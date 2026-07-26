`ifdef verilatorsim
`include "buffers.svh"
`include "interfaces.svh"
`else
`include "../design/includes/buffers.svh"
`include "../design/includes/interfaces.svh"
`endif

`timescale 1ns/1ps

// Testbench for skid_buffer (buffers.svh).
//
// The skid_buffer is a 2-deep elastic buffer with fully registered ready/valid
// on both ports (it breaks the combinational ready and valid paths between
// stages).  Ideal behavior:
//   * decoupled ready/valid: a transfer occurs iff valid && ready at a posedge
//   * capacity 2 (output register + one skid slot)
//   * lossless under back-pressure, no duplication, strict FIFO order
//   * full throughput (1 transfer/cycle) when the consumer keeps up
//   * synchronous flush via i_clear
//
// Verification: a SystemVerilog queue is the golden scoreboard.  Every accepted
// upstream word is pushed; every downstream word is checked against
// scoreboard.pop_front().  Timing is race-free: do_cycle() drives inputs 1ns
// into the cycle and samples the registered ready/valid/data (stable all cycle)
// with their pre-edge value, which is what the DUT commits at the edge.

module skid_buffer_tb;

  localparam int DataWidth = 16;
  localparam int ClkPeriod = 10;
  localparam int Capacity = 2;  // output register + skid slot
  localparam int IdleMax = 4;  // consecutive idle cycles => drained

  logic clk;
  logic rst;
  logic i_clear;

  handshakeIf #(.DATA_T(logic [DataWidth-1:0])) hsup (clk);
  handshakeIf #(.DATA_T(logic [DataWidth-1:0])) hsdown (clk);

  skid_buffer dut (
      .clk    (clk),
      .rst    (rst),
      .i_clear(i_clear),
      .hsup   (hsup),
      .hsdown (hsdown)
  );

  // Golden scoreboard + bookkeeping
  logic [DataWidth-1:0] scb                                                   [$];
  logic [DataWidth-1:0] next_tx;  // next value to drive (held until accepted)
  logic last_up, last_dn;  // did up/down transfer fire last cycle
  int sent_cnt, recv_cnt;
  int pass_cnt, fail_cnt;

  initial clk = 0;
  always #(ClkPeriod / 2) clk = ~clk;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  task automatic check_bit(input logic got, input logic expected, input string label);
    if (got !== expected) begin
      $display("[FAIL][%s] got=%0b expected=%0b", label, got, expected);
      fail_cnt++;
    end else begin
      $display("[PASS][%s] = %0b", label, got);
      pass_cnt++;
    end
  endtask

  task automatic check_int(input int got, input int expected, input string label);
    if (got !== expected) begin
      $display("[FAIL][%s] got=%0d expected=%0d", label, got, expected);
      fail_cnt++;
    end else begin
      $display("[PASS][%s] = %0d", label, got);
      pass_cnt++;
    end
  endtask

  // Advance one clock.  Drive (valid=try_push, ready=try_pop), measure the
  // transfers that commit on the upcoming edge, and update the scoreboard.
  // Must be called aligned to a posedge; returns aligned to the next posedge.
  task automatic do_cycle(input logic try_push, input logic try_pop);
    logic [DataWidth-1:0] dn_data, expected;

    #1;
    hsup.valid   = try_push;
    hsup.data    = next_tx;
    hsdown.ready = try_pop;

    // Registered outputs: stable this whole cycle == value sampled at edge.
    last_up      = try_push && hsup.ready;
    last_dn      = try_pop && hsdown.valid;
    dn_data      = hsdown.data;  // word consumed if last_dn

    @(posedge clk);  // transfers commit here

    // Downstream first so a same-cycle push lands behind the popped word.
    if (last_dn) begin
      if (scb.size() == 0) begin
        $display("[FAIL] spurious transfer: valid high, model empty, got=0x%04h", dn_data);
        fail_cnt++;
      end else begin
        expected = scb.pop_front();
        recv_cnt++;
        if (dn_data !== expected) begin
          $display("[FAIL] order mismatch: got=0x%04h exp=0x%04h", dn_data, expected);
          fail_cnt++;
        end else begin
          pass_cnt++;
        end
      end
    end
    if (last_up) begin
      scb.push_back(next_tx);
      sent_cnt++;
      next_tx = next_tx + 1;
    end
  endtask

  // Pop until the buffer has been idle (valid low) for IdleMax cycles.
  task automatic drain_all();
    int idle, guard;
    idle  = 0;
    guard = 0;
    while (idle < IdleMax && guard < 1000) begin
      do_cycle(1'b0, 1'b1);
      idle = last_dn ? 0 : idle + 1;
      guard++;
    end
  endtask

  task automatic do_reset();
    scb.delete();
    sent_cnt = 0;
    recv_cnt = 0;
    next_tx  = 16'hA000;
    hsup.valid   = 0;
    hsup.data    = 0;
    hsdown.ready = 0;
    i_clear = 0;
    rst = 1;
    repeat (3) @(posedge clk);
    rst = 0;
    repeat (2) @(posedge clk);  // ready registers high after reset
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, skid_buffer_tb);
    pass_cnt = 0;
    fail_cnt = 0;

    // ------------------------------------------------------------------
    // TEST 1: Reset / idle state
    //   Empty buffer must offer ready=1 (can accept) and valid=0.
    // ------------------------------------------------------------------
    $display("\n=== TEST 1: Reset state ===");
    do_reset();
    #1;
    check_bit(hsup.ready, 1'b1, "reset: ready");
    check_bit(hsdown.valid, 1'b0, "reset: valid");

    // ------------------------------------------------------------------
    // TEST 2: Capacity — fill with no draining
    //   An ideal skid buffer accepts exactly 2 words, then deasserts ready.
    // ------------------------------------------------------------------
    $display("\n=== TEST 2: Capacity (fill, no drain) ===");
    do_reset();
    for (int t = 0; t < 8; t++) do_cycle(1'b1, 1'b0);
    $display("[INFO] accepted %0d words before back-pressure (ideal=%0d)", sent_cnt, Capacity);
    check_int(sent_cnt, Capacity, "capacity: accepted == 2");
    // Hold valid high one more cycle while full: nothing extra may be taken.
    do_cycle(1'b1, 1'b0);
    check_int(sent_cnt, Capacity, "capacity: no overflow when full");
    #1;
    check_bit(hsup.ready, 1'b0, "full: ready low");
    check_bit(hsdown.valid, 1'b1, "full: valid high");

    // ------------------------------------------------------------------
    // TEST 3: Drain — verify count and FIFO order
    // ------------------------------------------------------------------
    $display("\n=== TEST 3: Drain, verify order ===");
    drain_all();
    check_int(recv_cnt, sent_cnt, "drain: received == accepted");
    check_int(scb.size(), 0, "drain: scoreboard empty (no lost words)");
    #1;
    check_bit(hsdown.valid, 1'b0, "empty: valid low");
    check_bit(hsup.ready, 1'b1, "empty: ready high");

    // ------------------------------------------------------------------
    // TEST 4: Full-throughput streaming
    //   Prime, then push+pop every cycle with an always-ready consumer.
    // ------------------------------------------------------------------
    $display("\n=== TEST 4: Simultaneous push/pop streaming ===");
    do_reset();
    do_cycle(1'b1, 1'b0);  // prime so the buffer is non-empty
    for (int t = 0; t < 40; t++) do_cycle(1'b1, 1'b1);
    drain_all();
    check_int(recv_cnt, sent_cnt, "stream: received == accepted");
    check_int(scb.size(), 0, "stream: scoreboard empty");

    // ------------------------------------------------------------------
    // TEST 5: Randomized push/pop stress
    //   Random back-pressure and bubbles on both ports; the scoreboard
    //   guarantees order + no loss + no duplication throughout.
    // ------------------------------------------------------------------
    $display("\n=== TEST 5: Randomized stress ===");
    do_reset();
    for (int t = 0; t < 200; t++)
    do_cycle(logic'($urandom_range(0, 1)), logic'($urandom_range(0, 1)));
    drain_all();
    check_int(recv_cnt, sent_cnt, "random: received == accepted");
    check_int(scb.size(), 0, "random: scoreboard empty");

    // ------------------------------------------------------------------
    // TEST 6: i_clear mid-operation
    //   Clear must flush all contents: valid->0, ready->1, buffer reusable.
    // ------------------------------------------------------------------
    $display("\n=== TEST 6: i_clear flush ===");
    do_reset();
    repeat (2) do_cycle(1'b1, 1'b0);  // load it full
    // One-cycle clear pulse
    #1;
    hsup.valid = 0;
    hsdown.ready = 0;
    i_clear = 1;
    @(posedge clk);
    #1;
    i_clear = 0;
    @(posedge clk);  // realign; let valid/ready re-register
    scb.delete();
    sent_cnt = 0;
    recv_cnt = 0;
    #1;
    check_bit(hsdown.valid, 1'b0, "after clear: valid low");
    check_bit(hsup.ready, 1'b1, "after clear: ready high");
    // Buffer must work normally again after clear.
    do_cycle(1'b1, 1'b0);
    drain_all();
    check_int(recv_cnt, sent_cnt, "post-clear: received == accepted");
    check_int(scb.size(), 0, "post-clear: scoreboard empty");

    // ------------------------------------------------------------------
    // Summary
    // ------------------------------------------------------------------
    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d TEST(S) FAILED - see [FAIL] lines above", fail_cnt);

    #50 $finish;
  end

endmodule
