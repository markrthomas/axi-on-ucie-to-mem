# Random regression (`dv/random`)

Opt-in, seeded, constrained-random regression of `axi_ucie_mem_top`. **Not** part of
`make check` / `regress` / `ci`. Verilator (`--binary --timing --assert`, so the bound
AXI4/flit/credit SVA fire too). Built once, then N jobs reuse the same binary with
different plusargs.

## Checker

`tb_rr.sv` uses the same scoreboard as `dv/sv/tb_axi_ucie_mem.sv`: a reference word
memory, every read beat checked for data / RRESP / RID / RLAST, every write for
BRESP / BID, plus the bound SVA. Only what that scoreboard checks is randomized:
addresses (inside a window), burst type (INCR/WRAP/FIXED) and length, data, idle gaps
(between transactions and W beats) and RREADY back-pressure. PRNG is an in-TB
xorshift32 seeded once from `+seed=N`, so a seed is bit-identical across runs.

## Contract

| command | what |
|---|---|
| `make rr-build` | build `dv/random/obj_dir/vrr` once (`VL_JOBS=2` default, see below) |
| `make rr N=<n> JOBS=<j> [SEED=<base>]` | n jobs, seeds `SEED+i`, config = `i mod 6`; writes `dv/random/runs/<UTC>/results.jsonl`; prints `rr run: <dir> seed_base=<s> jobs=<n> fail=<f>`; non-zero iff f > 0 |
| `make rr-triage RUN=<dir>` | cluster FAILs by signature: count, configs, repro |
| `make rr-replay` | rerun `corpus.json`; entries with `"fixed": true` must PASS (the gate; ~1 s) |
| `python3 dv/random/rr.py one --seed S --config C` | single-job repro, prints the log |

`results.jsonl` line: `{"job","seed","config","status":"PASS|FAIL","signature","log","repro"}`.
Signature = first `[RR-TB] ERR <kind>` (`data-mismatch`, `rid-mismatch`, `rlast-mismatch`,
`bad-rresp`, `bad-bresp`, `bid-mismatch`, `timeout`), else the first Verilator
assertion/`%Error` line with numbers normalised, else `exit-<rc>`.
`runs/` and `obj_dir/` are git-ignored.

## Knobs (configs, in `rr.py` `CONFIGS`)

Plusargs: `+xfers +maxlen(0..15) +gap +bp(RREADY stall %) +win(words) +burst(bit0 INCR, bit1 WRAP, bit2 FIXED)`.
Configs: `default`, `tight` (no gaps/stalls), `bp_heavy` (75% stall), `hot` (64-word
window, heavy aliasing), `single` (single beats), `wrap_fix`. Env `RR_JOB_TIMEOUT` (s, default 300).

## Memory note

`dv/random/Makefile` builds with `VL_JOBS=2` (Verilator `-j`), matching the image
default: cloud builders see many cores but little RAM and parallel `cc1plus` OOMs. If a
build is OOM-killed, re-run `make rr-build VL_JOBS=1`. Raise it on a big dev box.

## Teeth (checked at bootstrap)

Mutation `rdata_q <= m_rdata ^ 1` in `rtl/aou_axi_target_bridge.sv`: `make rr N=20` ->
`fail=20`, one cluster `data-mismatch`. Restored: `fail=0`.

## Stimulus backlog

- B1 random WSTRB (needs a byte-strobe reference model; `axi_lite_mem` strobe support to confirm)
- B2 multiple outstanding reads with RREADY held low (queue-full, credit-ceiling pressure)
- B3 random BREADY back-pressure and early/late W relative to AW
- B4 over-long bursts (SLVERR contract, SCAN_ISSUES #1) mixed in
- B5 ERROR-recovery / reset mid-traffic (reference memory reset semantics)
- B6 `OOO_EN=1` and `NUM_RP=2` builds with different-ID overtake (reuse `dv/ooo`, `dv/mrp` checkers)
- B7 mixed read/write ID collisions, wider AXI_DATA_W
