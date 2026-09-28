// -----------------------------------------------------------------------------
// tb_axi4_sva_mut : assertion mutation harness for dv/sva/axi4_sva.sv
// (SCAN_ISSUES #4).  Proves every stability/hold property of the checker can
// actually FAIL, so a DUT or TB that corrupts a stalled field is caught.
//
// The harness drives the checker directly (no DUT): all five channels raise
// VALID with READY low and hold every payload field for STALL cycles, then
// READY completes the transfer.  +MUT=<n> corrupts ONE thing mid-stall:
//     0        nothing (clean run -- must PASS with zero assertion failures)
//     1..21    one payload field changes while its channel is stalled
//     22..26   one channel drops VALID before READY
// The expected failing assertion for each mutant is printed as
// "[SVA-MUT] expect <assertion>" so dv/sva/mut/Makefile can check that the
// RIGHT property fired, not just that something did.
//
// Runs under Verilator only (--binary --timing --assert), which treats a failed
// concurrent assertion as $stop, which exits non-zero.
// -----------------------------------------------------------------------------
module tb_axi4_sva_mut;
  localparam int AW = 32, DW = 32, SW = DW/8, IDW = 4;
  localparam int STALL = 4;

  logic clk, rstn;
  initial begin clk = 1'b0; forever #5 clk = ~clk; end

  logic [IDW-1:0] awid,  bid,  arid,  rid;
  logic [AW-1:0]  awaddr, araddr;
  logic [7:0]     awlen,  arlen;
  logic [2:0]     awsize, arsize, awprot, arprot;
  logic [1:0]     awburst, arburst, bresp, rresp;
  logic [DW-1:0]  wdata, rdata;
  logic [SW-1:0]  wstrb;
  logic           wlast, rlast;
  logic awvalid, awready, wvalid, wready, bvalid, bready;
  logic arvalid, arready, rvalid, rready;

  axi4_sva #(.AW(AW), .DW(DW), .SW(SW), .IDW(IDW)) u_chk (.*);

  int mut;
  string exp_name;

  function automatic string expect_of(int m);
    case (m)
      0:                       return "none";
      1,2,3,4,5,6:             return "a_aw_stable";
      7,8,9:                   return "a_w_stable";
      10,11:                   return "a_b_stable";
      12,13,14,15,16,17:       return "a_ar_stable";
      18,19,20,21:             return "a_r_stable";
      22: return "a_aw_hold";  23: return "a_w_hold";  24: return "a_b_hold";
      25: return "a_ar_hold";  26: return "a_r_hold";
      default:                 return "unknown";
    endcase
  endfunction

  // Flip the selected field (or drop the selected VALID) at the current stall.
  task automatic corrupt(int m);
    case (m)
      1:  awid    = ~awid;     2:  awaddr  = ~awaddr;   3:  awlen   = ~awlen;
      4:  awsize  = ~awsize;   5:  awburst = ~awburst;  6:  awprot  = ~awprot;
      7:  wdata   = ~wdata;    8:  wstrb   = ~wstrb;    9:  wlast   = ~wlast;
      10: bid     = ~bid;      11: bresp   = ~bresp;
      12: arid    = ~arid;     13: araddr  = ~araddr;   14: arlen   = ~arlen;
      15: arsize  = ~arsize;   16: arburst = ~arburst;  17: arprot  = ~arprot;
      18: rid     = ~rid;      19: rdata   = ~rdata;    20: rresp   = ~rresp;
      21: rlast   = ~rlast;
      22: awvalid = 1'b0;      23: wvalid  = 1'b0;      24: bvalid  = 1'b0;
      25: arvalid = 1'b0;      26: rvalid  = 1'b0;
      default: ;
    endcase
  endtask

  task automatic idle_all();
    {awvalid, wvalid, bvalid, arvalid, rvalid} = '0;
    {awready, wready, bready, arready, rready} = '0;
    awid = 4'h3; awaddr = 32'h0000_1230; awlen = 8'd3; awsize = 3'd2;
    awburst = 2'b01; awprot = 3'b000;
    wdata = 32'hA5A5_0F0F; wstrb = 4'hF; wlast = 1'b0;
    bid = 4'h3; bresp = 2'b00;
    arid = 4'h5; araddr = 32'h0000_4560; arlen = 8'd7; arsize = 3'd2;
    arburst = 2'b10; arprot = 3'b010;
    rid = 4'h5; rdata = 32'h5A5A_F0F0; rresp = 2'b00; rlast = 1'b0;
  endtask

  initial begin
    if (!$value$plusargs("MUT=%d", mut)) mut = 0;
    exp_name = expect_of(mut);
    $display("[SVA-MUT] MUT=%0d expect %s", mut, exp_name);
    rstn = 1'b0;
    idle_all();
    repeat (3) @(negedge clk);
    rstn = 1'b1;
    repeat (2) @(negedge clk);

    // All channels stalled with fixed payloads.
    {awvalid, wvalid, bvalid, arvalid, rvalid} = '1;
    for (int c = 0; c < STALL; c++) begin
      @(negedge clk);
      if (c == STALL/2) corrupt(mut);
    end
    // Complete every transfer, then go idle.
    {awready, wready, bready, arready, rready} = '1;
    @(negedge clk);
    idle_all();
    repeat (4) @(negedge clk);

    $display("[SVA-MUT] PASS: MUT=%0d no assertion fired", mut);
    $finish;
  end
endmodule
