# §8 activation FSM unit test (aou_pkg + aou_activation).
# Runs the SAME tb_aou_act.sv under Icarus and Verilator.

IVERILOG  ?= iverilog
VVP       ?= $(shell d=$$(dirname $$(command -v $(IVERILOG) 2>/dev/null) 2>/dev/null); echo $${d:-.}/vvp)
VERILATOR ?= verilator

RTL := ../../rtl/aou_pkg.sv ../../rtl/aou_activation.sv
TB  := tb_aou_act.sv
TOP := tb_aou_act

PASS_RE := \[ACT-TB\] PASS

.PHONY: all icarus verilator clean
all: icarus verilator

icarus:
	@mkdir -p sim_build
	$(IVERILOG) -g2012 -s $(TOP) -o sim_build/act.vvp $(RTL) $(TB)
	@$(VVP) sim_build/act.vvp 2>&1 | tee sim_build/icarus.log
	@grep -q "$(PASS_RE)" sim_build/icarus.log || { echo "[ACT] Icarus run FAILED"; exit 1; }
	@echo "[ACT] Icarus PASSED"

verilator:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[ACT] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[ACT] Verilator < 5 — skipping"; exit 0; fi; \
	mkdir -p sim_build; \
	$(VERILATOR) --binary --timing -j 0 -Wall -Wno-DECLFILENAME \
		-Wno-UNUSEDSIGNAL -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-PROCASSINIT \
		--top-module $(TOP) --Mdir obj_dir $(RTL) $(TB) -o vact; \
	./obj_dir/vact 2>&1 | tee sim_build/verilator.log; \
	grep -q "$(PASS_RE)" sim_build/verilator.log || { echo "[ACT] Verilator run FAILED"; exit 1; }; \
	echo "[ACT] Verilator PASSED"

clean:
	rm -rf sim_build obj_dir
