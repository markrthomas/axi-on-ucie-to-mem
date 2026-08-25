// -----------------------------------------------------------------------------
// aou_rp_mux : resource-plane (§3) multiplexing onto one shared UCIe flit link.
//
// docs/PLAN.md F1.  A chiplet runs NUM_RP independent AoU chains — one per
// resource plane — over a SINGLE physical link.  Two small blocks do all the
// plane multiplexing; everything else (bridges, activation, credits) is the
// existing single-plane logic, instantiated once per plane:
//
//   aou_rp_arb   N -> 1 egress.  Round-robin over the planes that have a flit
//                ready, so every ready plane is served within NUM_RP grants
//                (starvation-free); the grant is LOCKED while the link stalls so
//                the presented flit is held stable (the §4.3 flit SVA checks it).
//
//   aou_rp_route 1 -> N ingress.  Routes each arriving flit to the plane named by
//                its §4.3 FDId header field and buffers it in that plane's OWN
//                receive queue.  A plane therefore only ever sees flits addressed
//                to it: responses and the MsgCredit word they carry cannot reach
//                another plane's bridge, which is what makes the per-plane credit
//                banks isolated by construction.
//
// Why the per-plane receive queue matters (head-of-line blocking).  §6.1: "a
// credit guarantees the receiver has room" — so a receiver must actually own the
// room it advertised, otherwise it backpressures the SHARED link and one plane's
// stall becomes every plane's stall.  RX_D is therefore sized to the largest
// credit grant in flits (128 granules / 8 granules-per-data-message = 16), so a
// fully-credited plane can always be drained off the link even while its bridge
// is busy or its AXI master is backpressuring.  With that buffer, a plane that is
// out of credits sends nothing and a plane that is stalled absorbs what it was
// credited for — neither can stall another plane.
//
// Not elaborated at NUM_RP == 1: axi_ucie_mem_top's single-plane branch wires the
// bridges straight to the links exactly as before.
// -----------------------------------------------------------------------------
`ifndef AOU_RP_MUX_SV
`define AOU_RP_MUX_SV

