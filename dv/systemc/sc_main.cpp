// -----------------------------------------------------------------------------
// sc_main.cpp : SystemC testbench for axi_ucie_mem_top.
//
// Verilator (--sc) generates a SystemC model of the DUT; this hand-written
// SystemC testbench drives the AXI4-Lite front door, keeps a reference word
// memory, and self-checks every read.  Mirrors the cocotb and SV directed
// testbenches so all environments cross-check the same design.  Exits non-zero
// (and prints "[SC-TB] FAIL") on any mismatch; the Makefile also greps for the
// PASS banner.
// -----------------------------------------------------------------------------
#include "Vaxi_ucie_mem_top.h"
#include <systemc.h>

#include <cstdint>
#include <cstdlib>
#include <map>

static const int      MEM_ADDR_W = 16;
static const uint32_t WORDS      = 1u << (MEM_ADDR_W - 2);

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
    AWVALID.write(false);
    uint32_t a = addr;
    for (uint32_t k = 0; k <= len; k++) {
      uint32_t dv = d0 + k * dstep;
      WDATA.write(dv); WSTRB.write(0xF); WLAST.write(k == len); WVALID.write(true);
      do { wait(); } while (!WREADY.read());
      ref[a] = dv;
      a = next_addr(a, addr, burst, SZ4, len);
      WVALID.write(false); WLAST.write(false);
    }
    do { wait(); } while (!BVALID.read());
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
    ARVALID.write(false);
    uint32_t a = addr;
    for (uint32_t k = 0; k <= len; k++) {
      do { wait(); } while (!RVALID.read());
      uint32_t exp = ref.count(a) ? ref[a] : 0;
      check(a, RDATA.read(), exp);
      if (RRESP.read() != 0)        { errors++; std::cout << "[SC-TB] bad RRESP\n"; }
      if (RID.read() != id)         { errors++; std::cout << "[SC-TB] RID mismatch\n"; }
      if (RLAST.read() != (k == len)) { errors++; std::cout << "[SC-TB] RLAST mismatch\n"; }
      a = next_addr(a, addr, burst, SZ4, len);
      wait();
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

    if (errors == 0)
      std::cout << "[SC-TB] PASS: " << reads << " reads checked, 0 errors\n";
    else
      std::cout << "[SC-TB] FAIL: " << reads << " reads checked, "
                << errors << " errors\n";
    sc_stop();
  }
};

int sc_main(int, char**) {
  sc_clock clk("clk", 10, SC_NS);
  sc_signal<bool>     ARESETn, AWVALID, AWREADY, WLAST, WVALID, WREADY,
                      BVALID, BREADY, ARVALID, ARREADY, RLAST, RVALID, RREADY;
  sc_signal<uint32_t> AWID, AWADDR, AWLEN, AWSIZE, AWBURST, AWPROT,
                      WDATA, WSTRB, BID, BRESP,
                      ARID, ARADDR, ARLEN, ARSIZE, ARBURST, ARPROT,
                      RID, RDATA, RRESP;

  Vaxi_ucie_mem_top dut("dut");
  dut.ACLK(clk);       dut.ARESETn(ARESETn);
  dut.AWID(AWID); dut.AWADDR(AWADDR); dut.AWLEN(AWLEN); dut.AWSIZE(AWSIZE);
  dut.AWBURST(AWBURST); dut.AWPROT(AWPROT); dut.AWVALID(AWVALID); dut.AWREADY(AWREADY);
  dut.WDATA(WDATA);    dut.WSTRB(WSTRB);   dut.WLAST(WLAST); dut.WVALID(WVALID); dut.WREADY(WREADY);
  dut.BID(BID);        dut.BRESP(BRESP);   dut.BVALID(BVALID); dut.BREADY(BREADY);
  dut.ARID(ARID); dut.ARADDR(ARADDR); dut.ARLEN(ARLEN); dut.ARSIZE(ARSIZE);
  dut.ARBURST(ARBURST); dut.ARPROT(ARPROT); dut.ARVALID(ARVALID); dut.ARREADY(ARREADY);
  dut.RID(RID); dut.RDATA(RDATA); dut.RRESP(RRESP); dut.RLAST(RLAST);
  dut.RVALID(RVALID);  dut.RREADY(RREADY);

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
