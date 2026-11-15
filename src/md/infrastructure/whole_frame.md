# A whole frame: a window never shows a picture that is being drawn

A picture of a window reaches the screen whole, or it does not reach it. This is a rule of the system, for every window. It lives in the package `display` and in the window layer of the interface package. A program writes no code for it.

How a program opens a surface and presents a picture is in [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "2.1 Draw record (format version 9)" and "2.2 Damage by difference". This file records why the rule has this form.

## The purpose

- The compositor composes a frame of the screen at any time. It must never read pixels that a program writes at that time.
- A program that moves a large form each frame, and a program that changes one number a second, follow the same rule with the same code.

The fault that made the rule: a surface had one picture. The window layer paints a damage rectangle with the background, then draws its records. The compositor read the rectangle between the two, and the screen showed the head of a form with no body ([features/heron_program.md](../features/heron_program.md)).

## The constraints

- **A program cannot hold the compositor.** The compositor never waits for a program, and never does work that a program can make longer without a bound.
- **The program pays.** The memory of a picture comes from the budget of its program, never from the budget of the compositor.
- **No code in each program.** A rule that 51 programs must each write is a rule that one of them forgets.
- **The compositor cannot hold a service.** A program that serves other programs must not stop for a time with no bound because the compositor does not read.
- **The damage stays small.** A frame that changes one number draws a few rectangles, not the window.

## The chosen form

**Every surface has two pictures.** `display.open` creates the memory of two pictures, always. The program draws in one picture. `Present` names the picture that is complete, and the compositor reads only that one from then on. The next frame is drawn in the other picture. The compositor refuses a surface whose memory does not hold two pictures.

- The compositor shows the surface of a window only after its first `Present`. Until then the window has its frame and the background color: the first picture is whole too.
- The option `two_pictures` of `display.open` is removed. A surface with one picture does not exist.

**The window layer keeps the debt of each picture.** A picture holds the frame of two frames before. The window layer keeps one table, the table of the last frame that it presented, and for each picture the rectangles where that picture differs from that table: its debt. A frame draws the difference with the last table and the debt of its picture, and presents the difference with the last table. After the `Present`, the debt of the drawn picture is empty, and the difference joins the debt of the other picture.

- A program gives the window layer two tables, as before the rule: the table that it builds and the table of the last frame. It gives no table for the second picture. The three programs that gave one no longer do.
- The damage of a frame is the damage of two steps. A window that changes one number draws that number two times. It is still a few rectangles.
- A picture whose state is not known (the first frame of each picture, a new font, a `Present` that the full ring refused) is drawn whole.

**The program draws only when the compositor took the last `Present`.** Until then the compositor can still read the picture that the program would draw in. `display.canvas_free` says it: the count of the records that the compositor read from the ring of the window passed the last `Present`.

- `display.canvas_wait` is the wait of the system. The thread waits on the count of the records that the compositor read, a word of the ring of the window. The compositor wakes the thread when it has read the ring. The wait has no fixed step.
- The wait has a bound, and the bound only ends a hang: it is the hang bound of the tests, 60 s. When it ends, the window writes one line on the log, and it waits no more: each frame is then left out at once, until the compositor reads again. A compositor that is stopped costs a program one bound, one time.
- The window layer calls `display.canvas_wait` at the end of each frame. A frame that is left out changes no state: the next frame is compared with the last frame that was presented.
- A program that serves other programs in the thread of its window asks `display.canvas_free` before it builds a frame, and never waits. When the answer is no, the wait of its loop (`display.wait_events`) ends when the compositor has read. `heron`, `manual`, `terminal`, `remote`, `server`, `log` and `quic_echo` do this.
- A program that draws by hand in the canvas calls `display.canvas_wait` before it draws, and draws the whole canvas: the canvas holds the frame of two frames before.

**The proof is two counts of the compositor.** The compositor cannot see a write. It sees which picture each `Present` names. A program that draws in the picture on the screen must name that picture again, because it has no other complete picture to name. So the compositor counts, for each window, the `Present` records that named the picture that it already showed (`pictures_drawn_again`), and the frames that it composed from a picture of the window (`frames`). The export `windows` gives both. The main test types one line in the console and waits for 0 windows with a picture drawn again.

## What a stopped or hostile program shows

- **A program that stops in the middle of a draw**: the screen keeps the last picture that the program presented, whole. The picture that was being drawn was never named.
- **A program that never presents**: its window has its frame and the background color.
- **A hostile program** holds the right to write both pictures: it can write the picture that the compositor reads. The screen then shows a mix in the window of that program, and nowhere else. The compositor reads the surface as pixels only, waits for nothing, and checks each number of a `Present` against the size of the surface. No rule of the compositor can stop this write, so the rule does not try: the count `pictures_drawn_again` says it for a program that presents, and a program that harms only its own window harms no other program.

## The memory

A window of 1024 by 720 pixels is 720 pages for a picture: the second picture adds 2.8 MiB. The 51 programs with a window add about 76 MiB in all when each of them runs, by a count of their window sizes. How many run at one time in the main test is not counted here: the measure of the root service gives the margin of a run. The budget of a program moves pages from the root service when the program starts, so the cost is in the budget of each program:

- A program with the usual budget of 2048 pages and no other large memory has room for a second picture.
- The budgets of the programs that had less room than a second picture, or a room that no count gives, are larger by 1024 pages: `kernel_events`, `extended_state`, `scheduler`, `errors`, `quic_echo`, `server`, `address_space`, `rings`, `pointers` and `vector_glyphs`. The budget of `budget` is larger by 256 pages.

## The refused forms

- **Two pictures as an option of the program.** It was the form before: three programs asked for two pictures, 48 did not, and each of the 48 could show a mix. A rule that a program must ask for is not a rule of the system.
- **Two pictures only in the window layer, and the programs that draw by hand apart.** The 11 programs that draw by hand then keep one picture, or need a second form of the rule. One form in `display` covers both.
- **One picture, and a word that says "the program draws".** The compositor then skips the window or copies it while the word is clear. A program that always draws, or that stops in the middle of a draw, keeps the word set: the compositor shows an old frame for ever, or it reads a picture that is being drawn. A copy by the compositor is also work of the compositor for each window, paid by its budget, and its length is chosen by the program.
- **One picture, and the compositor waits for the program.** A program must not hold the compositor.
- **Three pictures, so that the program never waits.** It is one picture more for each window, and the program still needs to know which picture the compositor reads: the same count of the ring.
- **A table for each picture, in the memory of the program.** It was the form of the three programs with two pictures. Each program must give the memory of a third table and of its text, and the 48 other programs would each change. The debt of a picture is 8 rectangles in the window layer.
- **A copy of the changed rectangles from the shown picture into the drawn one.** It needs no debt, but the drawing module draws in the canvas of the caller, and a copy is a second way to bring a picture up to date. The debt uses the one draw.
- **A wait of 1 ms, then a new look.** It was the form of the three programs. It is a fixed delay: the frame is late by up to 1 ms for nothing, and a thread wakes with no cause.
- **A wait with no bound in the window layer.** A compositor that is stopped by a debugger would stop each program with a window, among them a service.
- **A line of the log for each window that says "two pictures".** It is 51 lines in a bounded log, and it proves the option, not the behavior. The counts of the compositor are one check.

## The subtle points

- `canvas_free` reads a count that the compositor writes when it takes a record, before it changes the picture that it reads. Both are in one turn of the one loop of the compositor, with no frame between them, so the count is enough.
- The compositor wakes a thread that waits for the canvas with the flag of the ring that says "the writer waits". It enters the kernel for that wake only when the flag is set.
- **The wait is on a value that was read.** The compositor adds 1 to the count of the records read for each record of any kind, not only for a `Present`. So the wait list holds the count with the value that the thread read, and only when that value says "not free". Each record that the compositor takes after that read changes the count and ends the wait, and the thread asks again. The proof that no wake is lost: the thread sets the flag "the writer waits", then the kernel reads the count; the compositor writes the count, then reads the flag. One of the two sees the other.
- **When the canvas is free at that read, the list gets no word.** The list is marked full, which ends the wait at once with no kernel entry. The form that was refused: a wait on the count plus 1, "a value that the count does not have". The compositor can take one record more (a pointer shape that the program sent after its `Present`) before the thread sleeps. The count then has that value, the flag was not set when the compositor read it, and the thread sleeps with no wake to come.
- **One "no", one wake.** A program that asked `canvas_free` and got no has a mark in its window. `display.wait_events` adds the event of the surface while the mark is set, and the mark is cleared when the wait finds the canvas free. A program that does not ask again then sleeps in its next wait: it does not turn with no sleep.
- **One thread owns a window.** The flag of the ring is cleared after a wait, so a second thread that waits on the same window would lose its wake.
- **A turn of the compositor has a bound.** The compositor takes from the ring of a window the records that the ring holds at the start of the turn, at most its capacity, and no more (`system.records_of_turn`). A program that writes as fast as the compositor reads then cannot keep it from the frame, the input and the other windows.
- **The wake costs the compositor one kernel entry, and the program chooses it.** The flag is in memory that the program writes. A program that sets it at each turn costs one wake for each turn in which it also sent a record: the cost has the bound of the sends of that program.
- **A `Present` with a picture number that names no picture is refused and counted** (`presents_refused` in the export `windows`). It changes no picture and no damage, and it is not a first `Present`: a window shows only a picture that its program named.
- A frame that is equal to the last table draws nothing and presents nothing, also when its picture has a debt: the screen shows the other picture, which has none.
- The time of a wait for the canvas is not in the measure of a picture: `display.canvas_wait` moves the start of the measure by the time that it waited.
- A program that draws over the frame of the window layer by hand (`interface_font`, `vector_glyphs`) ends its frame with `window_frame_end_without_present`: the window layer draws the frame whole and presents nothing, the program draws over it in the same canvas, then presents. With `window_frame_end` the canvas is the other picture after the call.
- `interface.window_events` says that an event came when a frame was left out and the canvas is free again: a program that draws only after an event then draws the frame.

## The state

Built: two pictures for every surface, the debt of each picture, `display.canvas_wait`, the first picture after the first `Present`, the bound of a turn of the compositor, the three counts in the export `windows`, the step of the main test, the host tests of the debt rule, of the procedures of `window_frame_end` on a window in plain memory, and of the bound of a turn. The root service writes one measure when the console is started: the free pages of its budget, now and at the lowest.

Left:

- No host test of the wait itself (`canvas_wait` while the canvas is not free, the wake of the compositor): it enters the kernel. No host test of `window_frame_end_without_present`, which reads the clock, nor of a difference or a draw that the drawing module refuses.
- The measure of the root service is written at the end of the start. The lowest count of a whole test, with the programs that the console starts later, is not written: the log of the main test has little room for more lines.

- A program that draws only after a change of its own, and reads its events with `display.next_event`, does not draw a frame that was left out when the compositor reads again. It draws it at its next change. This needs a compositor that did not read for the whole bound.
- No check reads the pixels of the screen for a mix. The counts say what each program named, not what it wrote.
- The budgets were raised from a count of the pages of each program, not from a measure of a run.
