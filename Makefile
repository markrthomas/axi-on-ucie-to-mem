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
# lcov exporter that ships with Verilator.  Parameterized (like VERILATOR) so a
# pinned/out-of-PATH Verilator install can point it at the matching binary;
# otherwise the coverage floor is silently skipped when it is not on PATH.
VERILATOR_COV ?= verilator_coverage
# SymbiYosys driver for the formal tier.  Parameterized (like VERILATOR) because
# oss-cad-suite is deliberately kept OFF $PATH — its bundled iverilog would
# shadow the apt one the cocotb VPI links against — so the image / CI pass the
# bundled prover by absolute path: `make formal SBY="$$OSS/bin/sby"`.
# Left at the bare default, the formal target skips gracefully when sby is not
# installed; given an explicit path it MUST run (a bad path is a hard error).
SBY ?= sby

RTL_DIR := rtl
# Package first, then leaf modules, then the top (compile order matters).
RTL := \
    $(RTL_DIR)/aou_pkg.sv \
    $(RTL_DIR)/ucie_stream_link.sv \
    $(RTL_DIR)/aou_activation.sv \
    $(RTL_DIR)/axi_lite_mem.sv \
    $(RTL_DIR)/aou_reorder.sv \
    $(RTL_DIR)/aou_ooo_resp_src.sv \
    $(RTL_DIR)/aou_rp_mux.sv \
    $(RTL_DIR)/aou_axi_initiator_bridge.sv \
    $(RTL_DIR)/aou_axi_target_bridge.sv \
    $(RTL_DIR)/axi_ucie_mem_top.sv
TOP := axi_ucie_mem_top

TB_DIR     := dv/cocotb
SV_DIR     := dv/sv
PACK_DIR   := dv/pack
ACT_DIR    := dv/act
REORDER_DIR := dv/reorder
OOO_DIR     := dv/ooo
MRP_DIR     := dv/mrp
SC_DIR     := dv/systemc
UVM_DIR    := uvm
TB_RESULTS := $(TB_DIR)/results.xml
FST        := $(TB_DIR)/sim_build/$(TOP).fst

# --- waveform layouts (dev-only; NOTHING here is on the gate path) -----------
# dv/waves/ holds one curated GTKWave save file per debug target, so `make wave`
# opens the FST pre-populated and grouped for THAT scenario instead of blank.
# default.gtkw is the generic fallback used whenever a test has no bespoke
# layout.  See README "Waveform debugging" and docs/NOTES.md.
WAVE_DIR     := dv/waves
WAVE_DEFAULT := $(WAVE_DIR)/default.gtkw
WAVE_CHECK   := $(WAVE_DIR)/wave_check.py
# Per-env dumps written by the `waves-<env>` targets (dv/common/aou_wave_dump.svh
# is compiled into those builds only, under -DAOU_WAVES).
SV_FST  := $(SV_DIR)/sim_build/tb_axi_ucie_mem.fst
OOO_FST := $(OOO_DIR)/sim_build/tb_axi_ucie_ooo.fst
MRP_FST := $(MRP_DIR)/sim_build/tb_axi_ucie_mrp.fst
ACT_FST := $(ACT_DIR)/sim_build/tb_aou_act.fst
# wave_layout(<key>): the bespoke dv/waves/<key>.gtkw when it exists, else the
# generic layout — so a brand-new test still opens populated.
wave_layout = $(if $(wildcard $(WAVE_DIR)/$(1).gtkw),$(WAVE_DIR)/$(1).gtkw,$(WAVE_DEFAULT))

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

# Functional-coverage floor for the PyUVM model (dv/cocotb/axi_coverage.py),
# in percent of that model's own goal bins.  100 by default: every goal bin is
# reachable with the stimulus in dv/cocotb/axi_seq.py, so anything less is a
# coverage regression.  The last cocotb test of `make test-all` gates on it and
# prints the `[COV-FUNC] PASS/FAIL` banner.
FCOV_MIN ?= 100
export FCOV_MIN
# Merge database the per-test simulations of one `make test*` run accumulate into
# (each test runs in its own sim, so no single process sees the whole run).
FCOV_DB := $(TB_DIR)/fcov.json

