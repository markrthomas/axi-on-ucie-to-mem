// -----------------------------------------------------------------------------
// aou_reorder : per-ID response reorder buffer (out-of-order-by-ID completion).
//
// Models the initiator-side buffer AXI needs when responses may complete out of
// order.  The AXI ordering rule is: transactions with the SAME ID complete in
// issue order, transactions with DIFFERENT IDs may complete in any order.  This
// block delivers exactly that:
//   * issue side  — allocates a slot per transaction in issue order, returning
//                   a tag (the slot index) and storing the transaction's ID;
//   * completion  — data arrives addressed by tag and may arrive in ANY order
//                   (this is the "out-of-order" the initiator must tolerate);
//   * output side — presents a completed response as soon as it is the OLDEST
//                   not-yet-released transaction OF ITS ID.  A younger response
//                   of a different ID can therefore overtake an older one still
//                   awaiting completion (out-of-order across IDs), while two
//                   responses sharing an ID always leave in issue order.
//
// The current AoU chain (single serialized link + single in-order memory) never
// produces out-of-order completions, so this block is not wired into the full
// datapath; it is a synthesizable, self-contained mechanism verified by the
// directed unit test in dv/reorder, ready for a variable-latency / multi-channel
// target.  See docs/PLAN.md (F2).
//
// Slots occupy a contiguous window [head, tail): position within the window is
// age (head = oldest).  Completed responses may leave the window out of order
// (occ cleared in place); the freed space is reclaimed in issue order as head
// advances over vacated slots (at most one slot/cycle).  DEPTH must be a power
// of two so the tag/head/tail pointers wrap naturally.
// -----------------------------------------------------------------------------
`ifndef AOU_REORDER_SV
`define AOU_REORDER_SV

module aou_reorder #(
    parameter int DEPTH  = 8,        // outstanding capacity (power of two)
    parameter int ID_W   = 10,
    parameter int DATA_W = 32,
    // Derived; do NOT override.  In the parameter list so the ports can use it.
    parameter int TAGW   = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  logic                     clk,
    input  logic                     rstn,
    // issue: allocate a slot in issue order (iss_tag valid when fired)
    input  logic                     iss_valid,
    output logic                     iss_ready,
    input  logic [ID_W-1:0]          iss_id,
    output logic [TAGW-1:0]          iss_tag,
    // completion: data for `cmp_tag` arrives, possibly out of order
    input  logic                     cmp_valid,
    input  logic [TAGW-1:0]          cmp_tag,
    input  logic [DATA_W-1:0]        cmp_data,
    // output: oldest-of-its-ID completed response, released on out_ready
    output logic                     out_valid,
    output logic [ID_W-1:0]          out_id,
    output logic [DATA_W-1:0]        out_data,
    input  logic                     out_ready
);

  logic [DEPTH-1:0]   occ;                 // slot allocated, not yet released
  logic [DEPTH-1:0]   done;                // completion data has arrived
  logic [ID_W-1:0]    id_arr   [DEPTH];
  logic [DATA_W-1:0]  data_arr [DEPTH];
  logic [TAGW-1:0]    head, tail;
  logic [TAGW:0]      count;               // window size (tail-head), 0..DEPTH

  // circular index of the k-th slot from head (0 = oldest)
  function automatic logic [TAGW-1:0] idx_at(input int k);
    int s;
    begin
      s = int'(head) + k;
      if (s >= DEPTH) s -= DEPTH;
      idx_at = s[TAGW-1:0];
    end
  endfunction

  assign iss_ready = (count != DEPTH[TAGW:0]);
  assign iss_tag   = tail;

  wire iss_fire = iss_valid && iss_ready;
  wire cmp_fire = cmp_valid;

  // --- output selection: oldest completed slot with no older same-ID slot ----
  logic [TAGW-1:0] out_idx;
  always_comb begin
    logic [TAGW-1:0] idx, jdx;
    logic            blocked;
    idx       = '0;
    jdx       = '0;
    blocked   = 1'b0;
    out_valid = 1'b0;
    out_idx   = head;
    for (int k = 0; k < DEPTH; k++) begin
      idx = idx_at(k);
      if ((k < int'(count)) && occ[idx] && done[idx] && !out_valid) begin
        blocked = 1'b0;
        for (int j = 0; j < DEPTH; j++) begin
          jdx = idx_at(j);
          if ((j < k) && occ[jdx] && (id_arr[jdx] == id_arr[idx]))
            blocked = 1'b1;               // an older, still-present same-ID slot
        end
        if (!blocked) begin
          out_valid = 1'b1;
          out_idx   = idx;
        end
      end
    end
  end
  assign out_id   = id_arr[out_idx];
  assign out_data = data_arr[out_idx];

  wire out_fire = out_valid && out_ready;

  // head slot is vacated this cycle (or already vacant) -> reclaim its space
  wire reclaim = (count != '0) &&
                 (!occ[head] || (out_fire && (out_idx == head)));

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      occ   <= '0;
      done  <= '0;
      head  <= '0;
      tail  <= '0;
      count <= '0;
    end else begin
      if (iss_fire) begin
        occ[tail]     <= 1'b1;
        done[tail]    <= 1'b0;
        id_arr[tail]  <= iss_id;
        tail          <= tail + 1'b1;
      end
      if (cmp_fire) begin
        done[cmp_tag]     <= 1'b1;
        data_arr[cmp_tag] <= cmp_data;
      end
      if (out_fire) begin
        occ[out_idx]  <= 1'b0;
        done[out_idx] <= 1'b0;
      end
      if (reclaim) head <= head + 1'b1;
      count <= count + (TAGW+1)'(iss_fire) - (TAGW+1)'(reclaim);
    end
  end

endmodule
`endif
