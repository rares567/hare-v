`ifdef verilatorsim
`include "buffers.svh"
`else
`include "../design/includes/buffers.svh"
`endif

`timescale 1ns / 1ps

// Testbench for sync_fifo (buffers.svh).
//
// Timing model:
//   - Inputs driven between clock edges (blocking assignment, safe after #1 past posedge)
//   - Outputs sampled at @(posedge clk) #1  so NBA region has committed
//   - o_full / o_empty are registered: they reflect the state AFTER the current tick
//   - o_data is registered: it holds the word read by the current tick
//
// Reference model: a SystemVerilog queue tracks ideal FIFO contents.
// Each `check` call determines ideal write/read actions, ticks the clock,
// updates the model, then compares DUT outputs against ideal expectations.

module sync_fifo_tb;

  localparam DATA_WIDTH = 16;
  localparam DEPTH = 8;
  localparam int ClkPeriod = 20;

  logic clk, rst, i_clear;
  logic i_wr_en, i_rd_en;
  logic [DATA_WIDTH-1:0] i_data;
  logic [DATA_WIDTH-1:0] o_data;
  logic o_empty, o_full;

  // Reference model
  logic [DATA_WIDTH-1:0] ref_q[$];
  int pass_cnt, fail_cnt;

  sync_fifo #(
      .DEPTH    (DEPTH),
      .DATA_T   (logic [DATA_WIDTH-1:0]),
      .DEBUG    (0),
      .FIFO_NAME("TB")
  ) dut (
      .*
  );

  initial clk = 0;
  always #(ClkPeriod / 2) clk = ~clk;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  task automatic assert_eq(input logic got, input logic expected, input string sig,
                           input string label);
    if (got !== expected) begin
      $error("[FAIL][%s] %s=%0b expected=%0b", label, sig, got, expected);
      fail_cnt++;
    end else begin
      $display("[PASS][%s] %s=%0b", label, sig, got);
      pass_cnt++;
    end
  endtask

  // Apply inputs and advance one clock.  Outputs are stable after #1.
  task automatic tick(input logic wr_en, input logic [DATA_WIDTH-1:0] wr_data, input logic rd_en);
    i_wr_en = wr_en;
    i_data  = wr_data;
    i_rd_en = rd_en;
    @(posedge clk);
    #1;
  endtask

  // Tick + compare DUT outputs against the ideal reference model.
  //
  // Ideal write: happens when wr_en=1 AND ref_q.size() < DEPTH
  // Ideal read:  happens when rd_en=1 AND ref_q.size() > 0
  // Both can occur simultaneously when 0 < size < DEPTH.
  // When FULL:  write is blocked, read goes through.
  // When EMPTY: read  is blocked, write goes through.
  task automatic check(input logic wr_en, input logic [DATA_WIDTH-1:0] wr_data, input logic rd_en,
                       input string label);
    logic did_write, did_read;
    logic [DATA_WIDTH-1:0] expected_rdata;
    int                    expected_size;

    did_write = wr_en && (int'(ref_q.size()) < DEPTH);
    did_read  = rd_en && (ref_q.size() > 0);

    if (did_read) expected_rdata = ref_q[0];  // head BEFORE the tick

    tick(wr_en, wr_data, rd_en);

    // Update reference in the same order the DUT processes them:
    // write and read are independent and can both fire in one cycle.
    if (did_write) ref_q.push_back(wr_data);
    if (did_read) ref_q.pop_front();

    expected_size = int'(ref_q.size());

    assert_eq(o_full, expected_size == DEPTH, "o_full", label);
    assert_eq(o_empty, expected_size == 0, "o_empty", label);

    if (did_read) begin
      if (o_data !== expected_rdata) begin
        $error("[FAIL][%s] o_data=0x%04h expected=0x%04h", label, o_data, expected_rdata);
        fail_cnt++;
      end else begin
        $display("[PASS][%s] o_data=0x%04h", label, o_data);
        pass_cnt++;
      end
    end
  endtask

  task automatic do_reset();
    ref_q.delete();
    i_wr_en = 0;
    i_rd_en = 0;
    i_data = 0;
    i_clear = 0;
    rst = 1;
    repeat (3) @(posedge clk);
    #1;
    rst = 0;
    @(posedge clk);
    #1;
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, sync_fifo_tb);
    pass_cnt = 0;
    fail_cnt = 0;

    // ------------------------------------------------------------------
    // TEST 1: Reset state
    // ------------------------------------------------------------------
    $display("\n=== TEST 1: Reset state ===");
    do_reset();
    assert_eq(o_empty, 1'b1, "o_empty", "reset");
    assert_eq(o_full, 1'b0, "o_full", "reset");

    // ------------------------------------------------------------------
    // TEST 2: Fill to full, one item per cycle
    //   After the DEPTH-th write o_full must assert (registered, same tick).
    //   Items 0..DEPTH-2: o_full stays 0.
    //   Item  DEPTH-1:    o_full becomes 1.
    // ------------------------------------------------------------------
    $display("\n=== TEST 2: Fill until full ===");
    for (int i = 0; i < DEPTH; i++)
    check(1, 16'hA000 + DATA_WIDTH'(i), 0, $sformatf("fill[%0d]", i));

    // ------------------------------------------------------------------
    // TEST 3: Write when full — write must be silently dropped
    //   o_full stays 1, o_empty stays 0.
    // ------------------------------------------------------------------
    $display("\n=== TEST 3: Write when full (should be dropped) ===");
    check(1, 16'hDEAD, 0, "overflow");

    // ------------------------------------------------------------------
    // TEST 4: Drain until empty, verify data order (FIFO)
    //   After the DEPTH-th read o_empty must assert (same tick).
    // ------------------------------------------------------------------
    $display("\n=== TEST 4: Drain until empty, verify FIFO order ===");
    for (int i = 0; i < DEPTH; i++) check(0, '0, 1, $sformatf("drain[%0d]", i));

    // ------------------------------------------------------------------
    // TEST 5: Read when empty — read must be silently dropped
    //   o_empty stays 1, o_full stays 0.
    // ------------------------------------------------------------------
    $display("\n=== TEST 5: Read when empty (should be dropped) ===");
    check(0, '0, 1, "underflow");

    // ------------------------------------------------------------------
    // TEST 6: Simultaneous push+pop with exactly 1 item in FIFO
    //   Ideal: the old item is read, the new item is written.
    //   FIFO has 1 item after → o_empty=0, o_full=0.
    //   DUT bug trigger: w_almost_empty fires during the read even
    //   though a write is replacing the item.
    // ------------------------------------------------------------------
    $display("\n=== TEST 6: Simultaneous push+pop, 1 item ===");
    do_reset();
    check(1, 16'hBEEF, 0, "pre-load");
    check(1, 16'hCAFE, 1, "simult/1-item");

    // ------------------------------------------------------------------
    // TEST 7: Simultaneous push+pop with DEPTH-1 items
    //   Ideal: one item in, one item out → size stays DEPTH-1.
    //   o_full=0, o_empty=0.
    //   DUT bug trigger: w_almost_full fires during the write even
    //   though a read is consuming a slot.
    // ------------------------------------------------------------------
    $display("\n=== TEST 7: Simultaneous push+pop, DEPTH-1 items ===");
    do_reset();
    for (int i = 0; i < DEPTH - 1; i++)
    check(1, 16'hB000 + DATA_WIDTH'(i), 0, $sformatf("fill[%0d]", i));
    check(1, 16'hFFFF, 1, "simult/DEPTH-1");

    // ------------------------------------------------------------------
    // TEST 8: Simultaneous push+pop when FULL
    //   Write is blocked (o_full=1 gates the write path), read goes through.
    //   Ideal: size drops to DEPTH-1, o_full=0.
    // ------------------------------------------------------------------
    $display("\n=== TEST 8: Simultaneous push+pop when full ===");
    do_reset();
    for (int i = 0; i < DEPTH; i++)
    check(1, 16'hC000 + DATA_WIDTH'(i), 0, $sformatf("fill[%0d]", i));
    check(1, 16'hDEAD, 1, "simult/full");

    // ------------------------------------------------------------------
    // TEST 9: Simultaneous push+pop when EMPTY
    //   Read is blocked (o_empty=1 gates the read path), write goes through.
    //   Ideal: size rises to 1, o_empty=0.
    // ------------------------------------------------------------------
    $display("\n=== TEST 9: Simultaneous push+pop when empty ===");
    do_reset();
    check(1, 16'hFACE, 1, "simult/empty");

    // ------------------------------------------------------------------
    // TEST 10: Alternating push / pop — verifies pointer wrap-around
    // ------------------------------------------------------------------
    $display("\n=== TEST 10: Alternating push/pop (pointer wrap) ===");
    do_reset();
    for (int i = 0; i < 2 * DEPTH; i++) begin
      if (i % 2 == 0) check(1, 16'h1000 + DATA_WIDTH'(i), 0, $sformatf("alt-push[%0d]", i));
      else check(0, '0, 1, $sformatf("alt-pop [%0d]", i));
    end

    // ------------------------------------------------------------------
    // TEST 11: i_clear resets FIFO mid-operation
    // ------------------------------------------------------------------
    $display("\n=== TEST 11: i_clear ===");
    do_reset();
    for (int i = 0; i < 4; i++)
    check(1, 16'hE000 + DATA_WIDTH'(i), 0, $sformatf("pre-clear[%0d]", i));
    // Assert clear for one cycle
    i_clear = 1;
    i_wr_en = 0;
    i_rd_en = 0;
    @(posedge clk);
    #1;
    i_clear = 0;
    ref_q.delete();
    @(posedge clk);
    #1;
    assert_eq(o_empty, 1'b1, "o_empty", "after-clear");
    assert_eq(o_full, 1'b0, "o_full", "after-clear");
    // Ensure FIFO is usable again after clear
    check(1, 16'h5A5A, 0, "post-clear-push");
    check(0, '0, 1, "post-clear-pop");

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED — see [FAIL] lines above", fail_cnt);

    #50 $finish;
  end

endmodule
