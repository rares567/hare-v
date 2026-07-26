`ifdef verilatorsim
`include "buffers.svh"
`include "interfaces.svh"
`else
`include "../design/includes/buffers.svh"
`include "../design/includes/interfaces.svh"
`endif

`timescale 1ns/1ps

// Testbench for queue (buffers.svh).
//
// The queue is a ready/valid FIFO built from a 1-deep input skid buffer in
// front of a DEPTH-deep sync_fifo.  The skid register absorbs the in-flight
// word that arrives while the FIFO fills, so the ideal storage capacity is
// DEPTH + 1.
//
// Verification strategy (implementation-independent / "ideal queue"):
//   * A SystemVerilog queue acts as a golden scoreboard.
//   * A transfer on a ready/valid port happens iff (valid && ready) at a
//     posedge.  Every accepted upstream word is pushed to the scoreboard;
//     every downstream word is checked against scoreboard.pop_front().
//   * This proves: no data loss, no duplication, strict FIFO order.
//   * Directed tests additionally check capacity == DEPTH+1, the full/empty
//     handshake levels, full-throughput streaming, and i_clear.
//
// Timing model (race-free):
//   * do_cycle() is always entered right after a posedge.
//   * Inputs are driven 1ns into the cycle (well before the next edge).
//   * ready / valid / o_data are all registered, hence stable for the whole
//     cycle; they are sampled at the same 1ns point with their pre-edge value,
//     which is exactly what the DUT samples at the upcoming edge.

