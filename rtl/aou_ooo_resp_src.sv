// -----------------------------------------------------------------------------
// aou_ooo_resp_src : optional out-of-order RESPONSE SOURCE for the AoU target.
//
// Sits on the target bridge's response (B->A) flit path, between the bridge FSM
// and its §8 activation mux, and turns the otherwise strictly in-order response
// stream into a legally out-of-order one:
//
//   * it may HOLD one completed, single-flit response transaction (a WriteResp,
//     or a single-beat ReadData — i.e. one whose first flit is also its last);
//   * a LATER response of a DIFFERENT ID is then forwarded past the held one,
//     so it overtakes it on the link;
//   * the held response is released as soon as one whole transaction has passed
//     it, or a response of the SAME ID arrives (same-ID order is inviolable), or
//     a bounded hold timer expires (liveness with no other traffic).
//
// It therefore only ever reorders responses of DIFFERENT IDs — the exact
// freedom AXI grants — and never splits or interleaves the flits of one
// transaction (a multi-flit ReadData burst is always forwarded whole, and is
// never chosen as the held transaction).  Bounded state: one flit register, one
// ID register and one down-counter; nothing scales with traffic.
//
// This is the "OOO source" of docs/PLAN.md F2.  It is instantiated ONLY when
// aou_axi_target_bridge is built with OOO_EN=1; with the shipping default
// (OOO_EN=0) the bridge's response path is a plain wire and this module is not
// elaborated at all, so the default datapath is bit- and cycle-identical.
// -----------------------------------------------------------------------------
`ifndef AOU_OOO_RESP_SRC_SV
`define AOU_OOO_RESP_SRC_SV

module aou_ooo_resp_src
  import aou_pkg::*;
#(
    parameter int AXI_ID_W = 4,
    // Cycles a response may be held with no other traffic to overtake it.
    // Bounds the added latency (and guarantees forward progress) when the
    // initiator has only one transaction outstanding.
    parameter int HOLD_CYC = 48
) (
    input  logic                clk,
    input  logic                rstn,
    // from the target bridge FSM
    input  logic [PLP_BITS-1:0] in_data,
    input  logic                in_valid,
    output logic                in_ready,
    // to the link (via the §8 activation mux)
    output logic [PLP_BITS-1:0] out_data,
    output logic                out_valid,
    input  logic                out_ready
);

  localparam int CW = $clog2(HOLD_CYC + 1);

  // --- decode the response's ID and its end-of-transaction marker -----------
  // Every response message starts at granule 0 and both fields we need (RID/BID
  // at bit offset 24, RLAST at offset 36) live inside that first 40-bit granule,
  // so one 1-granule payload_get() serves WriteResp and ReadData alike.
  msg_t                 m1;
  logic [MSGTYPE_W-1:0] mt;
  logic                 in_last;
  // verilator lint_off UNUSEDSIGNAL
  logic [AOU_ID_W-1:0]  in_id_full;         // only the low AXI_ID_W bits are used
  // verilator lint_on UNUSEDSIGNAL
  assign m1         = payload_get(flit_payload(in_data), 0, 1);
  assign mt         = get_msgtype(m1);
  assign in_last    = (mt == MT_WRITERESP) ? 1'b1 : rd_last(m1);
  assign in_id_full = (mt == MT_WRITERESP) ? wrsp_id(m1) : rd_id(m1);
  wire [AXI_ID_W-1:0] in_id = in_id_full[AXI_ID_W-1:0];

  // --- held-response state --------------------------------------------------
  logic                mid;        // mid-transaction on the forwarded stream
  logic                h_valid;    // a response transaction is being held
  logic [PLP_BITS-1:0] h_data;
  logic [AXI_ID_W-1:0] h_id;
  logic [CW-1:0]       h_timer;
  logic                fwd_seen;   // a whole transaction overtook the held one
  logic                flushing;   // release in progress (keeps out_valid stable)

  wire in_first   = !mid;                         // next flit starts a transaction
  // A same-ID response must never overtake the held one: release it first.
  wire same_id_in = h_valid && in_valid && in_first && (in_id == h_id);
  wire flush_trig = h_valid && !mid &&
                    (fwd_seen || (h_timer == '0) || same_id_in);
  // Latched once triggered so out_valid never drops before out_ready (the flit
  // link and dv/sva/aou_flit_sva both require a stable valid/ready handshake).
  wire flush_now  = h_valid && (flushing || flush_trig);
  // Take a complete single-flit response into the hold register.
  wire capture    = !flush_now && !h_valid && in_valid && in_first && in_last;

  assign out_valid = flush_now ? 1'b1 : (in_valid && !capture);
  assign out_data  = flush_now ? h_data : in_data;
  assign in_ready  = !flush_now && (capture || out_ready);

  wire in_fire  = in_valid && in_ready;
  wire fwd_fire = in_fire && !capture;             // a flit was forwarded

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      mid      <= 1'b0;
      h_valid  <= 1'b0;
      h_data   <= '0;
      h_id     <= '0;
      h_timer  <= '0;
      fwd_seen <= 1'b0;
      flushing <= 1'b0;
    end else begin
      if (in_fire) mid <= !in_last;
      if (capture) begin
        h_valid  <= 1'b1;
        h_data   <= in_data;
        h_id     <= in_id;
        h_timer  <= CW'(HOLD_CYC);
        fwd_seen <= 1'b0;
      end else begin
        if (h_valid && (h_timer != '0)) h_timer <= h_timer - 1'b1;
        if (fwd_fire && in_last)        fwd_seen <= 1'b1;
        if (flush_now && out_ready) begin
          h_valid  <= 1'b0;
          fwd_seen <= 1'b0;
        end
      end
      flushing <= flush_now && !out_ready;
    end
  end

endmodule
`endif
