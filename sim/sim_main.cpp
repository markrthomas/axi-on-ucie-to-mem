// Verilator coverage harness for axi_ucie_mem_top.
//
// Single clock (ACLK). This driver does not self-check (the cocotb/pyuvm and SV
// testbenches own correctness); its only job is to walk the full AXI-over-UCIe
// path — initiator bridge, flit links, target bridge, and the AXI-Lite memory —
// through single-beat and burst traffic so `make coverage` emits meaningful line
// coverage:
//   * a write attempted while ARESETn=0 (must NOT commit)
//   * committed single-beat writes/reads to edge and interior addresses
//   * INCR / WRAP / FIXED bursts of assorted lengths (the multi-beat FSM legs
//     and axi_burst_next's three address rules)
//   * reads of written and un-written locations
//   * idle cycles
//
// Run from the Verilator --Mdir (cwd holds coverage.dat); the root Makefile then
// feeds coverage.dat to verilator_coverage --write-info.

#include "Vaxi_ucie_mem_top.h"
#include "verilated.h"
#include "verilated_cov.h"

#include <cstdint>
#include <cstdio>

static Vaxi_ucie_mem_top* dut = nullptr;

// AXI burst-type encodings (AoU carries these in FLEX[1:0]; the boundary AXI
// interface uses the standard AxBURST values).
static const uint32_t BURST_FIXED = 0;
static const uint32_t BURST_INCR  = 1;
static const uint32_t BURST_WRAP  = 2;
static const uint32_t SZ4         = 2;   // 4-byte beat (32-bit)

// One ACLK cycle: settle inputs/comb with the clock low, then a rising edge.
static void tick() {
    dut->ACLK = 0;
    dut->eval();
    dut->ACLK = 1;
    dut->eval();
}

static void idle_cycles(int n) {
    dut->AWVALID = 0;
    dut->WVALID = 0;
    dut->ARVALID = 0;
    for (int i = 0; i < n; ++i) tick();
}

// AXI4 write burst: present AW, wait AWREADY (accepted in the bridge's IDLE),
// then stream len+1 W beats (WLAST on the final one), then accept B.
static void axi_wburst(uint32_t id, uint32_t addr, uint32_t len, uint32_t burst,
                       uint32_t d0, uint32_t dstep) {
    dut->AWID = id; dut->AWADDR = addr; dut->AWLEN = len; dut->AWSIZE = SZ4;
    dut->AWBURST = burst; dut->AWPROT = 0; dut->AWVALID = 1;
    dut->BREADY = 1;
    int guard = 0;
    do { tick(); } while (!dut->AWREADY && ++guard < 400);
    dut->AWVALID = 0;
    for (uint32_t k = 0; k <= len; ++k) {
        dut->WDATA = d0 + k * dstep; dut->WSTRB = 0xF;
        dut->WLAST = (k == len); dut->WVALID = 1;
        guard = 0;
        do { tick(); } while (!dut->WREADY && ++guard < 400);
        dut->WVALID = 0; dut->WLAST = 0;
    }
    guard = 0;
    do { tick(); } while (!dut->BVALID && ++guard < 400);
    tick();                 // accept B (BREADY high)
    dut->BREADY = 0;
}

// AXI4 read burst: present AR, wait ARREADY, then consume len+1 R beats.
static void axi_rburst(uint32_t id, uint32_t addr, uint32_t len, uint32_t burst) {
    dut->ARID = id; dut->ARADDR = addr; dut->ARLEN = len; dut->ARSIZE = SZ4;
    dut->ARBURST = burst; dut->ARPROT = 0; dut->ARVALID = 1;
    dut->RREADY = 1;
    int guard = 0;
    do { tick(); } while (!dut->ARREADY && ++guard < 400);
    dut->ARVALID = 0;
    for (uint32_t k = 0; k <= len; ++k) {
        guard = 0;
        do { tick(); } while (!dut->RVALID && ++guard < 400);
        (void)dut->RDATA;
        tick();             // accept R beat (RREADY high)
    }
    dut->RREADY = 0;
}

// single-beat convenience wrappers (AWLEN=0, INCR)
static void axi_write(uint32_t addr, uint32_t data) {
    axi_wburst(0, addr, 0, BURST_INCR, data, 0);
}
static void axi_read(uint32_t addr) {
    axi_rburst(0, addr, 0, BURST_INCR);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxi_ucie_mem_top;

    const uint32_t LAST = 0xFFFC;   // top word of the 64 KiB space

    // --- reset: hold ARESETn low and attempt a write (must NOT commit) --------
    dut->ARESETn = 0;
    idle_cycles(1);
    dut->AWADDR = 0x1234; dut->AWPROT = 0; dut->AWVALID = 1;
    dut->WDATA = 0xEEEEEEEE; dut->WSTRB = 0xF; dut->WVALID = 1;
    dut->BREADY = 1;
    tick(); tick();
    idle_cycles(1);
    dut->ARESETn = 1;
    tick();

    // --- single-beat edge + interior addresses, patterned payloads ------------
    const uint32_t addrs[] = {0x0000, 0x0004, 0x0008, 0x8000, LAST - 4, LAST};
    const uint32_t data[]  = {0x00000000, 0xFFFFFFFF, 0x55555555,
                              0xAAAAAAAA, 0xDEADBEEF, 0x0000CAFE};
    const int N = sizeof(addrs) / sizeof(addrs[0]);

    for (int i = 0; i < N; ++i) axi_write(addrs[i], data[i]);
    for (int i = 0; i < N; ++i) axi_read(addrs[i]);

    // read of an un-written location -> zero-initialised array path
    axi_read(0x1230);

    // --- bursts: exercise the multi-beat FSM legs and all three addr rules ----
    const uint32_t blens[] = {1, 3, 7, 15};
    // INCR
    for (int i = 0; i < 4; ++i) {
        uint32_t a = 0x2000 + (i << 6);
        axi_wburst(i + 1, a, blens[i], BURST_INCR, 0xA0000000u + i * 16, 0x11);
        axi_rburst(i + 1, a, blens[i], BURST_INCR);
    }
    // WRAP (non-aligned starts inside the wrap window)
    for (int i = 0; i < 4; ++i) {
        uint32_t a = (0x100 + (i * 4)) & ~0x3u;
        axi_wburst(i + 2, a, blens[i], BURST_WRAP, 0xB0000000u + i * 16, 0x07);
        axi_rburst(i + 2, a, blens[i], BURST_WRAP);
    }
    // FIXED (all beats hit the same address; last write wins)
    axi_wburst(9, 0x40, 3, BURST_FIXED, 0xF0000000u, 0x01);
    axi_rburst(9, 0x40, 3, BURST_FIXED);

    // a stretch of idle cycles
    idle_cycles(8);

    dut->final();
    VerilatedCov::write("coverage.dat");
    printf("[sim_cov] done\n");
    delete dut;
    return 0;
}
