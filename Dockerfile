# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# axi-on-ucie-to-mem — reproducible DV toolchain image.
#
# Runs the same `make ci` gate as .github/workflows/ci.yml with the same pinned
# tools (lint + eda-check + cocotb/PyUVM + SV directed on Icarus & Verilator +
# pack + act + reorder + ooo + mrp + sva-mut + SystemC + Verilator coverage +
# SymbiYosys formal) — CI runs this image's `tools` stage (docs/DOCKER.md
# "Relation to CI"):
#   * Ubuntu 24.04 ships SystemC 2.3.3 (libsystemc-dev) and the apt Icarus that
#     the cocotb VPI is built against.
#   * Verilator is built from source and PINNED (v5.048).  The apt Verilator
#     attributes line coverage ~9 pts stricter and would push `make coverage`
#     below its 85% floor, and a newer Verilator adds lints this design predates
#     — so the tag is exact, not "latest".  The formal tier (`make formal`) uses
#     Yosys (native slang frontend) + SBY + btormc (Boolector), also built from
#     source and pinned below.  No prebuilt tool bundle is used.
#
# Stages:  builder (compiles the toolchain under /opt)  ->  tools (apt + venv +
# the built toolchain; what GitHub CI runs the gate in: `--target tools`)  ->
# full (tools + Node/Claude Code/gh + the repo; the default / Railway image).
#
# Build:  docker build -t aou-dv .          # compiles the toolchain: slow the first time
# Run  :  docker run --rm aou-dv                 # full gate (make ci)
#         docker run --rm aou-dv make check      # gate without coverage
#         docker run --rm aou-dv make reorder    # a single environment
#
# Headless Claude Code agent (same image; needs ANTHROPIC_API_KEY at run time):
#         docker run --rm -e ANTHROPIC_API_KEY=… aou-dv agent "summarize the RTL"
#         printf '%s' "$payload" | docker run --rm -i -e ANTHROPIC_API_KEY=… aou-dv agent
#
# DV finalization swarm (manager + per-env testers + infra; edits, tests, PRs):
#         docker run --rm -e ANTHROPIC_API_KEY=… -e GITHUB_TOKEN=… aou-dv swarm
#
# Run on Kimi K3 instead of Claude (whole run; only a Moonshot API key — no host
# to stand up).  Every agent/swarm run also prints a per-model token/time metrics
# block at the end.  See docs/DOCKER.md → "Model selection, providers & run metrics":
#         docker run --rm -e AOU_MODEL_PROVIDER=kimi -e KIMI_API_KEY=… aou-dv agent "hi"
#
# On Railway: this is a batch/one-off image (no listening port).  Deploy it as a
# one-off job or a Cron service — it runs the gate to completion and exits with
# the gate's status (0 = green).  It is NOT a long-running web service.
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# builder: compile Verilator + Yosys(+slang) + SBY + btormc, install under /opt
# -----------------------------------------------------------------------------
FROM ubuntu:24.04 AS builder

ARG VERILATOR_REF=v5.048
# Yosys master commit with the native slang frontend (frontends/slang) + CMake build.
ARG YOSYS_REF=47595d984
ARG SBY_REF=main
ARG BOOLECTOR_REF=3.2.4
# Parallel compile jobs (0 = all cores).  Lower it (e.g. --build-arg BUILD_JOBS=2)
# on a small-RAM builder; the heavy Verilator/slang/Boolector TUs can OOM it.
ARG BUILD_JOBS=0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git make cmake g++ ccache \
        autoconf flex bison libfl-dev help2man perl \
        python3 python3-dev zlib1g-dev liblz4-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Verilator (from source) --------------------------------------------------
RUN git clone --depth 1 -b "${VERILATOR_REF}" https://github.com/verilator/verilator /src/verilator \
    && cd /src/verilator \
    && autoconf && ./configure --prefix=/opt/verilator \
    && make -j"$(j=${BUILD_JOBS}; [ "$j" -gt 0 ] && echo $j || nproc)" && make install \
    && rm -rf /src/verilator

# --- Yosys + native slang (CMake) ---------------------------------------------
# tcl/readline/editline/ffi OFF (not needed for formal); abc + slang ON.  -j is
# capped so the heavy slang TUs fit a CI runner's RAM.  slang is BUILT IN, so the
# .sby files use `read_slang` directly (no `plugin -i slang`).
RUN git clone --recurse-submodules https://github.com/YosysHQ/yosys /src/yosys \
    && cd /src/yosys && git checkout "${YOSYS_REF}" && git submodule update --init --recursive \
    && cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/yosys \
        -DYOSYS_WITHOUT_TCL=ON -DYOSYS_WITHOUT_READLINE=ON \
        -DYOSYS_WITHOUT_EDITLINE=ON -DYOSYS_WITHOUT_LIBFFI=ON \
    && cmake --build build -j"$(j=${BUILD_JOBS}; [ "$j" -gt 0 ] && echo $j || echo $(( $(nproc) < 4 ? $(nproc) : 4 )))" \
    && cmake --install build \
    && rm -rf /src/yosys

