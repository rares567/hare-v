`include "decode.svh"
`ifdef verilatorsim
`include "verilog_xilinx.svh";
`endif
import decode_package::*;

//main ALU unit for Arithmetic/Logic operations like ADD, SUB, XOR, AND and OR based in Xilinx FPGA primitives
//can be extended tu support some other operations from the B-extension like ORN, ANDN, XNOR
//branch/jump and load/store addresses computation are handled through individual add/sub units
//as shift operations are not supported in DSPs they are also excluded from this `alu_unit` as well
module xilinx_alu_unit#(
        //data width of the operands and result
        parameter int DATA_WIDTH=32,

        //implement the operations wither with DSPs or classic LUTs, CARRYs and FFs
        parameter string IMPL = "FABRIC", //DSP/FABRIC

        //ULTRASCALE and ARTIX7 have different kind of DSPs and CARRYs
        parameter string FPGA_FAMILY = "ARTIX7", //ULTRSCALE/ARTIX7

        //it will add one extra pipeline stage, only for IMPL=FABRIC
        //splitting the DATA_WIDTH-bit operations in two DATA_WIDTH/2-bit operations to improve timing
        parameter string EXTRA_PIPE = "FALSE" //TRUE/FALSE
    )(
        input  logic                  clk,
    (*direct_reset="true"*) input logic rst,
    (*direct_enable="true"*)input logic en,
        input  alu_op_t             i_alu_op,
        input  logic [DATA_WIDTH-1:0] i_rs1,
        input  logic [DATA_WIDTH-1:0] i_rs2,
        output logic [DATA_WIDTH-1:0] o_rd,
        output logic                  o_valid
    );


    if(IMPL == "DSP") begin
        //TODO: to be implemented
        xilinx_dsp_alu #(.DATA_WIDTH(DATA_WIDTH),.FPGA_FAMILY(FPGA_FAMILY)) alu_inst_high(
                .clk(clk),
                .rst(rst),
                .A(i_rs1),
                .B(i_rs2),
                .ALUMODE(i_alu_op),
                .P(o_rd),
                .CARRYOUT(/*open*/)
            );
    end

    else begin
        //register the inputs just like in the case of the DSP-based unit
        logic [DATA_WIDTH-1:0] r_rs1, r_rs2;
        alu_op_t r_alu_op;
        logic r_valid;

        always_ff@(posedge clk) begin
            if(rst) begin
                r_rs1 <= '0;
                r_rs2 <= '0;
                r_alu_op <= alu_op_t'(0);
                r_valid <= '0;
            end
            else if(en) begin
                r_rs1 <= i_rs1;
                r_rs2 <= i_rs2;
                r_alu_op <= i_alu_op;
                r_valid <= '1;
            end
            else
                r_valid <= '0;
        end

        if (EXTRA_PIPE == "TRUE") begin
            logic [DATA_WIDTH/2-1:0] r_rd;
            logic r_carry;
            xilinx_aluNb #(
                .DATA_WIDTH(DATA_WIDTH/2),
                .FPGA_FAMILY(FPGA_FAMILY),
                .REGISTER_OUTPUT("TRUE"),
                .FIRST_IN_CHAIN("TRUE")
            ) alu_inst_low(
                .clk(clk),
                .rst(rst),
                .CI(1'b0),
                .A(r_rs1[DATA_WIDTH/2-1:0]),
                .B(r_rs2[DATA_WIDTH/2-1:0]),
                .ALUMODE(r_alu_op),
                .P(r_rd),
                .CARRYOUT(r_carry)
            );

            logic [DATA_WIDTH/2-1:0] r2_rs1, r2_rs2;
            alu_op_t r2_alu_op;
            logic r2_valid;

            always_ff@(posedge clk) begin
                if(rst) begin
                    r2_rs1 <= '0;
                    r2_rs2 <= '0;
                    r2_alu_op <= alu_op_t'(0);
                    r2_valid <= '0;
                end
                else begin
                    r2_rs1 <= r_rs1[DATA_WIDTH-1:DATA_WIDTH/2];
                    r2_rs2 <= r_rs2[DATA_WIDTH-1:DATA_WIDTH/2];
                    r2_alu_op <= r_alu_op;
                    r2_valid <= r_valid;
                end
            end

            xilinx_aluNb #(
                .DATA_WIDTH(DATA_WIDTH/2),
                .FPGA_FAMILY(FPGA_FAMILY),
                .REGISTER_OUTPUT("TRUE"),
                .FIRST_IN_CHAIN("FALSE")
            )alu_inst_high(
                .clk(clk),
                .rst(rst),
                .A(r2_rs1),
                .B(r2_rs2),
                .CI(r_carry),
                .ALUMODE(r2_alu_op),
                .P(o_rd[DATA_WIDTH-1:DATA_WIDTH/2]),
                .CARRYOUT(/*open*/)
            );

            //register the remaining output signals
            always_ff@(posedge clk) begin
                if(rst) begin
                    o_valid <= '0;
                    o_rd[DATA_WIDTH/2-1:0] <= '0;
                end
                else begin
                    o_valid <= r2_valid;
                    o_rd[DATA_WIDTH/2-1:0] <= r_rd;
                end
            end

        end
        else begin
            xilinx_aluNb #(
                .DATA_WIDTH(DATA_WIDTH),
                .FPGA_FAMILY(FPGA_FAMILY),
                .REGISTER_OUTPUT("TRUE"),
                .FIRST_IN_CHAIN("TRUE")
            )alu_inst(
                .clk(clk),
                .rst(rst),
                .A(r_rs1),
                .B(r_rs2),
                .CI(1'b0),
                .ALUMODE(r_alu_op),
                .P(o_rd),
                .CARRYOUT(/*open*/)
            );

            //register the remaining output signals
            always_ff@(posedge clk) begin
                if(rst)
                    o_valid <= '0;
                else
                    o_valid <= r_valid;
            end
        end
    end


endmodule

//implementation of ALU using DSP(s)
//TODO
module xilinx_dsp_alu#(
        parameter int DATA_WIDTH=32,
        parameter string FPGA_FAMILY = "ULTRASCALE" //ULTRSCALE/ARTIX7
    )(
        input  logic                  clk,
    (*direct_reset="true"*)input logic rst,
        input  alu_op_t             ALUMODE,
        input  logic [DATA_WIDTH-1:0] A,
        input  logic [DATA_WIDTH-1:0] B,
        output logic [DATA_WIDTH-1:0] P,
        output logic                  CARRYOUT
    );



