`ifndef verilatorsim
`include "../design/includes/interfaces.svh"
`include "../design/includes/decode.svh"
`else
`include "interfaces.svh"
`include "decode.svh"
`endif

`timescale 1ns/1ps

// Unit testbench for instr_fetch_stage with 1-cycle synchronous BRAM.
module instr_fetch_stage_tb;
  import decode_package::*;

  localparam rv32_data_t START_ADDR = 32'h0000_0000;
  localparam int CLK_PERIOD = 10;

  logic clk, rst;
  logic i_stall_if;
  logic i_branch_taken;
  rv32_data_t i_branch_target;

  instruction_t o_if_instr;
  rv32_data_t   o_if_pc;
  logic         o_if_valid;

  wishboneIf #(
      .DATA_T    (rv32_data_t),
      .ADDR_WIDTH(12)
  ) wb_imem_bus (.clk(clk));

  instr_fetch_stage #(
      .DATA_T       (rv32_data_t),
      .START_ADDRESS(START_ADDR)
  ) dut (
      .wb_imem(wb_imem_bus.Master),
      .*
  );

  wb_bram_sync #(
      .INIT_FILE    (""),
      .START_ADDRESS(0),
      .SIZE         (4096)
  ) imem_inst (
      .wb_cpu(wb_imem_bus.Slave),
      .*
  );

  always #(CLK_PERIOD / 2) clk = (clk === 1'b0);

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

  function automatic rv32_data_t exp_word(input rv32_data_t pc);
    return 32'hDEAD_0000 | (pc & 32'h0000_0FFF);
  endfunction

  task automatic preload_imem();
    for (int i = 0; i < 1024; i++) begin
      imem_inst.mem[i] = 32'hDEAD_0000 | (i * 4);
    end
  endtask

  task automatic do_reset();
    rst = 1'b1;
    i_stall_if = 1'b0;
    i_branch_taken = 1'b0;
    i_branch_target = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  endtask

  rv32_data_t exp_pc;
  rv32_data_t held_pc;

  initial begin
    preload_imem();
    do_reset();

    $display("=== STARTING INSTR_FETCH_STAGE (1-CYCLE BRAM) VERIFICATION ===");

    // Post-reset startup and sequential stream
    $display("\n--- Test 1: Post-Reset Startup & 64-Word Sequential Stream ---");
    #1;
    chk_bit("post-reset bubble: valid=0 before first edge", o_if_valid, 1'b0);
    chk("post-reset bubble: pc_r at START_ADDR", o_if_pc, START_ADDR);

    for (int i = 0; i < 64; i++) begin
      @(posedge clk);
      #1;
      chk_bit($sformatf("seq[%0d]: valid", i), o_if_valid, 1'b1);
      chk($sformatf("seq[%0d]: pc", i),        o_if_pc,        START_ADDR + (i * 4));
      chk($sformatf("seq[%0d]: instr", i),     o_if_instr.raw, exp_word(START_ADDR + (i * 4)));
    end

    // Stall ordering regression
    $display("\n--- Test 2: Stall Ordering Regression (1, 2, 5 cycles) ---");
    do_reset();
    exp_pc = START_ADDR;

    // Advance 3 normal instructions (PC = 0, 4, 8)
    for (int i = 0; i < 3; i++) begin
      @(posedge clk);
      #1;
      chk($sformatf("pre-stall[%0d]: pc", i),    o_if_pc,        exp_pc);
      chk($sformatf("pre-stall[%0d]: instr", i), o_if_instr.raw, exp_word(exp_pc));
      exp_pc += 4;
    end

    // Stall for 1, 2, and 5 cycles and verify no instruction is skipped after release
    for (int s = 0; s < 3; s++) begin
      automatic int stall_cycles = (s == 0) ? 1 : ((s == 1) ? 2 : 5);
      held_pc = o_if_pc;

      @(negedge clk);
      i_stall_if = 1'b1;
      for (int c = 0; c < stall_cycles; c++) begin
        @(posedge clk);
        #1;
        chk_bit($sformatf("stall(%0d)[%0d]: valid held", stall_cycles, c), o_if_valid, 1'b1);
        chk($sformatf("stall(%0d)[%0d]: pc held", stall_cycles, c),        o_if_pc,        held_pc);
        chk($sformatf("stall(%0d)[%0d]: instr held", stall_cycles, c),     o_if_instr.raw, exp_word(held_pc));
      end

      // Release stall: next rising edge must deliver exact next instruction exp_pc
      @(negedge clk);
      i_stall_if = 1'b0;
      for (int k = 0; k < 4; k++) begin
        @(posedge clk);
        #1;
        chk_bit($sformatf("post-stall(%0d)[%0d]: valid", stall_cycles, k), o_if_valid, 1'b1);
        chk($sformatf("post-stall(%0d)[%0d]: exact next pc", stall_cycles, k), o_if_pc, exp_pc);
        chk($sformatf("post-stall(%0d)[%0d]: exact next instr", stall_cycles, k), o_if_instr.raw, exp_word(exp_pc));
        exp_pc += 4;
      end
    end

    // Branch redirect
    $display("\n--- Test 3: Branch Redirect ---");
    @(negedge clk);
    i_branch_taken  = 1'b1;
    i_branch_target = 32'h0000_0180;
    @(posedge clk);
    #1;
    chk_bit("branch: valid on target edge", o_if_valid, 1'b1);
    chk("branch: PC immediately at target", o_if_pc, 32'h0000_0180);
    chk("branch: target instr",             o_if_instr.raw, exp_word(32'h0000_0180));

    @(negedge clk);
    i_branch_taken = 1'b0;
    @(posedge clk);
    #1;
    chk("branch+1: sequential target+4", o_if_pc, 32'h0000_0184);
    chk("branch+1: instr at target+4",   o_if_instr.raw, exp_word(32'h0000_0184));

    // Unaligned branch target
    @(negedge clk);
    i_branch_taken  = 1'b1;
    i_branch_target = 32'h0000_0182;
    @(posedge clk);
    #1;
    chk_bit("unaligned branch: valid on target edge", o_if_valid, 1'b1);
    chk("unaligned branch: PC at unaligned target",   o_if_pc, 32'h0000_0182);
    chk("unaligned branch: word read",                o_if_instr.raw, exp_word(32'h0000_0180));

    @(negedge clk);
    i_branch_taken = 1'b0;
    @(posedge clk);
    #1;
    chk("unaligned branch+1: sequential target+4",    o_if_pc, 32'h0000_0186);
    chk("unaligned branch+1: word at target+4",       o_if_instr.raw, exp_word(32'h0000_0184));

    // Branch priority over stall
    $display("\n--- Test 4: Branch Priority Over Stall ---");
    @(negedge clk);
    i_stall_if      = 1'b1;
    i_branch_taken  = 1'b1;
    i_branch_target = 32'h0000_0240;
    @(posedge clk);
    #1;
    chk("branch-over-stall: PC redirected", o_if_pc, 32'h0000_0240);
    chk("branch-over-stall: target instr",  o_if_instr.raw, exp_word(32'h0000_0240));
    @(negedge clk);
    i_stall_if     = 1'b0;
    i_branch_taken = 1'b0;

    // Back-to-back branches
    $display("\n--- Test 5: Back-to-Back Branches ---");
    @(negedge clk);
    i_branch_taken  = 1'b1;
    i_branch_target = 32'h0000_0300;
    @(posedge clk);
    #1;
    chk("b2b[0]: first target PC",    o_if_pc, 32'h0000_0300);
    chk("b2b[0]: first target instr", o_if_instr.raw, exp_word(32'h0000_0300));

    @(negedge clk);
    i_branch_target = 32'h0000_0400;
    @(posedge clk);
    #1;
    chk("b2b[1]: second target PC",    o_if_pc, 32'h0000_0400);
    chk("b2b[1]: second target instr", o_if_instr.raw, exp_word(32'h0000_0400));

    @(negedge clk);
    i_branch_taken = 1'b0;
    @(posedge clk);
    #1;
    chk("b2b[2]: sequential after second target", o_if_pc, 32'h0000_0404);

    // Randomized fuzzing
    $display("\n--- Test 6: Randomized Fuzzing (500 iterations) ---");
    do_reset();
    exp_pc = START_ADDR;
    begin
      automatic logic exp_valid = 1'b0;

      for (int iter = 0; iter < 500; iter++) begin
        automatic int action = $urandom_range(0, 3);
        automatic rv32_data_t rand_tgt = {$urandom_range(0, 1023), 2'b00};

        if (iter > 0) @(negedge clk);
        case (action)
          0, 1: begin // Normal advance
            i_stall_if = 1'b0;
            i_branch_taken = 1'b0;
          end
          2: begin // Stall
            i_stall_if = 1'b1;
            i_branch_taken = 1'b0;
          end
          3: begin // Branch (occasionally combined with stall)
            i_stall_if = $urandom_range(0, 1);
            i_branch_taken = 1'b1;
            i_branch_target = rand_tgt;
          end
        endcase

        // Golden next-state prediction matching 1-cycle BRAM timing
        if (i_branch_taken) begin
          exp_pc = i_branch_target;
        end else if (!i_stall_if && exp_valid) begin
          exp_pc = exp_pc + 32'd4;
        end
        exp_valid = 1'b1;

        @(posedge clk);
        #1;
        chk_bit($sformatf("fuzz[%0d]: valid", iter), o_if_valid, exp_valid);
        chk($sformatf("fuzz[%0d]: pc", iter),        o_if_pc,        exp_pc);
        chk($sformatf("fuzz[%0d]: instr", iter),     o_if_instr.raw, exp_word(exp_pc));
      end
    end

    #20;
    $display("\n==========================================================================");
    $display("INSTR_FETCH_STAGE TEST SUMMARY: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("==========================================================================");
    if (fail_cnt > 0) $fatal(1, "TEST FAILED WITH %0d ERRORS", fail_cnt);
    else $display("ALL %0d CHECKS PASSED PERFECTLY", pass_cnt);
    $finish;
  end

endmodule
