`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns/1ps

// Testbench for register_bank_2r1w.
//
// The bank is more than a register file: alongside the data it tracks, per
// architectural register, a busy flag and the ROB tag of that register's most
// recent producer. Reads are registered, so an address driven on cycle N produces
// its data/busy/tag on N+1, and a commit landing on the same cycle as a read of
// the same register has to be bypassed to the output rather than read stale out
// of the RAM.
//
// The interesting cases are all about *which* producer a commit belongs to. A
// register can have several instructions in flight targeting it; only a commit
// carrying the newest tag makes it ready. A commit from a superseded producer
// must leave the register busy and must not be forwarded, because its value is
// already stale by the time it arrives.
//
// Every check drives inputs on the negedge and samples one posedge later, which
// is exactly the read latency of the bank.

module register_bank_tb;
  import decode_package::*;

  localparam type DATA_T = bit [31:0];
  localparam int NUM_REGS = 32;
  localparam int ADDR_WIDTH = $clog2(NUM_REGS);
  localparam int ROBTAG_WIDTH = $clog2(decode_package::ROB_DEPTH);
  localparam int CLK_PERIOD = 10;

  logic                     clk;
  logic                     rst;
  logic                     ce;

  logic                     i_commit_en;
  logic  [  ADDR_WIDTH-1:0] i_commit_addr;
  DATA_T                    i_commit_data;
  logic  [ROBTAG_WIDTH-1:0] i_commit_tag;

  logic  [  ADDR_WIDTH-1:0] i_rs1_addr;
  logic  [  ADDR_WIDTH-1:0] i_rs2_addr;
  logic  [  ADDR_WIDTH-1:0] i_rd_addr;
  logic  [ROBTAG_WIDTH-1:0] i_rd_tag;
  logic                     i_rd_we;

  DATA_T                    o_rs1_data;
  DATA_T                    o_rs2_data;
  logic                     o_rs1_busy;
  logic                     o_rs2_busy;
  logic  [ROBTAG_WIDTH-1:0] o_rs1_tag;
  logic  [ROBTAG_WIDTH-1:0] o_rs2_tag;

  register_bank_2r1w #(
      .DATA_T  (DATA_T),
      .NUM_REGS(NUM_REGS)
  ) dut (
      .*
  );

  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

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

  //drive one cycle: inputs settle on the negedge, are captured on the posedge, and
  //the outputs they produce are readable as soon as this returns
  task automatic cycle(input logic [ADDR_WIDTH-1:0] rs1 = '0, input logic [ADDR_WIDTH-1:0] rs2 = '0,
                       input logic rd_we = 1'b0, input logic [ADDR_WIDTH-1:0] rd = '0,
                       input logic [ROBTAG_WIDTH-1:0] rd_tag = '0, input logic cm_en = 1'b0,
                       input logic [ADDR_WIDTH-1:0] cm_addr = '0, input DATA_T cm_data = '0,
                       input logic [ROBTAG_WIDTH-1:0] cm_tag = '0, input logic ce_in = 1'b1);
    @(negedge clk);
    ce            = ce_in;
    i_rs1_addr    = rs1;
    i_rs2_addr    = rs2;
    i_rd_we       = rd_we;
    i_rd_addr     = rd;
    i_rd_tag      = rd_tag;
    i_commit_en   = cm_en;
    i_commit_addr = cm_addr;
    i_commit_data = cm_data;
    i_commit_tag  = cm_tag;
    @(posedge clk);
    #1;
  endtask

  task automatic do_reset();
    @(negedge clk);
    rst           = 1'b1;
    ce            = 1'b1;
    i_rs1_addr    = '0;
    i_rs2_addr    = '0;
    i_rd_we       = '0;
    i_rd_addr     = '0;
    i_rd_tag      = '0;
    i_commit_en   = '0;
    i_commit_addr = '0;
    i_commit_data = '0;
    i_commit_tag  = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    @(posedge clk);
    #1;
  endtask

  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, register_bank_tb);

    // =====================================================================
    $display("\n--- 1. commit then read back, on both ports ---");
    do_reset();
    cycle(.cm_en(1), .cm_addr(5'd5), .cm_data(32'hDEAD_BEEF), .cm_tag('0));
    cycle(.cm_en(1), .cm_addr(5'd9), .cm_data(32'h1234_5678), .cm_tag('0));
    cycle(.rs1(5'd5), .rs2(5'd9));
    chk("x5 reads back on rs1", o_rs1_data, 32'hDEAD_BEEF);
    chk("x9 reads back on rs2", o_rs2_data, 32'h1234_5678);
    //the two ports are separate banks, so prove they are not aliased
    cycle(.rs1(5'd9), .rs2(5'd5));
    chk("ports are independent (rs1=x9)", o_rs1_data, 32'h1234_5678);
    chk("ports are independent (rs2=x5)", o_rs2_data, 32'hDEAD_BEEF);

    // =====================================================================
    $display("\n--- 2. x0 is hardwired zero ---");
    do_reset();
    cycle(.cm_en(1), .cm_addr(5'd0), .cm_data(32'hFFFF_FFFF), .cm_tag('0));
    cycle(.rs1(5'd0), .rs2(5'd0));
    chk("x0 reads zero on rs1 even after a write", o_rs1_data, 32'd0);
    chk("x0 reads zero on rs2 even after a write", o_rs2_data, 32'd0);
    //x0 can legally be an instruction's rd (the canonical NOP), and must never
    //become a dependency for anyone
    cycle(.rd_we(1), .rd(5'd0), .rd_tag(5'd4));
    cycle(.rs1(5'd0));
    chk("x0 never reports busy", o_rs1_busy, 1'b0);

    // =====================================================================
    $display("\n--- 3. commit bypass: read and commit the same register ---");
    do_reset();
    cycle(.cm_en(1), .cm_addr(5'd7), .cm_data(32'h0000_1111), .cm_tag('0));
    //the RAM read port is read-first, so without the bypass this returns the old value
    cycle(.rs1(5'd7), .cm_en(1), .cm_addr(5'd7), .cm_data(32'hBEEF_CAFE), .cm_tag('0));
    chk("same-cycle commit is forwarded to rs1", o_rs1_data, 32'hBEEF_CAFE);
    cycle(.rs2(5'd7), .cm_en(1), .cm_addr(5'd7), .cm_data(32'h5555_6666), .cm_tag('0));
    chk("same-cycle commit is forwarded to rs2", o_rs2_data, 32'h5555_6666);

    // =====================================================================
    $display("\n--- 4. allocating a destination marks it busy and renames it ---");
    do_reset();
    //rd and its tag are deliberately different values: the busy list is indexed by
    //register address, the rename table stores the tag, and confusing the two is
    //invisible if they happen to be equal
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd3));
    cycle(.rs1(5'd5));
    chk("allocated rd reports busy", o_rs1_busy, 1'b1);
    chk("allocated rd carries its producer's tag", o_rs1_tag, 5'd3);
    cycle(.rs1(5'd3));
    chk("an unrelated register is untouched by the allocation", o_rs1_busy, 1'b0);

    // =====================================================================
    $display("\n--- 5. a commit on the newest tag releases the register ---");
    do_reset();
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd3));
    cycle(.cm_en(1), .cm_addr(5'd5), .cm_data(32'hA5A5_A5A5), .cm_tag(5'd3));
    cycle(.rs1(5'd5));
    chk("register is released once its newest producer commits", o_rs1_busy, 1'b0);
    chk("released register holds the committed value", o_rs1_data, 32'hA5A5_A5A5);

    // =====================================================================
    $display("\n--- 6. a commit on a superseded tag must not release ---");
    do_reset();
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd3));  //older producer
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd7));  //newer producer supersedes it
    cycle(.cm_en(1), .cm_addr(5'd5), .cm_data(32'hAAAA_AAAA), .cm_tag(5'd3));
    cycle(.rs1(5'd5));
    chk("stale commit leaves the register busy", o_rs1_busy, 1'b1);
    chk("rename tag still points at the newest producer", o_rs1_tag, 5'd7);

    // =====================================================================
    $display("\n--- 7. the bypass must respect the tag too ---");
    // Same setup as 6, but the read happens on the very cycle the stale commit
    // lands. The value being written belongs to a producer that has already been
    // superseded, so forwarding it would hand out a stale operand and, worse,
    // report the register as ready when it is still waiting on tag 7.
    do_reset();
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd3));
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd7));
    cycle(.rs1(5'd5), .cm_en(1), .cm_addr(5'd5), .cm_data(32'hAAAA_AAAA), .cm_tag(5'd3));
    chk("stale bypass must not report the register ready", o_rs1_busy, 1'b1);

    // =====================================================================
    $display("\n--- 8. re-allocating on the same cycle as a commit keeps it busy ---");
    do_reset();
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd3));
    //tag 3 commits while a new producer (tag 7) claims x5 in the same cycle
    cycle(.rd_we(1), .rd(5'd5), .rd_tag(5'd7), .cm_en(1), .cm_addr(5'd5), .cm_data(32'h1111_2222),
          .cm_tag(5'd3));
    cycle(.rs1(5'd5));
    chk("register stays busy for the new producer", o_rs1_busy, 1'b1);
    chk("rename tag follows the new producer", o_rs1_tag, 5'd7);

    // =====================================================================
    $display("\n--- 9. ce low freezes the bank ---");
    do_reset();
    cycle(.cm_en(1), .cm_addr(5'd12), .cm_data(32'h0BAD_0BAD), .cm_tag('0));
    //try to overwrite x12 and allocate x13 while stalled: neither may take effect.
    //ce has to be driven as part of the cycle rather than poked around it, or the
    //commit stays asserted into the cycle where ce comes back and lands after all
    cycle(.ce_in(0), .rd_we(1), .rd(5'd13), .rd_tag(5'd9), .cm_en(1), .cm_addr(5'd12),
          .cm_data(32'hFFFF_0000), .cm_tag('0));
    cycle(.rs1(5'd12), .rs2(5'd13));
    chk("write while stalled did not land", o_rs1_data, 32'h0BAD_0BAD);
    chk("allocation while stalled did not land", o_rs2_busy, 1'b0);

    // =====================================================================
    $display("\n--- 10. reset clears the visible state ---");
    do_reset();
    cycle(.cm_en(1), .cm_addr(5'd20), .cm_data(32'hCAFE_F00D), .cm_tag('0));
    cycle(.rd_we(1), .rd(5'd20), .rd_tag(5'd11));
    do_reset();
    cycle(.rs1(5'd20));
    chk("register file is zeroed by reset", o_rs1_data, 32'd0);
    chk("busy list is cleared by reset", o_rs1_busy, 1'b0);
    chk("rename table is cleared by reset", o_rs1_tag, 5'd0);

    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED", fail_cnt);
    $finish;
  end

endmodule
