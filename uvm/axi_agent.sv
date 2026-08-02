// -----------------------------------------------------------------------------
// axi_agent : sequencer + driver + monitor (active agent), matching
// dv/cocotb/axi_components.py AxiAgent.
// -----------------------------------------------------------------------------
typedef uvm_sequencer #(axi_seq_item) axi_sequencer;

class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)

    axi_sequencer seqr;
    axi_driver    driver;
    axi_monitor   monitor;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        seqr    = axi_sequencer::type_id::create("seqr", this);
        driver  = axi_driver::type_id::create("driver", this);
        monitor = axi_monitor::type_id::create("monitor", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        driver.seq_item_port.connect(seqr.seq_item_export);
    endfunction

endclass
