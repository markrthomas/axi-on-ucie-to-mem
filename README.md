# axi-on-ucie-to-mem

[![CI](https://github.com/markrthomas/axi-on-ucie-to-mem/actions/workflows/ci.yml/badge.svg)](https://github.com/markrthomas/axi-on-ucie-to-mem/actions/workflows/ci.yml)

**AXI4-Lite transported over an AXI-over-UCIe (AoU) link to an AXI-Lite memory**,
verified in **five DV environments** — cocotb + PyUVM, Icarus, Verilator, SystemC,
and a license-gated SystemVerilog UVM mirror — that all cross-check the same
design against the same reference-memory model. Digital-only, open-source
toolchain. Sibling project to `uvm_review`.

## What it is

The design bridges an on-chip **AXI4-Lite** interface across a modeled **UCIe
streaming (FDI) link** using the **AXI-over-UCIe (AoU) Basic Profile** message
set, delivering transactions to a far-side **AXI4-Lite SRAM memory**. AXI is the
OCA non-coherent bus protocol carried over UCIe (OCA System Architecture spec
§5.2), so the memory speaks AXI natively rather than a peripheral bus like APB.

Two "chiplets" are joined by the link. The initiator bridge turns AXI writes and
reads into AoU messages, **packs multiple messages into one 250-byte PLP flit**
(a real 10-byte protocol header with the `MsgStart[47:0]` granule bitmap plus
48 × 5-byte granules of payload), and the target bridge **walks that bitmap** to
unpack them and drive the memory.

```mermaid
flowchart LR
    M["AXI4-Lite master<br/>(TB: cocotb / SV / SystemC / UVM)"]

    subgraph A["Chiplet A — initiator bridge"]
      PK["pack:<br/>AW+W → WriteReq+WriteData256<br/>AR → ReadReq"]
      UPA["unpack return:<br/>ReadData→R, WriteResp→B"]
    end
    subgraph L["ucie_stream_link (FDI model)"]
      AB["A → B  flit"]
      BA["B → A  flit"]
    end
    subgraph B["Chiplet B — target bridge"]
      UPB["unpack (walk MsgStart)<br/>→ AXI-Lite manager"]
      PKB["pack return:<br/>R→ReadData256, B→WriteResp"]
    end
    MEM["axi_lite_mem<br/>(AXI4-Lite SRAM, 64 KiB)"]

    M <-->|"AW/W/B/AR/R"| PK
    PK --> AB --> UPB --> MEM
    MEM --> PKB --> BA --> UPA
    UPA <--> M
    UPB -.-> PKB
```

## AoU Basic-Profile mapping (spec §5)

Each AXI transaction maps to AoU messages with the spec's exact field widths and
granule counts (1 granule = 5 bytes = 40 bits; 48 granules per PLP payload):

| AXI action | AoU messages (granules) | Direction |
|------------|-------------------------|-----------|
| write (AW+W) | `WriteReq` (3) + `WriteData256` (8) packed in one flit | A → B |
| read (AR)    | `ReadReq` (3)                                          | A → B |
| read data (R)  | `ReadData256` (8)                                   | B → A |
| write resp (B) | `WriteResp` (1)                                     | B → A |

A write flit therefore carries **two messages** (`MsgStart` bits 0 and 3 set),
exercising real multi-message packing; the unpacker is bitmap-driven. This build
covers the Basic Profile, Resource Plane RP0, 32-bit single-beat AXI-Lite
(`AWLEN=ARLEN=0`, `DLENGTH=256b`); AXI data occupies the low 32 bits of the AoU
data field and the AoU 10-bit ID carries a per-transaction tag echoed on the
response. See [`docs/PLAN.md`](docs/PLAN.md) for the full architecture and the
out-of-scope follow-ons (credit flow control §6, activation FSM §8, resource
planes, AXI4 bursts).

## Directory layout

- `rtl/` — the design:
  - `aou_pkg.sv` — AoU message formats + flit pack/unpack helper functions
  - `ucie_stream_link.sv` — one-directional flit channel (FDI-boundary model)
  - `aou_axi_initiator_bridge.sv` / `aou_axi_target_bridge.sv` — the two bridges
  - `axi_lite_mem.sv` — AXI4-Lite SRAM memory target
  - `axi_ucie_mem_top.sv` — the DUT top (wires the chain + return link)
- `dv/cocotb/` — cocotb + PyUVM testbench (the golden runnable env)
- `dv/sv/` — portable self-checking SV directed TB (Icarus + Verilator)
- `dv/sva/` — AXI-Lite + AoU-flit assertion checkers (bound to the DUT)
- `dv/systemc/` — SystemC testbench (`verilator --sc` model + `sc_main`)
- `uvm/` — SystemVerilog UVM TB (multi-file + single-file), license-gated
- `sim/` — Verilator C++ coverage harness
- `Makefile` — standard DV gate targets; `docs/PLAN.md` — the design plan

## The five DV environments

All drive the same DUT and check reads against a reference word memory.

| Environment | Directory | Runs here? | What it is |
|-------------|-----------|-----------|------------|
| cocotb + PyUVM | `dv/cocotb/` | ✅ | AXI-Lite BFM + driver/monitor/agent/scoreboard; write-read / random / walking tests |
| Icarus (SV) | `dv/sv/` | ✅ | portable self-checking SV directed TB under `iverilog`+`vvp` |
| Verilator (SV) | `dv/sv/` | ✅ | same SV TB under `--binary --timing`, **plus bound SVA** (`--assert`) |
| SystemC | `dv/systemc/` | ✅ | `verilator --sc` DUT model + hand-written `sc_main` driver/scoreboard |
| SystemVerilog UVM | `uvm/` | ⚠️ skips | full UVM mirror; needs VCS/Xcelium/Questa — skips cleanly if unlicensed |

The **PyUVM** and **UVM** testbenches map one-for-one:

| PyUVM (`dv/cocotb/`) | SystemVerilog UVM (`uvm/`) |
|----------------------|----------------------------|
| `axi_lite_bfm.py` (cocotb BFM) | `axi_lite_if.sv` + driver/monitor virtual interface |
| `AxiSeqItem` | `axi_seq_item.sv` |
| `axi_seq.py` sequences | `axi_sequences.sv` |
| driver / monitor / agent | `axi_driver.sv` / `axi_monitor.sv` / `axi_agent.sv` |
| `AxiScoreboard` | `axi_scoreboard.sv` |
| `AxiEnv` | `axi_env.sv` |
| tests + `@cocotb.test` | `axi_test.sv` + `axi_ucie_tb_top.sv` (`run_test`) |

```mermaid
flowchart TB
    SEQ["Sequence<br/>write-read · random · walking"]
    subgraph TEST["test — builds env, drives reset, starts the sequence"]
      subgraph ENV["env"]
        subgraph AG["agent (active)"]
          SEQR["Sequencer"]; DRV["Driver"]; MON["Monitor"]
        end
        SB["Scoreboard<br/>reference word memory<br/>read == last write"]
      end
    end
    IF["AXI-Lite interface / cocotb BFM"]
    DUT["axi_ucie_mem_top (DUT)"]
    SVA["axi_lite_sva / aou_flit_sva<br/>(bound; SV/Verilator/UVM flows)"]

    SEQ -->|items| SEQR --> DRV -->|drive AW/W/AR| IF
    IF <-->|AXI-Lite| DUT
    IF -->|sample| MON -->|analysis port| SB
    DUT -.->|bind| SVA
```

## Verification

Everything runs from the repo root and degrades gracefully if a tool is absent.

| Flow | Command | What it does |
|------|---------|--------------|
| Full regression | `make test` | all three cocotb tests (write-read, random, walking) |
| Directed | `make test-write-read` / `test-random` / `test-walking` | one cocotb test |
| SV (Icarus) | `make sv` | portable SV directed TB under Icarus |
| SV (Verilator) | `make vlt` | same TB under Verilator + bound SVA assertions |
| SystemC | `make systemc` | SystemC TB (Verilator `--sc` + `sc_main`) |
| SV/UVM | `make uvm` | UVM TB (VCS/Xcelium/Questa); skips cleanly if unlicensed |
| Waves | `make waves` / `make wave` | dump / open GTKWave |
| Lint | `make lint` | `iverilog -Wall` + Verilator RTL lint |
| Coverage | `make coverage` | Verilator `--coverage` → `sim/coverage.info` (floor `COV_MIN`, default 90%) |
| Gate | `make check` | lint + cocotb + SV(both sims) + SystemC |
| CI | `make ci` | `check` + coverage as one pass/fail gate |

Run `make help` for the full list.

## Tutorial

Every command is run from the repo root unless noted.

### 1. Toolchain

The runnable flows need Icarus Verilog, Verilator **5.x** (for `--binary` /
`--timing` / `--sc`), a Python with cocotb + pyuvm, and (for SystemC)
`libsystemc-dev`:

```bash
iverilog -V | head -1
verilator --version                 # expect 5.x
python3 -c "import cocotb, pyuvm; print(cocotb.__version__, pyuvm.__version__)"
```

If missing: `python3 -m pip install cocotb==1.9.2 pyuvm==4.0.1`. The cocotb
runner pins `ICARUS_BIN_DIR=/usr/bin` and the cocotb-bound interpreter so the VPI
is built against the same Python that imports the testbench.

### 2. Run the regression

```bash
make test        # three cocotb PASS lines, exit 0
```

Each test builds the env, pulses reset via the BFM, runs its sequence, and the
scoreboard asserts `errors == 0` in its check phase.

### 3. The other environments

```bash
make sv          # SV directed TB under Icarus       -> "[SV] Icarus PASSED"
make vlt         # SV directed TB under Verilator + SVA -> "[SV] Verilator PASSED"
make systemc     # SystemC TB                          -> "[SC] SystemC PASSED"
```

Each prints `... PASS: 65 reads checked, 0 errors`. All four runnable
environments cross-check the identical DUT.

### 4. Coverage, lint, and the CI gate

```bash
make lint        # iverilog -Wall + Verilator lint
make coverage    # Verilator --coverage -> sim/coverage.info (floor COV_MIN=90)
make ci          # lint + cocotb + SV(both) + SystemC + coverage, one gate
```

Lower the coverage bar for a quick look with `make coverage COV_MIN=80`.

### 5. Waveforms

```bash
make waves                    # dump dv/cocotb/sim_build/axi_ucie_mem_top.fst
make wave                     # + open GTKWave (skips cleanly if not installed)
make waves TEST=random_test   # just one test
```

Look at the AXI `AW`/`W` handshake, then a flit valid on the link, then the
far-side memory write and the `WriteResp` flit returning to complete `B`.

### 6. The SystemVerilog UVM testbench

```bash
make uvm                        # multi-file set, default write-read test
make uvm TEST=axi_random_test   # pick a test
make uvm SINGLE=1               # build the single-file variant instead
```

This host has no UVM license, so `make uvm` prints a skip and exits 0. On a
licensed host it auto-detects VCS / Xcelium / Questa, elaborates the DUT +
interface + UVM package + the bound `axi_lite_sva` / `aou_flit_sva` checkers, and
runs `+UVM_TESTNAME=<test>`.

**On [EDA Playground](https://www.edaplayground.com)** (free UVM-capable
simulators): paste `uvm/axi_ucie_tb_single.sv` into `testbench.sv`, and the
**concatenated** DUT RTL — `rtl/aou_pkg.sv`, `ucie_stream_link.sv`,
`axi_lite_mem.sv`, `aou_axi_initiator_bridge.sv`, `aou_axi_target_bridge.sv`,
`axi_ucie_mem_top.sv`, in that order — into `design.sv`. Tick **UVM 1.2**, pick a
simulator, and add `+UVM_TESTNAME=axi_write_read_test` (or `axi_random_test` /
`axi_walking_test`) to the run options.

## Scope & follow-ons

This pass implements the Basic Profile message formats and real flit packing over
a streaming link. Explicitly **out of scope for now** (documented in
`docs/PLAN.md`), in rough priority order:

- **Credit flow control** (spec §6) — per-message-type credit pools + `CrdtGrant`.
- **Activation state machine** (spec §8) — `Activate`/`Deactivate`/`ERROR`.
- **Multiple resource planes** (RP0..RP3) and multi-outstanding transactions.
- **Full AXI4** — INCR bursts (`AxLEN>0`), out-of-order IDs, 512b/1024b data.

## Specs

Built to the OCA drafts (kept locally in `docs/`, **not** redistributed here —
copyrighted Tenstorrent drafts; get them from
[openchipletatlas.org](https://openchipletatlas.org)):
- **AXI over UCIe Protocol Specification v0.8** — the transport/message protocol.
- **Open Chiplet Atlas System Architecture Specification v0.8** — umbrella spec.

## Toolchain

- Simulators: **Icarus Verilog** (cocotb + directed SV), **Verilator 5.x**
  (directed SV `--binary`, SystemC `--sc`, coverage)
- **SystemC 2.3.3** (`libsystemc-dev`)
- Python: **cocotb 1.9.2** + **pyuvm 4.0.1** (system `python3`)
- UVM flow: any of **VCS / Xcelium / Questa** (license-gated; not on this host)
