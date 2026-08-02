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

    localparam int AW = 32, DW = 32, MEM_ADDR_W = 16;

    // 10 ns clock, matching the cocotb BFM's 10 ns period.
    logic ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    axi_lite_if #(.AW(AW), .DW(DW)) axi (.ACLK(ACLK));

    axi_ucie_mem_top #(
        .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .MEM_ADDR_W(MEM_ADDR_W)
    ) dut (
        .ACLK(axi.ACLK), .ARESETn(axi.ARESETn),
        .AWADDR(axi.AWADDR), .AWPROT(axi.AWPROT), .AWVALID(axi.AWVALID), .AWREADY(axi.AWREADY),
        .WDATA(axi.WDATA),   .WSTRB(axi.WSTRB),   .WVALID(axi.WVALID),   .WREADY(axi.WREADY),
        .BRESP(axi.BRESP),   .BVALID(axi.BVALID), .BREADY(axi.BREADY),
        .ARADDR(axi.ARADDR), .ARPROT(axi.ARPROT), .ARVALID(axi.ARVALID), .ARREADY(axi.ARREADY),
        .RDATA(axi.RDATA),   .RRESP(axi.RRESP),   .RVALID(axi.RVALID),   .RREADY(axi.RREADY)
    );

    initial begin
        uvm_config_db#(virtual axi_lite_if)::set(null, "*", "vif", axi);
        // Default to the write-read test; +UVM_TESTNAME overrides it when given
        // (so it "just runs" on EDA Playground with no run-option set).
        run_test("axi_write_read_test");
    end

`ifdef DUMP
    initial begin
        $dumpfile("axi_ucie_tb_top.vcd");
        $dumpvars(0, axi_ucie_tb_top);
    end
`endif

endmodule
