// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// cocotb toplevel: psram_controller connected to the W955D8MBYA model.
// The clock and the host interface are driven from Python (sim/tests/).
`timescale 1ns / 1ps

module tb_psram_controller #(
    parameter integer CLK_HZ = 27_000_000
);
    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         req_valid = 1'b0;
    wire        req_ready;
    reg         req_we = 1'b0;
    reg  [23:0] req_addr = 24'h0;
    reg  [31:0] req_wdata = 32'h0;
    reg  [3:0]  req_wstrb = 4'h0;
    wire        rsp_valid;
    wire [31:0] rsp_rdata;
    wire        init_done;
    wire [31:0] dbg_sample;

    wire [1:0]  psram_ck;
    wire [1:0]  psram_ck_n;
    wire [1:0]  psram_cs_n;
    wire [1:0]  psram_reset_n;
    wire [15:0] psram_dq;
    wire [1:0]  psram_rwds;

    psram_controller #(
        .CLK_HZ(CLK_HZ)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .req_valid      (req_valid),
        .req_ready      (req_ready),
        .req_we         (req_we),
        .req_addr       (req_addr),
        .req_wdata      (req_wdata),
        .req_wstrb      (req_wstrb),
        .rsp_valid      (rsp_valid),
        .rsp_rdata      (rsp_rdata),
        .init_done      (init_done),
        .O_psram_ck     (psram_ck),
        .O_psram_ck_n   (psram_ck_n),
        .O_psram_cs_n   (psram_cs_n),
        .O_psram_reset_n(psram_reset_n),
        .IO_psram_dq    (psram_dq),
        .IO_psram_rwds  (psram_rwds),
        .dbg_sample     (dbg_sample)
    );

    w955d8mbya_model psram (
        .ck     (psram_ck),
        .ck_n   (psram_ck_n),
        .cs_n   (psram_cs_n),
        .reset_n(psram_reset_n),
        .dq     (psram_dq),
        .rwds   (psram_rwds)
    );
endmodule
