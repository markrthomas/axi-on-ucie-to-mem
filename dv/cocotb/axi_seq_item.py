"""AXI4-Lite transaction object shared by sequences, driver, monitor, scoreboard.

The DUT is an AXI-Lite-over-UCIe bridge to a 32-bit word memory, so transfers are
word-aligned 32-bit accesses within the memory's address space.
"""

import random

from pyuvm import uvm_sequence_item

MEM_ADDR_W = 16                      # DUT memory byte-address width (64 KiB)
ADDR_LIMIT = 1 << MEM_ADDR_W         # 0x10000
DATA_MASK = 0xFFFFFFFF               # 32-bit word
WORD_ADDRS = ADDR_LIMIT // 4         # number of word locations


# AxBURST encodings.
BURST_FIXED = 0
BURST_INCR = 1
BURST_WRAP = 2
SIZE_4B = 2                          # AxSIZE for a 32-bit (4-byte) beat


def rand_word_addr():
    """A random word-aligned byte address inside the memory."""
    return random.randrange(0, WORD_ADDRS) * 4


def next_addr(a, base, burst, size, length):
    """Independent copy of the AXI next-beat address rule (mirrors the DUT's
    axi_burst_next and the SV/SystemC testbenches)."""
    nbytes = 1 << size
    if burst == BURST_FIXED:
        return a
    if burst == BURST_WRAP:
        total = (length + 1) << size
        low = base & ~(total - 1)
        return low if (a + nbytes) == (low + total) else (a + nbytes)
    return a + nbytes                # INCR


class AxiSeqItem(uvm_sequence_item):
    """An AXI4 read or write transfer of one or more beats.

    Single-beat (AXI-Lite-style) transfers leave length=0/burst=INCR.  Burst
    transfers set length (AxLEN, beats-1), burst (AxBURST), and — for writes —
    a `beats` list of per-beat WDATA (falling back to `data` for a single beat)."""

    def __init__(self, name="AxiSeqItem", addr=0, data=0, write=True,
                 length=0, burst=BURST_INCR, size=SIZE_4B, beats=None):
        super().__init__(name)
        self.addr = addr & (ADDR_LIMIT - 1) & ~0x3   # word aligned
        self.data = data & DATA_MASK                 # single-beat payload (WDATA)
        self.write = write                           # True -> write, False -> read
        self.length = length                         # AxLEN (beats - 1)
        self.burst = burst                           # AxBURST
        self.size = size                             # AxSIZE
        self.beats = beats                           # per-beat WDATA list (writes)
        self.rdata = 0                               # captured read data (RDATA)
        self.rbeats = []                             # captured per-beat RDATA
        self.resp = 0                                # BRESP / RRESP
        self.outstanding = 1                         # open transfers (monitor)

    def __eq__(self, other):
        if not isinstance(other, AxiSeqItem):
            return NotImplemented
        payload = self.data if self.write else self.rdata
        other_payload = other.data if other.write else other.rdata
        return (self.write, self.addr, payload) == \
               (other.write, other.addr, other_payload)

    def __str__(self):
        kind = "WR" if self.write else "RD"
        payload = self.data if self.write else self.rdata
        return f"{kind} @0x{self.addr:05X} = 0x{payload:08X}"
