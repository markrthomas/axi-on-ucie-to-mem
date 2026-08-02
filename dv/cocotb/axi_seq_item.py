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


def rand_word_addr():
    """A random word-aligned byte address inside the memory."""
    return random.randrange(0, WORD_ADDRS) * 4


class AxiSeqItem(uvm_sequence_item):
    """A single AXI4-Lite read or write transfer."""

    def __init__(self, name="AxiSeqItem", addr=0, data=0, write=True):
        super().__init__(name)
        self.addr = addr & (ADDR_LIMIT - 1) & ~0x3   # word aligned
        self.data = data & DATA_MASK                 # write payload (WDATA)
        self.write = write                           # True -> write, False -> read
        self.rdata = 0                               # captured read data (RDATA)
        self.resp = 0                                # BRESP / RRESP

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
