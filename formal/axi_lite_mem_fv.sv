// -----------------------------------------------------------------------------
// axi_lite_mem_fv : formal property harness for the AXI4-Lite memory target.
//
// The full AoU chain (bridges + pack/unpack + 2000-bit flit datapath) is out of
// reach for the open-source yosys formal frontend — its wide part-select
// functions blow past any sane elaboration time.  The tractable, high-value
// formal target is the far-side memory `axi_lite_mem`, verified here for:
//
//   * AXI4-Lite channel legality  (VALID held until READY; payload stable while
//                                  stalled; responses always OKAY),
//   * no response without a matching outstanding request, and
//   * write -> read DATA INTEGRITY against an independent reference array.
//
// Style is the portable yosys idiom: immediate assert/assume/cover inside a
// clocked block using $past/$stable (yosys rejects `default clocking` and an
// inline `@(posedge clk)` in `assert property`).  A small ADDR_W keeps the proof
// small — combined with `read_verilog -defer` in the .sby so the memory is
// elaborated at this width, not the 64 KiB default.
//
// Master-driven request signals are free formal inputs, CONSTRAINED (assume) to
// obey AXI; slave-driven responses are CHECKED (assert).  Reset is generated
// internally so every trace starts from a defined reset.
// -----------------------------------------------------------------------------
`default_nettype none
module axi_lite_mem_fv #(
    parameter int ADDR_W = 4,               // 4 byte-addr bits -> 4 words
    parameter int DATA_W = 32,
    parameter int STRB_W = DATA_W/8
) (
    input  wire                  ACLK,
    // ---- master-driven request signals (free inputs, constrained below) ----
    input  wire [ADDR_W-1:0]     AWADDR,
    input  wire [2:0]            AWPROT,
    input  wire                  AWVALID,
    input  wire [DATA_W-1:0]     WDATA,
    input  wire [STRB_W-1:0]     WSTRB,
    input  wire                  WVALID,
    input  wire                  BREADY,
    input  wire [ADDR_W-1:0]     ARADDR,
    input  wire [2:0]            ARPROT,
    input  wire                  ARVALID,
    input  wire                  RREADY
);
  localparam int WORDS     = 1 << (ADDR_W-2);
  localparam logic [1:0] OKAY = 2'b00;

  // --- slave-driven outputs (DUT drives these) ------------------------------
  wire              AWREADY, WREADY, BVALID, ARREADY, RVALID;
  wire [1:0]        BRESP, RRESP;
  wire [DATA_W-1:0] RDATA;

  // --- internally generated reset: low at step 0, high thereafter -----------
  logic rst_done = 1'b0;
  always @(posedge ACLK) rst_done <= 1'b1;
  wire ARESETn = rst_done;

  // --- $past validity: true from the second step on -------------------------
  logic f_past_valid = 1'b0;
  always @(posedge ACLK) f_past_valid <= 1'b1;

  // registered previous-cycle reset ($past is only legal inside clocked blocks)
  logic aresetn_q = 1'b0;
  always @(posedge ACLK) aresetn_q <= ARESETn;

  // convenience: both this cycle and last cycle were out of reset
  wire f_active = f_past_valid && ARESETn && aresetn_q;

  // === DUT ==================================================================
  axi_lite_mem #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .STRB_W(STRB_W)) dut (
    .ACLK(ACLK), .ARESETn(ARESETn),
    .AWADDR(AWADDR), .AWPROT(AWPROT), .AWVALID(AWVALID), .AWREADY(AWREADY),
    .WDATA(WDATA),   .WSTRB(WSTRB),   .WVALID(WVALID),   .WREADY(WREADY),
    .BRESP(BRESP),   .BVALID(BVALID), .BREADY(BREADY),
    .ARADDR(ARADDR), .ARPROT(ARPROT), .ARVALID(ARVALID), .ARREADY(ARREADY),
    .RDATA(RDATA),   .RRESP(RRESP),   .RVALID(RVALID),   .RREADY(RREADY)
  );

  // =========================================================================
  // ENVIRONMENT CONSTRAINTS — the master obeys AXI on the request channels.
  // =========================================================================
  always @(posedge ACLK) if (f_active) begin
    // AW: once asserted, VALID holds and payload is stable until READY.
    if ($past(AWVALID) && !$past(AWREADY)) begin
      assume (AWVALID);
      assume ($stable(AWADDR));
      assume ($stable(AWPROT));
    end
    // W
    if ($past(WVALID) && !$past(WREADY)) begin
      assume (WVALID);
      assume ($stable(WDATA));
      assume ($stable(WSTRB));
    end
    // AR
    if ($past(ARVALID) && !$past(ARREADY)) begin
      assume (ARVALID);
      assume ($stable(ARADDR));
      assume ($stable(ARPROT));
    end
    // BREADY / RREADY are left free (a legal master may stall responses).
  end

  // =========================================================================
  // ASSERTIONS — the slave obeys AXI on the response channels.
  // =========================================================================
  always @(posedge ACLK) if (ARESETn) begin
    // This slave never errors.
    assert (BRESP == OKAY);
    assert (RRESP == OKAY);
  end

  always @(posedge ACLK) if (f_active) begin
    // B: VALID holds and RESP is stable until READY.
    if ($past(BVALID) && !$past(BREADY)) begin
      assert (BVALID);
      assert ($stable(BRESP));
    end
    // R: VALID holds; DATA/RESP stable until READY.
    if ($past(RVALID) && !$past(RREADY)) begin
      assert (RVALID);
      assert ($stable(RDATA));
      assert ($stable(RRESP));
    end
  end

  // =========================================================================
  // OUTSTANDING TRACKING — no response without a matching request.
  //   Monotonic saturating handshake counters: a channel can never complete
  //   more responses than requests it accepted.  Robust to the memory's
  //   accept-next-while-responding overlap (no clear-timing subtlety).
  // =========================================================================
  // Saturating counters: capping at all-ones (rather than wrapping) keeps
  // "n_b <= n_aw" sound under the unbounded `prove` task — a wrapped counter
  // would otherwise manufacture a spurious n_b > n_aw counterexample.
  localparam int CW = 6;
  logic [CW-1:0] n_aw, n_w, n_b, n_ar, n_r;
  always @(posedge ACLK or negedge ARESETn)
    if (!ARESETn) begin
      n_aw <= '0; n_w <= '0; n_b <= '0; n_ar <= '0; n_r <= '0;
    end else begin
      if (AWVALID && AWREADY && !(&n_aw)) n_aw <= n_aw + 1'b1;
      if (WVALID  && WREADY  && !(&n_w )) n_w  <= n_w  + 1'b1;
      if (BVALID  && BREADY  && !(&n_b )) n_b  <= n_b  + 1'b1;
      if (ARVALID && ARREADY && !(&n_ar)) n_ar <= n_ar + 1'b1;
      if (RVALID  && RREADY  && !(&n_r )) n_r  <= n_r  + 1'b1;
    end
  always @(posedge ACLK) if (ARESETn) begin
    assert (n_b <= n_aw);   // never more write responses than AW accepted
    assert (n_b <= n_w);    // ...  than W accepted
    assert (n_r <= n_ar);   // never more read responses than AR accepted
  end

  // =========================================================================
  // DATA INTEGRITY — an independent reference memory, written per the AXI-Lite
  // byte-strobe spec, must match what the DUT returns on reads.
  // =========================================================================
  logic [DATA_W-1:0] f_mem [0:WORDS-1];
  integer gi;
  initial for (gi = 0; gi < WORDS; gi = gi + 1) f_mem[gi] = '0;

  // Boundary mirror of the DUT's capture/commit (axi_lite_mem: aw_taken/
  // w_taken set on accept, cleared on do_write = both taken && !BVALID).
  logic              cap_aw, cap_w;
  logic [ADDR_W-1:0] aw_addr_q;
  logic [DATA_W-1:0] w_data_q;
  logic [STRB_W-1:0] w_strb_q;
  wire   ref_commit = cap_aw && cap_w && !BVALID;
  always @(posedge ACLK or negedge ARESETn)
    if (!ARESETn) begin cap_aw <= 1'b0; cap_w <= 1'b0; end
    else begin
      if (AWVALID && AWREADY) begin cap_aw <= 1'b1; aw_addr_q <= AWADDR; end
      if (WVALID  && WREADY ) begin cap_w  <= 1'b1; w_data_q <= WDATA; w_strb_q <= WSTRB; end
      if (ref_commit)         begin cap_aw <= 1'b0; cap_w <= 1'b0; end
    end

  // Reference write: byte-strobed, into the addressed word, on commit.
  integer wb;
  always @(posedge ACLK) if (ARESETn && ref_commit)
    for (wb = 0; wb < STRB_W; wb = wb + 1)
      if (w_strb_q[wb])
        f_mem[aw_addr_q[ADDR_W-1:2]][wb*8 +: 8] <= w_data_q[wb*8 +: 8];

  // Latch the expected read value at AR-accept (the memory is single-read-
  // outstanding: ARREADY drops while RVALID), check it when RVALID lands.
  logic [DATA_W-1:0] rd_expect;
  always @(posedge ACLK) if (ARVALID && ARREADY)
    rd_expect <= f_mem[ARADDR[ADDR_W-1:2]];

  always @(posedge ACLK) if (ARESETn)
    if (RVALID) assert (RDATA == rd_expect);

  // =========================================================================
  // COVER — reachability sanity: the design can actually complete traffic.
  // =========================================================================
  always @(posedge ACLK) if (ARESETn) begin
    cover (BVALID && BREADY);                       // a write completes
    cover (RVALID && RREADY);                        // a read completes
    cover (RVALID && RREADY && RDATA != '0);         // read returns written data
  end

endmodule
`default_nettype wire
