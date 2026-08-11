// -----------------------------------------------------------------------------
// aou_activation : §8 interface state management + §6.4.3 reset credit exchange.
//
// Sits between a bridge's data FSM and its flit link and manages the five §8
// activity states (Table 24):
//
//   DISABLED --(ActivateReq sent/rcvd)--> ACTIVATE
//            --(ActivateAck sent&rcvd & peer CrdtGrant rcvd)--> ENABLED
//            --(DeactivateReq sent/rcvd)--> DEACTIVATE
//            --(DeactivateAck sent&rcvd)--> DISABLED (re-activates as usual)
//   any --(inconsistent Activate/Deactivate Req)--> ERROR --(err_clear)--> DISABLED
//
// While not ENABLED this module OWNS the link: it drives the bring-up / teardown
// Misc messages (ActivateReq -> ActivateAck -> CrdtGrant, and DeactivateReq ->
// DeactivateAck) and consumes the peer's, holding the data path off
// (d_tx_ready=0, d_rx_valid=0).  Once ENABLED it is a transparent pass-through.
// The peer's CrdtGrant is decoded into a one-cycle `seed` pulse that initialises
// the bridge's transmit credit counters (which reset to 0 per §8.4 DISABLED:
// "the transmitter has no credits"); `act_disabled` re-zeroes them each time the
// interface returns to DISABLED, so a later re-activation re-seeds from scratch
// (§8.2: "discards all previously received protocol-level credits").
//
// Deactivate is triggered by `deact_trig` (§8.3.2: "System Software writing a
// flag in the AoU bridge").  Only Option 1 (§8.3.2, MANDATORY) is modelled: the
// bridge asserts `deact_trig` only once the link is quiesced, so DEACTIVATE has
// no pending Data/WriteResp to drain and the module can own the link for the
// teardown handshake.  Option 2 (hardware quiescing) is a documented follow-on.
//
// ERROR (§8.3.3): entered when an inconsistent link-state Req is received (e.g.
// an ActivateReq while ENABLED, or a DeactivateReq while DISABLED).  In ERROR no
// message is transmitted and received messages are ignored (consumed/dropped);
// `err_clear` (IMPLEMENTATION_DEFINED, §8.4) returns the state to DISABLED, from
// which the interface re-initialises as usual.
//
// Ordering safety: this side only ENABLES after receiving the peer's CrdtGrant,
// which the in-order link guarantees arrives before any of the peer's data
// flits (CrdtGrant is the peer's last bring-up message).  So a data flit never
// reaches a still-activating receiver.
//
// Scope: CrdtGrant covers resource plane RP0.
// -----------------------------------------------------------------------------
`ifndef AOU_ACTIVATION_SV
`define AOU_ACTIVATION_SV

module aou_activation
  import aou_pkg::*;
