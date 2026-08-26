// -----------------------------------------------------------------------------
// aou_sc_dbg_top : DV-ONLY observation wrapper around axi_ucie_mem_top for the
// SystemC testbench's VERBOSE=1|2 build.
//
// WHY THIS EXISTS.  The SV and cocotb environments read the DUT's internal flit
// links and bridge state through hierarchical references from the testbench.
// A `--sc` model exposes only its PORTS to sc_main, so the SystemC TB has no
// equivalent reach.  This wrapper closes that gap the same way — with
// read-only hierarchical references — and re-exports what it observes as extra
// output ports, WITHOUT touching rtl/:
//
//   * it instantiates the unmodified axi_ucie_mem_top and passes every real
//     port straight through, so the design under test is bit-for-bit the
//     shipping one;
//   * every `dbg_*` port is driven from a hierarchical READ of a signal the
//     design already drives — nothing is fed back in, so the datapath cannot be
//     influenced;
//   * it is compiled ONLY for the verbose build (dv/systemc/Makefile picks it
//     as the Verilator top when AOU_VERBOSE is set).  The default VERBOSE=0
//     build verilates axi_ucie_mem_top directly, exactly as before, which is
//     what keeps the committed dv/systemc/sc.log byte-identical.
//
// The flit handshake is REGISTERED here (dbg_*_fire pulses for the cycle after
// a transfer, with the transferred flit held alongside it) so the SystemC
// monitor sees a full-cycle-stable value regardless of SystemC/Verilator delta
// ordering.  The state ports are plain pass-throughs of RTL registers.
// -----------------------------------------------------------------------------
`ifndef AOU_SC_DBG_TOP_SV
`define AOU_SC_DBG_TOP_SV

