# =============================================================================
# axi-on-ucie-to-mem — AXI-over-UCIe (AoU) to an AXI-Lite memory.
#
# Standard DV gate targets shared with the sibling RTL repos.  The cocotb/pyuvm
# run lives in dv/cocotb/; this file provides help / lint / test / waves / check
# / regress / ci / clean and delegates to it.  More DV environments (SV directed
# TB, SystemC, coverage, SV/UVM) are added in later build phases and plug in as
# additional targets here.
#
# Toolchain (WSL2 host):
#   * Simulator : Icarus Verilog 11  (/usr/bin/iverilog, pinned via ICARUS_BIN_DIR)
#   * Python    : /usr/bin/python3 with cocotb 1.9.2 + pyuvm 4.0.1
#   * Lint      : Verilator (optional; degrades gracefully if absent)
# =============================================================================

IVERILOG  ?= iverilog
VERILATOR ?= verilator

RTL_DIR := rtl
# Package first, then leaf modules, then the top (compile order matters).
RTL := \
    $(RTL_DIR)/aou_pkg.sv \
    $(RTL_DIR)/ucie_stream_link.sv \
    $(RTL_DIR)/aou_activation.sv \
    $(RTL_DIR)/axi_lite_mem.sv \
    $(RTL_DIR)/aou_axi_initiator_bridge.sv \
    $(RTL_DIR)/aou_axi_target_bridge.sv \
    $(RTL_DIR)/axi_ucie_mem_top.sv
TOP := axi_ucie_mem_top

TB_DIR     := dv/cocotb
SV_DIR     := dv/sv
PACK_DIR   := dv/pack
ACT_DIR    := dv/act
SC_DIR     := dv/systemc
UVM_DIR    := uvm
TB_RESULTS := $(TB_DIR)/results.xml
FST        := $(TB_DIR)/sim_build/$(TOP).fst
WAVE_SAVE  := dv/wave.gtkw           # curated signal layout applied on open

IVERILOG_FLAGS       ?= -g2012 -Wall
VERILATOR_LINT_FLAGS ?= --lint-only -Wall -Wno-DECLFILENAME

# Verilator coverage harness (sim/sim_main.cpp -> lcov coverage.info).
VERILATOR_ROOT := $(shell v=$$(command -v verilator 2>/dev/null); [ -n "$$v" ] && realpath "$$(dirname "$$v")/../share/verilator")
VERILATOR_INC  := $(VERILATOR_ROOT)/include
VERILATOR_CPP  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_cov.cpp \
                  $(VERILATOR_INC)/verilated_threads.cpp
COV_DIR := sim/obj_dir_cov
# Minimum line-coverage floor enforced by `make coverage`.  Set with headroom
# below the achieved coverage (~90-94%) because Verilator's line attribution
# differs slightly between versions (e.g. 89.8% on 5.020 vs 93.5% on 5.047).
COV_MIN ?= 85

.PHONY: default help \
	test test-all test-write-read test-random test-walking test-burst \
	test-outstanding \
	sv vlt pack act systemc uvm coverage formal waves wave check regress ci \
	lint _lint_iverilog _lint_verilator clean

default: help

help:
	@echo "axi-on-ucie-to-mem — common targets"
	@echo ""
	@echo "  Tests (PyUVM / cocotb):"
	@echo "    make test              # all five cocotb tests"
	@echo "    make test-write-read   # write-then-read-back sequence"
	@echo "    make test-random       # constrained-random read/write mix"
	@echo "    make test-walking      # directed address/data edge cases"
	@echo "    make test-burst        # INCR/WRAP/FIXED burst read-back"
	@echo "    make test-outstanding  # multiple-outstanding reads (fills initiator queue)"
	@echo "    make waves             # dump $(FST) (TEST=<name> for one test)"
	@echo "    make wave              # open the dump in GTKWave"
	@echo ""
	@echo "  Other DV environments:"
	@echo "    make sv                # portable SV directed TB under Icarus"
	@echo "    make vlt               # same SV TB under Verilator (+ bound SVA)"
	@echo "    make pack              # §4.3/§5.8 byte-exact packing conformance (Icarus+Verilator)"
	@echo "    make act               # §8 activation FSM unit test: deactivate/re-activate/ERROR (Icarus+Verilator)"
	@echo "    make systemc           # SystemC TB (Verilator --sc model + sc_main)"
	@echo "    make uvm               # SystemVerilog UVM TB (license-gated; skips if no VCS/Xcelium/Questa)"
	@echo "    make coverage          # Verilator --coverage -> sim/coverage.info (floor COV_MIN=$(COV_MIN)%)"
	@echo "    make formal            # SymbiYosys proof of axi_lite_mem (TASK=bmc|cover|prove; skips if no sby)"
	@echo ""
	@echo "  Gates:"
	@echo "    make lint              # iverilog -Wall + Verilator RTL lint"
	@echo "    make check             # lint + cocotb + SV(Icarus+Verilator) + pack + act + SystemC"
	@echo "    make regress           # check + coverage (CI-style pass/fail)"
	@echo "    make ci                # regress"
	@echo ""
	@echo "  Other: make clean"

