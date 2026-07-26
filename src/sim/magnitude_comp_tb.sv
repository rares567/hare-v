`ifdef verilatorsim
`include "functional_units.svh"
`else
`include "../design/includes/functional_units.svh"
`endif
`timescale 1ns / 1ps

module xilinx_magnitude_comp_tb;

  localparam int DATA_WIDTH = 32;
  localparam int CLK_PERIOD = 10;
  localparam int LATENCY = 3;  // The 3-cycle pipeline delay

  // Interface Signals
  logic                             clk;
  logic                             rst;
  logic                             en;
  logic            [DATA_WIDTH-1:0] i_rs1;
  logic            [DATA_WIDTH-1:0] i_rs2;
  logic                             i_signed;
  magnitude_comp_t                  o_comp_result;
  logic                             o_valid;

  // --- Scoreboard Logic ---
  // This queue stores the expected result and the metadata for logging
  typedef struct {
    logic [DATA_WIDTH-1:0] a;
    logic [DATA_WIDTH-1:0] b;
    logic                  is_signed;
    magnitude_comp_t       exp_res;
  } test_packet_t;

  test_packet_t scoreboard[$];

  // Instantiate DUT
  xilinx_magnitude_comp #(.DATA_WIDTH(DATA_WIDTH)) dut (.*);

  // Clock Gen
  always #(CLK_PERIOD / 2) clk = (clk === 1'b0);

  // --- Reference Model ---
  // Function to calculate what the hardware SHOULD output
  function magnitude_comp_t get_expected(logic [31:0] a, logic [31:0] b, logic sgn);
    if (sgn) begin
      if ($signed(a) == $signed(b)) return EQ;
      if ($signed(a) < $signed(b)) return LT;
      return GT;
    end else begin
      if (a == b) return EQ;
      if (a < b) return LT;
      return GT;
    end
  endfunction

  // --- Input Driver ---
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars(0, xilinx_magnitude_comp_tb);

    clk = 0;
    rst = 1;
    en = 0;
    i_rs1 = 0;
    i_rs2 = 0;
    i_signed = 0;
    repeat (5) @(posedge clk);
    rst = 0;
    @(posedge clk);

    // Test Sequence: We can drive these back-to-back because it's pipelined!
    drive_sample(32'd10, 32'd10, 0);  // Unsigned EQ
    drive_sample(32'd5, 32'd10, 0);  // Unsigned LT
    drive_sample(32'd20, 32'd10, 0);  // Unsigned GT
    drive_sample(32'd10, 32'd10, 1);  // Unsigned EQ
    drive_sample(32'd5, 32'd10, 1);  // Unsigned LT
    drive_sample(32'd20, 32'd10, 1);  // Unsigned GT
    drive_sample(256, -256, 1);
    drive_sample(-256, 256, 1);

    // Disable for a cycle to test the 'en' gate
    en = 0;
    repeat (2) @(posedge clk);

    drive_sample(32'hFFFF_FFFF, 32'h0000_0001, 1);  // Signed LT (-1 < 1)
    drive_sample(32'h7000_0000, 32'h8000_0000, 1);  // Signed GT (Pos > Neg)
    drive_sample(32'h8000_0000, 32'h8000_0000, 1);  // Signed EQ    
    drive_sample(32'hFFFF_FFFF, 32'h0000_0001, 0);
    drive_sample(32'h7000_0000, 32'h8000_0000, 0);
    drive_sample(32'h8000_0000, 32'h8000_0000, 0);  // Unsigned EQ   

    en = 0;
    wait (scoreboard.size() == 0);
    repeat (5) @(posedge clk);
    $display("\n[SUCCESS] All tests passed through the pipeline.");
    $finish;
  end

  // --- Checker Logic ---
  // Monitors o_valid and compares output against the oldest item in the queue
  always @(posedge clk) begin
    if (o_valid) begin
      test_packet_t pkt;
      if (scoreboard.size() == 0) begin
        $error("[ERROR] Unexpected o_valid asserted! Scoreboard is empty.");
        $stop;
      end

      pkt = scoreboard.pop_front();

      if (o_comp_result !== pkt.exp_res) begin
        $error("[FAIL] A:%h B:%h Sgn:%b | Exp:%s Got:%s", pkt.a, pkt.b, pkt.is_signed,
               pkt.exp_res.name(), o_comp_result.name());
        $stop;
      end else begin
        $display("[PASS] %t | A:%h B:%h Sgn:%b | Result:%s", $time, pkt.a, pkt.b, pkt.is_signed,
                 o_comp_result.name());
      end
    end
  end

  // Task to simplify driving
  task drive_sample(input [31:0] a, input [31:0] b, input sgn);
    begin
      test_packet_t pkt;
      en = 1;
      i_rs1 = a;
      i_rs2 = b;
      i_signed = sgn;

      pkt.a = a;
      pkt.b = b;
      pkt.is_signed = sgn;
      pkt.exp_res = get_expected(a, b, sgn);
      scoreboard.push_back(pkt);

      @(posedge clk);
    end
  endtask

endmodule
