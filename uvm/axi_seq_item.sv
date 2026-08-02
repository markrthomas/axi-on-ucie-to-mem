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
