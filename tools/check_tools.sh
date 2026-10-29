#!/usr/bin/env bash
# =============================================================================
# check_tools.sh — verify (and optionally install) the DV toolchain for an
# RTL/DV bridge repo in this workspace. Canonical copy lives in the `dv-toolchain`
# skill; vendored into each repo as tools/check_tools.sh and driven by its Makefile:
#
#   make tools          verify every tier, then apt/pip-install what is MISSING
#   make tools-check    verify only, install nothing (CI / dry-run friendly)
#   make tools TOOLS_HEAVY=1   also build the from-source UVM Verilator (slow)
#
# Version pins come from dv_env.mk (workspace root) when present, else the
# built-in defaults below. The repo's Dockerfile remains the buildable source of
# truth; this script audits a local/CI environment against the shared pins.
#
# Tiers:
#   core     required for lint / sim / cocotb  -> iverilog, python3, cocotb (apt+pip)
#   formal   `make formal` (post-gate)         -> yosys(+slang), sby, a solver
#   waves    `make wave*`  (off-gate)          -> gtkwave
#   heavy    UVM `--binary` (CI/Railway)       -> Verilator >= MIN from source
#
# Missing OPTIONAL tools never fail --check; only missing CORE tools do, so CI can
# gate on `make tools-check`.
# =============================================================================
set -uo pipefail

CHECK_ONLY=0
DO_HEAVY=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --heavy) DO_HEAVY=1 ;;
    -h|--help) grep -E '^#( |=|$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check_tools.sh: unknown arg '$a'" >&2; exit 2 ;;
  esac
done

# ---- pins (from dv_env.mk if found, else defaults) --------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DV_ENV_MK="${DV_ENV_MK:-}"
if [ -z "$DV_ENV_MK" ]; then
  for c in "$SCRIPT_DIR/../dv_env.mk" "$SCRIPT_DIR/../../dv_env.mk" "$PWD/dv_env.mk" "$PWD/../dv_env.mk"; do
    [ -f "$c" ] && { DV_ENV_MK="$c"; break; }
  done
fi
pinval() { [ -n "$DV_ENV_MK" ] && grep -m1 "^$1" "$DV_ENV_MK" 2>/dev/null | grep -oP '(?<=\?=).*' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }
VERILATOR_MIN="$(pinval VERILATOR_MIN)";       VERILATOR_MIN="${VERILATOR_MIN:-5.030}"
VERILATOR_VERSION="$(pinval VERILATOR_VERSION)"; VERILATOR_VERSION="${VERILATOR_VERSION:-5.050}"
ICARUS_MIN="$(pinval ICARUS_MIN)";             ICARUS_MIN="${ICARUS_MIN:-12}"
YICES_VERSION="$(pinval YICES_VERSION)";       YICES_VERSION="${YICES_VERSION:-2.6.5}"

# ---- probes -----------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }
have_py()  { python3 -c "import $1" >/dev/null 2>&1; }
have_apt=0; have_cmd apt-get && have_apt=1
if [ "$(id -u)" -eq 0 ]; then SUDO=""; elif have_cmd sudo; then SUDO="sudo"; else SUDO=""; fi

CORE_MISSING=0
RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
[ -t 1 ] || { RED=""; GRN=""; YEL=""; RST=""; }
ok()   { echo "  ${GRN}[ok]${RST}    $*"; }
miss() { echo "  ${YEL}[miss]${RST}  $*"; }
bad()  { echo "  ${RED}[CORE]${RST}  $*"; CORE_MISSING=1; }

vernum() { echo "${1:-0}" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1; }
ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

apt_install() { [ "$CHECK_ONLY" -eq 1 ] && return 0; [ "$have_apt" -eq 1 ] || { echo "       (no apt; install manually: $*)"; return 0; }; echo "       installing: $*"; $SUDO apt-get install -y -q "$@" >/dev/null 2>&1 || echo "       apt install failed for: $*"; }
pip_install() { [ "$CHECK_ONLY" -eq 1 ] && return 0; echo "       installing (pip): $*"; python3 -m pip install --user -q "$@" >/dev/null 2>&1 || echo "       pip install failed for: $*"; }

