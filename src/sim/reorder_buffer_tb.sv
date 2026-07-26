`ifdef verilatorsim
`include "decode.svh"
`else
`include "../design/includes/decode.svh"
`endif

`timescale 1ns / 1ps

// Testbench for the reorder_buffer.
//
// The ROB is driven as if it sat in a real machine: a stream of RISC-V
// instructions is decoded with rv32iDecoder, dispatched in order, and handed to
// one of four modelled functional units
//
//   FU0/FU1  ALU          1 cycle  (ideal)
//   FU2      LSU          3 cycles (cache-like)
//   FU3      Branch/Jump  2 cycles
//
// The point of the mixed latencies is that instructions *complete out of order* -
// an ALU op issued after a load finishes long before it - so the ROB has to put
// them back in program order. Every instruction is given a unique result value,
// so the checker can prove both the order and the payload: the value has to make
// the round trip through the result memory and come back out at o_commit_value in
// phase with o_commit_rd.
//
// Instruction encodings are real, produced by
//   riscv64-unknown-elf-as -march=rv32i -mabi=ilp32
// and the assembly each one came from is kept alongside it below.
//
// The TB also honours the flush contract the ROB relies on: whenever a trap or a
// mispredict squashes the ROB, the modelled FU pipelines are flushed too, since a
// writeback that arrives after its tag has been reallocated would silently mark a
// younger instruction complete.

