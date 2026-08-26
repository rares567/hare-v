`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns/1ps

// Testbench for register_bank_inorder.
//
// Checks:
// - async read ports 1 & 2
// - sync writes on posedge clk
// - x0 hardwired to 0
// - internal wb->id bypass (same-cycle write-first)

module register_bank_inorder_tb;
  import decode_package::*;

  localparam type DATA_T = bit [31:0];
  localparam int NUM_REGS = 32;
  localparam int ADDR_WIDTH = $clog2(NUM_REGS);
  localparam int CLK_PERIOD = 10;

  // Interface Signals
  logic                  clk;
  logic                  rst;

  logic                  i_we;
  logic [ADDR_WIDTH-1:0] i_waddr;
  DATA_T                 i_wdata;

  logic [ADDR_WIDTH-1:0] i_raddr1;
  logic [ADDR_WIDTH-1:0] i_raddr2;
  DATA_T                 o_rdata1;
  DATA_T                 o_rdata2;

  // Instantiate DUT
  register_bank_inorder #(
      .DATA_T  (DATA_T),
      .NUM_REGS(NUM_REGS)
  ) dut (
      .*
  );

  // Clock Gen
  always #(CLK_PERIOD / 2) clk = (clk === 1'b0);

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

  task automatic do_reset();
    @(negedge clk);
    rst      = 1'b1;
    i_we     = 1'b0;
    i_waddr  = '0;
    i_wdata  = '0;
    i_raddr1 = '0;
    i_raddr2 = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  endtask

  task automatic write_reg(input logic [ADDR_WIDTH-1:0] addr, input DATA_T data);
    @(negedge clk);
    i_we    = 1'b1;
    i_waddr = addr;
    i_wdata = data;
    @(posedge clk);
    #1;
    i_we    = 1'b0;
  endtask

  // -------------------------------------------------------------------------
  // Main Test Sequence
  // -------------------------------------------------------------------------
  initial begin
    do_reset();

    // Test Group 1: Reset check (all registers initialize to zero)
    for (int i = 0; i < NUM_REGS; i++) begin
      i_raddr1 = i;
      i_raddr2 = i;
      #1;
      chk($sformatf("reset: r1[%0d] == 0", i), o_rdata1, 32'h0);
      chk($sformatf("reset: r2[%0d] == 0", i), o_rdata2, 32'h0);
    end

    // Test Group 2: Write sweep (x1..x31 test pattern loading)
    for (int i = 1; i < NUM_REGS; i++) begin
      write_reg(i, 32'hA000_0000 | (i << 16) | i);
    end

    // Test Group 3: Dual-port simultaneous read verification
    for (int i = 1; i < NUM_REGS; i += 2) begin
      i_raddr1 = i;
      i_raddr2 = (i + 1 < NUM_REGS) ? (i + 1) : 0;
      #1;
      chk($sformatf("read: r1[%0d]", i), o_rdata1, 32'hA000_0000 | (i << 16) | i);
      if (i + 1 < NUM_REGS)
        chk($sformatf("read: r2[%0d]", i + 1), o_rdata2, 32'hA000_0000 | ((i + 1) << 16) | (i + 1));
    end

    // Test Group 4: Register x0 immutability
    write_reg(5'd0, 32'hDEAD_BEEF);
    i_raddr1 = 5'd0;
    i_raddr2 = 5'd0;
    #1;
    chk("x0 immutability r1", o_rdata1, 32'h0);
    chk("x0 immutability r2", o_rdata2, 32'h0);

    // Test Group 5: Internal same-cycle WB-to-ID bypass
    for (int i = 1; i < NUM_REGS; i++) begin
      @(negedge clk);
      i_we     = 1'b1;
      i_waddr  = i;
      i_wdata  = 32'hBEEF_0000 | i;
      i_raddr1 = i;
      i_raddr2 = i;
      #1;
      chk($sformatf("bypass: r1[%0d]", i), o_rdata1, 32'hBEEF_0000 | i);
      chk($sformatf("bypass: r2[%0d]", i), o_rdata2, 32'hBEEF_0000 | i);
      @(posedge clk);
      i_we     = 1'b0;
    end

    #20;
    $display("--- Summary: %0d passed, %0d failed ---", pass_cnt, fail_cnt);
    if (fail_cnt > 0) $fatal(1, "TEST FAILED");
    else $display("ALL TESTS PASSED");
    $finish;
  end

endmodule