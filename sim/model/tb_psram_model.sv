// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// Simulation model for Winbond W955D8MBYA (64Mbit, 2x 32Mb x8 HyperBus PSRAM)
// Clean-room model strictly adhering to W955D8MBYA datasheet specifications
`timescale 1ns / 1ps

module tb_psram_model (
    input  wire [1:0]  ck,
    input  wire [1:0]  ck_n,
    input  wire [1:0]  cs_n,
    input  wire [1:0]  reset_n,
    inout  wire [15:0] dq,
    inout  wire [1:0]  rwds
);
    // 32Mb memory array per channel = 2M 16-bit words
    // For simulation speed and memory footprint, we model a 64K word sparse array
    reg [15:0] mem [0:65535];

    reg [47:0] ca_reg;
    integer    ca_count;
    integer    latency_count;
    reg        in_ca;
    reg        in_latency;
    reg        in_write;
    reg        in_read;
    integer    data_count;

    reg [15:0] dq_out_reg;
    reg        dq_oe_reg;
    reg [1:0]  rwds_out_reg;
    reg        rwds_oe_reg;

    assign dq   = dq_oe_reg ? dq_out_reg : 16'bz;
    assign rwds = rwds_oe_reg ? rwds_out_reg : 2'bz;

    reg [21:0] current_word_addr;
    reg        is_read;
    reg        is_reg;

    initial begin
        ca_count      = 0;
        latency_count = 0;
        in_ca         = 0;
        in_latency    = 0;
        in_write      = 0;
        in_read       = 0;
        data_count    = 0;
        dq_oe_reg     = 0;
        rwds_oe_reg   = 0;
        dq_out_reg    = 16'd0;
        rwds_out_reg  = 2'd0;
        is_read       = 0;
        is_reg        = 0;
    end

    // Transaction start / stop on CS#
    always @(cs_n[0] or reset_n[0]) begin
        if (!reset_n[0] || cs_n[0]) begin
            // Reset or De-select
            ca_count      <= 0;
            latency_count <= 0;
            in_ca         <= 0;
            in_latency    <= 0;
            in_write      <= 0;
            in_read       <= 0;
            data_count    <= 0;
            dq_oe_reg     <= 0;
            rwds_oe_reg   <= 0;
        end else if (!cs_n[0] && reset_n[0]) begin
            // CS# fell active: start Command-Address capture
            ca_count      <= 0;
            latency_count <= 0;
            in_ca         <= 1;
            in_latency    <= 0;
            in_write      <= 0;
            in_read       <= 0;
            data_count    <= 0;
            dq_oe_reg     <= 0;
            // Drive RWDS High during CA to indicate 2x Fixed Latency
            rwds_oe_reg   <= 1;
            rwds_out_reg  <= 2'b11;
        end
    end

    // Process on both CK edges (DDR)
    always @(posedge ck[0] or negedge ck[0]) begin
        if (!cs_n[0] && reset_n[0]) begin
            if (in_ca) begin
                // Capture CA DDR (6 half-cycles = 3 clock cycles)
                ca_reg <= {ca_reg[39:0], dq[7:0]};
                ca_count <= ca_count + 1;

                if (ca_count == 5) begin
                    in_ca         <= 0;
                    in_latency    <= 1;
                    latency_count <= 0;
                    rwds_oe_reg   <= 0; // Release RWDS during latency
                end
            end else if (in_latency) begin
                if (latency_count == 0) begin
                    current_word_addr = {ca_reg[33:22], ca_reg[21:16], ca_reg[2:0]};
                    is_read           = ca_reg[47];
                    is_reg            = ca_reg[46];
                end

                latency_count <= latency_count + 1;

                // Fixed latency = 12 PSRAM clock cycles = 24 DDR half-cycles
                if (latency_count == 23) begin
                    in_latency <= 0;
                    data_count <= 0;
                    if (is_read) begin
                        in_read   <= 1;
                        dq_oe_reg <= 1;
                    end else begin
                        in_write <= 1;
                    end
                end
            end else if (in_write) begin
                // Host writes 16-bit words DDR
                if (rwds[0] == 1'b0) begin
                    mem[current_word_addr[15:0]][7:0] <= dq[7:0];
                end
                if (rwds[1] == 1'b0) begin
                    mem[current_word_addr[15:0]][15:8] <= dq[15:8];
                end
                current_word_addr <= current_word_addr + 1'b1;
                data_count <= data_count + 1;
            end else if (in_read) begin
                if (data_count == 0) begin
                    // First read data half-cycle (between Edge 25 and Edge 26): Word 0
                    if (is_reg) begin
                        dq_out_reg <= 16'h0000;
                    end else begin
                        dq_out_reg <= mem[current_word_addr[15:0]];
                    end
                end else begin
                    // Subsequent read data half-cycles: Word 1, 2, ...
                    current_word_addr <= current_word_addr + 1'b1;
                    if (is_reg) begin
                        dq_out_reg <= 16'h5F5F;
                    end else begin
                        dq_out_reg <= mem[(current_word_addr + 1'b1) & 16'hFFFF];
                    end
                end
                data_count <= data_count + 1;
            end
        end
    end

endmodule
