// -----------------------------------------------------------------------------
// aou_credit_fv : formal property harness for the §6 credit flow control of the
//                 two AoU bridges (initiator, chiplet A; target, chiplet B).
//
// Both bridges are instantiated with EVERY external input left free: the AXI
// side, the AXI-Lite memory responses, the link back-pressure, and — crucially —
// the 2000-bit received flit.  The peer is therefore completely adversarial: it
// may advertise any MsgCredit, any CrdtGrant bucket, at any time, in any §8
// activation phase.  Under that environment we prove the §6 invariants:
//
//   * BOUNDED / NO OVERFLOW — every held credit counter stays at or below its
//     configured ceiling, i.e. the §6.4 saturating replenish never inflates a
//     counter past the advertised buffer depth.  These are the SAME properties
//     (and the SAME ceilings, see the binds at the bottom of this file) that
//     dv/sva/aou_credit_sva.sv + dv/sva/bind_sva.sv carry in simulation, so the
//     Verilator/UVM SVA is now also discharged formally.  They are RESTATED here
//     as immediate assertions rather than binding aou_credit_sva directly
//     because yosys-slang rejects concurrent SVA ("SVA unsupported"); per the
//     plan's constraint the WRAPPER is adjusted, the property is not weakened —
//     `always @(posedge clk) if (rstn) assert (c <= CEIL)` is exactly
//     `assert property (@(posedge clk) disable iff (!rstn) c <= CEIL)`.
//   * NO UNDERFLOW / CREDITS NEVER GO NEGATIVE — the counters are unsigned 8-bit,
//     so a decrement below zero wraps to >= 248, far above every ceiling (3, 3,
//     128, 128, 1).  The bound assertions above therefore prove no counter is
//     ever decremented without being funded first.
//   * GATING / EVERY SEND IS FUNDED (§6.1) — whenever a bridge presents a data
//     flit for transmission, the credit counter for THE MESSAGE TYPE ACTUALLY
//     ENCODED IN THAT FLIT holds at least that message's granule count.  This is
//     strictly stronger than the RTL's `dtx_valid` gate: it also proves the FSM
//     state and the flit its packer built agree, so no message can be sent
//     against another type's credit.  aou_send_funded_fv below states it.
//
// Read with yosys-slang (`plugin -i slang; read_slang`): the RTL uses the
// `module <name> import aou_pkg::*;` header form and `bind`, neither of which the
// stock yosys Verilog frontend accepts.
//
// Formal-only file — no RTL or simulation source is modified by it.
// -----------------------------------------------------------------------------
`default_nettype none

// =============================================================================
// §6 credit checker.  Bound into each bridge, so it sees the bridge's own held
// counters and the data-path flit (dtx_*) it is presenting.  Counters for
// message types a given bridge never sends are tied to 0 (ceiling 0) by the
// bind, which makes the corresponding "funded" disjunct false — so sending an
// unexpected message type is itself a proof failure.
// =============================================================================
module aou_credit_props_fv
  import aou_pkg::*;
#(
    // per-counter ceilings, mirroring dv/sva/bind_sva.sv
    parameter int CEIL_WREQ  = 0,
    parameter int CEIL_RREQ  = 0,
    parameter int CEIL_WDATA = 0,
    parameter int CEIL_RDATA = 0,
    parameter int CEIL_WRESP = 0
) (
    input logic                clk,
    input logic                rstn,
    input logic [PLP_BITS-1:0] dtx_data,
    input logic                dtx_valid,
    input logic                dtx_ready,
    input logic [7:0]          c_wreq,
    input logic [7:0]          c_rreq,
    input logic [7:0]          c_wdata,
    input logic [7:0]          c_rdata,
    input logic [7:0]          c_wresp
);
  // MSGTYPE of the message the packer placed at granule 0 of this flit.
  wire [MSGTYPE_W-1:0] mt = payload_msgtype(flit_payload(dtx_data), 0);

  // --- bounded / no overflow / no underflow (== dv/sva/aou_credit_sva.sv) ----
  // The counters are unsigned 8-bit: an unfunded decrement wraps to >= 248,
  // which every ceiling below rejects, so these also prove "never negative".
  always @(posedge clk) if (rstn) begin
    assert (c_wreq  <= CEIL_WREQ[7:0]);
    assert (c_rreq  <= CEIL_RREQ[7:0]);
    assert (c_wdata <= CEIL_WDATA[7:0]);
    assert (c_rdata <= CEIL_RDATA[7:0]);
    assert (c_wresp <= CEIL_WRESP[7:0]);
  end

  // --- §6.1 every presented message is funded by its own type's credit ------
  always @(posedge clk) if (rstn) begin
    assert (!dtx_valid ||
            ((mt == MT_WRITEREQ)  && (c_wreq  >= WRITEREQ_GRAN[7:0]))  ||
            ((mt == MT_READREQ)   && (c_rreq  >= READREQ_GRAN[7:0]))   ||
            ((mt == MT_WRITEDATA) && (c_wdata >= WRITEDATA_GRAN[7:0])) ||
            ((mt == MT_READDATA)  && (c_rdata >= READDATA_GRAN[7:0]))  ||
            ((mt == MT_WRITERESP) && (c_wresp >= WRITERESP_GRAN[7:0])));
    // a zero credit for the presented type must block the send outright
    assert (!(dtx_valid && (mt == MT_WRITEREQ)  && (c_wreq  == 8'd0)));
    assert (!(dtx_valid && (mt == MT_READREQ)   && (c_rreq  == 8'd0)));
    assert (!(dtx_valid && (mt == MT_WRITEDATA) && (c_wdata == 8'd0)));
    assert (!(dtx_valid && (mt == MT_READDATA)  && (c_rdata == 8'd0)));
    assert (!(dtx_valid && (mt == MT_WRITERESP) && (c_wresp == 8'd0)));
  end

  // --- reachability: the credit machinery really can fund traffic ------------
  always @(posedge clk) if (rstn) begin
    // credits were granted by the peer (seed / MsgCredit replenish works)
    cover ({c_wreq, c_rreq, c_wdata} != '0 || {c_rdata, c_wresp} != '0);
    // a funded data-message send actually completes
    cover (dtx_valid && dtx_ready);
    // the saturating replenish reaches a full-burst ceiling (128 granules)
    cover (c_wdata == 8'd128 || c_rdata == 8'd128);
  end
endmodule

// =============================================================================
// Formal top: both bridges, every input free, internally generated reset.
// =============================================================================
module aou_credit_fv
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int AXI_ID_W   = 4
) (
    input wire                    clk,
    // ---- chiplet A (initiator bridge): free AXI4 subordinate stimulus -------
    input wire [AXI_ID_W-1:0]     i_awid,
    input wire [AXI_ADDR_W-1:0]   i_awaddr,
    input wire [7:0]              i_awlen,
    input wire [2:0]              i_awsize,
    input wire [1:0]              i_awburst,
    input wire [2:0]              i_awprot,
    input wire                    i_awvalid,
    input wire [AXI_DATA_W-1:0]   i_wdata,
    input wire [AXI_STRB_W-1:0]   i_wstrb,
    input wire                    i_wlast,
    input wire                    i_wvalid,
    input wire                    i_bready,
    input wire [AXI_ID_W-1:0]     i_arid,
    input wire [AXI_ADDR_W-1:0]   i_araddr,
    input wire [7:0]              i_arlen,
    input wire [2:0]              i_arsize,
    input wire [1:0]              i_arburst,
    input wire [2:0]              i_arprot,
    input wire                    i_arvalid,
    input wire                    i_rready,
    // ---- chiplet A link: adversarial peer ----------------------------------
    input wire                    i_tx_ready,
    input wire [PLP_BITS-1:0]     i_rx_data,
    input wire                    i_rx_valid,
    // ---- chiplet B (target bridge) link: adversarial peer ------------------
    input wire                    t_tx_ready,
    input wire [PLP_BITS-1:0]     t_rx_data,
    input wire                    t_rx_valid,
    // ---- chiplet B: free AXI-Lite memory responses -------------------------
    input wire                    t_awready,
    input wire                    t_wready,
    input wire [1:0]              t_bresp,
    input wire                    t_bvalid,
    input wire                    t_arready,
    input wire [AXI_DATA_W-1:0]   t_rdata,
    input wire [1:0]              t_rresp,
    input wire                    t_rvalid
);

  // --- internally generated reset: low at step 0, high thereafter -----------
  logic rst_done = 1'b0;
  always @(posedge clk) rst_done <= 1'b1;
  wire rstn = rst_done;

  // --- unused DUT outputs (the properties look at internals via bind) -------
  /* verilator lint_off UNUSEDSIGNAL */
  wire                  i_awready, i_wready, i_bvalid, i_arready, i_rvalid, i_rlast;
  wire [AXI_ID_W-1:0]   i_bid, i_rid;
  wire [1:0]            i_bresp, i_rresp;
  wire [AXI_DATA_W-1:0] i_rdata;
  wire [PLP_BITS-1:0]   i_tx_data;
  wire                  i_tx_valid, i_rx_ready;
  wire [PLP_BITS-1:0]   t_tx_data;
  wire                  t_tx_valid, t_rx_ready;
  wire [AXI_ADDR_W-1:0] t_awaddr, t_araddr;
  wire [2:0]            t_awprot, t_arprot;
  wire                  t_awvalid, t_wvalid, t_bready, t_arvalid, t_rready;
  wire [AXI_DATA_W-1:0] t_wdata;
  wire [AXI_STRB_W-1:0] t_wstrb;
  /* verilator lint_on UNUSEDSIGNAL */

  // === chiplet A =============================================================
  aou_axi_initiator_bridge #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .AXI_STRB_W(AXI_STRB_W), .AXI_ID_W(AXI_ID_W)
  ) u_init (
    .clk(clk), .rstn(rstn),
    .s_awid(i_awid), .s_awaddr(i_awaddr), .s_awlen(i_awlen), .s_awsize(i_awsize),
    .s_awburst(i_awburst), .s_awprot(i_awprot), .s_awvalid(i_awvalid),
    .s_awready(i_awready),
    .s_wdata(i_wdata), .s_wstrb(i_wstrb), .s_wlast(i_wlast), .s_wvalid(i_wvalid),
    .s_wready(i_wready),
    .s_bid(i_bid), .s_bresp(i_bresp), .s_bvalid(i_bvalid), .s_bready(i_bready),
    .s_arid(i_arid), .s_araddr(i_araddr), .s_arlen(i_arlen), .s_arsize(i_arsize),
    .s_arburst(i_arburst), .s_arprot(i_arprot), .s_arvalid(i_arvalid),
    .s_arready(i_arready),
    .s_rid(i_rid), .s_rdata(i_rdata), .s_rresp(i_rresp), .s_rlast(i_rlast),
    .s_rvalid(i_rvalid), .s_rready(i_rready),
    .tx_data(i_tx_data), .tx_valid(i_tx_valid), .tx_ready(i_tx_ready),
    .rx_data(i_rx_data), .rx_valid(i_rx_valid), .rx_ready(i_rx_ready)
  );

  // === chiplet B =============================================================
  aou_axi_target_bridge #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W),
    .AXI_STRB_W(AXI_STRB_W), .AXI_ID_W(AXI_ID_W)
  ) u_tgt (
    .clk(clk), .rstn(rstn),
    .rx_data(t_rx_data), .rx_valid(t_rx_valid), .rx_ready(t_rx_ready),
    .tx_data(t_tx_data), .tx_valid(t_tx_valid), .tx_ready(t_tx_ready),
    .m_awaddr(t_awaddr), .m_awprot(t_awprot), .m_awvalid(t_awvalid),
    .m_awready(t_awready),
    .m_wdata(t_wdata), .m_wstrb(t_wstrb), .m_wvalid(t_wvalid), .m_wready(t_wready),
    .m_bresp(t_bresp), .m_bvalid(t_bvalid), .m_bready(t_bready),
    .m_araddr(t_araddr), .m_arprot(t_arprot), .m_arvalid(t_arvalid),
    .m_arready(t_arready),
    .m_rdata(t_rdata), .m_rresp(t_rresp), .m_rvalid(t_rvalid), .m_rready(t_rready)
  );

endmodule

// =============================================================================
// Property binds.  Ceilings match dv/sva/bind_sva.sv exactly (WREQ/RREQ = 3
// granules, WDATA/RDATA = 128 granules = a full 16-beat burst, WRESP = 1);
// counters a bridge does not hold are tied to 0 with a ceiling of 0.
// =============================================================================
bind aou_axi_initiator_bridge aou_credit_props_fv #(
  .CEIL_WREQ(3), .CEIL_RREQ(3), .CEIL_WDATA(128)
) u_cr_fv (
  .clk(clk), .rstn(rstn),
  .dtx_data(dtx_data), .dtx_valid(dtx_valid), .dtx_ready(dtx_ready),
  .c_wreq(cr_wreq), .c_rreq(cr_rreq), .c_wdata(cr_wdata),
  .c_rdata(8'd0),   .c_wresp(8'd0)
);

bind aou_axi_target_bridge aou_credit_props_fv #(
  .CEIL_RDATA(128), .CEIL_WRESP(1)
) u_cr_fv (
  .clk(clk), .rstn(rstn),
  .dtx_data(dtx_data), .dtx_valid(dtx_valid), .dtx_ready(dtx_ready),
  .c_wreq(8'd0), .c_rreq(8'd0), .c_wdata(8'd0),
  .c_rdata(cr_rdata), .c_wresp(cr_wresp)
);

`default_nettype wire
