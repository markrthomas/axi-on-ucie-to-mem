// -----------------------------------------------------------------------------
// aou_flit_log.svh — shared AoU flit -> string decoder + the two-level
// (VERBOSE=0|1|2) file-logging helpers used by every SystemVerilog DV env.
//
// NON-SYNTHESIZABLE, DV-ONLY.  This file is `include`d INSIDE a testbench
// module (never in rtl/), so nothing here is elaborated into the datapath and
// the VERBOSE=0 build is bit-for-bit the design that ships.  It only READS
// flits that the DUT already produced.
//
// One source of truth for the rendered form of a flit: dv/common/aou_flit_log.py
// (cocotb) and dv/common/aou_flit_log.h (SystemC) are field-for-field mirrors of
// the format produced here, so a flit reads the same in every environment's log.
//
// Verbosity levels (documented once, identical in every env):
//   0  off      — no extra output at all; stdout stays byte-identical.
//   1  packet   — one decoded line per AoU flit crossing a UCIe link, plus the
//                 env's existing AXI transaction trace.
//   2  debug    — level 1 plus internal DUT state (FSMs, credit counters,
//                 queue occupancy, arbiter grants, reorder slots).
//
// Requirements of the including module:
//   * `import aou_pkg::*;` in scope,
//   * call aou_log_init("[XX-TB]") once at time 0,
//   * call aou_log_close() before $finish.
//
// Line formats
//   <tag>[V] ...                       level / log-file banner
//   <tag>[T] ...                       AXI transaction trace (env-specific)
//   <tag>[F] t=<time> <dir> fdid=<n> crd=<credit> ms=0x<48b> g=<n> <Type>
//            gran=<n> <per-type fields>
//   <tag>[D] t=<time> <what>           internal state (level 2)
// -----------------------------------------------------------------------------
`ifndef AOU_FLIT_LOG_SVH
`define AOU_FLIT_LOG_SVH

  // --- level + per-test log file --------------------------------------------
  int    aou_lvl = 0;      // 0 = off, 1 = packet + txn, 2 = + internal state
  int    aou_fd  = 0;      // $fopen handle for logs/<env>.log (0 = none)
  string aou_tag = "";     // env banner tag, e.g. "[SV-TB]"
  bit    aou_to_stdout = 1'b1;   // mirror verbose lines on stdout (see below)

  // +verbose=<lvl> is the canonical knob; a bare +verbose (the historical form)
  // still means level 1 so older command lines keep working.
  function automatic int aou_log_level();
    int l;
    begin
      if ($value$plusargs("verbose=%d", l))    aou_log_level = (l < 0) ? 0 : l;
      else if ($test$plusargs("verbose") != 0) aou_log_level = 1;
      else                                     aou_log_level = 0;
    end
  endfunction

  // Open the per-test log file named by +logfile=<path> (each env's Makefile
  // passes it).  At level 0 nothing is opened and nothing is printed, so the
  // default run is byte-identical to a build without this file.
  task automatic aou_log_init(input string tag);
    string path;
    begin
      aou_tag = tag;
      aou_lvl = aou_log_level();
      aou_fd  = 0;
      if (aou_lvl > 0) begin
        if (!$value$plusargs("logfile=%s", path)) path = "";
        if (path != "") begin
          aou_fd = $fopen(path, "w");
          if (aou_fd == 0)
            $display("%s[V] WARNING: cannot open log file '%s'", tag, path);
        end
        if (aou_to_stdout)
          $display("%s[V] verbose level %0d (1=packet+txn, 2=+internal state)%s",
                   tag, aou_lvl, (aou_fd != 0) ? " -> log file" : "");
        if (aou_fd != 0)
          $fdisplay(aou_fd, "%s[V] verbose level %0d, log file '%s'",
                    tag, aou_lvl, path);
      end
    end
  endtask

  // Emit one verbose line: stdout (as the pre-existing VERBOSE=1 trace did) and
  // the per-test log file.  Never called at level 0.
  task automatic aou_emit(input string s);
    begin
      if (aou_to_stdout) $display("%s", s);
      if (aou_fd != 0)   $fdisplay(aou_fd, "%s", s);
    end
  endtask

  task automatic aou_log_close();
    if (aou_fd != 0) begin
      $fflush(aou_fd);
      $fclose(aou_fd);
      aou_fd = 0;
    end
  endtask

  // --- enum -> name ---------------------------------------------------------
  function automatic string aou_msgtype_name(input logic [MSGTYPE_W-1:0] mt);
    case (mt)
      MT_MISC:          aou_msgtype_name = "Misc";
      MT_WRITEREQ:      aou_msgtype_name = "WriteReq";
      MT_READREQ:       aou_msgtype_name = "ReadReq";
      MT_WRITEDATA:     aou_msgtype_name = "WriteData";
      MT_READDATA:      aou_msgtype_name = "ReadData";
      MT_WRITERESP:     aou_msgtype_name = "WriteResp";
      MT_WRITEDATAFULL: aou_msgtype_name = "WriteDataFull";
      default:          aou_msgtype_name = "Unknown";
    endcase
  endfunction

  function automatic string aou_burst_name(input logic [1:0] b);
    case (b)
      AXBURST_FIXED: aou_burst_name = "FIXED";
      AXBURST_INCR:  aou_burst_name = "INCR";
      AXBURST_WRAP:  aou_burst_name = "WRAP";
      default:       aou_burst_name = "RSVD";
    endcase
  endfunction

  function automatic string aou_actop_name(input logic [ACTIVATIONOP_W-1:0] op);
    case (op)
      ACTOP_ACTIVATE_REQ:   aou_actop_name = "ActivateReq";
      ACTOP_ACTIVATE_ACK:   aou_actop_name = "ActivateAck";
      ACTOP_DEACTIVATE_REQ: aou_actop_name = "DeactivateReq";
      ACTOP_DEACTIVATE_ACK: aou_actop_name = "DeactivateAck";
      default:              aou_actop_name = "Unknown";
    endcase
  endfunction

  // Granule count of a decoded message.  msg_granules() covers the §5.8 data
  // messages; the §5.6 Misc family is sized by its MISCOP / ActivationOp.
  function automatic int aou_msg_gran(input msg_t m);
    logic [MSGTYPE_W-1:0] mt;
    begin
      mt = get_msgtype(m);
      if (mt == MT_MISC) begin
        if (misc_op(m) == MISCOP_CRDTGRANT)
          aou_msg_gran = CRDTGRANT_GRAN;
        else if ((misc_op(m) == MISCOP_ACTIVATION) &&
                 (misc_activationop(m) == ACTOP_ACTIVATE_REQ))
          aou_msg_gran = ACTIVATEREQ_GRAN;
        else
          aou_msg_gran = MISC_GRAN;
      end else begin
        aou_msg_gran = msg_granules(mt);
        if (aou_msg_gran == 0) aou_msg_gran = 1;
      end
    end
  endfunction

  // --- per-message field rendering -----------------------------------------
  // `rp` is the flit's FDId, i.e. the resource plane the message belongs to; it
  // selects which per-plane slot of a Table-18 CrdtGrant is reported.
  function automatic string aou_msg_str(input msg_t m, input logic [RP_W-1:0] rp);
    logic [MSGTYPE_W-1:0] mt;
    begin
      mt = get_msgtype(m);
      case (mt)
        MT_WRITEREQ:
          aou_msg_str = $sformatf(
              "id=%0d addr=0x%016h len=%0d size=%0d burst=%s flex=0x%04h",
              wr_id(m), wr_addr(m), wr_len(m), wr_size(m),
              aou_burst_name(wr_burst(m)), wr_flex(m));
        MT_READREQ:
          aou_msg_str = $sformatf(
              "id=%0d addr=0x%016h len=%0d size=%0d burst=%s flex=0x%04h",
              rr_id(m), rr_addr(m), rr_len(m), rr_size(m),
              aou_burst_name(rr_burst(m)), rr_flex(m));
        MT_WRITEDATA:
          aou_msg_str = $sformatf("dlen=%0d data=0x%064h strb=0x%08h flex=0x%04h",
                                  msg_dlength(m), wd_data(m), wd_strb(m),
                                  msg_flex(m));
        MT_READDATA:
          aou_msg_str = $sformatf(
              "id=%0d resp=%0d last=%0b dlen=%0d data=0x%064h flex=0x%04h",
              rd_id(m), rd_resp(m), rd_last(m), msg_dlength(m), rd_data(m),
              msg_flex(m));
        MT_WRITERESP:
          aou_msg_str = $sformatf("id=%0d resp=%0d flex=0x%04h",
                                  wrsp_id(m), wrsp_resp(m), msg_flex(m));
        MT_MISC: begin
          if (misc_op(m) == MISCOP_CRDTGRANT)
            aou_msg_str = $sformatf(
                "op=CrdtGrant rp%0d(wreq=%0d rreq=%0d wdata=%0d rdata=%0d wresp=%0d)",
                rp, cred_decode(cg_wreq(m, rp)), cred_decode(cg_rreq(m, rp)),
                cred_decode(cg_wdata(m, rp)), cred_decode(cg_rdata(m, rp)),
                cred_decode({1'b0, cg_wresp(m, rp)}));
          else if (misc_op(m) == MISCOP_ACTIVATION)
            aou_msg_str = $sformatf("op=Activation aop=%s",
                                    aou_actop_name(misc_activationop(m)));
          else
            aou_msg_str = $sformatf("op=0x%0h", misc_op(m));
        end
        default: aou_msg_str = "";
      endcase
    end
  endfunction

  // §6 MsgCredit word (Table 16/17): raw value plus the decoded grant per type.
  function automatic string aou_credit_str(input logic [CREDIT_W-1:0] c);
    aou_credit_str = $sformatf(
        "0x%04h(rp=%0d wreq=%0d rreq=%0d wdata=%0d rdata=%0d wresp=%0d)",
        c, mc_rp(c), cred_decode(mc_wreq(c)), cred_decode(mc_rreq(c)),
        cred_decode(mc_wdata(c)), cred_decode(mc_rdata(c)),
        cred_decode({1'b0, mc_wresp(c)}));
  endfunction

  // --- flit -> log ----------------------------------------------------------
  // Decode one PLP and emit one [F] line per message it STARTS (§4.3 MsgStart
  // bitmap).  `dir` is the link direction label, e.g. "A->B".
  task automatic aou_log_flit(input string dir, input flit_t f);
    msgstart_t         ms;
    payload_t          pl;
    msg_t              m;
    logic [FDID_W-1:0] fdid;
    int                g, gm;
    begin
      if (aou_lvl >= 1) begin
        ms   = flit_msgstart(f);
        pl   = flit_payload(f);
        fdid = flit_fdid(f);
        for (g = 0; g < NUM_GRAN; g++) begin
          if (ms[g] === 1'b1) begin
            gm = NUM_GRAN - g;
            if (gm > MSG_MAX_GRAN) gm = MSG_MAX_GRAN;
            m  = payload_get(pl, g, gm);
            aou_emit($sformatf("%s[F] t=%0d %s fdid=%0d crd=%s ms=0x%012h g=%0d %s gran=%0d %s",
                               aou_tag, $time, dir, fdid, aou_credit_str(flit_credit(f)),
                               ms, g, aou_msgtype_name(get_msgtype(m)),
                               aou_msg_gran(m), aou_msg_str(m, RP_W'(fdid))));
          end
        end
      end
    end
  endtask

  // --- level-2 helpers ------------------------------------------------------
  task automatic aou_dbg(input string s);
    if (aou_lvl >= 2) aou_emit($sformatf("%s[D] t=%0d %s", aou_tag, $time, s));
  endtask

  // Initiator/target bridge FSM state names (rtl/aou_axi_initiator_bridge.sv,
  // rtl/aou_axi_target_bridge.sv) and the §8 activation FSM (rtl/aou_activation.sv).
  function automatic string aou_init_state_name(input logic [2:0] s);
    case (s)
      3'd0: aou_init_state_name = "S_IDLE";
      3'd1: aou_init_state_name = "S_WREQ";
      3'd2: aou_init_state_name = "S_WDATA";
      3'd3: aou_init_state_name = "S_WWAIT";
      3'd4: aou_init_state_name = "S_B";
      3'd5: aou_init_state_name = "S_RREQ";
      3'd6: aou_init_state_name = "S_RDATA";
      default: aou_init_state_name = "S_?";
    endcase
  endfunction

  // OOO_EN=1 initiator FSM (ostate_e).
  function automatic string aou_oinit_state_name(input logic [1:0] s);
    case (s)
      2'd0: aou_oinit_state_name = "O_IDLE";
      2'd1: aou_oinit_state_name = "O_WREQ";
      2'd2: aou_oinit_state_name = "O_WDATA";
      default: aou_oinit_state_name = "O_RREQ";
    endcase
  endfunction

  function automatic string aou_tgt_state_name(input logic [2:0] s);
    case (s)
      3'd0: aou_tgt_state_name = "S_IDLE";
      3'd1: aou_tgt_state_name = "S_WBEAT";
      3'd2: aou_tgt_state_name = "S_WRESP";
      3'd3: aou_tgt_state_name = "S_RBEAT";
      default: aou_tgt_state_name = "S_?";
    endcase
  endfunction

  function automatic string aou_act_state_name(input logic [2:0] s);
    case (s)
      3'd0: aou_act_state_name = "ACT_DISABLED";
      3'd1: aou_act_state_name = "ACT_ACTIVATE";
      3'd2: aou_act_state_name = "ACT_ENABLED";
      3'd3: aou_act_state_name = "ACT_DEACTIVATE";
      3'd4: aou_act_state_name = "ACT_ERROR";
      default: aou_act_state_name = "ACT_?";
    endcase
  endfunction

`endif
