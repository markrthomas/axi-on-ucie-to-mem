#!/usr/bin/env bash
# Headless Claude Code runner for the aou-dv image.
#
# Non-interactive mode is the CLI's `-p`/`--print` flag (there is NO
# CLAUDE_CODE_NON_INTERACTIVE environment variable — that is a myth); `--bare`
# skips host hooks/plugins/CLAUDE.md so a container run is reproducible.  See
# https://code.claude.com/docs/en/headless.
#
# Task source, in precedence order:
#   1. the first CLI argument           ->  agent "fix the failing test"
#   2. $CLAUDE_TASK                      ->  -e CLAUDE_TASK="…"
#   3. stdin (e.g. a piped webhook body) ->  printf … | docker run -i … agent
#
# Any further arguments are passed straight through to `claude` (e.g.
# --allowedTools, --add-dir).  Tunables:
#   AOU_MODEL_PROVIDER       "anthropic" (default, needs ANTHROPIC_API_KEY) or
#                            "kimi" (Kimi K3 via Moonshot, needs KIMI_API_KEY).
#                            See docker/provider-env.sh.
#   CLAUDE_PERMISSION_MODE   default "dontAsk" (locked-down CI posture); set
#                            "acceptEdits" or pass --allowedTools for a worker
#                            that must edit files / run commands.
#   CLAUDE_OUTPUT_FORMAT     default "text"; "json" / "stream-json" for callers.
#   AOU_METRICS / AOU_METRICS_JSON   per-model token/time metrics at end of run
#                            (set AOU_METRICS=0 to disable); see render-metrics.py.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker/provider-env.sh
. "$SELF_DIR/provider-env.sh"

task="${1:-}"
[ "$#" -gt 0 ] && shift || true

if [ -z "$task" ]; then
  task="${CLAUDE_TASK:-}"
fi
if [ -z "$task" ] && [ ! -t 0 ]; then
  task="$(cat)"                 # read a piped task / webhook payload
fi

if [ -z "$task" ]; then
  echo "agent: no task provided (pass an argument, set \$CLAUDE_TASK, or pipe it on stdin)" >&2
  exit 2
fi

# Resolve the provider (anthropic|kimi): sets auth + alias remaps, checks the key.
aou_resolve_provider || exit $?

fmt="${CLAUDE_OUTPUT_FORMAT:-text}"
case "$fmt" in text|json|stream-json) ;; *) fmt="text" ;; esac

# Fast path: metrics disabled -> original behavior, exact same output shape.
if [ "${AOU_METRICS:-1}" = "0" ]; then
  exec claude -p "$task" \
    --bare \
    --permission-mode "${CLAUDE_PERMISSION_MODE:-dontAsk}" \
    --output-format "$fmt" \
    "$@"
fi

# Metrics path: drive Claude in stream-json and let render-metrics.py reproduce
# the requested output shape on stdout and print the per-model metrics on stderr.
metrics_json="${AOU_METRICS_JSON:-last-run-metrics.json}"
start="$(date +%s)"
set +e
claude -p "$task" \
  --bare \
  --permission-mode "${CLAUDE_PERMISSION_MODE:-dontAsk}" \
  --output-format stream-json --verbose \
  "$@" \
  | python3 "$SELF_DIR/render-metrics.py" \
      --emit "$fmt" --provider "$AOU_PROVIDER" \
      --json-out "$metrics_json" --wall-start "$start"
rc_claude=${PIPESTATUS[0]}; rc_render=${PIPESTATUS[1]}
set -e
[ "$rc_claude" -ne 0 ] && exit "$rc_claude"
exit "$rc_render"
