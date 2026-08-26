// -----------------------------------------------------------------------------
// tb_aou_act : directed unit test for the §8 activation state machine.
//
// Drives a single aou_activation instance and plays its link partner by hand
// (feeding the Misc messages the peer would send and accepting every tx flit),
// so every §8 state transition is reachable deterministically:
//
//   * bring-up      DISABLED -> ACTIVATE -> ENABLED (ActivateReq/Ack + CrdtGrant,
//                   including the decoded credit seed pulse);
//   * teardown      ENABLED -> DEACTIVATE -> DISABLED, both SW-triggered
//                   (deact_trig) and peer-initiated (received DeactivateReq);
//   * quiescing     §8.3.2 Option 2 — deact_trig asserted mid-transaction is
//                   held (quiescing raised) until data_idle, then tears down;
//   * re-activation  DISABLED -> ... -> ENABLED again after each teardown;
//   * error          inconsistent ActivateReq while ENABLED -> ERROR (tx silent,
//                   rx ignored) -> DISABLED via err_clear.
//
// Self-checking; prints "[ACT-TB] PASS: <n> checks, 0 errors".  Runs under both
// Icarus and Verilator (see the Makefile).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_aou_act
  import aou_pkg::*;
;
  // Shared DV-only flit decoder + VERBOSE=0|1|2 logging helpers.  Included in
  // the TB only (never in rtl/); at VERBOSE=0 nothing is emitted.
  `include "aou_flit_log.svh"

  logic clk;
  logic rstn;
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Dev-only waveform dump (compiled ONLY under -DAOU_WAVES; never on the gate).
  `include "aou_wave_dump.svh"

  // DUT link + data-path signals
  logic                enabled, act_disabled, error;
  logic                deact_trig, err_clear;
  logic                data_idle, quiescing;
  logic [PLP_BITS-1:0] tx_data;
  logic                tx_valid;
  logic                tx_ready;
  logic [PLP_BITS-1:0] rx_data;
  logic                rx_valid;
  logic                rx_ready;
  logic [PLP_BITS-1:0] d_tx_data;
  logic                d_tx_valid;
  logic                d_tx_ready;
  logic [PLP_BITS-1:0] d_rx_data;
  logic                d_rx_valid;
  logic                d_rx_ready;
  logic                seed_valid;
  logic [2:0]          seed_wreq, seed_rreq, seed_wdata, seed_rdata;
  logic [1:0]          seed_wresp;

  // This endpoint grants these Table-17 codes (arbitrary, for the TB).
  localparam logic [2:0] G_WREQ  = 3'b010;
  localparam logic [2:0] G_RREQ  = 3'b011;
  localparam logic [2:0] G_WDATA = 3'b100;
  localparam logic [2:0] G_RDATA = 3'b001;
  localparam logic [1:0] G_WRESP = 2'b01;

  aou_activation #(
    .GRANT_WREQ(G_WREQ), .GRANT_RREQ(G_RREQ), .GRANT_WDATA(G_WDATA),
    .GRANT_RDATA(G_RDATA), .GRANT_WRESP(G_WRESP)
  ) dut (
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

  int checks = 0, errors = 0;
  task automatic chk(input logic cond, input string what);
    checks++;
    if (cond !== 1'b1) begin
      errors++;
      $display("[ACT-TB] CHECK FAILED: %s", what);
    end
    // level 1: per-check detail behind the [ACT-TB] PASS count.
    if (aou_lvl >= 1)
      aou_emit($sformatf("[ACT-TB][C] %s check %0d: %s",
                         (cond === 1'b1) ? "ok  " : "FAIL", checks, what));
  endtask

  function automatic logic [PLP_BITS-1:0] mkflit(input msg_t m, input int gran);
    mkflit = flit_assemble('0, msgstart_t'(1), payload_put('0, 0, gran, m));
  endfunction

  // one-cycle drive of a peer Misc message onto rx (rx_ready is 1 while the DUT
  // is not ENABLED, so it is consumed in the single posedge between the edges)
  task automatic feed(input msg_t m, input int gran);
    @(negedge clk); rx_valid = 1'b1; rx_data = mkflit(m, gran);
    @(negedge clk); rx_valid = 1'b0; rx_data = '0;
  endtask

  // feed a CrdtGrant and check the DUT decodes it into the seed pulse
  task automatic feed_crdt(input logic [2:0] w, r, wd, rd, input logic [1:0] wr);
    msg_t m;
    m = mk_crdtgrant(w, r, wd, rd, wr);
    @(negedge clk); rx_valid = 1'b1; rx_data = mkflit(m, CRDTGRANT_GRAN);
    #1;
    chk(seed_valid === 1'b1, "seed_valid pulses on CrdtGrant");
    chk(seed_wreq  === w && seed_rreq  === r  && seed_wdata === wd &&
        seed_rdata === rd && seed_wresp === wr, "seed fields decode from CrdtGrant");
    @(negedge clk); rx_valid = 1'b0; rx_data = '0;
  endtask

  task automatic ticks(input int n);
    for (int i = 0; i < n; i++) @(negedge clk);
  endtask

  // full DISABLED -> ENABLED bring-up (DUT sends its own req/ack/crdt; we feed
  // the peer's).  Leaves the DUT ENABLED.
  task automatic bring_up;
    ticks(2);                                       // DUT emits ActivateReq -> ACTIVATE
    feed(mk_activate_req(5'b0, 5'b0, 16'b0), ACTIVATEREQ_GRAN);
    ticks(1);                                       // DUT emits ActivateAck
    feed(mk_activation_other(ACTOP_ACTIVATE_ACK), MISC_GRAN);
    ticks(1);
    feed_crdt(G_WREQ, G_RREQ, G_WDATA, G_RDATA, G_WRESP);
    ticks(2);
    chk(enabled === 1'b1 && error === 1'b0 && act_disabled === 1'b0, "reaches ENABLED");
  endtask

  // --- level 1: decode every §5.6 Misc flit crossing the activation link -----
  // (tx_ready is tied high and rx is consumed while not ENABLED, so a valid on
  // either side is a transfer.)  Level 2 adds the §8 FSM state on change.
  logic [2:0] p_state;
  bit         dbg_armed;
  always @(posedge clk) begin
    if ((aou_lvl >= 1) && rstn) begin
      if (tx_valid && tx_ready) aou_log_flit("DUT->peer", tx_data);
      if (rx_valid && rx_ready) aou_log_flit("peer->DUT", rx_data);
    end
    if (aou_lvl >= 2) begin
      if (!rstn) dbg_armed <= 1'b0;
      else begin
        if (!dbg_armed || (dut.state !== p_state))
          aou_dbg($sformatf("act.fsm %s (enabled=%0b disabled=%0b error=%0b quiescing=%0b)",
                            aou_act_state_name(dut.state), enabled, act_disabled,
                            error, quiescing));
        dbg_armed <= 1'b1;
      end
      p_state <= dut.state;
    end
  end

  initial begin
    aou_log_init("[ACT-TB]");
    rstn       = 1'b0;
    deact_trig = 1'b0;
    data_idle  = 1'b1;                 // Option-1 default: link pre-quiesced
    err_clear  = 1'b0;
    tx_ready   = 1'b1;                 // always accept the DUT's tx flits
    d_tx_valid = 1'b0;
    d_tx_data  = '0;
    d_rx_ready = 1'b1;
    rx_valid   = 1'b0;
    rx_data    = '0;
    repeat (4) @(negedge clk);
    rstn = 1'b1;

    chk(act_disabled === 1'b1 && enabled === 1'b0, "starts DISABLED after reset");

    // --- 1) bring-up ---------------------------------------------------------
    bring_up();

    // --- 2) SW-triggered teardown (deact_trig) -------------------------------
    @(negedge clk); deact_trig = 1'b1;
    @(negedge clk); deact_trig = 1'b0;
    ticks(1);
    chk(enabled === 1'b0, "deact_trig leaves ENABLED");         // now DEACTIVATE
    feed(mk_activation_other(ACTOP_DEACTIVATE_REQ), MISC_GRAN); // -> DUT sends DeactivateAck
    ticks(1);
    feed(mk_activation_other(ACTOP_DEACTIVATE_ACK), MISC_GRAN); // Ack sent&rcvd -> DISABLED
    ticks(1);
    chk(act_disabled === 1'b1, "SW teardown reaches DISABLED");

    // --- 2b) Option 2 (§8.3.2): deact_trig mid-transaction is held until the
    //         data path drains (data_idle), with `quiescing` raised meanwhile ---
    bring_up();
    data_idle = 1'b0;                            // data path busy (in-flight)
    @(negedge clk); deact_trig = 1'b1;           // SW writes the flag mid-txn
    @(negedge clk); deact_trig = 1'b0;           // latched even as a 1-cycle pulse
    ticks(2);
    chk(enabled === 1'b1, "Opt-2: teardown withheld while data path busy");
    chk(quiescing === 1'b1, "Opt-2: quiescing asserted while draining");
    data_idle = 1'b1;                            // bridge reports data path drained
    ticks(2);
    chk(enabled === 1'b0 && quiescing === 1'b0, "Opt-2: teardown starts once drained");
    feed(mk_activation_other(ACTOP_DEACTIVATE_REQ), MISC_GRAN); // -> DUT sends DeactivateAck
    ticks(1);
    feed(mk_activation_other(ACTOP_DEACTIVATE_ACK), MISC_GRAN); // Ack sent&rcvd -> DISABLED
    ticks(1);
    chk(act_disabled === 1'b1, "Opt-2: teardown reaches DISABLED");
    data_idle = 1'b1;                            // restore Option-1 default

    // --- 3) re-activation ----------------------------------------------------
    bring_up();
    chk(enabled === 1'b1, "re-activates after SW teardown");

    // --- 4) peer-initiated teardown (received DeactivateReq) -----------------
    feed(mk_activation_other(ACTOP_DEACTIVATE_REQ), MISC_GRAN); // ENABLED -> DEACTIVATE
    ticks(1);
    chk(enabled === 1'b0, "received DeactivateReq leaves ENABLED");
    feed(mk_activation_other(ACTOP_DEACTIVATE_ACK), MISC_GRAN); // DUT already sent Ack -> DISABLED
    ticks(1);
    chk(act_disabled === 1'b1, "peer teardown reaches DISABLED");

    bring_up();                                                 // back to ENABLED

    // --- 5) ERROR on inconsistent ActivateReq while ENABLED ------------------
    feed(mk_activate_req(5'b0, 5'b0, 16'b0), ACTIVATEREQ_GRAN);
    ticks(1);
    chk(error === 1'b1 && enabled === 1'b0, "inconsistent ActivateReq -> ERROR");
    @(negedge clk); #1;
    chk(tx_valid === 1'b0, "ERROR transmits nothing");
    feed(mk_activation_other(ACTOP_DEACTIVATE_ACK), MISC_GRAN); // ignored in ERROR
    ticks(1);
    chk(error === 1'b1, "ERROR ignores received messages");
    // err_clear returns to DISABLED, from which the FSM re-activates on its own
    // (DISABLED is a single-cycle transient), so sample it the cycle it lands.
    @(negedge clk); err_clear = 1'b1;
    @(negedge clk);                     // posedge between applied ERROR->DISABLED
    chk(act_disabled === 1'b1 && error === 1'b0, "err_clear returns to DISABLED");
    err_clear = 1'b0;

    bring_up();                                                 // recovers to ENABLED
    chk(enabled === 1'b1, "re-activates after ERROR recovery");

    if (errors == 0) $display("[ACT-TB] PASS: %0d checks, 0 errors", checks);
    else             $display("[ACT-TB] FAIL: %0d checks, %0d errors", checks, errors);
    aou_log_close();
    $finish;
  end

  // watchdog
  initial begin
    #200000;
    $display("[ACT-TB] FAIL: timeout (checks=%0d errors=%0d)", checks, errors);
    aou_log_close();
    $finish;
  end
endmodule
