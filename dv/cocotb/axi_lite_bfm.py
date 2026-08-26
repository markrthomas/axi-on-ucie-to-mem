"""Bus Functional Model: the only layer that touches DUT signals directly.

An AXI4-Lite master for the axi_ucie_mem_top DUT.  pyuvm components stay
simulator-agnostic and talk to this cocotb singleton via async methods and
queues.  Request signals are driven after the clock edge so the DUT samples
clean, race-free values on the following rising edge; handshakes are observed on
the rising edge.
"""

import logging
import os

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from pyuvm import utility_classes

import aou_debug
from axi_seq_item import BURST_INCR, SIZE_4B, next_addr


class AxiLiteBfm(metaclass=utility_classes.Singleton):
    def __init__(self):
        self.dut = cocotb.top
        self.driver_queue = Queue()        # command items handed to the driver
        self.result_queue = Queue()        # (rdata, resp) returned to the driver
        self.monitor_queue = Queue()       # completed transfers seen on the bus
        # Opt-in per-beat transaction tracing.  Level >= 1 (the repo-root
        # `make ... VERBOSE=1|2` exports AOU_VERBOSE) raises this BFM's logger to
        # DEBUG so every AW/W/B/AR/R beat is logged with sim time, and routes it
        # into the per-test log file alongside the decoded-flit trace; level 0
        # (default) leaves the log unchanged.
        self.log = logging.getLogger("axi.bfm")
        if aou_debug.level() >= 1:
            self.log.setLevel(logging.DEBUG)
            aou_debug.get_logger()
            self.log.debug("verbose transaction tracing enabled")

    # -- clock / reset --------------------------------------------------------
    async def start_clock(self, period_ns=10):
        cocotb.start_soon(Clock(self.dut.ACLK, period_ns, units="ns").start())
        # Decoded-flit (level 1) and internal-state (level 2) monitors; a no-op
        # at the default VERBOSE=0, so nothing is started and nothing is logged.
        aou_debug.start(self.dut)

    async def reset(self):
        d = self.dut
        d.ARESETn.value = 0
        for sig in ("AWVALID", "WVALID", "BREADY", "ARVALID", "RREADY",
                    "AWID", "AWADDR", "AWLEN", "AWSIZE", "AWBURST", "AWPROT",
                    "WDATA", "WSTRB", "WLAST",
                    "ARID", "ARADDR", "ARLEN", "ARSIZE", "ARBURST", "ARPROT"):
            getattr(d, sig).value = 0
        await ClockCycles(d.ACLK, 3)
        await FallingEdge(d.ACLK)
        d.ARESETn.value = 1
        await RisingEdge(d.ACLK)

    # -- primitive AXI4 transfers (single- or multi-beat) ---------------------
    async def _wburst(self, addr, beats, strb, length, burst, size):
        """Write burst: present AW, stream len+1 W beats, collect the B response."""
        d = self.dut
        await FallingEdge(d.ACLK)
        d.AWID.value = 0
        d.AWADDR.value = addr
        d.AWLEN.value = length
        d.AWSIZE.value = size
        d.AWBURST.value = burst
        d.AWPROT.value = 0
        d.AWVALID.value = 1
        d.BREADY.value = 1

        while True:
            await RisingEdge(d.ACLK)
            if d.AWREADY.value == 1:
                break
        self.log.debug("AW  addr=0x%05X len=%d burst=%d", addr, length, burst)
        await FallingEdge(d.ACLK)
        d.AWVALID.value = 0

        for k, beat in enumerate(beats):
            d.WDATA.value = beat
            d.WSTRB.value = strb
            d.WLAST.value = 1 if k == length else 0
            d.WVALID.value = 1
            while True:
                await RisingEdge(d.ACLK)
                if d.WREADY.value == 1:
                    break
            self.log.debug("W   beat %d data=0x%08X last=%d",
                           k, beat, 1 if k == length else 0)
            await FallingEdge(d.ACLK)
            d.WVALID.value = 0
            d.WLAST.value = 0

        while d.BVALID.value != 1:
            await RisingEdge(d.ACLK)
        resp = int(d.BRESP.value)
        self.log.debug("B   resp=%d", resp)
        await FallingEdge(d.ACLK)
        d.BREADY.value = 0
        return resp

    async def _rburst(self, addr, length, burst, size):
        """Read burst: present AR, consume len+1 R beats, return the data list."""
        d = self.dut
        await FallingEdge(d.ACLK)
        d.ARID.value = 0
        d.ARADDR.value = addr
        d.ARLEN.value = length
        d.ARSIZE.value = size
        d.ARBURST.value = burst
        d.ARPROT.value = 0
        d.ARVALID.value = 1
        d.RREADY.value = 1

        while True:
            await RisingEdge(d.ACLK)
            if d.ARREADY.value == 1:
                break
        self.log.debug("AR  addr=0x%05X len=%d burst=%d", addr, length, burst)
        await FallingEdge(d.ACLK)
        d.ARVALID.value = 0

        beats = []
        resp = 0
        for k in range(length + 1):
            while d.RVALID.value != 1:
                await RisingEdge(d.ACLK)
            beats.append(int(d.RDATA.value))
            resp = int(d.RRESP.value)
            self.log.debug("R   beat %d data=0x%08X resp=%d id=%d last=%d",
                           k, int(d.RDATA.value), resp, int(d.RID.value),
                           int(d.RLAST.value))
            await RisingEdge(d.ACLK)     # beat accepted (RREADY high); advance
        await FallingEdge(d.ACLK)
        d.RREADY.value = 0
        return beats, resp

    async def read_multi(self, reqs):
        """Multiple-outstanding reads: fire every AR handshake with RREADY held
        low so the requests pile into the initiator queue (up to full), then
        drain all beats in issue order.  The monitor reports each beat to the
        scoreboard; correctness is checked there.  len(reqs) must be <= the
        initiator REQ_QD + 1 to avoid stalling.  Each req: dict(addr, length,
        burst, size, id)."""
        d = self.dut
        d.RREADY.value = 0
        for r in reqs:                             # phase 1: queue AR handshakes
            await FallingEdge(d.ACLK)
            d.ARID.value = r.get("id", 0)
            d.ARADDR.value = r["addr"]
            d.ARLEN.value = r["length"]
            d.ARSIZE.value = r["size"]
            d.ARBURST.value = r["burst"]
            d.ARPROT.value = 0
            d.ARVALID.value = 1
            while True:
                await RisingEdge(d.ACLK)
                if d.ARREADY.value == 1:
                    break
            self.log.debug("AR  (mo) id=%d addr=0x%05X len=%d",
                           r.get("id", 0), r["addr"], r["length"])
            await FallingEdge(d.ACLK)
            d.ARVALID.value = 0
        d.RREADY.value = 1                         # phase 2: drain in issue order
        remaining = sum(r["length"] + 1 for r in reqs)
        while remaining > 0:
            await RisingEdge(d.ACLK)
            if d.RVALID.value == 1 and d.RREADY.value == 1:
                self.log.debug("R   (mo) data=0x%08X id=%d last=%d",
                               int(d.RDATA.value), int(d.RID.value),
                               int(d.RLAST.value))
                remaining -= 1
        await FallingEdge(d.ACLK)
        d.RREADY.value = 0
        await ClockCycles(d.ACLK, 5)   # let the monitor drain the last beats

    # -- coroutines started by the pyuvm components ---------------------------
    async def driver_bfm(self):
        """Serialise sequencer commands onto the bus, one transfer (burst) at a
        time (the DUT is single-outstanding)."""
        while True:
            cmd = await self.driver_queue.get()
            if cmd["write"]:
                resp = await self._wburst(cmd["addr"], cmd["beats"], cmd["strb"],
                                          cmd["length"], cmd["burst"], cmd["size"])
                await self.result_queue.put(([], resp))
            else:
                beats, resp = await self._rburst(cmd["addr"], cmd["length"],
                                                 cmd["burst"], cmd["size"])
                await self.result_queue.put((beats, resp))

    async def monitor_bfm(self):
        """Record every completed transfer by watching the five AXI channels.

        Writes stay single-outstanding (one pending AW/W set), so a single write
        context is enough.  Reads may be multiple-outstanding: AR contexts are
        held in an in-order FIFO and each R beat is attributed to the oldest open
        read (in-order completion), so overlapping bursts are reported at their
        own addresses.  Burst addresses are sequenced with the same AXI rule the
        DUT applies; write beats are buffered and flushed on B, reads reported
        live.

        Each report is (kind, addr, payload, resp, length, outstanding), where
        `length` is the observed AxLEN of the owning transfer and `outstanding`
        is how many transfers were open on the bus when the beat completed — both
        read off the monitored interface for the functional coverage model."""
        d = self.dut
        aw_base = aw_len = aw_size = aw_burst = 0
        w_cur = 0
        w_pending = []
        ar_q = []                 # FIFO of open reads: [cur, base, len, sz, bt, rem]
        while True:
            await RisingEdge(d.ACLK)
            if d.ARESETn.value != 1:
                continue
            if d.AWVALID.value == 1 and d.AWREADY.value == 1:
                aw_base = w_cur = int(d.AWADDR.value)
                aw_len = int(d.AWLEN.value)
                aw_size = int(d.AWSIZE.value)
                aw_burst = int(d.AWBURST.value)
                w_pending = []
            if d.WVALID.value == 1 and d.WREADY.value == 1:
                w_pending.append((w_cur, int(d.WDATA.value)))
                w_cur = next_addr(w_cur, aw_base, aw_burst, aw_size, aw_len)
            if d.BVALID.value == 1 and d.BREADY.value == 1:
                resp = int(d.BRESP.value)
                for a, wd in w_pending:
                    await self.monitor_queue.put(("W", a, wd, resp, aw_len, 1))
                w_pending = []
            if d.ARVALID.value == 1 and d.ARREADY.value == 1:
                base = int(d.ARADDR.value)
                ln = int(d.ARLEN.value)
                ar_q.append([base, base, ln, int(d.ARSIZE.value),
                             int(d.ARBURST.value), ln + 1])
            if d.RVALID.value == 1 and d.RREADY.value == 1 and ar_q:
                ctx = ar_q[0]
                await self.monitor_queue.put(
                    ("R", ctx[0], int(d.RDATA.value), int(d.RRESP.value),
                     ctx[2], len(ar_q)))
                ctx[0] = next_addr(ctx[0], ctx[1], ctx[4], ctx[3], ctx[2])
                ctx[5] -= 1
                if ctx[5] == 0:
                    ar_q.pop(0)

    # -- driver-facing helpers ------------------------------------------------
    async def send_command(self, addr, write, wdata, strb=0xF,
                           length=0, burst=BURST_INCR, size=SIZE_4B, beats=None):
        if beats is None:
            beats = [wdata]
        await self.driver_queue.put({"addr": addr, "write": write, "strb": strb,
                                     "length": length, "burst": burst,
                                     "size": size, "beats": beats})

    async def get_result(self):
        return await self.result_queue.get()

    async def get_monitored(self):
        return await self.monitor_queue.get()

    def start_bfms(self):
        cocotb.start_soon(self.driver_bfm())
        cocotb.start_soon(self.monitor_bfm())