# --- debug logging (VERBOSE=0|1|2) -------------------------------------------
# ONE knob for the whole DV gate, threaded into every environment (see README
# "Debug logging" and docs/DOCKER.md).  `make <target> VERBOSE=<lvl>` exports
# AOU_VERBOSE to every sub-make, which passes it on as `+verbose=<lvl>` (SV /
# Icarus / Verilator), AOU_VERBOSE in the environment (cocotb, SystemC):
#
#   0  off      — DEFAULT.  No extra output anywhere; every env's stdout is
#                 byte-identical to a build without the logging facility, so CI
#                 banners, the committed dv/systemc/sc.log and the coverage
#                 ratio are unaffected.
#   1  packet   — one decoded AoU flit line per link handshake in the envs that
#                 carry real flits (cocotb, sv, systemc, ooo, mrp), the unit
#                 envs' per-check detail (pack, act, reorder), plus the existing
#                 per-beat AXI transaction trace.
#   2  debug    — level 1 plus internal DUT state: bridge FSMs, §6 credit
#                 counters, initiator request-queue occupancy, reorder-buffer
#                 slots, RP arbiter grants / per-plane RX depth, OOO hold state.
#
# Every level also writes a per-test file under $(LOG_DIR) (gitignored) so a
# failing run stays inspectable after the fact.  (AOU_VERBOSE can be exported
# directly instead; a bare `+verbose` still means level 1.)
LOG_DIR ?= $(CURDIR)/logs
export AOU_LOG_DIR := $(LOG_DIR)

VERBOSE ?= 0
AOU_LVL := $(strip $(VERBOSE))
ifeq ($(AOU_LVL),)
AOU_LVL := 0
endif
ifeq ($(filter 0 1 2,$(AOU_LVL)),)
$(error VERBOSE must be 0, 1 or 2 (got '$(VERBOSE)'))
endif
ifneq ($(AOU_LVL),0)
export AOU_VERBOSE := $(AOU_LVL)
endif

.PHONY: default help \
	test test-all test-write-read test-random test-walking test-burst \
	test-outstanding test-coverage fcov-reset \
	sv vlt pack act reorder ooo mrp systemc uvm eda-check coverage formal check regress ci \
	waves waves-sv waves-ooo waves-mrp waves-act waves-all \
	wave wave-sv wave-ooo wave-mrp wave-act wave-check \
	lint _lint_iverilog _lint_verilator clean

default: help

