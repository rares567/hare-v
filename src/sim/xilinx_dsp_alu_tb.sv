`ifdef verilatorsim
`include "functional_units.svh"
`else
`include "../design/includes/functional_units.svh"
`endif`timescale 1ns/1ps

// Testbench for xilinx_dsp_alu (DSP48E2 / ULTRASCALE implementation).
//
// The unit computes A op B for op in {ADD, SUB, AND, OR, XOR} inside DSP slices.
// For DATA_WIDTH <= 48 a single DSP is used (fixed 2-cycle latency). For wider
// data the operand is split into 48-bit slices whose add/sub carry ripples
// through CARRYCASCOUT->CARRYCASCIN; that path is NOT fully pipelined, so the
// stimulus holds every operand pair stable and samples the result only after it
// has settled (see SETTLE below). A software reference model predicts each
// result and a self-checking comparison flags any mismatch.
//
// Two DUTs are instantiated -- 32-bit (single DSP) and 64-bit (two cascaded
// DSPs) -- and driven with the same directed corners plus randomized vectors.
//
// NOTE: the behavioural DSP48E2 model shipped in verilog_xilinx.svh does not
// route the real add/sub carry on CARRYCASCOUT for the non-multiplier path, so
// the cross-slice (64-bit) add/sub cases only pass on a full DSP model such as
// the Vivado/xsim UNISIM. The 32-bit cases and all logic ops pass everywhere.

module xilinx_dsp_alu_tb;
  import decode_package::*;

  // number of cycles to hold an operand pair before sampling the result;
  // comfortably covers the single-DSP latency (2) and the 64-bit carry ripple.
  localparam int SETTLE = 12;

  logic    clk;
  logic    rst;

  // ---------------------------------------------------------------------
  // DUTs
  // ---------------------------------------------------------------------
  alu_op_t op32;
  logic [31:0] a32, b32, p32;
  logic co32;

  xilinx_dsp_alu #(
      .DATA_WIDTH (32),
      .FPGA_FAMILY("ARTIX7")
  ) dut32 (
      .clk,
      .rst,
      .ALUMODE(op32),
      .A(a32),
      .B(b32),
      .P(p32),
      .CARRYOUT(co32)
  );

  alu_op_t op64;
  logic [63:0] a64, b64, p64;
  logic co64;

  xilinx_dsp_alu #(
      .DATA_WIDTH (64),
      .FPGA_FAMILY("ARTIX7")
  ) dut64 (
      .clk,
      .rst,
      .ALUMODE(op64),
      .A(a64),
      .B(b64),
      .P(p64),
      .CARRYOUT(co64)
  );

  // ---------------------------------------------------------------------
  // Reference model
  // ---------------------------------------------------------------------
  function automatic logic [63:0] alu_ref(input alu_op_t op, input logic [63:0] a,
                                          input logic [63:0] b, input int w);
    logic [63:0] r;
    case (op)
      ADD_OP:  r = a + b;
      SUB_OP:  r = a - b;
      AND_OP:  r = a & b;
      OR_OP:   r = a | b;
      XOR_OP:  r = a ^ b;
      default: r = '0;
    endcase
    // keep only the low w bits (unused upper bits are don't-care)
    alu_ref = (w >= 64) ? r : (r & ((64'd1 << w) - 64'd1));
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

  int pass_cnt = 0;
  int fail_cnt = 0;

  // ---------------------------------------------------------------------
  // Drive-and-check tasks: hold the operands, wait for settle, then compare
  // ---------------------------------------------------------------------
  task automatic check32(input alu_op_t op, input logic [31:0] a, input logic [31:0] b);
    logic [31:0] exp;
    op32 = op;
    a32  = a;
    b32  = b;
    repeat (SETTLE) @(posedge clk);
    #1;
    exp = alu_ref(op, {32'b0, a}, {32'b0, b}, 32);
    if (p32 !== exp) begin
      $display("[FAIL][32 %s] a=0x%08h b=0x%08h : got=0x%08h exp=0x%08h", op_name(op), a, b, p32,
               exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  task automatic check64(input alu_op_t op, input logic [63:0] a, input logic [63:0] b);
    logic [63:0] exp;
    op64 = op;
    a64  = a;
    b64  = b;
    repeat (SETTLE) @(posedge clk);
    #1;
    exp = alu_ref(op, a, b, 64);
    if (p64 !== exp) begin
      $display("[FAIL][64 %s] a=0x%016h b=0x%016h : got=0x%016h exp=0x%016h", op_name(op), a, b,
               p64, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  // ---------------------------------------------------------------------
  // Clock / reset
  // ---------------------------------------------------------------------
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, xilinx_dsp_alu_tb);
    clk = 1'b0;
    rst = 1'b1;
    forever #5 clk = ~clk;
  end

  // ---------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------
  alu_op_t ops[5] = '{ADD_OP, SUB_OP, AND_OP, OR_OP, XOR_OP};

  // directed 32-bit operand pairs (corners + carry/borrow across 16-bit halves)
  logic [31:0] da32[] = '{
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
  logic [31:0] db32[] = '{
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

  // directed 64-bit operand pairs (corners + carry/borrow across the 48-bit
  // slice boundary and within a slice)
  logic [63:0] da64[] = '{
      64'h0000_0000_0000_0000,
      64'hFFFF_FFFF_FFFF_FFFF,
      64'h0000_FFFF_FFFF_FFFF,
      64'h0001_0000_0000_0000,
      64'h0000_0000_FFFF_FFFF,
      64'h8000_0000_0000_0000,
      64'h1234_5678_9ABC_DEF0,
      64'h0000_0000_0000_0005,
      64'hFFFF_FFFF_FFFF_0000,
      64'h7FFF_FFFF_FFFF_FFFF
  };
  logic [63:0] db64[] = '{
      64'h0000_0000_0000_0000,
      64'h0000_0000_0000_0001,
      64'h0000_0000_0000_0001,
      64'h0000_0000_0000_0001,
      64'h0000_0000_0000_0001,
      64'h8000_0000_0000_0000,
      64'h0FED_CBA9_8765_4321,
      64'h0000_0000_0000_000A,
      64'h0000_0000_0000_FFFF,
      64'h0000_0000_0000_0001
  };

  initial begin
    //wait 100ns for GSR(Global Set Reset) to be asserted -> this controls the system reset of the DSP in simulation
    repeat (12) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);

    // ---- directed: every op over every corner-case operand pair ----
    foreach (da32[k]) foreach (ops[j]) check32(ops[j], da32[k], db32[k]);

    foreach (da64[k]) foreach (ops[j]) check64(ops[j], da64[k], db64[k]);

    // ---- randomized ----
    for (int i = 0; i < 200; ++i) begin
      alu_op_t rop = ops[$urandom_range(0, 4)];
      check32(rop, $urandom, $urandom);
      check64(rop, {$urandom, $urandom}, {$urandom, $urandom});
    end

    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED - see [FAIL] lines above", fail_cnt);
    $finish;
  end

endmodule
