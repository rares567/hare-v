/*
`ifdef verilatorsim
`include "interfaces.svh"
`include "decode.svh"
`else
`include "includes/interfaces.svh"
`include "includes/decode.svh"
`endif
import decode_package::*;

module program_counter #(
    parameter type DATA_T = decode_package::rv32_data_t,
    parameter DATA_T START_ADDRESS = 0
) (
    input logic clk,
    (*direct_reset="true"*) input logic rst,
    (*direct_enable="true"*) input logic i_en,
    input DATA_T i_data,
    output DATA_T o_data
);


  always_ff @(posedge clk) begin
    if (rst) o_data <= START_ADDRESS;
    else if (i_en) begin
      o_data <= i_data;
    end
  end

endmodule


module next_address_generator #(
    parameter type DATA_T = decode_package::rv32_data_t
) (
    input  logic  i_is_branch,
    input  logic  i_is_jump,
    input  logic  i_take_branch,  //resut comming from Execute stage from an ALU unit
    input  DATA_T i_current_pc,
    input  DATA_T i_jump_pc,
    output DATA_T o_next_pc
);

  //currently this is just a mux, but branch prediction logic can be implemented here
  logic take_jump;
  assign take_jump = i_is_jump | (i_is_branch & i_take_branch);
  assign o_next_pc = take_jump ? i_jump_pc : i_current_pc + DATA_T'(4'h4);

endmodule


//should be able to be parameterized to support multiple instruction fetch and issue
module instruction_fetch_controller #(
    parameter int PC_FIFO_DEPTH = 4,
    parameter type DATA_T = decode_package::rv32_data_t,
    parameter type PACKET_T = decode_package::rv32_instr_pc_packet_t,
    parameter int DEBUG = 1
) (
    input logic clk,
    input logic rst,

    //current PC
    input DATA_T i_pc,

    //signal comming from a hazard detection unit or scorboard that we should flush all queued instructions
    input logic i_flush_pipeline,

    //write enable signal for PC to allow it to update with the next address, or to stall it
    output logic o_pc_we,

    //wishbone interface to Instruction Memory (can be main, cache, etc)
    wishboneIf.Master wb_imem,

    //output data and ready-valid signal that can go to next stage (usually instruction decode)
    handshakeIf.Downstream hs_decode
);

  //make sure that we can output the right amount of data which should be an instruction and its PC
  initial assert ($bits(i_pc) + ILEN == $bits(hs_decode.data));

  logic w_pc_fifo_full, w_pc_fifo_empty;
  DATA_T w_pc;
  sync_fifo #(
      .DEPTH(PC_FIFO_DEPTH),
      .DATA_T(DATA_T),
      .DEBUG(DEBUG),
      .FIFO_NAME("IF_PC_FIFO")
  ) pc_fifo_inst (
      .clk(clk),
      .rst(rst),
      .i_clear(i_flush_pipeline),
      .i_wr_en(o_pc_we),  // Write enable
      .i_rd_en(hs_decode.valid & hs_decode.ready),  // Read enable
      .i_data(i_pc),  // Data written into FIFO
      .o_data(w_pc),  // Data read from FIFO
      .o_empty(w_pc_fifo_empty),  // FIFO is empty when high
      .o_full(w_pc_fifo_full)  // FIFO is full when high
  );

  assign o_pc_we = ~wb_imem.stall & ~i_flush_pipeline & ~w_pc_fifo_full;
  assign wb_imem.cyc = 1'b1;  //can always be maintained on high
  assign wb_imem.sel = '1;  //we need all the bytes, all the time
  assign wb_imem.wr = '0;  //should never write to imem 
  assign wb_imem.stb = ~wb_imem.stall & ~i_flush_pipeline & hs_decode.ready;

  PACKET_T if_data;
  assign if_data.instr = wb_imem.data_rd;
  assign if_data.pc = w_pc;
  assign hs_decode.data = if_data;
  assign hs_decode.valid = wb_imem.ack & wb_imem.cyc & ~wb_imem.err & ~w_pc_fifo_empty;

endmodule

module instr_fetch_stage #(
    parameter type DATA_T = decode_package::rv32_data_t,
    parameter int ADDR_WIDTH = 12,
    parameter DATA_T START_ADDRESS = 0
) (
    //system signals
    input logic clk,
    input logic rst,
    // these come from branch/jump unit
    input logic i_is_branch,  //control signal decoded from instruction in Decode Stage
    input logic i_is_jump,  //control signal decoded from instruction in Decode Stage
    input logic i_take_branch,  //branch condition resut comming from Execute stage from an ALU unit
    input DATA_T i_jump_pc,  //branch or jal(r) computed address coming from Execute stage
    // this comes from a hazard detection unit/scoreboard
    input logic i_flush_pipeline,
    //wishbone interface to Instruction Memory (can be main, cache, etc)
    wishboneIf.Master wb_imem,
    //these goes further to the Instruction Decode stage
    handshakeIf.Downstream hs_decode
);

  //stage 1 - send current pc to instr memory and compute next address,
  DATA_T current_address, next_address;
  logic pc_we;
  program_counter #(
      .DATA_T(DATA_T),
      .START_ADDRESS(START_ADDRESS)
  ) program_counter_inst (
      .clk(clk),
      .rst(rst),
      .i_en(pc_we),
      .i_data(next_address),
      .o_data(current_address)
  );

  next_address_generator #(
      .DATA_T(DATA_T)
  ) next_address_generator_inst (
      .i_is_jump(i_is_jump),
      .i_is_branch(i_is_branch),
      .i_take_branch(i_take_branch),
      .i_current_pc(current_address),
      .i_jump_pc(i_jump_pc),
      .o_next_pc(next_address)
  );

  if (type (DATA_T) == type (rv32_data_t)) begin
    localparam type packet_t = decode_package::rv32_instr_pc_packet_t;
    instruction_fetch_controller #(
        .DATA_T(DATA_T),
        .PACKET_T(packet_t),
        .PC_FIFO_DEPTH(4)
    ) if_controller_inst (
        .clk(clk),
        .rst(rst),
        .i_flush_pipeline(i_flush_pipeline),
        .o_pc_we(pc_we),
        .wb_imem(wb_imem),
        .hs_decode(hs_decode)
    );
  end else begin
    localparam type packet_t = decode_package::rv32_instr_pc_packet_t;
    instruction_fetch_controller #(
        .DATA_T(DATA_T),
        .PACKET_T(packet_t),
        .PC_FIFO_DEPTH(4)
    ) if_controller_inst (
        .clk(clk),
        .rst(rst),
        .i_flush_pipeline(i_flush_pipeline),
        .o_pc_we(pc_we),
        .wb_imem(wb_imem),
        .hs_decode(hs_decode)
    );
  end

endmodule
*/
