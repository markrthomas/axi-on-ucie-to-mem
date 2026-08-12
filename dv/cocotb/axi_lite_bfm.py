"""Bus Functional Model: the only layer that touches DUT signals directly.

An AXI4-Lite master for the axi_ucie_mem_top DUT.  pyuvm components stay
simulator-agnostic and talk to this cocotb singleton via async methods and
queues.  Request signals are driven after the clock edge so the DUT samples
clean, race-free values on the following rising edge; handshakes are observed on
the rising edge.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.queue import Queue
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge

from pyuvm import utility_classes

from axi_seq_item import BURST_INCR, SIZE_4B, next_addr


class AxiLiteBfm(metaclass=utility_classes.Singleton):
    def __init__(self):
        self.dut = cocotb.top
        self.driver_queue = Queue()        # command items handed to the driver
        self.result_queue = Queue()        # (rdata, resp) returned to the driver
        self.monitor_queue = Queue()       # completed transfers seen on the bus

    # -- clock / reset --------------------------------------------------------
    async def start_clock(self, period_ns=10):
        cocotb.start_soon(Clock(self.dut.ACLK, period_ns, units="ns").start())

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
            await FallingEdge(d.ACLK)
            d.WVALID.value = 0
            d.WLAST.value = 0

        while d.BVALID.value != 1:
            await RisingEdge(d.ACLK)
        resp = int(d.BRESP.value)
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
        await FallingEdge(d.ACLK)
        d.ARVALID.value = 0

        beats = []
        resp = 0
        for _ in range(length + 1):
            while d.RVALID.value != 1:
                await RisingEdge(d.ACLK)
            beats.append(int(d.RDATA.value))
            resp = int(d.RRESP.value)
            await RisingEdge(d.ACLK)     # beat accepted (RREADY high); advance
        await FallingEdge(d.ACLK)
        d.RREADY.value = 0
        return beats, resp

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

        Single-outstanding DUT, so one pending AW/W/AR is enough to correlate a
        response with its address.  Burst addresses are sequenced with the same
        AXI rule the DUT applies, so each beat is reported at its own address:
        write beats are buffered and flushed on B; read beats are reported live."""
        d = self.dut
        aw_addr = aw_base = aw_len = aw_size = aw_burst = 0
        w_cur = 0
        w_pending = []
        ar_cur = ar_base = ar_len = ar_size = ar_burst = 0
        while True:
            await RisingEdge(d.ACLK)
            if d.ARESETn.value != 1:
                continue
            if d.AWVALID.value == 1 and d.AWREADY.value == 1:
                aw_addr = aw_base = w_cur = int(d.AWADDR.value)
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
                    await self.monitor_queue.put(("W", a, wd, resp))
                w_pending = []
            if d.ARVALID.value == 1 and d.ARREADY.value == 1:
                ar_cur = ar_base = int(d.ARADDR.value)
                ar_len = int(d.ARLEN.value)
                ar_size = int(d.ARSIZE.value)
                ar_burst = int(d.ARBURST.value)
            if d.RVALID.value == 1 and d.RREADY.value == 1:
                await self.monitor_queue.put(
                    ("R", ar_cur, int(d.RDATA.value), int(d.RRESP.value)))
                ar_cur = next_addr(ar_cur, ar_base, ar_burst, ar_size, ar_len)

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
