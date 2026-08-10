# §4.3/§5.8 byte-exact packing conformance test (aou_pkg only).
# Runs the SAME tb_aou_pack.sv under Icarus and Verilator.

IVERILOG  ?= iverilog
VVP       ?= $(shell d=$$(dirname $$(command -v $(IVERILOG) 2>/dev/null) 2>/dev/null); echo $${d:-.}/vvp)
VERILATOR ?= verilator

PKG := ../../rtl/aou_pkg.sv
TB  := tb_aou_pack.sv
TOP := tb_aou_pack

PASS_RE := \[PACK-TB\] PASS

.PHONY: all icarus verilator clean
all: icarus verilator

icarus:
	@mkdir -p sim_build
	$(IVERILOG) -g2012 -s $(TOP) -o sim_build/pack.vvp $(PKG) $(TB)
	@$(VVP) sim_build/pack.vvp 2>&1 | tee sim_build/icarus.log
	@grep -q "$(PASS_RE)" sim_build/icarus.log || { echo "[PACK] Icarus run FAILED"; exit 1; }
	@echo "[PACK] Icarus PASSED"

verilator:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[PACK] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[PACK] Verilator < 5 — skipping"; exit 0; fi; \
	mkdir -p sim_build; \
	$(VERILATOR) --binary --timing -j 0 -Wall -Wno-DECLFILENAME \
		-Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD \
		--top-module $(TOP) --Mdir obj_dir $(PKG) $(TB) -o vpack; \
	./obj_dir/vpack 2>&1 | tee sim_build/verilator.log; \
	grep -q "$(PASS_RE)" sim_build/verilator.log || { echo "[PACK] Verilator run FAILED"; exit 1; }; \
	echo "[PACK] Verilator PASSED"

clean:
	rm -rf sim_build obj_dir
