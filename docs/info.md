## How it works

Three blocks do the work. The score picks which note comes next and how long it lasts. The tempo counts clock ticks to time each note. The tone divides the clock down to the pitch of the note.

## How to test

Run it with a 100 kHz clock. Hold rst_n low for a few cycles, then raise it, and the tune plays on uo[0]. Hold ui[0] high to pause.

## External hardware

A small speaker or buzzer on uo[0], or the Tiny Tapeout audio PMOD on uio[7].
