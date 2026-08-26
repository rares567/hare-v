`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns/1ps

// Dedicated Unit Testbench for alu_rv32i (Pure 2-Operand ALU).
//
// Verification suite:
// 1. Integer Arithmetic (ADD, SUB) with signed/unsigned overflow, carry ripple, corner cases
// 2. Bitwise Logic Operations (AND, OR, XOR) with masks, identities, inversions
// 3. Barrel Shift Operations (SLL, SRL, SRA) across all shift amounts [0..31] and negative MSB sign extension
// 4. Set-Less-Than Comparisons (SLT signed, SLTU unsigned) across boundary and extreme values
// 5. Load / Store address calculation (A + B)
// 6. Shift amount masking (shamt > 31 uses lower 5 bits)
// 7. Exhaustive randomized fuzzing (500 iterations) against an independent golden software model

module alu_rv32i_tb;
  import decode_package::*;

  // -------------------------------------------------------------------------
  // Stimulus & DUT Signals
  // -------------------------------------------------------------------------
  rv32_data_t        i_op_a;
  rv32_data_t        i_op_b;
  functional_unit_t  i_fu_type;
  fu_op_t            i_fu_op;
  rv32_data_t        o_result;

  alu_rv32i #(
      .DATA_T(rv32_data_t)
  ) dut (
      .i_op_a   (i_op_a),
      .i_op_b   (i_op_b),
      .i_fu_type(i_fu_type),
      .i_fu_op  (i_fu_op),
      .o_result (o_result)
  );

  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic chk(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("[FAIL] %-58s got=0x%08h exp=0x%08h", what, got, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  // -------------------------------------------------------------------------
  // Golden Reference Model for pure 2-operand ALU
  // -------------------------------------------------------------------------
  function automatic rv32_data_t alu_ref(
      input rv32_data_t a,
      input rv32_data_t b,
      input functional_unit_t fu_type,
      input fu_op_t fu_op
  );
    logic [4:0] shamt = b[4:0];
    case (fu_type)
      INT_ALU_UNIT: begin
        case (fu_op.alu_op)
          ADD_OP:  return a + b;
          SUB_OP:  return a - b;
          AND_OP:  return a & b;
          OR_OP:   return a | b;
          XOR_OP:  return a ^ b;
          default: return 32'h0;
        endcase
      end
      SHIFTER_UNIT: begin
        case (fu_op.shift_op)
          SLL_OP:  return a << shamt;
          SRL_OP:  return a >> shamt;
          SRA_OP:  return $signed(a) >>> shamt;
          default: return 32'h0;
        endcase
      end
      COMPARATOR_UNIT: begin
        case (fu_op.comp_op)
          SLT_OP:  return ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;
          SLTU_OP: return (a < b)                   ? 32'h1 : 32'h0;
          default: return 32'h0;
        endcase
      end
      LOAD_STORE_UNIT: return a + b;
      default: return 32'h0;
    endcase
  endfunction

  task automatic test_alu_op(
      input string name,
      input rv32_data_t a,
      input rv32_data_t b,
      input functional_unit_t fu_type,
      input fu_op_t fu_op
  );
    rv32_data_t exp;
    i_op_a    = a;
    i_op_b    = b;
    i_fu_type = fu_type;
    i_fu_op   = fu_op;
    #1;
    exp = alu_ref(a, b, fu_type, fu_op);
    chk(name, o_result, exp);
  endtask

  // -------------------------------------------------------------------------
  // Main Test Sequence
  // -------------------------------------------------------------------------
  initial begin
    fu_op_t op;
    $display("=== STARTING DEDICATED ALU_RV32I UNIT VERIFICATION ===");

    // =========================================================================
    // Test Group 1: Integer Arithmetic (ADD, SUB)
    // =========================================================================
    $display("\n--- Test Group 1: Integer Arithmetic ---");
    op.alu_op = ADD_OP;
    test_alu_op("ADD 10 + 20", 32'd10, 32'd20, INT_ALU_UNIT, op);
    test_alu_op("ADD zero left", 32'd0, 32'h1234_5678, INT_ALU_UNIT, op);
    test_alu_op("ADD zero right", 32'h1234_5678, 32'd0, INT_ALU_UNIT, op);
    test_alu_op("ADD max signed + 1", 32'h7FFF_FFFF, 32'd1, INT_ALU_UNIT, op);
    test_alu_op("ADD all ones + 1", 32'hFFFF_FFFF, 32'd1, INT_ALU_UNIT, op);
    test_alu_op("ADD carry ripple", 32'h0000_FFFF, 32'h0000_0001, INT_ALU_UNIT, op);

    op.alu_op = SUB_OP;
    test_alu_op("SUB 50 - 20", 32'd50, 32'd20, INT_ALU_UNIT, op);
    test_alu_op("SUB 20 - 50", 32'd20, 32'd50, INT_ALU_UNIT, op);
    test_alu_op("SUB identity x - x", 32'hDEAD_BEEF, 32'hDEAD_BEEF, INT_ALU_UNIT, op);
    test_alu_op("SUB 0 - 1", 32'd0, 32'd1, INT_ALU_UNIT, op);
    test_alu_op("SUB min signed - 1", 32'h8000_0000, 32'd1, INT_ALU_UNIT, op);

    // =========================================================================
    // Test Group 2: Logic Operations (AND, OR, XOR)
    // =========================================================================
    $display("\n--- Test Group 2: Logic Operations ---");
    op.alu_op = AND_OP;
    test_alu_op("AND bitmask", 32'hFFFF_0000, 32'h0FF0_0FF0, INT_ALU_UNIT, op);
    test_alu_op("AND with zero", 32'hFFFF_FFFF, 32'h0000_0000, INT_ALU_UNIT, op);
    test_alu_op("AND with all-ones", 32'h1234_5678, 32'hFFFF_FFFF, INT_ALU_UNIT, op);

    op.alu_op = OR_OP;
    test_alu_op("OR bitmask", 32'hF0F0_0000, 32'h0F0F_0000, INT_ALU_UNIT, op);
    test_alu_op("OR with zero", 32'h1234_5678, 32'h0000_0000, INT_ALU_UNIT, op);

    op.alu_op = XOR_OP;
    test_alu_op("XOR identical", 32'hAAAA_5555, 32'hAAAA_5555, INT_ALU_UNIT, op);
    test_alu_op("XOR invert", 32'hAAAA_5555, 32'hFFFF_FFFF, INT_ALU_UNIT, op);

    // =========================================================================
    // Test Group 3: Shift Operations (SLL, SRL, SRA)
    // =========================================================================
    $display("\n--- Test Group 3: Shift Operations ---");
    for (int sh = 0; sh < 32; sh++) begin
      op.shift_op = SLL_OP;
      test_alu_op($sformatf("SLL by %0d", sh), 32'h0000_0001, sh, SHIFTER_UNIT, op);
      op.shift_op = SRL_OP;
      test_alu_op($sformatf("SRL by %0d", sh), 32'h8000_0000, sh, SHIFTER_UNIT, op);
      op.shift_op = SRA_OP;
      test_alu_op($sformatf("SRA neg by %0d", sh), 32'h8000_0000, sh, SHIFTER_UNIT, op);
      test_alu_op($sformatf("SRA pos by %0d", sh), 32'h7FFF_FFFF, sh, SHIFTER_UNIT, op);
    end

    // Shift amount masking with high bits set (shamt[4:0])
    op.shift_op = SLL_OP;
    test_alu_op("SLL shamt 36 (mask to 4)", 32'h0000_0001, 32'd36, SHIFTER_UNIT, op);
    op.shift_op = SRL_OP;
    test_alu_op("SRL shamt 65 (mask to 1)", 32'h8000_0000, 32'd65, SHIFTER_UNIT, op);
    op.shift_op = SRA_OP;
    test_alu_op("SRA shamt 95 (mask to 31)", 32'h8000_0000, 32'd95, SHIFTER_UNIT, op);

    // =========================================================================
    // Test Group 4: Comparisons (SLT, SLTU)
    // =========================================================================
    $display("\n--- Test Group 4: Comparisons ---");
    op.comp_op = SLT_OP;
    test_alu_op("SLT 5 < 10", 32'd5, 32'd10, COMPARATOR_UNIT, op);
    test_alu_op("SLT 10 < 5", 32'd10, 32'd5, COMPARATOR_UNIT, op);
    test_alu_op("SLT 5 == 5", 32'd5, 32'd5, COMPARATOR_UNIT, op);
    test_alu_op("SLT -10 < 5 (neg < pos)", -32'd10, 32'd5, COMPARATOR_UNIT, op);
    test_alu_op("SLT 5 < -10 (pos < neg)", 32'd5, -32'd10, COMPARATOR_UNIT, op);
    test_alu_op("SLT -10 < -5 (neg < neg)", -32'd10, -32'd5, COMPARATOR_UNIT, op);
    test_alu_op("SLT MIN_SIGNED < MAX_SIGNED", 32'h8000_0000, 32'h7FFF_FFFF, COMPARATOR_UNIT, op);
    test_alu_op("SLT MAX_SIGNED < MIN_SIGNED", 32'h7FFF_FFFF, 32'h8000_0000, COMPARATOR_UNIT, op);

    op.comp_op = SLTU_OP;
    test_alu_op("SLTU 5 < 10", 32'd5, 32'd10, COMPARATOR_UNIT, op);
    test_alu_op("SLTU 10 < 5", 32'd10, 32'd5, COMPARATOR_UNIT, op);
    test_alu_op("SLTU 0xFFFFFFFF < 1", 32'hFFFF_FFFF, 32'd1, COMPARATOR_UNIT, op);
    test_alu_op("SLTU 1 < 0xFFFFFFFF", 32'd1, 32'hFFFF_FFFF, COMPARATOR_UNIT, op);
    test_alu_op("SLTU 0 < 0xFFFFFFFF", 32'h0000_0000, 32'hFFFF_FFFF, COMPARATOR_UNIT, op);

    // =========================================================================
    // Test Group 5: Load / Store Effective Address Calculation
    // =========================================================================
    $display("\n--- Test Group 5: Load / Store Address Calculation ---");
    test_alu_op("LOAD_STORE_UNIT base + 0", 32'h2000_0000, 32'd0, LOAD_STORE_UNIT, op);
    test_alu_op("LOAD_STORE_UNIT base + offset", 32'h2000_0000, 32'd64, LOAD_STORE_UNIT, op);
    test_alu_op("LOAD_STORE_UNIT base - offset", 32'h2000_0100, -32'd16, LOAD_STORE_UNIT, op);

    // =========================================================================
    // Test Group 6: Randomized Fuzzing (500 iterations)
    // =========================================================================
    $display("\n--- Test Group 6: Randomized Fuzzing against Golden Model ---");
    for (int iter = 0; iter < 500; iter++) begin
      automatic rv32_data_t r_a = $urandom();
      automatic rv32_data_t r_b = $urandom();
      functional_unit_t rand_fu;
      fu_op_t rand_op;

      case ($urandom_range(0, 3))
        0: begin
          rand_fu = INT_ALU_UNIT;
          case ($urandom_range(0, 4))
            0: rand_op.alu_op = ADD_OP;
            1: rand_op.alu_op = SUB_OP;
            2: rand_op.alu_op = AND_OP;
            3: rand_op.alu_op = OR_OP;
            4: rand_op.alu_op = XOR_OP;
          endcase
        end
        1: begin
          rand_fu = SHIFTER_UNIT;
          case ($urandom_range(0, 2))
            0: rand_op.shift_op = SLL_OP;
            1: rand_op.shift_op = SRL_OP;
            2: rand_op.shift_op = SRA_OP;
          endcase
        end
        2: begin
          rand_fu = COMPARATOR_UNIT;
          case ($urandom_range(0, 1))
            0: rand_op.comp_op = SLT_OP;
            1: rand_op.comp_op = SLTU_OP;
          endcase
        end
        3: begin
          rand_fu = LOAD_STORE_UNIT;
        end
      endcase

      test_alu_op($sformatf("RAND_%0d", iter), r_a, r_b, rand_fu, rand_op);
    end

    #10;
    $display("\n==========================================================================");
    $display("ALU_RV32I UNIT TEST SUMMARY: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("==========================================================================");

    if (fail_cnt > 0) $fatal(1, "TEST FAILED WITH %0d ERRORS", fail_cnt);
    else $display("ALL %0d CHECKS PASSED PERFECTLY", pass_cnt);

    $finish;
  end

endmodule
