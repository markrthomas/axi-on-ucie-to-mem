# Repository scan — fix handoff

This document captures issues found in a repository scan on 2026-08-25.  The
default verification gate passed (`make check`), so these are either untested
edge cases or specification/integration gaps rather than current gate failures.

## 1. Long AXI bursts can deadlock

**Priority:** high

The top-level accepts the full 8-bit `AWLEN` and `ARLEN` fields, but the data
credit budgets allow only 16 beats (128 granules / 8 granules per 256-bit data
message).  The initiator does not reject or otherwise handle a longer burst.

For a 17-beat write, the initiator exhausts its WriteData credits after 16
flits; the target remains waiting for the seventeenth WriteData flit and cannot
return credits until it generates the write response.  For a 17-beat read, the
target exhausts ReadData credits after 16 response flits, while the initiator
only returns those credits on a later request flit.  Both cases can therefore
stall permanently.

**Relevant code**

- `rtl/axi_ucie_mem_top.sv`: top-level `AWLEN`/`ARLEN` are 8 bits.
- `rtl/aou_axi_initiator_bridge.sv`: `CR_WDATA = 128`; comments at lines 17--20
  describe the 16-beat bound but the AXI acceptance path does not enforce it.
- `rtl/aou_axi_target_bridge.sv`: `CR_RDATA = 128`.

**Expected resolution**

Choose and document one supported contract:

1. Enforce a maximum of 16 beats at the AXI boundary and return a deterministic
   error response for unsupported bursts, without emitting a partial AoU
   transaction; or
2. Implement safe mid-burst credit replenishment so all accepted AXI4 burst
   lengths can complete.

Do not merely tighten documentation while leaving the currently accepted
transaction capable of hanging.

**Verification needed**

- Add 17-beat read and write directed tests with a timeout.
- The test must either observe the documented error response or complete all
  beats; it must never time out.
- Retain the existing 16-beat boundary tests.

## 2. Activation ERROR recovery is unavailable in the full DUT

**Priority:** medium

