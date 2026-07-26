`ifdef verilatorsim
`include "functional_units.svh"
`else
`include "../design/includes/functional_units.svh"
`endif
`timescale 1ns/1ps

// Testbench for xilinx_alu_unit (FABRIC implementation).
//
// The ALU is pipelined: `en` registers a new input, and o_valid flags a
// completed result.  As with the barrel-shifter TB, a software reference model
// predicts each result and a concurrent checker pops one expected value each
// cycle o_valid is high -- so the check is independent of pipeline depth.
//
// Two DUTs are instantiated with EXTRA_PIPE FALSE and TRUE and fed the same
// stimulus: the result must be correct regardless of the internal structure
// (the EXTRA_PIPE variant splits the 32-bit op into two 16-bit halves with a
// carry crossing between them, so it gets its own scoreboard).
//
// DSP IMPL is intentionally out of scope here.

module xilinx_alu_unit_tb;
  import decode_package::*;

  localparam int DataWidth = 32;

  logic                    clk;
  logic                    rst;
  logic                    en;
  alu_op_t                 i_alu_op;
  logic    [DataWidth-1:0] i_rs1;
  logic    [DataWidth-1:0] i_rs2;

  logic [DataWidth-1:0] o_rd_np, o_rd_ep;
  logic o_valid_np, o_valid_ep;

  // No extra pipeline stage
  xilinx_alu_unit #(
      .DATA_WIDTH (DataWidth),
      .IMPL       ("FABRIC"),
      .FPGA_FAMILY("ARTIX7"),
      .EXTRA_PIPE ("FALSE")
  ) dut_np (
      .clk,
      .rst,
      .en,
      .i_alu_op,
      .i_rs1,
      .i_rs2,
      .o_rd(o_rd_np),
      .o_valid(o_valid_np)
  );

  // Split into two halves with an extra pipeline stage
  xilinx_alu_unit #(
      .DATA_WIDTH (DataWidth),
      .IMPL       ("FABRIC"),
      .FPGA_FAMILY("ARTIX7"),
      .EXTRA_PIPE ("TRUE")
  ) dut_ep (
      .clk,
      .rst,
      .en,
      .i_alu_op,
      .i_rs1,
      .i_rs2,
      .o_rd(o_rd_ep),
      .o_valid(o_valid_ep)
  );

  // -------------------------------------------------------------------------
  // Reference model + scoreboard
  // -------------------------------------------------------------------------
  typedef struct {
    alu_op_t              op;
    logic [DataWidth-1:0] a;
    logic [DataWidth-1:0] b;
    logic [DataWidth-1:0] expected;
  } txn_t;

  txn_t exp_np[$];
  txn_t exp_ep[$];
  int pass_cnt = 0;
  int fail_cnt = 0;

  function automatic logic [DataWidth-1:0] alu_ref(input alu_op_t op, input logic [DataWidth-1:0] a,
                                                   input logic [DataWidth-1:0] b);
    case (op)
      ADD_OP:  alu_ref = a + b;
      SUB_OP:  alu_ref = a - b;
      AND_OP:  alu_ref = a & b;
      OR_OP:   alu_ref = a | b;
      XOR_OP:  alu_ref = a ^ b;
      default: alu_ref = 'x;
    endcase
  endfunction

  function automatic string op_name(input alu_op_t op);
    case (op)
      ADD_OP:  op_name = "ADD";
      SUB_OP:  op_name = "SUB";
      AND_OP:  op_name = "AND";
      OR_OP:   op_name = "OR ";
      XOR_OP:  op_name = "XOR";
      default: op_name = "?  ";
    endcase
  endfunction

  // Drive one input for one clock and queue its expected result for both DUTs.
  task automatic apply(input alu_op_t op, input logic [DataWidth-1:0] a,
                       input logic [DataWidth-1:0] b);
    txn_t t;
    i_alu_op = op;
    i_rs1    = a;
    i_rs2    = b;
    t.op = op;
    t.a = a;
    t.b = b;
    t.expected = alu_ref(op, a, b);
    exp_np.push_back(t);
    exp_ep.push_back(t);
    #10;
  endtask

  // Compare one observed result against the head of a variant's queue.
  task automatic score(input string tag, input logic [DataWidth-1:0] got, ref txn_t q[$]);
    txn_t t;
    if (q.size() == 0) begin
      $display("[FAIL][%s] o_valid with empty model (got=0x%08h)", tag, got);
      fail_cnt++;
      return;
    end
    t = q.pop_front();
    if (got !== t.expected) begin
      $display("[FAIL][%s] %s a=0x%08h b=0x%08h : got=0x%08h exp=0x%08h", tag, op_name(t.op), t.a,
               t.b, got, t.expected);
      fail_cnt++;
    end else begin
      pass_cnt++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Clock / reset
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, xilinx_alu_unit_tb);
    clk = 1'b0;
    rst = 1'b1;
    en  = 1'b0;
    forever #5 clk = ~clk;
  end

  // -------------------------------------------------------------------------
  // Concurrent checkers (one per variant; queues are independent and in-order)
  // -------------------------------------------------------------------------
  initial begin
    forever begin
      @(posedge clk);
      #1;
      if (!rst && o_valid_np) score("NOPIPE", o_rd_np, exp_np);
    end
  end

  initial begin
    forever begin
      @(posedge clk);
      #1;
      if (!rst && o_valid_ep) score("XPIPE ", o_rd_ep, exp_ep);
    end
  end

  // -------------------------------------------------------------------------
  // Stimulus
  // -------------------------------------------------------------------------
  alu_op_t ops[5] = '{ADD_OP, SUB_OP, AND_OP, OR_OP, XOR_OP};

  // Directed operand pairs: corners + carry/borrow across the 16-bit halves.
  logic [DataWidth-1:0] da[] = '{
      32'h0000_0000,
      32'hFFFF_FFFF,
      32'h0000_FFFF,
      32'h0001_0000,
      32'h7FFF_FFFF,
      32'h8000_0000,
      32'hDEAD_BEEF,
      32'hFFFF_0000,
      32'h1234_5678,
      32'h0000_0001
  };
  logic [DataWidth-1:0] db[] = '{
      32'h0000_0000,
      32'h0000_0001,
      32'h0000_0001,
      32'h0000_0001,
      32'h0000_0001,
      32'h8000_0000,
      32'h1234_5678,
      32'h0000_FFFF,
      32'h9ABC_DEF0,
      32'h0000_0001
  };

  initial begin
    #10 rst = 1'b0;
    en = 1'b1;

    // ---- Directed: every op over every corner-case operand pair ----
    foreach (da[k]) foreach (ops[j]) apply(ops[j], da[k], db[k]);

    // ---- Randomized: random op + operands ----
    for (int i = 0; i < 500; ++i) apply(ops[$urandom_range(0, 4)], $urandom, $urandom);

    // Stop feeding and drain both pipelines so every result is checked.
    en = 1'b0;
    repeat (40) @(posedge clk);
    #2;

    // Anything still queued was never produced => lost outputs.
    while (exp_np.size() > 0) begin
      txn_t t;
      t = exp_np.pop_front();
      $display("[FAIL][NOPIPE] missing output for %s a=0x%08h b=0x%08h (exp=0x%08h)", op_name(t.op
               ), t.a, t.b, t.expected);
      fail_cnt++;
    end
    while (exp_ep.size() > 0) begin
      txn_t t;
      t = exp_ep.pop_front();
      $display("[FAIL][XPIPE ] missing output for %s a=0x%08h b=0x%08h (exp=0x%08h)", op_name(t.op
               ), t.a, t.b, t.expected);
      fail_cnt++;
    end

    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED - see [FAIL] lines above", fail_cnt);
    $finish;
  end

endmodule