# --- SBY (pure Python) --------------------------------------------------------
RUN git clone --depth 1 -b "${SBY_REF}" https://github.com/YosysHQ/sby /src/sby \
    && make -C /src/sby install PREFIX=/opt/sby \
    && rm -rf /src/sby

# --- btormc (Boolector's BTOR2 model checker; the `btor btormc` sby engine) ---
# apt's boolector is 1.5 (no btormc), so build 3.2.x with its bundled deps
# (btor2tools + lingeling); btorsim (from btor2tools) replays cover witnesses.
RUN git clone --depth 1 -b "${BOOLECTOR_REF}" https://github.com/Boolector/boolector /src/boolector \
    && cd /src/boolector \
    && ./contrib/setup-btor2tools.sh && ./contrib/setup-lingeling.sh \
    && ./configure.sh --prefix /opt/boolector \
    && cd build && make -j"$(j=${BUILD_JOBS}; [ "$j" -gt 0 ] && echo $j || nproc)" \
    && mkdir -p /opt/boolector/bin \
    && install -m755 bin/btormc bin/boolector ../deps/btor2tools/build/bin/btorsim /opt/boolector/bin/ \
    && rm -rf /src/boolector

# -----------------------------------------------------------------------------
# tools: everything needed to RUN the DV gate, WITHOUT the repo baked in.
# Verilator re-compiles C++ sims at run time, so g++/make + the Verilator headers
# + lz4/zlib dev headers (FST traces) must be present.  GitHub CI builds
# `--target tools` and runs the gate against a checkout, so the CI image depends
# only on tool versions, not on the source.
# -----------------------------------------------------------------------------
FROM ubuntu:24.04 AS tools

ARG COCOTB_VERSION=1.9.2
ARG PYUVM_VERSION=4.0.1

ENV DEBIAN_FRONTEND=noninteractive

# Force a UTF-8 locale + Python I/O encoding. The cloud (Railway/CI) starts the
# container under a C/POSIX locale, which makes Python's stdout fall back to the
# ASCII codec. Printing any non-ASCII char then raises UnicodeEncodeError and
# aborts the run — e.g. the em-dash in the cocotb "[COV-FUNC] AXI functional
# coverage —" banner (crashed the write_read_test on Railway). ubuntu:24.04 ships
# C.UTF-8 built in, so this needs no locale-gen. Byte-identical output on a
# UTF-8-capable sink; it only stops the crash on an ASCII one.
#
# PYTHONUNBUFFERED makes cocotb/pyuvm output stream live rather than block-buffer
# when stdout is a pipe (the cloud captures logs off a pipe). Flush timing only;
# output bytes unchanged.
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 PYTHONIOENCODING=UTF-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1

