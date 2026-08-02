// -----------------------------------------------------------------------------
// ucie_stream_link : one-directional flit transport across the FDI boundary.
//
// Models a UCIe streaming (FDI) link as a registered valid/ready flit channel.
// This is deliberately ABOVE the UCIe PHY / Die-to-Die Adapter: everything below
// FDI (electrical, retry, CRC, sideband) is UCIe's own concern and
// IMPLEMENTATION DEFINED per the AoU spec, so it is not modeled here.  A 1-deep
// skid buffer gives one cycle of latency, decouples the two bridges' handshakes,
// and sustains one flit per cycle.
// -----------------------------------------------------------------------------
`ifndef UCIE_STREAM_LINK_SV
`define UCIE_STREAM_LINK_SV

module ucie_stream_link #(
    parameter int W = 2000               // flit width (PLP = 250B = 2000b)
) (
    input  logic         clk,
    input  logic         rstn,
    // upstream (transmit side)
    input  logic [W-1:0] in_data,
    input  logic         in_valid,
    output logic         in_ready,
    // downstream (receive side)
    output logic [W-1:0] out_data,
    output logic         out_valid,
    input  logic         out_ready
);

  logic         full;
  logic [W-1:0] data_q;

  assign out_valid = full;
  assign out_data  = data_q;
  // can accept when empty, or when the held flit is being taken this cycle
  assign in_ready  = !full || out_ready;

  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      full   <= 1'b0;
      data_q <= '0;
    end else begin
      if (in_valid && in_ready) begin
        data_q <= in_data;
        full   <= 1'b1;
      end else if (out_valid && out_ready) begin
        full   <= 1'b0;
      end
    end
  end

endmodule
`endif
