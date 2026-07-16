`include "decode.svh"
import decode_package::*;

class RVFrontend #(
    parameter type DATA_T = decode_package::rv32_data_t,
    parameter type DECODER_T = decode_package::rv32iDecoder
);

  localparam int ROBTAG_WIDTH = $clog2(ROB_DEPTH);

  typedef struct {
    DATA_T regs[32];
    bit free[32];
    bit [ROBTAG_WIDTH-1:0] tag;
    semaphore locks[32];
  } regfile_t;

  typedef struct {
    fu_op_t OpType;
    DATA_T Rs1Data;
    DATA_T Rs2Data;
    bit Rs1Ready;
    bit Rs2Ready;
    bit [ROBTAG_WIDTH-1:0] Rs1Tag;
    bit [ROBTAG_WIDTH-1:0] Rs2Tag;
    bit [4:0] RdAddr;
    bit [ROBTAG_WIDTH-1:0] RdTag;
    decode_package::control_data_t ControlData;
    DATA_T Pc;
    DATA_T Imm;
  } fu_packet_t;

  //ports/queues to each functional unit type
  fu_packet_t functional_units[functional_unit_t][$];

  //regsiter bank
  protected regfile_t regfile;

  //access to memory map for ICache 
  protected MemoryMap #(.DATA_T(DATA_T)) memory_map;

  //current program counter
  protected DATA_T pc = '0;

  //queue of decoded instructions ready to be dispatched by a scheduler
  DECODER_T::decoded_instruction_t instruction_queue[$];
  DECODER_T decoder;

  function new();

    //initialize memory map and decoder
    this.memory_map = MemoryMap::get();
    this.decoder = new();

    //initialize reg file
    for (int i = 0; i < 32; i++) begin
      this.regfile.regs[i]  = '0;
      this.regfile.free[i]  = '1;
      this.regfile.tag[i]   = '0;
      this.regfile.locks[i] = new(1);
    end

    //initialize one funtional unit of each type
    this.functional_units = '{
        INT_ALU_UNIT: '{default: '0},
        BRANCH_JUMP_UNIT: '{default: '0},
        LOAD_STORE_UNIT: '{default: '0},
        SHIFTER_UNIT: '{default: '0},
        COMPARATOR_UNIT: '{default: '0},
        MUL_DIV_UNIT: '{default: '0}
    };

  endfunction

  function automatic void setPC(DATA_T start_address);
    this.pc = start_address;
  endfunction

  function automatic bit instrQueueEmpty();
    return this.instruction_queue.size() == 0;
  endfunction

  function automatic DECODER_T::decoded_instruction_t getNextInstruction();
    return this.instruction_queue[0];
  endfunction

  //fetches and outputs a single instruction every clock cycle
  //if there is a control hazard it will stall, otherwise it jumps to the new pc immediately
  function automatic void stallingFetchAndDecode();

    DATA_T new_pc = pc + 4;  //assume normal flow

    //read and decode instruction
    decode_package::instruction_t current_instr = instruction_t'(memory_map.read(
        this.pc, 8'hF
    ).data);
    DECODER_T::decoded_instruction_t decoded_instr;
    decoded_instr = this.decoder.decodeInstruction(current_instr);

    //check if instruction is a branch/jump and fetch next pc
    if (decoded_instr.FunctionalUnitType == BRANCH_JUMP_UNIT) begin
      if (decoded_instr.FunctionalUnitOp == JAL_OP) begin
        new_pc = this.pc + decoded_instr.Imm;
        this.setRegisterBusy(
            decoded_instr.Rd);  //mark it busy as early as possible in case there is a quick return
      end else if (decoded_instr.FunctionalUnitOp == JALR_OP) begin
        DATA_T rs1_data;
        bit rs1_ready;
        this.readRegister(.i_rs_addr(decoded_instr.Rs1), .o_rs_ready(rs1_ready),
                          .o_rs_data(rs1_data));

        if (!rs1_ready) begin
          return;
        end

        this.setRegisterBusy(
            decoded_instr.Rd);  //mark it busy as early as possible in case there is a quick return
        new_pc = rs1_data + decoded_instr.Imm;
        new_pc[0] = '0;  //jalr specification
      end else begin
        DATA_T rs1_data, rs2_data;
        bit rs1_ready, rs2_ready;
        this.readRegisters(.i_rs1_addr(decoded_instr.Rs1), .o_rs1_ready(rs1_ready),
                           .o_rs1_data(rs1_data), .i_rs2_addr(decoded_instr.Rs2),
                           .o_rs2_ready(rs2_ready), .o_rs2_data(rs2_data));

        if (!rs1_ready || !rs2_ready) begin
          return;
        end

        unique case (decoded_instr.FunctionalUnitOp.branch_jump_op)
          BEQ_OP:  if (rs1_data == rs2_data) new_pc = this.pc + decoded_instr.Imm;
          BNE_OP:  if (rs1_data != rs2_data) new_pc = this.pc + decoded_instr.Imm;
          BLT_OP:  if (signed'(rs1_data) < signed'(rs2_data)) new_pc = this.pc + decoded_instr.Imm;
          BGE_OP:  if (signed'(rs1_data) >= signed'(rs2_data)) new_pc = this.pc + decoded_instr.Imm;
          BLTU_OP: if (rs1_data < rs2_data) new_pc = this.pc + decoded_instr.Imm;
          BGEU_OP: if (rs1_data >= rs2_data) new_pc = this.pc + decoded_instr.Imm;
          default: new_pc = this.pc + 4;
        endcase
      end
    end

    //push current decoded instruction into queue
    this.instruction_queue.push_back(decoded_instr);

    //update pc
    this.pc = new_pc;
  endfunction

  function automatic void inorderDispatch(bit [ROBTAG_WIDTH-1:0] rd_robtag);
    if (this.instruction_queue.size() > 0) begin

      //consume instruction and dispatch it to the FU
      DECODER_T::decoded_instruction_t top_instr = this.instruction_queue.pop_front();
      //prepare pkt to be sent to a functional unit
      fu_packet_t pkt = '{default: '0};
      //read data from register file
      DATA_T rs1_data, rs2_data;
      bit rs1_ready, rs2_ready;
      bit [ROBTAG_WIDTH-1:0] rs1_tag, rs2_tag;

      this.readRegisters(.i_rs1_addr(top_instr.Rs1), .i_rs2_addr(top_instr.Rs2),
                         .o_rs1_data(rs1_data), .o_rs2_data(rs2_data), .o_rs1_ready(rs1_ready),
                         .o_rs2_ready(rs2_ready), .o_rs1_tag(rs1_tag), .o_rs2_tag(rs2_tag));

      //mark rd reg as busy
      this.allocateRegister(top_instr.Rd, rd_robtag);

      //fill packet for FU
      pkt.OpType      = top_instr.FunctionalUnitOp;
      pkt.Rs1Data     = rs1_data;
      pkt.Rs2Data     = rs2_data;
      pkt.Rs1Ready    = rs1_ready;
      pkt.Rs2Ready    = rs2_ready;
      pkt.Rs1Tag      = rs1_tag;
      pkt.Rs2Tag      = rs2_tag;
      pkt.RdAddr      = top_instr.Rd;
      pkt.RdTag       = rd_robtag;
      pkt.ControlData = top_instr.ControlData;
      pkt.Pc          = top_instr.Pc;
      pkt.Imm         = top_instr.Imm;

      //dispath it in the queue of the FU
      this.functional_units[top_instr.FunctionalUnitType].push_back(pkt);
    end
  endfunction


  function automatic void readRegisters(
      input bit [4:0] i_rs1_addr, input bit [4:0] i_rs2_addr, output DATA_T o_rs1_data,
      output DATA_T o_rs2_data, output bit o_rs1_ready, output bit o_rs2_ready,
      output bit [ROBTAG_WIDTH-1:0] o_rs1_tag, output bit [ROBTAG_WIDTH-1:0] o_rs2_tag);

    o_rs1_data  = this.regfile.regs[i_rs1_addr];
    o_rs1_ready = this.regfile.free[i_rs1_addr];
    o_rs1_tag   = this.regfile.tag[i_rs1_addr];

    o_rs1_data  = this.regfile.regs[i_rs2_addr];
    o_rs1_ready = this.regfile.free[i_rs2_addr];
    o_rs1_tag   = this.regfile.tag[i_rs2_addr];

  endfunction

  function automatic void readRegister(input bit [4:0] i_rs_addr, output DATA_T o_rs_data,
                                       output bit o_rs_ready,
                                       output bit [ROBTAG_WIDTH-1:0] o_rs_tag);

    this.regfile.locks[i_rs_addr].get();
    o_rs_data  = this.regfile.regs[i_rs_addr];
    o_rs_ready = this.regfile.free[i_rs_addr];
    o_rs_tag   = this.regfile.tag[i_rs_addr];
    this.regfile.locks[i_rs_addr].put();

  endfunction

  function automatic void writeRegister(input bit [4:0] i_rd_addr, input DATA_T i_rd_data,
                                        input bit [ROBTAG_WIDTH-1:0] i_rd_tag);
    this.regfile.locks[i_rd_addr].get();
    this.regfile.regs[i_rd_addr] = i_rd_data;
    if (this.regfile.tag[i_rd_addr] == i_rd_tag) //update data but do not mark as free if this is not the latest tag
      this.regfile.free[i_rd_addr] = 1'b1;
    this.regfile.locks[i_rd_addr].put();
  endfunction

  function automatic void allocateRegister(input bit [4:0] i_rd_addr,
                                           input bit [ROBTAG_WIDTH-1:0] i_rd_tag);
    this.regfile.locks[i_rd_addr].get();
    this.regfile.tag[i_rd_addr]  = i_rd_tag;
    this.regfile.free[i_rd_addr] = 1'b0;
    this.regfile.locks[i_rd_addr].put();
  endfunction

  function automatic void setRegisterBusy(input bit [4:0] i_rs_addr);
    this.regfile.locks[i_rs_addr].get();
    this.regfile.free[i_rs_addr] = '0;
    this.regfile.locks[i_rs_addr].put();
  endfunction

  function automatic void clearRegisterBusy(input bit [4:0] i_rs_addr);
    this.regfile.locks[i_rs_addr].get();
    this.regfile.free[i_rs_addr] = '1;
    this.regfile.locks[i_rs_addr].put();
  endfunction

  function automatic void setRegisterTag(input bit [4:0] i_rs_addr,
                                         input bit [ROBTAG_WIDTH-1:0] i_rs_tag);
    this.regfile.tag[i_rs_addr] = i_rs_tag;
  endfunction

  function automatic fu_packet_t readFuPacket(functional_unit_t unit_type, bit fu_ready);
    fu_packet_t pkt = '{default: '0};
    if (this.functional_units[unit_type].size() && fu_ready)
      pkt = this.functional_units[unit_type].pop_front();
    return pkt;
  endfunction

endclass
