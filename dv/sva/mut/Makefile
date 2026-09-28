# Assertion mutation tests for dv/sva/axi4_sva.sv (SCAN_ISSUES #4).
#
# Builds tb_axi4_sva_mut once under Verilator --assert, then:
#   * MUT=0            must run clean (exit 0, "[SVA-MUT] PASS");
#   * MUT=1..$(NMUT)   each must FAIL (non-zero exit) and the failing assertion
#                      must be the one the harness names for that mutant.
# A mutant that survives, or fires the wrong property, fails the target.
# Verilator-only (Icarus has no usable concurrent SVA); skips below Verilator 5.

VERILATOR ?= verilator
VL_JOBS   ?= 0
NMUT      := 26

SRC := ../axi4_sva.sv tb_axi4_sva_mut.sv
TOP := tb_axi4_sva_mut

.PHONY: all run clean
all: run

run:
	@if ! command -v $(VERILATOR) >/dev/null 2>&1; then \
		echo "[SVA-MUT] verilator not on PATH — skipping"; exit 0; fi; \
	maj=$$($(VERILATOR) --version 2>/dev/null | grep -oE 'Verilator [0-9]+' | grep -oE '[0-9]+'); \
	if [ -z "$$maj" ] || [ "$$maj" -lt 5 ]; then \
		echo "[SVA-MUT] Verilator < 5 (no --binary/--timing) — skipping"; exit 0; fi; \
	mkdir -p sim_build; \
	$(VERILATOR) --binary --timing --assert -j $(VL_JOBS) -Wall -Wno-DECLFILENAME \
		-Wno-BLKSEQ --top-module $(TOP) --Mdir obj_dir $(SRC) -o vmut >sim_build/build.log 2>&1 \
		|| { cat sim_build/build.log; echo "[SVA-MUT] build FAILED"; exit 1; }; \
	fail=0; \
	if ./obj_dir/vmut +MUT=0 >sim_build/mut0.log 2>&1 && grep -q "\[SVA-MUT\] PASS" sim_build/mut0.log \
	   && ! grep -q "Assertion failed" sim_build/mut0.log; then \
		echo "[SVA-MUT] MUT=0  clean run passes"; \
	else cat sim_build/mut0.log; echo "[SVA-MUT] MUT=0 clean run FAILED"; fail=1; fi; \
	for m in $$(seq 1 $(NMUT)); do \
		log=sim_build/mut$$m.log; \
		if ./obj_dir/vmut +MUT=$$m >$$log 2>&1; then rc=0; else rc=$$?; fi; \
		exp=$$(sed -n 's/^\[SVA-MUT\] MUT=[0-9]* expect //p' $$log); \
		if [ $$rc -ne 0 ] && grep -q "u_chk\.$$exp:" $$log \
		   && grep -q "Assertion failed" $$log; then \
			printf '[SVA-MUT] MUT=%-2s killed by %s\n' $$m "$$exp"; \
		else cat $$log; echo "[SVA-MUT] MUT=$$m SURVIVED (expected $$exp to fire)"; fail=1; fi; \
	done; \
	[ $$fail -eq 0 ] || { echo "[SVA-MUT] FAILED"; exit 1; }; \
	echo "[SVA-MUT] PASS: $(NMUT)/$(NMUT) mutants killed by the expected assertion, clean run passes"

clean:
	rm -rf obj_dir sim_build
