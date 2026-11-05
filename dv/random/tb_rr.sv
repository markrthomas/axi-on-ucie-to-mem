// -----------------------------------------------------------------------------
// tb_rr : seeded constrained-random AXI4 master for axi_ucie_mem_top.
//
// Uses the SAME scoreboard as dv/sv/tb_axi_ucie_mem.sv (reference word memory;
// every read beat is checked for data, RRESP, RID, RLAST; every write for
// BRESP/BID) -- no new, weaker checker.  Only what that scoreboard already
// checks is randomized: addresses (inside a window), burst type/length, data,
// idle gaps between transactions and beats, and RREADY back-pressure.
//
// Plusargs: +seed=N  +xfers=N  +maxlen=N(0..15)  +gap=N  +bp=PCT  +win=WORDS
//           +burst=MASK (bit0 INCR, bit1 WRAP, bit2 FIXED)
// Own xorshift32 PRNG seeded once from +seed => identical on every simulator.
// Banners: "[RR-TB] PASS ..." / "[RR-TB] ERR <kind>: ..." / "[RR-TB] FAIL ...".
// -----------------------------------------------------------------------------
module tb_rr
  import aou_pkg::*;
;
  localparam int AW = 32, DW = 32, SW = DW/8, IW = 4, MEM_ADDR_W = 16;
  localparam int WORDS = 1 << (MEM_ADDR_W-2);
  localparam logic [2:0] SZ4 = 3'd2;
  localparam logic [1:0] BF = 2'b00, BI = 2'b01, BW = 2'b10;

  logic             ACLK, ARESETn;
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
    .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .AXI_ID_W(IW), .MEM_ADDR_W(MEM_ADDR_W)
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

  logic [DW-1:0] ref_mem [0:WORDS-1];
  int errors, reads, writes;
  int unsigned prng;
  int cfg_xfers, cfg_maxlen, cfg_gap, cfg_bp, cfg_win, cfg_burst;

  function automatic int unsigned rnd32();
    prng ^= prng << 13; prng ^= prng >> 17; prng ^= prng << 5;
    return prng;
  endfunction
  function automatic int rnd(input int n);   // 0..n-1
    return (n <= 1) ? 0 : int'(rnd32() % unsigned'(n));
  endfunction

  // independent AXI next-beat address (same rule as dv/sv)
  function automatic logic [AW-1:0] nxt_addr(input logic [AW-1:0] a, base,
                                             input logic [1:0] bt,
                                             input logic [7:0] ln);
    logic [AW-1:0] tot, low;
    begin
      case (bt)
        BF:      nxt_addr = a;
        BW: begin
          tot = ({24'b0, ln} + 1) << 2;
          low = base & ~(tot - 1);
          nxt_addr = ((a + 4) == (low + tot)) ? low : (a + 4);
        end
        default: nxt_addr = a + 4;
      endcase
    end
  endfunction

  task automatic idle(input int n);
    repeat (n) @(negedge ACLK);
  endtask

  task automatic wburst(input logic [IW-1:0] id, input logic [AW-1:0] addr,
                        input logic [7:0] len, input logic [1:0] bt);
    logic [AW-1:0] a;
    logic [DW-1:0] d;
    int k;
    begin
      @(negedge ACLK);
      AWID = id; AWADDR = addr; AWLEN = len; AWSIZE = SZ4; AWBURST = bt;
      AWPROT = 3'b000; AWVALID = 1'b1;
      @(posedge ACLK); while (!AWREADY) @(posedge ACLK);
      @(negedge ACLK); AWVALID = 1'b0;
      a = addr;
      for (k = 0; k <= len; k++) begin
        if (cfg_gap > 0 && rnd(4) == 0) idle(rnd(cfg_gap + 1));   // W-channel gap
        @(negedge ACLK);
        d = rnd32();
        WDATA = d; WSTRB = {SW{1'b1}};
        WLAST = (k == int'(len)); WVALID = 1'b1;
        @(posedge ACLK); while (!WREADY) @(posedge ACLK);
        ref_mem[a[MEM_ADDR_W-1:2]] = d;
        a = nxt_addr(a, addr, bt, len);
        @(negedge ACLK); WVALID = 1'b0; WLAST = 1'b0;
      end
      @(posedge ACLK); while (!BVALID) @(posedge ACLK);
      writes++;
      if (BRESP !== 2'b00) begin errors++; $display("[RR-TB] ERR bad-bresp: BRESP=%b", BRESP); end
      if (BID   !== id)    begin errors++; $display("[RR-TB] ERR bid-mismatch: got %0d exp %0d", BID, id); end
    end
  endtask

  task automatic rburst(input logic [IW-1:0] id, input logic [AW-1:0] addr,
                        input logic [7:0] len, input logic [1:0] bt);
    logic [AW-1:0] a;
    int k;
    bit got;
    begin
      @(negedge ACLK);
      ARID = id; ARADDR = addr; ARLEN = len; ARSIZE = SZ4; ARBURST = bt;
      ARPROT = 3'b000; ARVALID = 1'b1;
      @(posedge ACLK); while (!ARREADY) @(posedge ACLK);
      @(negedge ACLK); ARVALID = 1'b0;
      a = addr;
      for (k = 0; k <= len; k++) begin
        got = 1'b0;
        while (!got) begin                       // random RREADY back-pressure
          RREADY = (rnd(100) >= cfg_bp);
          @(posedge ACLK);
          got = RVALID && RREADY;
          if (!got) @(negedge ACLK);
        end
        reads++;
        if (RDATA !== ref_mem[a[MEM_ADDR_W-1:2]]) begin
          errors++;
          $display("[RR-TB] ERR data-mismatch: beat %0d @0x%05h got 0x%08h exp 0x%08h",
                   k, a, RDATA, ref_mem[a[MEM_ADDR_W-1:2]]);
        end
        if (RRESP !== 2'b00) begin errors++; $display("[RR-TB] ERR bad-rresp: RRESP=%b", RRESP); end
        if (RID   !== id)    begin errors++; $display("[RR-TB] ERR rid-mismatch: got %0d exp %0d", RID, id); end
        if (RLAST !== (k == int'(len))) begin
          errors++; $display("[RR-TB] ERR rlast-mismatch: beat %0d of %0d", k, int'(len)+1);
        end
        a = nxt_addr(a, addr, bt, len);
        @(negedge ACLK);
      end
      RREADY = 1'b1;
    end
  endtask

  // pick a legal burst (never crosses 4KB; WRAP len+1 in {2,4,8,16})
  task automatic pick(output logic [AW-1:0] addr, output logic [7:0] len,
                      output logic [1:0] bt);
    int w, sel, wl, n;
    int opts [3];
    begin
      n = 0;
      if (cfg_burst[0]) opts[n++] = 0;
      if (cfg_burst[1]) opts[n++] = 1;
      if (cfg_burst[2]) opts[n++] = 2;
      sel = opts[rnd(n)];
      w = rnd(cfg_win);
      case (sel)
        1: begin
          bt = BW; wl = 1 << (1 + rnd(4));        // 2,4,8,16 beats
          if (wl - 1 > cfg_maxlen) wl = 2;
          len = 8'(wl - 1);
        end
        2: begin bt = BF; len = 8'(rnd(cfg_maxlen + 1)); end
        default: begin
          bt = BI; len = 8'(rnd(cfg_maxlen + 1));
          if ((w & 1023) + int'(len) + 1 > 1024) w = w & ~1023;
        end
      endcase
      addr = AW'(w) << 2;
    end
  endtask

  logic [AW-1:0] pa; logic [7:0] pl; logic [1:0] pb;
  int seed_v, n, i;
  initial begin
    if (!$value$plusargs("seed=%d", seed_v))       seed_v = 1;
    if (!$value$plusargs("xfers=%d", cfg_xfers))   cfg_xfers = 200;
    if (!$value$plusargs("maxlen=%d", cfg_maxlen)) cfg_maxlen = 15;
    if (!$value$plusargs("gap=%d", cfg_gap))       cfg_gap = 3;
    if (!$value$plusargs("bp=%d", cfg_bp))         cfg_bp = 25;
    if (!$value$plusargs("win=%d", cfg_win))       cfg_win = WORDS - 16;
    if (!$value$plusargs("burst=%d", cfg_burst))   cfg_burst = 7;
    if (cfg_maxlen > 15) cfg_maxlen = 15;
    if (cfg_win > WORDS - 16) cfg_win = WORDS - 16;
    if (cfg_burst == 0) cfg_burst = 1;
    prng = 32'(seed_v) ^ 32'h9E3779B9;
    if (prng == 0) prng = 1;
    repeat (4) void'(rnd32());

    ARESETn = 1'b0;
    AWVALID = 1'b0; WVALID = 1'b0; ARVALID = 1'b0; WLAST = 1'b0;
    AWID = '0; AWADDR = '0; AWLEN = '0; AWSIZE = '0; AWBURST = '0; AWPROT = '0;
    WDATA = '0; WSTRB = '0;
    ARID = '0; ARADDR = '0; ARLEN = '0; ARSIZE = '0; ARBURST = '0; ARPROT = '0;
    BREADY = 1'b1; RREADY = 1'b1;
    errors = 0; reads = 0; writes = 0;
    for (i = 0; i < WORDS; i++) ref_mem[i] = '0;
    repeat (3) @(negedge ACLK);
    ARESETn = 1'b1;
    @(negedge ACLK);

    for (n = 0; n < cfg_xfers; n++) begin
      pick(pa, pl, pb);
      if (rnd(2) == 0) wburst(4'(rnd(16)), pa, pl, pb);
      else             rburst(4'(rnd(16)), pa, pl, pb);
      idle(rnd(cfg_gap + 1));
    end
    // final sweep: read back a handful of random words
    for (n = 0; n < 8; n++) begin
      pa = AW'(rnd(cfg_win)) << 2;
      rburst(4'(rnd(16)), pa, 8'd0, BI);
    end

    if (errors == 0)
      $display("[RR-TB] PASS: seed=%0d %0d writes %0d read beats, 0 errors, end t=%0t", seed_v, writes, reads, $time);
    else
      $display("[RR-TB] FAIL: seed=%0d %0d errors", seed_v, errors);
    $finish;
  end

  initial begin
    #20000000;
    $display("[RR-TB] ERR timeout: watchdog expired");
    $display("[RR-TB] FAIL: seed=%0d timeout", seed_v);
    $finish;
  end
endmodule
