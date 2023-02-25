//
// KFMMC_Data_IO
// Written by kitune-san
//
module KFMMC_Data_IO (
    input   logic           clock,
    input   logic           reset,

    input   logic           disable_data_io,
    input   logic           start_data_io,
    input   logic           check_data_start_bit,
    input   logic           clear_data_crc,
    input   logic           data_io,
    input   logic   [7:0]   transmit_data,

    output  logic           data_io_busy,
    output  logic   [7:0]   received_data,

    output  logic           start_communication_to_mmc,
    output  logic           data_io_to_mmc,
    output  logic           check_data_start_bit_to_mmc,
    output  logic           read_continuous_data_to_mmc,
    output  logic           clear_data_crc_to_mmc,
    output  logic           clear_data_interrupt_to_mmc,
    output  logic           mask_data_interrupt_to_mmc,
    output  logic           set_send_data_to_mmc,
    output  logic   [7:0]   send_data_to_mmc,
    input   logic   [7:0]   received_data_from_mmc,

    input   logic           mmc_is_in_connecting,
    input   logic           sent_data_interrupt_from_mmc,
    input   logic           received_data_interrupt_from_mmc
);

    // State
    typedef enum {IDLE, SEND_DATA, RECV_DATA} data_io_state_t;

    //
    // Internal signals
    //
    data_io_state_t data_io_state;
    data_io_state_t next_data_io_state;
    logic           idle_mode;
    logic           ready_to_communicate;
    logic           check_data_start_bit_ff;
    logic           clear_data_crc_ff;

    //
    // State machine
    //
    always_comb begin
        next_data_io_state = data_io_state;

        if (disable_data_io)
            next_data_io_state = IDLE;
        else begin
            case (data_io_state)
                IDLE: begin
                    if (start_data_io)
                        if (data_io)
                            next_data_io_state = RECV_DATA;
                        else
                            next_data_io_state = SEND_DATA;
                end
                SEND_DATA: begin
                    if ((~ready_to_communicate) && (sent_data_interrupt_from_mmc))
                        next_data_io_state = IDLE;
                end
                RECV_DATA: begin
                    if ((~ready_to_communicate) && (received_data_interrupt_from_mmc))
                        next_data_io_state = IDLE;
                end
            endcase
        end
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            data_io_state <= IDLE;
        else
            data_io_state <= next_data_io_state;
    end

    //
    // Generate control signals
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            start_communication_to_mmc      <= 1'b0;
            data_io_to_mmc                  <= 1'b1;
            check_data_start_bit_to_mmc     <= 1'b0;
            read_continuous_data_to_mmc     <= 1'b0;
            clear_data_crc_to_mmc           <= 1'b0;
            clear_data_interrupt_to_mmc     <= 1'b0;
            mask_data_interrupt_to_mmc      <= 1'b0;
            set_send_data_to_mmc            <= 1'b0;
        end
        else if (disable_data_io) begin
            start_communication_to_mmc      <= 1'b0;
            data_io_to_mmc                  <= 1'b1;
            check_data_start_bit_to_mmc     <= 1'b0;
            read_continuous_data_to_mmc     <= 1'b0;
            clear_data_crc_to_mmc           <= 1'b0;
            clear_data_interrupt_to_mmc     <= 1'b0;
            mask_data_interrupt_to_mmc      <= 1'b1;
            set_send_data_to_mmc            <= 1'b0;
        end
        else begin
            case (data_io_state)
                IDLE: begin
                    start_communication_to_mmc      <= 1'b0;
                    data_io_to_mmc                  <= 1'b1;
                    check_data_start_bit_to_mmc     <= 1'b0;
                    read_continuous_data_to_mmc     <= 1'b0;
                    clear_data_crc_to_mmc           <= 1'b0;
                    clear_data_interrupt_to_mmc     <= 1'b0;
                    mask_data_interrupt_to_mmc      <= 1'b0;
                    set_send_data_to_mmc            <= 1'b0;
                end
                SEND_DATA: begin
                    if ((~mmc_is_in_connecting) && (ready_to_communicate)) begin
                        start_communication_to_mmc      <= 1'b1;
                        data_io_to_mmc                  <= 1'b0;
                        check_data_start_bit_to_mmc     <= 1'b0;
                        read_continuous_data_to_mmc     <= 1'b0;
                        clear_data_crc_to_mmc           <= clear_data_crc_ff;
                        clear_data_interrupt_to_mmc     <= 1'b1;
                        mask_data_interrupt_to_mmc      <= 1'b0;
                        set_send_data_to_mmc            <= 1'b1;
                    end
                    else begin
                        start_communication_to_mmc      <= 1'b0;
                        data_io_to_mmc                  <= 1'b0;
                        check_data_start_bit_to_mmc     <= 1'b0;
                        read_continuous_data_to_mmc     <= 1'b0;
                        clear_data_crc_to_mmc           <= 1'b0;
                        clear_data_interrupt_to_mmc     <= 1'b0;
                        mask_data_interrupt_to_mmc      <= 1'b0;
                        set_send_data_to_mmc            <= 1'b0;
                    end
                end
                RECV_DATA: begin
                    if ((~mmc_is_in_connecting) && (ready_to_communicate)) begin
                        start_communication_to_mmc      <= 1'b1;
                        data_io_to_mmc                  <= 1'b1;
                        check_data_start_bit_to_mmc     <= check_data_start_bit_ff;
                        read_continuous_data_to_mmc     <= ~check_data_start_bit_ff;
                        clear_data_crc_to_mmc           <= clear_data_crc_ff;
                        clear_data_interrupt_to_mmc     <= 1'b1;
                        mask_data_interrupt_to_mmc      <= 1'b0;
                        set_send_data_to_mmc            <= 1'b0;
                    end
                    else begin
                        start_communication_to_mmc      <= 1'b0;
                        data_io_to_mmc                  <= 1'b1;
                        check_data_start_bit_to_mmc     <= 1'b0;
                        read_continuous_data_to_mmc     <= 1'b0;
                        clear_data_crc_to_mmc           <= 1'b0;
                        clear_data_interrupt_to_mmc     <= 1'b0;
                        mask_data_interrupt_to_mmc      <= 1'b0;
                        set_send_data_to_mmc            <= 1'b0;
                    end
                end
            endcase
        end
    end

    assign  idle_mode = (data_io_state == IDLE) || (disable_data_io);

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            ready_to_communicate <= 1'b0;
        else if (idle_mode)
            ready_to_communicate <= 1'b1;
        else if ((mmc_is_in_connecting) && (start_communication_to_mmc))
            ready_to_communicate <= 1'b0;
        else
            ready_to_communicate <= ready_to_communicate;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            check_data_start_bit_ff <= 1'b0;
        else if (idle_mode)
            check_data_start_bit_ff <= check_data_start_bit;
        else
            check_data_start_bit_ff <= check_data_start_bit_ff;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            clear_data_crc_ff <= 1'b0;
        else if (idle_mode)
            clear_data_crc_ff <= clear_data_crc;
        else
            clear_data_crc_ff <= clear_data_crc_ff;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            send_data_to_mmc <= 8'h00;
        else if (idle_mode)
            send_data_to_mmc <= transmit_data;
        else
            send_data_to_mmc <= send_data_to_mmc;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            received_data <= 8'h00;
        else if (data_io_state == RECV_DATA)
            received_data <= received_data_from_mmc;
        else
            received_data <= received_data;
    end

    //
    // Busy flag to controller
    //
    assign  data_io_busy = (data_io_state != IDLE);

endmodule

