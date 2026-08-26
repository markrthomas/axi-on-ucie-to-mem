#!/usr/bin/env python3
"""wave_check.py - drift-guard for the curated GTKWave layouts in dv/waves/.

A `.gtkw` save file is a flat list of hierarchical net paths.  When RTL is
renamed or a scope moves (e.g. the single-plane chain gaining its `g_rp1`
generate wrapper) GTKWave silently drops the entries it cannot resolve, so the
layout rots into a half-empty pane and nobody notices until the next debug
session.  This script is the `eda-check` of the wave layer: for every layout it
resolves EVERY referenced net path against the signal hierarchy of that
layout's real dump and fails, naming the orphaned path, when one no longer
exists.

Usage
    wave_check.py <repo-root> [layout.gtkw ...]      # default: dv/waves/*.gtkw

The dump belonging to a layout comes from its own `[dumpfile]` line (a path
relative to the repo root); the `[*] wave-check: env=<env>` header names the
`make waves-<env>` target that regenerates it.  A missing dump is a graceful
SKIP (with the command to produce it), never a failure - this target is
dev/opt-in and must degrade on a host without the simulators.

The hierarchy is read with the oss-cad-suite `fst2vcd` (GTKWave's own reader,
so a path this script accepts is a path GTKWave resolves): its VCD header is
walked $scope/$upscope/$var to rebuild the fully qualified names.  Point
FST2VCD=<path> or OSS=<oss-cad-suite root> at it; a plain `.vcd` dump is parsed
directly.  With no reader available the run SKIPs rather than failing.
"""

import os
import re
import subprocess
import sys

BANNER = "[WAVE-CHECK]"

# .gtkw line kinds we must not mistake for a net path.
RE_DIRECTIVE = re.compile(r"^\[")        # [dumpfile] / [timestart] / [treeopen] ...
RE_FLAGS = re.compile(r"^@")             # @22 / @800200 (trace flags, group markers)
RE_COMMENT = re.compile(r"^[-#]")        # -Group label / #comment
RE_ALIAS = re.compile(r"^\+\{[^}]*\}\s*")  # +{Human alias} net.path[3:0]
RE_RANGE = re.compile(r"^(?P<path>.*?)(?:\[(?P<msb>-?\d+)(?::(?P<lsb>-?\d+))?\])?$")

GRP_BEGIN = "@800200"
GRP_END = "@1000200"


def fst2vcd_bin():
    """Locate GTKWave's fst2vcd, or None when no reader is installed."""
    cand = os.environ.get("FST2VCD")
    if cand and os.path.exists(cand):
        return cand
    oss = os.environ.get("OSS")
    if oss:
        cand = os.path.join(oss, "bin", "fst2vcd")
        if os.path.exists(cand):
            return cand
    for d in os.environ.get("PATH", "").split(os.pathsep):
        cand = os.path.join(d, "fst2vcd")
        if os.path.exists(cand):
            return cand
    return None


