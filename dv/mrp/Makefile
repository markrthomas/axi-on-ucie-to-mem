# End-to-end MULTIPLE-RESOURCE-PLANE testbench for axi_ucie_mem_top (NUM_RP=2).
# Runs the SAME tb_axi_ucie_mrp.sv under Icarus and Verilator, exactly like
# dv/sv and dv/ooo.  This is the docs/PLAN.md F1 proof environment; the default
# single-plane (NUM_RP=1) chain is covered by dv/sv, dv/cocotb and dv/systemc.
#
# The Verilator run additionally binds the concurrent SVA checkers through
# dv/sva/bind_mrp_sva.sv: aou_flit_sva with NUM_RP=2 (so the §4.3 FDId and the
# Table-16 MsgCredit RP subfield are bounded to the ACTIVE planes rather than
# RP0-only), aou_rp_sva (per-plane routing / no silent drop), aou_credit_sva on
# each plane's bridges, and axi_lite_sva on each plane's AXI front door.

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
TB  := tb_axi_ucie_mrp.sv
TOP := tb_axi_ucie_mrp

SVA_DIR := ../sva
SVA := $(SVA_DIR)/axi_lite_sva.sv $(SVA_DIR)/aou_flit_sva.sv \
       $(SVA_DIR)/aou_credit_sva.sv $(SVA_DIR)/aou_rp_sva.sv \
       $(SVA_DIR)/bind_mrp_sva.sv

PASS_RE := \[MRP-TB\] PASS

PLUSARGS := $(if $(AOU_VERBOSE),+verbose,)

.PHONY: all icarus verilator clean
all: icarus verilator

# --- Icarus ------------------------------------------------------------------
icarus:
	@mkdir -p sim_build
	$(IVERILOG) -g2012 -s $(TOP) -o sim_build/mrp.vvp $(RTL) $(TB)
	@$(VVP) sim_build/mrp.vvp $(PLUSARGS) 2>&1 | tee sim_build/icarus.log
	@grep -q "$(PASS_RE)" sim_build/icarus.log || { echo "[MRP] Icarus run FAILED"; exit 1; }
	@echo "[MRP] Icarus PASSED"

# --- Verilator (--binary --timing runs the SV TB directly, + bound SVA) ------
verilator:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[MRP] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[MRP] Verilator < 5 (no --binary/--timing) — skipping"; exit 0; fi; \
	mkdir -p sim_build; \
	$(VERILATOR) --binary --timing --assert -j $(VL_JOBS) -Wall -Wno-DECLFILENAME \
		-Wno-SYNCASYNCNET -Wno-BLKSEQ \
		--top-module $(TOP) --Mdir obj_dir $(RTL) $(SVA) $(TB) -o vmrp; \
	./obj_dir/vmrp $(PLUSARGS) 2>&1 | tee sim_build/verilator.log; \
	grep -q "$(PASS_RE)" sim_build/verilator.log || { echo "[MRP] Verilator run FAILED"; exit 1; }; \
	echo "[MRP] Verilator PASSED"

clean:
	rm -rf sim_build obj_dir