help:
	@echo "axi-on-ucie-to-mem — common targets"
	@echo ""
	@echo "  Tests (PyUVM / cocotb):"
	@echo "    make test              # all six cocotb tests (ends with the [COV-FUNC] gate)"
	@echo "    make test-write-read   # write-then-read-back sequence"
	@echo "    make test-random       # constrained-random read/write mix"
	@echo "    make test-walking      # directed address/data edge cases"
	@echo "    make test-burst        # INCR/WRAP/FIXED burst read-back"
	@echo "    make test-outstanding  # multiple-outstanding reads (fills initiator queue)"
	@echo "    make test-coverage     # functional-coverage closure + [COV-FUNC] floor (FCOV_MIN=$(FCOV_MIN)%)"
	@echo "    make waves             # dump $(FST) (TEST=<name> for one test)"
	@echo "    make wave              # dump + open in GTKWave with the matching dv/waves/ layout"
	@echo ""
	@echo "  Waveform debugging (dev-only — never part of check/regress/ci):"
	@echo "    make wave TEST=<name>   # cocotb chain; layout = dv/waves/<key>.gtkw, key = <name>"
	@echo "                           #   minus its _test suffix (write_read, burst,"
	@echo "                           #   multi_outstanding), else dv/waves/default.gtkw"
	@echo "    make wave-sv           # dv/sv directed TB      -> dv/waves/sv.gtkw"
	@echo "    make wave-ooo          # dv/ooo OOO_EN=1 chain  -> dv/waves/ooo.gtkw"
	@echo "    make wave-mrp          # dv/mrp NUM_RP=2 chain  -> dv/waves/mrp.gtkw"
	@echo "    make wave-act          # dv/act §8 FSM unit TB  -> dv/waves/act.gtkw"
	@echo "    make waves-sv|-ooo|-mrp|-act   # just dump the FST (no viewer)"
	@echo "    make waves-all         # every dump above, in one go"
	@echo "    make wave-check        # drift-guard: every .gtkw net path must still"
	@echo "                           #   exist in its dump (LAYOUT=<file> for just one)"
	@echo ""
	@echo "  Other DV environments:"
	@echo "    make sv                # portable SV directed TB under Icarus"
	@echo "    make vlt               # same SV TB under Verilator (+ bound SVA)"
	@echo "    make pack              # §4.3/§5.8 byte-exact packing conformance (Icarus+Verilator)"
	@echo "    make act               # §8 activation FSM unit test: deactivate/re-activate/ERROR (Icarus+Verilator)"
	@echo "    make reorder           # per-ID response reorder buffer: out-of-order-by-ID completion (Icarus+Verilator)"
	@echo "    make ooo               # END-TO-END out-of-order-by-ID chain (OOO_EN=1): real different-ID overtake (Icarus+Verilator)"
	@echo "    make mrp               # END-TO-END multiple resource planes (NUM_RP=2): per-plane credits/routing, arbiter fairness (Icarus+Verilator)"
	@echo "    make systemc           # SystemC TB (Verilator --sc model + sc_main)"
	@echo "    make uvm               # SystemVerilog UVM TB (license-gated; skips if no VCS/Xcelium/Questa)"
	@echo "    make coverage          # Verilator --coverage -> sim/coverage.info (floor COV_MIN=$(COV_MIN)%)"
	@echo "    make formal            # SymbiYosys proofs: axi_lite_mem + §4.3 flit + §6 credits + §8 activation"
	@echo "                           #   (bmc+cover gate, prove best-effort; TASK=bmc|cover|prove;"
	@echo "                           #    SBY=<path> for an out-of-PATH sby, e.g. SBY=\$$OSS/bin/sby)"
	@echo ""
	@echo "  Gates:"
	@echo "    make lint              # iverilog -Wall + Verilator RTL lint"
	@echo "    make eda-check         # verify the EDA Playground design.sv is current (drift-guard)"
	@echo "    make check             # lint + eda-check + cocotb + SV(Icarus+Verilator) + pack + act + reorder + ooo + mrp + SystemC"
	@echo "    make regress           # check + coverage + formal (CI-style pass/fail)"
	@echo "    make ci                # regress"
	@echo ""
	@echo "  Debug logging (one knob, every env — see README 'Debug logging'):"
	@echo "    VERBOSE=0               # default: no extra output (byte-identical stdout)"
	@echo "    VERBOSE=1               # decoded AoU flit trace + per-beat AXI transactions"
	@echo "    VERBOSE=2               # + internal state (FSMs, credits, queues, arbiter)"
	@echo "                           #   (e.g. make sv VERBOSE=1 / make ooo VERBOSE=2)"
	@echo "                           #   logs land in $(LOG_DIR)/<env>[_<test>].log"
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

# The per-test simulations of one run merge their functional-coverage bins
# through $(FCOV_DB); drop any stale database so a report always describes
# exactly this invocation.
fcov-reset:
	@rm -f $(FCOV_DB)

# coverage_test runs LAST: it closes the functional coverage model and gates the
# merged result against FCOV_MIN, printing [COV-FUNC] PASS/FAIL.
test-all: fcov-reset
	$(call run_one_test,write_read_test)
	$(call run_one_test,random_test)
	$(call run_one_test,walking_test)
	$(call run_one_test,burst_test)
	$(call run_one_test,multi_outstanding_test)
	$(call run_one_test,coverage_test)
	@echo "[TEST] all six PyUVM tests passed"

test-write-read: fcov-reset
	$(call run_one_test,write_read_test)

