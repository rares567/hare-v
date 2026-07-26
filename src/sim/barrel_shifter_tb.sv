`ifdef verilatorsim
`include "functional_units.svh"
`else
`include "../design/includes/functional_units.svh"
`endif

`timescale 1ns / 1ps

// Testbench for barrel_shifter_N.
//
// The DUT is a fully-pipelined barrel shifter (one result per cycle).  Rather
// than hardcode the pipeline latency, a software reference model computes the
// expected result for every applied input and pushes it onto a queue; a
// concurrent checker pops one expected result each cycle o_valid is high and
// compares it against o_data.  Because the pipeline is in-order and emits
// exactly one valid result per accepted input, the queue stays aligned no
// matter how deep the pipe is.

module barrel_shifter_tb;
  localparam int DATA_WIDTH = 32;
  localparam int N = $clog2(DATA_WIDTH);

  logic                       clk;
  logic                       rst;
  logic                       en;
  logic      [DATA_WIDTH-1:0] i_data;
  logic      [         N-1:0] i_shamt;
  shift_op_t                  i_shconf;
  logic      [DATA_WIDTH-1:0] o_data;
  logic                       o_valid;

  barrel_shifter_N #(
      .DATA_WIDTH(DATA_WIDTH),
      .EXTRA_PIPE("TRUE")
  ) uut (
      .*
  );

  // -------------------------------------------------------------------------
  // Reference model + scoreboard
  // -------------------------------------------------------------------------
  typedef struct {
    logic [DATA_WIDTH-1:0] data;
    logic [N-1:0]          shamt;
    shift_op_t             op;
    logic [DATA_WIDTH-1:0] expected;
  } txn_t;

  txn_t exp_q[$];
  int pass_cnt = 0;
  int fail_cnt = 0;

  // Golden shift/rotate model.
  function automatic logic [DATA_WIDTH-1:0] shift_ref(
      input logic [DATA_WIDTH-1:0] data, input logic [N-1:0] shamt, input shift_op_t op);
    int s;
    s = int'(shamt);
    case (op)
      SLL_OP:  shift_ref = data << s;
      SRL_OP:  shift_ref = data >> s;
      SRA_OP:  shift_ref = $signed(data) >>> s;
      ROTL_OP: shift_ref = (s == 0) ? data : (data << s) | (data >> (DATA_WIDTH - s));
      ROTR_OP: shift_ref = (s == 0) ? data : (data >> s) | (data << (DATA_WIDTH - s));
      default: shift_ref = 'x;
    endcase
  endfunction

  function automatic string op_name(input shift_op_t op);
    case (op)
      SLL_OP:  op_name = "SLL ";
      SRL_OP:  op_name = "SRL ";
      SRA_OP:  op_name = "SRA ";
      ROTL_OP: op_name = "ROTL";
      ROTR_OP: op_name = "ROTR";
      default: op_name = "?   ";
    endcase
  endfunction

  // Drive one input for one clock and queue its expected result.
  task automatic apply(input logic [DATA_WIDTH-1:0] data, input int shamt, input shift_op_t op);
    txn_t t;
    i_data     = data;
    i_shamt    = N'(shamt);
    i_shconf   = op;
    t.data     = data;
    t.shamt    = N'(shamt);
    t.op       = op;
    t.expected = shift_ref(data, N'(shamt), op);
    exp_q.push_back(t);
    #10;
  endtask

  // -------------------------------------------------------------------------
  // Clock / reset
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, barrel_shifter_tb);
    clk = 1'b0;
    rst = 1'b1;
    en  = 1'b0;
    forever #5 clk = ~clk;
  end

  // -------------------------------------------------------------------------
  // Concurrent checker: every cycle a valid result emerges, compare it
  // against the head of the expected queue.
  // -------------------------------------------------------------------------
  initial begin
    txn_t t;
    forever begin
      @(posedge clk);
      #1;
      if (!rst && o_valid) begin
        if (exp_q.size() == 0) begin
          $display("[FAIL] o_valid with empty model (o_data=0x%08h)", o_data);
          fail_cnt++;
        end else begin
          t = exp_q.pop_front();
          if (o_data !== t.expected) begin
            $display("[FAIL] %s data=0x%08h shamt=%0d : got=0x%08h exp=0x%08h", op_name(t.op),
                     t.data, t.shamt, o_data, t.expected);
            fail_cnt++;
          end else begin
            pass_cnt++;
          end
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Stimulus
  // -------------------------------------------------------------------------
  initial begin
    #10 rst = 1'b0;
    en = 1'b1;
    for (int i = 0; i < 32; ++i) begin
      apply(32'h8000_0001, i, ROTL_OP);
    end
    for (int i = 0; i < 32; ++i) begin
      apply(32'h8000_0001, i, ROTR_OP);
    end
    for (int i = 0; i < 32; ++i) begin
      apply(32'h800F_000F, i, SLL_OP);
    end
    for (int i = 0; i < 32; ++i) begin
      apply(32'h800F_000F, i, SRL_OP);
    end
    for (int i = 0; i < 32; ++i) begin
      apply(32'h800F_000F, i, SRA_OP);
    end

    // Stop feeding and let the pipeline drain so every result is checked.
    en = 1'b0;
    repeat (40) @(posedge clk);
    #2;

    // Anything still queued was never produced => lost outputs.
    while (exp_q.size() > 0) begin
      txn_t t;
      t = exp_q.pop_front();
      $display("[FAIL] missing output for %s data=0x%08h shamt=%0d (exp=0x%08h)", op_name(t.op),
               t.data, t.shamt, t.expected);
      fail_cnt++;
    end

    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED - see [FAIL] lines above", fail_cnt);
    $finish;
  end

endmodule
