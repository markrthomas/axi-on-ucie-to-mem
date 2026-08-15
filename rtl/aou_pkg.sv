// -----------------------------------------------------------------------------
// aou_pkg : AXI-over-UCIe (AoU) Basic-Profile message + flit definitions.
//
// Source: "AXI over UCIe Protocol Specification v0.8" (OCA / Tenstorrent),
//   Chapter 4 (Packing) and Chapter 5 (Message Structures).
//
// Scope of THIS package (see docs/PLAN.md):
//   * Basic Profile messages: WriteReq, ReadReq, WriteData(256b),
//     ReadData(256b), WriteResp.  (WriteDataFull / 512b / 1024b not built.)
//   * Resource Plane RP0 only; §6 per-message-type credit flow control (see the
//     credit helpers below and the bridges); no activation FSM (§8).
//   * AXI4-Lite front door, 32-bit data / 32-bit address, single beat
//     (AWLEN=ARLEN=0, DLENGTH=00 -> 256b data message).
//
// Bit-ordering convention (documented, shared by packer + unpacker):
//   * A message is packed MSB-first in spec table order (Tables 2,3,4,10,13):
//     the first table field lands in the most-significant bits.
//   * Each message is left-justified in an MSG_MAX_BITS (=320b) vector, so
//     message granule 0 is always the MSB slice [319:280].
//   * The 240B PLP payload is NUM_GRAN granules of GRAN_BITS bits each, granule
//     0 = most-significant.  A message of N granules starting at granule g
//     occupies payload[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS -: N*GRAN_BITS].
//   Field order, widths and granule counts match the §5.8 message layouts
//   exactly (byte 0 first, MSB-first fields), and the §4.3 protocol header uses
//   the exact Figure-5 byte map (FDId/MsgStart/MsgCredit/Rsvd scattered across
//   the 10 header bytes, LSB-first).  flit_get_byte() exposes the byte-exact
//   PLP for conformance checking.
// -----------------------------------------------------------------------------
`ifndef AOU_PKG_SV
`define AOU_PKG_SV