module queue_tb;

  localparam int Depth = 8;
  localparam int DataWidth = 32;
  localparam int ClkPeriod = 10;
  localparam int Capacity = Depth + 1;  // ideal storage: FIFO depth + skid
  localparam int IdleMax = 4;  // consecutive idle cycles => drained

  logic clk;
  logic rst;
  logic i_clear;

  handshakeIf #(.DATA_T(logic [DataWidth-1:0])) upstream_if (clk);
  handshakeIf #(.DATA_T(logic [DataWidth-1:0])) downstream_if (clk);

  queue #(
      .DEPTH     (Depth),
      .DEBUG     (0),
      .QUEUE_NAME("TEST")
  ) dut (
      .clk    (clk),
      .rst    (rst),
      .i_clear(i_clear),
      .hsup   (upstream_if.Upstream),
      .hsdown (downstream_if.Downstream)
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

  // Non-fatal checks: log and count so the whole suite runs to completion.
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

  // Advance exactly one clock.  Drive (valid=try_push, ready=try_pop), measure
  // the transfers that commit on the upcoming edge, and update the scoreboard.
  // Must be called aligned to a posedge; returns aligned to the next posedge.
  task automatic do_cycle(input logic try_push, input logic try_pop);
    logic [DataWidth-1:0] dn_data, expected;

    #1;
    upstream_if.valid   = try_push;
    upstream_if.data    = next_tx;
    downstream_if.ready = try_pop;

    // Registered outputs: stable this whole cycle == value sampled at edge.
    last_up             = try_push && upstream_if.ready;
    last_dn             = try_pop && downstream_if.valid;
    dn_data             = downstream_if.data;  // word consumed if last_dn

    @(posedge clk);  // transfers commit here

    // Downstream first so a same-cycle push lands behind the popped word.
    if (last_dn) begin
      if (scb.size() == 0) begin
        $display("[FAIL] spurious transfer: valid high, model empty, got=0x%08h", dn_data);
        fail_cnt++;
      end else begin
        expected = scb.pop_front();
        recv_cnt++;
        if (dn_data !== expected) begin
          $display("[FAIL] order mismatch: got=0x%08h exp=0x%08h", dn_data, expected);
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

  // Pop until the queue has been idle (valid low) for IdleMax cycles.
  // Guarded against a stuck-high valid so a buggy DUT cannot hang the sim.
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
    next_tx  = 32'hA000_0000;
    upstream_if.valid   = 0;
    upstream_if.data    = 0;
    downstream_if.ready = 0;
    i_clear = 0;
    rst = 1;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);  // ready registers high one cycle later
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------

  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, queue_tb);
    pass_cnt = 0;
    fail_cnt = 0;

    // ------------------------------------------------------------------
    // TEST 1: Reset / idle state
    //   Empty queue must offer ready=1 (can accept) and valid=0 (nothing).
    // ------------------------------------------------------------------
    $display("\n=== TEST 1: Reset state ===");
    do_reset();
    #1;
    check_bit(upstream_if.ready, 1'b1, "reset: ready");
    check_bit(downstream_if.valid, 1'b0, "reset: valid");

    // ------------------------------------------------------------------
    // TEST 2: Capacity — fill with no draining
    //   An ideal queue accepts exactly DEPTH+1 words, then deasserts ready.
    // ------------------------------------------------------------------
    $display("\n=== TEST 2: Capacity (fill, no drain) ===");
    do_reset();
    for (int t = 0; t < 3 * Capacity; t++) do_cycle(1'b1, 1'b0);
    $display("[INFO] accepted %0d words before back-pressure (ideal=%0d)", sent_cnt, Capacity);
    check_int(sent_cnt, Capacity, "capacity: accepted == DEPTH+1");
    // Hold valid high one more cycle while full: nothing extra may be taken.
    do_cycle(1'b1, 1'b0);
    check_int(sent_cnt, Capacity, "capacity: no overflow when full");
    #1;
    check_bit(upstream_if.ready, 1'b0, "full: ready low");
    check_bit(downstream_if.valid, 1'b1, "full: valid high");

    // ------------------------------------------------------------------
    // TEST 3: Drain — verify count and strict FIFO order
    // ------------------------------------------------------------------
    $display("\n=== TEST 3: Drain, verify FIFO order ===");
    drain_all();
    check_int(recv_cnt, sent_cnt, "drain: received == accepted");
    check_int(scb.size(), 0, "drain: scoreboard empty (no lost words)");
    #1;
    check_bit(downstream_if.valid, 1'b0, "empty: valid low");
    check_bit(upstream_if.ready, 1'b1, "empty: ready high");

    // ------------------------------------------------------------------
    // TEST 4: Full-throughput streaming
    //   Prime, then push+pop every cycle with an always-ready consumer.
    //   Data integrity must hold across the simultaneous traffic.
    // ------------------------------------------------------------------
    $display("\n=== TEST 4: Simultaneous push/pop streaming ===");
    do_reset();
    repeat (3) do_cycle(1'b1, 1'b0);  // prime so the queue is non-empty
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
    for (int t = 0; t < 300; t++)
    do_cycle(logic'($urandom_range(0, 1)), logic'($urandom_range(0, 1)));
    drain_all();
    check_int(recv_cnt, sent_cnt, "random: received == accepted");
    check_int(scb.size(), 0, "random: scoreboard empty");

    // ------------------------------------------------------------------
    // TEST 6: i_clear mid-operation
    //   Clear must flush all contents: valid->0, ready->1, queue reusable.
    // ------------------------------------------------------------------
    $display("\n=== TEST 6: i_clear flush ===");
    do_reset();
    repeat (4) do_cycle(1'b1, 1'b0);  // load 4 words
    // One-cycle clear pulse
    #1;
    upstream_if.valid = 0;
    downstream_if.ready = 0;
    i_clear = 1;
    @(posedge clk);
    #1;
    i_clear = 0;
    @(posedge clk);  // realign; let valid/ready re-register
    scb.delete();
    sent_cnt = 0;
    recv_cnt = 0;
    #1;
    check_bit(downstream_if.valid, 1'b0, "after clear: valid low");
    check_bit(upstream_if.ready, 1'b1, "after clear: ready high");
    // Queue must work normally again after clear.
    repeat (3) do_cycle(1'b1, 1'b0);
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
