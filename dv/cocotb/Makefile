# cocotb / pyuvm runner for axi_ucie_mem_top (invoked by the repo-root Makefile).
# Select a single test with TESTCASE=<name>; dump waves with WAVES=1.

TOPLEVEL_LANG = verilog
SIM          ?= icarus

RTL_DIR = $(PWD)/../../rtl
# Package first, then leaf modules, then the top.
VERILOG_SOURCES = \
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

TOPLEVEL = axi_ucie_mem_top
MODULE   = axi_test

# Pin the apt Icarus + the cocotb-bound interpreter so the VPI is built against
# the same Python that imports the testbench (avoids the OSS-CAD-Suite mismatch).
ICARUS_BIN_DIR    ?= /usr/bin
export ICARUS_BIN_DIR
SIM_CMD_PREFIX    := env -u VIRTUAL_ENV -u PYTHONHOME
export PYGPI_PYTHON_BIN := $(shell cocotb-config --python-bin)
export PYTHON_BIN       := $(shell cocotb-config --python-bin)

# dv/common holds the shared flit decoder (aou_flit_log.py), the Python mirror
# of dv/common/aou_flit_log.svh used by the VERBOSE=1|2 packet trace.
export PYTHONPATH := $(PWD):$(PWD)/../common:$(PYTHONPATH)

# Per-test debug log location (repo root exports it; keep a default so this
# Makefile also works when invoked directly).
AOU_LOG_DIR ?= $(abspath ../../logs)
export AOU_LOG_DIR

# Icarus needs SystemVerilog turned on explicitly.
COMPILE_ARGS += -g2012

# make WAVES=1  -> dump.fst
ifeq ($(WAVES),1)
    PLUSARGS += -fst
endif

ifdef TESTCASE
export TESTCASE
endif

include $(shell cocotb-config --makefiles)/Makefile.sim
