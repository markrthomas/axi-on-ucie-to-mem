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
