// -----------------------------------------------------------------------------
// tb_axi_ucie_ooo : end-to-end proof of the opt-in out-of-order-by-ID datapath.
//
// Instantiates axi_ucie_mem_top with OOO_EN=1 — i.e. the target bridge's
// response path runs through aou_ooo_resp_src (which lets a later DIFFERENT-ID
// response overtake an earlier one) and the initiator bridge restores AXI
// ordering with two aou_reorder buffers — and drives INTERLEAVED MULTI-ID
// traffic with several transactions in flight at once.
//
// What it proves (docs/PLAN.md F2 acceptance):
//   (a) same-ID in-order delivery — every response is matched against the head
//       of a per-ID reference FIFO of issued transactions, and read data /
//       RLAST / beat address are checked against that entry.  A same-ID
//       reordering would show up immediately as a data or RLAST mismatch.
//   (b) a REAL different-ID overtake — a completing transaction is counted as
//       an overtake when an OLDER transaction of a DIFFERENT ID is still
//       outstanding.  The test FAILS if the counts are zero, so it cannot pass
//       by merely tolerating out-of-order completion: it has to observe it.
//   (c) no cross-ID leakage — a response whose ID has no outstanding
//       transaction is an error, and every read beat must carry the data its
//       own transaction wrote (distinct data per transaction).
//   (d) every response delivered — the run only finishes when all NW write and
//       all NR read transactions have completed; the watchdog fails otherwise.
//
// Portable: no fork/join, no classes.  Runs under Icarus (iverilog -g2012 +
// vvp) and Verilator (--binary --timing).  Prints "[OOO-TB] PASS: ...".
// -----------------------------------------------------------------------------
`ifndef TB_AXI_UCIE_OOO_SV
`define TB_AXI_UCIE_OOO_SV

module tb_axi_ucie_ooo
  import aou_pkg::*;