// =============================================================================
// aou_rp_arb : round-robin N->1 flit arbiter (plane egress onto the link).
// =============================================================================
module aou_rp_arb #(
    parameter int W      = 2000,          // flit width (PLP bits)
    parameter int NUM_RP = 2              // number of planes (>= 2 here)
) (
    input  logic                clk,
    input  logic                rstn,
    // per-plane inputs, plane p in bits [p*W +: W]
    input  logic [NUM_RP*W-1:0] in_data,
    input  logic [NUM_RP-1:0]   in_valid,
    output logic [NUM_RP-1:0]   in_ready,
    // shared link output
    output logic [W-1:0]        out_data,
    output logic                out_valid,
    input  logic                out_ready,
    // grant observability (per-plane served count / fairness checks in DV)
    output logic [NUM_RP-1:0]   grant
);

  localparam int SELW = (NUM_RP > 1) ? $clog2(NUM_RP) : 1;

  logic [SELW-1:0] last;        // last plane granted (rotation anchor)
  logic [SELW-1:0] rr_sel;      // round-robin pick this cycle
  logic            rr_hit;
  logic            lock;        // grant held across a link stall
  logic [SELW-1:0] lock_sel;

  // Rotate the priority: the plane AFTER the last one granted looks first, so a
  // ready plane waits at most NUM_RP-1 grants.
  always_comb begin
    // verilator lint_off UNUSEDSIGNAL
    int idx;                     // only the low $clog2(NUM_RP) bits are used
    // verilator lint_on UNUSEDSIGNAL
    rr_sel = '0;
    rr_hit = 1'b0;
    for (int k = 1; k <= NUM_RP; k++) begin
      idx = (int'(last) + k) % NUM_RP;
      if (!rr_hit && in_valid[idx]) begin
        rr_hit = 1'b1;
        rr_sel = SELW'(idx);
      end
    end
  end

  wire [SELW-1:0] sel   = lock ? lock_sel : rr_sel;
  wire            valid = lock ? in_valid[lock_sel] : rr_hit;

  assign out_valid = valid;
  assign out_data  = in_data[int'(sel)*W +: W];

  always_comb begin
    grant = '0;
    if (valid) grant[sel] = 1'b1;
  end
  assign in_ready = grant & {NUM_RP{out_ready}};

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      last <= '0; lock <= 1'b0; lock_sel <= '0;
    end else begin
      // hold the selection while the link stalls (flit must stay stable)
      lock     <= valid && !out_ready;
      lock_sel <= sel;
      if (valid && out_ready) last <= sel;
    end
  end

endmodule

// =============================================================================
// aou_flit_fifo : DEPTH-deep flit queue (a plane's receive buffer).
// =============================================================================
module aou_flit_fifo #(
    parameter int W     = 2000,
    parameter int DEPTH = 16              // power of two
) (
    input  logic         clk,
    input  logic         rstn,
    input  logic [W-1:0] in_data,
    input  logic         in_valid,
    output logic         in_ready,
    output logic [W-1:0] out_data,
    output logic         out_valid,
    input  logic         out_ready
);

  localparam int PW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

  logic [W-1:0]  mem [0:DEPTH-1];
  logic [PW-1:0] head, tail;
  logic [PW:0]   count;

  wire full        = (count == (PW+1)'(DEPTH));
  assign in_ready  = !full || out_ready;
  assign out_valid = (count != '0);
  assign out_data  = mem[head];

  wire push = in_valid  && in_ready;
  wire pop  = out_valid && out_ready;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      head <= '0; tail <= '0; count <= '0;
      for (int i = 0; i < DEPTH; i++) mem[i] <= '0;
    end else begin
      if (push) begin
        mem[tail] <= in_data;
        tail      <= (int'(tail) == DEPTH-1) ? '0 : tail + 1'b1;
      end
      if (pop) head <= (int'(head) == DEPTH-1) ? '0 : head + 1'b1;
      if      (push && !pop) count <= count + 1'b1;
      else if (!push && pop) count <= count - 1'b1;
    end
  end

endmodule

// =============================================================================
// aou_rp_route : 1->N flit router by §4.3 FDId + per-plane receive queue.
// =============================================================================
module aou_rp_route
  import aou_pkg::*;
#(
    parameter int NUM_RP = 2,
    // Receive queue depth per plane, in flits.  Must cover the largest credit
    // grant this endpoint advertises (see the file header).
    parameter int RX_D   = 16
) (
    input  logic                       clk,
    input  logic                       rstn,
    // shared link input
    input  logic [PLP_BITS-1:0]        in_data,
    input  logic                       in_valid,
    output logic                       in_ready,
    // per-plane outputs, plane p in bits [p*PLP_BITS +: PLP_BITS]
    output logic [NUM_RP*PLP_BITS-1:0] out_data,
    output logic [NUM_RP-1:0]          out_valid,
    input  logic [NUM_RP-1:0]          out_ready
);

  wire [FDID_W-1:0]  fdid = flit_fdid(in_data);

  logic [NUM_RP-1:0] hit;          // flit is addressed to plane p
  logic [NUM_RP-1:0] q_in_valid, q_in_ready;

  always_comb begin
    for (int p = 0; p < NUM_RP; p++)
      hit[p] = in_valid && (fdid == FDID_W'(p));
  end

  assign q_in_valid = hit;
  // Accept when the addressed plane's queue can take it.  An FDId outside
  // 0..NUM_RP-1 addresses no plane in this build and is consumed and dropped so
  // it can never wedge the shared link; dv/sva/aou_flit_sva.sv asserts every
  // transmitted flit carries an in-range FDId, so this is unreachable here.
  assign in_ready = (|hit) ? |(hit & q_in_ready) : 1'b1;

  genvar p;
  generate
    for (p = 0; p < NUM_RP; p++) begin : g_q
      aou_flit_fifo #(.W(PLP_BITS), .DEPTH(RX_D)) u_q (
        .clk(clk), .rstn(rstn),
        .in_data(in_data), .in_valid(q_in_valid[p]), .in_ready(q_in_ready[p]),
        .out_data(out_data[p*PLP_BITS +: PLP_BITS]),
        .out_valid(out_valid[p]), .out_ready(out_ready[p])
      );
    end
  endgenerate

endmodule

`endif
