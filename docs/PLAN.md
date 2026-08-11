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
  see `aou_activation.sv` and the `dv/act` unit test.  Only Deactivate quiescing
  Option 2 (§8.3.2, OPTIONAL hardware quiescing) is left out.)
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
5. README + CI polish; final push. (Formal = optional follow-on.)

Resource planes, multi-message QoS, and AXI4 bursts are explicitly **out of
scope for this pass** (documented as future phases in the README).  (UPDATE: §6
credit flow control, byte-exact §4.3/§5.8 packing, and the full §8 activation
FSM — bring-up (§6.4.2 `CrdtGrant` / §6.4.3 reset credit exchange), teardown,
re-activation, and `ERROR` recovery — all originally listed here as out of
scope, have since been implemented; only Deactivate quiescing Option 2 (§8.3.2,
OPTIONAL) remains future.)

## Remaining follow-ons (actionable backlog)

Each item below is self-contained and ordered by rough priority / value. For
each: **Spec** = driving spec sections, **Touch** = files to change, **Approach**
= a starting sketch, **Verify** = how to prove it. The current baseline is
RP0-only, single-outstanding, AXI4-Lite 32-bit, with the full §8 activation FSM
(bring-up + teardown + ERROR) already in place.

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
  counters and the single-outstanding transaction slot per plane; add a small
  round-robin/priority arbiter selecting which plane's message packs into the
  next flit. Keep one plane == today's behavior so the RP0 path is unchanged.
- **Verify:** extend `dv/pack` with multi-RP round-trips; add a cocotb/SV test
  issuing interleaved traffic on two planes and checking no cross-plane
  credit/response leakage; SVA bounds hold per plane.
- **Effort:** large (data-path + arbitration + DV). Biggest single item.

### F2 — Full AXI4 (INCR bursts, out-of-order IDs, wide data)
- **Spec:** AoU §5 message formats for `WriteData512/1024` and multi-beat
  Read/Write data; AXI4 (`AxLEN>0` INCR, `AxSIZE`, ID-based reordering).
- **Touch:** `rtl/axi_lite_mem.sv` → a full AXI4 slave (or a new
  `rtl/axi_mem.sv`), both bridges (burst→multi-granule packing, per-ID response
  reorder buffers), `rtl/aou_pkg.sv` (wider `WriteData`/`ReadData` builders +
  `MSG_MAX_BITS`), the cocotb BFM `dv/cocotb/axi_lite_bfm.py` (AXI4 burst driver)
  and scoreboard, the SV/SystemC TBs, and `dv/pack` (wide-data byte-exactness).
- **Approach:** stage it — (a) single-beat 512b/1024b data first (just wider
  granule packing), then (b) INCR bursts with `AxLEN`, then (c) multiple
  outstanding IDs with reorder. Each sub-stage is independently committable.
- **Verify:** burst read/write scoreboard in cocotb; `dv/pack` byte-exact checks
  for the wide `WriteData`/`ReadData` layouts; SVA for beat counts vs `AxLEN`.
- **Effort:** large; naturally splits into (a)/(b)/(c).

### F3 — Deactivate quiescing Option 2 (hardware-managed quiescing)
- **Spec:** §8.3.2 (Option 2 is OPTIONAL; Option 1 already implemented).
- **Touch:** `rtl/aou_activation.sv` (+ a hook into each bridge's data FSM idle
  status), `dv/act/tb_aou_act.sv`.
- **Approach:** today `deact_trig` must be asserted only when the data path is
  quiesced (Option 1). For Option 2, let `deact_trig` be asserted at any time:
  latch the intent, stop accepting new AXI requests, drain in-flight
  Data/WriteResp (the spec explicitly permits those to complete after
  `DeactivateReq`), then send `DeactivateReq` once the bridge reports idle. Needs
  a `data_idle`/`quiesced` signal from the bridge into the activation module and
  a "pending requests must finish first" gate.
- **Verify:** add a `dv/act` case that raises `deact_trig` mid-transaction and
  checks `DeactivateReq` is withheld until the (stubbed) `data_idle` asserts;
  full-chain test that deactivates with an outstanding transaction and confirms
  the response still drains.
- **Effort:** small–medium; mostly local to `aou_activation` + one bridge signal.

### F4 — Whole-chain formal
- **Spec:** n/a (methodology). Current `formal/axi_lite_mem.sby` proves the
  memory target only.
- **Touch:** `formal/` (new `.sby` + properties), reuse `dv/sva/*` bound checkers
  as the property source.
- **Approach:** the bridge/flit path needs a SystemVerilog front end that Yosys's
  built-in reader can't fully handle (packed structs, functions in `always_comb`).
  Options: (a) a Verific-based front end (Tabby CAD / commercial), or (b)
  hand-abstract the flit packing into bit-blasted helpers Yosys can read. Start
  with bounded (`bmc`) proofs of the credit-counter and activation-FSM invariants
  (no counter overflow; never `ENABLED` before `CrdtGrant`; never a data flit
  while a peer is not `ENABLED`).
- **Verify:** `make formal TASK=bmc` extended to the bridges; `prove` for the
  FSM/credit invariants if the front end supports it.
- **Effort:** medium, but **blocked on tooling** (no Verific in the local
  oss-cad-suite) unless the hand-abstraction route is taken.

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
