/*
 * Music looper chip: records notes from seven buttons and plays them back as a
 * loop, one note per beat, as a square wave on one pin.
 *
 *   ui_in[6:0]  seven note buttons, one per pitch (row 0 = lowest)
 *   uo_out[0]   audio out (connect a small speaker)
 *   uio_out[7]  the same signal, on the Tiny Tapeout audio PMOD pin
 *   ui_in[7]    unused
 *
 * Expects a 50 MHz clock. The tune is a 32 step loop at 120 BPM, so one turn
 * round takes 16 seconds. Pressing a button toggles that pitch on the beat that
 * is playing at that moment: press once to record a note, again to erase it.
 *
 * Three blocks do the work:
 *   the song   32 columns of seven rows, the recorded notes
 *   the tempo  counts clock ticks to step through the columns, one per beat
 *   the tone   divides the clock down to the pitch of the note
 */

`default_nettype none

module tt_um_kellen_d_happy_birthday_chip #(
    // The clock the chip runs from, in Hz. Every interval below is derived from
    // this one number, so retargeting the design is a single edit.
    parameter CLOCK_HZ = 50000000,
    // Tempo in beats a minute. The loop is 32 beats long, so at 120 BPM one turn
    // round takes 16 seconds.
    parameter BPM = 120
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

    // Notes. Each row is one pitch, and the row number is the note code.
    localparam G4 = 3'd0, A4 = 3'd1, B4 = 3'd2, C5 = 3'd3,
               D5 = 3'd4, E5 = 3'd5, F5 = 3'd6;

    localparam COLS = 32;   // beats in the loop

    // ---- timing -------------------------------------------------------------
    // One beat lasts 60/BPM seconds, which is this many clock ticks. Divide
    // before multiplying: CLOCK_HZ * 60 is 3,000,000,000 at 50 MHz, which
    // overflows a 32 bit integer and would make BEAT_TICKS negative, freezing
    // the beat counter for good. Dividing first keeps every value in range.
    localparam integer BEAT_TICKS = 60 * (CLOCK_HZ / BPM);
    localparam integer BEAT_BITS  = $clog2(BEAT_TICKS);

    // ---- the song -------------------------------------------------------------
    // 32 columns, one per beat, each seven bits wide, one bit per row. Bit r of
    // song[c] set means row r plays on beat c. Playback takes the lowest set row,
    // so if several notes are recorded on one beat only one of them is heard.
    reg [6:0] song [0:COLS-1];

    // On reset the memory is wiped, one column a clock, before the loop begins.
    localparam S_CLEAR = 1'b0, S_RUN = 1'b1;
    reg       state;
    reg [4:0] clear_col;

    // ---- the tempo ------------------------------------------------------------
    // beat_tick counts clock ticks up to one beat. column is the beat now playing.
    reg [BEAT_BITS-1:0] beat_tick;
    reg [4:0]           column;
    wire beat_done = (beat_tick == BEAT_TICKS - 1);

    always @(posedge clk) begin
        if (!rst_n) begin
            beat_tick <= {BEAT_BITS{1'b0}};
            column    <= 5'd0;
        end else if (state == S_RUN) begin
            beat_tick <= beat_done ? {BEAT_BITS{1'b0}} : beat_tick + 1'b1;
            if (beat_done)
                column <= (column == COLS - 1) ? 5'd0 : column + 5'd1;
        end
    end

    // ---- the buttons ----------------------------------------------------------
    // Two flops to settle the pins, then the previous value gives the moment a
    // button goes down. A debounce timer is added in a later step.
    reg [6:0] btn_s0, btn_s1, btn_prev;
    always @(posedge clk) begin
        btn_s0   <= ui_in[6:0];
        btn_s1   <= btn_s0;
        btn_prev <= btn_s1;
    end
    wire [6:0] pressed = btn_s1 & ~btn_prev;   // one pulse as a button goes down

    // A press toggles that row of the beat that is playing. Press twice and it
    // is back how it was, so the same beat clears it on the next time round.
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_CLEAR;
            clear_col <= 5'd0;
        end else case (state)
            S_CLEAR: begin
                song[clear_col] <= 7'b0;
                if (clear_col == COLS - 1)
                    state <= S_RUN;
                else
                    clear_col <= clear_col + 5'd1;
            end
            default: begin   // S_RUN
                if (|pressed)
                    song[column] <= song[column] ^ pressed;
            end
        endcase
    end

    // ---- which note is playing ------------------------------------------------
    wire [6:0] row_bits = song[column];
    wire       note_on  = (state == S_RUN) && |row_bits;

    reg [2:0] pitch;
    always @(*) begin
        if      (row_bits[0]) pitch = G4;
        else if (row_bits[1]) pitch = A4;
        else if (row_bits[2]) pitch = B4;
        else if (row_bits[3]) pitch = C5;
        else if (row_bits[4]) pitch = D5;
        else if (row_bits[5]) pitch = E5;
        else if (row_bits[6]) pitch = F5;
        else                  pitch = G4;
    end

    // ---- the pitch table ------------------------------------------------------
    // Clock ticks in half a cycle of each note: CLOCK_HZ / (2 x frequency).
    localparam [15:0]
        HP_G4 = CLOCK_HZ / (2*392), HP_A4 = CLOCK_HZ / (2*440),
        HP_B4 = CLOCK_HZ / (2*494), HP_C5 = CLOCK_HZ / (2*523),
        HP_D5 = CLOCK_HZ / (2*587), HP_E5 = CLOCK_HZ / (2*659),
        HP_F5 = CLOCK_HZ / (2*698);

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
            default: half_period = HP_G4;
        endcase
    end

    // ---- the tone -------------------------------------------------------------
    // Counts up to half a cycle, then flips the output. That makes a square wave.
    // It restarts at the start of every beat so each note begins in the same
    // place, and a short silence at the end of the beat keeps the notes apart.
    reg [15:0] tone_count;
    reg        audio;
    wire gap = (beat_tick >= BEAT_TICKS - (BEAT_TICKS >> 3));

    always @(posedge clk) begin
        if (!rst_n || beat_done || !note_on || gap) begin
            tone_count <= 16'd0;
            audio      <= 1'b0;
        end else if (tone_count == half_period - 16'd1) begin
            tone_count <= 16'd0;
            audio      <= ~audio;
        end else begin
            tone_count <= tone_count + 16'd1;
        end
    end

    wire speaker = audio;

    assign uo_out  = {7'b0, speaker};
    assign uio_out = {speaker, 7'b0};
    assign uio_oe  = 8'h80;

    wire _unused_ok = &{ena, ui_in[7], uio_in};

endmodule
