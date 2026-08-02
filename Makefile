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
    $(RTL_DIR)/axi_lite_mem.sv \
    $(RTL_DIR)/aou_axi_initiator_bridge.sv \
    $(RTL_DIR)/aou_axi_target_bridge.sv \
    $(RTL_DIR)/axi_ucie_mem_top.sv
TOP := axi_ucie_mem_top

TB_DIR     := dv/cocotb
SV_DIR     := dv/sv
TB_RESULTS := $(TB_DIR)/results.xml
FST        := $(TB_DIR)/sim_build/$(TOP).fst

IVERILOG_FLAGS       ?= -g2012 -Wall
VERILATOR_LINT_FLAGS ?= --lint-only -Wall -Wno-DECLFILENAME

# Verilator coverage harness (sim/sim_main.cpp -> lcov coverage.info).
VERILATOR_ROOT := $(shell v=$$(command -v verilator 2>/dev/null); [ -n "$$v" ] && realpath "$$(dirname "$$v")/../share/verilator")
VERILATOR_INC  := $(VERILATOR_ROOT)/include
VERILATOR_CPP  := $(VERILATOR_INC)/verilated.cpp $(VERILATOR_INC)/verilated_cov.cpp \
                  $(VERILATOR_INC)/verilated_threads.cpp
COV_DIR := sim/obj_dir_cov
# Minimum line-coverage floor enforced by `make coverage`.
COV_MIN ?= 90

.PHONY: default help \
	test test-all test-write-read test-random test-walking \
	sv vlt coverage waves wave check regress ci \
	lint _lint_iverilog _lint_verilator clean

default: help

help:
	@echo "axi-on-ucie-to-mem — common targets"
	@echo ""
	@echo "  Tests (PyUVM / cocotb):"
	@echo "    make test              # all three cocotb tests"
	@echo "    make test-write-read   # write-then-read-back sequence"
	@echo "    make test-random       # constrained-random read/write mix"
	@echo "    make test-walking      # directed address/data edge cases"
	@echo "    make waves             # dump $(FST) (TEST=<name> for one test)"
	@echo "    make wave              # open the dump in GTKWave"
	@echo ""
	@echo "  Other DV environments:"
	@echo "    make sv                # portable SV directed TB under Icarus"
	@echo "    make vlt               # same SV TB under Verilator (+ bound SVA)"
	@echo "    make coverage          # Verilator --coverage -> sim/coverage.info (floor COV_MIN=$(COV_MIN)%)"
	@echo ""
	@echo "  Gates:"
	@echo "    make lint              # iverilog -Wall + Verilator RTL lint"
	@echo "    make check             # lint + cocotb + SV(Icarus+Verilator)"
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
	@echo "[TEST] all three PyUVM tests passed"

test-write-read:
	$(call run_one_test,write_read_test)

test-random:
	$(call run_one_test,random_test)

test-walking:
	$(call run_one_test,walking_test)

# Waveform dump.  All three tests share one sim by default; TEST=<name> dumps
# just one.  cocotb's Icarus dump module is only compiled into a FRESH
# sim_build, so wipe it first.
WAVE_TESTS := write_read_test random_test walking_test

waves:
	@if [ -n "$(TEST)" ] && ! echo " $(WAVE_TESTS) " | grep -q " $(TEST) "; then \
		echo "[WAVES] unknown TEST='$(TEST)' — choose one of: $(WAVE_TESTS)"; exit 1; fi
	rm -rf $(TB_DIR)/sim_build
	$(MAKE) -C $(TB_DIR) WAVES=1 $(if $(TEST),TESTCASE=$(TEST),)
	@echo "[WAVES] wrote $(FST)$(if $(TEST), (single test: $(TEST)),)"

wave:
	@if ! command -v gtkwave >/dev/null 2>&1; then \
		echo "[WAVE] gtkwave not on PATH — install GTKWave to view waveforms"; exit 0; fi; \
	$(MAKE) --no-print-directory waves $(if $(TEST),TEST=$(TEST),); \
	echo "[WAVE] opening $(FST) in GTKWave"; \
	exec gtkwave $(FST)

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

# --- gates -------------------------------------------------------------------
check: lint test-all sv vlt

regress: check coverage
	@echo "[REGRESS] lint + cocotb + SV(Icarus+Verilator) + coverage PASSED"

ci: regress
	@echo "[CI] full regression PASSED"

# --- clean -------------------------------------------------------------------
clean:
	$(MAKE) -C $(TB_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(SV_DIR) clean 2>/dev/null || true
	rm -rf $(TB_DIR)/sim_build $(TB_DIR)/__pycache__ __pycache__ \
		results.xml dump.fst dump.vcd obj_dir \
		$(COV_DIR) sim/coverage.info sim/coverage.dat sim/annotated
