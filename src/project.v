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
 * round takes 16 seconds. Pressing a button records that pitch on the beat that
 * is playing at that moment: press once to record a note, again to erase it.
 *
 * Three blocks do the work:
 *   the song   32 columns, one note code each, the recorded notes
 *   the tempo  counts clock ticks to step through the columns, one per beat
 *   the tone   divides the clock down to the pitch of the note
 *
 * The song stores one three bit code per beat rather than a bit per row. Codes
 * 0 to 6 are the seven pitches and code 7 means empty. That is 96 flip flops
 * instead of 224, and a three bit read instead of seven, which is what keeps the
 * design small enough for a 1x1 tile. Playback only ever plays one note per
 * beat, so nothing is lost.
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

    // Notes. Each row is one pitch, and the row number is the note code. EMPTY is
    // the eighth code, so a beat holds one of these eight values in three bits.
    localparam G4 = 3'd0, A4 = 3'd1, B4 = 3'd2, C5 = 3'd3,
               D5 = 3'd4, E5 = 3'd5, F5 = 3'd6, EMPTY = 3'd7;

    localparam COLS = 32;   // beats in the loop

    // ---- timing -------------------------------------------------------------
    // One beat lasts 60/BPM seconds, which is this many clock ticks. Divide
    // before multiplying: CLOCK_HZ * 60 is 3,000,000,000 at 50 MHz, which
    // overflows a 32 bit integer and would make BEAT_TICKS negative, freezing
    // the beat counter for good. Dividing first keeps every value in range.
    localparam integer BEAT_TICKS = 60 * (CLOCK_HZ / BPM);
    localparam integer BEAT_BITS  = $clog2(BEAT_TICKS);

    // ---- the song -------------------------------------------------------------
    // 32 columns, one per beat, each holding one note code. EMPTY means nothing
    // plays on that beat. One code per beat, rather than a bit per row, is what
    // keeps the memory small enough to fit a 1x1 tile.
    reg [2:0] song [0:COLS-1];

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
    // A mechanical switch chatters for about a millisecond when it is pressed. A
    // new value is only believed once it has held steady for that long, so the
    // chatter never gets through and a whole press counts once.
    localparam integer DEBOUNCE_TICKS = CLOCK_HZ / 1000;   // 1 ms
    localparam integer DEB_BITS = $clog2(DEBOUNCE_TICKS);

    // Two flops to settle the pins, so the rest of the logic sees a clean signal.
    reg [6:0] btn_s0, btn_s1;
    always @(posedge clk) begin
        btn_s0 <= ui_in[6:0];
        btn_s1 <= btn_s0;
    end

    // The debounced value, and how long the raw value has differed from it.
    reg [6:0]          btn_state;
    reg [DEB_BITS-1:0] deb_count;
    always @(posedge clk) begin
        if (!rst_n) begin
            btn_state <= 7'b0;
            deb_count <= {DEB_BITS{1'b0}};
        end else if (btn_s1 != btn_state) begin
            if (deb_count == DEBOUNCE_TICKS - 1) begin
                btn_state <= btn_s1;
                deb_count <= {DEB_BITS{1'b0}};
            end else begin
                deb_count <= deb_count + 1'b1;
            end
        end else begin
            deb_count <= {DEB_BITS{1'b0}};
        end
    end

    // The previous debounced value gives the moment a button goes down.
    reg [6:0] btn_prev;
    always @(posedge clk) begin
        if (!rst_n) btn_prev <= 7'b0;
        else        btn_prev <= btn_state;
    end
    wire [6:0] pressed = btn_state & ~btn_prev;   // one pulse as a button goes down

    // Which row was pressed. If several are, the lowest one wins, the same order
    // the tone uses to choose a note.
    reg [2:0] pressed_row;
    reg       pressed_any;
    always @(*) begin
        pressed_any = 1'b1;
        if      (pressed[0]) pressed_row = G4;
        else if (pressed[1]) pressed_row = A4;
        else if (pressed[2]) pressed_row = B4;
        else if (pressed[3]) pressed_row = C5;
        else if (pressed[4]) pressed_row = D5;
        else if (pressed[5]) pressed_row = E5;
        else if (pressed[6]) pressed_row = F5;
        else begin
            pressed_row = EMPTY;
            pressed_any = 1'b0;
        end
    end

    // A press writes the playing beat. If the beat already holds that note it is
    // erased instead, so pressing twice puts it back how it was.
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_CLEAR;
            clear_col <= 5'd0;
        end else case (state)
            S_CLEAR: begin
                song[clear_col] <= EMPTY;
                if (clear_col == COLS - 1)
                    state <= S_RUN;
                else
                    clear_col <= clear_col + 5'd1;
            end
            default: begin   // S_RUN
                if (pressed_any)
                    song[column] <= (song[column] == pressed_row) ? EMPTY : pressed_row;
            end
        endcase
    end

    // ---- which note is playing ------------------------------------------------
    wire [2:0] note = song[column];
    wire       note_on = (state == S_RUN) && (note != EMPTY);

    // The note code is the pitch, except on an empty beat, where it is shown as
    // G4 so the waveform never shows an invalid pitch.
    wire [2:0] pitch = (note == EMPTY) ? G4 : note;

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
