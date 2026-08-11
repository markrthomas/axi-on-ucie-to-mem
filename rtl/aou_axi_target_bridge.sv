// -----------------------------------------------------------------------------
// aou_axi_target_bridge : chiplet-B bridge (AoU -> AXI-Lite manager).
//
// Decodes AoU messages arriving on the A->B link (one message per flit) and
// drives an AXI4-Lite manager into the memory, expanding each AXI burst into a
// sequence of single-beat AXI-Lite accesses (so axi_lite_mem stays single-beat):
//   * WriteReq + (AWLEN+1) WriteData -> AWLEN+1 single-beat writes -> WriteResp
//   * ReadReq -> AWLEN+1 single-beat reads -> AWLEN+1 ReadData (RLAST on last)
// Per-beat addresses follow the AXI burst type (INCR/WRAP/FIXED) carried in the
// request (burst type in FLEX[1:0]); the {AW,AR}ID tag is echoed into {B,R}ID.
//
// Single-outstanding (one burst in flight), matching the initiator bridge.
// -----------------------------------------------------------------------------
`ifndef AOU_AXI_TARGET_BRIDGE_SV
`define AOU_AXI_TARGET_BRIDGE_SV

module aou_axi_target_bridge
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int AXI_ID_W   = 4,
    // §6 flow control — granule credits this (target) bridge holds to send each
    // response message type (granted by chiplet A).  ReadData is sized for a
    // full read burst (128 granules = 16 beats).
    parameter int CR_RDATA = 128,               // ReadData  credits (16 beats)
    parameter int CR_WRESP = WRITERESP_GRAN     // WriteResp credits (1 granule)
) (
    input  logic                    clk,
    input  logic                    rstn,
    // ---- flit RX (from A->B link) ----
    input  logic [PLP_BITS-1:0]     rx_data,
    input  logic                    rx_valid,
    output logic                    rx_ready,
    // ---- flit TX (to B->A link) ----
    output logic [PLP_BITS-1:0]     tx_data,
    output logic                    tx_valid,
    input  logic                    tx_ready,
    // ---- AXI4-Lite manager (drives the memory) ----
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
    S_IDLE, S_WBEAT, S_WRESP, S_RBEAT
  } state_e;
  state_e state;

  // burst context
  logic [AXI_ID_W-1:0]   id_q;
  logic [AXI_ADDR_W-1:0] base_q, addr_q;   // start address, current beat address
  logic [7:0]            len_q, beat_q;    // AxLEN, current beat index
  logic [2:0]            size_q;
  logic [1:0]            burst_q;
  // write-beat buffer + mem-write handshake
  logic [AXI_DATA_W-1:0] wdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  logic                  wpending, aw_done, w_done;
  logic [1:0]            bresp_q;
  // read-beat buffer + mem-read handshake
  logic [AXI_DATA_W-1:0] rdata_q;
  logic [1:0]            rresp_q;
  logic                  rpending, ar_done;

  // §6 credits HELD to transmit responses (granted by chiplet A).
  logic [7:0] cr_rdata, cr_wresp;
  // §6 credits OWED back to A for the request messages this bridge consumes.
  logic [7:0] ret_wreq, ret_rreq, ret_wdata;

  function automatic logic [7:0] sat_add(input logic [7:0]  cur,
                                         input int unsigned add,
                                         input int unsigned lim);
    int unsigned s;
    begin
      s = {24'b0, cur} + add;
      sat_add = (s > lim) ? lim[7:0] : s[7:0];
    end
  endfunction

  // next-beat address (INCR/WRAP/FIXED), computed in the AoU 64b address space.
  function automatic logic [AXI_ADDR_W-1:0] next_addr();
    // verilator lint_off UNUSEDSIGNAL
    logic [AOU_ADDR_W-1:0] n;         // only low AXI_ADDR_W bits used
    // verilator lint_on UNUSEDSIGNAL
    begin
      n = axi_burst_next({{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, addr_q},
                         {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, base_q},
                         burst_q, size_q, len_q);
      next_addr = n[AXI_ADDR_W-1:0];
    end
  endfunction

  wire last_beat = (beat_q == len_q);

  // === §8 activation + §6.4.3 reset credit exchange ========================
  localparam logic [2:0] GR_WREQ  = 3'b010;   // >= WRITEREQ_GRAN  (3)
  localparam logic [2:0] GR_RREQ  = 3'b010;   // >= READREQ_GRAN   (3)
  localparam logic [2:0] GR_WDATA = 3'b111;   // 128 granules (16 WriteData beats)

  logic [PLP_BITS-1:0]   dtx_data, drx_data;
  logic                  dtx_valid, dtx_ready, drx_valid, drx_ready;
  logic                  seed_valid, act_disabled;
  logic [2:0]            seed_rdata;
  logic [1:0]            seed_wresp;
  // verilator lint_off UNUSEDSIGNAL
  logic                  act_enabled, act_error;
  logic [2:0]            seed_wreq, seed_rreq, seed_wdata;
  // verilator lint_on UNUSEDSIGNAL

  aou_activation #(
    .GRANT_WREQ(GR_WREQ), .GRANT_RREQ(GR_RREQ), .GRANT_WDATA(GR_WDATA)
  ) u_act (
    .clk(clk), .rstn(rstn), .enabled(act_enabled),
    .act_disabled(act_disabled), .error(act_error),
    .deact_trig(1'b0), .err_clear(1'b0),
    .tx_data(tx_data),  .tx_valid(tx_valid),  .tx_ready(tx_ready),
    .rx_data(rx_data),  .rx_valid(rx_valid),  .rx_ready(rx_ready),
    .d_tx_data(dtx_data), .d_tx_valid(dtx_valid), .d_tx_ready(dtx_ready),
    .d_rx_data(drx_data), .d_rx_valid(drx_valid), .d_rx_ready(drx_ready),
    .seed_valid(seed_valid), .seed_wreq(seed_wreq), .seed_rreq(seed_rreq),
    .seed_wdata(seed_wdata), .seed_rdata(seed_rdata), .seed_wresp(seed_wresp)
  );

  // MsgCredit this bridge advertises to A (grants WriteReq/ReadReq/WriteData).
  function automatic logic [CREDIT_W-1:0] return_credit();
    return_credit = mk_msgcredit(2'b00,
                                 cred_encode_ge(ret_wreq),
                                 cred_encode_ge(ret_rreq),
                                 cred_encode_ge(ret_wdata),
                                 3'b000, 2'b00);
  endfunction

  // --- build the response flits ---------------------------------------------
  function automatic flit_t build_wresp_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_writeresp(2'b00, '0, {{(AOU_ID_W-AXI_ID_W){1'b0}}, id_q}, bresp_q);
      pl = payload_put('0, 0, WRITERESP_GRAN, m);
      build_wresp_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  function automatic flit_t build_rdata_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_readdata256(2'b00, '0, {{(AOU_ID_W-AXI_ID_W){1'b0}}, id_q},
                          rresp_q, last_beat,
                          {{(AOU_DATA_W-AXI_DATA_W){1'b0}}, rdata_q});
      pl = payload_put('0, 0, READDATA_GRAN, m);
      build_rdata_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  // --- incoming-flit views (one message per flit, always at granule 0) ------
  payload_t                in_pl;
  logic [MSGTYPE_W-1:0]    in_mt;
  msg_t                    in_msg;
  // verilator lint_off UNUSEDSIGNAL
  logic [AOU_ID_W-1:0]    in_id;      // only low AXI_ID_W bits used
  logic [AOU_ADDR_W-1:0]  in_addr;
  logic [AOU_DATA_W-1:0]  in_wdata;
  logic [AOU_STRB_W-1:0]  in_wstrb;
  // verilator lint_on UNUSEDSIGNAL
  assign in_pl    = flit_payload(drx_data);
  assign in_mt    = payload_msgtype(in_pl, 0);
  assign in_msg   = payload_get(in_pl, 0, WRITEDATA_GRAN);  // widest; req uses top bits
  assign in_addr  = (in_mt == MT_WRITEREQ) ? wr_addr(in_msg) : rr_addr(in_msg);
  assign in_id    = (in_mt == MT_WRITEREQ) ? wr_id(in_msg)   : rr_id(in_msg);
  assign in_wdata = wd_data(in_msg);
  assign in_wstrb = wd_strb(in_msg);

  // --- combinational outputs ------------------------------------------------
  // consume the request in S_IDLE; consume a WriteData beat into the buffer in
  // S_WBEAT when the buffer is free.
  assign drx_ready = (state == S_IDLE) || ((state == S_WBEAT) && !wpending);
  assign m_awaddr  = addr_q;
  assign m_awprot  = 3'b000;
  assign m_awvalid = (state == S_WBEAT) && wpending && !aw_done;
  assign m_wdata   = wdata_q;
  assign m_wstrb   = wstrb_q;
  assign m_wvalid  = (state == S_WBEAT) && wpending && !w_done;
  assign m_bready  = (state == S_WBEAT) && wpending;
  assign m_araddr  = addr_q;
  assign m_arprot  = 3'b000;
  assign m_arvalid = (state == S_RBEAT) && !rpending && !ar_done;
  assign m_rready  = (state == S_RBEAT) && !rpending;
  // response send gated by credit (§6.1)
  assign dtx_valid = ((state == S_WRESP) && (cr_wresp >= WRITERESP_GRAN[7:0])) ||
                     ((state == S_RBEAT) && rpending && (cr_rdata >= READDATA_GRAN[7:0]));

  always_comb begin
    if (state == S_WRESP) dtx_data = build_wresp_flit();
    else                  dtx_data = build_rdata_flit();
  end

  // --- FSM ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state    <= S_IDLE;
      id_q     <= '0; base_q <= '0; addr_q <= '0;
      len_q    <= '0; beat_q <= '0; size_q <= '0; burst_q <= '0;
      wdata_q  <= '0; wstrb_q <= '0; wpending <= 1'b0;
      aw_done  <= 1'b0; w_done <= 1'b0; bresp_q <= '0;
      rdata_q  <= '0; rresp_q <= '0; rpending <= 1'b0; ar_done <= 1'b0;
      cr_rdata <= '0; cr_wresp <= '0;
      ret_wreq <= '0; ret_rreq <= '0; ret_wdata <= '0;
    end else begin
      // §8.2 DISABLED: discard granted credits; §6.4.3 seed re-grants them.
      if (act_disabled) begin
        cr_rdata <= '0; cr_wresp <= '0;
      end else if (seed_valid) begin
        cr_rdata <= sat_add(cr_rdata, cred_decode(seed_rdata),         CR_RDATA);
        cr_wresp <= sat_add(cr_wresp, cred_decode({1'b0, seed_wresp}), CR_WRESP);
      end
      unique case (state)
        S_IDLE: if (drx_valid) begin : s_idle_blk
          logic [CREDIT_W-1:0] mc;
          mc = flit_credit(drx_data);
          cr_rdata <= sat_add(cr_rdata, cred_decode(mc_rdata(mc)),          CR_RDATA);
          cr_wresp <= sat_add(cr_wresp, cred_decode({1'b0, mc_wresp(mc)}), CR_WRESP);
          id_q    <= in_id[AXI_ID_W-1:0];
          base_q  <= in_addr[AXI_ADDR_W-1:0];
          addr_q  <= in_addr[AXI_ADDR_W-1:0];
          beat_q  <= '0;
          if (in_mt == MT_WRITEREQ) begin
            len_q   <= wr_len(in_msg);
            size_q  <= wr_size(in_msg);
            burst_q <= wr_burst(in_msg);
            wpending <= 1'b0; aw_done <= 1'b0; w_done <= 1'b0;
            ret_wreq <= ret_wreq + WRITEREQ_GRAN[7:0];
            state   <= S_WBEAT;
          end else begin
            len_q   <= rr_len(in_msg);
            size_q  <= rr_size(in_msg);
            burst_q <= rr_burst(in_msg);
            rpending <= 1'b0; ar_done <= 1'b0;
            ret_rreq <= ret_rreq + READREQ_GRAN[7:0];
            state   <= S_RBEAT;
          end
        end
        S_WBEAT: begin
          // buffer a WriteData beat
          if (drx_valid && drx_ready && !wpending) begin
            wdata_q <= in_wdata[AXI_DATA_W-1:0];
            wstrb_q <= in_wstrb[AXI_STRB_W-1:0];
            wpending <= 1'b1; aw_done <= 1'b0; w_done <= 1'b0;
            ret_wdata <= ret_wdata + WRITEDATA_GRAN[7:0];
          end
          // single-beat memory write
          if (m_awvalid && m_awready) aw_done <= 1'b1;
          if (m_wvalid  && m_wready ) w_done  <= 1'b1;
          if (m_bvalid  && m_bready ) begin
            bresp_q  <= m_bresp;
            wpending <= 1'b0;
            addr_q   <= next_addr();
            beat_q   <= beat_q + 8'd1;
            if (last_beat) state <= S_WRESP;
          end
        end
        S_WRESP: if (dtx_valid && dtx_ready) begin
          cr_wresp  <= cr_wresp - WRITERESP_GRAN[7:0];
          ret_wreq  <= '0; ret_rreq <= '0; ret_wdata <= '0;
          state     <= S_IDLE;
        end
        S_RBEAT: begin
          // single-beat memory read into the buffer
          if (m_arvalid && m_arready) ar_done <= 1'b1;
          if (m_rvalid  && m_rready ) begin
            rdata_q  <= m_rdata;
            rresp_q  <= m_rresp;
            rpending <= 1'b1;
          end
          // send the buffered beat as a ReadData flit
          if (dtx_valid && dtx_ready) begin
            cr_rdata <= cr_rdata - READDATA_GRAN[7:0];
            rpending <= 1'b0; ar_done <= 1'b0;
            addr_q   <= next_addr();
            beat_q   <= beat_q + 8'd1;
            if (last_beat) begin
              ret_wreq <= '0; ret_rreq <= '0; ret_wdata <= '0;
              state    <= S_IDLE;
            end
          end
        end
        // verilator coverage_off
        default: state <= S_IDLE;   // unreachable (all states enumerated)
        // verilator coverage_on
      endcase
    end
  end

endmodule
`endif
