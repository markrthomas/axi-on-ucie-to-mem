// -----------------------------------------------------------------------------
// axi_lite_sva : concurrent-assertion checker for an AXI4-Lite bus.
//
// Bind onto a module exposing an AXI4-Lite interface (here: the DUT front door)
// to check the handshake protocol independently of the data scoreboard:
//   * a channel's VALID, once asserted, stays asserted until READY (no dropping
//     a request the slave has not accepted);
//   * address/data payloads are stable while a transfer is stalled;
//   * control signals are known (no X) out of reset.
//
// Concurrent SVA is carried by the Verilator (--assert) and commercial/UVM
// flows; the Icarus directed run does not compile this (its SVA support is too
// weak), matching the sibling repo's convention.
// -----------------------------------------------------------------------------
`ifndef AXI_LITE_SVA_SV
`define AXI_LITE_SVA_SV

module axi_lite_sva #(
    parameter int AW = 32,
    parameter int DW = 32,
    parameter int SW = DW/8
) (
    input logic          clk,
    input logic          rstn,
    input logic [AW-1:0] awaddr,  input logic awvalid, input logic awready,
    input logic [DW-1:0] wdata,   input logic [SW-1:0] wstrb,
                                  input logic wvalid,  input logic wready,
    input logic          bvalid,  input logic bready,
    input logic [AW-1:0] araddr,  input logic arvalid, input logic arready,
    input logic [DW-1:0] rdata,   input logic rvalid,  input logic rready
);

  default disable iff (!rstn);

  // --- VALID held until READY ------------------------------------------------
  property p_hold(valid, ready);
    @(posedge clk) (valid && !ready) |=> valid;
  endproperty
  a_aw_hold: assert property (p_hold(awvalid, awready));
  a_w_hold:  assert property (p_hold(wvalid,  wready));
  a_b_hold:  assert property (p_hold(bvalid,  bready));
  a_ar_hold: assert property (p_hold(arvalid, arready));
  a_r_hold:  assert property (p_hold(rvalid,  rready));

  // --- payload stable while stalled -----------------------------------------
  a_aw_stable: assert property (@(posedge clk)
    (awvalid && !awready) |=> $stable(awaddr));
  a_w_stable:  assert property (@(posedge clk)
    (wvalid && !wready) |=> ($stable(wdata) && $stable(wstrb)));
  a_ar_stable: assert property (@(posedge clk)
    (arvalid && !arready) |=> $stable(araddr));
  a_r_stable:  assert property (@(posedge clk)
    (rvalid && !rready) |=> $stable(rdata));

  // --- control signals known out of reset -----------------------------------
  a_known: assert property (@(posedge clk)
    !$isunknown({awvalid, wvalid, bvalid, arvalid, rvalid,
                 awready, wready, bready, arready, rready}));

endmodule
`endif
