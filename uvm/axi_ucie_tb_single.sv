// -----------------------------------------------------------------------------
// axi_ucie_tb_single : single-file UVM testbench for axi_ucie_mem_top.
//
// Self-contained variant of the multi-file set (axi_lite_if + axi_pkg + classes
// + top + a bound axi_lite_sva checker) for drop-in use, e.g. EDA Playground.
// The two layouts define the SAME names — compile ONE or the other, never both.
//
// On EDA Playground: paste this into `testbench.sv`, and paste the CONCATENATED
// DUT RTL (rtl/aou_pkg.sv, ucie_stream_link.sv, axi_lite_mem.sv,
// aou_axi_initiator_bridge.sv, aou_axi_target_bridge.sv, axi_ucie_mem_top.sv,
// in that order) into `design.sv`.  Tick UVM 1.2 and set
// +UVM_TESTNAME=axi_write_read_test (or axi_random_test / axi_walking_test).
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

interface axi_lite_if #(
    parameter int AW = 32,
    parameter int DW = 32,
    parameter int SW = DW/8
) (
    input logic ACLK
);
    logic          ARESETn;
    // write address
    logic [AW-1:0] AWADDR;
    logic [2:0]    AWPROT;
    logic          AWVALID;
    logic          AWREADY;
    // write data
    logic [DW-1:0] WDATA;
    logic [SW-1:0] WSTRB;
    logic          WVALID;
    logic          WREADY;
    // write response
    logic [1:0]    BRESP;
    logic          BVALID;
    logic          BREADY;
    // read address
    logic [AW-1:0] ARADDR;
    logic [2:0]    ARPROT;
    logic          ARVALID;
    logic          ARREADY;
    // read data
    logic [DW-1:0] RDATA;
    logic [1:0]    RRESP;
    logic          RVALID;
    logic          RREADY;
endinterface

package axi_pkg;
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ==== axi_seq_item.sv ====
// -----------------------------------------------------------------------------
// axi_seq_item : one AXI4-Lite read or write transfer.
//
// Mirrors dv/cocotb/axi_seq_item.py:
//   * addr  — 32-bit byte address, word-aligned, inside the 64 KiB memory
//   * data  — 32-bit write payload (WDATA)
//   * write — 1 = write, 0 = read
//   * rdata — captured read data (RDATA), filled by the driver on reads
//   * resp  — captured BRESP / RRESP
// -----------------------------------------------------------------------------
class axi_seq_item extends uvm_sequence_item;

    rand bit [31:0] addr;
    rand bit [31:0] data;
    rand bit        write;
    bit [31:0]      rdata;
    bit [1:0]       resp;

    // 64 KiB memory (MEM_ADDR_W=16), word-aligned accesses.
    constraint c_addr { addr[1:0] == 2'b00; addr < 32'h0001_0000; }

    `uvm_object_utils_begin(axi_seq_item)
        `uvm_field_int(addr,  UVM_ALL_ON)
        `uvm_field_int(data,  UVM_ALL_ON)
        `uvm_field_int(write, UVM_ALL_ON)
        `uvm_field_int(rdata, UVM_ALL_ON)
        `uvm_field_int(resp,  UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axi_seq_item");
        super.new(name);
    endfunction

    function bit [31:0] payload();
        return write ? data : rdata;
    endfunction

    function string convert2string();
        return $sformatf("%s @0x%05X = 0x%08X",
                         write ? "WR" : "RD", addr, payload());
    endfunction

endclass

    // ==== axi_sequences.sv ====
// -----------------------------------------------------------------------------
// Stimulus sequences — one-for-one with dv/cocotb/axi_seq.py.
//
//   axi_write_read_seq : write a value, then read it back (32 pairs)
//   axi_random_seq     : random mix; reads biased 4:1 to written addrs (64 items)
//   axi_walking_seq    : directed first/last address and patterned payloads
// -----------------------------------------------------------------------------

// Write a value, then read it back from the same address.
class axi_write_read_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_write_read_seq)

    int unsigned num = 32;

    function new(string name = "axi_write_read_seq");
        super.new(name);
    endfunction

    task body();
        axi_seq_item wr, rd;
        for (int unsigned i = 0; i < num; i++) begin
            wr = axi_seq_item::type_id::create("wr");
            start_item(wr);
            if (!wr.randomize() with { write == 1'b1; })
                `uvm_error("RAND", "axi_seq_item randomize failed")
            finish_item(wr);

            rd = axi_seq_item::type_id::create("rd");
            start_item(rd);
            if (!rd.randomize() with { write == 1'b0; addr == wr.addr; })
                `uvm_error("RAND", "axi_seq_item randomize failed")
            finish_item(rd);
        end
    endtask
endclass


// Random mix; reads biased 4:1 toward already-written addresses.
class axi_random_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_random_seq)

    int unsigned num = 64;

    function new(string name = "axi_random_seq");
        super.new(name);
    endfunction

    task body();
        axi_seq_item item;
        bit [31:0]   written[$];
        for (int unsigned i = 0; i < num; i++) begin
            item = axi_seq_item::type_id::create("item");
            start_item(item);
            if (!item.randomize())
                `uvm_error("RAND", "axi_seq_item randomize failed")
            if (!item.write && written.size() > 0) begin
                bit        hit_written;
                int        idx;
                bit [31:0] target;
                if (!std::randomize(hit_written) with {
                        hit_written dist { 1 := 4, 0 := 1 }; })
                    `uvm_error("RAND", "bias randomize failed")
                if (hit_written) begin
                    if (!std::randomize(idx) with {
                            idx inside { [0:written.size()-1] }; })
                        `uvm_error("RAND", "index randomize failed")
                    target = written[idx];
                    if (!item.randomize() with { write == 1'b0; addr == target; })
                        `uvm_error("RAND", "axi_seq_item randomize failed")
                end
            end
            finish_item(item);
            if (item.write) written.push_back(item.addr);
        end
    endtask
endclass


// Directed edge cases: first/last address and patterned payloads.
class axi_walking_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_walking_seq)

    function new(string name = "axi_walking_seq");
        super.new(name);
    endfunction

    task body();
        axi_seq_item wr, rd;
        bit [31:0] edge_addrs[] = '{32'h0000_0000, 32'h0000_0004,
                                    32'h0000_FFF8, 32'h0000_FFFC};
        bit [31:0] edge_data[]  = '{32'h0000_0000, 32'h0000_0001, 32'h5555_5555,
                                    32'hAAAA_AAAA, 32'hFFFF_FFFF, 32'hDEAD_BEEF};
        foreach (edge_addrs[ai]) begin
            foreach (edge_data[di]) begin
                wr = axi_seq_item::type_id::create("wr");
                start_item(wr);
                wr.addr = edge_addrs[ai]; wr.data = edge_data[di];
                wr.write = 1'b1;
                finish_item(wr);

                rd = axi_seq_item::type_id::create("rd");
                start_item(rd);
                rd.addr = edge_addrs[ai]; rd.write = 1'b0;
                finish_item(rd);
            end
        end
    endtask
