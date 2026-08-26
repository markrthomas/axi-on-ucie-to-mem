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

# Stream the gate's output LIVE instead of block-buffering it.  When stdout is a
# pipe (the cloud captures logs off a pipe, not a TTY), glibc full-buffers each
# process, so a long `make ci` shows *nothing* until it exits — a running gate is
# indistinguishable from a hung one in the Railway/CI log viewer.  `stdbuf -oL -eL`
# forces line-buffering, and because stdbuf works via LD_PRELOAD (libstdbuf.so) +
# env, it propagates to the child tools too (Verilator/Icarus/sby/gcc).  Python
# ignores libc stdio buffering, so PYTHONUNBUFFERED=1 (set in the Dockerfile ENV)
# covers cocotb/pyuvm.  Timing only — output bytes are unchanged, so the gate's
# banners/baselines (incl. the SystemC sc.log diff) stay byte-identical.
STREAM=( stdbuf -oL -eL )

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
  exec "${STREAM[@]}" make ci "${MAKE_ARGS[@]}"
elif [ "$1" = "make" ]; then
  shift
  exec "${STREAM[@]}" make "$@" "${MAKE_ARGS[@]}"
else
  exec "$@"
fi
