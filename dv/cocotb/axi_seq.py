"""Stimulus sequences for the AXI-over-UCIe memory."""

import random

from pyuvm import uvm_sequence

from axi_seq_item import AxiSeqItem, DATA_MASK, rand_word_addr


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
