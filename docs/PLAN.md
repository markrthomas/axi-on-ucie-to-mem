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
   Carries the repo's **functional** coverage model (`dv/cocotb/axi_coverage.py`)
   — a stdlib-only covergroup helper sampled by a `uvm_subscriber` off the
   monitor's analysis port, merged across the per-test sims of one `make test`
   run, printed as a `[COV-FUNC]` table and gated on `FCOV_MIN` (default 100%).
   So the repo now has **both** coverage flavours: Verilator *line* coverage
   (`make coverage`, `COV_MIN`) and PyUVM *functional* coverage (`make test`,
   `FCOV_MIN`).
2. **Icarus SV** (`dv/sv/`) — a self-checking **SystemVerilog** directed TB (AXI
   master tasks + reference-memory checker) runnable under `iverilog`+`vvp`,
   independent of cocotb.
3. **Verilator** (`dv/verilator/` + `sim/`) — the same portable SV TB run under
   Verilator, **plus** a C++ *line*-coverage harness (`sim/sim_main.cpp`, modeled
   on `../uvm_review/sim/`) → `sim/coverage.info` (lcov) with a `COV_MIN` floor.
   (Functional coverage lives in the PyUVM env — see 1 above.)
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
- **Waveform debugging (dev-only) — DONE (SWARM_PLAN feature 2 of 3).** The single
  `dv/wave.gtkw` became `dv/waves/`, **one curated GTKWave layout per debug
  target** — `default` (generic cocotb fallback), `write_read`, `burst`,
  `multi_outstanding`, `sv`, `ooo`, `mrp`, `act` — sharing one group scheme
  (Clock/Reset → AXI front door → AoU bridge → UCIe flit link → §6 credits →
  memory) with `@800200`/`@1000200` group markers and `+{human alias}` names.
  `make wave [TEST=<name>]` picks `dv/waves/<key>.gtkw` (key = test name minus
  `_test`) and falls back to `default.gtkw`; `wave-sv|-ooo|-mrp|-act` and
  `waves-sv|-ooo|-mrp|-act|-all` extend the flow to the SV envs, which dump via
  `dv/common/aou_wave_dump.svh` under `-DAOU_WAVES` — a define only those targets
  pass, so the gate elaborates no dump logic and stays byte-identical.
  `make wave-check` is the drift-guard: it resolves every `.gtkw` net path against
  that target's real dump hierarchy (oss-cad-suite `fst2vcd`) and fails naming the
  orphan. It is **dev/opt-in and deliberately NOT in `check`/`regress`/`ci`**, so
  the gate stays wave-free and GTKWave-independent. It immediately caught real
  rot: 23 of the old `dv/wave.gtkw`'s 42 net paths had died when the single-plane
  chain moved under the `g_rp1` generate wrapper.
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
(512/1024b)**, the **out-of-order-by-ID reorder block** *and its opt-in
full-datapath integration* (`OOO_EN`), **multiple resource planes** *and their
opt-in full-datapath integration* (`NUM_RP`: per-plane credit banks, a
round-robin plane arbiter and `FDId` routing), and a **formal-verification tier**
(yosys-slang; flit + credit proofs, activation in progress) have all since been
implemented.)

## Remaining follow-ons (actionable backlog)

Each item below is self-contained and ordered by rough priority / value. For
each: **Spec** = driving spec sections, **Touch** = files to change, **Approach**
= a starting sketch, **Verify** = how to prove it. The current baseline is
RP0-only, 32-bit, with the full §8 activation FSM (bring-up + teardown + ERROR),
**AXI4 INCR/WRAP/FIXED bursts**, and **multiple-outstanding transactions with
in-order completion** (initiator request queue) already in place.

### F1 — Multiple resource planes (RP0..RP3) — DONE (2 planes proven, generalises to 4)
- **Spec:** §3 (resource planes / FDId routing), §4.3 (FDId header field), §6
  (per-plane credits), Table 16 (`MsgCredit` RP subfield `[15:14]`), §8.3.4
  Table 25 (per-RP Profile fields in `ActivateReq`), Table 18 (per-RP
  `CrdtGrant` slots).
