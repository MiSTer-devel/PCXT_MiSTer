//
// KFMMC_Controller
// Written by kitune-san
//
module KFMMC_Controller #(
    parameter init_spi_clock_cycle = 8'd010,
    parameter normal_spi_clock_cycle = 8'd002,
    parameter access_block_size = 16'd512
) (
    input   logic           clock,
    input   logic           reset,

    // Internal bus
    input   logic   [7:0]   data_bus,
    input   logic   [24:0]  data_bus_extension,
    input   logic           write_block_address_1,
    input   logic           write_block_address_2,
    input   logic           write_block_address_3,
    input   logic           write_block_address_4,
    input   logic           write_block_address_extension,
    input   logic           write_access_command,
    input   logic           write_data,

    output  logic   [7:0]   read_data_byte,
    input   logic           read_data,

    // Control MMC signals
    // Output (to Command I/O)
    output  logic           reset_command_state,
    output  logic           start_command,
    output  logic   [47:0]  command,
    output  logic           enable_command_crc,
    output  logic           enable_response_crc,
    output  logic   [4:0]   response_length,
    // Input (from Command I/O)
    input   logic           command_busy,
    input   logic   [135:0] response,
    input   logic           response_error,
    // Output (to Data I/O)
    output  logic           disable_data_io,
    output  logic           start_data_io,
    output  logic           check_data_start_bit,
    output  logic           clear_data_crc,
    output  logic           data_io,
    output  logic   [7:0]   transmit_data,
    // Input (from Data I/O)
    input   logic           data_io_busy,
    input   logic   [7:0]   received_data,
    // Output (to MMC interface)
    output  logic   [7:0]   mmc_clock_cycle,
    // Input (from MMC interface)
    input   logic   [15:0]  send_data_crc,
    input   logic   [15:0]  received_data_crc,
    input   logic           timeout_interrupt,

    // State
    output  logic           drive_busy,
    output  logic   [39:0]  storage_size,

    // Error flags
    output  logic           read_interface_error,
    output  logic           read_crc_error,
    output  logic           write_interface_error,

    // External input/output
    output  logic           read_byte_interrupt,
    output  logic           read_completion_interrupt,
    output  logic           request_write_data_interrupt,
    output  logic           write_completion_interrupt
);

    // State
    typedef enum {
        INIT, RESET_CLK_1, RESET_CLK_2, SEND_CMD0, WAIT_TO_SEND_CMD0, SEND_DUMMY, WAIT_TO_SEND_DUMMY, SEND_CMD8,
        RESP_CMD8, SEND_CMD1, RESP_CMD1, SEND_CMD55, RESP_CMD55, SEND_ACMD41, RESP_ACMD41, SEND_CMD58, SEND_INITIALIZE_DUMMY,
        WAIT_TO_SEND_INITIALIZE_DUMMY, SEND_CMD2, RESP_CMD2, SEND_CMD3, RESP_CMD3, SEND_CMD9, RESP_CMD9, SEND_CMD7, RESP_CMD7,
        BUSY_WAIT_1, BUSY_WAIT_2, READY,
        // Read
        SEND_CMD17, READ_DATA_BLOCK, COMPLETE_TO_READ,
        // Write
        SEND_CMD24, RESP_CMD24, SEND_START_DATA_BIT, SEND_WRITE_DATA, WAIT_TO_SEND_WRITE_DATA,
        SEND_CRC_DATA, WAIT_TO_SEND_CRC_DATA, START_TO_RESV_CRC_STATUS, RECV_CRC_STATUS, COMPLETE_TO_WRITE
    } control_state_t;

    //
    // Internal signals
    //
    control_state_t control_state;
    control_state_t next_control_state;
    logic           busy;
    logic           error;
    logic   [3:0]   reset_pulse_count;
    logic           mmc_reset;
    logic           emmc_reset;

    logic           read_next_byte;

    logic           write_next_byte;
    logic   [7:0]   write_data_buffer;
    logic   [15:0]  write_data_crc;
    logic           send_crc_count;

    logic   [16:0]  access_count;

    logic   [32:0]  ocr;
    logic   [127:0] cid;
    logic   [15:0]  rca;
    logic   [127:0] csd;
    logic   [31:0]  block_address;

    //
    // State machine
    //
    always_comb begin
        next_control_state = control_state;

        case (control_state)
            INIT: begin
                if (~busy)
                    next_control_state = RESET_CLK_1;
            end
            RESET_CLK_1: begin
                if (busy)
                    next_control_state = RESET_CLK_2;
            end
            RESET_CLK_2: begin
                if (~busy)
                    if (reset_pulse_count != 4'd00)
                        next_control_state = RESET_CLK_1;
                    else
                        next_control_state = SEND_CMD0;
            end
            SEND_CMD0: begin
                if (busy)
                    next_control_state = WAIT_TO_SEND_CMD0;
            end
            WAIT_TO_SEND_CMD0: begin
                if (~busy)
                    next_control_state = SEND_DUMMY;
            end
            SEND_DUMMY: begin
                if (busy)
                    next_control_state = WAIT_TO_SEND_DUMMY;
            end
            WAIT_TO_SEND_DUMMY: begin
                if (~busy)
                    if (emmc_reset)
                        next_control_state = SEND_CMD0;
                    else if (mmc_reset)
                        next_control_state = SEND_CMD1;
                    else
                        next_control_state = SEND_CMD8;
            end
            SEND_CMD8: begin
                if (busy)
                    next_control_state = RESP_CMD8;
            end
            RESP_CMD8: begin
                if (error)
                    next_control_state = INIT;
                else if (~busy)
                    if (response[19:8] != 12'h1_AA)
                        next_control_state = INIT;
                    else
                        next_control_state = SEND_CMD55;
            end
            SEND_CMD1: begin
                if (busy)
                    next_control_state = RESP_CMD1;
            end
            RESP_CMD1: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    if (response[39] == 1'b0)
                        next_control_state = SEND_INITIALIZE_DUMMY;
                    else
                        next_control_state = SEND_CMD2;
            end
            SEND_CMD55: begin
                if (busy)
                    next_control_state = RESP_CMD55;
            end
            RESP_CMD55: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    next_control_state = SEND_ACMD41;
            end
            SEND_ACMD41: begin
                if (busy)
                    next_control_state = RESP_ACMD41;
            end
            RESP_ACMD41: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    if (response[39] == 1'b0)
                        next_control_state = SEND_INITIALIZE_DUMMY;
                    else
                        next_control_state = SEND_CMD2;
            end
            SEND_INITIALIZE_DUMMY: begin
                if (busy)
                    next_control_state = WAIT_TO_SEND_INITIALIZE_DUMMY;
            end
            WAIT_TO_SEND_INITIALIZE_DUMMY: begin
                if (~busy)
                    if (mmc_reset)
                        next_control_state = SEND_CMD1;
                    else
                        next_control_state = SEND_CMD55;
            end
            SEND_CMD2: begin
                if (busy)
                    next_control_state = RESP_CMD2;
            end
            RESP_CMD2: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    next_control_state = SEND_CMD3;
            end
            SEND_CMD3: begin
                if (busy)
                    next_control_state = RESP_CMD3;
            end
            RESP_CMD3: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    if (response[21] == 1'b1)
                        next_control_state = INIT;
                    else
                        next_control_state = SEND_CMD9;
            end
            SEND_CMD9: begin
                if (busy)
                    next_control_state = RESP_CMD9;
            end
            RESP_CMD9: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    next_control_state = SEND_CMD7;
            end
            SEND_CMD7: begin
                if (busy)
                    next_control_state = RESP_CMD7;
            end
            RESP_CMD7: begin
                if (error)
                    next_control_state = INIT;
                if (~busy)
                    if (response[27] == 1'b1)
                        next_control_state = INIT;
                    else
                        next_control_state = BUSY_WAIT_1;
            end
            BUSY_WAIT_1: begin
                if (busy)
                    next_control_state = BUSY_WAIT_2;
            end
            BUSY_WAIT_2: begin
                if (timeout_interrupt)
                    next_control_state = READY;
                else if (~busy)
                    if (received_data[0] == 1'b1)
                        next_control_state = READY;
                    else
                        next_control_state = BUSY_WAIT_1;
            end
            READY: begin
                if (write_access_command)
                    if (data_bus == 8'b10000000)       // Read command
                        next_control_state = SEND_CMD17;
                    else if (data_bus == 8'b10000001)  // Write command
                        next_control_state = SEND_CMD24;
            end

            //
            // Block read
            //
            SEND_CMD17: begin
                if (busy)
                    next_control_state = READ_DATA_BLOCK;
            end
            READ_DATA_BLOCK: begin
                if (~busy)
                    if (access_count == 16'h0000)
                        next_control_state = COMPLETE_TO_READ;
            end
            COMPLETE_TO_READ: begin
                if (read_data)
                    if (read_interface_error)
                        next_control_state = INIT;
                    else
                        next_control_state = BUSY_WAIT_1;
            end

            //
            // Write block
            //
            SEND_CMD24: begin
                if (busy)
                    next_control_state = RESP_CMD24;
            end
            RESP_CMD24: begin
                if ((~busy) || (error))
                    next_control_state = SEND_START_DATA_BIT;
            end
            SEND_START_DATA_BIT: begin
                if (busy)
                    next_control_state = WAIT_TO_SEND_WRITE_DATA;
            end
            SEND_WRITE_DATA: begin
                if (busy)
                    next_control_state = WAIT_TO_SEND_WRITE_DATA;
            end
            WAIT_TO_SEND_WRITE_DATA: begin
                if (~busy)
                    if (access_count != 16'h0000)
                        next_control_state = SEND_WRITE_DATA;
                    else
                        next_control_state = SEND_CRC_DATA;
            end
            SEND_CRC_DATA: begin
                if (busy)
                    next_control_state = WAIT_TO_SEND_CRC_DATA;
            end
            WAIT_TO_SEND_CRC_DATA: begin
                if (~busy)
                    if (send_crc_count != 1'b0)
                        next_control_state = SEND_CRC_DATA;
                    else
                        next_control_state = START_TO_RESV_CRC_STATUS;
            end
            START_TO_RESV_CRC_STATUS: begin
                if (busy)
                    next_control_state = RECV_CRC_STATUS;
            end
            RECV_CRC_STATUS: begin
                if ((~busy) || (error))
                    next_control_state = COMPLETE_TO_WRITE;
            end
            COMPLETE_TO_WRITE: begin
                if (read_data)
                    if (write_interface_error)
                        next_control_state = INIT;
                    else
                        next_control_state = BUSY_WAIT_1;
            end
            default: begin
                next_control_state = INIT;
            end
        endcase
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            control_state <= INIT;
        else
            control_state <= next_control_state;
    end


    //
    // Control signals
    //
    always_comb begin
        reset_command_state     = 1'b0;
        start_command           = 1'b0;
        command                 = 48'hFF_FF_FF_FF_FF_FF;
        enable_command_crc      = 1'b0;
        enable_response_crc     = 1'b0;
        response_length         = 5'd0;

        disable_data_io         = 1'b1;
        start_data_io           = 1'b0;
        check_data_start_bit    = 1'b0;
        clear_data_crc          = 1'b0;
        data_io                 = 1'b1;
        transmit_data           = 8'hFF;

        case (control_state)
            INIT: begin
                reset_command_state     = 1'b1;
            end
            RESET_CLK_1: begin
                start_command           = 1'b1;
            end
            RESET_CLK_2: begin
            end
            SEND_CMD0: begin
                start_command           = 1'b1;
                if (emmc_reset)
                    command             = 48'h40_F0_F0_F0_F0_00;
                else
                    command             = 48'h40_00_00_00_00_00;
                enable_command_crc      = 1'b1;
            end
            WAIT_TO_SEND_CMD0: begin
            end
            SEND_DUMMY: begin
                start_command           = 1'b1;
            end
            WAIT_TO_SEND_DUMMY: begin
            end
            SEND_CMD8: begin
                start_command           = 1'b1;
                command                 = 48'h48_00_00_01_AA_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;
            end
            RESP_CMD8: begin
            end
            SEND_CMD1: begin
                start_command           = 1'b1;
                command                 = 48'h69_40_FF_80_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;
            end
            RESP_CMD1: begin
            end
            SEND_CMD55: begin
                start_command           = 1'b1;
                command                 = 48'h77_00_00_00_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;
            end
            RESP_CMD55: begin
            end
            SEND_ACMD41: begin
                start_command           = 1'b1;
                command                 = 48'h69_40_FF_80_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;
            end
            RESP_ACMD41: begin
            end
            SEND_INITIALIZE_DUMMY: begin
                start_command           = 1'b1;
            end
            WAIT_TO_SEND_INITIALIZE_DUMMY: begin
            end
            SEND_CMD2: begin
                start_command           = 1'b1;
                command                 = 48'h42_00_00_00_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd17;
            end
            RESP_CMD2: begin
            end
            SEND_CMD3: begin
                start_command           = 1'b1;
                command[47:40]          = 8'h43;
                if (~mmc_reset)
                    command[39:24]      = 16'h00;
                else
                    command[39:24]      = 16'h01;
                command[23:0]           = 24'h00_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;
            end
            RESP_CMD3: begin
            end
            SEND_CMD9: begin
                start_command           = 1'b1;
                command[47:40]          = 8'h49;
                command[39:24]          = rca;
                command[23:0]           = 24'h00_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd17;
            end
            RESP_CMD9: begin
            end
            SEND_CMD7: begin
                start_command           = 1'b1;
                command[47:40]          = 8'h47;
                command[39:24]          = rca;
                command[23:0]           = 24'h00_00_00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;
            end
            RESP_CMD7: begin
            end
            BUSY_WAIT_1: begin
                disable_data_io         = 1'b0;
                start_data_io           = 1'b1;
                check_data_start_bit    = 1'b0;
                data_io                 = 1'b1;
            end
            BUSY_WAIT_2: begin
                disable_data_io         = 1'b0;
            end
            READY: begin
            end

            //
            // Block read
            //
            SEND_CMD17: begin
                start_command           = 1'b1;
                command[47:40]          = 8'h51;
                if (ocr[30] == 1'b0)
                    command[39:8]       = {block_address[22:0], 9'b000000000};
                else
                    command[39:8]       = block_address;
                command[7:0]            = 8'h00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;

                disable_data_io         = 1'b0;
                start_data_io           = 1'b1;
                check_data_start_bit    = 1'b1;
                clear_data_crc          = 1'b1;
                data_io                 = 1'b1;
            end
            READ_DATA_BLOCK: begin
                disable_data_io         = 1'b0;
                start_data_io           = 1'b0;
                check_data_start_bit    = 1'b0;
                clear_data_crc          = 1'b0;
                data_io                 = 1'b1;

                // For forcibly reading
                if ((data_io_busy) && (timeout_interrupt))
                    disable_data_io     = 1'b1;

                // Read next byte data
                if ((~data_io_busy) && (read_next_byte))
                    start_data_io       = 1'b1;
            end
            COMPLETE_TO_READ: begin
            end

            //
            // Write block
            //
            SEND_CMD24: begin
                start_command           = 1'b1;
                command[47:40]          = 8'h58;
                if (ocr[30] == 1'b0)
                    command[39:8]       = {block_address[22:0], 9'b000000000};
                else
                    command[39:8]       = block_address;
                command[7:0]            = 8'h00;
                enable_command_crc      = 1'b1;
                enable_response_crc     = 1'b1;
                response_length         = 5'd6;

            end
            RESP_CMD24: begin
            end
            SEND_START_DATA_BIT: begin
                disable_data_io         = 1'b0;
                start_data_io           = 1'b1;
                check_data_start_bit    = 1'b0;
                clear_data_crc          = 1'b0;
                data_io                 = 1'b0;
                transmit_data           = 8'hFE;
            end
            SEND_WRITE_DATA: begin
                disable_data_io         = 1'b0;
                start_data_io           = write_next_byte;
                check_data_start_bit    = 1'b0;
                clear_data_crc          = (access_count == access_block_size) ? 1'b1 : 1'b0;
                data_io                 = 1'b0;
                transmit_data           = write_data_buffer;
            end
            WAIT_TO_SEND_WRITE_DATA: begin
                disable_data_io         = 1'b0;
            end
            SEND_CRC_DATA: begin
                disable_data_io         = 1'b0;
                start_data_io           = 1'b1;
                check_data_start_bit    = 1'b0;
                clear_data_crc          = 1'b0;
                data_io                 = 1'b0;
                transmit_data           = send_crc_count == 1'b1 ? write_data_crc[15:8] : write_data_crc[7:0];
            end
            WAIT_TO_SEND_CRC_DATA: begin
                disable_data_io         = 1'b0;
            end
            START_TO_RESV_CRC_STATUS: begin
                disable_data_io         = 1'b0;
                start_data_io           = 1'b1;
                check_data_start_bit    = 1'b1;
                clear_data_crc          = 1'b0;
                data_io                 = 1'b1;
            end
            RECV_CRC_STATUS: begin
                disable_data_io         = 1'b0;
            end
            COMPLETE_TO_WRITE: begin
            end
            default: begin
            end
        endcase
    end

    // Busy flag
    assign  busy = command_busy | data_io_busy;

    // Error flag
    assign  error = response_error | timeout_interrupt;

    // Count of reset pulse
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            reset_pulse_count <= 4'd02;
        else if (control_state == INIT)
            reset_pulse_count <= 4'd02;
        else if ((control_state == RESET_CLK_1) && (next_control_state == RESET_CLK_2))
            reset_pulse_count <= reset_pulse_count - 4'd01;
        else
            reset_pulse_count <= reset_pulse_count;
    end

    // Reset mode
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            mmc_reset   <= 1'b0;
            emmc_reset  <= 1'b0;
        end
        else if (control_state == INIT) begin
            mmc_reset   <= 1'b0;
            emmc_reset  <= 1'b0;
        end
        else if ((control_state == RESP_CMD8) && (timeout_interrupt)) begin
            mmc_reset   <= 1'b1;
            emmc_reset  <= 1'b1;
        end
        else if ((control_state == SEND_DUMMY) && (emmc_reset)) begin
            mmc_reset   <= 1'b1;
            emmc_reset  <= 1'b0;
        end
        else if ((control_state == RESP_CMD1) && (timeout_interrupt)) begin
            mmc_reset   <= 1'b0;
            emmc_reset  <= 1'b0;
        end
        else begin
            mmc_reset   <= mmc_reset;
            emmc_reset  <= emmc_reset;
        end
    end

    // MMC clock cycle
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            mmc_clock_cycle <= init_spi_clock_cycle;
        else if (control_state == INIT)
            mmc_clock_cycle <= init_spi_clock_cycle;
        else if (control_state == READY)
            mmc_clock_cycle <= normal_spi_clock_cycle;
        else
            mmc_clock_cycle <= mmc_clock_cycle;
    end

    // Reading crc byte flag
    wire    reading_crc_byte = (access_count == 16'h0001) || (access_count == 16'h0000);

    // Interrupt to read data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            read_byte_interrupt <= 1'b0;
        else if ((read_data) && (read_byte_interrupt))
            read_byte_interrupt <= 1'b0;
        else if ((control_state == READ_DATA_BLOCK)
            && (~data_io_busy) && (~read_next_byte) && (~reading_crc_byte))
            read_byte_interrupt <= 1'b1;
        else
            read_byte_interrupt <= read_byte_interrupt;
    end

    // Signal to read next data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            read_next_byte <= 1'b0;
        else if (data_io_busy)
            read_next_byte <= 1'b0;
        else if ((read_data) && (read_byte_interrupt))
            read_next_byte <= 1'b1;
        else if (reading_crc_byte)
            read_next_byte <= 1'b1;
        else
            read_next_byte <= read_next_byte;
    end

    // Complete to read
    assign  read_completion_interrupt = (control_state == COMPLETE_TO_READ);

    // Catch block read error
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            read_interface_error <= 1'b0;
        else if (control_state == READY)
            read_interface_error <= 1'b0;
        else if ((control_state == READ_DATA_BLOCK) && (error))
            read_interface_error <= 1'b1;
        else
            read_interface_error <= read_interface_error;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            read_crc_error <= 1'b0;
        else if (control_state == READY)
            read_crc_error <= 1'b0;
        else if ((control_state == READ_DATA_BLOCK)
            && (~data_io_busy) && (access_count == 16'h0000) && (received_data_crc != 16'h0000))
            read_crc_error <= 1'b1;
        else
            read_crc_error <= read_crc_error;
    end

    // Request next write data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            request_write_data_interrupt <= 1'b0;
        else if ((write_next_byte) && (request_write_data_interrupt))
            request_write_data_interrupt <= 1'b0;
        else if ((control_state == SEND_WRITE_DATA) && (~write_next_byte))
            request_write_data_interrupt <= 1'b1;
        else
            request_write_data_interrupt <= request_write_data_interrupt;
    end

    // Signal to set next write data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            write_next_byte <= 1'b0;
        else if (data_io_busy)
            write_next_byte <= 1'b0;
        else if ((write_data) && (request_write_data_interrupt))
            write_next_byte <= 1'b1;
        else
            write_next_byte <= write_next_byte;
    end

    // Write data
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            write_data_buffer <= 8'h00;
        else if (write_data)
            write_data_buffer <= data_bus;
        else
            write_data_buffer <= write_data_buffer;
    end

    // CRC
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            write_data_crc <= 16'h0000;
        else if (control_state == WAIT_TO_SEND_WRITE_DATA)
            write_data_crc <= send_data_crc;
        else
            write_data_crc <= write_data_crc;
    end

    // Send crc count
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            send_crc_count <= 1'b1;
        else if (control_state == WAIT_TO_SEND_WRITE_DATA)
            send_crc_count <= 1'b1;
        else if ((control_state == WAIT_TO_SEND_CRC_DATA) && (~busy))
            send_crc_count <= 1'b0;
        else
            send_crc_count <= send_crc_count;
    end

    // Complete to write
    assign  write_completion_interrupt = (control_state == COMPLETE_TO_WRITE);

    // Catch block write error
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            write_interface_error <= 1'b0;
        else if (control_state == READY)
            write_interface_error <= 1'b0;
        else if ((control_state == RECV_CRC_STATUS) && (~busy))
            if ((received_data[7:4] != 4'b0101) || (error))
                write_interface_error <= 1'b1;
            else
                write_interface_error <= 1'b0;
        else
            write_interface_error <= write_interface_error;
    end

    // access count
    wire    read_count_down = read_next_byte & data_io_busy;
    wire    write_count_down = write_next_byte & data_io_busy;

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            access_count <= 16'h0000;
        else if (control_state == SEND_CMD17)
            access_count <= access_block_size + 1;
        else if (control_state == SEND_CMD24)
            access_count <= access_block_size;
        else if ((control_state == READ_DATA_BLOCK) && (read_count_down))
            access_count <= access_count - 16'h0001;
        else if ((control_state == SEND_WRITE_DATA) && (write_count_down))
            access_count <= access_count - 16'h0001;
        else
            access_count <= access_count;
    end


    //
    // Registers
    //
    // OCR
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            ocr <= 32'h00000000;
        else if ((control_state == RESP_ACMD41) || (control_state == RESP_CMD1))
            ocr <= response[39:8];
        else
            ocr <= ocr;
    end

    // CID
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            cid <= 0;
        else if (control_state == RESP_CMD2)
            cid <= response[127:0];
        else
            cid <= cid;
    end

    // RCA
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            rca <= 16'h0001;
        else if ((~mmc_reset) && (control_state == RESP_CMD3))
            rca <= response[39:24];
        else
            rca <= rca;
    end

    // CSD
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            csd <= 0;
        else if (control_state == RESP_CMD9)
            csd <= response[127:0];
        else
            csd <= csd;
    end

    // Storage size
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            storage_size <= 0;
        else if (csd[127:126] == 2'b00) // V1
            storage_size <= (csd[73:62]  + 40'd1) << (csd[49:47] + csd[83:80] + 5'd2);
        else if (csd[127:126] == 2'b01) // V2
            storage_size <= {(csd[69:48] + 22'd1), 19'b0000000000000000000};
        else                            // other
            storage_size <= 0;
    end

    // Block Address
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            block_address <= 32'h00000000;
        else if (write_block_address_extension)
            block_address <= {data_bus_extension, data_bus};
        else if (write_block_address_1)
            block_address <= {block_address[31:8],  data_bus};
        else if (write_block_address_2)
            block_address <= {block_address[31:16], data_bus, block_address[7:0]};
        else if (write_block_address_3)
            block_address <= {block_address[31:24], data_bus, block_address[15:0]};
        else if (write_block_address_4)
            block_address <= {data_bus, block_address[23:0]};
        else
            block_address <= block_address;
    end

    // Read data
    assign  read_data_byte = received_data;

    //
    // Status
    //
    // Drive is busy
    assign  drive_busy = ~(control_state == READY);

endmodule

