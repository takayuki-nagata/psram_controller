// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// The PSRAM of the GW1NR-9 QN88P: two independent W955D8MBYA 32Mb x8 dies, each with its
// own CK/CK#/CS#/RESET#/RWDS and DQ byte (die 0: DQ[7:0], die 1: DQ[15:8]).
`timescale 1ns / 1ps

module w955d8mbya_model (
    input  wire [1:0]  ck,
    input  wire [1:0]  ck_n,
    input  wire [1:0]  cs_n,
    input  wire [1:0]  reset_n,
    inout  wire [15:0] dq,
    inout  wire [1:0]  rwds
);
    w955d8mbya_die #(.DIE(0)) die0 (
        .ck(ck[0]), .ck_n(ck_n[0]), .cs_n(cs_n[0]), .reset_n(reset_n[0]), .dq(dq[7:0]), .rwds(rwds[0])
    );
    w955d8mbya_die #(.DIE(1)) die1 (
        .ck(ck[1]), .ck_n(ck_n[1]), .cs_n(cs_n[1]), .reset_n(reset_n[1]), .dq(dq[15:8]), .rwds(rwds[1])
    );

    // Read by the tests after every run
    wire [31:0] error_count = die0.error_count + die1.error_count;
endmodule
