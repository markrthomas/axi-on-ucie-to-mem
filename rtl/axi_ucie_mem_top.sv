// -----------------------------------------------------------------------------
// axi_ucie_mem_top : DUT top — AXI-Lite over UCIe (AoU) to an AXI-Lite memory.
//
//   TB AXI-Lite master
//        -> aou_axi_initiator_bridge  (chiplet A: AXI-Lite SUB -> AoU flits)
//        == ucie_stream_link A->B ==>
//        -> aou_axi_target_bridge     (chiplet B: AoU flits -> AXI-Lite MGR)
//        -> axi_lite_mem              (the memory)
//        <= ucie_stream_link B->A <=  (WriteResp / ReadData flits)
//
// Flat AXI-Lite ports on the boundary (no SystemVerilog interface) so the same
// DUT is drivable from cocotb, a portable SV TB, a Verilator SystemC harness,
// and UVM without wrapper shims.
// -----------------------------------------------------------------------------
`ifndef AXI_UCIE_MEM_TOP_SV
`define AXI_UCIE_MEM_TOP_SV

module axi_ucie_mem_top
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int MEM_ADDR_W = 16          // memory byte-address width (64 KiB)
) (
    input  logic                  ACLK,
    input  logic                  ARESETn,
    // AXI4-Lite subordinate (TB master side)
    input  logic [AXI_ADDR_W-1:0] AWADDR,
    input  logic [2:0]            AWPROT,
    input  logic                  AWVALID,
    output logic                  AWREADY,
    input  logic [AXI_DATA_W-1:0] WDATA,
    input  logic [AXI_STRB_W-1:0] WSTRB,
    input  logic                  WVALID,
    output logic                  WREADY,
    output logic [1:0]            BRESP,
    output logic                  BVALID,
    input  logic                  BREADY,
    input  logic [AXI_ADDR_W-1:0] ARADDR,
    input  logic [2:0]            ARPROT,
    input  logic                  ARVALID,
    output logic                  ARREADY,
    output logic [AXI_DATA_W-1:0] RDATA,
    output logic [1:0]            RRESP,
    output logic                  RVALID,
    input  logic                  RREADY
);

  // --- flit links (both directions) -----------------------------------------
  logic [PLP_BITS-1:0] a2b_data, b2a_data;
  logic                a2b_valid, a2b_ready, b2a_valid, b2a_ready;

  // initiator side of each link (as seen by the initiator bridge)
  logic [PLP_BITS-1:0] init_tx_data, init_rx_data;
  logic                init_tx_valid, init_tx_ready, init_rx_valid, init_rx_ready;
  // target side of each link
  logic [PLP_BITS-1:0] tgt_tx_data, tgt_rx_data;
  logic                tgt_tx_valid, tgt_tx_ready, tgt_rx_valid, tgt_rx_ready;

  // --- chiplet-B AXI-Lite manager <-> memory --------------------------------
  logic [AXI_ADDR_W-1:0] m_awaddr, m_araddr;
  logic [2:0]            m_awprot, m_arprot;
  logic                  m_awvalid, m_awready, m_wvalid, m_wready;
  logic [AXI_DATA_W-1:0] m_wdata, m_rdata;
  logic [AXI_STRB_W-1:0] m_wstrb;
  logic [1:0]            m_bresp, m_rresp;
  logic                  m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;

  // === Chiplet A: initiator bridge =========================================
  aou_axi_initiator_bridge #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W)
  ) u_init (
    .clk(ACLK), .rstn(ARESETn),
    .s_awaddr(AWADDR), .s_awprot(AWPROT), .s_awvalid(AWVALID), .s_awready(AWREADY),
    .s_wdata(WDATA),   .s_wstrb(WSTRB),   .s_wvalid(WVALID),   .s_wready(WREADY),
    .s_bresp(BRESP),   .s_bvalid(BVALID), .s_bready(BREADY),
    .s_araddr(ARADDR), .s_arprot(ARPROT), .s_arvalid(ARVALID), .s_arready(ARREADY),
    .s_rdata(RDATA),   .s_rresp(RRESP),   .s_rvalid(RVALID),   .s_rready(RREADY),
    .tx_data(init_tx_data), .tx_valid(init_tx_valid), .tx_ready(init_tx_ready),
    .rx_data(init_rx_data), .rx_valid(init_rx_valid), .rx_ready(init_rx_ready)
  );

  // === A->B link ============================================================
  ucie_stream_link #(.W(PLP_BITS)) u_link_a2b (
    .clk(ACLK), .rstn(ARESETn),
    .in_data(init_tx_data), .in_valid(init_tx_valid), .in_ready(init_tx_ready),
    .out_data(a2b_data),    .out_valid(a2b_valid),    .out_ready(a2b_ready)
  );
  assign tgt_rx_data  = a2b_data;
  assign tgt_rx_valid = a2b_valid;
  assign a2b_ready    = tgt_rx_ready;

  // === B->A link ============================================================
  ucie_stream_link #(.W(PLP_BITS)) u_link_b2a (
    .clk(ACLK), .rstn(ARESETn),
    .in_data(tgt_tx_data), .in_valid(tgt_tx_valid), .in_ready(tgt_tx_ready),
    .out_data(b2a_data),   .out_valid(b2a_valid),   .out_ready(b2a_ready)
  );
  assign init_rx_data  = b2a_data;
  assign init_rx_valid = b2a_valid;
  assign b2a_ready     = init_rx_ready;

  // === Chiplet B: target bridge ============================================
  aou_axi_target_bridge #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W)
  ) u_tgt (
    .clk(ACLK), .rstn(ARESETn),
    .rx_data(tgt_rx_data), .rx_valid(tgt_rx_valid), .rx_ready(tgt_rx_ready),
    .tx_data(tgt_tx_data), .tx_valid(tgt_tx_valid), .tx_ready(tgt_tx_ready),
    .m_awaddr(m_awaddr), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
    .m_wdata(m_wdata),   .m_wstrb(m_wstrb),   .m_wvalid(m_wvalid),   .m_wready(m_wready),
    .m_bresp(m_bresp),   .m_bvalid(m_bvalid), .m_bready(m_bready),
    .m_araddr(m_araddr), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready),
    .m_rdata(m_rdata),   .m_rresp(m_rresp),   .m_rvalid(m_rvalid),   .m_rready(m_rready)
  );

  // === Chiplet B: AXI-Lite memory ==========================================
  axi_lite_mem #(
    .ADDR_W(MEM_ADDR_W), .DATA_W(AXI_DATA_W), .STRB_W(AXI_STRB_W)
  ) u_mem (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWADDR(m_awaddr[MEM_ADDR_W-1:0]), .AWPROT(m_awprot), .AWVALID(m_awvalid), .AWREADY(m_awready),
    .WDATA(m_wdata), .WSTRB(m_wstrb), .WVALID(m_wvalid), .WREADY(m_wready),
    .BRESP(m_bresp), .BVALID(m_bvalid), .BREADY(m_bready),
    .ARADDR(m_araddr[MEM_ADDR_W-1:0]), .ARPROT(m_arprot), .ARVALID(m_arvalid), .ARREADY(m_arready),
    .RDATA(m_rdata), .RRESP(m_rresp), .RVALID(m_rvalid), .RREADY(m_rready)
  );

  // upper address bits beyond the memory are not decoded (single memory target)
  // verilator lint_off UNUSEDSIGNAL
  wire _unused_ok = &{1'b0, m_awaddr[AXI_ADDR_W-1:MEM_ADDR_W],
                            m_araddr[AXI_ADDR_W-1:MEM_ADDR_W]};
  // verilator lint_on UNUSEDSIGNAL

endmodule
`endif
