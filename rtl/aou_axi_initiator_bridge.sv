// -----------------------------------------------------------------------------
// aou_axi_initiator_bridge : chiplet-A bridge (AXI4 subordinate -> AoU).
//
// Accepts AXI4 transactions (INCR/WRAP/FIXED bursts, AxLEN beats) from the TB
// master and turns them into AoU Basic-Profile messages, one message per flit:
//   * write  -> WriteReq flit, then (AWLEN+1) WriteData256 flits (one per beat)
//   * read   -> ReadReq flit; then (ARLEN+1) ReadData256 flits arrive on B->A,
//               each driven out as one R beat (RLAST on the last).
// The AoU {AW,AR}ID tag is carried and echoed back in {B,R}ID.  The burst type
// rides in the request FLEX[1:0] (AoU has no AWBURST field); address sequencing
// is done target-side, so this bridge just streams/collects beats.
//
// Multiple-outstanding (stage 2): a REQ_QD-deep request queue decouples the AXI
// AW/AR accept from the FSM, so the master can have several transactions queued
// while a prior burst is still in flight (s_awready/s_arready track queue-space,
// not FSM state).  The FSM still processes one queued request at a time and the
// single serialized link + single in-order memory return completions in issue
// order, so this is multiple-outstanding with in-order completion.
// Bursts are bounded by the data-message credit ceiling (§6): the target's
// CrdtGrant seeds enough WriteData/ReadData credits for up to CR_* granules, so
// AxLEN+1 <= CR_WDATA/WRITEDATA_GRAN beats (16 by default); longer bursts need
// mid-burst credit replenishment (follow-on).
// -----------------------------------------------------------------------------
`ifndef AOU_AXI_INITIATOR_BRIDGE_SV
`define AOU_AXI_INITIATOR_BRIDGE_SV