test-random: fcov-reset
	$(call run_one_test,random_test)

test-walking: fcov-reset
	$(call run_one_test,walking_test)

test-burst: fcov-reset
	$(call run_one_test,burst_test)

test-outstanding: fcov-reset
	$(call run_one_test,multi_outstanding_test)

test-coverage: fcov-reset
	$(call run_one_test,coverage_test)

# Waveform dump.  All three tests share one sim by default; TEST=<name> dumps
# just one.  cocotb's Icarus dump module is only compiled into a FRESH
# sim_build, so wipe it first.
WAVE_TESTS := write_read_test random_test walking_test burst_test \
              multi_outstanding_test coverage_test

waves:
	@if [ -n "$(TEST)" ] && ! echo " $(WAVE_TESTS) " | grep -q " $(TEST) "; then \
		echo "[WAVES] unknown TEST='$(TEST)' — choose one of: $(WAVE_TESTS)"; exit 1; fi
	rm -rf $(TB_DIR)/sim_build
	$(MAKE) -C $(TB_DIR) WAVES=1 $(if $(TEST),TESTCASE=$(TEST),)
	@echo "[WAVES] wrote $(FST)$(if $(TEST), (single test: $(TEST)),)"

# --- per-env waveform dumps (dev-only) ---------------------------------------
# The SV testbenches gained an opt-in dump hook (dv/common/aou_wave_dump.svh)
# that is compiled ONLY under -DAOU_WAVES, which only these targets pass — the
# gate builds the same TBs with not one dump statement elaborated.
waves-sv:
	@$(MAKE) --no-print-directory -C $(SV_DIR) waves

waves-ooo:
	@$(MAKE) --no-print-directory -C $(OOO_DIR) waves

waves-mrp:
	@$(MAKE) --no-print-directory -C $(MRP_DIR) waves

waves-act:
	@$(MAKE) --no-print-directory -C $(ACT_DIR) waves

waves-all: waves waves-sv waves-ooo waves-mrp waves-act

# open_gtkwave(<fst>,<layout>): apply the curated layout so the wave pane is
# populated and grouped on open — GTKWave never auto-adds signals, so without a
# save file the FST opens blank and looks hung.  NO_AT_BRIDGE=1 skips the AT-SPI
# accessibility bus, whose absent-server timeout is what makes GTK apps appear
# to hang for seconds under WSLg/headless X.  No gtkwave on PATH is a clean
# skip (exit 0) AFTER the dump, so the FST is still there for a viewer elsewhere.
define open_gtkwave
@if ! command -v gtkwave >/dev/null 2>&1; then \
	echo "[WAVE] gtkwave not on PATH — dump is at $(1) (layout: $(2))"; exit 0; fi; \
echo "[WAVE] opening $(1) in GTKWave (layout: $(2))"; \
exec env NO_AT_BRIDGE=1 gtkwave $(if $(wildcard $(2)),-a $(2),) $(1)
endef

# `make wave [TEST=<name>]` — cocotb chain.  The layout key is the test name
# with its `_test` suffix stripped (write_read_test -> dv/waves/write_read.gtkw);
# a test with no bespoke layout falls back to dv/waves/default.gtkw.
WAVE_KEY := $(if $(TEST),$(patsubst %_test,%,$(TEST)),default)

wave:
	@$(MAKE) --no-print-directory waves $(if $(TEST),TEST=$(TEST),)
	$(call open_gtkwave,$(FST),$(call wave_layout,$(WAVE_KEY)))

wave-sv: waves-sv
	$(call open_gtkwave,$(SV_FST),$(call wave_layout,sv))

wave-ooo: waves-ooo
	$(call open_gtkwave,$(OOO_FST),$(call wave_layout,ooo))

wave-mrp: waves-mrp
	$(call open_gtkwave,$(MRP_FST),$(call wave_layout,mrp))

wave-act: waves-act
	$(call open_gtkwave,$(ACT_FST),$(call wave_layout,act))

