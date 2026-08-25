"""Functional coverage model for the AXI-over-UCIe PyUVM environment.

Verilator gives this repo *line* coverage (`make coverage`, floor `COV_MIN`).
This module adds *functional* coverage on top: a dependency-light covergroup
helper (plain dicts of named bins) that is sampled from the **monitored**
transaction stream only — never from the stimulus side, and never by peeking at
RTL internals from Python.

Structure
---------
`CoverGroup` is one coverpoint: an ordered set of named bins, each a hit
counter.  A bin may be *excluded* from the goal with a recorded reason (used for
AXI response encodings the DUT provably cannot drive); excluded bins are still
printed, still counted if they are ever hit, but do not drag the percentage
down.  `AxiCoverage` owns the groups, classifies an observed `AxiSeqItem` into
bins in `sample()`, and prints a `[COV-FUNC]` report.

Cross-simulation merge
----------------------
`make test-all` runs each cocotb test in its **own** simulation (so the RTL
memory is re-zeroed per test), so no single process sees the whole run.  The
model therefore persists its bin counts to a small JSON database (`FCOV_DB`,
default `fcov.json` in the cocotb run directory) and merges what is already
there on start-up.  The root Makefile deletes the database before a test target
runs, so the counts always describe exactly one `make test*` invocation.

Everything here is deterministic and stdlib-only: no new pip dependency, and the
same bins are computed identically in CI and in the container.
"""

import json
import os

from axi_seq_item import ADDR_LIMIT, DATA_MASK

# --- knobs -------------------------------------------------------------------
# Functional-coverage floor, in percent of the model's own goal bins.  100 is the
# default: every goal bin is meant to be reachable with the stimulus in
# dv/cocotb/axi_seq.py, so anything less is a coverage regression.
FCOV_MIN = float(os.environ.get("FCOV_MIN", "100"))
# Merge database shared by the per-test simulations of one `make test*` run.
FCOV_DB = os.environ.get("FCOV_DB", "fcov.json")

BANNER = "[COV-FUNC]"

