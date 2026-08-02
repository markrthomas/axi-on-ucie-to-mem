# =============================================================================
# SystemVerilog UVM runner for axi_ucie_mem_top.
#
# This testbench needs a UVM-capable commercial simulator (VCS, Xcelium, or
# Questa) — none of which is licensed on this host, so `make` here DEGRADES
# GRACEFULLY: it detects an available simulator and, finding none, prints a skip
# and exits 0 (the same policy the root Makefile uses for absent tools).
#
# On a licensed host it runs for real.  Select a test with TEST=<name>:
#   axi_write_read_test | axi_random_test | axi_walking_test
# and add WAVES=1 for a dump.
#
# Two equivalent source layouts (pick with SINGLE):
#   SINGLE=0 (default) : multi-file set (axi_lite_if.sv + axi_pkg.sv + classes + top)
#   SINGLE=1           : the single-file variant axi_ucie_tb_single.sv
# =============================================================================

TEST   ?= axi_write_read_test
WAVES  ?=
SINGLE ?= 0

TOP := axi_ucie_tb_top

# DUT RTL (package first, then leaf modules, then the top).
RTL := \
    ../rtl/aou_pkg.sv \
    ../rtl/ucie_stream_link.sv \
    ../rtl/axi_lite_mem.sv \
    ../rtl/aou_axi_initiator_bridge.sv \
    ../rtl/aou_axi_target_bridge.sv \
    ../rtl/axi_ucie_mem_top.sv

# Bound assertion checkers (shared with the Verilator flow).
SVA := ../dv/sva/axi_lite_sva.sv ../dv/sva/aou_flit_sva.sv ../dv/sva/bind_sva.sv

SV_IF  := axi_lite_if.sv
PKG    := axi_pkg.sv
SV_TOP := axi_ucie_tb_top.sv
MULTI_SRC := $(SV_IF) $(RTL) $(SVA) $(PKG) $(SV_TOP)

# Included class files (axi_pkg.sv `include's these; listed for clean/clarity).
CLASSES := axi_seq_item.sv axi_sequences.sv axi_driver.sv axi_monitor.sv \
           axi_agent.sv axi_scoreboard.sv axi_env.sv axi_test.sv

# Single-file variant: interface + package + top in one file (SVA inlined).
SINGLE_SRC := $(RTL) axi_ucie_tb_single.sv

ifeq ($(SINGLE),1)
    SOURCES := $(SINGLE_SRC)
else
    SOURCES := $(MULTI_SRC)
endif

.PHONY: default help test single vcs xcelium questa clean

default: test

help:
	@echo "axi_ucie_mem — SystemVerilog UVM runner (license-gated)"
	@echo ""
	@echo "  make test        # auto-detect VCS/Xcelium/Questa; skip cleanly if none"
	@echo "  make single      # same, using the single-file variant (SINGLE=1)"
	@echo "  make vcs         # force Synopsys VCS"
	@echo "  make xcelium     # force Cadence Xcelium (xrun)"
	@echo "  make questa      # force Siemens Questa (qrun)"
	@echo "  make clean"
	@echo ""
	@echo "  TEST=<name>   axi_write_read_test | axi_random_test | axi_walking_test"
	@echo "  WAVES=1       enable a waveform dump"
	@echo "  SINGLE=1      build the single-file TB (axi_ucie_tb_single.sv)"

# --- auto-select --------------------------------------------------------------
test:
	@if   command -v vcs  >/dev/null 2>&1; then $(MAKE) vcs; \
	elif command -v xrun >/dev/null 2>&1; then $(MAKE) xcelium; \
	elif command -v qrun >/dev/null 2>&1; then $(MAKE) questa; \
	else \
		echo "[UVM] no UVM simulator (vcs/xrun/qrun) on PATH — skipping"; \
		echo "[UVM] this host has no SystemVerilog/UVM license; TB is a"; \
		echo "[UVM] reference deliverable. Run on a licensed host or EDA Playground."; \
	fi

single:
	@$(MAKE) test SINGLE=1

vcs:
	@echo "[UVM] VCS: $(TEST)"
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps +incdir+. \
		$(if $(WAVES),+define+DUMP,) \
		$(SOURCES) -o simv
	./simv +UVM_TESTNAME=$(TEST)

xcelium:
	@echo "[UVM] Xcelium: $(TEST)"
	xrun -64bit -sv -uvm -timescale 1ns/1ps -incdir . \
		$(if $(WAVES),+define+DUMP,) \
		$(SOURCES) +UVM_TESTNAME=$(TEST)

questa:
	@echo "[UVM] Questa: $(TEST)"
	qrun -64 -sv -uvm -timescale 1ns/1ps +incdir+. \
		$(if $(WAVES),+define+DUMP,) \
		$(SOURCES) -top $(TOP) +UVM_TESTNAME=$(TEST)

clean:
	rm -rf simv simv.daidir csrc *.log ucli.key \
		xcelium.d xrun.history xrun.log INCA_libs .simvision \
		qrun.out work modelsim.ini transcript vsim.wlf \
		*.vcd *.fsdb *.shm novas.* verdi*
