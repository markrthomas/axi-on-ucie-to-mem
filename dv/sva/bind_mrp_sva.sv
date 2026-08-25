// -----------------------------------------------------------------------------
// bind_mrp_sva : assertion bindings for the MULTI-PLANE build (NUM_RP > 1).
//
// The single-plane bindings live in bind_sva.sv and attach axi_lite_sva to the
// DUT's (scalar) boundary ports.  At NUM_RP > 1 those boundary ports are
// per-plane vectors, so the AXI-Lite checker is bound one level down instead —
// onto each aou_axi_initiator_bridge instance, i.e. onto EVERY plane's AXI front
// door, which is strictly more coverage than the single top-level bind.
//
// The flit and credit checkers are bound exactly as in the single-plane flow,
// except that aou_flit_sva is given this build's NUM_RP so its FDId / MsgCredit
// RP bounds tighten to the active plane count instead of being RP0-only.  The
// credit checker binds per BRIDGE INSTANCE, so each plane's §6 counters get
// their own bound — that is the per-plane credit-bank check.
//
// Keep in sync with dv/sva/bind_sva.sv; only one of the two is ever compiled.
// -----------------------------------------------------------------------------
`ifndef BIND_MRP_SVA_SV
`define BIND_MRP_SVA_SV

// Active plane count of the build under check (the multi-plane DV env's NUM_RP).
`ifndef MRP_NUM_RP
  `define MRP_NUM_RP 2
`endif

// Per-plane AXI4-Lite front door (one bind per initiator bridge instance).
bind aou_axi_initiator_bridge axi_lite_sva #(
  .AW(AXI_ADDR_W), .DW(AXI_DATA_W), .SW(AXI_STRB_W)
) u_axi_sva (
  .clk(clk), .rstn(rstn),
  .awaddr(s_awaddr), .awvalid(s_awvalid), .awready(s_awready),
  .wdata(s_wdata),   .wstrb(s_wstrb), .wvalid(s_wvalid), .wready(s_wready),
  .bvalid(s_bvalid), .bready(s_bready),
  .araddr(s_araddr), .arvalid(s_arvalid), .arready(s_arready),
  .rdata(s_rdata),   .rvalid(s_rvalid), .rready(s_rready)
);

// §4.3 flit well-formedness on the shared links, bounded to the ACTIVE planes.
bind ucie_stream_link aou_flit_sva #(.NUM_RP(`MRP_NUM_RP)) u_flit_sva (
  .clk(clk), .rstn(rstn),
  .flit(in_data), .valid(in_valid), .ready(in_ready)
);

// Per-plane routing / no-drop (docs/PLAN.md F1).
bind aou_rp_route aou_rp_sva #(.NUM_RP(NUM_RP)) u_rp_sva (
  .clk(clk), .rstn(rstn),
  .in_data(in_data), .in_valid(in_valid),
  .out_data(out_data), .out_valid(out_valid)
);

// §6 held-credit bounds — one instance per plane's bridge.
bind aou_axi_initiator_bridge aou_credit_sva #(.CEIL0(3), .CEIL1(3), .CEIL2(128)) u_cr_sva (
  .clk(clk), .rstn(rstn), .c0(cr_wreq), .c1(cr_rreq), .c2(cr_wdata)
);

bind aou_axi_target_bridge aou_credit_sva #(.CEIL0(128), .CEIL1(1), .CEIL2(0)) u_cr_sva (
  .clk(clk), .rstn(rstn), .c0(cr_rdata), .c1(cr_wresp), .c2(8'd0)
);

`endif
