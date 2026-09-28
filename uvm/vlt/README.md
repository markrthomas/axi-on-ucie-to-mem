# UVM on open-source Verilator (`uvm/vlt`)

Runs the AXI-Lite-over-UCIe (AoU) UVM environment under open-source **Verilator
5.050** (the first Verilator that can elaborate/run UVM) with the bundled
Accellera UVM 2020.3.1 library — a license-free path. The repo's `uvm/Makefile`
otherwise needs VCS/Xcelium/Questa and degrades to a skip without one.

## Prerequisites
- **Verilator >= 5.050, UVM-capable** (OSS CAD Suite's is not). Local ref:
  `~/verilator/bin/verilator`.
- **`unset VERILATOR_ROOT`** after sourcing the OSS CAD Suite env.
- **`UVM_HOME`** = `~/verilator/test_regress/t/uvm`.

## Usage
```sh
V=~/verilator/bin/verilator ; U=~/verilator/test_regress/t/uvm
( unset VERILATOR_ROOT; make -C uvm/vlt lint       VERILATOR=$V UVM_HOME=$U )  # RAM-safe (~300 MB)
( unset VERILATOR_ROOT; make -C uvm/vlt write_read  VERILATOR=$V UVM_HOME=$U )  # build + run
```
Targets: `lint`; `write_read` (default), `random`, `walking`, `all`; `clean`.

Each run is **gated**: it tees `obj/<test>.log` and prints
`[UVM-VLT] PASS: <test>` only if `UVM_ERROR : 0`, `UVM_FATAL : 0` and the
scoreboard reports `0 errors`; otherwise `[UVM-VLT] FAIL` and a non-zero exit.
Default `UVM_PLUSARGS` include `+UVM_TIMEOUT=2000000,NO` (2 ms). The value is
a bare integer in ns; a unit suffix like `2000us` is silently read as `2000`.

Result (Verilator 5.050): `write_read` 32 reads / 0 errors, `random` 35 / 0,
`walking` 24 / 0.
Top `axi_ucie_tb_top`; one `--binary` build serves all tests (`+UVM_TESTNAME`).

## RAM note — build in CI, not on a small box
`--lint-only` is cheap (~300 MB); the `--binary` build (large generated C++)
OOMs a RAM-constrained host. CI (`.github/workflows/verilator-uvm.yml`) builds
Verilator 5.050 from source and runs lint + `write_read` on a GitHub runner.

## `uvm_macros.svh`
Required tracked empty include-shim (the monolithic UVM header defines the
macros). Do not delete.
