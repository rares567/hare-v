`ifndef verilatorsim
`include "includes/decode.svh"
`else
`include "decode.svh"
`endif

import decode_package::*;

// Instruction Decode (ID) stage.
// Decodes the fetched instruction and reads register operands from the regfile.
module instr_decode_stage #(
    parameter type DATA_T = rv32_data_t,
    parameter int  NUM_REGS = 32
) (
    input  logic                             clk,
    (*direct_reset="true"*) input logic      rst,

    // From IF/ID pipeline register
    input  instruction_t                     i_if_id_instr,
    input  DATA_T                            i_if_id_pc,
    input  logic                             i_if_id_valid,

    // From WB stage
    input  logic                             i_wb_regwrite,
    input  logic  [$clog2(NUM_REGS)-1:0]     i_wb_rd,
    input  DATA_T                            i_wb_data,

    // To ID/EX pipeline register
    output DATA_T                            o_id_pc,
    output DATA_T                            o_id_rs1_data,
    output DATA_T                            o_id_rs2_data,
    output DATA_T                            o_id_imm,
    output logic  [$clog2(NUM_REGS)-1:0]     o_id_rs1_addr,
    output logic  [$clog2(NUM_REGS)-1:0]     o_id_rs2_addr,
    output logic  [$clog2(NUM_REGS)-1:0]     o_id_rd_addr,
    output functional_unit_t                 o_id_fu_type,
    output fu_op_t                           o_id_fu_op,
    output control_data_t                    o_id_ctrl,
    output logic                             o_id_valid
);

  rv32i_decoded_instruction_t decoded_w;

  decoder_rv32i decoder_inst (
      .i_instr(i_if_id_instr),
      .i_pc(i_if_id_pc),
      .o_decoded(decoded_w)
  );

  register_bank_inorder #(
      .DATA_T(DATA_T),
      .NUM_REGS(NUM_REGS)
  ) regfile_inst (
      .clk(clk),
      .rst(rst),
      .i_we(i_wb_regwrite),
      .i_waddr(i_wb_rd),
      .i_wdata(i_wb_data),
      .i_raddr1(decoded_w.Rs1),
      .i_raddr2(decoded_w.Rs2),
      .o_rdata1(o_id_rs1_data),
      .o_rdata2(o_id_rs2_data)
  );

  // Assign combinational stage outputs
  assign o_id_pc       = decoded_w.Pc;
  assign o_id_imm      = decoded_w.Imm;
  assign o_id_rs1_addr = decoded_w.Rs1;
  assign o_id_rs2_addr = decoded_w.Rs2;
  assign o_id_rd_addr  = decoded_w.Rd;
  assign o_id_fu_type  = decoded_w.FunctionalUnitType;
  assign o_id_fu_op    = decoded_w.FunctionalUnitOp;
  assign o_id_ctrl     = decoded_w.ControlData;
  assign o_id_valid    = i_if_id_valid;

endmodule
