#!/usr/bin/env python3
"""Seeded random regression driver for axi_ucie_mem_top (see README.md).

  rr.py run    --n N --jobs J [--seed S]   run N jobs, seeds S+i, write results.jsonl
  rr.py one    --seed S --config NAME      run one job (the repro command)
  rr.py triage RUN_DIR                     cluster FAILs by signature
  rr.py replay                             rerun corpus.json (fixed entries must PASS)

Exit code: run -> non-zero iff any FAIL; replay -> non-zero iff a "fixed" entry fails.
"""
import argparse
import concurrent.futures as cf
import datetime
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
BIN = os.path.join(HERE, "obj_dir", "vrr")
CORPUS = os.path.join(HERE, "corpus.json")
TIMEOUT = int(os.environ.get("RR_JOB_TIMEOUT", "300"))
REL = os.path.relpath(__file__, REPO)

# knob sets -> TB plusargs (all within what the dv/sv scoreboard checks)
CONFIGS = {
    "default":  "+xfers=200 +maxlen=15 +gap=3 +bp=25 +burst=7",
    "tight":    "+xfers=300 +maxlen=15 +gap=0 +bp=0 +burst=7",
    "bp_heavy": "+xfers=150 +maxlen=15 +gap=8 +bp=75 +burst=7",
    "hot":      "+xfers=300 +maxlen=7 +gap=1 +bp=30 +win=64 +burst=7",
    "single":   "+xfers=400 +maxlen=0 +gap=2 +bp=20 +win=256 +burst=1",
    "wrap_fix": "+xfers=200 +maxlen=15 +gap=2 +bp=40 +win=512 +burst=6",
}
ORDER = list(CONFIGS)


def signature(text, rc):
    """First failing check, with numbers normalised so equal bugs cluster."""
    for line in text.splitlines():
        m = re.search(r"\[RR-TB\] ERR ([\w-]+)", line)
        if m:
            return m.group(1)
        if "Assertion failed" in line or "%Error" in line or "%Fatal" in line:
            s = re.sub(r"0x[0-9a-fA-F]+|\d+", "N", line.strip())
            return s[:160]
    if rc != 0:
        return "exit-%d" % rc
    return "no-pass-banner"


def run_job(i, seed, config, logdir):
    log = os.path.join(logdir, "job%04d_seed%d.log" % (i, seed))
    cmd = [BIN, "+seed=%d" % seed] + CONFIGS[config].split()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
        out, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = (e.stdout or b"").decode(errors="replace") + "\n[RR-TB] ERR host-timeout\n", 124
    with open(log, "w") as f:
        f.write(out)
    ok = rc == 0 and "[RR-TB] PASS" in out and "[RR-TB] ERR" not in out
    return {
        "job": i, "seed": seed, "config": config,
        "status": "PASS" if ok else "FAIL",
        "signature": "" if ok else signature(out, rc),
        "log": os.path.relpath(log, REPO),
        "repro": "python3 %s one --seed %d --config %s" % (REL, seed, config),
    }


def need_bin():
    if not os.path.exists(BIN):
        sys.exit("rr: %s missing - run `make rr-build` first" % os.path.relpath(BIN, REPO))


def cmd_run(a):
    need_bin()
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    rundir = os.path.join(HERE, "runs", ts)
    os.makedirs(rundir, exist_ok=True)
    jobs = [(i, a.seed + i, ORDER[i % len(ORDER)] if not a.config else a.config) for i in range(a.n)]
    with cf.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        res = list(ex.map(lambda j: run_job(j[0], j[1], j[2], rundir), jobs))
    with open(os.path.join(rundir, "results.jsonl"), "w") as f:
        for r in res:
            f.write(json.dumps(r) + "\n")
    fails = sum(r["status"] == "FAIL" for r in res)
    print("rr run: %s seed_base=%d jobs=%d fail=%d" % (os.path.relpath(rundir, REPO), a.seed, a.n, fails))
    return 1 if fails else 0


def cmd_one(a):
    need_bin()
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        r = run_job(0, a.seed, a.config, d)
        print(open(os.path.join(REPO, r["log"])).read(), end="")
    print("rr one: seed=%d config=%s %s %s" % (a.seed, a.config, r["status"], r["signature"]))
    return 0 if r["status"] == "PASS" else 1


def cmd_triage(a):
    path = os.path.join(a.run, "results.jsonl")
    rows = [json.loads(l) for l in open(path) if l.strip()]
    clusters = {}
    for r in rows:
        if r["status"] == "FAIL":
            clusters.setdefault(r["signature"], []).append(r)
    print("rr triage: %s jobs=%d fail=%d clusters=%d" % (a.run, len(rows), sum(map(len, clusters.values())), len(clusters)))
    for sig, rs in sorted(clusters.items(), key=lambda kv: -len(kv[1])):
        cfgs = sorted({r["config"] for r in rs})
        print("  [%d] %s  configs=%s  repro: %s" % (len(rs), sig, ",".join(cfgs), rs[0]["repro"]))
    return 0


def cmd_replay(a):
    need_bin()
    corpus = json.load(open(CORPUS))
    bad = 0
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        for k, e in enumerate(corpus["entries"]):
            r = run_job(k, e["seed"], e["config"], d)
            fixed = e.get("fixed", False)
            gate = fixed and r["status"] != "PASS"
            bad += gate
            print("rr replay: %-24s seed=%d cfg=%s fixed=%s -> %s%s" % (
                e["name"], e["seed"], e["config"], str(fixed).lower(), r["status"],
                "  GATE-FAIL " + r["signature"] if gate else ""))
    print("rr replay: entries=%d gate_failures=%d" % (len(corpus["entries"]), bad))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    r = sp.add_parser("run"); r.add_argument("--n", type=int, default=10)
    r.add_argument("--jobs", type=int, default=2); r.add_argument("--seed", type=int, default=1)
    r.add_argument("--config", choices=ORDER)
    o = sp.add_parser("one"); o.add_argument("--seed", type=int, required=True)
    o.add_argument("--config", choices=ORDER, default="default")
    t = sp.add_parser("triage"); t.add_argument("run")
    sp.add_parser("replay")
    a = ap.parse_args()
    sys.exit({"run": cmd_run, "one": cmd_one, "triage": cmd_triage, "replay": cmd_replay}[a.cmd](a))


if __name__ == "__main__":
    main()
