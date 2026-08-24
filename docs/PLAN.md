# AXI-over-UCIe → AXI memory: RTL + 5 DV environments

## Context

`~/proj/axi-on-ucie-to-mem` is an empty scaffold (`rtl/ dv/ src/ docs/`, empty
`Makefile`, `START_NOTES`). The brief (`START_NOTES`): build an **AXI-over-UCIe
(AoU)** design that reaches a **basic memory**, modeled on the sibling repo
`../uvm_review`, and verify it in **five DV environments** (cocotb + PyUVM,
Icarus, Verilator, SystemC, SystemVerilog UVM), cross-checking design and TBs.
Digital-only host, no commercial simulator (UVM is license-gated and must degrade
gracefully, exactly as `../uvm_review` does). Push to `github.com/markrthomas`
(private repo).

Specs in `docs/`: **AXI over UCIe Protocol Specification v0.8** (AoU, the
transport/message protocol) and the **Open Chiplet Atlas (OCA) System
Architecture Specification v0.8** (the umbrella system spec).

This repo is a sibling of `../uvm_review`, whose layout, Makefile gate targets,
graceful-degradation style, and thorough README are the template to mirror.

### Memory-interface decision (user asked to move off APB)
The user asked to swap the memory interface from APB to "any I/F that would work
well with UCIe." Findings from the specs:
- **OCMI** (mentioned in OCA Ch. 6) is the *Open Chiplet **Management** Interface*
  — a software/SiP-management interface, **not** a memory interface. N/A.
- OCA §5.2 fixes the D2D **bus protocols** to **AXI over UCIe** (`NCOH_PRO`,
  non-/IO-coherent) and **CHI-C2C** (`COH_PRO`, coherent). AXI *is* the
  non-coherent parallel interface carried over UCIe; the AoU profile pins AXI ID
  width = 10 and `QOS_WIDTH` = 2 (REQ-PFAU-15/16). APB is a low-speed peripheral
  bus not intended for a D2D link.

**Decision:** drop APB entirely. The far-side target becomes a **native AXI4-Lite
SRAM memory** — consistent with the AXI4-Lite front door and with AoU carrying
AXI. (CHI-C2C is the coherent alternative but far heavier; out of scope.)

### Confirmed scope (from user)
- **AoU fidelity:** real Basic-Profile message *formats* (§5) + real **flit
  packing** (250 B PLP = 10 B protocol header with FDId + MsgStart[47:0] granule
  bitmap + 240 B / 48 granules of payload), over a ready/valid 256 B streaming
  link. **RP0 only** — an explicit later phase.
  (UPDATE: §6 per-message-type credit flow control on RP0 has since been
  implemented — see the credit helpers in `aou_pkg` and the two bridges. The
  full §8 activation FSM — bring-up (+ §6.4.2 `CrdtGrant` / §6.4.3 reset credit
  exchange), teardown, re-activation, and `ERROR` recovery — is implemented too;
  see `aou_activation.sv` and the `dv/act` unit test.  Both §8.3.2 deactivate
  quiescing options are now modelled: Option 1 (SW pre-quiesces) and Option 2
  (hardware-managed — `deact_trig` mid-transaction is latched, `quiescing` gates
  new requests, teardown withheld until `data_idle`).)
- **AXI flavor:** **AXI4-Lite, 32-bit** (single-beat AW/W/B/AR/R, AWLEN/ARLEN=0),
  both at the front door and at the memory target.
- **GitHub:** create **private** repo `markrthomas/axi-on-ucie-to-mem` now, push
  early + at milestones.
- **This plan** (`docs/PLAN.md`) is committed into the repo as the first commit
  once approved.

## Architecture

Two chiplets joined by a modeled UCIe streaming (FDI-like) link. DUT top =
`axi_ucie_mem_top`:

```
TB AXI-Lite master
      │  AW/W/B/AR/R (32-bit)
      ▼
┌─────────────────────────────┐        256B flit + vld/rdy        ┌─────────────────────────────┐
│ Chiplet A: initiator bridge │  ══ A→B link ═══════════════════▶ │ Chiplet B: target bridge    │
│  AXI-Lite SUB → AoU msgs    │                                   │  AoU msgs → AXI-Lite MGR     │
│  (WriteReq+WriteData256,    │  ◀═══════════════════ B→A link ══ │  → axi_lite_mem (SRAM slave) │
│   ReadReq) + flit pack;     │                                   │  R/B → ReadData256/WriteResp │
│  return flit → R/B          │                                   │  + flit pack                 │
└─────────────────────────────┘                                   └─────────────────────────────┘
```

