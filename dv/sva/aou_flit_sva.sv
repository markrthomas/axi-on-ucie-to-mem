// -----------------------------------------------------------------------------
// aou_flit_sva : well-formedness checker for an AoU flit channel.
//
// Bind onto a ucie_stream_link instance to check the PLP the packer emits:
//   * valid/ready handshake stability (flit held + stable while stalled);
//   * every transmitted flit starts a message at granule 0 (this design's
//     packer always places the first message there, so MsgStart[0] must be set);
//   * the first message's MSGTYPE is a supported Basic-Profile type;
//   * FDId names an ACTIVE resource plane (< NUM_RP) — at the NUM_RP=1 default
//     that is exactly "FDId == 0", the historical RP0-only property; a
//     multi-plane bind passes its NUM_RP so the bound tightens to that build's
//     active plane count (dv/sva/bind_mrp_sva.sv).
//
// Carried by the Verilator (--assert) and UVM flows (see axi_lite_sva header).
// -----------------------------------------------------------------------------
`ifndef AOU_FLIT_SVA_SV
`define AOU_FLIT_SVA_SV

module aou_flit_sva
  import aou_pkg::*;
#(
    // Active resource planes in the build under check (docs/PLAN.md F1).
    parameter int NUM_RP = 1
) (
    input logic                clk,
    input logic                rstn,
    input logic [PLP_BITS-1:0] flit,
    input logic                valid,
    input logic                ready
);

  // `disable iff (!rstn)` inlined per property (see axi_lite_sva note).

  // header/payload views of the flit under check (only the checked slices are
  // read; the rest is intentionally unused here).
  // verilator lint_off UNUSEDSIGNAL
  wire [FDID_W-1:0]     fdid     = flit_fdid(flit);       // §4.3 scattered layout
  wire msgstart_t       msgstart = flit_msgstart(flit);
  wire payload_t        payload  = flit[PLP_PAYLOAD_BITS-1:0];
  wire [MSGTYPE_W-1:0]  mt0      = payload[PLP_PAYLOAD_BITS-1 -: MSGTYPE_W];
  wire [CREDIT_W-1:0]   msgcred  = flit_credit(flit);
  // verilator lint_on UNUSEDSIGNAL

  // --- handshake -------------------------------------------------------------
  a_flit_hold: assert property (@(posedge clk) disable iff (!rstn)
    (valid && !ready) |=> valid);
  a_flit_stable: assert property (@(posedge clk) disable iff (!rstn)
    (valid && !ready) |=> $stable(flit));

  // --- well-formedness -------------------------------------------------------
  a_msgstart0: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> msgstart[0]);
  a_fdid_range: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> (32'(fdid) < NUM_RP));
  a_mt0_known: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> (mt0 == MT_WRITEREQ || mt0 == MT_READREQ ||
               mt0 == MT_WRITEDATA ||  // bursts: WriteData travels in its own flit
               mt0 == MT_READDATA || mt0 == MT_WRITERESP ||
               mt0 == MT_MISC));       // §8 activation / §6.4.2 CrdtGrant flits

  // §6 credits are advertised per resource plane, so the MsgCredit RP subfield
  // (Table 16, [15:14]) must name an active plane.  At NUM_RP=1 this is exactly
  // the historical "mc_rp == 0"; at NUM_RP=2 a credit word may only be tagged
  // RP0 or RP1, never a plane this build does not implement.
  a_credit_rp_range: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> (32'(mc_rp(msgcred)) < NUM_RP));

endmodule
`endif
