// =====================================================================
// tb_cache.v - Testbench for the direct-mapped cache controller
// =====================================================================
// Drives four access patterns and reports hit/miss stats + AMAT:
//   1. SEQUENTIAL : walk ascending addresses (spatial locality)
//   2. REPEATED   : small working set hit over and over (temporal)
//   3. RANDOM     : pseudo-random addresses (poor locality)
//   4. CONFLICT   : alternate blocks that map to the same cache line
//
// Self-contained: traces generated in-TB, no external files.
// =====================================================================
`include "cache_defs.vh"
`timescale 1ns/1ps

module tb_cache;

    // ---- AMAT model parameters ----
    localparam integer HIT_TIME     = 1;    // cycles for a hit
    localparam integer MISS_PENALTY = 10;   // = main_memory MEM_LATENCY

    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;                    // 100 MHz

    // CPU <-> cache
    reg  [`ADDR_WIDTH-1:0] cpu_addr;
    reg                    cpu_req;
    wire                   cpu_ready;
    wire [31:0]            cpu_rdata;
    wire                   hit_flag;

    // cache <-> memory
    wire                    mem_req;
    wire [`ADDR_WIDTH-1:0]  mem_addr;
    wire                    mem_ready;
    wire [`BLOCK_BITS-1:0]  mem_rdata;

    // stats
    wire [31:0] stat_accesses, stat_hits, stat_misses;

    // ---- DUT ----
    cache_controller u_cache (
        .clk(clk), .rst_n(rst_n),
        .cpu_req(cpu_req), .cpu_addr(cpu_addr),
        .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata), .hit_flag(hit_flag),
        .mem_req(mem_req), .mem_addr(mem_addr),
        .mem_ready(mem_ready), .mem_rdata(mem_rdata),
        .stat_accesses(stat_accesses), .stat_hits(stat_hits), .stat_misses(stat_misses)
    );

    main_memory #(.MEM_LATENCY(MISS_PENALTY)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .req(mem_req), .addr(mem_addr),
        .ready(mem_ready), .rdata(mem_rdata)
    );

    // ----------------------------------------------------------------
    // Task: issue one CPU read, block until cache responds
    // ----------------------------------------------------------------
    task do_access(input [`ADDR_WIDTH-1:0] a);
        begin
            @(posedge clk);
            cpu_addr <= a;
            cpu_req  <= 1'b1;
            @(posedge clk);
            cpu_req  <= 1'b0;
            // wait for completion
            wait (cpu_ready == 1'b1);
            @(posedge clk);
        end
    endtask

    // Snapshot helpers to report per-phase stats
    reg [31:0] base_acc, base_hit, base_miss;
    task phase_begin;
        begin
            base_acc  = stat_accesses;
            base_hit  = stat_hits;
            base_miss = stat_misses;
        end
    endtask

    task phase_report(input [8*16-1:0] name);
        reg [31:0] acc, hit, miss;
        real hit_ratio, miss_ratio, amat;
        begin
            acc  = stat_accesses - base_acc;
            hit  = stat_hits     - base_hit;
            miss = stat_misses   - base_miss;
            hit_ratio  = (acc == 0) ? 0.0 : (hit  * 1.0) / acc;
            miss_ratio = (acc == 0) ? 0.0 : (miss * 1.0) / acc;
            amat = HIT_TIME + miss_ratio * MISS_PENALTY;
            $display("---------------------------------------------");
            $display(" PHASE: %0s", name);
            $display("   accesses   = %0d", acc);
            $display("   hits       = %0d", hit);
            $display("   misses     = %0d", miss);
            $display("   hit ratio  = %0.3f", hit_ratio);
            $display("   miss ratio = %0.3f", miss_ratio);
            $display("   AMAT       = %0.3f cycles  (hit=%0d + miss_ratio*%0d)",
                     amat, HIT_TIME, MISS_PENALTY);
        end
    endtask

    integer k;
    reg [31:0] rnd;

    initial begin
        $dumpfile("cache.vcd");
        $dumpvars(0, tb_cache);

        cpu_req  = 0;
        cpu_addr = 0;
        // reset
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // ========================================================
        // PHASE 1: SEQUENTIAL access (spatial locality)
        //   64 words ascending by 4 bytes. 4 words per 16B block,
        //   so expect 1 miss per block, 3 hits -> ~75% hit ratio.
        // ========================================================
        phase_begin;
        for (k = 0; k < 64; k = k + 1)
            do_access(k * 4);
        phase_report("SEQUENTIAL");

        // ========================================================
        // PHASE 2: REPEATED access (temporal locality)
        //   Hammer a tiny 4-block working set 40 times. Use a high
        //   address region NOT touched by Phase 1 so the first touch
        //   of each block is a genuine COLD miss:
        //     4 cold misses + 36 hits -> hit ratio = 0.90
        // ========================================================
        phase_begin;
        for (k = 0; k < 40; k = k + 1)
            do_access(32'h0001_0000 + (k % 4) * 64);  // 4 fresh blocks, reused
        phase_report("REPEATED");

        // ========================================================
        // PHASE 3: RANDOM access (poor locality)
        //   Pseudo-random 32-bit LFSR addresses across a 64 KB span.
        //   Many conflict misses -> low hit ratio.
        // ========================================================
        phase_begin;
        rnd = 32'hACE1_2345;
        for (k = 0; k < 200; k = k + 1) begin
            // xorshift for spread
            rnd = rnd ^ (rnd << 13);
            rnd = rnd ^ (rnd >> 17);
            rnd = rnd ^ (rnd << 5);
            do_access(rnd[15:0]);        // 64 KB address window
        end
        phase_report("RANDOM");

        // ========================================================
        // PHASE 4: CONFLICT misses (direct-mapped eviction)
        //   0x000 and 0x400 share index 0 but have different tags.
        //   Alternating between them makes each revisit a miss.
        // ========================================================
        phase_begin;
        do_access(32'h0000_0000);
        do_access(`CACHE_SIZE);
        do_access(32'h0000_0000);
        do_access(`CACHE_SIZE);
        phase_report("CONFLICT");
        if ((stat_accesses - base_acc) !== 32'd4 ||
            (stat_hits - base_hit) !== 32'd0 ||
            (stat_misses - base_miss) !== 32'd4)
            $fatal(1, "CONFLICT: expected four accesses and four misses");

        // ========================================================
        // OVERALL
        // ========================================================
        $display("=============================================");
        $display(" OVERALL");
        $display("   total accesses = %0d", stat_accesses);
        $display("   total hits     = %0d", stat_hits);
        $display("   total misses   = %0d", stat_misses);
        $display("   overall hit ratio  = %0.3f",
                 (stat_hits * 1.0) / stat_accesses);
        $display("   overall AMAT       = %0.3f cycles",
                 HIT_TIME + ((stat_misses * 1.0)/stat_accesses) * MISS_PENALTY);
        $display("=============================================");

        repeat (4) @(posedge clk);
        $finish;
    end

    // Safety timeout
    initial begin
        #2_000_000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
