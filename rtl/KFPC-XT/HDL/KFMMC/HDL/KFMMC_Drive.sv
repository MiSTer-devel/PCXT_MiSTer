//
// KFMMC_Drive
// Written by kitune-san
//
module KFMMC_Drive #(
    parameter init_spi_clock_cycle = 8'd010,
    parameter normal_spi_clock_cycle = 8'd002,
    parameter timeout = 32'hFFFFFFFF
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
    output  logic           write_completion_interrupt,

    output  logic           mmc_clk,
    input   logic           mmc_cmd_in,
    output  logic           mmc_cmd_out,
    output  logic           mmc_cmd_io,
    input   logic           mmc_dat_in,
    output  logic           mmc_dat_out,
    output  logic           mmc_dat_io
);

    //
    // Controller
    //
    // Output (to Command I/O)
    logic           reset_command_state;
    logic           start_command;
    logic   [47:0]  command;
    logic           enable_command_crc;
    logic           enable_response_crc;
    logic   [4:0]   response_length;
    // Input (from Command I/O)
    logic           command_busy;
    logic   [135:0] response;
    logic           response_error;
    // Output (to Data I/O)
    logic           disable_data_io;
    logic           start_data_io;
    logic           check_data_start_bit;
    logic           clear_data_crc;
    logic           data_io;
    logic   [7:0]   transmit_data;
    // Input (from Data I/O)
    logic           data_io_busy;
    logic   [7:0]   received_data;
    // Output (to MMC interface)
    logic   [7:0]   mmc_clock_cycle;
    // Input (from MMC interface)
    logic   [15:0]  send_data_crc;
    logic   [15:0]  received_data_crc;
    logic           timeout_interrupt;

    KFMMC_Controller #(
        .init_spi_clock_cycle   (init_spi_clock_cycle),
        .normal_spi_clock_cycle (normal_spi_clock_cycle)
    ) u_KFMMC_Controller (
        .clock                                  (clock),
        .reset                                  (reset),

        .data_bus                               (data_bus),
        .data_bus_extension                     (data_bus_extension),
        .write_block_address_1                  (write_block_address_1),
        .write_block_address_2                  (write_block_address_2),
        .write_block_address_3                  (write_block_address_3),
        .write_block_address_4                  (write_block_address_4),
        .write_block_address_extension          (write_block_address_extension),
        .write_access_command                   (write_access_command),
        .write_data                             (write_data),
        .read_data_byte                         (read_data_byte),
        .read_data                              (read_data),

        .reset_command_state                    (reset_command_state),
        .start_command                          (start_command),
        .command                                (command),
        .enable_command_crc                     (enable_command_crc),
        .enable_response_crc                    (enable_response_crc),
        .response_length                        (response_length),

        .command_busy                           (command_busy),
        .response                               (response),
        .response_error                         (response_error),

        .disable_data_io                        (disable_data_io),
        .start_data_io                          (start_data_io),
        .check_data_start_bit                   (check_data_start_bit),
        .clear_data_crc                         (clear_data_crc),
        .data_io                                (data_io),
        .transmit_data                          (transmit_data),

        .data_io_busy                           (data_io_busy),
        .received_data                          (received_data),

        .mmc_clock_cycle                        (mmc_clock_cycle),

        .send_data_crc                          (send_data_crc),
        .received_data_crc                      (received_data_crc),
        .timeout_interrupt                      (timeout_interrupt),

        .drive_busy                             (drive_busy),
        .storage_size                           (storage_size),

        .read_interface_error                   (read_interface_error),
        .read_crc_error                         (read_crc_error),
        .write_interface_error                  (write_interface_error),

        .read_byte_interrupt                    (read_byte_interrupt),
        .read_completion_interrupt              (read_completion_interrupt),
        .request_write_data_interrupt           (request_write_data_interrupt),
        .write_completion_interrupt             (write_completion_interrupt)
    );


    //
    // Command I/O
    //
    // Output (to MMC interface)
    logic           start_communication_from_command_io;
    logic           command_io_to_mmc;
    logic           check_command_start_bit_to_mmc;
    logic           clear_command_crc_to_mmc;
    logic           clear_command_interrupt_to_mmc;
    logic           mask_command_interrupt_to_mmc;
    logic           set_send_command_to_mmc;
    logic   [7:0]   send_command_to_mmc;
    // Input (from MMC interface)
    logic   [7:0]   received_response_from_mmc;
    logic   [6:0]   send_command_crc_from_mmc;
    logic   [6:0]   received_response_crc_from_mmc;
    logic           mmc_is_in_connecting;
    logic           sent_command_interrupt_from_mmc;
    logic           received_response_interrupt_from_mmc;

    KFMMC_Command_IO u_KFMMC_Command_IO (
        .clock                                  (clock),
        .reset                                  (reset),

        .reset_command_state                    (reset_command_state),

        .start_command                          (start_command),
        .command                                (command),
        .enable_command_crc                     (enable_command_crc),
        .enable_response_crc                    (enable_response_crc),
        .response_length                        (response_length),

        .command_busy                           (command_busy),
        .response                               (response),
        .response_error                         (response_error),

        .start_communication_to_mmc             (start_communication_from_command_io),
        .command_io_to_mmc                      (command_io_to_mmc),
        .check_command_start_bit_to_mmc         (check_command_start_bit_to_mmc),
        .clear_command_crc_to_mmc               (clear_command_crc_to_mmc),
        .clear_command_interrupt_to_mmc         (clear_command_interrupt_to_mmc),
        .mask_command_interrupt_to_mmc          (mask_command_interrupt_to_mmc),
        .set_send_command_to_mmc                (set_send_command_to_mmc),
        .send_command_to_mmc                    (send_command_to_mmc),

        .received_response_from_mmc             (received_response_from_mmc),
        .send_command_crc_from_mmc              (send_command_crc_from_mmc),
        .received_response_crc_from_mmc         (received_response_crc_from_mmc),

        .mmc_is_in_connecting                   (mmc_is_in_connecting),
        .sent_command_interrupt_from_mmc        (sent_command_interrupt_from_mmc),
        .received_response_interrupt_from_mmc   (received_response_interrupt_from_mmc)
    );


    //
    // Data I/O
    //
    // Output (to MMC interface)
    logic           start_communication_from_data_io;
    logic           data_io_to_mmc;
    logic           check_data_start_bit_to_mmc;
    logic           read_continuous_data_to_mmc;
    logic           clear_data_crc_to_mmc;
    logic           clear_data_interrupt_to_mmc;
    logic           mask_data_interrupt_to_mmc;
    logic           set_send_data_to_mmc;
    logic   [7:0]   send_data_to_mmc;
    // Input (from MMC interface)
    logic   [7:0]   received_data_from_mmc;
    logic           sent_data_interrupt_from_mmc;
    logic           received_data_interrupt_from_mmc;

    KFMMC_Data_IO u_KFMMC_Data_IO (
        .clock                                  (clock),
        .reset                                  (reset),

        .disable_data_io                        (disable_data_io),
        .start_data_io                          (start_data_io),
        .check_data_start_bit                   (check_data_start_bit),
        .clear_data_crc                         (clear_data_crc),
        .data_io                                (data_io),
        .transmit_data                          (transmit_data),

        .data_io_busy                           (data_io_busy),
        .received_data                          (received_data),

        .start_communication_to_mmc             (start_communication_from_data_io),
        .data_io_to_mmc                         (data_io_to_mmc),
        .check_data_start_bit_to_mmc            (check_data_start_bit_to_mmc),
        .read_continuous_data_to_mmc            (read_continuous_data_to_mmc),
        .clear_data_crc_to_mmc                  (clear_data_crc_to_mmc),
        .clear_data_interrupt_to_mmc            (clear_data_interrupt_to_mmc),
        .mask_data_interrupt_to_mmc             (mask_data_interrupt_to_mmc),
        .set_send_data_to_mmc                   (set_send_data_to_mmc),
        .send_data_to_mmc                       (send_data_to_mmc),
        .received_data_from_mmc                 (received_data_from_mmc),

        .mmc_is_in_connecting                   (mmc_is_in_connecting),
        .sent_data_interrupt_from_mmc           (sent_data_interrupt_from_mmc),
        .received_data_interrupt_from_mmc       (received_data_interrupt_from_mmc)
    );


    //
    // Interface
    //
    wire start_communication = start_communication_from_command_io | start_communication_from_data_io;

    KFMMC_Interface #(
        .timeout    (timeout)
    ) u_KFMMC_Interface (
        .clock                                  (clock),
        .reset                                  (reset),

        .start_communication                    (start_communication),
        .command_io                             (command_io_to_mmc),
        .data_io                                (data_io_to_mmc),
        .check_command_start_bit                (check_command_start_bit_to_mmc),
        .check_data_start_bit                   (check_data_start_bit_to_mmc),
        .read_continuous_data                   (read_continuous_data_to_mmc),
        .clear_command_crc                      (clear_command_crc_to_mmc),
        .clear_data_crc                         (clear_data_crc_to_mmc),
        .clear_command_interrupt                (clear_command_interrupt_to_mmc),
        .clear_data_interrupt                   (clear_data_interrupt_to_mmc),
        .mask_command_interrupt                 (mask_command_interrupt_to_mmc),
        .mask_data_interrupt                    (mask_data_interrupt_to_mmc),
        .set_send_command                       (set_send_command_to_mmc),
        .send_command                           (send_command_to_mmc),
        .set_send_data                          (set_send_data_to_mmc),
        .send_data                              (send_data_to_mmc),

        .received_response                      (received_response_from_mmc),
        .send_command_crc                       (send_command_crc_from_mmc),
        .received_response_crc                  (received_response_crc_from_mmc),
        .received_data                          (received_data_from_mmc),
        .send_data_crc                          (send_data_crc),
        .received_data_crc                      (received_data_crc),

        .in_connecting                          (mmc_is_in_connecting),
        .sent_command_interrupt                 (sent_command_interrupt_from_mmc),
        .received_response_interrupt            (received_response_interrupt_from_mmc),
        .sent_data_interrupt                    (sent_data_interrupt_from_mmc),
        .received_data_interrupt                (received_data_interrupt_from_mmc),
        .timeout_interrupt                      (timeout_interrupt),

        .mmc_clock_cycle                        (mmc_clock_cycle),
        .mmc_clk                                (mmc_clk),
        .mmc_cmd_in                             (mmc_cmd_in),
        .mmc_cmd_out                            (mmc_cmd_out),
        .mmc_cmd_io                             (mmc_cmd_io),
        .mmc_dat_in                             (mmc_dat_in),
        .mmc_dat_out                            (mmc_dat_out),
        .mmc_dat_io                             (mmc_dat_io)
    );

endmodule