Message granules (Basic Profile, §5.8): WriteReq 3, ReadReq 3, WriteData256 8,
ReadData256 8, WriteResp 1 — all fit one 48-granule PLP with room to spare, so
packing multiple messages per flit is exercised but never overflows.

### RTL files (`rtl/`)
- **`aou_pkg.sv`** — params + `MSGTYPE`/`MISCOP` enums, field widths & granule
  counts, `GRANULE_BITS=40`, `NUM_GRANULES=48`, `FDID_W=2`; packed-struct typedefs
  for the 5 messages and **pack/unpack functions** (field order per §5.3–5.5
  tables; a single documented bit order shared by packer+unpacker — field widths
  and granule totals match the spec exactly).  (UPDATE: byte-exact packing has
  since been implemented — §5.8 message layouts and the §4.3 Figure-5 protocol
  header — with a `dv/pack` conformance test.)
- **`aou_flit_pack.sv`** — accepts a stream of typed messages, lays them into the
  240 B payload granule-by-granule, sets `MsgStart[47:0]` + `FDId`, emits the
  250 B PLP inside a 256 B flit on a `flit_valid/flit_ready` bus. One flit per
  "batch" of ready messages (single-message batches are legal; empty granules
  padded).
- **`aou_flit_unpack.sv`** — walks `MsgStart` bitmap, slices granules, decodes
  each message by `MSGTYPE`, emits typed messages.
- **`aou_axi_initiator_bridge.sv`** — chiplet A: AXI-Lite **subordinate** front
  (to TB). AW+W → WriteReq+WriteData256; AR → ReadReq; return ReadData256 → R,
  WriteResp → B. Holds a small outstanding-transaction table keyed by
  AWID/ARID (Lite: single ID, depth-1..N FIFO).
- **`aou_axi_target_bridge.sv`** — chiplet B: unpack → drive AXI-Lite **manager**;
  capture R/B → ReadData256/WriteResp → pack return flit.
- **`ucie_stream_link.sv`** — one-directional 256 B flit pipe, valid/ready,
  parameterizable latency/backpressure. **Not** a UCIe PHY/D2D — the FDI boundary
  is the modeled interface (matches spec: everything below FDI is UCIe's own,
  IMPLEMENTATION DEFINED). Two instances (A→B, B→A).
- **`axi_lite_mem.sv`** — the memory target: an **AXI4-Lite 32-bit SRAM slave**
  (word-addressed, zero-wait, `RRESP/BRESP=OKAY`). Replaces the old APB bridge +
  APB memory. Reuses `../uvm_review/rtl/apb_mem.sv` ideas — zero-init array,
  plain-`always` write idiom (VCS ICPD note), coverage waiver on constant
  tie-offs — but with an AXI-Lite (not APB) front end.
- **`axi_ucie_mem_top.sv`** — wires the chain; flat AXI-Lite ports (no SV
  interface on the boundary, for cocotb/Verilator/SystemC portability).

## DV environments (the five in the brief) — `dv/`

Golden reference = the cocotb/PyUVM env (fully runnable here); all others
cross-check the same DUT and the same reference-memory scoreboard.

1. **cocotb + PyUVM** (`dv/cocotb/`) — AXI-Lite master BFM, driver/monitor/agent/
   scoreboard/env, sequences (write-read, constrained-random, walking edge
   cases), `@cocotb.test` entries. Mirrors `../uvm_review/tb/` structure. One sim
   per test (fresh memory), pass/fail gated on `results.xml`. Runs on Icarus.
2. **Icarus SV** (`dv/sv/`) — a self-checking **SystemVerilog** directed TB (AXI
   master tasks + reference-memory checker) runnable under `iverilog`+`vvp`,
   independent of cocotb.
3. **Verilator** (`dv/verilator/` + `sim/`) — the same portable SV TB run under
   Verilator, **plus** a C++ coverage harness (`sim/sim_main.cpp`, modeled on
   `../uvm_review/sim/`) → `sim/coverage.info` (lcov) with a `COV_MIN` floor.
4. **SystemC** (`dv/systemc/`) — `verilator --sc` generates a SystemC model of
   the DUT; a hand-written `sc_main` testbench drives AXI-Lite + scoreboards
   reads. (Verilator-SystemC is the pragmatic OSS path; SystemC headers confirmed
   at `/usr/include/systemc.h`.)
