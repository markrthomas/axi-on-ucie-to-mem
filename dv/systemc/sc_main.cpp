// -----------------------------------------------------------------------------
// sc_main.cpp : SystemC testbench for axi_ucie_mem_top.
//
// Verilator (--sc) generates a SystemC model of the DUT; this hand-written
// SystemC testbench drives the AXI4-Lite front door, keeps a reference word
// memory, and self-checks every read.  Mirrors the cocotb and SV directed
// testbenches so all environments cross-check the same design.  Exits non-zero
// (and prints "[SC-TB] FAIL") on any mismatch; the Makefile also greps for the
// PASS banner.
//
// Debug logging (VERBOSE=0|1|2, see README "Debug logging").  Unlike the SV /
// cocotb environments, the SystemC verbose lines go to the per-test log file
// ONLY, never to stdout: dv/systemc/sc.log is a COMMITTED baseline, so keeping
// stdout free of trace lines leaves it byte-identical at every level.
//   * level 1 — decoded AoU flit lines + the per-beat AXI transaction trace,
//   * level 2 — plus internal DUT state (bridge/activation FSMs, §6 credits,
//     initiator request-queue occupancy).
// Levels 1 and 2 need to see inside the DUT, which a Verilator --sc model does
// not expose, so that build verilates the DV-only observation wrapper
// dv/systemc/aou_sc_dbg_top.sv instead (AOU_SC_DBG).  The default VERBOSE=0
// build is unchanged: plain axi_ucie_mem_top, no wrapper, no log file.
// -----------------------------------------------------------------------------
#ifdef AOU_SC_DBG
#include "Vaou_sc_dbg_top.h"
typedef Vaou_sc_dbg_top Vdut;
#else
#include "Vaxi_ucie_mem_top.h"
typedef Vaxi_ucie_mem_top Vdut;
#endif
#include <systemc.h>

#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>

#ifdef AOU_SC_DBG
#include "aou_flit_log.h"
#endif

static const int      MEM_ADDR_W = 16;
static const uint32_t WORDS      = 1u << (MEM_ADDR_W - 2);

// --- verbosity level + per-test log file -------------------------------------
namespace dbg {

inline int level() {
  const char* v = std::getenv("AOU_VERBOSE");
  if (v == nullptr || *v == 0) return 0;
  char* end = nullptr;
  long l = std::strtol(v, &end, 10);
  if (end == v) return 1;                 // set but non-numeric == "verbose"
  return (l < 0) ? 0 : (int)l;
}

inline std::string path() {
  const char* f = std::getenv("AOU_LOG_FILE");
  if (f != nullptr && *f != 0) return f;
  const char* d = std::getenv("AOU_LOG_DIR");
  return std::string(d != nullptr && *d != 0 ? d : "../../logs") + "/systemc.log";
}

// The log file, opened on first use (only ever reached at level >= 1), and a
// discarding sink used when it could not be opened.
inline std::ostream& out() {
  static std::ofstream fs;
  static std::ostream null_sink(nullptr);
  static bool tried = false;
  if (!tried) {
    tried = true;
    fs.open(path().c_str(), std::ios::out | std::ios::trunc);
    if (fs.is_open())
      fs << "[SC-TB][V] verbose level " << level() << ", log file '"
         << path() << "'\n";
  }
  return fs.is_open() ? static_cast<std::ostream&>(fs) : null_sink;
}

inline long t_ns() {
  return (long)(sc_time_stamp() / sc_time(1, SC_NS));
}

}  // namespace dbg

