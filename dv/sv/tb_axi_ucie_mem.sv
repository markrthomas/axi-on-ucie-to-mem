// -----------------------------------------------------------------------------
// tb_axi_ucie_mem : self-checking SystemVerilog directed testbench.
//
// A portable, cocotb-free testbench for axi_ucie_mem_top that runs under BOTH
// Icarus (iverilog -g2012 + vvp) and Verilator (--binary --timing).  It drives
// the AXI4-Lite front door with simple master tasks, keeps a reference word
// memory, and self-checks every read.  Exit code / $finish + a PASS/FAIL banner
// make it a pass/fail gate; a watchdog guards against hangs.
//
// Master simplification: BREADY / RREADY are tied high (this master always
// accepts responses), and AW+W are issued together (the DUT asserts both readies
// in its IDLE state), so the tasks only wait for the readies then the response.
// -----------------------------------------------------------------------------
`ifndef TB_AXI_UCIE_MEM_SV
`define TB_AXI_UCIE_MEM_SV

module tb_axi_ucie_mem;

  localparam int AW         = 32;
  localparam int DW         = 32;
  localparam int SW         = DW/8;
  localparam int MEM_ADDR_W = 16;                 // must match the DUT default
  localparam int WORDS      = 1 << (MEM_ADDR_W-2);

  logic             ACLK;
  logic             ARESETn;
  logic [AW-1:0]    AWADDR;  logic [2:0] AWPROT;  logic AWVALID, AWREADY;
  logic [DW-1:0]    WDATA;   logic [SW-1:0] WSTRB; logic WVALID, WREADY;
  logic [1:0]       BRESP;   logic BVALID, BREADY;
  logic [AW-1:0]    ARADDR;  logic [2:0] ARPROT;  logic ARVALID, ARREADY;
  logic [DW-1:0]    RDATA;   logic [1:0] RRESP;    logic RVALID, RREADY;

  axi_ucie_mem_top #(
    .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .MEM_ADDR_W(MEM_ADDR_W)
  ) dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWADDR(AWADDR), .AWPROT(AWPROT), .AWVALID(AWVALID), .AWREADY(AWREADY),
    .WDATA(WDATA),   .WSTRB(WSTRB),   .WVALID(WVALID),   .WREADY(WREADY),
    .BRESP(BRESP),   .BVALID(BVALID), .BREADY(BREADY),
    .ARADDR(ARADDR), .ARPROT(ARPROT), .ARVALID(ARVALID), .ARREADY(ARREADY),
    .RDATA(RDATA),   .RRESP(RRESP),   .RVALID(RVALID),   .RREADY(RREADY)
  );

  // 100 MHz clock
  initial ACLK = 1'b0;
  always #5 ACLK = ~ACLK;

  // reference memory (word-indexed) + error counter
  logic [DW-1:0] ref_mem [0:WORDS-1];
  int            errors, reads;

  // --- AXI4-Lite master tasks ----------------------------------------------
  task automatic axi_write(input logic [AW-1:0] addr, input logic [DW-1:0] data);
    @(negedge ACLK);
    AWADDR  = addr; AWPROT = 3'b000; AWVALID = 1'b1;
    WDATA   = data; WSTRB  = {SW{1'b1}}; WVALID = 1'b1;
    @(posedge ACLK);
    while (!(AWREADY && WREADY)) @(posedge ACLK);
    @(negedge ACLK); AWVALID = 1'b0; WVALID = 1'b0;
    @(posedge ACLK);
    while (!BVALID) @(posedge ACLK);
    if (BRESP !== 2'b00) begin
      errors++; $display("[SV-TB] bad BRESP=%b @0x%05h", BRESP, addr);
    end
  endtask

  task automatic axi_read(input logic [AW-1:0] addr, output logic [DW-1:0] data);
    @(negedge ACLK);
    ARADDR = addr; ARPROT = 3'b000; ARVALID = 1'b1;
    @(posedge ACLK);
    while (!ARREADY) @(posedge ACLK);
    @(negedge ACLK); ARVALID = 1'b0;
    @(posedge ACLK);
    while (!RVALID) @(posedge ACLK);
    data = RDATA;
    if (RRESP !== 2'b00) begin
      errors++; $display("[SV-TB] bad RRESP=%b @0x%05h", RRESP, addr);
    end
  endtask

  task automatic check(input logic [AW-1:0] addr, input logic [DW-1:0] got,
                       input logic [DW-1:0] exp);
    reads++;
    if (got !== exp) begin
      errors++;
      $display("[SV-TB] MISMATCH @0x%05h: got 0x%08h exp 0x%08h", addr, got, exp);
    end
  endtask

  // --- stimulus -------------------------------------------------------------
  logic [DW-1:0] rd;
  logic [AW-1:0] a;
  logic [DW-1:0] d;
  int            i, j;

  initial begin
    // idle + reset
    ARESETn = 1'b0;
    AWVALID = 1'b0; WVALID = 1'b0; ARVALID = 1'b0;
    AWADDR = '0; WDATA = '0; WSTRB = '0; AWPROT = '0; ARADDR = '0; ARPROT = '0;
    BREADY = 1'b1; RREADY = 1'b1;   // always accept responses
    errors = 0; reads = 0;
    for (i = 0; i < WORDS; i++) ref_mem[i] = '0;
    repeat (3) @(negedge ACLK);
    ARESETn = 1'b1;
    @(negedge ACLK);

    // 1) directed write-read pairs (constrained-random addr/data)
    for (i = 0; i < 40; i++) begin
      a = ({$random} % WORDS) << 2;
      d = $random;
      axi_write(a, d); ref_mem[a[MEM_ADDR_W-1:2]] = d;
      axi_read(a, rd); check(a, rd, ref_mem[a[MEM_ADDR_W-1:2]]);
    end

    // 2) walking edge cases: first/last address x patterned payloads
    begin : walking
      logic [AW-1:0] edge_a [0:3];
      logic [DW-1:0] edge_d [0:5];
      edge_a[0] = 32'h0;        edge_a[1] = 32'h4;
      edge_a[2] = (WORDS-2)<<2; edge_a[3] = (WORDS-1)<<2;
      edge_d[0] = 32'h0000_0000; edge_d[1] = 32'h0000_0001;
      edge_d[2] = 32'h5555_5555; edge_d[3] = 32'hAAAA_AAAA;
      edge_d[4] = 32'hFFFF_FFFF; edge_d[5] = 32'hDEAD_BEEF;
      for (i = 0; i < 4; i++)
        for (j = 0; j < 6; j++) begin
          axi_write(edge_a[i], edge_d[j]);
          ref_mem[edge_a[i][MEM_ADDR_W-1:2]] = edge_d[j];
          axi_read(edge_a[i], rd);
          check(edge_a[i], rd, ref_mem[edge_a[i][MEM_ADDR_W-1:2]]);
        end
    end

    // 3) read-back of an un-written location returns 0
    a = 32'h1234 & ~32'h3;
    axi_read(a, rd); check(a, rd, 32'h0);

    if (errors == 0)
      $display("[SV-TB] PASS: %0d reads checked, 0 errors", reads);
    else
      $display("[SV-TB] FAIL: %0d reads checked, %0d errors", reads, errors);
    $finish;
  end

  // watchdog
  initial begin
    #500000;
    $display("[SV-TB] FAIL: timeout");
    $finish;
  end

endmodule
`endif
