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

**F1 — multiple resource planes (RP0..RP3)** (`docs/PLAN.md`). Today the chain is
RP0-only: `flit_fdid` always decodes 0, and `mk_crdtgrant` / `mk_activate_req`
already carry zero-filled RP1..RP3 slots. Make the datapath genuinely carry
**more than one resource plane** end-to-end: per-plane credit banks, per-plane
outstanding tracking, and an arbiter choosing which plane packs into the next
flit — with **no cross-plane credit or response leakage**. Start with **two
planes** (`NUM_RP=2`); the design must generalize to 4 but proving 2 is the bar.

**Hard invariant — `NUM_RP=1` stays byte-identical.** With a single plane (the
shipping default), `axi_ucie_mem_top` behaves EXACTLY as today: every existing DV
env (cocotb, sv, pack, act, reorder, ooo, systemc) stays green with identical
banners/read-counts, `make coverage` ≥ `COV_MIN`, `dv/pack` byte-map unchanged,
formal still 4 proofs. Multi-plane is opt-in via `NUM_RP`.

## Approach (sound, additive, default-single-plane)

1. **Parameterize `NUM_RP`** (default 1) through `axi_ucie_mem_top` and both
   bridges. All per-plane state becomes a `[NUM_RP]` bank; at `NUM_RP=1` the
   generated hardware must reduce to today's single path (prefer a `generate`
   that, for `NUM_RP==1`, elaborates the existing logic verbatim — the F2 pattern
   — so the default is *structurally* unchanged, not just assert-equal).

2. **Thread a plane id (FDId) end-to-end.** Populate the §4.3 FDId header field
   (`flit_assemble` gains an `fdid` input; the RP0 path passes 0 → byte-identical).
   The target routes/answers per the received FDId; responses carry their plane's
   FDId back. Reuse the existing `flit_fdid` decode.

3. **Per-plane credits.** Replicate the §6 credit counters as `cr_*[RP]` in both
   bridges. `MsgCredit` already has the RP subfield (`[15:14]`, Table 16) and
   `mk_crdtgrant` reserves RP1..RP3 slots — populate and consume them per plane.
   A credit granted to one plane must NEVER release a message on another.

4. **Per-plane outstanding + arbitration.** Per-plane request tracking (the
   initiator request queue replicated or tagged by plane), and a small
   **round-robin (or documented priority)** arbiter picking which plane's message
   packs into the next flit. Bound it; no unbounded state. Starvation-free:
   document and (ideally) assert that each ready plane is eventually served.

5. **Activation.** Extend the bring-up so RP1's credits/profile come up too
   (`mk_activate_req` / `mk_crdtgrant` RP1 fields), reusing the §8 FSM. If
   per-plane activation is more than a bounded extension, keep the FSM per-chain
   and gate data per plane on that plane's `CrdtGrant` — whichever is soundest;
   explain the choice in the PR.

## Scope & files

- `rtl/aou_pkg.sv` — per-plane inputs to `mk_crdtgrant` / `mk_activate_req`
  (populate RP1 slots), `fdid` into `flit_assemble`; keep every `NUM_RP=1` /
  RP0 byte map identical (prove in `dv/pack`).
- `rtl/aou_axi_initiator_bridge.sv`, `rtl/aou_axi_target_bridge.sv` — per-plane
  credit banks, per-plane outstanding tracking, the plane arbiter. Default path
  structurally unchanged at `NUM_RP=1`.
- `rtl/axi_ucie_mem_top.sv` — thread `NUM_RP` (default 1). Multi-plane wiring:
  either replicate the AXI front-end per plane, or add a per-plane FDId/select
  input — pick the smaller sound option and document it.
- `rtl/aou_activation.sv` — per-plane credit seed if needed (see step 5).
- `dv/sva/aou_flit_sva.sv` + `aou_credit_sva.sv` — relax the RP0-only asserts
  (`a_fdid_rp0`, `a_credit_rp0 = mc_rp==0`) to **per-plane bounds** (credit for
  plane p only ever gates plane p; FDId in range). Never weaken to vacuous.
- **DV (the proof):**
  - `dv/pack` — multi-RP round-trips (FDId + per-RP `MsgCredit`/CrdtGrant byte
    maps), plus the unchanged RP0 byte map.
  - A cocotb/SV top-level test (extend an env or add one) issuing **interleaved
    traffic on two planes** and checking: (a) each plane's responses come back on
    that plane, (b) **no cross-plane credit leakage** (starving plane 0's credits
    must not stall/free plane 1 and vice-versa), (c) arbiter serves both (no
    starvation), (d) every transaction completes.
  - A **default-single-plane regression**: `NUM_RP=1` reproduces today's exact
    banners/read-counts across cocotb + sv + systemc.

## Acceptance

- With `NUM_RP=2`: end-to-end test shows **interleaved two-plane** traffic with
  correct per-plane routing, **no cross-plane credit/response leakage**, arbiter
  fairness, all transactions completing.
- With `NUM_RP=1` (default): **every** existing env byte-identical green
  (`make check` unchanged banners), `make coverage` ≥ `COV_MIN`, `dv/pack`
  byte-map unchanged, formal still 4 proofs.
- Per-plane SVA bounds hold; no existing property weakened.
- `make regress` ends `[REGRESS] … PASSED`.
- `docs/PLAN.md` F1: mark DONE (2 planes proven, generalizes to 4), describing the
  per-plane credit banks + arbiter + FDId routing. `README.md` + `docs/DOCKER.md`
  updated.

## Notes / constraints — READ

- **STOP-and-report over faking.** If genuine multi-plane isolation cannot be
  reached without changing the default (`NUM_RP=1`) behavior, or a real
  cross-plane leakage/starvation counterexample appears that the design can't
  satisfy, open the PR as **"PARTIAL — design blocker"** describing exactly what
  breaks and the options — do NOT weaken an SVA, fake isolation, or make the RP0
  path non-identical to force green.
- Credits and responses are strictly per-plane; a message may only be released by
  a credit of its own plane. Same-ID ordering (F2) and the AXI rules still hold
  within a plane.
- Additive/opt-in: `NUM_RP=1` is the shipping default and must be byte-identical.
- Follow repo conventions (pinned-tool absolute paths, banners in the `[..]`
  style, one clean commit per logical step, the `Co-Authored-By` trailer). Never
  commit on `main`; branch and open a PR. Checkpoint continuously (branch early,
  push incrementally, draft PR, mark "PARTIAL — resume needed" on cutoff).
