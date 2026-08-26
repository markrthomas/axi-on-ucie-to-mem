// -----------------------------------------------------------------------------
// aou_wave_dump.svh — shared, DEV-ONLY waveform dump hook for the SV testbenches.
//
// `include`d by dv/sv, dv/ooo, dv/mrp and dv/act.  The whole body sits inside
// `ifdef AOU_WAVES, which NOTHING on the gate path defines: `make check` /
// `regress` / `ci` compile these testbenches without -DAOU_WAVES, so not one
// statement below is elaborated and every env's stdout stays byte-identical.
// Only the interactive `make waves-<env>` / `make wave-<env>` flows define it.
//
// The dump file name comes from -DAOU_WAVE_FILE=<"path"> (the per-env Makefile
// passes it); the default keeps a direct `iverilog -DAOU_WAVES` invocation
// working.  Under Icarus the FST writer is selected at RUN time by passing
// `-fst` to vvp (the per-env Makefile does that too); without it the same hook
// writes a VCD of the same base name, which GTKWave also opens.
//
// $dumpvars(0) (all scopes, full depth) is deliberate: the .gtkw layouts in
// dv/waves/ reference DUT internals several levels down, and a dump that is
// missing them would open with empty traces.
// -----------------------------------------------------------------------------
`ifdef AOU_WAVES
  `ifndef AOU_WAVE_FILE
    `define AOU_WAVE_FILE "sim_build/waves.fst"
  `endif
  initial begin : aou_wave_dump
    $dumpfile(`AOU_WAVE_FILE);
    $dumpvars(0);
  end
`endif
