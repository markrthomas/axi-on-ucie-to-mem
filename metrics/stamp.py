#!/usr/bin/env python3
"""Prefix every stdin line with "[+SS.mmm] " (seconds since this filter started).

Used by metrics/capture.sh so metrics/collect.py can derive per-step wall time
from a gate log.  Deliberately a pure stdin->stdout filter: it adds no work to
the wrapped process and, unlike `stdbuf`, LD_PRELOADs nothing into the pinned
oss-cad-suite tools (see CLAUDE.md, "Never stdbuf/unbuffer the gate").

Timestamps are when this filter READ the line, which for the block-buffered C
tools is when their stdout was flushed, not when they printed.  collect.py
records every number derived from these as `estimated` and says so.
"""
import sys
import time


def main():
    t0 = time.monotonic()
    out = sys.stdout
    for line in sys.stdin:
        out.write("[+%08.3f] %s" % (time.monotonic() - t0, line))
        out.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
