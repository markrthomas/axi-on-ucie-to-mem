# Verilator UVM flow for the AXI-Lite-over-UCIe (AoU) UVM environment (../, RTL
# in ../../rtl, bound SVA in ../../dv/sva).
#
# Runs the *same* SystemVerilog UVM env as VCS/Xcelium/Questa would, but under
# open-source Verilator (>= 5.050) with the Accellera UVM 2020.3.1 library
# bundled in the Verilator source tree (test_regress/t/uvm).
#
# Quick start (local lint is RAM-safe; the full --binary build belongs in CI):
#   V=~/verilator/bin/verilator ; U=~/verilator/test_regress/t/uvm
#   ( unset VERILATOR_ROOT; make -C uvm/vlt lint       VERILATOR=$V UVM_HOME=$U )
#   ( unset VERILATOR_ROOT; make -C uvm/vlt write_read  VERILATOR=$V UVM_HOME=$U )

VERILATOR ?= verilator

UVM_HOME ?= $(error Set UVM_HOME to the bundled Verilator UVM dir, e.g. \
  ~/verilator/test_regress/t/uvm)
UVM_HDR := $(UVM_HOME)/uvm_pkg_all_v2020_3_1_dpi.svh
UVM_DPI := $(UVM_HOME)/v2020_3_1/dpi/uvm_dpi.cc

BUILD_JOBS ?= 1

VFLAGS ?= --binary --timing --vpi -j $(BUILD_JOBS) --build-jobs $(BUILD_JOBS) \
          -Wno-fatal -Wno-COVERIGN -Wno-TIMESCALEMOD --CFLAGS -O0
# +UVM_TIMEOUT takes a bare integer in the UVM package's time unit (ns here):
# UVM parses it with $sscanf("%d,%s"), so a suffix like "2000us" silently
# truncates to 2000 (= 2 us) and drops the override flag.  2000000 = 2 ms.
UVM_PLUSARGS ?= +UVM_NO_RELNOTES +UVM_TIMEOUT=2000000,NO

VLT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UVM     := $(abspath $(VLT_DIR)/..)
RTL     := $(abspath $(VLT_DIR)/../../rtl)
SVA     := $(abspath $(VLT_DIR)/../../dv/sva)
OBJ     := $(VLT_DIR)/obj

INCS := +incdir+$(UVM) +incdir+$(VLT_DIR) +incdir+$(UVM_HOME)

# Order: interface, RTL (package first, then leaves, then top), bound SVA,
# UVM package (pulls in the env via `include), then the TB top.
SRCS := $(UVM)/axi_lite_if.sv \
        $(RTL)/aou_pkg.sv $(RTL)/ucie_stream_link.sv $(RTL)/aou_activation.sv \
        $(RTL)/axi_lite_mem.sv $(RTL)/aou_reorder.sv $(RTL)/aou_ooo_resp_src.sv \
        $(RTL)/aou_rp_mux.sv $(RTL)/aou_axi_initiator_bridge.sv \
        $(RTL)/aou_axi_target_bridge.sv $(RTL)/axi_ucie_mem_top.sv \
        $(SVA)/axi4_sva.sv $(SVA)/aou_flit_sva.sv $(SVA)/aou_credit_sva.sv \
        $(SVA)/bind_sva.sv \
        $(UVM)/axi_pkg.sv $(UVM)/axi_ucie_tb_top.sv

define build
	rm -rf $(OBJ)/axi_ucie_tb_top
	mkdir -p $(OBJ)/axi_ucie_tb_top
	$(VERILATOR) $(VFLAGS) --top-module axi_ucie_tb_top \
	  --Mdir $(OBJ)/axi_ucie_tb_top $(INCS) $(UVM_HDR) $(UVM_DPI) $(SRCS)
endef
# Hard gate: the sim exits 0 even on UVM_FATAL, so pass only if the report
# summary shows UVM_ERROR == 0 and UVM_FATAL == 0 and the scoreboard reported a
# clean check.
define run
	$(OBJ)/axi_ucie_tb_top/Vaxi_ucie_tb_top $(UVM_PLUSARGS) +UVM_TESTNAME=$(1) \
	  2>&1 | tee $(OBJ)/$(1).log
	@grep -Eq '^UVM_ERROR : +0$$' $(OBJ)/$(1).log && \
	 grep -Eq '^UVM_FATAL : +0$$' $(OBJ)/$(1).log && \
	 grep -Eq '\[SCOREBOARD\] [0-9]+ reads checked, 0 errors' $(OBJ)/$(1).log && \
	 echo "[UVM-VLT] PASS: $(1)" || \
	 { echo "[UVM-VLT] FAIL: $(1) (see $(OBJ)/$(1).log)"; exit 1; }
endef

.PHONY: all build write_read random walking lint clean

all: write_read random walking

build:
	$(build)

write_read: build
	$(call run,axi_write_read_test)
random: build
	$(call run,axi_random_test)
walking: build
	$(call run,axi_walking_test)

LINTFLAGS ?= --lint-only --timing -Wno-fatal -Wno-COVERIGN -Wno-TIMESCALEMOD
lint:
	$(VERILATOR) $(LINTFLAGS) --top-module axi_ucie_tb_top $(INCS) \
	  $(UVM_HDR) $(SRCS)

clean:
	rm -rf $(OBJ)
