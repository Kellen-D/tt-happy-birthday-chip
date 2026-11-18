/*
 * Happy birthday chip: plays the tune as a square wave on one pin.
 *
 *   uo_out[0]   audio out (connect a small speaker)
 *   uio_out[7]  the same signal, on the Tiny Tapeout audio PMOD pin
 *   ui_in[0]    hold high to pause
 *
 * Expects a 50 MHz clock. Three blocks do the work:
 *   the score   which note comes next, and how long it lasts
 *   the tempo   counts clock ticks to time each note
 *   the tone    divides the clock down to the pitch of the note
 */

`default_nettype none

module tt_um_kellen_d_happy_birthday_chip #(
    // The clock the chip runs from, in Hz. Every interval below is derived from
    // this one number, so retargeting the design is a single edit.
    parameter CLOCK_HZ = 50000000,
    // Tempo in beats a minute. One sixteenth note is a quarter of a beat.
    parameter BPM = 100
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // Notes. Each name is a 3-bit code.
    localparam G4 = 3'd0, A4 = 3'd1, B4 = 3'd2, C5 = 3'd3,
               D5 = 3'd4, E5 = 3'd5, F5 = 3'd6, G5 = 3'd7;

    localparam LAST_NOTE = 5'd24;

    // ---- timing -------------------------------------------------------------
    // A sixteenth note lasts 15/BPM seconds, which is this many clock ticks.
    localparam integer SIXTEENTH_TICKS = CLOCK_HZ * 15 / BPM;
    localparam integer TICK_BITS       = $clog2(SIXTEENTH_TICKS);

    // ---- the score ------------------------------------------------------------
    // One line per note: its pitch, then its length in sixteenths.
    reg [4:0] index;      // which note of the tune is playing
    reg [2:0] pitch;
    reg [3:0] length;
    always @(*) begin
        case (index)
            5'd0:  begin pitch = G4; length = 4'd3; end   // Hap
            5'd1:  begin pitch = G4; length = 4'd1; end   // py
            5'd2:  begin pitch = A4; length = 4'd4; end   // birth
            5'd3:  begin pitch = G4; length = 4'd4; end   // day
            5'd4:  begin pitch = C5; length = 4'd4; end   // to
            5'd5:  begin pitch = B4; length = 4'd8; end   // you

            5'd6:  begin pitch = G4; length = 4'd3; end
            5'd7:  begin pitch = G4; length = 4'd1; end
            5'd8:  begin pitch = A4; length = 4'd4; end
            5'd9:  begin pitch = G4; length = 4'd4; end
            5'd10: begin pitch = D5; length = 4'd4; end
            5'd11: begin pitch = C5; length = 4'd8; end

            5'd12: begin pitch = G4; length = 4'd3; end
            5'd13: begin pitch = G4; length = 4'd1; end
            5'd14: begin pitch = G5; length = 4'd4; end
            5'd15: begin pitch = E5; length = 4'd4; end
            5'd16: begin pitch = C5; length = 4'd4; end
            5'd17: begin pitch = B4; length = 4'd4; end
            5'd18: begin pitch = A4; length = 4'd8; end

            5'd19: begin pitch = F5; length = 4'd3; end
            5'd20: begin pitch = F5; length = 4'd1; end
            5'd21: begin pitch = E5; length = 4'd4; end
            5'd22: begin pitch = C5; length = 4'd4; end
            5'd23: begin pitch = D5; length = 4'd4; end
            5'd24: begin pitch = C5; length = 4'd8; end
            default: begin pitch = G4; length = 4'd4; end
        endcase
    end

    // ---- the pitch table ------------------------------------------------------
    // Clock ticks in half a cycle of each note: CLOCK_HZ / (2 x frequency).
    localparam [15:0]
        HP_G4 = CLOCK_HZ / (2*392), HP_A4 = CLOCK_HZ / (2*440),
        HP_B4 = CLOCK_HZ / (2*494), HP_C5 = CLOCK_HZ / (2*523),
        HP_D5 = CLOCK_HZ / (2*587), HP_E5 = CLOCK_HZ / (2*659),
        HP_F5 = CLOCK_HZ / (2*698), HP_G5 = CLOCK_HZ / (2*784);

    reg [15:0] half_period;
    always @(*) begin
        case (pitch)
            G4: half_period = HP_G4;   // 392 Hz
            A4: half_period = HP_A4;   // 440 Hz
            B4: half_period = HP_B4;   // 494 Hz
            C5: half_period = HP_C5;   // 523 Hz
            D5: half_period = HP_D5;   // 587 Hz
            E5: half_period = HP_E5;   // 659 Hz
            F5: half_period = HP_F5;   // 698 Hz
            G5: half_period = HP_G5;   // 784 Hz
            default: half_period = HP_G4;
        endcase
    end

    // ---- the tempo ------------------------------------------------------------
    // tick counts clock ticks up to one sixteenth. step counts sixteenths up to
    // the length of the note, then the score moves on.
    reg [TICK_BITS-1:0] tick;
    reg [3:0]  step;
    wire sixteenth_done = (tick == SIXTEENTH_TICKS - 1);
    wire note_done      = sixteenth_done && (step == length - 4'd1);

    always @(posedge clk) begin
        if (!rst_n) begin
            tick  <= {TICK_BITS{1'b0}};
            step  <= 4'd0;
            index <= 5'd0;
        end else if (!ui_in[0]) begin
            tick <= sixteenth_done ? {TICK_BITS{1'b0}} : tick + 1'b1;
            if (note_done) begin
                step  <= 4'd0;
                index <= (index == LAST_NOTE) ? 5'd0 : index + 5'd1;
            end else if (sixteenth_done) begin
                step <= step + 4'd1;
            end
        end
    end

    // A short silence at the end of every note, so two notes of the same pitch
    // in a row are heard as two notes.
    wire gap = (step == length - 4'd1) && (tick >= SIXTEENTH_TICKS - (SIXTEENTH_TICKS >> 2));

    // ---- the tone -------------------------------------------------------------
    // Counts up to half a cycle, then flips the output. That makes a square wave.
    reg [15:0] tone_count;
    reg        audio;
    always @(posedge clk) begin
        if (!rst_n || note_done) begin
            tone_count <= 16'd0;
            audio      <= 1'b0;
        end else if (tone_count == half_period - 16'd1) begin
            tone_count <= 16'd0;
            audio      <= ~audio;
        end else begin
            tone_count <= tone_count + 16'd1;
        end
    end

    wire speaker = audio & ~gap & ~ui_in[0];

    assign uo_out  = {7'b0, speaker};
    assign uio_out = {speaker, 7'b0};
    assign uio_oe  = 8'h80;

    wire _unused_ok = &{ena, ui_in[7:1], uio_in};

endmodule
