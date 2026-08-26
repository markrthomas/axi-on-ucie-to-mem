---
status: ready
---

# Swarm implementation plan

<!--
  status: draft = ignored. status: ready = the Plan swarm implements this on a
  push to main (.github/workflows/plan-swarm.yml). Review the resulting PR, then
  set status back to draft. See docs/DOCKER.md -> "Plan-driven swarm".
-->

## Goal

**Feature 3 of 3 — a metrics database + self-contained HTML dashboard.** Capture,
per run, the design/verification/compute/AI numbers that show how the DV suite (and
the swarm that builds it) is doing over time, store them in a **committed SQLite
DB**, and render a **single self-contained HTML dashboard** (inlined CSS/JS + data,
no external requests — publishable as an Artifact) with **trend graphs**. New
`make metrics` (collect → insert a row) and `make dashboard` (regenerate the HTML)
targets; both are **opt-in and outside the gate**.

The overriding rule for this feature: **measurement must never change the thing it
measures.** Metrics collection runs as its **own step**, never inside a timed DV
run, and **must not alter `make check`/`regress`/`ci` pass/fail or their timings**.
And every number is labeled **measured** or **estimated** — never blurred.

## Hard invariant — the gate is byte-identical and un-perturbed

`make check`/`regress`/`ci` at their defaults stay **bit-and-cycle identical** and
**equally fast** — they do not collect metrics, synthesize, or write the DB. All of
F3 lives behind `make metrics`/`make dashboard` (and a CI step that runs *after* the
gate). Prove it: gate banners/read-counts unchanged, SystemC `sc.log` diff clean,
and no new work inside any DV env's timed region.

## Store & artifact

