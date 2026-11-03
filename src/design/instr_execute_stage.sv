`ifndef verilatorsim
`include "includes/decode.svh"
`include "includes/forwarding.svh"
`else
`include "decode.svh"
`include "forwarding.svh"
`endif

import decode_package::*;
import forwarding_package::*;

// Execute (EX) stage wrapper integrating ALU, branch unit, and operand/forwarding muxes.
module instr_execute_stage #(
    parameter type DATA_T = rv32_data_t
) (
    // Inputs from ID/EX pipeline register
    input  DATA_T            i_ex_pc,
    input  DATA_T            i_ex_rs1_data,
    input  DATA_T            i_ex_rs2_data,
    input  DATA_T            i_ex_imm,
    input  functional_unit_t i_ex_fu_type,
    input  fu_op_t           i_ex_fu_op,
    input  control_data_t    i_ex_ctrl,
    input  logic             i_ex_valid,

    // Forwarding selects from the external forwarding_unit
    input  fwd_sel_t         i_fwd_sel_a,
    input  fwd_sel_t         i_fwd_sel_b,
    // Bypass data from later pipeline stages (produced outside this module)
    input  DATA_T            i_fwd_data_mem,
    input  DATA_T            i_fwd_data_wb,

    // Outputs to EX/MEM pipeline register
    output DATA_T            o_ex_alu_result,
    output logic             o_ex_branch_taken,
    output DATA_T            o_ex_branch_target,
    output DATA_T            o_ex_mem_wdata,
    output functional_unit_t o_ex_fu_type,
    output fu_op_t           o_ex_fu_op,
    output control_data_t    o_ex_ctrl,
    output logic             o_ex_valid
);

  // Forwarding muxes
  DATA_T fwd_rs1_data;
  DATA_T fwd_rs2_data;

  always_comb begin
    case (i_fwd_sel_a)
      FWD_FROM_MEM: fwd_rs1_data = i_fwd_data_mem;
      FWD_FROM_WB:  fwd_rs1_data = i_fwd_data_wb;
      default:      fwd_rs1_data = i_ex_rs1_data;
    endcase
  end

  always_comb begin
    case (i_fwd_sel_b)
      FWD_FROM_MEM: fwd_rs2_data = i_fwd_data_mem;
      FWD_FROM_WB:  fwd_rs2_data = i_fwd_data_wb;
      default:      fwd_rs2_data = i_ex_rs2_data;
    endcase
  end

  // Operand muxes
  DATA_T op_a;
  always_comb begin
    unique case (i_ex_ctrl.FuSrc1)
      REG:     op_a = fwd_rs1_data;
      PC:      op_a = i_ex_pc;
      ZERO:    op_a = '0;
      default: op_a = '0;
    endcase
  end

  DATA_T op_b;
  always_comb begin
    unique case (i_ex_ctrl.FuSrc2)
      REG:     op_b = fwd_rs2_data;
      IMM:     op_b = i_ex_imm;
      default: op_b = '0;
    endcase
  end

  // ALU instance
  DATA_T alu_result_w;
  alu_rv32i #(
      .DATA_T(DATA_T)
  ) alu_inst (
      .i_op_a   (op_a),
      .i_op_b   (op_b),
      .i_fu_type(i_ex_fu_type),
      .i_fu_op  (i_ex_fu_op),
      .o_result (alu_result_w)
  );

  // Branch unit
  DATA_T link_addr_w;
  logic  branch_taken_w;
  branch_unit #(
      .DATA_T(DATA_T)
  ) branch_unit_inst (
      .i_rs1_data     (fwd_rs1_data),
      .i_rs2_data     (fwd_rs2_data),
      .i_pc           (i_ex_pc),
      .i_imm          (i_ex_imm),
      .i_ctrl         (i_ex_ctrl),
      .i_fu_op        (i_ex_fu_op),
      .o_branch_taken (branch_taken_w),
      .o_branch_target(o_ex_branch_target),
      .o_link_addr    (link_addr_w)
  );

  // Stage outputs
  assign o_ex_alu_result   = i_ex_ctrl.Jump ? link_addr_w : alu_result_w;
  assign o_ex_branch_taken = branch_taken_w && i_ex_valid;
  assign o_ex_mem_wdata    = fwd_rs2_data;
  assign o_ex_fu_type      = i_ex_fu_type;
  assign o_ex_fu_op        = i_ex_fu_op;
  assign o_ex_ctrl         = i_ex_ctrl;
  assign o_ex_valid        = i_ex_valid;

endmodule
