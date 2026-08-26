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
  metrics/capture.sh gate make "$@" "${MAKE_ARGS[@]}"
  gate_rc=$?
  set -e
  echo "[METRICS] gate exited ${gate_rc}; collecting (additive -- cannot change that verdict)"
  make metrics VERILATOR="${OSS}/bin/verilator" || echo "[METRICS] collection failed (ignored)"
  make dashboard || echo "[DASH] render failed (ignored)"
  exit "$gate_rc"
fi

if [ "$#" -eq 0 ]; then
  exec make ci "${MAKE_ARGS[@]}"
elif [ "$1" = "make" ]; then
  shift
  exec make "$@" "${MAKE_ARGS[@]}"
else
  exec "$@"
fi
