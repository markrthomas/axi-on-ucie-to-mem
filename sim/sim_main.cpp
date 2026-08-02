// Verilator coverage harness for axi_ucie_mem_top.
//
// Single clock (ACLK). This driver does not self-check (the cocotb/pyuvm and SV
// testbenches own correctness); its only job is to walk the full AXI-over-UCIe
// path — initiator bridge, flit links, target bridge, and the AXI-Lite memory —
// through writes and reads so `make coverage` emits meaningful line coverage:
//   * a write attempted while ARESETn=0 (must NOT commit)
//   * committed writes to edge and interior addresses, patterned payloads
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

// AXI4-Lite write: drive AW+W together, wait both readies, then the B response.
static void axi_write(uint32_t addr, uint32_t data) {
    dut->AWADDR = addr; dut->AWPROT = 0; dut->AWVALID = 1;
    dut->WDATA = data;  dut->WSTRB = 0xF; dut->WVALID = 1;
    dut->BREADY = 1;
    int guard = 0;
    do { tick(); } while (!(dut->AWREADY && dut->WREADY) && ++guard < 200);
    dut->AWVALID = 0; dut->WVALID = 0;
    guard = 0;
    do { tick(); } while (!dut->BVALID && ++guard < 200);
    tick();                 // accept B (BREADY high)
    dut->BREADY = 0;
}

// AXI4-Lite read; returns RDATA sampled when RVALID is high.
static uint32_t axi_read(uint32_t addr) {
    dut->ARADDR = addr; dut->ARPROT = 0; dut->ARVALID = 1;
    dut->RREADY = 1;
    int guard = 0;
    do { tick(); } while (!dut->ARREADY && ++guard < 200);
    dut->ARVALID = 0;
    guard = 0;
    do { tick(); } while (!dut->RVALID && ++guard < 200);
    uint32_t d = dut->RDATA;
    tick();                 // accept R (RREADY high)
    dut->RREADY = 0;
    return d;
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

    // --- edge + interior addresses, all-0 / all-1 / patterned payloads --------
    const uint32_t addrs[] = {0x0000, 0x0004, 0x0008, 0x8000, LAST - 4, LAST};
    const uint32_t data[]  = {0x00000000, 0xFFFFFFFF, 0x55555555,
                              0xAAAAAAAA, 0xDEADBEEF, 0x0000CAFE};
    const int N = sizeof(addrs) / sizeof(addrs[0]);

    for (int i = 0; i < N; ++i) axi_write(addrs[i], data[i]);
    for (int i = 0; i < N; ++i) (void)axi_read(addrs[i]);

    // read of an un-written location -> zero-initialised array path
    (void)axi_read(0x1230);

    // a stretch of idle cycles
    idle_cycles(8);

    dut->final();
    VerilatedCov::write("coverage.dat");
    printf("[sim_cov] done\n");
    delete dut;
    return 0;
}
