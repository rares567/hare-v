/*
`include "decode.svh"
import decode_package::*;

module instruction_decode#(
        parameter type DATA_T = bit [31:0],
        parameter type DECODER_T = rv32iDecoder,
        localparam type DECODED_INSTR_T = DECODER_T::decoded_instruction_t
    )(
      
    );


endmodule

module instr_issue_stage#(
    parameter type DATA_T = bit [31:0],
    parameter type DECODER_T = rv32iDecoder,
    parameter int ROBTAG_WIDTH = 32,
    localparam int NUM_REGS = 32
)(
    input logic clk,
    input logic rst,
    // this comes from a hazard detection unit
    input  logic                       i_stall_pipeline,
    input  logic                       i_flush_pipeline,
    //input data from instruction fetch stage
    input logic [ILEN-1:0]             i_instruction,
    input DATA_T                       i_pc,
    //input data from instruction commit stage
    input logic                        i_rd_write,
    input logic [$clog2(NUM_REGS)-1:0] i_rd_reg,
    input DATA_T                       i_rd_data,
    input logic [ROBTAG_WIDTH-1:0]     i_rd_tag,
    //output data to instruction scheduling stage
    output logic                       o_instr_valid,
    output logic [ROBTAG_WIDTH-1:0]    o_rd_tag,
    output DATA_T                      o_rs1_data,
    output DATA_T                      o_rs2_data,
    output DATA_T                      o_imm_data,
    output DATA_T                      o_pc,
    output logic [ROBTAG_WIDTH-1:0]    o_rs1_tag,
    output logic [ROBTAG_WIDTH-1:0]    o_rs2_tag,
    output logic                       o_rs1_ready,
    output logic                       o_rs2_ready,
    output functional_unit_t           o_fu_type,
    output fu_op_t                     o_fu_op
);
   

endmodule


module instr_dispatch_stage();


endmodule
*/