endmodule


//N-bit ALU made from a chain of 4-bit ALUs based on LUT and CARRY primitves (FABRIC)
//Capable of computing operations like A+B, A-B, A&B, A|B, A^B
module xilinx_aluNb#(
    parameter int DATA_WIDTH = 32,
    parameter string FPGA_FAMILY = "ULTRASCALE", //ULTRSCALE/ARTIX7
    parameter string REGISTER_OUTPUT = "TRUE",
    parameter string FIRST_IN_CHAIN = "TRUE", //the position of the alu in a larger chain
    localparam int N = FPGA_FAMILY == "ULTRASCALE" ? 8 : 4
)(
    input logic          clk,
(*direct_reset="true"*)input logic rst,
    input logic [DATA_WIDTH-1:0]  A,
    input logic [DATA_WIDTH-1:0]  B,
    input logic                   CI,
    input alu_op_t              ALUMODE,
    output logic [DATA_WIDTH-1:0] P,
    output logic                  CARRYOUT
);

generate

    genvar i;
    logic [DATA_WIDTH/N:0] CARRY;
    logic [DATA_WIDTH-1:0] P_w;

    assign CARRY[0] = CI;
    for (i=0;i<DATA_WIDTH/N;i++) begin
        xilinx_alu4b #(
            .FPGA_FAMILY(FPGA_FAMILY),
            .FIRST_IN_CHAIN(FIRST_IN_CHAIN == "TRUE" && i == 0 ? "TRUE" : "FALSE")
            ) alu4_inst(
            .clk(clk),
            .rst(rst),
            .A(A[i*N+N-1:i*N]),
            .B(B[i*N+N-1:i*N]),
            .ALUMODE(ALUMODE),
            .S(P_w[i*N+N-1:i*N]),
            .CI(CARRY[i]),
            .CO(CARRY[i+1])
        );
    end

    if (REGISTER_OUTPUT == "TRUE")
        always_ff@(posedge clk) begin
            if (rst) begin
                P <= '0;
                CARRYOUT <= '0;
            end
            else begin
                P <= P_w;
                CARRYOUT <= CARRY[DATA_WIDTH/N];
            end
        end
    else
        assign {CARRYOUT, P} = {CARRY[N/4], P_w};

endgenerate

endmodule


