# Design notes

Longer-form "why it is built this way" notes that do not belong in `README.md`
(usage), `docs/PLAN.md` (design + backlog) or `docs/DOCKER.md` (container/CI).

---

## Metrics DB (`metrics/`) — schema, provenance, and the rules it enforces

`make metrics` inserts one row per run into the committed SQLite database
`metrics/metrics.db`; `make dashboard` renders it into the single self-contained
page `metrics/dashboard.html`. Both are **opt-in and outside the gate** — see
"Why it is not on the gate path" below.

### The overriding rule

> **Measurement must never change the thing it measures.**

`make check` / `regress` / `ci` do not depend on any metrics target, never write
the database and never run synthesis. Collection is a separate step that runs
**after** a completed gate. Everything the collector needs is either an artifact
the gate already left behind, or a pass the collector runs itself (yosys,
Verilator lint) that no DV environment is timed through.

Where a number could *only* be obtained by perturbing a timed run, it is
**dropped and the reason recorded** rather than taken. There is exactly one such
case today, and the DB says so in as many words:

| metric | why it is `not_attributable` |
|--------|------------------------------|
| per-env `sim_cycles`, and the `throughput_cycles_per_s` derived from it | no DV env prints a cycle count. Adding one changes every env's stdout — and `dv/systemc/sc.log` is a **committed golden log** the SystemC env diffs, so the only way to measure it is to break the thing being measured. |

### Schema (`metrics/schema.sql`)

```
run                      one row per collected run
 ├─ id, run_key (UNIQUE) run_key is the idempotency key
 ├─ git_sha / git_branch / git_dirty
 ├─ ts_utc, trigger (local|ci|railway|swarm), runner, runner_vcpu, runner_ram_mb
 └─ collector_ver, notes

design_metric  (run_id, scope, name, value, unit, kind, source)   scope = module
verif_metric   (run_id, scope, name, value, unit, kind, source)   scope = env / proof:task
compute_metric (run_id, scope, name, value, unit, kind, source)   scope = gate step / env
ai_metric      (run_id, agent, model, name, value, unit, kind, source)

v_metric       a UNION view over all four, for the trend queries
```

Three schema decisions are load-bearing:

1. **`kind` is a CHECK constraint**, not a convention:
   `kind IN ('measured','estimated','not_attributable')`.
   - `measured` — read out of a real artifact (a log, `sim/coverage.info`, an
     `sby` `status` file, `/usr/bin/time -v`, a yosys `stat`, the Claude Code
     result JSON).
   - `estimated` — **modeled**: a measured input multiplied by a documented
     coefficient from `metrics/coefficients.json`. Energy, cost, Fmax and the
     generic-cell gate counts are all of this kind. There is no metered energy
     source on any of these hosts, and no liberty file, so pretending otherwise
     would be the whole failure mode this schema exists to prevent.
   - `not_attributable` — the number was **asked for** and the tooling cannot
     supply it. `value` is `NULL` and `source` holds the reason. A fabricated
     "measured" energy figure is therefore a *schema error*, not a judgement
     call.
2. **History is append-only**, so the dashboard can trend. `run_key` (default
   `<sha12>/<trigger>/<ci-run-id | gate-log mtime | "dev">`) makes re-collection
   **idempotent**: collecting the same key again refreshes the run row and
   replaces its child rows instead of appending a duplicate run.
3. **`ai_metric` carries `agent` and `model` axes** because the plan needs a
   per-(agent × model) breakdown, and the other three domains do not.

### Per-agent AI numbers — what is attributable, and what is not

Claude Code headless reports `modelUsage` **per MODEL**, and it **aggregates
subagents**. There is no per-agent token field, and no per-model wall-time split
at all. So:

- **Per-model rows** (`agent = '*aggregate*'`) come straight from the result
  JSON and are honest about being whole-swarm totals — the `source` string says
  "AGGREGATES subagents -- not one agent".
- **Per-agent rows** are reconstructed from the **event stream**:
  `docker/render-metrics.py --stream-out` tees the raw `stream-json` to
  `metrics/_capture/swarm-stream.jsonl`, injecting one extra key (`_ts_epoch`)
  per event. `metrics/collect.py` then attributes every event carrying
  `parent_tool_use_id` to the `Task` tool-use that spawned it, giving each agent
  a wall span, turn count, tool-call count and tool-error rate — and tokens
  **where the sidechain assistant events expose a `usage` block**.
- **Where they do not**, the row is written `not_attributable` with the reason.
  Same for `per_model_wall_time`, and for `pr_human_fix_needed` (only a human
  reviewer knows that). Never a guessed number.
- If the stream capture is missing entirely, a single explicit
  `*per-agent* / attribution` gap row records why, and points at
  `docker/swarm.sh`.

`parallelism_peak` counts overlapping **subagent** spans; the manager's span
covers the whole run by construction and is excluded.

### Coefficient provenance (`metrics/coefficients.json`)

Every modeled number's coefficient lives in that file with its own `_note`,
`verified_on` and provenance. Summary of *why each exists*:

| block | models | provenance / caveat |
|-------|--------|---------------------|
| `inference_energy_wh_per_1k_tokens` | LLM inference energy, by model class | No vendor publishes per-token energy. Derived from published per-query estimates (Google's 2025 inference-impact paper, ~0.24 Wh/prompt; Epoch AI's ~0.3 Wh/query; Luccioni et al., FAccT 2024 for the task spread) divided by an assumed response length and scaled by class. Output tokens cost ~10× input because they are generated one forward pass at a time; a cache **read** skips prefill compute almost entirely. **Order of magnitude, for trending only.** |
| `cpu_energy` | sim/synth CPU energy | `core_seconds` (measured) × an amortized W/core × PUE. Not a measured TDP and not RAPL. |
| `ci_compute_cost_usd_per_core_hour` | CI compute cost | GitHub-hosted Linux 2-core billing for private repos; free (so an *opportunity* cost) on public ones. Per-runner overrides for railway/self-hosted/local. |
| `api_price_usd_per_mtok` | token cost fallback | The collector **prefers** the `costUSD` Claude Code itself reports. This prefix-matched table is only the fallback, and is a committed snapshot of list prices — verify before quoting. Non-Anthropic providers (Kimi/Moonshot) are deliberately absent, so their cost is recorded `not_attributable` rather than guessed. |
| `gate_equivalents` | generic cells → GE | Textbook 2-input-NAND transistor ratios, not a foundry library. `$mem` macros get weight 0 (a 512 Kbit array is not random logic) and are reported separately as `memory_bits`. Cells with no weight are counted in `cells_unweighted` so a mismatch is visible. |
| `fmax_estimate` | Fmax | `ltp` combinational depth in **cell levels** × an assumed ns/level + fixed overhead. No liberty timing, no placement. Useful only to answer "did this change deepen the critical path?" |
| `regression` | dashboard flags | Which direction is *good* per metric name, plus a percentage dead-band below which a change is noise. |

### Design metrics — two yosys passes, on purpose

- **Whole-design numbers come from a FLATTENED run.** `read_slang` elaborates the
  hierarchy away, so yosys optimizes across module boundaries exactly as a real
  flow would. This is the number to trend.
- **Per-module numbers come from a second `--best-effort-hierarchy` run**, so each
  block is counted **as instantiated**, with its real parameter overrides.
  Synthesizing a module standalone would use its *default* parameters —
  `aou_flit_fifo` defaults to a far larger FIFO than the top ever instantiates,
  which produced a 64 k-cell block on the first attempt — and give a badly
  misleading number.
- Because module boundaries block cross-boundary optimization, the per-module
  totals **sum to more** than the flattened whole-design count. That is expected;
  every per-module `source` string says so.
- The 16384-word memory is kept as a `$mem_v2` macro (`memory -nomap`) so it does
  not explode into half a million cells and swamp the bridge logic. Its storage
  is captured separately, from a `stat` taken *before* the `memory` pass (the only
  point where `num_memory_bits` is still populated).
- `read_slang` needs `--unroll-limit=40000`: the memory's zeroing `for` loop
  unrolls `WORDS` (16384) times, well past slang's 4000 default.

### Capturing a run without perturbing it

`metrics/capture.sh <label> <cmd…>` observes from the **outside** only:

- `/usr/bin/time -v` → exact wall clock, user+sys core-seconds, peak RSS, %CPU.
- a **timestamped tee** (`metrics/stamp.py`, a pure byte-oriented stdin→stdout
  filter) → `[+SSSS.mmm]`-prefixed gate log, from which per-step wall time and the
  build-vs-run split are derived.

Deliberately **no `stdbuf` and no `LD_PRELOAD`**: the system `libstdbuf.so` is
built against this image's glibc 2.38 and the pinned oss-cad-suite tools run
against their own older bundled glibc, so preloading it kills `make lint`
outright (see `CLAUDE.md`). `stamp.py` is byte-oriented rather than text-mode so
a stray non-UTF-8 byte from a simulator cannot abort the capture — and with it,
through `pipefail`, the gate.

The one honest caveat, recorded in the DB with every number derived from it: the
C tools **block-buffer** when stdout is a pipe, so a banner's timestamp is when
it was *flushed*, not when it was printed. Totals from `/usr/bin/time` are
`measured`; the per-step split is `estimated`.

### The dashboard is self-contained, and proves it

`metrics/dashboard.py` inlines the CSS, the JavaScript and the data, and draws
its trend charts as hand-rolled inline SVG — there is no charting library to
vendor and nothing to fetch. Before writing the file it runs
`check_self_contained()` over the rendered page and **refuses to emit** anything
containing a `src=`/`<link href=>` asset reference, a CSS `@import`, a
`url(http…)` or a JavaScript network call. That guard is mutation-tested: all
five injected forms are caught. The page therefore renders from a `file://` URL
with the network off and can be published verbatim as a CI Artifact.

### Why it is not on the gate path

`make metrics` runs a full yosys elaboration twice and a Verilator lint; `make
dashboard` rewrites a committed file. Folding either into `check`/`regress`/`ci`
would (a) add minutes to the gate, (b) make the gate write to the repository, and
(c) contaminate the very timings being recorded. So the gate stays exactly as it
was, and the collection step runs after it — in CI as a `continue-on-error`
post-gate step, in the container behind `AOU_POST_METRICS=1`, and locally as
`make metrics-capture && make metrics`.