5. **SystemVerilog UVM** (`uvm/`) — full UVM TB mirroring the PyUVM one
   component-for-component, **license-gated**: auto-detects VCS/Xcelium/Questa,
   prints skip + exits 0 when absent. Ships multi-file + single-file
   (`axi_ucie_tb_single.sv`) variants for EDA Playground, per `../uvm_review`.

**Shared assertions** (`dv/sva/`): AXI-Lite protocol checker (front door + memory
port) and AoU message/flit well-formedness (MsgStart consistency, granule bounds),
`bind`-ed onto the DUT in the SV/UVM flows (Icarus/cocotb SVA is too weak to
carry the rich ones — same caveat `../uvm_review` documents).

**Optional (stretch): formal** (`formal/`) — `sby`/yosys is installed; a modest
AXI-Lite protocol property set. Flagged optional, not part of the core five.

## Build/CI
- **Root `Makefile`** mirroring `../uvm_review/Makefile` gate targets: `help`,
  `lint` (iverilog -Wall + Verilator lint), `test`/`test-*` (cocotb), `sv`
  (Icarus SV TB), `vlt` (Verilator SV TB), `systemc`, `uvm`, `coverage`,
  `check`, `regress`, `ci`, `clean`, `waves`/`wave`. Each degrades gracefully if
  its tool is absent.
- **`.github/workflows/ci.yml`** — GitHub Actions running `make ci`.
- **`README.md`** — mirror `../uvm_review/README.md` depth: architecture +
  mermaid diagrams, a spec→RTL field-mapping table, per-env run instructions, a
  step-by-step tutorial, and the EDA-Playground/UVM section.

## Execution phases
0. **Commit `docs/PLAN.md`** (this plan) as the first commit. Scaffold + `aou_pkg`
   + `axi_lite_mem` + top with a pass-through link; **create private GitHub repo,
   push initial commit.**
1. Real message pack/unpack + flit PLP (header/MsgStart); cocotb write-read /
   random / walking green end-to-end. Push.
2. Icarus SV TB + Verilator SV TB + SVA + Verilator coverage harness. Push.
3. SystemC (`verilator --sc`) env. Push.
4. UVM mirror (license-gated) + single-file variant. Push.
5. README + CI polish; final push. (Formal is now a landed, gating tier — see F4.)

Resource planes and multi-message QoS are explicitly **out of scope for this
pass** (documented as future phases in the README).  (UPDATE: §6 credit flow
control, byte-exact §4.3/§5.8 packing, the full §8 activation FSM — bring-up
(§6.4.2 `CrdtGrant` / §6.4.3 reset credit exchange), teardown, re-activation, and
`ERROR` recovery — **AXI4 INCR/WRAP/FIXED bursts** (`AxLEN`/`AxSIZE`/burst type
in FLEX[1:0], per-beat target expansion, `{B,R}ID` echo), and
**multiple-outstanding transactions with in-order completion** (initiator request
queue), **Deactivate quiescing Option 2** (§8.3.2 hardware-managed), **wide data
(512/1024b)**, the **out-of-order-by-ID reorder block**, and a **formal-verification
tier** (yosys-slang; flit + credit proofs, activation in progress) have all since
been implemented.  Only F1 (multiple resource planes) and the full-datapath OOO
integration part of F2 remain.)

## Remaining follow-ons (actionable backlog)

Each item below is self-contained and ordered by rough priority / value. For
each: **Spec** = driving spec sections, **Touch** = files to change, **Approach**
= a starting sketch, **Verify** = how to prove it. The current baseline is
RP0-only, 32-bit, with the full §8 activation FSM (bring-up + teardown + ERROR),
**AXI4 INCR/WRAP/FIXED bursts**, and **multiple-outstanding transactions with
in-order completion** (initiator request queue) already in place.

### F1 — Multiple resource planes (RP0..RP3) + multi-outstanding
- **Spec:** §3 (resource planes / FDId routing), §4.3 (FDId header field), §6
  (per-plane credits), Table 16 (`MsgCredit` RP subfield `[15:14]`), §8.3.4
  Table 25 (per-RP Profile fields in `ActivateReq`).
- **Touch:** `rtl/aou_pkg.sv` — the `FDID_W=2` header field and `flit_fdid`
  decode already exist (always 0 today); the `mk_crdtgrant` / `mk_activate_req`
  message formats already reserve zero-filled RP1..RP3 slots, so add per-plane
  inputs to populate them and thread a plane id through `flit_assemble`. Both
  bridges (per-plane credit banks `cr_*[RP]`, per-plane outstanding tracking +
  arbitration). `dv/sva/aou_flit_sva.sv` + `aou_credit_sva.sv` currently assert
  RP0-only (`a_fdid_rp0`, `a_credit_rp0` = `mc_rp==0`) — relax to per-plane
  bounds; `dv/sva/bind_sva.sv`.
