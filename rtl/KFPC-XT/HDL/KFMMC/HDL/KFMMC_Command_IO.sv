//
// KFMMC_Command_IO
// Written by kitune-san
//
module KFMMC_Command_IO (
    input   logic           clock,
    input   logic           reset,

    input   logic           reset_command_state,

    input   logic           start_command,
    input   logic   [47:0]  command,
    input   logic           enable_command_crc,
    input   logic           enable_response_crc,
    input   logic   [4:0]   response_length,

    output  logic           command_busy,
    output  logic   [135:0] response,
    output  logic           response_error,

    output  logic           start_communication_to_mmc,
    output  logic           command_io_to_mmc,
    output  logic           check_command_start_bit_to_mmc,
    output  logic           clear_command_crc_to_mmc,
    output  logic           clear_command_interrupt_to_mmc,
    output  logic           mask_command_interrupt_to_mmc,
    output  logic           set_send_command_to_mmc,
    output  logic   [7:0]   send_command_to_mmc,

    input   logic   [7:0]   received_response_from_mmc,
    input   logic   [6:0]   send_command_crc_from_mmc,
    input   logic   [6:0]   received_response_crc_from_mmc,

    input   logic           mmc_is_in_connecting,
    input   logic           sent_command_interrupt_from_mmc,
    input   logic           received_response_interrupt_from_mmc
);
    `define SEND_COMMAND_LENGTH (3'd7)

    // State
    typedef enum {IDLE, SEND_COMMAND, RECV_RESPONSE} command_state_t;

    //
    // Internal signals
    //
    command_state_t command_state;
    command_state_t next_command_state;
    logic   [47:0]  command_buffer;
    logic   [2:0]   send_count;
    logic   [4:0]   recv_count;
    logic           enable_command_crc_ff;
    logic           enable_response_crc_ff;
    logic   [7:0]   recv_crc;
    logic           complete_receiving;

    //
    // State machine
    //
    always_comb begin
        next_command_state = command_state;

        case (command_state)
            IDLE: begin
                if (start_command)
                    next_command_state = SEND_COMMAND;
            end
            SEND_COMMAND: begin
                if ((sent_command_interrupt_from_mmc) && (send_count == 3'd0))
                    next_command_state = RECV_RESPONSE;
            end
            RECV_RESPONSE: begin
                if (complete_receiving)
                    next_command_state = IDLE;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            command_state <= IDLE;
        else if (reset_command_state)
            command_state <= IDLE;
        else
            command_state <= next_command_state;
    end

    //
    // Generate control signals
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            start_communication_to_mmc      <= 1'b0;
            command_io_to_mmc               <= 1'b1;
            check_command_start_bit_to_mmc  <= 1'b0;
            clear_command_crc_to_mmc        <= 1'b0;
            clear_command_interrupt_to_mmc  <= 1'b0;
            mask_command_interrupt_to_mmc   <= 1'b0;
            set_send_command_to_mmc         <= 1'b0;
        end
        else if (command_state == SEND_COMMAND) begin
            if ((~mmc_is_in_connecting) && (send_count == `SEND_COMMAND_LENGTH)) begin
                start_communication_to_mmc      <= 1'b1;
                command_io_to_mmc               <= 1'b0;
                check_command_start_bit_to_mmc  <= 1'b0;
                clear_command_crc_to_mmc        <= 1'b1;
                clear_command_interrupt_to_mmc  <= 1'b1;
                mask_command_interrupt_to_mmc   <= 1'b0;
                set_send_command_to_mmc         <= 1'b1;
            end
            else if ((sent_command_interrupt_from_mmc) && (send_count != 3'd0)) begin
                start_communication_to_mmc      <= 1'b1;
                command_io_to_mmc               <= 1'b0;
                check_command_start_bit_to_mmc  <= 1'b0;
                clear_command_crc_to_mmc        <= (send_count == (`SEND_COMMAND_LENGTH-1)) ? 1'b1 : 1'b0;
                clear_command_interrupt_to_mmc  <= 1'b1;
                mask_command_interrupt_to_mmc   <= 1'b0;
                set_send_command_to_mmc         <= 1'b1;
            end
            else begin
                start_communication_to_mmc      <= 1'b0;
                command_io_to_mmc               <= 1'b0;
                check_command_start_bit_to_mmc  <= 1'b0;
                clear_command_crc_to_mmc        <= 1'b0;
                clear_command_interrupt_to_mmc  <= 1'b0;
                mask_command_interrupt_to_mmc   <= 1'b0;
                set_send_command_to_mmc         <= 1'b0;
            end
        end
        else if ((command_state == RECV_RESPONSE) && (~complete_receiving)) begin
            if (sent_command_interrupt_from_mmc) begin
                start_communication_to_mmc      <= 1'b1;
                command_io_to_mmc               <= 1'b1;
                check_command_start_bit_to_mmc  <= 1'b1;
                clear_command_crc_to_mmc        <= 1'b1;
                clear_command_interrupt_to_mmc  <= 1'b1;
                mask_command_interrupt_to_mmc   <= 1'b0;
                set_send_command_to_mmc         <= 1'b0;
            end
            else if ((received_response_interrupt_from_mmc) && (recv_count != 5'd1)) begin
                start_communication_to_mmc      <= 1'b1;
                command_io_to_mmc               <= 1'b1;
                check_command_start_bit_to_mmc  <= 1'b0;
                clear_command_crc_to_mmc        <= 1'b0;
                clear_command_interrupt_to_mmc  <= 1'b1;
                mask_command_interrupt_to_mmc   <= 1'b0;
                set_send_command_to_mmc         <= 1'b0;
            end
            else begin
                start_communication_to_mmc      <= 1'b0;
                command_io_to_mmc               <= 1'b1;
                check_command_start_bit_to_mmc  <= 1'b0;
                clear_command_crc_to_mmc        <= 1'b0;
                clear_command_interrupt_to_mmc  <= 1'b0;
                mask_command_interrupt_to_mmc   <= 1'b0;
                set_send_command_to_mmc         <= 1'b0;
            end
        end
        else begin
            start_communication_to_mmc      <= 1'b0;
            command_io_to_mmc               <= 1'b1;
            check_command_start_bit_to_mmc  <= 1'b0;
            clear_command_crc_to_mmc        <= 1'b0;
            clear_command_interrupt_to_mmc  <= 1'b0;
            mask_command_interrupt_to_mmc   <= 1'b1;
            set_send_command_to_mmc         <= 1'b0;
        end
    end

    wire    shift_send_command_data  =  start_communication_to_mmc & mmc_is_in_connecting & (command_state == SEND_COMMAND);
    wire    shift_recv_response_data = ~start_communication_to_mmc & received_response_interrupt_from_mmc & (command_state == RECV_RESPONSE);

    //
    // Send byte count
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            send_count <= `SEND_COMMAND_LENGTH;
        else if (command_state != SEND_COMMAND)
            send_count <= `SEND_COMMAND_LENGTH;
        else if (shift_send_command_data)
            send_count <= send_count - 3'd1;
        else
            send_count <= send_count;
    end

    //
    // Enable command crc flag
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            enable_command_crc_ff <= 1'b0;
        else if ((start_command) && (command_state == IDLE))
            enable_command_crc_ff <= enable_command_crc;
        else
            enable_command_crc_ff <= enable_command_crc_ff;
    end

    //
    // Send command byte to mmc
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            command_buffer <= 48'hFFFFFFFFFFFF;
            send_command_to_mmc <= 8'hFF;
        end
        else if ((start_command) && (command_state == IDLE)) begin
            command_buffer <= command;
            send_command_to_mmc <= 8'hFF;
        end
        else if ((enable_command_crc_ff) && (send_count == 3'd1)) begin
            command_buffer <= command_buffer;
            send_command_to_mmc <= {send_command_crc_from_mmc, 1'b1};
        end
        else if (shift_send_command_data) begin
                command_buffer <= {command_buffer[39:0], 8'hFF};
                send_command_to_mmc <= command_buffer[47:40];
        end
        else begin
            command_buffer <= command_buffer;
            send_command_to_mmc <= send_command_to_mmc;
        end
    end

    //
    // Receive byte count
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            recv_count <= 5'd0;
        else if ((start_command) && (command_state == IDLE))
            recv_count <= response_length;
        else if ((shift_recv_response_data) && (recv_count != 5'd0))
            recv_count <= recv_count - 5'd1;
        else
            recv_count <= recv_count;
    end

    assign  complete_receiving = (recv_count == 5'd0);

    //
    // Receive response byte from mmc
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            response <= 136'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        else if (command_state != RECV_RESPONSE)
            response <= response;
        else if (complete_receiving)
            response <= response;
        else if (shift_recv_response_data)
            response <= {response[127:0], received_response_from_mmc};
        else
            response <= response;
    end

    //
    // Enable response crc flag
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            enable_response_crc_ff <= 1'b0;
        else if ((start_command) && (command_state == IDLE))
            enable_response_crc_ff <= enable_response_crc;
        else
            enable_response_crc_ff <= enable_response_crc_ff;
    end

    //
    // Get CRC
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            recv_crc <= 8'b00000000;
        else if ((enable_response_crc_ff) && (shift_recv_response_data) && (recv_count != 5'd1))
            recv_crc <= {received_response_crc_from_mmc, 1'b1};
        else
            recv_crc <= recv_crc;
    end

    //
    // Error (CRC check)
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            response_error <= 1'b0;
        else if (reset_command_state)
            response_error <= 1'b0;
        else if ((start_command) && (command_state == IDLE))
            response_error <= 1'b0;
        else if ((enable_response_crc_ff) && (shift_recv_response_data) && (recv_count == 5'd0))
            if (recv_crc != received_response_from_mmc)
                response_error <= 1'b1;
            else
                response_error <= 1'b0;
        else
            response_error <= response_error;
    end

    //
    // Busy flag to controller
    //
    assign  command_busy = (command_state != IDLE);

endmodule

