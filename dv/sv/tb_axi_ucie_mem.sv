// -----------------------------------------------------------------------------
// tb_axi_ucie_mem : self-checking SystemVerilog directed testbench.
//
// A portable, cocotb-free testbench for axi_ucie_mem_top that runs under BOTH
// Icarus (iverilog -g2012 + vvp) and Verilator (--binary --timing).  It drives
// the AXI4 front door with burst-capable master tasks (INCR/WRAP/FIXED,
// AxLEN beats, AxID tags), keeps a reference word memory, and self-checks every
// read beat (data, RRESP, RID, RLAST).  A watchdog guards against hangs.
//
// Master simplification: BREADY / RREADY are tied high (this master always
// accepts responses).  Most sections issue one transaction (burst) at a time,
// but the multiple-outstanding section fires several AR handshakes (RREADY held
// low) before draining, exercising the initiator request queue up to full and
// checking in-order completion.  Burst addresses are sequenced by nxt_addr(), an
// independent copy of the AXI rule (not the DUT's axi_burst_next).
// -----------------------------------------------------------------------------
`ifndef TB_AXI_UCIE_MEM_SV
`define TB_AXI_UCIE_MEM_SV

module tb_axi_ucie_mem;

  localparam int AW         = 32;
  localparam int DW         = 32;
  localparam int SW         = DW/8;
  localparam int IW         = 4;                  // AXI ID width
  localparam int MEM_ADDR_W = 16;                 // must match the DUT default
  localparam int WORDS      = 1 << (MEM_ADDR_W-2);
  localparam logic [2:0] SZ4 = 3'd2;              // 4-byte beat (32-bit)
  localparam logic [1:0] BF = 2'b00, BI = 2'b01, BW = 2'b10;  // FIXED/INCR/WRAP
  localparam int NO = 5;                          // outstanding reads (fills queue)

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
  int            errors, reads;

  // independent AXI next-beat address (mirror of the spec rule)
  function automatic logic [AW-1:0] nxt_addr(input logic [AW-1:0] a, base,
                                             input logic [1:0] bt,
                                             input logic [2:0] sz,
                                             input logic [7:0] ln);
    logic [AW-1:0] nb, tot, low;
    begin
      nb = (1 << sz);
      case (bt)
        BF:      nxt_addr = a;                                   // FIXED
        BW: begin                                               // WRAP
          tot = ({24'b0, ln} + 1) << sz;
          low = base & ~(tot - 1);
          nxt_addr = ((a + nb) == (low + tot)) ? low : (a + nb);
        end
        default: nxt_addr = a + nb;                             // INCR
      endcase
    end
  endfunction

  // --- burst-capable AXI4 master tasks -------------------------------------
  task automatic axi_wburst(input logic [IW-1:0] id, input logic [AW-1:0] addr,
                            input logic [7:0] len, input logic [1:0] bt,
                            input logic [DW-1:0] d0, input logic [DW-1:0] dstep);
    logic [AW-1:0] a;
    int k;
    begin
      @(negedge ACLK);
      AWID = id; AWADDR = addr; AWLEN = len; AWSIZE = SZ4; AWBURST = bt;
      AWPROT = 3'b000; AWVALID = 1'b1;
      @(posedge ACLK); while (!AWREADY) @(posedge ACLK);
      @(negedge ACLK); AWVALID = 1'b0;
      a = addr;
      for (k = 0; k <= len; k++) begin
        @(negedge ACLK);
        WDATA = d0 + k*dstep; WSTRB = {SW{1'b1}};
        WLAST = (k == int'(len)); WVALID = 1'b1;
        @(posedge ACLK); while (!WREADY) @(posedge ACLK);
        ref_mem[a[MEM_ADDR_W-1:2]] = d0 + k*dstep;
        a = nxt_addr(a, addr, bt, SZ4, len);
        @(negedge ACLK); WVALID = 1'b0; WLAST = 1'b0;
      end
      @(posedge ACLK); while (!BVALID) @(posedge ACLK);
      if (BRESP !== 2'b00) begin errors++; $display("[SV-TB] bad BRESP=%b", BRESP); end
      if (BID   !== id)    begin errors++; $display("[SV-TB] BID got %0d exp %0d", BID, id); end
    end
  endtask

  task automatic axi_rburst(input logic [IW-1:0] id, input logic [AW-1:0] addr,
                            input logic [7:0] len, input logic [1:0] bt);
    logic [AW-1:0] a;
    int k;
    begin
      @(negedge ACLK);
      ARID = id; ARADDR = addr; ARLEN = len; ARSIZE = SZ4; ARBURST = bt;
      ARPROT = 3'b000; ARVALID = 1'b1;
      @(posedge ACLK); while (!ARREADY) @(posedge ACLK);
      @(negedge ACLK); ARVALID = 1'b0;
      a = addr;
      for (k = 0; k <= len; k++) begin
        @(posedge ACLK); while (!RVALID) @(posedge ACLK);
        reads++;
        if (RDATA !== ref_mem[a[MEM_ADDR_W-1:2]]) begin
          errors++;
          $display("[SV-TB] MISMATCH beat %0d @0x%05h: got 0x%08h exp 0x%08h",
                   k, a, RDATA, ref_mem[a[MEM_ADDR_W-1:2]]);
        end
        if (RRESP !== 2'b00)         begin errors++; $display("[SV-TB] bad RRESP"); end
        if (RID   !== id)            begin errors++; $display("[SV-TB] RID mismatch"); end
        if (RLAST !== (k == int'(len)))    begin errors++; $display("[SV-TB] RLAST mismatch beat %0d", k); end
        a = nxt_addr(a, addr, bt, SZ4, len);
        @(negedge ACLK);
      end
    end
  endtask

  // single-beat convenience wrappers (AWLEN=0, INCR)
  task automatic axi_write(input logic [AW-1:0] addr, input logic [DW-1:0] data);
    axi_wburst(4'd0, addr, 8'd0, BI, data, 32'd0);
  endtask
  task automatic axi_read(input logic [AW-1:0] addr);
    axi_rburst(4'd0, addr, 8'd0, BI);
  endtask

  // --- stimulus -------------------------------------------------------------
  logic [AW-1:0] a;
  logic [DW-1:0] d;
  int            i, j;

  initial begin
    ARESETn = 1'b0;
    AWVALID = 1'b0; WVALID = 1'b0; ARVALID = 1'b0; WLAST = 1'b0;
    AWID = '0; AWADDR = '0; AWLEN = '0; AWSIZE = '0; AWBURST = '0; AWPROT = '0;
    WDATA = '0; WSTRB = '0;
    ARID = '0; ARADDR = '0; ARLEN = '0; ARSIZE = '0; ARBURST = '0; ARPROT = '0;
    BREADY = 1'b1; RREADY = 1'b1;
    errors = 0; reads = 0;
    for (i = 0; i < WORDS; i++) ref_mem[i] = '0;
    repeat (3) @(negedge ACLK);
    ARESETn = 1'b1;
    @(negedge ACLK);

    // 1) single-beat write-read pairs (constrained-random addr/data)
    for (i = 0; i < 30; i++) begin
      a = ({$random} % WORDS) << 2;
      d = $random;
      axi_write(a, d);
      axi_read(a);
    end

    // 2) INCR bursts of assorted lengths, then read-back and check every beat
    begin : incr_bursts
      int lens [0:3];
      lens[0]=1; lens[1]=3; lens[2]=7; lens[3]=15;
      for (i = 0; i < 4; i++) begin
        a = (({$random} % (WORDS-16)) << 2);
        axi_wburst(4'(i+1), a, 8'(lens[i]), BI, 32'hA0000000 + i*16, 32'h11);
        axi_rburst(4'(i+1), a, 8'(lens[i]), BI);
      end
    end

    // 3) WRAP bursts (len+1 in {2,4,8,16}); address wraps at the aligned boundary
    begin : wrap_bursts
      int wl [0:3];
      wl[0]=1; wl[1]=3; wl[2]=7; wl[3]=15;
      for (i = 0; i < 4; i++) begin
        // pick a non-aligned start inside the wrap window to exercise wrapping
        a = (32'h100 + (i*4)) & ~32'h3;
        axi_wburst(4'(i+2), a, 8'(wl[i]), BW, 32'hB0000000 + i*16, 32'h07);
        axi_rburst(4'(i+2), a, 8'(wl[i]), BW);
      end
    end

    // 4) FIXED bursts: all beats hit the same address (last write wins)
    begin : fixed_bursts
      a = 32'h40 & ~32'h3;
      axi_wburst(4'd9, a, 8'd3, BF, 32'hF0000000, 32'h01);   // 4 beats, same addr
      axi_rburst(4'd9, a, 8'd3, BF);
    end

    // 4b) MULTIPLE-OUTSTANDING reads: pre-load known data, then fire NO AR
    //     handshakes with RREADY held low so they pile into the initiator
    //     request queue (up to full); drain in issue order and check every beat.
    begin : multi_outstanding
      logic [AW-1:0] oa  [0:NO-1];
      logic [7:0]    ol  [0:NO-1];
      logic [IW-1:0] oid [0:NO-1];
      logic [AW-1:0] ca;
      int m, k;
      ol[0]=8'd0; ol[1]=8'd3; ol[2]=8'd1; ol[3]=8'd7; ol[4]=8'd0;
      for (m = 0; m < NO; m++) begin
        oa[m]  = 32'h800 + (m << 6);
        oid[m] = 4'(m + 1);
        axi_wburst(oid[m], oa[m], ol[m], BI, 32'hC0000000 + (m << 8), 32'h13);
      end
      // Phase 1: hold RREADY low and fire every AR handshake -> they queue up.
      RREADY = 1'b0;
      for (m = 0; m < NO; m++) begin
        @(negedge ACLK);
        ARID = oid[m]; ARADDR = oa[m]; ARLEN = ol[m]; ARSIZE = SZ4;
        ARBURST = BI; ARPROT = 3'b000; ARVALID = 1'b1;
        @(posedge ACLK); while (!ARREADY) @(posedge ACLK);
        @(negedge ACLK); ARVALID = 1'b0;
      end
      // Phase 2: drain in issue order (in-order completion) and self-check.
      RREADY = 1'b1;
      for (m = 0; m < NO; m++) begin
        ca = oa[m];
        for (k = 0; k <= int'(ol[m]); k++) begin
          @(posedge ACLK); while (!RVALID) @(posedge ACLK);
          reads++;
          if (RDATA !== ref_mem[ca[MEM_ADDR_W-1:2]]) begin
            errors++;
            $display("[SV-TB] MO MISMATCH req %0d beat %0d @0x%05h: got 0x%08h exp 0x%08h",
                     m, k, ca, RDATA, ref_mem[ca[MEM_ADDR_W-1:2]]);
          end
          if (RID   !== oid[m])              begin errors++; $display("[SV-TB] MO RID mismatch req %0d", m); end
          if (RLAST !== (k == int'(ol[m])))  begin errors++; $display("[SV-TB] MO RLAST mismatch req %0d beat %0d", m, k); end
          ca = nxt_addr(ca, oa[m], BI, SZ4, ol[m]);
          @(negedge ACLK);
        end
      end
    end

    // 5) walking single-beat edge cases
    begin : walking
      logic [AW-1:0] edge_a [0:3];
      logic [DW-1:0] edge_d [0:5];
      edge_a[0]=32'h0; edge_a[1]=32'h4;
      edge_a[2]=(WORDS-2)<<2; edge_a[3]=(WORDS-1)<<2;
      edge_d[0]=32'h0; edge_d[1]=32'h1; edge_d[2]=32'h5555_5555;
      edge_d[3]=32'hAAAA_AAAA; edge_d[4]=32'hFFFF_FFFF; edge_d[5]=32'hDEAD_BEEF;
      for (i = 0; i < 4; i++)
        for (j = 0; j < 6; j++) begin
          axi_write(edge_a[i], edge_d[j]);
          axi_read(edge_a[i]);
        end
    end

    if (errors == 0)
      $display("[SV-TB] PASS: %0d reads checked, 0 errors", reads);
    else
      $display("[SV-TB] FAIL: %0d reads checked, %0d errors", reads, errors);
    $finish;
  end

  // watchdog
  initial begin
    #2000000;
    $display("[SV-TB] FAIL: timeout");
    $finish;
  end

endmodule
`endif
