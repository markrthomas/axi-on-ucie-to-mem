// -----------------------------------------------------------------------------
// axi_monitor : records every completed AXI4-Lite transfer by watching the five
// channels, and broadcasts it on an analysis port — the SV analogue of the
// cocotb monitor_bfm + uvm_analysis_port.  Single-outstanding DUT, so one
// pending AW/W/AR is enough to correlate a response with its address.
// -----------------------------------------------------------------------------
class axi_monitor extends uvm_monitor;
    `uvm_component_utils(axi_monitor)

    virtual axi_lite_if vif;
    uvm_analysis_port #(axi_seq_item) ap;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db#(virtual axi_lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "no virtual interface set for axi_monitor")
    endfunction

    task run_phase(uvm_phase phase);
        axi_seq_item tr;
        bit [31:0]   aw_addr = '0, w_data = '0, ar_addr = '0;
        forever begin
            @(posedge vif.ACLK);
            if (vif.ARESETn !== 1'b1) continue;
            if (vif.AWVALID === 1'b1 && vif.AWREADY === 1'b1) aw_addr = vif.AWADDR;
            if (vif.WVALID  === 1'b1 && vif.WREADY  === 1'b1) w_data  = vif.WDATA;
            if (vif.BVALID  === 1'b1 && vif.BREADY  === 1'b1) begin
                tr = axi_seq_item::type_id::create("mon_w");
                tr.write = 1'b1; tr.addr = aw_addr; tr.data = w_data;
                tr.resp  = vif.BRESP;
                `uvm_info("MON", $sformatf("observed %s", tr.convert2string()),
                          UVM_MEDIUM)
                ap.write(tr);
            end
            if (vif.ARVALID === 1'b1 && vif.ARREADY === 1'b1) ar_addr = vif.ARADDR;
            if (vif.RVALID  === 1'b1 && vif.RREADY  === 1'b1) begin
                tr = axi_seq_item::type_id::create("mon_r");
                tr.write = 1'b0; tr.addr = ar_addr; tr.rdata = vif.RDATA;
                tr.resp  = vif.RRESP;
                `uvm_info("MON", $sformatf("observed %s", tr.convert2string()),
                          UVM_MEDIUM)
                ap.write(tr);
            end
        end
    endtask

endclass
