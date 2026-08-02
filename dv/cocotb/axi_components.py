"""pyuvm structural components for the AXI-over-UCIe memory environment."""

from pyuvm import (
    ConfigDB,
    uvm_agent,
    uvm_analysis_port,
    uvm_component,
    uvm_driver,
    uvm_env,
    uvm_get_port,
    uvm_monitor,
    uvm_sequencer,
    uvm_tlm_analysis_fifo,
)

from axi_lite_bfm import AxiLiteBfm
from axi_seq_item import AxiSeqItem


class AxiDriver(uvm_driver):
    def build_phase(self):
        self.bfm = AxiLiteBfm()

    def start_of_simulation_phase(self):
        self.bfm.start_bfms()

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            strb = getattr(item, "strb", 0xF)
            await self.bfm.send_command(item.addr, item.write, item.data, strb)
            rdata, resp = await self.bfm.get_result()
            item.resp = resp
            if not item.write:
                item.rdata = rdata
            self.seq_item_port.item_done()


class AxiMonitor(uvm_monitor):
    def build_phase(self):
        self.bfm = AxiLiteBfm()
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        while True:
            kind, addr, payload, resp = await self.bfm.get_monitored()
            write = (kind == "W")
            tr = AxiSeqItem("mon", addr=addr, data=payload if write else 0,
                            write=write)
            tr.rdata = 0 if write else payload
            tr.resp = resp
            self.logger.info(f"observed {tr}")
            self.ap.write(tr)


class AxiAgent(uvm_agent):
    def build_phase(self):
        self.seqr = uvm_sequencer("seqr", self)
        self.driver = AxiDriver("driver", self)
        self.monitor = AxiMonitor("monitor", self)
        ConfigDB().set(None, "*", "SEQR", self.seqr)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)


class AxiScoreboard(uvm_component):
    """Reference word memory; checks every read against the last write."""

    def build_phase(self):
        self.fifo = uvm_tlm_analysis_fifo("fifo", self)
        self.port = uvm_get_port("port", self)
        self.model = {}
        self.reads = 0
        self.errors = 0

    def connect_phase(self):
        self.port.connect(self.fifo.get_export)

    @property
    def analysis_export(self):
        return self.fifo.analysis_export

    def check_phase(self):
        while self.port.can_get():
            _, tr = self.port.try_get()
            if tr.write:
                self.model[tr.addr] = tr.data
            else:
                self.reads += 1
                expected = self.model.get(tr.addr, 0)
                if tr.rdata != expected:
                    self.errors += 1
                    self.logger.error(
                        f"MISMATCH @0x{tr.addr:05X}: "
                        f"got 0x{tr.rdata:08X} exp 0x{expected:08X}")
                else:
                    self.logger.info(f"MATCH {tr}")
        self.logger.info(
            f"Scoreboard: {self.reads} reads checked, {self.errors} errors")
        assert self.errors == 0, f"{self.errors} scoreboard mismatch(es)"


class AxiEnv(uvm_env):
    def build_phase(self):
        self.agent = AxiAgent("agent", self)
        self.scoreboard = AxiScoreboard("scoreboard", self)

    def connect_phase(self):
        self.agent.monitor.ap.connect(self.scoreboard.analysis_export)
