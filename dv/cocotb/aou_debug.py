"""VERBOSE=0|1|2 debug logging for the cocotb/pyuvm environment.

The cocotb half of the repo-wide logging facility (see README "Debug logging"
and dv/common/aou_log.svh for the SystemVerilog half).  One knob, three levels,
identical everywhere:

  0  off      — DEFAULT.  Nothing is configured, no monitor coroutine is
                started, no handler is attached: the run is byte-identical.
  1  packet   — a decoded [COCOTB][F] line per AoU flit crossing either UCIe
                link (rendered by dv/common/aou_flit_log.py, the mirror of the
                SV/SystemC decoders) plus the BFM's per-beat AXI trace.
  2  debug    — level 1 plus [COCOTB][D] internal DUT state: the §8 activation
                FSMs, the bridge FSMs, the §6 credit counters and the initiator
                request-queue occupancy.

Everything here is passive: it only READS signals the DUT already drives, via
cocotb's hierarchy handles, so no RTL edit is needed and the datapath is
untouched.
"""

import logging
import os

import cocotb
from cocotb.triggers import RisingEdge
from cocotb.utils import get_sim_time

from aou_flit_log import decode_flit

TAG = "[COCOTB]"

# rtl/aou_axi_initiator_bridge.sv state_e / rtl/aou_axi_target_bridge.sv state_e
# / rtl/aou_activation.sv act_e — kept in step with aou_flit_log.svh.
INIT_STATE = ("S_IDLE", "S_WREQ", "S_WDATA", "S_WWAIT", "S_B", "S_RREQ", "S_RDATA")
TGT_STATE = ("S_IDLE", "S_WBEAT", "S_WRESP", "S_RBEAT")
ACT_STATE = ("ACT_DISABLED", "ACT_ACTIVATE", "ACT_ENABLED", "ACT_DEACTIVATE",
             "ACT_ERROR")


def level():
    """The active verbosity level (0/1/2) from AOU_VERBOSE."""
    v = os.environ.get("AOU_VERBOSE", "")
    if not v:
        return 0
    try:
        return max(0, int(v))
    except ValueError:
        return 1          # a bare/legacy truthy value means "verbose"


def log_path():
    """logs/cocotb[_<test>].log — the per-test file this run writes."""
    d = os.environ.get("AOU_LOG_DIR") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "logs")
    test = os.environ.get("TESTCASE", "")
    name = "cocotb_%s.log" % test if test else "cocotb.log"
    return os.path.abspath(os.path.join(d, name))


_log = None


def get_logger():
    """The "aou.dbg" logger, with a FileHandler attached on first use.

    Only ever called at level >= 1, so at VERBOSE=0 no handler is created and
    no file appears.
    """
    global _log
    if _log is not None:
        return _log
    _log = logging.getLogger("aou.dbg")
    _log.setLevel(logging.DEBUG)
    path = log_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fh = logging.FileHandler(path, mode="w")
        fh.setFormatter(logging.Formatter("%(message)s"))
        _log.addHandler(fh)
        # The BFM's per-beat AXI trace belongs in the same file.
        bfm = logging.getLogger("axi.bfm")
        bfm.addHandler(fh)
        _log.info("%s[V] verbose level %d, log file '%s'", TAG, level(), path)
    except OSError as exc:                     # pragma: no cover - diagnostic
        _log.warning("%s[V] cannot open log file '%s': %s", TAG, path, exc)
    return _log


def _t():
    return int(get_sim_time("ns"))


def _emit(line):
    """Verbose lines go to stdout (as the pre-existing trace did) and the file."""
    get_logger().info(line)


def _val(handle):
    """int() of a signal, or None while it is X/Z (e.g. during reset)."""
    try:
        return int(handle.value)
    except Exception:                          # unresolvable or missing
        return None


def _find(dut, path):
    """Resolve a dotted hierarchy path under `dut`, or None if unreachable."""
    obj = dut
    for part in path.split("."):
        try:
            obj = getattr(obj, part)
        except Exception:
            return None
    return obj


async def flit_monitor(dut):
    """Level 1: decode every flit crossing the A<->B link pair."""
    lvl = level()
    if lvl < 1:
        return
    tx_v = _find(dut, "g_rp1.init_tx_valid")
    tx_r = _find(dut, "g_rp1.init_tx_ready")
    tx_d = _find(dut, "g_rp1.init_tx_data")
    rx_v = _find(dut, "g_rp1.init_rx_valid")
    rx_r = _find(dut, "g_rp1.init_rx_ready")
    rx_d = _find(dut, "g_rp1.init_rx_data")
    if None in (tx_v, tx_r, tx_d, rx_v, rx_r, rx_d):
        _emit("%s[V] flit signals unreachable — skipping packet trace" % TAG)
        return
    clk = dut.ACLK
    while True:
        await RisingEdge(clk)
        if _val(dut.ARESETn) != 1:
            continue
        if _val(tx_v) == 1 and _val(tx_r) == 1:
            flit = _val(tx_d)
            if flit is not None:
                for line in decode_flit(flit):
                    _emit("%s[F] t=%d A->B %s" % (TAG, _t(), line))
        if _val(rx_v) == 1 and _val(rx_r) == 1:
            flit = _val(rx_d)
            if flit is not None:
                for line in decode_flit(flit):
                    _emit("%s[F] t=%d B->A %s" % (TAG, _t(), line))


