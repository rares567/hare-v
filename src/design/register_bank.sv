// Dual-Port RAM with Asynchronous Read (Distributed RAM)
// File: rams_dist.v
module rams_dist#(
        parameter type DATA_T= bit [31:0],
        parameter int NUM_REGS = 32
    )(
        input  logic                        clk,
    (*direct_reset="true"*)  input logic    rst,
    (*direct_enable="true"*) input logic    ce,
        input  logic                        i_we,
        input  logic [$clog2(NUM_REGS)-1:0] i_a, //write+read address
        input  logic [$clog2(NUM_REGS)-1:0] i_dpra, //read-only address
        input  DATA_T                       i_di,
        output DATA_T                       o_spo,
        output DATA_T                       o_dpo
    );

    (*ram_style = "distributed"*) DATA_T ram [NUM_REGS];

    always_ff@(posedge clk) begin
        if (rst) begin
            o_spo <= '0;
            o_dpo <= i_di;
            for (int i=0; i<NUM_REGS; i++)
                ram[i] <= '0;
        end
        else if(ce) begin
            if (i_we) begin //write_first behaviour
                ram[i_a] <= i_di;
                o_spo <= i_di;
            end
            else
                o_spo <= ram[i_a];
            o_dpo <= ram[i_dpra];
        end
    end


endmodule

