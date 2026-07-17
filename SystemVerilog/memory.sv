// move here bc if left in cpu, then we'd be instantianting so loading 32 private, identical copies of program which is not needed bc if threads are communicating w each other anything stored would be stored in their private memory rather than shared so these shared data semantics wouldn't work

    parameter int MEM_SIZE_BYTES = 65536,    // byte-addressable memory size (64 KiB)
    // INIT_FILE = the program this CPU runs (the .mem you flash). $readmemb resolves
    // this path against Vivado's RUN directory, not the source tree -- read the synth
    // log to confirm it was picked up; if not, use an absolute path. (A path Vivado
    // can't find loads memory as all-zero, so the CPU just runs nothing.)
    parameter     INIT_FILE      = "mems/test9.mem"


    // MEM_SIZE_BYTES - total size in bytes
    // /4 convert to words bc each memory location stores 4 bytes (32 bits)
    logic [31:0] mem [0:MEM_SIZE_BYTES/4-1];
    initial $readmemb(INIT_FILE, mem);