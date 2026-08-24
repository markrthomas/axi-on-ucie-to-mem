// -----------------------------------------------------------------------------
// aou_flit_fv : formal property harness for the §4.3 flit protocol header and
//               the §5.8 message-into-payload packing (aou_pkg).
//
// The flit packer is pure combinational bit-plumbing, so it is an ideal formal
// target: for ARBITRARY field inputs we prove
//
//   * BYTE-EXACT §4.3 MAP — the ten protocol-header bytes that flit_get_byte()
//     exposes equal an INDEPENDENT restatement of the Figure-5 byte map written
//     out byte by byte here (FDId / MsgStart / MsgCredit / Rsvd at their exact
//     byte+bit positions, LSB-first within each field), and the 240 payload
//     bytes are the payload, byte-aligned, starting at PLP byte 10;
//   * RESERVED BITS ARE ZERO at every reserved header position;
//   * PACK -> UNPACK ROUND-TRIP — flit_fdid / flit_msgstart / flit_credit /
//     flit_payload recover exactly what flit_assemble_cr() packed;
//   * §6 MsgCredit (Table 16) round-trip — mc_* recover the sub-fields that
//     mk_msgcredit() packed, and the Table-17 encode->decode pair is monotone
//     (cred_decode(cred_encode_ge(n)) >= n), which is what makes the receiver's
//     saturating replenish sound;
//   * §5.8 payload placement — payload_get(payload_put(...)) round-trips a
//     message at granule 0 and payload_msgtype() sees its MSGTYPE.
//
// The restatement below is deliberately NOT written with msgstart_g(): the whole
// point is to check aou_pkg's loop-based scatter against a literal transcription
// of the specification figure.
//
// Read with yosys-slang (`plugin -i slang; read_slang`) — the stock yosys
// Verilog frontend cannot parse the `module ... import pkg::*;` header form the
// RTL uses, and slang gives full SV package/typedef support.
// -----------------------------------------------------------------------------
`default_nettype none
module aou_flit_fv
  import aou_pkg::*;
(
    input  wire                          clk,
    // ---- free formal inputs: arbitrary header/payload field values ----------
    input  wire [FDID_W-1:0]             fdid,
    input  wire [NUM_GRAN-1:0]           msgstart,
    input  wire [CREDIT_W-1:0]           msgcredit,
    input  wire [PLP_PAYLOAD_BITS-1:0]   payload,
    // ---- free formal inputs: arbitrary MsgCredit sub-fields (Table 16) ------
    input  wire [RP_W-1:0]               c_rp,
    input  wire [WREQCRED_W-1:0]         c_wreq,
    input  wire [RREQCRED_W-1:0]         c_rreq,
    input  wire [WDATACRED_W-1:0]        c_wdata,
    input  wire [RDATACRED_W-1:0]        c_rdata,
    input  wire [WRESPCRED_W-1:0]        c_wresp,
    input  wire [7:0]                    n_free,
    // ---- free formal inputs: an arbitrary WriteData256 message (§5.8) -------
    input  wire [AOU_DATA_W-1:0]         m_wdata,
    input  wire [AOU_STRB_W-1:0]         m_wstrb,
    input  wire [FLEX_W-1:0]             m_flex
);

  // === device under proof: the packer ======================================
  flit_t f;
  always_comb f = flit_assemble_cr(fdid, msgstart, msgcredit, payload);

  // =========================================================================
  // INDEPENDENT §4.3 (Figure 5) HEADER BYTE MAP.
  //
  // PLP byte 0 is PH B0, the first byte on the wire; within a byte the earliest
  // transmitted bit is the MSB.  Writing the ten bytes out literally:
  //
  //   B0 : FDId[0] FDId[1] Rsvd Rsvd MsgStart[0..3]
  //   B1 : MsgStart[4..11]
  //   B2 : Rsvd(4)          MsgStart[12..15]
  //   B3 : MsgStart[16..23]
  //   B4 : MsgCredit[0..7]
  //   B5 : MsgCredit[8..15]
  //   B6 : Rsvd(4)          MsgStart[24..27]
  //   B7 : MsgStart[28..35]
  //   B8 : Rsvd(4)          MsgStart[36..39]
  //   B9 : MsgStart[40..47]
  // =========================================================================
  wire [7:0] hb0 = {fdid[0], fdid[1], 2'b00,
                    msgstart[0],  msgstart[1],  msgstart[2],  msgstart[3]};
  wire [7:0] hb1 = {msgstart[4],  msgstart[5],  msgstart[6],  msgstart[7],
                    msgstart[8],  msgstart[9],  msgstart[10], msgstart[11]};
  wire [7:0] hb2 = {4'b0000,
                    msgstart[12], msgstart[13], msgstart[14], msgstart[15]};
  wire [7:0] hb3 = {msgstart[16], msgstart[17], msgstart[18], msgstart[19],
                    msgstart[20], msgstart[21], msgstart[22], msgstart[23]};
  wire [7:0] hb4 = {msgcredit[0], msgcredit[1], msgcredit[2], msgcredit[3],
                    msgcredit[4], msgcredit[5], msgcredit[6], msgcredit[7]};
  wire [7:0] hb5 = {msgcredit[8], msgcredit[9], msgcredit[10], msgcredit[11],
                    msgcredit[12], msgcredit[13], msgcredit[14], msgcredit[15]};
  wire [7:0] hb6 = {4'b0000,
                    msgstart[24], msgstart[25], msgstart[26], msgstart[27]};
  wire [7:0] hb7 = {msgstart[28], msgstart[29], msgstart[30], msgstart[31],
                    msgstart[32], msgstart[33], msgstart[34], msgstart[35]};
  wire [7:0] hb8 = {4'b0000,
                    msgstart[36], msgstart[37], msgstart[38], msgstart[39]};
  wire [7:0] hb9 = {msgstart[40], msgstart[41], msgstart[42], msgstart[43],
                    msgstart[44], msgstart[45], msgstart[46], msgstart[47]};

  // === §6 MsgCredit (Table 16) assembly under proof ========================
  wire [CREDIT_W-1:0] mc = mk_msgcredit(c_rp, c_wreq, c_rreq, c_wdata,
                                        c_rdata, c_wresp);

  // === §5.8 message placement under proof ==================================
  msg_t     m_in, m_out;
  payload_t pl;
  always_comb begin
    m_in  = mk_writedata256(2'b00, m_flex, m_wdata, m_wstrb);
    pl    = payload_put('0, 0, WRITEDATA_GRAN, m_in);
    m_out = payload_get(pl, 0, WRITEDATA_GRAN);
  end

  // =========================================================================
  // ASSERTIONS.  Everything here is combinational in the free inputs, so a
  // single clocked evaluation per step proves it for all field values.
  // =========================================================================
  always @(posedge clk) begin : header_bytes
    // --- byte-exact §4.3 protocol header ---
    assert (flit_get_byte(f, 0) == hb0);
    assert (flit_get_byte(f, 1) == hb1);
    assert (flit_get_byte(f, 2) == hb2);
    assert (flit_get_byte(f, 3) == hb3);
    assert (flit_get_byte(f, 4) == hb4);
    assert (flit_get_byte(f, 5) == hb5);
    assert (flit_get_byte(f, 6) == hb6);
    assert (flit_get_byte(f, 7) == hb7);
    assert (flit_get_byte(f, 8) == hb8);
    assert (flit_get_byte(f, 9) == hb9);
  end

  // --- the 240 payload bytes follow the header, byte-aligned ---------------
  always @(posedge clk) begin : payload_bytes
    for (int k = 0; k < PLP_PAYLOAD_BITS/8; k++)
      assert (flit_get_byte(f, PLP_HDR_BITS/8 + k) ==
              payload[PLP_PAYLOAD_BITS-1 - 8*k -: 8]);
  end

  // --- every reserved header bit is transmitted as 0 -----------------------
  // Reserved transmission-order positions (§4.3): 2,3, 16..19, 48..51, 64..67.
  always @(posedge clk) begin : reserved_zero
    assert (f[PLP_BITS-1 -  2] == 1'b0);
    assert (f[PLP_BITS-1 -  3] == 1'b0);
    for (int g = 16; g <= 19; g++) assert (f[PLP_BITS-1 - g] == 1'b0);
    for (int g = 48; g <= 51; g++) assert (f[PLP_BITS-1 - g] == 1'b0);
    for (int g = 64; g <= 67; g++) assert (f[PLP_BITS-1 - g] == 1'b0);
  end

  // --- pack -> unpack round-trip -------------------------------------------
  always @(posedge clk) begin : roundtrip
    assert (flit_fdid(f)     == fdid);
    assert (flit_msgstart(f) == msgstart);
    assert (flit_credit(f)   == msgcredit);
    assert (flit_payload(f)  == payload);
  end

  // --- §6 MsgCredit sub-field round-trip + Table-17 monotonicity -----------
  always @(posedge clk) begin : credit_fields
    int unsigned want3, want2;
    want3 = (int'(n_free) > CRED_MAX) ? CRED_MAX : int'(n_free);
    want2 = (int'(n_free) > 8)        ? 8        : int'(n_free);
    assert (mc_rp(mc)    == c_rp);
    assert (mc_wreq(mc)  == c_wreq);
    assert (mc_rreq(mc)  == c_rreq);
    assert (mc_wdata(mc) == c_wdata);
    assert (mc_rdata(mc) == c_rdata);
    assert (mc_wresp(mc) == c_wresp);
    // Table 17 buckets are ordered, and the encoder returns a bucket granting
    // AT LEAST what it was asked for (up to the CRED_MAX ceiling) — the
    // property the bridges' saturating replenish relies on.
    assert (cred_decode(cred_encode_ge(n_free)) >= want3);
    assert (cred_decode({1'b0, cred_encode_ge2(n_free)}) >= want2);
  end

  // --- §5.8 payload placement round-trip -----------------------------------
  always @(posedge clk) begin : msg_roundtrip
    assert (payload_msgtype(pl, 0) == MT_WRITEDATA);
    assert (wd_data(m_out) == m_wdata);
    assert (wd_strb(m_out) == m_wstrb);
    assert (get_msgtype(m_out) == MT_WRITEDATA);
    assert (msg_dlength(m_out) == DLEN_256);
  end

  // =========================================================================
  // COVER — the packer can actually produce non-trivial flits (guards against
  // a vacuous proof over a constant-folded design).
  // =========================================================================
  always @(posedge clk) begin : reach
    cover (msgstart[0] && msgcredit != '0 && fdid != '0);
    cover (&msgstart);
    cover (flit_get_byte(f, 4) == 8'hFF);
  end

endmodule
`default_nettype wire
