`include "decode.svh"
import decode_package::*;

module reorder_buffer#(
    //data type and width of value fields
    parameter type DATA_T = bit[31:0],
    //read and write ports supporting all functional units that are outputing results to the ROB
    parameter int NUM_WPORTS = 4,
    parameter int NUM_RPORTS = 8,
    parameter int DEBUG = 1,
    //depth of ROB, defined in the decode package
    //local to the module, can be modified only through the decode package
    localparam int DEPTH = ROB_DEPTH,
    localparam int TAG_WIDTH = $clog2(ROB_DEPTH)
)(
    input logic                 clk,
    input logic                 rst,

    //input in-order instruction comming from issue (ROB tail)
    input DATA_T                i_issue_pc,
    input logic [4:0]           i_issue_rd,
    input logic                 i_issue_regwrite,
    input logic                 i_issue_store,
    //instruction that already traps at decode (ECALL/EBREAK/illegal opcode)
    //it never reaches a functional unit, so the ROB completes it at issue
    input logic                 i_issue_exception,
    input exception_cause_t     i_issue_exc_cause,
    input logic                 i_issue_valid,
    //tag that the next accepted issue will be allocated. Dispatch needs it to tell the
    //functional unit where to write its result back, and to tag the destination register.
    //Exposing it keeps that knowledge in one place: mirroring wptr outside the ROB means
    //replaying every rewind it does internally, and silently corrupting tags on a miss
    output logic [TAG_WIDTH-1:0] o_issue_robtag,

    //input results comming from functional units
    input logic                 i_fu_res_valid  [NUM_WPORTS],
    input logic [TAG_WIDTH-1:0] i_fu_res_robtag [NUM_WPORTS], //address inside rob to store result
    input DATA_T                i_fu_res_data [NUM_WPORTS],
    //faults only discovered while executing (misaligned address, access fault)
    //i_fu_res_data carries the faulting address in that case so that it lands in
    //the result memory and can be read out as mtval when the entry commits
    input logic                 i_fu_res_exception [NUM_WPORTS],
    input exception_cause_t     i_fu_res_cause [NUM_WPORTS],

    //input operands addresses that each FU is waiting to be computed
    //usually all type of functional units are expecting two operands comming from registers
    input logic [TAG_WIDTH-1:0] i_fu_op_robtag [NUM_RPORTS],
    //output values for the requested operands
    output DATA_T               o_fu_op_value [NUM_RPORTS],
    output logic                o_fu_op_valid [NUM_RPORTS],

    //output commit values for the register file (ROB head)
    output logic [4:0]          o_commit_rd,
    output DATA_T               o_commit_value,
    output logic                o_commit_valid,

    //output commit values for the store queue
    output logic[TAG_WIDTH-1:0] o_store_robtag,
    output logic                o_store_valid,
    output logic                o_store_flush,

    //trap request, raised once the head entry is complete and faulted
    //everything older has committed by then and everything younger must be squashed,
    //which is what makes the trap precise. o_commit_value doubles as mtval: for a
    //load/store fault it is the faulting address the FU wrote as its result
    output logic                o_exception_valid,
    output exception_cause_t    o_exception_cause,
    output DATA_T               o_exception_pc, //mepc

    //branch/jump misprediction identified by the ROB position
    input logic [TAG_WIDTH-1:0] i_jump_robtag,
    input logic                 i_jump_valid,
    input logic                 i_jump_mispredicted,

    //status signals
    //used to flag that ROB is not full and ready to accept new instructions
    output logic                o_ready,
    //ROB has drained. Dispatch needs this to release a serializing instruction -
    //a FENCE, and later CSR writes / MRET - which must not overlap older work.
    //Note this only means stores were handed to the store queue, not that they
    //reached the bus, so a full FENCE also has to wait on the store queue draining
    output logic                o_empty
);

    localparam int FIFO_DWIDTH = $bits(i_issue_pc) + $bits(i_issue_rd) + 2;

    ////////////////////////////////ROB PORTS <=> FIFO PORTS MAPPING////////////////////////////////

    logic [$clog2(DEPTH)-1:0] wptr;
    logic [$clog2(DEPTH)-1:0] rptr;

    logic w_almost_full, w_almost_empty;
    logic r_full, r_empty;

    (*ram_style="block"*) logic [FIFO_DWIDTH-1:0] fifo [DEPTH];

    logic [FIFO_DWIDTH-1:0] tail_data, head_data;
    assign tail_data = {i_issue_pc, i_issue_store, i_issue_regwrite, i_issue_rd};
    logic fifo_read, fifo_write;
    assign fifo_write = i_issue_valid;

    /////////////////////////////////ROB STATUS FOR EACH ENTRY/////////////////////////////////

    //per-entry completion status. This lives in flops rather than in the fifo BRAM
    //above because functional units complete out of order and write it at an
    //arbitrary robtag, while the fifo has a single write port tied to wptr
    typedef struct packed {
        logic             ready;
        logic             exception;
        exception_cause_t cause; //only meaningful while exception is set
    } rob_status_t;

    rob_status_t rob_status [DEPTH];

    //pop condition, combinational on the entry rptr currently points at
    assign fifo_read = rob_status[rptr].ready;

    //The head is a two stage pipeline so that it lands in phase with o_commit_value.
    //The result memory is read off rptr as well and takes two cycles (ram_sdp_wf
    //registers the address for timing, then the output), so an entry selected by rptr on
    //cycle T is presented here on T+2 exactly as its result appears on o_commit_value.
    //Data, status and tag move together, so the presented head always describes one
    //single entry - reading rob_status[rptr] directly would pair this instruction's pc
    //with a later instruction's status.
    logic [FIFO_DWIDTH-1:0]   s1_data;   //T+1: fifo/status read result
    rob_status_t              s1_status;
    logic [$clog2(DEPTH)-1:0] s1_robtag;
    rob_status_t              r_head_status; //T+2: presented head, alongside head_data
    logic [$clog2(DEPTH)-1:0] r_head_robtag;

    ////////////////////////////////////COMMIT / TRAP OUTPUTS//////////////////////////////////////

    assign o_ready = ~r_full;
    //r_empty only means the fifo drained; the head pipeline can still hold two entries
    //that have not committed yet, and a FENCE must wait for those to retire as well
    assign o_empty = r_empty & ~s1_status.ready & ~r_head_status.ready;

    //the entry i_issue_valid would allocate this cycle, tracking every rewind for free
    assign o_issue_robtag = wptr;

    //a faulted entry must not be allowed to change architectural state: a faulting
    //load still carries RegWrite=1 and would clobber rd, and a faulting store still
    //carries Store=1 and would make the trap visible in memory
    assign o_commit_valid = r_head_status.ready & head_data[5] & ~r_head_status.exception;
    assign o_commit_rd = head_data[4:0];

    assign o_store_valid = r_head_status.ready & head_data[6] & ~r_head_status.exception;
    assign o_store_robtag = r_head_robtag;

    //the trap fires only once the faulted entry is the one being presented: keying off
    //rob_status[rptr] instead would trap out of order and latch a younger pc as mepc
    assign o_exception_valid = r_head_status.ready & r_head_status.exception;
    assign o_exception_cause = r_head_status.cause;
    assign o_exception_pc = DATA_T'(head_data[FIFO_DWIDTH-1:7]);

    //a trap at the head squashes the trapping entry and everything younger
    logic w_trap_flush;
    assign w_trap_flush = o_exception_valid;

    //////////////////////////////////////LOGIC FOR FIFO - START/////////////////////////////////////

    always_ff@(posedge clk) begin
        if(rst) begin
            //cause resets to ILLEGAL_INSTR to match the decoder: it is a don't-care
            //while exception is clear, and the fail-safe if one is ever set without one
            for (int i=0;i<DEPTH;i++)
                rob_status[i] <= '{ready: 1'b0, exception: 1'b0, cause: ILLEGAL_INSTR};
        end
        //everything younger than the trap is squashed, so drop any writeback or
        //allocation landing this cycle: it belongs to an instruction that no longer
        //exists. Writebacks arriving *later* are the functional units' problem - they
        //must be flushed alongside the ROB or a stale result would mark a reallocated
        //entry ready before its own result exists
        else if (w_trap_flush) begin
            for (int i=0;i<DEPTH;i++)
                rob_status[i] <= '{ready: 1'b0, exception: 1'b0, cause: ILLEGAL_INSTR};
        end
        else begin
            //resolving a jump completes its entry whether or not it predicted correctly:
            //a mispredict squashes everything *younger*, but the jump itself is a valid
            //instruction that still has to retire and write its return address for
            //JAL/JALR. It cannot fault here either - a misaligned target is reported by
            //the branch unit as a normal fu result
            if(i_jump_valid)
                rob_status[i_jump_robtag].ready <= 1'b1;

            //i indexes the write port, so the entry being completed is the one the
            //port is carrying a tag for - not entry i, which would only ever mark
            //the first NUM_WPORTS entries ready
            for (int i=0;i<NUM_WPORTS;i++) begin
                if (i_fu_res_valid[i] == 1'b1) begin
                    rob_status[i_fu_res_robtag[i]].ready     <= 1'b1;
                    rob_status[i_fu_res_robtag[i]].exception <= i_fu_res_exception[i];
                    rob_status[i_fu_res_robtag[i]].cause     <= i_fu_res_cause[i];
                end
            end

            //allocation comes last so a freshly issued entry always wins over a
            //writeback: an instruction that traps at decode never reaches a functional
            //unit, so it is allocated already complete - otherwise the head would wait
            //forever on a result that is never coming and wedge the ROB
            if (fifo_write) begin
                rob_status[wptr].ready     <= i_issue_exception;
                rob_status[wptr].exception <= i_issue_exception;
                rob_status[wptr].cause     <= i_issue_exc_cause;
            end
        end
    end

    //an operand is forwardable as soon as its producer is complete; a producer that
    //faulted is squashed rather than committed, so its consumers never retire either
    always_comb begin
        for (int i=0;i<NUM_RPORTS;i++)
           o_fu_op_valid[i] = rob_status[i_fu_op_robtag[i]].ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wptr <= 0;
            r_full <= '0;
            o_store_flush <= '0;
        end
        else begin
            o_store_flush <= '0;
            //the trapping entry has just been popped, so pulling wptr back to rptr
            //discards everything younger and leaves the ROB empty. This takes priority
            //over a mispredict - the trap is at the head, so it is the oldest thing in
            //the machine and any jump still in flight is younger - and over an issue in
            //the same cycle, which belongs to an instruction that no longer exists
            if (w_trap_flush) begin
                wptr <= rptr;
                r_full <= '0;
                o_store_flush <= '1;
            end
            //rewind to the slot *after* the jump: only younger instructions are on the
            //wrong path, the jump itself still has to retire
            else if (i_jump_valid && i_jump_mispredicted) begin
                wptr <= i_jump_robtag + 1'b1;
                //rewinding normally frees slots, but if the jump was already the
                //youngest entry then nothing is squashed and wptr does not move - a full
                //ROB has to stay full, or the next issue would overwrite the head
                if ((i_jump_robtag + 1'b1) != wptr)
                    r_full <= '0;
                o_store_flush <= '1;
            end
            else if (fifo_write & !r_full) begin
                fifo[wptr] <= tail_data;
                wptr <= wptr + 1'b1;
                if(w_almost_full)
                    r_full <= '1;
            end
            else if(r_full && fifo_read)
                r_full <= '0;
        end
    end

    initial begin
        if (DEBUG)
            $monitor("[%0t] [ROB] rob_issue=%0b rob_input=0x%0h rob_commit=%0b rob_head=0x%0h empty=%0b full=%0b", $time, fifo_write, tail_data, fifo_read, head_data, r_empty, r_full);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rptr <= 0;
            s1_data <= '0;
            s1_status <= '{ready: 1'b0, exception: 1'b0, cause: ILLEGAL_INSTR};
            s1_robtag <= '0;
            head_data <= '0;
            r_head_status <= '{ready: 1'b0, exception: 1'b0, cause: ILLEGAL_INSTR};
            r_head_robtag <= '0;
            r_empty <= '1;
        end
        //rptr has already moved past both stages, so everything still in the head
        //pipeline is the trapping entry or younger and has to be dropped. Clearing the
        //presented head also stops the trap from re-firing on the next cycle
        else if (w_trap_flush) begin
            s1_status.ready <= 1'b0;
            r_head_status.ready <= 1'b0;
            r_empty <= '1;
        end
        else begin
            //stage 1 captures whatever rptr selects this cycle; ready doubles as "this
            //stage carries a real entry", which is exactly the pop condition
            s1_data             <= fifo[rptr];
            s1_robtag           <= rptr;
            s1_status.exception <= rob_status[rptr].exception;
            s1_status.cause     <= rob_status[rptr].cause;
            s1_status.ready     <= fifo_read & ~r_empty;

            //stage 2 advances every cycle to stay lock-step with the result memory
            head_data     <= s1_data;
            r_head_status <= s1_status;
            r_head_robtag <= s1_robtag;

            if (fifo_read & !r_empty) begin
                rptr <= rptr + 1'b1;
                if(w_almost_empty)
                    r_empty <= '1;
            end
            else if(r_empty && fifo_write)
                r_empty <= '0;
        end
    end

    assign w_almost_full = wptr + 1'b1 == rptr;
    assign w_almost_empty = rptr + 1'b1 == wptr;

    //////////////////////////////////////LOGIC FOR FIFO - END/////////////////////////////////////

    /////////////////////////////////MULTI-PORT MEM HOLDING RESUTS/////////////////////////////////

    mwnr_multiport_mem#(
        .NUM_WRITE(NUM_WPORTS),
        .NUM_READ(NUM_RPORTS + 1),
        .DATA_T(DATA_T),
        .ADDR_WIDTH(TAG_WIDTH),
        .RAMSTYLE("block")
    ) multiport_mem_inst(
        .clk(clk),
        .rst(rst),
        .ce(1'b1),
        .i_we(i_fu_res_valid),
        .i_waddr(i_fu_res_robtag),
        .i_raddr({i_fu_op_robtag, rptr}),
        .i_wdata(i_fu_res_data),
        .o_rdata({o_fu_op_value, o_commit_value})
    );

endmodule