- **Approach:** parameterize `NUM_RP` (start with 2). Replicate the credit
  counters and the initiator request queue per plane; add a small
  round-robin/priority arbiter selecting which plane's message packs into the
  next flit. Keep one plane == today's behavior so the RP0 path is unchanged.
- **Verify:** extend `dv/pack` with multi-RP round-trips; add a cocotb/SV test
  issuing interleaved traffic on two planes and checking no cross-plane
  credit/response leakage; SVA bounds hold per plane.
- **Effort:** large (data-path + arbitration + DV). Biggest single item.

### F2 — Full AXI4 (bursts ✅, multiple-outstanding ✅, wide data ✅, OOO-by-ID block ✅)
- **Spec:** AoU §5 message formats for `WriteData512/1024` and multi-beat
  Read/Write data; AXI4 (`AxLEN>0`, `AxSIZE`, burst types, ID-based reordering).
- **DONE (sub-stages b + in-order c + wide data + OOO-by-ID reorder block):**
  - **INCR/WRAP/FIXED bursts** — `AxLEN`/`AxSIZE` carried in the request, burst
    type in `FLEX[1:0]` (AoU has no `AxBURST`); the target expands each burst into
    single-beat AXI-Lite accesses (per-beat `axi_burst_next`), `{B,R}ID` echoed,
    `RLAST` on the final beat. Credit ceilings raised to 128 granules (16 beats).
  - **Multiple-outstanding, in-order** — a `REQ_QD`-deep request queue in
    `aou_axi_initiator_bridge` decouples AW/AR accept from the FSM, so several
    transactions (distinct IDs) can be outstanding at once. Verified in cocotb
    (`multi_outstanding_test`), SV, SystemC, and the coverage harness.
  - **Wide data (512b/1024b)** — `aou_pkg` gained `mk_writedata512/1024`,
    `mk_readdata512/1024` and matching width-specific getters (`wd_data512/1024`,
    `rd_data512/1024`, `msg_dlength`), with `MSG_MAX_BITS` widened to 1200b / 30
    granules (WriteData1024, Table 6) — every message stays left-justified, so
    the 256b end-to-end path is byte-identical.  The wide builders/getters are
    off the 32-bit AXI end-to-end path (kept out of coverage line accounting) and
    are byte-exactly conformance-tested in `dv/pack` (DLENGTH byte-map, data-field
    byte offset, full field round-trip; 63 checks, Icarus + Verilator).
  - **Out-of-order-by-ID completion** — the current topology (single serialized
    flit link + single in-order memory) gives OOO **no natural source**, so it is
    delivered as the deliberate per-ID reorder buffer the initiator would need:
    `rtl/aou_reorder.sv` allocates a slot per transaction in issue order, accepts
    completions addressed by tag in ANY order, and releases each response as the
    oldest un-released of its ID — so a younger different-ID response overtakes an
    older uncompleted one while same-ID responses stay in issue order (the AXI
    rule).  It is a self-contained, synthesizable block (not wired into the
    in-order full chain, which never reorders), verified in `dv/reorder`
    (cross-ID overtake, same-ID ordering, capacity/reclaim, and a scrambled-
    completion per-ID reference-FIFO drain; 76 checks, Icarus + Verilator).  Full
    datapath integration (variable-latency / interleaved target) is future work.
- **Verify:** per-beat burst scoreboards in cocotb/SV/SystemC; multiple-
  outstanding tests fill the queue and check in-order completion; `dv/pack` for
  wide data; `dv/reorder` for out-of-order-by-ID release.
- **Effort:** full-datapath OOO integration (interleaved target) remains, sized
  independently.

### F3 — Deactivate quiescing Option 2 (hardware-managed quiescing) — DONE
- **Spec:** §8.3.2 (Option 2 is OPTIONAL; Option 1 already implemented).
- **DONE:** `aou_activation` gained a `data_idle` input and a `quiescing` output.
  `deact_trig` may now be asserted at any time: the FSM latches the intent
  (`deact_pending`), raises `quiescing` (the bridge's hook to stop accepting new
  AXI requests), and holds in ENABLED — letting in-flight Data/WriteResp drain,
  which the spec permits after the flag is set — entering DEACTIVATE to emit
  `DeactivateReq` only once `data_idle` asserts.  Option 1 is the degenerate case
  where `data_idle` is tied high (as both bridges tie it in the full chain, where
  no SW teardown is driven).  A peer-initiated `DeactivateReq` is still answered
  immediately, independent of the local quiescing gate.