def vcd_header(dump):
    """Yield the VCD definition lines of `dump` (an .fst is converted first)."""
    if dump.endswith(".vcd"):
        with open(dump, errors="replace") as fh:
            for line in fh:
                yield line
                if line.startswith("$enddefinitions"):
                    return
        return
    exe = fst2vcd_bin()
    if exe is None:
        raise RuntimeError("fst2vcd not found (set FST2VCD=<path> or OSS=<root>)")
    proc = subprocess.run([exe, "-f", dump], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError("fst2vcd failed on %s: %s" % (dump, proc.stderr.strip()))
    for line in proc.stdout.splitlines():
        yield line
        if line.startswith("$enddefinitions"):
            return


def dump_signals(dump):
    """{fully.qualified.name: (msb, lsb)} for every net in `dump`.

    Scalars map to (None, None).  Sub-ranged .gtkw entries are validated
    against the declared range, so a narrowed vector is caught too.
    """
    sigs = {}
    scope = []
    for line in vcd_header(dump):
        line = line.strip()
        if line.startswith("$scope"):
            scope.append(line.split()[2])
        elif line.startswith("$upscope"):
            if scope:
                scope.pop()
        elif line.startswith("$var"):
            parts = line.split()
            # $var <type> <size> <id> <ref> [<range>] $end
            name = parts[4]
            rng = parts[5] if len(parts) > 5 and parts[5] != "$end" else ""
            msb = lsb = None
            m = re.match(r"^\[(-?\d+)(?::(-?\d+))?\]$", rng)
            if m:
                msb = int(m.group(1))
                lsb = int(m.group(2)) if m.group(2) is not None else msb
            sigs[".".join(scope + [name])] = (msb, lsb)
        elif line.startswith("$enddefinitions"):
            break
    return sigs


def parse_layout(path):
    """-> (env, dumpfile, [(lineno, net_path), ...], [group-marker errors])."""
    env = None
    dumpfile = None
    nets = []
    depth = 0
    errs = []
    with open(path, errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line:
                continue
            if line.startswith("[*]"):
                m = re.search(r"wave-check:\s*env=(\S+)", line)
                if m:
                    env = m.group(1)
                continue
            if RE_DIRECTIVE.match(line):
                m = re.match(r"^\[dumpfile\]\s+\"?([^\"]+)\"?\s*$", line)
                if m:
                    dumpfile = m.group(1)
                continue
            if RE_FLAGS.match(line):
                if line == GRP_BEGIN:
                    depth += 1
                elif line == GRP_END:
                    depth -= 1
                    if depth < 0:
                        errs.append("%s:%d: group close without a matching open"
                                    % (path, lineno))
                        depth = 0
                continue
            if RE_COMMENT.match(line):
                continue
            nets.append((lineno, RE_ALIAS.sub("", line).strip()))
    if depth:
        errs.append("%s: %d group(s) opened but never closed" % (path, depth))
    return env, dumpfile, nets, errs


def check_layout(root, layout, sigs):
    """-> list of human-readable orphan descriptions."""
    bad = []
    for lineno, net in parse_layout(layout)[2]:
        m = RE_RANGE.match(net)
        base = m.group("path")
        if base in sigs:
            msb, lsb = sigs[base]
            if m.group("msb") is None:
                continue
            hi = int(m.group("msb"))
            lo = int(m.group("lsb")) if m.group("lsb") is not None else hi
            if msb is None:
                bad.append("%s:%d: %s is a scalar in the dump, layout asks for "
                           "a bit range" % (layout, lineno, base))
            elif max(hi, lo) > max(msb, lsb) or min(hi, lo) < min(msb, lsb):
                bad.append("%s:%d: %s[%d:%d] is outside the dump's [%d:%d]"
                           % (layout, lineno, base, hi, lo, msb, lsb))
            continue
        # Not found: is it a rename, or did a whole scope move?
        scope = base.rsplit(".", 1)[0] if "." in base else base
        hint = ""
        if not any(s.startswith(scope + ".") for s in sigs):
            hint = "  (scope '%s' is not in the dump either)" % scope
        bad.append("%s:%d: orphaned net path '%s'%s" % (layout, lineno, net, hint))
    return bad


def main(argv):
    if len(argv) < 2:
        print("%s usage: wave_check.py <repo-root> [layout.gtkw ...]" % BANNER)
        return 2
    root = os.path.abspath(argv[1])
    layouts = argv[2:]
    if not layouts:
        wdir = os.path.join(root, "dv", "waves")
        layouts = sorted(os.path.join(wdir, f) for f in os.listdir(wdir)
                         if f.endswith(".gtkw"))
    if not layouts:
        print("%s no .gtkw layouts found under dv/waves/" % BANNER)
        return 1

    failures = []
    checked = skipped = 0
    for layout in layouts:
        rel = os.path.relpath(layout, root)
        env, dumpfile, nets, errs = parse_layout(layout)
        failures += errs
        if not dumpfile:
            failures.append("%s: no [dumpfile] line - cannot resolve its dump" % rel)
            continue
        dump = dumpfile if os.path.isabs(dumpfile) else os.path.join(root, dumpfile)
        if not os.path.exists(dump):
            how = "make waves-%s" % env if env else "the env's waves target"
            print("%s SKIP %-34s no dump at %s (run `%s`)"
                  % (BANNER, rel, dumpfile, how))
            skipped += 1
            continue
        try:
            sigs = dump_signals(dump)
        except (RuntimeError, OSError) as exc:
            print("%s SKIP %-34s %s" % (BANNER, rel, exc))
            skipped += 1
            continue
        bad = check_layout(root, rel, sigs)
        checked += 1
        if bad:
            failures += bad
            print("%s FAIL %-34s %d of %d net path(s) no longer exist"
                  % (BANNER, rel, len(bad), len(nets)))
        else:
            print("%s ok   %-34s %d net paths resolved against %s"
                  % (BANNER, rel, len(nets), dumpfile))

    if failures:
        print("")
        for f in failures:
            print("%s   %s" % (BANNER, f))
        print("%s FAIL: %d stale entry/entries - a renamed or moved signal has "
              "left the layout behind." % (BANNER, len(failures)))
        print("%s        Fix the .gtkw net path (or the RTL), then re-run "
              "`make wave-check`." % BANNER)
        return 1

    print("%s PASS: %d layout(s) verified, %d skipped (no dump)."
          % (BANNER, checked, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
