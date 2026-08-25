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
// not FSM state).
// Bursts are bounded by the data-message credit ceiling (§6): the target's
// CrdtGrant seeds enough WriteData/ReadData credits for up to CR_* granules, so
// AxLEN+1 <= CR_WDATA/WRITEDATA_GRAN beats (16 by default); longer bursts need
// mid-burst credit replenishment (follow-on).
//
// Two response paths, selected by OOO_EN (docs/PLAN.md F2):
//
//   OOO_EN = 0 (SHIPPING DEFAULT) — in-order.  The FSM processes one queued
//     request at a time and blocks on its response (S_WWAIT / S_RDATA); the
//     single serialized link and single in-order memory return completions in
//     issue order, so this is multiple-outstanding with in-order completion.
//     This is exactly the pre-F2 datapath, bit- and cycle-identical.
//
//   OOO_EN = 1 — out-of-order-by-ID.  The FSM issues a request and immediately
//     returns to S_IDLE, so up to OOO_DEPTH transactions are in flight.  Each
//     issue allocates a slot in an `aou_reorder` buffer keyed by AXI ID (one
//     buffer for reads -> R, one for writes -> B, so neither channel heads-of-
//     line the other); the allocated slot index is stamped into the request's
//     FLEX[15:12] tag and echoed by the target in the response, so completions
//     may arrive in ANY order and are still attributed to the right slot.  The
//     reorder buffer then presents the oldest-not-yet-released response OF ITS
//     ID onto R/B, which is precisely the AXI ordering rule.  The out-of-order
//     completions themselves come from aou_ooo_resp_src on the target side.
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
    parameter int CR_WDATA = 128,               // WriteData credits (16 beats)
    // --- out-of-order response handling (default OFF) ---------------------
    parameter bit OOO_EN    = 1'b0,
    // Outstanding capacity of each reorder buffer.  Power of two, and
    // $clog2(OOO_DEPTH)+1 must fit the FLEX_TAG_W-bit tag (so <= 8).
    parameter int OOO_DEPTH = REQ_QD,
    // Longest read burst a reorder slot can hold (credit ceiling is 16 beats).
    parameter int OOO_MAXB  = 16
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

  // FSM state encodings.  Declared at module scope (not inside the generate
  // branch that uses them) because Icarus does not resolve enum labels declared
  // in a generate block.  Only one of the two FSMs is ever elaborated.
  typedef enum logic [2:0] {
    S_IDLE, S_WREQ, S_WDATA, S_WWAIT, S_B, S_RREQ, S_RDATA
  } state_e;                                        // OOO_EN = 0
  typedef enum logic [1:0] {
    O_IDLE, O_WREQ, O_WDATA, O_RREQ
  } ostate_e;                                       // OOO_EN = 1

  // --- multiple-outstanding request queue -----------------------------------
  // Descriptors for AW/AR requests accepted from the AXI master but not yet
  // processed by the FSM.  A single write port (AW has priority over AR) keeps
  // one push per cycle; the FSM pops one descriptor per burst (`do_pop`).
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
  logic                  do_pop;                 // driven by the selected FSM

  // captured request context (one burst being transmitted)
  logic [AXI_ID_W-1:0]   id_q;
  logic [AXI_ADDR_W-1:0] addr_q;
  logic [7:0]            len_q;
  logic [2:0]            size_q;
  logic [1:0]            burst_q;
  logic [2:0]            prot_q;
  // write-data beat buffer
  logic [AXI_DATA_W-1:0] wdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  // FLEX word stamped on the outgoing request (burst type, plus the reorder tag
  // in OOO mode — zero in the default build, so the byte map is unchanged).
  logic [FLEX_W-1:0]     req_flex;

  // §6 credits HELD to transmit (granted by chiplet B).  Consumed per message,
  // replenished from the MsgCredit field of the B->A response flit.
  logic [7:0] cr_wreq, cr_rreq, cr_wdata;
  // §6 credits OWED back to B for the responses this bridge consumes
  // (ReadData / WriteResp): advertised in the next A->B flit header, then cleared.
  logic [7:0] ret_rdata, ret_wresp;

  // In OOO mode several requests are in flight before any response returns, so
  // the request-message credit ceilings scale with the outstanding capacity.
  localparam int LCR_WREQ = OOO_EN ? (WRITEREQ_GRAN * OOO_DEPTH) : CR_WREQ;
  localparam int LCR_RREQ = OOO_EN ? (READREQ_GRAN  * OOO_DEPTH) : CR_RREQ;

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
  // B (the message types B transmits).  ReadData is sized for a full read burst;
  // in OOO mode WriteResp needs room for a held response plus one overtaking it.
  localparam logic [2:0] GR_RDATA = 3'b111;                  // 128 granules
  localparam logic [1:0] GR_WRESP = OOO_EN ? 2'b11 : 2'b01;  // 8 : 1 granule(s)

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
      m  = mk_writereq(2'b00, 1'b0, req_flex,
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
      m  = mk_readreq(2'b00, 1'b0, req_flex,
                      {{(AOU_ID_W-AXI_ID_W){1'b0}}, id_q}, size_q, prot_q,
                      len_q, '0, '0,
                      {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, addr_q});
      pl = payload_put('0, 0, READREQ_GRAN, m);
      build_rreq_flit = flit_assemble_cr('0, msgstart_t'(1), return_credit(), pl);
    end
  endfunction

  // --- AXI accept + request queue (shared by both response paths) -----------
  // AXI accepted once ENABLED (§8) whenever the request queue has space; the FSM
  // pops and processes descriptors independently (multiple-outstanding accept).
  // AW has priority over AR so at most one descriptor is enqueued per cycle.
  assign s_awready = act_enabled && !q_full;
  assign s_arready = act_enabled && !q_full && !s_awvalid;  // AW priority
  wire acc_aw = s_awvalid && s_awready;
  wire acc_ar = s_arvalid && s_arready;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      q_head <= '0; q_tail <= '0; q_count <= '0;
    end else begin
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
      if (do_pop) q_head <= (q_head == QLAST) ? '0 : q_head + 1'b1;
      if ((acc_aw || acc_ar) && !do_pop)      q_count <= q_count + 1'b1;
      else if (!(acc_aw || acc_ar) && do_pop) q_count <= q_count - 1'b1;
    end
  end

  generate
  // =========================================================================
  // OOO_EN = 0 : the in-order response path (shipping default, unchanged).
  // =========================================================================
  if (!OOO_EN) begin : g_inorder

    state_e state;

    logic                  wbeat_valid, wlast_q;
    logic [AXI_ID_W-1:0]   bid_q;
    logic [1:0]            bresp_q;

    // --- read-beat view of the current B->A flit ----------------------------
    msg_t rdmsg;
    // verilator lint_off UNUSEDSIGNAL
    logic [AOU_ID_W-1:0]   rd_rid_full;    // only low AXI_ID_W bits used
    logic [AOU_DATA_W-1:0] rd_full;
    // verilator lint_on UNUSEDSIGNAL
    assign rdmsg       = payload_get(flit_payload(drx_data), 0, READDATA_GRAN);
    assign rd_full     = rd_data(rdmsg);
    assign rd_rid_full = rd_id(rdmsg);

    assign req_flex = {{(FLEX_W-2){1'b0}}, burst_q};
    assign do_pop   = (state == S_IDLE) && !q_empty;
    // In S_WDATA we take a W beat only when no beat is buffered awaiting send.
    assign s_wready = (state == S_WDATA) && !wbeat_valid;
    assign s_bid    = bid_q;
    assign s_bvalid = (state == S_B);
    assign s_bresp  = bresp_q;
    // Drive an R beat straight from an incoming ReadData flit.
    assign s_rid    = rd_rid_full[AXI_ID_W-1:0];
    assign s_rvalid = (state == S_RDATA) && drx_valid;
    assign s_rdata  = rd_full[AXI_DATA_W-1:0];
    assign s_rresp  = rd_resp(rdmsg);
    assign s_rlast  = rd_last(rdmsg);

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

    // --- FSM --------------------------------------------------------------
    always_ff @(posedge clk or negedge rstn) begin
      if (!rstn) begin
        state    <= S_IDLE;
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
          cr_wreq  <= sat_add(cr_wreq,  cred_decode(seed_wreq),  LCR_WREQ);
          cr_rreq  <= sat_add(cr_rreq,  cred_decode(seed_rreq),  LCR_RREQ);
          cr_wdata <= sat_add(cr_wdata, cred_decode(seed_wdata), CR_WDATA);
        end

        unique case (state)
          // Pop the next queued request (issue order) and start its burst.
          S_IDLE: if (!q_empty) begin
            id_q    <= q_id[q_head];    addr_q  <= q_addr[q_head];
            len_q   <= q_len[q_head];   size_q  <= q_size[q_head];
            burst_q <= q_burst[q_head]; prot_q  <= q_prot[q_head];
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
            cr_wreq  <= sat_add(cr_wreq,  cred_decode(mc_wreq (mc)), LCR_WREQ);
            cr_rreq  <= sat_add(cr_rreq,  cred_decode(mc_rreq (mc)), LCR_RREQ);
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
              cr_wreq  <= sat_add(cr_wreq,  cred_decode(mc_wreq (mc)), LCR_WREQ);
              cr_rreq  <= sat_add(cr_rreq,  cred_decode(mc_rreq (mc)), LCR_RREQ);
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

  end else begin : g_ooo
  // =========================================================================
  // OOO_EN = 1 : pipelined issue + per-ID reorder buffers on the response path.
  // =========================================================================

    localparam int OTAGW = (OOO_DEPTH > 1) ? $clog2(OOO_DEPTH) : 1;
    localparam int EW    = AXI_DATA_W + 2;          // one held R beat: {RRESP,RDATA}
    localparam int RVEC_W = OOO_MAXB * EW;          // all beats of one read burst
    localparam int RDAT_W = RVEC_W + 8;             // + the burst's AxLEN

    ostate_e ostate;

    logic                  wbeat_valid, wlast_q;
    logic [FLEX_TAG_W-1:0] tag_q;

    // ---- the two per-ID reorder buffers (reads -> R, writes -> B) ---------
    logic                 r_iss_valid, r_iss_ready;
    logic [OTAGW-1:0]     r_iss_tag;
    logic                 r_cmp_valid;
    logic [OTAGW-1:0]     r_cmp_tag;
    logic [RDAT_W-1:0]    r_cmp_data;
    logic                 r_out_valid, r_out_ready;
    logic [AXI_ID_W-1:0]  r_out_id;
    logic [RDAT_W-1:0]    r_out_data;

    logic                 w_iss_valid, w_iss_ready;
    logic [OTAGW-1:0]     w_iss_tag;
    logic                 w_cmp_valid;
    logic [OTAGW-1:0]     w_cmp_tag;
    logic [1:0]           w_cmp_data;
    logic                 w_out_valid, w_out_ready;
    logic [AXI_ID_W-1:0]  w_out_id;
    logic [1:0]           w_out_data;

    aou_reorder #(.DEPTH(OOO_DEPTH), .ID_W(AXI_ID_W), .DATA_W(RDAT_W)) u_rob_r (
      .clk(clk), .rstn(rstn),
      .iss_valid(r_iss_valid), .iss_ready(r_iss_ready),
      .iss_id(q_id[q_head]),   .iss_tag(r_iss_tag),
      .cmp_valid(r_cmp_valid), .cmp_tag(r_cmp_tag), .cmp_data(r_cmp_data),
      .out_valid(r_out_valid), .out_id(r_out_id), .out_data(r_out_data),
      .out_ready(r_out_ready)
    );

    aou_reorder #(.DEPTH(OOO_DEPTH), .ID_W(AXI_ID_W), .DATA_W(2)) u_rob_w (
      .clk(clk), .rstn(rstn),
      .iss_valid(w_iss_valid), .iss_ready(w_iss_ready),
      .iss_id(q_id[q_head]),   .iss_tag(w_iss_tag),
      .cmp_valid(w_cmp_valid), .cmp_tag(w_cmp_tag), .cmp_data(w_cmp_data),
      .out_valid(w_out_valid), .out_id(w_out_id), .out_data(w_out_data),
      .out_ready(w_out_ready)
    );

    // ---- issue -----------------------------------------------------------
    // §6 anti-starvation.  This bridge returns ReadData/WriteResp credits only
    // by piggybacking them on the NEXT request flit it sends.  With several
    // reads in flight and no further request to send, the target could
    // therefore exhaust its ReadData credits mid-flight and stall with no way
    // to get more.  Bound it at issue: never let more ReadData granules be
    // outstanding than the ceiling this bridge granted the target
    // (GR_RDATA = 128 granules = 16 beats).  A lone transaction is always let
    // through, so the worst case degenerates to exactly the in-order path,
    // whose burst length that same ceiling already caps.
    // (WriteResp needs no equivalent gate: at most OOO_DEPTH writes are
    //  outstanding and GR_WRESP grants 8 >= OOO_DEPTH granules.)
    localparam int RD_CEIL = 128;
    logic [15:0] rd_out;                       // ReadData granules in flight
    wire  [15:0] rd_need = 16'((32'(q_len[q_head]) + 1) * READDATA_GRAN);
    wire         rd_fits = (rd_out == '0) ||
                           ((32'(rd_out) + 32'(rd_need)) <= RD_CEIL);

    wire q_is_wr    = q_wr[q_head];
    wire rob_ready  = q_is_wr ? w_iss_ready : (r_iss_ready && rd_fits);
    assign do_pop      = (ostate == O_IDLE) && !q_empty && rob_ready;
    assign r_iss_valid = do_pop && !q_is_wr;
    assign w_iss_valid = do_pop &&  q_is_wr;
    // The reorder-slot index, zero-extended into the FLEX[15:12] tag field.
    // Read and write slots share the tag space: MSGTYPE already tells a
    // ReadData from a WriteResp, so the two buffers are indexed independently.
    wire [FLEX_TAG_W-1:0] alloc_tag =
        {{(FLEX_TAG_W-OTAGW){1'b0}}, (q_is_wr ? w_iss_tag : r_iss_tag)};

    assign req_flex = {tag_q, {(FLEX_W-FLEX_TAG_W-2){1'b0}}, burst_q};

    // ---- incoming response flit view -------------------------------------
    msg_t rmsg;
    // verilator lint_off UNUSEDSIGNAL
    logic [AOU_DATA_W-1:0] rd_full;      // only the low AXI_DATA_W bits are used
    // verilator lint_on UNUSEDSIGNAL
    assign rmsg    = payload_get(flit_payload(drx_data), 0, READDATA_GRAN);
    assign rd_full = rd_data(rmsg);
    wire [MSGTYPE_W-1:0]   rsp_mt   = get_msgtype(rmsg);
    wire                   rsp_rd   = drx_valid && (rsp_mt == MT_READDATA);
    wire                   rsp_wr   = drx_valid && (rsp_mt == MT_WRITERESP);
    // verilator lint_off UNUSEDSIGNAL
    wire [FLEX_TAG_W-1:0]  rsp_tag  = flex_tag(msg_flex(rmsg));  // low OTAGW used
    // verilator lint_on UNUSEDSIGNAL
    wire [OTAGW-1:0]       rsp_slot = rsp_tag[OTAGW-1:0];
    wire                   rsp_last = rd_last(rmsg);

    // Completions are always accepted: the slot was reserved at issue time.
    assign drx_ready = 1'b1;

    // ---- read-beat accumulator (one flit per beat, RLAST closes the slot) --
    logic [RVEC_W-1:0] acc     [0:OOO_DEPTH-1];
    logic [7:0]        acc_cnt [0:OOO_DEPTH-1];
    logic [7:0]        acc_len [0:OOO_DEPTH-1];
    wire [7:0]         cur_cnt = acc_cnt[rsp_slot];
    // verilator lint_off UNUSEDSIGNAL
    wire [31:0]        cur_off = 32'(cur_cnt) * EW;   // part-select base
    // verilator lint_on UNUSEDSIGNAL
    // Guard the vector bound: bursts longer than OOO_MAXB beats cannot be held
    // (the §6 ReadData credit ceiling already caps a burst at 16 beats).
    wire               acc_ok  = (32'(cur_cnt) < OOO_MAXB);

    // cmp is registered one cycle behind the flit so the accumulator write has
    // landed; at most one response flit arrives per cycle, so nothing is lost.
    logic             cmpr_pend;
    logic [OTAGW-1:0] cmpr_tag;
    logic             cmpw_pend;
    logic [OTAGW-1:0] cmpw_tag;
    logic [1:0]       cmpw_resp;

    assign r_cmp_valid = cmpr_pend;
    assign r_cmp_tag   = cmpr_tag;
    assign r_cmp_data  = {acc_len[cmpr_tag], acc[cmpr_tag]};
    assign w_cmp_valid = cmpw_pend;
    assign w_cmp_tag   = cmpw_tag;
    assign w_cmp_data  = cmpw_resp;

    // ---- AXI R output stage (registered: the ROB's out_* selection is
    //      combinational and may re-point when another slot completes) -------
    logic [AXI_ID_W-1:0] r_id_q;
    logic [RVEC_W-1:0]   r_vec_q;
    logic [7:0]          r_len_q, r_beat;
    logic                r_busy;
    // verilator lint_off UNUSEDSIGNAL
    wire [31:0]          r_off  = 32'(r_beat) * EW;   // part-select base
    // verilator lint_on UNUSEDSIGNAL
    wire [EW-1:0]        r_elem = r_vec_q[r_off +: EW];

    assign r_out_ready = !r_busy;
    assign s_rvalid    = r_busy;
    assign s_rid       = r_id_q;
    assign s_rdata     = r_elem[AXI_DATA_W-1:0];
    assign s_rresp     = r_elem[EW-1 -: 2];
    assign s_rlast     = (r_beat == r_len_q);

    // ---- AXI B output stage ----------------------------------------------
    logic [AXI_ID_W-1:0] b_id_q;
    logic [1:0]          b_resp_q;
    logic                b_busy;
    assign w_out_ready = !b_busy;
    assign s_bvalid    = b_busy;
    assign s_bid       = b_id_q;
    assign s_bresp     = b_resp_q;

    // ---- request transmit -------------------------------------------------
    assign s_wready  = (ostate == O_WDATA) && !wbeat_valid;
    assign dtx_valid = ((ostate == O_WREQ)  && wreq_ok)  ||
                       ((ostate == O_WDATA) && wbeat_valid && wdata_ok) ||
                       ((ostate == O_RREQ)  && rreq_ok);
    wire dtx_fire  = dtx_valid && dtx_ready;
    wire wreq_fire = dtx_fire && (ostate == O_WREQ);
    wire rreq_fire = dtx_fire && (ostate == O_RREQ);
    wire wdat_fire = dtx_fire && (ostate == O_WDATA);
    wire req_fire  = wreq_fire || rreq_fire;

    always_comb begin
      unique case (ostate)
        O_WREQ:  dtx_data = build_wreq_flit();
        O_WDATA: dtx_data = build_wdata_flit();
        default: dtx_data = build_rreq_flit();
      endcase
    end

    // ---- §6 credit next-state ---------------------------------------------
    // Issue and completion are concurrent here (unlike the in-order FSM), so a
    // send and a replenish can land in the same cycle: fold both into one
    // next-value so neither is dropped.
    logic [CREDIT_W-1:0] rmc;
    logic [7:0]  n_wreq, n_rreq, n_wdata, n_ret_rdata, n_ret_wresp;
    logic [15:0] n_rd_out;
    assign rmc = flit_credit(drx_data);

    // return-credit accumulator, capped at the largest Table-17 bucket
    function automatic logic [7:0] ret_inc(input logic [7:0] cur,
                                           input int unsigned add);
      int unsigned s;
      begin
        s = {24'b0, cur} + add;
        ret_inc = (s > CRED_MAX) ? CRED_MAX[7:0] : s[7:0];
      end
    endfunction

    always_comb begin
      n_wreq  = cr_wreq;
      n_rreq  = cr_rreq;
      n_wdata = cr_wdata;
      if (wreq_fire) n_wreq  = n_wreq  - WRITEREQ_GRAN[7:0];
      if (rreq_fire) n_rreq  = n_rreq  - READREQ_GRAN[7:0];
      if (wdat_fire) n_wdata = n_wdata - WRITEDATA_GRAN[7:0];
      if (drx_valid) begin
        n_wreq  = sat_add(n_wreq,  cred_decode(mc_wreq (rmc)), LCR_WREQ);
        n_rreq  = sat_add(n_rreq,  cred_decode(mc_rreq (rmc)), LCR_RREQ);
        n_wdata = sat_add(n_wdata, cred_decode(mc_wdata(rmc)), CR_WDATA);
      end
      // the request flit sent this cycle carried the OLD return-credit totals
      n_ret_rdata = req_fire ? 8'd0 : ret_rdata;
      n_ret_wresp = req_fire ? 8'd0 : ret_wresp;
      if (rsp_rd) n_ret_rdata = ret_inc(n_ret_rdata, READDATA_GRAN);
      if (rsp_wr) n_ret_wresp = ret_inc(n_ret_wresp, WRITERESP_GRAN);
      // ReadData granules in flight: charged at issue, released per beat.
      n_rd_out = rd_out;
      if (do_pop && !q_is_wr) n_rd_out = n_rd_out + rd_need;
      if (rsp_rd)             n_rd_out = n_rd_out - 16'(READDATA_GRAN);
    end

    // ---- sequential --------------------------------------------------------
    always_ff @(posedge clk or negedge rstn) begin
      if (!rstn) begin
        ostate   <= O_IDLE;
        id_q     <= '0; addr_q <= '0; len_q <= '0; size_q <= '0;
        burst_q  <= '0; prot_q <= '0; tag_q  <= '0;
        wdata_q  <= '0; wstrb_q <= '0; wbeat_valid <= 1'b0; wlast_q <= 1'b0;
        cr_wreq  <= '0; cr_rreq <= '0; cr_wdata <= '0;
        ret_rdata <= '0; ret_wresp <= '0; rd_out <= '0;
        cmpr_pend <= 1'b0; cmpr_tag <= '0;
        cmpw_pend <= 1'b0; cmpw_tag <= '0; cmpw_resp <= '0;
        r_id_q <= '0; r_vec_q <= '0; r_len_q <= '0; r_beat <= '0; r_busy <= 1'b0;
        b_id_q <= '0; b_resp_q <= '0; b_busy <= 1'b0;
        for (int i = 0; i < OOO_DEPTH; i++) begin
          acc[i]     <= '0;
          acc_cnt[i] <= '0;
          acc_len[i] <= '0;
        end
      end else begin
        // §8.2 DISABLED: discard granted credits; §6.4.3 seed re-grants them.
        if (act_disabled) begin
          cr_wreq <= '0; cr_rreq <= '0; cr_wdata <= '0;
        end else if (seed_valid) begin
          cr_wreq  <= sat_add(cr_wreq,  cred_decode(seed_wreq),  LCR_WREQ);
          cr_rreq  <= sat_add(cr_rreq,  cred_decode(seed_rreq),  LCR_RREQ);
          cr_wdata <= sat_add(cr_wdata, cred_decode(seed_wdata), CR_WDATA);
        end else begin
          cr_wreq <= n_wreq; cr_rreq <= n_rreq; cr_wdata <= n_wdata;
        end
        ret_rdata <= n_ret_rdata;
        ret_wresp <= n_ret_wresp;
        rd_out    <= n_rd_out;

        // ---- response collection (concurrent with issue) -------------------
        cmpr_pend <= 1'b0;
        cmpw_pend <= 1'b0;
        if (rsp_rd) begin
          if (acc_ok) begin
            acc[rsp_slot][cur_off +: EW] <= {rd_resp(rmsg),
                                             rd_full[AXI_DATA_W-1:0]};
            acc_len[rsp_slot] <= cur_cnt;
          end
          if (rsp_last) begin
            acc_cnt[rsp_slot] <= 8'd0;
            cmpr_pend         <= 1'b1;
            cmpr_tag          <= rsp_slot;
          end else if (acc_ok) begin
            acc_cnt[rsp_slot] <= cur_cnt + 8'd1;
          end
        end
        if (rsp_wr) begin
          cmpw_pend <= 1'b1;
          cmpw_tag  <= rsp_slot;
          cmpw_resp <= wrsp_resp(rmsg);
        end

        // ---- AXI R output stage ------------------------------------------
        if (!r_busy) begin
          if (r_out_valid) begin
            r_id_q  <= r_out_id;
            r_vec_q <= r_out_data[RVEC_W-1:0];
            r_len_q <= r_out_data[RDAT_W-1 -: 8];
            r_beat  <= 8'd0;
            r_busy  <= 1'b1;
          end
        end else if (s_rready) begin
          if (r_beat == r_len_q) r_busy <= 1'b0;
          else                   r_beat <= r_beat + 8'd1;
        end

        // ---- AXI B output stage ------------------------------------------
        if (!b_busy) begin
          if (w_out_valid) begin
            b_id_q   <= w_out_id;
            b_resp_q <= w_out_data;
            b_busy   <= 1'b1;
          end
        end else if (s_bready) begin
          b_busy <= 1'b0;
        end

        // ---- request FSM: issue and move on (no waiting for a response) ----
        unique case (ostate)
          O_IDLE: if (do_pop) begin
            id_q    <= q_id[q_head];    addr_q  <= q_addr[q_head];
            len_q   <= q_len[q_head];   size_q  <= q_size[q_head];
            burst_q <= q_burst[q_head]; prot_q  <= q_prot[q_head];
            tag_q   <= alloc_tag;
            if (q_is_wr) begin
              wbeat_valid <= 1'b0;
              ostate <= O_WREQ;
            end else begin
              ostate <= O_RREQ;
            end
          end
          O_WREQ: if (dtx_fire) ostate <= O_WDATA;
          O_WDATA: begin
            if (s_wvalid && s_wready) begin
              wdata_q <= s_wdata; wstrb_q <= s_wstrb; wlast_q <= s_wlast;
              wbeat_valid <= 1'b1;
            end
            if (dtx_fire) begin
              wbeat_valid <= 1'b0;
              if (wlast_q) ostate <= O_IDLE;
            end
          end
          O_RREQ: if (dtx_fire) ostate <= O_IDLE;
          // verilator coverage_off
          default: ostate <= O_IDLE;   // unreachable (all states enumerated)
          // verilator coverage_on
        endcase
      end
    end

  end
  endgenerate

endmodule
`endif
