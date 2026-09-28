// -----------------------------------------------------------------------------
// axi4_sva : concurrent-assertion checker for the AXI4-subset front door.
//
// The DUT boundary is an AXI4 subset (IDs, AxLEN/AxSIZE/AxBURST, WLAST, RLAST;
// see README "AXI4 subset profile"), so this checker covers every payload field
// the boundary carries, on all five channels:
//   * a channel's VALID, once asserted, stays asserted until READY (no dropping
//     a transfer the other side has not accepted);
//   * EVERY payload field of a channel is stable while that channel is stalled
//     (VALID && !READY) -- AW/AR: ID, ADDR, LEN, SIZE, BURST, PROT;
//     W: DATA, STRB, LAST;  B: ID, RESP;  R: ID, DATA, RESP, LAST;
//   * control signals are known (no X) out of reset.
//
// Stability is checked with `sig === $past(sig)` rather than $stable(): a
// 4-state simulator then treats an undriven (z) field as stable instead of
// raising an X-induced false failure (the license-gated UVM tops leave the
// AXI4-only fields unconnected).
//
// Concurrent SVA is carried by the Verilator (--assert) and commercial/UVM
// flows; the Icarus directed run does not compile this (its SVA support is too
// weak).  dv/sva/mut/ proves each stability property can fail (`make sva-mut`).
// Replaces the former axi_lite_sva (SCAN_ISSUES #4), which only checked the
// address/data fields and was named for a protocol the boundary is not.
// -----------------------------------------------------------------------------
`ifndef AXI4_SVA_SV
`define AXI4_SVA_SV

module axi4_sva #(
    parameter int AW  = 32,
    parameter int DW  = 32,
    parameter int SW  = DW/8,
    parameter int IDW = 4
) (
    input logic           clk,
    input logic           rstn,
    // AW
    input logic [IDW-1:0] awid,   input logic [AW-1:0] awaddr, input logic [7:0] awlen,
    input logic [2:0]     awsize, input logic [1:0]    awburst, input logic [2:0] awprot,
    input logic           awvalid, input logic awready,
    // W
    input logic [DW-1:0]  wdata,  input logic [SW-1:0] wstrb, input logic wlast,
    input logic           wvalid, input logic wready,
    // B
    input logic [IDW-1:0] bid,    input logic [1:0] bresp,
    input logic           bvalid, input logic bready,
    // AR
    input logic [IDW-1:0] arid,   input logic [AW-1:0] araddr, input logic [7:0] arlen,
    input logic [2:0]     arsize, input logic [1:0]    arburst, input logic [2:0] arprot,
    input logic           arvalid, input logic arready,
    // R
    input logic [IDW-1:0] rid,    input logic [DW-1:0] rdata, input logic [1:0] rresp,
    input logic           rlast,  input logic rvalid, input logic rready
);

  // `disable iff (!rstn)` is inlined per property rather than via a module-level
  // `default disable iff` (the latter is unsupported by some Verilator 5.x).

  // --- VALID held until READY ------------------------------------------------
  property p_hold(valid, ready);
    @(posedge clk) disable iff (!rstn) (valid && !ready) |=> valid;
  endproperty
  a_aw_hold: assert property (p_hold(awvalid, awready));
  a_w_hold:  assert property (p_hold(wvalid,  wready));
  a_b_hold:  assert property (p_hold(bvalid,  bready));
  a_ar_hold: assert property (p_hold(arvalid, arready));
  a_r_hold:  assert property (p_hold(rvalid,  rready));

  // --- every payload field stable while its channel is stalled ---------------
  a_aw_stable: assert property (@(posedge clk) disable iff (!rstn)
    (awvalid && !awready) |=>
      (awid    === $past(awid))    && (awaddr  === $past(awaddr)) &&
      (awlen   === $past(awlen))   && (awsize  === $past(awsize)) &&
      (awburst === $past(awburst)) && (awprot  === $past(awprot)));
  a_w_stable: assert property (@(posedge clk) disable iff (!rstn)
    (wvalid && !wready) |=>
      (wdata === $past(wdata)) && (wstrb === $past(wstrb)) &&
      (wlast === $past(wlast)));
  a_b_stable: assert property (@(posedge clk) disable iff (!rstn)
    (bvalid && !bready) |=>
      (bid === $past(bid)) && (bresp === $past(bresp)));
  a_ar_stable: assert property (@(posedge clk) disable iff (!rstn)
    (arvalid && !arready) |=>
      (arid    === $past(arid))    && (araddr  === $past(araddr)) &&
      (arlen   === $past(arlen))   && (arsize  === $past(arsize)) &&
      (arburst === $past(arburst)) && (arprot  === $past(arprot)));
  a_r_stable: assert property (@(posedge clk) disable iff (!rstn)
    (rvalid && !rready) |=>
      (rid   === $past(rid))   && (rdata === $past(rdata)) &&
      (rresp === $past(rresp)) && (rlast === $past(rlast)));

  // --- control signals known out of reset -----------------------------------
  a_known: assert property (@(posedge clk) disable iff (!rstn)
    !$isunknown({awvalid, wvalid, bvalid, arvalid, rvalid,
                 awready, wready, bready, arready, rready}));

endmodule
`endif
