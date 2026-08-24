# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# axi-on-ucie-to-mem — reproducible DV toolchain image.
#
# Mirrors .github/workflows/ci.yml exactly so `docker run` reproduces the CI
# gate (lint + cocotb/PyUVM + SV directed on Icarus & Verilator + pack + act +
# reorder + SystemC + Verilator coverage):
#   * Ubuntu 24.04 ships SystemC 2.3.3 (libsystemc-dev) and the apt Icarus that
#     the cocotb VPI is built against.
#   * Verilator is PINNED to the oss-cad-suite build used for local dev + CI
#     (tag 2026-04-13, Verilator 5.047).  The apt Verilator attributes line
#     coverage ~9 pts stricter and would push `make coverage` below its 85%
#     floor, and a newer oss-cad-suite adds lints this design predates — so the
#     tag is exact, not "latest".
#
# Build:  docker build -t aou-dv .
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
FROM ubuntu:24.04

# Pins (bump deliberately — see the coverage/lint note above).
ARG OSS_TAG=2026-04-13
ARG OSS_STAMP=20260413
ARG COCOTB_VERSION=1.9.2
ARG PYUVM_VERSION=4.0.1

ENV DEBIAN_FRONTEND=noninteractive

# --- RTL tools (Icarus + SystemC) + build/runtime deps, from apt --------------
# iverilog: cocotb VPI + the Icarus directed/pack/act/reorder flows.
# libsystemc-dev: SystemC 2.3.3 headers + libsystemc.so for the SystemC TB.
# python3-dev: ships libpython3.x.so, which cocotb's find_libpython needs to
#   embed the interpreter in the VPI (the plain python3 runtime package omits
#   it; GitHub's setup-python bundles a shared-lib build, so CI never hit this).
RUN apt-get update && apt-get install -y --no-install-recommends \
        iverilog \
        libsystemc-dev \
        build-essential \
        python3 \
        python3-dev \
        python3-venv \
        ca-certificates \
        curl \
        git \
        make \
        tmux \
    && rm -rf /var/lib/apt/lists/*

# --- Pinned Verilator via oss-cad-suite ---------------------------------------
# Extracted to /opt/oss-cad-suite; invoked by absolute path so it never shadows
# the apt iverilog the cocotb VPI links against.
ENV OSS=/opt/oss-cad-suite
RUN curl -fL -o /tmp/oss.tgz \
      "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_TAG}/oss-cad-suite-linux-x64-${OSS_STAMP}.tgz" \
    && tar xzf /tmp/oss.tgz -C /opt \
    && rm /tmp/oss.tgz

# --- Python deps (cocotb + pyuvm) in an isolated venv -------------------------
# A venv satisfies PEP 668 (Ubuntu 24.04 marks the system Python externally
# managed) and keeps the cocotb interpreter self-contained.  cocotb's makefiles
# pick up `python`/`python3` from PATH.
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir "cocotb==${COCOTB_VERSION}" "pyuvm==${PYUVM_VERSION}"

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
# `?=` in dv/cocotb/Makefile, so env suffices here).  The pinned Verilator paths
# are `:=`-computed in the Makefile and can only be overridden on the make
# command line, which the entrypoint does — see docker/entrypoint.sh.
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
COPY docker/entrypoint.sh   /usr/local/bin/entrypoint.sh
COPY docker/agent.sh        /usr/local/bin/agent.sh
COPY docker/swarm.sh        /usr/local/bin/swarm.sh
COPY docker/provider-env.sh /usr/local/bin/provider-env.sh
COPY docker/render-metrics.py /usr/local/bin/render-metrics.py
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/agent.sh \
             /usr/local/bin/swarm.sh /usr/local/bin/render-metrics.py

# Fail fast if the toolchain didn't assemble correctly.
RUN iverilog -V | head -1 \
    && "$OSS/bin/verilator" --version \
    && python -c "import cocotb, pyuvm; print('cocotb', cocotb.__version__, 'pyuvm', pyuvm.__version__)" \
    && node --version \
    && claude --version \
    && gh --version | head -1

# Default: run the full CI gate (make ci) with the pinned Verilator overrides
# injected by the entrypoint.  Override the args to run a subset, e.g.
#   docker run --rm aou-dv make reorder
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD []
