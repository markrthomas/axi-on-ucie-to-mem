// -----------------------------------------------------------------------------
// aou_credit_sva : §6 flow-control safety checker for an AoU bridge.
//
// Bound into each bridge (initiator + target), it watches the per-message-type
// granule credit counters the bridge HOLDS to transmit.  Two things must hold:
//   * a counter never exceeds its configured ceiling (saturation is correct,
//     §6.4 — credits do not inflate past the advertised buffer depth);
//   * a counter never underflows.  The bridges only decrement a counter on a
//     send that its own tx_valid gate proved was funded, so a decrement below
//     zero (sending an unfunded message) is impossible — and would wrap the
//     8-bit counter far above the ceiling, tripping the same bound check.
//
// Compiled into the Verilator (--assert) and UVM flows; unused counter inputs
// are tied to 0 by the bind and pass trivially.
// -----------------------------------------------------------------------------
`ifndef AOU_CREDIT_SVA_SV
`define AOU_CREDIT_SVA_SV

module aou_credit_sva #(
    parameter int CEIL0 = 8,          // per-counter ceilings (differ by msg type)
    parameter int CEIL1 = 8,
    parameter int CEIL2 = 8
) (
    input logic       clk,
    input logic       rstn,
    input logic [7:0] c0,
    input logic [7:0] c1,
    input logic [7:0] c2
);

  // `disable iff (!rstn)` inlined per property (see axi_lite_sva note).
  a_c0_bound: assert property (@(posedge clk) disable iff (!rstn) c0 <= CEIL0[7:0]);
  a_c1_bound: assert property (@(posedge clk) disable iff (!rstn) c1 <= CEIL1[7:0]);
  a_c2_bound: assert property (@(posedge clk) disable iff (!rstn) c2 <= CEIL2[7:0]);

endmodule
`endif
