// -----------------------------------------------------------------------------
// axi_lite_if : AXI4-Lite signal bundle shared by the UVM driver, monitor and
// DUT.  The clock (ACLK) is generated in the top module and passed in; every
// other signal lives here so the class-based components only ever touch a
// virtual interface handle (the SV analogue of the cocotb BFM boundary).
// -----------------------------------------------------------------------------
interface axi_lite_if #(
    parameter int AW = 32,
    parameter int DW = 32,
    parameter int SW = DW/8
) (
    input logic ACLK
);
    logic          ARESETn;
    // write address
    logic [AW-1:0] AWADDR;
    logic [2:0]    AWPROT;
    logic          AWVALID;
    logic          AWREADY;
    // write data
    logic [DW-1:0] WDATA;
    logic [SW-1:0] WSTRB;
    logic          WVALID;
    logic          WREADY;
    // write response
    logic [1:0]    BRESP;
    logic          BVALID;
    logic          BREADY;
    // read address
    logic [AW-1:0] ARADDR;
    logic [2:0]    ARPROT;
    logic          ARVALID;
    logic          ARREADY;
    // read data
    logic [DW-1:0] RDATA;
    logic [1:0]    RRESP;
    logic          RVALID;
    logic          RREADY;
endinterface
