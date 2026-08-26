// -----------------------------------------------------------------------------
// aou_log.svh — the shared VERBOSE=0|1|2 level + per-test log-file plumbing for
// every SystemVerilog DV environment.  NON-SYNTHESIZABLE, DV-ONLY: it is
// `include`d INSIDE a testbench module (never in rtl/), so nothing here is
// elaborated into the datapath and the VERBOSE=0 build is bit-for-bit the
// design that ships.
//
// Verbosity levels (documented once, identical in every env and language):
//   0  off      — no extra output at all; stdout stays byte-identical.
//   1  packet   — decoded AoU flit lines / per-check detail, plus the env's
//                 existing AXI transaction trace.
//   2  debug    — level 1 plus internal DUT state (FSMs, credit counters,
//                 queue occupancy, arbiter grants, reorder slots).
//
// Requirements of the including module:
//   * call aou_log_init("[XX-TB]") once at time 0,
//   * call aou_log_close() before $finish.
//
// Line formats
//   <tag>[V] ...                       level / log-file banner
//   <tag>[T] ...                       AXI transaction trace (env-specific)
//   <tag>[C] ...                       per-check detail (unit envs)
//   <tag>[F] ...                       decoded flit (see aou_flit_log.svh)
//   <tag>[D] t=<time> <what>           internal state (level 2)
//
// dv/common/aou_flit_log.py (cocotb) and dv/common/aou_flit_log.h (SystemC) are
// the mirrors of this facility for the other two DV languages.
// -----------------------------------------------------------------------------
`ifndef AOU_LOG_SVH
`define AOU_LOG_SVH


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

  // --- level-2 helper -------------------------------------------------------
  task automatic aou_dbg(input string s);
    if (aou_lvl >= 2) aou_emit($sformatf("%s[D] t=%0d %s", aou_tag, $time, s));
  endtask

`endif
