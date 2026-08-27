#!/usr/bin/env python3
"""Prefix every stdin line with "[+SSSS.mmm] " (seconds since this filter began).

Used by metrics/capture.sh so metrics/collect.py can derive per-step wall time
from a gate log.  Deliberately a pure stdin->stdout filter: it adds no work to
the wrapped process and, unlike `stdbuf`, LD_PRELOADs nothing into the pinned
oss-cad-suite tools (see CLAUDE.md, "Never stdbuf/unbuffer the gate").

Byte-oriented on purpose.  A gate log carries whatever the tools emit -- an
invalid UTF-8 byte from a simulator would abort a text-mode filter and take the
gate's log (and, through pipefail, the gate) with it.  Bytes in, bytes out.

Timestamps are when this filter READ the line, which for the block-buffered C
tools is when their stdout was FLUSHED, not when they printed.  collect.py
records every number derived from these as `estimated` and says so.
"""
import sys
import time


def main():
    t0 = time.monotonic()
    src = sys.stdin.buffer
    dst = sys.stdout.buffer
    for line in src:
        dst.write(("[+%08.3f] " % (time.monotonic() - t0)).encode("ascii"))
        dst.write(line)
        dst.flush()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (BrokenPipeError, KeyboardInterrupt):
        sys.exit(0)