module xilinx_alu4b#(
        parameter string FPGA_FAMILY = "ULTRASCALE", //ULTRSCALE/ARTIX7
        parameter string FIRST_IN_CHAIN = "TRUE", //the position of the alu in a larger chain
        localparam int N = FPGA_FAMILY == "ULTRASCALE" ? 8 : 4
    )(
        input logic        clk,
        (*direct_reset="true"*)input logic rst,
        input  logic [N-1:0] A,
        input  logic [N-1:0] B,
        input  logic         CI,
        input  alu_op_t    ALUMODE,
        output logic [N-1:0] S,
        output logic         CO
    );
 
  logic [N-1:0] O6, O5;
  logic [N-1:0] CarryOuts;
 
  assign O5 = (~ALUMODE[2] & ~ALUMODE[1]) ? A & B :  //ADD
              (~ALUMODE[2] &  ALUMODE[1]) ? A & ~B : '0; //SUB or anything else
  assign O6 = ( ALUMODE[3] &  ALUMODE[2] &  ALUMODE[1]) ? A | B : ( //OR_OP
              ( ALUMODE[3] &  ALUMODE[2] & ~ALUMODE[1]) ? A & B : ( //AND_OP
              (~ALUMODE[3] & ~ALUMODE[2] &  ALUMODE[1]) ? A ^~B : A ^ B));  //SUB or ADD/XOR
  assign CO = CarryOuts[N-1];
 
  generate
    if (FPGA_FAMILY == "ARTIX7")
        CARRY4 CARRY4_inst (
            .CO(CarryOuts),         // 4-bit carry out
            .O(S),           // 4-bit carry chain XOR data out
            .CI(FIRST_IN_CHAIN == "TRUE" ? '0 : CI),         // 1-bit carry cascade input
            .CYINIT(FIRST_IN_CHAIN == "TRUE" ? ALUMODE[0] : '0),// ADD/SUB
            .DI(O5),         // 4-bit carry-MUX data in
            .S(O6)            // 4-bit carry-MUX select input
        );
    else
        CARRY8 CARRY8_inst (
            .CI(FIRST_IN_CHAIN == "TRUE" ? ALUMODE[0] : CI),
            .CI_TOP('0),
            .DI(O5),
            .S(O6),
            .CO(CarryOuts),
            .O(S)
        );

  endgenerate

endmodule

//adder used to compute LOAD/STORE and BRANCH/JUMP addresses
//subtractor used for condition checking and set less then instructions
//made from chain of 4-bit adders, based on LUT and CARRY primitives
module xilinx_addsub_unit#(
        parameter string FPGA_FAMILY = "ULTRASCALE", //ULTRSCALE/ARTIX7
        parameter int DATA_WIDTH = 32,
        parameter string MODE = "ADD",
        parameter string REGISTER_OUTPUT = "TRUE",
        localparam int N = FPGA_FAMILY == "ULTRASCALE" ? 8 : 4
        )(
            input  logic         clk,
        (*direct_reset="true"*)input logic rst,
            input  logic [DATA_WIDTH-1:0] A,B,
            output logic [DATA_WIDTH-1:0] S,
            output logic CARRYOUT
);

 initial assert (DATA_WIDTH % N == 0);

 logic [DATA_WIDTH/N:0] CarryOuts;
 assign CarryOuts[0] = FPGA_FAMILY == "ULTRASCALE" && MODE == "SUB" ? 1'b1 : 1'b0;
 logic [DATA_WIDTH-1:0] S_w;
 generate
    genvar i;
    for(i=0;i<DATA_WIDTH/N;i=i+1) begin
        localparam string FIRST_IN_CHAIN = i == 0 ? "TRUE" : "FALSE";
        fast_addsub #(
            .MODE(MODE),
            .FPGA_FAMILY(FPGA_FAMILY),
            .FIRST_IN_CHAIN(FIRST_IN_CHAIN))
            fa_inst(
            .A(A[i*N+N-1:i*N]),
            .B(B[i*N+N-1:i*N]),
            .CI(CarryOuts[i]),
            .S(S_w[i*N+N-1:i*N]),
            .CO(CarryOuts[i+1]));
    end

    if (REGISTER_OUTPUT == "TRUE") begin
        always_ff@(posedge clk)
            if(rst) begin
                S <= '0;
                CARRYOUT <= '0;
            end
            else begin
                S <= S_w;
                CARRYOUT <= CarryOuts[DATA_WIDTH/N];
            end

    end
    else
        assign S = S_w;
 endgenerate

endmodule

module fast_addsub#(
    parameter string FPGA_FAMILY = "ULTRASCALE", //ULTRSCALE/ARTIX7
    parameter string MODE = "ADD", //ADD/SUB
    parameter string FIRST_IN_CHAIN = "TRUE", //Not used for ULTRASCALE
    localparam int N = FPGA_FAMILY == "ULTRASCALE" ? 8 : 4
    )(
        input logic [N-1:0]  A, B,
        input logic          CI,
        output logic [N-1:0] S,
        output logic         CO
    );


    logic [N-1:0] P, G;
    logic [N-1:0] CarryOuts;
    assign CO = CarryOuts[N-1];

    if (MODE == "ADD") begin
        assign P = A ^ B;
        assign G = A & B;

        if (FPGA_FAMILY == "ARTIX7")
            CARRY4 CARRY4_inst (
                .CO(CarryOuts), // 4-bit carry out
                .O(S),          // 4-bit carry chain XOR data out
                .CI(CI),  // 1-bit carry cascade input
                .CYINIT(1'b0),     // 1-bit carry initialization
                .DI(G),         // 4-bit carry-MUX data in
                .S(P)           // 4-bit carry-MUX select input
            );
        else
            CARRY8 CARRY8_inst (
                .CI(CI),
                .CI_TOP('0),
                .DI(G),
                .S(P),
                .CO(CarryOuts),
                .O(S)
            );
    end
    else if(MODE == "SUB") begin
        assign P = A ^ ~B;
        assign G = A & ~B;
        if (FPGA_FAMILY == "ARTIX7")
            CARRY4 CARRY4_inst (
                .CO(CarryOuts), // 4-bit carry out
                .O(S),          // 4-bit carry chain XOR data out
                .CI(FIRST_IN_CHAIN == "TRUE" ? 1'b0 : CI),        // 1-bit carry cascade input
                .CYINIT(FIRST_IN_CHAIN == "TRUE" ? 1'b1 : 1'b0),  // 1-bit carry initialization
                .DI(G),         // 4-bit carry-MUX data in
                .S(P)           // 4-bit carry-MUX select input
            );
        else
            CARRY8 CARRY8_inst (
                .CI(CI),
                .CI_TOP('0),
                .DI(G),
                .S(P),
                .CO(CarryOuts),
                .O(S)
            );
    end

endmodule


//inspired from: https://community.element14.com/technologies/fpga-group/b/blog/posts/systemverilog-study-notes-barrel-shifter-rtl-combinational-circuit
module barrel_shifter_N #(
        parameter int DATA_WIDTH = 32,
        parameter string EXTRA_PIPE = "TRUE",
        localparam int N = $clog2(DATA_WIDTH)
    )(
        input logic                   clk,
        (*direct_reset="true"*) input logic  rst,
        (*direct_enable="true"*) input logic en,
        input logic [DATA_WIDTH-1:0]  i_data,
        input logic [N-1:0]           i_shamt,
        input shift_op_t          i_shconf,
        output logic [DATA_WIDTH-1:0] o_data,
        output logic                  o_valid
);

    // reverse input circuit if needed, or just pipeline it as it is
    logic [DATA_WIDTH-1:0] reversed_data;
    inverter_width #(.DATA_WIDTH(DATA_WIDTH)) input_inverter (
        .clk(clk),
        .rst(rst),
        .invert(i_shconf == SLL_OP || i_shconf == ROTL_OP),
        .data(i_data),
        .out(reversed_data));

    logic [N-1:0] r_shamt;
    shift_op_t r_shconf;
    logic r_valid;
    always_ff@(posedge clk) begin
        if(rst) begin
            r_shamt <= '0;
            r_shconf <= SRL_OP;
            r_valid <= '0;
        end
        else if(en) begin
            r_shamt <= i_shamt;
            r_shconf <= i_shconf;
            r_valid <= 1'b1;
        end
        else
            r_valid <= 1'b0;
    end

    logic [DATA_WIDTH-1:0] reversed_outr;
    logic w_valid;
    barrel_shifter_N_right #(.DATA_WIDTH(DATA_WIDTH),.EXTRA_PIPE(EXTRA_PIPE)) bsr (
        .clk(clk),
        .rst(rst),
        .i_valid(r_valid),
        .i_data(reversed_data),
        .i_shamt(r_shamt),
        .i_shconf(r_shconf),
        .o_data(reversed_outr),
        .o_valid(w_valid));

    shift_op_t w_shconf;
    if(EXTRA_PIPE == "TRUE")
        always_ff@(posedge clk)
            if(rst)
                w_shconf <= SRL_OP;
            else
                w_shconf <= r_shconf;
    else
        assign w_shconf = r_shconf;

    //  reverse output circuit if needed, or just pipeline it as it is
    inverter_width #(.DATA_WIDTH(DATA_WIDTH)) output_inverter(
        .clk(clk),
        .rst(rst),
        .invert(w_shconf == SLL_OP || w_shconf == ROTL_OP),
        .data(reversed_outr), 
        .out(o_data)
     );
     always_ff@(posedge clk) begin
        if(rst)
            o_valid <= '0;
        else
            o_valid <= w_valid;
    end

