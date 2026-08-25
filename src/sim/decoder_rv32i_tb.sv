`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns/1ps

// Testbench for decoder_rv32i.
//
// Checks decode for all base RV32I instructions + system/exceptions.

module decoder_rv32i_tb;
  import decode_package::*;

  // Interface Signals
  instruction_t               i_instr;
  rv32_data_t                 i_pc;
  rv32i_decoded_instruction_t o_decoded;

  // Instantiate Hardware DUT
  decoder_rv32i dut (
      .*
  );

  // Golden Reference Model
  rv32iDecoder ref_model;

  int pass_cnt = 0;
  int fail_cnt = 0;

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------
  task automatic chk(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("[FAIL] %-58s got=0x%0h exp=0x%0h", what, got, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  // Reference model comparison helper
  task automatic check_against_ref(string name, logic [31:0] raw_code);
    rv32i_decoded_instruction_t exp;
    i_instr.raw = raw_code;
    #1;
    exp = ref_model.decodeInstruction(i_instr, i_pc);

    chk({name, ": rd"},        o_decoded.Rd,                    exp.Rd);
    chk({name, ": rs1"},       o_decoded.Rs1,                   exp.Rs1);
    chk({name, ": rs2"},       o_decoded.Rs2,                   exp.Rs2);
    chk({name, ": imm"},       o_decoded.Imm,                   exp.Imm);
    chk({name, ": futype"},    o_decoded.FunctionalUnitType,    exp.FunctionalUnitType);
    chk({name, ": regwrite"},  o_decoded.ControlData.RegWrite,  exp.ControlData.RegWrite);
    chk({name, ": load"},      o_decoded.ControlData.Load,      exp.ControlData.Load);
    chk({name, ": store"},     o_decoded.ControlData.Store,     exp.ControlData.Store);
    chk({name, ": branch"},    o_decoded.ControlData.Branch,    exp.ControlData.Branch);
    chk({name, ": jump"},      o_decoded.ControlData.Jump,      exp.ControlData.Jump);
    chk({name, ": exception"}, o_decoded.ControlData.Exception, exp.ControlData.Exception);
    chk({name, ": exccause"},  o_decoded.ControlData.ExcCause,  exp.ControlData.ExcCause);
    chk({name, ": fence"},     o_decoded.ControlData.Fence,     exp.ControlData.Fence);
  endtask

  // -------------------------------------------------------------------------
  // Main Test Sequence
  // -------------------------------------------------------------------------
  initial begin
    ref_model = new();
    i_pc = 32'h8000_0000;

    // Test Group 1: R-type instructions
    check_against_ref("ADD",  32'h002081B3);
    check_against_ref("SUB",  32'h40208233);
    check_against_ref("SLL",  32'h002091B3);
    check_against_ref("SLT",  32'h0020A1B3);
    check_against_ref("SLTU", 32'h0020B1B3);
    check_against_ref("XOR",  32'h0020C1B3);
    check_against_ref("SRL",  32'h0020D1B3);
    check_against_ref("SRA",  32'h4020D1B3);
    check_against_ref("OR",   32'h0020E1B3);
    check_against_ref("AND",  32'h0020F1B3);

    // Test Group 2: I-type arithmetic & logic
    check_against_ref("ADDI",  32'h02A00093);
    check_against_ref("SLTI",  32'h00A0A093);
    check_against_ref("SLTIU", 32'h00A0B093);
    check_against_ref("XORI",  32'h0FF0C093);
    check_against_ref("ORI",   32'h0F00E093);
    check_against_ref("ANDI",  32'h00F0F093);
    check_against_ref("SLLI",  32'h00409093);
    check_against_ref("SRLI",  32'h0040D093);
    check_against_ref("SRAI",  32'h4040D093);

    // Test Group 3: Load operations
    check_against_ref("LB",  32'h00408083);
    check_against_ref("LH",  32'h00409083);
    check_against_ref("LW",  32'h0080A283);
    check_against_ref("LBU", 32'h0040C083);
    check_against_ref("LHU", 32'h0040D083);

    // Test Group 4: Store operations
    check_against_ref("SB", 32'h00208423);
    check_against_ref("SH", 32'h00209423);
    check_against_ref("SW", 32'h0020A623);

    // Test Group 5: Branch operations
    check_against_ref("BEQ",  32'h00208863);
    check_against_ref("BNE",  32'h00209863);
    check_against_ref("BLT",  32'h0020C863);
    check_against_ref("BGE",  32'h0020D863);
    check_against_ref("BLTU", 32'h0020E863);
    check_against_ref("BGEU", 32'h0020F863);

    // Test Group 6: Upper immediate and Jumps
    check_against_ref("LUI",   32'h12345537);
    check_against_ref("AUIPC", 32'h12345517);
    check_against_ref("JAL",   32'h008000EF);
    check_against_ref("JALR",  32'h004080E7);

    // Test Group 7: System instructions and exceptions
    check_against_ref("FENCE",   32'h0000000F);
    check_against_ref("ECALL",   32'h00000073);
    check_against_ref("EBREAK",  32'h00100073);
    check_against_ref("ILLEGAL", 32'hFFFFFFFF);

    // Test Group 8: Randomized fuzzing against golden model
    for (int i = 0; i < 50; i++) begin
      check_against_ref($sformatf("rand_%0d", i), $urandom);
    end

    #10;
    $display("--- Summary: %0d passed, %0d failed ---", pass_cnt, fail_cnt);
    if (fail_cnt > 0) $fatal(1, "TEST FAILED");
    else $display("ALL TESTS PASSED");
    $finish;
  end

endmodule