The README claims that the integrated interface supports activation teardown
and `ERROR` recovery.  In the full chain, however, both bridge instances tie
the activation block's `err_clear` input to `1'b0`, and the top-level exposes
no recovery control.  An `ERROR` state in the integrated DUT is thus permanent
until reset.

**Relevant code**

- `rtl/aou_axi_initiator_bridge.sv`: activation instantiation, `err_clear(1'b0)`.
- `rtl/aou_axi_target_bridge.sv`: activation instantiation, `err_clear(1'b0)`.
- `rtl/axi_ucie_mem_top.sv`: no control port is routed to either bridge.

**Expected resolution**

Either route an explicit recovery control through `axi_ucie_mem_top` and prove
that it returns an errored link to normal activation, or revise the public
documentation to state that full-chain recovery requires reset.  Preserve the
default port/interface behavior if compatibility requires it (for example,
behind an opt-in parameter or wrapper).

**Verification needed**

- Add an integrated-DUT test that reaches `ERROR`, requests recovery, and
  completes a post-recovery AXI transaction.
- If recovery remains unsupported, test and document the reset-only behavior.

## 3. Public naming says AXI4-Lite, but the boundary is AXI4-like

**Priority:** medium

The README and module comments call the front door "AXI4-Lite", while the
actual boundary includes AXI4-only features: IDs, `AxLEN`, `AxSIZE`, `AxBURST`,
and `WLAST`.  AXI4-Lite is single-beat and does not define those signals.  This
can cause an integration team to expect an incompatible standard interface.

**Relevant code/docs**

- `README.md`: title and repeated AXI4-Lite descriptions.
- `docs/PLAN.md`: original AXI4-Lite scope contrasts with later burst support.
- `rtl/axi_ucie_mem_top.sv`: AXI4-style boundary ports.

**Expected resolution**

Rename the public interface and documentation as an AXI4 subset/profile, or
provide a separate, genuinely AXI4-Lite-compatible wrapper.  Clearly document
the supported burst length, IDs, response behavior, and any unsupported AXI4
features.

## 4. AXI protocol assertions do not cover all stalled payload fields

**Priority:** low

`dv/sva/axi_lite_sva.sv` only checks address stability for stalled AW and AR
channels.  It omits AW/AR ID, length, size, burst, and protection fields.  It
also does not require B/R response payload fields (ID, response, data, last) to
remain stable while the consumer backpressures them.  A DUT or testbench that
corrupts one of those fields during a stall would not be caught by this checker.

**Expected resolution**

Expand the checker (or replace its AXI4-Lite name and scope) so every payload
field on each valid/ready channel is stable while `VALID && !READY`.  Bind it
to the full AXI4-style port list, including ID and burst controls.

**Verification needed**

- Add assertion mutation tests: deliberately change a stalled AW/AR sideband
  field and each stalled B/R payload field, and demonstrate that the Verilator
  SVA flow fails.

## Scan baseline

- Working tree was clean before the scan.
- `make check` completed successfully: RTL lint, EDA drift check, cocotb
  functional coverage, SV, packing, activation, reorder, OOO, resource-plane,
  and SystemC environments all passed.

## Documentation/text consistency audit

The following additional findings were checked against the current RTL,
Makefile, test directories, and swarm scripts.  They are documentation or agent
instruction defects; no RTL behavior was changed by this audit.

### 5. Public architecture claims multi-message write flits, but the RTL uses one message per flit

**Priority:** high

`README.md` says each write packs `WriteReq` and `WriteData256` into one flit,
with `MsgStart` bits 0 and 3 set, and that the target walks the bitmap.  The
shipping bridge does not do that: it emits one `WriteReq` flit followed by one
`WriteData256` flit per beat, each constructed with a message at payload granule
zero.  The target likewise decodes exactly one message at granule zero.

**Evidence**

- `README.md`, the architecture diagram and the mapping table near the start.
- `rtl/aou_axi_initiator_bridge.sv`: header and builders state/use "one message
  per flit" and call `payload_put(..., 0, ...)` for each message.
- `rtl/aou_axi_target_bridge.sv`: incoming-flit view says "one message per flit,
  always at granule 0" and calls `payload_get(..., 0, ...)`.

**Required fix**

Either implement the documented multi-message packer/unpacker, or correct the
README, architecture diagram, plan, and waveform description to say that this
implementation uses one AoU message per flit.  Do not claim bitmap walking is
exercised by the end-to-end datapath unless a test proves it.

### 6. `docs/PLAN.md` describes non-existent modules and an obsolete initial architecture

**Priority:** high

The plan's current "RTL files" section lists `rtl/aou_flit_pack.sv`,
`rtl/aou_flit_unpack.sv`, and `dv/verilator/`; none exists.  It also describes a
single-beat AXI4-Lite front door and a multi-message flit datapath, both of
which disagree with the current parameterized AXI4-like bridge and its
one-message-per-flit implementation.

**Evidence**

- `docs/PLAN.md`, lines 49--50, 86--109, and 130--132.
- `rtl/` contains no `aou_flit_pack.sv` or `aou_flit_unpack.sv`; packing helpers
  are in `rtl/aou_pkg.sv` and bridge-local builders.
- The current Verilator SV TB is `dv/sv/`; coverage harness is `sim/`.

**Required fix**

Split historical planning material from a current architecture reference, or
refresh the plan throughout.  A document designated as the design/backlog
authority must not list modules and directories that are absent from the repo.

### 7. README contains mutually contradictory feature status

**Priority:** medium

Most of the README accurately documents `OOO_EN`, `NUM_RP`, wide-data packing,
and Option-2 activation quiescing as implemented.  Its later "Scope &
follow-ons" section says the opposite: Option 2, 512/1024-bit data, and genuine
OOO completion are out of scope.  `docs/PLAN.md` marks F2 and F3 done, and the
corresponding RTL/DV directories are present.

**Evidence**

- `README.md`, OOO and multi-plane descriptions near the tutorial versus
  "Scope & follow-ons" around lines 582--592.
- `rtl/aou_ooo_resp_src.sv`, `dv/ooo/`, `rtl/aou_activation.sv`, and
  `dv/act/`.

**Required fix**

Delete or rewrite the obsolete follow-on bullets.  Keep only genuinely pending
work, and qualify activation support correctly: the standalone activation block
implements Option 2, while the integrated top currently ties its trigger and
recovery controls off (issue 2 above).

### 8. Swarm/agent instructions do not cover the actual gate

**Priority:** medium

The root `check` target runs eight environments: cocotb, SV, pack, act, reorder,
OOO, MRP, and SystemC.  The operational prompts enumerate fewer environments,
so an autonomous finalization run can omit required regression legs before it
claims to have reviewed every environment.

**Evidence**

- `Makefile`: `check` depends on `test-all sv vlt pack act reorder ooo mrp
  systemc` (the eight environment grouping treats Icarus/Verilator SV as one).
- `docker/swarm-task.md` lists only cocotb, sv, pack, act, reorder, and systemc.
- `.claude/agents/swarm-manager.md` and `.claude/agents/dv-env-tester.md` omit
  `mrp`; the manager list has seven entries total.
- `.claude/agents/dv-runner.md` omits `mrp` from `make check`, calls the
  six-test cocotb suite "five" tests, and says `make regress` is only check plus
  coverage even though it also invokes formal.

**Required fix**

Make all swarm task files and agent maps derive from (or exactly match) the root
Makefile: include `ooo` and `mrp`, say six cocotb tests, and state that
`regress`/`ci` run the formal tier.  Align the environment count terminology
across `CLAUDE.md`, swarm scripts, and agent instructions.

### 9. Docker swarm parallelism documentation disagrees with the script

**Priority:** low

`docs/DOCKER.md` says automatic `SWARM_MAX_PARALLEL` is clamped to 1--6 and
describes a maximum of six parallel testers.  `docker/swarm.sh` clamps it to
1--8 and tells the manager to schedule eight environments.  This can lead users
to provision the wrong memory budget and makes the written operating procedure
internally inconsistent.

**Evidence**

- `docs/DOCKER.md`, runtime-input table and compute-guard text near lines
  292--301.
- `docker/swarm.sh`, the `SWARM_MAX_PARALLEL` calculation (maximum 8) and
  generated manager prompt.

**Required fix**

Choose the intended maximum and update both the code and prose consistently.
Also update it together with the corrected eight-environment swarm manifest.

### 10. Small but actionable path and gate-description drift

**Priority:** low

- `CLAUDE.md` instructs contributors to update `docs/NOTES.md`, but the tracked
  file is `NOTES.md` at the repository root.
- `docs/PLAN.md` says `make ci` is only lint + cocotb + coverage, while the real
  CI gate also runs EDA drift checking, SV, packing, activation, reorder, OOO,
  MRP, SystemC, and formal.
- One README `make ci` comment omits the MRP environment even though the earlier
  command table correctly includes it.

**Required fix**

Correct the path in `CLAUDE.md`, and use the root Makefile's `check`/`regress`
dependency lists as the single source for all gate descriptions.

### 11. Container/CI parity and agent metrics defaults are overstated

**Priority:** low

`docs/DOCKER.md` says the Docker image and GitHub Actions install the same tools
the same way.  They do not: the Dockerfile uses Ubuntu 24.04's `python3` (3.12),
whereas CI explicitly installs Python 3.10 with `actions/setup-python`.  The
document also says the default `AOU_METRICS_JSON` path is
`docker/last-run-metrics.json` for both agent and swarm modes, but `agent.sh`
defaults to `last-run-metrics.json`; only `swarm.sh` defaults underneath
`docker/`.

**Evidence**

- `Dockerfile`: apt installs `python3`/`python3-dev` on Ubuntu 24.04.
- `.github/workflows/ci.yml`: `actions/setup-python` requests `3.10`.
- `docker/agent.sh`: `metrics_json="${AOU_METRICS_JSON:-last-run-metrics.json}"`.
- `docker/swarm.sh`: default is `$ROOT/docker/last-run-metrics.json`.

**Required fix**

Either make Python versions and installation paths genuinely identical or state
the deliberate version difference and test/support policy.  Correct the metrics
default in the Railway/runtime-variable documentation, or standardize the two
scripts on one default path.
