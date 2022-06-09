`timescale 1ns / 1ps

`ifndef GL_RTL_SIM
`include "sabitler.vh"
`endif

`define PRESCALE        10'd5
`define FIFO_DEPTH      `ADRES_BIT


module ll_spi (
    // AXI4 LITE SLAVE signals
    // Global Signals
    input                       ACLK,
    input                       ARESET,
    // Write Address Channel
    input [`ADRES_BIT - 1:0]    AWADDR,
    input                       AWVALID,
    output                      AWREADY,
    // Write Data Channel
    input [`VERI_BIT - 1:0]     WDATA,
    input                       WVALID,
    output                      WREADY,
    // Write Response Channel
    input                       BREADY,
    output                      BVALID,
    // Read Address Channel
    input [`ADRES_BIT - 1:0]    ARADDR,
    input                       ARVALID,
    output                      ARREADY,
    // Read Data Channel
    input                       RREADY,
    output [`VERI_BIT - 1:0]    RDATA,
    output                      RVALID,

    // spi i/o
    input               in_so,
    output              out_si,
    output              out_cs,
    output              out_sck
    );
    
    reg [7:0] miso_buffer [31:0];
    reg [7:0] miso_buffer_next [31:0];
    
    reg [7:0 ]mosi_buffer [31:0];
    reg [7:0 ]mosi_buffer_next [31:0];
    
    localparam [2:0]
       IDLE = 3'b001,
       WRITE= 3'b010,
       READ = 3'b100 ;
    
    //spi i/o registers
    reg r_cs, r_cs_next;
    reg r_sck, r_sck_next;
    reg r_spi_sr, r_spi_sr_next;   // 1 i_clk cycle retarted sck to prevent race conditions while driving slave device,
                                     // would not work if prescale is 1.
    (*dont_touch = "true"*)  reg [2:0]       state; 
    reg [2:0] state_next;
    reg [9:0]       clock_ctr, clock_ctr_next;
    reg [9:0]       bit_ctr, bit_ctr_next;
    reg             valid, valid_next; // AXI arayuzu icin
    reg             valid_flag, valid_flag_next;
    reg             busy, busy_next;
    
    reg [`FIFO_DEPTH:0]  fifo, fifo_next;  
    
    reg read_flag, read_flag_next;
    reg [5:0] clock_reg, clock_reg_next; 

    
    assign out_cs = r_cs;
    assign out_sck= r_spi_sr;
    
    assign RDATA = fifo[`FIFO_DEPTH-1:0];
    assign RVALID= valid;
    assign BVALID= valid;
    
    assign ARREADY  = ~busy;
    assign WREADY   = ~busy;
    assign AWREADY  = ~busy;
    
    reg [4:0] ts_cycle, ts_cycle_next;
    
    // i/o shift register.
    assign out_si = fifo[ts_cycle];
    
    always@* begin
        state_next      = state;
        clock_ctr_next  = clock_ctr;
        bit_ctr_next    = bit_ctr;
        valid_next      = valid;
        busy_next       = busy;
        valid_flag_next = valid_flag;
        fifo_next       = fifo;
        
        read_flag_next  = read_flag; 
        ts_cycle_next   = ts_cycle;
        
        r_cs_next       = r_cs;
        r_sck_next      = r_sck;
        r_spi_sr_next   = r_sck;
        
        clock_reg_next  = clock_reg;
        
        if(clock_ctr > 0) begin
            clock_ctr_next  = clock_ctr - 10'd1;
        end
        else if(clock_ctr == 10'd0) begin
            case(state)
            
            IDLE: // IDLE
            begin
                if(!valid_flag) begin
                    if (~busy && AWADDR[24] && WVALID && AWVALID) begin // yazma-write istegi, input 
                        clock_ctr_next  = `PRESCALE - 10'd1;
                        bit_ctr_next    = AWADDR[4:0];      
                        state_next      = WRITE;
                        fifo_next       = WDATA;
                        busy_next       = 1'b1;
                        
                        ts_cycle_next   = AWADDR[4:0];
                        
                        r_cs_next       = 1'b0;
                        r_sck_next      = 1'b0;
                    end
                    else if(~busy && ARADDR[25] && ARVALID) begin
                        clock_ctr_next  = `PRESCALE - 10'd1;
                        bit_ctr_next    = ARADDR[11:6]; 
                        state_next      = WRITE;
                        busy_next       = 1'b1;
                        
                        fifo_next       = ARADDR[23:12]; 
                        read_flag_next  = 1'b1;
                        clock_reg_next  = ARADDR[5:0]; 
                        ts_cycle_next   = ARADDR[11:6];
                        
                        r_cs_next       = 1'b0;
                        r_sck_next      = 1'b0;
                    end
                    else begin
                        clock_ctr_next  = 10'b0;
                        state_next      = IDLE;
                        valid_next      = 1'b0;
                        busy_next       = 1'b0;
                        
                        r_cs_next       = 1'b1;
                        r_sck_next      = 1'b0; 
                    end
                end
                else begin
                    valid_flag_next = 1'b0;
                    valid_next      = 1'b1;
                    busy_next       = 1'b1;
                    r_sck_next      = 1'b0; 
                    clock_ctr_next  = `PRESCALE - 10'd1;//10'd0;
                    
                    r_cs_next       = 1'b1;
                    state_next      = IDLE;
                end
            end
            
            WRITE: // yazma islemi
            begin
                clock_ctr_next  = `PRESCALE - 10'd1;
                if(bit_ctr == 10'd0) begin
                    if(read_flag) begin
                        read_flag_next  = 1'b0;
                        state_next      = READ;
                        bit_ctr_next    = clock_reg;
                        ts_cycle_next   = clock_reg;
                        r_sck_next      = 1'b0;
                    end
                    else begin
                        state_next      = IDLE;
                        valid_flag_next = 1'b1; // valid birden fazla çevrim high'da kaliyor bunu kontrol et.
                        valid_next      = 1'b0;
                        //clock_ctr_next  = 10'd0;
                        r_cs_next       = 1'b0;
                        r_sck_next      = 1'b0;
                    end
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
                clock_ctr_next  = `PRESCALE - 10'd1;
                if(bit_ctr == 10'd0) begin
                    state_next      = IDLE;
                    
                    valid_flag_next = 1'b1;
                    valid_next      = 1'b0;
                    //clock_ctr_next  = 10'd0;
                    r_cs_next       = 1'b0;
                    r_sck_next      = 1'b0;
                end
                else begin
                    r_sck_next  = ~r_sck_next;
                    state_next  = READ;
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
            valid   <= 1'b0;
            busy    <= 1'b0;
            valid_flag<= 1'b0;
            fifo    <= {`FIFO_DEPTH {1'b0}};
            read_flag<= 1'b0;
            clock_reg <= 5'd0;
            ts_cycle <= 5'd0;
            r_cs    <= 1'b1;
            r_sck   <= 1'b0;
            r_spi_sr<= 1'b0;
        end
        else begin
            state   <=  state_next;
            clock_ctr<=  clock_ctr_next;
            bit_ctr <=  bit_ctr_next;
            valid   <=  valid_next;
            busy    <= busy_next;
            valid_flag<= valid_flag_next;
            fifo    <=  fifo_next;
            read_flag<= read_flag_next;
            clock_reg <= clock_reg_next;
            ts_cycle <= ts_cycle_next;
            r_cs    <=  r_cs_next;
            r_sck   <=  r_sck_next;
            r_spi_sr<= r_spi_sr_next;
        end
        
    end
    
endmodule