module register_bank_2r1w#(
        parameter type DATA_T= bit [31:0],
        parameter int NUM_REGS=32,
        localparam int ROBTAG_WIDTH = $clog2(ROB_DEPTH),
        localparam DATA_T REG_ZERO = '0
    )(
        input  logic                        clk,
    (*direct_reset="true"*)  input logic    rst,
        //use it for stalling when a structural hazard is detected
    (*direct_enable="true"*) input logic    ce,
        //Data comming from the WB stage, Reorder buffer, Scoreboard, etc.
        input  logic                        i_commit_en,
        input  logic [$clog2(NUM_REGS)-1:0] i_commit_addr,
        input  DATA_T                       i_commit_data,
        input  logic [ROBTAG_WIDTH-1:0]     i_commit_tag,
        //data comming from instruction decode and issue
        input  logic [$clog2(NUM_REGS)-1:0] i_rs1_addr,
        input  logic [$clog2(NUM_REGS)-1:0] i_rs2_addr,
        input  logic [$clog2(NUM_REGS)-1:0] i_rd_addr,
        input  logic [ROBTAG_WIDTH-1:0]     i_rd_tag,
        input  logic                        i_rd_we,
        //data going for instruction dispatch
        output DATA_T                       o_rs1_data,
        output DATA_T                       o_rs2_data,
        output logic                        o_rs1_busy,
        output logic                        o_rs2_busy,
        output logic [ROBTAG_WIDTH-1:0]     o_rs1_tag,
        output logic [ROBTAG_WIDTH-1:0]     o_rs2_tag
    );

    DATA_T r_spo, r_dpo;
    DATA_T r_commit_data;
    //use two parallel banks in order to have two parallel read ports with 1 common write port
    //this should suse only SLICEMs blocks which are efficient
    rams_dist#(.DATA_T(DATA_T), .NUM_REGS(NUM_REGS)) bank1_inst(
        .clk(clk),
        .rst(rst),
        .ce(ce),
        .i_we(i_commit_en),
        .i_a(i_commit_addr),
        .i_dpra(i_rs1_addr),
        .i_di(i_commit_data),
        .o_spo(r_commit_data),
        .o_dpo(r_spo)
    );

    rams_dist#(.DATA_T(DATA_T), .NUM_REGS(NUM_REGS)) bank2_inst(
        .clk(clk),
        .rst(rst),
        .ce(ce),
        .i_we(i_commit_en),
        .i_a(i_commit_addr),
        .i_dpra(i_rs2_addr),
        .i_di(i_commit_data),
        .o_spo(/*open*/),
        .o_dpo(r_dpo)
    );

    bit [NUM_REGS-1:0] busy_list = '0;
    bit [ROBTAG_WIDTH-1:0] renamed_regs [NUM_REGS];

    //register the inputs as well for further bypass
    logic r_bypass1, r_bypass2, r_zero1, r_zero2;
    logic w_rs1_eq_commit, w_rs2_eq_commit;

    //a register can have several producers in flight and only the newest one's commit
    //makes it ready, so the bypass has to check the tag exactly like the release logic
    //below does. Forwarding a superseded commit would hand out a value that is already
    //stale and, because r_bypass also forces busy low at the output, would advertise the
    //register as ready while it is still waiting on its real producer
    assign w_rs1_eq_commit = (i_commit_addr == i_rs1_addr) & i_commit_en
                             & (renamed_regs[i_rs1_addr] == i_commit_tag);
    assign w_rs2_eq_commit = (i_commit_addr == i_rs2_addr) & i_commit_en
                             & (renamed_regs[i_rs2_addr] == i_commit_tag);

    always_ff@(posedge clk) begin
        if (rst) begin
            r_zero1 <= '0;
            r_zero2 <= '0;
            r_bypass1 <= '0;
            r_bypass2 <= '0;
        end
        else if(ce)begin
            r_zero1 <= i_rs1_addr == REG_ZERO;
            r_zero2 <= i_rs2_addr == REG_ZERO;
            r_bypass1 <= w_rs1_eq_commit;
            r_bypass2 <= w_rs2_eq_commit;
        end
    end

    //handle busy_list and register_renaming
    logic r_rs1_busy, r_rs2_busy;
    logic [ROBTAG_WIDTH-1:0] r_rs1_rename, r_rs2_rename;
    always_ff@(posedge clk) begin
        if(rst) begin
            busy_list <= '0;
            r_rs1_busy <= '0;
            r_rs2_busy <= '0;
            r_rs1_rename <= '0;
            r_rs2_rename <= '0;
            for (int i=0;i<NUM_REGS;i++)
                renamed_regs[i] <= '0;
        end
        else if(ce) begin
            //just read status for rs1 and rs2, we bypass them at output if needed
            r_rs1_busy <= busy_list[i_rs1_addr];
            r_rs2_busy <= busy_list[i_rs2_addr];
            r_rs1_rename <= renamed_regs[i_rs1_addr];
            r_rs2_rename <= renamed_regs[i_rs2_addr];
            // if we commit at the same address of the current instruction rd, then thst rd should be still busy for any upcoming instruction
            if(i_commit_en && i_rd_we && i_commit_addr == i_rd_addr) begin 
                busy_list[i_rd_addr] <= 1'b1;
            end
            else begin
                if(i_commit_en && renamed_regs[i_commit_addr] == i_commit_tag) //make sure we release reg if we get a commit on its latest tag
                    busy_list[i_commit_addr] <= 1'b0;
                //busy_list is indexed by architectural register, not by ROB tag - both
                //happen to be 5 bits wide here, so confusing them compiles silently and
                //marks some unrelated register busy while rd stays free
                if(i_rd_we)
                    busy_list[i_rd_addr] <= 1'b1;
            end
            //also update the rename tag for the current instruction
            if(i_rd_we) begin
                renamed_regs[i_rd_addr] <= i_rd_tag;
            end
        end
    end

    //add bypass and zero-out logic at the final output
    assign o_rs1_data = r_zero1 ? '0 : (r_bypass1 ? r_commit_data : r_spo);
    assign o_rs2_data = r_zero2 ? '0 : (r_bypass2 ? r_commit_data : r_dpo);
    assign o_rs1_busy = r_zero1 ? '0 : (r_bypass1 ? '0 : r_rs1_busy);
    assign o_rs2_busy = r_zero2 ? '0 : (r_bypass2 ? '0 : r_rs2_busy);
    //no need to bypass these as we wil check the busy flags when we need them
    assign o_rs1_tag = r_rs1_rename;
    assign o_rs2_tag = r_rs2_rename;

endmodule
