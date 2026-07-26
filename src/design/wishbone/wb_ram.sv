`ifdef verilatorsim
`include "interfaces.svh"
`else
`include "../includes/interfaces.svh"
`endif

/*
 * pipelined BRAM implementation with Wishbone interface
 * no real stall will take place, so requests can be sent back-to-back
 * single read/write port, meaning it should be used either as an IMEM or DMEM, but not both
 */
module wb_bram #(
    parameter string INIT_FILE = "",
    parameter int START_ADDRESS = 32'h0,
    parameter int SIZE = 4096
) (
    input wire clk,
    (*direct_reset="true"*) input wire rst,
    wishboneIf.Slave wb_cpu
);

  localparam type data_t = bit [wb_cpu.DATA_WIDTH-1:0];
  // for interfaces that are more than one word wide, disable address lines
  localparam VALID_ADDR_WIDTH = wb_cpu.ADDR_WIDTH - $clog2(wb_cpu.SELECT_WIDTH);
  // width of data port in words (1, 2, 4, or 8)
  localparam WORD_WIDTH = wb_cpu.SELECT_WIDTH;
  // size of words (8, 16, 32, or 64 bits)
  localparam WORD_SIZE = wb_cpu.DATA_WIDTH / WORD_WIDTH;

  data_t dat_o_reg = '0;
  data_t dat_i_reg = '0;
  logic ack_o_reg = '0;
  logic cyc_i_reg = '0;
  logic stb_i_reg = '0;
  logic we_i_reg = '0;
  logic [wb_cpu.SELECT_WIDTH-1:0] sel_i_reg = '0;

  (* RAM_STYLE="BLOCK" *) (* ram_decomp = "power" *) data_t mem[2**VALID_ADDR_WIDTH];

  logic [VALID_ADDR_WIDTH-1:0] adr_i_valid = '0;

  assign wb_cpu.data_rd = dat_o_reg;
  assign wb_cpu.ack = ack_o_reg;
  assign wb_cpu.stall = 1'b0;  //no actual stall required
  assign wb_cpu.err = cyc_i_reg && stb_i_reg && ((adr_i_valid < START_ADDRESS) || (adr_i_valid >= START_ADDRESS + SIZE));

  integer i, j;

  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    else
      for (i = 0; i < 2 ** VALID_ADDR_WIDTH; i = i + 2 ** (VALID_ADDR_WIDTH / 2)) begin
        for (j = i; j < i + 2 ** (VALID_ADDR_WIDTH / 2); j = j + 1) begin
          mem[j] = 0;
        end
      end
  end

  always @(posedge clk) begin
    if (rst) begin
      ack_o_reg <= '0;
      adr_i_valid <= '0;
      cyc_i_reg <= '0;
      stb_i_reg <= '0;
      we_i_reg <= '0;
      sel_i_reg <= '0;
      dat_i_reg <= '0;
      dat_o_reg <= '0;
    end else begin
      //pipeline both inputs and outputs for better BRAM timing
      ack_o_reg <= cyc_i_reg & stb_i_reg & (adr_i_valid >= START_ADDRESS) & (adr_i_valid < START_ADDRESS + SIZE); //acknowledge when we register a stb
      adr_i_valid <= wb_cpu.addr >> (wb_cpu.ADDR_WIDTH - VALID_ADDR_WIDTH);
      cyc_i_reg <= wb_cpu.cyc;
      stb_i_reg <= wb_cpu.stb;
      we_i_reg <= wb_cpu.we;
      sel_i_reg <= wb_cpu.sel;
      dat_i_reg <= wb_cpu.data_wr;
      if (cyc_i_reg & stb_i_reg) begin
        for (i = 0; i < WORD_WIDTH; i = i + 1) begin
          if (we_i_reg & sel_i_reg[i]) begin
            mem[adr_i_valid][WORD_SIZE*i+:WORD_SIZE] <= dat_i_reg[WORD_SIZE*i+:WORD_SIZE];
          end
        end
        dat_o_reg <= mem[adr_i_valid];
      end
    end
  end

endmodule
