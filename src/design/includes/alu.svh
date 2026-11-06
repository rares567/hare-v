`include "decode.svh"

package alu_package;
    import decode_package::*;

    //base RV32I ALU class for 2-operand combinational operations
    class rv32iAlu;

        //main eval function for RV32I ALU operations
        static function automatic rv32_data_t eval(
            input rv32_data_t       op_a,
            input rv32_data_t       op_b,
            input functional_unit_t fu_type,
            input fu_op_t           fu_op
        );
            rv32_data_t result;
            unique case (fu_type)
                // Integer Arithmetic & Logic: ADD, SUB, AND, OR, XOR, LUI, AUIPC
                INT_ALU_UNIT:    result = evalIntAlu(op_a, op_b, fu_op.alu_op);
                // Shifts: SLL, SRL, SRA
                SHIFTER_UNIT:    result = evalShifter(op_a, op_b[4:0], fu_op.shift_op);
                // Comparisons: SLT, SLTU
                COMPARATOR_UNIT: result = evalComparator(op_a, op_b, fu_op.comp_op);
                // Load/Store Address Calculation: Rs1 + Imm
                LOAD_STORE_UNIT: result = evalAddress(op_a, op_b);
                default:         result = '0;
            endcase
            return result;
        endfunction

        //integer arithmetic & logic: ADD, SUB, AND, OR, XOR
        static function automatic rv32_data_t evalIntAlu(input rv32_data_t a, b, input alu_op_t op);
            rv32_data_t res;
            unique case (op)
                ADD_OP: res = a + b;
                SUB_OP: res = a - b;
                AND_OP: res = a & b;
                OR_OP:  res = a | b;
                XOR_OP: res = a ^ b;
                default: res = '0;
            endcase
            return res;
        endfunction

        //shifts: SLL, SRL, SRA
        static function automatic rv32_data_t evalShifter(input rv32_data_t a, input logic [4:0] shamt, input shift_op_t op);
            rv32_data_t res;
            unique case (op)
                SLL_OP: res = a << shamt;
                SRL_OP: res = a >> shamt;
                SRA_OP: res = rv32_data_t'($signed(a) >>> shamt);
                default: res = '0;
            endcase
            return res;
        endfunction

        //comparisons: SLT, SLTU
        static function automatic rv32_data_t evalComparator(input rv32_data_t a, b, input comp_op_t op);
            rv32_data_t res;
            unique case (op)
                SLT_OP:  res = rv32_data_t'($signed(a) < $signed(b));
                SLTU_OP: res = rv32_data_t'(a < b);
                default: res = '0;
            endcase
            return res;
        endfunction

        //load/store address calculation: Rs1 + Imm
        static function automatic rv32_data_t evalAddress(input rv32_data_t base, offset);
            return base + offset;
        endfunction

    endclass

    //extended RV64I ALU class
    class rv64iAlu extends rv32iAlu;

        //main eval function for RV64I ALU operations
        static function automatic rv64_data_t eval64(
            input rv64_data_t       op_a,
            input rv64_data_t       op_b,
            input functional_unit_t fu_type,
            input fu_op_t           fu_op
        );
            rv64_data_t result;
            unique case (fu_type)
                // Integer Arithmetic & Logic: ADD, SUB, AND, OR, XOR, LUI, AUIPC
                INT_ALU_UNIT:    result = evalIntAlu64(op_a, op_b, fu_op.alu_op);
                // Shifts: SLL, SRL, SRA
                SHIFTER_UNIT:    result = evalShifter64(op_a, op_b[5:0], fu_op.shift_op);
                // Comparisons: SLT, SLTU
                COMPARATOR_UNIT: result = evalComparator64(op_a, op_b, fu_op.comp_op);
                // Load/Store Address Calculation: Rs1 + Imm
                LOAD_STORE_UNIT: result = evalAddress64(op_a, op_b);
                default:         result = '0;
            endcase
            return result;
        endfunction

        //integer arithmetic & logic: ADD, SUB, AND, OR, XOR
        static function automatic rv64_data_t evalIntAlu64(input rv64_data_t a, b, input alu_op_t op);
            rv64_data_t res;
            unique case (op)
                ADD_OP: res = a + b;
                SUB_OP: res = a - b;
                AND_OP: res = a & b;
                OR_OP:  res = a | b;
                XOR_OP: res = a ^ b;
                default: res = '0;
            endcase
            return res;
        endfunction

        //shifts: SLL, SRL, SRA
        static function automatic rv64_data_t evalShifter64(input rv64_data_t a, input logic [5:0] shamt, input shift_op_t op);
            rv64_data_t res;
            unique case (op)
                SLL_OP: res = a << shamt;
                SRL_OP: res = a >> shamt;
                SRA_OP: res = rv64_data_t'($signed(a) >>> shamt);
                default: res = '0;
            endcase
            return res;
        endfunction

        //comparisons: SLT, SLTU
        static function automatic rv64_data_t evalComparator64(input rv64_data_t a, b, input comp_op_t op);
            rv64_data_t res;
            unique case (op)
                SLT_OP:  res = rv64_data_t'($signed(a) < $signed(b));
                SLTU_OP: res = rv64_data_t'(a < b);
                default: res = '0;
            endcase
            return res;
        endfunction

        //load/store address calculation: Rs1 + Imm
        static function automatic rv64_data_t evalAddress64(input rv64_data_t base, offset);
            return base + offset;
        endfunction

    endclass

endpackage
