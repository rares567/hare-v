`ifndef verilatorsim
`include "includes/decode.svh"
`else
`include "decode.svh"
`endif

import decode_package::*;

// 2-operand single-cycle Arithmetic Logic Unit (ALU) for RV32I.
//
// Computes arithmetic, logic, shift, comparison, and effective address operations
// on two input operands (i_op_a and i_op_b).
module alu_rv32i #(
    parameter type DATA_T = rv32_data_t
) (
    input  DATA_T            i_op_a,
    input  DATA_T            i_op_b,
    input  functional_unit_t i_fu_type,
    input  fu_op_t           i_fu_op,
    output DATA_T            o_result
);

  localparam int SHAMT_WIDTH = $clog2($bits(DATA_T));

  logic [SHAMT_WIDTH-1:0] shamt;
  assign shamt = i_op_b[SHAMT_WIDTH-1:0];

  always_comb begin
    unique case (i_fu_type)

      // Integer Arithmetic & Logic: ADD, SUB, AND, OR, XOR, LUI, AUIPC
      INT_ALU_UNIT: begin
        unique case (i_fu_op.alu_op)
          ADD_OP:  o_result = i_op_a + i_op_b;
          SUB_OP:  o_result = i_op_a - i_op_b;
          AND_OP:  o_result = i_op_a & i_op_b;
          OR_OP:   o_result = i_op_a | i_op_b;
          XOR_OP:  o_result = i_op_a ^ i_op_b;
          default: o_result = '0;
        endcase
      end

      // Shifts: SLL, SRL, SRA
      SHIFTER_UNIT: begin
        unique case (i_fu_op.shift_op)
          SLL_OP:  o_result = i_op_a << shamt;
          SRL_OP:  o_result = i_op_a >> shamt;
          SRA_OP:  o_result = $signed(i_op_a) >>> shamt;
          default: o_result = '0;
        endcase
      end

      // Comparisons: SLT, SLTU
      COMPARATOR_UNIT: begin
        unique case (i_fu_op.comp_op)
          SLT_OP:  o_result = ($signed(i_op_a) < $signed(i_op_b));
          SLTU_OP: o_result = (i_op_a < i_op_b);
          default: o_result = '0;
        endcase
      end

      // Load/Store Address Calculation: Rs1 + Imm
      LOAD_STORE_UNIT: begin
        o_result = i_op_a + i_op_b;
      end

      default: o_result = '0;

    endcase
  end

endmodule
