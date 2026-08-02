// -----------------------------------------------------------------------------
// axi_lite_mem : AXI4-Lite word-wide SRAM memory (the far-side target).
//
// Replaces the APB memory of ../uvm_review with a native AXI4-Lite slave, since
// AXI is the OCA non-coherent bus protocol carried over UCIe (OCA §5.2); APB is
// a low-speed peripheral bus not intended for a die-to-die link.  Reuses the
// reference's memory idioms: zero-initialised array (reads of un-written
// locations return 0), plain `always @(posedge)` write (portable to VCS, which
// rejects a second driver on an `always_ff` variable), and constant OKAY
// responses (this slave never errors).
//
//  * Data width  : DATA_W bits (default 32, word)
//  * Address     : byte address, ADDR_W bits; word index = ADDR[ADDR_W-1:2]
//  * Wait states : none (single-cycle accept + response)
//  * Responses   : BRESP/RRESP tied to OKAY
// -----------------------------------------------------------------------------
`ifndef AXI_LITE_MEM_SV
`define AXI_LITE_MEM_SV

module axi_lite_mem #(
    parameter int ADDR_W = 16,          // byte address width -> 64 KiB
    parameter int DATA_W = 32,
    parameter int STRB_W = DATA_W/8
) (
    input  logic              ACLK,
    input  logic              ARESETn,
    // write address channel
    input  logic [ADDR_W-1:0] AWADDR,
    input  logic [2:0]        AWPROT,
    input  logic              AWVALID,
    output logic              AWREADY,
    // write data channel
    input  logic [DATA_W-1:0] WDATA,
    input  logic [STRB_W-1:0] WSTRB,
    input  logic              WVALID,
    output logic              WREADY,
    // write response channel
    output logic [1:0]        BRESP,
    output logic              BVALID,
    input  logic              BREADY,
    // read address channel
    input  logic [ADDR_W-1:0] ARADDR,
    input  logic [2:0]        ARPROT,
    input  logic              ARVALID,
    output logic              ARREADY,
    // read data channel
    output logic [DATA_W-1:0] RDATA,
    output logic [1:0]        RRESP,
    output logic              RVALID,
    input  logic              RREADY
);

  localparam int WORDS = 1 << (ADDR_W-2);
  localparam logic [1:0] RESP_OKAY = 2'b00;

  // AXI requires AxPROT and full-width AxADDR on the bus, but a word memory
  // ignores protection bits and the two low (sub-word) address bits.  Sink
  // them so the (correct) "intentionally unused" lint stays visible elsewhere.
  // verilator lint_off UNUSEDSIGNAL
  wire _unused_ok = &{1'b0, AWPROT, ARPROT, AWADDR[1:0], ARADDR[1:0]};
  // verilator lint_on UNUSEDSIGNAL

  logic [DATA_W-1:0] mem [0:WORDS-1];

  // Power up all-zero so reads of un-written locations return 0 (not X).
  integer i;
  initial begin
    for (i = 0; i < WORDS; i = i + 1) mem[i] = '0;
  end

  // verilator coverage_off
  // Constant tie-offs: this slave never errors -> no logic to cover.
  assign BRESP = RESP_OKAY;
  assign RRESP = RESP_OKAY;
  // verilator coverage_on

  // --- Write channel --------------------------------------------------------
  // Capture AW and W independently, commit the write once both are held.
  logic                aw_taken, w_taken;
  logic [ADDR_W-3:0]   awaddr_q;   // captured word index (drops sub-word bits)
  logic [DATA_W-1:0]   wdata_q;
  logic [STRB_W-1:0]   wstrb_q;

  assign AWREADY = !aw_taken;
  assign WREADY  = !w_taken;

  wire do_write = aw_taken && w_taken && !BVALID;

  // plain always (not always_ff) — see header note on the memory array driver.
  always @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      aw_taken <= 1'b0;
      w_taken  <= 1'b0;
      awaddr_q <= '0;
      wdata_q  <= '0;
      wstrb_q  <= '0;
      BVALID   <= 1'b0;
    end else begin
      if (AWVALID && AWREADY) begin
        aw_taken <= 1'b1;
        awaddr_q <= AWADDR[ADDR_W-1:2];
      end
      if (WVALID && WREADY) begin
        w_taken <= 1'b1;
        wdata_q <= WDATA;
        wstrb_q <= WSTRB;
      end
      if (do_write) begin
        // byte-strobed write into the addressed word
        for (int b = 0; b < STRB_W; b++)
          if (wstrb_q[b])
            mem[awaddr_q][b*8 +: 8] <= wdata_q[b*8 +: 8];
        aw_taken <= 1'b0;
        w_taken  <= 1'b0;
        BVALID   <= 1'b1;
      end else if (BVALID && BREADY) begin
        BVALID <= 1'b0;
      end
    end
  end

  // --- Read channel ---------------------------------------------------------
  logic ar_taken;
  assign ARREADY = !ar_taken && !RVALID;

  always @(posedge ACLK or negedge ARESETn) begin
    if (!ARESETn) begin
      ar_taken <= 1'b0;
      RVALID   <= 1'b0;
      RDATA    <= '0;
    end else begin
      if (ARVALID && ARREADY) begin
        RDATA    <= mem[ARADDR[ADDR_W-1:2]];
        RVALID   <= 1'b1;
        ar_taken <= 1'b0;   // single-cycle: data ready next cycle
      end
      if (RVALID && RREADY) begin
        RVALID <= 1'b0;
      end
    end
  end

endmodule
`endif
