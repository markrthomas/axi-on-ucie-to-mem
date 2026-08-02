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
  sc_out<uint32_t> AWADDR;  sc_out<uint32_t> AWPROT;  sc_out<bool> AWVALID;
  sc_in<bool>      AWREADY;
  sc_out<uint32_t> WDATA;   sc_out<uint32_t> WSTRB;   sc_out<bool> WVALID;
  sc_in<bool>      WREADY;
  sc_in<uint32_t>  BRESP;   sc_in<bool>      BVALID;   sc_out<bool> BREADY;
  sc_out<uint32_t> ARADDR;  sc_out<uint32_t> ARPROT;  sc_out<bool> ARVALID;
  sc_in<bool>      ARREADY;
  sc_in<uint32_t>  RDATA;   sc_in<uint32_t>  RRESP;    sc_in<bool>  RVALID;
  sc_out<bool>     RREADY;

  int                        errors = 0;
  int                        reads  = 0;
  std::map<uint32_t, uint32_t> ref;

  SC_CTOR(Stim) { SC_THREAD(run); sensitive << clk.pos(); }

  void axi_write(uint32_t addr, uint32_t data) {
    AWADDR.write(addr); AWPROT.write(0); AWVALID.write(true);
    WDATA.write(data);  WSTRB.write(0xF); WVALID.write(true);
    BREADY.write(true);
    do { wait(); } while (!(AWREADY.read() && WREADY.read()));
    AWVALID.write(false); WVALID.write(false);
    do { wait(); } while (!BVALID.read());
    if (BRESP.read() != 0) { errors++; std::cout << "[SC-TB] bad BRESP\n"; }
    wait();
    BREADY.write(false);
  }

  uint32_t axi_read(uint32_t addr) {
    ARADDR.write(addr); ARPROT.write(0); ARVALID.write(true);
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
    AWADDR.write(0); AWPROT.write(0); WDATA.write(0); WSTRB.write(0);
    ARADDR.write(0); ARPROT.write(0);
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
  sc_signal<bool>     ARESETn, AWVALID, AWREADY, WVALID, WREADY,
                      BVALID, BREADY, ARVALID, ARREADY, RVALID, RREADY;
  sc_signal<uint32_t> AWADDR, AWPROT, WDATA, WSTRB, BRESP,
                      ARADDR, ARPROT, RDATA, RRESP;

  Vaxi_ucie_mem_top dut("dut");
  dut.ACLK(clk);       dut.ARESETn(ARESETn);
  dut.AWADDR(AWADDR);  dut.AWPROT(AWPROT); dut.AWVALID(AWVALID); dut.AWREADY(AWREADY);
  dut.WDATA(WDATA);    dut.WSTRB(WSTRB);   dut.WVALID(WVALID);   dut.WREADY(WREADY);
  dut.BRESP(BRESP);    dut.BVALID(BVALID); dut.BREADY(BREADY);
  dut.ARADDR(ARADDR);  dut.ARPROT(ARPROT); dut.ARVALID(ARVALID); dut.ARREADY(ARREADY);
  dut.RDATA(RDATA);    dut.RRESP(RRESP);   dut.RVALID(RVALID);   dut.RREADY(RREADY);

  Stim stim("stim");
  stim.clk(clk);       stim.ARESETn(ARESETn);
  stim.AWADDR(AWADDR); stim.AWPROT(AWPROT); stim.AWVALID(AWVALID); stim.AWREADY(AWREADY);
  stim.WDATA(WDATA);   stim.WSTRB(WSTRB);   stim.WVALID(WVALID);   stim.WREADY(WREADY);
  stim.BRESP(BRESP);   stim.BVALID(BVALID); stim.BREADY(BREADY);
  stim.ARADDR(ARADDR); stim.ARPROT(ARPROT); stim.ARVALID(ARVALID); stim.ARREADY(ARREADY);
  stim.RDATA(RDATA);   stim.RRESP(RRESP);   stim.RVALID(RVALID);   stim.RREADY(RREADY);

  sc_start();
  return stim.errors ? 1 : 0;
}
