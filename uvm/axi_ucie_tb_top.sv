// -----------------------------------------------------------------------------
// axi_ucie_tb_top : simulation top.  Generates ACLK, binds the DUT
// (axi_ucie_mem_top) to the AXI4-Lite interface, publishes the virtual
// interface to the UVM config DB, and launches UVM via run_test (the test is
// selected with +UVM_TESTNAME=<name>).
//
// SV analogue of the cocotb entry points in dv/cocotb/axi_test.py:
//   +UVM_TESTNAME=axi_write_read_test   <-  write_read_test
//   +UVM_TESTNAME=axi_random_test       <-  random_test
//   +UVM_TESTNAME=axi_walking_test      <-  walking_test
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module axi_ucie_tb_top;

    import uvm_pkg::*;
    import axi_pkg::*;
    `include "uvm_macros.svh"

    localparam int AW = 32, DW = 32, IW = 4, MEM_ADDR_W = 16;

    // 10 ns clock, matching the cocotb BFM's 10 ns period.
    logic ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    axi_lite_if #(.AW(AW), .DW(DW), .IW(IW)) axi (.ACLK(ACLK));

    axi_ucie_mem_top #(
        .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .AXI_ID_W(IW), .MEM_ADDR_W(MEM_ADDR_W)
    ) dut (
        .ACLK(axi.ACLK), .ARESETn(axi.ARESETn),
        .AWID(axi.AWID),     .AWADDR(axi.AWADDR), .AWLEN(axi.AWLEN),     .AWSIZE(axi.AWSIZE),
        .AWBURST(axi.AWBURST), .AWPROT(axi.AWPROT), .AWVALID(axi.AWVALID), .AWREADY(axi.AWREADY),
        .WDATA(axi.WDATA),   .WSTRB(axi.WSTRB),   .WLAST(axi.WLAST),
        .WVALID(axi.WVALID), .WREADY(axi.WREADY),
        .BID(axi.BID),       .BRESP(axi.BRESP),   .BVALID(axi.BVALID),   .BREADY(axi.BREADY),
        .ARID(axi.ARID),     .ARADDR(axi.ARADDR), .ARLEN(axi.ARLEN),     .ARSIZE(axi.ARSIZE),
        .ARBURST(axi.ARBURST), .ARPROT(axi.ARPROT), .ARVALID(axi.ARVALID), .ARREADY(axi.ARREADY),
        .RID(axi.RID),       .RDATA(axi.RDATA),   .RRESP(axi.RRESP),     .RLAST(axi.RLAST),
        .RVALID(axi.RVALID), .RREADY(axi.RREADY)
    );

    initial begin
        uvm_config_db#(virtual axi_lite_if)::set(null, "*", "vif", axi);
        // Default to the random-mix test (64 items, >= 5 txns); +UVM_TESTNAME
        // overrides it when given (so it "just runs" on EDA Playground with no
        // run-option set).
        run_test("axi_random_test");
    end

`ifdef DUMP
    initial begin
        $dumpfile("axi_ucie_tb_top.vcd");
        $dumpvars(0, axi_ucie_tb_top);
    end
`endif

endmodule
