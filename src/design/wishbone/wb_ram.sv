`ifdef verilatorsim
`include "interfaces.svh"
`else
`include "../includes/interfaces.svh"
`endif

/*
 * Pipelined BRAM implementation with Wishbone interface (2-cycle read latency).
 * No real stall will take place, so requests can be sent back-to-back.
 * Single read/write port, meaning it should be used either as an IMEM or DMEM, but not both.
 * Sized by SIZE parameter with correct byte-to-word address offset calculation.
 */
module wb_bram #(
    parameter string INIT_FILE = "",
    parameter int START_ADDRESS = 32'h0,
    parameter int SIZE = 4096
) (
    input logic clk,
    (*direct_reset="true"*) input logic rst,
    wishboneIf.Slave wb_cpu
);

  localparam type data_t        = logic [wb_cpu.DATA_WIDTH-1:0];
  localparam int BYTES_PER_WORD = wb_cpu.SELECT_WIDTH;
  localparam int BITS_PER_BYTE  = wb_cpu.DATA_WIDTH / BYTES_PER_WORD;
  localparam int WORDS          = SIZE / BYTES_PER_WORD;
  localparam int ADDR_WIDTH     = $clog2(WORDS);

  data_t dat_o_reg = '0;
  data_t dat_i_reg = '0;
  logic ack_o_reg = '0;
  logic cyc_i_reg = '0;
  logic stb_i_reg = '0;
  logic we_i_reg = '0;
  logic [wb_cpu.SELECT_WIDTH-1:0] sel_i_reg = '0;
  logic in_range_reg = '0;

  (* RAM_STYLE="BLOCK" *) (* ram_decomp = "power" *) data_t mem[WORDS];

  logic [ADDR_WIDTH-1:0] adr_i_valid = '0;

  localparam [31:0] START_WORD = START_ADDRESS >> $clog2(BYTES_PER_WORD);
  logic [31:0] word_addr;
  assign word_addr = wb_cpu.addr >> $clog2(BYTES_PER_WORD);

  logic in_range_w;
  assign in_range_w = (word_addr >= START_WORD) && (word_addr < START_WORD + WORDS);

  logic [ADDR_WIDTH-1:0] mem_addr;
  assign mem_addr = word_addr - START_WORD;

  assign wb_cpu.data_rd = dat_o_reg;
  assign wb_cpu.ack     = ack_o_reg;
  assign wb_cpu.stall   = 1'b0;  // no actual stall required
  assign wb_cpu.err     = cyc_i_reg && stb_i_reg && !in_range_reg;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    else begin
      for (int i = 0; i < WORDS; i++) begin
        mem[i] = '0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ack_o_reg    <= '0;
      adr_i_valid  <= '0;
      cyc_i_reg    <= '0;
      stb_i_reg    <= '0;
      we_i_reg     <= '0;
      sel_i_reg    <= '0;
      dat_i_reg    <= '0;
      dat_o_reg    <= '0;
      in_range_reg <= '0;
    end else begin
      // Pipeline both inputs and outputs for better BRAM timing
      // Acknowledge when we register a stb in range
      ack_o_reg    <= cyc_i_reg & stb_i_reg & in_range_reg;
      adr_i_valid  <= mem_addr;
      in_range_reg <= in_range_w;
      cyc_i_reg    <= wb_cpu.cyc;
      stb_i_reg    <= wb_cpu.stb;
      we_i_reg     <= wb_cpu.we;
      sel_i_reg    <= wb_cpu.sel;
      dat_i_reg    <= wb_cpu.data_wr;
      if (cyc_i_reg & stb_i_reg && in_range_reg) begin
        for (int i = 0; i < BYTES_PER_WORD; i++) begin
          if (we_i_reg & sel_i_reg[i]) begin
            mem[adr_i_valid][BITS_PER_BYTE*i +: BITS_PER_BYTE] <= dat_i_reg[BITS_PER_BYTE*i +: BITS_PER_BYTE];
          end
        end
        dat_o_reg <= mem[adr_i_valid];
      end
    end
  end

endmodule

// Synchronous 1-cycle BRAM with Wishbone interface.
module wb_bram_sync #(
    parameter string INIT_FILE = "",
    parameter int START_ADDRESS = 32'h0,
    parameter int SIZE = 4096
) (
    input logic clk,
    (*direct_reset="true"*) input logic rst,
    wishboneIf.Slave wb_cpu
);

  localparam type data_t        = logic [wb_cpu.DATA_WIDTH-1:0];
  localparam int BYTES_PER_WORD = wb_cpu.SELECT_WIDTH;
  localparam int BITS_PER_BYTE  = wb_cpu.DATA_WIDTH / BYTES_PER_WORD;
  localparam int WORDS          = SIZE / BYTES_PER_WORD;
  localparam int ADDR_WIDTH     = $clog2(WORDS);

  data_t dat_o_reg = '0;
  logic  ack_o_reg = '0;
  logic  err_o_reg = '0;

  (* RAM_STYLE="BLOCK" *) (* ram_decomp = "power" *) data_t mem[WORDS];

  localparam [31:0] START_WORD = START_ADDRESS >> $clog2(BYTES_PER_WORD);
  logic [31:0] word_addr;
  assign word_addr = wb_cpu.addr >> $clog2(BYTES_PER_WORD);

  logic in_range_w;
  assign in_range_w = (word_addr >= START_WORD) && (word_addr < START_WORD + WORDS);

  logic [ADDR_WIDTH-1:0] mem_addr;
  assign mem_addr = word_addr - START_WORD;

  logic req_w;
  assign req_w = wb_cpu.cyc & wb_cpu.stb;

  assign wb_cpu.data_rd = dat_o_reg;
  assign wb_cpu.ack     = ack_o_reg;
  assign wb_cpu.stall   = 1'b0;
  assign wb_cpu.err     = err_o_reg;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    else begin
      for (int i = 0; i < WORDS; i++) begin
        mem[i] = '0;
      end
    end
  end

  // Single-process read and write per Xilinx UG901 Block RAM template
  always_ff @(posedge clk) begin
    if (rst) begin
      ack_o_reg <= 1'b0;
      err_o_reg <= 1'b0;
      dat_o_reg <= '0;
    end else begin
      ack_o_reg <= req_w & in_range_w;
      err_o_reg <= req_w & !in_range_w;
      if (req_w && in_range_w) begin
        if (wb_cpu.we) begin
          for (int i = 0; i < BYTES_PER_WORD; i++) begin
            if (wb_cpu.sel[i]) begin
              mem[mem_addr][BITS_PER_BYTE*i +: BITS_PER_BYTE] <= wb_cpu.data_wr[BITS_PER_BYTE*i +: BITS_PER_BYTE];
            end
          end
        end
        dat_o_reg <= mem[mem_addr];
      end
    end
  end

endmodule
