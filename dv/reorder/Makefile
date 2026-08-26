# Per-ID response reorder-buffer unit test (aou_reorder).
# Runs the SAME tb_aou_reorder.sv under Icarus and Verilator.

IVERILOG  ?= iverilog
VVP       ?= $(shell d=$$(dirname $$(command -v $(IVERILOG) 2>/dev/null) 2>/dev/null); echo $${d:-.}/vvp)
VERILATOR ?= verilator
# Verilator C++ build parallelism (0 = one job per core; lower on low-RAM
# builders to keep parallel cc1plus from OOMing — see the Dockerfile).
VL_JOBS ?= 0

RTL := ../../rtl/aou_reorder.sv
TB  := tb_aou_reorder.sv
TOP := tb_aou_reorder

PASS_RE := \[ROB-TB\] PASS

# Shared, DV-only flit decoder + logging helpers (dv/common/), `include`d by the TB.
INC_DIR := ../common

# Debug logging: the repo root exports AOU_VERBOSE=<lvl> for `make ... VERBOSE=
# 1|2` and AOU_LOG_DIR for the per-test log files.  The level rides in as
# +verbose=<lvl> and the log path as +logfile=<path>; Icarus (vvp) and Verilator
# (--binary) both honour $value$plusargs.  With AOU_VERBOSE unset NOTHING is
# passed, so the run stays byte-identical.
AOU_LOG_DIR ?= $(abspath ../../logs)
LOGARGS  = $(if $(AOU_VERBOSE),+verbose=$(AOU_VERBOSE) +logfile=$(AOU_LOG_DIR)/reorder_$(1).log,)
MKLOGDIR = $(if $(AOU_VERBOSE),mkdir -p $(AOU_LOG_DIR),true)

.PHONY: all icarus verilator clean
all: icarus verilator

icarus:
	@mkdir -p sim_build
	$(IVERILOG) -g2012 -I$(INC_DIR) -s $(TOP) -o sim_build/rob.vvp $(RTL) $(TB)
	@$(MKLOGDIR)
	@$(VVP) sim_build/rob.vvp $(call LOGARGS,icarus) 2>&1 | tee sim_build/icarus.log
	@grep -q "$(PASS_RE)" sim_build/icarus.log || { echo "[ROB] Icarus run FAILED"; exit 1; }
	@echo "[ROB] Icarus PASSED"

verilator:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[ROB] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[ROB] Verilator < 5 — skipping"; exit 0; fi; \
	mkdir -p sim_build; $(MKLOGDIR); \
	$(VERILATOR) --binary --timing -j $(VL_JOBS) -Wall -Wno-DECLFILENAME \
		-Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-SYNCASYNCNET \
		+incdir+$(INC_DIR) --top-module $(TOP) --Mdir obj_dir $(RTL) $(TB) -o vrob; \
	./obj_dir/vrob $(call LOGARGS,verilator) 2>&1 | tee sim_build/verilator.log; \
	grep -q "$(PASS_RE)" sim_build/verilator.log || { echo "[ROB] Verilator run FAILED"; exit 1; }; \
	echo "[ROB] Verilator PASSED"

clean:
	rm -rf sim_build obj_dir
