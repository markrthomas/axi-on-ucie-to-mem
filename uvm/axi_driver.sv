// -----------------------------------------------------------------------------
// axi_driver : serialises sequence items onto the AXI4-Lite bus, one transfer at
// a time, and writes captured RDATA/response back into the item.
//
// Timing mirrors the cocotb BFM (dv/cocotb/axi_lite_bfm.py): requests are driven
// on the falling edge so the DUT samples clean values on the rising edge.  The
// DUT asserts AWREADY and WREADY together in its idle state, so AW and W are
// issued together and both readies are awaited on the same cycle; BREADY/RREADY
// are held high for the response.
// -----------------------------------------------------------------------------
class axi_driver extends uvm_driver #(axi_seq_item);
    `uvm_component_utils(axi_driver)

    virtual axi_lite_if vif;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi_lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "no virtual interface set for axi_driver")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);
            drive_transfer(req);
            seq_item_port.item_done();
        end
    endtask

    task automatic drive_transfer(axi_seq_item item);
        if (item.write) drive_write(item);
        else            drive_read(item);
    endtask

    task automatic drive_write(axi_seq_item item);
        @(negedge vif.ACLK);
        vif.AWADDR  <= item.addr; vif.AWPROT <= 3'b000; vif.AWVALID <= 1'b1;
        vif.WDATA   <= item.data; vif.WSTRB  <= '1;     vif.WVALID  <= 1'b1;
        vif.BREADY  <= 1'b1;
        @(posedge vif.ACLK);
        while (!(vif.AWREADY === 1'b1 && vif.WREADY === 1'b1))
            @(posedge vif.ACLK);
        @(negedge vif.ACLK);
        vif.AWVALID <= 1'b0; vif.WVALID <= 1'b0;
        @(posedge vif.ACLK);
        while (vif.BVALID !== 1'b1) @(posedge vif.ACLK);
        item.resp = vif.BRESP;
        @(negedge vif.ACLK);
        vif.BREADY <= 1'b0;
    endtask

    task automatic drive_read(axi_seq_item item);
        @(negedge vif.ACLK);
        vif.ARADDR  <= item.addr; vif.ARPROT <= 3'b000; vif.ARVALID <= 1'b1;
        vif.RREADY  <= 1'b1;
        @(posedge vif.ACLK);
        while (vif.ARREADY !== 1'b1) @(posedge vif.ACLK);
        @(negedge vif.ACLK);
        vif.ARVALID <= 1'b0;
        @(posedge vif.ACLK);
        while (vif.RVALID !== 1'b1) @(posedge vif.ACLK);
        item.rdata = vif.RDATA;
        item.resp  = vif.RRESP;
        @(negedge vif.ACLK);
        vif.RREADY <= 1'b0;
    endtask

endclass
