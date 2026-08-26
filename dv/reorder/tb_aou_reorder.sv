// -----------------------------------------------------------------------------
// tb_aou_reorder : directed unit test for the per-ID response reorder buffer.
//
// Drives aou_reorder and checks the AXI out-of-order-by-ID completion rule:
//   * cross-ID overtake — a younger response of a different ID leaves before an
//     older, still-uncompleted response;
//   * same-ID ordering  — two responses sharing an ID always leave in issue
//     order, regardless of the order their completions arrive;
//   * capacity          — iss_ready deasserts when the buffer is full and
//     reasserts once space is reclaimed;
//   * attribution       — under a scrambled completion order every response is
//     delivered as the oldest un-released transaction of its ID, with the data
//     that was completed for its tag (per-ID reference-FIFO check).
//
// Self-checking; prints "[ROB-TB] PASS: <n> checks, 0 errors".  Icarus + Verilator.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
module tb_aou_reorder;

  // Shared DV-only VERBOSE=0|1|2 logging plumbing (no flit decoder needed here:
  // aou_reorder carries responses, not flits).  TB-only; at VERBOSE=0 nothing
  // is emitted.
  `include "aou_log.svh"

  localparam int DEPTH  = 8;
  localparam int ID_W   = 4;
  localparam int DATA_W = 32;
  localparam int TAGW   = 3;
  localparam logic [31:0] DBASE = 32'hDA7A_0000;   // unique per-tag data = DBASE|tag

  logic                clk, rstn;
  logic                iss_valid, iss_ready;
  logic [ID_W-1:0]     iss_id;
  logic [TAGW-1:0]     iss_tag;
  logic                cmp_valid;
  logic [TAGW-1:0]     cmp_tag;
  logic [DATA_W-1:0]   cmp_data;
  logic                out_valid, out_ready;
  logic [ID_W-1:0]     out_id;
  logic [DATA_W-1:0]   out_data;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  aou_reorder #(.DEPTH(DEPTH), .ID_W(ID_W), .DATA_W(DATA_W)) dut (
    .clk(clk), .rstn(rstn),
    .iss_valid(iss_valid), .iss_ready(iss_ready), .iss_id(iss_id), .iss_tag(iss_tag),
    .cmp_valid(cmp_valid), .cmp_tag(cmp_tag), .cmp_data(cmp_data),
    .out_valid(out_valid), .out_id(out_id), .out_data(out_data), .out_ready(out_ready)
  );

  int checks = 0, errors = 0;
  task automatic chk(input logic cond, input string what);
    checks++;
    if (cond !== 1'b1) begin
      errors++;
      $display("[ROB-TB] CHECK FAILED: %s", what);
    end
    // level 1: per-check detail behind the [ROB-TB] PASS count.
    if (aou_lvl >= 1)
      aou_emit($sformatf("[ROB-TB][C] %s check %0d: %s",
                         (cond === 1'b1) ? "ok  " : "FAIL", checks, what));
  endtask

  // issue one transaction (id), returning the tag the DUT allocated
  task automatic issue(input logic [ID_W-1:0] id, output logic [TAGW-1:0] tag);
    @(negedge clk);
    iss_valid = 1'b1; iss_id = id;
    #1;
    chk(iss_ready === 1'b1, "iss_ready asserted during issue");
    tag = iss_tag;
    @(negedge clk);                 // posedge in between allocates the slot
    iss_valid = 1'b0;
  endtask

  // deliver completion data for a tag (may be called in any order)
  task automatic complete(input logic [TAGW-1:0] tag);
    @(negedge clk);
    cmp_valid = 1'b1; cmp_tag = tag; cmp_data = DBASE | {29'b0, tag};
    @(negedge clk);                 // posedge registers done
    cmp_valid = 1'b0;
  endtask

  // pop exactly one output, checking it carries the expected id/tag
  task automatic pop(input logic [ID_W-1:0] eid, input logic [TAGW-1:0] etag);
    @(negedge clk); #1;
    chk(out_valid === 1'b1, "pop: out_valid asserted");
    chk(out_id  === eid,               $sformatf("pop: id exp=%0d got=%0d", eid, out_id));
    chk(out_data === (DBASE | {29'b0, etag}), "pop: data matches tag");
    out_ready = 1'b1;
    @(negedge clk);                 // posedge releases the slot
    out_ready = 1'b0;
  endtask

  task automatic expect_no_out(input string what);
    @(negedge clk); #1;
    chk(out_valid === 1'b0, what);
  endtask

  // per-ID reference FIFOs for the scrambled-drain scenario (plain arrays +
  // head/tail indices — portable across iverilog/verilator, unlike queues).
  logic [TAGW-1:0] rf_data [0:(1<<ID_W)-1][0:DEPTH-1];
  int              rf_head [0:(1<<ID_W)-1];
  int              rf_tail [0:(1<<ID_W)-1];
  function automatic int rf_size(input logic [ID_W-1:0] id);
    rf_size = rf_tail[id] - rf_head[id];
  endfunction
  task automatic rf_push(input logic [ID_W-1:0] id, input logic [TAGW-1:0] tag);
    rf_data[id][rf_tail[id]] = tag;
    rf_tail[id]++;
  endtask

  // --- level 2: reorder-buffer slot state (allocated / completed window) -----
  logic [DEPTH-1:0] p_occ, p_done;
  bit               dbg_armed;
  always @(posedge clk) begin
    if (aou_lvl >= 2) begin
      if (!rstn) dbg_armed <= 1'b0;
      else begin
        if (!dbg_armed || (dut.occ !== p_occ) || (dut.done !== p_done))
          aou_dbg($sformatf("rob occ=0x%02h done=0x%02h head=%0d tail=%0d count=%0d out_valid=%0b out_id=%0d",
                            dut.occ, dut.done, dut.head, dut.tail, dut.count,
                            out_valid, out_id));
        dbg_armed <= 1'b1;
      end
      p_occ  <= dut.occ;
      p_done <= dut.done;
    end
  end

  logic [TAGW-1:0] ta, tb, tc, td, te, tf, tg, th;
  logic [TAGW-1:0] tmp;
  int popped;

  initial begin
    aou_log_init("[ROB-TB]");
    rstn = 1'b0;
    iss_valid = 1'b0; iss_id = '0;
    cmp_valid = 1'b0; cmp_tag = '0; cmp_data = '0;
    out_ready = 1'b0;
    for (int i = 0; i < (1<<ID_W); i++) begin rf_head[i] = 0; rf_tail[i] = 0; end
    repeat (4) @(negedge clk);
    rstn = 1'b1;
    @(negedge clk); #1;
    chk(out_valid === 1'b0 && iss_ready === 1'b1, "empty after reset");

    // --- 1) cross-ID overtake: younger diff-ID leaves before older ----------
    issue(4'd1, ta);                 // oldest, ID 1
    issue(4'd2, tb);                 // younger, ID 2
    expect_no_out("nothing completed -> no output");
    complete(tb);                    // complete only the younger (ID 2)
    pop(4'd2, tb);                   // ID 2 overtakes the uncompleted ID 1
    expect_no_out("older ID 1 still uncompleted -> no output");
    complete(ta);
    pop(4'd1, ta);
    expect_no_out("buffer drained");

    // --- 2) same-ID ordering preserved despite reversed completion ----------
    issue(4'd5, ta);                 // first ID 5
    issue(4'd5, tb);                 // second ID 5
    complete(tb);                    // complete the YOUNGER first
    expect_no_out("younger same-ID blocked by older uncompleted");
    complete(ta);
    pop(4'd5, ta);                   // older ID 5 leaves first ...
    pop(4'd5, tb);                   // ... then younger, in issue order
    expect_no_out("same-ID pair drained");

    // --- 3) capacity: fill DEPTH, iss_ready deasserts, then reclaim ----------
    issue(4'd0, ta); issue(4'd1, tb); issue(4'd2, tc); issue(4'd3, td);
    issue(4'd4, te); issue(4'd5, tf); issue(4'd6, tg); issue(4'd7, th);
    @(negedge clk); iss_valid = 1'b1; iss_id = 4'd8; #1;
    chk(iss_ready === 1'b0, "iss_ready deasserts when full");
    @(negedge clk); iss_valid = 1'b0;
    complete(ta); complete(tb); complete(tc); complete(td);
    complete(te); complete(tf); complete(tg); complete(th);
    pop(4'd0, ta); pop(4'd1, tb); pop(4'd2, tc); pop(4'd3, td);
    pop(4'd4, te); pop(4'd5, tf); pop(4'd6, tg); pop(4'd7, th);
    @(negedge clk); #1;
    chk(iss_ready === 1'b1, "iss_ready reasserts after drain");

    // --- 4) scrambled completion, per-ID reference-FIFO attribution ---------
    // six transactions across IDs {3,3,7,3,7,9}; complete in a jumbled order.
    issue(4'd3, ta); rf_push(4'd3, ta);
    issue(4'd3, tb); rf_push(4'd3, tb);
    issue(4'd7, tc); rf_push(4'd7, tc);
    issue(4'd3, td); rf_push(4'd3, td);
    issue(4'd7, te); rf_push(4'd7, te);
    issue(4'd9, tf); rf_push(4'd9, tf);
    complete(te); complete(ta); complete(tf); complete(td); complete(tc); complete(tb);
    popped = 0;
    while (popped < 6) begin
      @(negedge clk); #1;
      if (out_valid === 1'b1) begin
        // must be the oldest un-released transaction of this ID
        chk(rf_size(out_id) > 0, "drain: output ID has an outstanding txn");
        if (rf_size(out_id) > 0) begin
          tmp = rf_data[out_id][rf_head[out_id]];
          chk(out_data === (DBASE | {29'b0, tmp}),
              $sformatf("drain: id %0d data is oldest tag", out_id));
          rf_head[out_id]++;
        end
        out_ready = 1'b1;
        @(negedge clk);
        out_ready = 1'b0;
        popped++;
      end else begin
        @(negedge clk);
      end
    end
    chk(rf_size(4'd3)==0 && rf_size(4'd7)==0 && rf_size(4'd9)==0,
        "drain: all reference FIFOs emptied");
    expect_no_out("all six drained");

    if (errors == 0) $display("[ROB-TB] PASS: %0d checks, 0 errors", checks);
    else             $display("[ROB-TB] FAIL: %0d checks, %0d errors", checks, errors);
    aou_log_close();
    $finish;
  end

  // watchdog
  initial begin
    #200000;
    $display("[ROB-TB] FAIL: timeout (checks=%0d errors=%0d)", checks, errors);
    aou_log_close();
    $finish;
  end
endmodule