SC_MODULE(Stim) {
  sc_in<bool>      clk;
  sc_out<bool>     ARESETn;
  sc_out<uint32_t> AWID; sc_out<uint32_t> AWADDR; sc_out<uint32_t> AWLEN;
  sc_out<uint32_t> AWSIZE; sc_out<uint32_t> AWBURST; sc_out<uint32_t> AWPROT;
  sc_out<bool>     AWVALID; sc_in<bool> AWREADY;
  sc_out<uint32_t> WDATA;   sc_out<uint32_t> WSTRB;   sc_out<bool> WLAST;
  sc_out<bool>     WVALID;   sc_in<bool>      WREADY;
  sc_in<uint32_t>  BID;     sc_in<uint32_t>  BRESP;   sc_in<bool> BVALID;
  sc_out<bool>     BREADY;
  sc_out<uint32_t> ARID; sc_out<uint32_t> ARADDR; sc_out<uint32_t> ARLEN;
  sc_out<uint32_t> ARSIZE; sc_out<uint32_t> ARBURST; sc_out<uint32_t> ARPROT;
  sc_out<bool>     ARVALID; sc_in<bool> ARREADY;
  sc_in<uint32_t>  RID;     sc_in<uint32_t>  RDATA;   sc_in<uint32_t> RRESP;
  sc_in<bool>      RLAST;   sc_in<bool>      RVALID;   sc_out<bool> RREADY;

  int                        errors = 0;
  int                        reads  = 0;
  std::map<uint32_t, uint32_t> ref;

  // Opt-in per-beat transaction tracing; enabled at VERBOSE>=1 (the repo-root
  // `make ... VERBOSE=1|2` exports AOU_VERBOSE).  Trace lines carry the
  // [SC-TB][T] tag and go to the per-test log file, so sc.log stays
  // byte-identical at every level.
  bool verbose = (dbg::level() >= 1);

  SC_CTOR(Stim) { SC_THREAD(run); sensitive << clk.pos(); }

  void axi_write(uint32_t addr, uint32_t data) {
    AWID.write(0); AWADDR.write(addr); AWLEN.write(0); AWSIZE.write(2);
    AWBURST.write(1); AWPROT.write(0); AWVALID.write(true);
    WDATA.write(data);  WSTRB.write(0xF); WLAST.write(true); WVALID.write(true);
    BREADY.write(true);
    // AW and W are accepted independently (the bridge takes AW in IDLE, then the
    // W beat once it reaches its data state), so track each ready separately.
    bool aw = false, w = false;
    while (!(aw && w)) {
      wait();
      if (!aw && AWREADY.read()) { aw = true; AWVALID.write(false); }
      if (!w  && WREADY.read())  { w  = true; WVALID.write(false); WLAST.write(false); }
    }
    do { wait(); } while (!BVALID.read());
    if (verbose)
      dbg::out() << "[SC-TB][T] W   addr=0x" << std::hex << addr << " data=0x"
                << data << " resp=" << std::dec << BRESP.read() << "\n";
    if (BRESP.read() != 0) { errors++; std::cout << "[SC-TB] bad BRESP\n"; }
    wait();
    BREADY.write(false);
  }

  uint32_t axi_read(uint32_t addr) {
    ARID.write(0); ARADDR.write(addr); ARLEN.write(0); ARSIZE.write(2);
    ARBURST.write(1); ARPROT.write(0); ARVALID.write(true);
    RREADY.write(true);
    do { wait(); } while (!ARREADY.read());
    ARVALID.write(false);
    do { wait(); } while (!RVALID.read());
    uint32_t d = RDATA.read();
    if (verbose)
      dbg::out() << "[SC-TB][T] R   addr=0x" << std::hex << addr << " data=0x"
                << d << " resp=" << std::dec << RRESP.read() << "\n";
    if (RRESP.read() != 0) { errors++; std::cout << "[SC-TB] bad RRESP\n"; }
    wait();
    RREADY.write(false);
    return d;
  }

  // AxBURST encodings + 4-byte beat size (matches the SV / cocotb TBs).
  enum : uint32_t { BURST_FIXED = 0, BURST_INCR = 1, BURST_WRAP = 2, SZ4 = 2 };

  // Independent copy of the AXI next-beat address rule (not the DUT's).
  static uint32_t next_addr(uint32_t a, uint32_t base, uint32_t burst,
                            uint32_t sz, uint32_t len) {
    uint32_t nb = 1u << sz;
    if (burst == BURST_FIXED) return a;
    if (burst == BURST_WRAP) {
      uint32_t tot = (len + 1) << sz;
      uint32_t low = base & ~(tot - 1);
      return ((a + nb) == (low + tot)) ? low : (a + nb);
    }
    return a + nb;   // INCR
  }

  // AXI4 write burst: present AW, stream len+1 W beats (WLAST on the last),
  // update the reference memory, then check the B response (BRESP, BID).
  void axi_wburst(uint32_t id, uint32_t addr, uint32_t len, uint32_t burst,
                  uint32_t d0, uint32_t dstep) {
    AWID.write(id); AWADDR.write(addr); AWLEN.write(len); AWSIZE.write(SZ4);
    AWBURST.write(burst); AWPROT.write(0); AWVALID.write(true); BREADY.write(true);
    do { wait(); } while (!AWREADY.read());
    if (verbose)
      dbg::out() << "[SC-TB][T] AW  id=" << id << " addr=0x" << std::hex << addr
                << std::dec << " len=" << len << " burst=" << burst << "\n";
    AWVALID.write(false);
    uint32_t a = addr;
    for (uint32_t k = 0; k <= len; k++) {
      uint32_t dv = d0 + k * dstep;
      WDATA.write(dv); WSTRB.write(0xF); WLAST.write(k == len); WVALID.write(true);
      do { wait(); } while (!WREADY.read());
      if (verbose)
        dbg::out() << "[SC-TB][T] W   beat " << k << " addr=0x" << std::hex << a
                  << " data=0x" << dv << std::dec << " last=" << (k == len) << "\n";
      ref[a] = dv;
      a = next_addr(a, addr, burst, SZ4, len);
      WVALID.write(false); WLAST.write(false);
    }
    do { wait(); } while (!BVALID.read());
    if (verbose)
      dbg::out() << "[SC-TB][T] B   id=" << BID.read() << " resp=" << BRESP.read() << "\n";
    if (BRESP.read() != 0) { errors++; std::cout << "[SC-TB] bad BRESP\n"; }
    if (BID.read() != id)  { errors++; std::cout << "[SC-TB] BID mismatch\n"; }
    wait();
    BREADY.write(false);
  }

  // AXI4 read burst: present AR, consume len+1 R beats, self-check each beat's
  // data plus RRESP / RID / RLAST.
  void axi_rburst(uint32_t id, uint32_t addr, uint32_t len, uint32_t burst) {
    ARID.write(id); ARADDR.write(addr); ARLEN.write(len); ARSIZE.write(SZ4);
    ARBURST.write(burst); ARPROT.write(0); ARVALID.write(true); RREADY.write(true);
    do { wait(); } while (!ARREADY.read());
    if (verbose)
      dbg::out() << "[SC-TB][T] AR  id=" << id << " addr=0x" << std::hex << addr
                << std::dec << " len=" << len << " burst=" << burst << "\n";
    ARVALID.write(false);
    uint32_t a = addr;
    for (uint32_t k = 0; k <= len; k++) {
      do { wait(); } while (!RVALID.read());
      uint32_t exp = ref.count(a) ? ref[a] : 0;
      if (verbose)
        dbg::out() << "[SC-TB][T] R   beat " << k << " addr=0x" << std::hex << a
                  << " data=0x" << RDATA.read() << std::dec << " resp=" << RRESP.read()
                  << " id=" << RID.read() << " last=" << RLAST.read() << "\n";
      check(a, RDATA.read(), exp);
      if (RRESP.read() != 0)        { errors++; std::cout << "[SC-TB] bad RRESP\n"; }
      if (RID.read() != id)         { errors++; std::cout << "[SC-TB] RID mismatch\n"; }
      if (RLAST.read() != (k == len)) { errors++; std::cout << "[SC-TB] RLAST mismatch\n"; }
      a = next_addr(a, addr, burst, SZ4, len);
      wait();
    }
    RREADY.write(false);
  }

  // Multiple-outstanding reads: fire n AR handshakes with RREADY held low so
  // they pile into the initiator request queue (up to full), then drain every
  // beat in issue order (in-order completion) and self-check data/RRESP/RID/
  // RLAST.  n must be <= the initiator REQ_QD + 1 to avoid stalling.
  void axi_rburst_pipe(int n, const uint32_t* ids, const uint32_t* addrs,
                       const uint32_t* lens, const uint32_t* bursts) {
    RREADY.write(false);
    for (int i = 0; i < n; i++) {          // phase 1: queue the AR handshakes
      ARID.write(ids[i]); ARADDR.write(addrs[i]); ARLEN.write(lens[i]);
      ARSIZE.write(SZ4); ARBURST.write(bursts[i]); ARPROT.write(0);
      ARVALID.write(true);
      do { wait(); } while (!ARREADY.read());
      if (verbose)
        dbg::out() << "[SC-TB][T] AR  (mo) id=" << ids[i] << " addr=0x" << std::hex
                  << addrs[i] << std::dec << " len=" << lens[i] << "\n";
      ARVALID.write(false);
      wait();                              // gap cycle between handshakes
    }
    RREADY.write(true);                    // phase 2: drain in issue order
    for (int i = 0; i < n; i++) {
      uint32_t a = addrs[i];
      for (uint32_t k = 0; k <= lens[i]; k++) {
        do { wait(); } while (!RVALID.read());
        uint32_t exp = ref.count(a) ? ref[a] : 0;
        if (verbose)
          dbg::out() << "[SC-TB][T] R   (mo) req " << i << " beat " << k << " addr=0x"
                    << std::hex << a << " data=0x" << RDATA.read() << std::dec
                    << " id=" << RID.read() << " last=" << RLAST.read() << "\n";
        check(a, RDATA.read(), exp);
        if (RRESP.read() != 0)            { errors++; std::cout << "[SC-TB] MO bad RRESP\n"; }
        if (RID.read() != ids[i])         { errors++; std::cout << "[SC-TB] MO RID mismatch\n"; }
        if (RLAST.read() != (k == lens[i])) { errors++; std::cout << "[SC-TB] MO RLAST mismatch\n"; }
        a = next_addr(a, addrs[i], bursts[i], SZ4, lens[i]);
        wait();
      }
    }
    RREADY.write(false);
  }

  void check(uint32_t addr, uint32_t got, uint32_t exp) {
    reads++;
    if (got != exp) {
      errors++;
      std::cout << "[SC-TB] MISMATCH @0x" << std::hex << addr
                << ": got 0x" << got << " exp 0x" << exp << std::dec << "\n";
    }
  }

  void run() {
    if (verbose)
      dbg::out() << "[SC-TB][T] verbose transaction tracing enabled\n";
    // idle + reset
    ARESETn.write(false);
    AWVALID.write(false); WVALID.write(false); ARVALID.write(false);
    BREADY.write(false);  RREADY.write(false);
    AWID.write(0); AWADDR.write(0); AWLEN.write(0); AWSIZE.write(2);
    AWBURST.write(1); AWPROT.write(0); WDATA.write(0); WSTRB.write(0); WLAST.write(false);
    ARID.write(0); ARADDR.write(0); ARLEN.write(0); ARSIZE.write(2);
    ARBURST.write(1); ARPROT.write(0);
    for (int i = 0; i < 3; i++) wait();
    ARESETn.write(true);
    wait();

    std::srand(1);

    // 1) directed write-read pairs
    for (int i = 0; i < 40; i++) {
      uint32_t a = (std::rand() % WORDS) << 2;
      uint32_t d = (uint32_t)std::rand() ^ ((uint32_t)std::rand() << 16);
      axi_write(a, d); ref[a] = d;
      uint32_t r = axi_read(a); check(a, r, ref[a]);
    }

    // 2) walking edge cases
    const uint32_t edge_a[] = {0x0, 0x4, (WORDS - 2) << 2, (WORDS - 1) << 2};
    const uint32_t edge_d[] = {0x00000000, 0x00000001, 0x55555555,
                               0xAAAAAAAA, 0xFFFFFFFF, 0xDEADBEEF};
    for (uint32_t a : edge_a)
      for (uint32_t d : edge_d) {
        axi_write(a, d); ref[a] = d;
        uint32_t r = axi_read(a); check(a, r, ref[a]);
      }

    // 3) un-written location reads 0
    uint32_t ua = 0x1230;
    check(ua, axi_read(ua), ref.count(ua) ? ref[ua] : 0);

    // 4) bursts: INCR / WRAP / FIXED, assorted lengths, each beat checked
    const uint32_t blens[] = {1, 3, 7, 15};
    for (int i = 0; i < 4; i++) {
      uint32_t a = 0x2000 + (i << 6);
      axi_wburst(i + 1, a, blens[i], BURST_INCR, 0xA0000000u + i * 16, 0x11);
      axi_rburst(i + 1, a, blens[i], BURST_INCR);
    }
    for (int i = 0; i < 4; i++) {
      uint32_t a = (0x100 + (i * 4)) & ~0x3u;
      axi_wburst(i + 2, a, blens[i], BURST_WRAP, 0xB0000000u + i * 16, 0x07);
      axi_rburst(i + 2, a, blens[i], BURST_WRAP);
    }
    axi_wburst(9, 0x40, 3, BURST_FIXED, 0xF0000000u, 0x01);
    axi_rburst(9, 0x40, 3, BURST_FIXED);

    // 5) multiple-outstanding reads: preload, then issue five reads (distinct
    //    IDs, mixed lengths) that fill the initiator queue; drain in order.
    {
      const uint32_t moid[]  = {1, 2, 3, 4, 5};
      const uint32_t moad[]  = {0x800, 0x840, 0x880, 0x8C0, 0x900};
      const uint32_t molen[] = {0, 3, 1, 7, 0};
      const uint32_t mob[]   = {BURST_INCR, BURST_INCR, BURST_INCR,
                                BURST_INCR, BURST_INCR};
      for (int i = 0; i < 5; i++)
        axi_wburst(moid[i], moad[i], molen[i], mob[i],
                   0xC0000000u + (i << 8), 0x13);
      axi_rburst_pipe(5, moid, moad, molen, mob);
    }

    if (errors == 0)
      std::cout << "[SC-TB] PASS: " << reads << " reads checked, 0 errors\n";
    else
      std::cout << "[SC-TB] FAIL: " << reads << " reads checked, "
                << errors << " errors\n";
    sc_stop();
  }
};

