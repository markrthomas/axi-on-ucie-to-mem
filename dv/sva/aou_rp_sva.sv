// -----------------------------------------------------------------------------
// aou_rp_sva : per-resource-plane routing checker for aou_rp_route.
//
// Bound onto each aou_rp_route instance (docs/PLAN.md F1), it proves the two
// plane-isolation properties the router is responsible for:
//
//   * a_rp_in_range   — every flit arriving off the shared link names an ACTIVE
//     plane.  The router has a "no plane matched -> consume and drop" path so an
//     illegal FDId can never wedge the shared link; this assertion proves that
//     path is DEAD in a real build, i.e. no flit is ever silently dropped.
//
//   * a_rp_deliver_own — a flit handed to plane p carries FDId == p.  This is the
//     structural root of "no cross-plane response or credit leakage": a bridge
//     only ever sees flits of its own plane, so the MsgCredit word riding in a
//     flit header can only ever replenish its own plane's §6 counters, and a
//     response can only ever be driven onto its own plane's AXI R/B channels.
//
// Concurrent SVA, so it is compiled by the Verilator (--assert) / commercial
// flows only, like the other checkers here.
// -----------------------------------------------------------------------------
`ifndef AOU_RP_SVA_SV
`define AOU_RP_SVA_SV

module aou_rp_sva
  import aou_pkg::*;
#(
    parameter int NUM_RP = 2
) (
    input logic                       clk,
    input logic                       rstn,
    input logic [PLP_BITS-1:0]        in_data,
    input logic                       in_valid,
    input logic [NUM_RP*PLP_BITS-1:0] out_data,
    input logic [NUM_RP-1:0]          out_valid
);

  // verilator lint_off UNUSEDSIGNAL
  wire [FDID_W-1:0] in_fdid = flit_fdid(in_data);
  // verilator lint_on UNUSEDSIGNAL

  a_rp_in_range: assert property (@(posedge clk) disable iff (!rstn)
    in_valid |-> (32'(in_fdid) < NUM_RP));

  genvar p;
  generate
    for (p = 0; p < NUM_RP; p++) begin : g_p
      // verilator lint_off UNUSEDSIGNAL
      wire [FDID_W-1:0] out_fdid = flit_fdid(out_data[p*PLP_BITS +: PLP_BITS]);
      // verilator lint_on UNUSEDSIGNAL
      a_rp_deliver_own: assert property (@(posedge clk) disable iff (!rstn)
        out_valid[p] |-> (out_fdid == FDID_W'(p)));
    end
  endgenerate

endmodule
`endif