endmodule

// rotates amt bits of data to the right staged implementation
module barrel_shifter_N_right #(
        parameter int DATA_WIDTH = 32,
        parameter string EXTRA_PIPE = "TRUE",
        localparam int N = $clog2(DATA_WIDTH)
    )(
        input logic                   clk,
        (*direct_reset="true"*) input logic rst,
        input logic                   i_valid,
        input logic  [DATA_WIDTH-1:0] i_data,
        input logic  [N-1:0]          i_shamt,
        input shift_op_t          i_shconf,
        output logic [2**N-1:0]       o_data,
        output logic                  o_valid
    );

    logic  [N-1:0][DATA_WIDTH-1:0] stage_out;
    logic  initial_shvalue;
    assign initial_shvalue = (i_shconf == SLL_OP || i_shconf == SRL_OP) ? '0 : (i_shconf == ROTL_OP || i_shconf == ROTR_OP ? i_data[0] : i_data[DATA_WIDTH-1]);

    generate

        assign stage_out[0] = i_shamt[0] ? { initial_shvalue, i_data[DATA_WIDTH-1:1]} : i_data;

        if (EXTRA_PIPE == "TRUE") begin
            genvar stage1,stage2;
            for (stage1 = 1; stage1 < N/2 ; ++stage1) begin
                logic [stage1**2:0] temp_shvalue;
                assign temp_shvalue = (i_shconf == SLL_OP || i_shconf == SRL_OP) ? '0 : (i_shconf == ROTL_OP || i_shconf == ROTR_OP ? stage_out[stage1-1][stage1**2:0] : {(stage1**2+1){i_data[DATA_WIDTH-1]}});
                assign stage_out[stage1] = i_shamt[stage1] ? {temp_shvalue, stage_out[stage1-1][DATA_WIDTH-1:2**stage1]} : stage_out[stage1 -1];
            end

            logic [DATA_WIDTH-1:0] stage_pipe;
            logic [N-1:0] r_shamt;
            shift_op_t r_shconf;
            logic r_valid;
            logic r_data;
            always_ff@(posedge clk) begin
                if(rst) begin
                    stage_pipe <= '0;
                    r_shamt <= '0;
                    r_shconf <= SRL_OP;
                    r_valid <= '0;
                    r_data <= '0;
                end
                else begin
                    stage_pipe <= stage_out[N/2-1];
                    r_shamt <= i_shamt;
                    r_valid <= i_valid;
                    r_shconf <= i_shconf;
                    r_data <= i_data[DATA_WIDTH-1];
                end
            end

            logic [(N/2)**2:0] stage_shvalue;
            assign stage_shvalue = (r_shconf == SLL_OP || r_shconf == SRL_OP) ? '0 : (r_shconf == ROTL_OP || r_shconf == ROTR_OP ? stage_pipe[(N/2)**2:0] : {((N/2)**2+1){r_data}});
            assign stage_out[N/2] = r_shamt[N/2] ? {stage_shvalue, stage_pipe[DATA_WIDTH-1:2**(N/2)]} : stage_pipe;
            for (stage2 = N/2+1; stage2 < N ; ++stage2) begin
                logic [stage2**2:0] temp_shvalue;
                assign temp_shvalue = (r_shconf == SLL_OP || r_shconf == SRL_OP) ? '0 : (r_shconf == ROTL_OP || r_shconf == ROTR_OP ? stage_out[stage2-1][stage2**2:0] : {(stage2**2+1){r_data}});
                assign stage_out[stage2] = r_shamt[stage2] ? {temp_shvalue, stage_out[stage2-1][DATA_WIDTH-1:2**stage2]} : stage_out[stage2-1];
            end
            assign o_data = stage_out[N-1];
            assign o_valid = r_valid;
        end

        else begin
            genvar stage;
            for (stage = 1; stage < N ; ++stage) begin
                logic [stage**2:0] temp_shvalue;
                assign temp_shvalue = (i_shconf == SLL_OP || i_shconf == SRL_OP) ? '0 : (i_shconf == ROTL_OP || i_shconf == ROTR_OP ? stage_out[stage-1][stage**2:0] : {(stage**2+1){i_data[DATA_WIDTH-1]}});
                assign stage_out[stage] = i_shamt[stage] ? {temp_shvalue, stage_out[stage-1][DATA_WIDTH-1:2**stage]} : stage_out[stage-1];
            end
            assign o_data = stage_out[N-1];
            assign o_valid = i_valid;
        end
    endgenerate

