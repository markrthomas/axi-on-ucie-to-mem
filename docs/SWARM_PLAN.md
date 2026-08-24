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

Complete **F4 — whole-chain formal** (`docs/PLAN.md`). The formal tier now proves
the §4.3 flit header (`formal/aou_flit*`) and the §6 credit flow on the real
bridges (`formal/aou_credit*`), using the bundled **yosys-slang** frontend. The
one piece left is the **§8 activation FSM invariants**. Add formal proofs of them
so whole-chain formal covers flit + credit + activation, and mark F4 done.

## Scope & files

1. **New `formal/aou_activation_fv.sv` + `formal/aou_activation.sby`** — a formal
   harness over `rtl/aou_activation.sv` (mirror `aou_credit_fv.sv` / `.sby`:
   `plugin -i slang; read_slang`, bmc+cover gating, prove best-effort). Prove the
   activation-FSM safety invariants:
   - **Never ENABLED before CrdtGrant.** The FSM cannot reach the data-transfer
     ENABLED state before the §6.4.2 `CrdtGrant` / §6.4.3 reset-credit exchange it
     depends on — i.e. the enable/"credits ready" gate must have occurred.
   - **No premature data-transfer enable.** The signal the bridges use to allow a
     data/message flit (the ENABLED/`quiescing` gating out of `aou_activation`) is
     never asserted in a non-ENABLED state. Prove it at the tightest sound scope —
     FSM-level if the gate lives in `aou_activation`; otherwise a small bridge
     abstraction.
   - **FSM safety / legal transitions.** No illegal state transition; teardown
     enters DEACTIVATE only from ENABLED and (per the F3 Option-2 mechanism) only
     once `data_idle`/quiescing allow it; `deact_pending`→`quiescing` holds;
     `ERROR` recovery is reachable and returns to a defined state.
   - **Cover traces:** bring-up reaches ENABLED; teardown reaches DISABLED;
     ERROR-recovery path is reachable.

2. **`Makefile`** — add `formal/aou_activation.sby` to the `FORMAL_SBY` list so
   `make formal` / `regress` runs it (gating). No `ci.yml` change is needed — CI
   already runs `make ci` with `SBY=$OSS/bin/sby`.

3. **Reuse existing properties** where one already exists; otherwise restate the
   invariant as immediate assertions in the wrapper (as `aou_credit_fv.sv` did for
   the SVA it couldn't `bind`) — **never weaken a property**.

4. **Docs** — `docs/PLAN.md`: mark **F4 DONE** (tooling unblocked by yosys-slang;
   flit + credit + activation all proven). `README.md` verification/formal list
   and `docs/DOCKER.md` formal section: add the activation proof so the formal
   tier's coverage reads flit + credit + activation.

## Acceptance

- `make formal SBY="$OSS/bin/sby"` runs **all** `.sby` (now including
  `aou_activation`) with **bmc + cover PASS**; covers reachable.
- The new activation invariants are **proven** (bmc), not skipped.
- `make regress` ends `[REGRESS] … + formal PASSED` with coverage ≥ 85% — no
  existing DV env regresses.
- The CI formal step stays green.
- Docs updated; `docs/PLAN.md` F4 marked complete.

## Notes / constraints

- Use the **yosys-slang** pattern from `formal/aou_credit.sby`
  (`plugin -i slang`, `read_slang`, RTL uses `module … import aou_pkg::*;`).
- Keep proof depths bounded — the activation FSM is small, so bmc should be cheap.
- **Additive only** — do NOT change RTL behavior. If a property exposes a real
  RTL bug, or a genuine invariant can't be proven (too deep / a real
  counterexample), **STOP and report it** in the PR rather than weakening the
  assertion or "fixing" the RTL to force green.
- Follow repo conventions (pinned-tool absolute paths, one clean commit, the
  Co-Authored-By trailer). Never commit on `main`; branch and open a PR.