// This is a protocol-definition package: it deliberately declares the full
// Basic-Profile field set (including reserved fields and the 512b/1024b DLENGTH
// encodings this build does not yet use), and its field getters each read only
// the slice of a message they need.  Both are intentional, so waive the
// "unused" lints that would otherwise fire on the package in isolation.
// verilator lint_off UNUSEDPARAM
// verilator lint_off UNUSEDSIGNAL
package aou_pkg;

  // --- Flit / PLP geometry (spec §4.2) --------------------------------------
  localparam int GRAN_BITS         = 40;                 // 5 bytes per granule
  localparam int NUM_GRAN          = 48;                 // 240B payload / 5B
  localparam int PLP_PAYLOAD_BITS  = GRAN_BITS * NUM_GRAN; // 1920
  localparam int PLP_HDR_BITS      = 80;                 // 10B protocol header
  localparam int PLP_BITS          = PLP_HDR_BITS + PLP_PAYLOAD_BITS; // 2000 (250B)

  localparam int FDID_W  = 2;                           // Flit Destination ID
  localparam int CREDIT_W = 16;                          // MsgCredit field
  localparam int HDR_RSVD_W = PLP_HDR_BITS - FDID_W - NUM_GRAN - CREDIT_W; // 14

  typedef logic [PLP_BITS-1:0]         flit_t;           // 250B PLP == link word
  typedef logic [PLP_PAYLOAD_BITS-1:0] payload_t;        // 240B / 48 granules
  typedef logic [NUM_GRAN-1:0]         msgstart_t;       // MsgStart bitmap

  // --- MSGTYPE encoding (spec Table 1) --------------------------------------
  localparam int MSGTYPE_W = 4;
  typedef enum logic [MSGTYPE_W-1:0] {
    MT_MISC          = 4'b0000,
    MT_WRITEREQ      = 4'b0001,
    MT_READREQ       = 4'b0010,
    MT_WRITEDATA     = 4'b0011,
    MT_READDATA      = 4'b0100,
    MT_WRITERESP     = 4'b0101,
    MT_WRITEDATAFULL = 4'b0110
  } msgtype_e;

  // --- AoU-specific + AXI-equivalent field widths (Basic Profile) -----------
  localparam int RP_W      = 2;    // resource plane
  localparam int DLENGTH_W = 2;    // data-message width selector
  localparam int FLEX_W    = 16;   // USER[15:0] in Basic Profile
  localparam int AOU_ID_W  = 10;   // AWID/ARID/BID/RID
  localparam int AOU_SIZE_W  = 3;
  localparam int AOU_PROT_W  = 3;
  localparam int AOU_LEN_W   = 8;
  localparam int AOU_CACHE_W = 4;
  localparam int AOU_QOS_W   = 4;
  localparam int AOU_ADDR_W  = 64;
  localparam int AOU_DATA_W  = 256;  // WriteData/ReadData(256b)
  localparam int AOU_STRB_W  = 32;
  localparam int AOU_RESP_W  = 2;    // RRESP/BRESP

  // DLENGTH encodings (spec §5.4).  This design uses 256b only.
  localparam logic [DLENGTH_W-1:0] DLEN_256  = 2'b00;
  localparam logic [DLENGTH_W-1:0] DLEN_512  = 2'b01;
  localparam logic [DLENGTH_W-1:0] DLEN_1024 = 2'b10;

  // --- Message bit-lengths and granule counts (spec §5.3-5.5) ---------------
  localparam int WRITEREQ_BITS  = 120; localparam int WRITEREQ_GRAN  = 3;
  localparam int READREQ_BITS   = 120; localparam int READREQ_GRAN   = 3;
  localparam int WRITEDATA_BITS = 320; localparam int WRITEDATA_GRAN = 8;
  localparam int READDATA_BITS  = 320; localparam int READDATA_GRAN  = 8;
  localparam int WRITERESP_BITS = 40;  localparam int WRITERESP_GRAN = 1;

  localparam int MSG_MAX_BITS = 320;   // largest built message (WriteData256)
  localparam int MSG_MAX_GRAN = 8;

  typedef logic [MSG_MAX_BITS-1:0] msg_t;   // left-justified message container

  // granule count for a decoded MSGTYPE (0 = unknown/unsupported)
  function automatic int msg_granules(input logic [MSGTYPE_W-1:0] mt);
    case (mt)
      MT_WRITEREQ  : msg_granules = WRITEREQ_GRAN;
      MT_READREQ   : msg_granules = READREQ_GRAN;
      MT_WRITEDATA : msg_granules = WRITEDATA_GRAN;
      MT_READDATA  : msg_granules = READDATA_GRAN;
      MT_WRITERESP : msg_granules = WRITERESP_GRAN;
      default      : msg_granules = 0;
    endcase
  endfunction

  // =========================================================================
  // Message builders.  Each returns an MSG_MAX_BITS vector with the message
  // left-justified (granule 0 in the MSBs) and low bits zero-padded.
  // AXI-Lite fields are widened into the AoU fields (addr/data zero-extended,
  // id placed in the low bits of the 10-bit AoU id field).
  // =========================================================================

  // WriteReq (Table 2): MSGTYPE,RP,RsvdZero(1),AWLOCK,FLEX,AWID,AWSIZE,AWPROT,
  //                     AWLEN,AWCACHE,AWQOS,AWADDR  => 120b
  function automatic msg_t mk_writereq(
      input logic [RP_W-1:0]        rp,
      input logic                   awlock,
      input logic [FLEX_W-1:0]      flex,
      input logic [AOU_ID_W-1:0]    awid,
      input logic [AOU_SIZE_W-1:0]  awsize,
      input logic [AOU_PROT_W-1:0]  awprot,
      input logic [AOU_LEN_W-1:0]   awlen,
      input logic [AOU_CACHE_W-1:0] awcache,
      input logic [AOU_QOS_W-1:0]   awqos,
      input logic [AOU_ADDR_W-1:0]  awaddr);
    logic [WRITEREQ_BITS-1:0] v;
    begin
      v = {MT_WRITEREQ, rp, 1'b0, awlock, flex, awid, awsize, awprot,
           awlen, awcache, awqos, awaddr};
      mk_writereq = {v, {(MSG_MAX_BITS-WRITEREQ_BITS){1'b0}}};
    end
  endfunction

  // ReadReq (Table 3): symmetric to WriteReq => 120b
  function automatic msg_t mk_readreq(
      input logic [RP_W-1:0]        rp,
      input logic                   arlock,
      input logic [FLEX_W-1:0]      flex,
      input logic [AOU_ID_W-1:0]    arid,
      input logic [AOU_SIZE_W-1:0]  arsize,
      input logic [AOU_PROT_W-1:0]  arprot,
      input logic [AOU_LEN_W-1:0]   arlen,
      input logic [AOU_CACHE_W-1:0] arcache,
      input logic [AOU_QOS_W-1:0]   arqos,
      input logic [AOU_ADDR_W-1:0]  araddr);
    logic [READREQ_BITS-1:0] v;
    begin
      v = {MT_READREQ, rp, 1'b0, arlock, flex, arid, arsize, arprot,
           arlen, arcache, arqos, araddr};
      mk_readreq = {v, {(MSG_MAX_BITS-READREQ_BITS){1'b0}}};
    end
  endfunction

  // WriteData 256b (Table 4): MSGTYPE,RP,DLENGTH,FLEX,WDATA(256),WSTRB(32),
  //                           RsvdZero(8) => 320b (exactly MSG_MAX_BITS)
  function automatic msg_t mk_writedata256(
      input logic [RP_W-1:0]       rp,
      input logic [FLEX_W-1:0]     flex,
      input logic [AOU_DATA_W-1:0] wdata,
      input logic [AOU_STRB_W-1:0] wstrb);
    mk_writedata256 = {MT_WRITEDATA, rp, DLEN_256, flex, wdata, wstrb, 8'b0};
  endfunction

  // ReadData 256b (Table 10): MSGTYPE,RP,DLENGTH,FLEX,RID,RRESP,RLAST,
  //   RsvdZero(3),RDATA(256),RsvdZero(24) => 320b
  function automatic msg_t mk_readdata256(
      input logic [RP_W-1:0]       rp,
      input logic [FLEX_W-1:0]     flex,
      input logic [AOU_ID_W-1:0]   rid,
      input logic [AOU_RESP_W-1:0] rresp,
      input logic                  rlast,
      input logic [AOU_DATA_W-1:0] rdata);
    mk_readdata256 = {MT_READDATA, rp, DLEN_256, flex, rid, rresp, rlast,
                      3'b0, rdata, 24'b0};
  endfunction

  // WriteResp (Table 13): MSGTYPE,RP,RsvdZero(2),FLEX,BID,BRESP,RsvdZero(4)
  //                       => 40b (1 granule) left-justified in 320b
  function automatic msg_t mk_writeresp(
      input logic [RP_W-1:0]       rp,
      input logic [FLEX_W-1:0]     flex,
      input logic [AOU_ID_W-1:0]   bid,
      input logic [AOU_RESP_W-1:0] bresp);
    logic [WRITERESP_BITS-1:0] v;
    begin
      v = {MT_WRITERESP, rp, 2'b0, flex, bid, bresp, 4'b0};
      mk_writeresp = {v, {(MSG_MAX_BITS-WRITERESP_BITS){1'b0}}};
    end
  endfunction

  // =========================================================================
  // Field extractors.  Input `m` is a left-justified MSG_MAX_BITS slice (the
  // unpacker builds it by taking N granules from the payload and zero-padding
  // the low bits).  MSGTYPE is always m[MSG_MAX_BITS-1 -: 4].
  // =========================================================================
  function automatic logic [MSGTYPE_W-1:0] get_msgtype(input msg_t m);
    get_msgtype = m[MSG_MAX_BITS-1 -: MSGTYPE_W];
  endfunction

  // WriteReq field getters
  function automatic logic [AOU_ADDR_W-1:0] wr_addr(input msg_t m);
    // AWADDR is the last (LSB) field of the 120b message
    wr_addr = m[(MSG_MAX_BITS-WRITEREQ_BITS) +: AOU_ADDR_W];
  endfunction
  function automatic logic [AOU_ID_W-1:0] wr_id(input msg_t m);
    // AWID sits after MSGTYPE(4),RP(2),RsvdZero(1),AWLOCK(1),FLEX(16) = 24 bits
    wr_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [FLEX_W-1:0] wr_flex(input msg_t m);
    wr_flex = m[MSG_MAX_BITS-1-8 -: FLEX_W];  // after 4+2+1+1 = 8 bits
  endfunction
  function automatic logic [AOU_SIZE_W-1:0] wr_size(input msg_t m);
    wr_size = m[MSG_MAX_BITS-1-34 -: AOU_SIZE_W];   // after 24 + AWID(10)
  endfunction
  function automatic logic [AOU_LEN_W-1:0] wr_len(input msg_t m);
    wr_len = m[MSG_MAX_BITS-1-40 -: AOU_LEN_W];     // after 34 + AWSIZE(3)+AWPROT(3)
  endfunction
  // AoU Table 2 WriteReq has no AWBURST field; the burst type rides in FLEX[1:0]
  // as a Basic-Profile extension (§5.2 FLEX "additional information / extensions").
  function automatic logic [1:0] wr_burst(input msg_t m);
    logic [FLEX_W-1:0] f;                 // temp: Icarus rejects func(...)[range]
    begin f = wr_flex(m); wr_burst = f[1:0]; end
  endfunction

  // ReadReq field getters (identical layout to WriteReq)
  function automatic logic [AOU_ADDR_W-1:0] rr_addr(input msg_t m);
    rr_addr = m[(MSG_MAX_BITS-READREQ_BITS) +: AOU_ADDR_W];
  endfunction
  function automatic logic [AOU_ID_W-1:0] rr_id(input msg_t m);
    rr_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [FLEX_W-1:0] rr_flex(input msg_t m);
    rr_flex = m[MSG_MAX_BITS-1-8 -: FLEX_W];
  endfunction
  function automatic logic [AOU_SIZE_W-1:0] rr_size(input msg_t m);
    rr_size = m[MSG_MAX_BITS-1-34 -: AOU_SIZE_W];
  endfunction
  function automatic logic [AOU_LEN_W-1:0] rr_len(input msg_t m);
    rr_len = m[MSG_MAX_BITS-1-40 -: AOU_LEN_W];
  endfunction
  function automatic logic [1:0] rr_burst(input msg_t m);
    logic [FLEX_W-1:0] f;
    begin f = rr_flex(m); rr_burst = f[1:0]; end
  endfunction

  // AXI burst types (AxBURST encoding).  Carried in FLEX[1:0] (see wr_burst).
  localparam logic [1:0] AXBURST_FIXED = 2'b00;
  localparam logic [1:0] AXBURST_INCR  = 2'b01;
  localparam logic [1:0] AXBURST_WRAP  = 2'b10;

  // Next-beat address for an AXI burst (FIXED/INCR/WRAP), per the AXI4 spec.
  //   addr = current beat address, base = burst start address,
  //   size = log2(bytes/beat), len = AxLEN (beats-1).
  // WRAP wraps at the aligned boundary of (len+1)*2^size bytes (len+1 in {2,4,
  // 8,16}); FIXED holds the address; INCR increments by 2^size.
  function automatic logic [AOU_ADDR_W-1:0] axi_burst_next(
      input logic [AOU_ADDR_W-1:0] addr,
      input logic [AOU_ADDR_W-1:0] base,
      input logic [1:0]            burst,
      input logic [AOU_SIZE_W-1:0] size,
      input logic [AOU_LEN_W-1:0]  len);
    logic [AOU_ADDR_W-1:0] nbytes, total, low, nxt;
    begin
      nbytes = (1 << size);
      unique case (burst)
        AXBURST_FIXED: axi_burst_next = addr;
        AXBURST_WRAP: begin
          total = ({{(AOU_ADDR_W-AOU_LEN_W){1'b0}}, len} + 1) << size;
          low   = base & ~(total - 1);
          nxt   = addr + nbytes;
          axi_burst_next = (nxt == (low + total)) ? low : nxt;
        end
        default: axi_burst_next = addr + nbytes;   // AXBURST_INCR
      endcase
    end
  endfunction

  // WriteData256 getters: after MSGTYPE(4),RP(2),DLENGTH(2),FLEX(16) = 24 bits
  function automatic logic [AOU_DATA_W-1:0] wd_data(input msg_t m);
    wd_data = m[MSG_MAX_BITS-1-24 -: AOU_DATA_W];
  endfunction
  function automatic logic [AOU_STRB_W-1:0] wd_strb(input msg_t m);
    wd_strb = m[MSG_MAX_BITS-1-24-AOU_DATA_W -: AOU_STRB_W];
  endfunction

  // ReadData256 getters: MSGTYPE(4),RP(2),DLENGTH(2),FLEX(16),RID(10),
  //   RRESP(2),RLAST(1),RsvdZero(3) then RDATA(256)
  function automatic logic [AOU_ID_W-1:0] rd_id(input msg_t m);
    rd_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [AOU_RESP_W-1:0] rd_resp(input msg_t m);
    rd_resp = m[MSG_MAX_BITS-1-34 -: AOU_RESP_W];  // after 24+10
  endfunction
  function automatic logic rd_last(input msg_t m);
    rd_last = m[MSG_MAX_BITS-1-36];                // after 24+10+2
  endfunction
  function automatic logic [AOU_DATA_W-1:0] rd_data(input msg_t m);
    rd_data = m[MSG_MAX_BITS-1-40 -: AOU_DATA_W];  // after 24+10+2+1+3 = 40
  endfunction

  // WriteResp getters: after MSGTYPE(4),RP(2),RsvdZero(2),FLEX(16) = 24 bits
  function automatic logic [AOU_ID_W-1:0] wrsp_id(input msg_t m);
    wrsp_id = m[MSG_MAX_BITS-1-24 -: AOU_ID_W];
  endfunction
  function automatic logic [AOU_RESP_W-1:0] wrsp_resp(input msg_t m);
    wrsp_resp = m[MSG_MAX_BITS-1-34 -: AOU_RESP_W];
  endfunction

  // =========================================================================
  // Flit assembly / disassembly (spec §4.2-4.3, byte-exact).
  //
  // The 250B PLP is a 10B protocol header (PH B0..B9) followed by the 240B
  // payload.  Per §4.3 (Figure 5) the header fields are NOT contiguous: FDId,
  // the 48-bit MsgStart bitmap, the 16-bit MsgCredit word, and 14 Rsvd bits are
  // scattered across the ten header bytes at fixed byte/bit positions.  Unlike
  // the §5.8 message fields (packed MSB-first), the header packs each field
  // LSB-first — MsgStart[0], MsgCredit[0], FDId[0] are the earliest bits.  We
  // model that exact layout so flit_get_byte() reproduces the spec's byte map.
  //
  // Let g be a header bit's transmission order (g=0 is PH B0's first bit); it
  // sits at flit[PLP_BITS-1-g].  The payload is flit[PLP_PAYLOAD_BITS-1:0].
  //   FDId[j]      : g = j              (PH B0 labels 0..1)
  //   MsgCredit[j] : g = 32 + j         (PH B4/B5)
  //   MsgStart[i]  : g = msgstart_g(i)  (scattered across B0..B3, B6..B9)
  //   Rsvd (=0)    : g in {2,3, 16..19, 48..51, 64..67}
  // =========================================================================

  // Transmission-order bit index of MsgStart[i] within the header (Figure 5:
  // MsgStart occupies PH B0[4:7],B1,B2[4:7],B3 then B6[4:7],B7,B8[4:7],B9).
  function automatic int msgstart_g(input int i);
    if      (i <= 11) msgstart_g = i + 4;    // B0[4:7], B1, B2[4:7]start
    else if (i <= 23) msgstart_g = i + 8;    // B2[4:7], B3
    else if (i <= 35) msgstart_g = i + 28;   // B6[4:7], B7
    else              msgstart_g = i + 32;   // B8[4:7], B9
  endfunction

  function automatic flit_t flit_assemble_cr(input logic [FDID_W-1:0]   fdid,
                                             input msgstart_t           msgstart,
                                             input logic [CREDIT_W-1:0] msgcredit,
                                             input payload_t            payload);
    flit_t f;
    begin
      f = '0;
      f[PLP_PAYLOAD_BITS-1:0] = payload;
      for (int j = 0; j < FDID_W;   j++) f[PLP_BITS-1 - j]            = fdid[j];
      for (int j = 0; j < CREDIT_W; j++) f[PLP_BITS-1 - (32 + j)]     = msgcredit[j];
      for (int i = 0; i < NUM_GRAN; i++) f[PLP_BITS-1 - msgstart_g(i)] = msgstart[i];
      flit_assemble_cr = f;                  // Rsvd bits left at 0
    end
  endfunction

  // MsgCredit=0 convenience wrapper (used where no credit is advertised).
  function automatic flit_t flit_assemble(input logic [FDID_W-1:0] fdid,
                                          input msgstart_t         msgstart,
                                          input payload_t          payload);
    flit_assemble = flit_assemble_cr(fdid, msgstart, {CREDIT_W{1'b0}}, payload);
  endfunction

  function automatic msgstart_t flit_msgstart(input flit_t f);
    msgstart_t m;
    begin
      m = '0;
      for (int i = 0; i < NUM_GRAN; i++) m[i] = f[PLP_BITS-1 - msgstart_g(i)];
      flit_msgstart = m;
    end
  endfunction

  function automatic logic [CREDIT_W-1:0] flit_credit(input flit_t f);
    logic [CREDIT_W-1:0] c;
    begin
      c = '0;
      for (int j = 0; j < CREDIT_W; j++) c[j] = f[PLP_BITS-1 - (32 + j)];
      flit_credit = c;
    end
  endfunction

  function automatic logic [FDID_W-1:0] flit_fdid(input flit_t f);
    logic [FDID_W-1:0] d;
    begin
      d = '0;
      for (int j = 0; j < FDID_W; j++) d[j] = f[PLP_BITS-1 - j];
      flit_fdid = d;
    end
  endfunction

  function automatic payload_t flit_payload(input flit_t f);
    flit_payload = f[PLP_PAYLOAD_BITS-1:0];
  endfunction

  // Byte-addressable §4.3/§5.8 view: PLP byte 0 = PH B0 (first on the wire),
  // bytes 10.. are payload granule bytes; byte idx's label-0 bit is its MSB.
  function automatic logic [7:0] flit_get_byte(input flit_t f, input int idx);
    flit_get_byte = f[PLP_BITS-1 - idx*8 -: 8];
  endfunction

  // Place a (left-justified) message of `gran` granules into a payload at
  // granule `g`.  Returns the payload bits to be OR-ed / assigned.
  function automatic payload_t payload_put(input payload_t base,
                                           input int       g,
                                           input int       gran,
                                           input msg_t     m);
    payload_t p;
    begin
      p = base;
      // granule g occupies payload[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS -: 40];
      // a `gran`-granule message spans gran*GRAN_BITS bits from that top.
      for (int b = 0; b < gran*GRAN_BITS; b++)
        p[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS - b] = m[MSG_MAX_BITS-1 - b];
      payload_put = p;
    end
  endfunction

  // Extract the message that starts at granule `g` (length `gran`) from a
  // payload, returned left-justified in an MSG_MAX_BITS container.
  function automatic msg_t payload_get(input payload_t p,
                                       input int       g,
                                       input int       gran);
    msg_t m;
    begin
      m = '0;
      for (int b = 0; b < gran*GRAN_BITS; b++)
        m[MSG_MAX_BITS-1 - b] = p[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS - b];
      payload_get = m;
    end
  endfunction

  // MSGTYPE of the message starting at granule g (top 4 bits of that granule).
  function automatic logic [MSGTYPE_W-1:0] payload_msgtype(input payload_t p,
                                                           input int g);
    payload_msgtype = p[PLP_PAYLOAD_BITS-1 - g*GRAN_BITS -: MSGTYPE_W];
  endfunction

  // =========================================================================
  // §6 Flow control — per-message-type, per-granule credits (Basic Profile,
  // resource plane RP0).  A credit guarantees the receiver has room for one
  // granule of the advertised message type (§6.1); all of a message's credits
  // are consumed by the transmitter at its start.  Credits are advertised in
  // the 16-bit MsgCredit header field, sub-divided per Table 16 and value-
  // encoded in coarse buckets per Table 17.
  // =========================================================================

  // Per-type credit sub-field widths (Table 16).
  localparam int WREQCRED_W  = 3;   // MsgCredit[2:0]
  localparam int RREQCRED_W  = 3;   // MsgCredit[5:3]
  localparam int WDATACRED_W = 3;   // MsgCredit[8:6]
  localparam int RDATACRED_W = 3;   // MsgCredit[11:9]
  localparam int WRESPCRED_W = 2;   // MsgCredit[13:12]  (RP is MsgCredit[15:14])

  localparam int CRED_MAX = 128;    // largest grant (Table 17 'b111)

  // Table 17: a *CRED bucket code -> number of granted credits.
  function automatic int unsigned cred_decode(input logic [2:0] code);
    case (code)
      3'b000: cred_decode = 0;
      3'b001: cred_decode = 1;
      3'b010: cred_decode = 4;
      3'b011: cred_decode = 8;
      3'b100: cred_decode = 16;
      3'b101: cred_decode = 32;
      3'b110: cred_decode = 64;
      3'b111: cred_decode = 128;
      default:cred_decode = 0;
    endcase
  endfunction

  // Smallest Table-17 bucket granting at least `n` credits (n<=128 saturates).
  // Used to return "at least the granules just freed"; the peer counter then
  // saturates at its ceiling, so a coarse over-grant is harmless (§6.4).
  function automatic logic [2:0] cred_encode_ge(input logic [7:0] n);
    if      (n == 0) cred_encode_ge = 3'b000;
    else if (n <= 1) cred_encode_ge = 3'b001;
    else if (n <= 4) cred_encode_ge = 3'b010;
    else if (n <= 8) cred_encode_ge = 3'b011;
    else if (n <= 16) cred_encode_ge = 3'b100;
    else if (n <= 32) cred_encode_ge = 3'b101;
    else if (n <= 64) cred_encode_ge = 3'b110;
    else              cred_encode_ge = 3'b111;
  endfunction

  // 2-bit variant for the WRESPCRED field (Table 16): only the first four
  // Table-17 encodings are legal for WriteResp (up to 8 credits).
  function automatic logic [1:0] cred_encode_ge2(input logic [7:0] n);
    if      (n == 0) cred_encode_ge2 = 2'b00;
    else if (n <= 1) cred_encode_ge2 = 2'b01;
    else if (n <= 4) cred_encode_ge2 = 2'b10;
    else             cred_encode_ge2 = 2'b11;
  endfunction

  // Assemble a MsgCredit word (Table 16): RP in [15:14], then the five
  // per-type bucket codes.  Inputs are already Table-17 bucket codes.
  function automatic logic [CREDIT_W-1:0] mk_msgcredit(
      input logic [RP_W-1:0]        rp,
      input logic [WREQCRED_W-1:0]  wreq,
      input logic [RREQCRED_W-1:0]  rreq,
      input logic [WDATACRED_W-1:0] wdata,
      input logic [RDATACRED_W-1:0] rdata,
      input logic [WRESPCRED_W-1:0] wresp);
    mk_msgcredit = {rp, wresp, rdata, wdata, rreq, wreq};
  endfunction

  // MsgCredit sub-field extractors (Table 16).
  function automatic logic [2:0]      mc_wreq (input logic [CREDIT_W-1:0] c); mc_wreq  = c[2:0];   endfunction
  function automatic logic [2:0]      mc_rreq (input logic [CREDIT_W-1:0] c); mc_rreq  = c[5:3];   endfunction
  function automatic logic [2:0]      mc_wdata(input logic [CREDIT_W-1:0] c); mc_wdata = c[8:6];   endfunction
  function automatic logic [2:0]      mc_rdata(input logic [CREDIT_W-1:0] c); mc_rdata = c[11:9];  endfunction
  function automatic logic [1:0]      mc_wresp(input logic [CREDIT_W-1:0] c); mc_wresp = c[13:12]; endfunction
  function automatic logic [RP_W-1:0] mc_rp   (input logic [CREDIT_W-1:0] c); mc_rp    = c[15:14]; endfunction

  // =========================================================================
  // Miscellaneous messages (§5.6) — MSGTYPE = MT_MISC ('b0000), then a 3-bit
  // MISCOP (Table 15).  Used for §6.4.2 credit grants (CrdtGrant) and §8
  // interface state management (Activation).  Built MSB-first, left-justified
  // in an MSG_MAX_BITS container like the §5.8 data messages.
  // =========================================================================
  localparam int MISCOP_W       = 3;
  localparam int ACTIVATIONOP_W = 4;

  // MISCOP encoding (Table 15).
  localparam logic [MISCOP_W-1:0] MISCOP_ACTIVATION = 3'b010;
  localparam logic [MISCOP_W-1:0] MISCOP_CRDTGRANT  = 3'b100;

  // ActivationOp encoding (Table 27).
  localparam logic [ACTIVATIONOP_W-1:0] ACTOP_ACTIVATE_REQ   = 4'b0000;
  localparam logic [ACTIVATIONOP_W-1:0] ACTOP_ACTIVATE_ACK   = 4'b0001;
  localparam logic [ACTIVATIONOP_W-1:0] ACTOP_DEACTIVATE_REQ = 4'b0010;
  localparam logic [ACTIVATIONOP_W-1:0] ACTOP_DEACTIVATE_ACK = 4'b0011;

  // Misc message granule counts (Tables 14, 25, 26, 18).
  localparam int MISC_GRAN        = 1;   // generic Misc / ActivationOthers (40b)
  localparam int ACTIVATEREQ_GRAN = 4;   // ActivateReq (160b, carries profiles)
  localparam int CRDTGRANT_GRAN   = 2;   // CrdtGrant   (80b)

  // --- builders -------------------------------------------------------------
  // ActivationOthers (Table 26): ActivateAck / DeactivateReq / DeactivateAck.
  //   MSGTYPE(4), MISCOP(3)=Activation, ACTIVATIONOP(4), RsvdZero(29) => 40b.
  function automatic msg_t mk_activation_other(input logic [ACTIVATIONOP_W-1:0] op);
    logic [39:0] v;
    begin
      v = {MT_MISC, MISCOP_ACTIVATION, op, 29'b0};
      mk_activation_other = {v, {(MSG_MAX_BITS-40){1'b0}}};
    end
  endfunction

  // ActivateReq (Table 25): as ActivationOthers but ACTIVATIONOP=ActivateReq
  //   plus RsvdZero(3) and RP0..RP3 Profile{ID(5),Rev(5),Opt(16)} => 160b.  The
  //   Basic Profile leaves the profile fields at 0 (Chapter 11 defines them).
  function automatic msg_t mk_activate_req(
      input logic [4:0]  rp0_id,  input logic [4:0]  rp0_rev, input logic [15:0] rp0_opt);
    logic [159:0] v;
    begin
      v = {MT_MISC, MISCOP_ACTIVATION, ACTOP_ACTIVATE_REQ, 3'b0,
           rp0_id, rp0_rev, rp0_opt, 14'b0,   // RP0
           5'b0,   5'b0,    16'b0,   14'b0,   // RP1 (not present)
           5'b0,   5'b0,    16'b0,   14'b0,   // RP2 (not present)
           5'b0,   5'b0,    16'b0};           // RP3 (not present)
      mk_activate_req = {v, {(MSG_MAX_BITS-160){1'b0}}};
    end
  endfunction

  // CrdtGrant (Table 18): bulk credit advertisement.  Only RP0 is populated in
  // this single-plane build; RP1..RP3 fields are 0.  Inputs are Table-17 codes.
  function automatic msg_t mk_crdtgrant(
      input logic [2:0] wreq0,  input logic [2:0] rreq0,
      input logic [2:0] wdata0, input logic [2:0] rdata0,
      input logic [1:0] wresp0);
    logic [79:0] v;
    begin
      v = {MT_MISC, MISCOP_CRDTGRANT,
           wreq0,  3'b0, 3'b0, 3'b0,          // WREQCRED0..3
           rreq0,  3'b0, 3'b0, 3'b0,          // RREQCRED0..3
           wdata0, 3'b0, 3'b0, 3'b0,          // WDATACRED0..3
           rdata0, 3'b0, 3'b0, 3'b0,          // RDATACRED0..3
           wresp0, 2'b0, 2'b0, 2'b0,          // WRESPCRED0..3
           17'b0};
      mk_crdtgrant = {v, {(MSG_MAX_BITS-80){1'b0}}};
    end
  endfunction

  // --- getters (MSGTYPE is get_msgtype(); these read the Misc sub-fields) ---
  function automatic logic [MISCOP_W-1:0] misc_op(input msg_t m);
    misc_op = m[MSG_MAX_BITS-1-MSGTYPE_W -: MISCOP_W];            // after MSGTYPE(4)
  endfunction
  function automatic logic [ACTIVATIONOP_W-1:0] misc_activationop(input msg_t m);
    misc_activationop = m[MSG_MAX_BITS-1-7 -: ACTIVATIONOP_W];    // after 4+3
  endfunction

  // CrdtGrant RP0 credit-code getters (offsets after MSGTYPE(4)+MISCOP(3)=7).
  function automatic logic [2:0] cg_wreq0 (input msg_t m); cg_wreq0  = m[MSG_MAX_BITS-1-7  -: 3]; endfunction
  function automatic logic [2:0] cg_rreq0 (input msg_t m); cg_rreq0  = m[MSG_MAX_BITS-1-19 -: 3]; endfunction
  function automatic logic [2:0] cg_wdata0(input msg_t m); cg_wdata0 = m[MSG_MAX_BITS-1-31 -: 3]; endfunction
  function automatic logic [2:0] cg_rdata0(input msg_t m); cg_rdata0 = m[MSG_MAX_BITS-1-43 -: 3]; endfunction
  function automatic logic [1:0] cg_wresp0(input msg_t m); cg_wresp0 = m[MSG_MAX_BITS-1-55 -: 2]; endfunction

endpackage : aou_pkg
// verilator lint_on UNUSEDSIGNAL
// verilator lint_on UNUSEDPARAM

`endif