endmodule


module inverter_width #(parameter DATA_WIDTH=32) (
    input  logic                  clk,
    (*direct_reset="true"*) input logic rst,
    input  logic                  invert,
    input  logic [DATA_WIDTH-1:0] data,
    output logic [DATA_WIDTH-1:0] out
);
    always_ff@(posedge clk) begin
        if (rst)
            out <= '0;
        else if(invert)
            out <= {<<{data}};
        else
            out <= data;
    end

endmodule

module xilinx_magnitude_comp#(
    parameter string FPGA_FAMILY = "ARTIX7", //ULTRSCALE/ARTIX7
    parameter int DATA_WIDTH = 32,
    localparam int N = FPGA_FAMILY == "ULTRASCALE" ? 8 : 4
   )(
        input  logic                  clk,
        (*direct_reset="true"*) input logic rst,
        (*direct_enable="true"*)input logic en,
        input  logic [DATA_WIDTH-1:0] i_rs1,
        input  logic [DATA_WIDTH-1:0] i_rs2,
        input  logic                  i_signed,
        output magnitude_comp_t       o_comp_result,
        output logic                  o_valid
   );
   
   logic [DATA_WIDTH-1+N:0] r_rs1;
   logic [DATA_WIDTH-1+N:0] r_rs2;
   logic r_valid;
   logic r_signed;
   always_ff@(posedge clk) begin
        if(rst) begin
            r_rs1 <= '0;
            r_rs2 <= '0;
            r_valid <= '0;
            r_signed <= '0;
        end
        else if(en) begin
            logic w_rs1_msb; //temp logic
            logic w_rs2_msb; //temp logic
            w_rs1_msb = i_signed ? i_rs1[DATA_WIDTH-1] : '0;
            w_rs2_msb = i_signed ? i_rs2[DATA_WIDTH-1] : '0;
            r_rs1 <= {{N-1{'0}}, w_rs1_msb, i_rs1};
            r_rs2 <= {{N-1{'0}}, w_rs2_msb, i_rs2};
            r_signed <= i_signed & (i_rs1[DATA_WIDTH-1] ^ i_rs2[DATA_WIDTH-1]);
            r_valid <= 1'b1;
        end
        else r_valid <= 1'b0;
        
   end
   
   logic [DATA_WIDTH-1+N:0] w_s;
   logic w_valid;
   logic w_signed;
   
   xilinx_addsub_unit#(
      .FPGA_FAMILY(FPGA_FAMILY),
      .DATA_WIDTH(DATA_WIDTH+N),
      .MODE("SUB"),
      .REGISTER_OUTPUT("TRUE")
   ) sub_unit_inst(
      .clk(clk),
      .rst(rst),
      .A(r_rs1),
      .B(r_rs2),
      .S(w_s),
      .CARRYOUT(/*open*/)   
   );
        
   always_ff@(posedge clk) begin
        if(rst) begin
            w_valid <= '0;
            w_signed <= r_signed;
        end
        else begin
            w_signed <= r_signed;
            w_valid <= r_valid;
        end
   end
   
   magnitude_comp_t w_comp_result;
   logic all_zero, carryout;
   always_comb begin
       all_zero = ~|w_s;
       carryout = w_s[DATA_WIDTH+1];
       unique case({w_signed, carryout, all_zero}) inside
            3'b??1 : w_comp_result = EQ;
            3'b000 : w_comp_result = GT; 
            3'b010 : w_comp_result = LT; 
            3'b100 : w_comp_result = LT;
            3'b110 : w_comp_result = GT;
            default: w_comp_result = NONE;
       endcase 
   end
   
   always_ff@(posedge clk) begin
        if(rst) begin
            o_valid <= '0;
            o_comp_result <= NONE;
        end
        else begin
            o_valid <= w_valid;
            o_comp_result <= w_comp_result;
        end
   end

endmodule
