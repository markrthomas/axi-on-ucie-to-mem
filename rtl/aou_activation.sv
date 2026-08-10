// -----------------------------------------------------------------------------
// aou_activation : §8 interface state management + §6.4.3 reset credit exchange.
//
// Sits between a bridge's data FSM and its flit link and brings the interface up
// before any credited (data) traffic is allowed:
//
//   DISABLED --(ActivateReq sent/received)--> ACTIVATE --(ActivateAck sent &
//   received & peer CrdtGrant received)--> ENABLED
//
// While not ENABLED this module OWNS the link: it drives the bring-up Misc
// messages (ActivateReq -> ActivateAck -> CrdtGrant, one flit each) and consumes
// the peer's, holding the data path off (d_tx_ready=0, d_rx_valid=0).  Once
// ENABLED it is a transparent pass-through so the bridge's data FSM drives the
// link directly.  The peer's CrdtGrant is decoded into a one-cycle `seed` pulse
// that the bridge uses to initialise its transmit credit counters (which reset
// to 0 per §8.4 DISABLED: "the transmitter has no credits").
//
// Ordering safety: this side only ENABLES after receiving the peer's CrdtGrant,
// which the in-order link guarantees arrives before any of the peer's data
// flits (CrdtGrant is the peer's last bring-up message).  So a data flit never
// reaches a still-activating receiver.
//
// Scope: bring-up only.  DEACTIVATE / ERROR (§8 teardown + error recovery) are a
// documented follow-on; `CrdtGrant` here also covers only resource plane RP0.
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

  typedef enum logic [1:0] { ACT_DISABLED, ACT_ACTIVATE, ACT_ENABLED } act_e;
  act_e state;

  logic req_sent, req_rcvd, ack_sent, ack_rcvd, crdt_sent, crdt_rcvd;

  assign enabled = (state == ACT_ENABLED);

  // --- bring-up TX: pick the next Misc message to send (priority order) -----
  wire send_req  = !req_sent;
  wire send_ack  = req_rcvd && !ack_sent;
  wire send_crdt = ack_sent && !crdt_sent;

  logic [PLP_BITS-1:0] act_tx_flit;
  logic                act_tx_valid;

  always_comb begin
    msg_t     m;
    payload_t pl;
    m            = '0;
    pl           = '0;
    act_tx_flit  = '0;
    act_tx_valid = 1'b0;
    if (!enabled) begin
      if (send_req) begin
        m  = mk_activate_req(5'b0, 5'b0, 16'b0);
        pl = payload_put('0, 0, ACTIVATEREQ_GRAN, m);
        act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
        act_tx_valid = 1'b1;
      end else if (send_ack) begin
        m  = mk_activation_other(ACTOP_ACTIVATE_ACK);
        pl = payload_put('0, 0, MISC_GRAN, m);
        act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
        act_tx_valid = 1'b1;
      end else if (send_crdt) begin
        m  = mk_crdtgrant(GRANT_WREQ, GRANT_RREQ, GRANT_WDATA, GRANT_RDATA, GRANT_WRESP);
        pl = payload_put('0, 0, CRDTGRANT_GRAN, m);
        act_tx_flit  = flit_assemble('0, msgstart_t'(1), pl);
        act_tx_valid = 1'b1;
      end
    end
  end

  // --- bring-up RX: classify the incoming Misc message ----------------------
  // Continuous assigns, NOT an always_comb: the message accessors do constant
  // part-selects, which under iverilog force the enclosing always_* process to
  // be "sensitive to all bits" of the wide (320b) `rm` it both writes and reads.
  // That self-referential wide process wedges iverilog's settle under cocotb's
  // VPI ReadWrite region (the pure-vvp SV TB tolerates it, cocotb does not).
  // Continuous assigns evaluate on their RHS nets directly and avoid it.
  msg_t                rm;
  logic                rx_is_req, rx_is_ack, rx_is_crdt;
  assign rm = payload_get(flit_payload(rx_data), 0, CRDTGRANT_GRAN);
  assign rx_is_req  = (get_msgtype(rm) == MT_MISC) && (misc_op(rm) == MISCOP_ACTIVATION)
                      && (misc_activationop(rm) == ACTOP_ACTIVATE_REQ);
  assign rx_is_ack  = (get_msgtype(rm) == MT_MISC) && (misc_op(rm) == MISCOP_ACTIVATION)
                      && (misc_activationop(rm) == ACTOP_ACTIVATE_ACK);
  assign rx_is_crdt = (get_msgtype(rm) == MT_MISC) && (misc_op(rm) == MISCOP_CRDTGRANT);

  // credit seed (decoded RP0 grant fields) — pulsed as the CrdtGrant is consumed
  assign seed_valid = rx_valid && !enabled && rx_is_crdt;
  assign seed_wreq  = cg_wreq0(rm);
  assign seed_rreq  = cg_rreq0(rm);
  assign seed_wdata = cg_wdata0(rm);
  assign seed_rdata = cg_rdata0(rm);
  assign seed_wresp = cg_wresp0(rm);

  // --- link / data-path mux -------------------------------------------------
  assign tx_data    = enabled ? d_tx_data  : act_tx_flit;
  assign tx_valid   = enabled ? d_tx_valid : act_tx_valid;
  assign d_tx_ready = enabled ? tx_ready   : 1'b0;
  assign rx_ready   = enabled ? d_rx_ready : 1'b1;   // bring-up always consumes
  assign d_rx_data  = rx_data;
  assign d_rx_valid = enabled ? rx_valid   : 1'b0;

  // --- state / handshake flags ----------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state     <= ACT_DISABLED;
      req_sent  <= 1'b0; req_rcvd <= 1'b0;
      ack_sent  <= 1'b0; ack_rcvd <= 1'b0;
      crdt_sent <= 1'b0; crdt_rcvd <= 1'b0;
    end else begin
      // sent-flags: which bring-up message went out this cycle
      if (!enabled && act_tx_valid && tx_ready) begin
        if      (send_req)  req_sent  <= 1'b1;
        else if (send_ack)  ack_sent  <= 1'b1;
        else if (send_crdt) crdt_sent <= 1'b1;
      end
      // received-flags
      if (!enabled && rx_valid) begin
        if (rx_is_req)  req_rcvd  <= 1'b1;
        if (rx_is_ack)  ack_rcvd  <= 1'b1;
        if (rx_is_crdt) crdt_rcvd <= 1'b1;
      end
      // state transitions (use registered flags; costs at most 1 cycle)
      case (state)
        ACT_DISABLED:
          if ((act_tx_valid && tx_ready && send_req) || (rx_valid && rx_is_req))
            state <= ACT_ACTIVATE;
        ACT_ACTIVATE:
          if (ack_sent && ack_rcvd && crdt_rcvd) state <= ACT_ENABLED;
        // verilator coverage_off
        default: state <= state;    // ENABLED is terminal in this build
        // verilator coverage_on
      endcase
    end
  end

endmodule
`endif
