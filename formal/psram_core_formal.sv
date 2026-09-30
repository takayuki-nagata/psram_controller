// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// Formal properties of psram_core (make formal, SymbiYosys).
//
// Assumes a single reset at the start and a host that follows the request protocol,
// then proves (unbounded, PDR):
//   - host interface: one request in flight, exactly one response per accepted request,
//     a response within RESPONSE_MAX cycles, req_ready only after init_done
//   - CS#: both dies together, High during initialization, Low for at most CS_LOW_MAX
//     cycles (tCSM), CK only runs while CS# is Low
//   - bus direction: reads never drive RWDS and drive DQ only for the CA; register writes
//     never drive RWDS
//   - RESET#: Low for at least RESET_PULSE_CYCLES after reset, never again afterwards
`timescale 1ns / 1ps

module psram_core_formal #(
    parameter integer CLK_HZ = 27_000_000
) (
    input wire        clk,
    input wire        rst_n,
    input wire        req_valid,
    input wire        req_we,
    input wire [23:0] req_addr,
    input wire [31:0] req_wdata,
    input wire [3:0]  req_wstrb,
    input wire [15:0] dq_in
);
    localparam integer RESET_PULSE_CYCLES = (400 * 64'(CLK_HZ) + 999_999_999) / 1_000_000_000;
    localparam integer CS_LOW_MAX = 40;     // cycles; x period must stay <= tCSM (4 us)
    localparam integer RESPONSE_MAX = 64;   // cycles from acceptance to response

    wire        req_ready;
    wire        rsp_valid;
    wire [31:0] rsp_rdata;
    wire        init_done;
    wire        psram_ck_reg;
    wire        ck_en;
    wire [1:0]  cs_n_out;
    wire [1:0]  reset_n_out;
    wire        dq_oe;
    wire [15:0] dq_out;
    wire        rwds_oe;
    wire [1:0]  rwds_out;
    wire [3:0]  dbg_state;
    wire [5:0]  dbg_timer;

    psram_core #(.CLK_HZ(CLK_HZ)) dut (.*);

    // ------------------------------------------------------------ environment
    reg f_past_valid = 1'b0;
    always @(posedge clk) f_past_valid <= 1'b1;
    always @(*) begin
        if (!f_past_valid) assume (!rst_n);
        else assume (rst_n);
    end

    // Host: once raised, req_valid and the payload stay until accepted
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n) && $past(req_valid && !req_ready)) begin
            assume (req_valid);
            assume ($stable(req_we) && $stable(req_addr) && $stable(req_wdata) && $stable(req_wstrb));
        end
    end

    // ------------------------------------------------------------ bookkeeping
    reg       f_out;      // a request is in flight
    reg       f_we;
    reg       f_reg;
    reg [7:0] f_wait;     // cycles since acceptance
    reg [7:0] f_cs_low;   // cycles CS# has been Low
    reg [15:0] f_rst_low; // cycles RESET# has been Low
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_out     <= 1'b0;
            f_we      <= 1'b0;
            f_reg     <= 1'b0;
            f_wait    <= 8'd0;
            f_cs_low  <= 8'd0;
            f_rst_low <= 16'd0;
        end else begin
            if (rsp_valid) f_out <= 1'b0;
            if (req_valid && req_ready) begin
                f_out  <= 1'b1;
                f_we   <= req_we;
                f_reg  <= req_addr[23];
                f_wait <= 8'd0;
            end else if (f_out && f_wait != 8'hFF) begin
                f_wait <= f_wait + 8'd1;
            end
            f_cs_low  <= cs_n_out[0] ? 8'd0 : (f_cs_low == 8'hFF ? f_cs_low : f_cs_low + 8'd1);
            f_rst_low <= reset_n_out[0] ? f_rst_low : (f_rst_low == 16'hFFFF ? f_rst_low : f_rst_low + 16'd1);
        end
    end

    // ------------------------------------------------------------ properties
    always @(*) begin
        if (rst_n) begin
            // Host interface
            if (rsp_valid) assert (f_out);
            if (req_ready) assert (!f_out || rsp_valid);
            if (req_ready) assert (init_done);
            if (f_out) assert (f_wait < RESPONSE_MAX);

            // CS# and CK
            assert (cs_n_out[0] == cs_n_out[1]);
            assert (reset_n_out[0] == reset_n_out[1]);
            if (!init_done) assert (cs_n_out == 2'b11);
            assert (f_cs_low < CS_LOW_MAX);
            if (ck_en) assert (!cs_n_out[0]);
            if (cs_n_out[0]) assert (!ck_en && !dq_oe && !rwds_oe);

            // Bus direction
            if (f_out && !f_we) assert (!rwds_oe);
            if (f_out && !f_we && dq_oe) assert (f_cs_low <= 6);  // CA only
            if (f_out && f_we && f_reg) assert (!rwds_oe);

            // RESET#
            if (init_done) assert (reset_n_out == 2'b11);
        end
    end

    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n) && $rose(reset_n_out[0]))
            assert ($past(f_rst_low) + 1 >= RESET_PULSE_CYCLES);
        if (f_past_valid && rst_n && $past(rst_n) && $past(init_done))
            assert (init_done);
    end

    // ------------------------------------------------------------ reachability
    always @(*) begin
        if (rst_n) begin
            cover (rsp_valid && f_we && !f_reg);
            cover (rsp_valid && f_we && f_reg);
            cover (rsp_valid && !f_we);
            cover (rsp_valid && req_valid && req_ready);  // back-to-back
        end
    end
endmodule
