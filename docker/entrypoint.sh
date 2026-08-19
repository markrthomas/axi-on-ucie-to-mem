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

if [ "$#" -eq 0 ]; then
  exec make ci "${VLT_ARGS[@]}"
elif [ "$1" = "make" ]; then
  shift
  exec make "$@" "${VLT_ARGS[@]}"
else
  exec "$@"
fi
