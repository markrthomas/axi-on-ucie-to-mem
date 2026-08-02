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
