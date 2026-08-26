#!/usr/bin/env bash
# Entrypoint for the aou-dv image.  The Makefile computes VERILATOR_ROOT (and
# defaults SBY to the bare `sby`) with `:=`/`?=` that environment variables do
# NOT override — so, exactly like .github/workflows/ci.yml, the pinned
# Verilator triplet AND the SymbiYosys prover (bundled in oss-cad-suite, kept
# off PATH — see the Dockerfile) must be passed as make COMMAND-LINE
# arguments.  This wrapper appends them to every `make` invocation so the
# pinned toolchain is always used.
#
#   (no args)        -> make ci   <pinned-tool overrides>
#   make <targets>   -> make <targets> <pinned-tool overrides>
#   <anything else>  -> exec verbatim (shell, tool version, etc.)
set -euo pipefail

MAKE_ARGS=(
  "VERILATOR=${OSS}/bin/verilator"
  "VERILATOR_ROOT=${OSS}/share/verilator"
  "VERILATOR_COV=${OSS}/bin/verilator_coverage"
  "SBY=${OSS}/bin/sby"
)

# NB: do NOT wrap the gate in `stdbuf`/`unbuffer` to force line-buffering.  stdbuf
# works by LD_PRELOAD-ing the *system* libstdbuf.so (built against this image's
# glibc 2.38) into every child — but the pinned oss-cad-suite tools (Verilator,
# sby) run against their OWN bundled, older glibc, which lacks GLIBC_2.38, so the
# preload fails to resolve and the tool dies:
#   verilator_bin: /opt/oss-cad-suite/lib/libc.so.6: version `GLIBC_2.38' not
#   found (required by /usr/libexec/coreutils/libstdbuf.so)
# It breaks `make lint` immediately (see docs/DOCKER.md / CLAUDE.md).  Python is
# the one leg where live streaming matters (cocotb), and it bypasses libc stdio
# buffering anyway, so PYTHONUNBUFFERED=1 in the Dockerfile ENV covers it without
# any preload.  The C toolchain block-buffers when stdout is a pipe; that is a
# cosmetic log-latency tradeoff, accepted to keep the pinned tools working.

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

if [ "$#" -eq 0 ]; then
  run_make ci "${MAKE_ARGS[@]}"
elif [ "$1" = "make" ]; then
  shift
  run_make "$@" "${MAKE_ARGS[@]}"
else
  exec "$@"
fi
