// -----------------------------------------------------------------------------
// aou_axi_initiator_bridge : chiplet-A bridge (AXI-Lite subordinate -> AoU).
//
// Accepts AXI4-Lite transactions from the TB master and turns them into AoU
// Basic-Profile messages packed into a flit sent over the A->B link:
//   * write  -> {WriteReq (g0), WriteData256 (g3)}   (MsgStart = bit0 | bit3)
//   * read   -> {ReadReq  (g0)}                       (MsgStart = bit0)
// The return flit from B->A carries a WriteResp or ReadData256 message, which is
// unpacked to complete the AXI B / R response.
//
// Scope: one transaction in flight at a time (single-outstanding).  A monotonic
// tag is carried in the AoU {AW,AR}ID field and echoed back in {B,R}ID for
// faithfulness; response routing is trivial with one outstanding transaction.
// Multiple-outstanding + credit flow control is a documented follow-on.
// -----------------------------------------------------------------------------
`ifndef AOU_AXI_INITIATOR_BRIDGE_SV
`define AOU_AXI_INITIATOR_BRIDGE_SV

module aou_axi_initiator_bridge
  import aou_pkg::*;
#(
    parameter int AXI_ADDR_W = 32,
    parameter int AXI_DATA_W = 32,
    parameter int AXI_STRB_W = AXI_DATA_W/8
) (
    input  logic                    clk,
    input  logic                    rstn,
    // ---- AXI4-Lite subordinate (TB master drives these) ----
    input  logic [AXI_ADDR_W-1:0]   s_awaddr,
    input  logic [2:0]              s_awprot,
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [AXI_DATA_W-1:0]   s_wdata,
    input  logic [AXI_STRB_W-1:0]   s_wstrb,
    input  logic                    s_wvalid,
    output logic                    s_wready,
    output logic [1:0]              s_bresp,
    output logic                    s_bvalid,
    input  logic                    s_bready,
    input  logic [AXI_ADDR_W-1:0]   s_araddr,
    input  logic [2:0]              s_arprot,
    input  logic                    s_arvalid,
    output logic                    s_arready,
    output logic [AXI_DATA_W-1:0]   s_rdata,
    output logic [1:0]              s_rresp,
    output logic                    s_rvalid,
    input  logic                    s_rready,
    // ---- flit TX (to A->B link) ----
    output logic [PLP_BITS-1:0]     tx_data,
    output logic                    tx_valid,
    input  logic                    tx_ready,
    // ---- flit RX (from B->A link) ----
    input  logic [PLP_BITS-1:0]     rx_data,
    input  logic                    rx_valid,
    output logic                    rx_ready
);

  typedef enum logic [2:0] {
    S_IDLE, S_WSEND, S_RSEND, S_WAIT, S_B, S_R
  } state_e;
  state_e state;

  logic                  aw_seen, w_seen, is_write;
  logic [AXI_ADDR_W-1:0] awaddr_q, araddr_q;
  logic [2:0]            awprot_q, arprot_q;
  logic [AXI_DATA_W-1:0] wdata_q;
  logic [AXI_STRB_W-1:0] wstrb_q;
  logic [AOU_ID_W-1:0]   id_q, id_ctr;
  logic [1:0]            bresp_q, rresp_q;
  logic [AXI_DATA_W-1:0] rdata_q;

  localparam logic [2:0] AXSIZE_4B = 3'b010;   // 32-bit beat

  // --- build the outgoing flits (combinational from captured regs) ----------
  function automatic flit_t build_write_flit();
    msg_t     m_wreq, m_wdata;
    payload_t pl;
    begin
      m_wreq  = mk_writereq(2'b00, 1'b0, '0, id_q, AXSIZE_4B, awprot_q,
                            '0, '0, '0,
                            {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, awaddr_q});
      m_wdata = mk_writedata256(2'b00, '0,
                            {{(AOU_DATA_W-AXI_DATA_W){1'b0}}, wdata_q},
                            {{(AOU_STRB_W-AXI_STRB_W){1'b0}}, wstrb_q});
      pl = payload_put('0,            0,             WRITEREQ_GRAN,  m_wreq);
      pl = payload_put(pl, WRITEREQ_GRAN, WRITEDATA_GRAN, m_wdata);
      build_write_flit = flit_assemble('0,
                           (msgstart_t'(1) << 0) | (msgstart_t'(1) << WRITEREQ_GRAN),
                           pl);
    end
  endfunction

  function automatic flit_t build_read_flit();
    msg_t     m_rreq;
    payload_t pl;
    begin
      m_rreq = mk_readreq(2'b00, 1'b0, '0, id_q, AXSIZE_4B, arprot_q,
                          '0, '0, '0,
                          {{(AOU_ADDR_W-AXI_ADDR_W){1'b0}}, araddr_q});
      pl = payload_put('0, 0, READREQ_GRAN, m_rreq);
      build_read_flit = flit_assemble('0, (msgstart_t'(1) << 0), pl);
    end
  endfunction

  // --- combinational outputs ------------------------------------------------
  assign s_awready = (state == S_IDLE) && !aw_seen;
  assign s_wready  = (state == S_IDLE) && !w_seen;
  assign s_arready = (state == S_IDLE) && !aw_seen && !w_seen;
  assign s_bvalid  = (state == S_B);
  assign s_bresp   = bresp_q;
  assign s_rvalid  = (state == S_R);
  assign s_rdata   = rdata_q;
  assign s_rresp   = rresp_q;
  assign tx_valid  = (state == S_WSEND) || (state == S_RSEND);
  assign rx_ready  = (state == S_WAIT);

  // Build the outgoing flit procedurally: Icarus 11 mis-generates a wide
  // function call placed directly in a continuous assign, so drive it from an
  // always_comb into a register-free net instead.
  always_comb begin
    if (state == S_WSEND) tx_data = build_write_flit();
    else                  tx_data = build_read_flit();
  end

  // --- FSM ------------------------------------------------------------------
  always_ff @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      state    <= S_IDLE;
      aw_seen  <= 1'b0;
      w_seen   <= 1'b0;
      is_write <= 1'b0;
      id_ctr   <= '0;
      id_q     <= '0;
      awaddr_q <= '0; awprot_q <= '0;
      araddr_q <= '0; arprot_q <= '0;
      wdata_q  <= '0; wstrb_q  <= '0;
      bresp_q  <= '0; rresp_q  <= '0; rdata_q <= '0;
    end else begin
      unique case (state)
        S_IDLE: begin : s_idle_blk
          logic aw_now, w_now;
          aw_now = aw_seen;
          w_now  = w_seen;
          if (s_awvalid && s_awready) begin
            aw_seen  <= 1'b1; aw_now = 1'b1;
            awaddr_q <= s_awaddr; awprot_q <= s_awprot;
          end
          if (s_wvalid && s_wready) begin
            w_seen  <= 1'b1; w_now = 1'b1;
            wdata_q <= s_wdata; wstrb_q <= s_wstrb;
          end
          if (aw_now && w_now) begin
            is_write <= 1'b1;
            id_q     <= id_ctr;
            id_ctr   <= id_ctr + 1'b1;
            state    <= S_WSEND;
          end else if (s_arvalid && s_arready) begin
            araddr_q <= s_araddr; arprot_q <= s_arprot;
            is_write <= 1'b0;
            id_q     <= id_ctr;
            id_ctr   <= id_ctr + 1'b1;
            state    <= S_RSEND;
          end
        end
        S_WSEND: if (tx_ready) begin
          aw_seen <= 1'b0; w_seen <= 1'b0; state <= S_WAIT;
        end
        S_RSEND: if (tx_ready) state <= S_WAIT;
        S_WAIT: if (rx_valid) begin : s_wait_blk
          payload_t              rpl;
          msg_t                  m;
          // AoU RDATA is 256b; only the low AXI_DATA_W bits carry this design's
          // 32-bit beat — the rest is intentionally dropped.
          // verilator lint_off UNUSEDSIGNAL
          logic [AOU_DATA_W-1:0] rd_full;
          // verilator lint_on UNUSEDSIGNAL
          rpl = flit_payload(rx_data);
          if (is_write) begin
            m        = payload_get(rpl, 0, WRITERESP_GRAN);
            bresp_q <= wrsp_resp(m);
            state   <= S_B;
          end else begin
            m        = payload_get(rpl, 0, READDATA_GRAN);
            rd_full  = rd_data(m);
            rdata_q <= rd_full[AXI_DATA_W-1:0];
            rresp_q <= rd_resp(m);
            state   <= S_R;
          end
        end
        S_B: if (s_bready) state <= S_IDLE;
        S_R: if (s_rready) state <= S_IDLE;
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
`endif
