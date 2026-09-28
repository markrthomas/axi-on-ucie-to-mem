// -----------------------------------------------------------------------------
// bind_sva : attach the AoU / AXI4-subset assertion checkers to the DUT.
//
// Kept in a separate file so the concurrent-SVA flows (Verilator --assert, UVM)
// compile it while the Icarus directed run omits it.
//   * axi4_sva     -> the DUT front door (AXI4-subset subordinate), every
//                     payload field incl. IDs, AxLEN/SIZE/BURST/PROT, W/RLAST.
//   * aou_flit_sva -> every ucie_stream_link (both A->B and B->A directions),
//     watching the flit presented on the link input.
// -----------------------------------------------------------------------------
`ifndef BIND_SVA_SV
`define BIND_SVA_SV

bind axi_ucie_mem_top axi4_sva #(
  .AW(AXI_ADDR_W), .DW(AXI_DATA_W), .SW(AXI_STRB_W), .IDW(AXI_ID_W)
) u_axi_sva (
  .clk(ACLK), .rstn(ARESETn),
  .awid(AWID), .awaddr(AWADDR), .awlen(AWLEN), .awsize(AWSIZE),
  .awburst(AWBURST), .awprot(AWPROT), .awvalid(AWVALID), .awready(AWREADY),
  .wdata(WDATA), .wstrb(WSTRB), .wlast(WLAST), .wvalid(WVALID), .wready(WREADY),
  .bid(BID), .bresp(BRESP), .bvalid(BVALID), .bready(BREADY),
  .arid(ARID), .araddr(ARADDR), .arlen(ARLEN), .arsize(ARSIZE),
  .arburst(ARBURST), .arprot(ARPROT), .arvalid(ARVALID), .arready(ARREADY),
  .rid(RID), .rdata(RDATA), .rresp(RRESP), .rlast(RLAST),
  .rvalid(RVALID), .rready(RREADY)
);

bind ucie_stream_link aou_flit_sva u_flit_sva (
  .clk(clk), .rstn(rstn),
  .flit(in_data), .valid(in_valid), .ready(in_ready)
);

// aou_credit_sva -> each bridge's held §6 credit counters, with per-counter
// ceilings (data-message credits now cover a full burst: WDATA/RDATA=128,
// WREQ/RREQ=3, WRESP=1).
bind aou_axi_initiator_bridge aou_credit_sva #(.CEIL0(3), .CEIL1(3), .CEIL2(128)) u_cr_sva (
  .clk(clk), .rstn(rstn), .c0(cr_wreq), .c1(cr_rreq), .c2(cr_wdata)
);

bind aou_axi_target_bridge aou_credit_sva #(.CEIL0(128), .CEIL1(1), .CEIL2(0)) u_cr_sva (
  .clk(clk), .rstn(rstn), .c0(cr_rdata), .c1(cr_wresp), .c2(8'd0)
);

`endif