;

  // Shared DV-only flit decoder + VERBOSE=0|1|2 logging helpers.  Included in
  // the TB only (never in rtl/), so VERBOSE=0 emits nothing and the OOO
  // datapath is untouched.
  `include "aou_flit_log.svh"


  localparam int AW         = 32;
  localparam int DW         = 32;
  localparam int SW         = DW/8;
  localparam int IW         = 4;                  // AXI ID width
  localparam int MEM_ADDR_W = 16;
  localparam int WORDS      = 1 << (MEM_ADDR_W-2);
  localparam logic [2:0] SZ4 = 3'd2;              // 4-byte beat (32-bit)
  localparam logic [1:0] BI  = 2'b01;             // INCR
  localparam int NIDS       = 1 << IW;

  localparam int NW = 12;                         // write transactions
  localparam int NR = 16;                         // read  transactions

  logic             ACLK;
  logic             ARESETn;
  logic [IW-1:0]    AWID;    logic [AW-1:0] AWADDR; logic [7:0] AWLEN;
  logic [2:0]       AWSIZE;  logic [1:0] AWBURST;   logic [2:0] AWPROT;
  logic             AWVALID, AWREADY;
  logic [DW-1:0]    WDATA;   logic [SW-1:0] WSTRB; logic WLAST, WVALID, WREADY;
  logic [IW-1:0]    BID;     logic [1:0] BRESP;    logic BVALID, BREADY;
  logic [IW-1:0]    ARID;    logic [AW-1:0] ARADDR; logic [7:0] ARLEN;
  logic [2:0]       ARSIZE;  logic [1:0] ARBURST;   logic [2:0] ARPROT;
  logic             ARVALID, ARREADY;
  logic [IW-1:0]    RID;     logic [DW-1:0] RDATA;  logic [1:0] RRESP;
  logic             RLAST, RVALID, RREADY;

  axi_ucie_mem_top #(
    .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .AXI_ID_W(IW), .MEM_ADDR_W(MEM_ADDR_W),
    .OOO_EN(1'b1)
  ) dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWID(AWID), .AWADDR(AWADDR), .AWLEN(AWLEN), .AWSIZE(AWSIZE),
    .AWBURST(AWBURST), .AWPROT(AWPROT), .AWVALID(AWVALID), .AWREADY(AWREADY),
    .WDATA(WDATA), .WSTRB(WSTRB), .WLAST(WLAST), .WVALID(WVALID), .WREADY(WREADY),
    .BID(BID), .BRESP(BRESP), .BVALID(BVALID), .BREADY(BREADY),
    .ARID(ARID), .ARADDR(ARADDR), .ARLEN(ARLEN), .ARSIZE(ARSIZE),
    .ARBURST(ARBURST), .ARPROT(ARPROT), .ARVALID(ARVALID), .ARREADY(ARREADY),
    .RID(RID), .RDATA(RDATA), .RRESP(RRESP), .RLAST(RLAST),
    .RVALID(RVALID), .RREADY(RREADY)
  );

  initial ACLK = 1'b0;
  always #5 ACLK = ~ACLK;

  // Dev-only waveform dump (compiled ONLY under -DAOU_WAVES; never on the gate).
  `include "aou_wave_dump.svh"

  // Level >= 1 ([OOO-TB][T] transaction trace + [OOO-TB][F] decoded flits);
  // level 2 adds [OOO-TB][D] internal state (see the monitors at the bottom).
  bit verbose;
  int errors, beats, r_overtakes, b_overtakes;

  // --- transaction descriptors ---------------------------------------------
  logic [IW-1:0] w_id   [0:NW-1];
  logic [AW-1:0] w_addr [0:NW-1];
  logic [DW-1:0] w_data [0:NW-1];
  bit            w_done [0:NW-1];

  logic [IW-1:0] r_id   [0:NR-1];
  logic [AW-1:0] r_addr [0:NR-1];
  logic [7:0]    r_len  [0:NR-1];
  bit            r_done [0:NR-1];

  logic [DW-1:0] ref_mem [0:WORDS-1];

  // --- per-ID reference FIFOs of issued-but-uncompleted transactions --------
  // Head = the transaction that MUST complete next for that ID (AXI same-ID
  // ordering).  Plain arrays + head/tail indices: portable across simulators.
  int  pw [0:NIDS-1][0:NW-1];   int pw_head [0:NIDS-1]; int pw_tail [0:NIDS-1];
  int  pr [0:NIDS-1][0:NR-1];   int pr_head [0:NIDS-1]; int pr_tail [0:NIDS-1];
  int  r_beat_of [0:NIDS-1];    // current beat index of that ID's head read

  task automatic chk(input bit cond, input string what);
    if (!cond) begin
      errors++;
      $display("[OOO-TB] CHECK FAILED: %s", what);
    end
  endtask

  // INCR next-beat address (independent copy of the AXI rule)
  function automatic logic [AW-1:0] nxt_addr(input logic [AW-1:0] a);
    nxt_addr = a + (1 << SZ4);
  endfunction

  // A completing transaction overtook something iff an OLDER transaction of a
  // DIFFERENT ID is still outstanding.  That is exactly the freedom AXI grants
  // and exactly what the OOO source is expected to produce.
  function automatic bit overtook_r(input int g);
    bit o;
    begin
      o = 1'b0;
      for (int j = 0; j < NR; j++)
        if ((j < g) && !r_done[j] && (r_id[j] !== r_id[g])) o = 1'b1;
      overtook_r = o;
    end
  endfunction

  function automatic bit overtook_w(input int g);
    bit o;
    begin
      o = 1'b0;
      for (int j = 0; j < NW; j++)
        if ((j < g) && !w_done[j] && (w_id[j] !== w_id[g])) o = 1'b1;
      overtook_w = o;
    end
  endfunction

  // --- phase A: pipelined multi-ID single-beat writes ----------------------
  // One cycle-accurate process drives AW, W and monitors B independently, so
  // several writes are in flight at once without needing fork/join.
  task automatic write_phase();
    int ai, wi, bi, g;
    logic [IW-1:0] id;
    begin
      ai = 0; wi = 0; bi = 0;
      while (bi < NW) begin
        @(negedge ACLK);
        if (ai < NW) begin
          AWID = w_id[ai]; AWADDR = w_addr[ai]; AWLEN = 8'd0; AWSIZE = SZ4;
          AWBURST = BI; AWPROT = 3'b000; AWVALID = 1'b1;
        end else AWVALID = 1'b0;
        if (wi < NW) begin
          WDATA = w_data[wi]; WSTRB = {SW{1'b1}}; WLAST = 1'b1; WVALID = 1'b1;
        end else begin WVALID = 1'b0; WLAST = 1'b0; end
        @(posedge ACLK);
        if (AWVALID && AWREADY) begin
          // issue order per ID
          pw[w_id[ai]][pw_tail[w_id[ai]]] = ai;
          pw_tail[w_id[ai]]++;
          if (verbose) aou_emit($sformatf("[OOO-TB][T] AW  txn %0d id=%0d addr=0x%05h",
                                          ai, w_id[ai], w_addr[ai]));
          ai++;
        end
        if (WVALID && WREADY) wi++;
        if (BVALID && BREADY) begin
          id = BID;
          chk(pw_head[id] < pw_tail[id],
              $sformatf("B with id %0d has no outstanding write (cross-ID leak)", id));
          if (pw_head[id] < pw_tail[id]) begin
            g = pw[id][pw_head[id]];
            pw_head[id]++;
            chk(BRESP === 2'b00, $sformatf("BRESP txn %0d", g));
            if (overtook_w(g)) b_overtakes++;
            w_done[g] = 1'b1;
            if (verbose) aou_emit($sformatf("[OOO-TB][T] B   txn %0d id=%0d (issue #%0d, delivery #%0d)",
                                            g, id, g, bi));
          end
          bi++;
        end
      end
      @(negedge ACLK); AWVALID = 1'b0; WVALID = 1'b0; WLAST = 1'b0;
    end
  endtask

  // --- phase B: pipelined multi-ID reads (single- and multi-beat) ----------
  task automatic read_phase();
    int ai, ndone, g;
    logic [IW-1:0] id;
    logic [AW-1:0] ea;
    begin
      ai = 0; ndone = 0;
      while (ndone < NR) begin
        @(negedge ACLK);
        if (ai < NR) begin
          ARID = r_id[ai]; ARADDR = r_addr[ai]; ARLEN = r_len[ai]; ARSIZE = SZ4;
          ARBURST = BI; ARPROT = 3'b000; ARVALID = 1'b1;
        end else ARVALID = 1'b0;
        @(posedge ACLK);
        if (ARVALID && ARREADY) begin
          pr[r_id[ai]][pr_tail[r_id[ai]]] = ai;
          pr_tail[r_id[ai]]++;
          if (verbose) aou_emit($sformatf("[OOO-TB][T] AR  txn %0d id=%0d addr=0x%05h len=%0d",
                                          ai, r_id[ai], r_addr[ai], r_len[ai]));
          ai++;
        end
        if (RVALID && RREADY) begin
          id = RID;
          beats++;
          chk(pr_head[id] < pr_tail[id],
              $sformatf("R with id %0d has no outstanding read (cross-ID leak)", id));
          if (pr_head[id] < pr_tail[id]) begin
            g  = pr[id][pr_head[id]];
            ea = r_addr[g] + (r_beat_of[id] << SZ4);
            chk(RRESP === 2'b00, $sformatf("RRESP txn %0d", g));
            chk(RDATA === ref_mem[ea[MEM_ADDR_W-1:2]],
                $sformatf("txn %0d id %0d beat %0d @0x%05h: got 0x%08h exp 0x%08h",
                          g, id, r_beat_of[id], ea, RDATA, ref_mem[ea[MEM_ADDR_W-1:2]]));
            chk(RLAST === (r_beat_of[id] == int'(r_len[g])),
                $sformatf("RLAST txn %0d beat %0d", g, r_beat_of[id]));
            if (verbose) aou_emit($sformatf("[OOO-TB][T] R   txn %0d id=%0d beat %0d data=0x%08h last=%0b",
                                            g, id, r_beat_of[id], RDATA, RLAST));
            if (RLAST) begin
              pr_head[id]++;
              r_beat_of[id] = 0;
              if (overtook_r(g)) r_overtakes++;
              r_done[g] = 1'b1;
              ndone++;
            end else r_beat_of[id]++;
          end
        end
      end
      @(negedge ACLK); ARVALID = 1'b0;
    end
  endtask

  int i;

  initial begin
    ARESETn = 1'b0;
    AWVALID = 1'b0; WVALID = 1'b0; ARVALID = 1'b0; WLAST = 1'b0;
    AWID = '0; AWADDR = '0; AWLEN = '0; AWSIZE = '0; AWBURST = '0; AWPROT = '0;
    WDATA = '0; WSTRB = '0;
    ARID = '0; ARADDR = '0; ARLEN = '0; ARSIZE = '0; ARBURST = '0; ARPROT = '0;
    BREADY = 1'b1; RREADY = 1'b1;
    errors = 0; beats = 0; r_overtakes = 0; b_overtakes = 0;
    aou_log_init("[OOO-TB]");
    verbose = (aou_lvl >= 1);

    for (i = 0; i < WORDS; i++) ref_mem[i] = '0;
    for (i = 0; i < NIDS; i++) begin
      pw_head[i] = 0; pw_tail[i] = 0;
      pr_head[i] = 0; pr_tail[i] = 0;
      r_beat_of[i] = 0;
    end

    // Interleaved multi-ID write traffic: IDs 1,2,3 round-robin, one distinct
    // address and one distinct data word per transaction (so any cross-ID or
    // same-ID misdelivery shows up as a data mismatch on read-back).
    for (i = 0; i < NW; i++) begin
      w_id[i]   = 4'((i % 3) + 1);
      w_addr[i] = 32'h1000 + (i << 6);
      w_data[i] = 32'h5A5A_0000 + i;
      w_done[i] = 1'b0;
      ref_mem[w_addr[i][MEM_ADDR_W-1:2]] = w_data[i];
    end

    repeat (3) @(negedge ACLK);
    ARESETn = 1'b1;
    @(negedge ACLK);

    write_phase();

    // Interleaved multi-ID reads over what was just written.
    //   txn 0..7   single-beat
    //   txn 8..11  2-beat INCR bursts   — exercise the initiator's read
    //              reorder-slot beat accumulator alongside single-beat traffic.
    //              (The OOO source forwards multi-flit responses whole; it only
    //              ever holds a single-flit response, so a burst is never split.)
    //   txn 12..15 16-beat INCR bursts  — 4 x 16 beats = 512 ReadData granules,
    //              FOUR TIMES the 128-granule §6 ReadData credit ceiling this bridge
    //              granted the target.  Since the initiator only returns
    //              ReadData credits piggybacked on its next request flit, an
    //              unthrottled OOO issue path deadlocks here: once all four are
    //              in flight there is no further request to carry the returns
    //              and the target stalls at zero credits.  The issue-side
    //              granule gate (rd_out/rd_fits in the g_ooo branch) is what
    //              keeps this live, so this section is its regression test.
    // Beats past the first of each burst read never-written words, which the
    // reference memory holds at 0 — the first beat still carries that
    // transaction's own distinct data, so cross-ID leakage is still caught.
    for (i = 0; i < NR; i++) begin
      r_id[i]   = 4'((i % 3) + 1);
      r_addr[i] = w_addr[i % NW];
      r_len[i]  = (i >= 12) ? 8'd15 : ((i >= 8) ? 8'd1 : 8'd0);
      r_done[i] = 1'b0;
    end

    read_phase();

    // --- acceptance checks ------------------------------------------------
    for (i = 0; i < NW; i++)
      chk(w_done[i], $sformatf("write txn %0d never completed", i));
    for (i = 0; i < NR; i++)
      chk(r_done[i], $sformatf("read txn %0d never completed", i));
    for (i = 0; i < NIDS; i++) begin
      chk(pw_head[i] == pw_tail[i], $sformatf("id %0d has undelivered writes", i));
      chk(pr_head[i] == pr_tail[i], $sformatf("id %0d has undelivered reads",  i));
    end
    // The whole point of OOO_EN=1: responses of different IDs really do overtake.
    chk(r_overtakes > 0, "no different-ID READ overtake observed (OOO source inert?)");
    chk(b_overtakes > 0, "no different-ID WRITE overtake observed (OOO source inert?)");

    if (errors == 0)
      $display("[OOO-TB] PASS: %0d read beats checked, %0d R + %0d B different-ID overtakes, 0 errors",
               beats, r_overtakes, b_overtakes);
    else
      $display("[OOO-TB] FAIL: %0d read beats checked, %0d R + %0d B different-ID overtakes, %0d errors",
               beats, r_overtakes, b_overtakes, errors);
    aou_log_close();
    $finish;
  end

  // --- level 1: decoded AoU flit trace at the UCIe link boundary -------------
  // Passive observation of the initiator's TX/RX handshakes; no RTL edit.
  always @(posedge ACLK) begin
    if ((aou_lvl >= 1) && ARESETn) begin
      if (dut.g_rp1.init_tx_valid && dut.g_rp1.init_tx_ready)
        aou_log_flit("A->B", dut.g_rp1.init_tx_data);
      if (dut.g_rp1.init_rx_valid && dut.g_rp1.init_rx_ready)
        aou_log_flit("B->A", dut.g_rp1.init_rx_data);
    end
  end

  // --- level 2: OOO internal state ------------------------------------------
  // The two pieces the F2 datapath is debugged from: the target-side OOO
  // response source's HOLD state (which response is being held back, for how
  // long, and whether something overtook it) and the initiator-side reorder
  // buffers' slot occupancy / completion bitmaps.  Read-only hierarchical
  // references; reported on change.
  logic       p_hv, p_fs, p_fl;
  logic [3:0] p_hid;
  logic [7:0] p_roccr, p_rdoner, p_roccw, p_rdonew;
  logic [1:0] p_istate;             // ostate_e is 2 bits (rtl initiator bridge)
  bit         dbg_armed;

  always @(posedge ACLK) begin
    if (aou_lvl >= 2) begin
      if (!ARESETn) begin
        dbg_armed <= 1'b0;
      end else begin
        if (!dbg_armed || (dut.g_rp1.u_init.g_ooo.ostate !== p_istate))
          aou_dbg($sformatf("init.fsm %s",
                            aou_oinit_state_name(dut.g_rp1.u_init.g_ooo.ostate)));
        if (!dbg_armed ||
            (dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_valid  !== p_hv) ||
            (dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_id     !== p_hid) ||
            (dut.g_rp1.u_tgt.g_ooo_src.u_ooo.fwd_seen !== p_fs) ||
            (dut.g_rp1.u_tgt.g_ooo_src.u_ooo.flushing !== p_fl))
          aou_dbg($sformatf("tgt.ooo hold=%0b id=%0d timer=%0d overtaken=%0b flushing=%0b",
                            dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_valid,
                            dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_id,
                            dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_timer,
                            dut.g_rp1.u_tgt.g_ooo_src.u_ooo.fwd_seen,
                            dut.g_rp1.u_tgt.g_ooo_src.u_ooo.flushing));
        if (!dbg_armed ||
            (8'(dut.g_rp1.u_init.g_ooo.u_rob_r.occ)  !== p_roccr) ||
            (8'(dut.g_rp1.u_init.g_ooo.u_rob_r.done) !== p_rdoner))
          aou_dbg($sformatf("init.rob_r occ=0x%02h done=0x%02h head=%0d tail=%0d count=%0d",
                            dut.g_rp1.u_init.g_ooo.u_rob_r.occ,
                            dut.g_rp1.u_init.g_ooo.u_rob_r.done,
                            dut.g_rp1.u_init.g_ooo.u_rob_r.head,
                            dut.g_rp1.u_init.g_ooo.u_rob_r.tail,
                            dut.g_rp1.u_init.g_ooo.u_rob_r.count));
        if (!dbg_armed ||
            (8'(dut.g_rp1.u_init.g_ooo.u_rob_w.occ)  !== p_roccw) ||
            (8'(dut.g_rp1.u_init.g_ooo.u_rob_w.done) !== p_rdonew))
          aou_dbg($sformatf("init.rob_w occ=0x%02h done=0x%02h head=%0d tail=%0d count=%0d",
                            dut.g_rp1.u_init.g_ooo.u_rob_w.occ,
                            dut.g_rp1.u_init.g_ooo.u_rob_w.done,
                            dut.g_rp1.u_init.g_ooo.u_rob_w.head,
                            dut.g_rp1.u_init.g_ooo.u_rob_w.tail,
                            dut.g_rp1.u_init.g_ooo.u_rob_w.count));
        dbg_armed <= 1'b1;
      end
      p_istate <= dut.g_rp1.u_init.g_ooo.ostate;
      p_hv     <= dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_valid;
      p_hid    <= dut.g_rp1.u_tgt.g_ooo_src.u_ooo.h_id;
      p_fs     <= dut.g_rp1.u_tgt.g_ooo_src.u_ooo.fwd_seen;
      p_fl     <= dut.g_rp1.u_tgt.g_ooo_src.u_ooo.flushing;
      p_roccr  <= 8'(dut.g_rp1.u_init.g_ooo.u_rob_r.occ);
      p_rdoner <= 8'(dut.g_rp1.u_init.g_ooo.u_rob_r.done);
      p_roccw  <= 8'(dut.g_rp1.u_init.g_ooo.u_rob_w.occ);
      p_rdonew <= 8'(dut.g_rp1.u_init.g_ooo.u_rob_w.done);
    end
  end

  // watchdog — also catches a lost/never-delivered response
  initial begin
    #2000000;
    $display("[OOO-TB] FAIL: timeout (errors=%0d beats=%0d)", errors, beats);
    aou_log_close();
    $finish;
  end

endmodule
`endif
