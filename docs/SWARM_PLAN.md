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

**Feature 1 of 3 — verbose logging to files (packet-level + full-debug).** Today a
partial facility exists: `VERBOSE=1` at the repo root passes `+verbose`, and the SV
TBs print `[SV-TB][T]` **AXI transaction** traces while the cocotb BFM logs at DEBUG.
Complete it into a **consistent, two-level, file-based** logging facility across
**all DV envs**, and make it log the **AoU packets/flits** (not just AXI beats).

Two levels, one knob:
- **`VERBOSE=1` (packet/verbose):** a human-readable trace of every AoU **flit**
  crossing each UCIe link — decoded: message type (WriteReq/ReadReq/WriteData/
  ReadData/WriteResp/Misc), FDId/plane, MsgStart, MsgCredit, granule count, and the
  key fields (id/addr/data/resp/last) — **plus** the existing AXI transaction trace.
- **`VERBOSE=2` (full debug):** everything in L1 **plus** internal state needed to
  debug: activation FSM state/transitions, per-message-type credit counters in both
  bridges, initiator request-queue occupancy, reorder-buffer slot state (F2), RP
  arbiter grants + per-plane RX-queue depth (F1), and OOO hold state (F2).

Every level writes to a **per-test log file** (not just stdout) so a failing run is
inspectable after the fact.

## Hard invariant — `VERBOSE=0` (default) stays byte-identical

The whole gate depends on stable banners/baselines (SystemC even diffs a committed
`dv/systemc/sc.log`). At `VERBOSE=0`, every env's stdout must be **exactly** as
today — all new logging is behind the level gate and emitted only at L1/L2. No RTL
behavior change; logging is additive DV only.

## Scope & files

1. **Shared flit decoder (one source of truth).** Add a pure, non-synthesizable
   flit→string decoder so SV and SystemC render a flit identically: either a
   `` `ifndef SYNTHESIS `` function in `rtl/aou_pkg.sv` (used only by TBs, never
   instantiated in the datapath) or a `dv/common/` helper. cocotb gets a small
   Python mirror (reuse the §4.3/§5.8 byte map already encoded in `dv/pack`). It
   must decode msgtype, FDId, MsgStart, MsgCredit (+RP subfield), granule count,
   and per-type fields. **Prove the L0 datapath is unaffected** (function unused
   when not logging).

2. **One verbosity knob, threaded everywhere.** Root `Makefile`: `VERBOSE ?= 0`
   (accept `0|1|2`; keep `VERBOSE=1` meaning "verbose" as today, add `2`). Pass it
   down to each env: `+verbose=<lvl>` (SV/Icarus/Verilator via `$value$plusargs`),
   a define or run-arg for SystemC, and an env var / cocotb log-level for cocotb.
   A single documented mapping: 0=off, 1=packet+txn, 2=+internal debug.

3. **Per-test log files.** Each env writes `logs/<env>[_<test>].log` (gitignored)
   via `$fopen`/`$fdisplay` (SV/SystemC) or a Python `FileHandler` (cocotb), tagged
   with the env's existing `[..]` banner style (`[SV-TB][T]`, `[SC-TB][T]`,
   `[COCOTB]`, etc.). The passing PASS/○ banners still go to stdout unchanged.
   Add a `logs/` ignore and a `make clean` sweep.

4. **Packet logging (L1)** in the envs that carry real flits end-to-end (cocotb, sv,
   systemc, ooo, mrp) — decode each flit at the link boundary (`tx_valid/rx_valid`
   handshake) and log it. Unit envs (pack/act/reorder) log their existing
   check-level detail at L1.

5. **Full-debug logging (L2)** — internal state. Prefer TB-side hierarchical
   references to the RTL state (no RTL edits); if a signal isn't reachable, add a
   `` `ifndef SYNTHESIS `` debug-only observation port or `$display` in the RTL
   **gated by a plusarg/param that is off by default** — never alter behavior.

6. **Docs** — `README.md` (a "Debug logging" section: the `VERBOSE=0|1|2` levels,
   where the logs land, a sample decoded-flit line) and `docs/DOCKER.md`. Note the
   log files are for humans; CI runs at `VERBOSE=0`.

## Acceptance

- `make check` at the **default** `VERBOSE=0`: every env byte-identical green
  (unchanged banners/read-counts, SystemC `sc.log` diff clean), `make coverage` ≥
  `COV_MIN`, formal 4 proofs, `eda-check` clean.
- `make check VERBOSE=1`: still green; each flit-carrying env writes a `logs/*.log`
  containing **decoded flit lines** (msgtype/FDId/credit/fields) for its traffic.
- `make <env> VERBOSE=2`: the log additionally shows internal state (FSM/credits/
  queues/arbiter/reorder) for at least cocotb + sv + one of ooo/mrp.
- No RTL behavior change; the decoder is unused on the L0 datapath.
- Docs updated; `.gitignore` covers `logs/`.

## Notes / constraints — READ

- **Additive DV, no RTL behavior change.** L0 must be byte-identical; if L2 truly
  needs an internal signal that can't be reached from the TB, add a synthesis-
  excluded, default-off debug hook — do NOT change datapath logic. If that can't be
  done cleanly for some env, log what IS reachable and note the gap in the PR
  (**STOP-and-report over faking**).
- One decoder, one level-mapping — don't fork per-env conventions.
- Keep it the **first of three** planned features (wave configs and a metrics DB
  follow as separate plans) — do not scope-creep into those here.
- Follow repo conventions (pinned-tool paths, `[..]` banners, one clean commit per
  logical step, `Co-Authored-By` trailer). Never commit on `main`; branch, open a
  PR, checkpoint continuously (branch early, push incrementally, draft PR, mark
  "PARTIAL — resume needed" on cutoff).
