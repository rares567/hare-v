`ifndef verilatorsim
`include "includes/decode.svh"
`include "includes/alu.svh"
`else
`include "decode.svh"
`include "alu.svh"
`endif

import decode_package::*;
import alu_package::*;

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

  always_comb begin
    o_result = rv32iAlu::eval(i_op_a, i_op_b, i_fu_type, i_fu_op);
  end

endmodule