endclass

    // ==== axi_driver.sv ====
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

    // ==== axi_monitor.sv ====
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

    // ==== axi_agent.sv ====
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

    // ==== axi_scoreboard.sv ====
// -----------------------------------------------------------------------------
// axi_scoreboard : keeps a reference word memory and checks every read against
// the last write to that address — the SV analogue of dv/cocotb AxiScoreboard.
// Writes update the model; reads are checked (default 0 for a never-written
// location, matching the zero-initialised RTL array).  Response codes are
// checked to be OKAY.
// -----------------------------------------------------------------------------
class axi_scoreboard extends uvm_component;
    `uvm_component_utils(axi_scoreboard)

    uvm_analysis_imp #(axi_seq_item, axi_scoreboard) analysis_export;

    bit [31:0] model [bit [31:0]];   // reference memory (word-addressed)
    int        reads  = 0;
    int        errors = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        analysis_export = new("analysis_export", this);
    endfunction

    function void write(axi_seq_item tr);
        if (tr.resp !== 2'b00)
            `uvm_error("RESP", $sformatf("non-OKAY resp 0x%0h on %s",
                       tr.resp, tr.convert2string()))
        if (tr.write) begin
            model[tr.addr] = tr.data;
        end else begin
            bit [31:0] expected = model.exists(tr.addr) ? model[tr.addr] : 32'h0;
            reads++;
            if (tr.rdata !== expected) begin
                errors++;
                `uvm_error("MISMATCH", $sformatf(
                    "@0x%05X: got 0x%08X exp 0x%08X",
                    tr.addr, tr.rdata, expected))
            end else begin
                `uvm_info("MATCH", tr.convert2string(), UVM_MEDIUM)
            end
        end
    endfunction

    function void check_phase(uvm_phase phase);
        `uvm_info("SCOREBOARD", $sformatf(
            "%0d reads checked, %0d errors", reads, errors), UVM_LOW)
        if (errors != 0)
            `uvm_error("SCOREBOARD",
                $sformatf("%0d scoreboard mismatch(es)", errors))
    endfunction

endclass

    // ==== axi_env.sv ====