- **Verify (done):** `dv/act` case 2b raises `deact_trig` mid-transaction with
  `data_idle=0`, checks the DUT stays ENABLED with `quiescing` high, then asserts
  `data_idle` and checks teardown proceeds to DISABLED (30 checks, Icarus +
  Verilator).  Full-chain envs unchanged (deact tied off) — all five green,
  coverage floor still met.
- **REMAINING:** wiring `quiescing`/`data_idle` into real bridge request-accept
  and drain logic (a full-chain SW teardown) is left for when a use case needs
  it; the mechanism is proven in `dv/act`.

### F4 — Whole-chain formal — DONE
- **Spec:** n/a (methodology).
- **DONE — tooling blocker resolved.** The **yosys-slang** frontend (bundled in
  the pinned oss-cad-suite) reads the full SV the RTL uses (`module … import
  aou_pkg::*;`, packed structs, functions in `always_comb`, `bind`), so **no
  Verific and no hand-abstraction are needed** — the original blocker is gone.
  Formal is now a **first-class gating tier**: `make regress` / `make ci` run it,
  with the pinned prover passed by absolute path (`SBY=$OSS/bin/sby`), `bmc`+`cover`
  gating and `prove` best-effort. Proven:
  - `formal/aou_flit*` — §4.3 byte-exact header map + §5.8 packing round-trip,
    checked against an independent Figure-5 transcription.
  - `formal/aou_credit*` — §6 credit invariants on the **real bridges**
    (`aou_axi_initiator_bridge` / `aou_axi_target_bridge`, fully adversarial peer):
    counters never exceed their ceilings; credit is spent only for the message
    type actually sent.
  - `formal/aou_activation*` — the **§8 activation-FSM invariants**, with the
    FSM driven by a fully adversarial peer (free 2000-bit RX flit) and free
    `deact_trig`/`data_idle`/`err_clear` controls: never `ENABLED` before the
    peer's `CrdtGrant` (proven both from the FSM's own flags *and* from an
    independent link-level decode of the raw flit); no data-transfer enable
    (`d_tx_ready`/`d_rx_valid`/`quiescing`) in a non-`ENABLED` state, and only
    Misc Activation/CrdtGrant messages on the link while not `ENABLED`; only
    legal Table-24 transitions, with `DEACTIVATE` entered solely from `ENABLED`
    and solely on a peer `DeactivateReq` or with `data_idle` high (the F3
    Option-2 gate); and `ERROR` sticky until `err_clear`, then always back to a
    fully re-armed `DISABLED`. Covers: bring-up → `ENABLED`, credit seeding,
    Option-2 quiescing, teardown → `DISABLED`, `ERROR` entry and recovery.
  - `formal/axi_lite_mem*` — the memory target (unchanged, stock `read_verilog`).
- **Verify:** `make formal` (all four proofs, `bmc`+`cover` gate; `prove`
  best-effort — the activation proof also converges under unbounded k-induction).
  All three AoU proofs are mutation-tested for non-vacuity.
- **REMAINING:** only an end-to-end *datapath* proof (an AXI write reappearing in
  memory through the 2000-bit flit path) is still simulation-only; the memory
  target, packing map, flow control and interface state machine are all formal.

## Verification (how to check end-to-end)
- `make test` — three cocotb/PyUVM tests PASS (fresh memory per test).
- `make sv` / `make vlt` — SV directed TB self-checks under Icarus / Verilator.
- `make systemc` — SystemC TB reports 0 mismatches.
- `make coverage` — Verilator lcov ≥ `COV_MIN` floor.
- `make uvm` — prints clean skip here (no license), runs real on a licensed host.
- `make ci` — lint + cocotb regression + coverage as one pass/fail gate.
- Spot-check waveforms: `make wave` shows AXI AW/W handshake → a flit with
  `MsgStart` bits set for WriteReq+WriteData → far-side AXI-Lite memory write →
  WriteResp flit → AXI B.

## Key references reused
- `../uvm_review/rtl/apb_mem.sv` (memory-array idioms, re-fronted as AXI-Lite),
  `../uvm_review/Makefile`
  (gate-target template), `../uvm_review/tb/*` (cocotb TB structure),
  `../uvm_review/uvm/*` (UVM mirror + single-file pattern),
  `../uvm_review/sim/sim_main.cpp` (Verilator coverage harness),
  `../uvm_review/README.md` (doc depth/style).
