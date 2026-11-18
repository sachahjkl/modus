# The due picture of a terminal: a change that waits is said before the wait

A terminal draws at most one picture in each `FRAME_TIME` (16 ms). So a change can wait for its picture while every thread of the terminal waits. The machine test takes a picture only of a settled screen ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "When the tool takes a picture"), and a wait with a change looks the same as a wait with nothing to draw. The terminal says the difference with `Picture_Due` (`display.picture_due_set`). This file records where in its loop it says it, and why.

## The purpose

- A picture of a settled screen shows the end of each output of a terminal: the last row, the count of the rows, the next prompt.
- The rule holds with no time in the tool and no copy of the pace of the terminal.

## The fault that made this form

Two runs of the main machine test took a picture of the console that showed the state of a running call. The log had the whole result, and each program was in a wait.

The terminal declared a due picture at one place: after the events of a turn, from the state at that time. Then it drew. A record that came while it drew its picture had no declaration:

1. The reader takes the record and adds 1 to the count of its groups of records (`activity`). The drawer does not wait with nothing to draw, so the reader does not wake it.
2. The `Present` of the picture ends the due picture of the compositor.
3. The drawer waits for the time of its next frame, with the change and with no due picture.
4. The console has written its last line and waits. The reader waits. For at most one `FRAME_TIME`, every program waits, no window has a picture that waits for a frame, and no window has `due` 1. A picture of the screen taken then is settled, and it shows the picture before the change.

No wake was lost. The drawer drew the change at its next frame. The terminal said a false fact to the tool for some milliseconds.

## The chosen form

**One decision at the start of each turn, before each wait.** The turn reads the count of the groups of records once (`seen`). From that count, the count of the last picture (`drawn`), a change with no record (a key, a press of a scroll bar, a new font: `dirty`), the flag of the measure and the flag that the compositor still holds the canvas, the procedure `terminal_records.picture_wait_choose` gives two values:

- the wait of the turn: nothing to draw, the compositor, or the next frame;
- whether a picture is due: a change waits (`dirty`, or `seen` is not `drawn`).

The terminal sends the due state, then waits. So each wait of the loop starts with the true state.

- **Nothing to draw.** The wait is on `activity` with the value `seen`. A record after the read of `seen` ends the wait at once, because the kernel compares the word before it waits. The next turn then says that a picture is due before its own wait.
- **The next frame or the compositor.** A picture is already due. A record during this wait needs no wake: the due picture is already said, and the next picture takes each record that the reader took before it.

**The stop of the program is a change too.** The kernel adds 1 to the event word of each thread of a program when a program that it holds stops. The terminal reads its event word just before its look at the state of the program, and the wait with nothing to draw also waits on that value. So a stop after the look ends the wait at once, and the same turn finds the stop and draws it. The look comes before the check of the canvas: a stop that waits for the compositor is known, and the next turn says that its picture is due. The look at each 250 ms stays as the deadline of that wait: the checks of a lost wake read it.

**A frame that did not reach the compositor is still owed.** When the full command ring refused the `Present`, the compositor left the frame out, or the drawing module refused the draw, the window layer does not keep the frame as the last one (`drawing.drawn` false, or `drawing.late`). The terminal then marks the view changed, so the next turn draws it again and says before its wait that it is due. Without this, the next turn saw no change, waited with nothing to draw, and the screen kept the older picture until the next record or key.

**The decision is a procedure with no state.** It reads no clock and no word, so a host test drives it with each case (`src/library/support/terminal/picture_wait_test.odin`).

## The refused forms

- **A wake of the drawer for each group of records.** The reader would wake the drawer during the wait for the next frame too, and the drawer would then say the due picture. It costs one kernel entry of each thread for each group of records, and a writer such as `flood` gives a new group at each turn of the reader. The decision before the wait gives the same fact with no wake.
- **A check in the tool of the terminal ring.** The tool would read the count of the records that the reader did not take. That does not close the gap: the reader took the records. The change is in the terminal, and only the terminal knows that its picture is older.
- **A wait in the tool of one `FRAME_TIME` before a picture.** A fixed delay for a state is refused for every test ([`docs/TOOLS.md`](../../../docs/TOOLS.md), "The bounds of the tests"), and it copies the pace of one program into the tool.
- **A picture at once for a record that comes during a picture.** The pace of the terminal keeps a writer such as `flood` from costing one picture for each group of records.

## The subtle points

- `seen` is read once in a turn. The wait with nothing to draw uses this value, not a second read: a second read can take a record that the decision did not see, and the wait then holds while the record waits.
- The `Present` ends the due picture in the compositor. So a change that comes after the read of `drawn` and before the `Present` must be said again after the `Present`: the next turn does it.
- The checks of a lost wake stay (`lost_wake_check` in `src/modules/system/terminal/main.odin`). They do not explain this fault, which lost no wake. They name the side of a lost wake if one comes.
- The event word also changes for the other events of the thread: the end of another thread, an interrupt. Such an event ends one wait with nothing to draw, and the turn reads the word again at its look at the program, so no turn follows with no sleep.
- A drawing module that refuses each draw makes the terminal try a frame at each `FRAME_TIME`. The window layer writes the refusal on the log one time; the frames that it tries cost only the calls.

## The state

Built: the decision, its host test, its use in the loop of the terminal, the stop of the program in the wait with nothing to draw, and the frame that did not reach the compositor drawn again.
