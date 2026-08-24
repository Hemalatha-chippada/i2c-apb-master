`timescale 1ns/1ps

module i2c_apb_master_tb;

    // ============================================================
    // Clock and Reset
    // ============================================================
    reg PCLK;
    reg PRESETn;

    // ============================================================
    // APB Signals
    // ============================================================
    reg        PSEL;
    reg        PENABLE;
    reg        PWRITE;
    reg [7:0]  PADDR;
    reg [31:0] PWDATA;

    wire [31:0] PRDATA;
    wire        PREADY;

    // ============================================================
    // I2C Signals
    // Open-drain bus with pull-up
    // ============================================================
    wire SDA;
    wire SCL;

    reg slave_sda_drive_low;
    reg slave_scl_drive_low;

    assign SDA = slave_sda_drive_low ? 1'b0 : 1'bz;
    assign SCL = slave_scl_drive_low ? 1'b0 : 1'bz;

    pullup(SDA);
    pullup(SCL);

    // ============================================================
    // DUT
    // CLK_DIV is reduced for faster simulation
    // ============================================================
    i2c_apb_master #(
        .CLK_DIV(4)
    ) DUT (
        .PCLK       (PCLK),
        .PRESETn    (PRESETn),

        .PSEL       (PSEL),
        .PENABLE    (PENABLE),
        .PWRITE     (PWRITE),
        .PADDR      (PADDR),
        .PWDATA     (PWDATA),
        .PRDATA     (PRDATA),
        .PREADY     (PREADY),

        .SDA        (SDA),
        .SCL        (SCL)
    );

    // ============================================================
    // Clock Generation
    // 10 ns clock period
    // ============================================================
    initial begin
        PCLK = 1'b0;
        forever #5 PCLK = ~PCLK;
    end

    // ============================================================
    // APB WRITE TASK
    // ============================================================
    task apb_write;
        input [7:0]  address;
        input [31:0] data;

        begin

            @(posedge PCLK);

            PSEL    <= 1'b1;
            PENABLE <= 1'b0;
            PWRITE  <= 1'b1;
            PADDR   <= address;
            PWDATA  <= data;

            @(posedge PCLK);

            PENABLE <= 1'b1;

            @(posedge PCLK);

            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
            PWRITE  <= 1'b0;
            PADDR   <= 8'd0;
            PWDATA  <= 32'd0;

        end
    endtask

    // ============================================================
    // APB READ TASK
    // ============================================================
    task apb_read;
        input  [7:0] address;
        output [31:0] data;

        begin

            @(posedge PCLK);

            PSEL    <= 1'b1;
            PENABLE <= 1'b0;
            PWRITE  <= 1'b0;
            PADDR   <= address;

            @(posedge PCLK);

            PENABLE <= 1'b1;

            @(posedge PCLK);

            data = PRDATA;

            PSEL    <= 1'b0;
            PENABLE <= 1'b0;
            PADDR   <= 8'd0;

        end
    endtask

    // ============================================================
    // Wait for I2C transaction to complete
    // ============================================================
    task wait_for_done;

        integer timeout;

        begin

            timeout = 0;

            while ((DUT.done !== 1'b1) && (timeout < 10000)) begin
                @(posedge PCLK);
                timeout = timeout + 1;
            end

            if (timeout >= 10000) begin
                $display("ERROR: I2C transaction timeout!");
            end
            else begin
                $display("I2C transaction completed.");
            end

        end
    endtask

    // ============================================================
    // Test Sequence
    // ============================================================
    reg [31:0] read_data;

    initial begin

        // --------------------------------------------------------
        // Initial values
        // --------------------------------------------------------
        PRESETn = 1'b0;

        PSEL    = 1'b0;
        PENABLE = 1'b0;
        PWRITE  = 1'b0;
        PADDR   = 8'd0;
        PWDATA  = 32'd0;

        slave_sda_drive_low = 1'b0;
        slave_scl_drive_low = 1'b0;

        // --------------------------------------------------------
        // Reset
        // --------------------------------------------------------
        #100;

        PRESETn = 1'b1;

        #50;

        $display("============================================");
        $display("      I2C APB MASTER TESTBENCH START");
        $display("============================================");

        // ========================================================
        // TEST 1: APB WRITE TO TRANSMIT REGISTER
        // ========================================================

        $display("");
        $display("TEST 1: Writing data to TX register");

        apb_write(
            8'h04,
            32'h000000A5
        );

        $display("TX data written = 0xA5");

        // ========================================================
        // TEST 2: CONFIGURE I2C WRITE
        //
        // control_reg:
        // bit 0   = START
        // bit 1   = R/W
        // bits 8:2 = 7-bit slave address
        //
        // Slave address = 0x50
        // Write operation = 0
        // ========================================================

        $display("");
        $display("TEST 2: Starting I2C WRITE transaction");

        apb_write(
            8'h00,
            {23'd0, 7'h50, 1'b0, 1'b1}
        );

        // Wait for transaction
        wait_for_done;

        $display("I2C WRITE transaction finished.");
        $display("SDA = %b", SDA);
        $display("SCL = %b", SCL);

        // --------------------------------------------------------
        // Clear START command
        // --------------------------------------------------------
        apb_write(
            8'h00,
            32'h00000000
        );

        #100;

        // ========================================================
        // TEST 3: READ STATUS REGISTER
        // ========================================================

        $display("");
        $display("TEST 3: Reading STATUS register");

        apb_read(
            8'h08,
            read_data
        );

        $display("STATUS = %h", read_data);

        // ========================================================
        // TEST 4: I2C READ TRANSACTION
        //
        // R/W = 1
        // Since no external slave drives SDA in this basic
        // testbench, the pull-up keeps SDA HIGH.
        // ========================================================

        $display("");
        $display("TEST 4: Starting I2C READ transaction");

        apb_write(
            8'h00,
            {23'd0, 7'h50, 1'b1, 1'b1}
        );

        wait_for_done;

        // --------------------------------------------------------
        // Clear START
        // --------------------------------------------------------
        apb_write(
            8'h00,
            32'h00000000
        );

        #100;

        // ========================================================
        // TEST 5: READ RECEIVED DATA
        // ========================================================

        $display("");
        $display("TEST 5: Reading RX register");

        apb_read(
            8'h0C,
            read_data
        );

        $display("RX DATA = %h", read_data);

        // ========================================================
        // Final status
        // ========================================================

        $display("");
        $display("============================================");
        $display("       I2C APB MASTER TESTBENCH END");
        $display("============================================");

        #100;

        $finish;

    end

    // ============================================================
    // Monitor important signals
    // ============================================================
    initial begin

        $monitor(
            "TIME=%0t | PSEL=%b PWRITE=%b ADDR=%h | SCL=%b SDA=%b | BUSY=%b DONE=%b RX=%h",
            $time,
            PSEL,
            PWRITE,
            PADDR,
            SCL,
            SDA,
            DUT.busy,
            DUT.done,
            DUT.rx_reg[7:0]
        );

    end

endmodule