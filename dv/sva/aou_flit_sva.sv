// -----------------------------------------------------------------------------
// aou_flit_sva : well-formedness checker for an AoU flit channel.
//
// Bind onto a ucie_stream_link instance to check the PLP the packer emits:
//   * valid/ready handshake stability (flit held + stable while stalled);
//   * every transmitted flit starts a message at granule 0 (this design's
//     packer always places the first message there, so MsgStart[0] must be set);
//   * the first message's MSGTYPE is a supported Basic-Profile type;
//   * FDId is RP0's destination (0) in this single-plane build.
//
// Carried by the Verilator (--assert) and UVM flows (see axi_lite_sva header).
// -----------------------------------------------------------------------------
`ifndef AOU_FLIT_SVA_SV
`define AOU_FLIT_SVA_SV

module aou_flit_sva
  import aou_pkg::*;
(
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
  wire [FDID_W-1:0]     fdid     = flit[PLP_BITS-1 -: FDID_W];
  wire msgstart_t       msgstart = flit[PLP_BITS-1-FDID_W -: NUM_GRAN];
  wire payload_t        payload  = flit[PLP_PAYLOAD_BITS-1:0];
  wire [MSGTYPE_W-1:0]  mt0      = payload[PLP_PAYLOAD_BITS-1 -: MSGTYPE_W];
  // verilator lint_on UNUSEDSIGNAL

  // --- handshake -------------------------------------------------------------
  a_flit_hold: assert property (@(posedge clk) disable iff (!rstn)
    (valid && !ready) |=> valid);
  a_flit_stable: assert property (@(posedge clk) disable iff (!rstn)
    (valid && !ready) |=> $stable(flit));

  // --- well-formedness -------------------------------------------------------
  a_msgstart0: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> msgstart[0]);
  a_fdid_rp0: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> (fdid == '0));
  a_mt0_known: assert property (@(posedge clk) disable iff (!rstn)
    valid |-> (mt0 == MT_WRITEREQ || mt0 == MT_READREQ ||
               mt0 == MT_READDATA || mt0 == MT_WRITERESP));

endmodule
`endif
