// -----------------------------------------------------------------------------
// aou_flit_log.h — shared AoU flit -> string decoder for the SystemC DV env.
//
// The C++ mirror of dv/common/aou_flit_log.svh (SystemVerilog) and
// dv/common/aou_flit_log.py (cocotb): the same §4.3 protocol-header byte map,
// the same §5.8 message field offsets and the SAME rendered line format, so a
// flit reads identically in every environment's log.
//
// Header-only and purely observational: it decodes a flit value the design
// already produced, so it cannot affect VERBOSE=0 behaviour.
//
// Bit convention (identical to rtl/aou_pkg.sv): PLP byte 0 is PH B0, the first
// byte on the wire, and its MSB is the figure's bit label 0.  A bit at
// transmission offset g is therefore bit (7 - g%8) of byte g/8.
// -----------------------------------------------------------------------------
#ifndef AOU_FLIT_LOG_H
#define AOU_FLIT_LOG_H

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

namespace aou {

// --- §4.2 flit / PLP geometry ------------------------------------------------
static const int GRAN_BITS = 40;
static const int NUM_GRAN = 48;
static const int PLP_PAYLOAD_BITS = GRAN_BITS * NUM_GRAN;   // 1920
static const int PLP_HDR_BITS = 80;
static const int PLP_BITS = PLP_HDR_BITS + PLP_PAYLOAD_BITS;  // 2000
static const int PLP_BYTES = PLP_BITS / 8;                  // 250
static const int FDID_W = 2;
static const int CREDIT_W = 16;
static const int MSG_MAX_GRAN = 30;

// --- Table 1 MSGTYPE ---------------------------------------------------------
enum {
  MT_MISC = 0x0, MT_WRITEREQ = 0x1, MT_READREQ = 0x2, MT_WRITEDATA = 0x3,
  MT_READDATA = 0x4, MT_WRITERESP = 0x5, MT_WRITEDATAFULL = 0x6
};

// --- §5.6 Misc ---------------------------------------------------------------
static const int MISCOP_ACTIVATION = 0x2;
static const int MISCOP_CRDTGRANT = 0x4;
static const int MISC_GRAN = 1;
static const int ACTIVATEREQ_GRAN = 4;
static const int CRDTGRANT_GRAN = 2;

// Table 18 CrdtGrant per-plane slot offsets.
static const int CG_WREQ_G0 = 7, CG_RREQ_G0 = 19, CG_WDATA_G0 = 31,
                 CG_RDATA_G0 = 43, CG_WRESP_G0 = 55;

// Table 17: credit bucket code -> granted credits.
inline int cred_decode(int code) {
  static const int t[8] = {0, 1, 4, 8, 16, 32, 64, 128};
  return t[code & 7];
}

inline const char* msgtype_name(int mt) {
  switch (mt) {
    case MT_MISC:          return "Misc";
    case MT_WRITEREQ:      return "WriteReq";
    case MT_READREQ:       return "ReadReq";
    case MT_WRITEDATA:     return "WriteData";
    case MT_READDATA:      return "ReadData";
    case MT_WRITERESP:     return "WriteResp";
    case MT_WRITEDATAFULL: return "WriteDataFull";
    default:               return "Unknown";
  }
}

inline const char* burst_name(int b) {
  switch (b & 3) {
    case 0:  return "FIXED";
    case 1:  return "INCR";
    case 2:  return "WRAP";
    default: return "RSVD";
  }
}

inline const char* actop_name(int op) {
  switch (op) {
    case 0:  return "ActivateReq";
    case 1:  return "ActivateAck";
    case 2:  return "DeactivateReq";
    case 3:  return "DeactivateAck";
    default: return "Unknown";
  }
}

// Transmission-order bit index of MsgStart[i] within the §4.3 header.
inline int msgstart_g(int i) {
  if (i <= 11) return i + 4;
  if (i <= 23) return i + 8;
  if (i <= 35) return i + 28;
  return i + 32;
}

// A 250-byte PLP, addressed by transmission-order bit offset.
struct Flit {
  uint8_t b[PLP_BYTES];

  Flit() { for (int i = 0; i < PLP_BYTES; i++) b[i] = 0; }

  bool bit(int g) const { return (b[g >> 3] >> (7 - (g & 7))) & 1; }

  // Field of `w` (<= 64) bits at transmission offset `off`, MSB-first.
  uint64_t fld(int off, int w) const {
    uint64_t v = 0;
    for (int i = 0; i < w; i++) v = (v << 1) | (uint64_t)bit(off + i);
    return v;
  }

  // Wide field as lower-case hex (w must be a multiple of 4).
  std::string fldhex(int off, int w) const {
    static const char* H = "0123456789abcdef";
    std::string s;
    s.reserve(w / 4);
    for (int i = 0; i < w; i += 4) {
      int nib = 0;
      for (int k = 0; k < 4; k++) nib = (nib << 1) | (int)bit(off + i + k);
      s += H[nib];
    }
    return s;
  }

