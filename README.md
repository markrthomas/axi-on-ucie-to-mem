# axi-on-ucie-to-mem

**AXI-over-UCIe (AoU) → AXI memory**, verified in five DV environments
(cocotb + PyUVM, Icarus, Verilator, SystemC, and a license-gated SystemVerilog
UVM mirror). Sibling project to `uvm_review`; digital-only, open-source toolchain.

> 🚧 **Under construction.** This repo is being built out in phases — see
> [`docs/PLAN.md`](docs/PLAN.md) for the full architecture and roadmap.

## What it is

A design that transports **AXI4-Lite** transactions across a modeled **UCIe
streaming link** using the **AXI-over-UCIe (AoU) Basic Profile** message set
(WriteReq / ReadReq / WriteData256 / ReadData256 / WriteResp), packed into real
250 B PLP flits (10 B protocol header with the `MsgStart[47:0]` granule bitmap +
48 × 5 B granules of payload), and delivers them to a far-side **AXI4-Lite SRAM
memory**. AXI is the OCA non-coherent bus protocol carried over UCIe (OCA §5.2),
so the memory target speaks AXI natively rather than APB.

```
AXI-Lite master → [initiator bridge: pack] ══flit══▶ [target bridge: unpack] → AXI-Lite memory
                  [           ◀══════════ return flit (ReadData/WriteResp) ══════════          ]
```

## Status

| Piece | State |
|-------|-------|
| `rtl/aou_pkg.sv` — AoU Basic-Profile message formats + pack/unpack helpers | ✅ |
| `rtl/axi_lite_mem.sv` — AXI4-Lite SRAM memory target | ✅ |
| AoU packer / unpacker / bridges / UCIe link / top | ⏳ |
| cocotb + PyUVM env | ⏳ |
| Icarus / Verilator SV TB + SVA + coverage | ⏳ |
| SystemC env | ⏳ |
| SystemVerilog UVM mirror (license-gated) | ⏳ |

## Specs

Built to the OCA drafts (kept locally in `docs/`, not redistributed here — get
them from [openchipletatlas.org](https://openchipletatlas.org)):
- **AXI over UCIe Protocol Specification v0.8** — the transport/message protocol.
- **Open Chiplet Atlas System Architecture Specification v0.8** — umbrella spec.

## Scope (this pass)

Basic Profile, Resource Plane RP0, AXI4-Lite single-beat, 256 b data messages.
Credit flow control (§6), the activation state machine (§8), resource planes,
and AXI4 bursts are documented follow-ons — see `docs/PLAN.md`.