- **DONE — opt-in `NUM_RP` (default 1), `NUM_RP=1` byte-identical:**
  - **Plane id end-to-end.** `aou_pkg` gained per-plane `CrdtGrant` (Table 18)
    and `ActivateReq` (Table 25) slot builders/getters — `mk_crdtgrant_rp`,
    `mk_activate_req_rp`, `cg_{wreq,rreq,wdata,rdata,wresp}(m,rp)`,
    `ar_prof_{id,rev,opt}(m,rp)` — with the old RP0 entry points kept as `rp=0`
    wrappers, proven **byte-identical** in `dv/pack`. Both bridges and
    `aou_activation` take an `RP_ID` parameter (default 0) that is stamped into
    the §4.3 `FDId` (`flit_assemble`'s existing `fdid` input), the §5.8 `RP`
    field of every message, and the Table-16 `MsgCredit` RP subfield; the peer's
    `CrdtGrant` is decoded from **that plane's own slot**, so a grant addressed
    to another plane seeds nothing.
  - **Per-plane credit banks + outstanding tracking.** Realised by replicating
    the whole chain per plane: at `NUM_RP>1` each plane owns an initiator
    bridge, a target bridge, its §8 activation FSM, its `cr_*` counters, its
    request queue and its memory image. That is stronger isolation than an
    indexed bank inside a shared bridge (there is no shared state to leak
    through) and it leaves the `NUM_RP==1` generate branch elaborating the
    existing single-plane logic **verbatim** — the F2 pattern.
  - **Plane arbiter + FDId routing** — new `rtl/aou_rp_mux.sv`. `aou_rp_arb` is
    a round-robin N→1 egress arbiter (a ready plane waits at most `NUM_RP-1`
    grants; the grant is locked while the link stalls so the presented flit
    stays stable for the §4.3 flit SVA). `aou_rp_route` is the 1→N ingress: it
    routes each arriving flit by its `FDId` into that plane's **own** receive
    queue. §6.1 says a credit guarantees the receiver has room, so the queue is
    sized to the largest grant (128 granules / 8 = 16 flits) — owning that room
    is what stops a stalled plane back-pressuring the SHARED link and turning
    one plane's stall into every plane's stall (head-of-line blocking). An
    unroutable `FDId` is consumed and dropped so it can never wedge the link;
    `aou_rp_sva` proves that path is dead.
  - **Top-level wiring.** `axi_ucie_mem_top` takes `NUM_RP` (default 1). Of the
    plan's two options — replicate the AXI front end, or add a plane-select
    side-band — the replication was chosen and the replicas were **flattened
    into the existing boundary ports** (plane `p` owns bit slice `[p*W +: W]`).
    That adds **no port at all**, so at `NUM_RP=1` every port keeps its
    historical width (`[0:0]` control ports still map to `sc_in<bool>` for the
    SystemC env) and no existing testbench changes; and it gives each plane its
    own AXI request/response channels, so a response delivered to the wrong
    plane is directly observable at the boundary rather than needing an internal
    probe.
  - **Activation.** Per-plane rather than per-chain: each plane runs the §8 FSM
    over the shared link with its own `FDId`, so RP1 brings its own credits and
    profile up through the existing (unchanged) Table-25/Table-18 machinery.
  - **Verified.** New `dv/mrp` env (`make mrp`, Icarus + Verilator + bound SVA)
    at `NUM_RP=2`: interleaved single-beat traffic then CONCURRENT multi-beat
    bursts that saturate the shared link, checking (a) per-plane routing — both
    planes write the SAME addresses with DIFFERENT data and each must read back
    its own, plus a per-flit `FDId` / `MsgCredit`-RP delivery monitor; (b) no
    cross-plane credit leakage — plane 1's five §6 counters must not move by a
    single count while only plane 0 runs, and a deliberately jammed plane 0
    (never accepts an R beat, so its ReadData credits run out) must not stop
    plane 1 completing; (c) arbiter fairness measured only on **contended**
    cycles; (d) every transaction completes. Mutation-tested: mis-tagging the
    `MsgCredit` RP, routing every flit to plane 0, a fixed-priority arbiter and
    an undersized per-plane receive queue each make the env fail.
    `dv/pack` grew 63 → 229 checks (per-plane slot round-trips + the RP0
    byte-identity proof); `dv/sva/aou_flit_sva.sv`'s `a_fdid_rp0` /
    `a_credit_rp0` became the per-plane bounds `a_fdid_range` /
    `a_credit_rp_range`, which at `NUM_RP=1` are exactly the old properties.
- **Not done / follow-on:** only 2 planes are exercised (the format ceiling
  `MAX_RP=4` is implemented and `dv/pack` round-trips all four slots, but no
  4-plane end-to-end run is in the gate), and planes share the link but not a
  memory — each plane has its own image, which is what makes cross-plane data
  leakage observable. A shared target behind a per-plane AXI arbiter is the
  natural next step.

### F2 — Full AXI4 (bursts ✅, multiple-outstanding ✅, wide data ✅, OOO-by-ID ✅ end-to-end) — DONE
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
  - **Out-of-order-by-ID reorder block** — `rtl/aou_reorder.sv` allocates a slot
    per transaction in issue order, accepts completions addressed by tag in ANY
    order, and releases each response as the oldest un-released of its ID — so a
    younger different-ID response overtakes an older uncompleted one while
    same-ID responses stay in issue order (the AXI rule).  Verified standalone in
    `dv/reorder` (cross-ID overtake, same-ID ordering, capacity/reclaim, and a
    scrambled-completion per-ID reference-FIFO drain; 76 checks, Icarus +
    Verilator).
  - **Full-datapath OOO integration (`OOO_EN`, opt-in, default 0)** — the
    in-order topology (single serialized flit link + single in-order memory) has
    **no natural OOO source**, so one was added, and the reorder buffer was wired
    into the response path behind it:
    * **OOO source (target).** `rtl/aou_ooo_resp_src.sv` sits on the target
      bridge's response flit path.  It may HOLD one completed single-flit
      response (a `WriteResp`, or a single-beat `ReadData`) and forward a later
      response of a **different ID** past it, so that response really does
      overtake on the link.  The held one is released as soon as one whole
      transaction has passed it, or a **same-ID** response arrives (same-ID order
      is inviolable), or a bounded hold timer expires (liveness when there is
      nothing to overtake).  Multi-flit read bursts are always forwarded whole
      and are never held, so a transaction's flits are never split or
      interleaved.  Bounded state: one flit register, one ID, one down-counter.
    * **Transaction tag.** No new message field: the tag rides in `FLEX[15:12]`,
      a slice of an existing §5.2 FLEX field (`FLEX[1:0]` already carries
      `AxBURST`).  The initiator stamps the reorder-slot index on the
      `WriteReq`/`ReadReq`; the target echoes it into the `WriteResp`/`ReadData`.
      At `OOO_EN=0` the initiator stamps 0 and the target echoes 0, so the §4.3 /
      §5.8 byte map is unchanged (`dv/pack` 63 checks unchanged).
    * **Reorder wiring (initiator).** At `OOO_EN=1` the initiator FSM issues a
      request and returns to idle instead of blocking on its response, so up to
      `OOO_DEPTH` transactions are in flight.  Two `aou_reorder` instances —
      reads → R, writes → B, so neither channel head-of-line blocks the other —
      allocate a slot per issue keyed by AXI ID, take `cmp_*` by tag as
      completions arrive in any order, and present `out_*` (oldest-of-its-ID)
      onto the AXI R/B channels through registered output stages (the buffer's
      `out_*` select is combinational and can re-point, so it is latched before a
      burst is streamed).  `DEPTH = REQ_QD` (power of two); no new unbounded
      state.  §6 credit accounting is folded into a single next-value so a send
      and a replenish landing in the same cycle cannot drop a credit, and the
      request-message credit grants scale with the outstanding capacity **only**
      in OOO mode.  Issue is additionally throttled by the §6 ReadData credit
      ceiling: because this bridge only returns response credits piggybacked on
      its next request flit, an unthrottled OOO issue path can leave the target
      stalled at zero credits with no further request behind it to carry the
      returns — so each read is charged its `(AxLEN+1)*READDATA_GRAN` granules at
      issue and released per beat, and a read that would push the in-flight total
      past the granted ceiling waits.  A lone transaction is always let through,
      so the worst case degenerates to the in-order path.
    * **Default-off invariant.** All of the above lives in `generate` branches /
      a separate module that are **not elaborated** at `OOO_EN=0`, so the
      shipping default chain is bit- and cycle-identical to the in-order build
      (`dv/sv` reaches `$finish` on the same cycle, 18920, as before).
- **Verify:** per-beat burst scoreboards in cocotb/SV/SystemC; multiple-
  outstanding tests fill the queue and check in-order completion; `dv/pack` for
  wide data; `dv/reorder` for the standalone reorder block; and `dv/ooo`
  (`make ooo`, Icarus + Verilator) for the end-to-end OOO chain — interleaved
  multi-ID traffic against `axi_ucie_mem_top #(.OOO_EN(1))`, checking same-ID
  in-order delivery against a per-ID reference FIFO, **a real different-ID
  overtake** (counted; the test FAILS at zero), no cross-ID leakage, and that
  every response is delivered:
  `[OOO-TB] PASS: 80 read beats checked, 4 R + 6 B different-ID overtakes, 0 errors`.
  Negative control: the same TB at `OOO_EN=0` observes `0 R + 0 B` overtakes and
  fails, so the check observes reordering rather than merely tolerating it.

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

### F5 — PyUVM functional-coverage closure — DONE
- **Spec:** n/a (methodology).
- **DONE.** The PyUVM env now carries the repo's functional coverage model,
  `dv/cocotb/axi_coverage.py`: a stdlib-only covergroup helper (no new pip
  dependency) with eight coverpoints — direction, address partition (derived from
  the DUT's `MEM_ADDR_W`, not a hardcoded size), first/last-word boundary,
  payload pattern (zero / all-ones / walking-1 / walking-0 / alternating /
  other), observed `BRESP`/`RRESP` encoding, burst-length bucket, outstanding
  depth, and the direction × address-region cross. `AxiCoverageCollector`
  (a `uvm_subscriber`) hangs off the **monitor's** analysis port, so only traffic
  the DUT actually completed on the bus is credited — never stimulus, never RTL
  internals. Because `make test-all` runs each test in its own simulation, the
  model merges through a small JSON database (`FCOV_DB`), prints a `[COV-FUNC]`
  table per test, and the new `coverage_test` — which runs last and whose
  `AxiCoverageCloseSeq` closes every bin on its own — gates the merged result
  against `FCOV_MIN` (default **100%**) with a `[COV-FUNC] PASS/FAIL` banner.
- **Verify (done):** `make test` → 26/26 goal bins = 100.0%, `[COV-FUNC] PASS`;
  the floor really gates (`make test-coverage FCOV_MIN=101` fails the sim).
- **NOT REACHABLE HERE:** the `EXOKAY`/`SLVERR`/`DECERR` response encodings are
  kept as *excluded* bins with a recorded reason rather than deleted —
  `rtl/axi_lite_mem.sv` ties `BRESP`/`RRESP` to `RESP_OKAY` and the bridges
  transport that value verbatim, so hitting them needs an RTL behaviour change
  (out of scope for an additive-DV task). AoU-protocol state (message type,
  credits, activation) is not observable at this env's AXI interface; it stays
  covered by `dv/pack`, `dv/act`, `dv/reorder` and the formal tier.

## Verification (how to check end-to-end)
- `make test` — six cocotb/PyUVM tests PASS (fresh memory per test), ending with
  the `[COV-FUNC]` functional-coverage report and its `FCOV_MIN` floor.
- `make sv` / `make vlt` — SV directed TB self-checks under Icarus / Verilator.
- `make systemc` — SystemC TB reports 0 mismatches.
- `make coverage` — Verilator lcov ≥ `COV_MIN` floor.
- `make uvm` — prints clean skip here (no license), runs real on a licensed host.
- `make ci` — lint + cocotb regression + coverage as one pass/fail gate.
- Spot-check waveforms: `make wave TEST=write_read_test` opens pre-populated with
  `dv/waves/write_read.gtkw` and shows AXI AW/W handshake → a flit with `MsgStart`
  bits set for WriteReq+WriteData → far-side AXI-Lite memory write → WriteResp
  flit → AXI B. `make wave-ooo` / `wave-mrp` / `wave-act` open their own layouts.
- `make wave-check` — every committed `.gtkw` net path still resolves in its dump
  (dev-only; not part of the gate).

## Key references reused
- `../uvm_review/rtl/apb_mem.sv` (memory-array idioms, re-fronted as AXI-Lite),
  `../uvm_review/Makefile`
  (gate-target template), `../uvm_review/tb/*` (cocotb TB structure),
  `../uvm_review/uvm/*` (UVM mirror + single-file pattern),
  `../uvm_review/sim/sim_main.cpp` (Verilator coverage harness),
  `../uvm_review/README.md` (doc depth/style).