def _name(table, v):
    return table[v] if (v is not None and v < len(table)) else "?"


async def state_monitor(dut):
    """Level 2: internal DUT state, reported on change."""
    if level() < 2:
        return
    sigs = {
        "iact": _find(dut, "g_rp1.u_init.u_act.state"),
        "tact": _find(dut, "g_rp1.u_tgt.u_act.state"),
        "ifsm": _find(dut, "g_rp1.u_init.g_inorder.state"),
        "tfsm": _find(dut, "g_rp1.u_tgt.state"),
        "qcnt": _find(dut, "g_rp1.u_init.q_count"),
        "i_cr_wreq": _find(dut, "g_rp1.u_init.cr_wreq"),
        "i_cr_rreq": _find(dut, "g_rp1.u_init.cr_rreq"),
        "i_cr_wdata": _find(dut, "g_rp1.u_init.cr_wdata"),
        "i_ret_rdata": _find(dut, "g_rp1.u_init.ret_rdata"),
        "i_ret_wresp": _find(dut, "g_rp1.u_init.ret_wresp"),
        "t_cr_rdata": _find(dut, "g_rp1.u_tgt.cr_rdata"),
        "t_cr_wresp": _find(dut, "g_rp1.u_tgt.cr_wresp"),
        "t_ret_wreq": _find(dut, "g_rp1.u_tgt.ret_wreq"),
        "t_ret_rreq": _find(dut, "g_rp1.u_tgt.ret_rreq"),
        "t_ret_wdata": _find(dut, "g_rp1.u_tgt.ret_wdata"),
    }
    missing = sorted(k for k, v in sigs.items() if v is None)
    if missing:
        _emit("%s[V] internal signals unreachable: %s" % (TAG, ",".join(missing)))
    clk = dut.ACLK
    prev = {}
    while True:
        await RisingEdge(clk)
        if _val(dut.ARESETn) != 1:
            continue
        cur = {k: (_val(v) if v is not None else None) for k, v in sigs.items()}
        groups = (
            ("init.act", ("iact",),
             lambda c: "init.act %s" % _name(ACT_STATE, c["iact"])),
            ("tgt.act", ("tact",),
             lambda c: "tgt.act  %s" % _name(ACT_STATE, c["tact"])),
            ("init.fsm", ("ifsm",),
             lambda c: "init.fsm %s" % _name(INIT_STATE, c["ifsm"])),
            ("tgt.fsm", ("tfsm",),
             lambda c: "tgt.fsm  %s" % _name(TGT_STATE, c["tfsm"])),
            ("init.reqq", ("qcnt",),
             lambda c: "init.reqq occupancy=%s" % c["qcnt"]),
            ("init.credits",
             ("i_cr_wreq", "i_cr_rreq", "i_cr_wdata", "i_ret_rdata",
              "i_ret_wresp"),
             lambda c: "init.credits held(wreq=%s rreq=%s wdata=%s) "
                       "owed(rdata=%s wresp=%s)"
                       % (c["i_cr_wreq"], c["i_cr_rreq"], c["i_cr_wdata"],
                          c["i_ret_rdata"], c["i_ret_wresp"])),
            ("tgt.credits",
             ("t_cr_rdata", "t_cr_wresp", "t_ret_wreq", "t_ret_rreq",
              "t_ret_wdata"),
             lambda c: "tgt.credits  held(rdata=%s wresp=%s) "
                       "owed(wreq=%s rreq=%s wdata=%s)"
                       % (c["t_cr_rdata"], c["t_cr_wresp"], c["t_ret_wreq"],
                          c["t_ret_rreq"], c["t_ret_wdata"])),
        )
        for key, fields, render in groups:
            if any(sigs[f] is None for f in fields):
                continue
            snap = tuple(cur[f] for f in fields)
            if prev.get(key) != snap:
                prev[key] = snap
                _emit("%s[D] t=%d %s" % (TAG, _t(), render(cur)))


def start(dut):
    """Start whichever monitors the active level calls for (none at level 0)."""
    lvl = level()
    if lvl < 1:
        return
    get_logger()
    cocotb.start_soon(flit_monitor(dut))
    if lvl >= 2:
        cocotb.start_soon(state_monitor(dut))
