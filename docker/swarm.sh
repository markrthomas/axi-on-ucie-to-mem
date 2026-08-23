#!/usr/bin/env bash
# Launch the AoU DV finalization swarm.
#
# A manager (the `swarm-manager` agent) dispatches one `dv-env-tester` per DV
# environment plus the `infra-agent`, applies the fixes needed to get the gate
# green and the image/Railway config sound, then commits to a branch and opens a
# PR (a human merges).  See .claude/agents/*.md and docs/DOCKER.md.
#
# Unlike plain `agent` mode, the swarm runs Claude Code **NON-bare** so the
# project's .claude/agents/ are discovered and dispatchable.
#
# Task source, in precedence order:
#   1. first CLI argument     2. $SWARM_TASK     3. stdin
#   4. the default task in docker/swarm-task.md
#
# Runtime inputs:
#   ANTHROPIC_API_KEY   (required) Console API key.
#   GITHUB_TOKEN        (for commit+PR) a token with repo/PR scope; without it
#                       the swarm still edits & tests but cannot push/open a PR.
#   GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL   commit identity (sensible defaults).
#   SWARM_PERMISSION_MODE   default "acceptEdits".
#   SWARM_ALLOWED_TOOLS     default "Bash,Read,Edit,Write,Grep,Glob,Task,Agent".
#   CLAUDE_OUTPUT_FORMAT    default "text".
set -euo pipefail

task="${1:-}"
[ "$#" -gt 0 ] && shift || true
[ -z "$task" ] && task="${SWARM_TASK:-}"
[ -z "$task" ] && [ ! -t 0 ] && task="$(cat)"
[ -z "$task" ] && [ -f /work/docker/swarm-task.md ] && task="$(cat /work/docker/swarm-task.md)"

if [ -z "$task" ]; then
  echo "swarm: no task (pass an arg, set \$SWARM_TASK, pipe stdin, or ship docker/swarm-task.md)" >&2
  exit 2
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "swarm: ANTHROPIC_API_KEY is not set — Claude Code cannot authenticate." >&2
  exit 3
fi

# Commit identity + GitHub auth so the manager can push a branch and open a PR.
git config --global user.name  "${GIT_AUTHOR_NAME:-aou-dv swarm}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-aou-dv-swarm@users.noreply.github.com}"
git config --global --add safe.directory /work
if [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
  gh auth setup-git 2>/dev/null || true
else
  echo "swarm: GITHUB_TOKEN not set — the swarm will edit & test but cannot push or open a PR." >&2
fi

# Auto-throttle tester concurrency to available RAM: each DV env's Verilator/g++
# build can need ~2 GB, so running all six in parallel OOMs a small host.  Pick a
# safe batch size from MemAvailable (>= 1, <= 6 envs); override with
# SWARM_MAX_PARALLEL.  VL_JOBS (image default 2) still caps each build's own
# parallel cc1plus; on a very tight host also set VL_JOBS=1.
avail_mb="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)"
if [ -z "${SWARM_MAX_PARALLEL:-}" ]; then
  SWARM_MAX_PARALLEL=$(( avail_mb / 2048 ))
  [ "$SWARM_MAX_PARALLEL" -lt 1 ] && SWARM_MAX_PARALLEL=1
  [ "$SWARM_MAX_PARALLEL" -gt 6 ] && SWARM_MAX_PARALLEL=6
fi
echo "swarm: ~${avail_mb} MB available, VL_JOBS=${VL_JOBS:-2} -> at most ${SWARM_MAX_PARALLEL} dv-env-tester(s) in parallel." >&2

exec claude -p "You are the swarm manager. Use the swarm-manager subagent to carry out the task below, following its documented procedure, then print its final report verbatim.

HOST CAPACITY: ~${avail_mb} MB memory available.  Dispatch AT MOST ${SWARM_MAX_PARALLEL} dv-env-tester subagent(s) in parallel — run the six DV environments in batches of that size, never all six at once.  If a Verilator/g++ compile is OOM-killed (\"Killed … cc1plus\"), re-run that environment with VL_JOBS=1.

TASK:
$task" \
  --permission-mode "${SWARM_PERMISSION_MODE:-acceptEdits}" \
  --allowedTools "${SWARM_ALLOWED_TOOLS:-Bash,Read,Edit,Write,Grep,Glob,Task,Agent}" \
  --output-format "${CLAUDE_OUTPUT_FORMAT:-text}" \
  "$@"