echo "DV toolchain check — pins from ${DV_ENV_MK:-<defaults>}"
echo "  (verilator>=$VERILATOR_MIN, icarus>=$ICARUS_MIN, yices $YICES_VERSION)"

echo ""; echo "core:"
if have_cmd iverilog; then
  v="$(vernum "$(iverilog -V 2>&1 | head -1)")"
  if ge "$v" "$ICARUS_MIN"; then ok "iverilog $v"; else bad "iverilog $v < $ICARUS_MIN (need >= $ICARUS_MIN; apt on Ubuntu 24.04)"; fi
else bad "iverilog not found"; apt_install iverilog; fi
if have_cmd python3; then ok "python3 $(python3 -V 2>&1 | awk '{print $2}')"; else bad "python3 not found"; apt_install python3 python3-pip; fi
if have_py cocotb; then ok "cocotb $(python3 -c 'import cocotb;print(cocotb.__version__)' 2>/dev/null)"; else bad "cocotb (python) not found"; pip_install cocotb; fi
if have_py pyuvm; then ok "pyuvm present"; else miss "pyuvm (python) not found"; pip_install pyuvm; fi

echo ""; echo "formal (optional — make formal):"
if have_cmd yosys; then
  if yosys -p 'help read_slang' >/dev/null 2>&1; then ok "yosys (native slang)"; else miss "yosys present but no read_slang (build Yosys with slang for make formal)"; fi
else miss "yosys not found (build from source with native slang — see docs/TOOLCHAIN.md)"; fi
have_cmd sby && ok "sby present" || miss "sby not found (SymbiYosys — pip/source)"
if have_cmd yices || have_cmd yices-smt2; then ok "yices present"
elif have_cmd btormc; then ok "btormc present (Boolector — used by the AoU formal flow)"
elif have_cmd z3; then ok "z3 present (yices $YICES_VERSION preferred; z3 can OOM on deep covers)"
else miss "no formal solver (yices/btormc preferred, or z3)"; apt_install z3; fi

echo ""; echo "waves (optional — make wave*):"
have_cmd gtkwave && ok "gtkwave present" || { miss "gtkwave not found"; apt_install gtkwave; }

echo ""; echo "systemc (optional — make systemc):"
if [ -f /usr/include/systemc.h ] || [ -n "${SYSTEMC_HOME:-}" ]; then ok "SystemC headers present"; else miss "SystemC not found"; apt_install libsystemc-dev; fi

echo ""; echo "heavy (optional — UVM --binary; CI/Railway/TOOLS_HEAVY=1):"
if have_cmd verilator; then
  v="$(vernum "$(verilator --version 2>&1)")"
  if ge "$v" "$VERILATOR_MIN"; then ok "verilator $v (UVM-capable)"; else miss "verilator $v < $VERILATOR_MIN — UVM --binary needs a from-source build"; fi
else
  miss "verilator not found"
  if [ "$DO_HEAVY" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
    echo "       build: git clone -b v$VERILATOR_VERSION https://github.com/verilator/verilator && autoconf && ./configure --prefix=\$HOME/.local && make -j2 && make install"
  else
    echo "       (opt-in: make tools TOOLS_HEAVY=1, or build v$VERILATOR_VERSION from source; never set VERILATOR_ROOT)"
  fi
fi

echo ""
if [ "$CORE_MISSING" -eq 1 ]; then
  echo "${RED}[tools] core tool(s) missing.${RST}"; [ "$CHECK_ONLY" -eq 1 ] && exit 1 || exit 0
else
  echo "${GRN}[tools] core toolchain present.${RST}"; exit 0
fi
