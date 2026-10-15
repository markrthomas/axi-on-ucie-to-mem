#!/usr/bin/env bash
# Entrypoint for the aou-dv image.  The pinned, from-source toolchain (Verilator,
# Yosys/SBY, btormc — see the Dockerfile) is already on PATH, and the Makefile
# derives VERILATOR_ROOT from `command -v verilator`, so no tool overrides are
# needed on the make command line.
#
#   (no args)        -> make ci
#   make <targets>   -> make <targets>
#   <anything else>  -> exec verbatim (shell, tool version, etc.)
set -euo pipefail

# Live log streaming: Python (cocotb) is the leg that matters and is handled by
# PYTHONUNBUFFERED=1 in the Dockerfile ENV; the C toolchain block-buffers when
# stdout is a pipe, which is an accepted, cosmetic log-latency tradeoff.

# --- log-volume control for rate-limited cloud log sinks ---------------------
# `make ci` is very chatty: Verilator's generated build echoes a ~500-char g++
# command PER source file across ~7 Verilator-building envs. Railway rate-limits
# log INGESTION (~500 lines/s + a volume cap), so an unfiltered gate maxes the
# limit and buries the useful banners. On Railway (auto-detected) forward only the
# SIGNAL — `[BRACKET]` banners, warnings, errors, PASS/FAIL — to the log stream,
# while the FULL transcript is tee'd to a file and, on failure, tail-dumped so a
# red run is still debuggable. Everywhere else (local `docker run`, CI) the gate
# streams verbatim as before. Override with AOU_CI_QUIET=1/0. The exit status is
# always make's (via PIPESTATUS), never grep's.
if [ -n "${AOU_CI_QUIET:-}" ]; then
  _ci_quiet="${AOU_CI_QUIET}"
elif [ -n "${RAILWAY_SERVICE_ID:-}${RAILWAY_PROJECT_ID:-}${RAILWAY_ENVIRONMENT:-}" ]; then
  _ci_quiet=1
else
  _ci_quiet=0
fi

_CI_LOG="${AOU_CI_LOG:-/tmp/aou-ci-full.log}"
# Signal lines: [ENV-TB]/[STAGE] banners, tool errors/warnings, PASS/FAIL, the
# iverilog "sorry:" notes, $finish, assertion hits, and make's *** failure line.
_CI_SIGNAL_RE='(\[[A-Z][A-Z0-9_-]+\])|([Ee]rror)|([Ww]arning)|(%Error)|(%Warning)|(PASS)|(FAIL)|(\bsorry:)|(Assertion)|(\$finish)|(make(\[[0-9]+\])?: \*\*\*)'

run_make() {
  if [ "${_ci_quiet}" != "1" ]; then
    exec make "$@"          # verbatim, unchanged behavior (local / CI)
  fi
  set +e
  make "$@" 2>&1 | tee "${_CI_LOG}" | grep --line-buffered -E "${_CI_SIGNAL_RE}"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "${rc}" -ne 0 ]; then
    echo "=== gate FAILED (rc=${rc}) — last 200 lines of full transcript ==="
    tail -n 200 "${_CI_LOG}" 2>/dev/null || true
  fi
  exit "${rc}"
}

# Headless Claude Code agent mode (layered ON TOP of the DV gate — it is only
# reached when explicitly requested; the default and `make …` paths below are
# unchanged).  See docker/agent.sh and docs/DOCKER.md.
#   docker run … agent "do the task"          # task as an argument
#   docker run -e CLAUDE_TASK="…" … agent      # task from the environment
#   printf '%s' "$payload" | docker run -i … agent   # task/webhook from stdin
if [ "${1:-}" = "agent" ] || [ "${1:-}" = "claude" ]; then
  shift
  exec /usr/local/bin/agent.sh "$@"
fi

# Headless DV finalization swarm (manager + per-env testers + infra-agent).
#   docker run -e ANTHROPIC_API_KEY=… -e GITHUB_TOKEN=… aou-dv swarm ["task"]
if [ "${1:-}" = "swarm" ]; then
  shift
  exec /usr/local/bin/swarm.sh "$@"
fi

# Optional POST-GATE metrics step (SWARM_PLAN F3).  OFF by default, so the
# default `docker run aou-dv` path below is byte-identical to before.  With
# AOU_POST_METRICS=1 the container runs the gate through metrics/capture.sh
# (which only wraps it in /usr/bin/time -v + a timestamped tee — no work is
# added inside any timed DV run) and then collects a metrics row and
# regenerates the dashboard.
#
# The collection step is ADDITIVE and CANNOT change the verdict: the gate's exit
# status is captured first and is what the container exits with; a failing
# collector only prints.  See docs/DOCKER.md -> "Post-gate metrics step".
if [ "${AOU_POST_METRICS:-0}" = "1" ] && { [ "$#" -eq 0 ] || [ "$1" = "make" ]; }; then
  if [ "$#" -eq 0 ]; then set -- make ci; fi
  shift                                   # drop the literal "make"
  set +e
  metrics/capture.sh gate make "$@"
  gate_rc=$?
  set -e
  echo "[METRICS] gate exited ${gate_rc}; collecting (additive -- cannot change that verdict)"
  make metrics || echo "[METRICS] collection failed (ignored)"
  make dashboard || echo "[DASH] render failed (ignored)"
  exit "$gate_rc"
fi

if [ "$#" -eq 0 ]; then
  run_make ci
elif [ "$1" = "make" ]; then
  shift
  run_make "$@"
else
  exec "$@"
fi
