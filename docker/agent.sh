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
# --allowedTools, --add-dir, --output-format).  Tunables:
#   ANTHROPIC_API_KEY        (required) Console API key; -p always uses it.
#   CLAUDE_PERMISSION_MODE   default "dontAsk" (locked-down CI posture); set
#                            "acceptEdits" or pass --allowedTools for a worker
#                            that must edit files / run commands.
#   CLAUDE_OUTPUT_FORMAT     default "text"; "json" / "stream-json" for callers.
set -euo pipefail

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
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "agent: ANTHROPIC_API_KEY is not set — Claude Code cannot authenticate." >&2
  echo "       Inject it at run time (docker run -e ANTHROPIC_API_KEY=… / a Railway variable); never bake it into the image." >&2
  exit 3
fi

exec claude -p "$task" \
  --bare \
  --permission-mode "${CLAUDE_PERMISSION_MODE:-dontAsk}" \
  --output-format "${CLAUDE_OUTPUT_FORMAT:-text}" \
  "$@"
