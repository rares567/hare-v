`ifndef INTERFACES_SVH
`define INTERFACES_SVH

//Wishbone interface used between CPU and Memories/Periperals
interface wishboneIf #(
        parameter type DATA_T = bit[31:0],
        parameter int ADDR_WIDTH = 10,
        parameter int DATA_WIDTH = $bits(DATA_T),
        parameter int SELECT_WIDTH = (DATA_WIDTH/8)
    )(
        input wire clk
    );

    logic [ADDR_WIDTH-1:0]   addr;   // ADR_I() address
    DATA_T                   data_wr;   // DAT_I() data for write access
    DATA_T                   data_rd;   // DAT_O() data for read access
    logic                    we;    // WE_I write enable input
    logic [SELECT_WIDTH-1:0] sel;   // SEL_I() select input
    logic                    stb;   // STB_I strobe input
    logic                    ack;   // ACK_O acknowledge output
    logic                    stall;
    logic                    cyc;    // CYC_I cycle input
    logic                    err;

    modport Slave (
        //inputs from Master
        input addr,
        input data_wr,
        input we,
        input sel,
        input stb,
        input cyc,
        //Outputs to Master
        output data_rd,
        output ack,
        output stall,
        output err
    );

    modport Master (
        //outputs to Slave
        output addr,
        output data_wr,
        output we,
        output sel,
        output stb,
        output cyc,
        //inputs from Slave
        input data_rd,
        input ack,
        input stall,
        input err
    );

    task automatic MasterWrite (
        input logic [ADDR_WIDTH-1:0]   waddr,
        input DATA_T                   wdata,
        input logic [SELECT_WIDTH-1:0] wsel = '1
    );
        if (stall)
            $display("Downstream module is busy, waiting for it to become ready before sending write request");
        @(posedge clk iff stall == '0);
        addr    = waddr;
        data_wr = wdata;
        we      = '1;
        sel     = wsel;
        stb     = '1;
        cyc     = '1;
        @(posedge clk);
        we  = '0;
        stb = '0;
        if (~ack && ~err)
            wait(ack == 1'b1 || err == 1'b1);
        cyc = '0;
        if (err)
            $display("Received err on write request @address %h", waddr);
        else
            $display("Received ack on write request @address %h with data %h", waddr, wdata);
    endtask

    task automatic MasterRead (
        input  logic [ADDR_WIDTH-1:0]   raddr,
        output DATA_T                   rdata,
        input  logic [SELECT_WIDTH-1:0] rsel = '1
    );
        if (stall)
            $display("Downstream module is busy, waiting for it to become ready before sending read request");
        @(posedge clk iff stall == '0);
        addr    = raddr;
        data_wr = '0;
        we      = '0;
        sel     = rsel;
        stb     = '1;
        cyc     = '1;
        @(posedge clk);
        stb = '0;
        if (~ack && ~err)
            wait(ack == 1'b1 || err == 1'b1);
        rdata = data_rd;
        cyc = '0;
        if (err)
            $display("Received err on read request @address %h", raddr);
        else
            $display("Received ack on read request @address %h with data %h", raddr, rdata);
    endtask

endinterface //interfacename

//Basic Ready-Valid interface for CPU internal pipeline with generic data type
interface handshakeIf #(
        parameter type DATA_T = bit [31:0],
        parameter int DATA_WIDTH = $bits(DATA_T)
    )(
        input clk
    );

    DATA_T data;
    logic ready;
    logic valid;

    modport Downstream(
        output data,
        output valid,
        input ready
    );

    modport Upstream(
        input data,
        input valid,
        output ready
    );

    // Task to push a single piece of data
    task automatic push_data(input DATA_T val);
        valid <= 1;
        data  <= val;

        // Wait for a clock edge where ready is high (the "handshake")
        do begin
            @(posedge clk);
        end while (!ready);

        valid <= 0;
        $display("[PRODUCER] Pushed: %h", val);
    endtask

    // Task to pop a single piece of data
    task automatic pop_data(output DATA_T val);
        ready <= 1;

        // Wait for a clock edge where valid is high
        do begin
            @(posedge clk);
        end while (!valid);

        val = data;
        ready <= 0;
        $display("[CONSUMER] Popped: %h", val);
    endtask

endinterface

`endif // INTERFACES_SVH