# --- RTL tools (Icarus + SystemC) + build/runtime deps, from apt --------------
# iverilog: cocotb VPI + the Icarus directed/pack/act/reorder flows.
# libsystemc-dev: SystemC 2.3.3 headers + libsystemc.so for the SystemC TB.
# python3-dev: ships libpython3.x.so, which cocotb's find_libpython needs to
#   embed the interpreter in the VPI (the plain python3 runtime package omits
#   it; GitHub's setup-python bundles a shared-lib build, so CI never hit this).
# liblz4-dev/zlib1g-dev: Verilator FST-trace builds (`#include <lz4.h>`).
# gtkwave: provides fst2vcd for the dev-only `make wave-check`.
RUN apt-get update && apt-get install -y --no-install-recommends \
        iverilog \
        libsystemc-dev \
        build-essential \
        ccache \
        python3 \
        python3-dev \
        python3-venv \
        ca-certificates \
        curl \
        git \
        make \
        tmux \
        zlib1g-dev \
        liblz4-dev \
        gtkwave \
    && rm -rf /var/lib/apt/lists/*

# --- Built-from-source toolchain ----------------------------------------------
COPY --from=builder /opt/verilator /opt/verilator
COPY --from=builder /opt/yosys     /opt/yosys
COPY --from=builder /opt/sby       /opt/sby
COPY --from=builder /opt/boolector /opt/boolector
# The Makefile derives VERILATOR_ROOT from `command -v verilator`, so Verilator
# just has to be on PATH (do NOT set VERILATOR_ROOT yourself).  None of these
# ship their own iverilog, so they can sit on PATH.
ENV PATH="/opt/verilator/bin:/opt/yosys/bin:/opt/sby/bin:/opt/boolector/bin:$PATH"

# --- Python deps (cocotb + pyuvm) in an isolated venv -------------------------
# A venv satisfies PEP 668 (Ubuntu 24.04 marks the system Python externally
# managed) and keeps the cocotb interpreter self-contained.  cocotb's makefiles
# pick up `python`/`python3` from PATH.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "cocotb==${COCOTB_VERSION}" "pyuvm==${PYUVM_VERSION}" click  # click: sby dependency

# Fail fast if the toolchain didn't assemble correctly.
RUN iverilog -V | head -1 \
    && verilator --version \
    && sby --help >/dev/null \
    && yosys -V \
    && btormc --version \
    && python -c "import cocotb, pyuvm; print('cocotb', cocotb.__version__, 'pyuvm', pyuvm.__version__)"

# -----------------------------------------------------------------------------
# full: the tools image + Node/Claude Code/gh + the repo, for local / Railway
# batch runs.  GitHub CI's gate does NOT use this stage (it builds `--target tools`).
# -----------------------------------------------------------------------------
FROM tools AS full

# --- Node.js 20 LTS + Claude Code CLI (headless agent mode) -------------------
# Layered alongside the DV toolchain so the same image can also run Anthropic's
# Claude Code headless as a cloud agent (see docker/agent.sh).  Node 20 (>= 18,
# as Claude Code requires) from NodeSource; git is already installed above.
#
# Non-interactive operation is the CLI's `-p`/`--print` flag, NOT an environment
# variable — there is no CLAUDE_CODE_NON_INTERACTIVE.  The umbrella var below is
# the real switch that turns off telemetry / error reporting / update checks
# (per https://code.claude.com/docs/en/env-vars); it is harmless to the DV gate.
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# GitHub CLI — lets the finalization swarm (docker/swarm.sh) push a branch and
# open a PR when GITHUB_TOKEN is provided at run time (never baked in).
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Project ------------------------------------------------------------------
WORKDIR /work
COPY . /work

# The cocotb VPI links against the apt iverilog at /usr/bin (ICARUS_BIN_DIR is
# `?=` in dv/cocotb/Makefile, so env suffices here).
ENV ICARUS_BIN_DIR=/usr/bin
# Cap Verilator's C++ build parallelism.  Railway (and other cloud builders)
# advertise many cores but little RAM, so the default `-j 0` (one cc1plus per
# core) OOM-kills the compiler.  2 keeps peak memory bounded; lower to 1 on the
# smallest instances, or raise it (or set VL_JOBS=0) where RAM is ample.
ENV VL_JOBS=2
# Model provider for headless agent/swarm runs: "anthropic" (default, needs
# ANTHROPIC_API_KEY) or "kimi" (whole run on Kimi K3 via Moonshot's
# Anthropic-compatible endpoint, needs KIMI_API_KEY).  Keys are ALWAYS injected
# at run time — never baked in.  Resolution lives in docker/provider-env.sh.
ENV AOU_MODEL_PROVIDER=anthropic
# Post-gate metrics (SWARM_PLAN F3).  OFF by default so `docker run aou-dv` is
# byte-identical to before.  With -e AOU_POST_METRICS=1 the container runs the
# gate through metrics/capture.sh (an outside-only /usr/bin/time + timestamped
# tee wrapper — no work is added inside any timed DV run) and then collects a
# metrics row and regenerates metrics/dashboard.html.  Collection is additive:
# the container still exits with the GATE's status.  See docs/DOCKER.md.
ENV AOU_POST_METRICS=0
# metrics/*.sh and *.py are invoked directly by the entrypoint's post-gate path.
RUN chmod +x /work/metrics/capture.sh /work/metrics/collect.py \
             /work/metrics/dashboard.py /work/metrics/stamp.py
COPY docker/entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY docker/agent.sh        /usr/local/bin/agent.sh
COPY docker/swarm.sh        /usr/local/bin/swarm.sh
COPY docker/provider-env.sh /usr/local/bin/provider-env.sh
COPY docker/render-metrics.py /usr/local/bin/render-metrics.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/agent.sh \
             /usr/local/bin/swarm.sh /usr/local/bin/render-metrics.py

# Fail fast if the agent layer didn't assemble correctly.
RUN node --version \
    && claude --version \
    && gh --version | head -1

# Default: run the full CI gate (make ci) — see docker/entrypoint.sh.  Override the args to run a subset, e.g.
#   docker run --rm aou-dv make reorder
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