#(
    // Table-17 credit codes THIS endpoint grants to the peer (for the message
    // types it receives).  Initiator grants ReadData/WriteResp; target grants
    // WriteReq/ReadReq/WriteData.  Unused types are 0.
    parameter logic [2:0] GRANT_WREQ  = 3'b000,
    parameter logic [2:0] GRANT_RREQ  = 3'b000,
    parameter logic [2:0] GRANT_WDATA = 3'b000,
    parameter logic [2:0] GRANT_RDATA = 3'b000,
    parameter logic [1:0] GRANT_WRESP = 2'b00
) (
    input  logic                clk,
    input  logic                rstn,
    output logic                enabled,           // ENABLED (data traffic ok)
    output logic                act_disabled,      // DISABLED (credit-reset qual)
    output logic                error,             // ERROR state
    input  logic                deact_trig,        // §8.3.2 SW deactivate flag
    input  logic                err_clear,         // §8.4 ERROR->DISABLED trigger
    // physical flit link (owned by this module until ENABLED)
    output logic [PLP_BITS-1:0] tx_data,
    output logic                tx_valid,
    input  logic                tx_ready,
    input  logic [PLP_BITS-1:0] rx_data,
    input  logic                rx_valid,
    output logic                rx_ready,
    // data path (bridge FSM), muxed onto the link when ENABLED
    input  logic [PLP_BITS-1:0] d_tx_data,
    input  logic                d_tx_valid,
    output logic                d_tx_ready,
    output logic [PLP_BITS-1:0] d_rx_data,
    output logic                d_rx_valid,
    input  logic                d_rx_ready,
    // credit seeding to the bridge (one-cycle pulse on peer CrdtGrant)
    output logic                seed_valid,
    output logic [2:0]          seed_wreq,
    output logic [2:0]          seed_rreq,
    output logic [2:0]          seed_wdata,
    output logic [2:0]          seed_rdata,
    output logic [1:0]          seed_wresp
);

  typedef enum logic [2:0] {
    ACT_DISABLED, ACT_ACTIVATE, ACT_ENABLED, ACT_DEACTIVATE, ACT_ERROR
  } act_e;
  act_e state;

  // activate-phase / deactivate-phase handshake flags
  logic areq_sent, areq_rcvd, aack_sent, aack_rcvd, crdt_sent, crdt_rcvd;
  logic dreq_sent, dreq_rcvd, dack_sent, dack_rcvd;

  assign enabled      = (state == ACT_ENABLED);
  assign act_disabled = (state == ACT_DISABLED);
  assign error        = (state == ACT_ERROR);

  wire in_bringup = (state == ACT_DISABLED) || (state == ACT_ACTIVATE);

  // --- bring-up / teardown TX: pick the next Misc message (priority order) ---
  wire send_areq = in_bringup && !areq_sent;
  wire send_aack = in_bringup && areq_rcvd && !aack_sent;
  wire send_crdt = in_bringup && aack_sent && !crdt_sent;
  wire send_dreq = (state == ACT_DEACTIVATE) && !dreq_sent;
  wire send_dack = (state == ACT_DEACTIVATE) && dreq_rcvd && !dack_sent;

  logic [PLP_BITS-1:0] act_tx_flit;
  logic                act_tx_valid;

  always_comb begin
    msg_t     m;
    payload_t pl;
    m            = '0;
    pl           = '0;
    act_tx_flit  = '0;
    act_tx_valid = 1'b0;
    if (send_areq) begin
      m  = mk_activate_req(5'b0, 5'b0, 16'b0);
      pl = payload_put('0, 0, ACTIVATEREQ_GRAN, m);
      act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
      act_tx_valid = 1'b1;
    end else if (send_aack) begin
      m  = mk_activation_other(ACTOP_ACTIVATE_ACK);
      pl = payload_put('0, 0, MISC_GRAN, m);
      act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
      act_tx_valid = 1'b1;
    end else if (send_crdt) begin
      m  = mk_crdtgrant(GRANT_WREQ, GRANT_RREQ, GRANT_WDATA, GRANT_RDATA, GRANT_WRESP);
      pl = payload_put('0, 0, CRDTGRANT_GRAN, m);
      act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
      act_tx_valid = 1'b1;
    // teardown TX is exercised by dv/act, not the full-chain coverage harness
    // (which ties deact_trig/err_clear low) — see the coverage note at the FSM.
    // verilator coverage_off
    end else if (send_dreq) begin
      m  = mk_activation_other(ACTOP_DEACTIVATE_REQ);
      pl = payload_put('0, 0, MISC_GRAN, m);
      act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
      act_tx_valid = 1'b1;
    end else if (send_dack) begin
      m  = mk_activation_other(ACTOP_DEACTIVATE_ACK);
      pl = payload_put('0, 0, MISC_GRAN, m);
      act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
      act_tx_valid = 1'b1;
    end
    // verilator coverage_on
  end

  // --- RX: classify the incoming Misc message -------------------------------
  // Continuous assigns, NOT an always_comb: the message accessors do constant
  // part-selects, which under iverilog force the enclosing always_* process to
  // be "sensitive to all bits" of the wide (320b) `rm` it both writes and reads.
  // That self-referential wide process wedges iverilog's settle under cocotb's
  // VPI ReadWrite region (the pure-vvp SV TB tolerates it, cocotb does not).
  // Continuous assigns evaluate on their RHS nets directly and avoid it.
  msg_t rm;
  logic rx_misc_act, rx_is_areq, rx_is_aack, rx_is_dreq, rx_is_dack, rx_is_crdt;
  assign rm          = payload_get(flit_payload(rx_data), 0, CRDTGRANT_GRAN);
  assign rx_misc_act = (get_msgtype(rm) == MT_MISC) && (misc_op(rm) == MISCOP_ACTIVATION);
  assign rx_is_areq  = rx_misc_act && (misc_activationop(rm) == ACTOP_ACTIVATE_REQ);
  assign rx_is_aack  = rx_misc_act && (misc_activationop(rm) == ACTOP_ACTIVATE_ACK);
  assign rx_is_dreq  = rx_misc_act && (misc_activationop(rm) == ACTOP_DEACTIVATE_REQ);
  assign rx_is_dack  = rx_misc_act && (misc_activationop(rm) == ACTOP_DEACTIVATE_ACK);
  assign rx_is_crdt  = (get_msgtype(rm) == MT_MISC) && (misc_op(rm) == MISCOP_CRDTGRANT);

  // §8.3.3 inconsistent link-state Req -> ERROR.  Only the unambiguous cases are
  // flagged (ActivateReq while active, DeactivateReq while inactive); a stray
  // Ack racing a state change is tolerated rather than mis-flagged.
  wire err_now = rx_valid && (
      (rx_is_areq && ((state == ACT_ENABLED)  || (state == ACT_DEACTIVATE))) ||
      (rx_is_dreq && ((state == ACT_DISABLED) || (state == ACT_ACTIVATE))));

  // credit seed (decoded RP0 grant fields) — pulsed as the CrdtGrant is consumed
  assign seed_valid = rx_valid && !enabled && (state != ACT_ERROR) && rx_is_crdt;
  assign seed_wreq  = cg_wreq0(rm);
  assign seed_rreq  = cg_rreq0(rm);
  assign seed_wdata = cg_wdata0(rm);
  assign seed_rdata = cg_rdata0(rm);
  assign seed_wresp = cg_wresp0(rm);

  // --- link / data-path mux -------------------------------------------------
  // ERROR transmits nothing (act_tx_valid is already 0 there); every non-ENABLED
  // state consumes RX (rx_ready=1) so an ignored/dropped message never stalls.
  assign tx_data    = enabled ? d_tx_data  : act_tx_flit;
  assign tx_valid   = enabled ? d_tx_valid : act_tx_valid;
  assign d_tx_ready = enabled ? tx_ready   : 1'b0;
  assign rx_ready   = enabled ? d_rx_ready : 1'b1;
  assign d_rx_data  = rx_data;
  assign d_rx_valid = enabled ? rx_valid   : 1'b0;

  wire tx_fire = act_tx_valid && tx_ready && !enabled;

  // --- state / handshake flags ----------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state     <= ACT_DISABLED;
      areq_sent <= 1'b0; areq_rcvd <= 1'b0;
      aack_sent <= 1'b0; aack_rcvd <= 1'b0;
      crdt_sent <= 1'b0; crdt_rcvd <= 1'b0;
      dreq_sent <= 1'b0; dreq_rcvd <= 1'b0;
      dack_sent <= 1'b0; dack_rcvd <= 1'b0;
    end else begin
      // sent-flags: which Misc message went out this cycle.
      // NOTE: the DEACTIVATE / ERROR paths below are unreachable in the
      // full-chain coverage harness (deact_trig/err_clear are tied low there)
      // and are instead verified by dv/act, so they carry `verilator
      // coverage_off` to keep the line-coverage floor meaningful.
      if (tx_fire) begin
        if      (send_areq) areq_sent <= 1'b1;
        else if (send_aack) aack_sent <= 1'b1;
        else if (send_crdt) crdt_sent <= 1'b1;
        // verilator coverage_off
        else if (send_dreq) dreq_sent <= 1'b1;
        else if (send_dack) dack_sent <= 1'b1;
        // verilator coverage_on
      end
      // received-flags (ignored entirely in ERROR)
      if (rx_valid && (state != ACT_ERROR)) begin
        if (rx_is_areq && in_bringup)                          areq_rcvd <= 1'b1;
        if (rx_is_aack && (state == ACT_ACTIVATE))             aack_rcvd <= 1'b1;
        if (rx_is_crdt && (state == ACT_ACTIVATE))             crdt_rcvd <= 1'b1;
        // verilator coverage_off
        if (rx_is_dreq && ((state == ACT_ENABLED) ||
                           (state == ACT_DEACTIVATE)))         dreq_rcvd <= 1'b1;
        if (rx_is_dack && (state == ACT_DEACTIVATE))           dack_rcvd <= 1'b1;
        // verilator coverage_on
      end
      // state transitions (registered flags; clearing on entry re-arms a phase)
      case (state)
        ACT_DISABLED:
          if ((tx_fire && send_areq) || (rx_valid && rx_is_areq))
            state <= ACT_ACTIVATE;
        ACT_ACTIVATE: begin
          // verilator coverage_off
          if (err_now) state <= ACT_ERROR;
          else
          // verilator coverage_on
          if (aack_sent && aack_rcvd && crdt_rcvd) begin
            state     <= ACT_ENABLED;
            dreq_sent <= 1'b0; dreq_rcvd <= 1'b0;   // arm a future teardown
            dack_sent <= 1'b0; dack_rcvd <= 1'b0;
          end
        end
        // The ENABLED->DEACTIVATE->DISABLED teardown and the ERROR state are
        // driven only via deact_trig / err_clear / inconsistent-Req detection,
        // none of which the full-chain coverage harness stimulates (dv/act does).
        // verilator coverage_off
        ACT_ENABLED: begin
          if (err_now) state <= ACT_ERROR;
          else if (deact_trig || (rx_valid && rx_is_dreq))
            state <= ACT_DEACTIVATE;
        end
        ACT_DEACTIVATE: begin
          if (err_now) state <= ACT_ERROR;
          else if (dack_sent && dack_rcvd) begin
            state     <= ACT_DISABLED;
            areq_sent <= 1'b0; areq_rcvd <= 1'b0;   // re-arm bring-up
            aack_sent <= 1'b0; aack_rcvd <= 1'b0;
            crdt_sent <= 1'b0; crdt_rcvd <= 1'b0;
          end
        end
        ACT_ERROR:
          if (err_clear) begin
            state     <= ACT_DISABLED;
            areq_sent <= 1'b0; areq_rcvd <= 1'b0;
            aack_sent <= 1'b0; aack_rcvd <= 1'b0;
            crdt_sent <= 1'b0; crdt_rcvd <= 1'b0;
            dreq_sent <= 1'b0; dreq_rcvd <= 1'b0;
            dack_sent <= 1'b0; dack_rcvd <= 1'b0;
          end
        default: state <= state;
        // verilator coverage_on
      endcase
    end
  end

endmodule
`endif
