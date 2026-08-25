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

**F2 — full-datapath out-of-order (OOO) integration** (`docs/PLAN.md`). The per-ID
reorder buffer `rtl/aou_reorder.sv` is proven standalone in `dv/reorder`, but it is
**not wired into the full chain**, because today's topology (single serialized flit
link + single in-order `axi_lite_mem`) never completes out of order — there is no
OOO source. This item makes the whole datapath exercise real OOO-by-ID completion:
introduce an **optional OOO source** at the target, **wire `aou_reorder` into the
initiator response path** to restore AXI-legal ordering, and prove **end-to-end**
that same-ID responses stay in issue order while different-ID responses may overtake.

**Hard invariant — the default chain must stay byte-identical.** With the OOO source
disabled (the default), `axi_ucie_mem_top` must behave EXACTLY as today: every
existing DV env (cocotb, sv, pack, act, reorder, systemc) stays green with identical
banners/read-counts, and `make coverage` still meets `COV_MIN`. OOO is an opt-in mode.

## Approach (sound, additive, default-off)

1. **OOO source at the target (opt-in).** Add a way for responses of *different IDs*
   to complete out of request order — the smallest sound mechanism, chosen by the
   swarm and justified in the PR. Preferred: a **variable-latency / interleaving
   target** wrapper (parameter `OOO_EN`, default `0`) in front of / inside
   `aou_axi_target_bridge` that may hold a completed different-ID response and let a
   later different-ID response pass, tagging each response with its transaction tag
   over the link. When `OOO_EN=0` it is a pass-through and the datapath is unchanged.
   Do **not** reorder within an ID, ever. Do **not** modify `axi_lite_mem.sv`
   behavior; if extra state is needed, add it in the bridge/wrapper, not the memory.

2. **Carry the transaction tag end-to-end.** The response flit must carry enough tag
   for the initiator to match a completion to its outstanding slot. Reuse the
   existing ID/flit fields where possible; if a tag field must be added to the
   response message, keep it within the already-defined message layout (§5/§4.3) and
   assert the default path is byte-identical when `OOO_EN=0`.

3. **Wire `aou_reorder` into `aou_axi_initiator_bridge`.** On issue (AW/AR accepted),
   allocate a reorder slot (`iss_*`) keyed by AXI ID; on a response flit arriving
   from the link, drive `cmp_*` by tag (completions may arrive in any order); present
   the reorder buffer's `out_*` (oldest-of-its-ID) onto the AXI R/B channels. Keep the
   existing `REQ_QD` in-order queue as the `OOO_EN=0` path (or prove the reorder path
   degenerates to identical in-order behavior when completions arrive in order — then
   a single path is fine). Respect `out_ready`/backpressure and the §6 credit gating.

4. **Bound it.** `DEPTH` = the existing outstanding capacity (power of two); no new
   unbounded state. Same-ID ordering and no-cross-ID-leakage must hold under credit
   backpressure and teardown/quiescing.

## Scope & files

- `rtl/aou_axi_initiator_bridge.sv` — instantiate `aou_reorder`, drive issue/
  completion/output, keep AXI R/B ordering compliant. Default path unchanged.
- `rtl/aou_axi_target_bridge.sv` (+ optional small wrapper) — the `OOO_EN` OOO
  source; pass-through when disabled.
- `rtl/aou_pkg.sv` — only if a response tag field is genuinely required; keep the
  `OOO_EN=0` byte map identical (prove it in `dv/pack`).
- `rtl/axi_ucie_mem_top.sv` — thread the `OOO_EN` parameter (default 0).
- **DV (the proof):**
  - Extend `dv/reorder` or add a top-level cocotb/SV test that, with `OOO_EN=1`,
    issues **interleaved multi-ID** read/write traffic and checks: (a) per-ID
    responses arrive in issue order, (b) different-ID responses actually overtake
    (observe a real reorder, not just tolerate it), (c) no cross-ID data/credit
    leakage, (d) every response is eventually delivered (no leak/loss).
  - A **default-off regression**: the full chain with `OOO_EN=0` reproduces today's
    exact banners/read-counts in cocotb + sv + systemc.
  - Update SVA if any concurrent property needs to bind on the new wiring; never
    weaken an existing property.

## Acceptance

- With `OOO_EN=1`: an end-to-end test demonstrates a **real different-ID overtake**
  AND same-ID in-order delivery, no cross-ID leakage, all responses delivered.
- With `OOO_EN=0` (default): **every** existing env is byte-identical green
  (`make check` unchanged banners), `make coverage` ≥ `COV_MIN`, `dv/pack` byte-map
  unchanged, formal still 4 proofs green.
- `make regress` ends `[REGRESS] … PASSED`.
- `docs/PLAN.md` F2: move "full-datapath OOO integration" from REMAINING to DONE,
  describing the `OOO_EN` source + the initiator reorder wiring. `README.md` +
  `docs/DOCKER.md` updated.

## Notes / constraints — READ

- **STOP-and-report over faking.** If real OOO integration cannot be done without
  changing the default chain's behavior, or a genuine AXI-ordering counterexample
  appears, **do NOT** weaken the invariant or hack the memory to force green — open
  the PR as **"PARTIAL — design blocker"** describing exactly what breaks and the
  options. A faithful partial with a clear blocker beats a green that fakes OOO.
- The OOO source must be a *legal* AXI/AoU behavior (only different-ID reordering),
  not random corruption. Same-ID order is inviolable.
- Additive/opt-in: `OOO_EN=0` is the shipping default and must be byte-identical.
- Follow repo conventions (pinned-tool absolute paths, banners in the `[..]` style,
  one clean commit per logical step, the `Co-Authored-By` trailer). Never commit on
  `main`; branch and open a PR. Checkpoint continuously (branch early, push
  incrementally, draft PR, mark "PARTIAL — resume needed" on cutoff).
