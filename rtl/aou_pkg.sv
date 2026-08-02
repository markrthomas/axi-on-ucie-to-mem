// -----------------------------------------------------------------------------
// aou_pkg : AXI-over-UCIe (AoU) Basic-Profile message + flit definitions.
//
// Source: "AXI over UCIe Protocol Specification v0.8" (OCA / Tenstorrent),
//   Chapter 4 (Packing) and Chapter 5 (Message Structures).
//
// Scope of THIS package (see docs/PLAN.md):
//   * Basic Profile messages: WriteReq, ReadReq, WriteData(256b),
//     ReadData(256b), WriteResp.  (WriteDataFull / 512b / 1024b not built.)
//   * Resource Plane RP0 only; no credit flow control; no activation FSM.
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
//   Field *widths* and *granule counts* match the spec exactly; the exact §5.8
//   PCIe byte placement within a granule is modeled at field granularity (it is
//   not needed for interoperability inside this self-contained design).
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
  // Flit assembly / disassembly (spec §4.2-4.3).
  //   Header layout (MSB-first): FDId(2) | MsgStart(48) | MsgCredit(16) |
  //   Rsvd(14), followed by the 1920b payload.  Credit is always 0 in this
  //   build (no flow control yet).
  // =========================================================================
  function automatic flit_t flit_assemble(input logic [FDID_W-1:0] fdid,
                                           input msgstart_t         msgstart,
                                           input payload_t          payload);
    flit_assemble = {fdid, msgstart, {CREDIT_W{1'b0}}, {HDR_RSVD_W{1'b0}},
                     payload};
  endfunction

  function automatic msgstart_t flit_msgstart(input flit_t f);
    flit_msgstart = f[PLP_BITS-1-FDID_W -: NUM_GRAN];
  endfunction

  function automatic payload_t flit_payload(input flit_t f);
    flit_payload = f[PLP_PAYLOAD_BITS-1:0];
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

endpackage : aou_pkg
// verilator lint_on UNUSEDSIGNAL
// verilator lint_on UNUSEDPARAM

`endif