# wave-check: drift-guard for dv/waves/*.gtkw — resolve every net path a layout
# references against that target's real dump hierarchy and fail, naming the
# orphan, when a renamed/moved RTL signal has left a stale entry behind (the
# `eda-check` idea, applied to the wave layer).
#
# Deliberately DEV/OPT-IN and NOT part of check/regress/ci: it has to run the
# sims to produce dumps and it needs GTKWave's fst2vcd, neither of which the
# byte-identical, wave-free gate may depend on.  Missing dumps or no fst2vcd
# degrade to a printed SKIP.  Pass FST2VCD=<path> or OSS=<root> for the reader.
wave-check: waves-all
	@echo "[WAVE-CHECK] verifying $(words $(wildcard $(WAVE_DIR)/*.gtkw)) layout(s) in $(WAVE_DIR)/"
	@python3 $(WAVE_CHECK) $(CURDIR) $(if $(LAYOUT),$(LAYOUT),)

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

reorder:
	$(MAKE) -C $(REORDER_DIR) icarus
	$(MAKE) -C $(REORDER_DIR) verilator

# End-to-end OOO datapath proof: axi_ucie_mem_top with OOO_EN=1 driven by
# interleaved multi-ID traffic.  Checks same-ID in-order delivery, a REAL
# different-ID overtake (fails if none is observed), no cross-ID leakage and
# that every response is delivered.  See docs/PLAN.md F2.
ooo:
	$(MAKE) -C $(OOO_DIR) icarus
	$(MAKE) -C $(OOO_DIR) verilator

# End-to-end multiple-resource-plane proof: axi_ucie_mem_top with NUM_RP=2 —
# two AoU chains (own §8 activation, own §6 credit banks, own outstanding
# tracking) sharing one link pair through the round-robin plane arbiter and the
# FDId router.  Checks per-plane routing, no cross-plane credit leakage (idle
# plane's credit bank never moves; a jammed plane never stalls the other),
# arbiter fairness under contention, and that every transaction completes.
# See docs/PLAN.md F1.
mrp:
	$(MAKE) -C $(MRP_DIR) icarus
	$(MAKE) -C $(MRP_DIR) verilator

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
	if command -v $(VERILATOR_COV) >/dev/null 2>&1; then \
		$(VERILATOR_COV) --write-info sim/coverage.info $(COV_DIR)/coverage.dat; \
		echo "[COVERAGE] sim/coverage.info written"; \
		pct=$$(awk -F: '/^DA:/{split($$2,a,","); f++; if(a[2]+0>0) h++} END{printf "%.1f", (f? 100*h/f : 0)}' sim/coverage.info); \
		echo "[COVERAGE] line coverage: $$pct% (floor $(COV_MIN)%)"; \
		awk -v p="$$pct" -v m="$(COV_MIN)" 'BEGIN{exit !(p+0 >= m+0)}' || { \
			echo "[COVERAGE] FAIL: line coverage $$pct% below the $(COV_MIN)% floor"; exit 1; }; \
		echo "[COVERAGE] PASS: meets the $(COV_MIN)% floor"; \
	else \
		echo "[COVERAGE] coverage.dat in $(COV_DIR) (install verilator for lcov export)"; \
	fi

# formal: the SymbiYosys proof tier — a first-class, GATING part of `regress`.
#
#   formal/axi_lite_mem.sby — AXI4-Lite memory target: channel legality, no
#       response without a request, write->read data integrity.
#   formal/aou_flit.sby     — §4.3 byte-exact flit protocol header (checked
#       against an independent transcription of the Figure-5 byte map), reserved
#       bits zero, pack->unpack round-trip, §6 MsgCredit (Table 16/17) and §5.8
#       message-into-payload placement.
#   formal/aou_credit.sby   — §6 credit flow control on the REAL bridges against
#       a fully adversarial peer: counters never exceed their ceiling (and, being
#       unsigned, therefore never underflow), and every presented message is
#       funded by its own message type's credit.
#   formal/aou_activation.sby — §8 interface activation FSM against a fully
#       adversarial peer and free SW deactivate / ERROR-clear controls: never
#       ENABLED before the peer's CrdtGrant, no data-transfer enable outside
#       ENABLED, only legal Table-24 transitions (teardown gated on data_idle),
#       and ERROR always recovers to a re-armed DISABLED.
#
# `bmc` (bounded safety) and `cover` (required covers reachable) GATE; `prove`
# (unbounded k-induction) is run best-effort and only warns if it does not
# converge, since convergence depends on the solver/depth.
# TASK=<bmc|cover|prove> runs just that one task, gating.
FORMAL_SBY := formal/axi_lite_mem.sby formal/aou_flit.sby formal/aou_credit.sby \
              formal/aou_activation.sby