#ifdef AOU_SC_DBG
// -----------------------------------------------------------------------------
// Mon : the level-1 / level-2 observer.  Reads ONLY the dbg_* observation ports
// that dv/systemc/aou_sc_dbg_top.sv re-exports (each one a hierarchical read of
// a signal the design already drives), decodes flits with the shared
// dv/common/aou_flit_log.h renderer, and writes to the per-test log file.
// -----------------------------------------------------------------------------
SC_MODULE(Mon) {
  sc_in<bool>      clk;
  sc_in<bool>      ARESETn;
  sc_in<bool>      a2b_fire;   sc_in<sc_bv<aou::PLP_BITS> > a2b_data;
  sc_in<bool>      b2a_fire;   sc_in<sc_bv<aou::PLP_BITS> > b2a_data;
  sc_in<uint32_t>  i_act, t_act, i_fsm, t_fsm, i_qcount;
  sc_in<uint32_t>  i_cr_wreq, i_cr_rreq, i_cr_wdata, i_ret_rdata, i_ret_wresp;
  sc_in<uint32_t>  t_cr_rdata, t_cr_wresp, t_ret_wreq, t_ret_rreq, t_ret_wdata;

  int  lvl;
  bool armed = false;
  uint32_t p_iact = 0, p_tact = 0, p_ifsm = 0, p_tfsm = 0, p_q = 0;
  uint32_t p_icr[5] = {0, 0, 0, 0, 0};
  uint32_t p_tcr[5] = {0, 0, 0, 0, 0};

  SC_CTOR(Mon) : lvl(dbg::level()) { SC_THREAD(run); sensitive << clk.pos(); }

  // rtl/aou_axi_initiator_bridge.sv state_e / aou_axi_target_bridge.sv state_e /
  // aou_activation.sv act_e — the same names the SV and cocotb envs print.
  static const char* init_state(uint32_t s) {
    static const char* n[] = {"S_IDLE", "S_WREQ", "S_WDATA", "S_WWAIT", "S_B",
                              "S_RREQ", "S_RDATA"};
    return (s < 7) ? n[s] : "S_?";
  }
  static const char* tgt_state(uint32_t s) {
    static const char* n[] = {"S_IDLE", "S_WBEAT", "S_WRESP", "S_RBEAT"};
    return (s < 4) ? n[s] : "S_?";
  }
  static const char* act_state(uint32_t s) {
    static const char* n[] = {"ACT_DISABLED", "ACT_ACTIVATE", "ACT_ENABLED",
                              "ACT_DEACTIVATE", "ACT_ERROR"};
    return (s < 5) ? n[s] : "ACT_?";
  }

  static aou::Flit to_flit(const sc_bv<aou::PLP_BITS>& v) {
    aou::Flit f;
    for (int i = 0; i < aou::PLP_BYTES; i++) {
      uint8_t byte = 0;
      for (int k = 0; k < 8; k++)
        byte = (uint8_t)((byte << 1) | (v[aou::PLP_BITS - 1 - (i * 8 + k)].to_bool() ? 1 : 0));
      f.b[i] = byte;
    }
    return f;
  }

  void emit_flit(const char* dir, const sc_bv<aou::PLP_BITS>& v) {
    aou::Flit f = to_flit(v);
    std::vector<std::string> lines = aou::decode_flit(f);
    for (size_t i = 0; i < lines.size(); i++)
      dbg::out() << "[SC-TB][F] t=" << dbg::t_ns() << " " << dir << " "
                 << lines[i] << "\n";
  }

  void dbg_line(const std::string& s) {
    dbg::out() << "[SC-TB][D] t=" << dbg::t_ns() << " " << s << "\n";
  }

  void run() {
    char buf[256];
    while (true) {
      wait();
      if (lvl < 1 || !ARESETn.read()) continue;
      if (a2b_fire.read()) emit_flit("A->B", a2b_data.read());
      if (b2a_fire.read()) emit_flit("B->A", b2a_data.read());
      if (lvl < 2) continue;
      uint32_t icr[5] = {i_cr_wreq.read(), i_cr_rreq.read(), i_cr_wdata.read(),
                         i_ret_rdata.read(), i_ret_wresp.read()};
      uint32_t tcr[5] = {t_cr_rdata.read(), t_cr_wresp.read(), t_ret_wreq.read(),
                         t_ret_rreq.read(), t_ret_wdata.read()};
      if (!armed || i_act.read() != p_iact)
        dbg_line(std::string("init.act ") + act_state(i_act.read()));
      if (!armed || t_act.read() != p_tact)
        dbg_line(std::string("tgt.act  ") + act_state(t_act.read()));
      if (!armed || i_fsm.read() != p_ifsm)
        dbg_line(std::string("init.fsm ") + init_state(i_fsm.read()));
      if (!armed || t_fsm.read() != p_tfsm)
        dbg_line(std::string("tgt.fsm  ") + tgt_state(t_fsm.read()));
      if (!armed || i_qcount.read() != p_q) {
        std::snprintf(buf, sizeof(buf), "init.reqq occupancy=%u", i_qcount.read());
        dbg_line(buf);
      }
      bool icr_ch = !armed;
      bool tcr_ch = !armed;
      for (int k = 0; k < 5; k++) {
        if (icr[k] != p_icr[k]) icr_ch = true;
        if (tcr[k] != p_tcr[k]) tcr_ch = true;
      }
      if (icr_ch) {
        std::snprintf(buf, sizeof(buf),
                      "init.credits held(wreq=%u rreq=%u wdata=%u) owed(rdata=%u wresp=%u)",
                      icr[0], icr[1], icr[2], icr[3], icr[4]);
        dbg_line(buf);
      }
      if (tcr_ch) {
        std::snprintf(buf, sizeof(buf),
                      "tgt.credits  held(rdata=%u wresp=%u) owed(wreq=%u rreq=%u wdata=%u)",
                      tcr[0], tcr[1], tcr[2], tcr[3], tcr[4]);
        dbg_line(buf);
      }
      p_iact = i_act.read(); p_tact = t_act.read();
      p_ifsm = i_fsm.read(); p_tfsm = t_fsm.read(); p_q = i_qcount.read();
      for (int k = 0; k < 5; k++) { p_icr[k] = icr[k]; p_tcr[k] = tcr[k]; }
      armed = true;
    }
  }
};
#endif  // AOU_SC_DBG

