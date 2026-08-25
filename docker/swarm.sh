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
#   AOU_MODEL_PROVIDER  "anthropic" (default, needs ANTHROPIC_API_KEY) or "kimi"
#                       (whole swarm on Kimi K3 via Moonshot, needs KIMI_API_KEY).
#                       See docker/provider-env.sh.
#   GITHUB_TOKEN        (for commit+PR) a token with repo/PR scope; without it
#                       the swarm still edits & tests but cannot push/open a PR.
#   GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL   commit identity (sensible defaults).
#   SWARM_PERMISSION_MODE   default "acceptEdits".
#   SWARM_ALLOWED_TOOLS     default "Bash,Read,Edit,Write,Grep,Glob,Task,Agent".
#   AOU_METRICS / AOU_METRICS_JSON   per-model token/time metrics at end of run
#                       (set AOU_METRICS=0 to disable); see render-metrics.py.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker/provider-env.sh
. "$SELF_DIR/provider-env.sh"
# Resolve the provider (anthropic|kimi) up front: sets auth + Kimi alias remaps
# and fails fast if the selected provider's key is missing — before any cloning.
aou_resolve_provider || exit $?

# Resolve the repo to work in.  On a git checkout (a CI runner, a dev box) use it
# directly.  The container image ships code WITHOUT .git (see .dockerignore), so
# there we clone at run time from GITHUB_TOKEN + a repo slug — that is what lets
# the manager branch / commit / push / open a PR on Railway.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$ROOT" ]; then
  repo="${SWARM_REPO:-${GITHUB_REPOSITORY:-}}"
  if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$repo" ]; then
    ROOT="${SWARM_CLONE_DIR:-/tmp/aou-swarm-repo}"
    echo "swarm: no local git checkout — cloning ${repo} into ${ROOT}" >&2
    rm -rf "$ROOT"
    git clone --depth 50 "https://x-access-token:${GITHUB_TOKEN}@github.com/${repo}.git" "$ROOT" >&2
  else
    ROOT="/work"
    echo "swarm: no git checkout and no GITHUB_TOKEN+repo — running from ${ROOT} (edit/test only; cannot push a PR)." >&2
  fi
fi
cd "$ROOT"

task="${1:-}"
[ "$#" -gt 0 ] && shift || true
[ -z "$task" ] && task="${SWARM_TASK:-}"
[ -z "$task" ] && [ ! -t 0 ] && task="$(cat)"
[ -z "$task" ] && [ -f "$ROOT/docker/swarm-task.md" ] && task="$(cat "$ROOT/docker/swarm-task.md")"

if [ -z "$task" ]; then
  echo "swarm: no task (pass an arg, set \$SWARM_TASK, pipe stdin, or ship docker/swarm-task.md)" >&2
  exit 2
fi

# Commit identity + GitHub auth so the manager can push a branch and open a PR.
git config --global user.name  "${GIT_AUTHOR_NAME:-aou-dv swarm}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-aou-dv-swarm@users.noreply.github.com}"
git config --global --add safe.directory "$ROOT"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="$GITHUB_TOKEN"
  gh auth setup-git 2>/dev/null || true
else
  echo "swarm: GITHUB_TOKEN not set — the swarm will edit & test but cannot push or open a PR." >&2
fi

# Auto-throttle tester concurrency to available RAM: each DV env's Verilator/g++
# build can need ~2 GB, so running all seven in parallel OOMs a small host.  Pick
# a safe batch size from MemAvailable (>= 1, <= 7 envs); override with
# SWARM_MAX_PARALLEL.  VL_JOBS (image default 2) still caps each build's own
# parallel cc1plus; on a very tight host also set VL_JOBS=1.
avail_mb="$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 4096)"
if [ -z "${SWARM_MAX_PARALLEL:-}" ]; then
  SWARM_MAX_PARALLEL=$(( avail_mb / 2048 ))
  [ "$SWARM_MAX_PARALLEL" -lt 1 ] && SWARM_MAX_PARALLEL=1
  [ "$SWARM_MAX_PARALLEL" -gt 7 ] && SWARM_MAX_PARALLEL=7
fi
echo "swarm: ~${avail_mb} MB available, VL_JOBS=${VL_JOBS:-2} -> at most ${SWARM_MAX_PARALLEL} dv-env-tester(s) in parallel." >&2

prompt="You are the swarm manager. Use the swarm-manager subagent to carry out the task below, following its documented procedure, then print its final report verbatim.

HOST CAPACITY: ~${avail_mb} MB memory available.  Dispatch AT MOST ${SWARM_MAX_PARALLEL} dv-env-tester subagent(s) in parallel — run the seven DV environments in batches of that size, never all seven at once.  If a Verilator/g++ compile is OOM-killed (\"Killed … cc1plus\"), re-run that environment with VL_JOBS=1.

TASK:
$task"

perm="${SWARM_PERMISSION_MODE:-acceptEdits}"
tools="${SWARM_ALLOWED_TOOLS:-Bash,Read,Edit,Write,Grep,Glob,Task,Agent}"

# Fast path: metrics disabled -> original behavior.
if [ "${AOU_METRICS:-1}" = "0" ]; then
  exec claude -p "$prompt" \
    --permission-mode "$perm" \
    --allowedTools "$tools" \
    --output-format "${CLAUDE_OUTPUT_FORMAT:-text}" \
    "$@"
fi

# Metrics path: run in stream-json and let render-metrics.py print the manager's
# report on stdout and the per-model token/time summary on stderr, and archive
# the raw result JSON for CI.
metrics_json="${AOU_METRICS_JSON:-$ROOT/docker/last-run-metrics.json}"
start="$(date +%s)"
set +e
claude -p "$prompt" \
  --permission-mode "$perm" \
  --allowedTools "$tools" \
  --output-format stream-json --verbose \
  "$@" \
  | python3 "$SELF_DIR/render-metrics.py" \
      --emit text --provider "$AOU_PROVIDER" \
      --json-out "$metrics_json" --wall-start "$start"
# Snapshot the whole PIPESTATUS array in one shot: a plain assignment resets
# PIPESTATUS, so reading [0] then [1] on separate commands loses [1] (and under
# `set -u` that read is an "unbound variable" fatal error).
rc=( "${PIPESTATUS[@]}" ); rc_claude=${rc[0]}; rc_render=${rc[1]}
set -e
[ "$rc_claude" -ne 0 ] && exit "$rc_claude"
exit "$rc_render"
