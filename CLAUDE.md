# CLAUDE.md — working conventions for this repo

Guidance auto-loaded into every Claude session (including each headless **swarm**
run) that works in this repo. It captures the **non-obvious** conventions and
hard-won gotchas so a run doesn't re-derive or re-trip them. It is not a spec —
`README.md` and `docs/PLAN.md` are; this is the "how we work here" layer.

**This repo:** a digital-only, open-source DV suite for an AXI-Lite-over-UCIe
(AoU) bridge to an AXI-Lite memory. No commercial simulator on the host; every
license-gated flow degrades gracefully (prints a skip, exits 0). See
`docs/PLAN.md` for the design + backlog and `README.md` for usage.

---

## Golden rules (do not violate)

1. **Every new feature is opt-in with a byte-identical default.** New capability
   goes behind a parameter/knob that defaults OFF (`OOO_EN=0`, `NUM_RP=1`,
   `VERBOSE=0`, …). At the default, the chain must be **bit-and-cycle identical**
   to before — proven *structurally* (put the new logic in a `generate` branch
   that isn't elaborated at the default) and *empirically* (every existing env's
   banners/read-counts are unchanged; SystemC even diffs a committed
   `dv/systemc/sc.log`). Prefer structural byte-identity over an assertion.

2. **Additive DV — never change RTL behavior to force a test green.** If a property
   exposes a real RTL bug, or an invariant genuinely can't be met, **STOP and
   report it in the PR** (mark it "PARTIAL — design blocker"). Never weaken an SVA,
   delete a coverage bin, or hack the memory/RTL to get a green. A faithful partial
   beats a fake pass. (This has repeatedly been the right call — e.g. RESP-code
   bins that need an RTL change, and the OOO credit deadlock that was a real bug.)

3. **Never commit on `main`.** Branch, push incrementally, open a PR; a human
   reviews and merges. Checkpoint continuously so an interrupted run loses at most
   the last increment (draft PR early; mark "PARTIAL — resume needed" on cutoff).

4. **Report results faithfully.** Quote the real banner/log. Never claim green
   without the actual run. **Mutation-test** any new DV env (prove a plausible bug
   makes it fail) so the test has teeth — a test that can't fail is a defect.

5. **Update docs in the same PR as the code.** For every change, update as
   applicable: `README.md` (usage/features), `docs/PLAN.md` (mark the item done +
   what shipped), `docs/DOCKER.md` (container/CI/gate, any new env or knob),
   `docs/NOTES.md` (design notes), and the root `Makefile` `help:` lines for any
   new target/knob. Skip a file only with a one-line reason it doesn't apply.

---

## Build & gate essentials

- **Pinned tools.** Verilator + SymbiYosys (`sby`) + `yosys-slang` come from the
  **oss-cad-suite tag `2026-04-13`** (at `$OSS`, i.e. `oss-cad-suite/`). Icarus +
  SystemC 2.3.3 are from apt. `python3-dev` is required (cocotb VPI needs
  `libpython*.so`).
- **The Verilator triplet must be passed as make command-line args**, not env:
  the Makefile computes `VERILATOR_ROOT` with `:=` (`command -v`), which env can't
  override. Pass `VERILATOR=… VERILATOR_ROOT=… VERILATOR_COV=…` (CI/entrypoint do).
- **Formal uses yosys-slang** (`plugin -i slang; read_slang`), because stock yosys
  can't parse `module … import aou_pkg::*;` / concurrent SVA. Pass
  `SBY="$OSS/bin/sby"` like the Verilator triplet. When a bridge starts
  instantiating a new module, **add that module to the `read_slang` file list** in
  the relevant `formal/*.sby` or the proof won't elaborate.
- **`VL_JOBS`** caps each Verilator build's parallel `cc1plus` (cloud builders have
  many cores but little RAM → OOM). Image default is 2; the swarm also throttles
  how many envs build at once (`SWARM_MAX_PARALLEL`).
- **The gate:**
  - `make check` = `lint eda-check` + the **8 DV envs**: `test-all` (cocotb/PyUVM),
    `sv`, `pack`, `act`, `reorder`, `ooo`, `mrp`, `systemc`.
  - `make regress` = `check` + `coverage` (Verilator lcov ≥ `COV_MIN`, floor 85) +
    `formal` (**4 proofs**: `axi_lite_mem`, `aou_flit`, `aou_credit`,
    `aou_activation`; bmc+cover gate, prove best-effort).
  - `make ci` = `regress`. The Dockerfile/CI/Railway all run `make ci`.
- **After any `rtl/` change, run `make -C uvm eda` and commit** the regenerated
  `eda/vcs_uvm/design.sv` — `make check` runs `eda-check`, which **fails** if that
  single EDA-Playground design file is stale vs `rtl/`.
- **Metrics are NOT on the gate.** `metrics/` (`make metrics-capture`,
  `make metrics`, `make dashboard`) is opt-in and runs *after* a completed gate.
  Never fold it into `check`/`regress`/`ci`, and never make a DV env do extra work
  to produce a number — *measurement must not change the thing it measures*. Every
  value is tagged `measured | estimated | not_attributable` (a schema `CHECK`), and
  a metric that could only be had by perturbing a timed run is **dropped with the
  reason recorded**, never taken. See `docs/NOTES.md` → "Metrics DB".