formal:
	@set -e; \
	if [ -z "$(strip $(SBY))" ]; then \
		echo "[FORMAL] SBY is empty — skipping the formal tier"; exit 0; fi; \
	if ! command -v $(SBY) >/dev/null 2>&1; then \
		if [ "$(strip $(SBY))" = "sby" ]; then \
			echo "[FORMAL] SymbiYosys (sby) not on PATH — install oss-cad-suite, or pass SBY=<path>, to run proofs"; \
			exit 0; \
		fi; \
		echo "[FORMAL] FAIL: SBY='$(strip $(SBY))' is not an executable prover"; exit 1; \
	fi; \
	gating="$(strip $(TASK))"; best=""; \
	if [ -z "$$gating" ]; then gating="bmc cover"; best="prove"; fi; \
	for f in $(FORMAL_SBY); do \
		for t in $$gating; do \
			echo "[FORMAL] $$f: $$t"; \
			$(SBY) -f $$f $$t || { echo "[FORMAL] FAIL: $$f $$t"; exit 1; }; \
		done; \
		for t in $$best; do \
			echo "[FORMAL] $$f: $$t (best-effort, non-gating)"; \
			$(SBY) -f $$f $$t || \
				echo "[FORMAL] NOTE: $$f $$t did not converge — best-effort, not gating"; \
		done; \
	done; \
	echo "[FORMAL] PASS: $(words $(FORMAL_SBY)) proofs, gating tasks: $$gating"

# EDA Playground drift-guard: fail if the committed single design file
# (eda/vcs_uvm/design.sv) or testbench.sv is stale vs rtl/ + the UVM TB.  Cheap
# (concat + diff), so it rides in the light `check` loop and keeps the pasteable
# EDA Playground design current with zero manual steps.
eda-check:
	@$(MAKE) --no-print-directory -C uvm eda-check

# --- gates -------------------------------------------------------------------
check: lint eda-check test-all sv vlt pack act reorder ooo mrp systemc

# regress is the single signoff gate: everything `check` runs, plus the coverage
# floor and the formal tier.  `formal` is kept OUT of the lighter `check` so the
# quick loop stays quick; only regress/ci pay the prover time.
regress: check coverage formal
	@echo "[REGRESS] lint + cocotb + SV(Icarus+Verilator) + pack + act + reorder + ooo + mrp + SystemC + coverage + formal PASSED"

ci: regress
	@echo "[CI] full regression PASSED"

# --- clean -------------------------------------------------------------------
clean:
	$(MAKE) -C $(TB_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(SV_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(PACK_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(ACT_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(REORDER_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(OOO_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(MRP_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(SC_DIR) clean 2>/dev/null || true
	$(MAKE) -C $(UVM_DIR) clean 2>/dev/null || true
	rm -f $(FCOV_DB)
	rm -rf $(LOG_DIR)
	rm -rf $(TB_DIR)/sim_build $(TB_DIR)/__pycache__ __pycache__ \
		results.xml dump.fst dump.vcd obj_dir \
		$(COV_DIR) sim/coverage.info sim/coverage.dat sim/annotated
	rm -rf $(patsubst %.sby,%_bmc,$(FORMAL_SBY)) \
		$(patsubst %.sby,%_cover,$(FORMAL_SBY)) \
		$(patsubst %.sby,%_prove,$(FORMAL_SBY))
