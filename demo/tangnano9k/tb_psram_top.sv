// Copyright (c) 2026 Takayuki Nagata
// SPDX-License-Identifier: MIT

// Testbench for psram_top on Icarus Verilog
`timescale 1ns / 1ps

module tb_psram_top;
    reg clk;
    reg rst_n;
    reg btn;

    wire uart_tx;
    reg  uart_rx;
    wire [5:0] led;

    wire [1:0]  O_psram_ck;
    wire [1:0]  O_psram_ck_n;
    wire [1:0]  O_psram_cs_n;
    wire [1:0]  O_psram_reset_n;
    wire [15:0] IO_psram_dq;
    wire [1:0]  IO_psram_rwds;

    // 27MHz clock generator (period = 37.037ns -> toggle every 18.518ns)
    initial begin
        clk = 0;
        forever #18.518 clk = ~clk;
    end

    // DUT: psram_top
    psram_top #(
        .DIAG_CYCLES(4)
    ) dut (
        .clk            (clk            ),
        .rst_n          (rst_n          ),
        .btn            (btn            ),
        .uart_tx        (uart_tx        ),
        .uart_rx        (uart_rx        ),
        .led            (led            ),
        .O_psram_ck     (O_psram_ck     ),
        .O_psram_ck_n   (O_psram_ck_n   ),
        .O_psram_cs_n   (O_psram_cs_n   ),
        .O_psram_reset_n(O_psram_reset_n),
        .IO_psram_dq    (IO_psram_dq    ),
        .IO_psram_rwds  (IO_psram_rwds  )
    );

    // W955D8MBYA model (sim/model/)
    w955d8mbya_model psram_inst (
        .ck     (O_psram_ck     ),
        .ck_n   (O_psram_ck_n   ),
        .cs_n   (O_psram_cs_n   ),
        .reset_n(O_psram_reset_n),
        .dq     (IO_psram_dq    ),
        .rwds   (IO_psram_rwds  )
    );

    // UART RX monitor task (clock-accurate sampling)
    reg [7:0] rx_byte;
    integer rx_bit;
    always begin
        @(negedge uart_tx); // Start bit leading edge
        repeat (117) @(posedge clk); // Center of start bit
        for (rx_bit = 0; rx_bit < 8; rx_bit = rx_bit + 1) begin
            repeat (234) @(posedge clk); // Center of bit 0..7
            rx_byte[rx_bit] = uart_tx;
        end
        repeat (117) @(posedge clk); // End of data / start of stop bit
        $write("%c", rx_byte);
        $fflush();
    end

    // Test sequence
    initial begin
        $dumpfile("build/demo/sim/tb.vcd");
        $dumpvars(0, tb_psram_top);
        $display("=== Starting PSRAM Controller Simulation ===");
        rst_n   = 1'b0;
        btn     = 1'b1;
        uart_rx = 1'b1;

        // Apply reset
        #200;
        rst_n = 1'b1;
        $display("[TB] Reset de-asserted. Waiting for power-up initialization (150us)...");

        // Wait for test to complete or timeout
        fork
            begin
                wait (led == 6'b000000 || led == 6'b111110);
                #10000000; // wait 10ms for UART to flush final characters
            end
            begin
                #25000000; // 25ms timeout
                $display("\n[TB] TIMEOUT reached!");
            end
        join_any

        $display("\n[TB] Checking final LED status: 6'b%b", led);
        if (led == 6'b000000) begin
            $display("[TB] SUCCESS: All LEDs ON -> PSRAM verification passed!");
            $finish(0);
        end else begin
            $display("[TB] FAILURE: LEDs indicate error state: 6'b%b", led);
            $finish(1);
        end
    end

endmodule
