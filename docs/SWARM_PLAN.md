---
status: ready
---

# Swarm implementation plan

<!--
  status: draft  = ignored.   status: ready = the Plan swarm implements this on a
  push to main (.github/workflows/plan-swarm.yml). Review the resulting PR, then
  set status back to draft. See docs/DOCKER.md -> "Plan-driven swarm".
-->

## Goal

Turn on **open-source formal verification** as a first-class, gating DV tier.
SymbiYosys (`sby`) + yosys + SMT solvers are already bundled inside the
oss-cad-suite the image installs for Verilator, and real proofs already exist
under `formal/` — but `make formal` **silently skips** because `sby` is off
`PATH`, and `formal` is not part of `check`/`regress`. Make the existing proofs
actually run and block on failure, then **extend formal coverage to the
AoU-specific properties** (the §4.3 byte-exact flit header and the §6 credit flow)
that today are only simulated, never proven.

## Scope & files

1. **`Makefile`**
   - Add an overridable `SBY ?= sby` variable and use `$(SBY)` in the `formal`
     target instead of a bare `sby`. Keep a graceful skip only when `SBY` truly
     resolves to nothing; when a path is provided it must run (no silent skip).
   - Run all three tasks (`bmc`, `prove`, `cover`) and fail the target if any
     assertion fails or a required cover is unreachable. `prove` (k-induction) may
     stay best-effort if it doesn't converge at the current depth — but `bmc` and
     `cover` must pass and gate.
   - Add `formal` to the `regress` gate (and a `help`/`.PHONY` entry to match
     style). It's fine to keep it out of the lighter `check` if runtime is a
     concern — pick whichever keeps `regress` the single signoff gate.

2. **`docker/entrypoint.sh`** — inject `SBY=$OSS/bin/sby` alongside the existing
   pinned-Verilator make args, so `make formal` / `make regress` in the image use
   the bundled prover (oss-cad-suite stays OFF `PATH`; pass it by absolute path,
   exactly like the `VERILATOR` triplet).

3. **`.github/workflows/ci.yml`** — add a formal step/job that runs
   `make formal SBY="$OSS/bin/sby"` (bmc + prove + cover) and blocks on failure,
   reusing the oss-cad-suite the workflow already installs. Keep proof depths
   bounded so CI runtime stays reasonable.

4. **`formal/` — new AoU proofs.** Add formal wrappers + `.sby` for the AoU
   properties, mirroring the existing `axi_lite_mem` structure:
   - **Flit header (§4.3):** prove the byte-exact map — reconstruct the Figure-5
     header bytes and prove they equal `flit_get_byte(...)` for arbitrary field
     inputs, and that pack→unpack round-trips (`flit_fdid`/`flit_msgstart`/
     `flit_credit` recover what was packed). Reuse `dv/sva/aou_flit_sva.sv` via a
     bound formal top where practical.
   - **Credit flow (§6):** prove the invariants — credits never go negative, never
     exceed their configured max (no overflow on replenish), and gating holds
     (no send when the relevant credit is zero). Reuse `dv/sva/aou_credit_sva.sv`.

5. **Docs** — correct `docs/DOCKER.md` (the "formal … would only skip" claim is
   now wrong: `sby` ships in the image) and document the formal tier + the `SBY`
   knob next to the `VL_JOBS`/Verilator-args explanation. Update the README
   verification table with a Formal row. Optionally add `sby --version` to the
   Dockerfile healthcheck.

## Acceptance

- `make formal SBY="$OSS/bin/sby"` runs bmc/prove/cover and **passes** (all
  asserts hold to depth; required covers reachable) for the existing
  `axi_lite_mem` proof.
- The **new AoU flit and credit formal proofs pass** (bmc + cover at minimum).
- `make regress` includes formal and ends `[REGRESS] … PASSED` with coverage
  ≥ 85% — no existing sim environment regresses.
- CI has a **formal job/step that is green and blocks on failure**.
- Docs corrected; README Formal row added.

## Notes / constraints

- `sby` lives at `$OSS/bin/sby`; oss-cad-suite must stay OFF `PATH` (its bundled
  `iverilog` would shadow the apt one the cocotb VPI links against) — pass `SBY`
  by absolute path, the same pattern as `VERILATOR`/`VERILATOR_ROOT`.
- **yosys SV-frontend limits are a real risk.** If yosys can't ingest a property
  or package construct, adjust the *formal wrapper* (a thin FV top / `read -sv`
  tweaks / a small combinational restatement of the check) — **do not weaken the
  RTL or the assertion** to force a pass. If a genuine property can't be proven
  (too deep, or a real design bug), **STOP and report it** in the PR rather than
  deleting/relaxing the assertion.
- Keep proof depths bounded for CI runtime (start from the existing `depth 24` /
  cover `depth 32`); raise only if needed for a specific property.
- Formal is **additive** — it must not change RTL behavior or break the existing
  cocotb / SV / Verilator / pack / act / reorder / SystemC envs.
- Follow repo conventions (pinned-tool absolute paths, one clean commit, the
  Co-Authored-By trailer). Never commit on `main`; open a PR.
