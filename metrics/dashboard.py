#!/usr/bin/env python3
"""[DASH] renderer -- metrics/metrics.db -> a single self-contained HTML file.

Reads the committed SQLite history and writes metrics/dashboard.html with the
CSS, the JavaScript and the DATA all inlined: no CDN, no <script src>, no web
font, no fetch.  It therefore renders from a `file://` URL with the network off
and can be published verbatim as a CI Artifact.  The generator asserts that
before it writes (see check_self_contained) -- an external asset reference is a
hard failure, not a warning.

Charts are hand-rolled inline SVG (one polyline + axes per metric); there is no
charting library to vendor and nothing to fetch.

Every value keeps the `kind` the collector gave it, and the legend/badges keep
measured, estimated and not-attributable visually distinct -- the whole point of
the exercise is that a MODELED energy figure never gets mistaken for a
measurement.

Usage:
  metrics/dashboard.py [--db metrics/metrics.db] [--out metrics/dashboard.html]
                       [--runs N] [--coefficients metrics/coefficients.json]
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

MEASURED = "measured"
ESTIMATED = "estimated"
GAP = "not_attributable"

DOMAINS = [
    ("design", "Design / RTL",
     "Size and shape of the RTL. Gate counts come from an out-of-gate yosys "
     "generic-cell synthesis -- there is no liberty file, so they are estimates "
     "whose value is the TREND, not the absolute number."),
    ("verif", "Verification / coverage",
     "What the eight DV environments and the four formal proofs actually "
     "checked, plus the coverage they closed."),
    ("compute", "CI / compute",
     "What the gate cost to run. Totals come from /usr/bin/time -v (exact); the "
     "per-step split is derived from a timestamped gate log and is approximate "
     "because the C tools block-buffer under a pipe."),
    ("ai", "AI / swarm",
     "What the agents that built this spent. Token counts and wall times are "
     "measured; cost and energy are MODELED from metrics/coefficients.json. "
     "Claude Code's per-model usage AGGREGATES subagents, so per-agent rows are "
     "reconstructed from the stream-json capture -- and where they cannot be, "
     "the gap is recorded instead of a number."),
]

# Metrics promoted to a trend chart, per domain, in display order.  Everything
# else still appears in that domain's table.
HEADLINES = {
    "design": ["gate_equivalents", "cells", "flops", "comb_path_levels",
               "fmax_mhz", "rtl_loc_code", "rtl_modules", "verilator_warnings"],
    "verif": ["line_coverage_pct", "func_coverage_pct", "sva_assertions",
              "immediate_assertions", "immediate_covers", "proofs_passing",
              "tests_passing"],
    "compute": ["wall_s", "core_seconds", "peak_rss_mb", "build_s", "run_s",
                "ci_cost_usd", "cpu_energy_wh"],
    "ai": ["total_tokens", "output_tokens", "cost_usd", "inference_energy_wh",
           "cache_hit_ratio", "turns", "agents_dispatched", "output_tokens_per_s",
           "pr_files_changed"],
}
# Scopes a headline chart is allowed to come from ('' = whole design/run).
HEADLINE_SCOPES = {"", "gate", "cocotb"}


def esc(s):
    return html.escape("" if s is None else str(s), quote=True)


def fmt(v, unit=""):
    if v is None:
        return "n/a"
    if unit == "bool":
        return "yes" if v else "no"
    av = abs(v)
    if av >= 1e6:
        s = "%.2fM" % (v / 1e6)
    elif av >= 1e4:
        s = "%.1fk" % (v / 1e3)
    elif av >= 100:
        s = "%.0f" % v
    elif av >= 1:
        s = "%.2f" % v
    elif v == 0:
        s = "0"
    else:
        s = "%.4g" % v
    if s.endswith(".00"):
        s = s[:-3]
    return s + ((" " + unit) if unit and unit not in ("bool",) else "")


# --------------------------------------------------------------------------- #
# data
# --------------------------------------------------------------------------- #
def load(db_path, limit):
    if not os.path.exists(db_path):
        raise SystemExit("[DASH] FAIL: %s does not exist -- run `make metrics` first" % db_path)
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    runs = list(con.execute(
        "SELECT * FROM run ORDER BY id DESC LIMIT ?", (limit,)))[::-1]
    if not runs:
        raise SystemExit("[DASH] FAIL: %s has no runs -- run `make metrics` first" % db_path)
    ids = [r["id"] for r in runs]
    qmarks = ",".join("?" * len(ids))
    series = {}   # (domain, scope, name) -> {run_id: (value, unit, kind, source)}
    for row in con.execute(
            "SELECT domain, run_id, scope, name, value, unit, kind, source "
            "FROM v_metric WHERE run_id IN (%s)" % qmarks, ids):
        key = (row["domain"], row["scope"], row["name"])
        series.setdefault(key, {})[row["run_id"]] = (
            row["value"], row["unit"] or "", row["kind"], row["source"] or "")
    con.close()
    return runs, series


def regression_policy(coeff):
    reg = (coeff or {}).get("regression", {})
    return reg.get("direction", {}), float(reg.get("tolerance_pct", 2.0))


def verdict(name, cur, prev, direction, tol):
    """-> ('better'|'worse'|'flat'|'', delta, pct) for the latest step.

    `pct` is None when the previous value was 0 (no meaningful percentage) --
    but the verdict is still computed, because 0 -> 5 new Verilator warnings is
    exactly the kind of regression this is here to catch.
    """
    if cur is None or prev is None:
        return "", None, None
    delta = cur - prev
    pct = (100.0 * delta / abs(prev)) if prev else None
    want = direction.get(name)
    if want is None:
        for key, d in direction.items():
            if name.endswith(key):
                want = d
                break
    if want is None or delta == 0 or (pct is not None and abs(pct) < tol):
        return "flat", delta, pct
    good = (delta > 0) if want == "up" else (delta < 0)
    return ("better" if good else "worse"), delta, pct


def pct_txt(pct):
    return ("%+.1f%%" % pct) if pct is not None else "from 0"


# --------------------------------------------------------------------------- #
# inline SVG chart (no library, no fetch)
# --------------------------------------------------------------------------- #
def sparkline(points, kind, w=260, h=90, pad=6):
    """points: list of (x_index, value|None).  Returns an <svg> string."""
    vals = [v for _i, v in points if v is not None]
    if not vals:
        return '<div class="nochart">no numeric history</div>'
    lo, hi = min(vals), max(vals)
    if hi == lo:
        lo, hi = lo - (abs(lo) * 0.05 + 1), hi + (abs(hi) * 0.05 + 1)
    n = max(1, len(points) - 1)
    iw, ih = w - 2 * pad, h - 2 * pad

    def px(i):
        return pad + (iw * i / n)

    def py(v):
        return pad + ih - ih * (v - lo) / (hi - lo)

    segs, cur = [], []
    for i, v in points:
        if v is None:
            if len(cur) > 1:
                segs.append(cur)
            cur = []
        else:
            cur.append("%.1f,%.1f" % (px(i), py(v)))
    if len(cur) > 1:
        segs.append(cur)
    cls = "line " + kind
    body = "".join('<polyline class="%s" points="%s"/>' % (cls, " ".join(s)) for s in segs)
    if not segs:
        # A single sample: show it as a dot so the panel is not blank.
        for i, v in points:
            if v is not None:
                body += '<circle class="dot %s" cx="%.1f" cy="%.1f" r="3"/>' % (kind, px(i), py(v))
    else:
        last_i, last_v = [(i, v) for i, v in points if v is not None][-1]
        body += '<circle class="dot %s" cx="%.1f" cy="%.1f" r="3"/>' % (kind, px(last_i), py(last_v))
    grid = ('<line class="ax" x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f"/>'
            % (pad, pad + ih, pad + iw, pad + ih))
    return ('<svg viewBox="0 0 %d %d" preserveAspectRatio="none" role="img">%s%s</svg>'
            % (w, h, grid, body))


# --------------------------------------------------------------------------- #
# HTML
# --------------------------------------------------------------------------- #
CSS = """
:root{--bg:#0f1117;--panel:#171a23;--panel2:#1d2230;--fg:#e6e9ef;--dim:#98a1b3;
--line:#2a3040;--measured:#4fc3f7;--estimated:#ffb74d;--gap:#8a8f9c;
--good:#66bb6a;--bad:#ef5350;}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
font:14px/1.5 ui-sans-serif,system-ui,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
header{padding:22px 26px 10px;border-bottom:1px solid var(--line)}
h1{margin:0 0 4px;font-size:20px;letter-spacing:.2px}
h2{margin:26px 0 2px;font-size:16px}
.sub{color:var(--dim);font-size:12.5px;margin:0}
.wrap{padding:0 26px 60px;max-width:1500px}
.legend{display:flex;gap:16px;flex-wrap:wrap;margin:12px 0 4px;font-size:12px;
color:var(--dim);align-items:center}
.badge{display:inline-block;padding:1px 7px;border-radius:9px;font-size:11px;
font-weight:600;letter-spacing:.2px;white-space:nowrap}
.badge.measured{background:rgba(79,195,247,.16);color:var(--measured)}
.badge.estimated{background:rgba(255,183,77,.16);color:var(--estimated)}
.badge.not_attributable{background:rgba(138,143,156,.18);color:var(--gap)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(275px,1fr));
gap:12px;margin-top:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:11px 12px}
.card .k{font-size:12px;color:var(--dim);display:flex;justify-content:space-between;gap:8px}
.card .v{font-size:22px;font-weight:600;margin:2px 0 1px}
.card .d{font-size:12px;min-height:17px}
.card svg{width:100%;height:74px;margin-top:5px;display:block}
svg .line{fill:none;stroke-width:1.8;vector-effect:non-scaling-stroke}
svg .line.measured{stroke:var(--measured)} svg .line.estimated{stroke:var(--estimated)}
svg .line.not_attributable{stroke:var(--gap)}
svg .dot{stroke:none} svg .dot.measured{fill:var(--measured)}
svg .dot.estimated{fill:var(--estimated)} svg .dot.not_attributable{fill:var(--gap)}
svg .ax{stroke:var(--line);stroke-width:1;vector-effect:non-scaling-stroke}
.nochart{color:var(--dim);font-size:12px;padding:24px 0;text-align:center}
.better{color:var(--good)} .worse{color:var(--bad)} .flat{color:var(--dim)}
table{border-collapse:collapse;width:100%;margin-top:10px;font-size:13px}
th,td{text-align:left;padding:5px 9px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--dim);font-weight:600;font-size:12px;position:sticky;top:0;background:var(--bg)}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
tr.gap td{color:var(--dim)}
.src{color:var(--dim);font-size:11.5px;max-width:640px}
.controls{margin:14px 0 0;display:flex;gap:14px;flex-wrap:wrap;align-items:center;font-size:12.5px}
.controls label{color:var(--dim);cursor:pointer;user-select:none}
.flags{background:var(--panel2);border:1px solid var(--line);border-left:3px solid var(--bad);
border-radius:7px;padding:10px 13px;margin-top:14px}
.flags.none{border-left-color:var(--good)}
.flags ul{margin:6px 0 0;padding-left:18px} .flags li{margin:2px 0}
code{background:var(--panel2);padding:1px 5px;border-radius:4px;font-size:12px}
footer{color:var(--dim);font-size:12px;padding:18px 26px;border-top:1px solid var(--line)}
.runbar{display:flex;gap:18px;flex-wrap:wrap;color:var(--dim);font-size:12.5px;margin-top:6px}
body.hide-gaps tr.gap{display:none}
"""

JS = """
(function(){
  var cb=document.getElementById('showgaps');
  function apply(){document.body.classList.toggle('hide-gaps',!cb.checked);}
  cb.addEventListener('change',apply); apply();
  // Every cell with a data-src gets its provenance as a native tooltip: no
  // library, no fetch, works from file://.
  var n=document.querySelectorAll('[data-src]');
  for(var i=0;i<n.length;i++){n[i].title=n[i].getAttribute('data-src');}
})();
"""


def build_html(runs, series, coeff, db_path):
    direction, tol = regression_policy(coeff)
    ids = [r["id"] for r in runs]
    idx = {rid: i for i, rid in enumerate(ids)}
    latest, prev = ids[-1], (ids[-2] if len(ids) > 1 else None)
    last = runs[-1]

    def cell(key, rid):
        return series.get(key, {}).get(rid)

    regressions = []
    parts = []
    parts.append("<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\">")
    parts.append("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">")
    parts.append("<title>AoU DV metrics dashboard</title>")
    parts.append("<style>%s</style></head><body>" % CSS)

    parts.append("<header><h1>axi-on-ucie-to-mem &mdash; DV metrics</h1>")
    parts.append("<p class=\"sub\">Design, verification, compute and AI/swarm numbers "
                 "per run. Self-contained: CSS, JS and data are inlined &mdash; no "
                 "external requests, opens offline.</p>")
    parts.append("<div class=\"runbar\">")
    for label, val in (
            ("run", "#%d" % last["id"]),
            ("commit", (last["git_sha"] or "")[:12] + (" (dirty)" if last["git_dirty"] else "")),
            ("branch", last["git_branch"]),
            ("when", last["ts_utc"]),
            ("trigger", last["trigger"]),
            ("runner", "%s, %s vCPU, %s MB" % (last["runner"], last["runner_vcpu"],
                                               last["runner_ram_mb"])),
            ("history", "%d run(s) shown" % len(runs))):
        parts.append("<span><b>%s</b> %s</span>" % (esc(label), esc(val)))
    parts.append("</div>")
    parts.append("<div class=\"legend\">"
                 "<span class=\"badge measured\">measured</span> read from a real artifact"
                 "<span class=\"badge estimated\">estimated</span> MODELED from measured inputs "
                 "&times; a documented coefficient (<code>metrics/coefficients.json</code>)"
                 "<span class=\"badge not_attributable\">not attributable</span> the tooling "
                 "cannot supply this &mdash; the reason is recorded, never a made-up number"
                 "</div>")
    parts.append("<div class=\"controls\">"
                 "<label><input type=\"checkbox\" id=\"showgaps\" checked> "
                 "show not-attributable rows</label></div>")
    parts.append("</header><div class=\"wrap\">")

    flags_slot = len(parts)
    parts.append("")   # regression banner, filled in once every domain is walked

    for domain, title, blurb in DOMAINS:
        keys = sorted(k for k in series if k[0] == domain)
        if not keys:
            continue
        parts.append("<h2>%s</h2><p class=\"sub\">%s</p>" % (esc(title), esc(blurb)))

        # --- headline trend cards -------------------------------------------
        wanted = HEADLINES.get(domain, [])
        cards = []
        for name in wanted:
            for key in keys:
                if key[2] != name or key[1] not in HEADLINE_SCOPES:
                    continue
                pts = []
                kind = MEASURED
                unit = ""
                for rid in ids:
                    c = cell(key, rid)
                    if c is None:
                        pts.append((idx[rid], None))
                        continue
                    pts.append((idx[rid], c[0]))
                    unit = c[1] or unit
                    if c[2] != GAP:
                        kind = c[2]
                cur = cell(key, latest)
                if cur is None or cur[0] is None:
                    continue
                pv = cell(key, prev) if prev else None
                v, dlt, pct = verdict(name, cur[0], pv[0] if pv else None, direction, tol)
                if v == "worse":
                    regressions.append((title, key[1], name, cur[0], pv[0], pct, cur[1]))
                delta_txt = ""
                if dlt is not None and v:
                    arrow = "&#9650;" if dlt > 0 else ("&#9660;" if dlt < 0 else "&#8722;")
                    delta_txt = ('<span class="%s">%s %s (%s)%s</span>'
                                 % (v, arrow, fmt(abs(dlt), cur[1]), pct_txt(pct),
                                    " regression" if v == "worse" else ""))
                elif prev is None:
                    delta_txt = '<span class="flat">first run</span>'
                else:
                    delta_txt = '<span class="flat">no prior value</span>'
                scope_lbl = (" &middot; " + esc(key[1])) if key[1] else ""
                cards.append(
                    '<div class="card"><div class="k"><span>%s%s</span>'
                    '<span class="badge %s">%s</span></div>'
                    '<div class="v" data-src="%s">%s</div><div class="d">%s</div>%s</div>'
                    % (esc(name), scope_lbl, cur[2], cur[2].replace("_", " "),
                       esc(cur[3]), fmt(cur[0], cur[1]), delta_txt,
                       sparkline(pts, cur[2])))
        if cards:
            parts.append('<div class="cards">%s</div>' % "".join(cards))

        # --- full table ------------------------------------------------------
        parts.append("<table><thead><tr><th>scope</th><th>metric</th>"
                     "<th class=\"num\">value</th><th class=\"num\">vs prev</th>"
                     "<th>kind</th><th>source / why not attributable</th></tr></thead><tbody>")
        for key in keys:
            cur = cell(key, latest)
            if cur is None:
                continue
            pv = cell(key, prev) if prev else None
            v, dlt, pct = verdict(key[2], cur[0], pv[0] if pv else None, direction, tol)
            if v == "worse" and not any(r[2] == key[2] and r[1] == key[1] for r in regressions):
                regressions.append((title, key[1], key[2], cur[0], pv[0], pct, cur[1]))
            dcell = "&mdash;"
            if dlt is not None and v:
                dcell = '<span class="%s">%s</span>' % (v, pct_txt(pct))
            parts.append(
                '<tr class="%s"><td>%s</td><td>%s</td><td class="num">%s</td>'
                '<td class="num">%s</td><td><span class="badge %s">%s</span></td>'
                '<td class="src">%s</td></tr>'
                % ("gap" if cur[2] == GAP else "", esc(key[1]) if key[1] else "&mdash;",
                   esc(key[2]),
                   fmt(cur[0], cur[1]), dcell, cur[2], cur[2].replace("_", " "), esc(cur[3])))
        parts.append("</tbody></table>")

    # --- regression banner (now that we know) --------------------------------
    if prev is None:
        banner = ('<div class="flags none"><b>Trends</b><br>Only one run in the '
                  'database &mdash; nothing to compare against yet. Collect another run '
                  '(<code>make metrics</code>) and the charts start trending.</div>')
    elif regressions:
        items = "".join(
            "<li><b>%s</b> &middot; %s%s: %s &rarr; %s (%s)</li>"
            % (esc(sec), esc(scope + " / ") if scope else "", esc(name),
               fmt(pvv, unit), fmt(cv, unit), pct_txt(pc))
            for sec, scope, name, cv, pvv, pc, unit in regressions)
        banner = ('<div class="flags"><b>%d regression(s) vs the previous run</b> '
                  '(dead-band %.1f%%, direction policy in '
                  '<code>metrics/coefficients.json:regression</code>)<ul>%s</ul></div>'
                  % (len(regressions), tol, items))
    else:
        banner = ('<div class="flags none"><b>No regressions</b> vs the previous run '
                  '(dead-band %.1f%%).</div>' % tol)
    parts[flags_slot] = banner

    parts.append("</div><footer>Generated %s from <code>%s</code> by "
                 "<code>metrics/dashboard.py</code> (<code>make dashboard</code>). "
                 "Cost and energy figures are MODELED estimates from "
                 "<code>metrics/coefficients.json</code>, never measurements. "
                 "Hover any value for its provenance.</footer>"
                 % (datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    esc(os.path.relpath(db_path, REPO))))
    parts.append("<script>%s</script></body></html>" % JS)
    return "".join(parts), regressions


# --------------------------------------------------------------------------- #
# self-containment check
# --------------------------------------------------------------------------- #
# Anything that would make the browser reach out over the network.  Plain text
# that merely mentions a URL is fine; an ASSET REFERENCE is not.
EXTERNAL_PATTERNS = [
    (re.compile(r"""<(?:script|img|iframe|embed|source|video|audio)\b[^>]*\bsrc\s*=""", re.I),
     "element with a src= attribute"),
    (re.compile(r"""<link\b[^>]*\bhref\s*=""", re.I), "<link> stylesheet/icon"),
    (re.compile(r"""@import\b""", re.I), "CSS @import"),
    (re.compile(r"""url\(\s*['\"]?https?:""", re.I), "CSS url() over http(s)"),
    (re.compile(r"""\b(?:fetch|XMLHttpRequest|importScripts)\s*\(""", re.I),
     "JavaScript network call"),
]


def check_self_contained(doc):
    """Return a list of offending descriptions (empty == self-contained)."""
    return [why for rx, why in EXTERNAL_PATTERNS if rx.search(doc)]


def main(argv=None):
    ap = argparse.ArgumentParser(description="Render metrics.db to a self-contained HTML page.")
    ap.add_argument("--db", default=os.path.join(HERE, "metrics.db"))
    ap.add_argument("--out", default=os.path.join(HERE, "dashboard.html"))
    ap.add_argument("--coefficients", default=os.path.join(HERE, "coefficients.json"))
    ap.add_argument("--runs", type=int, default=20, help="how many recent runs to trend")
    args = ap.parse_args(argv)

    coeff = {}
    try:
        with open(args.coefficients, encoding="utf-8") as fh:
            coeff = json.load(fh)
    except (OSError, json.JSONDecodeError):
        print("[DASH] note: no usable %s -- regression flags fall back to defaults"
              % args.coefficients, file=sys.stderr)

    runs, series = load(args.db, max(1, args.runs))
    doc, regressions = build_html(runs, series, coeff, args.db)

    bad = check_self_contained(doc)
    if bad:
        print("[DASH] FAIL: the page is not self-contained: %s" % "; ".join(bad),
              file=sys.stderr)
        return 1

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(doc)
    rel = os.path.relpath(args.out, REPO)
    print("[DASH] wrote %s (%.1f KiB, %d run(s), %d metric series)"
          % (rel, len(doc.encode("utf-8")) / 1024.0, len(runs), len(series)))
    print("[DASH] self-contained: no external asset references (inlined CSS + JS + data)")
    print("[DASH] %s" % ("%d regression(s) flagged" % len(regressions) if regressions
                         else "no regressions flagged"))
    print("[DASH] open it with: xdg-open %s   (works offline / as a CI Artifact)" % rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
