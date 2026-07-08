//=============================================================================
// Full-duplex SPI Master / Slave, 12-bit data, configurable CPOL & CPHA
//=============================================================================

//-----------------------------------------------------------------------------
// MASTER
//-----------------------------------------------------------------------------
module spi_master #(
    parameter DW      = 12,   // data width
    parameter CPOL    = 0,    // 0 = SCLK idles low , 1 = SCLK idles high
    parameter CPHA    = 0,    // 0 = sample on leading edge, 1 = sample on trailing edge
    parameter CLK_DIV = 4     // sclk half-period, in system clk cycles
)(
    input  logic          clk,
    input  logic          rst,
    input  logic          newd,        // pulse: start a transfer
    input  logic [DW-1:0] din,         // data master -> slave
    input  logic          miso,        // data slave  -> master
    output logic          sclk,
    output logic          cs,          // active-low chip select
    output logic          mosi,
    output logic [DW-1:0] dout,        // data received from slave
    output logic          done         // 1-cycle pulse when transfer completes
);

    localparam IDLE = 2'd0, LOAD = 2'd1, XFER = 2'd2, FIN = 2'd3;
    logic [1:0] state;

    // ---------------- sclk generator ----------------
    logic [$clog2(CLK_DIV+1)-1:0] div_cnt;
    logic sclk_en;
    logic leading_edge, trailing_edge;

    always_ff @(posedge clk) begin
        if (rst || !sclk_en) begin
            div_cnt       <= '0;
            sclk          <= CPOL[0];
            leading_edge  <= 1'b0;
            trailing_edge <= 1'b0;
        end else begin
            leading_edge  <= 1'b0;
            trailing_edge <= 1'b0;
            if (div_cnt == CLK_DIV-1) begin
                div_cnt <= '0;
                sclk    <= ~sclk;
                if (sclk == CPOL[0]) leading_edge  <= 1'b1; // leaving idle level
                else                 trailing_edge <= 1'b1; // returning to idle level
            end else begin
                div_cnt <= div_cnt + 1'b1;
            end
        end
    end

    // ---------------- transfer FSM ----------------
    logic [$clog2(DW+1)-1:0] bitcnt;
    logic [DW-1:0] tx_shift;
    logic [DW-1:0] rx_shift;

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            cs       <= 1'b1;
            mosi     <= 1'b0;
            sclk_en  <= 1'b0;
            done     <= 1'b0;
            bitcnt   <= '0;
            tx_shift <= '0;
            rx_shift <= '0;
            dout     <= '0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    cs      <= 1'b1;
                    sclk_en <= 1'b0;
                    if (newd) begin
                        tx_shift <= din;
                        bitcnt   <= '0;
                        cs       <= 1'b0;
                        state    <= LOAD;
                    end
                end

                // Present the very first bit before the first clock edge.
                // Needed only for CPHA = 0 (data must be valid before the
                // leading edge samples it).
                LOAD: begin
                    sclk_en <= 1'b1;
                    if (CPHA == 0)
                        mosi <= tx_shift[DW-1];
                    state <= XFER;
                end

                XFER: begin
                    if (CPHA == 0) begin
                        // sample on leading edge, present next bit on trailing edge
                        if (leading_edge)
                            rx_shift <= {rx_shift[DW-2:0], miso};
                        if (trailing_edge) begin
                            if (bitcnt == DW-1) begin
                                state <= FIN;
                            end else begin
                                mosi   <= tx_shift[DW-2-bitcnt];
                                bitcnt <= bitcnt + 1'b1;
                            end
                        end
                    end else begin
                        // present bit on leading edge, sample on trailing edge
                        if (leading_edge)
                            mosi <= tx_shift[DW-1-bitcnt];
                        if (trailing_edge) begin
                            rx_shift <= {rx_shift[DW-2:0], miso};
                            if (bitcnt == DW-1)
                                state <= FIN;
                            else
                                bitcnt <= bitcnt + 1'b1;
                        end
                    end
                end

                FIN: begin
                    sclk_en <= 1'b0;
                    cs      <= 1'b1;
                    mosi    <= 1'b0;
                    dout    <= rx_shift;
                    done    <= 1'b1;
                    state   <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule


//-----------------------------------------------------------------------------
// SLAVE  (runs directly off sclk supplied by the master, as real SPI slaves do)
//-----------------------------------------------------------------------------
module spi_slave #(
    parameter DW   = 12,
    parameter CPOL = 0,
    parameter CPHA = 0
)(
    input  logic          sclk,
    input  logic          cs,     // active low
    input  logic          mosi,
    input  logic [DW-1:0] din,    // data slave -> master (loaded when cs falls)
    output logic          miso,
    output logic [DW-1:0] dout,   // data received from master
    output logic          done
);

    // Which sclk level is the "sample" edge for this CPOL/CPHA combination.
    // sample edge = leading edge  when CPHA = 0
    // sample edge = trailing edge when CPHA = 1
    // leading edge is a rising edge when CPOL = 0, falling edge when CPOL = 1
    localparam bit SAMPLE_ON_POSEDGE = (CPOL == CPHA);

    logic [DW-1:0] tx_shift;
    logic [DW-1:0] rx_shift;
    logic [$clog2(DW+1)-1:0] bitcnt;

    // Preload the first output bit as soon as we are selected.
    // Only required for CPHA = 0 (output must be valid before the first
    // sampling edge, which happens with no prior "shift" edge to prep it).
    generate
        if (CPHA == 0) begin : g_preload
            always_ff @(negedge cs) begin
                miso <= din[DW-1];
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // NOTE: The dual-edge block this used to be
    //   (always_ff @(posedge sclk or negedge sclk))
    // simulates fine but is NOT synthesizable -- FPGA flip-flops only
    // trigger on one edge each. Split into two single-edge blocks:
    // whichever edge is the "sample" edge for this CPOL/CPHA drives
    // bitcnt/rx_shift/dout/done; the other edge only updates miso.
    // Which edge is which is a compile-time choice (SAMPLE_ON_POSEDGE
    // depends only on CPOL/CPHA), so `generate` picks it at elaboration
    // -- each branch is an ordinary, synthesizable single-edge process.
    // `cs` is used as an async reset (posedge cs) instead of being
    // polled on every sclk edge, since it can no longer share a
    // sensitivity list with sclk's other edge.
    //
    // IMPORTANT (Vivado synthesizability rule): whenever a signal's edge
    // appears in the sensitivity list (e.g. `posedge cs`), the very first
    // branch inside the always_ff body must be an `if (cs) ... else ...`
    // that matches that edge polarity. A body that only has `if (!cs)`
    // with no explicit reset branch will fail elaboration with
    // "Expression condition using operand 'cs' does not match with the
    // corresponding edges used in event control" (Synth 8-7213) plus a
    // "no clock signal specified in event control" (Synth 8-462) error,
    // because the tool can no longer prove which edge is the async reset
    // and which is the clock. Both miso-driving blocks below now start
    // with an explicit `if (cs) ... else ...` for this reason.
    // ------------------------------------------------------------------
    generate
    if (SAMPLE_ON_POSEDGE) begin : g_sample_posedge

        always_ff @(posedge sclk or posedge cs) begin
            if (cs) begin
                bitcnt <= '0;
                done   <= 1'b0;
            end else begin
                rx_shift <= {rx_shift[DW-2:0], mosi};
                if (bitcnt == DW-1) begin
                    dout   <= {rx_shift[DW-2:0], mosi};
                    done   <= 1'b1;
                    bitcnt <= '0;
                end else begin
                    bitcnt <= bitcnt + 1'b1;
                    done   <= 1'b0;
                end
            end
        end

        always_ff @(negedge sclk or posedge cs) begin
            if (cs) begin
                miso <= 1'b0;
            end else begin
                if (CPHA == 0) begin
                    if (bitcnt != 0)
                        miso <= tx_shift[DW-1-bitcnt];
                end else begin
                    miso <= (bitcnt == 0) ? din[DW-1] : tx_shift[DW-1-bitcnt];
                end
            end
        end

    end else begin : g_sample_negedge

        always_ff @(negedge sclk or posedge cs) begin
            if (cs) begin
                bitcnt <= '0;
                done   <= 1'b0;
            end else begin
                rx_shift <= {rx_shift[DW-2:0], mosi};
                if (bitcnt == DW-1) begin
                    dout   <= {rx_shift[DW-2:0], mosi};
                    done   <= 1'b1;
                    bitcnt <= '0;
                end else begin
                    bitcnt <= bitcnt + 1'b1;
                    done   <= 1'b0;
                end
            end
        end

        always_ff @(posedge sclk or posedge cs) begin
            if (cs) begin
                miso <= 1'b0;
            end else begin
                if (CPHA == 0) begin
                    if (bitcnt != 0)
                        miso <= tx_shift[DW-1-bitcnt];
                end else begin
                    miso <= (bitcnt == 0) ? din[DW-1] : tx_shift[DW-1-bitcnt];
                end
            end
        end

    end
    endgenerate

    // Latch the parallel load data into tx_shift when selected, so it is
    // stable throughout the transfer.
    always_ff @(negedge cs) begin
        tx_shift <= din;
    end

endmodule


//-----------------------------------------------------------------------------
// TOP: wires master <-> slave together, exposing both CPOL/CPHA as parameters
//-----------------------------------------------------------------------------
module top #(
    parameter DW      = 12,
    parameter CPOL    = 0,
    parameter CPHA    = 0,
    parameter CLK_DIV = 4
)(
    input  logic          clk,
    input  logic          rst,
    input  logic          newd,
    input  logic [DW-1:0] m_din,    // master -> slave data
    input  logic [DW-1:0] s_din,    // slave  -> master data
    output logic [DW-1:0] m_dout,   // data master received (== s_din)
    output logic [DW-1:0] s_dout,   // data slave received  (== m_din)
    output logic          master_done,
    output logic          slave_done
);

    logic sclk, cs, mosi, miso;

    spi_master #(.DW(DW), .CPOL(CPOL), .CPHA(CPHA), .CLK_DIV(CLK_DIV)) m1 (
        .clk(clk), .rst(rst), .newd(newd), .din(m_din), .miso(miso),
        .sclk(sclk), .cs(cs), .mosi(mosi), .dout(m_dout), .done(master_done)
    );

    spi_slave #(.DW(DW), .CPOL(CPOL), .CPHA(CPHA)) s1 (
        .sclk(sclk), .cs(cs), .mosi(mosi), .din(s_din),
        .miso(miso), .dout(s_dout), .done(slave_done)
    );

endmodule