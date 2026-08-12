"""Stimulus sequences for the AXI-over-UCIe memory."""

import random

from pyuvm import uvm_sequence

from axi_seq_item import (
    AxiSeqItem,
    BURST_FIXED,
    BURST_INCR,
    BURST_WRAP,
    DATA_MASK,
    rand_word_addr,
)


class AxiWriteReadSeq(uvm_sequence):
    """Write a value, then read it back from the same address."""

    def __init__(self, name="AxiWriteReadSeq", num=32):
        super().__init__(name)
        self.num = num

    async def body(self):
        for _ in range(self.num):
            addr = rand_word_addr()
            data = random.randint(0, DATA_MASK)

            wr = AxiSeqItem("wr", addr=addr, data=data, write=True)
            await self.start_item(wr)
            await self.finish_item(wr)

            rd = AxiSeqItem("rd", addr=addr, write=False)
            await self.start_item(rd)
            await self.finish_item(rd)


class AxiRandomSeq(uvm_sequence):
    """Random mix of reads and writes.  Reads are biased 4:1 toward addresses
    that have already been written, so they mostly check stored data instead of
    reading never-written locations (which return 0)."""

    def __init__(self, name="AxiRandomSeq", num=64):
        super().__init__(name)
        self.num = num

    async def body(self):
        written = []
        for _ in range(self.num):
            write = bool(random.getrandbits(1))
            if write:
                item = AxiSeqItem("wr", addr=rand_word_addr(),
                                  data=random.randint(0, DATA_MASK), write=True)
            else:
                if written and random.random() < 4 / 5:
                    addr = random.choice(written)
                else:
                    addr = rand_word_addr()
                item = AxiSeqItem("rd", addr=addr, write=False)
            await self.start_item(item)
            await self.finish_item(item)
            if write:
                written.append(item.addr)


class AxiBurstSeq(uvm_sequence):
    """INCR / WRAP / FIXED bursts of assorted lengths, each written then read
    back.  The burst-aware monitor sequences per-beat addresses, so the shared
    scoreboard checks every beat.  WRAP starts are kept inside a low window and
    away from the wrap boundary; FIXED reuses one address (last write wins)."""

    async def body(self):
        blens = [1, 3, 7, 15]
        # INCR
        for i, length in enumerate(blens):
            addr = 0x2000 + (i << 6)
            beats = [(0xA0000000 + i * 16 + k * 0x11) & DATA_MASK
                     for k in range(length + 1)]
            await self._burst(addr, length, BURST_INCR, beats)
        # WRAP
        for i, length in enumerate(blens):
            addr = (0x100 + i * 4) & ~0x3
            beats = [(0xB0000000 + i * 16 + k * 0x07) & DATA_MASK
                     for k in range(length + 1)]
            await self._burst(addr, length, BURST_WRAP, beats)
        # FIXED (4 beats, same address)
        await self._burst(0x40, 3, BURST_FIXED,
                          [(0xF0000000 + k) & DATA_MASK for k in range(4)])

    async def _burst(self, addr, length, burst, beats):
        wr = AxiSeqItem("wr", addr=addr, write=True,
                        length=length, burst=burst, beats=beats)
        await self.start_item(wr)
        await self.finish_item(wr)
        rd = AxiSeqItem("rd", addr=addr, write=False, length=length, burst=burst)
        await self.start_item(rd)
        await self.finish_item(rd)


class AxiWalkingSeq(uvm_sequence):
    """Directed edge cases: first/last address and all-0 / all-1 / patterned
    payloads."""

    async def body(self):
        from axi_seq_item import ADDR_LIMIT
        edge_addrs = [0x0, 0x4, ADDR_LIMIT - 8, ADDR_LIMIT - 4]
        edge_data = [0x00000000, 0x00000001, 0x55555555,
                     0xAAAAAAAA, 0xFFFFFFFF, 0xDEADBEEF]
        for addr in edge_addrs:
            for data in edge_data:
                wr = AxiSeqItem("wr", addr=addr, data=data, write=True)
                await self.start_item(wr)
                await self.finish_item(wr)
                rd = AxiSeqItem("rd", addr=addr, write=False)
                await self.start_item(rd)
                await self.finish_item(rd)
