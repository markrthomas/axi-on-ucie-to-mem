// -----------------------------------------------------------------------------
// tb_axi_ucie_mrp : end-to-end proof of the opt-in MULTIPLE RESOURCE PLANE mode.
//
// Instantiates axi_ucie_mem_top with NUM_RP=2 — two complete AoU chains (each
// with its own §8 activation FSM, its own §6 credit banks, its own outstanding
// tracking and its own memory image) sharing ONE pair of UCIe links through the
// round-robin plane arbiter (aou_rp_arb) and the FDId router (aou_rp_route) —
// and drives INTERLEAVED traffic on BOTH planes at once.
//
// What it proves (docs/PLAN.md F1 acceptance):
//
//   (a) per-plane routing.  Both planes write the SAME addresses with DIFFERENT
//       data and then read them back; each plane must see its own data, its own
//       BID/RID and its own RLAST.  A response delivered to the wrong plane is a
//       data mismatch, not a silent pass.  A cycle-by-cycle monitor additionally
//       checks that every flit handed to plane p carries FDId == p and that
//       every data flit's Table-16 MsgCredit RP subfield is p.
//
//   (b) no cross-plane credit leakage.  Two independent checks:
//         * CREDIT-BANK STABILITY — with plane 1 completely idle, a full burst
//           of plane-0 traffic runs; plane 1's five §6 credit counters (both of
//           its bridges) must not move by a single count.  A credit granted to
//           one plane can therefore never release a message on another.
//         * STARVATION ISOLATION — plane 0 is deliberately jammed: it issues a
//           16-beat read and then holds RREADY low forever, so its ReadData
//           credits run out and its chain wedges with flits queued.  Plane 1
//           must keep completing transactions throughout.  Then plane 0 is
//           released and its jammed read must still complete correctly.
//
//   (c) arbiter fairness under real contention.  A phase of CONCURRENT
//       multi-beat INCR bursts on both planes saturates the shared link, and the
//       monitor counts the cycles in which BOTH planes have a flit ready at the
//       arbiter, recording which plane won each of them.  The run fails unless
//       both planes won contended grants (a fixed-priority arbiter would leave
//       the loser at zero), both planes were served overall, and the two planes'
//       flits actually INTERLEAVE on the link.
//
//   (d) every transaction completes.  The phases only finish when every issued
//       write and read on both planes has been retired; the watchdog fails
//       otherwise.
//
// Portable: no fork/join, no classes.  Runs under Icarus (iverilog -g2012 + vvp)
// and Verilator (--binary --timing).  Prints "[MRP-TB] PASS: ...".
// -----------------------------------------------------------------------------
`ifndef TB_AXI_UCIE_MRP_SV
`define TB_AXI_UCIE_MRP_SV

module tb_axi_ucie_mrp
  import aou_pkg::*;
