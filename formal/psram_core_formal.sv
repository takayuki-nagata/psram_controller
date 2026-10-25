// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// Formal properties of psram_core (make formal, SymbiYosys).
//
// Assumes a single reset at the start and a host that follows the request protocol,
// then proves (unbounded, PDR):
//   - host interface: one request in flight; N responses to an N-word read and one to a
//     write, rsp_last with the last one; req_ready only after init_done
//   - timing contract (docs/integration.md): the cycle of every response, of req_ready,
//     and of every wdata_next, for every length; R = tRWR cycles
//   - write data: DQ and the RWDS masks carry each word's req_wdata/req_wstrb (word 0 at
//     acceptance, word k in cycle 29 + 2k) on its two edges
//   - CS#: both dies together, High during initialization, Low for 30 + 2N cycles at most
//     (read; 29 + 2N write), CK only runs while CS# is Low
//   - bus direction: reads never drive RWDS and drive DQ only for the CA; register writes
//     never drive RWDS
//   - RESET#: Low for at least RESET_PULSE_CYCLES after reset, never again afterwards
`timescale 1ns / 1ps

module psram_core_formal #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer MAX_BURST_WORDS = 16,
    localparam integer LEN_W = MAX_BURST_WORDS > 1 ? $clog2(MAX_BURST_WORDS) : 1
) (
    input wire        clk,
    input wire        rst_n,
    input wire        req_valid,
    input wire        req_we,
    input wire [23:0] req_addr,
    input wire [31:0] req_wdata,
    input wire [3:0]  req_wstrb,
    input wire [LEN_W-1:0] req_len,
    input wire [15:0] dq_in
);
    localparam integer RESET_PULSE_CYCLES = (400 * 64'(CLK_HZ) + 999_999_999) / 1_000_000_000;
    localparam integer R = (36 * 64'(CLK_HZ) + 999_999_999) / 1_000_000_000;  // tRWR cycles

    wire        req_ready;
    wire        rsp_valid;
    wire        rsp_last;
    wire [31:0] rsp_rdata;
    wire        wdata_next;
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

    psram_core #(.CLK_HZ(CLK_HZ), .MAX_BURST_WORDS(MAX_BURST_WORDS)) dut (.*);

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
            assume ($stable(req_len));
        end
    end

    // Bursts: memory space only, aligned to their length (the core ignores req_len for
    // register accesses and with MAX_BURST_WORDS = 1, which the bookkeeping models)
    wire [5:0] req_n = (MAX_BURST_WORDS == 1 || req_addr[23]) ? 6'd1 : 6'(req_len) + 6'd1;
    always @(*) begin
        if (req_valid && req_len != 0) begin
            assume (!req_addr[23]);
            assume ((req_addr[7:2] & 6'(req_n - 1)) == 0);
        end
    end

    // ------------------------------------------------------------ bookkeeping
    reg       f_out;      // a request is in flight (responses to come)
    reg       f_busy;     // a request was accepted and req_ready has not been High since
    reg       f_we;
    reg       f_reg;
    reg [5:0] f_n;        // its length (words)
    reg [5:0] f_left;     // responses still to come
    reg [7:0] f_wait;     // cycles since acceptance - 1 (0 in cycle 1)
    reg [31:0] f_wdata0;  // word 0 of a write
    reg [3:0]  f_wstrb0;
    reg [7:0] f_cs_low;   // cycles CS# has been Low
    reg [15:0] f_rst_low; // cycles RESET# has been Low
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f_out     <= 1'b0;
            f_busy    <= 1'b0;
            f_we      <= 1'b0;
            f_reg     <= 1'b0;
            f_n       <= 6'd0;
            f_left    <= 6'd0;
            f_wait    <= 8'd0;
            f_wdata0  <= 32'd0;
            f_wstrb0  <= 4'd0;
            f_cs_low  <= 8'd0;
            f_rst_low <= 16'd0;
        end else begin
            if (rsp_valid) begin
                f_left <= f_left - 6'd1;
                if (f_left == 6'd1) f_out <= 1'b0;
            end
            if (req_ready) f_busy <= 1'b0;
            if (req_valid && req_ready) begin
                f_out  <= 1'b1;
                f_busy <= 1'b1;
                f_we   <= req_we;
                f_reg  <= req_addr[23];
                f_n    <= req_n;
                f_left <= req_we ? 6'd1 : req_n;
                f_wdata0 <= req_wdata;
                f_wstrb0 <= req_wstrb;
                f_wait <= 8'd0;
            end else if (f_busy && f_wait != 8'hFF) begin
                f_wait <= f_wait + 8'd1;
            end
            f_cs_low  <= cs_n_out[0] ? 8'd0 : (f_cs_low == 8'hFF ? f_cs_low : f_cs_low + 8'd1);
            f_rst_low <= reset_n_out[0] ? f_rst_low : (f_rst_low == 16'hFFFF ? f_rst_low : f_rst_low + 16'd1);
        end
    end

    // Cycle of the timing contract, minus 1 (f_wait), of each event
    wire [7:0] f_beat_t  = 8'd31 + 8'd2 * 8'(f_n - f_left);   // burst read word k at 32 + 2k
    wire [7:0] f_done_t  = f_we ? (f_reg ? 8'd10 + 8'(R) : 8'd30 + 8'd2 * 8'(f_n) + 8'(R))
                         : (f_n == 6'd1 ? 8'd33 + 8'(R) : 8'd31 + 8'd2 * 8'(f_n) + 8'(R));
    wire f_wnext_t = f_out && f_we && !f_reg && f_n > 6'd1 && f_wait[0]
                     && f_wait >= 8'd29 && f_wait <= 8'd25 + 8'd2 * 8'(f_n);  // 28 + 2k, k = 1..N-1

    // ------------------------------------------------------------ properties
    always @(*) begin
        if (rst_n) begin
            // Host interface
            if (rsp_valid) assert (f_out && f_left != 0);
            if (rsp_valid) assert (rsp_last == (f_left == 6'd1));
            if (!rsp_valid) assert (!rsp_last);
            if (req_ready) assert (!f_out || (rsp_valid && f_left == 6'd1));
            if (req_ready) assert (init_done);
            if (f_out) assert (f_left != 0 && f_left <= f_n && f_n <= MAX_BURST_WORDS);
            if (f_out && f_we) assert (f_left == 6'd1);

            // Timing contract: responses exactly at their cycles, req_ready exactly at the end
            if (f_out && !f_we && f_n > 6'd1) assert (rsp_valid == (f_wait == f_beat_t));
            if (f_out && (f_we || f_n == 6'd1)) assert (rsp_valid == (f_wait == f_done_t));
            if (f_out) assert (f_busy);
            if (f_busy) assert (f_wait <= f_done_t);
            if (f_busy) assert (req_ready == (f_wait == f_done_t));
            assert (wdata_next == f_wnext_t);

            // CS# and CK
            assert (cs_n_out[0] == cs_n_out[1]);
            assert (reset_n_out[0] == reset_n_out[1]);
            if (!init_done) assert (cs_n_out == 2'b11);
            if (f_out) assert (f_cs_low <= (f_we ? 8'd29 : 8'd30) + 8'd2 * 8'(f_n));
            assert (f_cs_low <= 8'd30 + 8'd2 * MAX_BURST_WORDS);
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

    // Memory write data phase: word k on DQ in cycles 30 + 2k ([15:0], f_wait 29 + 2k) and
    // 31 + 2k ([31:16]), k = 0..N-1; word k >= 1 is req_wdata/req_wstrb of cycle 29 + 2k
    wire f_wdata_phase = f_out && f_we && !f_reg && f_wait >= 8'd29 && f_wait <= 8'd28 + 8'd2 * 8'(f_n);
    always @(posedge clk) begin
        if (f_past_valid && rst_n && $past(rst_n) && f_wdata_phase) begin
            assert (dq_oe && rwds_oe);
            if (f_wait == 8'd29) begin
                assert (dq_out == f_wdata0[15:0] && rwds_out == ~f_wstrb0[1:0]);
            end else if (f_wait == 8'd30) begin
                assert (dq_out == f_wdata0[31:16] && rwds_out == ~f_wstrb0[3:2]);
            end else if (f_wait[0]) begin
                assert (dq_out == $past(req_wdata[15:0]) && rwds_out == ~$past(req_wstrb[1:0]));
            end else begin
                assert (dq_out == $past(req_wdata[31:16], 2) && rwds_out == ~$past(req_wstrb[3:2], 2));
            end
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
            cover (rsp_last && !f_we && f_n == MAX_BURST_WORDS);  // longest burst read
            cover (rsp_last && f_we && f_n == MAX_BURST_WORDS);   // longest burst write
            cover (f_busy && !f_out && req_valid && req_ready);   // back-to-back after a burst read
        end
    end
endmodule
