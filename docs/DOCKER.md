# Containerized DV gate — Docker & Railway

A single container image, **`aou-dv`**, packages the whole open-source DV
toolchain and runs the same pass/fail gate as CI. Use it to reproduce the gate
on any machine without installing Icarus / Verilator / SystemC / cocotb locally,
and to run the gate as a job on [Railway](https://railway.com).

The image is defined by four files at the repo root:

| File | Role |
|------|------|
| `Dockerfile` | Builds the toolchain image; mirrors `.github/workflows/ci.yml`. |
| `docker/entrypoint.sh` | Injects the pinned-Verilator make args, then runs the gate. |
| `.dockerignore` | Keeps the build context small (no local tools / sim artifacts / `.git`). |
| `railway.toml` | Tells Railway to build the Dockerfile and run it as a batch job. |

---

## Quick start

```bash
# build the image (downloads ~677 MB oss-cad-suite once; cached thereafter)
docker build -t aou-dv .

# run the full CI gate (lint + cocotb + SV + pack + act + reorder + SystemC + coverage)
docker run --rm aou-dv

# run just one environment
docker run --rm aou-dv make reorder
docker run --rm aou-dv make check      # the gate without coverage

# open an interactive shell in the toolchain (tmux is available for long-running
# / multi-pane sessions inside the container)
docker run --rm -it --entrypoint bash aou-dv
```

A green run ends with:

```
[REGRESS] lint + cocotb + SV(Icarus+Verilator) + pack + act + reorder + SystemC + coverage PASSED
```

and exit status `0`. Any failing environment stops the gate and returns non-zero.

> The examples say `docker`; this repo is also tested under **podman** via its
> `docker` CLI shim — the commands are identical.

---

## What's in the image

Ubuntu 24.04 base, chosen because it ships the exact tool versions CI validates:

| Component | Source | Version | Why this source |
|-----------|--------|---------|-----------------|
| Icarus Verilog | apt | 12.0 | The cocotb VPI is built against the apt `iverilog`/`vvp`. |
| SystemC | apt (`libsystemc-dev`) | 2.3.3 | Headers + `libsystemc.so` for the SystemC TB. |
| **Verilator** | **oss-cad-suite, pinned tag `2026-04-13`** | **5.047** | The apt Verilator attributes line coverage ~9 pts stricter (would fail the 85% floor) and a newer oss-cad-suite adds lints this design predates — so the tag is **exact**, not `latest`. |
| Python | apt (`python3` + **`python3-dev`**) | 3.12 | `python3-dev` provides `libpython3.12.so`, which cocotb's `find_libpython` needs to embed the interpreter in the VPI (see gotcha below). |
| cocotb / pyuvm | pip, in a venv | 1.9.2 / 4.0.1 | Pinned to the CI versions; a venv satisfies PEP 668 on 24.04. |
| tmux | apt | 3.4 | Terminal multiplexer for interactive / long-running sessions inside the container. |
| Node.js | NodeSource | 20 LTS | Runtime for the Claude Code CLI (Claude Code needs Node ≥ 18). |
| Claude Code CLI | npm (`@anthropic-ai/claude-code`) | latest | Headless agent mode (see below); does not affect the DV gate. |

The build ends with a healthcheck that fails the image build if any of
`iverilog`, the pinned `verilator`, or `import cocotb, pyuvm` is missing.

The UVM flow (`make uvm`) and formal (`make formal`) are **not** in the image:
they need a licensed simulator / SymbiYosys and would only skip.

---

## How it runs the gate — the entrypoint

The default command is `make ci`, but it is **not** run directly. The image sets
`ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`, which wraps every `make`
invocation with three variables:

```
VERILATOR=$OSS/bin/verilator
VERILATOR_ROOT=$OSS/share/verilator
VERILATOR_COV=$OSS/bin/verilator_coverage
```

**Why a wrapper instead of environment variables?** The root `Makefile` computes

```make
VERILATOR_ROOT := $(shell v=$$(command -v verilator …); … )
```

with `:=` (immediate assignment via a shell call). A `:=` variable is **not**
overridden by an environment variable — only by a make **command-line** argument.
The pinned oss-cad-suite Verilator is deliberately kept off `PATH` (so its
bundled `iverilog` can't shadow the apt one the cocotb VPI links against), so
`command -v verilator` would otherwise find nothing. The entrypoint therefore
appends the triplet as make args. CI does the exact same thing.

Entrypoint dispatch:

| You run | It executes |
|---------|-------------|
| `docker run --rm aou-dv` | `make ci  <verilator args>` |
| `docker run --rm aou-dv make reorder` | `make reorder  <verilator args>` |
| `docker run --rm aou-dv <anything else>` | `<anything else>` verbatim (e.g. `bash`) |

---

## Build memory & the `VL_JOBS` knob

Verilator compiles the generated C++ model with `--build -j 0`, meaning **one
`cc1plus` (g++) per detected core**. Cloud builders commonly advertise many
vCPUs but cap RAM — Railway's builder reports **48 vCPUs**. Uncapped, the 48
parallel precompiled-header compiles exhaust memory and the kernel kills the
compiler:

```
make -C obj_dir -f Vaxi_ucie_mem_top.mk -j 48
g++: fatal error: Killed signal terminated program cc1plus
```

The job count is the make variable **`VL_JOBS`** across every Verilator DV
Makefile (`dv/sv`, `dv/pack`, `dv/act`, `dv/reorder`, `dv/systemc`):

- **`VL_JOBS ?= 0`** is the default — one job per core, fast on dev machines and
  CI (unchanged behavior).
- The **Docker image sets `ENV VL_JOBS=2`**, bounding peak compile memory so the
  gate fits a memory-constrained instance.

Tune it for your instance:

```bash
docker run --rm -e VL_JOBS=1 aou-dv     # smallest instances (serialize compiles)
docker run --rm -e VL_JOBS=0 aou-dv     # plenty of RAM: use all cores (fastest)
make systemc VL_JOBS=4                   # locally, cap to 4 jobs
```

Rule of thumb: keep `VL_JOBS × ~0.5 GB` under the instance's RAM. `VL_JOBS=2`
runs the full gate green under a **2 GB** cap.

---

## Headless Claude Code agent mode

The same image can run **[Claude Code](https://code.claude.com/docs/en/headless)
headless** as a cloud agent, layered alongside the DV toolchain (Node.js 20 +
the `@anthropic-ai/claude-code` CLI are installed; the DV gate is untouched).

```bash
# task as an argument
docker run --rm -e ANTHROPIC_API_KEY=sk-ant-… aou-dv agent "summarize rtl/aou_pkg.sv"

# task from the environment
docker run --rm -e ANTHROPIC_API_KEY=sk-ant-… -e CLAUDE_TASK="run make reorder and explain a failure" aou-dv agent

# task / webhook payload piped on stdin
printf '%s' "$WEBHOOK_BODY" | docker run --rm -i -e ANTHROPIC_API_KEY=sk-ant-… aou-dv agent
```

`agent` is a keyword the entrypoint recognizes (see `docker/agent.sh`); it runs
`claude -p "<task>" --bare` and exits with Claude Code's status. Anything else is
still the DV gate (`docker run … aou-dv` → `make ci`, `… aou-dv make reorder`, …).

**How non-interactive mode actually works.** It is the CLI's **`-p` / `--print`
flag**, plus **`--bare`** (skips host hooks/plugins/`CLAUDE.md` for a reproducible
run) — **not** an environment variable. There is **no `CLAUDE_CODE_NON_INTERACTIVE`
variable**, and `CI=true` is not Claude Code's setup/telemetry switch. The image
instead sets the real umbrella **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`**
(turns off telemetry, error reporting, and update checks).

**Authentication (required).** Claude Code needs **`ANTHROPIC_API_KEY`** (a
[Console](https://platform.claude.com) key) — under `-p` the key is always used
when present. **Inject it at run time** (`docker run -e …`, or a Railway service
variable); **never bake a key into the image or commit it.** Amazon Bedrock /
Google Vertex / Microsoft Foundry are supported via their own provider credentials.

**Permission posture.** `docker/agent.sh` defaults to `--permission-mode dontAsk`
(a locked-down CI posture: only read-only commands and explicit `allow` rules
run). For a worker that must edit files or run commands, open it up per run:

```bash
docker run --rm -e ANTHROPIC_API_KEY=… -e CLAUDE_PERMISSION_MODE=acceptEdits aou-dv \
  agent "apply the lint fixes" --allowedTools "Bash,Read,Edit"
```

Trailing arguments after the task pass straight through to `claude`, and
`CLAUDE_OUTPUT_FORMAT` (`text` default, or `json` / `stream-json`) selects the
output shape for programmatic callers.

The agent can also run on **Kimi K3** (`AOU_MODEL_PROVIDER=kimi` + `KIMI_API_KEY`)
and prints a per-model token/time **metrics block** at the end of the run — see
[Model selection, providers & run metrics](#model-selection-providers--run-metrics).

> A headless agent with `acceptEdits`/broad `--allowedTools` can run shell
> commands and edit files in the container unattended — scope the tools and the
> container's mounts/network to what the task actually needs.

## DV finalization swarm

A step beyond single-agent mode: `agent` runs one Claude Code session, **`swarm`**
runs a small **manager-led team** that finalizes the DV work and opens a PR. It
is defined by three agents in `.claude/agents/` (baked into the image) plus
`docker/swarm.sh` and the default task in `docker/swarm-task.md`.

```
swarm-manager (opus → claude-opus-5)        # the manager — the top-level session
 ├─ dv-env-tester (haiku → claude-haiku-4-5)  × cocotb, sv, pack, act, reorder, systemc  (parallel)
 └─ infra-agent   (sonnet → claude-sonnet-5)  # Dockerfile / entrypoint / railway.toml / CI
```

> The `opus` / `sonnet` labels are model **tiers**, not fixed models. The active
> provider maps them to concrete models — Claude by default, or **Kimi K3** — and
> the runner prints per-model token/time metrics at the end. See
> [Model selection, providers & run metrics](#model-selection-providers--run-metrics).

The manager dispatches one **`dv-env-tester`** per DV environment (each runs that
env and reports pass/fail + a file:line finding — read-only) and the
**`infra-agent`** (verifies/fixes the container & CI plumbing), applies the
minimal fixes for anything red, runs the whole `make regress` gate, and — only
when green — commits to a branch and opens a PR. **A human merges.**

```bash
# default finalization task (docker/swarm-task.md); needs both keys
docker run --rm \
  -e ANTHROPIC_API_KEY=sk-ant-… \
  -e GITHUB_TOKEN=ghp_… \
  aou-dv swarm

# or give it a specific task
docker run --rm -e ANTHROPIC_API_KEY=… -e GITHUB_TOKEN=… aou-dv \
  swarm "get every DV env green and open a PR titled 'DV finalize'"
```

Runtime inputs:

| Variable | Needed for | Notes |
|----------|-----------|-------|
| `ANTHROPIC_API_KEY` | everything | Console key; injected at run time, never baked. |
| `GITHUB_TOKEN` | push + PR | repo/PR scope; without it the swarm edits & tests but stops before pushing (leaves a committed branch). |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | commit identity | sensible defaults if unset. |
| `SWARM_MAX_PARALLEL` | throttle | max dv-env-testers run at once. **Auto-sized to available RAM** (`MemAvailable / 2 GB`, clamped 1–6) since each env's Verilator build can need ~2 GB; set it to override. |
| `SWARM_PERMISSION_MODE` | tuning | default `acceptEdits`. |
| `SWARM_ALLOWED_TOOLS` | tuning | default `Bash,Read,Edit,Write,Grep,Glob,Task,Agent`. |

**Compute guard.** Running all six DV environments at once means up to six
concurrent Verilator/g++ compiles — on a small host that OOM-kills `cc1plus`
(the same failure the `VL_JOBS` cap fixes for a single build). `swarm.sh`
therefore reads `MemAvailable` and dispatches testers in **batches** of
`SWARM_MAX_PARALLEL` (≈ 2 on a 5–6 GB box, up to 6 where RAM is ample); the
manager also retries any OOM-killed env with `VL_JOBS=1`. Sequential
`make regress` is unaffected — this only bounds the swarm's parallel fan-out.

Unlike `agent` mode, the swarm runs Claude Code **non-`--bare`** so the project's
`.claude/agents/` are discovered and dispatchable. The manager never commits on
`main` and never merges — it branches, pushes, and opens a PR for human review.

**Run it from GitHub Actions.** The **`DV swarm`** workflow
(`.github/workflows/swarm.yml`) is a manual **Run workflow** button
(`workflow_dispatch`) — pick an optional task, parallelism, and the **provider**
(`anthropic` or `kimi`), and it sets up the same toolchain as CI plus Node/Claude
and runs `docker/swarm.sh` on the runner. It reads `secrets.ANTHROPIC_API_KEY`
(for `anthropic`), `secrets.KIMI_API_KEY` (for `kimi`), and
`secrets.SWARM_GITHUB_TOKEN` (optional; falls back to the built-in `GITHUB_TOKEN`,
whose PRs don't re-trigger CI), and the job declares `contents: write` +
`pull-requests: write`. It uploads `last-run-metrics.json` as an artifact and
prints the per-model metrics table to the run's job summary. The button appears
only once the workflow is on the default branch. `swarm.sh` runs from the
runner's checkout; in the container image (no `.git`) it clones the repo at run
time from `GITHUB_TOKEN` + the repo slug so the manager can still push a PR.

> This is autonomous, multi-agent, and API-metered: it edits files, runs shell
> commands, and pushes a branch on its own. Run it in a disposable container /
> runner with a **scoped** token, and review the PR before merging.

## Model selection, providers & run metrics

Every agent picks a model **tier** by alias (`opus` / `sonnet`), and a single
knob — **`AOU_MODEL_PROVIDER`** — decides which vendor's models those aliases
resolve to for the whole run. Both `agent` and `swarm` honor it.

### Right model for the job

| Agent | Job | Tier | Claude (default) | Kimi (`AOU_MODEL_PROVIDER=kimi`) |
|-------|-----|------|------------------|----------------------------------|
| `swarm-manager` | orchestrate, triage, fix, land the PR | `opus` | `claude-opus-5` | `kimi-k3` |
| `dv-runner` | run all DV envs + code review | `opus` | `claude-opus-5` | `kimi-k3` |
| `infra-agent` | edit Dockerfile / CI / scripts | `sonnet` | `claude-sonnet-5` | `kimi-k2.7-code` |
| `dv-env-tester` | run ONE env read-only + report | `haiku` | `claude-haiku-4-5` | `kimi-k2.7-code-highspeed` |

Rationale for the Anthropic set:
- **Manager + `dv-runner` → Claude Opus 5** — the deep agentic reasoning: triage,
  minimal RTL/TB fixes, running the gate, branching and opening the PR. This is
  where model quality most affects the outcome.
- **`infra-agent` → Claude Sonnet 5** — strong, inexpensive coding for the
  well-scoped Dockerfile / CI / script edits; it doesn't need Opus.
- **`dv-env-testers` → Claude Haiku 4.5** — they fan out in parallel (up to six)
  and mostly *run one env and report its banner*, so the fast/cheap tier keeps
  latency and cost down. The manager re-runs the whole `make regress` gate itself
  on Opus 5, so a tester's judgement is never the last word (escalate a tester to
  Sonnet 5 with `ANTHROPIC_HAIKU_MODEL=claude-sonnet-5` if you want richer failure
  reviews; note Haiku's 200K context vs. 1M on Opus/Sonnet 5).

The exact models are **pinned** in `docker/provider-env.sh` (via the
`ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` alias map) so the selection is
deterministic instead of drifting with the account default — override any with
`ANTHROPIC_{OPUS,SONNET,HAIKU}_MODEL` (e.g. `claude-fable-5` for the manager tier
if you want maximum capability regardless of cost). Because the agents reference
**aliases**, switching provider needs **no edit to any agent** — only the map
changes.

### Providers

- **`anthropic`** (default) — today's behavior. Needs **`ANTHROPIC_API_KEY`**.
- **`kimi`** — routes Claude Code at Moonshot's Anthropic-compatible endpoint
  (`https://api.moonshot.ai/anthropic`). Needs **`KIMI_API_KEY`** (a Moonshot
  key). The runner exports `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` and the
  alias remaps `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` for you (and unsets
  `ANTHROPIC_API_KEY` so it can't shadow the Moonshot endpoint).
  [Kimi K3](https://platform.kimi.ai/docs/guide/claude-code-kimi) is Moonshot's
  1M-context coding model; it speaks the Anthropic Messages API, so no code
  change is needed.

```bash
# run the swarm on Kimi K3 instead of Claude
docker run --rm \
  -e AOU_MODEL_PROVIDER=kimi -e KIMI_API_KEY=sk-… \
  -e GITHUB_TOKEN=ghp_… -e SWARM_REPO=owner/repo \
  aou-dv swarm
```

Override any Kimi model with `KIMI_OPUS_MODEL` / `KIMI_SONNET_MODEL` /
`KIMI_HAIKU_MODEL` (defaults `kimi-k3` / `kimi-k2.7-code` /
`kimi-k2.7-code-highspeed`).

#### Compliance & IP risk

> **⚠️ `kimi` mode is opt-in and OFF by default** (`AOU_MODEL_PROVIDER=anthropic`).
> Read this before enabling it — the runner also prints this caution at run time.
>
> Enabling `kimi` **sends your repo contents — RTL/DV, diffs, and prompts — to
> Moonshot, a China-based provider.** As of **Aug 2026** Moonshot is **under
> active US BIS investigation**, with an **Entity-List designation openly
> threatened** and **IP-theft allegations** (including against Anthropic).
> Independently, a third-party model host may **retain or train on** whatever you
> send it.
>
> Before enabling `kimi`:
> - **Don't route proprietary or export-sensitive IP through it.** A generic
>   AXI↔UCIe↔memory bridge on open, published standards is most likely
>   EAR99/publishable — but an Entity-List listing can make even EAR99 transfers
>   license-required, so first verify Moonshot (and affiliates) are **not** on the
>   [BIS Entity List](https://www.bis.doc.gov/index.php/policy-guidance/lists-of-parties-of-concern/entity-list)
>   or the Treasury SDN list.
> - **Confirm your design's classification** and clear it with **export/trade
>   counsel.** Nothing here is legal advice or an export determination.
> - Prefer `kimi` only for **non-sensitive / already-public** code — or wait until
>   Moonshot's status resolves.

**Why run on Kimi?** cost, provider independence, or cross-checking that the DV
gate passes under a *second*, independent model — not just Claude. Weigh that
against the risks above.

### Getting a Kimi API key (no host to stand up)

Kimi K3's open weights are huge (2.8T params) — you do **not** self-host. Claude
Code only needs Moonshot's **Anthropic-compatible** hosted API, so all you get is
an API key:

1. **Sign up** at [platform.moonshot.ai](https://platform.moonshot.ai) — the
   **international** endpoint (`api.moonshot.ai`; there is a separate `.cn` —
   don't use it). The [Kimi Open Platform console](https://platform.kimi.ai/console/api-keys)
   is the same account.
2. **Add ≥ $1 balance to activate** (pay-as-you-go; no free tier). Kimi K3 is
   **$3 / MTok input, $15 / MTok output, $0.30 / MTok cache-hit** — prepaying
   **$10–20** covers many runs; the metrics block tells you actual token spend.
3. **Console → API keys → create key** (`sk-…`). That single key is
   **`KIMI_API_KEY`** — nothing else to configure. `provider-env.sh` sets the
   base URL and the `opus`/`sonnet`/`haiku` → Kimi-model map for you, so **don't**
   set `ANTHROPIC_MODEL` / `ANTHROPIC_BASE_URL` yourself.

**Smoke-test the key** before a full swarm (a few tokens ≈ fractions of a cent):

```bash
docker run --rm -e AOU_MODEL_PROVIDER=kimi -e KIMI_API_KEY=sk-… \
  aou-dv agent "reply with one short line naming the model you are"
```

It should authenticate, answer, and print a metrics block showing `kimi-k3`.

> **Most other Kimi hosts won't drop in.** Providers such as OpenRouter expose
> only an *OpenAI-compatible* endpoint, which Claude Code can't use without a
> translation proxy. Moonshot's own `/anthropic` endpoint is what makes this
> integration need no code change — get the key from Moonshot directly.

> **Data / privacy.** In `kimi` mode your repo contents, diffs, and prompts are
> sent to **Moonshot (a third-party provider)** instead of Anthropic. Fine for
> this open DV repo; weigh it before pointing a swarm at anything proprietary.

> **One provider per run.** Claude Code's provider (base URL + auth) is
> **process-wide**, so a single run cannot put the manager on Claude Opus and a
> tester on Kimi K3 at the same time — `AOU_MODEL_PROVIDER` swaps the engine for
> the *entire* run; the per-agent aliases only choose the tier within it. To
> compare the two vendors, run the swarm twice (once each) and diff the metrics.

### Run metrics

At the end of every `agent` / `swarm` run the runner prints a **per-model metrics
block** and writes the raw result JSON to `docker/last-run-metrics.json`
(override with `AOU_METRICS_JSON`; disable the block with `AOU_METRICS=0`). It is
derived from Claude Code's `--output-format json` result (`modelUsage` +
`duration_*` + `num_turns`):

```
── run metrics (provider: kimi) ─────────────────────────────
model                          in      out    cache    est.$*
kimi-k3                    184,203   12,904   96,010   —
kimi-k2.7-code-highspeed    52,110    8,431   40,006   —
────────────────────────────────────────────────────────────
turns 37 · API time 214.8s · wall 631s · est. cost $— *
* cost is a client-side estimate from Anthropic's price table
  and is unreliable for non-Anthropic (Kimi) models.
```

- **Per-model token use is exact and includes subagents** — it comes from the
  result's `modelUsage` map. (The top-level `usage` field undercounts once
  subagents run, so it is deliberately *not* used.)
- **Per-model wall time is not reported by Claude Code** — only whole-run
  `duration_ms` / `duration_api_ms` / `num_turns`. The block shows total API
  time, total turns, and the runner's own wall-clock; it does **not** invent a
  per-model time split.
- **Cost is an estimate** — client-side, from a bundled Anthropic price table.
  Fine as a rough Claude figure; meaningless for Kimi (shown as `—`). Use each
  vendor's usage dashboard for authoritative billing.

In GitHub Actions the **`DV swarm`** workflow uploads `last-run-metrics.json` as a
build artifact and prints the same table to the job summary.

---

## Deploying on Railway — a how-to

This project is a **hardware DV suite, not a web service** — the container has no
listening port. It runs to completion and exits (`0` = green). On Railway it is a
**one-off or scheduled (cron) job**, never an always-on service (a service that
exits `0` is flagged "crashed"). `railway.toml` already sets
`builder = "DOCKERFILE"` and `restartPolicyType = "NEVER"`.

### Step 1 — create the service

Dashboard **New Project → Deploy from GitHub repo** (or `railway up` from a
checkout). Railway reads `railway.toml`, builds the `Dockerfile`, and runs the
container. First builds are **not instant** — the image pulls the ~677 MB
oss-cad-suite whenever that layer isn't cached.

### Step 2 — pick what it runs

The image default is the DV gate (`make ci`). To run the agent or swarm instead,
set the service's **image args** to `agent` or `swarm` (Railway service settings →
the Docker command / args). **Do not use Railway's `startCommand`** — Railway runs
it via `sh -c "…"`, which bypasses the image `ENTRYPOINT` and drops the injected
Verilator args. Leave `startCommand` empty and change the image args instead.

| Run mode | Image args | Needs |
|----------|-----------|-------|
| DV gate (default) | *(none)* | — |
| Headless agent | `agent "<task>"` | `ANTHROPIC_API_KEY` (or `KIMI_API_KEY` when `AOU_MODEL_PROVIDER=kimi`) |
| Finalization swarm | `swarm` | `ANTHROPIC_API_KEY` (or `KIMI_API_KEY`), `GITHUB_TOKEN`, `SWARM_REPO` |

### Step 3 — set the variables (API keys & secrets)

Railway → your service → **Variables**. **Secrets go here only** — never in the
image, `railway.toml`, a commit, or a PR. `agent.sh` / `swarm.sh` read them from
the runtime environment; nothing is baked in.

| Variable | Mode | Required? | Notes |
|----------|------|-----------|-------|
| `ANTHROPIC_API_KEY` | agent, swarm | **required in `anthropic` mode** (default) | A key from the [Claude Console](https://platform.claude.com). Under `-p` this key is always used. |
| `AOU_MODEL_PROVIDER` | agent, swarm | optional | `anthropic` (default) or `kimi` — selects which vendor the model aliases resolve to. |
| `KIMI_API_KEY` | agent, swarm | **required in `kimi` mode** | A Moonshot key — create one at [platform.moonshot.ai](https://platform.moonshot.ai) (add ≥ $1 balance to activate); used as `ANTHROPIC_AUTH_TOKEN` against `https://api.moonshot.ai/anthropic`. Same secret discipline as `ANTHROPIC_API_KEY` — inject at run time, never bake. See [Getting a Kimi API key](#getting-a-kimi-api-key-no-host-to-stand-up). |
| `GITHUB_TOKEN` | swarm | **required to open a PR** | A **fine-grained PAT** scoped to *this repo* with **Contents: write + Pull requests: write** (or a GitHub App token). Without it the swarm edits & tests but stops before pushing. |
| `SWARM_REPO` | swarm | **required on Railway** | `owner/repo`, e.g. `markrthomas/axi-on-ucie-to-mem`. The image has no `.git`, so `swarm.sh` clones the repo at run time to make its PR — and unlike GitHub Actions, Railway does **not** set `GITHUB_REPOSITORY`, so you must provide this. |
| `VL_JOBS` | any | optional | Verilator build parallelism; image default `2`. Set **`1`** on the smallest instances if a compile OOMs. |
| `SWARM_MAX_PARALLEL` | swarm | optional | Max DV envs tested at once; auto-sized to RAM if unset. |
| `AOU_METRICS_JSON` | agent, swarm | optional | Path for the raw run-metrics JSON (default `docker/last-run-metrics.json`); `AOU_METRICS=0` disables the metrics block. |
| `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` | swarm | optional | Commit identity for the swarm's branch. |

### Step 4 — run it, and (optionally) schedule it

Deploy / trigger the service. Watch the deploy logs:

- **gate** → ends with `[REGRESS] … PASSED`, exit `0`.
- **agent** → prints Claude's result.
- **swarm** → prints the manager's report and the PR URL.

To run the **gate** on a schedule, set `cronSchedule` (UTC) in `railway.toml`
(e.g. `cronSchedule = "0 6 * * *"`). Railway starts a fresh container per tick;
it must exit before the next, which the gate does. (Cron-scheduling the *swarm*
is possible but means autonomous unattended PRs — do so deliberately.)

### Critical notes

- **Never bake or commit a secret.** Keys live only in Railway Variables (or a
  shared Railway *shared variable* / environment). Rotate the token if exposed.
- **Scope the `GITHUB_TOKEN` tightly** — this repo only, minimum write scopes,
  short expiry. The swarm pushes a branch and opens a PR autonomously; **a human
  still merges.** Treat every run as a disposable container.
- **`SWARM_REPO` is the #1 Railway gotcha** — without it the swarm can edit &
  test but cannot clone/push, so it can't open a PR.
- **Pick the provider deliberately.** `AOU_MODEL_PROVIDER=kimi` runs the *entire*
  swarm on Kimi K3 (one provider per run) and needs `KIMI_API_KEY`, not
  `ANTHROPIC_API_KEY`. The metrics block's dollar figure is an Anthropic-price
  estimate and is **meaningless for Kimi** — trust the token counts there. It also
  transmits your repo to a China-based provider under active US export-control
  scrutiny — read [Compliance & IP risk](#compliance--ip-risk) before enabling it.
- **Build memory.** The SystemC model compile is the memory peak; if a build OOMs
  (`Killed … cc1plus`), set `VL_JOBS=1` or use a larger build instance.
- **Right-size the instance.** The gate needs enough RAM for the Verilator
  builds; the swarm additionally runs several env builds in parallel (bounded by
  `SWARM_MAX_PARALLEL`, auto-sized to `MemAvailable`).

---

## Gotchas (why the image is built the way it is)

- **`python3-dev` is mandatory.** The plain `python3` package omits
  `libpython3.12.so`; without it cocotb fails at load with
  *"find_libpython was not able to find a libpython."* GitHub's `setup-python`
  ships a shared-lib build, so CI never surfaces this — a from-scratch container
  does.
- **Verilator must stay off `PATH`.** oss-cad-suite bundles its own `iverilog`;
  if it shadowed the apt one, the cocotb VPI (built against apt `iverilog`)
  breaks. It's invoked by absolute path via the entrypoint instead.
- **Env can't override `VERILATOR_ROOT`** (it's `:=` in the Makefile) — hence the
  command-line injection in the entrypoint.
- **`.dockerignore` excludes a local `oss-cad-suite/`.** The image builds its own
  pinned copy; shipping a host install into the context would bloat the build and
  risk an arch mismatch.

---

## Relation to CI

The GitHub Actions workflow (`.github/workflows/ci.yml`) and this image install
the **same tools the same way** and run the **same `make ci` gate**. CI does not
build the Dockerfile — it's a parallel, equivalent recipe. Keep the two in sync:
if you bump a tool version or add an apt/pip dependency in one, mirror it in the
other. Both are validated by the same green gate (cocotb 5/5, SV 134 reads,
pack 63, act 30, reorder 76, SystemC 145, coverage 92.9%).
