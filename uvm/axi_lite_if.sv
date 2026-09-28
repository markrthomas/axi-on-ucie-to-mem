// -----------------------------------------------------------------------------
// axi_lite_if : AXI signal bundle shared by the UVM driver, monitor and DUT.
// The clock (ACLK) is generated in the top module and passed in; every other
// signal lives here so the class-based components only ever touch a virtual
// interface handle (the SV analogue of the cocotb BFM boundary).  Carries the
// AXI4-Lite core plus the AXI4 fields of the DUT's AXI4-subset boundary
// (Ax{ID,LEN,SIZE,BURST}, WLAST, {B,R}ID, RLAST) so every DUT port is
// connected; the UVM env drives them as single-beat transfers.
// -----------------------------------------------------------------------------
interface axi_lite_if #(
    parameter int AW = 32,
    parameter int DW = 32,
    parameter int SW = DW/8,
    parameter int IW = 4        // AXI ID width (matches axi_ucie_mem_top AXI_ID_W)
) (
    input logic ACLK
);
    logic          ARESETn;
    // write address
    logic [IW-1:0] AWID;
    logic [AW-1:0] AWADDR;
    logic [7:0]    AWLEN;
    logic [2:0]    AWSIZE;
    logic [1:0]    AWBURST;
    logic [2:0]    AWPROT;
    logic          AWVALID;
    logic          AWREADY;
    // write data
    logic [DW-1:0] WDATA;
    logic [SW-1:0] WSTRB;
    logic          WLAST;
    logic          WVALID;
    logic          WREADY;
    // write response
    logic [IW-1:0] BID;
    logic [1:0]    BRESP;
    logic          BVALID;
    logic          BREADY;
    // read address
    logic [IW-1:0] ARID;
    logic [AW-1:0] ARADDR;
    logic [7:0]    ARLEN;
    logic [2:0]    ARSIZE;
    logic [1:0]    ARBURST;
    logic [2:0]    ARPROT;
    logic          ARVALID;
    logic          ARREADY;
    // read data
    logic [IW-1:0] RID;
    logic [DW-1:0] RDATA;
    logic [1:0]    RRESP;
    logic          RLAST;
    logic          RVALID;
    logic          RREADY;
endinterface
