//
// KFMMC_IDE
// IDE(PIO) wrapper to access MMC
//
// Written by kitune-san
//
module KFMMC_IDE #(
    parameter init_spi_clock_cycle = 8'd010,
    parameter normal_spi_clock_cycle = 8'd002,
    parameter access_block_size = 16'd512,
    parameter timeout = 32'hFFFFFFFF
) (
    input   logic           clock,
    input   logic           reset,

    // IDE interface
    input   logic           ide_cs1fx_n,
    input   logic           ide_cs3fx_n,
    input   logic           ide_io_read_n,
    input   logic           ide_io_write_n,

    input   logic   [2:0]   ide_address,
    input   logic   [15:0]  ide_data_bus_in,
    output  logic   [15:0]  ide_data_bus_out,

    input   logic           device_master,

    // MMC interface
    output  logic           mmc_clk,
    input   logic           mmc_cmd_in,
    output  logic           mmc_cmd_out,
    output  logic           mmc_cmd_io,
    input   logic           mmc_dat_in,
    output  logic           mmc_dat_out,
    output  logic           mmc_dat_io
);

    //
    // MMC drive
    //
    logic           mmc_reset;
    // Control signal
    logic   [7:0]   mmc_data_bus;
    logic   [24:0]  mmc_ext_data_bus;
    logic           mmc_write_block_address;
    logic           mmc_write_access_command;
    logic           mmc_write_data;

    logic   [7:0]   mmc_read_data_byte;
    logic           mmc_read_data;

    // State
    logic           mmc_drive_busy;
    logic   [39:0]  mmc_storage_size;

    // Error flags
    logic           mmc_read_interface_error;
    logic           mmc_read_crc_error;
    logic           mmc_write_interface_error;

    // External input/output
    logic           mmc_read_byte_interrupt;
    logic           mmc_read_completion_interrupt;
    logic           mmc_request_write_data_interrupt;
    logic           mmc_write_completion_interrupt;

    KFMMC_Drive #(
        .init_spi_clock_cycle               (init_spi_clock_cycle),
        .normal_spi_clock_cycle             (normal_spi_clock_cycle),
        .timeout                            (timeout)
    ) u_KFMMC_Drive  (
        .clock                              (clock),
        .reset                              (reset | mmc_reset),

        .data_bus                           (mmc_data_bus),
        .data_bus_extension                 (mmc_ext_data_bus),
        .write_block_address_1              (1'b0),
        .write_block_address_2              (1'b0),
        .write_block_address_3              (1'b0),
        .write_block_address_4              (1'b0),
        .write_block_address_extension      (mmc_write_block_address),
        .write_access_command               (mmc_write_access_command),
        .write_data                         (mmc_write_data),

        .read_data_byte                     (mmc_read_data_byte),
        .read_data                          (mmc_read_data),

        .drive_busy                         (mmc_drive_busy),
        .storage_size                       (mmc_storage_size),

        .read_interface_error               (mmc_read_interface_error),
        .read_crc_error                     (mmc_read_crc_error),
        .write_interface_error              (mmc_write_interface_error),

        .read_byte_interrupt                (mmc_read_byte_interrupt),
        .read_completion_interrupt          (mmc_read_completion_interrupt),
        .request_write_data_interrupt       (mmc_request_write_data_interrupt),
        .write_completion_interrupt         (mmc_write_completion_interrupt),

        .mmc_clk                            (mmc_clk),
        .mmc_cmd_in                         (mmc_cmd_in),
        .mmc_cmd_out                        (mmc_cmd_out),
        .mmc_cmd_io                         (mmc_cmd_io),
        .mmc_dat_in                         (mmc_dat_in),
        .mmc_dat_out                        (mmc_dat_out),
        .mmc_dat_io                         (mmc_dat_io)
    );


    //
    // IDE Bus
    //
    logic   [2:0]   latch_address;
    logic   [15:0]  latch_data;
    logic           prev_read_n;
    logic           prev_write_n;
    logic           read_edge;
    logic           write_edge;
    logic           command_cs;
    logic           control_cs;
    logic           write_command;


    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            latch_address       <= 3'b000;
            latch_data          <= 16'h0000;
            prev_read_n         <= 1'b1;
            prev_write_n        <= 1'b1;
            read_edge           <= 1'b0;
            command_cs          <= 1'b0;
            control_cs          <= 1'b0;
        end
        else begin
            if (~ide_cs1fx_n | ~ide_cs3fx_n) begin
                latch_address   <= ide_address;
                latch_data      <= ide_data_bus_in;
            end
            else begin
                latch_address   <= latch_address;
                latch_data      <= latch_data;
            end
            prev_read_n         <= ide_io_read_n;
            prev_write_n        <= ide_io_write_n;
            read_edge           <=  prev_read_n  & ~ide_io_read_n;
            command_cs          <= ~ide_cs1fx_n;
            control_cs          <= ~ide_cs3fx_n;
        end
    end

    assign  write_edge          = ~prev_write_n &  ide_io_write_n;
    assign  write_command       = command_cs & write_edge;
    assign  write_control       = control_cs & write_edge;


    //
    // Storage CHS
    //
    wire    [31:0]  storage_total_sectors   = {1'b0, mmc_storage_size[39:9]};

//    logic           calc_storage_chs;
//    wire            end_of_storage_chs_calc = 1'b1;
//    wire    [15:0]  storage_cylinder        = 16'h3FF;
//    wire    [3:0]   storage_head            = 4'hF;
//    wire    [7:0]   storage_spt             = 8'h3F;
    typedef enum {CALC_STORAGE_CHS_IDLE, CALC_STORAGE_CHS_1, CALC_STORAGE_CHS_2, CALC_STORAGE_CHS_END} calc_storage_chs_state_t;
    calc_storage_chs_state_t    calc_storage_chs_state;
    logic           calc_storage_chs;
    logic           end_of_storage_chs_calc;
    logic   [15:0]  calc_storage_head_x_spt;
    logic   [31:0]  calc_storage_temp;

    logic   [15:0]  storage_cylinder;   // 65535-0  (BIOS: 1023-0)
    logic   [3:0]   storage_head;       // 15-0     (BIOS: 254-0)
    logic   [7:0]   storage_spt;        // 255-1    (BIOS: 63-1)

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            calc_storage_chs_state  <= CALC_STORAGE_CHS_IDLE;
            calc_storage_head_x_spt <= 16'h0000;
            calc_storage_temp       <= 31'h00000000;
            storage_cylinder        <= 16'h0000;
            storage_head            <= 4'h0;
            storage_spt             <= 8'h00;
        end
        else if (~calc_storage_chs) begin
            calc_storage_chs_state  <= CALC_STORAGE_CHS_IDLE;
            calc_storage_head_x_spt <= calc_storage_head_x_spt;
            calc_storage_temp       <= calc_storage_temp;
            storage_cylinder        <= storage_cylinder;
            storage_head            <= storage_head;
            storage_spt             <= storage_spt;
        end
        else begin
            casez (calc_storage_chs_state)
                CALC_STORAGE_CHS_IDLE: begin
                    calc_storage_head_x_spt <= 16'h00FC;
                    calc_storage_temp       <= storage_total_sectors;
                    storage_cylinder        <= 16'h0000;
                    storage_head            <= 4'h4;
                    storage_spt             <= 8'h3F;
                    calc_storage_chs_state  <= CALC_STORAGE_CHS_1;
                end
                CALC_STORAGE_CHS_1: begin
                    calc_storage_head_x_spt <= calc_storage_head_x_spt;
                    storage_head            <= storage_head;
                    storage_spt             <= storage_spt;
                    if ((~|calc_storage_temp) || (calc_storage_temp < calc_storage_head_x_spt)) begin
                        calc_storage_temp       <= calc_storage_temp;
                        storage_cylinder        <= storage_cylinder;
                        calc_storage_chs_state  <= CALC_STORAGE_CHS_END;
                    end
                    else if (storage_cylinder >= 16'h3FFF) begin
                        calc_storage_temp       <= calc_storage_temp;
                        storage_cylinder        <= storage_cylinder;
                        calc_storage_chs_state  <= CALC_STORAGE_CHS_2;
                    end
                    else begin
                        calc_storage_temp       <= calc_storage_temp - calc_storage_head_x_spt;
                        storage_cylinder        <= storage_cylinder + 1'b1;
                    end
                end
                CALC_STORAGE_CHS_2: begin
                    if (storage_head == 4'hF) begin
                        calc_storage_head_x_spt <= calc_storage_head_x_spt;
                        calc_storage_temp       <= calc_storage_temp;
                        storage_cylinder        <= 16'h3FFF;
                        storage_head            <= storage_head;
                        storage_spt             <= storage_spt;
                        calc_storage_chs_state  <= CALC_STORAGE_CHS_END;
                    end
                    else begin
                        calc_storage_head_x_spt <= calc_storage_head_x_spt + storage_spt;
                        calc_storage_temp       <= storage_total_sectors;
                        storage_cylinder        <= 16'h0000;
                        storage_head            <= storage_head + 1'b1;
                        storage_spt             <= storage_spt;
                        calc_storage_chs_state  <= CALC_STORAGE_CHS_1;
                    end
                end
                CALC_STORAGE_CHS_END: begin
                    calc_storage_head_x_spt <= calc_storage_head_x_spt;
                    calc_storage_temp       <= calc_storage_temp;
                    storage_cylinder        <= storage_cylinder;
                    storage_head            <= storage_head;
                    storage_spt             <= storage_spt;
                    calc_storage_chs_state  <= CALC_STORAGE_CHS_END;
                end
                default: begin
                    calc_storage_chs_state  <= CALC_STORAGE_CHS_IDLE;
                end
            endcase
        end
    end

    assign  end_of_storage_chs_calc = (calc_storage_chs_state == CALC_STORAGE_CHS_END);


    //
    // Logical CHS
    //
    logic   [15:0]  logical_cylinder;
    logic   [3:0]   logical_head;
    logic   [7:0]   logical_spt;

    // Calculate logical cylinder
    typedef enum {CALC_LC_1, CALC_LC_2, CALC_LC_3, CALC_LC_END} calc_lc_state_t;
    calc_lc_state_t calc_lc_state;
    logic           start_logical_cylinder;
    logic           end_logical_cylinder;
    logic   [3:0]   calc_lc_head_count;
    logic   [9:0]   calc_lc_temp;
    logic   [31:0]  calc_lc_temp_2;
    logic   [15:0]  result_calc_logical_cylinder;
    // total_cylinder = LBA / spt * total_headers
    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            calc_lc_head_count              <= 4'h0;
            calc_lc_temp                    <= 10'h000;
            calc_lc_temp_2                  <= 32'h00000000;
            result_calc_logical_cylinder    <= 16'h0000;
            calc_lc_state                   <= CALC_LC_1;
        end
        else if (~start_logical_cylinder) begin
            calc_lc_head_count              <= calc_lc_head_count;
            calc_lc_temp                    <= calc_lc_temp;
            calc_lc_temp_2                  <= calc_lc_temp_2;
            result_calc_logical_cylinder    <= result_calc_logical_cylinder;
            calc_lc_state                   <= CALC_LC_1;
        end
        else begin
            casez (calc_lc_state)
                CALC_LC_1: begin
                    calc_lc_head_count              <= logical_head;
                    calc_lc_temp                    <= 10'h000;
                    calc_lc_temp_2                  <= storage_total_sectors;
                    result_calc_logical_cylinder    <= 16'h0000;
                    calc_lc_state                   <= CALC_LC_2;
                end
                CALC_LC_2: begin
                    // spt * total_headers
                    if (|calc_lc_head_count) begin
                        calc_lc_head_count              <= calc_lc_head_count - 1'b1;
                        calc_lc_temp                    <= calc_lc_temp + logical_spt;
                        calc_lc_temp_2                  <= calc_lc_temp_2;
                        result_calc_logical_cylinder    <= result_calc_logical_cylinder;
                        calc_lc_state                   <= CALC_LC_2;
                    end
                    else begin
                        calc_lc_head_count              <= calc_lc_head_count;
                        calc_lc_temp                    <= calc_lc_temp;
                        calc_lc_temp_2                  <= calc_lc_temp_2;
                        result_calc_logical_cylinder    <= result_calc_logical_cylinder;
                        calc_lc_state                   <= CALC_LC_3;
                    end
                end
                CALC_LC_3: begin
                    // LBA / _
                    if ((calc_lc_temp <= calc_lc_temp_2) && (~&result_calc_logical_cylinder)) begin
                        calc_lc_head_count              <= calc_lc_head_count;
                        calc_lc_temp                    <= calc_lc_temp;
                        calc_lc_temp_2                  <= calc_lc_temp_2 - calc_lc_temp;
                        result_calc_logical_cylinder    <= result_calc_logical_cylinder + 1'b1;
                        calc_lc_state                   <= CALC_LC_3;
                    end
                    else begin
                        calc_lc_head_count              <= calc_lc_head_count;
                        calc_lc_temp                    <= calc_lc_temp;
                        result_calc_logical_cylinder    <= result_calc_logical_cylinder;
                        calc_lc_state                   <= CALC_LC_END;
                    end
                end
                CALC_LC_END: begin
                    calc_lc_head_count              <= calc_lc_head_count;
                    calc_lc_temp                    <= calc_lc_temp;
                    result_calc_logical_cylinder    <= result_calc_logical_cylinder;
                    calc_lc_state                   <= CALC_LC_END;
                end
                default: begin
                    calc_lc_head_count              <= calc_lc_head_count;
                    calc_lc_temp                    <= calc_lc_temp;
                    result_calc_logical_cylinder    <= result_calc_logical_cylinder;
                    calc_lc_state                   <= CALC_LC_1;
                end
            endcase
        end
    end

    assign  end_logical_cylinder    = (calc_lc_state == CALC_LC_END);


    //
    // Convert Access CHS to LBA
    //
    // LBA = (H + C * total_headers) * spt + (S - 1)
    //
    typedef enum {CHS2LBA_1, CHS2LBA_2, CHS2LBA_3, CHS2LBA_END} chs2lba_state_t;
    chs2lba_state_t chs2lba_state;
    logic           start_chs2lba;
    logic           end_chs2lba;
    logic   [3:0]   chs2lba_head_count;
    logic   [7:0]   chs2lba_spt_count;
    logic   [19:0]  chs2lba_calc_temp;
    logic   [31:0]  chs2lba;

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            chs2lba_head_count  <= 4'h0;
            chs2lba_spt_count   <= 8'h00;
            chs2lba_calc_temp   <= 20'h00000;
            chs2lba             <= 32'h00000000;
            chs2lba_state       <= CHS2LBA_1;
        end
        else if (~start_chs2lba) begin
            chs2lba_head_count  <= chs2lba_head_count;
            chs2lba_spt_count   <= chs2lba_spt_count;
            chs2lba_calc_temp   <= chs2lba_calc_temp;
            chs2lba             <= chs2lba;
            chs2lba_state       <= CHS2LBA_1;
        end
        else begin
            casez(chs2lba_state)
                CHS2LBA_1: begin
                    chs2lba_head_count      <= logical_head;
                    chs2lba_spt_count       <= chs2lba_spt_count;
                    chs2lba_calc_temp       <= {16'h0000, head_number}; // + H
                    chs2lba                 <= chs2lba;
                    chs2lba_state           <= CHS2LBA_2;
                end
                CHS2LBA_2: begin
                    // + (C * total_headers)
                    if (|chs2lba_head_count) begin
                        chs2lba_head_count  <= chs2lba_head_count - 1'b1;
                        chs2lba_spt_count   <= chs2lba_spt_count;
                        chs2lba_calc_temp   <= chs2lba_calc_temp + cylinder[15:0];
                        chs2lba             <= chs2lba;
                        chs2lba_state       <= CHS2LBA_2;
                    end
                    else begin
                        chs2lba_head_count  <= chs2lba_head_count;
                        chs2lba_spt_count   <= logical_spt;
                        chs2lba_calc_temp   <= chs2lba_calc_temp;
                        chs2lba             <= 32'h00000000;
                        chs2lba_state       <= CHS2LBA_3;
                    end
                end
                CHS2LBA_3: begin
                    if (|chs2lba_spt_count) begin
                        // * spt
                        chs2lba_head_count  <= chs2lba_head_count;
                        chs2lba_spt_count   <= chs2lba_spt_count - 1'b1;
                        chs2lba_calc_temp   <= chs2lba_calc_temp;
                        chs2lba             <= chs2lba + chs2lba_calc_temp;
                        chs2lba_state       <= CHS2LBA_3;
                    end
                    else begin
                        // + (S - 1)
                        chs2lba_head_count  <= chs2lba_head_count;
                        chs2lba_spt_count   <= chs2lba_spt_count;
                        chs2lba_calc_temp   <= chs2lba_calc_temp;
                        chs2lba             <= chs2lba + sector_number[7:0] - 1'b1;
                        chs2lba_state       <= CHS2LBA_END;
                    end
                end
                CHS2LBA_END: begin
                    chs2lba_head_count  <= chs2lba_head_count;
                    chs2lba_spt_count   <= chs2lba_spt_count;
                    chs2lba_calc_temp   <= chs2lba_calc_temp;
                    chs2lba             <= chs2lba;
                    chs2lba_state       <= CHS2LBA_END;
                end
                default: begin
                    chs2lba_head_count  <= chs2lba_head_count;
                    chs2lba_spt_count   <= chs2lba_spt_count;
                    chs2lba_calc_temp   <= chs2lba_calc_temp;
                    chs2lba             <= chs2lba;
                    chs2lba_state       <= CHS2LBA_1;
                end
            endcase
        end
    end

    assign  end_chs2lba = (chs2lba_state == CHS2LBA_END);


    //
    // FIFO
    //
    logic   [7:0]   fifo[access_block_size-1:0];
    logic   [7:0]   fifo_in;
    logic           shift_fifo;

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            fifo[0] <= 8'h00;
        else if (shift_fifo)
            fifo[0] <= fifo_in;
        else
            fifo[0] <= fifo[0];
    end

    genvar fifo_index;
    generate
    for (fifo_index = 1; fifo_index < access_block_size; fifo_index = fifo_index + 1) begin: Fifo_Shift
        always_ff @(posedge clock, posedge reset) begin
            if (reset)
                fifo[fifo_index]    <= 8'h00;
            else if (shift_fifo)
                fifo[fifo_index]    <= fifo[fifo_index-1];
            else
                fifo[fifo_index]    <= fifo[fifo_index];
        end
    end
    endgenerate


    //
    // Registers
    //
    // status
    logic           busy;
    logic           device_ready;
    logic           data_request;
    logic           error_flag;
    wire    [7:0]   status  = {busy, device_ready, 2'b00, data_request, 2'b00, error_flag};

    // error
    logic   [7:0]   error;

    logic   [7:0]   features;
    logic   [15:0]  sector_count;
    logic   [15:0]  sector_number;      // in CHS mode, use only 8 bit.(S)
    logic   [31:0]  cylinder;           // in CHS mode, use only 16 bit.(C)
    logic   [3:0]   head_number;        // (H)
    logic           select_drive;
    logic           select_lba;

    wire    [27:0]  lba28_address   = {head_number, cylinder[15:0], sector_number[7:0]};
    wire    [47:0]  lba48_address   = {cylinder[31:16], sector_number[15:8], cylinder[15:0], sector_number[7:0]};


    //
    // Identify
    //
    logic   [15:0]  identify[256:0];
    logic   [9:0]   identify_index;
    wire    [15:0]  identify_out    = identify[identify_index[8:1]];


    //
    // Command Control
    //
    typedef enum {RESET, WAIT_TO_RESET, CALC_STORAGE_CHS, IDLE, EXEC_COMMAND,
                    CMD_DEVICE_RESET,
                    CMD_EXE_DEVICE_DIAG,
                    CMD_IDENTIFY_DEVICE_1, CMD_IDENTIFY_DEVICE_2,
                    CMD_INIT_DEVICE_PARAM,
                    CMD_READ_1, CMD_READ_2, CMD_READ_3, CMD_READ_4, CMD_READ_5, CMD_READ_6,
                    CMD_WRITE_1, CMD_WRITE_2, CMD_WRITE_3, CMD_WRITE_4, CMD_WRITE_5, CMD_WRITE_6, CMD_WRITE_7, CMD_WRITE_8,
                    CMD_SEEK,
                    CMD_NO_SUPPORT,
                    SET_BLOCK_ADDRESS,
                    TRANS_SECTOR_1, TRANS_SECTOR_2, TRANS_SECTOR_3, TRANS_SECTOR_4, TRANS_SECTOR_5
                } state_t;
    state_t state;
    state_t ret_state;
    logic   [7:0]   command;
    logic   [10:0]  trans_fifo_index;
    logic   [31:0]  mmc_access_block;
    logic   [8:0]   remaining_sector_count;

    always_ff @(posedge clock, posedge reset) begin
        if (reset) begin
            state                       <= RESET;
            ret_state                   <= RESET;
            mmc_reset                   <= 1'b0;
            // registers
            busy                        <= 1'b1;
            device_ready                <= 1'b0;
            data_request                <= 1'b0;
            error_flag                  <= 1'b0;
            error                       <= 8'h01;
            // geometory
            calc_storage_chs            <= 1'b0;
            logical_cylinder            <= 16'h03FF;
            logical_head                <= 4'hF;
            logical_spt                 <= 8'h3F;
            // fifo
            fifo_in                     <= 1'b00;
            shift_fifo                  <= 1'b0;
            // commands
            identify_index              <= 10'h000;
            // mmc
            mmc_data_bus                <= 8'hFF;
            mmc_ext_data_bus            <= 24'hFFFFFF;
            mmc_write_block_address     <= 1'b0;
            mmc_write_access_command    <= 1'b0;
            mmc_write_data              <= 1'b0;
            mmc_read_data               <= 1'b0;
            // IDE command
            command                     <= 8'h00;
            trans_fifo_index            <= 10'h000;
            mmc_access_block            <= 32'h00000000;
            remaining_sector_count      <= 9'h000;
        end
        else if ((write_control) && (latch_address == 3'b110) && (latch_data[2] == 1'b1)) begin
            mmc_reset                   <= 1'b1;
        end
        else if (mmc_reset) begin
            mmc_reset                   <= 1'b0;
            state                       <= RESET;
            busy                        <= 1'b1;
            device_ready                <= 1'b0;
        end
        else begin
            casez (state)
                RESET: begin
                    state                       <= WAIT_TO_RESET;
                    mmc_reset                   <= 1'b0;
                    // registers
                    busy                        <= 1'b1;
                    device_ready                <= 1'b0;
                    data_request                <= 1'b0;
                    error_flag                  <= 1'b0;
                    error                       <= 8'h01;
                    // mmc
                    mmc_data_bus                <= 8'hFF;
                    mmc_ext_data_bus            <= 24'hFFFFFF;
                    mmc_write_block_address     <= 1'b0;
                    mmc_write_access_command    <= 1'b0;
                    mmc_write_data              <= 1'b0;
                    mmc_read_data               <= 1'b0;
                    // IDE command
                    command                     <= 8'h00;
                    trans_fifo_index            <= 10'h000;
                end

                WAIT_TO_RESET: begin
                    if (~mmc_drive_busy)
                        state                   <= CALC_STORAGE_CHS;
                end

                CALC_STORAGE_CHS: begin
                    calc_storage_chs            <= 1'b1;
                    logical_cylinder            <= storage_cylinder;
                    logical_head                <= storage_head;
                    logical_spt                 <= storage_spt;

                    if (end_of_storage_chs_calc) begin
                        calc_storage_chs        <= 1'b0;
                        state                   <= IDLE;
                    end
                end

                IDLE: begin
                    if ((~write_command) || (latch_address != 3'b111) || (~device_master != select_drive)) begin
                        // Wait Command
                        busy                    <= 1'b0;
                        device_ready            <= 1'b1;
                    end
                    else begin
                        busy                    <= 1'b1;
                        device_ready            <= 1'b0;
                        command                 <= latch_data;
                        state                   <= EXEC_COMMAND;
                    end
                end

                EXEC_COMMAND: begin
                    busy                        <= 1'b1;
                    device_ready                <= 1'b0;
                    data_request                <= 1'b0;
                    error_flag                  <= 1'b0;
                    error                       <= 8'b00000000;

                    casez (command)
                        8'h08: state            <= CMD_DEVICE_RESET;        // DEVICE_RESET
                        8'h90: state            <= CMD_EXE_DEVICE_DIAG;     // EXECUTE DEVICE DIAGNOSTIC
                        8'hEC: state            <= CMD_IDENTIFY_DEVICE_1;   // IDENTIFY DEVICE
                        8'hEF: state            <= CMD_NO_SUPPORT;          // SET FEATURES
                        8'h91: state            <= CMD_INIT_DEVICE_PARAM;   // INITIALIZE DEVICE PARAMETERS
                        8'h20: state            <= CMD_READ_1;              // READ SECTOR(S)
                        8'h21: state            <= CMD_READ_1;              // READ SECTOR(S) with retry
                        8'h30: state            <= CMD_WRITE_1;             // WRITE SECTOR(S)
                        8'h31: state            <= CMD_WRITE_1;             // WRITE SECTOR(S) with retry
                        8'h40: state            <= CMD_READ_1;              // READ VERIFY SECTOR(S)
                        8'h41: state            <= CMD_READ_1;              // READ VERIFY SECTOR(S) with retry
                        8'h70: state            <= CMD_SEEK;                // SEEK
                        default: state          <= CMD_NO_SUPPORT;
                    endcase
                end

                CMD_DEVICE_RESET: begin
                    mmc_reset                   <= 1'b1;
                    state                       <= WAIT_TO_RESET;
                end

                CMD_EXE_DEVICE_DIAG: begin
                    mmc_reset                   <= 1'b1;
                    state                       <= WAIT_TO_RESET;
                end

                CMD_IDENTIFY_DEVICE_1: begin
                    identify_index              <= 10'h000;
                    state                       <= CMD_IDENTIFY_DEVICE_2;
                end

                CMD_IDENTIFY_DEVICE_2: begin
                    if (identify_index < access_block_size) begin
                        identify_index          <= identify_index + 1'b1;
                        fifo_in                 <= identify_index[0] ? identify_out[15:8] : identify_out[7:0];
                        shift_fifo              <= 1'b1;
                    end
                    else begin
                        fifo_in                 <= 8'h00;
                        shift_fifo              <= 1'b0;
                        ret_state               <= IDLE;
                        state                   <= TRANS_SECTOR_1;
                    end
                end

                CMD_INIT_DEVICE_PARAM: begin
                    logical_head                <= head_number;
                    logical_spt                 <= sector_count[7:0];
                    logical_cylinder            <= result_calc_logical_cylinder;

                    if (~end_logical_cylinder) begin
                        start_logical_cylinder  <= 1'b1;
                    end
                    else begin
                        start_logical_cylinder  <= 1'b0;
                        state                   <= IDLE;
                    end
                end

                // Set sector count and calculate LBA
                CMD_READ_1: begin
                    state                       <= SET_BLOCK_ADDRESS;
                    ret_state                   <= CMD_READ_2;
                end

                // Set Address to MMC drive
                CMD_READ_2: begin
                    mmc_data_bus                <= mmc_access_block[7:0];
                    mmc_ext_data_bus            <= mmc_access_block[31:8];

                    if (|remaining_sector_count) begin
                        if (mmc_drive_busy) begin
                            mmc_read_data           <= 1'b1;    // Dummy read
                        end
                        else begin
                            mmc_read_data           <= 1'b0;
                            // Start block read
                            mmc_write_block_address <= 1'b1;
                            state                   <= CMD_READ_3;
                        end
                    end
                    else begin
                        // Complete
                        state                   <= IDLE;
                    end
                end

                // Start block read
                CMD_READ_3: begin
                    mmc_data_bus                <= 8'h80;   // 0x80 = Read command
                    mmc_write_block_address     <= 1'b0;
                    mmc_write_access_command    <= 1'b1;
                    state                       <= CMD_READ_4;
                end

                // Wait
                CMD_READ_4: begin
                    mmc_write_access_command    <= 1'b0;

                    if (mmc_read_interface_error | mmc_read_crc_error) begin
                        shift_fifo              <= 1'b0;
                        mmc_read_data           <= 1'b1;    // Dummy read
                        error_flag              <= 1'b1;
                        error                   <= 8'b01000000;
                        state                   <= CMD_READ_6;
                    end
                    else if (mmc_read_completion_interrupt) begin
                        shift_fifo              <= 1'b0;
                        mmc_read_data           <= 1'b1;    // Dummy read
                        remaining_sector_count  <= remaining_sector_count - 1'b1;
                        state                   <= CMD_READ_6;
                    end
                    else if (mmc_read_byte_interrupt) begin
                        fifo_in                 <= mmc_read_data_byte;
                        shift_fifo              <= 1'b1;
                        mmc_read_data           <= 1'b1;
                        state                   <= CMD_READ_5;
                    end
                    else begin
                        shift_fifo              <= 1'b0;
                        mmc_read_data           <= 1'b0;
                    end
                end

                // Read
                CMD_READ_5: begin
                    shift_fifo                  <= 1'b0;
                    mmc_read_data               <= 1'b0;
                    state                       <= CMD_READ_4;
                end

                // End of block read
                CMD_READ_6: begin
                    shift_fifo                  <= 1'b0;
                    mmc_read_data               <= 1'b0;
                    mmc_access_block            <= mmc_access_block + 1'b1;

                    if (error_flag)
                        state                   <= IDLE;
                    else if ((command == 8'h40) || (command == 8'h41))
                        state                   <= CMD_READ_2;
                    else begin
                        state                   <= TRANS_SECTOR_1;
                        ret_state               <= CMD_READ_2;
                    end
                end


                // Set sector count and calculate LBA
                CMD_WRITE_1: begin
                    state                       <= SET_BLOCK_ADDRESS;
                    ret_state                   <= CMD_WRITE_2;
                end

                // Set Address to MMC drive
                CMD_WRITE_2: begin
                    mmc_data_bus                <= mmc_access_block[7:0];
                    mmc_ext_data_bus            <= mmc_access_block[31:8];

                    if (|remaining_sector_count) begin
                        mmc_write_block_address <= 1'b1;
                        trans_fifo_index        <= access_block_size;
                        state                   <= CMD_WRITE_3;
                    end
                    else begin
                        // Complete
                        state                   <= IDLE;
                    end
                end

                // Get data from host
                CMD_WRITE_3: begin
                    busy                        <= 1'b0;
                    data_request                <= 1'b1;
                    mmc_write_block_address     <= 1'b0;
                    fifo_in                     <= latch_data[7:0];

                    if ((~write_command) || (ide_address != 3'b000)) begin
                        shift_fifo              <= 1'b0;
                    end
                    else begin
                        shift_fifo              <= 1'b1;
                        trans_fifo_index        <= {(trans_fifo_index[10:1] - 1'b1), 1'b0};
                        state                   <= CMD_WRITE_4;
                    end
                end

                CMD_WRITE_4: begin
                    fifo_in                     <= latch_data[15:8];
                    shift_fifo                  <= 1'b1;

                    if (|trans_fifo_index)
                        state                   <= CMD_WRITE_3;
                    else begin
                        busy                    <= 1'b1;
                        data_request            <= 1'b0;
                        state                   <= CMD_WRITE_5;
                    end
                end

                // Start block write
                CMD_WRITE_5: begin
                    if (mmc_drive_busy) begin
                        mmc_read_data               <= 1'b1;    // Dummy read
                    end
                    else begin
                        mmc_read_data               <= 1'b0;
                        shift_fifo                  <= 1'b0;
                        mmc_data_bus                <= 8'h81;   // 0x81 = Write command
                        mmc_write_access_command    <= 1'b1;
                        state                       <= CMD_WRITE_6;
                    end
                end

                // Wait
                CMD_WRITE_6: begin
                    mmc_write_access_command    <= 1'b0;

                    if (mmc_write_interface_error) begin
                        shift_fifo              <= 1'b0;
                        mmc_read_data           <= 1'b1;    // Dummy read
                        mmc_write_data          <= 1'b0;
                        error_flag              <= 1'b1;
                        error                   <= 8'b01000000;
                        state                   <= CMD_WRITE_8;
                    end
                    else if (mmc_write_completion_interrupt) begin
                        shift_fifo              <= 1'b0;
                        mmc_read_data           <= 1'b1;    // Dummy read
                        mmc_write_data          <= 1'b0;
                        remaining_sector_count  <= remaining_sector_count - 1'b1;
                        state                   <= CMD_WRITE_8;
                    end
                    else if (mmc_request_write_data_interrupt) begin
                        mmc_data_bus            <= fifo[access_block_size - 1];
                        shift_fifo              <= 1'b1;
                        mmc_read_data           <= 1'b0;
                        mmc_write_data          <= 1'b1;
                        state                   <= CMD_WRITE_7;
                    end
                    else begin
                        shift_fifo              <= 1'b0;
                        mmc_read_data           <= 1'b0;
                        mmc_write_data          <= 1'b0;
                    end
                end

                // Write
                CMD_WRITE_7: begin
                    shift_fifo                  <= 1'b0;
                    mmc_write_data              <= 1'b0;

                    if (~mmc_request_write_data_interrupt)
                        state                   <= CMD_WRITE_6;
                end

                // End of block write
                CMD_WRITE_8: begin
                    shift_fifo                  <= 1'b0;
                    mmc_read_data               <= 1'b0;
                    mmc_write_data              <= 1'b0;
                    mmc_access_block            <= mmc_access_block + 1'b1;

                    if (error_flag)
                        state                   <= IDLE;
                    else begin
                        state                   <= CMD_WRITE_2;
                    end
                end

                CMD_SEEK: begin
                    state                       <= IDLE;
                end

                CMD_NO_SUPPORT: begin
                    error_flag                  <= 1'b1;
                    error                       <= 8'b00000100;
                    state                       <= IDLE;
                end



                SET_BLOCK_ADDRESS: begin
                    // Set sector count (256-1)
                    remaining_sector_count      <= {(sector_count[7:0] == 8'h000 ? 1'b1 : 1'b0), sector_count[7:0]};

                    if (select_lba) begin
                        // LBA
                        start_chs2lba           <= 1'b0;
                        mmc_access_block        <= {4'h0, lba28_address};
                        state                   <= ret_state;
                    end
                    else if (~end_chs2lba) begin
                        // Calc chs2lba
                        start_chs2lba           <= 1'b1;
                    end
                    else begin
                        start_chs2lba           <= 1'b0;
                        mmc_access_block        <= chs2lba;
                        state                   <= ret_state;
                    end
                end



                TRANS_SECTOR_1: begin
                    trans_fifo_index            <= access_block_size;
                    state                       <= TRANS_SECTOR_2;
                end

                TRANS_SECTOR_2: begin
                    busy                        <= 1'b0;
                    data_request                <= 1'b1;

                    if ((read_edge) && (command_cs) && (ide_address == 3'b000)) begin
                        shift_fifo              <= 1'b1;
                        state                   <= TRANS_SECTOR_3;
                    end
                end

                TRANS_SECTOR_3: begin
                    trans_fifo_index            <= {(trans_fifo_index[10:1] - 1'b1), 1'b0};
                    shift_fifo                  <= 1'b1;
                    state                       <= TRANS_SECTOR_4;
                end

                TRANS_SECTOR_4: begin
                    shift_fifo                  <= 1'b0;

                    if (|trans_fifo_index) begin
                        state                   <= TRANS_SECTOR_2;
                    end
                    else begin
                        busy                    <= 1'b1;
                        data_request            <= 1'b0;
                        state                   <= ret_state;
                    end
                end

                default: begin
                    state   <= WAIT_TO_RESET;
                end
            endcase
        end
    end


    //
    // Update Features Register
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            features            <= 8'h00;
        else if (mmc_reset)
            features            <= 8'h00;
        else if (write_command && (latch_address == 3'b001))
            features            <= latch_data;
        else
            features            <= features;
    end


    //
    // Update Sector Count Register
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            sector_count        <= 16'h0001;
        else if (mmc_reset)
            sector_count        <= 16'h0001;
        else if (write_command && (latch_address == 3'b010))
            sector_count        <= {sector_count[7:0], latch_data[7:0]};
        else
            sector_count        <= sector_count;
    end


    //
    // Update sector Number Register
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            sector_number       <= 16'h0001;
        else if (mmc_reset)
            sector_number       <= 16'h0001;
        else if (write_command && (latch_address == 3'b011))
            sector_number       <= {sector_number[7:0], latch_data[7:0]};
        else
            sector_number       <= sector_number;
    end


    //
    // Update Cylinder Register
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            cylinder            <= 32'h00000000;
        else if (mmc_reset)
            cylinder            <= 32'h00000000;
        else if (write_command && (latch_address == 3'b100))
            cylinder            <= {cylinder[31:24], cylinder[7:0],   cylinder[15:8],  latch_data[7:0]};
        else if (write_command && (latch_address == 3'b101))
            cylinder            <= {cylinder[15:8],  cylinder[23:16], latch_data[7:0], cylinder[7:0]  };
        else
            cylinder            <= cylinder;
    end


    //
    // Update Drive / Head Register
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            head_number         <= 4'h0;
        else if (mmc_reset)
            head_number         <= 4'h0;
        else if (write_command && (latch_address == 3'b110))
            head_number         <= latch_data[3:0];
        else
            head_number         <= head_number;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            select_drive        <= 1'b0;
        else if (mmc_reset)
            select_drive        <= 1'b0;
        else if (write_command && (latch_address == 3'b110))
            select_drive        <= latch_data[4];
        else
            select_drive        <= select_drive;
    end

    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            select_lba          <= 1'b0;
        else if (mmc_reset)
            select_lba          <= 1'b0;
        else if (write_command && (latch_address == 3'b110))
            select_lba          <= latch_data[6];
        else
            select_lba          <= select_lba;
    end


    //
    // Read
    //
    always_ff @(posedge clock, posedge reset) begin
        if (reset)
            ide_data_bus_out    <= 16'hFFFF;
        else if (~read_edge)
            ide_data_bus_out    <= ide_data_bus_out;
        else if (command_cs)
            casez (ide_address)
                3'b000: // Data Register
                    ide_data_bus_out <= {fifo[access_block_size - 2], fifo[access_block_size - 1]};
                3'b001: // Error Register
                    ide_data_bus_out <= {8'h00, error};
                3'b010: // Sector Count Register
                    ide_data_bus_out <= {8'h00, sector_count[7:0]};
                3'b011: // Sector Number Register (or LBAlo)
                    ide_data_bus_out <= {8'h00, sector_number[7:0]};
                3'b100: // Cylinder Low Register (or LBAmid)
                    ide_data_bus_out <= {8'h00, cylinder[7:0]};
                3'b101: // Cylinder High Register (or LBAhi)
                    ide_data_bus_out <= {8'h00, cylinder[15:8]};
                3'b110: // Drive / Head Register
                    ide_data_bus_out <= {1'b1, select_lba, 1'b1, select_drive, head_number};
                3'b111: // Status Register
                    ide_data_bus_out <= {8'h00, status};
                default:
                    ide_data_bus_out <= 16'hFFFF;
            endcase
        else if (control_cs)
            casez (ide_address[0])
                1'b0:   // Status Register
                    ide_data_bus_out <= {8'h00, status};
                1'b1:   // Drive Address Register
                    ide_data_bus_out <= {1'b0, 1'b1, head_number, ~select_drive, select_drive};
                default:
                    ide_data_bus_out <= 16'hFFFF;
            endcase
        else
            ide_data_bus_out    <= ide_data_bus_out;
    end


    //
    // Identify
    //
    assign  identify[  0]   = 16'b0000_0000_0100_0000;
    assign  identify[  1]   = storage_cylinder;
    assign  identify[  2]   = 16'h0000;
    assign  identify[  3]   = {12'h000, storage_head};
    assign  identify[  4]   = 16'h0000;
    assign  identify[  5]   = 16'h0000;
    assign  identify[  6]   = {8'h00, storage_spt};
    assign  identify[  7]   = 16'h0000;
    assign  identify[  8]   = 16'h0000;
    assign  identify[  9]   = 16'h0000;

    assign  identify[ 10]   = {8'h4B, 8'h46};
    assign  identify[ 11]   = {8'h4D, 8'h4D};
    assign  identify[ 12]   = {8'h43, 8'h49};
    assign  identify[ 13]   = {8'h44, 8'h45};
    assign  identify[ 14]   = {8'h30, 8'h30};
    assign  identify[ 15]   = {8'h30, 8'h30};
    assign  identify[ 16]   = {8'h30, 8'h20};
    assign  identify[ 17]   = {8'h20, 8'h20};
    assign  identify[ 18]   = {8'h20, 8'h20};
    assign  identify[ 19]   = {8'h20, 8'h20};

    assign  identify[ 20]   = 16'h0000;
    assign  identify[ 21]   = 16'h0000;
    assign  identify[ 22]   = 16'h0000;
    assign  identify[ 23]   = {8'h30, 8'h30};
    assign  identify[ 24]   = {8'h30, 8'h30};
    assign  identify[ 25]   = {8'h30, 8'h30};
    assign  identify[ 26]   = {8'h30, 8'h30};
    assign  identify[ 27]   = {8'h4B, 8'h46};
    assign  identify[ 28]   = {8'h4D, 8'h4D};
    assign  identify[ 29]   = {8'h43, 8'h49};

    assign  identify[ 30]   = {8'h44, 8'h45};
    assign  identify[ 31]   = {8'h30, 8'h30};
    assign  identify[ 32]   = {8'h30, 8'h30};
    assign  identify[ 33]   = {8'h30, 8'h20};
    assign  identify[ 34]   = {8'h20, 8'h20};
    assign  identify[ 35]   = {8'h20, 8'h20};
    assign  identify[ 36]   = {8'h20, 8'h20};
    assign  identify[ 37]   = {8'h20, 8'h20};
    assign  identify[ 38]   = {8'h20, 8'h20};
    assign  identify[ 39]   = {8'h20, 8'h20};

    assign  identify[ 40]   = {8'h20, 8'h20};
    assign  identify[ 41]   = {8'h20, 8'h20};
    assign  identify[ 42]   = {8'h20, 8'h20};
    assign  identify[ 43]   = {8'h20, 8'h20};
    assign  identify[ 44]   = {8'h20, 8'h20};
    assign  identify[ 45]   = {8'h20, 8'h20};
    assign  identify[ 46]   = {8'h20, 8'h20};
    assign  identify[ 47]   = {8'h80, 8'h01};
    assign  identify[ 48]   = 16'h0000;
    assign  identify[ 49]   = 16'b0000_0010_0000_0000;

    assign  identify[ 50]   = 16'b0100_0000_0000_0001;
    assign  identify[ 51]   = 16'h200;
    assign  identify[ 52]   = 16'h200;
    assign  identify[ 53]   = 16'b0000_0000_0000_0111;
    assign  identify[ 54]   = logical_cylinder;
    assign  identify[ 55]   = {12'h000, logical_head};
    assign  identify[ 56]   = {8'h00, logical_spt};
    assign  identify[ 57]   = storage_total_sectors[15:0];
    assign  identify[ 58]   = storage_total_sectors[31:16];
    assign  identify[ 59]   = 16'b0000_0000_0000_0000;

    assign  identify[ 60]   = storage_total_sectors[15:0];
    assign  identify[ 61]   = storage_total_sectors[31:16];
    assign  identify[ 62]   = 16'h0000;
    assign  identify[ 63]   = 16'b0000_0000_0000_0000;
    assign  identify[ 64]   = 16'b0000_0000_0000_0000;
    assign  identify[ 65]   = 16'h0078;
    assign  identify[ 66]   = 16'h0078;
    assign  identify[ 67]   = 16'h0078;
    assign  identify[ 68]   = 16'h0078;
    assign  identify[ 69]   = 16'h0000;

    assign  identify[ 70]   = 16'h0000;
    assign  identify[ 71]   = 16'h0000;
    assign  identify[ 72]   = 16'h0000;
    assign  identify[ 73]   = 16'h0000;
    assign  identify[ 74]   = 16'h0000;
    assign  identify[ 75]   = 16'h0000;
    assign  identify[ 76]   = 16'h0000;
    assign  identify[ 77]   = 16'h0000;
    assign  identify[ 78]   = 16'h0000;
    assign  identify[ 79]   = 16'h0000;

    assign  identify[ 80]   = 16'b0000_0000_0111_1110;
    assign  identify[ 81]   = 16'h0000;
    assign  identify[ 82]   = 16'b0000_0000_0000_0000;
    assign  identify[ 83]   = 16'b0000_0000_0000_0000;
    assign  identify[ 84]   = 16'b0000_0000_0000_0000;
    assign  identify[ 85]   = 16'b0000_0000_0000_0000;
    assign  identify[ 86]   = 16'b0000_0000_0000_0000;
    assign  identify[ 87]   = 16'b0000_0000_0000_0000;
    assign  identify[ 88]   = 16'b0000_0000_0000_0000;
    assign  identify[ 89]   = 16'h0000;

    assign  identify[ 90]   = 16'h0000;
    assign  identify[ 91]   = 16'h0000;
    assign  identify[ 92]   = 16'h0000;
    assign  identify[ 93]   = 16'b0110_0011_0000_1011;
    assign  identify[ 94]   = 16'h0000;
    assign  identify[ 95]   = 16'h0000;
    assign  identify[ 96]   = 16'h0000;
    assign  identify[ 97]   = 16'h0000;
    assign  identify[ 98]   = 16'h0000;
    assign  identify[ 99]   = 16'h0000;

    assign  identify[100]   = 16'h0000; // LBA48
    assign  identify[101]   = 16'h0000; // LBA48
    assign  identify[102]   = 16'h0000; // LBA48
    assign  identify[103]   = 16'h0000; // LBA48
    assign  identify[104]   = 16'h0000;
    assign  identify[105]   = 16'h0000;
    assign  identify[106]   = 16'h0000;
    assign  identify[107]   = 16'h0000;
    assign  identify[108]   = 16'h0000;
    assign  identify[109]   = 16'h0000;

    assign  identify[110]   = 16'h0000;
    assign  identify[111]   = 16'h0000;
    assign  identify[112]   = 16'h0000;
    assign  identify[113]   = 16'h0000;
    assign  identify[114]   = 16'h0000;
    assign  identify[115]   = 16'h0000;
    assign  identify[116]   = 16'h0000;
    assign  identify[117]   = 16'h0000;
    assign  identify[118]   = 16'h0000;
    assign  identify[119]   = 16'h0000;

    assign  identify[120]   = 16'h0000;
    assign  identify[121]   = 16'h0000;
    assign  identify[122]   = 16'h0000;
    assign  identify[123]   = 16'h0000;
    assign  identify[124]   = 16'h0000;
    assign  identify[125]   = 16'h0000;
    assign  identify[126]   = 16'h0000;
    assign  identify[127]   = 16'h0000;
    assign  identify[128]   = 16'h0000;
    assign  identify[129]   = 16'h0000;

    assign  identify[130]   = 16'h0000;
    assign  identify[131]   = 16'h0000;
    assign  identify[132]   = 16'h0000;
    assign  identify[133]   = 16'h0000;
    assign  identify[134]   = 16'h0000;
    assign  identify[135]   = 16'h0000;
    assign  identify[136]   = 16'h0000;
    assign  identify[137]   = 16'h0000;
    assign  identify[138]   = 16'h0000;
    assign  identify[139]   = 16'h0000;

    assign  identify[140]   = 16'h0000;
    assign  identify[141]   = 16'h0000;
    assign  identify[142]   = 16'h0000;
    assign  identify[143]   = 16'h0000;
    assign  identify[144]   = 16'h0000;
    assign  identify[145]   = 16'h0000;
    assign  identify[146]   = 16'h0000;
    assign  identify[147]   = 16'h0000;
    assign  identify[148]   = 16'h0000;
    assign  identify[149]   = 16'h0000;

    assign  identify[150]   = 16'h0000;
    assign  identify[151]   = 16'h0000;
    assign  identify[152]   = 16'h0000;
    assign  identify[153]   = 16'h0000;
    assign  identify[154]   = 16'h0000;
    assign  identify[155]   = 16'h0000;
    assign  identify[156]   = 16'h0000;
    assign  identify[157]   = 16'h0000;
    assign  identify[158]   = 16'h0000;
    assign  identify[159]   = 16'h0000;

    assign  identify[160]   = 16'h0000;
    assign  identify[161]   = 16'h0000;
    assign  identify[162]   = 16'h0000;
    assign  identify[163]   = 16'h0000;
    assign  identify[164]   = 16'h0000;
    assign  identify[165]   = 16'h0000;
    assign  identify[166]   = 16'h0000;
    assign  identify[167]   = 16'h0000;
    assign  identify[168]   = 16'h0000;
    assign  identify[169]   = 16'h0000;

    assign  identify[170]   = 16'h0000;
    assign  identify[171]   = 16'h0000;
    assign  identify[172]   = 16'h0000;
    assign  identify[173]   = 16'h0000;
    assign  identify[174]   = 16'h0000;
    assign  identify[175]   = 16'h0000;
    assign  identify[176]   = 16'h0000;
    assign  identify[177]   = 16'h0000;
    assign  identify[178]   = 16'h0000;
    assign  identify[179]   = 16'h0000;

    assign  identify[180]   = 16'h0000;
    assign  identify[181]   = 16'h0000;
    assign  identify[182]   = 16'h0000;
    assign  identify[183]   = 16'h0000;
    assign  identify[184]   = 16'h0000;
    assign  identify[185]   = 16'h0000;
    assign  identify[186]   = 16'h0000;
    assign  identify[187]   = 16'h0000;
    assign  identify[188]   = 16'h0000;
    assign  identify[189]   = 16'h0000;

    assign  identify[190]   = 16'h0000;
    assign  identify[191]   = 16'h0000;
    assign  identify[192]   = 16'h0000;
    assign  identify[193]   = 16'h0000;
    assign  identify[194]   = 16'h0000;
    assign  identify[195]   = 16'h0000;
    assign  identify[196]   = 16'h0000;
    assign  identify[197]   = 16'h0000;
    assign  identify[198]   = 16'h0000;
    assign  identify[199]   = 16'h0000;

    assign  identify[200]   = 16'h0000;
    assign  identify[201]   = 16'h0000;
    assign  identify[202]   = 16'h0000;
    assign  identify[203]   = 16'h0000;
    assign  identify[204]   = 16'h0000;
    assign  identify[205]   = 16'h0000;
    assign  identify[206]   = 16'h0000;
    assign  identify[207]   = 16'h0000;
    assign  identify[208]   = 16'h0000;
    assign  identify[209]   = 16'h0000;

    assign  identify[210]   = 16'h0000;
    assign  identify[211]   = 16'h0000;
    assign  identify[212]   = 16'h0000;
    assign  identify[213]   = 16'h0000;
    assign  identify[214]   = 16'h0000;
    assign  identify[215]   = 16'h0000;
    assign  identify[216]   = 16'h0000;
    assign  identify[217]   = 16'h0000;
    assign  identify[218]   = 16'h0000;
    assign  identify[219]   = 16'h0000;

    assign  identify[220]   = 16'h0000;
    assign  identify[221]   = 16'h0000;
    assign  identify[222]   = 16'h0000;
    assign  identify[223]   = 16'h0000;
    assign  identify[224]   = 16'h0000;
    assign  identify[225]   = 16'h0000;
    assign  identify[226]   = 16'h0000;
    assign  identify[227]   = 16'h0000;
    assign  identify[228]   = 16'h0000;
    assign  identify[229]   = 16'h0000;

    assign  identify[230]   = 16'h0000;
    assign  identify[231]   = 16'h0000;
    assign  identify[232]   = 16'h0000;
    assign  identify[233]   = 16'h0000;
    assign  identify[234]   = 16'h0000;
    assign  identify[235]   = 16'h0000;
    assign  identify[236]   = 16'h0000;
    assign  identify[237]   = 16'h0000;
    assign  identify[238]   = 16'h0000;
    assign  identify[239]   = 16'h0000;

    assign  identify[240]   = 16'h0000;
    assign  identify[241]   = 16'h0000;
    assign  identify[242]   = 16'h0000;
    assign  identify[243]   = 16'h0000;
    assign  identify[244]   = 16'h0000;
    assign  identify[245]   = 16'h0000;
    assign  identify[246]   = 16'h0000;
    assign  identify[247]   = 16'h0000;
    assign  identify[248]   = 16'h0000;
    assign  identify[249]   = 16'h0000;

    assign  identify[250]   = 16'h0000;
    assign  identify[251]   = 16'h0000;
    assign  identify[252]   = 16'h0000;
    assign  identify[253]   = 16'h0000;
    assign  identify[254]   = 16'h0000;
    assign  identify[255]   = 16'h0000;

endmodule

