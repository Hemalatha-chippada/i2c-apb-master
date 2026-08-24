module i2c_apb_master #(
    parameter CLK_DIV = 250
)(
    input  wire        PCLK,
    input  wire        PRESETn,

    // APB interface
    input  wire        PSEL,
    input  wire        PENABLE,
    input  wire        PWRITE,
    input  wire [7:0]  PADDR,
    input  wire [31:0] PWDATA,
    output reg  [31:0] PRDATA,
    output wire        PREADY,

    // I2C interface
    inout  wire        SDA,
    inout  wire        SCL
);

    // ------------------------------------------------------------
    // APB Registers
    // ------------------------------------------------------------
    reg [31:0] control_reg;
    reg [31:0] tx_reg;
    reg [31:0] rx_reg;
    reg [31:0] status_reg;

    assign PREADY = 1'b1;

    // ------------------------------------------------------------
    // I2C control signals
    // ------------------------------------------------------------
    reg sda_drive_low;
    reg scl_drive_low;

    assign SDA = sda_drive_low ? 1'b0 : 1'bz;
    assign SCL = scl_drive_low ? 1'b0 : 1'bz;

    wire sda_in = SDA;
    wire scl_in = SCL;

    // ------------------------------------------------------------
    // Clock divider
    // ------------------------------------------------------------
    reg [15:0] clk_count;
    reg        i2c_tick;

    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            clk_count <= 16'd0;
            i2c_tick  <= 1'b0;
        end
        else begin
            if (clk_count == CLK_DIV - 1) begin
                clk_count <= 16'd0;
                i2c_tick  <= 1'b1;
            end
            else begin
                clk_count <= clk_count + 1'b1;
                i2c_tick  <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------
    // FSM states
    // ------------------------------------------------------------
    localparam IDLE       = 4'd0;
    localparam START      = 4'd1;
    localparam ADDR_LOW   = 4'd2;
    localparam ADDR_HIGH  = 4'd3;
    localparam ADDR_ACK   = 4'd4;
    localparam DATA_LOW   = 4'd5;
    localparam DATA_HIGH  = 4'd6;
    localparam DATA_ACK   = 4'd7;
    localparam READ_LOW   = 4'd8;
    localparam READ_HIGH  = 4'd9;
    localparam READ_ACK   = 4'd10;
    localparam STOP_LOW   = 4'd11;
    localparam STOP_HIGH  = 4'd12;
    localparam DONE       = 4'd13;

    reg [3:0] state;

    reg [3:0] bit_count;
    reg [7:0] addr_byte;
    reg [7:0] tx_data;
    reg [7:0] rx_data;
    reg       rw_bit;
    reg       busy;
    reg       done;
    reg       ack_error;

    // ------------------------------------------------------------
    // APB read
    // ------------------------------------------------------------
    always @(*) begin
        PRDATA = 32'd0;

        if (PSEL && !PWRITE) begin
            case (PADDR)
                8'h00: PRDATA = control_reg;
                8'h04: PRDATA = tx_reg;
                8'h08: PRDATA = status_reg;
                8'h0C: PRDATA = rx_reg;
                default: PRDATA = 32'd0;
            endcase
        end
    end

    // ------------------------------------------------------------
    // APB write registers
    // ------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            control_reg <= 32'd0;
            tx_reg      <= 32'd0;
        end
        else if (PSEL && PENABLE && PWRITE) begin
            case (PADDR)
                8'h00: control_reg <= PWDATA;
                8'h04: tx_reg      <= PWDATA;
                default: begin
                    control_reg <= control_reg;
                    tx_reg      <= tx_reg;
                end
            endcase
        end
    end

    // ------------------------------------------------------------
    // Status register
    // bit 0 = busy
    // bit 1 = done
    // bit 2 = ACK error
    // ------------------------------------------------------------
    always @(*) begin
        status_reg = 32'd0;
        status_reg[0] = busy;
        status_reg[1] = done;
        status_reg[2] = ack_error;
    end

    // ------------------------------------------------------------
    // I2C Master FSM
    //
    // control_reg[0]    = START command
    // control_reg[1]    = R/W (0 = write, 1 = read)
    // control_reg[8:2]  = 7-bit slave address
    // tx_reg[7:0]       = transmit data
    // rx_reg[7:0]       = received data
    // ------------------------------------------------------------
    always @(posedge PCLK or negedge PRESETn) begin

        if (!PRESETn) begin

            state          <= IDLE;

            sda_drive_low  <= 1'b0;
            scl_drive_low  <= 1'b0;

            bit_count      <= 4'd0;
            addr_byte      <= 8'd0;
            tx_data        <= 8'd0;
            rx_data        <= 8'd0;

            rw_bit         <= 1'b0;
            busy           <= 1'b0;
            done           <= 1'b0;
            ack_error      <= 1'b0;

            rx_reg         <= 32'd0;

        end
        else begin

            if (i2c_tick) begin

                case (state)

                    // ------------------------------------------------
                    // IDLE
                    // ------------------------------------------------
                    IDLE: begin

                        sda_drive_low <= 1'b0;
                        scl_drive_low <= 1'b0;

                        busy     <= 1'b0;
                        done     <= 1'b0;
                        ack_error <= 1'b0;

                        if (control_reg[0]) begin

                            busy <= 1'b1;

                            rw_bit <= control_reg[1];

                            addr_byte <= {
                                control_reg[8:2],
                                control_reg[1]
                            };

                            tx_data <= tx_reg[7:0];

                            bit_count <= 4'd7;

                            state <= START;

                        end
                    end

                    // ------------------------------------------------
                    // START CONDITION
                    // SDA goes LOW while SCL is HIGH
                    // ------------------------------------------------
                    START: begin

                        sda_drive_low <= 1'b1;
                        scl_drive_low <= 1'b0;

                        state <= ADDR_LOW;

                    end

                    // ------------------------------------------------
                    // Address bit LOW phase
                    // ------------------------------------------------
                    ADDR_LOW: begin

                        scl_drive_low <= 1'b1;

                        if (addr_byte[bit_count])
                            sda_drive_low <= 1'b0;
                        else
                            sda_drive_low <= 1'b1;

                        state <= ADDR_HIGH;

                    end

                    // ------------------------------------------------
                    // Address bit HIGH phase
                    // ------------------------------------------------
                    ADDR_HIGH: begin

                        scl_drive_low <= 1'b0;

                        if (bit_count == 0) begin
                            state <= ADDR_ACK;
                        end
                        else begin
                            bit_count <= bit_count - 1'b1;
                            state <= ADDR_LOW;
                        end

                    end

                    // ------------------------------------------------
                    // Address ACK
                    // ------------------------------------------------
                    ADDR_ACK: begin

                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b0;

                        state <= DATA_LOW;

                        bit_count <= 4'd7;

                    end

                    // ------------------------------------------------
                    // WRITE DATA - LOW
                    // ------------------------------------------------
                    DATA_LOW: begin

                        if (rw_bit) begin
                            state <= READ_LOW;
                        end
                        else begin

                            scl_drive_low <= 1'b1;

                            if (tx_data[bit_count])
                                sda_drive_low <= 1'b0;
                            else
                                sda_drive_low <= 1'b1;

                            state <= DATA_HIGH;

                        end
                    end

                    // ------------------------------------------------
                    // WRITE DATA - HIGH
                    // ------------------------------------------------
                    DATA_HIGH: begin

                        scl_drive_low <= 1'b0;

                        if (bit_count == 0) begin
                            state <= DATA_ACK;
                        end
                        else begin
                            bit_count <= bit_count - 1'b1;
                            state <= DATA_LOW;
                        end

                    end

                    // ------------------------------------------------
                    // WRITE DATA ACK
                    // ------------------------------------------------
                    DATA_ACK: begin

                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b0;

                        state <= STOP_LOW;

                    end

                    // ------------------------------------------------
                    // READ DATA - LOW
                    // ------------------------------------------------
                    READ_LOW: begin

                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b0;

                        state <= READ_HIGH;

                    end

                    // ------------------------------------------------
                    // READ DATA - HIGH
                    // ------------------------------------------------
                    READ_HIGH: begin

                        scl_drive_low <= 1'b0;

                        rx_data[bit_count] <= sda_in;

                        if (bit_count == 0) begin
                            state <= READ_ACK;
                        end
                        else begin
                            bit_count <= bit_count - 1'b1;
                            state <= READ_LOW;
                        end

                    end

                    // ------------------------------------------------
                    // READ ACK
                    // ------------------------------------------------
                    READ_ACK: begin

                        scl_drive_low <= 1'b1;

                        // Master sends NACK after single-byte read
                        sda_drive_low <= 1'b0;

                        rx_reg[7:0] <= rx_data;

                        state <= STOP_LOW;

                    end

                    // ------------------------------------------------
                    // STOP LOW
                    // ------------------------------------------------
                    STOP_LOW: begin

                        scl_drive_low <= 1'b1;
                        sda_drive_low <= 1'b1;

                        state <= STOP_HIGH;

                    end

                    // ------------------------------------------------
                    // STOP HIGH
                    // SDA goes HIGH while SCL is HIGH
                    // ------------------------------------------------
                    STOP_HIGH: begin

                        scl_drive_low <= 1'b0;
                        sda_drive_low <= 1'b0;

                        state <= DONE;

                    end

                    // ------------------------------------------------
                    // DONE
                    // ------------------------------------------------
                    DONE: begin

                        busy <= 1'b0;
                        done <= 1'b1;

                        state <= IDLE;

                    end

                    default: begin

                        state <= IDLE;
                        busy <= 1'b0;

                    end

                endcase
            end
        end
    end

endmodule