module aou_sc_dbg_top
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int AXI_ID_W   = 4,
    parameter int MEM_ADDR_W = 16
) (
    input  logic                  ACLK,
    input  logic                  ARESETn,
    input  logic [AXI_ID_W-1:0]   AWID,
    input  logic [AXI_ADDR_W-1:0] AWADDR,
    input  logic [7:0]            AWLEN,
    input  logic [2:0]            AWSIZE,
    input  logic [1:0]            AWBURST,
    input  logic [2:0]            AWPROT,
    input  logic                  AWVALID,
    output logic                  AWREADY,
    input  logic [AXI_DATA_W-1:0] WDATA,
    input  logic [AXI_STRB_W-1:0] WSTRB,
    input  logic                  WLAST,
    input  logic                  WVALID,
    output logic                  WREADY,
    output logic [AXI_ID_W-1:0]   BID,
    output logic [1:0]            BRESP,
    output logic                  BVALID,
    input  logic                  BREADY,
    input  logic [AXI_ID_W-1:0]   ARID,
    input  logic [AXI_ADDR_W-1:0] ARADDR,
    input  logic [7:0]            ARLEN,
    input  logic [2:0]            ARSIZE,
    input  logic [1:0]            ARBURST,
    input  logic [2:0]            ARPROT,
    input  logic                  ARVALID,
    output logic                  ARREADY,
    output logic [AXI_ID_W-1:0]   RID,
    output logic [AXI_DATA_W-1:0] RDATA,
    output logic [1:0]            RRESP,
    output logic                  RLAST,
    output logic                  RVALID,
    input  logic                  RREADY,
    // ---- DV-only observation ports (level 1: flits) ----
    output logic                  dbg_a2b_fire,
    output logic [PLP_BITS-1:0]   dbg_a2b_data,
    output logic                  dbg_b2a_fire,
    output logic [PLP_BITS-1:0]   dbg_b2a_data,
    // ---- DV-only observation ports (level 2: internal state) ----
    output logic [2:0]            dbg_i_act,
    output logic [2:0]            dbg_t_act,
    output logic [2:0]            dbg_i_fsm,
    output logic [2:0]            dbg_t_fsm,
    output logic [7:0]            dbg_i_qcount,
    output logic [7:0]            dbg_i_cr_wreq,
    output logic [7:0]            dbg_i_cr_rreq,
    output logic [7:0]            dbg_i_cr_wdata,
    output logic [7:0]            dbg_i_ret_rdata,
    output logic [7:0]            dbg_i_ret_wresp,
    output logic [7:0]            dbg_t_cr_rdata,
    output logic [7:0]            dbg_t_cr_wresp,
    output logic [7:0]            dbg_t_ret_wreq,
    output logic [7:0]            dbg_t_ret_rreq,
    output logic [7:0]            dbg_t_ret_wdata
);

  axi_ucie_mem_top #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_STRB_W(AXI_STRB_W),
    .AXI_ID_W(AXI_ID_W), .MEM_ADDR_W(MEM_ADDR_W)
  ) dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWID(AWID), .AWADDR(AWADDR), .AWLEN(AWLEN), .AWSIZE(AWSIZE),
    .AWBURST(AWBURST), .AWPROT(AWPROT), .AWVALID(AWVALID), .AWREADY(AWREADY),
    .WDATA(WDATA), .WSTRB(WSTRB), .WLAST(WLAST), .WVALID(WVALID), .WREADY(WREADY),
    .BID(BID), .BRESP(BRESP), .BVALID(BVALID), .BREADY(BREADY),
    .ARID(ARID), .ARADDR(ARADDR), .ARLEN(ARLEN), .ARSIZE(ARSIZE),
    .ARBURST(ARBURST), .ARPROT(ARPROT), .ARVALID(ARVALID), .ARREADY(ARREADY),
    .RID(RID), .RDATA(RDATA), .RRESP(RRESP), .RLAST(RLAST),
    .RVALID(RVALID), .RREADY(RREADY)
  );

  // --- level 1: registered flit-handshake observation ------------------------
  wire a2b_xfer = dut.g_rp1.init_tx_valid && dut.g_rp1.init_tx_ready;
  wire b2a_xfer = dut.g_rp1.init_rx_valid && dut.g_rp1.init_rx_ready;

  always_ff @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      dbg_a2b_fire <= 1'b0;
      dbg_b2a_fire <= 1'b0;
    end else begin
      dbg_a2b_fire <= a2b_xfer;
      dbg_b2a_fire <= b2a_xfer;
      if (a2b_xfer) dbg_a2b_data <= dut.g_rp1.init_tx_data;
      if (b2a_xfer) dbg_b2a_data <= dut.g_rp1.init_rx_data;
    end
  end

  // --- level 2: internal state pass-through ---------------------------------
  assign dbg_i_act       = dut.g_rp1.u_init.u_act.state;
  assign dbg_t_act       = dut.g_rp1.u_tgt.u_act.state;
  assign dbg_i_fsm       = dut.g_rp1.u_init.g_inorder.state;
  assign dbg_t_fsm       = dut.g_rp1.u_tgt.state;
  assign dbg_i_qcount    = 8'(dut.g_rp1.u_init.q_count);
  assign dbg_i_cr_wreq   = dut.g_rp1.u_init.cr_wreq;
  assign dbg_i_cr_rreq   = dut.g_rp1.u_init.cr_rreq;
  assign dbg_i_cr_wdata  = dut.g_rp1.u_init.cr_wdata;
  assign dbg_i_ret_rdata = dut.g_rp1.u_init.ret_rdata;
  assign dbg_i_ret_wresp = dut.g_rp1.u_init.ret_wresp;
  assign dbg_t_cr_rdata  = dut.g_rp1.u_tgt.cr_rdata;
  assign dbg_t_cr_wresp  = dut.g_rp1.u_tgt.cr_wresp;
  assign dbg_t_ret_wreq  = dut.g_rp1.u_tgt.ret_wreq;
  assign dbg_t_ret_rreq  = dut.g_rp1.u_tgt.ret_rreq;
  assign dbg_t_ret_wdata = dut.g_rp1.u_tgt.ret_wdata;

endmodule
`endif
