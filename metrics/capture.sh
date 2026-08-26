#!/usr/bin/env bash
# metrics/capture.sh — run a command and leave the artifacts metrics/collect.py
# reads.  Nothing here changes what the wrapped command DOES; it only observes
# it from the outside:
#
#   * /usr/bin/time -v      -> metrics/_capture/<label>.time  (wall, user+sys,
#                              peak RSS, %CPU — a measured, un-perturbing wrap)
#   * a timestamped tee     -> metrics/_capture/<label>.log   (every line
#                              prefixed "[+SS.mmm] " so collect.py can derive
#                              per-step wall time)
#
# The gate itself is untouched: no LD_PRELOAD, no stdbuf (see CLAUDE.md — the
# system libstdbuf.so clashes with oss-cad-suite's bundled glibc and kills
# `make lint`), no extra work inside any timed DV run.  The one caveat, recorded
# in the DB with every derived number: the C tools block-buffer when stdout is a
# pipe, so a banner's timestamp is when it was FLUSHED.  Totals from
# /usr/bin/time are exact; the per-step split is an estimate.
#
# Usage:
#   metrics/capture.sh <label> <command> [args...]
#
#   metrics/capture.sh gate make ci VERILATOR=... VERILATOR_ROOT=... SBY=...
#   metrics/capture.sh env-ooo make ooo VERILATOR=...
#
# Exit status is the wrapped command's.  AOU_CAPTURE_DIR overrides the output
# directory.
set -uo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: metrics/capture.sh <label> <command> [args...]" >&2
  exit 2
fi

label="$1"; shift
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cap="${AOU_CAPTURE_DIR:-$here/_capture}"
mkdir -p "$cap"

log="$cap/${label}.log"
tim="$cap/${label}.time"

echo "[METRICS] capturing '$label': $*" >&2

# `command -v` so a host without GNU time still runs the command (the timing
# rows then come back as not_attributable instead of the run failing).
if command -v /usr/bin/time >/dev/null 2>&1; then
  /usr/bin/time -v -o "$tim" "$@" 2>&1 \
    | python3 -u "$here/stamp.py" \
    | tee "$log"
else
  echo "[METRICS] note: /usr/bin/time not found — no wall/RSS capture for '$label'" >&2
  rm -f "$tim"
  "$@" 2>&1 | python3 -u "$here/stamp.py" | tee "$log"
fi

rc=("${PIPESTATUS[@]}")
echo "[METRICS] '$label' exited ${rc[0]} — artifacts: $log $( [ -f "$tim" ] && echo "$tim" )" >&2
exit "${rc[0]}"
