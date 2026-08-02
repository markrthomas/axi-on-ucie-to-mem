// -----------------------------------------------------------------------------
// Tests — one-for-one with dv/cocotb/axi_test.py.
//
//   axi_base_test    : builds the env, drives reset, runs a sequence
//   axi_write_read_test / axi_random_test / axi_walking_test : pick the sequence
//
// The clock runs in the top module; the base test owns reset (ARESETn pulse)
// via the virtual interface, exactly as the cocotb BFM.reset() did.
// -----------------------------------------------------------------------------
class axi_base_test extends uvm_test;
    `uvm_component_utils(axi_base_test)

    axi_env             env;
    virtual axi_lite_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        env = axi_env::type_id::create("env", this);
        if (!uvm_config_db#(virtual axi_lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "no virtual interface set for axi_base_test")
    endfunction

    virtual function uvm_sequence #(axi_seq_item) create_seq();
        axi_write_read_seq seq = axi_write_read_seq::type_id::create("seq");
        return seq;
    endfunction

    task reset();
        vif.ARESETn <= 1'b0;
        vif.AWVALID <= 1'b0; vif.WVALID  <= 1'b0; vif.ARVALID <= 1'b0;
        vif.BREADY  <= 1'b0; vif.RREADY  <= 1'b0;
        vif.AWADDR  <= '0;   vif.AWPROT  <= '0;
        vif.WDATA   <= '0;   vif.WSTRB   <= '0;
        vif.ARADDR  <= '0;   vif.ARPROT  <= '0;
        repeat (3) @(posedge vif.ACLK);
        @(negedge vif.ACLK);
        vif.ARESETn <= 1'b1;
        @(posedge vif.ACLK);
    endtask

    task run_phase(uvm_phase phase);
        uvm_sequence #(axi_seq_item) seq;
        phase.raise_objection(this);
        reset();
        seq = create_seq();
        seq.start(env.agent.seqr);
        phase.drop_objection(this);
    endtask

endclass


class axi_write_read_test extends axi_base_test;
    `uvm_component_utils(axi_write_read_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function uvm_sequence #(axi_seq_item) create_seq();
        axi_write_read_seq seq = axi_write_read_seq::type_id::create("seq");
        return seq;
    endfunction
endclass


class axi_random_test extends axi_base_test;
    `uvm_component_utils(axi_random_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function uvm_sequence #(axi_seq_item) create_seq();
        axi_random_seq seq = axi_random_seq::type_id::create("seq");
        return seq;
    endfunction
endclass


class axi_walking_test extends axi_base_test;
    `uvm_component_utils(axi_walking_test)
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction
    virtual function uvm_sequence #(axi_seq_item) create_seq();
        axi_walking_seq seq = axi_walking_seq::type_id::create("seq");
        return seq;
    endfunction
endclass
