// -----------------------------------------------------------------------------
// aou_axi_target_bridge : chiplet-B bridge (AoU -> AXI-Lite manager).
//
// Unpacks a flit arriving on the A->B link by walking its MsgStart[47:0] bitmap,
// decodes the AoU messages, and drives an AXI4-Lite manager into the memory:
//   * {WriteReq, WriteData256} -> AXI write  -> WriteResp   flit back on B->A
//   * {ReadReq}                -> AXI read    -> ReadData256 flit back on B->A
// The AoU {AW,AR}ID tag is echoed into the {B,R}ID of the response.
//
// Single-outstanding, matching the initiator bridge.
// -----------------------------------------------------------------------------
`ifndef AOU_AXI_TARGET_BRIDGE_SV
`define AOU_AXI_TARGET_BRIDGE_SV

module aou_axi_target_bridge
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    // §6 flow control — granule credits this (target) bridge holds to send each
    // response message type (granted by chiplet A).  See the initiator bridge
    // header for the CrdtGrant/ACTIVATE deferral note.
    parameter int CR_RDATA = READDATA_GRAN,    // ReadData  credits (8 granules)
    parameter int CR_WRESP = WRITERESP_GRAN    // WriteResp credits (1 granule)
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
    S_IDLE, S_WMEM, S_WRESP, S_RMEM, S_RDATA
  } state_e;
  state_e state;

  logic [AXI_ADDR_W-1:0] awaddr_q, araddr_q;
  logic [AXI_DATA_W-1:0] wdata_q, rdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  logic [AOU_ID_W-1:0]   id_q;
  logic [1:0]            bresp_q, rresp_q;
  logic                  aw_done, w_done, ar_done;

  // §6 credits HELD to transmit responses (granted by chiplet A, the receiver
  // of ReadData / WriteResp).  Consumed at the response send, replenished from
  // the MsgCredit field of the A->B request flit.
  logic [7:0] cr_rdata, cr_wresp;
  // §6 credits OWED back to A for the request messages this bridge consumes
  // (WriteReq / ReadReq / WriteData): advertised in the response flit header.
  logic [7:0] ret_wreq, ret_rreq, ret_wdata;

  // saturating add: cur + add, clamped at lim (§6.4 counter-saturation rule).
  function automatic logic [7:0] sat_add(input logic [7:0]  cur,
                                         input int unsigned add,
                                         input int unsigned lim);
    int unsigned s;
    begin
      s = {24'b0, cur} + add;
      sat_add = (s > lim) ? lim[7:0] : s[7:0];
    end
  endfunction

  // === §8 activation + §6.4.3 reset credit exchange ========================
  // This side is the target: it grants WriteReq/ReadReq/WriteData credits to
  // chiplet A (the message types A transmits), advertised in its CrdtGrant; and
  // it seeds its own ReadData/WriteResp credits from A's CrdtGrant.
  localparam logic [2:0] GR_WREQ  = 3'b010;   // >= WRITEREQ_GRAN  (3)
  localparam logic [2:0] GR_RREQ  = 3'b010;   // >= READREQ_GRAN   (3)
  localparam logic [2:0] GR_WDATA = 3'b011;   // >= WRITEDATA_GRAN (8)

  logic [PLP_BITS-1:0]   dtx_data, drx_data;
  logic                  dtx_valid, dtx_ready, drx_valid, drx_ready;
  logic                  seed_valid, act_disabled;
  logic [2:0]            seed_rdata;
  logic [1:0]            seed_wresp;
  // The target reacts to gated rx (held off until ENABLED by the activation
  // wrapper) so it needs no `enabled` gate of its own; it grants (and does not
  // consume) the WriteReq/ReadReq/WriteData seed fields.  No SW deactivate flag
  // is modelled in the full chain, so deact_trig/err_clear are tied low (the §8
  // teardown/ERROR paths are exercised by dv/act); `error` is observable only.
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

  // MsgCredit this bridge advertises to A: it grants WriteReq/ReadReq/WriteData
  // credits (the message types A transmits) for the request granules it freed.
  function automatic logic [CREDIT_W-1:0] return_credit();
    return_credit = mk_msgcredit(2'b00,
                                 cred_encode_ge(ret_wreq),
                                 cred_encode_ge(ret_rreq),
                                 cred_encode_ge(ret_wdata),
                                 3'b000, 2'b00);
  endfunction

  // --- build the response flits (combinational) -----------------------------
  function automatic flit_t build_wresp_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_writeresp(2'b00, '0, id_q, bresp_q);
      pl = payload_put('0, 0, WRITERESP_GRAN, m);
      build_wresp_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  function automatic flit_t build_rdata_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_readdata256(2'b00, '0, id_q, rresp_q, 1'b1,
                          {{(AOU_DATA_W-AXI_DATA_W){1'b0}}, rdata_q});
      pl = payload_put('0, 0, READDATA_GRAN, m);
      build_rdata_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  // --- combinational outputs ------------------------------------------------
  assign drx_ready = (state == S_IDLE);
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
  // A response is only presented once its credits are held (§6.1).  Single-
  // outstanding traffic replenishes these from the triggering request, so this
  // never stalls here; it is the safety gate for a multi-outstanding follow-on.
  assign dtx_valid = ((state == S_WRESP) && (cr_wresp >= WRITERESP_GRAN[7:0])) ||
                     ((state == S_RDATA) && (cr_rdata >= READDATA_GRAN[7:0]));

  // Procedural build (see the initiator bridge note on Icarus 11 wide-ufunc).
  always_comb begin
    if (state == S_WRESP) dtx_data = build_wresp_flit();
    else                  dtx_data = build_rdata_flit();
  end

  // --- FSM ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state    <= S_IDLE;
      awaddr_q <= '0; araddr_q <= '0;
      wdata_q  <= '0; rdata_q  <= '0; wstrb_q <= '0;
      id_q     <= '0; bresp_q  <= '0; rresp_q <= '0;
      aw_done  <= 1'b0; w_done <= 1'b0; ar_done <= 1'b0;
      // §8.4 DISABLED: the transmitter starts with NO credits; A's CrdtGrant
      // seeds them during activation (see the seed block below).
      cr_rdata <= '0; cr_wresp <= '0;
      ret_wreq <= '0; ret_rreq <= '0; ret_wdata <= '0;
    end else begin
      // §8.2 DISABLED: discard all previously granted credits on each return to
      // DISABLED; §6.4.3 reset credit exchange then re-seeds from A's CrdtGrant.
      // Both pulse only while not ENABLED, when the data FSM is idle — no race
      // with the case below.
      if (act_disabled) begin
        cr_rdata <= '0; cr_wresp <= '0;
      end else if (seed_valid) begin
        cr_rdata <= sat_add(cr_rdata, cred_decode(seed_rdata),         CR_RDATA);
        cr_wresp <= sat_add(cr_wresp, cred_decode({1'b0, seed_wresp}), CR_WRESP);
      end
      unique case (state)
        S_IDLE: if (drx_valid) begin : s_idle_blk
          payload_t              pl;
          msgstart_t             ms;
          logic [CREDIT_W-1:0]   mc;
          msg_t                  m0, m1;
          int                    s0, s1, cnt;
          // AoU addr/data/strb are 64/256/32b; only the low AXI-Lite widths are
          // used (this design's 32-bit beat) — upper bits intentionally dropped.
          // verilator lint_off UNUSEDSIGNAL
          logic [AOU_ADDR_W-1:0] addr_full;
          logic [AOU_DATA_W-1:0] wd_full;
          logic [AOU_STRB_W-1:0] ws_full;
          // verilator lint_on UNUSEDSIGNAL
          pl  = flit_payload(drx_data);
          ms  = flit_msgstart(drx_data);
          mc  = flit_credit(drx_data);
          // replenish response send-credits from A's grant (saturate at ceiling)
          cr_rdata <= sat_add(cr_rdata, cred_decode(mc_rdata(mc)), CR_RDATA);
          cr_wresp <= sat_add(cr_wresp, cred_decode({1'b0, mc_wresp(mc)}), CR_WRESP);
          // walk MsgStart: locate the (up to two) message-start granules
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
            // owe A the WriteReq + WriteData granules just consumed
            ret_wreq  <= ret_wreq  + WRITEREQ_GRAN[7:0];
            ret_wdata <= ret_wdata + WRITEDATA_GRAN[7:0];
            state    <= S_WMEM;
          end else begin // MT_READREQ
            m0        = payload_get(pl, s0, READREQ_GRAN);
            addr_full = rr_addr(m0);
            araddr_q <= addr_full[AXI_ADDR_W-1:0];
            id_q     <= rr_id(m0);
            ar_done  <= 1'b0;
            // owe A the ReadReq granules just consumed
            ret_rreq  <= ret_rreq + READREQ_GRAN[7:0];
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
        // On a successful response send its credits are consumed (§6.1) and the
        // return credits (just flushed into the header) are cleared.
        S_WRESP: if (dtx_valid && dtx_ready) begin
          cr_wresp  <= cr_wresp - WRITERESP_GRAN[7:0];
          ret_wreq  <= '0; ret_rreq <= '0; ret_wdata <= '0;
          state     <= S_IDLE;
        end
        S_RMEM: begin
          if (m_arvalid && m_arready) ar_done <= 1'b1;
          if (m_rvalid  && m_rready ) begin
            rdata_q <= m_rdata;
            rresp_q <= m_rresp;
            ar_done <= 1'b0;
            state   <= S_RDATA;
          end
        end
        S_RDATA: if (dtx_valid && dtx_ready) begin
          cr_rdata  <= cr_rdata - READDATA_GRAN[7:0];
          ret_wreq  <= '0; ret_rreq <= '0; ret_wdata <= '0;
          state     <= S_IDLE;
        end
        // verilator coverage_off
        default: state <= S_IDLE;   // unreachable (all states enumerated)
        // verilator coverage_on
      endcase
    end
  end

endmodule
`endif
