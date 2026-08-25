# End-to-end out-of-order-by-ID testbench for axi_ucie_mem_top (OOO_EN=1).
# Runs the SAME tb_axi_ucie_ooo.sv under Icarus and Verilator, exactly like
# dv/sv.  This is the docs/PLAN.md F2 proof environment; the default (OOO_EN=0)
# chain is covered by dv/sv, dv/cocotb and dv/systemc.

IVERILOG  ?= iverilog
VVP       ?= $(shell d=$$(dirname $$(command -v $(IVERILOG) 2>/dev/null) 2>/dev/null); echo $${d:-.}/vvp)
VERILATOR ?= verilator
# Verilator C++ build parallelism.  0 = one job per core; set a small value on
# memory-constrained builders so parallel cc1plus don't OOM.
VL_JOBS ?= 0

RTL_DIR := ../../rtl
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
TB  := tb_axi_ucie_ooo.sv
TOP := tb_axi_ucie_ooo

PASS_RE := \[OOO-TB\] PASS

PLUSARGS := $(if $(AOU_VERBOSE),+verbose,)

.PHONY: all icarus verilator clean
all: icarus verilator

# --- Icarus ------------------------------------------------------------------
icarus:
	@mkdir -p sim_build
	$(IVERILOG) -g2012 -s $(TOP) -o sim_build/ooo.vvp $(RTL) $(TB)
	@$(VVP) sim_build/ooo.vvp $(PLUSARGS) 2>&1 | tee sim_build/icarus.log
	@grep -q "$(PASS_RE)" sim_build/icarus.log || { echo "[OOO] Icarus run FAILED"; exit 1; }
	@echo "[OOO] Icarus PASSED"

# --- Verilator (--binary --timing runs the SV TB directly) -------------------
verilator:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[OOO] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[OOO] Verilator < 5 (no --binary/--timing) — skipping"; exit 0; fi; \
	mkdir -p sim_build; \
	$(VERILATOR) --binary --timing -j $(VL_JOBS) -Wall -Wno-DECLFILENAME \
		-Wno-SYNCASYNCNET -Wno-BLKSEQ \
		--top-module $(TOP) --Mdir obj_dir $(RTL) $(TB) -o vooo; \
	./obj_dir/vooo $(PLUSARGS) 2>&1 | tee sim_build/verilator.log; \
	grep -q "$(PASS_RE)" sim_build/verilator.log || { echo "[OOO] Verilator run FAILED"; exit 1; }; \
	echo "[OOO] Verilator PASSED"

clean:
	rm -rf sim_build obj_dir