- **SQLite, committed:** `metrics/metrics.db` — a normalized schema: a `run` table
  (id, git SHA, branch, UTC timestamp, trigger, runner) plus per-domain tables
  (`design_metric`, `verif_metric`, `compute_metric`, `ai_metric`, each keyed by
  run_id + name + value + unit + a `kind` column = `measured`|`estimated`). Keep
  history append-only so the dashboard can trend. Commit the DB (it's small); the
  collector is idempotent per (run_id).
- **Self-contained dashboard:** `make dashboard` → `metrics/dashboard.html`, a single
  file with **inlined** CSS/JS and the data embedded (read from the DB at generate
  time) — **no external fetches/CDNs** so it renders offline and can be published as
  an Artifact. Trend line/bar charts (hand-rolled inline SVG or a vendored, inlined
  micro-charting helper — no CDN). Sections mirror the domains below; each chart
  shows the metric over the last N runs and flags regressions.

## What to collect (per run)

Split **measured** vs **estimated** everywhere; document the source of each.

1. **Design / RTL** — est gate count **total and per-module** (yosys generic-cell
   synth: `read_slang`→`synth`→`stat`), flop count, RTL LOC per module + module
   count, Verilator `-Wall` warning count, and (best-effort) a longest-comb-path /
   Fmax **estimate** from yosys+abc if cheap — clearly labeled estimate (no real
   liberty timing). Run synth in the metrics step, never in the gate.
2. **Verification / coverage** — line-cov % (reuse `make coverage`) and functional-
   cov % (`[COV-FUNC]`) per env, SVA assertion count, formal proof count + per-
   property solve time + bmc depth (parse `sby` output), per-env test/check counts,
   sim cycles + sim wall time + throughput (cycles/s), and build-vs-run time split.
3. **CI / compute** — total + per-step/per-env wall time, CPU core-seconds
   (peak+avg), peak RSS per build (reuse the `VL_JOBS`/`/usr/bin/time -v` route),
   oss-cad-suite cache hit/miss, runner type/vCPU/RAM, and an **estimated** CI
   compute cost (documented coefficient).
4. **AI / swarm** — **per-AGENT** usage + performance for each swarm agent
   (swarm-manager, each dv-env-tester, infra-agent, dv-runner): wall time, turns,
   tool-call count, tool-error/retry rate, and tokens where attributable.
   **Per-(agent × model)** breakdown — split each agent by the model it ran
   (opus/sonnet/haiku via the alias map in `docker/provider-env.sh`): tokens, time,
   cost, throughput. **Inference efficiency** — output tokens/s, est cost per unit
   work, and **energy usage as a MODELED ESTIMATE** (token counts × published
   per-token inference-energy coefficients (Wh/1k tok by model class), optionally +
   CPU energy = CPU-seconds × TDP for sim/synth). Ship a documented **coefficient
   table** (`metrics/coefficients.*`) and label every cost/energy figure an estimate;
   keep measured token/time data separate from modeled figures. Also: prompt-cache
   hit ratio (cacheRead vs cacheCreation), agents dispatched + parallelism achieved,
   wall-vs-API time, and PR outcome (files changed, +/- lines, human-fix needed).
   **Feasibility (READ):** Claude Code headless `modelUsage` is per-MODEL and
   **aggregates** subagents — per-agent numbers must be reconstructed from the
   `stream-json` Task/subagent spans (wall time, turns, tool calls; per-agent tokens
   only where sidechain usage events expose them). **Capture what IS attributable,
   DOCUMENT any gap in the schema + dashboard, and NEVER fabricate a per-agent
   number.** Reuse the existing `docker/render-metrics.py` + `last-run-metrics.json`
   pipeline where it already parses this.
5. **Trends** — per-metric delta vs the previous run; **flag regressions** (coverage
   down, gate count up, runtime up, warnings up) with a visible marker on the
   dashboard; keep the history in SQLite.

## Scope & files

1. `metrics/collect.py` — the collector: gathers domains 1–5 from a completed run's
   artifacts (coverage info, `sby` logs, `/usr/bin/time` captures, the swarm
   `stream-json`/`last-run-metrics.json`, a separate yosys synth pass), and inserts
   one `run` row + child rows. Idempotent; measured/estimated tagged.
2. `metrics/schema.sql`, `metrics/metrics.db` (committed), `metrics/coefficients.*`
   (energy/cost coefficients + provenance).
3. `metrics/dashboard.py` — reads the DB → writes self-contained `metrics/dashboard.html`.
4. Root `Makefile`: `metrics` (collect a row) and `dashboard` (regen HTML) targets +
   `.PHONY` + `help` lines; **NOT** folded into `check`/`regress`/`ci`.
5. CI/entrypoint: a **post-gate** step (after `make ci` succeeds) that runs
   `make metrics` and (optionally) `make dashboard`, so the gate timing it records
   is clean. Document that this is additive and cannot fail the gate.
6. **Docs (required, same PR):** `README.md` (a "Metrics & dashboard" section: what's
   collected, measured-vs-estimated, how to view/publish the HTML), `docs/PLAN.md`
   (mark F3 done), `docs/DOCKER.md` (the post-gate metrics step, any new env/knob),
   `docs/NOTES.md` (schema + coefficient provenance), `Makefile` `help`.

## Acceptance

- `make check`/`regress`/`ci` **byte-identical green**, unchanged timings; no DB
  write or synth on the gate path (SystemC `sc.log` diff clean).
- `make metrics` inserts exactly one run row (+ children) into `metrics/metrics.db`;
  re-running for the same run_id is idempotent. Every value carries a
  `measured|estimated` kind.
- `make dashboard` writes a **single self-contained** `metrics/dashboard.html`
  (no external requests — verify: no `http(s)://` asset refs) with trend charts for
  each domain and visible regression flags; it opens offline and is Artifact-ready.
- Per-agent and per-(agent×model) rows are present for a swarm run **or** the schema
  records an explicit "not attributable" marker with a documented reason — never a
  fabricated number. Energy/cost rows are `estimated` and cite the coefficient table.
- Docs updated; `.gitignore` covers transient capture files but **not** the committed
  `metrics.db`/`dashboard.html`.

## Notes / constraints — READ

- **Measurement must not perturb the gate** — collection is a separate, post-gate
  step; synth/energy passes never run inside a timed DV env. If any metric can only
  be had by perturbing a timed run, **drop it and note why** (STOP-and-report).
- **Measured vs estimated stays separate** end to end (schema `kind`, dashboard
  legend, docs). Energy has no direct source → it is modeled from a documented
  coefficient table; say so wherever it appears.
- **Never fabricate** a per-agent/per-model number the tooling can't attribute —
  record the gap. A faithful partial beats an invented figure.
- This is the **third and final** planned feature. Keep it self-contained; reuse the
  existing metrics plumbing (`docker/render-metrics.py`, `last-run-metrics.json`,
  the coverage/`sby` outputs) rather than duplicating it.
- Follow repo conventions: pinned-tool absolute paths, `[METRICS]`/`[DASH]` banner
  style, one clean commit per logical step, the `Co-Authored-By` trailer. **Never
  commit on `main`** — branch, open a PR, checkpoint continuously (branch early, push
  incrementally, draft PR, mark "PARTIAL — resume needed" on cutoff). This is a large
  feature: land it in reviewable increments (schema+collector, then dashboard, then
  AI/per-agent, then CI wiring + docs) rather than one giant commit.