# --- tests -------------------------------------------------------------------
# run_one_test runs a SINGLE cocotb test in its own simulation and fails the
# build if that test did not pass.  One sim per test re-zeroes the memory (the
# RTL only zeroes its array at time 0) so a later test never reads a location an
# earlier test wrote, and we gate on results.xml because cocotb's make flow
# exits 0 even when a test fails.
define run_one_test
@$(MAKE) -C $(TB_DIR) TESTCASE=$(1)
@test -f $(TB_RESULTS) || { echo "[TEST] $(1): no results.xml (sim did not run)"; exit 1; }
@if grep -Eq "<failure|<error" $(TB_RESULTS); then echo "[TEST] $(1) FAILED (see log above)"; exit 1; fi
@echo "[TEST] $(1) passed"
endef

test: test-all

test-all:
	$(call run_one_test,write_read_test)
	$(call run_one_test,random_test)
	$(call run_one_test,walking_test)
	$(call run_one_test,burst_test)
	$(call run_one_test,multi_outstanding_test)
	@echo "[TEST] all five PyUVM tests passed"

test-write-read:
	$(call run_one_test,write_read_test)

test-random:
	$(call run_one_test,random_test)

test-walking:
	$(call run_one_test,walking_test)

test-burst:
	$(call run_one_test,burst_test)

test-outstanding:
	$(call run_one_test,multi_outstanding_test)

# Waveform dump.  All three tests share one sim by default; TEST=<name> dumps
# just one.  cocotb's Icarus dump module is only compiled into a FRESH
# sim_build, so wipe it first.
WAVE_TESTS := write_read_test random_test walking_test burst_test multi_outstanding_test

waves:
	@if [ -n "$(TEST)" ] && ! echo " $(WAVE_TESTS) " | grep -q " $(TEST) "; then \
		echo "[WAVES] unknown TEST='$(TEST)' — choose one of: $(WAVE_TESTS)"; exit 1; fi
	rm -rf $(TB_DIR)/sim_build
	$(MAKE) -C $(TB_DIR) WAVES=1 $(if $(TEST),TESTCASE=$(TEST),)
	@echo "[WAVES] wrote $(FST)$(if $(TEST), (single test: $(TEST)),)"

# GTKWave never auto-populates its wave pane, so opening the raw FST looks like a
# blank/hung window.  Apply $(WAVE_SAVE) so the AXI/flit/memory signals are shown
# on open.  NO_AT_BRIDGE=1 skips the AT-SPI accessibility bus, whose absent-server
# timeout is what makes GTK apps appear to hang for seconds under WSLg/headless X.
wave:
	@if ! command -v gtkwave >/dev/null 2>&1; then \
		echo "[WAVE] gtkwave not on PATH — install GTKWave to view waveforms"; exit 0; fi; \
	$(MAKE) --no-print-directory waves $(if $(TEST),TEST=$(TEST),); \
	echo "[WAVE] opening $(FST) in GTKWave (layout: $(WAVE_SAVE))"; \
	exec env NO_AT_BRIDGE=1 gtkwave $(if $(wildcard $(WAVE_SAVE)),-a $(WAVE_SAVE),) $(FST)

# --- gates -------------------------------------------------------------------
lint: _lint_iverilog _lint_verilator

_lint_iverilog:
	@echo "[LINT] iverilog -Wall compile check..."
	$(IVERILOG) $(IVERILOG_FLAGS) -o /dev/null -s $(TOP) $(RTL)

_lint_verilator:
	@if command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[LINT] Verilator RTL lint..."; \
		$(VERILATOR) $(VERILATOR_LINT_FLAGS) --top-module $(TOP) $(RTL); \
	else \
		echo "[LINT] verilator not on PATH — skipping RTL lint"; \
	fi

# --- other DV environments ---------------------------------------------------
# Portable SV directed TB under Icarus and Verilator (Verilator run also binds
# the AXI-Lite + AoU-flit SVA checkers via --assert).
sv:
	$(MAKE) -C $(SV_DIR) icarus

vlt:
	$(MAKE) -C $(SV_DIR) verilator

