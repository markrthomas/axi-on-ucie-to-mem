"""Tests and the cocotb entry points that launch the pyuvm testbench."""

import cocotb

from pyuvm import ConfigDB, uvm_root, uvm_test

from axi_lite_bfm import AxiLiteBfm
from axi_components import AxiEnv
from axi_seq import AxiBurstSeq, AxiRandomSeq, AxiWalkingSeq, AxiWriteReadSeq


class BaseTest(uvm_test):
    """Builds the env and handles clock + reset via the BFM."""

    seq_cls = AxiWriteReadSeq

    def build_phase(self):
        self.env = AxiEnv("env", self)

    async def run_phase(self):
        self.raise_objection()
        bfm = AxiLiteBfm()
        await bfm.start_clock()
        await bfm.reset()

        seqr = ConfigDB().get(self, "", "SEQR")
        seq = self.seq_cls()
        await seq.start(seqr)
        self.drop_objection()


class WriteReadTest(BaseTest):
    seq_cls = AxiWriteReadSeq


class RandomTest(BaseTest):
    seq_cls = AxiRandomSeq


class WalkingTest(BaseTest):
    seq_cls = AxiWalkingSeq


class BurstTest(BaseTest):
    seq_cls = AxiBurstSeq


# -- cocotb entry points ------------------------------------------------------
# TESTCASE (from the Makefile) selects which one runs; default runs all.

@cocotb.test()
async def write_read_test(_dut):
    await uvm_root().run_test("WriteReadTest")


@cocotb.test()
async def random_test(_dut):
    await uvm_root().run_test("RandomTest")


@cocotb.test()
async def walking_test(_dut):
    await uvm_root().run_test("WalkingTest")


@cocotb.test()
async def burst_test(_dut):
    await uvm_root().run_test("BurstTest")
