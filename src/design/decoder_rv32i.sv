`ifndef verilatorsim
`include "includes/decode.svh"
`else
`include "decode.svh"
`endif

import decode_package::*;

// Combinational decoder for RV32I base integer instructions.
module decoder_rv32i (
    input  instruction_t               i_instr,
    input  rv32_data_t                 i_pc,
    output rv32i_decoded_instruction_t o_decoded
);

  logic [4:0] opcode_high;
  logic [2:0] funct3;
  logic [6:0] funct7;
  logic [4:0] rs1, rs2, rd;
  logic sign_bit;

  assign opcode_high = i_instr.fields.Opcode[6:2];
  assign funct3      = i_instr.fields.Funct3;
  assign funct7      = i_instr.fields.Funct7;
  assign rs1         = i_instr.fields.Rs1;
  assign rs2         = i_instr.fields.Rs2;
  assign rd          = i_instr.fields.Rd;
  assign sign_bit    = i_instr.raw[31];

  always_comb begin
    o_decoded.Pc = i_pc;
    o_decoded.Rd = rd;
    o_decoded.Rs1 = rs1;
    o_decoded.Rs2 = rs2;
    o_decoded.Imm = '0;
    o_decoded.FunctionalUnitType = INT_ALU_UNIT;
    o_decoded.FunctionalUnitOp.alu_op = alu_op_t'(0);
    
    o_decoded.ControlData.RegWrite  = 1'b0;
    o_decoded.ControlData.Load      = 1'b0;
    o_decoded.ControlData.Store     = 1'b0;
    o_decoded.ControlData.Branch    = 1'b0;
    o_decoded.ControlData.Jump      = 1'b0;
    o_decoded.ControlData.FuSrc1    = ZERO;
    o_decoded.ControlData.FuSrc2    = ZERO;
    o_decoded.ControlData.Fence     = 1'b0;
    o_decoded.ControlData.Exception = 1'b0;
    o_decoded.ControlData.ExcCause  = ILLEGAL_INSTR;

    // Immediate generation per instruction format
    unique case (opcode_high)
      5'b00100: o_decoded.Imm = {{20{sign_bit}}, i_instr.raw[31:20]}; // I-type ALU
      5'b00000: o_decoded.Imm = {{20{sign_bit}}, i_instr.raw[31:20]}; // Load
      5'b01000: o_decoded.Imm = {{20{sign_bit}}, i_instr.raw[31:25], i_instr.raw[11:7]}; // S-type
      5'b11000: o_decoded.Imm = {{19{sign_bit}}, i_instr.raw[31], i_instr.raw[7], i_instr.raw[30:25], i_instr.raw[11:8], 1'b0}; // B-type
      5'b01101: o_decoded.Imm = {i_instr.raw[31:12], 12'b0}; // LUI
      5'b00101: o_decoded.Imm = {i_instr.raw[31:12], 12'b0}; // AUIPC
      5'b11011: o_decoded.Imm = {{11{sign_bit}}, i_instr.raw[31], i_instr.raw[19:12], i_instr.raw[20], i_instr.raw[30:21], 1'b0}; // JAL
      5'b11001: o_decoded.Imm = {{20{sign_bit}}, i_instr.raw[31:20]}; // JALR
      default:  o_decoded.Imm = '0;
    endcase

    // Control and Functional Unit decoding
    case (opcode_high)
      // R-Type Arithmetic/Logic: ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND
      5'b01100: begin
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.FuSrc1   = REG;
        o_decoded.ControlData.FuSrc2   = REG;
        case (funct3)
          3'b000: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = funct7[5] ? SUB_OP : ADD_OP;
          end
          3'b001: begin
            o_decoded.FunctionalUnitType = SHIFTER_UNIT;
            o_decoded.FunctionalUnitOp.shift_op = SLL_OP;
          end
          3'b010: begin
            o_decoded.FunctionalUnitType = COMPARATOR_UNIT;
            o_decoded.FunctionalUnitOp.comp_op = SLT_OP;
          end
          3'b011: begin
            o_decoded.FunctionalUnitType = COMPARATOR_UNIT;
            o_decoded.FunctionalUnitOp.comp_op = SLTU_OP;
          end
          3'b100: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = XOR_OP;
          end
          3'b101: begin
            o_decoded.FunctionalUnitType = SHIFTER_UNIT;
            o_decoded.FunctionalUnitOp.shift_op = funct7[5] ? SRA_OP : SRL_OP;
          end
          3'b110: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = OR_OP;
          end
          3'b111: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = AND_OP;
          end
        endcase
      end

      // I-Type Immediate Arithmetic/Logic: ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI
      5'b00100: begin
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.FuSrc1   = REG;
        o_decoded.ControlData.FuSrc2   = IMM;
        case (funct3)
          3'b000: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = ADD_OP;
          end
          3'b001: begin
            o_decoded.FunctionalUnitType = SHIFTER_UNIT;
            o_decoded.FunctionalUnitOp.shift_op = SLL_OP;
          end
          3'b010: begin
            o_decoded.FunctionalUnitType = COMPARATOR_UNIT;
            o_decoded.FunctionalUnitOp.comp_op = SLT_OP;
          end
          3'b011: begin
            o_decoded.FunctionalUnitType = COMPARATOR_UNIT;
            o_decoded.FunctionalUnitOp.comp_op = SLTU_OP;
          end
          3'b100: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = XOR_OP;
          end
          3'b101: begin
            o_decoded.FunctionalUnitType = SHIFTER_UNIT;
            o_decoded.FunctionalUnitOp.shift_op = funct7[5] ? SRA_OP : SRL_OP;
          end
          3'b110: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = OR_OP;
          end
          3'b111: begin
            o_decoded.FunctionalUnitType = INT_ALU_UNIT;
            o_decoded.FunctionalUnitOp.alu_op = AND_OP;
          end
        endcase
      end

      // Load Instructions: LB, LH, LW, LBU, LHU
      5'b00000: begin
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.Load     = 1'b1;
        o_decoded.ControlData.FuSrc1   = REG;
        o_decoded.ControlData.FuSrc2   = IMM;
        o_decoded.FunctionalUnitType   = LOAD_STORE_UNIT;
        o_decoded.FunctionalUnitOp.load_store_op = load_store_t'({1'b0, funct3});
      end

      // Store Instructions: SB, SH, SW
      5'b01000: begin
        o_decoded.ControlData.Store    = 1'b1;
        o_decoded.ControlData.FuSrc1   = REG;
        o_decoded.ControlData.FuSrc2   = IMM;
        o_decoded.FunctionalUnitType   = LOAD_STORE_UNIT;
        o_decoded.FunctionalUnitOp.load_store_op = load_store_t'({1'b1, funct3});
      end

      // Branch Instructions: BEQ, BNE, BLT, BGE, BLTU, BGEU
      5'b11000: begin
        o_decoded.ControlData.Branch   = 1'b1;
        o_decoded.ControlData.FuSrc1   = REG;
        o_decoded.ControlData.FuSrc2   = REG;
        o_decoded.FunctionalUnitType   = BRANCH_JUMP_UNIT;
        o_decoded.FunctionalUnitOp.branch_jump_op = branch_jump_t'(funct3);
      end

      // U-Type LUI: rd = imm
      5'b01101: begin
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.FuSrc1   = ZERO;
        o_decoded.ControlData.FuSrc2   = IMM;
        o_decoded.FunctionalUnitType   = INT_ALU_UNIT;
        o_decoded.FunctionalUnitOp.alu_op = ADD_OP;
      end

      // U-Type AUIPC: rd = pc + imm
      5'b00101: begin
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.FuSrc1   = PC;
        o_decoded.ControlData.FuSrc2   = IMM;
        o_decoded.FunctionalUnitType   = INT_ALU_UNIT;
        o_decoded.FunctionalUnitOp.alu_op = ADD_OP;
      end

      // J-Type JAL: rd = pc + 4, pc = pc + imm
      5'b11011: begin
        o_decoded.ControlData.Jump     = 1'b1;
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.FuSrc1   = PC;
        o_decoded.ControlData.FuSrc2   = IMM;
        o_decoded.FunctionalUnitType   = BRANCH_JUMP_UNIT;
        o_decoded.FunctionalUnitOp.branch_jump_op = JAL_OP;
      end

      // I-Type JALR: rd = pc + 4, pc = rs1 + imm
      5'b11001: begin
        o_decoded.ControlData.Jump     = 1'b1;
        o_decoded.ControlData.RegWrite = 1'b1;
        o_decoded.ControlData.FuSrc1   = REG;
        o_decoded.ControlData.FuSrc2   = IMM;
        o_decoded.FunctionalUnitType   = BRANCH_JUMP_UNIT;
        o_decoded.FunctionalUnitOp.branch_jump_op = JALR_OP;
      end

      // MISC-MEM (FENCE)
      5'b00011: begin
        if (funct3 == 3'b000) o_decoded.ControlData.Fence = 1'b1;
        else o_decoded.ControlData.Exception = 1'b1;
      end

      // SYSTEM: ECALL, EBREAK
      5'b11100: begin
        o_decoded.ControlData.Exception = 1'b1;
        if (funct3 == 3'b000) begin
          if (i_instr.raw[31:20] == 12'h000) o_decoded.ControlData.ExcCause = ECALL_FROM_M;
          else if (i_instr.raw[31:20] == 12'h001) o_decoded.ControlData.ExcCause = BREAKPOINT;
          else o_decoded.ControlData.ExcCause = ILLEGAL_INSTR;
        end
      end

      default: begin
        o_decoded.ControlData.Exception = 1'b1;
        o_decoded.ControlData.ExcCause  = ILLEGAL_INSTR;
      end
    endcase
  end

endmodule
