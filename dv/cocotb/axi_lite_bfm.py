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
                    "AWADDR", "AWPROT", "WDATA", "WSTRB", "ARADDR", "ARPROT"):
            getattr(d, sig).value = 0
        await ClockCycles(d.ACLK, 3)
        await FallingEdge(d.ACLK)
        d.ARESETn.value = 1
        await RisingEdge(d.ACLK)

    # -- primitive AXI4-Lite transfers ---------------------------------------
    async def _write(self, addr, data, strb=0xF):
        d = self.dut
        await FallingEdge(d.ACLK)
        d.AWADDR.value = addr
        d.AWPROT.value = 0
        d.AWVALID.value = 1
        d.WDATA.value = data
        d.WSTRB.value = strb
        d.WVALID.value = 1
        d.BREADY.value = 1

        aw_done = w_done = False
        while not (aw_done and w_done):
            await RisingEdge(d.ACLK)
            if not aw_done and d.AWREADY.value == 1:
                aw_done = True
            if not w_done and d.WREADY.value == 1:
                w_done = True
            await FallingEdge(d.ACLK)
            if aw_done:
                d.AWVALID.value = 0
            if w_done:
                d.WVALID.value = 0

        while d.BVALID.value != 1:
            await RisingEdge(d.ACLK)
        resp = int(d.BRESP.value)
        await FallingEdge(d.ACLK)
        d.BREADY.value = 0
        return 0, resp

    async def _read(self, addr):
        d = self.dut
        await FallingEdge(d.ACLK)
        d.ARADDR.value = addr
        d.ARPROT.value = 0
        d.ARVALID.value = 1
        d.RREADY.value = 1

        while True:
            await RisingEdge(d.ACLK)
            if d.ARREADY.value == 1:
                break
        await FallingEdge(d.ACLK)
        d.ARVALID.value = 0

        while d.RVALID.value != 1:
            await RisingEdge(d.ACLK)
        rdata = int(d.RDATA.value)
        resp = int(d.RRESP.value)
        await FallingEdge(d.ACLK)
        d.RREADY.value = 0
        return rdata, resp

    # -- coroutines started by the pyuvm components ---------------------------
    async def driver_bfm(self):
        """Serialise sequencer commands onto the bus, one transfer at a time."""
        while True:
            addr, write, wdata, strb = await self.driver_queue.get()
            if write:
                rdata, resp = await self._write(addr, wdata, strb)
            else:
                rdata, resp = await self._read(addr)
            await self.result_queue.put((rdata, resp))

    async def monitor_bfm(self):
        """Record every completed transfer by watching the five AXI channels.

        Single-outstanding DUT, so one pending AW/W/AR is enough to correlate a
        response with its address."""
        d = self.dut
        aw_addr = w_data = ar_addr = 0
        while True:
            await RisingEdge(d.ACLK)
            if d.ARESETn.value != 1:
                continue
            if d.AWVALID.value == 1 and d.AWREADY.value == 1:
                aw_addr = int(d.AWADDR.value)
            if d.WVALID.value == 1 and d.WREADY.value == 1:
                w_data = int(d.WDATA.value)
            if d.BVALID.value == 1 and d.BREADY.value == 1:
                await self.monitor_queue.put(("W", aw_addr, w_data, int(d.BRESP.value)))
            if d.ARVALID.value == 1 and d.ARREADY.value == 1:
                ar_addr = int(d.ARADDR.value)
            if d.RVALID.value == 1 and d.RREADY.value == 1:
                await self.monitor_queue.put(("R", ar_addr, int(d.RDATA.value), int(d.RRESP.value)))

    # -- driver-facing helpers ------------------------------------------------
    async def send_command(self, addr, write, wdata, strb=0xF):
        await self.driver_queue.put((addr, write, wdata, strb))

    async def get_result(self):
        return await self.result_queue.get()

    async def get_monitored(self):
        return await self.monitor_queue.get()

    def start_bfms(self):
        cocotb.start_soon(self.driver_bfm())
        cocotb.start_soon(self.monitor_bfm())