int sc_main(int, char**) {
  sc_clock clk("clk", 10, SC_NS);
  sc_signal<bool>     ARESETn, AWVALID, AWREADY, WLAST, WVALID, WREADY,
                      BVALID, BREADY, ARVALID, ARREADY, RLAST, RVALID, RREADY;
  sc_signal<uint32_t> AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWPROT,
                      WDATA, WSTRB, BID, BRESP,
                      ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARPROT,
                      RID, RDATA, RRESP;

  Vdut dut("dut");
  dut.ACLK(clk);       dut.ARESETn(ARESETn);
  dut.AWID(AWID); dut.AWADDR(AWADDR); dut.AWLEN(AWLEN); dut.AWSIZE(AWSIZE);
  dut.AWBURST(AWBURST); dut.AWPROT(AWPROT); dut.AWVALID(AWVALID); dut.AWREADY(AWREADY);
  dut.WDATA(WDATA);    dut.WSTRB(WSTRB);   dut.WLAST(WLAST); dut.WVALID(WVALID); dut.WREADY(WREADY);
  dut.BID(BID);        dut.BRESP(BRESP);   dut.BVALID(BVALID); dut.BREADY(BREADY);
  dut.ARID(ARID); dut.ARADDR(ARADDR); dut.ARLEN(ARLEN); dut.ARSIZE(ARSIZE);
  dut.ARBURST(ARBURST); dut.ARPROT(ARPROT); dut.ARVALID(ARVALID); dut.ARREADY(ARREADY);
  dut.RID(RID); dut.RDATA(RDATA); dut.RRESP(RRESP); dut.RLAST(RLAST);
  dut.RVALID(RVALID);  dut.RREADY(RREADY);

#ifdef AOU_SC_DBG
  // DV-only observation ports of aou_sc_dbg_top (see that file's header).
  sc_signal<bool>                    dbg_a2b_fire, dbg_b2a_fire;
  sc_signal<sc_bv<aou::PLP_BITS> >   dbg_a2b_data, dbg_b2a_data;
  sc_signal<uint32_t> dbg_i_act, dbg_t_act, dbg_i_fsm, dbg_t_fsm, dbg_i_qcount,
                      dbg_i_cr_wreq, dbg_i_cr_rreq, dbg_i_cr_wdata,
                      dbg_i_ret_rdata, dbg_i_ret_wresp,
                      dbg_t_cr_rdata, dbg_t_cr_wresp,
                      dbg_t_ret_wreq, dbg_t_ret_rreq, dbg_t_ret_wdata;
  dut.dbg_a2b_fire(dbg_a2b_fire);   dut.dbg_a2b_data(dbg_a2b_data);
  dut.dbg_b2a_fire(dbg_b2a_fire);   dut.dbg_b2a_data(dbg_b2a_data);
  dut.dbg_i_act(dbg_i_act);         dut.dbg_t_act(dbg_t_act);
  dut.dbg_i_fsm(dbg_i_fsm);         dut.dbg_t_fsm(dbg_t_fsm);
  dut.dbg_i_qcount(dbg_i_qcount);
  dut.dbg_i_cr_wreq(dbg_i_cr_wreq); dut.dbg_i_cr_rreq(dbg_i_cr_rreq);
  dut.dbg_i_cr_wdata(dbg_i_cr_wdata);
  dut.dbg_i_ret_rdata(dbg_i_ret_rdata); dut.dbg_i_ret_wresp(dbg_i_ret_wresp);
  dut.dbg_t_cr_rdata(dbg_t_cr_rdata);   dut.dbg_t_cr_wresp(dbg_t_cr_wresp);
  dut.dbg_t_ret_wreq(dbg_t_ret_wreq);   dut.dbg_t_ret_rreq(dbg_t_ret_rreq);
  dut.dbg_t_ret_wdata(dbg_t_ret_wdata);

  Mon mon("mon");
  mon.clk(clk);                     mon.ARESETn(ARESETn);
  mon.a2b_fire(dbg_a2b_fire);       mon.a2b_data(dbg_a2b_data);
  mon.b2a_fire(dbg_b2a_fire);       mon.b2a_data(dbg_b2a_data);
  mon.i_act(dbg_i_act);             mon.t_act(dbg_t_act);
  mon.i_fsm(dbg_i_fsm);             mon.t_fsm(dbg_t_fsm);
  mon.i_qcount(dbg_i_qcount);
  mon.i_cr_wreq(dbg_i_cr_wreq);     mon.i_cr_rreq(dbg_i_cr_rreq);
  mon.i_cr_wdata(dbg_i_cr_wdata);
  mon.i_ret_rdata(dbg_i_ret_rdata); mon.i_ret_wresp(dbg_i_ret_wresp);
  mon.t_cr_rdata(dbg_t_cr_rdata);   mon.t_cr_wresp(dbg_t_cr_wresp);
  mon.t_ret_wreq(dbg_t_ret_wreq);   mon.t_ret_rreq(dbg_t_ret_rreq);
  mon.t_ret_wdata(dbg_t_ret_wdata);
#endif

  Stim stim("stim");
  stim.clk(clk);       stim.ARESETn(ARESETn);
  stim.AWID(AWID); stim.AWADDR(AWADDR); stim.AWLEN(AWLEN); stim.AWSIZE(AWSIZE);
  stim.AWBURST(AWBURST); stim.AWPROT(AWPROT); stim.AWVALID(AWVALID); stim.AWREADY(AWREADY);
  stim.WDATA(WDATA);   stim.WSTRB(WSTRB);   stim.WLAST(WLAST); stim.WVALID(WVALID); stim.WREADY(WREADY);
  stim.BID(BID);       stim.BRESP(BRESP);   stim.BVALID(BVALID); stim.BREADY(BREADY);
  stim.ARID(ARID); stim.ARADDR(ARADDR); stim.ARLEN(ARLEN); stim.ARSIZE(ARSIZE);
  stim.ARBURST(ARBURST); stim.ARPROT(ARPROT); stim.ARVALID(ARVALID); stim.ARREADY(ARREADY);
  stim.RID(RID); stim.RDATA(RDATA); stim.RRESP(RRESP); stim.RLAST(RLAST);
  stim.RVALID(RVALID); stim.RREADY(RREADY);

  sc_start();
  return stim.errors ? 1 : 0;
}
