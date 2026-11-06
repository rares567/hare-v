package forwarding_package;

    // Forwarding multiplexer select controls for the Execute stage
    typedef enum logic [1:0] {
        FWD_NONE     = 2'b00,
        FWD_FROM_WB  = 2'b01,
        FWD_FROM_MEM = 2'b10
    } fwd_sel_t;

endpackage
