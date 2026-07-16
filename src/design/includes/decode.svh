package decode_package;

    //length of supported instructions; does not support compressed instructions for now
    parameter int ILEN = 32;
    // define the ROB DEPTH at the package level as this is needed to define the tag width
    parameter int ROB_DEPTH = 32;

    //instruction as bit vector
    typedef bit [ILEN-1:0] bit_instruction_t;
    typedef bit [31:0] rv32_data_t;
    typedef bit [63:0] rv64_data_t;

    //compressed opcode for the Execute stage
    typedef enum bit[3:0]{
        //I-base extension operations
        ADD_OP  = 4'b0000,
        SUB_OP  = 4'b0011,
        AND_OP  = 4'b1100,
        OR_OP   = 4'b1110,
        XOR_OP  = 4'b0100
    } alu_op_t;

    typedef enum bit[3:0] {
        MUL_OP    = 4'b0000,
        MULH_OP   = 4'b0001,
        MULHSU_OP = 4'b0011,
        DIV_OP    = 4'b0100,
        DIVU_OP   = 4'b0101,
        REM_OP    = 4'b0110,
        REMU_OP   = 4'b0111,
        MULW_OP   = 4'b1000,
        DIVW_OP   = 4'b1100,
        DIVUW_OP  = 4'b1101,
        REMW_OP   = 4'b1110,
        REMUW_OP  = 4'b1111
    } mul_div_op_t;

    typedef enum bit [2:0]{
        SRL_OP   = 3'b000,
        SLL_OP   = 3'b001,
        SRA_OP   = 3'b010,
        ROTL_OP  = 3'b101,
        ROTR_OP  = 3'b111
    } shift_op_t;

    //match branch codes
    //R-type SLT and SLTU needs to be left-shifted by one
    typedef enum bit [2:0] {
        SEQ_OP = 3'b000,
        SNE_OP = 3'b001,
        SLT_OP = 3'b100,
        SGE_OP = 3'b101,
        SLTU_OP = 3'b110,
        SGEU_OP = 3'b111
    } comp_op_t;

    typedef enum bit[2:0]{
        REG,
        IMM,
        CONST, //will be 4 for RV32 and 8 for RV8
        ZERO,
        PC
    } fu_src_t;

    typedef enum bit [2:0]{
        INT_ALU_UNIT,
        BRANCH_JUMP_UNIT,
        COMPARATOR_UNIT,
        LOAD_STORE_UNIT,
        SHIFTER_UNIT,
        MUL_DIV_UNIT
    } functional_unit_t;

    typedef enum bit [1:0] {
        NONE = 2'b00,
        EQ   = 2'b01, //EQUAL
        LT   = 2'b10, //LESS THAN
        GT   = 2'b11  //GREATER THAN
    } magnitude_comp_t;

    typedef enum bit [2:0] {
        BEQ_OP = 3'b000,
        BNE_OP = 3'b001,
        BLT_OP = 3'b100,
        BGE_OP = 3'b101,
        BLTU_OP = 3'b110,
        BGEU_OP = 3'b111,
        JAL_OP  = 3'b010,
        JALR_OP = 3'b011
    } branch_jump_t;

    typedef enum bit [3:0] {
        LB_OP = 4'b0000,
        LH_OP = 4'b0001,
        LW_OP = 4'b0010,
        LBU_OP = 4'b0100,
        LHU_OP = 4'b0101,
        LWU_OP = 4'b0110,
        LD_OP = 4'b0011,
        SB_OP = 4'b1000,
        SH_OP = 4'b1001,
        SW_OP = 4'b1010,
        SD_OP = 4'b1011
    } load_store_t;

    typedef union {
        alu_op_t alu_op;
        load_store_t load_store_op;
        branch_jump_t branch_jump_op;
        comp_op_t comp_op;
        shift_op_t shift_op;
    } fu_op_t;

    //standard RISC-V machine trap causes, i.e. the exception code that the trap
    //logic zero-extends into mcause (mcause[XLEN-1], the interrupt flag, is 0 for
    //all of these as they are all synchronous exceptions)
    typedef enum bit [3:0] {
        INSTR_ADDR_MISALIGNED = 4'd0,
        INSTR_ACCESS_FAULT    = 4'd1,
        ILLEGAL_INSTR         = 4'd2,
        BREAKPOINT            = 4'd3,
        LOAD_ADDR_MISALIGNED  = 4'd4,
        LOAD_ACCESS_FAULT     = 4'd5,
        STORE_ADDR_MISALIGNED = 4'd6,
        STORE_ACCESS_FAULT    = 4'd7,
        ECALL_FROM_U          = 4'd8,
        ECALL_FROM_S          = 4'd9,
        ECALL_FROM_M          = 4'd11
    } exception_cause_t;

    //main constrol signals for the entire CPU pipeline
    typedef struct packed {
        bit RegWrite;
        bit Load;
        bit Store;
        bit Branch;
        bit Jump;
        fu_src_t FuSrc1;
        fu_src_t FuSrc2;
        //FENCE changes no architectural state; it is a memory ordering barrier,
        //not a trap, so it gets its own bit rather than raising an Exception
        bit Fence;
        bit Exception;
        //only meaningful while Exception is set
        exception_cause_t ExcCause;
    } control_data_t;

    //instruction in a packet format with main fields
    typedef struct packed {
        bit [6:0] Funct7;
        bit [4:0] Rs2;
        bit [4:0] Rs1;
        bit [2:0] Funct3;
        bit [4:0] Rd;
        bit [6:0] Opcode;
    } packed_instruction_t;

    typedef union packed {
        bit_instruction_t raw;
        packed_instruction_t fields;
    } instruction_t;

    //packed data type that contains a instrunction and its PC for RV32
    typedef struct packed {
        instruction_t instr;
        rv32_data_t pc;
    } rv32_instr_pc_packet_t;

    //packed data type that contains a instrunction and its PC for RV64
    typedef struct packed {
        instruction_t instr;
        rv64_data_t pc;
    } rv64_instr_pc_packet_t;

    //unpacked decoded instruction for RV32
    typedef struct {
        bit [4:0] Rs2;
        bit [4:0] Rs1;
        bit [4:0] Rd;
        rv32_data_t Imm;
        rv32_data_t Pc;
        functional_unit_t FunctionalUnitType;
        fu_op_t FunctionalUnitOp;
        control_data_t ControlData;
    } rv32i_decoded_instruction_t;

    //unpacked decoded instruction for RV64
    typedef struct {
        bit [4:0] Rs2;
        bit [4:0] Rs1;
        bit [4:0] Rd;
        rv64_data_t Imm;
        rv64_data_t Pc;
        functional_unit_t FunctionalUnitType;
        fu_op_t FunctionalUnitOp;
        control_data_t ControlData;
    } rv64i_decoded_instruction_t;

    class rv32iDecoder;

        typedef rv32i_decoded_instruction_t decoded_instruction_t;

        //main decode function, should be used by any RV32-type extending child decoder class as it is, don't need to overrride it
        function decoded_instruction_t decodeInstruction(instruction_t instr, rv32_data_t pc);

            decoded_instruction_t decoded_instr;

            decoded_instr.Pc = pc;
            decoded_instr.Rd = instr.fields.Rd;
            decoded_instr.Rs1 = instr.fields.Rs1;
            decoded_instr.Rs2 = instr.fields.Rs2;
            decoded_instr.Imm = this.decodeImmData(instr);
            decoded_instr.FunctionalUnitType = this.decodeFuType(instr.fields.Opcode[6:2],instr.fields.Funct3);
            decoded_instr.FunctionalUnitOp = this.decodeFuOp(instr.fields.Opcode[6:2],instr.fields.Funct3, instr.fields.Funct7);
            decoded_instr.ControlData = this.decodeControlData(instr.fields.Opcode[6:2], instr.fields.Funct3, {instr.fields.Funct7, instr.fields.Rs2});

            return decoded_instr;
        endfunction

       //funct3 and funct12 are needed to tell the SYSTEM/MISC-MEM instructions apart:
       //ECALL and EBREAK share an opcode and differ only in funct12, and FENCE vs
       //FENCE.I differ only in funct3
       function control_data_t decodeControlData(bit [4:0] opcode, bit [2:0] funct3, bit [11:0] funct12);

            //ExcCause defaults to ILLEGAL_INSTR so that any opcode we never decode
            //traps as an illegal instruction without needing to spell it out
            control_data_t control_signals = '{
                RegWrite: 1'b0,
                Load: 1'b0,
                Store: 1'b0,
                Branch: 1'b0,
                Jump: 1'b0,
                FuSrc1: ZERO,
                FuSrc2: ZERO,
                Fence: 1'b0,
                Exception: 1'b0,
                ExcCause: ILLEGAL_INSTR
            };

            unique case (opcode) inside

                //Imm-Type
                5'b00100: begin
                    control_signals.RegWrite = 1'b1;
                    control_signals.FuSrc1 = REG;
                    control_signals.FuSrc2 = IMM;
                end

                //R-Type
                5'b01100: begin
                    control_signals.RegWrite = 1'b1;
                    control_signals.FuSrc1 = REG;
                    control_signals.FuSrc2 = REG;
                end

                //Load-Type
                5'b00000: begin
                    control_signals.RegWrite = 1'b1;
                    control_signals.Load = 1'b1;
                    control_signals.FuSrc1 = REG;
                    control_signals.FuSrc2 = IMM;
                end

                //Store-Type
                5'b01000: begin
                    control_signals.Store = 1'b1;
                    control_signals.FuSrc1 = REG;
                    control_signals.FuSrc2 = IMM;
                end

                 //U-Type LUI
                5'b01101: begin
                    control_signals.RegWrite = 1'b1;
                    control_signals.FuSrc1 = ZERO;
                    control_signals.FuSrc2 = IMM;
                end

                //U-Type AUIPC
                5'b00101: begin
                    control_signals.RegWrite = 1'b1;
                    control_signals.FuSrc1 = PC;
                    control_signals.FuSrc2 = IMM;
                end

                //B-Type
                5'b11000: begin
                    control_signals.Branch = 1'b1;
                    control_signals.FuSrc1 = REG;
                    control_signals.FuSrc2 = REG;
                end

                //J-Type Jal
                5'b11011: begin
                    control_signals.Jump = 1'b1;
                    control_signals.RegWrite = 1'b1;
                    control_signals.FuSrc1 = PC;
                    control_signals.FuSrc2 = IMM;
                end

                //J-Type Jalr
                5'b11001: begin
                    control_signals.Jump = 1'b1;
                    control_signals.RegWrite = 1'b1;
                    control_signals.FuSrc1 = REG;
                    control_signals.FuSrc2 = IMM;
                end

                //MISC-MEM: FENCE orders memory accesses but touches no architectural
                //state, so it retires as a barrier and must never trap - compilers emit
                //it for __sync_synchronize and correct programs would break otherwise.
                //Its fm/pred/succ/rs1/rd fields are reserved for finer-grain fences and
                //the spec requires base implementations to ignore them, so we key on
                //funct3 alone. FENCE.I (funct3=001) is Zifencei rather than RV32I, so it
                //stays illegal until that extension is added.
                5'b00011: begin
                    if (funct3 == 3'b000)
                        control_signals.Fence = 1'b1;
                    else
                        control_signals.Exception = 1'b1;
                end

                //SYSTEM: only ECALL and EBREAK are RV32I, and neither writes a register -
                //all of their architectural effect is trap entry, handled at commit.
                //Everything else sharing this opcode needs state we do not have yet:
                //MRET (funct12=0x302) and SRET (0x102) are trap *returns* that read
                //mepc/mstatus, and CSRR* (funct3!=0) is Zicsr. SRET is additionally
                //illegal by definition while S-mode is unimplemented.
                5'b11100: begin
                    control_signals.Exception = 1'b1;
                    if (funct3 == 3'b000) begin
                        case (funct12)
                            //this core is M-mode only, so ECALL always traps from M
                            12'h000: control_signals.ExcCause = ECALL_FROM_M;
                            12'h001: control_signals.ExcCause = BREAKPOINT;
                            default: control_signals.ExcCause = ILLEGAL_INSTR;
                        endcase
                    end
                end

                //Exception raised - undefined opcode
                default: control_signals.Exception = 1'b1;
            endcase

            return control_signals;
        endfunction

        function functional_unit_t decodeFuType(bit [4:0] opcode, bit [2:0] funct3);

            functional_unit_t fu_type = INT_ALU_UNIT;
            unique case ({opcode, funct3}) inside

                //R+I-Type Shift operations
                8'b0?100_?01: fu_type = SHIFTER_UNIT;

                //R+I-Type SLT operations
                8'b0?100_01?: fu_type = COMPARATOR_UNIT;

                //Load+Store-Type
                8'b0?000_???: fu_type = LOAD_STORE_UNIT;

                //U-Type
                8'b0?101_???: fu_type = INT_ALU_UNIT;

                //B-Type
                8'b11000_???,
                //J-Type Jal
                8'b11011_???,
                //J-Type Jalr
                8'b11001_???: fu_type = BRANCH_JUMP_UNIT;

                default: fu_type = INT_ALU_UNIT; //any other R/I-type instructions
            endcase

            return fu_type;
        endfunction

        function fu_op_t decodeFuOp(bit [4:0] opcode, bit[2:0] funct3, bit[6:0] funct7);
            fu_op_t execute_opcode;
            unique case({opcode, funct3,funct7[5]}) inside
                9'b00000_???_?: /*LOAD*/    execute_opcode.load_store_op = load_store_t'({1'b0, funct3});
                9'b01000_???_?: /*STORE*/   execute_opcode.load_store_op = load_store_t'({1'b1, funct3});
                9'b11011_???_?: /*JAL*/     execute_opcode.branch_jump_op = JAL_OP;
                9'b11001_???_?: /*JALR*/    execute_opcode.branch_jump_op = JALR_OP;
                9'b0?101_???_?, /*LUI,AUIPC*/
                9'b01100_000_0, /*ADD*/
                9'b00100_000_?: /*ADDI*/    execute_opcode.alu_op = ADD_OP;
                9'b0?100_111_?: /*AND(I)*/  execute_opcode.alu_op = AND_OP;
                9'b0?100_110_?: /*OR(I)*/   execute_opcode.alu_op = OR_OP;
                9'b0?100_100_?: /*XOR(I)*/  execute_opcode.alu_op = XOR_OP;
                9'b01100_000_1: /*SUB*/     execute_opcode.alu_op = SUB_OP;
                9'b0?100_001_?: /*SLL(I)*/  execute_opcode.shift_op = SLL_OP;
                9'b0?100_101_0: /*SRL(I)*/  execute_opcode.shift_op = SRL_OP;
                9'b0?100_101_1: /*SRA(I)*/  execute_opcode.shift_op = SRA_OP;
                9'b11000_???_?: /*BRANCH*/  execute_opcode.branch_jump_op = branch_jump_t'(funct3);
                9'b0?100_010_?: /*SLT(I)*/  execute_opcode.comp_op = SLT_OP;
                9'b0?100_011_?: /*SLTU(I)*/ execute_opcode.comp_op = SLTU_OP;
                default: execute_opcode.alu_op = alu_op_t'('0);
            endcase
            return execute_opcode;
        endfunction

        function rv32_data_t decodeImmData(instruction_t instruction);

            rv32_data_t imm_data = '0;
            bit sign_bit = instruction.raw[ILEN-1];

            unique case (instruction.fields.Opcode[6:2]) inside

                //Imm-Type
                5'b00100: imm_data = {{($bits(imm_data)-12){sign_bit}}, instruction.raw[31:20]};

                //Load-Type
                5'b00000: imm_data = {{($bits(imm_data)-12){sign_bit}}, instruction.raw[31:20]};

                //Store-Type
                5'b01000: imm_data = {{($bits(imm_data)-12){sign_bit}}, instruction.raw[31:25], instruction.raw[11:7]};

                //U-Type LUI
                5'b01101: imm_data = {instruction.raw[31:12], {12{1'b0}}};

                //U-Type AUIPC
                5'b00101: imm_data = {instruction.raw[31:12], {12{1'b0}}};

                //B-Type
                5'b11000: imm_data = {{($bits(imm_data)-13){sign_bit}}, instruction.raw[31], instruction.raw[7], instruction.raw[30:25], instruction.raw[11:8], 1'b0};

                //J-Type Jal
                5'b11011: imm_data = {{12{sign_bit}}, instruction.raw[19:12], instruction.raw[20], instruction.raw[30:21], 1'b0};

                //J-Type Jalr
                5'b11001: imm_data = {{20{sign_bit}}, instruction.raw[31:20]};

                //no other case
                default: imm_data = '0;
            endcase

            return imm_data;
        endfunction

    endclass

    class rv64iDecoder extends rv32iDecoder;

        typedef rv64i_decoded_instruction_t decoded_instruction_t;

        //main decode function, should be used by any RV64-type extending child decoder class as it is, don't need to overrride it
        function decoded_instruction_t decodeInstruction(instruction_t instr, rv64_data_t pc);

            decoded_instruction_t decoded_instr;

            decoded_instr.Pc = pc;
            decoded_instr.Rd = instr.fields.Rd;
            decoded_instr.Rs1 = instr.fields.Rs1;
            decoded_instr.Rs2 = instr.fields.Rs2;
            decoded_instr.Imm = this.decodeImmData(instr);
            decoded_instr.FunctionalUnitType = this.decodeFuType(instr.fields.Opcode[6:2],instr.fields.Funct3);
            decoded_instr.FunctionalUnitOp = this.decodeFuOp(instr.fields.Opcode[6:2],instr.fields.Funct3, instr.fields.Funct7);
            decoded_instr.ControlData = this.decodeControlData(instr.fields.Opcode[6:2], instr.fields.Funct3, {instr.fields.Funct7, instr.fields.Rs2});

            return decoded_instr;
        endfunction

        //RV64 inherits the RV32 FENCE/ECALL/EBREAK handling as-is: the trap causes are
        //XLEN-independent and RV64I adds no new SYSTEM or MISC-MEM instructions
        function control_data_t decodeControlData(bit [4:0] opcode, bit [2:0] funct3, bit [11:0] funct12);

            control_data_t control_signals = '{
                RegWrite: 1'b0,
                Load: 1'b0,
                Store: 1'b0,
                Branch: 1'b0,
                Jump: 1'b0,
                FuSrc1: ZERO,
                FuSrc2: ZERO,
                Fence: 1'b0,
                Exception: 1'b0,
                ExcCause: ILLEGAL_INSTR
            };
            unique case (opcode) inside
                default: control_signals = super.decodeControlData(opcode, funct3, funct12);
            endcase

            return control_signals;
        endfunction

        function functional_unit_t decodeFuType(bit [4:0] opcode, bit [2:0] funct3);
            functional_unit_t fu_type = INT_ALU_UNIT;
            unique case ({opcode, funct3}) inside
                default: fu_type = super.decodeFuType(opcode, funct3);
            endcase
            return fu_type;
        endfunction

        function fu_op_t decodeFuOp(bit [4:0] opcode, bit[2:0] funct3, bit[6:0] funct7);
            fu_op_t execute_opcode;
            unique case({opcode, funct3, funct7[5]}) inside
                default: execute_opcode = super.decodeFuOp(opcode, funct3, funct7);
            endcase
            return execute_opcode;
        endfunction

        function rv64_data_t decodeImmData(instruction_t instruction);
           rv32_data_t imm_data = '0;
           unique case (instruction.fields.Opcode[6:2]) inside
                default: imm_data = super.decodeImmData(instruction);
           endcase
           return {{32{imm_data[31]}}, imm_data};
        endfunction

    endclass

endpackage