// -----------------------------------------------------------------------------
// axi_env : agent + scoreboard, with the monitor's analysis port wired to the
// scoreboard — matching dv/cocotb/axi_components.py AxiEnv.
// -----------------------------------------------------------------------------
class axi_env extends uvm_env;
    `uvm_component_utils(axi_env)

    axi_agent      agent;
    axi_scoreboard scoreboard;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        agent      = axi_agent::type_id::create("agent", this);
        scoreboard = axi_scoreboard::type_id::create("scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        agent.monitor.ap.connect(scoreboard.analysis_export);
    endfunction

endclass

    // ==== axi_test.sv ====
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

endpackage

module axi_lite_sva #(
    parameter int AW = 32,
    parameter int DW = 32,
    parameter int SW = DW/8
) (
    input logic          clk,
    input logic          rstn,
    input logic [AW-1:0] awaddr,  input logic awvalid, input logic awready,
    input logic [DW-1:0] wdata,   input logic [SW-1:0] wstrb,
                                  input logic wvalid,  input logic wready,
    input logic          bvalid,  input logic bready,
    input logic [AW-1:0] araddr,  input logic arvalid, input logic arready,
    input logic [DW-1:0] rdata,   input logic rvalid,  input logic rready
);

  // `disable iff (!rstn)` is inlined per property rather than via a module-level
  // `default disable iff` (the latter is unsupported by some Verilator 5.x).

  // --- VALID held until READY ------------------------------------------------
  property p_hold(valid, ready);
    @(posedge clk) disable iff (!rstn) (valid && !ready) |=> valid;
  endproperty
  a_aw_hold: assert property (p_hold(awvalid, awready));
  a_w_hold:  assert property (p_hold(wvalid,  wready));
  a_b_hold:  assert property (p_hold(bvalid,  bready));
  a_ar_hold: assert property (p_hold(arvalid, arready));
  a_r_hold:  assert property (p_hold(rvalid,  rready));

  // --- payload stable while stalled -----------------------------------------
  a_aw_stable: assert property (@(posedge clk) disable iff (!rstn)
    (awvalid && !awready) |=> $stable(awaddr));
  a_w_stable:  assert property (@(posedge clk) disable iff (!rstn)
    (wvalid && !wready) |=> ($stable(wdata) && $stable(wstrb)));
  a_ar_stable: assert property (@(posedge clk) disable iff (!rstn)
    (arvalid && !arready) |=> $stable(araddr));
  a_r_stable:  assert property (@(posedge clk) disable iff (!rstn)
    (rvalid && !rready) |=> $stable(rdata));

  // --- control signals known out of reset -----------------------------------
  a_known: assert property (@(posedge clk) disable iff (!rstn)
    !$isunknown({awvalid, wvalid, bvalid, arvalid, rvalid,
                 awready, wready, bready, arready, rready}));

endmodule
`endif

bind axi_ucie_mem_top axi_lite_sva u_axi_sva (
  .clk(ACLK), .rstn(ARESETn),
  .awaddr(AWADDR), .awvalid(AWVALID), .awready(AWREADY),
  .wdata(WDATA),   .wstrb(WSTRB), .wvalid(WVALID), .wready(WREADY),
  .bvalid(BVALID), .bready(BREADY),
  .araddr(ARADDR), .arvalid(ARVALID), .arready(ARREADY),
  .rdata(RDATA),   .rvalid(RVALID), .rready(RREADY)
);

module axi_ucie_tb_top;

    import uvm_pkg::*;
    import axi_pkg::*;
    `include "uvm_macros.svh"

    localparam int AW = 32, DW = 32, MEM_ADDR_W = 16;

    // 10 ns clock, matching the cocotb BFM's 10 ns period.
    logic ACLK = 1'b0;
    always #5 ACLK = ~ACLK;

    axi_lite_if #(.AW(AW), .DW(DW)) axi (.ACLK(ACLK));

    axi_ucie_mem_top #(
        .AXI_ADDR_W(AW), .AXI_DATA_W(DW), .MEM_ADDR_W(MEM_ADDR_W)
    ) dut (
        .ACLK(axi.ACLK), .ARESETn(axi.ARESETn),
        .AWADDR(axi.AWADDR), .AWPROT(axi.AWPROT), .AWVALID(axi.AWVALID), .AWREADY(axi.AWREADY),
        .WDATA(axi.WDATA),   .WSTRB(axi.WSTRB),   .WVALID(axi.WVALID),   .WREADY(axi.WREADY),
        .BRESP(axi.BRESP),   .BVALID(axi.BVALID), .BREADY(axi.BREADY),
        .ARADDR(axi.ARADDR), .ARPROT(axi.ARPROT), .ARVALID(axi.ARVALID), .ARREADY(axi.ARREADY),
        .RDATA(axi.RDATA),   .RRESP(axi.RRESP),   .RVALID(axi.RVALID),   .RREADY(axi.RREADY)
    );

    initial begin
        uvm_config_db#(virtual axi_lite_if)::set(null, "*", "vif", axi);
        // Default to the write-read test; +UVM_TESTNAME overrides it when given
        // (so it "just runs" on EDA Playground with no run-option set).
        run_test("axi_write_read_test");
    end

`ifdef DUMP
    initial begin
        $dumpfile("axi_ucie_tb_top.vcd");
        $dumpvars(0, axi_ucie_tb_top);
    end
`endif

endmodule
