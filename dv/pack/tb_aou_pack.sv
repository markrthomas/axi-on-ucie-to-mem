// -----------------------------------------------------------------------------
// tb_aou_pack : §4.3 / §5.8 byte-exact packing conformance test.
//
// Builds AoU flits with the aou_pkg packers and checks that the resulting bytes
// match the spec's byte map, reconstructed INDEPENDENTLY here from the figures
// (so the check does not merely restate the package's own layout functions):
//   * §4.3 Figure 5 — the 10-byte protocol header: FDId / MsgStart[47:0] /
//     MsgCredit[15:0] / Rsvd scattered across PH B0..B9, packed LSB-first;
//   * §5.8 Figures 6/8/14 — the message field layouts inside the payload
//     granules, byte 0 first with MSB-first fields (checked via the leading
//     MSGTYPE nibble of granule 0 and a full field round-trip).
//
// Self-checking; runs under Icarus and Verilator.  Prints "[PACK-TB] PASS".
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_aou_pack
  import aou_pkg::*;
;

  int errors = 0;
  int checks = 0;

  task automatic check(input logic cond, input string what);
    begin
      checks = checks + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("[PACK-TB] MISMATCH: %s", what);
      end
    end
  endtask

  // spec Figure-5 header byte, reconstructed field-by-field (byte MSB = the
  // figure's bit label 0; header fields are packed LSB-first).
  function automatic logic [7:0] exp_hdr_byte(input logic [FDID_W-1:0]   fdid,
                                              input msgstart_t           ms,
                                              input logic [CREDIT_W-1:0] mc,
                                              input int                  b);
    case (b)
      0: exp_hdr_byte = {fdid[0], fdid[1], 2'b00, ms[0], ms[1], ms[2], ms[3]};
      1: exp_hdr_byte = {ms[4], ms[5], ms[6], ms[7], ms[8], ms[9], ms[10], ms[11]};
      2: exp_hdr_byte = {4'b0000, ms[12], ms[13], ms[14], ms[15]};
      3: exp_hdr_byte = {ms[16], ms[17], ms[18], ms[19], ms[20], ms[21], ms[22], ms[23]};
      4: exp_hdr_byte = {mc[0], mc[1], mc[2], mc[3], mc[4], mc[5], mc[6], mc[7]};
      5: exp_hdr_byte = {mc[8], mc[9], mc[10], mc[11], mc[12], mc[13], mc[14], mc[15]};
      6: exp_hdr_byte = {4'b0000, ms[24], ms[25], ms[26], ms[27]};
      7: exp_hdr_byte = {ms[28], ms[29], ms[30], ms[31], ms[32], ms[33], ms[34], ms[35]};
      8: exp_hdr_byte = {4'b0000, ms[36], ms[37], ms[38], ms[39]};
      9: exp_hdr_byte = {ms[40], ms[41], ms[42], ms[43], ms[44], ms[45], ms[46], ms[47]};
      default: exp_hdr_byte = 8'h00;
    endcase
  endfunction

  initial begin : main
    logic [FDID_W-1:0]   fdid;
    msgstart_t           ms;
    logic [CREDIT_W-1:0] mc;
    msg_t                m_wreq, m_rdata, mg;
    payload_t            pl;
    flit_t               f;
    string               s;
    logic [7:0]          byte10;               // func-call result temps (Icarus
    logic [AOU_DATA_W-1:0] rdd;                // can't part-select a call inline)

    // --- stimulus: values chosen to light up every scattered header byte ----
    fdid = 2'b01;                       // FDId[0]=1, FDId[1]=0
    ms   = 48'hA5A5_A5A5_A5A5;          // MsgStart across all byte regions
    mc   = 16'h1234;                    // MsgCredit (tests B4/B5 scatter)

    // --- WriteReq flit (Figure 6 payload + Figure 5 header) -----------------
    m_wreq = mk_writereq(2'b00, 1'b0, 16'hBEEF, 10'h123, 3'b010, 3'b101,
                         8'h00, 4'b0000, 4'b0000, 64'hDEAD_BEEF_0000_1234);
    pl = payload_put('0, 0, WRITEREQ_GRAN, m_wreq);
    f  = flit_assemble_cr(fdid, ms, mc, pl);

    // (1) §4.3 header byte map: package bytes == independent spec reconstruction
    for (int b = 0; b < 10; b++) begin
      s = $sformatf("PH B%0d  got=%02h exp=%02h", b,
                    flit_get_byte(f, b), exp_hdr_byte(fdid, ms, mc, b));
      check(flit_get_byte(f, b) == exp_hdr_byte(fdid, ms, mc, b), s);
    end

    // (2) header field round-trip through the scattered layout
    check(flit_fdid(f)     == fdid, "flit_fdid round-trip");
    check(flit_msgstart(f) == ms,   "flit_msgstart round-trip");
    check(flit_credit(f)   == mc,   "flit_credit round-trip");
    check(flit_payload(f)  == pl,   "flit_payload round-trip");

    // (3) §5.8 payload: first payload byte is granule-0 byte-0; its top nibble
    //     is MSGTYPE (byte 0 first, MSB-first).  Payload starts at PLP byte 10.
    byte10 = flit_get_byte(f, 10);
    check(byte10[7:4] == MT_WRITEREQ, "granule0 MSGTYPE nibble");

    // (4) §5.8 field round-trip: recover the WriteReq fields from the payload
    mg = payload_get(flit_payload(f), 0, WRITEREQ_GRAN);
    check(get_msgtype(mg) == MT_WRITEREQ,               "wreq msgtype");
    check(wr_addr(mg)     == 64'hDEAD_BEEF_0000_1234,   "wreq addr");
    check(wr_id(mg)       == 10'h123,                   "wreq id");
    check(wr_flex(mg)     == 16'hBEEF,                  "wreq flex");

    // --- ReadData flit: exercise the response payload MSGTYPE too ------------
    m_rdata = mk_readdata256(2'b00, 16'h0, 10'h2AB, 2'b00, 1'b1,
                             {{(AOU_DATA_W-32){1'b0}}, 32'hCAFEF00D});
    pl = payload_put('0, 0, READDATA_GRAN, m_rdata);
    f  = flit_assemble_cr(2'b00, msgstart_t'(1), '0, pl);
    byte10 = flit_get_byte(f, 10);
    check(byte10[7:4] == MT_READDATA, "readdata MSGTYPE nibble");
    mg  = payload_get(flit_payload(f), 0, READDATA_GRAN);
    rdd = rd_data(mg);
    check(rd_id(mg)   == 10'h2AB,       "rdata id");
    check(rdd[31:0] == 32'hCAFEF00D,    "rdata data");

    // --- Misc messages (§5.6 / §6.4.2 / §8.3.4): build, pack, round-trip ----
    // ActivateReq (4 granules) — packed into a flit and recovered.
    mg = mk_activate_req(5'h0, 5'h0, 16'h0);
    check(get_msgtype(mg)       == MT_MISC,            "actreq msgtype");
    check(misc_op(mg)           == MISCOP_ACTIVATION,  "actreq miscop");
    check(misc_activationop(mg) == ACTOP_ACTIVATE_REQ, "actreq activationop");
    pl = payload_put('0, 0, ACTIVATEREQ_GRAN, mg);
    f  = flit_assemble('0, msgstart_t'(1), pl);
    byte10 = flit_get_byte(f, 10);
    check(byte10[7:4] == MT_MISC,       "actreq granule0 MSGTYPE nibble");
    mg = payload_get(flit_payload(f), 0, ACTIVATEREQ_GRAN);
    check(misc_activationop(mg) == ACTOP_ACTIVATE_REQ, "actreq activationop (unpacked)");

    // ActivateAck (1 granule).
    mg = mk_activation_other(ACTOP_ACTIVATE_ACK);
    check(misc_op(mg)           == MISCOP_ACTIVATION,  "actack miscop");
    check(misc_activationop(mg) == ACTOP_ACTIVATE_ACK, "actack activationop");

    // CrdtGrant (2 granules): RP0 credit codes round-trip + Table-17 decode.
    mg = mk_crdtgrant(3'b010, 3'b010, 3'b011, 3'b011, 2'b01);
    check(get_msgtype(mg) == MT_MISC,         "crdt msgtype");
    check(misc_op(mg)     == MISCOP_CRDTGRANT, "crdt miscop");
    check(cg_wreq0(mg)  == 3'b010, "crdt wreq0");
    check(cg_rreq0(mg)  == 3'b010, "crdt rreq0");
    check(cg_wdata0(mg) == 3'b011, "crdt wdata0");
    check(cg_rdata0(mg) == 3'b011, "crdt rdata0");
    check(cg_wresp0(mg) == 2'b01,  "crdt wresp0");
    check(cred_decode(cg_wdata0(mg)) == 8, "crdt wdata0 Table-17 decode");

    // --- report -------------------------------------------------------------
    if (errors == 0)
      $display("[PACK-TB] PASS: %0d checks, 0 errors", checks);
    else
      $display("[PACK-TB] FAIL: %0d checks, %0d errors", checks, errors);
    $finish;
  end

endmodule
