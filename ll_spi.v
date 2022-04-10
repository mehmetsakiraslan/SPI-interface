`timescale 1ns / 1ps

`define PRESCALE        10'd5
`define FIFO_DEPTH      32'd16

module qspi_interface(
// AXI4 LITE SLAVE signals
    // Global Signals
    input                       ACLK,
    input                       ARESET,
    // Write Address Channel
    input [31:0]                AWADDR,
    input                       AWVALID,
    input [2:0]                 AWPROT,
    output                      AWREADY,    //+
    // Write Data Channel
    input [31:0]                WDATA,
    input [3:0]                 WSTRB,
    input                       WVALID,
    output                      WREADY,     //+
    // Write Response Channel   // yazma istegi buradan gelcek
    input                       BREADY,
    output                      BVALID,     //+
    output [1:0]                BRESP,      //+
    // Read Address Channel
    input [31:0]                ARADDR,     // adresin en anlamli 8 biti hangi islemin gerceklestirilecegine karar vermek icin kullaniliyor 
    input                       ARVALID,
    input [2:0]                 ARPROT,
    output                      ARREADY,    //+
    // Read Data Channel        // okuma isteg, buradan gelcek
    input                       RREADY,
    output [31:0]               RDATA,      //+
    output                      RVALID,     //+
    output [1:0]                RRESP,      //+
    // spi i/o
    input               in_so,
    output              out_si,
    output              out_cs,
    output              out_sck
    );
    localparam [2:0]
       IDLE = 3'b001,
       WRITE= 3'b010,
       READ = 3'b100 ;
    
    //spi i/o registers
    reg r_cs, r_cs_next;
    reg r_sck, r_sck_next;
    
    reg [2:0]       state, state_next;
    reg [9:0]       clock_ctr, clock_ctr_next;
    reg [9:0]       bit_ctr, bit_ctr_next;
    reg             busy, busy_next;
    reg             valid, valid_next; // AXI arayuzu icin
    
    reg [`FIFO_DEPTH-1:0]  fifo, fifo_next;  
    // i/o shift register.
    assign in_si = fifo[`FIFO_DEPTH-1];
    
    assign RDATA = fifo;
    assign RVALID= valid;
    
    always@* begin
        state_next      = state;
        clock_ctr_next  = clock_ctr;
        bit_ctr_next    = bit_ctr;
        busy_next       = busy;
        valid_next      = valid;
        fifo_next       = fifo;
        
        r_cs_next       = r_cs;
        r_sck_next      = r_sck;
        if(clock_ctr > 0) begin
            clock_ctr_next  = clock_ctr - 10'd1;
        end
        else if(clock_ctr == 10'd0) begin
            case(state)
            
            IDLE: // IDLE
            begin
                 if (!busy && (AWADDR[26] || AWADDR[24])) begin // yazma-write istegi, input 
                    clock_ctr_next  = `PRESCALE - 10'd1;
                    bit_ctr_next    = AWADDR[28] ? 10'd16 : 10'd8;  //(10'd8 * {AWADDR[29:27]}) - 10'd1; // carpma kullanmadan da yapilabilir.      
                    state_next      = WRITE;
                    fifo_next       = AWADDR[15:0];
                    busy_next       = 1'b1;
                    
                    r_cs_next       = 1'b0;
                    r_sck_next      = 1'b0;
                 end
                 else begin
                    clock_ctr_next  = 10'b0;
                    state_next      = IDLE;
                    busy_next       = 1'b0;
                    valid_next      = 1'b0;
                    
                    r_cs_next       = 1'b1;
                    r_sck_next      = 1'b0; 
                 end
            end
            
            WRITE: // yazma islemi
            begin
                if(bit_ctr == 10'd0) begin
                    state_next      = IDLE;
                    clock_ctr_next  = 10'd0;
                    valid_next      = 1'b1;
                    busy_next       = 1'b0;
                end
                else begin
                    r_sck_next  = ~r_sck_next;
                    state_next  = WRITE;
                    if(!r_sck) begin
                        bit_ctr_next    = bit_ctr - 10'd1;
                        fifo_next       = {fifo[`FIFO_DEPTH-2:0], 1'b0};
                    end
                end
            end
            
            READ: // islem
            begin
                if(bit_ctr == 10'd0) begin
                    state_next      = IDLE;
                    clock_ctr_next  = 10'd0;
                    valid_next      = 1'b1;
                    busy_next       = 1'b0;
                end
                else begin
                    r_sck_next  = ~r_sck_next;
                    state_next  = WRITE;
                    if(!r_sck) begin
                        bit_ctr_next    = bit_ctr - 10'd1;
                        fifo_next       = {fifo[`FIFO_DEPTH-2:0], in_so};
                    end
                end
            end
            
            endcase
        end
    end
    
    always@(posedge ACLK) begin
        if(ARESET) begin
            state   <= 3'b001;
            clock_ctr<= 10'd0;
            bit_ctr <= 10'd0;
            busy    <= 1'b0;
            valid   <= 1'b0;
            fifo    <= {`FIFO_DEPTH {1'b0}};
            r_cs    <= 1'b1;
            r_sck   <= 1'b0;
        end
        else begin
            state   <=  state_next;
            clock_ctr<=  clock_ctr_next;
            bit_ctr <=  bit_ctr_next;
            busy    <=  busy_next;
            valid   <=  valid_next;
            fifo    <=  fifo_next;
            r_cs    <=  r_cs_next;
            r_sck   <=  r_sck_next;
        end
        
    end
    
endmodule