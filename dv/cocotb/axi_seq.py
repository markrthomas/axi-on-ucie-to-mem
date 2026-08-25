"""Stimulus sequences for the AXI-over-UCIe memory."""

import random

from pyuvm import uvm_sequence

from axi_coverage import ADDR_REGIONS, ALT_5, LAST_WORD, region_sample_addr
from axi_seq_item import (
    AxiSeqItem,
    BURST_FIXED,
    BURST_INCR,
    BURST_WRAP,
    DATA_MASK,
    SIZE_4B,
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


class AxiMultiReadSeq(uvm_sequence):
    """Multiple-outstanding reads.  Preload known data with ordinary write items,
    then issue several reads (distinct IDs, mixed burst lengths) back-to-back via
    the BFM's read_multi so they fill the initiator request queue; the monitor
    reports every drained beat and the shared scoreboard checks each address."""

    async def body(self):
        from axi_lite_bfm import AxiLiteBfm
        reqs = [
            {"addr": 0x800, "length": 0, "id": 1},
            {"addr": 0x840, "length": 3, "id": 2},
            {"addr": 0x880, "length": 1, "id": 3},
            {"addr": 0x8C0, "length": 7, "id": 4},
            {"addr": 0x900, "length": 0, "id": 5},
        ]
        for r in reqs:
            r["burst"] = BURST_INCR
            r["size"] = SIZE_4B
        # preload each burst's addresses with known data (ordinary write items)
        for i, r in enumerate(reqs):
            beats = [(0xC0000000 + (i << 8) + k * 0x13) & DATA_MASK
                     for k in range(r["length"] + 1)]
            wr = AxiSeqItem("wr", addr=r["addr"], write=True, length=r["length"],
                            burst=BURST_INCR, beats=beats)
            await self.start_item(wr)
            await self.finish_item(wr)
        # issue all reads outstanding at once (fills the queue), then drain
        await AxiLiteBfm().read_multi(reqs)


class AxiWalkingSeq(uvm_sequence):
    """Directed edge cases: first/last address and all-0 / all-1 / patterned
    payloads.  The payload list covers every data-pattern bin of the functional
    coverage model: zero, all-ones, walking-1 (one bit set, at both ends of the
    word), walking-0 (one bit clear, at both ends) and the alternating
    0x5.../0xA... pair."""

    async def body(self):
        from axi_seq_item import ADDR_LIMIT
        edge_addrs = [0x0, 0x4, ADDR_LIMIT - 8, ADDR_LIMIT - 4]
        edge_data = [0x00000000, 0x00000001, 0x80000000,
                     0xFFFFFFFE, 0x7FFFFFFF, 0x55555555,
                     0xAAAAAAAA, 0xFFFFFFFF, 0xDEADBEEF]
        for addr in edge_addrs:
            for data in edge_data:
                wr = AxiSeqItem("wr", addr=addr, data=data, write=True)
                await self.start_item(wr)
                await self.finish_item(wr)
                rd = AxiSeqItem("rd", addr=addr, write=False)
                await self.start_item(rd)
                await self.finish_item(rd)


class AxiCoverageCloseSeq(uvm_sequence):
    """Directed closure stimulus for the functional coverage model.

    Deterministically drives every goal bin in `axi_coverage.py` — both
    directions in every address partition (the direction x region cross), the
    first/last-word boundaries, all payload patterns, all three burst-length
    buckets and both outstanding-depth buckets — so the model closes without
    depending on a random seed.  Address partitions are imported from the
    coverage model, so the stimulus follows the map if the memory depth
    changes."""

    # zero / all-ones / walking-1 / walking-0 / alternating / random-like
    PATTERNS = (0x00000000, DATA_MASK, 0x00000001, DATA_MASK - 1,
                ALT_5, 0xDEADBEEF)

    async def body(self):
        # 1. direction x address region, boundaries, and every data pattern.
        addrs = [region_sample_addr(name) for name, _, _ in ADDR_REGIONS]
        addrs += [0x0, LAST_WORD]            # first-word / last-word boundaries
        for addr in addrs:
            for data in self.PATTERNS:
                wr = AxiSeqItem("wr", addr=addr, data=data, write=True)
                await self.start_item(wr)
                await self.finish_item(wr)
                rd = AxiSeqItem("rd", addr=addr, write=False)
                await self.start_item(rd)
                await self.finish_item(rd)

        # 2. burst-length buckets: 1 beat (above), 2..8 beats, and the 16-beat
        #    maximum, each written then read back through the scoreboard.
        for base, length in ((region_sample_addr("low") + 0x40, 3),
                             (region_sample_addr("mid") + 0x80, 15)):
            beats = [(0x51000000 + (length << 16) + k * 0x0101) & DATA_MASK
                     for k in range(length + 1)]
            wr = AxiSeqItem("wr", addr=base, write=True, length=length,
                            burst=BURST_INCR, beats=beats)
            await self.start_item(wr)
            await self.finish_item(wr)
            rd = AxiSeqItem("rd", addr=base, write=False, length=length,
                            burst=BURST_INCR)
            await self.start_item(rd)
            await self.finish_item(rd)

        # 3. outstanding-depth bucket ">1": preload, then fire several ARs
        #    before draining any R beat so the requests overlap on the bus.
        from axi_lite_bfm import AxiLiteBfm
        base = region_sample_addr("high") & ~0xFF
        reqs = [{"addr": base + 0x00, "length": 0, "id": 1},
                {"addr": base + 0x40, "length": 3, "id": 2},
                {"addr": base + 0x80, "length": 1, "id": 3}]
        for i, r in enumerate(reqs):
            r["burst"] = BURST_INCR
            r["size"] = SIZE_4B
            beats = [(0x5C000000 + (i << 8) + k * 0x17) & DATA_MASK
                     for k in range(r["length"] + 1)]
            wr = AxiSeqItem("wr", addr=r["addr"], write=True, length=r["length"],
                            burst=BURST_INCR, beats=beats)
            await self.start_item(wr)
            await self.finish_item(wr)
        await AxiLiteBfm().read_multi(reqs)