  // §4.3 header fields (packed LSB-first, scattered across PH B0..B9).
  int fdid() const {
    int v = 0;
    for (int j = 0; j < FDID_W; j++) v |= (int)bit(j) << j;
    return v;
  }
  uint32_t credit() const {
    uint32_t v = 0;
    for (int j = 0; j < CREDIT_W; j++) v |= (uint32_t)bit(32 + j) << j;
    return v;
  }
  uint64_t msgstart() const {
    uint64_t v = 0;
    for (int i = 0; i < NUM_GRAN; i++)
      v |= (uint64_t)bit(msgstart_g(i)) << i;
    return v;
  }
};

// §6 MsgCredit word (Table 16/17): raw value plus the decoded grant per type.
inline std::string credit_str(uint32_t c) {
  char buf[128];
  std::snprintf(buf, sizeof(buf),
                "0x%04x(rp=%d wreq=%d rreq=%d wdata=%d rdata=%d wresp=%d)",
                c, (int)((c >> 14) & 3), cred_decode(c & 7),
                cred_decode((c >> 3) & 7), cred_decode((c >> 6) & 7),
                cred_decode((c >> 9) & 7), cred_decode((c >> 12) & 3));
  return buf;
}

// Granule count of the message starting at transmission offset `base`.
inline int msg_gran(const Flit& f, int base) {
  int mt = (int)f.fld(base, 4);
  if (mt == MT_MISC) {
    int op = (int)f.fld(base + 4, 3);
    if (op == MISCOP_CRDTGRANT) return CRDTGRANT_GRAN;
    if (op == MISCOP_ACTIVATION && f.fld(base + 7, 4) == 0)
      return ACTIVATEREQ_GRAN;
    return MISC_GRAN;
  }
  switch (mt) {
    case MT_WRITEREQ:  case MT_READREQ:  return 3;
    case MT_WRITEDATA: case MT_READDATA: return 8;
    case MT_WRITERESP:                   return 1;
    default:                             return 1;
  }
}

// Per-type field rendering; `rp` is the flit's FDId (the resource plane).
inline std::string msg_str(const Flit& f, int base, int rp) {
  char buf[512];
  int mt = (int)f.fld(base, 4);
  switch (mt) {
    case MT_WRITEREQ:
    case MT_READREQ: {
      uint32_t flex = (uint32_t)f.fld(base + 8, 16);
      std::snprintf(buf, sizeof(buf),
                    "id=%d addr=0x%016llx len=%d size=%d burst=%s flex=0x%04x",
                    (int)f.fld(base + 24, 10),
                    (unsigned long long)f.fld(base + 56, 64),
                    (int)f.fld(base + 40, 8), (int)f.fld(base + 34, 3),
                    burst_name((int)(flex & 3)), flex);
      return buf;
    }
    case MT_WRITEDATA: {
      std::string d = f.fldhex(base + 24, 256);
      std::snprintf(buf, sizeof(buf),
                    "dlen=%d data=0x%s strb=0x%08x flex=0x%04x",
                    (int)f.fld(base + 6, 2), d.c_str(),
                    (uint32_t)f.fld(base + 280, 32),
                    (uint32_t)f.fld(base + 8, 16));
      return buf;
    }
    case MT_READDATA: {
      std::string d = f.fldhex(base + 40, 256);
      std::snprintf(buf, sizeof(buf),
                    "id=%d resp=%d last=%d dlen=%d data=0x%s flex=0x%04x",
                    (int)f.fld(base + 24, 10), (int)f.fld(base + 34, 2),
                    (int)f.fld(base + 36, 1), (int)f.fld(base + 6, 2),
                    d.c_str(), (uint32_t)f.fld(base + 8, 16));
      return buf;
    }
    case MT_WRITERESP:
      std::snprintf(buf, sizeof(buf), "id=%d resp=%d flex=0x%04x",
                    (int)f.fld(base + 24, 10), (int)f.fld(base + 34, 2),
                    (uint32_t)f.fld(base + 8, 16));
      return buf;
    case MT_MISC: {
      int op = (int)f.fld(base + 4, 3);
      if (op == MISCOP_CRDTGRANT) {
        std::snprintf(
            buf, sizeof(buf),
            "op=CrdtGrant rp%d(wreq=%d rreq=%d wdata=%d rdata=%d wresp=%d)",
            rp, cred_decode((int)f.fld(base + CG_WREQ_G0 + 3 * rp, 3)),
            cred_decode((int)f.fld(base + CG_RREQ_G0 + 3 * rp, 3)),
            cred_decode((int)f.fld(base + CG_WDATA_G0 + 3 * rp, 3)),
            cred_decode((int)f.fld(base + CG_RDATA_G0 + 3 * rp, 3)),
            cred_decode((int)f.fld(base + CG_WRESP_G0 + 2 * rp, 2)));
        return buf;
      }
      if (op == MISCOP_ACTIVATION) {
        std::snprintf(buf, sizeof(buf), "op=Activation aop=%s",
                      actop_name((int)f.fld(base + 7, 4)));
        return buf;
      }
      std::snprintf(buf, sizeof(buf), "op=0x%x", op);
      return buf;
    }
    default:
      return "";
  }
}

// Render one PLP as one string per message it STARTS (§4.3 MsgStart bitmap).
inline std::vector<std::string> decode_flit(const Flit& f) {
  std::vector<std::string> out;
  uint64_t ms = f.msgstart();
  int fdid = f.fdid();
  std::string crd = credit_str(f.credit());
  for (int g = 0; g < NUM_GRAN; g++) {
    if (!((ms >> g) & 1)) continue;
    int base = PLP_HDR_BITS + g * GRAN_BITS;
    char buf[1024];
    std::string fields = msg_str(f, base, fdid);
    std::snprintf(buf, sizeof(buf), "fdid=%d crd=%s ms=0x%012llx g=%d %s gran=%d %s",
                  fdid, crd.c_str(), (unsigned long long)ms, g,
                  msgtype_name((int)f.fld(base, 4)), msg_gran(f, base),
                  fields.c_str());
    out.push_back(buf);
  }
  return out;
}

}  // namespace aou

#endif  // AOU_FLIT_LOG_H
