// =============================================================================
// axi_ucie_mem_playground.sv
//
// SINGLE-FILE build of the "AXI-Lite over UCIe (AoU) to an AXI-Lite memory"
// design + a self-checking SystemVerilog testbench, for pasting into
// EDA Playground (https://www.edaplayground.com/).
//
//   EDA Playground setup:
//     * Paste this whole file into the right-hand (testbench) pane, leave the
//       left (design) pane empty — everything is self-contained here.
//     * Testbench + Libraries : SystemVerilog / no UVM.
//     * Tools & Simulators     : any of Icarus Verilog, Verilator, Aldec
//                                Riviera-PRO, Synopsys VCS, Cadence Xcelium,
//                                Siemens Questa.  (Driving on negedge /
//                                sampling on posedge keeps it portable.)
//     * Tick "Open EPWave after run" to see waves (dump.vcd is written below).
//
// Chain exercised end-to-end by the TB:
//   TB AXI-Lite master
//     -> aou_axi_initiator_bridge  (chiplet A: AXI-Lite SUB -> AoU flits)
//     == ucie_stream_link A->B ==>
//     -> aou_axi_target_bridge     (chiplet B: AoU flits -> AXI-Lite MGR)
//     -> axi_lite_mem              (the memory)
//     <= ucie_stream_link B->A <=  (WriteResp / ReadData flits)
//
// This is a flattened copy of rtl/*.sv + a portable TB; the authoritative
// sources live in the repo (rtl/, dv/).  Keep them in sync if you edit here.
// =============================================================================
`default_nettype wire
`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// aou_pkg : AXI-over-UCIe Basic-Profile message + flit definitions.
// -----------------------------------------------------------------------------
package aou_pkg;

  // --- Flit / PLP geometry (spec §4.2) --------------------------------------
  localparam int GRAN_BITS         = 40;                   // 5 bytes per granule
  localparam int NUM_GRAN          = 48;                   // 240B payload / 5B
  localparam int PLP_PAYLOAD_BITS  = GRAN_BITS * NUM_GRAN; // 1920
  localparam int PLP_HDR_BITS      = 80;                   // 10B protocol header
  localparam int PLP_BITS          = PLP_HDR_BITS + PLP_PAYLOAD_BITS; // 2000

  localparam int FDID_W    = 2;
  localparam int CREDIT_W  = 16;
  localparam int HDR_RSVD_W = PLP_HDR_BITS - FDID_W - NUM_GRAN - CREDIT_W; // 14

  typedef logic [PLP_BITS-1:0]         flit_t;
  typedef logic [PLP_PAYLOAD_BITS-1:0] payload_t;
  typedef logic [NUM_GRAN-1:0]         msgstart_t;

  // --- MSGTYPE encoding (spec Table 1) --------------------------------------
  localparam int MSGTYPE_W = 4;
  typedef enum logic [MSGTYPE_W-1:0] {
    MT_MISC          = 4'b0000,
    MT_WRITEREQ      = 4'b0001,
    MT_READREQ       = 4'b0010,
    MT_WRITEDATA     = 4'b0011,
    MT_READDATA      = 4'b0100,
    MT_WRITERESP     = 4'b0101,
    MT_WRITEDATAFULL = 4'b0110
  } msgtype_e;

  // --- AoU-specific + AXI-equivalent field widths (Basic Profile) -----------
  localparam int RP_W      = 2;
  localparam int DLENGTH_W = 2;
  localparam int FLEX_W    = 16;
  localparam int AOU_ID_W  = 10;
  localparam int AOU_SIZE_W  = 3;
  localparam int AOU_PROT_W  = 3;
  localparam int AOU_LEN_W   = 8;
  localparam int AOU_CACHE_W = 4;
  localparam int AOU_QOS_W   = 4;
  localparam int AOU_ADDR_W  = 64;
  localparam int AOU_DATA_W  = 256;
  localparam int AOU_STRB_W  = 32;
  localparam int AOU_RESP_W  = 2;

  localparam logic [DLENGTH_W-1:0] DLEN_256  = 2'b00;
  localparam logic [DLENGTH_W-1:0] DLEN_512  = 2'b01;
  localparam logic [DLENGTH_W-1:0] DLEN_1024 = 2'b10;

  // --- Message bit-lengths and granule counts (spec §5.3-5.5) ---------------
  localparam int WRITEREQ_BITS  = 120; localparam int WRITEREQ_GRAN  = 3;
  localparam int READREQ_BITS   = 120; localparam int READREQ_GRAN   = 3;
  localparam int WRITEDATA_BITS = 320; localparam int WRITEDATA_GRAN = 8;
  localparam int READDATA_BITS  = 320; localparam int READDATA_GRAN  = 8;
  localparam int WRITERESP_BITS = 40;  localparam int WRITERESP_GRAN = 1;

  localparam int MSG_MAX_BITS = 320;
  localparam int MSG_MAX_GRAN = 8;

  typedef logic [MSG_MAX_BITS-1:0] msg_t;

  function automatic int msg_granules(input logic [MSGTYPE_W-1:0] mt);
    case (mt)
      MT_WRITEREQ  : msg_granules = WRITEREQ_GRAN;
      MT_READREQ   : msg_granules = READREQ_GRAN;
      MT_WRITEDATA : msg_granules = WRITEDATA_GRAN;
      MT_READDATA  : msg_granules = READDATA_GRAN;
      MT_WRITERESP : msg_granules = WRITERESP_GRAN;
      default      : msg_granules = 0;
    endcase
  endfunction

  // --- Message builders -----------------------------------------------------
  function automatic msg_t mk_writereq(
      input logic [RP_W-1:0]        rp,
      input logic                   awlock,
      input logic [FLEX_W-1:0]      flex,
      input logic [AOU_ID_W-1:0]    awid,
      input logic [AOU_SIZE_W-1:0]  awsize,
      input logic [AOU_PROT_W-1:0]  awprot,
      input logic [AOU_LEN_W-1:0]   awlen,
      input logic [AOU_CACHE_W-1:0] awcache,
      input logic [AOU_QOS_W-1:0]   awqos,
      input logic [AOU_ADDR_W-1:0]  awaddr);
    logic [WRITEREQ_BITS-1:0] v;
    begin
      v = {MT_WRITEREQ, rp, 1'b0, awlock, flex, awid, awsize, awprot,
           awlen, awcache, awqos, awaddr};
      mk_writereq = {v, {(MSG_MAX_BITS-WRITEREQ_BITS){1'b0}}};
    end
  endfunction

  function automatic msg_t mk_readreq(
      input logic [RP_W-1:0]        rp,
      input logic                   arlock,
      input logic [FLEX_W-1:0]      flex,
      input logic [AOU_ID_W-1:0]    arid,
      input logic [AOU_SIZE_W-1:0]  arsize,
      input logic [AOU_PROT_W-1:0]  arprot,
      input logic [AOU_LEN_W-1:0]   arlen,
      input logic [AOU_CACHE_W-1:0] arcache,
      input logic [AOU_QOS_W-1:0]   arqos,
      input logic [AOU_ADDR_W-1:0]  araddr);
    logic [READREQ_BITS-1:0] v;
    begin
      v = {MT_READREQ, rp, 1'b0, arlock, flex, arid, arsize, arprot,
           arlen, arcache, arqos, araddr};
      mk_readreq = {v, {(MSG_MAX_BITS-READREQ_BITS){1'b0}}};
    end
  endfunction

  function automatic msg_t mk_writedata256(
      input logic [RP_W-1:0]       rp,
      input logic [FLEX_W-1:0]     flex,
      input logic [AOU_DATA_W-1:0] wdata,
      input logic [AOU_STRB_W-1:0] wstrb);
    mk_writedata256 = {MT_WRITEDATA, rp, DLEN_256, flex, wdata, wstrb, 8'b0};
  endfunction

  function automatic msg_t mk_readdata256(
      input logic [RP_W-1:0]       rp,
      input logic [FLEX_W-1:0]     flex,
      input logic [AOU_ID_W-1:0]   rid,
      input logic [AOU_RESP_W-1:0] rresp,
      input logic                  rlast,
      input logic [AOU_DATA_W-1:0] rdata);
    mk_readdata256 = {MT_READDATA, rp, DLEN_256, flex, rid, rresp, rlast,
                      3'b0, rdata, 24'b0};
  endfunction

  function automatic msg_t mk_writeresp(
      input logic [RP_W-1:0]       rp,
      input logic [FLEX_W-1:0]     flex,
      input logic [AOU_ID_W-1:0]   bid,
      input logic [AOU_RESP_W-1:0] bresp);
    logic [WRITERESP_BITS-1:0] v;
    begin
      v = {MT_WRITERESP, rp, 2'b0, flex, bid, bresp, 4'b0};
      mk_writeresp = {v, {(MSG_MAX_BITS-WRITERESP_BITS){1'b0}}};
    end
  endfunction

  // --- Field extractors -----------------------------------------------------
  function automatic logic [MSGTYPE_W-1:0] get_msgtype(input msg_t m);
    get_msgtype = m[MSG_MAX_BITS-1 -: MSGTYPE_W];
  endfunction

  function automatic logic [AOU_ADDR_W-1:0] wr_addr(input msg_t m);
    wr_addr = m[(MSG_MAX_BITS-WRITEREQ_BITS) +: AOU_ADDR_W];
  endfunction
  function automatic logic [AOU_ID_W-1:0] wr_id(input msg_t m);
    wr_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [FLEX_W-1:0] wr_flex(input msg_t m);
    wr_flex = m[MSG_MAX_BITS-1-8 -: FLEX_W];
  endfunction

  function automatic logic [AOU_ADDR_W-1:0] rr_addr(input msg_t m);
    rr_addr = m[(MSG_MAX_BITS-READREQ_BITS) +: AOU_ADDR_W];
  endfunction
  function automatic logic [AOU_ID_W-1:0] rr_id(input msg_t m);
    rr_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [FLEX_W-1:0] rr_flex(input msg_t m);
    rr_flex = m[MSG_MAX_BITS-1-8 -: FLEX_W];
  endfunction

  function automatic logic [AOU_DATA_W-1:0] wd_data(input msg_t m);
    wd_data = m[MSG_MAX_BITS-1-24 -: AOU_DATA_W];
  endfunction
  function automatic logic [AOU_STRB_W-1:0] wd_strb(input msg_t m);
    wd_strb = m[MSG_MAX_BITS-1-24-AOU_DATA_W -: AOU_STRB_W];
  endfunction

  function automatic logic [AOU_ID_W-1:0] rd_id(input msg_t m);
    rd_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [AOU_RESP_W-1:0] rd_resp(input msg_t m);
    rd_resp = m[MSG_MAX_BITS-1-34 -: AOU_RESP_W];
  endfunction
  function automatic logic rd_last(input msg_t m);
    rd_last = m[MSG_MAX_BITS-1-36];
  endfunction
  function automatic logic [AOU_DATA_W-1:0] rd_data(input msg_t m);
    rd_data = m[MSG_MAX_BITS-1-40 -: AOU_DATA_W];
  endfunction

  function automatic logic [AOU_ID_W-1:0] wrsp_id(input msg_t m);
    wrsp_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [AOU_RESP_W-1:0] wrsp_resp(input msg_t m);
    wrsp_resp = m[MSG_MAX_BITS-1-34 -: AOU_RESP_W];
  endfunction

  // --- Flit assembly / disassembly (spec §4.2-4.3) --------------------------
  function automatic flit_t flit_assemble(input logic [FDID_W-1:0] fdid,
                                           input msgstart_t         msgstart,
                                           input payload_t          payload);
    flit_assemble = {fdid, msgstart, {CREDIT_W{1'b0}}, {HDR_RSVD_W{1'b0}},
                     payload};
  endfunction

  function automatic msgstart_t flit_msgstart(input flit_t f);
    flit_msgstart = f[PLP_BITS-1-FDID_W -: NUM_GRAN];
  endfunction

  function automatic payload_t flit_payload(input flit_t f);
    flit_payload = f[PLP_PAYLOAD_BITS-1:0];
  endfunction

  function automatic payload_t payload_put(input payload_t base,
                                           input int       g,
                                           input int       gran,
                                           input msg_t     m);
    payload_t p;
    begin
      p = base;
      for (int b = 0; b < gran*GRAN_BITS; b++)
        p[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS - b] = m[MSG_MAX_BITS-1 - b];
      payload_put = p;
    end
  endfunction

  function automatic msg_t payload_get(input payload_t p,
                                       input int       g,
                                       input int       gran);
    msg_t m;
    begin
      m = '0;
      for (int b = 0; b < gran*GRAN_BITS; b++)
        m[MSG_MAX_BITS-1 - b] = p[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS - b];
      payload_get = m;
    end
  endfunction

  function automatic logic [MSGTYPE_W-1:0] payload_msgtype(input payload_t p,
                                                           input int g);
    payload_msgtype = p[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS -: MSGTYPE_W];
  endfunction

endpackage : aou_pkg

// -----------------------------------------------------------------------------
// axi_lite_mem : AXI4-Lite word-wide SRAM memory (the far-side target).
// -----------------------------------------------------------------------------
module axi_lite_mem #(
    parameter int ADDR_W = 16,
    parameter int DATA_W = 32,
    parameter int STRB_W = DATA_W/8
) (
    input  logic              ACLK,
    input  logic              ARESETn,
    input  logic [ADDR_W-1:0] AWADDR,
    input  logic [2:0]        AWPROT,
    input  logic              AWVALID,
    output logic              AWREADY,
    input  logic [DATA_W-1:0] WDATA,
    input  logic [STRB_W-1:0] WSTRB,
    input  logic              WVALID,
    output logic              WREADY,
    output logic [1:0]        BRESP,
    output logic              BVALID,
    input  logic              BREADY,
    input  logic [ADDR_W-1:0] ARADDR,
    input  logic [2:0]        ARPROT,
    input  logic              ARVALID,
    output logic              ARREADY,
    output logic [DATA_W-1:0] RDATA,
    output logic [1:0]        RRESP,
    output logic              RVALID,
    input  logic              RREADY
);

  localparam int WORDS = 1 << (ADDR_W-2);
  localparam logic [1:0] RESP_OKAY = 2'b00;

  wire _unused_ok = &{1'b0, AWPROT, ARPROT, AWADDR[1:0], ARADDR[1:0]};

  logic [DATA_W-1:0] mem [0:WORDS-1];

  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = '0;
  end

  assign BRESP = RESP_OKAY;
  assign RRESP = RESP_OKAY;

  // --- Write channel --------------------------------------------------------
  logic                aw_taken, w_taken;
  logic [ADDR_W-3:0]   awaddr_q;
  logic [DATA_W-1:0]   wdata_q;
  logic [STRB_W-1:0]   wstrb_q;

  assign AWREADY = !aw_taken;
  assign WREADY  = !w_taken;

  wire do_write = aw_taken && w_taken && !BVALID;

  always @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      aw_taken <= 1'b0;
      w_taken  <= 1'b0;
      awaddr_q <= '0;
      wdata_q  <= '0;
      wstrb_q  <= '0;
      BVALID   <= 1'b0;
    end else begin
      if (AWVALID && AWREADY) begin
        aw_taken <= 1'b1;
        awaddr_q <= AWADDR[ADDR_W-1:2];
      end
      if (WVALID && WREADY) begin
        w_taken <= 1'b1;
        wdata_q <= WDATA;
        wstrb_q <= WSTRB;
      end
      if (do_write) begin
        for (int b = 0; b < STRB_W; b++)
          if (wstrb_q[b])
            mem[awaddr_q][b*8 +: 8] <= wdata_q[b*8 +: 8];
        aw_taken <= 1'b0;
        w_taken  <= 1'b0;
        BVALID   <= 1'b1;
      end else if (BVALID && BREADY) begin
        BVALID <= 1'b0;
      end
    end
  end

  // --- Read channel ---------------------------------------------------------
  logic ar_taken;
  assign ARREADY = !ar_taken && !RVALID;

  always @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      ar_taken <= 1'b0;
      RVALID   <= 1'b0;
      RDATA    <= '0;
    end else begin
      if (ARVALID && ARREADY) begin
        RDATA    <= mem[ARADDR[ADDR_W-1:2]];
        RVALID   <= 1'b1;
        ar_taken <= 1'b0;
      end
      if (RVALID && RREADY) begin
        RVALID <= 1'b0;
      end
    end
  end

endmodule

// -----------------------------------------------------------------------------
// aou_axi_initiator_bridge : chiplet-A bridge (AXI-Lite subordinate -> AoU).
// -----------------------------------------------------------------------------
module aou_axi_initiator_bridge
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8
) (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic [AXI_ADDR_W-1:0]   s_awaddr,
    input  logic [2:0]              s_awprot,
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [AXI_DATA_W-1:0]   s_wdata,
    input  logic [AXI_STRB_W-1:0]   s_wstrb,
    input  logic                    s_wvalid,
    output logic                    s_wready,
    output logic [1:0]              s_bresp,
    output logic                    s_bvalid,
    input  logic                    s_bready,
    input  logic [AXI_ADDR_W-1:0]   s_araddr,
    input  logic [2:0]              s_arprot,
    input  logic                    s_arvalid,
    output logic                    s_arready,
    output logic [AXI_DATA_W-1:0]   s_rdata,
    output logic [1:0]              s_rresp,
    output logic                    s_rvalid,
    input  logic                    s_rready,
    output logic [PLP_BITS-1:0]     tx_data,
    output logic                    tx_valid,
    input  logic                    tx_ready,
    input  logic [PLP_BITS-1:0]     rx_data,
    input  logic                    rx_valid,
    output logic                    rx_ready
);

  typedef enum logic [2:0] {
    S_IDLE, S_WSEND, S_RSEND, S_WAIT, S_B, S_R
  } state_e;
  state_e state;

  logic                  aw_seen, w_seen, is_write;
  logic [AXI_ADDR_W-1:0] awaddr_q, araddr_q;
  logic [2:0]            awprot_q, arprot_q;
  logic [AXI_DATA_W-1:0] wdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  logic [AOU_ID_W-1:0]   id_q, id_ctr;
  logic [1:0]            bresp_q, rresp_q;
  logic [AXI_DATA_W-1:0] rdata_q;

  localparam logic [2:0] AXSIZE_4B = 3'b010;

  function automatic flit_t build_write_flit();
    msg_t     m_wreq, m_wdata;
    payload_t pl;
    begin
      m_wreq  = mk_writereq(2'b00, 1'b0, '0, id_q, AXSIZE_4B, awprot_q,
                            '0, '0, '0,
                            {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, awaddr_q});
      m_wdata = mk_writedata256(2'b00, '0,
                            {{(AOU_DATA_W-AXI_DATA_W){1'b0}}, wdata_q},
                            {{(AOU_STRB_W-AXI_STRB_W){1'b0}}, wstrb_q});
      pl = payload_put('0,            0,             WRITEREQ_GRAN,  m_wreq);
      pl = payload_put(pl, WRITEREQ_GRAN, WRITEDATA_GRAN, m_wdata);
      build_write_flit = flit_assemble('0,
                           (msgstart_t'(1) << 0) | (msgstart_t'(1) << WRITEREQ_GRAN),
                           pl);
    end
  endfunction

  function automatic flit_t build_read_flit();
    msg_t     m_rreq;
    payload_t pl;
    begin
      m_rreq = mk_readreq(2'b00, 1'b0, '0, id_q, AXSIZE_4B, arprot_q,
                          '0, '0, '0,
                          {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, araddr_q});
      pl = payload_put('0, 0, READREQ_GRAN, m_rreq);
      build_read_flit = flit_assemble('0, (msgstart_t'(1) << 0), pl);
    end
  endfunction

  assign s_awready = (state == S_IDLE) && !aw_seen;
  assign s_wready  = (state == S_IDLE) && !w_seen;
  assign s_arready = (state == S_IDLE) && !aw_seen && !w_seen;
  assign s_bvalid  = (state == S_B);
  assign s_bresp   = bresp_q;
  assign s_rvalid  = (state == S_R);
  assign s_rdata   = rdata_q;
  assign s_rresp   = rresp_q;
  assign tx_valid  = (state == S_WSEND) || (state == S_RSEND);
  assign rx_ready  = (state == S_WAIT);

  always_comb begin
    if (state == S_WSEND) tx_data = build_write_flit();
    else                  tx_data = build_read_flit();
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state    <= S_IDLE;
      aw_seen  <= 1'b0;
      w_seen   <= 1'b0;
      is_write <= 1'b0;
      id_ctr   <= '0;
      id_q     <= '0;
      awaddr_q <= '0; awprot_q <= '0;
      araddr_q <= '0; arprot_q <= '0;
      wdata_q  <= '0; wstrb_q  <= '0;
      bresp_q  <= '0; rresp_q  <= '0; rdata_q <= '0;
    end else begin
      unique case (state)
        S_IDLE: begin : s_idle_blk
          logic aw_now, w_now;
          aw_now = aw_seen;
          w_now  = w_seen;
          if (s_awvalid && s_awready) begin
            aw_seen  <= 1'b1; aw_now = 1'b1;
            awaddr_q <= s_awaddr; awprot_q <= s_awprot;
          end
          if (s_wvalid && s_wready) begin
            w_seen  <= 1'b1; w_now = 1'b1;
            wdata_q <= s_wdata; wstrb_q <= s_wstrb;
          end
          if (aw_now && w_now) begin
            is_write <= 1'b1;
            id_q     <= id_ctr;
            id_ctr   <= id_ctr + 1'b1;
            state    <= S_WSEND;
          end else if (s_arvalid && s_arready) begin
            araddr_q <= s_araddr; arprot_q <= s_arprot;
            is_write <= 1'b0;
            id_q     <= id_ctr;
            id_ctr   <= id_ctr + 1'b1;
            state    <= S_RSEND;
          end
        end
        S_WSEND: if (tx_ready) begin
          aw_seen <= 1'b0; w_seen <= 1'b0; state <= S_WAIT;
        end
        S_RSEND: if (tx_ready) state <= S_WAIT;
        S_WAIT: if (rx_valid) begin : s_wait_blk
          payload_t              rpl;
          msg_t                  m;
          logic [AOU_DATA_W-1:0] rd_full;
          rpl = flit_payload(rx_data);
          if (is_write) begin
            m        = payload_get(rpl, 0, WRITERESP_GRAN);
            bresp_q <= wrsp_resp(m);
            state   <= S_B;
          end else begin
            m        = payload_get(rpl, 0, READDATA_GRAN);
            rd_full  = rd_data(m);
            rdata_q <= rd_full[AXI_DATA_W-1:0];
            rresp_q <= rd_resp(m);
            state   <= S_R;
          end
        end
        S_B: if (s_bready) state <= S_IDLE;
        S_R: if (s_rready) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

// -----------------------------------------------------------------------------
// ucie_stream_link : one-directional flit transport across the FDI boundary.
// -----------------------------------------------------------------------------
module ucie_stream_link #(
    parameter int W = 2000
) (
    input  logic         clk,
    input  logic         rstn,
    input  logic [W-1:0] in_data,
    input  logic         in_valid,
    output logic         in_ready,
    output logic [W-1:0] out_data,
    output logic         out_valid,
    input  logic         out_ready
);

  logic         full;
  logic [W-1:0] data_q;

  assign out_valid = full;
  assign out_data  = data_q;
  assign in_ready  = !full || out_ready;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      full   <= 1'b0;
      data_q <= '0;
    end else begin
      if (in_valid && in_ready) begin
        data_q <= in_data;
        full   <= 1'b1;
      end else if (out_valid && out_ready) begin
        full   <= 1'b0;
      end
    end
  end

endmodule

// -----------------------------------------------------------------------------
// aou_axi_target_bridge : chiplet-B bridge (AoU -> AXI-Lite manager).
// -----------------------------------------------------------------------------
module aou_axi_target_bridge
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8
) (
    input  logic                    clk,
    input  logic                    rstn,
    input  logic [PLP_BITS-1:0]     rx_data,
    input  logic                    rx_valid,
    output logic                    rx_ready,
    output logic [PLP_BITS-1:0]     tx_data,
    output logic                    tx_valid,
    input  logic                    tx_ready,
    output logic [AXI_ADDR_W-1:0]   m_awaddr,
    output logic [2:0]              m_awprot,
    output logic                    m_awvalid,
    input  logic                    m_awready,
    output logic [AXI_DATA_W-1:0]   m_wdata,
    output logic [AXI_STRB_W-1:0]   m_wstrb,
    output logic                    m_wvalid,
    input  logic                    m_wready,
    input  logic [1:0]              m_bresp,
    input  logic                    m_bvalid,
    output logic                    m_bready,
    output logic [AXI_ADDR_W-1:0]   m_araddr,
    output logic [2:0]              m_arprot,
    output logic                    m_arvalid,
    input  logic                    m_arready,
    input  logic [AXI_DATA_W-1:0]   m_rdata,
    input  logic [1:0]              m_rresp,
    input  logic                    m_rvalid,
    output logic                    m_rready
);

  typedef enum logic [2:0] {
    S_IDLE, S_WMEM, S_WRESP, S_RMEM, S_RDATA
  } state_e;
  state_e state;

  logic [AXI_ADDR_W-1:0] awaddr_q, araddr_q;
  logic [AXI_DATA_W-1:0] wdata_q, rdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  logic [AOU_ID_W-1:0]   id_q;
  logic [1:0]            bresp_q, rresp_q;
  logic                  aw_done, w_done, ar_done;

  function automatic flit_t build_wresp_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_writeresp(2'b00, '0, id_q, bresp_q);
      pl = payload_put('0, 0, WRITERESP_GRAN, m);
      build_wresp_flit = flit_assemble('0, msgstart_t'(1), pl);
    end
  endfunction

  function automatic flit_t build_rdata_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_readdata256(2'b00, '0, id_q, rresp_q, 1'b1,
                          {{(AOU_DATA_W-AXI_DATA_W){1'b0}}, rdata_q});
      pl = payload_put('0, 0, READDATA_GRAN, m);
      build_rdata_flit = flit_assemble('0, msgstart_t'(1), pl);
    end
  endfunction

  assign rx_ready  = (state == S_IDLE);
  assign m_awaddr  = awaddr_q;
  assign m_awprot  = 3'b000;
  assign m_awvalid = (state == S_WMEM) && !aw_done;
  assign m_wdata   = wdata_q;
  assign m_wstrb   = wstrb_q;
  assign m_wvalid  = (state == S_WMEM) && !w_done;
  assign m_bready  = (state == S_WMEM);
  assign m_araddr  = araddr_q;
  assign m_arprot  = 3'b000;
  assign m_arvalid = (state == S_RMEM) && !ar_done;
  assign m_rready  = (state == S_RMEM);
  assign tx_valid  = (state == S_WRESP) || (state == S_RDATA);

  always_comb begin
    if (state == S_WRESP) tx_data = build_wresp_flit();
    else                  tx_data = build_rdata_flit();
  end

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state    <= S_IDLE;
      awaddr_q <= '0; araddr_q <= '0;
      wdata_q  <= '0; rdata_q  <= '0; wstrb_q <= '0;
      id_q     <= '0; bresp_q  <= '0; rresp_q <= '0;
      aw_done  <= 1'b0; w_done <= 1'b0; ar_done <= 1'b0;
    end else begin
      unique case (state)
        S_IDLE: if (rx_valid) begin : s_idle_blk
          payload_t              pl;
          msgstart_t             ms;
          msg_t                  m0, m1;
          int                    s0, s1, cnt;
          logic [AOU_ADDR_W-1:0] addr_full;
          logic [AOU_DATA_W-1:0] wd_full;
          logic [AOU_STRB_W-1:0] ws_full;
          pl  = flit_payload(rx_data);
          ms  = flit_msgstart(rx_data);
          s0 = 0; s1 = 0; cnt = 0;
          for (int g = 0; g < NUM_GRAN; g++) begin
            if (ms[g]) begin
              if (cnt == 0) s0 = g;
              else if (cnt == 1) s1 = g;
              cnt = cnt + 1;
            end
          end
          if (payload_msgtype(pl, s0) == MT_WRITEREQ) begin
            m0        = payload_get(pl, s0, WRITEREQ_GRAN);
            m1        = payload_get(pl, s1, WRITEDATA_GRAN);
            addr_full = wr_addr(m0);
            wd_full   = wd_data(m1);
            ws_full   = wd_strb(m1);
            awaddr_q <= addr_full[AXI_ADDR_W-1:0];
            id_q     <= wr_id(m0);
            wdata_q  <= wd_full[AXI_DATA_W-1:0];
            wstrb_q  <= ws_full[AXI_STRB_W-1:0];
            aw_done  <= 1'b0; w_done <= 1'b0;
            state    <= S_WMEM;
          end else begin
            m0        = payload_get(pl, s0, READREQ_GRAN);
            addr_full = rr_addr(m0);
            araddr_q <= addr_full[AXI_ADDR_W-1:0];
            id_q     <= rr_id(m0);
            ar_done  <= 1'b0;
            state    <= S_RMEM;
          end
        end
        S_WMEM: begin
          if (m_awvalid && m_awready) aw_done <= 1'b1;
          if (m_wvalid  && m_wready ) w_done  <= 1'b1;
          if (m_bvalid  && m_bready ) begin
            bresp_q <= m_bresp;
            aw_done <= 1'b0; w_done <= 1'b0;
            state   <= S_WRESP;
          end
        end
        S_WRESP: if (tx_ready) state <= S_IDLE;
        S_RMEM: begin
          if (m_arvalid && m_arready) ar_done <= 1'b1;
          if (m_rvalid  && m_rready ) begin
            rdata_q <= m_rdata;
            rresp_q <= m_rresp;
            ar_done <= 1'b0;
            state   <= S_RDATA;
          end
        end
        S_RDATA: if (tx_ready) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule

// -----------------------------------------------------------------------------
// axi_ucie_mem_top : DUT top — AXI-Lite over UCIe (AoU) to an AXI-Lite memory.
// -----------------------------------------------------------------------------
module axi_ucie_mem_top
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int MEM_ADDR_W = 16
) (
    input  logic                  ACLK,
    input  logic                  ARESETn,
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

  logic [PLP_BITS-1:0] a2b_data, b2a_data;
  logic                a2b_valid, a2b_ready, b2a_valid, b2a_ready;

  logic [PLP_BITS-1:0] init_tx_data, init_rx_data;
  logic                init_tx_valid, init_tx_ready, init_rx_valid, init_rx_ready;
  logic [PLP_BITS-1:0] tgt_tx_data, tgt_rx_data;
  logic                tgt_tx_valid, tgt_tx_ready, tgt_rx_valid, tgt_rx_ready;

  logic [AXI_ADDR_W-1:0] m_awaddr, m_araddr;
  logic [2:0]            m_awprot, m_arprot;
  logic                  m_awvalid, m_awready, m_wvalid, m_wready;
  logic [AXI_DATA_W-1:0] m_wdata, m_rdata;
  logic [AXI_STRB_W-1:0] m_wstrb;
  logic [1:0]            m_bresp, m_rresp;
  logic                  m_bvalid, m_bready, m_arvalid, m_arready, m_rvalid, m_rready;

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

  ucie_stream_link #(.W(PLP_BITS)) u_link_a2b (
    .clk(ACLK), .rstn(ARESETn),
    .in_data(init_tx_data), .in_valid(init_tx_valid), .in_ready(init_tx_ready),
    .out_data(a2b_data),    .out_valid(a2b_valid),    .out_ready(a2b_ready)
  );
  assign tgt_rx_data  = a2b_data;
  assign tgt_rx_valid = a2b_valid;
  assign a2b_ready    = tgt_rx_ready;

  ucie_stream_link #(.W(PLP_BITS)) u_link_b2a (
    .clk(ACLK), .rstn(ARESETn),
    .in_data(tgt_tx_data), .in_valid(tgt_tx_valid), .in_ready(tgt_tx_ready),
    .out_data(b2a_data),   .out_valid(b2a_valid),   .out_ready(b2a_ready)
  );
  assign init_rx_data  = b2a_data;
  assign init_rx_valid = b2a_valid;
  assign b2a_ready     = init_rx_ready;

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

  wire _unused_ok = &{1'b0, m_awaddr[AXI_ADDR_W-1:MEM_ADDR_W],
                            m_araddr[AXI_ADDR_W-1:MEM_ADDR_W]};

endmodule

// =============================================================================
// tb_axi_ucie_mem : self-checking AXI4-Lite master exercising the whole chain.
//
// Portable style: the master drives request signals on the negative clock edge
// and samples handshakes on the positive edge, so it needs no clocking blocks
// or `iff` event controls (runs on Icarus as well as the commercial tools).
// =============================================================================
module tb_axi_ucie_mem;

  localparam int AXI_ADDR_W = 32;
  localparam int AXI_DATA_W = 32;
  localparam int AXI_STRB_W = AXI_DATA_W/8;
  localparam time CLK_PERIOD = 10ns;

  // --- clock / reset --------------------------------------------------------
  logic ACLK = 1'b0;
  logic ARESETn = 1'b0;
  always #(CLK_PERIOD/2) ACLK = ~ACLK;

  // --- AXI4-Lite master-side signals ---------------------------------------
  logic [AXI_ADDR_W-1:0] AWADDR;
  logic [2:0]            AWPROT;
  logic                  AWVALID;
  logic                  AWREADY;
  logic [AXI_DATA_W-1:0] WDATA;
  logic [AXI_STRB_W-1:0] WSTRB;
  logic                  WVALID;
  logic                  WREADY;
  logic [1:0]            BRESP;
  logic                  BVALID;
  logic                  BREADY;
  logic [AXI_ADDR_W-1:0] ARADDR;
  logic [2:0]            ARPROT;
  logic                  ARVALID;
  logic                  ARREADY;
  logic [AXI_DATA_W-1:0] RDATA;
  logic [1:0]            RRESP;
  logic                  RVALID;
  logic                  RREADY;

  // --- DUT ------------------------------------------------------------------
  axi_ucie_mem_top #(
    .AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .MEM_ADDR_W(16)
  ) dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWADDR(AWADDR), .AWPROT(AWPROT), .AWVALID(AWVALID), .AWREADY(AWREADY),
    .WDATA(WDATA),   .WSTRB(WSTRB),   .WVALID(WVALID),   .WREADY(WREADY),
    .BRESP(BRESP),   .BVALID(BVALID), .BREADY(BREADY),
    .ARADDR(ARADDR), .ARPROT(ARPROT), .ARVALID(ARVALID), .ARREADY(ARREADY),
    .RDATA(RDATA),   .RRESP(RRESP),   .RVALID(RVALID),   .RREADY(RREADY)
  );

  // --- scoreboard bookkeeping ----------------------------------------------
  int errors = 0;
  int checks = 0;

  // --- AXI4-Lite write: hold AW and W until both accepted, then take B ------
  task automatic axi_write(input logic [AXI_ADDR_W-1:0] addr,
                           input logic [AXI_DATA_W-1:0] data,
                           input logic [AXI_STRB_W-1:0] strb = {AXI_STRB_W{1'b1}});
    bit aw_done, w_done;
    begin
      aw_done = 1'b0;
      w_done  = 1'b0;
      @(negedge ACLK);
      AWADDR  = addr; AWPROT = 3'b000; AWVALID = 1'b1;
      WDATA   = data; WSTRB  = strb;   WVALID  = 1'b1;
      // wait for both request handshakes (they may complete on the same cycle)
      do begin
        @(posedge ACLK);
        if (AWVALID && AWREADY) aw_done = 1'b1;
        if (WVALID  && WREADY ) w_done  = 1'b1;
        @(negedge ACLK);
        if (aw_done) AWVALID = 1'b0;
        if (w_done ) WVALID  = 1'b0;
      end while (!(aw_done && w_done));
      // accept the write response
      BREADY = 1'b1;
      do @(posedge ACLK); while (!(BVALID && BREADY));
      if (BRESP !== 2'b00) begin
        $error("[%0t] write @0x%0h: BRESP=0b%02b (expected OKAY)", $time, addr, BRESP);
        errors++;
      end
      @(negedge ACLK);
      BREADY = 1'b0;
    end
  endtask

  // --- AXI4-Lite read: issue AR, capture R ---------------------------------
  task automatic axi_read(input  logic [AXI_ADDR_W-1:0] addr,
                          output logic [AXI_DATA_W-1:0] data);
    begin
      @(negedge ACLK);
      ARADDR = addr; ARPROT = 3'b000; ARVALID = 1'b1;
      do @(posedge ACLK); while (!(ARVALID && ARREADY));
      @(negedge ACLK);
      ARVALID = 1'b0;
      RREADY  = 1'b1;
      do @(posedge ACLK); while (!(RVALID && RREADY));
      data = RDATA;
      if (RRESP !== 2'b00) begin
        $error("[%0t] read @0x%0h: RRESP=0b%02b (expected OKAY)", $time, addr, RRESP);
        errors++;
      end
      @(negedge ACLK);
      RREADY = 1'b0;
    end
  endtask

  // --- check a written value reads back through the whole chain --------------
  task automatic check(input logic [AXI_ADDR_W-1:0] addr,
                       input logic [AXI_DATA_W-1:0] wdata);
    logic [AXI_DATA_W-1:0] rdata;
    begin
      axi_write(addr, wdata);
      axi_read (addr, rdata);
      checks++;
      if (rdata === wdata)
        $display("[%0t] PASS  @0x%08h  wrote 0x%08h  read 0x%08h",
                 $time, addr, wdata, rdata);
      else begin
        $error("[%0t] FAIL  @0x%08h  wrote 0x%08h  read 0x%08h",
               $time, addr, wdata, rdata);
        errors++;
      end
    end
  endtask

  // --- stimulus -------------------------------------------------------------
  logic [AXI_DATA_W-1:0] rd;
  initial begin
    // waves for EPWave
    $dumpfile("dump.vcd");
    $dumpvars(0, tb_axi_ucie_mem);

    // idle all master-driven signals
    AWADDR = '0; AWPROT = '0; AWVALID = 1'b0;
    WDATA  = '0; WSTRB  = '0; WVALID  = 1'b0;
    BREADY = 1'b0;
    ARADDR = '0; ARPROT = '0; ARVALID = 1'b0;
    RREADY = 1'b0;

    // reset
    ARESETn = 1'b0;
    repeat (4) @(negedge ACLK);
    ARESETn = 1'b1;
    repeat (2) @(negedge ACLK);

    $display("\n=== AXI-over-UCIe to memory : directed write/read-back ===");

    // directed word writes + read-backs across the whole AoU chain
    check(32'h0000_0000, 32'hDEAD_BEEF);
    check(32'h0000_0004, 32'hCAFE_F00D);
    check(32'h0000_0010, 32'h0123_4567);
    check(32'h0000_0100, 32'h89AB_CDEF);
    check(32'h0000_1FFC, 32'hA5A5_5A5A);

    // read-before-write of an untouched location returns 0 (zeroed memory)
    axi_read(32'h0000_0200, rd);
    checks++;
    if (rd === 32'h0000_0000)
      $display("[%0t] PASS  @0x00000200  untouched reads 0x%08h", $time, rd);
    else begin
      $error("[%0t] FAIL  @0x00000200  untouched read 0x%08h (expected 0)", $time, rd);
      errors++;
    end

    // byte-strobed partial write: only lanes 1..2 update the stored word
    axi_write(32'h0000_0020, 32'hFFFF_FFFF);        // seed all-ones
    axi_write(32'h0000_0020, 32'h1122_3344, 4'b0110); // update bytes [2:1]
    axi_read (32'h0000_0020, rd);
    checks++;
    if (rd === 32'hFF22_33FF)
      $display("[%0t] PASS  @0x00000020  byte-strobe merge -> 0x%08h", $time, rd);
    else begin
      $error("[%0t] FAIL  @0x00000020  byte-strobe merge 0x%08h (expected 0xFF2233FF)",
             $time, rd);
      errors++;
    end

    repeat (4) @(negedge ACLK);

    $display("\n=== DONE : %0d checks, %0d error(s) ===", checks, errors);
    if (errors == 0) $display(">>> TEST PASSED");
    else             $display(">>> TEST FAILED");
    $finish;
  end

  // --- watchdog -------------------------------------------------------------
  initial begin
    #100us;
    $error("TIMEOUT: simulation did not complete");
    $finish;
  end

endmodule
