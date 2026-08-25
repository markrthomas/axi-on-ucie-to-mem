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
//
// OOO_EN (docs/PLAN.md F2) is the opt-in out-of-order-by-ID mode and defaults to
// 0.  At 0 the chain is exactly the in-order datapath described above.  At 1 the
// target bridge gains aou_ooo_resp_src (an OOO response source that may let a
// later DIFFERENT-ID response overtake an earlier one) and the initiator bridge
// gains two aou_reorder buffers that restore AXI ordering on R/B.  See
// dv/ooo/tb_axi_ucie_ooo.sv for the end-to-end proof.
//
// NUM_RP (docs/PLAN.md F1) is the opt-in multiple-resource-plane mode and
// defaults to 1.  Multi-plane wiring choice (the plan offers two): the AXI front
// end is REPLICATED per plane, and the replicas are flattened into the SAME
// boundary ports — plane p owns bit slice [p*W +: W] of each AXI port.  At
// NUM_RP = 1 every port therefore has exactly its historical width and the
// generate below elaborates the single-plane chain verbatim, so the shipping
// default is structurally unchanged (no new ports, no new logic, byte-identical
// flits).  That is smaller and sounder than adding a plane-select side-band:
// per-plane AXI channels give each plane its own request/response ports, so a
// response delivered to the wrong plane is directly observable at the boundary.
//
// At NUM_RP > 1 each plane gets its own initiator bridge, target bridge and
// memory image (a resource plane is an independent set of resources, §3) — so
// its §6 credit counters, its §8 activation FSM and its outstanding tracking are
// physically its own — and the planes share ONE pair of UCIe links through
// aou_rp_arb (round-robin egress) / aou_rp_route (FDId ingress + per-plane
// receive queue).  See rtl/aou_rp_mux.sv.
// -----------------------------------------------------------------------------
`ifndef AXI_UCIE_MEM_TOP_SV
`define AXI_UCIE_MEM_TOP_SV

