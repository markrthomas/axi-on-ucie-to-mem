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

## Deploying on Railway

This project is a **hardware DV suite, not a web service** — the container has no
listening port. It runs the gate to completion and exits (`0` = green). Deploy
it as a **one-off or scheduled (cron) job**, not an always-on service (an
always-on service that exits `0` is flagged "crashed").

`railway.toml` configures this:

```toml
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
restartPolicyType = "NEVER"
# cronSchedule = "0 6 * * *"   # uncomment to run daily at 06:00 UTC
```

Steps:

1. Create a Railway project from this repo (dashboard **New Project → Deploy from
   GitHub repo**, or `railway up` from a checkout). Railway reads `railway.toml`,
   builds the Dockerfile, and runs the container.
2. Watch the deploy logs for the `[REGRESS] … PASSED` banner.
3. To run on a schedule, set `cronSchedule` (UTC) in `railway.toml`. Railway
   starts a fresh container per tick; it must exit before the next tick, which
   this gate does.

**Do not set a Railway `startCommand`.** Railway runs `startCommand` via
`sh -c "<command>"`, which bypasses the image `ENTRYPOINT` and would drop the
injected Verilator args. Leave it unset so the image default runs; to run a
subset, change the Docker `CMD` (image args) instead.

**If the build still OOMs** on the smallest instance (the SystemC model compile
is the memory peak): set a service variable **`VL_JOBS=1`**, or increase the
instance memory. Note the build pulls the ~677 MB oss-cad-suite each time its
layer isn't cached, so first builds are not instant.

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
