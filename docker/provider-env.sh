# shellcheck shell=bash
# Resolve the model provider for a headless Claude Code run.  This file is
# *sourced* by docker/agent.sh and docker/swarm.sh (do not exec it).
#
# AOU_MODEL_PROVIDER selects which vendor the agents' `opus`/`sonnet` tier
# aliases resolve to for the WHOLE run (Claude Code's provider is process-wide —
# one provider per run):
#
#   anthropic  (default)  Claude via ANTHROPIC_API_KEY (as before).
#   kimi                  Kimi K3 & friends via Moonshot's Anthropic-compatible
#                         endpoint.  Requires KIMI_API_KEY.  The tier aliases are
#                         remapped to concrete Kimi models so each agent's
#                         `model:` frontmatter keeps working with no edit.
#
# aou_resolve_provider sets AOU_PROVIDER (normalized, for the metrics label) and
# returns non-zero if the key for the selected provider is missing.

aou_resolve_provider() {
  # Defensive: strip ALL whitespace/newlines from pasted API keys.  A trailing
  # newline or leading space (common when copying a secret into a GitHub/Railway
  # field) survives into the env var and makes an otherwise-valid key fail with
  # "401 API key is invalid".  Anthropic/Moonshot keys never contain whitespace,
  # so removing it is safe.
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    ANTHROPIC_API_KEY="$(printf '%s' "$ANTHROPIC_API_KEY" | tr -d '[:space:]')"; export ANTHROPIC_API_KEY
  fi
  if [ -n "${KIMI_API_KEY:-}" ]; then
    KIMI_API_KEY="$(printf '%s' "$KIMI_API_KEY" | tr -d '[:space:]')"; export KIMI_API_KEY
  fi
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(printf '%s' "$CLAUDE_CODE_OAUTH_TOKEN" | tr -d '[:space:]')"; export CLAUDE_CODE_OAUTH_TOKEN
  fi
  # Common mistake: a subscription OAuth token (from `claude setup-token`, prefix
  # sk-ant-oat…) pasted into ANTHROPIC_API_KEY.  That token is rejected by the
  # Messages API (401) — it only works via CLAUDE_CODE_OAUTH_TOKEN.  Reroute it.
  case "${ANTHROPIC_API_KEY:-}" in
    sk-ant-oat*)
      CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-$ANTHROPIC_API_KEY}"; export CLAUDE_CODE_OAUTH_TOKEN
      unset ANTHROPIC_API_KEY
      echo "provider(anthropic): ANTHROPIC_API_KEY held an OAuth token (sk-ant-oat…) — rerouting to CLAUDE_CODE_OAUTH_TOKEN." >&2
      ;;
  esac

  AOU_PROVIDER="${AOU_MODEL_PROVIDER:-anthropic}"
  case "$AOU_PROVIDER" in
    anthropic)
      # Two credential types are accepted, in Claude Code's own priority order:
      #   ANTHROPIC_API_KEY        Console API key (sk-ant-api…), bills per token.
      #   CLAUDE_CODE_OAUTH_TOKEN  subscription token (sk-ant-oat…, from
      #                            `claude setup-token`), uses a Pro/Max/Team plan.
      if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        AOU_AUTH=apikey
        echo "provider: anthropic (Console API key)" >&2
      elif [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        AOU_AUTH=oauth
        # Drop anything that would outrank the OAuth token in Claude Code's auth
        # order (an empty ANTHROPIC_API_KEY exported by CI, or an auth token).
        unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN 2>/dev/null || true
        echo "provider: anthropic (subscription OAuth token)" >&2
      else
        echo "provider(anthropic): no credential set — Claude Code cannot authenticate." >&2
        echo "  Set ANTHROPIC_API_KEY (Console key, sk-ant-api…) OR CLAUDE_CODE_OAUTH_TOKEN" >&2
        echo "  (subscription token from 'claude setup-token', sk-ant-oat…)." >&2
        echo "  (Or run on Kimi: AOU_MODEL_PROVIDER=kimi with KIMI_API_KEY.)" >&2
        return 3
      fi
      export AOU_AUTH
      # Pin the "best set" of Anthropic models to the tier aliases the agents use,
      # so the selection is deterministic instead of drifting with the account
      # default.  Override any with ANTHROPIC_{OPUS,SONNET,HAIKU}_MODEL (e.g. use
      # claude-fable-5 for the manager tier if you want maximum capability).
      #   opus   -> claude-opus-5   : manager + whole-suite dv-runner (deep agentic
      #                               reasoning, code fixes, git/PR).
      #   sonnet -> claude-sonnet-5 : infra-agent (strong, cheap coding for the
      #                               well-scoped Dockerfile/CI/script edits).
      #   haiku  -> claude-haiku-4-5: dv-env-testers (fast/cheap, they fan out in
      #                               parallel and just run+report; the manager
      #                               re-runs the full gate itself as the backstop).
      export ANTHROPIC_DEFAULT_OPUS_MODEL="${ANTHROPIC_OPUS_MODEL:-claude-opus-5}"
      export ANTHROPIC_DEFAULT_SONNET_MODEL="${ANTHROPIC_SONNET_MODEL:-claude-sonnet-5}"
      export ANTHROPIC_DEFAULT_HAIKU_MODEL="${ANTHROPIC_HAIKU_MODEL:-claude-haiku-4-5}"
      echo "provider: anthropic (opus=${ANTHROPIC_DEFAULT_OPUS_MODEL}, sonnet=${ANTHROPIC_DEFAULT_SONNET_MODEL}, haiku=${ANTHROPIC_DEFAULT_HAIKU_MODEL})" >&2
      ;;
    kimi)
      if [ -z "${KIMI_API_KEY:-}" ]; then
        echo "provider(kimi): KIMI_API_KEY is not set — cannot authenticate to Moonshot." >&2
        echo "  Get a key at https://platform.kimi.ai and inject it at run time; never bake it into the image." >&2
        return 3
      fi
      # Point Claude Code at Moonshot's Anthropic-compatible endpoint.
      export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-https://api.moonshot.ai/anthropic}"
      export ANTHROPIC_AUTH_TOKEN="$KIMI_API_KEY"
      # A stray ANTHROPIC_API_KEY outranks ANTHROPIC_AUTH_TOKEN and would send the
      # run back to Anthropic's endpoint — drop it so kimi mode is unambiguous.
      unset ANTHROPIC_API_KEY
      # Remap the tier aliases the agents use to concrete Kimi models.
      export ANTHROPIC_DEFAULT_OPUS_MODEL="${KIMI_OPUS_MODEL:-kimi-k3}"
      export ANTHROPIC_DEFAULT_SONNET_MODEL="${KIMI_SONNET_MODEL:-kimi-k2.7-code}"
      export ANTHROPIC_DEFAULT_HAIKU_MODEL="${KIMI_HAIKU_MODEL:-kimi-k2.7-code-highspeed}"
      echo "provider: kimi -> ${ANTHROPIC_BASE_URL}" >&2
      echo "  aliases: opus=${ANTHROPIC_DEFAULT_OPUS_MODEL} sonnet=${ANTHROPIC_DEFAULT_SONNET_MODEL} haiku=${ANTHROPIC_DEFAULT_HAIKU_MODEL}" >&2
      echo "  ⚠  COMPLIANCE/IP CAUTION: this run sends your repo contents (RTL/DV, diffs," >&2
      echo "     prompts) to Moonshot, a China-based provider that (as of Aug 2026) is under" >&2
      echo "     active US BIS investigation with Entity-List designation threatened and IP-theft" >&2
      echo "     allegations. Do NOT enable kimi for proprietary/export-sensitive IP; verify" >&2
      echo "     Moonshot is not on the Entity List / SDN list first, and consult export counsel." >&2
      echo "     See docs/DOCKER.md → 'Compliance & IP risk'. Default is provider=anthropic." >&2
      AOU_AUTH=kimi; export AOU_AUTH
      ;;
    *)
      echo "provider: unknown AOU_MODEL_PROVIDER='$AOU_PROVIDER' (want 'anthropic' or 'kimi')." >&2
      return 4
      ;;
  esac
  return 0
}
