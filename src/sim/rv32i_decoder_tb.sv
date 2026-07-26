`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns/1ps

// Testbench for the rv32iDecoder class in decode.svh.
//
// The decoder is pure combinational software (a set of class methods), so there
// is no clock here: every RV32I instruction is encoded by this TB, pushed
// through decodeInstruction(), and compared against a golden model written
// straight from the RISC-V unprivileged spec (Vol I, "RV32I Base Integer
// Instruction Set") plus this design's own FU/op assignment as declared by the
// enums in decode.svh.
//
// All 40 RV32I instructions are exercised with NUM_TRIALS randomized register /
// immediate / PC fields each.  Per trial the TB checks:
//   Rd / Rs1 / Rs2      - only where the instruction format actually defines
//                         that field (the decoder slices them unconditionally,
//                         so e.g. LUI's "Rs1" is just immediate bits and is
//                         gated off by ControlData.FuSrc1 instead)
//   Imm                 - full 32-bit sign/zero-extended value per format
//   Pc                  - passed through unchanged
//   FunctionalUnitType  - which FU the instruction is steered to
//   FunctionalUnitOp    - the union member selected by the expected FU type
//   ControlData         - the whole packed control struct, including the trap
//                         cause that will drive mcause
//
// FENCE, ECALL and EBREAK reach no functional unit, so ControlData alone defines
// them: FENCE must retire as a barrier without trapping (and must ignore its
// reserved fm/pred/succ/rs1/rd fields, which this TB randomizes), while
// ECALL/EBREAK must trap with the right cause.
//
// Three non-RV32I encodings are also driven as negative tests and must decode as
// ILLEGAL_INSTR: FENCE.I (Zifencei), and MRET/SRET (trap returns needing the
// privileged CSRs this core does not implement).

module rv32i_decoder_tb;
  import decode_package::*;

  localparam int NUM_TRIALS = 64;
  localparam int NUM_RV32I = 40;  // the RV32I base set
  localparam int NUM_ILLEGAL = 3;  // FENCE.I / MRET / SRET: not RV32I, must trap
  localparam int NUM_INSTRS = NUM_RV32I + NUM_ILLEGAL;

  // -------------------------------------------------------------------------
  // RV32I opcodes (spec Chapter "RV32I Base Integer Instruction Set")
  // -------------------------------------------------------------------------
  localparam bit [6:0] OPC_LUI = 7'b0110111;
  localparam bit [6:0] OPC_AUIPC = 7'b0010111;
  localparam bit [6:0] OPC_JAL = 7'b1101111;
  localparam bit [6:0] OPC_JALR = 7'b1100111;
  localparam bit [6:0] OPC_BRANCH = 7'b1100011;
  localparam bit [6:0] OPC_LOAD = 7'b0000011;
  localparam bit [6:0] OPC_STORE = 7'b0100011;
  localparam bit [6:0] OPC_OP_IMM = 7'b0010011;
  localparam bit [6:0] OPC_OP = 7'b0110011;
  localparam bit [6:0] OPC_MISC_MEM = 7'b0001111;
  localparam bit [6:0] OPC_SYSTEM = 7'b1110011;

  localparam bit [6:0] F7_ZERO = 7'b0000000;
  localparam bit [6:0] F7_ALT = 7'b0100000;  // SUB / SRA / SRAI

  typedef enum {
    FMT_R,
    FMT_I,
    FMT_I_SHAMT,  // SLLI/SRLI/SRAI: imm field is funct7 ++ shamt
    FMT_S,
    FMT_B,
    FMT_U,
    FMT_J,
    FMT_SYS       // MISC-MEM / SYSTEM: no register or immediate operands
  } fmt_e;

  // The 40 RV32I instructions, then the three non-RV32I encodings that must trap.
  typedef enum {
    LUI,
    AUIPC,
    JAL,
    JALR,
    BEQ,
    BNE,
    BLT,
    BGE,
    BLTU,
    BGEU,
    LB,
    LH,
    LW,
    LBU,
    LHU,
    SB,
    SH,
    SW,
    ADDI,
    SLTI,
    SLTIU,
    XORI,
    ORI,
    ANDI,
    SLLI,
    SRLI,
    SRAI,
    ADD,
    SUB,
    SLL,
    SLT,
    SLTU,
    XOR,
    SRL,
    SRA,
    OR,
    AND,
    FENCE,
    ECALL,
    EBREAK,
    FENCE_I,
    MRET,
    SRET
  } rv32i_e;

  typedef struct {
    fmt_e             fmt;
    bit [6:0]         opcode;
    bit [2:0]         funct3;
    bit [6:0]         funct7;
    bit [11:0]        funct12;   // FMT_SYS only: what separates ECALL/EBREAK/MRET/SRET
    functional_unit_t exp_fu;
    fu_op_t           exp_op;
    control_data_t    exp_ctrl;
  } spec_t;

  rv32i_e all_instrs[NUM_INSTRS] = '{
      LUI,
      AUIPC,
      JAL,
      JALR,
      BEQ,
      BNE,
      BLT,
      BGE,
      BLTU,
      BGEU,
      LB,
      LH,
      LW,
      LBU,
      LHU,
      SB,
      SH,
      SW,
      ADDI,
      SLTI,
      SLTIU,
      XORI,
      ORI,
      ANDI,
      SLLI,
      SRLI,
      SRAI,
      ADD,
      SUB,
      SLL,
      SLT,
      SLTU,
      XOR,
      SRL,
      SRA,
      OR,
      AND,
      FENCE,
      ECALL,
      EBREAK,
      FENCE_I,
      MRET,
      SRET
  };

  rv32iDecoder decoder;
  rv64iDecoder decoder64;
  int pass_cnt = 0;
  int fail_cnt = 0;
  int fails_by_instr[NUM_INSTRS];

  // -------------------------------------------------------------------------
  // Instruction encoders (spec "Base Instruction Formats")
  // -------------------------------------------------------------------------
  function automatic bit_instruction_t enc_r(bit [6:0] f7, bit [4:0] rs2, bit [4:0] rs1,
                                             bit [2:0] f3, bit [4:0] rd, bit [6:0] op);
    return {f7, rs2, rs1, f3, rd, op};
  endfunction

  function automatic bit_instruction_t enc_i(bit [11:0] imm, bit [4:0] rs1, bit [2:0] f3,
                                             bit [4:0] rd, bit [6:0] op);
    return {imm, rs1, f3, rd, op};
  endfunction

  function automatic bit_instruction_t enc_s(bit [11:0] imm, bit [4:0] rs2, bit [4:0] rs1,
                                             bit [2:0] f3, bit [6:0] op);
    return {imm[11:5], rs2, rs1, f3, imm[4:0], op};
  endfunction

  // imm is the byte offset; imm[0] is not encoded and must be 0
  function automatic bit_instruction_t enc_b(bit [12:0] imm, bit [4:0] rs2, bit [4:0] rs1,
                                             bit [2:0] f3, bit [6:0] op);
    return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], op};
  endfunction

  function automatic bit_instruction_t enc_u(bit [19:0] imm, bit [4:0] rd, bit [6:0] op);
    return {imm, rd, op};
  endfunction

  // imm is the byte offset; imm[0] is not encoded and must be 0
  function automatic bit_instruction_t enc_j(bit [20:0] imm, bit [4:0] rd, bit [6:0] op);
    return {imm[20], imm[10:1], imm[11], imm[19:12], rd, op};
  endfunction

  // -------------------------------------------------------------------------
  // Golden model
  // -------------------------------------------------------------------------
  // A normal instruction: no barrier, no trap.  ExcCause is a don't-care while
  // Exception is clear, and the decoder parks it at ILLEGAL_INSTR as a fail-safe.
  function automatic control_data_t mk_ctrl(bit rw, bit ld, bit st, bit br, bit jp, fu_src_t s1,
                                            fu_src_t s2);
    mk_ctrl = '{
        RegWrite: rw,
        Load: ld,
        Store: st,
        Branch: br,
        Jump: jp,
        FuSrc1: s1,
        FuSrc2: s2,
        Fence: 1'b0,
        Exception: 1'b0,
        ExcCause: ILLEGAL_INSTR
    };
  endfunction

  // FENCE: retires as a memory barrier, changes no architectural state, never traps.
  function automatic control_data_t mk_fence();
    mk_fence = '{
        RegWrite: 1'b0,
        Load: 1'b0,
        Store: 1'b0,
        Branch: 1'b0,
        Jump: 1'b0,
        FuSrc1: ZERO,
        FuSrc2: ZERO,
        Fence: 1'b1,
        Exception: 1'b0,
        ExcCause: ILLEGAL_INSTR
    };
  endfunction

  // A trapping instruction: writes no register, cause feeds mcause at commit.
  function automatic control_data_t mk_trap(exception_cause_t cause);
    mk_trap = '{
        RegWrite: 1'b0,
        Load: 1'b0,
        Store: 1'b0,
        Branch: 1'b0,
        Jump: 1'b0,
        FuSrc1: ZERO,
        FuSrc2: ZERO,
        Fence: 1'b0,
        Exception: 1'b1,
        ExcCause: cause
    };
  endfunction

  function automatic spec_t spec_of(rv32i_e ins);
    spec_t s;

    s.fmt           = FMT_R;
    s.opcode        = 7'b0;
    s.funct3        = 3'b0;
    s.funct7        = F7_ZERO;
    s.funct12       = 12'h000;
    s.exp_fu        = INT_ALU_UNIT;
    s.exp_op.alu_op = ADD_OP;
    s.exp_ctrl      = mk_ctrl(0, 0, 0, 0, 0, ZERO, ZERO);

    case (ins)
      // ---- U-type: rd <- imm (LUI) / pc + imm (AUIPC) ----
      LUI: begin
        s.fmt = FMT_U;
        s.opcode = OPC_LUI;
        s.exp_fu = INT_ALU_UNIT;
        s.exp_op.alu_op = ADD_OP;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 0, ZERO, IMM);
      end
      AUIPC: begin
        s.fmt = FMT_U;
        s.opcode = OPC_AUIPC;
        s.exp_fu = INT_ALU_UNIT;
        s.exp_op.alu_op = ADD_OP;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 0, PC, IMM);
      end

      // ---- Jumps ----
      JAL: begin
        s.fmt = FMT_J;
        s.opcode = OPC_JAL;
        s.exp_fu = BRANCH_JUMP_UNIT;
        s.exp_op.branch_jump_op = JAL_OP;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 1, PC, IMM);
      end
      JALR: begin
        s.fmt = FMT_I;
        s.opcode = OPC_JALR;
        s.funct3 = 3'b000;
        s.exp_fu = BRANCH_JUMP_UNIT;
        s.exp_op.branch_jump_op = JALR_OP;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 1, REG, IMM);
      end

      // ---- B-type branches ----
      BEQ, BNE, BLT, BGE, BLTU, BGEU: begin
        s.fmt = FMT_B;
        s.opcode = OPC_BRANCH;
        s.exp_fu = BRANCH_JUMP_UNIT;
        s.exp_ctrl = mk_ctrl(0, 0, 0, 1, 0, REG, REG);
        case (ins)
          BEQ: begin
            s.funct3 = 3'b000;
            s.exp_op.branch_jump_op = BEQ_OP;
          end
          BNE: begin
            s.funct3 = 3'b001;
            s.exp_op.branch_jump_op = BNE_OP;
          end
          BLT: begin
            s.funct3 = 3'b100;
            s.exp_op.branch_jump_op = BLT_OP;
          end
          BGE: begin
            s.funct3 = 3'b101;
            s.exp_op.branch_jump_op = BGE_OP;
          end
          BLTU: begin
            s.funct3 = 3'b110;
            s.exp_op.branch_jump_op = BLTU_OP;
          end
          BGEU: begin
            s.funct3 = 3'b111;
            s.exp_op.branch_jump_op = BGEU_OP;
          end
          default: ;
        endcase
      end

      // ---- Loads ----
      LB, LH, LW, LBU, LHU: begin
        s.fmt = FMT_I;
        s.opcode = OPC_LOAD;
        s.exp_fu = LOAD_STORE_UNIT;
        s.exp_ctrl = mk_ctrl(1, 1, 0, 0, 0, REG, IMM);
        case (ins)
          LB: begin
            s.funct3 = 3'b000;
            s.exp_op.load_store_op = LB_OP;
          end
          LH: begin
            s.funct3 = 3'b001;
            s.exp_op.load_store_op = LH_OP;
          end
          LW: begin
            s.funct3 = 3'b010;
            s.exp_op.load_store_op = LW_OP;
          end
          LBU: begin
            s.funct3 = 3'b100;
            s.exp_op.load_store_op = LBU_OP;
          end
          LHU: begin
            s.funct3 = 3'b101;
            s.exp_op.load_store_op = LHU_OP;
          end
          default: ;
        endcase
      end

      // ---- Stores ----
      SB, SH, SW: begin
        s.fmt = FMT_S;
        s.opcode = OPC_STORE;
        s.exp_fu = LOAD_STORE_UNIT;
        s.exp_ctrl = mk_ctrl(0, 0, 1, 0, 0, REG, IMM);
        case (ins)
          SB: begin
            s.funct3 = 3'b000;
            s.exp_op.load_store_op = SB_OP;
          end
          SH: begin
            s.funct3 = 3'b001;
            s.exp_op.load_store_op = SH_OP;
          end
          SW: begin
            s.funct3 = 3'b010;
            s.exp_op.load_store_op = SW_OP;
          end
          default: ;
        endcase
      end

      // ---- OP-IMM: rd <- rs1 op imm ----
      ADDI, SLTI, SLTIU, XORI, ORI, ANDI: begin
        s.fmt = FMT_I;
        s.opcode = OPC_OP_IMM;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 0, REG, IMM);
        case (ins)
          ADDI: begin
            s.funct3 = 3'b000;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = ADD_OP;
          end
          SLTI: begin
            s.funct3 = 3'b010;
            s.exp_fu = COMPARATOR_UNIT;
            s.exp_op.comp_op = SLT_OP;
          end
          SLTIU: begin
            s.funct3 = 3'b011;
            s.exp_fu = COMPARATOR_UNIT;
            s.exp_op.comp_op = SLTU_OP;
          end
          XORI: begin
            s.funct3 = 3'b100;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = XOR_OP;
          end
          ORI: begin
            s.funct3 = 3'b110;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = OR_OP;
          end
          ANDI: begin
            s.funct3 = 3'b111;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = AND_OP;
          end
          default: ;
        endcase
      end

      // ---- OP-IMM shifts: imm field is funct7 ++ shamt ----
      SLLI, SRLI, SRAI: begin
        s.fmt = FMT_I_SHAMT;
        s.opcode = OPC_OP_IMM;
        s.exp_fu = SHIFTER_UNIT;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 0, REG, IMM);
        case (ins)
          SLLI: begin
            s.funct3 = 3'b001;
            s.funct7 = F7_ZERO;
            s.exp_op.shift_op = SLL_OP;
          end
          SRLI: begin
            s.funct3 = 3'b101;
            s.funct7 = F7_ZERO;
            s.exp_op.shift_op = SRL_OP;
          end
          SRAI: begin
            s.funct3 = 3'b101;
            s.funct7 = F7_ALT;
            s.exp_op.shift_op = SRA_OP;
          end
          default: ;
        endcase
      end

      // ---- OP: rd <- rs1 op rs2 ----
      ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND: begin
        s.fmt = FMT_R;
        s.opcode = OPC_OP;
        s.exp_ctrl = mk_ctrl(1, 0, 0, 0, 0, REG, REG);
        case (ins)
          ADD: begin
            s.funct3 = 3'b000;
            s.funct7 = F7_ZERO;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = ADD_OP;
          end
          SUB: begin
            s.funct3 = 3'b000;
            s.funct7 = F7_ALT;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = SUB_OP;
          end
          SLL: begin
            s.funct3 = 3'b001;
            s.funct7 = F7_ZERO;
            s.exp_fu = SHIFTER_UNIT;
            s.exp_op.shift_op = SLL_OP;
          end
          SLT: begin
            s.funct3 = 3'b010;
            s.funct7 = F7_ZERO;
            s.exp_fu = COMPARATOR_UNIT;
            s.exp_op.comp_op = SLT_OP;
          end
          SLTU: begin
            s.funct3 = 3'b011;
            s.funct7 = F7_ZERO;
            s.exp_fu = COMPARATOR_UNIT;
            s.exp_op.comp_op = SLTU_OP;
          end
          XOR: begin
            s.funct3 = 3'b100;
            s.funct7 = F7_ZERO;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = XOR_OP;
          end
          SRL: begin
            s.funct3 = 3'b101;
            s.funct7 = F7_ZERO;
            s.exp_fu = SHIFTER_UNIT;
            s.exp_op.shift_op = SRL_OP;
          end
          SRA: begin
            s.funct3 = 3'b101;
            s.funct7 = F7_ALT;
            s.exp_fu = SHIFTER_UNIT;
            s.exp_op.shift_op = SRA_OP;
          end
          OR: begin
            s.funct3 = 3'b110;
            s.funct7 = F7_ZERO;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = OR_OP;
          end
          AND: begin
            s.funct3 = 3'b111;
            s.funct7 = F7_ZERO;
            s.exp_fu = INT_ALU_UNIT;
            s.exp_op.alu_op = AND_OP;
          end
          default: ;
        endcase
      end

      // ---- MISC-MEM / SYSTEM: no functional unit, ControlData is the whole story ----
      FENCE: begin
        s.fmt = FMT_SYS;
        s.opcode = OPC_MISC_MEM;
        s.funct3 = 3'b000;
        s.funct12 = 12'b0000_0011_0011;  // fm=0 pred=rw succ=rw (randomized below)
        s.exp_ctrl = mk_fence();
      end
      ECALL: begin
        s.fmt = FMT_SYS;
        s.opcode = OPC_SYSTEM;
        s.funct3 = 3'b000;
        s.funct12 = 12'h000;
        s.exp_ctrl = mk_trap(ECALL_FROM_M);  // M-mode only core
      end
      EBREAK: begin
        s.fmt = FMT_SYS;
        s.opcode = OPC_SYSTEM;
        s.funct3 = 3'b000;
        s.funct12 = 12'h001;
        s.exp_ctrl = mk_trap(BREAKPOINT);
      end

      // ---- Not RV32I: must decode as an illegal instruction ----
      // FENCE.I is Zifencei.  MRET/SRET are trap *returns* rather than
      // exceptions, but both read privileged CSRs (mepc/mstatus) that do not
      // exist yet, and SRET is illegal by definition while S-mode is
      // unimplemented.  All three trap as ILLEGAL_INSTR until that changes.
      FENCE_I: begin
        s.fmt = FMT_SYS;
        s.opcode = OPC_MISC_MEM;
        s.funct3 = 3'b001;
        s.funct12 = 12'h000;
        s.exp_ctrl = mk_trap(ILLEGAL_INSTR);
      end
      MRET: begin
        s.fmt = FMT_SYS;
        s.opcode = OPC_SYSTEM;
        s.funct3 = 3'b000;
        s.funct12 = 12'h302;
        s.exp_ctrl = mk_trap(ILLEGAL_INSTR);
      end
      SRET: begin
        s.fmt = FMT_SYS;
        s.opcode = OPC_SYSTEM;
        s.funct3 = 3'b000;
        s.funct12 = 12'h102;
        s.exp_ctrl = mk_trap(ILLEGAL_INSTR);
      end

      default: ;
    endcase

    return s;
  endfunction

  // -------------------------------------------------------------------------
  // fu_op_t is a union: only the member matching the FU type is meaningful.
  // -------------------------------------------------------------------------
  function automatic bit [3:0] op_bits(functional_unit_t fu, fu_op_t v);
    case (fu)
      INT_ALU_UNIT:     op_bits = v.alu_op;
      SHIFTER_UNIT:     op_bits = {1'b0, v.shift_op};
      COMPARATOR_UNIT:  op_bits = {1'b0, v.comp_op};
      LOAD_STORE_UNIT:  op_bits = v.load_store_op;
      BRANCH_JUMP_UNIT: op_bits = {1'b0, v.branch_jump_op};
      default:          op_bits = 4'h0;
    endcase
  endfunction

  function automatic string op_name(functional_unit_t fu, fu_op_t v);
    case (fu)
      INT_ALU_UNIT:     op_name = v.alu_op.name();
      SHIFTER_UNIT:     op_name = v.shift_op.name();
      COMPARATOR_UNIT:  op_name = v.comp_op.name();
      LOAD_STORE_UNIT:  op_name = v.load_store_op.name();
      BRANCH_JUMP_UNIT: op_name = v.branch_jump_op.name();
      default:          op_name = "?";
    endcase
  endfunction

  function automatic string ctrl_str(control_data_t c);
    // ExcCause is only meaningful while Exception is set, so hide it otherwise
    // rather than print a don't-care that looks like a real cause.
    return $sformatf(
        "RegWrite=%0b Load=%0b Store=%0b Branch=%0b Jump=%0b FuSrc1=%s FuSrc2=%s Fence=%0b Exception=%0b%s",
        c.RegWrite,
        c.Load,
        c.Store,
        c.Branch,
        c.Jump,
        c.FuSrc1.name(),
        c.FuSrc2.name(),
        c.Fence,
        c.Exception,
        c.Exception ? {" ExcCause=", c.ExcCause.name()} : ""
    );
  endfunction

  // Which architectural fields the format actually defines.
  function automatic bit has_rd(fmt_e f);
    return f inside {FMT_R, FMT_I, FMT_I_SHAMT, FMT_U, FMT_J};
  endfunction
  function automatic bit has_rs1(fmt_e f);
    return f inside {FMT_R, FMT_I, FMT_I_SHAMT, FMT_S, FMT_B};
  endfunction
  function automatic bit has_rs2(fmt_e f);
    return f inside {FMT_R, FMT_S, FMT_B};
  endfunction

  // -------------------------------------------------------------------------
  // One randomized trial of one instruction
  // -------------------------------------------------------------------------
  task automatic check_one(input rv32i_e ins, input bit verbose);
    spec_t                      s;
    bit_instruction_t           enc;
    instruction_t               instr;
    rv32i_decoded_instruction_t d;
    rv32_data_t pc, exp_imm;
    bit [4:0] rd, rs1, rs2, shamt;
    bit    [11:0] imm12;
    bit    [12:0] imm13;
    bit    [19:0] imm20;
    bit    [20:0] imm21;
    string        errs;

    s = spec_of(ins);
    rd = 5'($urandom_range(0, 31));
    rs1 = 5'($urandom_range(0, 31));
    rs2 = 5'($urandom_range(0, 31));
    pc = $urandom & 32'hFFFF_FFFC;

    exp_imm = 32'd0;
    case (s.fmt)
      FMT_R: begin
        enc = enc_r(s.funct7, rs2, rs1, s.funct3, rd, s.opcode);
        exp_imm = 32'd0;  // R-type carries no immediate
      end
      FMT_I: begin
        imm12   = 12'($urandom);
        enc     = enc_i(imm12, rs1, s.funct3, rd, s.opcode);
        exp_imm = {{20{imm12[11]}}, imm12};
      end
      FMT_I_SHAMT: begin
        shamt   = 5'($urandom_range(0, 31));
        enc     = enc_i({s.funct7, shamt}, rs1, s.funct3, rd, s.opcode);
        exp_imm = {27'd0, shamt};
      end
      FMT_S: begin
        imm12   = 12'($urandom);
        enc     = enc_s(imm12, rs2, rs1, s.funct3, s.opcode);
        exp_imm = {{20{imm12[11]}}, imm12};
      end
      FMT_B: begin
        imm13   = {12'($urandom), 1'b0};  // imm[0] is never encoded
        enc     = enc_b(imm13, rs2, rs1, s.funct3, s.opcode);
        exp_imm = {{19{imm13[12]}}, imm13};
      end
      FMT_U: begin
        imm20   = 20'($urandom);
        enc     = enc_u(imm20, rd, s.opcode);
        exp_imm = {imm20, 12'd0};
      end
      FMT_J: begin
        imm21   = {20'($urandom), 1'b0};  // imm[0] is never encoded
        enc     = enc_j(imm21, rd, s.opcode);
        exp_imm = {{11{imm21[20]}}, imm21};
      end
      FMT_SYS: begin
        // FENCE's fm/pred/succ (== funct12) and its rs1/rd are reserved for
        // finer-grain fences; the spec requires base implementations to ignore
        // them rather than trap, so randomize them and expect no effect.
        if (ins == FENCE) enc = enc_i(12'($urandom), rs1, s.funct3, rd, s.opcode);
        else enc = enc_i(s.funct12, 5'd0, s.funct3, 5'd0, s.opcode);
      end
      default: enc = '0;
    endcase

    instr.raw = enc;
    d = decoder.decodeInstruction(instr, pc);

    errs = "";

    // MISC-MEM/SYSTEM never reach a functional unit and carry no operands, so
    // ControlData (plus the Pc that will become mepc) is their whole contract.
    if (s.fmt == FMT_SYS) begin
      if (d.Pc !== pc)
        errs = {errs, $sformatf("\n    Pc        : got=0x%08h exp=0x%08h", d.Pc, pc)};
      if (d.ControlData !== s.exp_ctrl) begin
        errs = {errs, $sformatf("\n    Control   : got=%s", ctrl_str(d.ControlData))};
        errs = {errs, $sformatf("\n                exp=%s", ctrl_str(s.exp_ctrl))};
      end
    end else begin
      if (has_rd(s.fmt) && d.Rd !== rd)
        errs = {errs, $sformatf("\n    Rd        : got=x%0d exp=x%0d", d.Rd, rd)};
      if (has_rs1(s.fmt) && d.Rs1 !== rs1)
        errs = {errs, $sformatf("\n    Rs1       : got=x%0d exp=x%0d", d.Rs1, rs1)};
      if (has_rs2(s.fmt) && d.Rs2 !== rs2)
        errs = {errs, $sformatf("\n    Rs2       : got=x%0d exp=x%0d", d.Rs2, rs2)};

      if (d.Pc !== pc)
        errs = {errs, $sformatf("\n    Pc        : got=0x%08h exp=0x%08h", d.Pc, pc)};

      // Shift-immediates: only Imm[4:0] reaches barrel_shifter_N's 5-bit
      // i_shamt port.  The decoder sign-extends the whole I-type field, so
      // the upper bits carry funct7 (SRAI => 0x400 + shamt) and are unused.
      if (s.fmt == FMT_I_SHAMT) begin
        if (d.Imm[4:0] !== exp_imm[4:0])
          errs = {
            errs, $sformatf("\n    Imm[4:0]  : got=%0d exp=%0d (shamt)", d.Imm[4:0], exp_imm[4:0])
          };
      end else if (d.Imm !== exp_imm) begin
        errs = {errs, $sformatf("\n    Imm       : got=0x%08h exp=0x%08h", d.Imm, exp_imm)};
      end

      if (d.FunctionalUnitType !== s.exp_fu)
        errs = {
          errs,
          $sformatf("\n    FuType    : got=%s exp=%s", d.FunctionalUnitType.name(), s.exp_fu.name())
        };

      // Compare through the member the expected FU type selects.
      if (op_bits(s.exp_fu, d.FunctionalUnitOp) !== op_bits(s.exp_fu, s.exp_op))
        errs = {
          errs,
          $sformatf(
              "\n    FuOp      : got=%s exp=%s",
              op_name(
                  s.exp_fu, d.FunctionalUnitOp
              ),
              op_name(
                  s.exp_fu, s.exp_op
              )
          )
        };

      if (d.ControlData !== s.exp_ctrl) begin
        errs = {errs, $sformatf("\n    Control   : got=%s", ctrl_str(d.ControlData))};
        errs = {errs, $sformatf("\n                exp=%s", ctrl_str(s.exp_ctrl))};
      end
    end

    if (errs == "") begin
      pass_cnt++;
    end else begin
      fail_cnt++;
      fails_by_instr[int'(ins)]++;
      if (verbose) $display("[FAIL] %-6s instr=0x%08h%s", ins.name(), enc, errs);
    end
  endtask

  // -------------------------------------------------------------------------
  // rv64iDecoder inherits MISC-MEM/SYSTEM handling from rv32iDecoder via super.
  // Nothing else instantiates that class, so drive the same encodings through it
  // to prove the override chain still lines up: the methods are not virtual, so a
  // signature drift between parent and child would silently shadow rather than
  // error, and RV64 would quietly stop decoding these at all.
  // -------------------------------------------------------------------------
  task automatic check_rv64_system();
    spec_t                      s;
    instruction_t               instr;
    rv64i_decoded_instruction_t d64;

    foreach (all_instrs[k]) begin
      s = spec_of(all_instrs[k]);
      if (s.fmt != FMT_SYS) continue;

      instr.raw = enc_i(s.funct12, 5'd0, s.funct3, 5'd0, s.opcode);
      d64 = decoder64.decodeInstruction(instr, 64'hDEAD_BEEF_0000_1000);

      // Trap causes are XLEN-independent, so RV64 must agree with RV32 exactly.
      if (d64.ControlData !== s.exp_ctrl) begin
        $display("[FAIL] %-7s (rv64iDecoder)\n    Control   : got=%s\n                exp=%s",
                 all_instrs[k].name(), ctrl_str(d64.ControlData), ctrl_str(s.exp_ctrl));
        fail_cnt++;
        fails_by_instr[int'(all_instrs[k])]++;
      end else begin
        pass_cnt++;
      end
    end
  endtask

  // -------------------------------------------------------------------------
  // Run
  // -------------------------------------------------------------------------
  initial begin
    int failing_instrs;

    $dumpfile("dump.vcd");
    $dumpvars(0, rv32i_decoder_tb);

    failing_instrs = 0;
    decoder = new();
    decoder64 = new();
    foreach (fails_by_instr[k]) fails_by_instr[k] = 0;

    $display("=== decode: %0d RV32I + %0d illegal encodings x %0d randomized trials ===\n",
             NUM_RV32I, NUM_ILLEGAL, NUM_TRIALS);

    foreach (all_instrs[k]) begin
      for (int t = 0; t < NUM_TRIALS; t++)
      // Only the first failing trial of an instruction prints detail.
      check_one(
      all_instrs[k], (fails_by_instr[int'(all_instrs[k])] == 0));
    end

    check_rv64_system();

    foreach (all_instrs[k]) if (fails_by_instr[int'(all_instrs[k])] != 0) failing_instrs++;

    if (failing_instrs != 0) begin
      $display("\n--- Failing instructions (%0d of %0d) ---", failing_instrs, NUM_INSTRS);
      foreach (all_instrs[k])
      if (fails_by_instr[int'(all_instrs[k])] != 0)
        $display(
            "  %-6s %0d/%0d trials failed",
            all_instrs[k].name(),
            fails_by_instr[int'(all_instrs[k])],
            NUM_TRIALS
        );
    end

    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED - see [FAIL] lines above", fail_cnt);
    $finish;
  end

endmodule
