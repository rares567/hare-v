`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns/1ps

// Unit testbench for branch_unit.
module branch_unit_tb;

  import decode_package::*;

  // Stimulus and DUT signals
  rv32_data_t        i_rs1_data;
  rv32_data_t        i_rs2_data;
  rv32_data_t        i_pc;
  rv32_data_t        i_imm;
  control_data_t     i_ctrl;
  fu_op_t            i_fu_op;

  logic              o_branch_taken;
  rv32_data_t        o_branch_target;
  rv32_data_t        o_link_addr;

  branch_unit #(
      .DATA_T(rv32_data_t)
  ) dut (
      .*
  );

  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic chk(input string what, input logic [31:0] got, input logic [31:0] exp);
    if (got !== exp) begin
      $display("[FAIL] %-58s got=0x%08h exp=0x%08h", what, got, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  task automatic chk_bit(input string what, input logic got, input logic exp);
    if (got !== exp) begin
      $display("[FAIL] %-58s got=%0b exp=%0b", what, got, exp);
      fail_cnt++;
    end else pass_cnt++;
  endtask

  // Golden Reference Model for Branch Unit
  function automatic void branch_ref(
      input rv32_data_t rs1_val,
      input rv32_data_t rs2_val,
      input rv32_data_t pc_val,
      input rv32_data_t imm_val,
      input control_data_t ctrl,
      input fu_op_t fu_op,
      output logic exp_taken,
      output rv32_data_t exp_target,
      output rv32_data_t exp_link
  );
    exp_link   = pc_val + 32'd4;
    exp_taken  = 1'b0;
    exp_target = 32'h0;

    if (ctrl.Jump) begin
      exp_taken = 1'b1;
      if (fu_op.branch_jump_op == JALR_OP)
        exp_target = (rs1_val + imm_val) & ~32'h1;
      else
        exp_target = pc_val + imm_val;
    end else if (ctrl.Branch) begin
      exp_target = pc_val + imm_val;
      case (fu_op.branch_jump_op)
        BEQ_OP:  exp_taken = (rs1_val == rs2_val);
        BNE_OP:  exp_taken = (rs1_val != rs2_val);
        BLT_OP:  exp_taken = ($signed(rs1_val) < $signed(rs2_val));
        BGE_OP:  exp_taken = ($signed(rs1_val) >= $signed(rs2_val));
        BLTU_OP: exp_taken = (rs1_val < rs2_val);
        BGEU_OP: exp_taken = (rs1_val >= rs2_val);
        default: exp_taken = 1'b0;
      endcase
    end
  endfunction

  task automatic test_branch_op(
      input string name,
      input rv32_data_t rs1_val,
      input rv32_data_t rs2_val,
      input rv32_data_t pc_val,
      input rv32_data_t imm_val,
      input control_data_t ctrl,
      input fu_op_t fu_op
  );
    logic exp_tk;
    rv32_data_t exp_tgt, exp_lnk;

    i_rs1_data = rs1_val;
    i_rs2_data = rs2_val;
    i_pc       = pc_val;
    i_imm      = imm_val;
    i_ctrl     = ctrl;
    i_fu_op    = fu_op;
    #1;

    branch_ref(rs1_val, rs2_val, pc_val, imm_val, ctrl, fu_op, exp_tk, exp_tgt, exp_lnk);
    chk_bit({name, ": taken"}, o_branch_taken, exp_tk);
    chk({name, ": target"}, o_branch_target, exp_tgt);
    chk({name, ": link_addr"}, o_link_addr, exp_lnk);
  endtask

  initial begin
    control_data_t b_ctrl, j_ctrl, no_ctrl;
    fu_op_t op;

    b_ctrl = '0; b_ctrl.Branch = 1'b1;
    j_ctrl = '0; j_ctrl.Jump   = 1'b1;
    no_ctrl = '0;

    $display("=== STARTING DEDICATED BRANCH_UNIT VERIFICATION ===");

    // Equality branches
    $display("\n--- Test Group 1: Equality Branches ---");
    op.branch_jump_op = BEQ_OP;
    test_branch_op("BEQ taken (42 == 42)", 32'd42, 32'd42, 32'h8000_0000, 32'd16, b_ctrl, op);
    test_branch_op("BEQ not-taken (42 != 43)", 32'd42, 32'd43, 32'h8000_0000, 32'd16, b_ctrl, op);
    op.branch_jump_op = BNE_OP;
    test_branch_op("BNE taken (42 != 43)", 32'd42, 32'd43, 32'h8000_0000, 32'd16, b_ctrl, op);
    test_branch_op("BNE not-taken (42 == 42)", 32'd42, 32'd42, 32'h8000_0000, 32'd16, b_ctrl, op);

    // Signed comparisons
    $display("\n--- Test Group 2: Signed Comparisons ---");
    op.branch_jump_op = BLT_OP;
    test_branch_op("BLT taken (-10 < 5)", -32'd10, 32'd5, 32'h8000_0000, 32'd20, b_ctrl, op);
    test_branch_op("BLT not-taken (5 < -10)", 32'd5, -32'd10, 32'h8000_0000, 32'd20, b_ctrl, op);
    test_branch_op("BLT not-taken (equal)", 32'd5, 32'd5, 32'h8000_0000, 32'd20, b_ctrl, op);
    test_branch_op("BLT taken (MIN_SIGNED < MAX_SIGNED)", 32'h8000_0000, 32'h7FFF_FFFF, 32'h8000_0000, 32'd20, b_ctrl, op);

    op.branch_jump_op = BGE_OP;
    test_branch_op("BGE taken (5 >= -10)", 32'd5, -32'd10, 32'h8000_0000, 32'd20, b_ctrl, op);
    test_branch_op("BGE taken (equal)", 32'd5, 32'd5, 32'h8000_0000, 32'd20, b_ctrl, op);
    test_branch_op("BGE not-taken (-10 >= 5)", -32'd10, 32'd5, 32'h8000_0000, 32'd20, b_ctrl, op);

    // Unsigned comparisons
    $display("\n--- Test Group 3: Unsigned Comparisons ---");
    op.branch_jump_op = BLTU_OP;
    test_branch_op("BLTU taken (5 < 10)", 32'd5, 32'd10, 32'h8000_0000, 32'd24, b_ctrl, op);
    test_branch_op("BLTU not-taken (0xFFFFFFFF < 5)", 32'hFFFF_FFFF, 32'd5, 32'h8000_0000, 32'd24, b_ctrl, op);
    test_branch_op("BLTU taken (5 < 0xFFFFFFFF)", 32'd5, 32'hFFFF_FFFF, 32'h8000_0000, 32'd24, b_ctrl, op);
    test_branch_op("BLTU not-taken (0x80000000 < 0x7FFFFFFF)", 32'h8000_0000, 32'h7FFF_FFFF, 32'h8000_0000, 32'd24, b_ctrl, op);

    op.branch_jump_op = BGEU_OP;
    test_branch_op("BGEU taken (0xFFFFFFFF >= 5)", 32'hFFFF_FFFF, 32'd5, 32'h8000_0000, 32'd24, b_ctrl, op);
    test_branch_op("BGEU taken (equal)", 32'd5, 32'd5, 32'h8000_0000, 32'd24, b_ctrl, op);
    test_branch_op("BGEU not-taken (5 >= 0xFFFFFFFF)", 32'd5, 32'hFFFF_FFFF, 32'h8000_0000, 32'd24, b_ctrl, op);

    // JAL direct jumps
    $display("\n--- Test Group 4: JAL Direct Jumps ---");
    op.branch_jump_op = JAL_OP;
    test_branch_op("JAL jump forward", 32'h0, 32'h0, 32'h8000_0100, 32'h0000_0200, j_ctrl, op);
    test_branch_op("JAL jump backward", 32'h0, 32'h0, 32'h8000_0100, -32'd64, j_ctrl, op);

    // JALR indirect jumps
    $display("\n--- Test Group 5: JALR Indirect Jumps ---");
    op.branch_jump_op = JALR_OP;
    test_branch_op("JALR aligned target", 32'h8000_0200, 32'h0, 32'h8000_0100, 32'd16, j_ctrl, op);
    test_branch_op("JALR unaligned bit 0 clearing (0x80000201 + 4 -> 0x80000204)",
                   32'h8000_0201, 32'h0, 32'h8000_0100, 32'd4, j_ctrl, op);
    test_branch_op("JALR unaligned bit 0 clearing (0x80000200 + 1 -> 0x80000200)",
                   32'h8000_0200, 32'h0, 32'h8000_0100, 32'd1, j_ctrl, op);
    test_branch_op("JALR negative imm with bit 0 clearing", 32'h8000_0205, 32'h0, 32'h8000_0100, -32'd4, j_ctrl, op);

    // Inactive output suppression
    $display("\n--- Test Group 6: Non-Branch Safe Output Suppression ---");
    op.alu_op = ADD_OP; // shared union bits = 3'b000 (same as BEQ_OP)
    test_branch_op("ADD instruction with equal rs1==rs2 (must NOT branch)",
                   32'd42, 32'd42, 32'h8000_0000, 32'd100, no_ctrl, op);

    op.shift_op = SLL_OP;
    test_branch_op("SLL instruction (must NOT branch)",
                   32'd10, 32'd20, 32'h8000_0000, 32'd100, no_ctrl, op);

    // Randomized fuzzing
    $display("\n--- Test Group 7: Randomized Fuzzing against Golden Model ---");
    for (int iter = 0; iter < 500; iter++) begin
      automatic rv32_data_t r_rs1 = $urandom();
      automatic rv32_data_t r_rs2 = $urandom();
      automatic rv32_data_t r_pc  = {$urandom(), 2'b00};
      automatic rv32_data_t r_imm = {$urandom(), 2'b00};
      automatic control_data_t r_ctrl = '0;
      fu_op_t r_op;

      case ($urandom_range(0, 2))
        0: begin // Conditional Branch
          r_ctrl.Branch = 1'b1;
          case ($urandom_range(0, 5))
            0: r_op.branch_jump_op = BEQ_OP;
            1: r_op.branch_jump_op = BNE_OP;
            2: r_op.branch_jump_op = BLT_OP;
            3: r_op.branch_jump_op = BGE_OP;
            4: r_op.branch_jump_op = BLTU_OP;
            5: r_op.branch_jump_op = BGEU_OP;
          endcase
        end
        1: begin // Jump
          r_ctrl.Jump = 1'b1;
          r_op.branch_jump_op = ($urandom_range(0, 1) == 0) ? JAL_OP : JALR_OP;
        end
        2: begin // Non-control-transfer
          r_ctrl.Branch = 1'b0;
          r_ctrl.Jump   = 1'b0;
          r_op.alu_op   = alu_op_t'($urandom_range(0, 4));
        end
      endcase

      test_branch_op($sformatf("RAND_%0d", iter), r_rs1, r_rs2, r_pc, r_imm, r_ctrl, r_op);
    end

    #10;
    $display("\n==========================================================================");
    $display("BRANCH_UNIT TEST SUMMARY: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("==========================================================================");

    if (fail_cnt > 0) $fatal(1, "TEST FAILED WITH %0d ERRORS", fail_cnt);
    else $display("ALL %0d CHECKS PASSED PERFECTLY", pass_cnt);

    $finish;
  end

endmodule