## DV env map (what each proves)

| env | dir | proves | banner |
|-----|-----|--------|--------|
| cocotb/PyUVM | `dv/cocotb` | end-to-end AXI + functional coverage (`FCOV_MIN`) | `[COV-FUNC]` / cocotb PASS |
| sv | `dv/sv` | directed SV TB, Icarus + Verilator(+bound SVA) | `[SV-TB] PASS: N reads` |
| pack | `dv/pack` | §4.3/§5.8 byte-exact flit/message packing | `[PACK-TB] PASS` |
| act | `dv/act` | §8 activation FSM (bring-up/teardown/ERROR, quiescing) | `[ACT-TB] PASS` |
| reorder | `dv/reorder` | standalone per-ID reorder buffer | `[ROB-TB] PASS` |
| ooo | `dv/ooo` | full-chain OOO-by-ID (`OOO_EN=1`) | `[OOO-TB] PASS` |
| mrp | `dv/mrp` | multiple resource planes (`NUM_RP=2`) | `[MRP-TB] PASS` |
| systemc | `dv/systemc` | SystemC model, diffs committed `sc.log` | `[SC-TB] PASS: 145 reads` |

## Adding a new DV env (checklist)

1. `dv/<env>/` with its `Makefile`; add an `<env>:` target to the root `Makefile`
   and fold it into `check` (and thus `regress`/`ci`).
2. Bump the "N envs" text in `docker/swarm.sh`, `.claude/agents/*.md`,
   `Dockerfile`, `railway.toml` (they enumerate the env list).
3. If the RTL grew a module, add it to the `formal/*.sby` `read_slang` list.
4. Mutation-test it. Update docs (rule 5).

## Known gotchas (expensive; don't rediscover)

- **cocotb + iverilog `always_comb` wedge:** a wide, self-referential `always_comb`
  hangs *only* under the cocotb VPI (fine in pure Icarus/Verilator). Use continuous
  `assign`s for wide combinational fan-in on signals cocotb touches.
- **Credit piggyback deadlock (the F2 class of bug):** the initiator returns
  ReadData/WriteResp credits **only** piggybacked on its next request flit. With
  several responses owed and no request behind them, the target can drain its
  credit pool and stall forever. Any change that lets more responses be outstanding
  must bound them against the granted ceiling (a lone transaction must always pass).
- **`sc.log` baseline:** the SystemC env diffs a committed golden log — any change
  to its stdout (even a new print) fails it. Gate new prints behind `VERBOSE`.
- **ASCII-stdout crash in the cloud (locale trap):** the cloud (Railway/CI Docker
  image) starts under a bare `C`/POSIX locale, so Python's stdout falls back to the
  **ASCII** codec — `print()` of any non-ASCII byte then raises `UnicodeEncodeError`
  and aborts the run. It never reproduces on a dev host (already UTF-8). Bit us via
  the em-dash in `[COV-FUNC] AXI functional coverage —`. Fixed **once, at the root**
  in the `Dockerfile` (`ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=UTF-8
  PYTHONUTF8=1`), so all envs are covered — don't chase individual characters. Keep
  that ENV; if you add a non-Docker cloud path, set the same there.
- **Never `stdbuf`/`unbuffer` the gate (bundled-glibc clash):** to make cloud logs
  stream live, wrapping `make` in `stdbuf -oL` is the obvious move — and it **breaks
  the gate at `make lint`**. `stdbuf` `LD_PRELOAD`s the system `libstdbuf.so` (glibc
  2.38) into every child, but the pinned oss-cad-suite tools (Verilator, `sby`) run
  against their own **older bundled glibc** → `version 'GLIBC_2.38' not found` and the
  tool dies. Same trap for any system-lib `LD_PRELOAD` into oss-cad-suite binaries.
  For live logs use Python-only `PYTHONUNBUFFERED=1` (cocotb is the leg that matters);
  the C tools block-buffer under a pipe — accepted. See [[docker-railway-dv-gate]].

## Conventions

- Log banners use the `[ENV-TB]` / `[STAGE]` bracket style already in the repo;
  match it. Keep the passing PASS banners on stdout; verbose detail goes to logs.
- One clean, logical commit per step. End commit messages with the repo's
  `Co-Authored-By:` trailer. Use pinned-tool **absolute** paths.
- The **plan-driven swarm**: `docs/SWARM_PLAN.md` with `status: ready` pushed to
  `main` triggers `.github/workflows/plan-swarm.yml`, which implements the plan and
  opens a PR. Reset to `status: draft` after it lands. The swarm agents are defined
  in `.claude/agents/` (swarm-manager, dv-env-tester, infra-agent, dv-runner).

## Cross-run memory (why this file exists)

Each swarm run starts **cold** — there is no per-swarm scratchpad. Durable learning
lives only in files a run reads: **this `CLAUDE.md`**, `.claude/agents/*.md`, the
`docs/`, and the code/tests themselves. When a run discovers a reusable convention
or a costly gotcha, the fix is to **write it here** (or into the relevant agent
playbook), so the next run is faster. Keep this file curated and high-signal.
