// -----------------------------------------------------------------------------
// bind_sva : attach the AoU / AXI-Lite assertion checkers to the DUT.
//
// Kept in a separate file so the concurrent-SVA flows (Verilator --assert, UVM)
// compile it while the Icarus directed run omits it.
//   * axi_lite_sva -> the DUT front door (AXI4-Lite subordinate).
//   * aou_flit_sva -> every ucie_stream_link (both A->B and B->A directions),
//     watching the flit presented on the link input.
// -----------------------------------------------------------------------------
`ifndef BIND_SVA_SV
`define BIND_SVA_SV

bind axi_ucie_mem_top axi_lite_sva u_axi_sva (
  .clk(ACLK), .rstn(ARESETn),
  .awaddr(AWADDR), .awvalid(AWVALID), .awready(AWREADY),
  .wdata(WDATA),   .wstrb(WSTRB), .wvalid(WVALID), .wready(WREADY),
  .bvalid(BVALID), .bready(BREADY),
  .araddr(ARADDR), .arvalid(ARVALID), .arready(ARREADY),
  .rdata(RDATA),   .rvalid(RVALID), .rready(RREADY)
);

bind ucie_stream_link aou_flit_sva u_flit_sva (
  .clk(clk), .rstn(rstn),
  .flit(in_data), .valid(in_valid), .ready(in_ready)
);

`endif
