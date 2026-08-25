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

**PyUVM coverage closure.** The cocotb/PyUVM env (`dv/cocotb/`) is the golden
reference, but it has **no functional coverage** — the only coverage in the repo
today is Verilator *line* coverage (`make coverage`, `COV_MIN=85`). Add a
**functional coverage model** to the PyUVM env, sample it from the monitored
transaction stream, print a coverage report, and enforce a **functional-coverage
floor** so `make test` / `make ci` fail on a coverage regression. Then **close
the holes**: add the directed/constrained stimulus needed to hit every defined
bin, so the model reports 100% of its own goal.

This is **additive DV only** — do NOT change RTL behavior. If reaching a bin
requires an RTL change, or a bin is genuinely unreachable, **STOP and report it**
in the PR rather than deleting the bin or weakening the goal.

## Scope & files

1. **New `dv/cocotb/axi_coverage.py`** — a self-contained functional coverage
   model. **Prefer NO new pip dependency**: implement a small covergroup helper
   (dict-of-bins with `sample()` and a `report()` that prints hit/total per
   group and an overall %). Only if it is clearly cleaner may you use
   `cocotb_coverage`; if you do, you MUST also add it to the `pip install` line
   in **both** `.github/workflows/plan-swarm.yml` and `.github/workflows/swarm.yml`
   and to the `Dockerfile` cocotb install, and pin the version. Cover at least:
   - **Transaction direction:** read, write.
   - **Address region:** low / mid / high partitions of the AXI-Lite memory map
     (derive from the memory depth in the RTL/params — do not hardcode a stale
     size), plus first-word and last-word boundary bins.
   - **Data pattern:** zero, all-ones, walking-1, walking-0, random (buckets the
     existing `AxiWalkingSeq` / `AxiRandomSeq` already generate).
   - **Response codes:** every `RRESP`/`BRESP` value the DUT can legally return
     (OKAY, and any error/exclusive codes the RTL actually drives) — sample from
     the monitor, not the sequence.
   - **Burst / multi-outstanding:** burst length buckets (1, small, max) and
     outstanding-depth buckets (1, >1) exercised by `AxiBurstSeq` /
     `AxiMultiReadSeq`.
   - **Cross:** direction × address-region (the meaningful cross; keep the cross
     space small so it is closeable).
   Add AoU-protocol bins **only where the PyUVM monitor can already observe the
   signal** (e.g. message-type / credit / activation state if surfaced at the
   monitored interface). If a state is not observable at this env's interface,
   note it in the PR as covered by the SV/act/reorder envs instead of inventing a
   probe — do not reach into RTL internals from Python.

2. **Sample it** — in `dv/cocotb/axi_components.py`, add a coverage subscriber
   (a `uvm_subscriber`/analysis export off the existing monitor, mirroring how
   the scoreboard/monitor are wired) that calls `cov.sample(item)` on every
   transaction. Do NOT sample from the driver/sequence — sample observed traffic
   only. Construct one shared coverage model in the env and `report()` it in the
   env's `report_phase` (or `final`), printing a banner in the repo's
   `[COV-FUNC] …` style consistent with the other DV banners.

3. **Enforce a floor** — add a functional-coverage floor (e.g. `FCOV_MIN`,
   default 100 for this model since every bin is meant to be reachable; if you
   justify a lower floor, say why in the PR). On the final test's `report_phase`,
   fail (non-zero → cocotb test failure) if achieved functional coverage is below
   the floor. Wire a short **`[COV-FUNC] PASS/FAIL`** line so `make test` surfaces
   it. Keep the existing per-test PASS banners and the read-count checks intact.

4. **Close the holes** — run it, see which bins are unhit, and add the minimal
   directed/constrained stimulus (extend an existing sequence in `dv/cocotb/axi_seq.py`,
   or add one small new sequence + test entry in `axi_test.py`) to hit them.
   Boundary addresses, both error responses if reachable, walking patterns, and
   the burst/outstanding buckets are the likely gaps. Aim for the model reporting
   **100% of its defined goal**.

5. **Docs** — `docs/PLAN.md`: note functional coverage is now part of the PyUVM
   env (line coverage via Verilator + functional coverage via the PyUVM model),
   and tick the PyUVM coverage-closure item. `README.md` verification section and
   `docs/DOCKER.md`: mention the `[COV-FUNC]` functional-coverage report + floor.

## Acceptance

- `make test` runs the PyUVM tests and prints a **`[COV-FUNC]` report**; the final
  test enforces the functional-coverage floor and the run is **green** with the
  model at its goal (100% unless a justified lower floor is documented).
- No existing DV env regresses: `make check` (cocotb + sv + vlt + pack + act +
  reorder + systemc) stays green, and `make coverage` still meets `COV_MIN`.
- `make regress` ends `[REGRESS] … PASSED` (check + coverage + formal), coverage
  floors met, formal still 4 proofs green.
- If any bin is unreachable without an RTL change, it is **reported in the PR**,
  not silently dropped.

## Notes / constraints

- **Additive DV only** — no RTL behavior change. Sample observed transactions from
  the monitor; never from the stimulus side, and never by peeking RTL internals
  from Python.
- Keep the coverage model **deterministic and dependency-light** so it runs
  identically in CI and the container. If you add `cocotb_coverage`, update every
  install site (both workflows + Dockerfile) and pin it — a missing dep must not
  silently skip coverage.
- Follow repo conventions: banners in the existing `[..]` style, pinned-tool
  paths, one clean commit, the `Co-Authored-By` trailer. Never commit on `main`;
  branch and open a PR.
- Checkpoint continuously (branch early, push incrementally, draft PR, mark
  "PARTIAL — resume needed" on cutoff) per the standing swarm task.
