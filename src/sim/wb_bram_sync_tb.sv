`ifndef verilatorsim
`include "../design/includes/interfaces.svh"
`else
`include "interfaces.svh"
`endif

`timescale 1ns/1ps

// Unit testbench for wb_bram_sync (1-cycle synchronous Block RAM with Wishbone slave).
module wb_bram_sync_tb;

  localparam int CLK_PERIOD = 10;
  localparam int DATA_WIDTH = 32;
  localparam int ADDR_WIDTH = 32;
  localparam int SIZE = 1024;                // 1024 bytes = 256 words
  localparam int WORDS = SIZE / 4;
  localparam logic [31:0] START_ADDR = 32'h8000_0000;

  logic clk, rst;

  wishboneIf #(
      .DATA_T    (logic [31:0]),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) wb_bus (.clk(clk));

  wb_bram_sync #(
      .INIT_FILE    (""),
      .START_ADDRESS(START_ADDR),
      .SIZE         (SIZE)
  ) dut (
      .clk   (clk),
      .rst   (rst),
      .wb_cpu(wb_bus.Slave)
  );

  always #(CLK_PERIOD / 2) clk = (clk === 1'b0);

  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic chk(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("[FAIL] %-55s got=0x%08h exp=0x%08h", what, got, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  task automatic chk_bit(input string what, input logic got, input logic exp);
    if (got !== exp) begin
      $display("[FAIL] %-55s got=%0b exp=%0b", what, got, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  task automatic do_reset();
    rst           = 1'b1;
    wb_bus.cyc    = 1'b0;
    wb_bus.stb    = 1'b0;
    wb_bus.we     = 1'b0;
    wb_bus.addr   = '0;
    wb_bus.data_wr = '0;
    wb_bus.sel    = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  endtask

  // Golden model for stress verification
  logic [31:0] golden_mem[WORDS];
  logic [31:0] rdata;

  initial begin
    for (int i = 0; i < WORDS; i++) golden_mem[i] = '0;

    do_reset();

    $display("=== STARTING WB_BRAM_SYNC (1-CYCLE BRAM) VERIFICATION ===");

    // -------------------------------------------------------------------------
    // Test 1: Reset & Idle State
    // -------------------------------------------------------------------------
    $display("\n--- Test 1: Reset & Idle State ---");
    #1;
    chk_bit("idle: ack is low",   wb_bus.ack,   1'b0);
    chk_bit("idle: err is low",   wb_bus.err,   1'b0);
    chk_bit("idle: stall is low", wb_bus.stall, 1'b0);

    // -------------------------------------------------------------------------
    // Test 2: Synchronous Write & 1-Cycle Read via MasterWrite / MasterRead
    // -------------------------------------------------------------------------
    $display("\n--- Test 2: Full-Word Write & 1-Cycle Read via MasterWrite / MasterRead ---");
    wb_bus.MasterWrite(START_ADDR, 32'hDEAD_BEEF);
    #1;
    chk_bit("post-write idle: cyc drops", wb_bus.cyc, 1'b0);

    // Read back the word
    wb_bus.MasterRead(START_ADDR, rdata);
    #1;
    chk("read cycle: data matches write", rdata, 32'hDEAD_BEEF);
    chk_bit("post-read idle: cyc drops", wb_bus.cyc, 1'b0);

    // -------------------------------------------------------------------------
    // Test 3: Sub-Word Byte-Enable Writes (sel) via MasterWrite
    // -------------------------------------------------------------------------
    $display("\n--- Test 3: Sub-Word Byte-Enable Writes (sel) via MasterWrite ---");
    // Write 0x0000_0000 to Word 1
    wb_bus.MasterWrite(START_ADDR + 32'h4, 32'h0000_0000, 4'b1111);

    // Byte 0 write: 0x11
    wb_bus.MasterWrite(START_ADDR + 32'h4, 32'h0000_0011, 4'b0001);

    // Byte 2 write: 0x33
    wb_bus.MasterWrite(START_ADDR + 32'h4, 32'h0033_0000, 4'b0100);

    // Halfword 1 write: 0xAA00
    wb_bus.MasterWrite(START_ADDR + 32'h4, 32'hAA55_0000, 4'b1100);

    // Read back Word 1
    wb_bus.MasterRead(START_ADDR + 32'h4, rdata);
    #1;
    // Expected: Byte 0=11, Byte 1=00, Bytes 3:2=AA55 -> 0xAA55_0011
    chk("sub-word selective write result", rdata, 32'hAA55_0011);

    // -------------------------------------------------------------------------
    // Test 4: 16-Word Back-to-Back Pipelined Streaming (1 transfer/cycle)
    // -------------------------------------------------------------------------
    $display("\n--- Test 4: 16-Word Back-to-Back Streaming ---");
    // Write 16 words streaming
    for (int i = 0; i < 16; i++) begin
      @(negedge clk);
      wb_bus.cyc     = 1'b1;
      wb_bus.stb     = 1'b1;
      wb_bus.we      = 1'b1;
      wb_bus.addr    = START_ADDR + (i * 4);
      wb_bus.data_wr = 32'hA000_0000 + i;
      wb_bus.sel     = 4'b1111;
      golden_mem[i]  = wb_bus.data_wr;
    end
    @(posedge clk);

    // Stream 16 reads back-to-back
    for (int i = 0; i < 16; i++) begin
      @(negedge clk);
      wb_bus.cyc  = 1'b1;
      wb_bus.stb  = 1'b1;
      wb_bus.we   = 1'b0;
      wb_bus.addr = START_ADDR + (i * 4);
      wb_bus.sel  = 4'b1111;
      if (i > 0) begin
        // The previous read finishes on this rising edge
        #1;
        chk($sformatf("streaming read[%0d]", i-1), wb_bus.data_rd, golden_mem[i-1]);
        chk_bit($sformatf("streaming ack[%0d]", i-1), wb_bus.ack, 1'b1);
      end
    end
    @(posedge clk);
    #1;
    // Final read output
    chk("streaming read[15]", wb_bus.data_rd, golden_mem[15]);
    chk_bit("streaming ack[15]", wb_bus.ack, 1'b1);

    @(negedge clk);
    wb_bus.cyc = 1'b0;
    wb_bus.stb = 1'b0;

    // -------------------------------------------------------------------------
    // Test 5: Out-of-Range Address Range Checking (err = 1)
    // -------------------------------------------------------------------------
    $display("\n--- Test 5: Address Boundary & Range Faults ---");
    // Address below START_ADDRESS
    @(negedge clk);
    wb_bus.cyc  = 1'b1;
    wb_bus.stb  = 1'b1;
    wb_bus.we   = 1'b0;
    wb_bus.addr = START_ADDR - 32'h4;
    @(posedge clk);
    #1;
    chk_bit("underflow addr: err=1", wb_bus.err, 1'b1);
    chk_bit("underflow addr: ack=0", wb_bus.ack, 1'b0);

    // Valid upper boundary: START_ADDR + SIZE - 4
    @(negedge clk);
    wb_bus.addr = START_ADDR + SIZE - 32'h4;
    @(posedge clk);
    #1;
    chk_bit("valid max word: err=0", wb_bus.err, 1'b0);
    chk_bit("valid max word: ack=1", wb_bus.ack, 1'b1);

    // Exact upper limit (out of range by 1 word): START_ADDR + SIZE
    @(negedge clk);
    wb_bus.addr = START_ADDR + SIZE;
    @(posedge clk);
    #1;
    chk_bit("overflow addr: err=1", wb_bus.err, 1'b1);
    chk_bit("overflow addr: ack=0", wb_bus.ack, 1'b0);

    // Wild address: 0xFFFF_FFF0
    @(negedge clk);
    wb_bus.addr = 32'hFFFF_FFF0;
    @(posedge clk);
    #1;
    chk_bit("wild addr: err=1", wb_bus.err, 1'b1);
    chk_bit("wild addr: ack=0", wb_bus.ack, 1'b0);

    @(negedge clk);
    wb_bus.cyc = 1'b0;
    wb_bus.stb = 1'b0;

    // -------------------------------------------------------------------------
    // Test 6: Randomized Fuzzing (500 Iterations)
    // -------------------------------------------------------------------------
    $display("\n--- Test 6: Randomized Stress Fuzzing (500 iterations) ---");
    for (int iter = 0; iter < 500; iter++) begin
      automatic bit is_write = $urandom_range(0, 1);
      automatic bit is_valid_addr = ($urandom_range(0, 9) != 0); // 90% valid, 10% invalid
      automatic int word_idx = $urandom_range(0, WORDS - 1);
      automatic logic [31:0] test_addr = is_valid_addr ? (START_ADDR + (word_idx * 4)) : 32'h1000_0000;
      automatic logic [31:0] rand_data = $urandom();
      automatic logic [3:0]  rand_sel  = $urandom_range(1, 15);

      @(negedge clk);
      wb_bus.cyc     = 1'b1;
      wb_bus.stb     = 1'b1;
      wb_bus.we      = is_write;
      wb_bus.addr    = test_addr;
      wb_bus.data_wr = rand_data;
      wb_bus.sel     = rand_sel;

      @(posedge clk);
      #1;
      if (!is_valid_addr) begin
        chk_bit($sformatf("fuzz[%0d] invalid addr: err=1", iter), wb_bus.err, 1'b1);
        chk_bit($sformatf("fuzz[%0d] invalid addr: ack=0", iter), wb_bus.ack, 1'b0);
      end else begin
        chk_bit($sformatf("fuzz[%0d] valid: err=0", iter), wb_bus.err, 1'b0);
        chk_bit($sformatf("fuzz[%0d] valid: ack=1", iter), wb_bus.ack, 1'b1);

        if (is_write) begin
          // Update golden model with byte mask
          for (int b = 0; b < 4; b++) begin
            if (rand_sel[b]) golden_mem[word_idx][b*8 +: 8] = rand_data[b*8 +: 8];
          end
        end else begin
          chk($sformatf("fuzz[%0d] read match", iter), wb_bus.data_rd, golden_mem[word_idx]);
        end
      end
    end

    @(negedge clk);
    wb_bus.cyc = 1'b0;
    wb_bus.stb = 1'b0;
    @(posedge clk);

    $display("\n==========================================================================");
    $display("WB_BRAM_SYNC TEST SUMMARY: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("==========================================================================");

    if (fail_cnt == 0) begin
      $display("ALL %0d CHECKS PASSED PERFECTLY", pass_cnt);
    end else begin
      $display("ERROR: %0d assertions failed!", fail_cnt);
    end

    $finish;
  end

endmodule
