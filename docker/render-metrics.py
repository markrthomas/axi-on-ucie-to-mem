#!/usr/bin/env python3
"""Render a headless Claude Code run and summarize per-model usage.

Reads a `claude -p --output-format stream-json --verbose` event stream on stdin,
reproduces a human-readable (or machine) view on stdout, and prints a per-model
token/time metrics block on **stderr** at the end (so it never corrupts stdout).
The raw final `result` object is written to --json-out for CI to archive.

Why this exists: the ask is "token use and run time for each model at the end of
a run". Per-model token use comes from the result's `modelUsage` map (which,
unlike the top-level `usage` field, *includes subagents*). Per-model wall time is
NOT emitted by Claude Code — only whole-run duration/turns — so we report total
API time + turns + our own wall-clock and do not invent a per-model split. Cost
is a client-side estimate from Anthropic's price table (unreliable for Kimi).

Usage:
  claude -p … --output-format stream-json --verbose \
    | render-metrics.py --emit {text,json,stream-json} \
        [--provider NAME] [--json-out PATH] [--wall-start EPOCH_SECONDS]

Exit status mirrors the result: 0 on subtype "success", 1 otherwise / no result.
"""
import argparse
import json
import sys
import time


def _n(v):
    try:
        return f"{int(v):,}"
    except (TypeError, ValueError):
        return "0"


def _text_blocks(msg):
    """Yield text from an assistant message's content blocks."""
    inner = msg.get("message", msg)
    content = inner.get("content")
    if isinstance(content, str):
        yield content
        return
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                yield block.get("text", "")


def render_metrics(result, provider, wall_start):
    """Return the metrics block as a string (for stderr)."""
    mu = result.get("modelUsage") or {}
    lines = []
    label = f" (provider: {provider})" if provider else ""
    bar = "─" * 60
    lines.append(f"── run metrics{label} " + "─" * max(0, 44 - len(label)))
    if mu:
        name_w = max([len("model")] + [len(m) for m in mu])
        header = f"{'model'.ljust(name_w)}  {'in':>11}  {'out':>9}  {'cache':>9}  {'est.$*':>8}"
        lines.append(header)
        tot_in = tot_out = tot_cache = 0
        tot_cost = 0.0
        for model, u in mu.items():
            u = u or {}
            i = int(u.get("inputTokens", 0) or 0)
            o = int(u.get("outputTokens", 0) or 0)
            c = int(u.get("cacheReadInputTokens", 0) or 0) + int(u.get("cacheCreationInputTokens", 0) or 0)
            cost = float(u.get("costUSD", 0) or 0)
            tot_in += i; tot_out += o; tot_cache += c; tot_cost += cost
            cost_s = "—" if provider == "kimi" else f"{cost:.4f}"
            lines.append(f"{model.ljust(name_w)}  {_n(i):>11}  {_n(o):>9}  {_n(c):>9}  {cost_s:>8}")
        lines.append(bar)
        lines.append(f"{'total'.ljust(name_w)}  {_n(tot_in):>11}  {_n(tot_out):>9}  {_n(tot_cache):>9}")
    else:
        lines.append("(no per-model usage reported)")
        lines.append(bar)

    turns = result.get("num_turns", "?")
    api_ms = result.get("duration_api_ms")
    dur_ms = result.get("duration_ms")
    total_cost = result.get("total_cost_usd")
    parts = [f"turns {turns}"]
    if api_ms is not None:
        parts.append(f"API {api_ms / 1000:.1f}s")
    elif dur_ms is not None:
        parts.append(f"run {dur_ms / 1000:.1f}s")
    if wall_start:
        parts.append(f"wall {int(time.time() - wall_start)}s")
    if provider == "kimi":
        parts.append("est. cost $—")
    elif total_cost is not None:
        parts.append(f"est. cost ${float(total_cost):.4f}")
    lines.append(" · ".join(parts))
    lines.append("* cost is a client-side estimate from Anthropic's price table; "
                 "unreliable for non-Anthropic (Kimi) models — trust the token counts.")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emit", choices=["text", "json", "stream-json"], default="text")
    ap.add_argument("--provider", default="")
    ap.add_argument("--json-out", default="")
    ap.add_argument("--wall-start", type=float, default=0.0)
    ap.add_argument("--no-metrics", action="store_true")
    ap.add_argument("--result-file", default="",
                    help="format a saved result JSON to stdout instead of reading a stream")
    args = ap.parse_args()

    # Reuse mode: render the metrics block from a previously saved result (e.g. a
    # CI step summary) rather than a live event stream.
    if args.result_file:
        try:
            with open(args.result_file) as fh:
                result = json.load(fh)
        except (OSError, json.JSONDecodeError) as e:
            print(f"render-metrics: cannot read {args.result_file}: {e}", file=sys.stderr)
            return 1
        print(render_metrics(result, args.provider, args.wall_start))
        return 0

    result = None
    printed_text = False

    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        if args.emit == "stream-json":
            print(line, flush=True)
        try:
            evt = json.loads(line)
        except json.JSONDecodeError:
            continue
        etype = evt.get("type")
        if etype == "result":
            result = evt
        elif args.emit == "text" and etype == "assistant" and not evt.get("parent_tool_use_id"):
            for chunk in _text_blocks(evt):
                if chunk:
                    print(chunk, flush=True)
                    printed_text = True

    # Fallbacks for the final visible output.
    if result is not None:
        if args.emit == "json":
            print(json.dumps(result), flush=True)
        elif args.emit == "text" and not printed_text:
            print(result.get("result", ""), flush=True)
    elif args.emit == "text" and not printed_text:
        print("(no result returned by Claude Code)", flush=True)

    if args.json_out and result is not None:
        try:
            with open(args.json_out, "w") as fh:
                json.dump(result, fh, indent=2)
        except OSError as e:
            print(f"render-metrics: could not write {args.json_out}: {e}", file=sys.stderr)

    if not args.no_metrics and result is not None:
        print(render_metrics(result, args.provider, args.wall_start), file=sys.stderr)

    if result is None:
        return 1
    return 0 if result.get("subtype") == "success" else 1


if __name__ == "__main__":
    sys.exit(main())
