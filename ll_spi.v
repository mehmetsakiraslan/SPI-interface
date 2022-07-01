`timescale 1ns / 1ps

`ifndef GL_RTL_SIM
`include "sabitler.vh"
`endif

`define PRESCALE        16'd5
`define FIFO_DEPTH      `ADRES_BIT


module ll_spi (
    // Global Signals
    input                       clk_g,
    input                       rst_g,
   
    input  [`ADRES_BIT - 1:0]   at_adres_c,                                     
    output [31:0]               at_oku_veri_g,                                   
    output                      at_oku_gecerli_g, // =valid.                                
    input  [31:0]               at_yaz_veri_c,                                   
    input                       at_yaz_gecerli_c,                                
    input                       at_gecerli_c,                                    
    output                      at_mesgul_g,                                      
    
    // spi i/o
    input               in_so,
    output              out_si,
    output              out_cs,
    output              out_sck
    );
    
    reg [31:0] miso_buffer [7:0];
    reg [31:0] miso_buffer_next [7:0];
    //reg [3:0] miso_head, miso_head_next;
    reg [3:0] miso_tail, miso_tail_next;
    
    reg [31:0] mosi_buffer [7:0];
    reg [31:0] mosi_buffer_next [7:0];
    //reg [3:0] mosi_head, mosi_head_next;
    reg [3:0] mosi_tail, mosi_tail_next;
    
    reg [31:0] spi_ctrl, spi_ctrl_next;
    
    // reg [3:0] spi_status, spi_status_next;
    
    reg [`FIFO_DEPTH-1:0]  spi_rdata, spi_rdata_next; // fifo in
     
    reg [`FIFO_DEPTH:0]  spi_wdata, spi_wdata_next; // fifo out   
 
    
    reg [13:0] spi_cmd, spi_cmd_next;
    
    // Kontrol Sinyalleri
    wire spi_en;
    assign spi_en = spi_ctrl[0];
    
    wire spi_rst;
    assign spi_rst = spi_ctrl[1];
    
    wire cpha; // cpha 1'se veri düsen kenarda latchlenicek
    assign cpha = spi_ctrl[2];
    
    wire cpol; // eger cpol ve spi_en'in ayni anda kontrol edildigi durumlar varsa ilk sck yukselen kenarinin yok sayilmasi icin flag ekle 
    assign cpol = spi_ctrl[3];
    
    wire [15:0] sck_div;
    assign sck_div = spi_ctrl[31:16];
    
    wire [11:0] lenght;
    assign lenght = spi_cmd[8:0]; 
    
    wire cs_active;
    assign cs_active = spi_cmd[9];
    
    // wire [1:0] direction;
    // assign direction = spi_cmd[13:12];
    
    wire miso_en;
    assign miso_en = spi_cmd[12];
    
    wire mosi_en;
    assign mosi_en = spi_cmd[13];
    
    wire mosi_full;
    assign mosi_full = (mosi_tail == 4'd8); // spi_status[0];
    
    wire miso_full;
    assign miso_full = (miso_tail == 4'd8); // spi_status[1];
    
    wire mosi_empty;
    assign mosi_empty = (mosi_tail == 4'd0); // spi_status[2];
    
    wire miso_empty;
    assign miso_empty = (miso_tail == 4'd0); // spi_status[3];
    
    
    
    localparam [4:0]
       CTRL = 5'h00,
       STATUS = 5'h04,
       RDATA = 5'h08,
       WDATA = 5'h0c,
       CMD = 5'h10;
    
    
    localparam [2:0]
       IDLE = 3'b001,
       WRITE = 3'b010,
       READ = 3'b100;
           
    reg r_cs, r_cs_next;
    reg r_sck, r_sck_next;
    reg r_spi_sr, r_spi_sr_next;   // 1 i_clk cycle retarted sck to prevent race conditions while driving slave device,
                                     // would not work if prescale is 1.
    reg [2:0] state, state_next; 
    reg [15:0] clock_ctr, clock_ctr_next;
    reg [11:0] bit_ctr, bit_ctr_next;
    reg valid, valid_next; 
    reg busy, busy_next;
    
    reg [11:0] bit_ctr_reg, bit_ctr_reg_next; // 32 bitten daha cok gonderim yapilacagi durumlarda kullanilacak
    reg read_flag, read_flag_next;
    reg write_flag, write_flag_next;
    
    
    assign out_cs = r_cs;
    assign out_sck = cpha ? ~r_spi_sr : r_spi_sr;
    assign out_si = spi_wdata[32];
    assign at_oku_veri_g = spi_rdata;
    assign at_mesgul_g = busy;
    assign at_oku_gecerli_g = valid;
    
    
    integer loop_counter;
    always@* begin
        for(loop_counter=0; loop_counter<8; loop_counter=loop_counter+1) begin  
            miso_buffer_next[loop_counter] = miso_buffer[loop_counter];
        end
        miso_tail_next = miso_tail;
        for(loop_counter=0; loop_counter<8; loop_counter=loop_counter+1) begin  
            mosi_buffer_next[loop_counter] = mosi_buffer[loop_counter];
        end
        mosi_tail_next = mosi_tail;
        spi_ctrl_next = spi_ctrl;
        // spi_status_next = spi_status;
        spi_rdata_next = spi_rdata;
        spi_wdata_next = spi_wdata;
        spi_cmd_next = spi_cmd;
 
        r_cs_next = r_cs;
        r_sck_next = r_sck;
        r_spi_sr_next = r_sck;
        state_next = state;
        clock_ctr_next = clock_ctr;
        bit_ctr_next = bit_ctr;
        valid_next = valid;
        busy_next = busy;
        
        bit_ctr_reg_next = bit_ctr_reg;        
        read_flag_next = read_flag;
        write_flag_next = write_flag;
        
        if(clock_ctr > 0) begin
            clock_ctr_next  = clock_ctr - 16'd1;
        end
        else if((clock_ctr == 16'd0)) begin
            valid_next = 1'b0;
            case(state)
            
            IDLE: // IDLE: her cycle kontrol yazmaci degerlerine gore seri iletim gerceklesicek
            begin
                if((!read_flag && spi_en && mosi_en && (!miso_en) && (!mosi_empty)) || write_flag) begin // si -> yaz 
                    clock_ctr_next = sck_div;
                    //bit_ctr_next = lenght<<3;
                    //bit_ctr_reg_next = (lenght-12'd32);
                    state_next = WRITE;
                    
                    spi_wdata_next = {1'b0, mosi_buffer[0]};
                    r_sck_next = 1'b0;
                    r_cs_next = 1'b0;
                    
                    bit_ctr_next = (bit_ctr_reg >= 12'd32) ? 12'd32 : bit_ctr_reg;
                    //bit_ctr_reg_next = (lenght-12'd32);
                    write_flag_next = 1'b0;
                    
                     
                end
                else if((!write_flag && spi_en && miso_en && (!mosi_en) && (!miso_full)) || read_flag) begin // so -> oku
                    clock_ctr_next = sck_div;
                    //bit_ctr_next = lenght<<3;
                    //bit_ctr_reg_next = (lenght-12'd32);
                    state_next = READ;
                    
                    r_sck_next = 1'b0;
                    r_cs_next = 1'b0;
                    
                    bit_ctr_next = (bit_ctr_reg >= 12'd32) ? 12'd32 : bit_ctr_reg;
                    //bit_ctr_reg_next = (lenght-12'd32);
                    read_flag_next = 1'b0;
                end
                else begin
                    clock_ctr_next = 16'd0;
                    state_next = IDLE;
                    
                    r_sck_next = cpol;
                    bit_ctr_reg_next = lenght<<3;
                end
            end
            
            READ: 
            begin
                clock_ctr_next  = sck_div;
                if(bit_ctr == 12'd0) begin
                    state_next = IDLE;
                    clock_ctr_next = 16'd0;
                    
                    miso_buffer_next[miso_tail] = spi_rdata;
                    spi_rdata_next = 32'd0;
                    miso_tail_next = miso_tail + 4'd1;
                    
                    r_cs_next = cs_active ? 1'b0 : 1'b1;
                    r_sck_next = 1'b0;
                    if(bit_ctr_reg > 12'd32)begin
                        bit_ctr_reg_next = bit_ctr_reg - 12'd32;
                        read_flag_next = 1'b1;
                        r_cs_next = 1'b0;
                    end
                    else begin
                        bit_ctr_reg_next = lenght<<3;
                        read_flag_next = 1'b0;
                    end
                end
                else begin
                    r_sck_next  = ~r_sck_next;
                    state_next = READ;
                    if(!r_sck) begin
                        bit_ctr_next    = bit_ctr - 12'd1;
                        spi_rdata_next       = {spi_rdata[`FIFO_DEPTH-2:0], in_so};
                    end
                end
            end
            
            WRITE: 
            begin
                clock_ctr_next  = sck_div;
                if(bit_ctr == 12'd0) begin
                   state_next = IDLE;
                   clock_ctr_next = 16'd0;
                   
                   mosi_buffer_next[0] = mosi_buffer[1];
                   mosi_buffer_next[1] = mosi_buffer[2];
                   mosi_buffer_next[2] = mosi_buffer[3];
                   mosi_buffer_next[3] = mosi_buffer[4];
                   mosi_buffer_next[4] = mosi_buffer[5];
                   mosi_buffer_next[5] = mosi_buffer[6];
                   mosi_buffer_next[6] = mosi_buffer[7];
                   mosi_buffer_next[7] = 32'd0;
                   
                   mosi_tail_next = mosi_tail - 4'd1;
                   
                   r_cs_next = cs_active ? 1'b0 : 1'b1;
                   r_sck_next = 1'b0;
                   if(bit_ctr_reg > 12'd32)begin
                        bit_ctr_reg_next = bit_ctr_reg - 12'd32;
                        write_flag_next = 1'b1;
                        r_cs_next = 1'b0;
                    end
                    else begin
                        bit_ctr_reg_next = lenght<<3;
                        write_flag_next = 1'b0;
                    end
                end
                else begin
                    r_sck_next  = ~r_sck_next;
                    state_next = WRITE;
                    if(!r_sck) begin
                        bit_ctr_next = bit_ctr - 12'd1;
                        spi_wdata_next = {spi_wdata[`FIFO_DEPTH-1:0], 1'b0};
                    end
                end
            end
            
            endcase
            
            
            
            case(at_adres_c[4:0])      
            
            STATUS: // Sadece okuma yazmaci
            begin
                spi_rdata_next = {miso_empty, mosi_empty, miso_full, mosi_full};
                valid_next = 1'b1;
            end
            
            CTRL: 
            begin
                if(at_yaz_gecerli_c && at_gecerli_c) begin
                    spi_ctrl_next = at_yaz_veri_c;// && 32'hFFFF000F;
                end
                else begin
                    spi_rdata_next = spi_ctrl;
                end
                valid_next = 1'b1;
            end 
            
            CMD: 
            begin
                if(at_yaz_gecerli_c && at_gecerli_c) begin
                    spi_cmd_next = at_yaz_veri_c;//&& 32'h000031FF; // 0011_0011_1111_1111 *********************************** mask yanli
                end
                else if(at_gecerli_c) begin
                    spi_rdata_next = spi_cmd;
                    
                end             
            end 
            
            RDATA: 
            begin
                if(!miso_empty) begin
                    spi_rdata_next = miso_buffer[0];
                    valid_next = 1'b1;
                    
                    miso_buffer_next[0] = miso_buffer[1];
                    miso_buffer_next[1] = miso_buffer[2];
                    miso_buffer_next[2] = miso_buffer[3];
                    miso_buffer_next[3] = miso_buffer[4];
                    miso_buffer_next[4] = miso_buffer[5];
                    miso_buffer_next[5] = miso_buffer[6];
                    miso_buffer_next[6] = miso_buffer[7];
                    miso_buffer_next[7] = 32'd0;
                    
                    miso_tail_next = miso_tail - 4'd1;
                    valid_next = 1'b1;
                end 
                else begin
                    valid_next = 1'b0;
                end
            end
            
            WDATA: 
            begin
                if(!mosi_full) begin
                    mosi_buffer_next[mosi_tail] = at_yaz_veri_c;
                    mosi_tail_next = mosi_tail + 4'b1;
                    
                    valid_next = 1'b1;
                end
                else begin
                    valid_next = 1'b0;
                end
            end
            endcase
        end  
    end
    
    always@(posedge clk_g) begin
        if(spi_rst || rst_g) begin
            for(loop_counter=0; loop_counter<8; loop_counter=loop_counter+1) begin  
            miso_buffer[loop_counter] <= 32'd0;
            end
            miso_tail <= 4'd0;
            for(loop_counter=0; loop_counter<8; loop_counter=loop_counter+1) begin  
                mosi_buffer[loop_counter] <= 32'd0;
            end
            mosi_tail <= 4'd0;
            spi_ctrl <= 32'd0;
            // spi_status_next = 4'd0;
            spi_rdata <= 32'd0;
            spi_wdata <= 33'd0;
            spi_cmd <= 14'd0;
 
            r_cs <= 1'b1;
            r_sck <= 1'b0;
            r_spi_sr <= 1'b0;
            state <= 3'b001;
            clock_ctr <= 16'd0;
            bit_ctr <= 12'd0;
            valid <= 1'b0;
            busy <= 1'b0;
            bit_ctr_reg <= 12'd0;
            read_flag <= 1'b0;
            write_flag <= 1'b0;
        end
        else begin
            for(loop_counter=0; loop_counter<8; loop_counter=loop_counter+1) begin  
            miso_buffer[loop_counter] <= miso_buffer_next[loop_counter];
            end
            miso_tail <= miso_tail_next;
            for(loop_counter=0; loop_counter<8; loop_counter=loop_counter+1) begin  
                mosi_buffer[loop_counter] <= mosi_buffer_next[loop_counter];
            end
            mosi_tail <= mosi_tail_next;
            spi_ctrl <= spi_ctrl_next;
            // spi_status_next = 4'd0;
            spi_rdata <= spi_rdata_next;
            spi_wdata <= spi_wdata_next;
            spi_cmd <= spi_cmd_next;
 
            r_cs <= r_cs_next;
            r_sck <= r_sck_next;
            r_spi_sr <= r_spi_sr_next;
            state <= state_next;
            clock_ctr <= clock_ctr_next;
            bit_ctr <= bit_ctr_next;
            valid <= valid_next;
            busy <= busy_next;
            bit_ctr_reg <= bit_ctr_reg_next;
            read_flag <= read_flag_next;
            write_flag <= write_flag_next;
        end
        
    end
    
endmodule
