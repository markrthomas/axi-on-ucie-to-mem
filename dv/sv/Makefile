# Portable SystemVerilog directed testbench for axi_ucie_mem_top.
# Runs the SAME tb_axi_ucie_mem.sv under Icarus and Verilator.

IVERILOG  ?= iverilog
# Run with the vvp that ships alongside the chosen iverilog (a compiler/runtime
# version mismatch makes vvp reject the compiled .vvp).
VVP       ?= $(shell d=$$(dirname $$(command -v $(IVERILOG) 2>/dev/null) 2>/dev/null); echo $${d:-.}/vvp)
VERILATOR ?= verilator
# Verilator C++ build parallelism.  0 = one job per core (fast on dev/CI); set a
# small value on memory-constrained builders (e.g. containers that see many
# cores but little RAM) so parallel cc1plus don't OOM.  See the Dockerfile.
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
TB  := tb_axi_ucie_mem.sv
TOP := tb_axi_ucie_mem

# Concurrent SVA checkers (bound to the DUT).  Compiled into the Verilator
# --assert flow; the Icarus flow omits them (weak iverilog SVA support).
SVA_DIR := ../sva
SVA := $(SVA_DIR)/axi_lite_sva.sv $(SVA_DIR)/aou_flit_sva.sv \
       $(SVA_DIR)/aou_credit_sva.sv $(SVA_DIR)/bind_sva.sv

PASS_RE := \[SV-TB\] PASS

# Per-beat transaction tracing: when AOU_VERBOSE is set (the repo-root
# `make ... VERBOSE=1` exports it) pass +verbose so the TB prints [SV-TB][T]
# traces.  Works the same under Icarus (vvp) and Verilator (--binary), both of
# which honour $test$plusargs.
PLUSARGS := $(if $(AOU_VERBOSE),+verbose,)

.PHONY: all icarus verilator clean
all: icarus verilator

# --- Icarus ------------------------------------------------------------------
icarus:
	@mkdir -p sim_build
	$(IVERILOG) -g2012 -s $(TOP) -o sim_build/svtb.vvp $(RTL) $(TB)
	@$(VVP) sim_build/svtb.vvp $(PLUSARGS) 2>&1 | tee sim_build/icarus.log
	@grep -q "$(PASS_RE)" sim_build/icarus.log || { echo "[SV] Icarus run FAILED"; exit 1; }
	@echo "[SV] Icarus PASSED"

# --- Verilator (--binary --timing runs the SV TB directly) -------------------
verilator:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[SV] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[SV] Verilator < 5 (no --binary/--timing) — skipping"; exit 0; fi; \
	mkdir -p sim_build; \
	$(VERILATOR) --binary --timing --assert -j $(VL_JOBS) -Wall -Wno-DECLFILENAME \
		-Wno-SYNCASYNCNET -Wno-BLKSEQ \
		--top-module $(TOP) --Mdir obj_dir $(RTL) $(SVA) $(TB) -o vsvtb; \
	./obj_dir/vsvtb $(PLUSARGS) 2>&1 | tee sim_build/verilator.log; \
	grep -q "$(PASS_RE)" sim_build/verilator.log || { echo "[SV] Verilator run FAILED"; exit 1; }; \
	echo "[SV] Verilator PASSED"

clean:
	rm -rf sim_build obj_dir