# --- address map partitions (derived from the RTL memory depth) --------------
# ADDR_LIMIT comes from MEM_ADDR_W in axi_seq_item.py, which mirrors the DUT's
# MEM_ADDR_W parameter — nothing here hardcodes a memory size.
_THIRD = (ADDR_LIMIT // 3) & ~0x3
LAST_WORD = ADDR_LIMIT - 4

# name -> (lo, hi) byte-address range, hi exclusive.
ADDR_REGIONS = (
    ("low", 0, _THIRD),
    ("mid", _THIRD, 2 * _THIRD),
    ("high", 2 * _THIRD, ADDR_LIMIT),
)


def region_of(addr):
    """Name of the address-map partition containing `addr`."""
    for name, lo, hi in ADDR_REGIONS:
        if lo <= addr < hi:
            return name
    return ADDR_REGIONS[-1][0]


def region_sample_addr(name):
    """A word-aligned address in the middle of the named partition.

    Sequences use this so directed stimulus tracks the partition boundaries
    instead of restating them."""
    for rname, lo, hi in ADDR_REGIONS:
        if rname == name:
            return ((lo + hi) // 2) & ~0x3
    raise KeyError(name)


# --- data patterns -----------------------------------------------------------
# Derived from DATA_MASK so a wider data bus reclassifies automatically.
ALT_5 = DATA_MASK // 3                       # 0x5555_5555 for a 32-bit word
ALT_A = (ALT_5 << 1) & DATA_MASK             # 0xAAAA_AAAA


def data_pattern(value):
    """Bucket a payload word into one of the data-pattern bins."""
    v = value & DATA_MASK
    if v == 0:
        return "zero"
    if v == DATA_MASK:
        return "all_ones"
    if v & (v - 1) == 0:
        return "walking_one"                 # exactly one bit set
    inv = (~v) & DATA_MASK
    if inv & (inv - 1) == 0:
        return "walking_zero"                # exactly one bit clear
    if v in (ALT_5, ALT_A):
        return "alternating"
    return "other"                           # constrained-random traffic


# --- burst / outstanding buckets --------------------------------------------
def burst_bucket(length):
    """AxLEN (beats-1) -> burst-length bin."""
    beats = length + 1
    if beats == 1:
        return "beats_1"
    if beats <= 8:
        return "beats_small"
    return "beats_max"


def outstanding_bucket(depth):
    """Number of transfers open on the bus at this beat -> outstanding bin."""
    return "one" if depth <= 1 else "multi"


RESP_NAMES = {0: "okay", 1: "exokay", 2: "slverr", 3: "decerr"}
# The AXI-Lite target (rtl/axi_lite_mem.sv) ties BRESP/RRESP to RESP_OKAY and the
# AoU bridges transport that value verbatim, so no error/exclusive encoding is
# reachable without an RTL behaviour change.  The bins are kept visible and
# excluded-with-a-reason rather than deleted (see the PR notes).
RESP_UNREACHABLE = "DUT ties BRESP/RRESP to OKAY (rtl/axi_lite_mem.sv:73-74)"


class CoverGroup:
    """One coverpoint: named bins with hit counters, plus excluded bins."""

    def __init__(self, name, desc, bins, excluded=None):
        self.name = name
        self.desc = desc
        self.excluded = dict(excluded or {})
        self.bins = {b: 0 for b in bins}
        for b in self.excluded:
            self.bins.setdefault(b, 0)

    def hit(self, *names):
        for n in names:
            if n in self.bins:
                self.bins[n] += 1
            else:                            # a bin we never declared
                self.bins[n] = 1
                self.excluded.setdefault(n, "undeclared bin observed")

    @property
    def goal(self):
        return [b for b in self.bins if b not in self.excluded]

    @property
    def missing(self):
        return [b for b in self.goal if self.bins[b] == 0]

    @property
    def covered(self):
        return sum(1 for b in self.goal if self.bins[b] > 0)

    @property
    def total(self):
        return len(self.goal)

    @property
    def pct(self):
        return 100.0 * self.covered / self.total if self.total else 100.0


class AxiCoverage:
    """The AXI-over-UCIe functional coverage model."""

    def __init__(self):
        self.samples = 0
        self.tests = []
        self.groups = {}
        for g in self._build_groups():
            self.groups[g.name] = g

    # -- model definition -----------------------------------------------------
    @staticmethod
    def _build_groups():
        regions = [r[0] for r in ADDR_REGIONS]
        return [
            CoverGroup("direction", "read vs write transfers",
                       ["read", "write"]),
            CoverGroup("addr_region",
                       f"address partition of the {ADDR_LIMIT >> 10} KiB map",
                       regions),
            CoverGroup("addr_boundary", "first / last word of the memory",
                       ["first_word", "interior", "last_word"]),
            CoverGroup("data_pattern", "payload word pattern",
                       ["zero", "all_ones", "walking_one", "walking_zero",
                        "alternating", "other"]),
            CoverGroup("resp", "observed BRESP / RRESP encoding",
                       ["okay"],
                       excluded={"exokay": RESP_UNREACHABLE,
                                 "slverr": RESP_UNREACHABLE,
                                 "decerr": RESP_UNREACHABLE}),
            CoverGroup("burst_len", "beats per transfer (AxLEN+1)",
                       ["beats_1", "beats_small", "beats_max"]),
            CoverGroup("outstanding", "transfers open on the bus at this beat",
                       ["one", "multi"]),
            CoverGroup("dir_x_region", "cross: direction x address partition",
                       [f"{d}_{r}" for d in ("read", "write") for r in regions]),
        ]

    # -- sampling -------------------------------------------------------------
    def sample(self, tr):
        """Sample one **observed** transfer (an `AxiSeqItem` from the monitor)."""
        self.samples += 1
        direction = "write" if tr.write else "read"
        payload = tr.data if tr.write else tr.rdata
        addr = tr.addr
        region = region_of(addr)

        self.groups["direction"].hit(direction)
        self.groups["addr_region"].hit(region)
        if addr == 0:
            self.groups["addr_boundary"].hit("first_word")
        elif addr == LAST_WORD:
            self.groups["addr_boundary"].hit("last_word")
        else:
            self.groups["addr_boundary"].hit("interior")
        self.groups["data_pattern"].hit(data_pattern(payload))
        self.groups["resp"].hit(RESP_NAMES.get(tr.resp & 0x3, "okay"))
        self.groups["burst_len"].hit(burst_bucket(getattr(tr, "length", 0) or 0))
        self.groups["outstanding"].hit(
            outstanding_bucket(getattr(tr, "outstanding", 1) or 1))
        self.groups["dir_x_region"].hit(f"{direction}_{region}")

    # -- totals ---------------------------------------------------------------
    @property
    def covered(self):
        return sum(g.covered for g in self.groups.values())

    @property
    def total(self):
        return sum(g.total for g in self.groups.values())

    @property
    def pct(self):
        return 100.0 * self.covered / self.total if self.total else 100.0

    def holes(self):
        """[(group, bin)] for every unhit goal bin."""
        return [(g.name, b) for g in self.groups.values() for b in g.missing]

    # -- cross-simulation merge ----------------------------------------------
    def load(self, path=None):
        """Merge counts from a previous simulation of the same run, if any."""
        path = path or FCOV_DB
        try:
            with open(path) as fh:
                db = json.load(fh)
        except (OSError, ValueError):
            return False
        for gname, bins in (db.get("groups") or {}).items():
            group = self.groups.get(gname)
            if group is None:
                continue                     # bin set changed — ignore stale data
            for bname, hits in bins.items():
                if bname in group.bins:
                    group.bins[bname] += int(hits)
        self.samples += int(db.get("samples", 0))
        self.tests = list(db.get("tests") or [])
        return True

    def save(self, test_name=None, path=None):
        path = path or FCOV_DB
        if test_name and test_name not in self.tests:
            self.tests.append(test_name)
        db = {
            "samples": self.samples,
            "tests": self.tests,
            "groups": {g.name: dict(g.bins) for g in self.groups.values()},
        }
        try:
            with open(path, "w") as fh:
                json.dump(db, fh, indent=1, sort_keys=True)
        except OSError:                      # read-only sandbox: report anyway
            return False
        return True

    # -- reporting ------------------------------------------------------------
    def report_lines(self):
        who = ", ".join(self.tests) if self.tests else "this test"
        lines = [
            f"{BANNER} AXI functional coverage — "
            f"{self.samples} observed transfers from: {who}",
        ]
        width = max(len(g.name) for g in self.groups.values())
        for g in self.groups.values():
            note = ""
            if g.missing:
                note = "  MISSING: " + ", ".join(sorted(g.missing))
            elif g.excluded:
                note = ("  EXCLUDED: " + ", ".join(sorted(g.excluded)) +
                        f" ({sorted(set(g.excluded.values()))[0]})")
            lines.append(
                f"{BANNER}   {g.name:<{width}}  {g.covered:>2}/{g.total:<2}"
                f" {g.pct:6.1f}%{note}")
        lines.append(
            f"{BANNER} overall: {self.covered}/{self.total} goal bins = "
            f"{self.pct:.1f}% (floor {FCOV_MIN:.1f}%)")
        return lines

    def report(self, printer=None):
        emit = printer or (lambda s: print(s, flush=True))
        for line in self.report_lines():
            emit(line)

    def check(self, printer=None, floor=None):
        """Print the `[COV-FUNC] PASS/FAIL` line; return True when at/above floor."""
        emit = printer or (lambda s: print(s, flush=True))
        floor = FCOV_MIN if floor is None else floor
        ok = self.pct + 1e-9 >= floor
        if ok:
            emit(f"{BANNER} PASS: functional coverage {self.pct:.1f}% "
                 f"meets the {floor:.1f}% floor")
        else:
            for gname, bname in self.holes():
                emit(f"{BANNER}   hole: {gname}.{bname} never hit")
            emit(f"{BANNER} FAIL: functional coverage {self.pct:.1f}% "
                 f"below the {floor:.1f}% floor")
        return ok
