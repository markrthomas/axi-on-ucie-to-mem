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

**Feature 2 of 3 — per-test GTKWave layouts (`.gtkw`) for one-click debug.** Today
there is a *single* curated layout, `dv/wave.gtkw`, that `make wave` applies with
`gtkwave -a` so the FST doesn't open blank — but one flat signal list can't suit
every test. A `write_read` run wants the AXI AW/W/B/AR/R channels and the memory;
an `ooo` run wants the reorder-buffer slots and per-ID hold state; an `mrp` run
wants the per-plane credit banks and the RP arbiter; an `act` run wants the §8
activation FSM and CrdtGrant handshake. Give **each debug target its own `.gtkw`**
with signals **grouped and named** for that scenario, and make `make wave
TEST=<name>` (and the per-env wave flows) open the *matching* layout automatically,
so a failing run is inspectable in seconds without hand-adding signals.

This is the wave viewer the user chose: **GTKWave `.gtkw`** save files.

## Hard invariant — the gate is untouched

Waveforms are a **dev-only convenience**. `make check` / `regress` / `ci` must be
**bit-and-cycle identical** — they never dump waves and never read a `.gtkw`. The
`.gtkw` files are static text applied only by the interactive `make wave*` targets;
no RTL/TB behavior changes. `WAVES` unset (the default everywhere) stays exactly as
today. Prove it: every env's gate banners/read-counts are unchanged and the SystemC
`sc.log` diff is clean.

## Scope & files

1. **A `dv/waves/` layout set — one `.gtkw` per debug target.** Author curated
   GTKWave save files with **`@` group markers** (open/close groups) and
   human-readable aliases, one per scenario, at minimum:
   - `write_read.gtkw`, `burst.gtkw`, `multi_outstanding.gtkw` (cocotb AXI tests:
     AW/W/B/AR/R channel beats + the UCIe flit/credit boundary + memory word).
   - `ooo.gtkw` (the `dv/ooo` chain: reorder-buffer slot valid/id/data, OOO hold
     state, response-source mux — the F2/OOO internals).
   - `mrp.gtkw` (the `dv/mrp` chain: per-plane RX-queue depth, per-plane credit
     banks, the RP arbiter grants + FDId routing).
   - `act.gtkw` (the `dv/act` FSM: activation state, CrdtGrant, data_idle teardown
     gate, ERROR recovery).
   Group by protocol layer (AXI channel / UCIe flit / credit / memory / internal
   FSM). Keep `dv/wave.gtkw` as the **generic fallback** when no per-test file
   matches (or move it into `dv/waves/default.gtkw` and update `WAVE_SAVE`).

2. **Auto-select the layout in `make wave`.** Root `Makefile`: pick
   `dv/waves/<key>.gtkw` for the requested `TEST`/env, falling back to the generic
   layout if the specific one is absent — so `gtkwave -a <the right file>`. Keep the
   `NO_AT_BRIDGE=1` / graceful "gtkwave not on PATH → skip, exit 0" behavior that is
   already there. Extend the wave flow beyond cocotb to the envs whose TBs can emit
   a dump (`ooo`, `mrp`, `act`, `sv`) — add a `WAVES=1` dump path + a `wave-<env>`
   convenience target where one doesn't exist yet, mirroring the cocotb one. If a
   given TB genuinely can't dump under its simulator, say so in the PR rather than
   faking it.

3. **A `.gtkw` freshness check (so layouts can't silently rot).** Add a lightweight
   `make wave-check` that, for each `dv/waves/*.gtkw`, verifies every referenced
   signal path still exists in that target's dump hierarchy (derive the signal list
   from a generated FST/VCD via the oss-cad-suite `fst`/`vcd` tooling, or from an
   iverilog/Verilator hierarchy dump). Fail with the orphaned `net path` when a
   renamed RTL signal has left a stale entry — the same "drift-guard with teeth"
   spirit as `eda-check`. This is a **dev/opt-in** target: it needs a dump (and
   GTKWave-free parsing), so **do NOT add it to `check`/`ci`** (keep the gate
   byte-identical and gtkwave-independent); wire it into `help` and mention it in
   docs. If deriving the hierarchy cheaply isn't feasible for some env, degrade
   gracefully (skip that env with a printed note) rather than blocking.

4. **Docs (required — update in this same PR).**
   - `README.md` — a "Waveform debugging" section: the per-test layouts, `make wave
     TEST=<name>` / `wave-<env>`, what each layout emphasizes, a screenshot-free
     description of the groups, and the `wave-check` guard.
   - `Makefile` `help:` — lines for any new/changed wave target + the `TEST=` keys.
   - `docs/NOTES.md` — a short note on the layout conventions (group scheme, naming).
   - `docs/DOCKER.md` — only if the container/gate story changes (it should not; the
     gate stays wave-free) — otherwise state "N/A, gate unchanged" in the PR.
   - `docs/PLAN.md` — mark F2 done + what shipped.

## Acceptance

- `make check` (and `regress`/`ci`) **byte-identical green** — no env dumps waves,
  no `.gtkw` read on the gate path; SystemC `sc.log` diff clean.
- `make wave TEST=write_read_test` opens (or, with no gtkwave, cleanly skips with
  exit 0 after dumping) using `dv/waves/write_read.gtkw`; likewise the `ooo`, `mrp`,
  `act` flows each pick up their own layout. Each layout opens **pre-populated and
  grouped** (no blank pane, no hand-adding signals).
- `make wave-check` passes on the committed layouts, and **fails** if a signal path
  in a `.gtkw` is renamed/removed (demonstrate the failure in the PR — the guard has
  teeth).
- Docs updated as above; `.gitignore` still covers generated dumps (`*.fst`,
  `*.vcd`, `sim_build/`, `obj_dir/`).

## Notes / constraints — READ

- **Additive, dev-only.** No RTL/TB behavior change; the gate never touches waves.
  If an env's simulator can't produce a dump its `.gtkw` needs, **STOP and report**
  it in the PR (mark PARTIAL) — never fake a layout against signals that don't exist.
- **One layout scheme, not per-env dialects** — shared group naming/order so the
  files read consistently; the fallback-to-generic keeps `make wave` working for a
  test with no bespoke layout yet.
- This is the **second of three** planned features (a metrics DB + dashboard is F3,
  a separate plan) — do not scope-creep into F3 (no metrics/telemetry here).
- Follow repo conventions: pinned-tool absolute paths, `[WAVES]`/`[WAVE]` banner
  style already in the `Makefile`, one clean commit per logical step, the
  `Co-Authored-By` trailer. **Never commit on `main`** — branch, open a PR, and
  checkpoint continuously (branch early, push incrementally, draft PR, mark
  "PARTIAL — resume needed" on cutoff).
