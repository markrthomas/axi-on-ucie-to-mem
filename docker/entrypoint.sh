#!/usr/bin/env bash
# Entrypoint for the aou-dv image.  The Makefile computes VERILATOR_ROOT with a
# `:=` shell call (command -v verilator), which environment variables do NOT
# override — so, exactly like .github/workflows/ci.yml, the pinned Verilator
# triplet must be passed as make COMMAND-LINE arguments.  This wrapper appends
# them to every `make` invocation so the pinned build is always used.
#
#   (no args)        -> make ci   <verilator overrides>
#   make <targets>   -> make <targets> <verilator overrides>
#   <anything else>  -> exec verbatim (shell, tool version, etc.)
set -euo pipefail

VLT_ARGS=(
  "VERILATOR=${OSS}/bin/verilator"
  "VERILATOR_ROOT=${OSS}/share/verilator"
  "VERILATOR_COV=${OSS}/bin/verilator_coverage"
)

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
  exec make ci "${VLT_ARGS[@]}"
elif [ "$1" = "make" ]; then
  shift
  exec make "$@" "${VLT_ARGS[@]}"
else
  exec "$@"
fi
