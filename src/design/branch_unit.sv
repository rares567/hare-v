`ifndef verilatorsim
`include "includes/decode.svh"
`else
`include "decode.svh"
`endif

import decode_package::*;

// Branch condition evaluation and branch/jump target calculation.
module branch_unit #(
    parameter type DATA_T = rv32_data_t
) (
    input  DATA_T          i_rs1_data,
    input  DATA_T          i_rs2_data,
    input  DATA_T          i_pc,
    input  DATA_T          i_imm,
    input  control_data_t  i_ctrl,
    input  fu_op_t         i_fu_op,

    output logic           o_branch_taken,
    output DATA_T          o_branch_target,
    output DATA_T          o_link_addr
);

  // Link return address is always next sequential instruction PC + 4
  assign o_link_addr = i_pc + 4;

  // Branch condition evaluation and target address generation
  always_comb begin
    o_branch_taken  = 1'b0;
    o_branch_target = '0;

    if (i_ctrl.Jump) begin
      o_branch_taken = 1'b1;
      if (i_fu_op.branch_jump_op == JALR_OP) begin
        // JALR clears LSB per RISC-V spec
        o_branch_target = (i_rs1_data + i_imm) & ~DATA_T'(1);
      end else begin
        o_branch_target = i_pc + i_imm;
      end
    end else if (i_ctrl.Branch) begin
      o_branch_target = i_pc + i_imm;

      unique case (i_fu_op.branch_jump_op)
        BEQ_OP:  o_branch_taken = (i_rs1_data == i_rs2_data);
        BNE_OP:  o_branch_taken = (i_rs1_data != i_rs2_data);
        BLT_OP:  o_branch_taken = ($signed(i_rs1_data) < $signed(i_rs2_data));
        BGE_OP:  o_branch_taken = ($signed(i_rs1_data) >= $signed(i_rs2_data));
        BLTU_OP: o_branch_taken = (i_rs1_data < i_rs2_data);
        BGEU_OP: o_branch_taken = (i_rs1_data >= i_rs2_data);
        default: o_branch_taken = 1'b0;
      endcase
    end
  end

endmodule
