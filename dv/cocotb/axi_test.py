"""Tests and the cocotb entry points that launch the pyuvm testbench."""

import cocotb

from pyuvm import ConfigDB, uvm_root, uvm_test

from axi_lite_bfm import AxiLiteBfm
from axi_components import AxiEnv
from axi_seq import (
    AxiBurstSeq,
    AxiCoverageCloseSeq,
    AxiMultiReadSeq,
    AxiRandomSeq,
    AxiWalkingSeq,
    AxiWriteReadSeq,
)


class BaseTest(uvm_test):
    """Builds the env and handles clock + reset via the BFM."""

    seq_cls = AxiWriteReadSeq
    # Only the test that runs LAST in `make test-all` gates on the merged
    # functional-coverage database; the others just contribute their bins.
    enforce_fcov = False

    def build_phase(self):
        self.env = AxiEnv("env", self)
        self.env.enforce_fcov = self.enforce_fcov

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


class MultiOutstandingTest(BaseTest):
    seq_cls = AxiMultiReadSeq


class CoverageTest(BaseTest):
    """Functional-coverage closure test.

    Its sequence alone hits every goal bin, so it passes standalone; run last by
    `make test-all` it also gates the merged `[COV-FUNC]` result of the whole
    PyUVM run against the FCOV_MIN floor."""

    seq_cls = AxiCoverageCloseSeq
    enforce_fcov = True


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


@cocotb.test()
async def multi_outstanding_test(_dut):
    await uvm_root().run_test("MultiOutstandingTest")


@cocotb.test()
async def coverage_test(_dut):
    await uvm_root().run_test("CoverageTest")
