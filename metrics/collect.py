#!/usr/bin/env python3
"""[METRICS] collector -- one run row (+ children) into metrics/metrics.db.

Gathers the design / verification / compute / AI numbers for a run that has
ALREADY finished and inserts them into the committed SQLite database that
metrics/dashboard.py trends.  Run by `make metrics`; NEVER by
check/regress/ci -- see docs/NOTES.md "Metrics DB" and the plan invariant:

    measurement must never change the thing it measures.

Everything here reads artifacts left behind by a completed run (a captured gate
log, /usr/bin/time output, sim/coverage.info, formal/*_{bmc,cover,prove}/,
dv/cocotb/fcov.json, docker/last-run-metrics.json, a swarm stream-json) or runs
its OWN out-of-gate passes (a yosys generic synth, a Verilator lint) that no DV
environment is timed through.

Two hard rules, both enforced by the schema:

  * Every value is tagged 'measured' (read from a real artifact) or 'estimated'
    (MODELED from measured inputs x a documented coefficient in
    metrics/coefficients.json).  Nothing in between.
  * A number the tooling cannot attribute is written as kind='not_attributable'
    with value NULL and the REASON in `source`.  Never fabricated.

Idempotent: re-collecting the same --run-key replaces that run's child rows
instead of appending a duplicate run.

Usage:
  metrics/collect.py [--db metrics/metrics.db] [--capture-dir metrics/_capture]
                     [--run-key KEY] [--trigger auto|local|ci|railway|swarm]
                     [--no-synth] [--yosys PATH] [--verilator PATH] [--quiet]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

COLLECTOR_VERSION = "1.0"

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# RTL compile order, mirrored from the root Makefile's $(RTL).
RTL_FILES = [
    "rtl/aou_pkg.sv",
    "rtl/ucie_stream_link.sv",
    "rtl/aou_activation.sv",
    "rtl/axi_lite_mem.sv",
    "rtl/aou_reorder.sv",
    "rtl/aou_ooo_resp_src.sv",
    "rtl/aou_rp_mux.sv",
    "rtl/aou_axi_initiator_bridge.sv",
    "rtl/aou_axi_target_bridge.sv",
    "rtl/axi_ucie_mem_top.sv",
]
TOP = "axi_ucie_mem_top"

# The four proofs `make formal` gates on, and the tasks it runs.
FORMAL_PROOFS = ["axi_lite_mem", "aou_flit", "aou_credit", "aou_activation"]
FORMAL_TASKS = ["bmc", "cover", "prove"]

# Known swarm agents (docker/swarm.sh + .claude/agents/).  Used to name the
# per-agent rows and to spot an unexpected agent type rather than drop it.
DV_ENVS = ["cocotb", "sv", "pack", "act", "reorder", "ooo", "mrp", "systemc"]


# --------------------------------------------------------------------------- #
# small helpers
# --------------------------------------------------------------------------- #
def log(msg, quiet=False):
    if not quiet:
        print("[METRICS] " + msg, flush=True)


def warn(msg):
    print("[METRICS] note: " + msg, file=sys.stderr, flush=True)


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def read_json(path):
    txt = read_text(path)
    if txt is None:
        return None
    try:
        return json.loads(txt)
    except json.JSONDecodeError as exc:
        warn("cannot parse %s: %s" % (path, exc))
        return None


def run_cmd(argv, timeout=900, cwd=None):
    """Run a command, return (rc, stdout+stderr).  Never raises."""
    try:
        proc = subprocess.run(
            argv, cwd=cwd or REPO, timeout=timeout,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        )
        return proc.returncode, proc.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        return 127, "collect.py: %s" % exc


def git(*args):
    rc, out = run_cmd(["git"] + list(args), timeout=60)
    return out.strip() if rc == 0 else ""


# Timestamp prefix written by metrics/capture.sh: "[+12.345] <line>".
TS_RE = re.compile(r"^\[\+(\d+\.\d+)\]\s?(.*)$")


def parse_capture_log(path):
    """Return [(offset_seconds_or_None, line), ...] for a captured gate log."""
    txt = read_text(path)
    if txt is None:
        return []
    out = []
    for raw in txt.splitlines():
        m = TS_RE.match(raw)
        if m:
            out.append((float(m.group(1)), m.group(2)))
        else:
            out.append((None, raw))
    return out


def parse_time_v(path):
    """Parse a `/usr/bin/time -v` capture into a dict of the fields we use."""
    txt = read_text(path)
    if txt is None:
        return None
    out = {}
    for line in txt.splitlines():
        line = line.strip()
        if line.startswith("Elapsed (wall clock) time"):
            # The LABEL contains colons too ("... time (h:mm:ss or m:ss): 0:01.00"),
            # so anchor on the trailing h:mm:ss / m:ss value instead of splitting
            # on the first colon.
            m = re.search(r":\s*(\d+(?::\d+)*(?:\.\d+)?)\s*$", line)
            if not m:
                continue
            secs = 0.0
            for p in m.group(1).split(":"):
                secs = secs * 60 + float(p)
            out["wall_s"] = secs
        elif line.startswith("User time (seconds):"):
            out["user_s"] = float(line.split(":", 1)[1])
        elif line.startswith("System time (seconds):"):
            out["sys_s"] = float(line.split(":", 1)[1])
        elif line.startswith("Maximum resident set size"):
            out["max_rss_kb"] = float(line.split(":", 1)[1])
        elif line.startswith("Percent of CPU this job got:"):
            out["cpu_pct"] = float(line.split(":", 1)[1].strip().rstrip("%"))
        elif line.startswith("Exit status:"):
            out["exit_status"] = float(line.split(":", 1)[1])
    return out or None


# --------------------------------------------------------------------------- #
# row accumulator
# --------------------------------------------------------------------------- #
MEASURED = "measured"
ESTIMATED = "estimated"
GAP = "not_attributable"


class Rows:
    """Accumulates the rows for one run, per domain, de-duplicated by key."""

    def __init__(self):
        self.design = {}
        self.verif = {}
        self.compute = {}
        self.ai = {}

    def _put(self, table, key, row):
        table[key] = row

    def design_row(self, scope, name, value, unit, kind, source):
        self._put(self.design, (scope, name), (scope, name, value, unit, kind, source))

    def verif_row(self, scope, name, value, unit, kind, source):
        self._put(self.verif, (scope, name), (scope, name, value, unit, kind, source))

    def compute_row(self, scope, name, value, unit, kind, source):
        self._put(self.compute, (scope, name), (scope, name, value, unit, kind, source))

    def ai_row(self, agent, model, name, value, unit, kind, source):
        self._put(self.ai, (agent, model, name),
                  (agent, model, name, value, unit, kind, source))

    def counts(self):
        return (len(self.design), len(self.verif), len(self.compute), len(self.ai))

    def kind_counts(self):
        out = {MEASURED: 0, ESTIMATED: 0, GAP: 0}
        for tbl, ki in ((self.design, 4), (self.verif, 4), (self.compute, 4), (self.ai, 5)):
            for row in tbl.values():
                out[row[ki]] = out.get(row[ki], 0) + 1
        return out


# --------------------------------------------------------------------------- #
# domain 1 -- design / RTL
# --------------------------------------------------------------------------- #
MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)


def collect_design(rows, coeff, yosys, verilator, do_synth, quiet):
    log("domain 1/4: design (RTL LOC, yosys generic synth, Verilator warnings)", quiet)

    # --- RTL LOC + module count (measured, trivially) ------------------------
    # rtl/ is not one-module-per-file (aou_rp_mux.sv alone holds aou_rp_arb,
    # aou_flit_fifo and aou_rp_route), so per-module LOC is attributed by
    # slicing each file at its `module` keywords, and the synth list comes from
    # the same parse rather than from file names.
    total_loc = total_code = 0
    modules = []
    for rel in RTL_FILES:
        txt = read_text(os.path.join(REPO, rel))
        if txt is None:
            continue
        lines = txt.splitlines()
        code = [ln for ln in lines if ln.strip() and not ln.strip().startswith("//")]
        total_loc += len(lines)
        total_code += len(code)
        starts = [(m.start(), m.group(1)) for m in MODULE_RE.finditer(txt)]
        for i, (pos, name) in enumerate(starts):
            modules.append(name)
            end = starts[i + 1][0] if i + 1 < len(starts) else len(txt)
            body = txt[pos:end].splitlines()
            bcode = [ln for ln in body if ln.strip() and not ln.strip().startswith("//")]
            rows.design_row(name, "rtl_loc", float(len(body)), "lines", MEASURED,
                            "%s (module body)" % rel)
            rows.design_row(name, "rtl_loc_code", float(len(bcode)), "lines", MEASURED,
                            "%s (blank + whole-line // comments excluded)" % rel)
    rows.design_row("", "rtl_loc", float(total_loc), "lines", MEASURED, "rtl/*.sv")
    rows.design_row("", "rtl_loc_code", float(total_code), "lines", MEASURED, "rtl/*.sv")
    rows.design_row("", "rtl_modules", float(len(modules)), "modules", MEASURED,
                    "rtl/*.sv `module` declarations")

    # --- Verilator -Wall warning count (measured) ----------------------------
    if verilator and shutil.which(verilator):
        rc, out = run_cmd([verilator, "--lint-only", "-Wall", "-Wno-DECLFILENAME",
                           "--top-module", TOP] + RTL_FILES, timeout=300)
        n_warn = len(re.findall(r"^%Warning", out, re.MULTILINE))
        n_err = len(re.findall(r"^%Error", out, re.MULTILINE))
        rows.design_row("", "verilator_warnings", float(n_warn), "warnings", MEASURED,
                        "verilator --lint-only -Wall (out-of-gate re-run)")
        rows.design_row("", "verilator_errors", float(n_err), "errors", MEASURED,
                        "verilator --lint-only -Wall (out-of-gate re-run)")
    else:
        rows.design_row("", "verilator_warnings", None, "warnings", GAP,
                        "verilator not found (pass --verilator or VERILATOR=<path>)")

    if not do_synth:
        rows.design_row("", "cells", None, "cells", GAP,
                        "synthesis skipped (--no-synth)")
        return
    if not (yosys and os.path.exists(yosys)):
        rows.design_row("", "cells", None, "cells", GAP,
                        "yosys not found (pass --yosys, or set OSS); no gate estimate")
        return

    # --- yosys generic synth: per-module + whole-design (estimated) ----------
    ge_cfg = coeff.get("gate_equivalents", {})
    ge_by_prefix = ge_cfg.get("by_cell_prefix", {})
    ge_default = float(ge_cfg.get("default", 1.0))

    def ge_weight(cell):
        best, weight = -1, None
        for pref, w in ge_by_prefix.items():
            if cell.startswith(pref) and len(pref) > best:
                best, weight = len(pref), float(w)
        return weight, (weight is not None)

    def tally(by_type):
        cells = flops = mem_cells = unweighted = 0
        ge = 0.0
        for cell, n in (by_type or {}).items():
            n = int(n)
            if cell.startswith("$mem"):
                mem_cells += n
                continue
            cells += n
            if "DFF" in cell or "DLATCH" in cell or cell.startswith("$_SR_"):
                flops += n
            w, known = ge_weight(cell)
            ge += (w if known else ge_default) * n
            if not known:
                unweighted += n
        return cells, flops, mem_cells, ge, unweighted

    def emit(scope, by_type, wire_bits, mem_bits, src):
        cells, flops, mem_cells, ge, unweighted = tally(by_type)
        rows.design_row(scope, "cells", float(cells), "cells", ESTIMATED,
                        src + "; generic cells, no liberty -> ESTIMATE")
        rows.design_row(scope, "gate_equivalents", round(ge, 1), "GE", ESTIMATED,
                        src + "; x coefficients.json:gate_equivalents")
        rows.design_row(scope, "flops", float(flops), "flops", MEASURED,
                        src + "; $_DFF*/$_DLATCH*/$_SR_ cells (technology independent)")
        rows.design_row(scope, "memory_cells", float(mem_cells), "arrays", MEASURED,
                        src + "; $mem_v2 arrays kept unmapped (macro, not random logic)")
        if mem_bits is not None:
            rows.design_row(scope, "memory_bits", float(mem_bits), "bits", MEASURED,
                            src + "; stat taken BEFORE `memory -nomap` (array storage, "
                                  "excluded from the GE count)")
        if wire_bits is not None:
            rows.design_row(scope, "netlist_wire_bits", float(wire_bits), "bits", MEASURED, src)
        if unweighted:
            rows.design_row(scope, "cells_unweighted", float(unweighted), "cells", MEASURED,
                            "cell types with no GE weight in coefficients.json "
                            "(fell back to default=%g)" % ge_default)

    # (a) Whole design, FLATTENED -- the headline numbers.  slang elaborates the
    #     hierarchy away, so yosys optimizes across module boundaries exactly as
    #     a real flow would; this is the count to trend.
    stat, pre, ltp = yosys_synth(yosys, TOP, quiet, hierarchical=False)
    if stat is None:
        rows.design_row("", "cells", None, "cells", GAP,
                        "yosys generic synth of the top failed -- no gate estimate this run")
    else:
        emit("", stat.get("num_cells_by_type"), stat.get("num_wire_bits"),
             (pre or {}).get("num_memory_bits"),
             "yosys generic synth, flattened (read_slang -> proc/opt/"
             "memory -nomap/techmap), top=" + TOP)
        if ltp is not None:
            fm = coeff.get("fmax_estimate", {})
            ns_per_level = float(fm.get("ns_per_level", 0.06))
            overhead = float(fm.get("overhead_ns", 0.25))
            rows.design_row("", "comb_path_levels", float(ltp), "cell levels", MEASURED,
                            "yosys `ltp -noff` on the flattened generic netlist")
            period_ns = ltp * ns_per_level + overhead
            if period_ns > 0:
                rows.design_row("", "fmax_mhz", round(1000.0 / period_ns, 1), "MHz", ESTIMATED,
                                "coefficients.json:fmax_estimate x comb_path_levels; "
                                "NO liberty timing -- trend only, never a signoff number")

    # (b) Per module, AS INSTANTIATED.  read_slang --best-effort-hierarchy keeps
    #     the boundaries, so each block is counted with its real parameter
    #     overrides (synthesizing a module standalone would use its DEFAULT
    #     parameters -- e.g. aou_flit_fifo defaults to a far larger FIFO than the
    #     top ever instantiates -- and give a badly misleading number).
    #     Boundaries block cross-module optimization, so the per-module sum is
    #     LARGER than the flattened whole-design count above; that is expected
    #     and the source string says so.
    hstat, _hpre, _hltp = yosys_synth(yosys, TOP, quiet, hierarchical=True)
    if not hstat:
        rows.design_row("*per-module*", "cells", None, "cells", GAP,
                        "yosys hierarchical pass (read_slang --best-effort-hierarchy) did not "
                        "produce per-module stats this run; whole-design numbers are unaffected")
        return
    per_mod = {}
    for key, mstat in hstat.items():
        # Uniquified name: "\<module>$<instance path>" (or plain "\<module>").
        name = key.lstrip("\\").split("$", 1)[0]
        acc = per_mod.setdefault(name, {"types": {}, "wire_bits": 0, "mem_bits": 0, "inst": 0})
        acc["inst"] += 1
        acc["wire_bits"] += int(mstat.get("num_wire_bits", 0) or 0)
        acc["mem_bits"] += int(mstat.get("num_memory_bits", 0) or 0)
        for cell, n in (mstat.get("num_cells_by_type") or {}).items():
            acc["types"][cell] = acc["types"].get(cell, 0) + int(n)
    for name, acc in sorted(per_mod.items()):
        if name == TOP:
            continue
        emit(name, acc["types"], acc["wire_bits"], None,
             "yosys hierarchical generic synth (read_slang --best-effort-hierarchy), "
             "summed over %d instantiation(s) of %s inside %s; module boundaries block "
             "cross-module optimization, so per-module totals exceed the flattened "
             "whole-design count" % (acc["inst"], name, TOP))
        rows.design_row(name, "instances", float(acc["inst"]), "instances", MEASURED,
                        "instantiations of %s elaborated inside %s at the DEFAULT "
                        "parameters (NUM_RP=1, OOO_EN=0)" % (name, TOP))


def yosys_synth(yosys, top, quiet, hierarchical=False):
    """One out-of-gate yosys generic synth.

    Flat mode  -> (post_stat, pre_stat, ltp_levels) for the whole design.
    Hier. mode -> (modules_dict, None, None): the per-module stat map, keyed by
                  yosys's uniquified "\\<module>$<instance path>" names.

    Nothing here runs on the gate path; `make check`/`regress`/`ci` never
    invoke yosys.
    """
    pid = os.getpid()
    tag = "h" if hierarchical else "f"
    pre_json = "/tmp/aou-metrics-pre-%d-%s.json" % (pid, tag)
    stat_json = "/tmp/aou-metrics-stat-%d-%s.json" % (pid, tag)
    ltp_txt = "/tmp/aou-metrics-ltp-%d-%s.txt" % (pid, tag)
    script = (
        "plugin -i slang; "
        # The memory's zeroing `for` loop unrolls WORDS times; the slang default
        # limit (4000) is below the 16384-word array, so raise it.
        "read_slang {hier}--unroll-limit=40000 --top {top} {files}; "
        "hierarchy -top {top}; proc; opt; "
        "tee -q -o {pre} stat -json; "
        # -nomap keeps the 512 Kbit array a $mem macro instead of exploding it
        # into half a million generic cells and swamping the logic count.
        "memory -nomap; opt -fast; techmap; opt; "
        "tee -q -o {stat} stat -json; "
        "tee -q -o {ltp} ltp -noff"
    ).format(top=top, files=" ".join(RTL_FILES), pre=pre_json, stat=stat_json, ltp=ltp_txt,
             hier="--best-effort-hierarchy " if hierarchical else "")
    rc, out = run_cmd([yosys, "-q", "-p", script], timeout=1800)
    if rc != 0:
        warn("yosys %s synth failed for top=%s (rc=%d)"
             % ("hierarchical" if hierarchical else "flat", top, rc))
        if not quiet:
            print(out[-800:], file=sys.stderr)
        return None, None, None

    data = read_json(stat_json)
    if hierarchical:
        for tmp in (pre_json, stat_json, ltp_txt):
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return ((data or {}).get("modules") or None), None, None

    def pick(path):
        d = read_json(path)
        if not d:
            return None
        return (d.get("modules") or {}).get("\\" + top) or d.get("design")

    stat, pre = pick(stat_json), pick(pre_json)
    levels = None
    txt = read_text(ltp_txt)
    if txt:
        m = re.search(r"Longest topological path in \S+ \(length=(\d+)\)", txt)
        if m:
            levels = int(m.group(1))
    for tmp in (pre_json, stat_json, ltp_txt):
        try:
            os.unlink(tmp)
        except OSError:
            pass
    return stat, pre, levels


# --------------------------------------------------------------------------- #
# domain 2 -- verification / coverage
# --------------------------------------------------------------------------- #
# One (env, metric-name, regex) per gate banner we can mine a real number from.
ENV_BANNERS = [
    ("sv",       "reads_checked", re.compile(r"\[SV-TB\] PASS: (\d+) reads checked")),
    ("pack",     "checks",        re.compile(r"\[PACK-TB\] PASS: (\d+) checks")),
    ("act",      "checks",        re.compile(r"\[ACT-TB\] PASS: (\d+) checks")),
    ("reorder",  "checks",        re.compile(r"\[ROB-TB\] PASS: (\d+) checks")),
    ("ooo",      "read_beats",    re.compile(r"\[OOO-TB\] PASS: (\d+) read beats checked")),
    ("ooo",      "overtakes_r",   re.compile(r"PASS: \d+ read beats checked, (\d+) R \+")),
    ("ooo",      "overtakes_b",   re.compile(r"read beats checked, \d+ R \+ (\d+) B ")),
    ("mrp",      "read_beats",    re.compile(r"\[MRP-TB\] PASS: \d+ planes, (\d+) read beats")),
    ("mrp",      "planes",        re.compile(r"\[MRP-TB\] PASS: (\d+) planes")),
    ("systemc",  "reads_checked", re.compile(r"\[SC-TB\] PASS: (\d+) reads checked")),
]

# Property inventory.  Non-recursive on purpose: `formal/` fills up with sby
# working directories (formal/aou_flit_bmc/src/...) that hold COPIES of these
# same sources, and walking into them double-counts every property.
SVA_DIRS = ["rtl", "dv/sva", "dv/common", "formal"]
SVA_PATTERNS = {
    "sva_assertions": re.compile(r"\bassert\s+property\b"),
    "cover_properties": re.compile(r"\bcover\s+property\b"),
    "assume_properties": re.compile(r"\bassume\s+property\b"),
    "immediate_assertions": re.compile(r"^\s*assert\s*\(", re.MULTILINE),
    "immediate_covers": re.compile(r"^\s*cover\s*\(", re.MULTILINE),
    "immediate_assumes": re.compile(r"^\s*assume\s*\(", re.MULTILINE),
}


def collect_verif(rows, gate_lines, quiet):
    log("domain 2/4: verification (coverage, SVA, formal, per-env checks)", quiet)
    plain = [ln for _, ln in gate_lines]
    blob = "\n".join(plain)

    # --- line coverage (measured, from the lcov file `make coverage` wrote) --
    info = read_text(os.path.join(REPO, "sim/coverage.info"))
    if info:
        found = hit = 0
        for ln in info.splitlines():
            if ln.startswith("DA:"):
                found += 1
                try:
                    if int(ln.split(",")[1]) > 0:
                        hit += 1
                except (IndexError, ValueError):
                    pass
        if found:
            rows.verif_row("", "line_coverage_pct", round(100.0 * hit / found, 2), "%",
                           MEASURED, "sim/coverage.info (verilator_coverage lcov export)")
            rows.verif_row("", "line_coverage_points", float(found), "points", MEASURED,
                           "sim/coverage.info DA: records")
    else:
        rows.verif_row("", "line_coverage_pct", None, "%", GAP,
                       "sim/coverage.info absent -- run `make coverage` before `make metrics`")

    # --- functional coverage (measured, from the [COV-FUNC] gate banner) -----
    fc = re.findall(r"\[COV-FUNC\] overall: (\d+)/(\d+) goal bins = ([\d.]+)%", blob)
    if fc:
        hitb, totb, pct = fc[-1]
        rows.verif_row("cocotb", "func_coverage_pct", float(pct), "%", MEASURED,
                       "[COV-FUNC] banner (last of the run) in the captured gate log")
        rows.verif_row("cocotb", "func_goal_bins", float(totb), "bins", MEASURED,
                       "[COV-FUNC] banner")
        rows.verif_row("cocotb", "func_goal_bins_hit", float(hitb), "bins", MEASURED,
                       "[COV-FUNC] banner")
    else:
        fcov = read_json(os.path.join(REPO, "dv/cocotb/fcov.json"))
        if fcov and fcov.get("groups"):
            tot = hitn = 0
            for bins in fcov["groups"].values():
                for n in bins.values():
                    tot += 1
                    hitn += 1 if n else 0
            rows.verif_row("cocotb", "func_bins_hit_pct", round(100.0 * hitn / tot, 2), "%",
                           MEASURED, "dv/cocotb/fcov.json (raw bins; EXCLUDED bins not "
                                     "modeled -- differs from the [COV-FUNC] goal-bin %)")
            rows.verif_row("cocotb", "func_samples", float(fcov.get("samples", 0)), "transfers",
                           MEASURED, "dv/cocotb/fcov.json")
        else:
            rows.verif_row("cocotb", "func_coverage_pct", None, "%", GAP,
                           "no [COV-FUNC] banner in the capture and no dv/cocotb/fcov.json")

    # --- cocotb per-test pass count (measured) -------------------------------
    passed = re.findall(r"^\[TEST\] (\S+) passed", blob, re.MULTILINE)
    if passed:
        rows.verif_row("cocotb", "tests_passing", float(len(passed)), "tests", MEASURED,
                       "[TEST] <name> passed lines in the captured gate log")

    # --- per-env check counts from the banners (measured) --------------------
    seen_envs = set()
    for env, name, rx in ENV_BANNERS:
        m = rx.search(blob)
        if m:
            rows.verif_row(env, name, float(m.group(1)), "checks", MEASURED,
                           "%s banner in the captured gate log" % env)
            seen_envs.add(env)
    for env in DV_ENVS:
        if env in seen_envs or env == "cocotb":
            continue
        if not gate_lines:
            continue
        rows.verif_row(env, "checks", None, "checks", GAP,
                       "env banner not present in the captured gate log")

    # --- SVA / cover property inventory (measured, static count) -------------
    sources = []
    for d in SVA_DIRS:
        root = os.path.join(REPO, d)
        if not os.path.isdir(root):
            continue
        for fn in sorted(os.listdir(root)):
            if fn.endswith((".sv", ".svh")) and os.path.isfile(os.path.join(root, fn)):
                sources.append(os.path.join(root, fn))
    blobs = [read_text(p) or "" for p in sources]
    for name, rx in SVA_PATTERNS.items():
        total = sum(len(rx.findall(b)) for b in blobs)
        rows.verif_row("", name, float(total), "properties", MEASURED,
                       "static count over %d file(s) in %s (sby working dirs excluded)"
                       % (len(sources), ", ".join(SVA_DIRS)))

    # --- formal: proofs, per-task status / depth / solve time (measured) -----
    proofs_run = proofs_pass = 0
    for proof in FORMAL_PROOFS:
        for task in FORMAL_TASKS:
            d = os.path.join(REPO, "formal", "%s_%s" % (proof, task))
            status = read_text(os.path.join(d, "status"))
            if status is None:
                continue
            proofs_run += 1
            ok = status.strip().upper().startswith("PASS")
            proofs_pass += 1 if ok else 0
            scope = "%s:%s" % (proof, task)
            rows.verif_row(scope, "proof_pass", 1.0 if ok else 0.0, "bool", MEASURED,
                           "formal/%s_%s/status" % (proof, task))
            logtxt = read_text(os.path.join(d, "logfile.txt")) or ""
            m = re.search(r"Elapsed clock time \[H:MM:SS \(secs\)\]:\s+\S+\s+\((\d+)\)", logtxt)
            if m:
                rows.verif_row(scope, "solve_s", float(m.group(1)), "s", MEASURED,
                               "sby summary 'Elapsed clock time' in formal/%s_%s/logfile.txt"
                               % (proof, task))
            cfg = read_text(os.path.join(d, "config.sby")) or ""
            depths = re.findall(r"^\s*(?:%s:\s*)?depth\s+(\d+)" % task, cfg, re.MULTILINE)
            if not depths:
                depths = re.findall(r"^\s*depth\s+(\d+)", cfg, re.MULTILINE)
            if depths:
                rows.verif_row(scope, "bmc_depth", float(depths[-1]), "cycles", MEASURED,
                               "depth option in formal/%s_%s/config.sby" % (proof, task))
    if proofs_run:
        rows.verif_row("", "proof_tasks_run", float(proofs_run), "tasks", MEASURED,
                       "formal/*_{bmc,cover,prove}/status")
        rows.verif_row("", "proofs_passing", float(proofs_pass), "tasks", MEASURED,
                       "formal/*_{bmc,cover,prove}/status")
    else:
        rows.verif_row("", "proofs_passing", None, "tasks", GAP,
                       "no formal/*_<task>/ working directories -- run `make formal` first")

    # --- sim cycles / throughput: DROPPED, with the reason recorded ---------
    # Getting a cycle count out of the DV envs would mean adding a print to each
    # testbench.  That changes every env's stdout, and dv/systemc/sc.log is a
    # COMMITTED golden log the SystemC env diffs -- i.e. the only way to measure
    # it is to perturb the thing being measured.  The plan says: drop it and say
    # why.  Recorded as an explicit gap so the dashboard shows the hole.
    for env in DV_ENVS:
        rows.verif_row(env, "sim_cycles", None, "cycles", GAP,
                       "no DV env prints a cycle count; adding one would change env stdout "
                       "and break the committed dv/systemc/sc.log golden diff -- dropped "
                       "rather than perturb a timed run (plan: Notes/constraints)")
    rows.verif_row("", "throughput_cycles_per_s", None, "cycles/s", GAP,
                   "derived from sim_cycles, which is not attributable (see per-env rows)")


# --------------------------------------------------------------------------- #
# domain 3 -- CI / compute
# --------------------------------------------------------------------------- #
# Gate-log markers that open a step.  Order matters only for readability.
STEP_MARKERS = [
    (re.compile(r"^\[LINT\] iverilog"), "lint"),
    (re.compile(r"^\[EDA\]"), "eda-check"),
    (re.compile(r"^\[TEST\] "), "cocotb"),
    (re.compile(r"^\[SV\] "), "sv"),
    (re.compile(r"^\[PACK\] "), "pack"),
    (re.compile(r"^\[ACT\] "), "act"),
    (re.compile(r"^\[ROB\] "), "reorder"),
    (re.compile(r"^\[OOO\] "), "ooo"),
    (re.compile(r"^\[MRP\] "), "mrp"),
    (re.compile(r"^\[SC\] "), "systemc"),
    (re.compile(r"^\[COVERAGE\] "), "coverage"),
    (re.compile(r"^\[FORMAL\] "), "formal"),
]
BUILD_LINE = re.compile(r"^(g\+\+|cc1plus|iverilog|.*/verilator|verilator|ar |make\[)")


def collect_compute(rows, gate_lines, gate_time, cap_dir, coeff, quiet):
    log("domain 3/4: compute (wall time, core-seconds, peak RSS, cost, energy)", quiet)

    ncpu = os.cpu_count() or 0
    ram_mb = 0
    try:
        with open("/proc/meminfo") as fh:
            for ln in fh:
                if ln.startswith("MemTotal:"):
                    ram_mb = int(int(ln.split()[1]) / 1024)
                    break
    except OSError:
        pass
    rows.compute_row("", "runner_vcpu", float(ncpu), "vCPU", MEASURED, "os.cpu_count()")
    rows.compute_row("", "runner_ram_mb", float(ram_mb), "MB", MEASURED, "/proc/meminfo MemTotal")
    rows.compute_row("", "vl_jobs", float(os.environ.get("VL_JOBS", 0) or 0), "jobs", MEASURED,
                     "VL_JOBS in the environment (Verilator compile parallelism cap)")

    core_seconds = None
    if gate_time:
        wall = gate_time.get("wall_s")
        user = gate_time.get("user_s", 0.0)
        sysc = gate_time.get("sys_s", 0.0)
        if wall is not None:
            rows.compute_row("gate", "wall_s", round(wall, 2), "s", MEASURED,
                             "/usr/bin/time -v of the gate (metrics/capture.sh)")
        core_seconds = user + sysc
        rows.compute_row("gate", "core_seconds", round(core_seconds, 2), "core-s", MEASURED,
                         "/usr/bin/time -v user+sys of the gate")
        rows.compute_row("gate", "user_s", round(user, 2), "s", MEASURED, "/usr/bin/time -v")
        rows.compute_row("gate", "sys_s", round(sysc, 2), "s", MEASURED, "/usr/bin/time -v")
        if "max_rss_kb" in gate_time:
            rows.compute_row("gate", "peak_rss_mb", round(gate_time["max_rss_kb"] / 1024.0, 1),
                             "MB", MEASURED,
                             "/usr/bin/time -v Maximum resident set size (largest single child)")
        if "cpu_pct" in gate_time:
            rows.compute_row("gate", "cpu_utilization_pct", gate_time["cpu_pct"], "%", MEASURED,
                             "/usr/bin/time -v Percent of CPU this job got")
    else:
        rows.compute_row("gate", "wall_s", None, "s", GAP,
                         "no /usr/bin/time capture -- run the gate through metrics/capture.sh")

    # --- per-env wall time ---------------------------------------------------
    # Preferred (measured): a per-env /usr/bin/time capture.  Fallback
    # (estimated): deltas between step banners in the timestamped gate log --
    # the C tools block-buffer under a pipe, so a banner's timestamp is when it
    # was FLUSHED, not when it was printed.  Good enough to trend, not exact.
    per_env_measured = set()
    if os.path.isdir(cap_dir):
        for fn in sorted(os.listdir(cap_dir)):
            m = re.match(r"^env-(.+)\.time$", fn)
            if not m:
                continue
            t = parse_time_v(os.path.join(cap_dir, fn))
            if not t:
                continue
            env = m.group(1)
            per_env_measured.add(env)
            if t.get("wall_s") is not None:
                rows.compute_row(env, "wall_s", round(t["wall_s"], 2), "s", MEASURED,
                                 "/usr/bin/time -v of `make %s` (metrics/capture.sh)" % env)
            rows.compute_row(env, "core_seconds",
                             round(t.get("user_s", 0.0) + t.get("sys_s", 0.0), 2), "core-s",
                             MEASURED, "/usr/bin/time -v user+sys of `make %s`" % env)
            if "max_rss_kb" in t:
                rows.compute_row(env, "peak_rss_mb", round(t["max_rss_kb"] / 1024.0, 1), "MB",
                                 MEASURED, "/usr/bin/time -v of `make %s`" % env)

    stamped = [(t, ln) for t, ln in gate_lines if t is not None]
    if stamped:
        # Walk the log, attributing each interval to the step that is open.
        spans = {}
        build_s = run_s = 0.0
        cur, prev_t = None, stamped[0][0]
        for t, ln in stamped:
            dt = max(0.0, t - prev_t)
            if cur:
                spans[cur] = spans.get(cur, 0.0) + dt
            if BUILD_LINE.match(ln):
                build_s += dt
            else:
                run_s += dt
            prev_t = t
            for rx, step in STEP_MARKERS:
                if rx.match(ln):
                    cur = step
                    break
        total_stamped = stamped[-1][0] - stamped[0][0]
        rows.compute_row("gate", "log_span_s", round(total_stamped, 2), "s", MEASURED,
                         "first-to-last timestamp in the captured gate log")
        for step, secs in spans.items():
            if step in per_env_measured:
                continue
            rows.compute_row(step, "wall_s", round(secs, 2), "s", ESTIMATED,
                             "delta between step banners in the timestamped gate log; C tools "
                             "block-buffer under a pipe, so banner times are flush times")
        rows.compute_row("", "build_s", round(build_s, 2), "s", ESTIMATED,
                         "gate-log intervals whose line looks like a compiler invocation "
                         "(g++/iverilog/verilator/make) -- heuristic split")
        rows.compute_row("", "run_s", round(run_s, 2), "s", ESTIMATED,
                         "gate-log intervals that are not compiler invocations -- heuristic split")
    else:
        rows.compute_row("", "build_s", None, "s", GAP,
                         "gate log has no [+seconds] timestamps (capture with metrics/capture.sh)")

    # --- oss-cad-suite cache hit/miss (measured when CI tells us) ------------
    hit = os.environ.get("AOU_OSS_CACHE_HIT", "")
    if hit != "":
        rows.compute_row("", "oss_cache_hit", 1.0 if hit.lower() in ("1", "true", "yes") else 0.0,
                         "bool", MEASURED, "AOU_OSS_CACHE_HIT (actions/cache cache-hit output)")
    else:
        rows.compute_row("", "oss_cache_hit", None, "bool", GAP,
                         "AOU_OSS_CACHE_HIT unset -- only CI knows whether the oss-cad-suite "
                         "cache was restored")

    # --- estimated CI cost + CPU energy (MODELED) ----------------------------
    if core_seconds:
        cost_cfg = coeff.get("ci_compute_cost_usd_per_core_hour", {})
        runner_kind = classify_runner()
        rate = float(cost_cfg.get("by_runner", {}).get(
            runner_kind, cost_cfg.get("default", 0.0)))
        rows.compute_row("", "ci_cost_usd", round(core_seconds / 3600.0 * rate, 4), "USD",
                         ESTIMATED,
                         "measured core-seconds x coefficients.json:"
                         "ci_compute_cost_usd_per_core_hour[%s]=%.3f" % (runner_kind, rate))
        e = coeff.get("cpu_energy", {})
        wh = core_seconds * float(e.get("watts_per_core", 0.0)) * float(e.get("pue", 1.0)) / 3600.0
        rows.compute_row("", "cpu_energy_wh", round(wh, 3), "Wh", ESTIMATED,
                         "measured core-seconds x coefficients.json:cpu_energy "
                         "(watts_per_core x PUE) -- MODELED, no wall-plug meter")


def classify_runner():
    if os.environ.get("GITHUB_ACTIONS") == "true":
        return "self-hosted" if os.environ.get("RUNNER_ENVIRONMENT") == "self-hosted" \
            else "github-hosted"
    if os.environ.get("RAILWAY_ENVIRONMENT") or os.environ.get("RAILWAY_PROJECT_ID"):
        return "railway"
    return "local"


# --------------------------------------------------------------------------- #
# domain 4 -- AI / swarm
# --------------------------------------------------------------------------- #
def model_class(model):
    m = (model or "").lower()
    for cls in ("opus", "sonnet", "haiku"):
        if cls in m:
            return cls
    return "other"


def price_for(model, coeff):
    tbl = coeff.get("api_price_usd_per_mtok", {}).get("by_model_prefix", {})
    best, hit = -1, None
    for pref, vals in tbl.items():
        if (model or "").startswith(pref) and len(pref) > best:
            best, hit = len(pref), vals
    return hit


def energy_wh(model, tokens, coeff):
    """MODELED inference energy: tokens x class coefficient.  Returns Wh."""
    cls = model_class(model)
    cfg = coeff.get("inference_energy_wh_per_1k_tokens", {}).get("classes", {})
    c = cfg.get(cls) or cfg.get("other") or {}
    wh = 0.0
    for key, coef_key in (("out", "output"), ("in", "input"), ("cache_read", "cache_read")):
        wh += (tokens.get(key, 0) / 1000.0) * float(c.get(coef_key, 0.0))
    # Cache CREATION is a full prefill: price it like input tokens.
    wh += (tokens.get("cache_create", 0) / 1000.0) * float(c.get("input", 0.0))
    return wh, cls


def collect_ai(rows, result, stream_path, coeff, quiet):
    log("domain 4/4: AI / swarm (per-model, per-agent, per-agent x model)", quiet)

    if not result:
        rows.ai_row("", "", "run_reported", None, "bool", GAP,
                    "no run result JSON (docker/last-run-metrics.json) -- this collection "
                    "did not follow a headless Claude Code run")
    else:
        collect_ai_from_result(rows, result, coeff)

    collect_ai_from_stream(rows, stream_path, coeff, quiet)
    collect_pr_outcome(rows)


def collect_ai_from_result(rows, result, coeff):
    """Whole-run + per-MODEL rows from the Claude Code result object.

    Note the aggregation caveat the plan calls out: `modelUsage` INCLUDES
    subagents, so these per-model rows are for the whole swarm, not any one
    agent.  The per-agent split comes from the stream (below) or is recorded as
    a gap.
    """
    src = "docker/last-run-metrics.json (Claude Code result object)"
    for key, name, unit in (("num_turns", "turns", "turns"),
                            ("duration_ms", "wall_s", "s"),
                            ("duration_api_ms", "api_s", "s")):
        v = result.get(key)
        if v is None:
            continue
        rows.ai_row("", "", name, float(v) / 1000.0 if unit == "s" else float(v), unit,
                    MEASURED, src)
    if result.get("total_cost_usd") is not None:
        rows.ai_row("", "", "cost_usd", round(float(result["total_cost_usd"]), 4), "USD",
                    ESTIMATED, src + " total_cost_usd (client-side price-table estimate)")

    mu = result.get("modelUsage") or {}
    tot = {"in": 0, "out": 0, "cache_read": 0, "cache_create": 0}
    tot_wh = 0.0
    for model, u in mu.items():
        u = u or {}
        tk = {
            "in": int(u.get("inputTokens", 0) or 0),
            "out": int(u.get("outputTokens", 0) or 0),
            "cache_read": int(u.get("cacheReadInputTokens", 0) or 0),
            "cache_create": int(u.get("cacheCreationInputTokens", 0) or 0),
        }
        for k, v in tk.items():
            tot[k] += v
        note = src + " modelUsage (AGGREGATES subagents -- not one agent)"
        rows.ai_row("*aggregate*", model, "input_tokens", float(tk["in"]), "tokens", MEASURED, note)
        rows.ai_row("*aggregate*", model, "output_tokens", float(tk["out"]), "tokens", MEASURED, note)
        rows.ai_row("*aggregate*", model, "cache_read_tokens", float(tk["cache_read"]), "tokens",
                    MEASURED, note)
        rows.ai_row("*aggregate*", model, "cache_create_tokens", float(tk["cache_create"]),
                    "tokens", MEASURED, note)
        cost = u.get("costUSD")
        if cost is not None:
            rows.ai_row("*aggregate*", model, "cost_usd", round(float(cost), 4), "USD", ESTIMATED,
                        note + "; costUSD is a client-side price-table estimate")
        else:
            p = price_for(model, coeff)
            if p:
                c = (tk["in"] * p["input"] + tk["out"] * p["output"]
                     + tk["cache_read"] * p["input"] * p.get("cache_read_mult", 0.1)
                     + tk["cache_create"] * p["input"] * p.get("cache_write_mult", 1.25)) / 1e6
                rows.ai_row("*aggregate*", model, "cost_usd", round(c, 4), "USD", ESTIMATED,
                            "coefficients.json:api_price_usd_per_mtok fallback "
                            "(no costUSD reported for this model)")
            else:
                rows.ai_row("*aggregate*", model, "cost_usd", None, "USD", GAP,
                            "no costUSD reported and no price entry for this model prefix "
                            "(non-Anthropic providers are deliberately not priced)")
        wh, cls = energy_wh(model, tk, coeff)
        tot_wh += wh
        rows.ai_row("*aggregate*", model, "energy_wh", round(wh, 3), "Wh", ESTIMATED,
                    "MODELED: tokens x coefficients.json:"
                    "inference_energy_wh_per_1k_tokens.classes.%s -- no metered source" % cls)

    if mu:
        total_tokens = sum(tot.values())
        rows.ai_row("", "", "total_tokens", float(total_tokens), "tokens", MEASURED, src)
        rows.ai_row("", "", "output_tokens", float(tot["out"]), "tokens", MEASURED, src)
        cached = tot["cache_read"] + tot["cache_create"]
        if cached:
            rows.ai_row("", "", "cache_hit_ratio",
                        round(100.0 * tot["cache_read"] / cached, 2), "%", MEASURED,
                        src + " cacheRead / (cacheRead + cacheCreation)")
        rows.ai_row("", "", "inference_energy_wh", round(tot_wh, 3), "Wh", ESTIMATED,
                    "MODELED sum of the per-model energy rows -- see coefficients.json")
        dur = result.get("duration_api_ms") or result.get("duration_ms")
        if dur:
            rows.ai_row("", "", "output_tokens_per_s", round(tot["out"] / (dur / 1000.0), 2),
                        "tok/s", MEASURED, src + " outputTokens / duration_api_ms")
        rows.ai_row("", "", "per_model_wall_time", None, "s", GAP,
                    "Claude Code reports only whole-run duration/turns -- there is no "
                    "per-model wall-time split in headless mode (see docker/render-metrics.py)")


# Task/Agent dispatch tool names the manager uses to spawn a subagent.
TASK_TOOLS = ("Task", "Agent")


def collect_ai_from_stream(rows, stream_path, coeff, quiet):
    """Per-AGENT and per-(agent x model) rows reconstructed from stream-json.

    Claude Code's result object is per-MODEL and aggregates subagents, so the
    only way to get a per-agent view is to walk the event stream and attribute
    each sidechain event to the Task tool_use that spawned it.  What IS
    attributable: wall span, turns, tool calls, tool errors, and -- where the
    sidechain assistant events carry `message.usage` -- tokens.  Anything the
    stream does not expose is written as a gap, never invented.
    """
    if not stream_path or not os.path.exists(stream_path):
        rows.ai_row("*per-agent*", "", "attribution", None, "agents", GAP,
                    "no swarm stream-json capture (metrics/_capture/swarm-stream.jsonl). "
                    "Claude Code's result modelUsage is per-MODEL and AGGREGATES subagents, "
                    "so per-agent numbers cannot be derived from it. Re-run the swarm with "
                    "docker/swarm.sh (which tees the stream) to populate these rows.")
        return

    agents = {}     # tool_use_id -> dict
    order = []
    tot_events = 0

    def blank(name):
        return {"name": name, "t0": None, "t1": None, "turns": 0, "tool_calls": 0,
                "tool_errors": 0, "models": {}}

    root = blank("swarm-manager")

    with open(stream_path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                evt = json.loads(line)
            except json.JSONDecodeError:
                continue
            tot_events += 1
            ts = evt.get("_ts_epoch")
            parent = evt.get("parent_tool_use_id")
            tgt = agents.get(parent) if parent else root
            if tgt is None and parent:
                # A sidechain whose Task block we have not seen yet (out-of-order
                # stream): create a placeholder rather than dropping the events.
                tgt = agents[parent] = blank("unknown-agent")
                order.append(parent)
            if tgt is None:
                tgt = root
            if ts is not None:
                tgt["t0"] = ts if tgt["t0"] is None else min(tgt["t0"], ts)
                tgt["t1"] = ts if tgt["t1"] is None else max(tgt["t1"], ts)

            etype = evt.get("type")
            inner = evt.get("message") or {}
            if etype == "assistant":
                tgt["turns"] += 1
                model = inner.get("model") or ""
                usage = inner.get("usage") or {}
                mrec = tgt["models"].setdefault(model, {
                    "in": 0, "out": 0, "cache_read": 0, "cache_create": 0, "turns": 0})
                mrec["turns"] += 1
                mrec["in"] += int(usage.get("input_tokens", 0) or 0)
                mrec["out"] += int(usage.get("output_tokens", 0) or 0)
                mrec["cache_read"] += int(usage.get("cache_read_input_tokens", 0) or 0)
                mrec["cache_create"] += int(usage.get("cache_creation_input_tokens", 0) or 0)
                for blk in inner.get("content") or []:
                    if not isinstance(blk, dict) or blk.get("type") != "tool_use":
                        continue
                    tgt["tool_calls"] += 1
                    if blk.get("name") in TASK_TOOLS:
                        tid = blk.get("id")
                        sub = (blk.get("input") or {}).get("subagent_type") or "subagent"
                        desc = (blk.get("input") or {}).get("description") or ""
                        label = sub
                        for env in DV_ENVS:
                            if re.search(r"\b%s\b" % re.escape(env), desc, re.I):
                                label = "%s:%s" % (sub, env)
                                break
                        if tid and tid not in agents:
                            agents[tid] = blank(label)
                            order.append(tid)
                        elif tid:
                            agents[tid]["name"] = label
            elif etype == "user":
                for blk in inner.get("content") or []:
                    if isinstance(blk, dict) and blk.get("type") == "tool_result" \
                            and blk.get("is_error"):
                        tgt["tool_errors"] += 1

    src = "reconstructed from %s (Task spans in the stream-json capture)" % \
        os.path.relpath(stream_path, REPO)

    recs = [("swarm-manager", root)] + [(agents[t]["name"], agents[t]) for t in order]
    # Disambiguate repeated agent types (three dv-env-testers etc.).
    used = {}
    spans = []
    for pos, (name, rec) in enumerate(recs):
        is_root = pos == 0
        n = used.get(name, 0)
        used[name] = n + 1
        agent = name if n == 0 else "%s#%d" % (name, n + 1)
        rows.ai_row(agent, "", "turns", float(rec["turns"]), "turns", MEASURED, src)
        rows.ai_row(agent, "", "tool_calls", float(rec["tool_calls"]), "calls", MEASURED, src)
        rows.ai_row(agent, "", "tool_errors", float(rec["tool_errors"]), "errors", MEASURED, src)
        if rec["tool_calls"]:
            rows.ai_row(agent, "", "tool_error_rate",
                        round(100.0 * rec["tool_errors"] / rec["tool_calls"], 2), "%",
                        MEASURED, src)
        if rec["t0"] is not None and rec["t1"] is not None:
            wall = rec["t1"] - rec["t0"]
            rows.ai_row(agent, "", "wall_s", round(wall, 2), "s", MEASURED,
                        src + "; span = first-to-last event timestamp injected by "
                              "docker/render-metrics.py --stream-out")
            # The manager's span covers the whole run by construction, so it is
            # excluded from the parallelism figure (which asks how many SUBagents
            # were in flight at once).
            if not is_root:
                spans.append((rec["t0"], rec["t1"]))
        else:
            rows.ai_row(agent, "", "wall_s", None, "s", GAP,
                        "stream capture carries no per-event timestamps "
                        "(needs docker/render-metrics.py --stream-out)")

        # Per-(agent x model).
        any_tokens = False
        for model, m in rec["models"].items():
            label = model or "(unreported)"
            tk = {k: m[k] for k in ("in", "out", "cache_read", "cache_create")}
            if sum(tk.values()) == 0:
                rows.ai_row(agent, label, "tokens", None, "tokens", GAP,
                            "sidechain assistant events for this agent carry no `usage` "
                            "block -- token counts are not attributable per agent; the "
                            "run total is in the *aggregate* rows")
                continue
            any_tokens = True
            rows.ai_row(agent, label, "turns", float(m["turns"]), "turns", MEASURED, src)
            rows.ai_row(agent, label, "input_tokens", float(tk["in"]), "tokens", MEASURED, src)
            rows.ai_row(agent, label, "output_tokens", float(tk["out"]), "tokens", MEASURED, src)
            rows.ai_row(agent, label, "cache_read_tokens", float(tk["cache_read"]), "tokens",
                        MEASURED, src)
            rows.ai_row(agent, label, "cache_create_tokens", float(tk["cache_create"]), "tokens",
                        MEASURED, src)
            p = price_for(model, coeff)
            if p:
                c = (tk["in"] * p["input"] + tk["out"] * p["output"]
                     + tk["cache_read"] * p["input"] * p.get("cache_read_mult", 0.1)
                     + tk["cache_create"] * p["input"] * p.get("cache_write_mult", 1.25)) / 1e6
                rows.ai_row(agent, label, "cost_usd", round(c, 4), "USD", ESTIMATED,
                            "coefficients.json:api_price_usd_per_mtok x per-agent tokens")
            else:
                rows.ai_row(agent, label, "cost_usd", None, "USD", GAP,
                            "no price entry for this model prefix in coefficients.json")
            wh, cls = energy_wh(model, tk, coeff)
            rows.ai_row(agent, label, "energy_wh", round(wh, 3), "Wh", ESTIMATED,
                        "MODELED: per-agent tokens x coefficients.json:"
                        "inference_energy_wh_per_1k_tokens.classes.%s" % cls)
            if rec["t0"] is not None and rec["t1"] is not None and rec["t1"] > rec["t0"]:
                rows.ai_row(agent, label, "output_tokens_per_s",
                            round(tk["out"] / (rec["t1"] - rec["t0"]), 2), "tok/s", MEASURED,
                            src + "; output tokens / agent wall span")
        if not rec["models"]:
            rows.ai_row(agent, "", "model", None, "models", GAP,
                        "no assistant events attributed to this agent in the stream capture")
        elif not any_tokens:
            rows.ai_row(agent, "", "tokens", None, "tokens", GAP,
                        "no `usage` block on this agent's sidechain events")

    rows.ai_row("", "", "agents_dispatched", float(len(order)), "agents", MEASURED, src)
    rows.ai_row("", "", "stream_events", float(tot_events), "events", MEASURED, src)
    if spans:
        rows.ai_row("", "", "parallelism_peak", float(max_overlap(spans)), "agents", MEASURED,
                    src + "; peak number of simultaneously-open agent spans")


def max_overlap(spans):
    """Max number of overlapping [t0, t1] spans."""
    events = []
    for t0, t1 in spans:
        events.append((t0, 1))
        events.append((t1, -1))
    events.sort()
    cur = best = 0
    for _t, d in events:
        cur += d
        best = max(best, cur)
    return best


def collect_pr_outcome(rows):
    """Files changed / +- lines for this branch vs its merge base (measured)."""
    base = git("merge-base", "HEAD", "origin/main") or git("merge-base", "HEAD", "main")
    if not base:
        rows.ai_row("", "", "pr_files_changed", None, "files", GAP,
                    "no merge-base against main -- cannot size the change")
        return
    out = git("diff", "--numstat", base, "HEAD")
    files = adds = dels = 0
    for ln in out.splitlines():
        parts = ln.split("\t")
        if len(parts) != 3:
            continue
        files += 1
        for i, acc in ((0, "a"), (1, "d")):
            try:
                n = int(parts[i])
            except ValueError:
                n = 0
            if acc == "a":
                adds += n
            else:
                dels += n
    src = "git diff --numstat <merge-base with main>..HEAD"
    rows.ai_row("", "", "pr_files_changed", float(files), "files", MEASURED, src)
    rows.ai_row("", "", "pr_lines_added", float(adds), "lines", MEASURED, src)
    rows.ai_row("", "", "pr_lines_removed", float(dels), "lines", MEASURED, src)
    rows.ai_row("", "", "pr_human_fix_needed", None, "bool", GAP,
                "only a human reviewer knows whether the PR needed follow-up fixes; "
                "record it by hand (UPDATE ai_metric) rather than guessing")


# --------------------------------------------------------------------------- #
# database
# --------------------------------------------------------------------------- #
def open_db(db_path, schema_path):
    fresh = not os.path.exists(db_path)
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA foreign_keys = ON")
    schema = read_text(schema_path)
    if schema is None:
        raise SystemExit("[METRICS] FAIL: cannot read schema %s" % schema_path)
    con.executescript(schema)
    con.commit()
    return con, fresh


def insert_run(con, meta, rows):
    cur = con.cursor()
    cur.execute("SELECT id FROM run WHERE run_key = ?", (meta["run_key"],))
    hit = cur.fetchone()
    replaced = hit is not None
    if replaced:
        run_id = hit[0]
        # Idempotent re-collection: refresh the run row and drop its children.
        cur.execute(
            "UPDATE run SET git_sha=?, git_branch=?, git_dirty=?, ts_utc=?, trigger=?, "
            "runner=?, runner_vcpu=?, runner_ram_mb=?, collector_ver=?, notes=? WHERE id=?",
            (meta["git_sha"], meta["git_branch"], meta["git_dirty"], meta["ts_utc"],
             meta["trigger"], meta["runner"], meta["runner_vcpu"], meta["runner_ram_mb"],
             COLLECTOR_VERSION, meta["notes"], run_id))
        for t in ("design_metric", "verif_metric", "compute_metric", "ai_metric"):
            cur.execute("DELETE FROM %s WHERE run_id = ?" % t, (run_id,))
    else:
        cur.execute(
            "INSERT INTO run (run_key, git_sha, git_branch, git_dirty, ts_utc, trigger, "
            "runner, runner_vcpu, runner_ram_mb, collector_ver, notes) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            (meta["run_key"], meta["git_sha"], meta["git_branch"], meta["git_dirty"],
             meta["ts_utc"], meta["trigger"], meta["runner"], meta["runner_vcpu"],
             meta["runner_ram_mb"], COLLECTOR_VERSION, meta["notes"]))
        run_id = cur.lastrowid

    cur.executemany(
        "INSERT INTO design_metric (run_id, scope, name, value, unit, kind, source) "
        "VALUES (?,?,?,?,?,?,?)",
        [(run_id,) + r for r in rows.design.values()])
    cur.executemany(
        "INSERT INTO verif_metric (run_id, scope, name, value, unit, kind, source) "
        "VALUES (?,?,?,?,?,?,?)",
        [(run_id,) + r for r in rows.verif.values()])
    cur.executemany(
        "INSERT INTO compute_metric (run_id, scope, name, value, unit, kind, source) "
        "VALUES (?,?,?,?,?,?,?)",
        [(run_id,) + r for r in rows.compute.values()])
    cur.executemany(
        "INSERT INTO ai_metric (run_id, agent, model, name, value, unit, kind, source) "
        "VALUES (?,?,?,?,?,?,?,?)",
        [(run_id,) + r for r in rows.ai.values()])
    con.commit()
    return run_id, replaced


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def default_yosys():
    oss = os.environ.get("OSS")
    if oss:
        cand = os.path.join(oss, "bin", "yosys")
        if os.path.exists(cand):
            return cand
    cand = os.path.join(REPO, "oss-cad-suite", "bin", "yosys")
    if os.path.exists(cand):
        return cand
    return shutil.which("yosys") or ""


def default_verilator():
    env = os.environ.get("VERILATOR")
    if env and shutil.which(env):
        return env
    oss = os.environ.get("OSS") or os.path.join(REPO, "oss-cad-suite")
    cand = os.path.join(oss, "bin", "verilator")
    if os.path.exists(cand):
        return cand
    return shutil.which("verilator") or ""


def main(argv=None):
    ap = argparse.ArgumentParser(description="Collect one run of AoU metrics into SQLite.")
    ap.add_argument("--db", default=os.path.join(HERE, "metrics.db"))
    ap.add_argument("--schema", default=os.path.join(HERE, "schema.sql"))
    ap.add_argument("--coefficients", default=os.path.join(HERE, "coefficients.json"))
    ap.add_argument("--capture-dir", default=os.path.join(HERE, "_capture"))
    ap.add_argument("--gate-log", default="", help="captured gate stdout (default: <capture>/gate.log)")
    ap.add_argument("--gate-time", default="", help="/usr/bin/time -v capture (default: <capture>/gate.time)")
    ap.add_argument("--result-json", default=os.path.join(REPO, "docker", "last-run-metrics.json"))
    ap.add_argument("--stream-json", default="", help="swarm stream-json capture (default: <capture>/swarm-stream.jsonl)")
    ap.add_argument("--run-key", default="", help="idempotency key (default: <sha12>/<trigger>/<token>)")
    ap.add_argument("--trigger", default="auto", choices=["auto", "local", "ci", "railway", "swarm"])
    ap.add_argument("--notes", default="")
    ap.add_argument("--no-synth", action="store_true", help="skip the yosys design pass")
    ap.add_argument("--yosys", default="")
    ap.add_argument("--verilator", default="")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="collect and print, do not write the DB")
    args = ap.parse_args(argv)

    t_start = time.time()
    cap = args.capture_dir
    gate_log = args.gate_log or os.path.join(cap, "gate.log")
    gate_time_p = args.gate_time or os.path.join(cap, "gate.time")
    stream_p = args.stream_json or os.path.join(cap, "swarm-stream.jsonl")

    coeff = read_json(args.coefficients) or {}
    if not coeff:
        warn("coefficients file %s missing/unparseable -- every ESTIMATED row is skipped or zero"
             % args.coefficients)

    gate_lines = parse_capture_log(gate_log)
    gate_time = parse_time_v(gate_time_p)
    result = read_json(args.result_json)

    log("repo %s" % REPO, args.quiet)
    log("gate log: %s (%d lines)" % (gate_log if gate_lines else "(absent)", len(gate_lines)),
        args.quiet)

    rows = Rows()
    collect_design(rows, coeff,
                   args.yosys or default_yosys(),
                   args.verilator or default_verilator(),
                   not args.no_synth, args.quiet)
    collect_verif(rows, gate_lines, args.quiet)
    collect_compute(rows, gate_lines, gate_time, cap, coeff, args.quiet)
    collect_ai(rows, result, stream_p, coeff, args.quiet)

    # --- run identity --------------------------------------------------------
    sha = git("rev-parse", "HEAD") or "unknown"
    branch = git("rev-parse", "--abbrev-ref", "HEAD") or "unknown"
    dirty = 1 if git("status", "--porcelain") else 0
    trigger = args.trigger
    if trigger == "auto":
        kind = classify_runner()
        trigger = {"github-hosted": "ci", "self-hosted": "ci"}.get(kind, kind)
        if os.environ.get("AOU_SWARM_RUN") or (result and result.get("modelUsage")):
            trigger = "swarm"
    if args.run_key:
        run_key = args.run_key
    else:
        token = os.environ.get("GITHUB_RUN_ID", "")
        if token:
            token += "." + os.environ.get("GITHUB_RUN_ATTEMPT", "1")
        elif os.path.exists(gate_log):
            token = str(int(os.path.getmtime(gate_log)))
        else:
            token = "dev"
        run_key = "%s/%s/%s" % (sha[:12], trigger, token)

    uname = os.uname()
    meta = {
        "run_key": run_key,
        "git_sha": sha,
        "git_branch": branch,
        "git_dirty": dirty,
        "ts_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "trigger": trigger,
        "runner": "%s %s %s (%s)" % (uname.sysname, uname.release, uname.machine,
                                     classify_runner()),
        "runner_vcpu": os.cpu_count() or 0,
        "runner_ram_mb": int(next(
            (int(l.split()[1]) / 1024 for l in (read_text("/proc/meminfo") or "").splitlines()
             if l.startswith("MemTotal:")), 0)),
        "notes": args.notes,
    }

    d, v, c, a = rows.counts()
    kinds = rows.kind_counts()
    log("run_key %s (%s, branch %s%s)" % (run_key, trigger, branch, ", DIRTY" if dirty else ""),
        args.quiet)
    log("rows: design %d, verif %d, compute %d, ai %d" % (d, v, c, a), args.quiet)
    log("kinds: measured %d, estimated %d, not_attributable %d"
        % (kinds[MEASURED], kinds[ESTIMATED], kinds[GAP]), args.quiet)

    if args.dry_run:
        log("--dry-run: nothing written to %s" % args.db, args.quiet)
        return 0

    con, fresh = open_db(args.db, args.schema)
    run_id, replaced = insert_run(con, meta, rows)
    n_runs = con.execute("SELECT COUNT(*) FROM run").fetchone()[0]
    con.close()
    log("%s run id=%d in %s (%d run%s in history%s)"
        % ("replaced" if replaced else "inserted", run_id, os.path.relpath(args.db, REPO),
           n_runs, "" if n_runs == 1 else "s", ", new DB" if fresh else ""), args.quiet)
    log("done in %.1fs -- `make dashboard` to regenerate the HTML" % (time.time() - t_start),
        args.quiet)
    return 0


if __name__ == "__main__":
    sys.exit(main())
