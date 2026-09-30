// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// Physical IO buffer module for Tang Nano 9K internal PSRAM
// Handles tri-state buffers and center-aligned clock outputs for Channel 0 & Channel 1
`timescale 1ns / 1ps

module psram_phy_io (
    input  wire        clk,          // System clock (27MHz)
    input  wire        rst_n,
    input  wire        psram_ck_reg, // 13.5MHz toggling clock signal from controller (updated on posedge clk)
    input  wire        ck_en,        // 1: output clock, 0: idle low
    input  wire [1:0]  cs_n_in,      // Active-low Chip Select
    input  wire [1:0]  reset_n_in,   // Active-low Hardware Reset
    input  wire        dq_oe,        // Data bus Output Enable (1: FPGA drives DQ)
    input  wire [15:0] dq_out,       // Data bus output
    output wire [15:0] dq_in,        // Data bus input
    input  wire        rwds_oe,      // RWDS Output Enable (1: FPGA drives RWDS as mask)
    input  wire [1:0]  rwds_out,     // RWDS output (byte mask: 0=write, 1=mask)
    output wire [1:0]  rwds_in,      // RWDS input (strobe/latency flag)

    // FPGA Physical Pins connected to internal PSRAM
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds
);

    // Drive PSRAM CK on negative edge of 27MHz system clock
    // Controller updates DQ/CA on posedge clk; registering CK on negedge clk
    // creates an exact 18.5ns (quarter-cycle of 13.5MHz) phase shift,
    // ensuring perfect Center-Aligned timing with 18.5ns setup & hold margin!
    reg psram_ck_q;
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psram_ck_q <= 1'b0;
        end else begin
            psram_ck_q <= ck_en ? psram_ck_reg : 1'b0;
        end
    end

    assign O_psram_ck[0]      = psram_ck_q;
    assign O_psram_ck[1]      = psram_ck_q;
    assign O_psram_ck_n[0]    = ~psram_ck_q;
    assign O_psram_ck_n[1]    = ~psram_ck_q;

    assign O_psram_cs_n[0]    = cs_n_in[0];
    assign O_psram_cs_n[1]    = cs_n_in[1];

    assign O_psram_reset_n[0] = reset_n_in[0];
    assign O_psram_reset_n[1] = reset_n_in[1];

    // DQ Tri-state buffers
    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : gen_dq
            assign IO_psram_dq[i] = dq_oe ? dq_out[i] : 1'bz;
            assign dq_in[i]       = IO_psram_dq[i];
        end
    endgenerate

    // RWDS Tri-state buffers
    genvar j;
    generate
        for (j = 0; j < 2; j = j + 1) begin : gen_rwds
            assign IO_psram_rwds[j] = rwds_oe ? rwds_out[j] : 1'bz;
            assign rwds_in[j]       = IO_psram_rwds[j];
        end
    endgenerate

endmodule
