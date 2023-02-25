//
// KFMMC_Interface
// Access to MMC
//
// Written by kitune-san
//
module KFMMC_Interface #(
    parameter timeout = 32'hFFFFFFFF
) (
    input   logic           clock,
    input   logic           reset,

    input   logic           start_communication,
    input   logic           command_io,
    input   logic           data_io,
    input   logic           check_command_start_bit,
    input   logic           check_data_start_bit,
    input   logic           read_continuous_data,
    input   logic           clear_command_crc,
    input   logic           clear_data_crc,
    input   logic           clear_command_interrupt,
    input   logic           clear_data_interrupt,
    input   logic           mask_command_interrupt,
    input   logic           mask_data_interrupt,
    input   logic           set_send_command,
    input   logic   [7:0]   send_command,
    input   logic           set_send_data,
    input   logic   [7:0]   send_data,

    output  logic   [7:0]   received_response,
    output  logic   [6:0]   send_command_crc,
    output  logic   [6:0]   received_response_crc,
    output  logic   [7:0]   received_data,
    output  logic   [15:0]  send_data_crc,
    output  logic   [15:0]  received_data_crc,

    output  logic           in_connecting,
    output  logic           sent_command_interrupt,
    output  logic           received_response_interrupt,
    output  logic           sent_data_interrupt,
    output  logic           received_data_interrupt,
    output  logic           timeout_interrupt,

    input   logic   [7:0]   mmc_clock_cycle,
    output  logic           mmc_clk,
    input   logic           mmc_cmd_in,
    output  logic           mmc_cmd_out,
    output  logic           mmc_cmd_io,
    input   logic           mmc_dat_in,
    output  logic           mmc_dat_out,
    output  logic           mmc_dat_io
);

    //
    // Internal signals
    //
    logic   [7:0]   clk_cycle_counter;
    logic           edge_mmc_clk;
    logic           sample_edge;
    logic           shift_edge;

    logic           detect_command_start_bit;
    logic   [3:0]   command_bit_count;
    logic   [8:0]   rx_cmd_register;
    logic   [7:0]   tx_cmd_register;

    logic           detect_data_start_bit;
    logic   [3:0]   data_bit_count;
    logic   [8:0]   rx_data_register;
    logic   [7:0]   tx_data_register;

    logic   [31:0]  timeout_counter;

    logic           mask_command_interrupt_ff;
    logic           mask_data_interrupt_ff;

    logic           disable_access;
    logic           access_flag;

    //
    // Calculate CRC
    //
    // CRC-7
    function logic [6:0] crc_7 (input data_in, input [6:0] prev_crc);
        crc_7[0] = prev_crc[6] ^ data_in;
        crc_7[1] = prev_crc[0];
        crc_7[2] = prev_crc[1];
        crc_7[3] = prev_crc[2] ^ (prev_crc[6] ^ data_in);
        crc_7[4] = prev_crc[3];
        crc_7[5] = prev_crc[4];
        crc_7[6] = prev_crc[5];
    endfunction

    // CRC-16
    function logic [15:0] crc_16 (input data_in, input [15:0] prev_crc);
        crc_16[0]  = prev_crc[15] ^ data_in;
        crc_16[1]  = prev_crc[0];
        crc_16[2]  = prev_crc[1];
        crc_16[3]  = prev_crc[2];
        crc_16[4]  = prev_crc[3];
        crc_16[5]  = prev_crc[4] ^ (prev_crc[15] ^ data_in);
        crc_16[6]  = prev_crc[5];
        crc_16[7]  = prev_crc[6];
        crc_16[8]  = prev_crc[7];
        crc_16[9]  = prev_crc[8];
        crc_16[10] = prev_crc[9];
        crc_16[11] = prev_crc[10];
        crc_16[12] = prev_crc[11] ^ (prev_crc[15] ^ data_in);
        crc_16[13] = prev_crc[12];
        crc_16[14] = prev_crc[13];
        crc_16[15] = prev_crc[14];
    endfunction

    //
    // MMC CLK
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            clk_cycle_counter <= 8'd01;
        else if (access_flag)
            if (edge_mmc_clk)
                clk_cycle_counter <= 8'd01;
            else
                clk_cycle_counter <= clk_cycle_counter + 8'd01;
        else
            clk_cycle_counter <= 8'd01;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            mmc_clk <= 1'b0;
        else if (access_flag)
            if (edge_mmc_clk)
                mmc_clk <= ~mmc_clk;
            else
                mmc_clk <=  mmc_clk;
        else
            mmc_clk <= 1'b0;
    end

    assign edge_mmc_clk = (clk_cycle_counter == {1'b0, mmc_clock_cycle[7:1]}) & (access_flag);
    assign sample_edge  = (edge_mmc_clk) & (mmc_clk == 1'b0); // 0 -> 1
    assign shift_edge   = (edge_mmc_clk) & (mmc_clk == 1'b1); // 1 -> 0

    //
    // Command I/O
    //
    // MMC_CMD I/O
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            mmc_cmd_io <= 1'b1;
        else if (start_communication)
            mmc_cmd_io <= command_io;
        else
            mmc_cmd_io <= mmc_cmd_io;
    end

    // Detect start bit
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            detect_command_start_bit <= 1'b0;
        else if (start_communication)
            if (mmc_cmd_io != command_io)
                detect_command_start_bit <= 1'b0;
            else if ((command_io == 1'b1) && (check_command_start_bit))
                detect_command_start_bit <= 1'b0;
            else
                detect_command_start_bit <= detect_command_start_bit;
        else if ((mmc_cmd_io == 1'b1) && (sample_edge) && (~mmc_cmd_in))
            detect_command_start_bit <= 1'b1;
        else
            detect_command_start_bit <= detect_command_start_bit;
    end

    // Bit count
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            command_bit_count <= 4'd00;
        else if (start_communication)
            if (mmc_cmd_io != command_io)
                command_bit_count <= 4'd00;
            else if ((command_io == 1'b1) && (check_command_start_bit))
                command_bit_count <= 4'd00;
            else if ((command_io == 1'b0) && (set_send_command))
                command_bit_count <= 4'd00;
            else if (command_bit_count == 4'd08)
                command_bit_count <= 4'd00;
            else
                command_bit_count <= command_bit_count;
        else if (mmc_cmd_io == 1'b1)
            if ((sample_edge) && (detect_command_start_bit))
                command_bit_count <= command_bit_count + 4'd01;
            else if ((sample_edge) && (~mmc_cmd_in))
                command_bit_count <= 4'd01;
            else
                command_bit_count <= command_bit_count;
        else
            if (sample_edge)
                command_bit_count <= command_bit_count + 4'd01;
            else
                command_bit_count <= command_bit_count;
    end

    // Receive command register
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            rx_cmd_register <= 9'h000;
        else if (sample_edge)
            rx_cmd_register <= {rx_cmd_register[8:1], mmc_cmd_in};
        else if (shift_edge)
            rx_cmd_register <= {rx_cmd_register[7:0], 1'b0};
        else
            rx_cmd_register <= rx_cmd_register;
    end

    assign  received_response = rx_cmd_register[8:1];

    // Send command register
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            tx_cmd_register <= 8'h00;
        else if ((start_communication) && (set_send_command))
            tx_cmd_register <= send_command;
        else if (shift_edge)
            tx_cmd_register <= {tx_cmd_register[6:0], 1'b1};
        else
            tx_cmd_register <= tx_cmd_register;
    end

    always_comb begin
        if (mmc_cmd_io == 1'b1)
            mmc_cmd_out = 1'b1;
        else
            mmc_cmd_out = tx_cmd_register[7];
    end

    // Sent command interrupt
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            sent_command_interrupt <= 1'b0;
        else if (mmc_cmd_io == 1'b1)
            sent_command_interrupt <= 1'b0;
        else if ((start_communication) && (clear_command_interrupt))
            sent_command_interrupt <= 1'b0;
        else if ((command_bit_count == 4'd8) && (shift_edge))
            sent_command_interrupt <= 1'b1;
        else
            sent_command_interrupt <= sent_command_interrupt;
    end

    // Received response interrupt
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            received_response_interrupt <= 1'b0;
        else if (mmc_cmd_io == 1'b0)
            received_response_interrupt <= 1'b0;
        else if ((start_communication) && (clear_command_interrupt))
            received_response_interrupt <= 1'b0;
        else if ((command_bit_count == 4'd8) && (shift_edge))
            received_response_interrupt <= 1'b1;
        else
            received_response_interrupt <= received_response_interrupt;
    end

    // Calculate crc of sent command
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            send_command_crc <= 7'b0000000;
        else if (clear_command_crc)
            send_command_crc <= 7'b0000000;
        else if (mmc_cmd_io == 1'b1)
            send_command_crc <= 7'b0000000;
        else if (sample_edge)
            send_command_crc <= crc_7(tx_cmd_register[7], send_command_crc);
        else
            send_command_crc <= send_command_crc;
    end

    // Calculate crc of received response
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            received_response_crc <= 7'b0000000;
        else if (clear_command_crc)
            received_response_crc <= 7'b0000000;
        else if (mmc_cmd_io == 1'b0)
            received_response_crc <= 7'b0000000;
        else if ((sample_edge) && (detect_command_start_bit))
            received_response_crc <= crc_7(mmc_cmd_in, received_response_crc);
        else
            received_response_crc <= received_response_crc;
    end

    //
    // Data I/O
    //
    // MMC_DAT I/O
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            mmc_dat_io <= 1'b1;
        else if (start_communication)
            mmc_dat_io <= data_io;
        else
            mmc_dat_io <= mmc_dat_io;
    end

    // Detect start bit
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            detect_data_start_bit <= 1'b0;
        else if (start_communication)
            if (mmc_dat_io != data_io)
                detect_data_start_bit <= 1'b0;
            else if ((data_io == 1'b1) && (check_data_start_bit))
                detect_data_start_bit <= 1'b0;
            else if ((data_io == 1'b1) && (read_continuous_data))
                detect_data_start_bit <= 1'b1;
            else
                detect_data_start_bit <= detect_data_start_bit;
        else if ((mmc_dat_io == 1'b1) && (sample_edge) && (~mmc_dat_in))
            detect_data_start_bit <= 1'b1;
        else
            detect_data_start_bit <= detect_data_start_bit;
    end

    // Bit count
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            data_bit_count <= 4'd00;
        else if (start_communication)
            if (mmc_dat_io != data_io)
                data_bit_count <= 4'd00;
            else if ((data_io == 1'b1) && (check_data_start_bit))
                data_bit_count <= 4'd00;
            else if ((data_io == 1'b0) && (set_send_data))
                data_bit_count <= 4'd00;
            else if (data_bit_count == 4'd08)
                data_bit_count <= 4'd00;
            else
                data_bit_count <= data_bit_count;
        else if (mmc_dat_io == 1'b1)
            if ((sample_edge) && (detect_data_start_bit))
                data_bit_count <= data_bit_count + 4'd01;
            else if ((sample_edge) && (mmc_dat_in))
                data_bit_count <= 4'd00;
            else
                data_bit_count <= data_bit_count;
        else
            if (sample_edge)
                data_bit_count <= data_bit_count + 4'd01;
            else
                data_bit_count <= data_bit_count;
    end

    // Receive data register
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            rx_data_register <= 9'h000;
        else if (sample_edge)
            rx_data_register <= {rx_data_register[8:1], mmc_dat_in};
        else if (shift_edge)
            rx_data_register <= {rx_data_register[7:0], 1'b0};
        else
            rx_data_register <= rx_data_register;
    end

    assign  received_data = rx_data_register[8:1];

    // Send data register
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            tx_data_register <= 8'h00;
        else if ((start_communication) && (set_send_data))
            tx_data_register <= send_data;
        else if (shift_edge)
            tx_data_register <= {tx_data_register[6:0], 1'b1};
        else
            tx_data_register <= tx_data_register;
    end

    always_comb begin
        if (mmc_dat_io == 1'b1)
            mmc_dat_out = 1'b1;
        else
            mmc_dat_out = tx_data_register[7];
    end

    // Sent data interrupt
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            sent_data_interrupt <= 1'b0;
        else if (mmc_dat_io == 1'b1)
            sent_data_interrupt <= 1'b0;
        else if ((start_communication) && (clear_data_interrupt))
            sent_data_interrupt <= 1'b0;
        else if ((data_bit_count == 4'd8) && (shift_edge))
            sent_data_interrupt <= 1'b1;
        else
            sent_data_interrupt <= sent_data_interrupt;
    end

    // Received data interrupt
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            received_data_interrupt <= 1'b0;
        else if (mmc_dat_io == 1'b0)
            received_data_interrupt <= 1'b0;
        else if ((start_communication) && (clear_data_interrupt))
            received_data_interrupt <= 1'b0;
        else if ((data_bit_count == 4'd8) && (shift_edge))
            received_data_interrupt <= 1'b1;
        else
            received_data_interrupt <= received_data_interrupt;
    end

    // Calculate crc of sent data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            send_data_crc <= 16'h0000;
        else if (clear_data_crc)
            send_data_crc <= 16'h0000;
        else if (mmc_dat_io == 1'b1)
            send_data_crc <= 16'h0000;
        else if (sample_edge)
            send_data_crc <= crc_16(tx_data_register[7], send_data_crc);
        else
            send_data_crc <= send_data_crc;
    end

    // Calculate crc of received data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            received_data_crc <= 16'h0000;
        else if (clear_data_crc)
            received_data_crc <= 16'h0000;
        else if (mmc_dat_io == 1'b0)
            received_data_crc <= 16'h0000;
        else if ((sample_edge) && (detect_data_start_bit))
            received_data_crc <= crc_16(mmc_dat_in, received_data_crc);
        else
            received_data_crc <= received_data_crc;
    end

    //
    // Time out counter
    //
    // Counter of timerout
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            timeout_counter <= timeout;
        else if (start_communication)
            timeout_counter <= timeout;
        else if ((timeout_counter != 32'h00000000) && (sample_edge))
            timeout_counter <= timeout_counter - 32'h00000001;
        else
            timeout_counter <= timeout_counter;
    end

    // Timeout interrupt
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            timeout_interrupt <= 1'b1;
        else if (start_communication)
            timeout_interrupt <= 1'b0;
        else if ((timeout_counter == 32'h00000000) && (shift_edge))
            timeout_interrupt <= 1'b1;
        else
            timeout_interrupt <= timeout_interrupt;
    end

    //
    // Interrupt mask
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            mask_command_interrupt_ff <= 1'b0;
            mask_data_interrupt_ff    <= 1'b0;
        end
        else if ((~access_flag) || (shift_edge)) begin
            mask_command_interrupt_ff <= mask_command_interrupt;
            mask_data_interrupt_ff    <= mask_data_interrupt;
        end
        else begin
            mask_command_interrupt_ff <= mask_command_interrupt_ff;
            mask_data_interrupt_ff    <= mask_data_interrupt_ff;
        end
    end

    //
    // access flag
    //
    assign  disable_access  = mask_command_interrupt_ff & mask_command_interrupt_ff & mask_data_interrupt_ff & mask_data_interrupt_ff;
    assign  in_connecting   = ~((sent_command_interrupt      & ~mask_command_interrupt_ff) |
                                (received_response_interrupt & ~mask_command_interrupt_ff) |
                                (sent_data_interrupt         & ~mask_data_interrupt_ff)    |
                                (received_data_interrupt     & ~mask_data_interrupt_ff)    |
                                timeout_interrupt | disable_access);
    assign  access_flag     = in_connecting & ~start_communication & ~disable_access;
endmodule