;

  localparam int NP         = 2;                  // resource planes under test
  localparam int AW         = 32;
  localparam int DW         = 32;
  localparam int SW         = DW/8;
  localparam int IW         = 4;
  localparam int MEM_ADDR_W = 16;
  localparam int WORDS      = 1 << (MEM_ADDR_W-2);
  localparam logic [2:0] SZ4 = 3'd2;              // 4-byte beat (32-bit)
  localparam logic [1:0] BI  = 2'b01;             // INCR

  localparam int NT   = 8;    // interleaved transactions per plane (phase A/B)
  localparam int NISO = 6;    // plane-1 transactions while plane 0 is jammed
  localparam int NSOLO = 6;   // plane-0 transactions while plane 1 is idle
  localparam int JLEN = 15;   // jammed read burst: JLEN+1 beats
  localparam int NB   = 4;    // concurrent burst transactions per plane
  localparam int BLEN = 3;    // burst length-1 (BLEN+1 beats)

  logic ACLK, ARESETn;

  // Per-plane AXI4 front doors.  Plane p occupies bit slice [p*W +: W] of each
  // port (see the axi_ucie_mem_top header): at NUM_RP=1 these are exactly the
  // historical widths, so the single-plane DUT is untouched.
  logic [NP*IW-1:0] AWID, BID, ARID, RID;
  logic [NP*AW-1:0] AWADDR, ARADDR;
  logic [NP*DW-1:0] WDATA, RDATA;
  logic [NP*SW-1:0] WSTRB;
  logic [NP*8-1:0]  AWLEN, ARLEN;
  logic [NP*3-1:0]  AWSIZE, AWPROT, ARSIZE, ARPROT;
  logic [NP*2-1:0]  AWBURST, ARBURST, BRESP, RRESP;
  logic [NP-1:0]    AWVALID, AWREADY, WLAST, WVALID, WREADY;
  logic [NP-1:0]    BVALID, BREADY, ARVALID, ARREADY, RLAST, RVALID, RREADY;

  axi_ucie_mem_top #(
    .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .AXI_ID_W(IW), .MEM_ADDR_W(MEM_ADDR_W),
    .NUM_RP(NP)
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

  // Shared DV-only flit decoder + VERBOSE=0|1|2 logging helpers.  Included in
  // the TB only (never in rtl/), so VERBOSE=0 emits nothing and the multi-plane
  // datapath is untouched.
  `include "aou_flit_log.svh"

  // Level >= 1 ([MRP-TB][T] transaction trace + [MRP-TB][F] decoded flits at the
  // SHARED link, which is where the plane interleaving is visible); level 2 adds
  // [MRP-TB][D] arbiter grants and per-plane RX-queue depth.
  bit verbose;
  int errors, beats;

  task automatic chk(input bit cond, input string what);
    if (!cond) begin
      errors++;
      $display("[MRP-TB] CHECK FAILED: %s", what);
    end
  endtask

  // --- per-plane reference memory + stimulus --------------------------------
  logic [DW-1:0] ref_mem [0:NP-1][0:WORDS-1];
  logic [AW-1:0] t_addr  [0:NP-1][0:NT-1];
  logic [DW-1:0] t_data  [0:NP-1][0:NT-1];
  logic [IW-1:0] t_id    [0:NP-1][0:NT-1];

  // ==========================================================================
  // Cross-plane monitors (run for the whole simulation)
  // ==========================================================================

  // (c) arbiter fairness: count each flit that enters the shared A->B link and
  //     which plane's FDId it carries.
  int  tx_cnt   [0:NP-1];       // A->B flits per plane
  int  rx_cnt   [0:NP-1];       // B->A flits per plane
  int  a_switch;                // consecutive A->B flits of different planes
  int  a_last;                  // plane of the previous A->B flit (-1 = none)
  // Fairness is only meaningful under CONTENTION, so count the cycles in which
  // every plane has a flit ready at the arbiter and record who won each of them.
  // A fixed-priority arbiter would show con_grant[loser] == 0.
  int  contend_cyc;
  int  con_grant [0:NP-1];

  wire        a_fire = dut.g_mrp.u_link_a2b.in_valid && dut.g_mrp.u_link_a2b.in_ready;
  wire        b_fire = dut.g_mrp.u_link_b2a.in_valid && dut.g_mrp.u_link_b2a.in_ready;
  wire [FDID_W-1:0] a_fdid = flit_fdid(dut.g_mrp.u_link_a2b.in_data);
  wire [FDID_W-1:0] b_fdid = flit_fdid(dut.g_mrp.u_link_b2a.in_data);

  always @(posedge ACLK) if (ARESETn) begin : mon_link
    if (a_fire) begin
      chk(32'(a_fdid) < NP, "A->B flit carries an FDId outside the active planes");
      if (32'(a_fdid) < NP) begin
        tx_cnt[32'(a_fdid)]++;
        if ((a_last >= 0) && (a_last != 32'(a_fdid))) a_switch++;
        a_last = 32'(a_fdid);
      end
    end
    if (b_fire) begin
      chk(32'(b_fdid) < NP, "B->A flit carries an FDId outside the active planes");
      if (32'(b_fdid) < NP) rx_cnt[32'(b_fdid)]++;
    end
    if (&dut.g_mrp.itx_valid) begin
      contend_cyc++;
      if (dut.g_mrp.a2b_link_ready)
        for (int p = 0; p < NP; p++)
          if (dut.g_mrp.u_arb_a.grant[p]) con_grant[p]++;
    end
    // level 1: decode every flit crossing the SHARED link pair — this is where
    // the per-plane interleaving the arbiter produces is visible, and the FDId
    // in each line names the plane the flit belongs to.
    if (aou_lvl >= 1) begin
      if (a_fire) aou_log_flit("A->B", dut.g_mrp.u_link_a2b.in_data);
      if (b_fire) aou_log_flit("B->A", dut.g_mrp.u_link_b2a.in_data);
    end
    // level 2: which plane the round-robin arbiter granted, and how deep each
    // plane's receive queue is at the far end of each link.
    if (aou_lvl >= 2) begin
      for (int p = 0; p < NP; p++) begin
        if (dut.g_mrp.u_arb_a.grant[p] && dut.g_mrp.a2b_link_ready)
          aou_dbg($sformatf("arb_a grant rp%0d (ready=%b)", p, dut.g_mrp.itx_valid));
        if (dut.g_mrp.u_arb_b.grant[p] && dut.g_mrp.b2a_link_ready)
          aou_dbg($sformatf("arb_b grant rp%0d (ready=%b)", p, dut.g_mrp.ttx_valid));
      end
      if (dut.g_mrp.u_route_b.g_q[0].u_q.count !== q_b0 ||
          dut.g_mrp.u_route_b.g_q[1].u_q.count !== q_b1 ||
          dut.g_mrp.u_route_a.g_q[0].u_q.count !== q_a0 ||
          dut.g_mrp.u_route_a.g_q[1].u_q.count !== q_a1)
        aou_dbg($sformatf("rxq depth  B-side rp0=%0d rp1=%0d  A-side rp0=%0d rp1=%0d",
                          dut.g_mrp.u_route_b.g_q[0].u_q.count,
                          dut.g_mrp.u_route_b.g_q[1].u_q.count,
                          dut.g_mrp.u_route_a.g_q[0].u_q.count,
                          dut.g_mrp.u_route_a.g_q[1].u_q.count));
      q_b0 <= dut.g_mrp.u_route_b.g_q[0].u_q.count;
      q_b1 <= dut.g_mrp.u_route_b.g_q[1].u_q.count;
      q_a0 <= dut.g_mrp.u_route_a.g_q[0].u_q.count;
      q_a1 <= dut.g_mrp.u_route_a.g_q[1].u_q.count;
    end
  end

  // previous per-plane RX-queue occupancies (level-2 change detection)
  logic [4:0] q_b0, q_b1, q_a0, q_a1;

  // (a)/(b) per-plane delivery: every flit handed to a plane's bridge must carry
  // that plane's FDId, and every DATA flit's MsgCredit word must be tagged with
  // that plane's RP subfield (Table 16).  Misc (§8 activation / CrdtGrant) flits
  // carry MsgCredit = 0 by construction and are exempt from the RP check.
  task automatic chk_delivery(input int p, input flit_t f, input string dir);
    logic [MSGTYPE_W-1:0] mt;
    begin
      chk(flit_fdid(f) == FDID_W'(p),
          $sformatf("%s flit delivered to plane %0d carries FDId %0d", dir, p,
                    flit_fdid(f)));
      mt = payload_msgtype(flit_payload(f), 0);
      if (mt != MT_MISC)
        chk(mc_rp(flit_credit(f)) == FDID_W'(p),
            $sformatf("%s data flit on plane %0d carries MsgCredit RP %0d", dir, p,
                      mc_rp(flit_credit(f))));
    end
  endtask

  always @(posedge ACLK) if (ARESETn) begin : mon_route
    for (int p = 0; p < NP; p++) begin
      if (dut.g_mrp.irx_valid[p] && dut.g_mrp.irx_ready[p])
        chk_delivery(p, dut.g_mrp.irx_data[p*PLP_BITS +: PLP_BITS], "B->A");
      if (dut.g_mrp.trx_valid[p] && dut.g_mrp.trx_ready[p])
        chk_delivery(p, dut.g_mrp.trx_data[p*PLP_BITS +: PLP_BITS], "A->B");
    end
  end

  // (b) credit-bank stability: plane 1's §6 counters must not move while only
  // plane 0 has traffic.  Hierarchical, because the whole point is that the
  // counters are physically separate banks, one per plane.
  wire [7:0] p1_cr_wreq  = dut.g_mrp.g_rp[1].u_init.cr_wreq;
  wire [7:0] p1_cr_rreq  = dut.g_mrp.g_rp[1].u_init.cr_rreq;
  wire [7:0] p1_cr_wdata = dut.g_mrp.g_rp[1].u_init.cr_wdata;
  wire [7:0] p1_cr_rdata = dut.g_mrp.g_rp[1].u_tgt.cr_rdata;
  wire [7:0] p1_cr_wresp = dut.g_mrp.g_rp[1].u_tgt.cr_wresp;

  bit        cr_watch;
  logic [7:0] cr_ref_wreq, cr_ref_rreq, cr_ref_wdata, cr_ref_rdata, cr_ref_wresp;
  int        cr_moves;

  always @(posedge ACLK) if (ARESETn && cr_watch) begin : mon_credit
    if ((p1_cr_wreq  !== cr_ref_wreq)  || (p1_cr_rreq  !== cr_ref_rreq) ||
        (p1_cr_wdata !== cr_ref_wdata) || (p1_cr_rdata !== cr_ref_rdata) ||
        (p1_cr_wresp !== cr_ref_wresp)) begin
      cr_moves++;
      chk(1'b0, $sformatf(
          "plane-1 credit bank moved while only plane 0 ran: wreq %0d->%0d rreq %0d->%0d wdata %0d->%0d rdata %0d->%0d wresp %0d->%0d",
          cr_ref_wreq, p1_cr_wreq, cr_ref_rreq, p1_cr_rreq,
          cr_ref_wdata, p1_cr_wdata, cr_ref_rdata, p1_cr_rdata,
          cr_ref_wresp, p1_cr_wresp));
      // resample so one disturbance is not reported every cycle
      cr_ref_wreq  = p1_cr_wreq;  cr_ref_rreq  = p1_cr_rreq;
      cr_ref_wdata = p1_cr_wdata; cr_ref_rdata = p1_cr_rdata;
      cr_ref_wresp = p1_cr_wresp;
    end
  end

  // ==========================================================================
  // Stimulus helpers (portable: one cycle-accurate process drives both planes)
  // ==========================================================================

  task automatic drive_idle();
    begin
      AWVALID = '0; WVALID = '0; WLAST = '0; ARVALID = '0;
    end
  endtask

  task automatic set_aw(input int p, input logic [IW-1:0] id,
                        input logic [AW-1:0] a, input logic [7:0] len);
    begin
      AWID   [p*IW +: IW] = id;   AWADDR [p*AW +: AW] = a;
      AWLEN  [p*8  +: 8]  = len;  AWSIZE [p*3 +: 3]   = SZ4;
      AWBURST[p*2  +: 2]  = BI;   AWPROT [p*3 +: 3]   = 3'b000;
      AWVALID[p] = 1'b1;
    end
  endtask

  task automatic set_ar(input int p, input logic [IW-1:0] id,
                        input logic [AW-1:0] a, input logic [7:0] len);
    begin
      ARID   [p*IW +: IW] = id;   ARADDR [p*AW +: AW] = a;
      ARLEN  [p*8  +: 8]  = len;  ARSIZE [p*3 +: 3]   = SZ4;
      ARBURST[p*2  +: 2]  = BI;   ARPROT [p*3 +: 3]   = 3'b000;
      ARVALID[p] = 1'b1;
    end
  endtask

  task automatic set_w(input int p, input logic [DW-1:0] d, input bit last);
    begin
      WDATA[p*DW +: DW] = d;  WSTRB[p*SW +: SW] = {SW{1'b1}};
      WLAST[p] = last;        WVALID[p] = 1'b1;
    end
  endtask

  // --- phase A: interleaved single-beat writes on BOTH planes ---------------
  // Both planes write the same address list with different data, concurrently.
  task automatic write_phase(input int n, input int len);
    int ai [0:NP-1];
    int wi [0:NP-1];      // transaction index on the W channel
    int wb [0:NP-1];      // beat index within that transaction
    int bi [0:NP-1];
    int p;
    bit done;
    begin
      for (p = 0; p < NP; p++) begin ai[p] = 0; wi[p] = 0; wb[p] = 0; bi[p] = 0; end
      done = 1'b0;
      while (!done) begin
        @(negedge ACLK);
        for (p = 0; p < NP; p++) begin
          if (ai[p] < n) set_aw(p, t_id[p][ai[p]], t_addr[p][ai[p]], 8'(len));
          else           AWVALID[p] = 1'b0;
          if (wi[p] < n) set_w(p, t_data[p][wi[p]] + DW'(wb[p]), wb[p] == len);
          else begin WVALID[p] = 1'b0; WLAST[p] = 1'b0; end
        end
        @(posedge ACLK);
        for (p = 0; p < NP; p++) begin
          if (AWVALID[p] && AWREADY[p]) begin
            if (verbose) aou_emit($sformatf("[MRP-TB][T] rp%0d AW  txn %0d addr=0x%05h",
                                            p, ai[p], t_addr[p][ai[p]]));
            ai[p]++;
          end
          if (WVALID[p] && WREADY[p]) begin
            if (wb[p] == len) begin wb[p] = 0; wi[p]++; end
            else                    wb[p]++;
          end
          if (BVALID[p] && BREADY[p]) begin
            chk(BRESP[p*2 +: 2] === 2'b00,
                $sformatf("rp%0d BRESP txn %0d", p, bi[p]));
            chk(BID[p*IW +: IW] === t_id[p][bi[p]],
                $sformatf("rp%0d BID txn %0d: got %0d exp %0d", p, bi[p],
                          BID[p*IW +: IW], t_id[p][bi[p]]));
            if (verbose) aou_emit($sformatf("[MRP-TB][T] rp%0d B   txn %0d", p, bi[p]));
            bi[p]++;
          end
        end
        done = 1'b1;
        for (p = 0; p < NP; p++) if (bi[p] < n) done = 1'b0;
      end
      @(negedge ACLK); drive_idle();
    end
  endtask

  // --- phase B: interleaved single-beat reads on BOTH planes ----------------
  // Each plane must read back ITS OWN data from the SAME addresses.
  task automatic read_phase(input int n, input int len);
    int ai [0:NP-1];
    int ri [0:NP-1];
    int rb [0:NP-1];
    int p;
    bit done;
    logic [AW-1:0] ea;
    begin
      for (p = 0; p < NP; p++) begin ai[p] = 0; ri[p] = 0; rb[p] = 0; end
      done = 1'b0;
      while (!done) begin
        @(negedge ACLK);
        for (p = 0; p < NP; p++) begin
          if (ai[p] < n) set_ar(p, t_id[p][ai[p]], t_addr[p][ai[p]], 8'(len));
          else           ARVALID[p] = 1'b0;
        end
        @(posedge ACLK);
        for (p = 0; p < NP; p++) begin
          if (ARVALID[p] && ARREADY[p]) ai[p]++;
          if (RVALID[p] && RREADY[p]) begin
            ea = t_addr[p][ri[p]] + AW'(rb[p] << 2);
            beats++;
            chk(RRESP[p*2 +: 2] === 2'b00, $sformatf("rp%0d RRESP txn %0d", p, ri[p]));
            chk(RLAST[p] === (rb[p] == len),
                $sformatf("rp%0d RLAST txn %0d beat %0d", p, ri[p], rb[p]));
            chk(RID[p*IW +: IW] === t_id[p][ri[p]],
                $sformatf("rp%0d RID txn %0d", p, ri[p]));
            chk(RDATA[p*DW +: DW] === ref_mem[p][ea[MEM_ADDR_W-1:2]],
                $sformatf("rp%0d txn %0d beat %0d @0x%05h: got 0x%08h exp 0x%08h (cross-plane data leak?)",
                          p, ri[p], rb[p], ea, RDATA[p*DW +: DW],
                          ref_mem[p][ea[MEM_ADDR_W-1:2]]));
            if (verbose) aou_emit($sformatf("[MRP-TB][T] rp%0d R   txn %0d beat %0d data=0x%08h",
                                            p, ri[p], rb[p], RDATA[p*DW +: DW]));
            if (rb[p] == len) begin rb[p] = 0; ri[p]++; end
            else                    rb[p]++;
          end
        end
        done = 1'b1;
        for (p = 0; p < NP; p++) if (ri[p] < n) done = 1'b0;
      end
      @(negedge ACLK); drive_idle();
    end
  endtask

  // --- single-plane traffic (used with the other plane idle / jammed) -------
  // One write + one read-back per iteration on plane `p` only.
  task automatic solo_traffic(input int p, input int n, input logic [AW-1:0] base);
    int i, ai, wi, bi, ri;
    logic [DW-1:0] d;
    logic [AW-1:0] a;
    begin
      for (i = 0; i < n; i++) begin
        a = base + AW'(i << 2);
        d = 32'hC0DE_0000 + DW'(p << 12) + DW'(i);
        ref_mem[p][a[MEM_ADDR_W-1:2]] = d;
        // write
        ai = 0; wi = 0; bi = 0;
        while (bi == 0) begin
          @(negedge ACLK);
          if (ai == 0) set_aw(p, 4'd1, a, 8'd0); else AWVALID[p] = 1'b0;
          if (wi == 0) set_w(p, d, 1'b1); else begin WVALID[p] = 1'b0; WLAST[p] = 1'b0; end
          @(posedge ACLK);
          if (AWVALID[p] && AWREADY[p]) ai = 1;
          if (WVALID[p] && WREADY[p])   wi = 1;
          if (BVALID[p] && BREADY[p]) begin
            chk(BRESP[p*2 +: 2] === 2'b00, $sformatf("rp%0d solo BRESP %0d", p, i));
            bi = 1;
          end
        end
        @(negedge ACLK); AWVALID[p] = 1'b0; WVALID[p] = 1'b0; WLAST[p] = 1'b0;
        // read back
        ai = 0; ri = 0;
        while (ri == 0) begin
          @(negedge ACLK);
          if (ai == 0) set_ar(p, 4'd1, a, 8'd0); else ARVALID[p] = 1'b0;
          @(posedge ACLK);
          if (ARVALID[p] && ARREADY[p]) ai = 1;
          if (RVALID[p] && RREADY[p]) begin
            beats++;
            chk(RDATA[p*DW +: DW] === d,
                $sformatf("rp%0d solo read %0d: got 0x%08h exp 0x%08h",
                          p, i, RDATA[p*DW +: DW], d));
            ri = 1;
          end
        end
        @(negedge ACLK); ARVALID[p] = 1'b0;
      end
    end
  endtask

  // --- phase C: issue a long read on plane 0 that is never drained ----------
  // Plane 0's AXI master stops accepting R beats, so its ReadData credits run
  // out and its chain wedges with flits queued behind it.  Plane 1 must be
  // completely unaffected.
  task automatic jam_plane0_issue(input logic [AW-1:0] a);
    int ai;
    begin
      ai = 0;
      while (ai == 0) begin
        @(negedge ACLK);
        set_ar(0, 4'd2, a, 8'(JLEN));
        @(posedge ACLK);
        if (ARVALID[0] && ARREADY[0]) ai = 1;
      end
      @(negedge ACLK); ARVALID[0] = 1'b0;
    end
  endtask

  // Drain the jammed read once RREADY is re-asserted; check every beat.
  task automatic jam_plane0_drain(input logic [AW-1:0] a);
    int b;
    logic [AW-1:0] ea;
    begin
      b = 0;
      RREADY[0] = 1'b1;
      while (b <= JLEN) begin
        @(posedge ACLK);
        if (RVALID[0] && RREADY[0]) begin
          ea = a + AW'(b << 2);
          beats++;
          chk(RDATA[0*DW +: DW] === ref_mem[0][ea[MEM_ADDR_W-1:2]],
              $sformatf("rp0 jammed-read beat %0d @0x%05h: got 0x%08h exp 0x%08h",
                        b, ea, RDATA[0*DW +: DW], ref_mem[0][ea[MEM_ADDR_W-1:2]]));
          chk(RLAST[0] === (b == JLEN),
              $sformatf("rp0 jammed-read RLAST beat %0d", b));
          b++;
        end
      end
    end
  endtask

  int i, p;
  int tx0_before, tx1_before;

  initial begin
    ARESETn = 1'b0;
    AWID = '0; AWADDR = '0; AWLEN = '0; AWSIZE = '0; AWBURST = '0; AWPROT = '0;
    WDATA = '0; WSTRB = '0;
    ARID = '0; ARADDR = '0; ARLEN = '0; ARSIZE = '0; ARBURST = '0; ARPROT = '0;
    drive_idle();
    BREADY = {NP{1'b1}}; RREADY = {NP{1'b1}};
    errors = 0; beats = 0; a_switch = 0; a_last = -1;
    contend_cyc = 0;
    for (p = 0; p < NP; p++) con_grant[p] = 0;
    cr_watch = 1'b0; cr_moves = 0;
    for (p = 0; p < NP; p++) begin tx_cnt[p] = 0; rx_cnt[p] = 0; end
    aou_log_init("[MRP-TB]");
    verbose = (aou_lvl >= 1);

    for (p = 0; p < NP; p++)
      for (i = 0; i < WORDS; i++) ref_mem[p][i] = '0;

    // Same addresses on both planes, DIFFERENT data and DIFFERENT IDs: a
    // response or a memory image leaking across planes is a hard mismatch.
    for (p = 0; p < NP; p++) begin
      for (i = 0; i < NT; i++) begin
        t_addr[p][i] = 32'h0100 + AW'(i << 4);
        t_data[p][i] = 32'hA0000000 + DW'(p << 20) + DW'(i);
        t_id  [p][i] = 4'((p*4 + i) % 8);
        ref_mem[p][t_addr[p][i][MEM_ADDR_W-1:2]] = t_data[p][i];
      end
    end

    repeat (3) @(negedge ACLK);
    ARESETn = 1'b1;
    @(negedge ACLK);

    // --- phase A + B: interleaved two-plane single-beat traffic -------------
    write_phase(NT, 0);
    read_phase(NT, 0);

    // --- phase A2 + B2: concurrent multi-beat INCR bursts on BOTH planes ----
    // Back-to-back WriteData / ReadData flits from both planes at once: this is
    // what puts the shared link under real contention, so the round-robin
    // arbiter's fairness (con_grant below) is measured on a saturated link.
    for (p = 0; p < NP; p++)
      for (i = 0; i < NB; i++) begin
        t_addr[p][i] = 32'h0400 + AW'(i << 6);
        t_data[p][i] = 32'hB0000000 + DW'(p << 20) + DW'(i << 4);
        t_id  [p][i] = 4'((p*2 + i) % 8);
        for (int b = 0; b <= BLEN; b++)
          ref_mem[p][32'(t_addr[p][i][MEM_ADDR_W-1:2]) + b] = t_data[p][i] + DW'(b);
      end
    write_phase(NB, BLEN);
    read_phase(NB, BLEN);

    // --- phase C: credit-bank isolation (plane 1 idle, plane 0 busy) --------
    // Sample plane 1's credit bank, then run plane-0-only traffic and require
    // that not one of plane 1's counters moves.
    @(negedge ACLK);
    cr_ref_wreq  = p1_cr_wreq;  cr_ref_rreq  = p1_cr_rreq;
    cr_ref_wdata = p1_cr_wdata; cr_ref_rdata = p1_cr_rdata;
    cr_ref_wresp = p1_cr_wresp;
    // a plane that never ran must still be fully credited by its own peer
    chk(cr_ref_wreq  != 8'd0, "plane 1 was never granted WriteReq credits");
    chk(cr_ref_wdata != 8'd0, "plane 1 was never granted WriteData credits");
    chk(cr_ref_rdata != 8'd0, "plane 1 was never granted ReadData credits");
    cr_watch = 1'b1;
    solo_traffic(0, NSOLO, 32'h0800);
    @(negedge ACLK);
    cr_watch = 1'b0;

    // --- phase D: starvation isolation --------------------------------------
    // Jam plane 0 (issue a 16-beat read, then never accept an R beat) and run
    // plane-1 traffic to completion right through it.
    tx0_before = tx_cnt[0];
    tx1_before = tx_cnt[1];
    @(negedge ACLK); RREADY[0] = 1'b0;
    jam_plane0_issue(32'h0100);
    solo_traffic(1, NISO, 32'h0C00);
    chk(tx_cnt[0] > tx0_before,
        "plane 0 never issued its jammed read (the jam scenario did not arm)");
    chk(tx_cnt[1] > tx1_before,
        "plane 1 sent no flits while plane 0 was jammed (cross-plane stall)");
    // now release plane 0 — its wedged burst must still complete correctly
    @(negedge ACLK);
    jam_plane0_drain(32'h0100);
    @(negedge ACLK);

    // --- acceptance checks --------------------------------------------------
    for (p = 0; p < NP; p++)
      chk(tx_cnt[p] > 0, $sformatf("plane %0d never got a shared-link grant (starved)", p));
    for (p = 0; p < NP; p++)
      chk(rx_cnt[p] > 0, $sformatf("plane %0d never received a response flit", p));
    chk(a_switch > 4,
        $sformatf("planes did not interleave on the shared link (%0d switches)", a_switch));
    chk(contend_cyc > 0,
        "the two planes never contended for the shared link (fairness untested)");
    for (p = 0; p < NP; p++)
      chk(con_grant[p] > 0,
          $sformatf("plane %0d never won a CONTENDED grant — the arbiter starves it", p));
    chk(cr_moves == 0, "plane-1 credit bank was disturbed by plane-0 traffic");

    if (errors == 0)
      $display("[MRP-TB] PASS: %0d planes, %0d read beats checked, A->B flits rp0=%0d rp1=%0d (%0d interleavings), %0d contended cycles won rp0=%0d rp1=%0d, 0 errors",
               NP, beats, tx_cnt[0], tx_cnt[1], a_switch, contend_cyc,
               con_grant[0], con_grant[1]);
    else
      $display("[MRP-TB] FAIL: %0d planes, %0d read beats checked, A->B flits rp0=%0d rp1=%0d (%0d interleavings), %0d contended cycles won rp0=%0d rp1=%0d, %0d errors",
               NP, beats, tx_cnt[0], tx_cnt[1], a_switch, contend_cyc,
               con_grant[0], con_grant[1], errors);
    aou_log_close();
    $finish;
  end

  // watchdog — also catches a cross-plane stall that never resolves
  initial begin
    #4000000;
    $display("[MRP-TB] FAIL: timeout (errors=%0d beats=%0d rp0_flits=%0d rp1_flits=%0d)",
             errors, beats, tx_cnt[0], tx_cnt[1]);
    aou_log_close();
    $finish;
  end

endmodule
`endif
