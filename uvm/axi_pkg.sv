// -----------------------------------------------------------------------------
// axi_pkg : bundles the UVM environment (sequence item, sequences, components,
// tests) into a single package.  Include order follows the dependency chain.
// The interface (axi_lite_if) lives outside the package, as interfaces must.
// -----------------------------------------------------------------------------
package axi_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    `include "axi_seq_item.sv"
    `include "axi_sequences.sv"
    `include "axi_driver.sv"
    `include "axi_monitor.sv"
    `include "axi_agent.sv"
    `include "axi_scoreboard.sv"
    `include "axi_env.sv"
    `include "axi_test.sv"

endpackage