module reorder_buffer_tb;
  import decode_package::*;

  localparam type DATA_T = bit [31:0];
  localparam int NUM_FU = 4;
  localparam int TAG_WIDTH = $clog2(decode_package::ROB_DEPTH);
  localparam int DEPTH = decode_package::ROB_DEPTH;
  localparam int CLK_PERIOD = 10;
  localparam int TIMEOUT = 2000;

  //functional unit map and latencies
  localparam int FU_ALU0 = 0;
  localparam int FU_ALU1 = 1;
  localparam int FU_LSU = 2;
  localparam int FU_BJU = 3;
  localparam int MAX_LAT = 3;
  localparam int FU_LATENCY[NUM_FU] = '{1, 1, 3, 2};

  localparam DATA_T BASE_PC = 32'h8000_0000;

  // -------------------------------------------------------------------------
  // DUT interface
  // -------------------------------------------------------------------------
  logic                             clk;
  logic                             rst = '1;

  DATA_T                            i_issue_pc;
  logic             [          4:0] i_issue_rd;
  logic                             i_issue_regwrite;
  logic                             i_issue_store;
  logic                             i_issue_exception;
  exception_cause_t                 i_issue_exc_cause;
  logic                             i_issue_valid;
  logic             [TAG_WIDTH-1:0] o_issue_robtag;

  logic                             i_fu_res_valid      [  NUM_FU];
  logic             [TAG_WIDTH-1:0] i_fu_res_robtag     [  NUM_FU];
  DATA_T                            i_fu_res_data       [  NUM_FU];
  logic                             i_fu_res_exception  [  NUM_FU];
  exception_cause_t                 i_fu_res_cause      [  NUM_FU];

  logic             [TAG_WIDTH-1:0] i_fu_op_robtag      [NUM_FU*2] = '{default: '0};
  DATA_T                            o_fu_op_value       [NUM_FU*2];
  logic                             o_fu_op_valid       [NUM_FU*2];

  logic             [          4:0] o_commit_rd;
  DATA_T                            o_commit_value;
  logic                             o_commit_valid;

  logic             [TAG_WIDTH-1:0] o_store_robtag;
  logic                             o_store_valid;
  logic                             o_store_flush;

  logic                             o_exception_valid;
  exception_cause_t                 o_exception_cause;
  DATA_T                            o_exception_pc;

  logic             [TAG_WIDTH-1:0] i_jump_robtag;
  logic                             i_jump_mispredicted;
  logic                             i_jump_valid;

  logic                             o_ready;
  logic                             o_empty;

  reorder_buffer #(
      .DATA_T(DATA_T),
      .NUM_WPORTS(NUM_FU),
      .NUM_RPORTS(2 * NUM_FU),
      .DEBUG(0)
  ) rob_inst (
      .*
  );

  initial begin
    clk = 0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // -------------------------------------------------------------------------
  // Pre-decoded program
  // -------------------------------------------------------------------------
  typedef struct {
    bit [31:0]        instr;
    DATA_T            pc;
    bit [4:0]         rd;
    bit               regwrite;
    bit               store;
    bit               exception;
    exception_cause_t cause;
    bit               fence;
    int               fu;         //target functional unit, -1 if it needs none
    DATA_T            value;      //unique result, so a commit can be traced back
    string            asm;
  } dec_t;

  dec_t        decoded [];
  rv32iDecoder decoder;

  //route a decoded instruction to one of the four units. The comparator and
  //shifter units fold into the ALUs here: they are all single cycle
  function automatic int fu_of(functional_unit_t t, int seq);
    case (t)
      LOAD_STORE_UNIT:  return FU_LSU;
      BRANCH_JUMP_UNIT: return FU_BJU;
      default:          return (seq % 2) ? FU_ALU1 : FU_ALU0;  //spread over both ALUs
    endcase
  endfunction

  function automatic void load_program(input bit [31:0] prog[], input string asms[]);
    instruction_t               instr;
    rv32i_decoded_instruction_t d;
    decoded = new[prog.size()];
    foreach (prog[k]) begin
      instr.raw = prog[k];
      d = decoder.decodeInstruction(instr, BASE_PC + 32'(4 * k));
      decoded[k].instr = prog[k];
      decoded[k].pc = BASE_PC + 32'(4 * k);
      decoded[k].rd = d.Rd;
      decoded[k].regwrite = d.ControlData.RegWrite;
      decoded[k].store = d.ControlData.Store;
      decoded[k].exception = d.ControlData.Exception;
      decoded[k].cause = d.ControlData.ExcCause;
      decoded[k].fence = d.ControlData.Fence;
      decoded[k].value = 32'hC0DE_0000 + 32'(k);
      decoded[k].asm = asms[k];
      //an instruction that traps at decode, or a FENCE, never reaches a unit
      decoded[k].fu = (d.ControlData.Exception || d.ControlData.Fence) ? -1 :
          fu_of(d.FunctionalUnitType, k);
    end
  endfunction

  // -------------------------------------------------------------------------
  // Expected observable events, in program order
  // -------------------------------------------------------------------------
  typedef enum {
    EV_COMMIT,
    EV_STORE,
    EV_TRAP
  } ev_kind_e;

  typedef struct {
    ev_kind_e           kind;
    bit [4:0]           rd;
    DATA_T              value;
    bit [TAG_WIDTH-1:0] tag;
    exception_cause_t   cause;
    DATA_T              pc;
    string              asm;
  } event_t;

  event_t exp_q        [$];
  int     pass_cnt = 0;
  int     fail_cnt = 0;

  // -------------------------------------------------------------------------
  // Dispatch
  // -------------------------------------------------------------------------
  typedef struct {
    bit                 valid;
    bit [TAG_WIDTH-1:0] robtag;
    DATA_T              data;
    bit                 exception;
    exception_cause_t   cause;
    bit                 regwrite;
    bit                 is_jump;
    bit                 mispredict;
  } fu_slot_t;

  fu_slot_t fu_pipe                                                  [NUM_FU][MAX_LAT];

  bit       dispatch_en = 0;
  int       pc_idx;
  bit       squashed;  //a trap or mispredict has emptied the machine
  int       mispredict_idx = -1;

  //A FENCE never enters the ROB: dispatch holds it until the machine has drained and
  //then retires it locally. Holding it is what makes it a barrier - nothing younger
  //can issue while it waits
  bit fence_at_head, fence_wait, fence_release;
  int fence_stall_cycles = 0;

  bit want_issue;

  //These read decoded[pc_idx] -- a dynamic-array element indexed by a variable.
  //As continuous assigns, xsim cannot infer a sensitivity list on a dynamic-array
  //element (WARNING XSIM 43-3980), so they never re-evaluate and the DUT sees
  //stale issue signals. `decoded` is loaded once and static thereafter, so an
  //explicit sensitivity list on the varying controls is equivalent and portable
  //(the array read inside the block is fine; only the *sensitivity* was the
  //problem). Driven combinationally so an issue is only asserted when the ROB can
  //take it, keeping shadow_wptr exactly in step with the ROB's own wptr.
  always @(dispatch_en, squashed, pc_idx, o_ready, o_empty) begin
    fence_at_head     = dispatch_en && !squashed && pc_idx < decoded.size()
                          && decoded[pc_idx].fence;
    fence_wait        = fence_at_head && !o_empty;
    fence_release     = fence_at_head && o_empty;
    want_issue        = dispatch_en && !squashed && pc_idx < decoded.size()
                          && !decoded[pc_idx].fence;
    i_issue_valid     = want_issue && o_ready;
    i_issue_pc        = want_issue ? decoded[pc_idx].pc : '0;
    i_issue_rd        = want_issue ? decoded[pc_idx].rd : '0;
    i_issue_regwrite  = want_issue ? decoded[pc_idx].regwrite : '0;
    i_issue_store     = want_issue ? decoded[pc_idx].store : '0;
    i_issue_exception = want_issue ? decoded[pc_idx].exception : '0;
    i_issue_exc_cause = want_issue ? decoded[pc_idx].cause : ILLEGAL_INSTR;
  end

  // -------------------------------------------------------------------------
  // Functional unit pipelines + dispatch bookkeeping
  // -------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst) begin
      for (int f = 0; f < NUM_FU; f++)
      for (int s = 0; s < MAX_LAT; s++) fu_pipe[f][s] <= '{default: '0, cause: ILLEGAL_INSTR};
      pc_idx             <= 0;
      squashed           <= 1'b0;
      fence_stall_cycles <= 0;
    end  //the flush contract: when the ROB squashes, the units must be squashed too,
         //or a late writeback would mark a reallocated entry complete
    else if (o_exception_valid || (i_jump_valid && i_jump_mispredicted)) begin
      for (int f = 0; f < NUM_FU; f++)
      for (int s = 0; s < MAX_LAT; s++) fu_pipe[f][s].valid <= 1'b0;
      //no pointer bookkeeping to undo here: o_issue_robtag follows the ROB's own
      //wptr, so the rewind is already accounted for by the time dispatch resumes
      squashed <= 1'b1;
    end else begin
      for (int f = 0; f < NUM_FU; f++) begin
        for (int s = MAX_LAT - 1; s > 0; s--) fu_pipe[f][s] <= fu_pipe[f][s-1];
        fu_pipe[f][0].valid <= 1'b0;
      end

      if (i_issue_valid) begin
        if (decoded[pc_idx].fu >= 0) begin
          fu_pipe[decoded[pc_idx].fu][0].valid      <= 1'b1;
          fu_pipe[decoded[pc_idx].fu][0].robtag     <= o_issue_robtag;
          fu_pipe[decoded[pc_idx].fu][0].data       <= decoded[pc_idx].value;
          fu_pipe[decoded[pc_idx].fu][0].exception  <= 1'b0;
          fu_pipe[decoded[pc_idx].fu][0].cause      <= ILLEGAL_INSTR;
          fu_pipe[decoded[pc_idx].fu][0].regwrite   <= decoded[pc_idx].regwrite;
          fu_pipe[decoded[pc_idx].fu][0].is_jump    <= (decoded[pc_idx].fu == FU_BJU);
          fu_pipe[decoded[pc_idx].fu][0].mispredict <= (pc_idx == mispredict_idx);
        end
        pc_idx <= pc_idx + 1;
      end  //retire the fence locally once everything older has committed
      else if (fence_release)
        pc_idx <= pc_idx + 1;
      else if (fence_wait) fence_stall_cycles <= fence_stall_cycles + 1;
    end
  end

  //unit results. The branch unit reports completion through i_jump_* instead, and
  //only writes a result back when the instruction actually produces one (JAL/JALR)
  always_comb begin
    for (int f = 0; f < NUM_FU; f++) begin
      i_fu_res_valid[f]     = fu_pipe[f][FU_LATENCY[f]-1].valid
                                    && (f != FU_BJU || fu_pipe[f][FU_LATENCY[f]-1].regwrite);
      i_fu_res_robtag[f] = fu_pipe[f][FU_LATENCY[f]-1].robtag;
      i_fu_res_data[f] = fu_pipe[f][FU_LATENCY[f]-1].data;
      i_fu_res_exception[f] = fu_pipe[f][FU_LATENCY[f]-1].exception;
      i_fu_res_cause[f] = fu_pipe[f][FU_LATENCY[f]-1].cause;
    end
  end

  assign i_jump_valid        = fu_pipe[FU_BJU][FU_LATENCY[FU_BJU]-1].valid
                                 && fu_pipe[FU_BJU][FU_LATENCY[FU_BJU]-1].is_jump;
  assign i_jump_robtag = fu_pipe[FU_BJU][FU_LATENCY[FU_BJU]-1].robtag;
  assign i_jump_mispredicted = fu_pipe[FU_BJU][FU_LATENCY[FU_BJU]-1].mispredict;

  // -------------------------------------------------------------------------
  // Checker
  // -------------------------------------------------------------------------
  function automatic void check_event(input ev_kind_e kind, input string detail);
    event_t e;
    if (exp_q.size() == 0) begin
      $display("[FAIL] unexpected %s with nothing outstanding | %s", kind.name(), detail);
      fail_cnt++;
      return;
    end
    e = exp_q.pop_front();
    if (e.kind !== kind) begin
      $display("[FAIL] out of order: got %s, expected %s for '%s'", kind.name(), e.kind.name(),
               e.asm);
      fail_cnt++;
      return;
    end
    case (kind)
      EV_COMMIT:
      if (o_commit_rd !== e.rd || o_commit_value !== e.value) begin
        $display("[FAIL] commit '%s': got rd=x%0d val=0x%08h, exp rd=x%0d val=0x%08h", e.asm,
                 o_commit_rd, o_commit_value, e.rd, e.value);
        fail_cnt++;
      end else pass_cnt++;
      EV_STORE:
      if (o_store_robtag !== e.tag) begin
        $display("[FAIL] store '%s': got tag=%0d, exp tag=%0d", e.asm, o_store_robtag, e.tag);
        fail_cnt++;
      end else pass_cnt++;
      EV_TRAP:
      if (o_exception_cause !== e.cause || o_exception_pc !== e.pc) begin
        $display("[FAIL] trap '%s': got cause=%s pc=0x%08h, exp cause=%s pc=0x%08h", e.asm,
                 o_exception_cause.name(), o_exception_pc, e.cause.name(), e.pc);
        fail_cnt++;
      end else pass_cnt++;
      default: ;
    endcase
  endfunction

  //plain always rather than always_ff: the pass/fail counters are shared with the
  //test driver below, so they must not be single-driver bound to this process
  always @(posedge clk) begin
    if (!rst) begin
      if (o_commit_valid)
        check_event(EV_COMMIT, $sformatf("rd=x%0d val=0x%08h", o_commit_rd, o_commit_value));
      if (o_store_valid) check_event(EV_STORE, $sformatf("tag=%0d", o_store_robtag));
      if (o_exception_valid) check_event(EV_TRAP, $sformatf("cause=%s", o_exception_cause.name()));
      //nothing squashed is ever queued, so a squashed instruction that reaches an
      //output lands here as an event with nothing outstanding rather than passing
      //silently - which is the whole point of the trap and mispredict tests
    end
  end

  // -------------------------------------------------------------------------
  // Test driver
  // -------------------------------------------------------------------------
  task automatic reset_dut();
    rst = 1'b1;
    exp_q.delete();
    mispredict_idx = -1;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
  endtask

  //queue the observable effect of each instruction, in program order. A conditional
  //branch neither writes a register nor stores, so it produces nothing to watch - it
  //just has to retire without wedging the head, which the final drain check proves.
  //Anything squashed is simply never queued, so if the ROB does commit it the checker
  //reports an event with nothing outstanding
  task automatic expect_program();
    bit [TAG_WIDTH-1:0] tag = '0;
    foreach (decoded[k]) begin
      event_t e;
      e.asm = decoded[k].asm;
      e.tag = tag;
      if (decoded[k].fence) continue;  //never enters the ROB, so it consumes no tag
      if (decoded[k].exception) begin
        e.kind = EV_TRAP;
        e.cause = decoded[k].cause;
        e.pc = decoded[k].pc;
        exp_q.push_back(e);
        break;  //younger instructions are squashed, so nothing after this is seen
      end
      if (decoded[k].store) begin
        e.kind = EV_STORE;
        exp_q.push_back(e);
      end else if (decoded[k].regwrite) begin
        e.kind = EV_COMMIT;
        e.rd = decoded[k].rd;
        e.value = decoded[k].value;
        exp_q.push_back(e);
      end
      tag++;
      //a mispredicted jump retires normally - it is a valid instruction that
      //merely predicted wrong - but everything younger is on the wrong path
      if (mispredict_idx >= 0 && k >= mispredict_idx) break;
    end
  endtask

  task automatic run_program(input string name);
    int t;
    $display("\n--- %s ---", name);
    dispatch_en = 1'b1;
    t = 0;
    //run until the stream is issued and the machine has drained, or a squash
    while (t < TIMEOUT && !(squashed && o_empty)
               && !(pc_idx == decoded.size() && o_empty && exp_q.size() == 0)) begin
      @(posedge clk);
      t++;
    end
    repeat (6) @(posedge clk);
    dispatch_en = 1'b0;

    if (t >= TIMEOUT) begin
      $display("[FAIL] %s: timed out (pc_idx=%0d/%0d empty=%0b outstanding=%0d)", name, pc_idx,
               decoded.size(), o_empty, exp_q.size());
      fail_cnt++;
    end else if (exp_q.size() != 0) begin
      $display("[FAIL] %s: %0d expected event(s) never happened, next is '%s'", name, exp_q.size(),
               exp_q[0].asm);
      fail_cnt++;
    end else begin
      $display("       %s: drained cleanly", name);
      pass_cnt++;
    end
  endtask

  // -------------------------------------------------------------------------
  // Programs (riscv64-unknown-elf-as -march=rv32i -mabi=ilp32)
  // -------------------------------------------------------------------------
  initial begin
    bit    [31:0] prog[];
    string        asms[];

    $dumpfile("dump.vcd");
    $dumpvars(0, reorder_buffer_tb);
    decoder = new();

    // ---- A: mixed latencies, so completion order != program order ----
    // The add at index 1 finishes 2 cycles before the lw at index 0; the ROB
    // still has to commit the lw first.
    prog = '{
        32'h00052083,  // lw   x1, 0(x10)
        32'h00418133,  // add  x2, x3, x4
        32'h007362b3,  // or   x5, x6, x7
        32'h00252223,  // sw   x2, 4(x10)
        32'h00100413,  // addi x8, x0, 1
        32'h00208663,  // beq  x1, x2, +12   (predicted correctly)
        32'h0020a4b3,  // slt  x9, x1, x2
        32'h002095b3,  // sll  x11, x1, x2
        32'h00852603,  // lw   x12, 8(x10)
        32'h0020c6b3,  // xor  x13, x1, x2
        32'h40208733  // sub  x14, x1, x2
    };
    asms = '{
        "lw x1,0(x10)",
        "add x2,x3,x4",
        "or x5,x6,x7",
        "sw x2,4(x10)",
        "addi x8,x0,1",
        "beq x1,x2,+12",
        "slt x9,x1,x2",
        "sll x11,x1,x2",
        "lw x12,8(x10)",
        "xor x13,x1,x2",
        "sub x14,x1,x2"
    };
    reset_dut();
    load_program(prog, asms);
    expect_program();
    run_program("A: out-of-order completion, in-order commit");

    // ---- B: ECALL traps at commit and squashes everything younger ----
    prog = '{
        32'h003100b3,  // add  x1, x2, x3
        32'h00052203,  // lw   x4, 0(x10)
        32'h00000073,  // ecall
        32'h007302b3,  // add  x5, x6, x7   <- squashed
        32'h00852023  // sw   x8, 0(x10)   <- squashed
    };
    asms = '{"add x1,x2,x3", "lw x4,0(x10)", "ecall", "add x5,x6,x7", "sw x8,0(x10)"};
    reset_dut();
    load_program(prog, asms);
    expect_program();
    run_program("B: ECALL traps precisely, younger squashed");

    // ---- C: mispredicted jump retires, younger squashed ----
    // A JALR rather than a conditional branch on purpose: it writes its link
    // register, so its commit is observable. That is what proves the jump itself
    // survived the flush - a beq would retire invisibly and the test would pass
    // even if the ROB wrongly discarded it along with the wrong-path instructions.
    prog = '{
        32'h003100b3,  // add  x1, x2, x3
        32'h000302e7,  // jalr x5, 0(x6)    (mispredicted target)
        32'h00838333,  // add  x6, x7, x8   <- squashed
        32'h00952023  // sw   x9, 0(x10)   <- squashed
    };
    asms = '{"add x1,x2,x3", "jalr x5,0(x6)", "add x6,x7,x8", "sw x9,0(x10)"};
    reset_dut();
    mispredict_idx = 1;  //set before expect_program so it stops queueing after it
    load_program(prog, asms);
    expect_program();
    run_program("C: mispredicted jump retires, younger squashed");

    // ---- D: EBREAK ----
    prog = '{
        32'h003100b3,  // add  x1, x2, x3
        32'h00100073,  // ebreak
        32'h00628233  // add  x4, x5, x6   <- squashed
    };
    asms = '{"add x1,x2,x3", "ebreak", "add x4,x5,x6"};
    reset_dut();
    load_program(prog, asms);
    expect_program();
    run_program("D: EBREAK traps with BREAKPOINT cause");

    // ---- E: FENCE drains the ROB before anything younger issues ----
    prog = '{
        32'h00052083,  // lw   x1, 0(x10)
        32'h00418133,  // add  x2, x3, x4
        32'h0330000f,  // fence rw, rw
        32'h007302b3  // add  x5, x6, x7
    };
    asms = '{"lw x1,0(x10)", "add x2,x3,x4", "fence rw,rw", "add x5,x6,x7"};
    reset_dut();
    load_program(prog, asms);
    expect_program();
    run_program("E: FENCE drains before younger work issues");
    //if the fence never actually waited, the test proved nothing: the lw ahead of it
    //takes 3 cycles, so dispatch must have been held for at least a few cycles
    if (fence_stall_cycles == 0) begin
      $display("[FAIL] E: FENCE never stalled - the barrier was not exercised");
      fail_cnt++;
    end else begin
      $display("       E: FENCE held dispatch for %0d cycles waiting on the drain",
               fence_stall_cycles);
      pass_cnt++;
    end

    // ---- F: backpressure, more instructions than the ROB is deep ----
    prog = new[DEPTH + 8];
    asms = new[DEPTH + 8];
    foreach (prog[k]) begin
      prog[k] = 32'h00100413;  // addi x8, x0, 1
      asms[k] = $sformatf("addi x8,x0,1 (#%0d)", k);
    end
    reset_dut();
    load_program(prog, asms);
    expect_program();
    run_program("F: backpressure, stream longer than the ROB");

    $display("\n=== SUMMARY: %0d passed, %0d failed ===", pass_cnt, fail_cnt);
    if (fail_cnt == 0) $display("ALL TESTS PASSED");
    else $display("%0d CHECK(S) FAILED", fail_cnt);
    $finish;
  end

endmodule