module axi_ucie_mem_top
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int AXI_ID_W   = 4,
    parameter int MEM_ADDR_W = 16,         // memory byte-address width (64 KiB)
    // Opt-in out-of-order-by-ID datapath (0 = today's in-order chain).
    parameter bit OOO_EN     = 1'b0,
    // Opt-in resource planes (1 = today's RP0-only chain).  1..MAX_RP.
    parameter int NUM_RP     = 1,
    // Per-plane receive queue depth, in flits, at each end of the shared link.
    // Must cover the largest §6 credit grant (128 granules / 8 = 16 messages).
    parameter int RP_RX_D    = 16
) (
    input  logic                         ACLK,
    input  logic                         ARESETn,
    // AXI4 subordinate (TB master side) — INCR/WRAP/FIXED bursts, AxLEN beats.
    // Plane p occupies bit slice [p*W +: W]; at NUM_RP=1 these are exactly the
    // historical scalar/vector widths.
    input  logic [NUM_RP*AXI_ID_W-1:0]   AWID,
    input  logic [NUM_RP*AXI_ADDR_W-1:0] AWADDR,
    input  logic [NUM_RP*8-1:0]          AWLEN,
    input  logic [NUM_RP*3-1:0]          AWSIZE,
    input  logic [NUM_RP*2-1:0]          AWBURST,
    input  logic [NUM_RP*3-1:0]          AWPROT,
    input  logic [NUM_RP-1:0]            AWVALID,
    output logic [NUM_RP-1:0]            AWREADY,
    input  logic [NUM_RP*AXI_DATA_W-1:0] WDATA,
    input  logic [NUM_RP*AXI_STRB_W-1:0] WSTRB,
    input  logic [NUM_RP-1:0]            WLAST,
    input  logic [NUM_RP-1:0]            WVALID,
    output logic [NUM_RP-1:0]            WREADY,
    output logic [NUM_RP*AXI_ID_W-1:0]   BID,
    output logic [NUM_RP*2-1:0]          BRESP,
    output logic [NUM_RP-1:0]            BVALID,
    input  logic [NUM_RP-1:0]            BREADY,
    input  logic [NUM_RP*AXI_ID_W-1:0]   ARID,
    input  logic [NUM_RP*AXI_ADDR_W-1:0] ARADDR,
    input  logic [NUM_RP*8-1:0]          ARLEN,
    input  logic [NUM_RP*3-1:0]          ARSIZE,
    input  logic [NUM_RP*2-1:0]          ARBURST,
    input  logic [NUM_RP*3-1:0]          ARPROT,
    input  logic [NUM_RP-1:0]            ARVALID,
    output logic [NUM_RP-1:0]            ARREADY,
    output logic [NUM_RP*AXI_ID_W-1:0]   RID,
    output logic [NUM_RP*AXI_DATA_W-1:0] RDATA,
    output logic [NUM_RP*2-1:0]          RRESP,
    output logic [NUM_RP-1:0]            RLAST,
    output logic [NUM_RP-1:0]            RVALID,
    input  logic [NUM_RP-1:0]            RREADY
);

  generate
  // =========================================================================
  // NUM_RP == 1 : the single-plane chain (SHIPPING DEFAULT), verbatim.
  // =========================================================================
  if (NUM_RP == 1) begin : g_rp1

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
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W),
    .AXI_ID_W(AXI_ID_W), .OOO_EN(OOO_EN)
  ) u_init (
    .clk(ACLK), .rstn(ARESETn),
    .s_awid(AWID), .s_awaddr(AWADDR), .s_awlen(AWLEN), .s_awsize(AWSIZE),
    .s_awburst(AWBURST), .s_awprot(AWPROT), .s_awvalid(AWVALID), .s_awready(AWREADY),
    .s_wdata(WDATA), .s_wstrb(WSTRB), .s_wlast(WLAST), .s_wvalid(WVALID), .s_wready(WREADY),
    .s_bid(BID), .s_bresp(BRESP), .s_bvalid(BVALID), .s_bready(BREADY),
    .s_arid(ARID), .s_araddr(ARADDR), .s_arlen(ARLEN), .s_arsize(ARSIZE),
    .s_arburst(ARBURST), .s_arprot(ARPROT), .s_arvalid(ARVALID), .s_arready(ARREADY),
    .s_rid(RID), .s_rdata(RDATA), .s_rresp(RRESP), .s_rlast(RLAST),
    .s_rvalid(RVALID), .s_rready(RREADY),
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
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W),
    .AXI_ID_W(AXI_ID_W), .OOO_EN(OOO_EN)
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

  end else begin : g_mrp
  // =========================================================================
  // NUM_RP > 1 : one AoU chain per resource plane over one shared link pair.
  // =========================================================================

    // shared links
    logic [PLP_BITS-1:0] a2b_data, b2a_data;
    logic                a2b_valid, a2b_ready, b2a_valid, b2a_ready;

    // per-plane flit streams (plane p in bits [p*PLP_BITS +: PLP_BITS])
    logic [NUM_RP*PLP_BITS-1:0] itx_data, irx_data, ttx_data, trx_data;
    logic [NUM_RP-1:0]          itx_valid, itx_ready, irx_valid, irx_ready;
    logic [NUM_RP-1:0]          ttx_valid, ttx_ready, trx_valid, trx_ready;
    // per-plane link grants, exported for DV fairness monitoring
    // verilator lint_off UNUSEDSIGNAL
    logic [NUM_RP-1:0]          a_grant, b_grant;
    // verilator lint_on UNUSEDSIGNAL

    genvar p;
    for (p = 0; p < NUM_RP; p++) begin : g_rp

      // --- chiplet-B AXI-Lite manager <-> this plane's memory image --------
      logic [AXI_ADDR_W-1:0] m_awaddr, m_araddr;
      logic [2:0]            m_awprot, m_arprot;
      logic                  m_awvalid, m_awready, m_wvalid, m_wready;
      logic [AXI_DATA_W-1:0] m_wdata, m_rdata;
      logic [AXI_STRB_W-1:0] m_wstrb;
      logic [1:0]            m_bresp, m_rresp;
      logic                  m_bvalid, m_bready, m_arvalid, m_arready,
                             m_rvalid, m_rready;

      aou_axi_initiator_bridge #(
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W),
        .AXI_ID_W(AXI_ID_W), .RP_ID(RP_W'(p)), .OOO_EN(OOO_EN)
      ) u_init (
        .clk(ACLK), .rstn(ARESETn),
        .s_awid   (AWID   [p*AXI_ID_W   +: AXI_ID_W]),
        .s_awaddr (AWADDR [p*AXI_ADDR_W +: AXI_ADDR_W]),
        .s_awlen  (AWLEN  [p*8 +: 8]),
        .s_awsize (AWSIZE [p*3 +: 3]),
        .s_awburst(AWBURST[p*2 +: 2]),
        .s_awprot (AWPROT [p*3 +: 3]),
        .s_awvalid(AWVALID[p]), .s_awready(AWREADY[p]),
        .s_wdata  (WDATA  [p*AXI_DATA_W +: AXI_DATA_W]),
        .s_wstrb  (WSTRB  [p*AXI_STRB_W +: AXI_STRB_W]),
        .s_wlast  (WLAST[p]), .s_wvalid(WVALID[p]), .s_wready(WREADY[p]),
        .s_bid    (BID    [p*AXI_ID_W +: AXI_ID_W]),
        .s_bresp  (BRESP  [p*2 +: 2]),
        .s_bvalid (BVALID[p]), .s_bready(BREADY[p]),
        .s_arid   (ARID   [p*AXI_ID_W   +: AXI_ID_W]),
        .s_araddr (ARADDR [p*AXI_ADDR_W +: AXI_ADDR_W]),
        .s_arlen  (ARLEN  [p*8 +: 8]),
        .s_arsize (ARSIZE [p*3 +: 3]),
        .s_arburst(ARBURST[p*2 +: 2]),
        .s_arprot (ARPROT [p*3 +: 3]),
        .s_arvalid(ARVALID[p]), .s_arready(ARREADY[p]),
        .s_rid    (RID    [p*AXI_ID_W   +: AXI_ID_W]),
        .s_rdata  (RDATA  [p*AXI_DATA_W +: AXI_DATA_W]),
        .s_rresp  (RRESP  [p*2 +: 2]),
        .s_rlast  (RLAST[p]), .s_rvalid(RVALID[p]), .s_rready(RREADY[p]),
        .tx_data (itx_data[p*PLP_BITS +: PLP_BITS]),
        .tx_valid(itx_valid[p]), .tx_ready(itx_ready[p]),
        .rx_data (irx_data[p*PLP_BITS +: PLP_BITS]),
        .rx_valid(irx_valid[p]), .rx_ready(irx_ready[p])
      );

      aou_axi_target_bridge #(
        .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W),
        .AXI_ID_W(AXI_ID_W), .RP_ID(RP_W'(p)), .OOO_EN(OOO_EN)
      ) u_tgt (
        .clk(ACLK), .rstn(ARESETn),
        .rx_data (trx_data[p*PLP_BITS +: PLP_BITS]),
        .rx_valid(trx_valid[p]), .rx_ready(trx_ready[p]),
        .tx_data (ttx_data[p*PLP_BITS +: PLP_BITS]),
        .tx_valid(ttx_valid[p]), .tx_ready(ttx_ready[p]),
        .m_awaddr(m_awaddr), .m_awprot(m_awprot), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata),   .m_wstrb(m_wstrb),   .m_wvalid(m_wvalid),   .m_wready(m_wready),
        .m_bresp(m_bresp),   .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_araddr(m_araddr), .m_arprot(m_arprot), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata),   .m_rresp(m_rresp),   .m_rvalid(m_rvalid),   .m_rready(m_rready)
      );

      // Each resource plane owns an independent memory image (§3: a plane is an
      // independent set of resources).  It also makes cross-plane leakage
      // directly observable: two planes may write the SAME address with
      // DIFFERENT data and each must read back its own.
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

      // verilator lint_off UNUSEDSIGNAL
      wire _unused_ok = &{1'b0, m_awaddr[AXI_ADDR_W-1:MEM_ADDR_W],
                                m_araddr[AXI_ADDR_W-1:MEM_ADDR_W]};
      // verilator lint_on UNUSEDSIGNAL
    end

    // === A->B: plane arbiter -> shared link -> per-plane FDId route ==========
    logic [PLP_BITS-1:0] a_arb_data;  logic a_arb_valid, a2b_link_ready;

    aou_rp_arb #(.W(PLP_BITS), .NUM_RP(NUM_RP)) u_arb_a (
      .clk(ACLK), .rstn(ARESETn),
      .in_data(itx_data), .in_valid(itx_valid), .in_ready(itx_ready),
      .out_data(a_arb_data), .out_valid(a_arb_valid), .out_ready(a2b_link_ready),
      .grant(a_grant)
    );

    ucie_stream_link #(.W(PLP_BITS)) u_link_a2b (
      .clk(ACLK), .rstn(ARESETn),
      .in_data(a_arb_data), .in_valid(a_arb_valid), .in_ready(a2b_link_ready),
      .out_data(a2b_data),  .out_valid(a2b_valid),  .out_ready(a2b_ready)
    );

    aou_rp_route #(.NUM_RP(NUM_RP), .RX_D(RP_RX_D)) u_route_b (
      .clk(ACLK), .rstn(ARESETn),
      .in_data(a2b_data), .in_valid(a2b_valid), .in_ready(a2b_ready),
      .out_data(trx_data), .out_valid(trx_valid), .out_ready(trx_ready)
    );

    // === B->A: same structure for the response direction =====================
    logic [PLP_BITS-1:0] b_arb_data;  logic b_arb_valid, b2a_link_ready;

    aou_rp_arb #(.W(PLP_BITS), .NUM_RP(NUM_RP)) u_arb_b (
      .clk(ACLK), .rstn(ARESETn),
      .in_data(ttx_data), .in_valid(ttx_valid), .in_ready(ttx_ready),
      .out_data(b_arb_data), .out_valid(b_arb_valid), .out_ready(b2a_link_ready),
      .grant(b_grant)
    );

    ucie_stream_link #(.W(PLP_BITS)) u_link_b2a (
      .clk(ACLK), .rstn(ARESETn),
      .in_data(b_arb_data), .in_valid(b_arb_valid), .in_ready(b2a_link_ready),
      .out_data(b2a_data),  .out_valid(b2a_valid),  .out_ready(b2a_ready)
    );

    aou_rp_route #(.NUM_RP(NUM_RP), .RX_D(RP_RX_D)) u_route_a (
      .clk(ACLK), .rstn(ARESETn),
      .in_data(b2a_data), .in_valid(b2a_valid), .in_ready(b2a_ready),
      .out_data(irx_data), .out_valid(irx_valid), .out_ready(irx_ready)
    );

  end
  endgenerate

endmodule
`endif
