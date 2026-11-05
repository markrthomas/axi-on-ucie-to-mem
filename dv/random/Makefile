# Random-regression sim build (Verilator --binary --timing, bound SVA via --assert).
# Built ONCE (make rr-build); every job reuses obj_dir/vrr with different plusargs.
VERILATOR ?= verilator
# Verilator C++ build parallelism. 2 = safe on memory-limited cloud builders
# (many cores, little RAM => parallel cc1plus OOM). Raise on a big dev box.
VL_JOBS   ?= 2
RTL_DIR := ../../rtl
SVA_DIR := ../sva
RTL := $(addprefix $(RTL_DIR)/,aou_pkg.sv ucie_stream_link.sv aou_activation.sv axi_lite_mem.sv \
        aou_reorder.sv aou_ooo_resp_src.sv aou_rp_mux.sv aou_axi_initiator_bridge.sv \
        aou_axi_target_bridge.sv axi_ucie_mem_top.sv)
SVA := $(SVA_DIR)/axi4_sva.sv $(SVA_DIR)/aou_flit_sva.sv $(SVA_DIR)/aou_credit_sva.sv $(SVA_DIR)/bind_sva.sv

.PHONY: build clean
build: obj_dir/vrr
obj_dir/vrr: $(RTL) $(SVA) tb_rr.sv
	$(VERILATOR) --binary --timing --assert -j $(VL_JOBS) -Wno-fatal -Wno-lint -Wno-style \
		--top-module tb_rr --Mdir obj_dir $(RTL) $(SVA) tb_rr.sv -o vrr
clean:
	rm -rf obj_dir runs