module aou_axi_initiator_bridge
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8,
    parameter int AXI_ID_W   = 4,
    // Multiple-outstanding request-queue depth (AXI AW/AR accepted ahead of the
    // FSM).  Depth 1 reduces to the original single-outstanding behaviour.
    parameter int REQ_QD     = 4,
    // §6 flow control — granule credits this (initiator) bridge holds to send
    // each message type it transmits.  WriteData is sized for a full burst
    // (128 granules = 16 beats) since a write burst gets no mid-burst credit
    // return (the WriteResp replenishes it at the end).
    parameter int CR_WREQ  = WRITEREQ_GRAN,     // WriteReq  credits (3 granules)
    parameter int CR_RREQ  = READREQ_GRAN,      // ReadReq   credits (3 granules)
    parameter int CR_WDATA = 128                // WriteData credits (16 beats)
) (
    input  logic                    clk,
    input  logic                    rstn,
    // ---- AXI4 subordinate (TB master drives these) ----
    input  logic [AXI_ID_W-1:0]     s_awid,
    input  logic [AXI_ADDR_W-1:0]   s_awaddr,
    input  logic [7:0]              s_awlen,
    input  logic [2:0]              s_awsize,
    input  logic [1:0]              s_awburst,
    input  logic [2:0]              s_awprot,
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [AXI_DATA_W-1:0]   s_wdata,
    input  logic [AXI_STRB_W-1:0]   s_wstrb,
    input  logic                    s_wlast,
    input  logic                    s_wvalid,
    output logic                    s_wready,
    output logic [AXI_ID_W-1:0]     s_bid,
    output logic [1:0]              s_bresp,
    output logic                    s_bvalid,
    input  logic                    s_bready,
    input  logic [AXI_ID_W-1:0]     s_arid,
    input  logic [AXI_ADDR_W-1:0]   s_araddr,
    input  logic [7:0]              s_arlen,
    input  logic [2:0]              s_arsize,
    input  logic [1:0]              s_arburst,
    input  logic [2:0]              s_arprot,
    input  logic                    s_arvalid,
    output logic                    s_arready,
    output logic [AXI_ID_W-1:0]     s_rid,
    output logic [AXI_DATA_W-1:0]   s_rdata,
    output logic [1:0]              s_rresp,
    output logic                    s_rlast,
    output logic                    s_rvalid,
    input  logic                    s_rready,
    // ---- flit TX (to A->B link) ----
    output logic [PLP_BITS-1:0]     tx_data,
    output logic                    tx_valid,
    input  logic                    tx_ready,
    // ---- flit RX (from B->A link) ----
    input  logic [PLP_BITS-1:0]     rx_data,
    input  logic                    rx_valid,
    output logic                    rx_ready
);

  typedef enum logic [2:0] {
    S_IDLE, S_WREQ, S_WDATA, S_WWAIT, S_B, S_RREQ, S_RDATA
  } state_e;
  state_e state;

  // --- multiple-outstanding request queue -----------------------------------
  // Descriptors for AW/AR requests accepted from the AXI master but not yet
  // processed by the FSM.  A single write port (AW has priority over AR) keeps
  // one push per cycle; the FSM pops one descriptor per burst.
  localparam int QPW = (REQ_QD > 1) ? $clog2(REQ_QD) : 1;   // pointer width
  localparam logic [QPW-1:0] QLAST = QPW'(REQ_QD-1);        // wrap value
  logic                  q_wr    [0:REQ_QD-1];   // 1 = write, 0 = read
  logic [AXI_ID_W-1:0]   q_id    [0:REQ_QD-1];
  logic [AXI_ADDR_W-1:0] q_addr  [0:REQ_QD-1];
  logic [7:0]            q_len   [0:REQ_QD-1];
  logic [2:0]            q_size  [0:REQ_QD-1];
  logic [1:0]            q_burst [0:REQ_QD-1];
  logic [2:0]            q_prot  [0:REQ_QD-1];
  logic [QPW-1:0]        q_head, q_tail;
  logic [QPW:0]          q_count;                // 0 .. REQ_QD
  wire                   q_full  = (q_count == REQ_QD[QPW:0]);
  wire                   q_empty = (q_count == '0);

  // captured request context (one burst in flight)
  logic [AXI_ID_W-1:0]   id_q;
  logic [AXI_ADDR_W-1:0] addr_q;
  logic [7:0]            len_q;
  logic [2:0]            size_q;
  logic [1:0]            burst_q;
  logic [2:0]            prot_q;
  // write-data beat buffer
  logic [AXI_DATA_W-1:0] wdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  logic                  wbeat_valid, wlast_q;
  // response context
  logic [AXI_ID_W-1:0]   bid_q;
  logic [1:0]            bresp_q;

  // §6 credits HELD to transmit (granted by chiplet B).  Consumed per message,
  // replenished from the MsgCredit field of the B->A response flit.
  logic [7:0] cr_wreq, cr_rreq, cr_wdata;
  // §6 credits OWED back to B for the responses this bridge consumes
  // (ReadData / WriteResp): advertised in the next A->B flit header, then cleared.
  logic [7:0] ret_rdata, ret_wresp;

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

  wire wreq_ok  = (cr_wreq  >= WRITEREQ_GRAN[7:0]);
  wire wdata_ok = (cr_wdata >= WRITEDATA_GRAN[7:0]);
  wire rreq_ok  = (cr_rreq  >= READREQ_GRAN[7:0]);

  // === §8 activation + §6.4.3 reset credit exchange ========================
  // This side is the initiator: it grants ReadData/WriteResp credits to chiplet
  // B (the message types B transmits).  ReadData is sized for a full read burst.
  localparam logic [2:0] GR_RDATA = 3'b111;   // 128 granules (16 ReadData beats)
  localparam logic [1:0] GR_WRESP = 2'b01;    // >= WRITERESP_GRAN (1)

  logic                  act_enabled, act_disabled;
  logic [PLP_BITS-1:0]   dtx_data, drx_data;
  logic                  dtx_valid, dtx_ready, drx_valid, drx_ready;
  logic                  seed_valid;
  logic [2:0]            seed_wreq, seed_rreq, seed_wdata;
  // verilator lint_off UNUSEDSIGNAL
  logic [2:0]            seed_rdata;
  logic [1:0]            seed_wresp;
  logic                  act_error;
  logic                  act_quiescing;   // Opt-2 drain hint, unused (deact tied 0)
  // verilator lint_on UNUSEDSIGNAL

  aou_activation #(
    .GRANT_RDATA(GR_RDATA), .GRANT_WRESP(GR_WRESP)
  ) u_act (
    .clk(clk), .rstn(rstn), .enabled(act_enabled),
    .act_disabled(act_disabled), .error(act_error),
    // deact/quiesce unused here (no SW teardown in the full chain); data_idle
    // tied high = Option-1 degenerate.  Option 2 is exercised in dv/act.
    .deact_trig(1'b0), .data_idle(1'b1), .quiescing(act_quiescing), .err_clear(1'b0),
    .tx_data(tx_data),  .tx_valid(tx_valid),  .tx_ready(tx_ready),
    .rx_data(rx_data),  .rx_valid(rx_valid),  .rx_ready(rx_ready),
    .d_tx_data(dtx_data), .d_tx_valid(dtx_valid), .d_tx_ready(dtx_ready),
    .d_rx_data(drx_data), .d_rx_valid(drx_valid), .d_rx_ready(drx_ready),
    .seed_valid(seed_valid), .seed_wreq(seed_wreq), .seed_rreq(seed_rreq),
    .seed_wdata(seed_wdata), .seed_rdata(seed_rdata), .seed_wresp(seed_wresp)
  );

  // MsgCredit this bridge advertises to B (grants ReadData/WriteResp).
  function automatic logic [CREDIT_W-1:0] return_credit();
    return_credit = mk_msgcredit(2'b00, 3'b000, 3'b000, 3'b000,
                                 cred_encode_ge(ret_rdata),
                                 cred_encode_ge2(ret_wresp));
  endfunction

  // --- build the outgoing flits (one message per flit) ----------------------
  function automatic flit_t build_wreq_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_writereq(2'b00, 1'b0, {{(FLEX_W-2){1'b0}}, burst_q},
                       {{(AOU_ID_W-AXI_ID_W){1'b0}}, id_q}, size_q, prot_q,
                       len_q, '0, '0,
                       {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, addr_q});
      pl = payload_put('0, 0, WRITEREQ_GRAN, m);
      build_wreq_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  function automatic flit_t build_wdata_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_writedata256(2'b00, '0,
                       {{(AOU_DATA_W-AXI_DATA_W){1'b0}}, wdata_q},
                       {{(AOU_STRB_W-AXI_STRB_W){1'b0}}, wstrb_q});
      pl = payload_put('0, 0, WRITEDATA_GRAN, m);
      build_wdata_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  function automatic flit_t build_rreq_flit();
    msg_t m; payload_t pl;
    begin
      m  = mk_readreq(2'b00, 1'b0, {{(FLEX_W-2){1'b0}}, burst_q},
                      {{(AOU_ID_W-AXI_ID_W){1'b0}}, id_q}, size_q, prot_q,
                      len_q, '0, '0,
                      {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, addr_q});
      pl = payload_put('0, 0, READREQ_GRAN, m);
      build_rreq_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  // --- read-beat view of the current B->A flit ------------------------------
  msg_t rdmsg;
  // verilator lint_off UNUSEDSIGNAL
  logic [AOU_ID_W-1:0]   rd_rid_full;    // only low AXI_ID_W bits used
  logic [AOU_DATA_W-1:0] rd_full;
  // verilator lint_on UNUSEDSIGNAL
  assign rdmsg       = payload_get(flit_payload(drx_data), 0, READDATA_GRAN);
  assign rd_full     = rd_data(rdmsg);
  assign rd_rid_full = rd_id(rdmsg);

  // --- combinational outputs ------------------------------------------------
  // AXI accepted once ENABLED (§8) whenever the request queue has space; the FSM
  // pops and processes descriptors independently (multiple-outstanding accept).
  // AW has priority over AR so at most one descriptor is enqueued per cycle.
  assign s_awready = act_enabled && !q_full;
  assign s_arready = act_enabled && !q_full && !s_awvalid;  // AW priority
  wire acc_aw = s_awvalid && s_awready;
  wire acc_ar = s_arvalid && s_arready;
  wire do_pop = (state == S_IDLE) && !q_empty;
  // In S_WDATA we take a W beat only when no beat is buffered awaiting send.
  assign s_wready  = (state == S_WDATA) && !wbeat_valid;
  assign s_bid     = bid_q;
  assign s_bvalid  = (state == S_B);
  assign s_bresp   = bresp_q;
  // Drive an R beat straight from an incoming ReadData flit.
  assign s_rid     = rd_rid_full[AXI_ID_W-1:0];
  assign s_rvalid  = (state == S_RDATA) && drx_valid;
  assign s_rdata   = rd_full[AXI_DATA_W-1:0];
  assign s_rresp   = rd_resp(rdmsg);
  assign s_rlast   = rd_last(rdmsg);

  // flit TX valid: gated by the credit for the message the state emits.
  assign dtx_valid = ((state == S_WREQ)  && wreq_ok)  ||
                     ((state == S_WDATA) && wbeat_valid && wdata_ok) ||
                     ((state == S_RREQ)  && rreq_ok);
  // flit RX ready: consume a WriteResp in S_WWAIT, or a ReadData as its R beat
  // is accepted in S_RDATA.
  assign drx_ready = (state == S_WWAIT) ||
                     ((state == S_RDATA) && s_rready);

  // Build the outgoing flit procedurally (Icarus 11 wide-ufunc-in-assign issue).
  always_comb begin
    unique case (state)
      S_WREQ:  dtx_data = build_wreq_flit();
      S_WDATA: dtx_data = build_wdata_flit();
      default: dtx_data = build_rreq_flit();
    endcase
  end

  // --- FSM ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state    <= S_IDLE;
      q_head   <= '0; q_tail <= '0; q_count <= '0;
      id_q     <= '0; addr_q <= '0; len_q <= '0; size_q <= '0;
      burst_q  <= '0; prot_q <= '0;
      wdata_q  <= '0; wstrb_q <= '0; wbeat_valid <= 1'b0; wlast_q <= 1'b0;
      bid_q    <= '0; bresp_q <= '0;
      cr_wreq  <= '0; cr_rreq <= '0; cr_wdata <= '0;
      ret_rdata <= '0; ret_wresp <= '0;
    end else begin
      // §8.2 DISABLED: discard granted credits; §6.4.3 seed re-grants them.
      if (act_disabled) begin
        cr_wreq <= '0; cr_rreq <= '0; cr_wdata <= '0;
      end else if (seed_valid) begin
        cr_wreq  <= sat_add(cr_wreq,  cred_decode(seed_wreq),  CR_WREQ);
        cr_rreq  <= sat_add(cr_rreq,  cred_decode(seed_rreq),  CR_RREQ);
        cr_wdata <= sat_add(cr_wdata, cred_decode(seed_wdata), CR_WDATA);
      end
      // ---- request-queue push (AW priority; one push per cycle) ----
      if (acc_aw) begin
        q_wr[q_tail]   <= 1'b1;      q_id[q_tail]    <= s_awid;
        q_addr[q_tail] <= s_awaddr;  q_len[q_tail]   <= s_awlen;
        q_size[q_tail] <= s_awsize;  q_burst[q_tail] <= s_awburst;
        q_prot[q_tail] <= s_awprot;
        q_tail <= (q_tail == QLAST) ? '0 : q_tail + 1'b1;
      end else if (acc_ar) begin
        q_wr[q_tail]   <= 1'b0;      q_id[q_tail]    <= s_arid;
        q_addr[q_tail] <= s_araddr;  q_len[q_tail]   <= s_arlen;
        q_size[q_tail] <= s_arsize;  q_burst[q_tail] <= s_arburst;
        q_prot[q_tail] <= s_arprot;
        q_tail <= (q_tail == QLAST) ? '0 : q_tail + 1'b1;
      end
      if ((acc_aw || acc_ar) && !do_pop)      q_count <= q_count + 1'b1;
      else if (!(acc_aw || acc_ar) && do_pop) q_count <= q_count - 1'b1;

      unique case (state)
        // Pop the next queued request (issue order) and start its burst.
        S_IDLE: if (!q_empty) begin
          id_q    <= q_id[q_head];    addr_q  <= q_addr[q_head];
          len_q   <= q_len[q_head];   size_q  <= q_size[q_head];
          burst_q <= q_burst[q_head]; prot_q  <= q_prot[q_head];
          q_head  <= (q_head == QLAST) ? '0 : q_head + 1'b1;
          if (q_wr[q_head]) begin
            wbeat_valid <= 1'b0;
            state <= S_WREQ;
          end else begin
            state <= S_RREQ;
          end
        end
        S_WREQ: if (dtx_valid && dtx_ready) begin
          cr_wreq   <= cr_wreq - WRITEREQ_GRAN[7:0];
          ret_rdata <= '0; ret_wresp <= '0;   // return-credits just flushed
          state     <= S_WDATA;
        end
        S_WDATA: begin
          // capture a W beat when the buffer is free
          if (s_wvalid && s_wready) begin
            wdata_q <= s_wdata; wstrb_q <= s_wstrb; wlast_q <= s_wlast;
            wbeat_valid <= 1'b1;
          end
          // send the buffered beat as a WriteData flit
          if (dtx_valid && dtx_ready) begin
            wbeat_valid <= 1'b0;
            cr_wdata    <= cr_wdata - WRITEDATA_GRAN[7:0];
            if (wlast_q) state <= S_WWAIT;
          end
        end
        S_WWAIT: if (drx_valid) begin : s_wwait_blk
          msg_t                m;
          logic [CREDIT_W-1:0] mc;
          // verilator lint_off UNUSEDSIGNAL
          logic [AOU_ID_W-1:0] bidf;   // only low AXI_ID_W bits used
          // verilator lint_on UNUSEDSIGNAL
          m  = payload_get(flit_payload(drx_data), 0, WRITERESP_GRAN);
          mc = flit_credit(drx_data);
          bidf = wrsp_id(m);
          cr_wreq  <= sat_add(cr_wreq,  cred_decode(mc_wreq (mc)), CR_WREQ);
          cr_rreq  <= sat_add(cr_rreq,  cred_decode(mc_rreq (mc)), CR_RREQ);
          cr_wdata <= sat_add(cr_wdata, cred_decode(mc_wdata(mc)), CR_WDATA);
          bresp_q  <= wrsp_resp(m);
          bid_q    <= bidf[AXI_ID_W-1:0];
          ret_wresp <= ret_wresp + WRITERESP_GRAN[7:0];
          state    <= S_B;
        end
        S_B: if (s_bready) state <= S_IDLE;
        S_RREQ: if (dtx_valid && dtx_ready) begin
          cr_rreq   <= cr_rreq - READREQ_GRAN[7:0];
          ret_rdata <= '0; ret_wresp <= '0;
          state     <= S_RDATA;
        end
        S_RDATA: begin
          // credit replenish + return-credit accounting happen per accepted beat
          if (s_rvalid && s_rready) begin : s_rdata_blk
            logic [CREDIT_W-1:0] mc;
            mc = flit_credit(drx_data);
            cr_wreq  <= sat_add(cr_wreq,  cred_decode(mc_wreq (mc)), CR_WREQ);
            cr_rreq  <= sat_add(cr_rreq,  cred_decode(mc_rreq (mc)), CR_RREQ);
            cr_wdata <= sat_add(cr_wdata, cred_decode(mc_wdata(mc)), CR_WDATA);
            ret_rdata <= ret_rdata + READDATA_GRAN[7:0];
            if (rd_last(rdmsg)) state <= S_IDLE;
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
