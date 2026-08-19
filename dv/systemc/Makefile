# SystemC testbench for axi_ucie_mem_top (Verilator --sc model + sc_main.cpp).
#
# Verilator generates a SystemC model of the DUT; sc_main.cpp drives it and
# self-checks.  Needs SystemC (libsystemc-dev): headers + libsystemc.so.

VERILATOR ?= verilator
# Verilator C++ build parallelism (0 = one job per core; lower on low-RAM
# builders to keep parallel cc1plus from OOMing — see the Dockerfile).
VL_JOBS ?= 0

RTL_DIR := ../../rtl
RTL := \
    $(RTL_DIR)/aou_pkg.sv \
    $(RTL_DIR)/ucie_stream_link.sv \
    $(RTL_DIR)/aou_activation.sv \
    $(RTL_DIR)/axi_lite_mem.sv \
    $(RTL_DIR)/aou_axi_initiator_bridge.sv \
    $(RTL_DIR)/aou_axi_target_bridge.sv \
    $(RTL_DIR)/axi_ucie_mem_top.sv
TOP := axi_ucie_mem_top

# SystemC install (Debian/Ubuntu libsystemc-dev layout; override if elsewhere).
SYSTEMC_INCLUDE ?= /usr/include
SYSTEMC_LIBDIR  ?= $(firstword $(wildcard /usr/lib/x86_64-linux-gnu /usr/lib) )
export SYSTEMC_INCLUDE SYSTEMC_LIBDIR

PASS_RE := \[SC-TB\] PASS
EXE     := obj_dir/V$(TOP)

.PHONY: run clean
run:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[SC] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[SC] Verilator < 5 — skipping"; exit 0; fi; \
	if [ ! -e "$(SYSTEMC_LIBDIR)/libsystemc.so" ] && \
	   [ ! -e "$(SYSTEMC_LIBDIR)/libsystemc.a" ]; then \
		echo "[SC] SystemC not found in $(SYSTEMC_LIBDIR) — install libsystemc-dev; skipping"; exit 0; fi; \
	$(VERILATOR) --sc --build -j $(VL_JOBS) -Wall -Wno-DECLFILENAME \
		--top-module $(TOP) --exe sc_main.cpp $(RTL) \
		-LDFLAGS "-L$(SYSTEMC_LIBDIR) -lsystemc -Wl,-rpath,$(SYSTEMC_LIBDIR)"; \
	LD_LIBRARY_PATH=$(SYSTEMC_LIBDIR):$$LD_LIBRARY_PATH ./$(EXE) 2>&1 | tee sc.log; \
	grep -q "$(PASS_RE)" sc.log || { echo "[SC] run FAILED"; exit 1; }; \
	echo "[SC] SystemC PASSED"

clean:
	rm -rf obj_dir sc.log
