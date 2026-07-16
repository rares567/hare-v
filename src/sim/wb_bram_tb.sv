`include "../wishbone/wb_ram.sv"
`timescale 1ns / 1ps

// Testbench for wb_bram (pipelined Wishbone BRAM slave).
//
// Protocol / timing model (from the RTL):
//   * stall is always 0 -> a request (cyc & stb) is accepted every cycle.
//   * 2-cycle latency: a request at cycle R yields ack (and data_rd for reads)
//     two cycles later; back-to-back requests produce a back-to-back ack stream.
//   * byte-enable writes via sel; reads return the whole word.
//   * a read observes writes from strictly earlier request cycles, so a
//     write immediately followed by a read of the same word returns the new
//     value.
//   * mem is initialised to 0 and survives rst (only the pipeline registers
//     reset); err never fires for in-range addresses (always the case here).
//
// Scoreboard: a reference word memory plus a 1-deep response delay line.  Each
// cycle the expected {ack, read-data} for the request being issued is computed
// from the model *before* that cycle's write is applied, then checked against
// the bus when the response emerges.  The bus is driven directly (pipelined)
// rather than through the blocking MasterRead/MasterWrite tasks.

module wb_bram_tb;

  localparam int DataWidth = 32;
  localparam int SelWidth = 4;
  localparam int NumWords = 256;  // 2**(ADDR_WIDTH - clog2(SELECT_WIDTH))
  typedef bit [DataWidth-1:0] data_t;

  logic clk, rst;
  wishboneIf #(.DATA_T(bit [DataWidth-1:0])) wbIf (clk);

  wb_bram dut (
      .clk(clk),
      .rst(rst),
      .wb_cpu(wbIf.Slave)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  // Reference model + response pipeline
  // -------------------------------------------------------------------------
  typedef struct {
    bit    expect_ack;
    bit    is_read;
    data_t rdata;
  } resp_t;

  data_t mem_ref[NumWords];  // golden memory (init 0, persists across rst)
  resp_t exp_1, exp_2;  // 2-deep response delay line
  int pass_cnt = 0;
  int fail_cnt = 0;

  // Drive one bus cycle and run the scoreboard.
  //   req : assert a request this cycle (cyc & stb)
  //   we  : 1 = write, 0 = read
  //   word: word index (byte address = word << 2)
  task automatic step(input bit req, input bit we, input int word, input data_t wdata,
                      input logic [SelWidth-1:0] sel);
    resp_t e0;

    #1;
    // 1) response now corresponds to the request issued two cycles ago
    if (exp_2.expect_ack) begin
      if (wbIf.ack !== 1'b1) begin
        $display("[FAIL] expected ack, got %0b", wbIf.ack);
        fail_cnt++;
      end else begin
        pass_cnt++;
      end
      if (exp_2.is_read) begin
        if (wbIf.data_rd !== exp_2.rdata) begin
          $display("[FAIL] rdata=0x%08h expected=0x%08h", wbIf.data_rd, exp_2.rdata);
          fail_cnt++;
        end else begin
          pass_cnt++;
        end
      end
    end else begin
      if (wbIf.ack !== 1'b0) begin
        $display("[FAIL] unexpected ack");
        fail_cnt++;
      end else begin
        pass_cnt++;
      end
    end
    if (wbIf.err !== 1'b0) begin
      $display("[FAIL] unexpected err");
      fail_cnt++;
    end

    // 2) expectation for the request issued THIS cycle (in range always)
    e0 = '{default: 0};
    if (req) begin
      e0.expect_ack = 1'b1;
      e0.is_read    = ~we;
      if (~we) e0.rdata = mem_ref[word];
    end

    // 3) advance the 2-deep response pipeline
    exp_2 = exp_1;
    exp_1 = e0;

    // 4) apply this cycle's write to the model (byte enables)
    if (req && we)
      for (int b = 0; b < SelWidth; b++) if (sel[b]) mem_ref[word][8*b+:8] = wdata[8*b+:8];

    // 5) drive the bus for this cycle
    wbIf.cyc     = req;
    wbIf.stb     = req;
    wbIf.we      = we;
    wbIf.addr    = word << 2;
    wbIf.data_wr = wdata;
    wbIf.sel     = sel;

    @(posedge clk);
  endtask

  task automatic wr(input int word, input data_t d, input logic [SelWidth-1:0] sel);
    step(1'b1, 1'b1, word, d, sel);
  endtask
  task automatic rd(input int word);
    step(1'b1, 1'b0, word, '0, '1);
  endtask
  task automatic idle();
    step(1'b0, 1'b0, 0, '0, '0);
  endtask

  task automatic do_reset();
    exp_1 = '{default: 0};
    exp_2 = '{default: 0};
    wbIf.cyc = 0;
    wbIf.stb = 0;
    wbIf.we = 0;
    wbIf.addr = 0;
    wbIf.data_wr = 0;
    wbIf.sel = 0;
    rst = 1;
    repeat (3) @(posedge clk);
    rst = 0;
    @(posedge clk);
  endtask

  // -------------------------------------------------------------------------
  // Test sequence
  // -------------------------------------------------------------------------
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, wb_bram_tb);
    do_reset();

    // ---- TEST 1: pipelined write burst then read burst ----
    $display("\n=== TEST 1: pipelined write/read burst ===");
    for (int i = 0; i < 32; i++) wr(i, 32'h1000_0000 + i, 4'hF);
    repeat (2) idle();
    for (int i = 0; i < 32; i++) rd(i);
    repeat (2) idle();

    // ---- TEST 2: read immediately after write (back-to-back ordering) ----
    $display("\n=== TEST 2: read-after-write ordering ===");
    for (int i = 0; i < 8; i++) begin
      wr(100 + i, 32'hCAFE_0000 + i, 4'hF);
      rd(100 + i);  // issued the very next cycle
    end
    repeat (2) idle();

    // ---- TEST 3: byte-enable writes ----
    $display("\n=== TEST 3: byte-enable writes ===");
    wr(50, 32'hAABB_CCDD, 4'hF);  // full word
    repeat (2) idle();
    rd(50);
    wr(50, 32'h1122_3344, 4'b0010);  // byte 1 only -> 0xAABB33DD
    repeat (2) idle();
    rd(50);
    wr(50, 32'hFFFF_FFFF, 4'b1001);  // bytes 0 and 3 -> 0xFFBB33FF
    repeat (2) idle();
    rd(50);
    repeat (2) idle();

    // ---- TEST 4: idle gaps between requests (ack only for real requests) ----
    $display("\n=== TEST 4: idle gaps ===");
    wr(70, 32'hDEAD_BEEF, 4'hF);
    idle();
    idle();
    idle();
    rd(70);
    idle();
    idle();

    // ---- TEST 5: randomized stress ----
    $display("\n=== TEST 5: randomized stress ===");
    for (int c = 0; c < 500; c++) begin
      static bit                   req = $urandom_range(0, 1);
      static bit                   we = $urandom_range(0, 1);
      static int                   word = $urandom_range(0, 63);
      static data_t                d = $urandom;
      static logic  [SelWidth-1:0] sel = $urandom_range(0, 15);
      step(req, we, word, d, sel);
    end
    repeat (2) idle();

    // ---- Summary ----
    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED - see [FAIL] lines above", fail_cnt);

    #20 $finish;
  end

endmodule