# §4.3/§5.8 byte-exact packing conformance TB (aou_pkg only), Icarus + Verilator.
pack:
	$(MAKE) -C $(PACK_DIR) icarus
	$(MAKE) -C $(PACK_DIR) verilator

# §8 activation FSM unit test (aou_activation): bring-up, SW/peer deactivate,
# re-activation, and ERROR entry/recovery, Icarus + Verilator.
act:
	$(MAKE) -C $(ACT_DIR) icarus
	$(MAKE) -C $(ACT_DIR) verilator

# SystemC TB: Verilator --sc model of the DUT + hand-written sc_main driver.
# Degrades gracefully (skip, exit 0) if Verilator or SystemC is absent.
systemc:
	$(MAKE) -C $(SC_DIR) run

# SystemVerilog UVM TB (mirrors the PyUVM TB).  Needs a UVM-capable commercial
# simulator; degrades gracefully (skip, exit 0) when none is present.
uvm:
	$(MAKE) -C $(UVM_DIR) $(if $(TEST),TEST=$(TEST),) $(if $(WAVES),WAVES=$(WAVES),) $(if $(SINGLE),SINGLE=$(SINGLE),)

# coverage: Verilator --coverage build + run of sim/sim_main.cpp; emits
# sim/coverage.info (lcov) and enforces the COV_MIN line floor.  Degrades
# gracefully (exit 0) when Verilator is not installed.
coverage:
	@set -e; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { echo "[COVERAGE] verilator not on PATH; skipping"; exit 0; }; \
	rm -rf $(COV_DIR); \
	$(VERILATOR) --coverage -cc $(RTL) --top-module $(TOP) \
		--Mdir $(COV_DIR) -Wall -Wno-DECLFILENAME; \
	$(MAKE) -C $(COV_DIR) -f V$(TOP).mk; \
	g++ -DVM_COVERAGE=1 -o $(COV_DIR)/sim_cov \
		sim/sim_main.cpp $(COV_DIR)/V$(TOP)__ALL.a \
		-I$(COV_DIR) -I$(VERILATOR_INC) -I$(VERILATOR_INC)/vltstd \
		$(VERILATOR_CPP) -pthread -lm; \
	( cd $(COV_DIR) && ./sim_cov ); \
	if command -v verilator_coverage >/dev/null 2>&1; then \
		verilator_coverage --write-info sim/coverage.info $(COV_DIR)/coverage.dat; \
		echo "[COVERAGE] sim/coverage.info written"; \
		pct=$$(awk -F: '/^DA:/{split($$2,a,","); f++; if(a[2]+0>0) h++} END{printf "%.1f", (f? 100*h/f : 0)}' sim/coverage.info); \
		echo "[COVERAGE] line coverage: $$pct% (floor $(COV_MIN)%)"; \
		awk -v p="$$pct" -v m="$(COV_MIN)" 'BEGIN{exit !(p+0 >= m+0)}' || { \
			echo "[COVERAGE] FAIL: line coverage $$pct% below the $(COV_MIN)% floor"; exit 1; }; \
		echo "[COVERAGE] PASS: meets the $(COV_MIN)% floor"; \
	else \
		echo "[COVERAGE] coverage.dat in $(COV_DIR) (install verilator for lcov export)"; \
	fi

# formal: SymbiYosys proof of the AXI4-Lite memory target (protocol legality +
# write->read data integrity).  bmc + cover + an unbounded `prove` (abc pdr).
# Optional stretch (not in the `ci` gate); degrades gracefully if sby is absent.
# TASK=<bmc|cover|prove> runs just one.
formal:
	@if ! command -v sby >/dev/null 2>&1; then \
		echo "[FORMAL] SymbiYosys (sby) not on PATH — install oss-cad-suite to run proofs"; exit 0; fi; \
	sby -f formal/axi_lite_mem.sby $(TASK)

# --- gates -------------------------------------------------------------------
check: lint test-all sv vlt pack act systemc

regress: check coverage
	@echo "[REGRESS] lint + cocotb + SV(Icarus+Verilator) + pack + act + SystemC + coverage PASSED"

ci: regress
	@echo "[CI] full regression PASSED"

# --- clean -------------------------------------------------------------------
clean:
	$(MAKE) -C $(TB_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(SV_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(PACK_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(ACT_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(SC_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(UVM_DIR) clean 2>/dev/null || true
	rm -rf $(TB_DIR)/sim_build $(TB_DIR)/__pycache__ __pycache__ \
		results.xml dump.fst dump.vcd obj_dir \
		$(COV_DIR) sim/coverage.info sim/coverage.dat sim/annotated
