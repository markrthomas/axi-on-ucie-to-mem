// -----------------------------------------------------------------------------
// aou_activation_fv : formal property harness for the §8 interface activation
//                     state machine (`rtl/aou_activation.sv`).
//
// The DUT is instantiated with EVERY external input left free: the 2000-bit
// received flit and its valid, the link back-pressure, the bridge-side data path
// (d_tx_*/d_rx_ready) and — crucially — the three IMPLEMENTATION_DEFINED control
// inputs `deact_trig` (§8.3.2 SW deactivate flag), `data_idle` (§8.3.2 Option-2
// quiesce report) and `err_clear` (§8.4 ERROR recovery).  The peer is therefore
// completely adversarial: it may inject any Misc message — ActivateReq,
// ActivateAck, CrdtGrant, DeactivateReq, DeactivateAck — or any data flit, at any
// time, in any state, and SW may pull the deactivate flag mid-transaction.
// Under that environment we prove the §8 activation invariants:
//
//   * NEVER ENABLED BEFORE CrdtGrant — the FSM cannot reach the data-transfer
//     ENABLED state before the §6.4.2 CrdtGrant / §6.4.3 reset-credit exchange it
//     depends on.  Proven twice, at two independent levels:
//       - FSM-level (aou_activation_props_fv, bound into the DUT): `enabled`
//         implies the RTL's own `crdt_rcvd` (and `aack_sent`/`aack_rcvd`) are set,
//         and the ENABLED entry edge is only taken out of ACTIVATE with all three
//         already high;
//       - link-level (aou_activation_fv below): an INDEPENDENT decoder watches
//         the raw rx flit stream and latches `ever_crdt` when a real §5.6.2
//         CrdtGrant is accepted; `enabled` implies `ever_crdt`.  This does not
//         trust any RTL internal — it re-derives "a CrdtGrant was received" from
//         the wire.
//
//   * NO PREMATURE DATA-TRANSFER ENABLE — the gate the bridges use to move a
//     data/message flit (`d_tx_ready` for TX, `d_rx_valid` for RX, and the
//     `quiescing` teardown qualifier) is never asserted outside ENABLED, and
//     while not ENABLED the flit this module drives onto the link is always a
//     §5.6 Misc Activation/CrdtGrant message — never a data message.  Because the
//     gate lives entirely inside `aou_activation` this is the tightest sound
//     scope; no bridge abstraction is needed.
//
//   * FSM SAFETY / LEGAL TRANSITIONS — the state register never holds an illegal
//     encoding, the `enabled`/`act_disabled`/`error` outputs agree with an
//     INDEPENDENT transcription of the Table-24 encoding, and every state change
//     is a member of the legal transition relation.  In particular DEACTIVATE is
//     entered only from ENABLED and only when either the peer's DeactivateReq is
//     being received or `data_idle` is high (the F3 Option-2 mechanism), and
//     `deact_pending` implies `quiescing` (and hence ENABLED).
//
//   * ERROR RECOVERY — ERROR is sticky until `err_clear` (§8.4), `err_clear`
//     always returns it to the defined DISABLED state, and that return leaves the
//     interface fully re-armed (every handshake flag clear), so the re-activation
//     must run the whole bring-up — including a fresh CrdtGrant — again.
//
//   * COVER TRACES — bring-up reaches ENABLED, teardown reaches DISABLED, the
//     ERROR path is reachable and recovers to DISABLED, Option-2 quiescing is
//     reachable, and a CrdtGrant really does pulse the credit seed.
//
// As in `formal/aou_credit_fv.sv`, the properties are stated as immediate
// assertions in a bound wrapper rather than as concurrent SVA, because
// yosys-slang rejects concurrent SVA ("SVA unsupported").  The WRAPPER shape is
// adjusted, never the property:
//     always @(posedge clk) if (rstn) assert (p);
// is exactly
//     assert property (@(posedge clk) disable iff (!rstn) p);
// and the one-cycle relations use explicitly registered "previous value" flops,
// which is exactly what `$past()` elaborates to.
//
// Read with yosys-slang (`plugin -i slang; read_slang`): the RTL uses the
// `module <name> import aou_pkg::*;` header form and `bind`, neither of which the
// stock yosys Verilog frontend accepts.
//
// Formal-only file — no RTL or simulation source is modified by it.
// -----------------------------------------------------------------------------
`default_nettype none

// =============================================================================
// §8 activation-FSM checker.  Bound into aou_activation, so it sees the state
// register and the bring-up / teardown handshake flags directly.
// =============================================================================
module aou_activation_props_fv
  import aou_pkg::*;
(
    input logic                clk,
    input logic                rstn,
    // state register + Table-24 status outputs
    input logic [2:0]          state,
    input logic                enabled,
    input logic                act_disabled,
    input logic                error,
    input logic                quiescing,
    input logic                deact_pending,
    // bring-up / teardown handshake flags
    input logic                areq_sent,
    input logic                areq_rcvd,
    input logic                aack_sent,
    input logic                aack_rcvd,
    input logic                crdt_sent,
    input logic                crdt_rcvd,
    input logic                dreq_sent,
    input logic                dreq_rcvd,
    input logic                dack_sent,
    input logic                dack_rcvd,
    // control inputs
    input logic                deact_trig,
    input logic                data_idle,
    input logic                err_clear,
    // link + data-path gating
    input logic [PLP_BITS-1:0] tx_data,
    input logic                tx_valid,
    input logic                rx_valid,
    input logic                rx_is_dreq,
    input logic                d_tx_ready,
    input logic                d_rx_valid,
    input logic                seed_valid
);

  // --- independent transcription of the Table-24 state encoding --------------
  // Deliberately restated here (not imported from the DUT's `act_e`) so the
  // status-output assertions below actually check the RTL's decode.
  localparam logic [2:0] S_DISABLED   = 3'd0;
  localparam logic [2:0] S_ACTIVATE   = 3'd1;
  localparam logic [2:0] S_ENABLED    = 3'd2;
  localparam logic [2:0] S_DEACTIVATE = 3'd3;
  localparam logic [2:0] S_ERROR      = 3'd4;

  // --- independent decode of the flit this module drives onto the link -------
  // (continuous assigns, as in the RTL: the accessors are constant part-selects)
  msg_t                tm;
  logic [MSGTYPE_W-1:0] tx_mt;
  logic [MISCOP_W-1:0]  tx_mop;
  assign tm     = payload_get(flit_payload(tx_data), 0, CRDTGRANT_GRAN);
  assign tx_mt  = get_msgtype(tm);
  assign tx_mop = misc_op(tm);

  // --- registered previous values (== $past under `disable iff (!rstn)`) -----
  logic [2:0] p_state;
  logic       p_seen;          // the previous cycle was a post-reset cycle
  logic       p_peer_dreq;     // a peer DeactivateReq was being consumed
  logic       p_err_clear;
  logic       p_data_idle;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      p_state     <= S_DISABLED;
      p_seen      <= 1'b0;
      p_peer_dreq <= 1'b0;
      p_err_clear <= 1'b0;
      p_data_idle <= 1'b0;
    end else begin
      p_state     <= state;
      p_seen      <= 1'b1;
      p_peer_dreq <= rx_valid && rx_is_dreq;
      p_err_clear <= err_clear;
      p_data_idle <= data_idle;
    end
  end

  // ==========================================================================
  // 1. State encoding + status-output agreement
  // ==========================================================================
  always @(posedge clk) if (rstn) begin
    // the register never holds an out-of-Table-24 encoding
    assert (state == S_DISABLED || state == S_ACTIVATE || state == S_ENABLED ||
            state == S_DEACTIVATE || state == S_ERROR);
    // the exported status bits are exactly the Table-24 states
    assert (enabled      == (state == S_ENABLED));
    assert (act_disabled == (state == S_DISABLED));
    assert (error        == (state == S_ERROR));
    // ...and they are mutually exclusive
    assert (!(enabled && act_disabled));
    assert (!(enabled && error));
    assert (!(act_disabled && error));
  end

  // ==========================================================================
  // 2. NEVER ENABLED BEFORE CrdtGrant  (§6.4.2 / §6.4.3 ordering)
  // ==========================================================================
  always @(posedge clk) if (rstn) begin
    // the whole activate exchange must have completed to be ENABLED, and the
    // peer's CrdtGrant is part of it
    assert (!enabled || crdt_rcvd);
    assert (!enabled || (aack_sent && aack_rcvd));
    assert (!enabled || (areq_sent && areq_rcvd));
  end
  always @(posedge clk) if (rstn && p_seen) begin
    // the ENABLED entry edge is only ever taken out of ACTIVATE, and only with
    // the CrdtGrant (and both Acks) already banked in the *previous* cycle
    assert (!(enabled && (p_state != S_ENABLED)) || (p_state == S_ACTIVATE));
  end

  // ==========================================================================
  // 3. NO PREMATURE DATA-TRANSFER ENABLE
  // ==========================================================================
  always @(posedge clk) if (rstn) begin
    // the bridge-side data path is gated shut outside ENABLED, in both
    // directions...
    assert (!d_tx_ready || enabled);
    assert (!d_rx_valid || enabled);
    // ...and so is the Option-2 teardown qualifier the bridge throttles on
    assert (!quiescing || enabled);
    assert (!deact_pending || enabled);
    // while this module owns the link it only ever transmits a §5.6 Misc
    // Activation / CrdtGrant message — never a data or WriteResp message
    assert (!(tx_valid && !enabled) || (tx_mt == MT_MISC));
    assert (!(tx_valid && !enabled) ||
            (tx_mop == MISCOP_ACTIVATION) || (tx_mop == MISCOP_CRDTGRANT));
    // ERROR (§8.3.3) transmits nothing at all
    assert (!error || !tx_valid);
    // credits are never (re-)seeded once the data path is live
    assert (!seed_valid || !enabled);
  end

  // ==========================================================================
  // 4. FSM safety: only legal transitions
  // ==========================================================================
  always @(posedge clk) if (rstn && p_seen) begin
    assert (
      (p_state == S_DISABLED   && (state == S_DISABLED   || state == S_ACTIVATE)) ||
      (p_state == S_ACTIVATE   && (state == S_ACTIVATE   || state == S_ENABLED ||
                                   state == S_ERROR))                            ||
      (p_state == S_ENABLED    && (state == S_ENABLED    || state == S_DEACTIVATE ||
                                   state == S_ERROR))                            ||
      (p_state == S_DEACTIVATE && (state == S_DEACTIVATE || state == S_DISABLED ||
                                   state == S_ERROR))                            ||
      (p_state == S_ERROR      && (state == S_ERROR      || state == S_DISABLED)));

    // teardown is entered ONLY from ENABLED ...
    assert (!(state == S_DEACTIVATE && p_state != S_DEACTIVATE) ||
            (p_state == S_ENABLED));
    // ... and only once the peer asked for it, or the F3 Option-2 gate said the
    // data path had drained.  A SW `deact_trig` alone can never tear the link
    // down mid-transaction.
    assert (!(p_state == S_ENABLED && state == S_DEACTIVATE) ||
            p_peer_dreq || p_data_idle);
    // DISABLED is only ever reached from a completed teardown or ERROR recovery
    assert (!(state == S_DISABLED && p_state != S_DISABLED) ||
            (p_state == S_DEACTIVATE) || (p_state == S_ERROR));
  end

  // ==========================================================================
  // 5. §8.3.2 Option-2 quiescing
  // ==========================================================================
  always @(posedge clk) if (rstn) begin
    // a latched SW deactivate intent always shows up as `quiescing`, which is
    // what makes the bridge stop accepting new AXI requests
    assert (!deact_pending || quiescing);
    assert (!quiescing || deact_pending);
  end
  always @(posedge clk) if (rstn && p_seen) begin
    // while quiescing with the data path still busy and no peer request, the
    // interface HOLDS in ENABLED — in-flight data is allowed to drain
    assert (!(p_state == S_ENABLED && !p_data_idle && !p_peer_dreq) ||
            (state == S_ENABLED) || (state == S_ERROR));
  end

  // ==========================================================================
  // 6. §8.3.3 / §8.4 ERROR recovery
  // ==========================================================================
  always @(posedge clk) if (rstn && p_seen) begin
    // ERROR is sticky until err_clear ...
    assert (!(p_state == S_ERROR && !p_err_clear) || (state == S_ERROR));
    // ... and err_clear always returns it to the defined DISABLED state
    assert (!(p_state == S_ERROR && p_err_clear) || (state == S_DISABLED));
    // the recovered interface is fully re-armed: every bring-up/teardown flag is
    // clear, so a re-activation must redo the whole exchange (CrdtGrant included)
    assert (!(p_state == S_ERROR && state == S_DISABLED) ||
            (!areq_sent && !areq_rcvd && !aack_sent && !aack_rcvd &&
             !crdt_sent && !crdt_rcvd && !dreq_sent && !dreq_rcvd &&
             !dack_sent && !dack_rcvd));
    // a completed teardown likewise re-arms the bring-up handshake
    assert (!(p_state == S_DEACTIVATE && state == S_DISABLED) ||
            (!areq_sent && !areq_rcvd && !aack_sent && !aack_rcvd && !crdt_rcvd));
  end

  // ==========================================================================
  // 7. Reachability
  // ==========================================================================
  logic was_enabled, was_error, was_deact;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      was_enabled <= 1'b0; was_error <= 1'b0; was_deact <= 1'b0;
    end else begin
      if (state == S_ENABLED)    was_enabled <= 1'b1;
      if (state == S_ERROR)      was_error   <= 1'b1;
      if (state == S_DEACTIVATE) was_deact   <= 1'b1;
    end
  end

  always @(posedge clk) if (rstn) begin
    cover (enabled);                          // bring-up reaches ENABLED
    cover (seed_valid);                       // a CrdtGrant seeds the credits
    cover (quiescing);                        // Option-2 drain is reachable
    cover (was_enabled && (state == S_DEACTIVATE));  // teardown starts
    cover (was_deact && act_disabled);        // teardown reaches DISABLED
    cover (error);                            // §8.3.3 ERROR is reachable
    cover (was_error && act_disabled);        // ERROR recovers to DISABLED
  end
endmodule

// =============================================================================
// Formal top: the activation FSM alone, every input free.  The FSM's behaviour
// does not depend on the GRANT_* parameters (they only select the credit codes
// placed in the CrdtGrant this endpoint emits), so one instance — parameterised
// exactly like the §6 target bridge — covers both real instantiations.
// =============================================================================
module aou_activation_fv
  import aou_pkg::*;
(
    input wire                clk,
    // ---- adversarial peer on the flit link ---------------------------------
    input wire                tx_ready,
    input wire [PLP_BITS-1:0] rx_data,
    input wire                rx_valid,
    // ---- free bridge-side data path ----------------------------------------
    input wire [PLP_BITS-1:0] d_tx_data,
    input wire                d_tx_valid,
    input wire                d_rx_ready,
    // ---- free IMPLEMENTATION_DEFINED controls (§8.3.2 / §8.4) --------------
    input wire                deact_trig,
    input wire                data_idle,
    input wire                err_clear
);

  // --- internally generated reset: low at step 0, high thereafter -----------
  logic rst_done = 1'b0;
  always @(posedge clk) rst_done <= 1'b1;
  wire rstn = rst_done;

  /* verilator lint_off UNUSEDSIGNAL */
  wire                  enabled, act_disabled, error, quiescing;
  wire [PLP_BITS-1:0]   tx_data;
  wire                  tx_valid, rx_ready;
  wire [PLP_BITS-1:0]   d_rx_data;
  wire                  d_tx_ready, d_rx_valid;
  wire                  seed_valid;
  wire [2:0]            seed_wreq, seed_rreq, seed_wdata, seed_rdata;
  wire [1:0]            seed_wresp;
  /* verilator lint_on UNUSEDSIGNAL */

  aou_activation #(
    .GRANT_WREQ(3'b010), .GRANT_RREQ(3'b010), .GRANT_WDATA(3'b111)
  ) u_act (
    .clk(clk), .rstn(rstn),
    .enabled(enabled), .act_disabled(act_disabled), .error(error),
    .deact_trig(deact_trig), .data_idle(data_idle), .quiescing(quiescing),
    .err_clear(err_clear),
    .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
    .rx_data(rx_data), .rx_valid(rx_valid), .rx_ready(rx_ready),
    .d_tx_data(d_tx_data), .d_tx_valid(d_tx_valid), .d_tx_ready(d_tx_ready),
    .d_rx_data(d_rx_data), .d_rx_valid(d_rx_valid), .d_rx_ready(d_rx_ready),
    .seed_valid(seed_valid), .seed_wreq(seed_wreq), .seed_rreq(seed_rreq),
    .seed_wdata(seed_wdata), .seed_rdata(seed_rdata), .seed_wresp(seed_wresp)
  );

  // ==========================================================================
  // Link-level "never ENABLED before CrdtGrant".
  //
  // This decoder does NOT look at any DUT internal: it re-derives "the peer's
  // §5.6.2 CrdtGrant was accepted on this interface" straight from the raw flit
  // wire, and latches it.  Proving `enabled -> ever_crdt` therefore proves the
  // §6.4.2/§6.4.3 ordering independently of the FSM's own bookkeeping flags.
  // ==========================================================================
  msg_t rm_mon;
  logic rx_crdt;
  assign rm_mon  = payload_get(flit_payload(rx_data), 0, CRDTGRANT_GRAN);
  assign rx_crdt = (get_msgtype(rm_mon) == MT_MISC) &&
                   (misc_op(rm_mon) == MISCOP_CRDTGRANT);
  wire  rx_accept = rx_valid && rx_ready;

  logic ever_crdt;
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn)                    ever_crdt <= 1'b0;
    else if (rx_accept && rx_crdt) ever_crdt <= 1'b1;
  end

  always @(posedge clk) if (rstn) begin
    assert (!enabled || ever_crdt);
    // the credit seed pulse is only ever produced by a real CrdtGrant flit
    assert (!seed_valid || (rx_valid && rx_crdt));
  end

endmodule

// =============================================================================
// Property bind.
// =============================================================================
bind aou_activation aou_activation_props_fv u_act_fv (
  .clk(clk), .rstn(rstn),
  .state(state), .enabled(enabled), .act_disabled(act_disabled), .error(error),
  .quiescing(quiescing), .deact_pending(deact_pending),
  .areq_sent(areq_sent), .areq_rcvd(areq_rcvd),
  .aack_sent(aack_sent), .aack_rcvd(aack_rcvd),
  .crdt_sent(crdt_sent), .crdt_rcvd(crdt_rcvd),
  .dreq_sent(dreq_sent), .dreq_rcvd(dreq_rcvd),
  .dack_sent(dack_sent), .dack_rcvd(dack_rcvd),
  .deact_trig(deact_trig), .data_idle(data_idle), .err_clear(err_clear),
  .tx_data(tx_data), .tx_valid(tx_valid),
  .rx_valid(rx_valid), .rx_is_dreq(rx_is_dreq),
  .d_tx_ready(d_tx_ready), .d_rx_valid(d_rx_valid),
  .seed_valid(seed_valid)
);

`default_nettype wire
