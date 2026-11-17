# The window of the debugger

## Purpose

A developer follows a program with a key or a click for each act, and reads its threads, its stack, its variables, its source line and its memory in one window. Before, the console was the only way: one typed line for each table. With the debug place field and the clicks on the rows, a developer needs the console for no act of the debugger.

The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The window of the debugger".

## Constraints

- **The debug access is one right, in one place.** The service `debugger` holds the handle with the right to debug a program, and the root service decides which program a caller can debug. A second holder of that right is a second place to check.
- **A command is a function.** The exports of the service are typed functions with described records. A window that reads a text of the console would break that rule.
- **The service debugs one program at a time**, for one caller.
- **No cut text.** A procedure name has up to 80 bytes, and the text of a breakpoint up to 160: a row of the window is as high as its text needs.

## The chosen form

**A client of the service, as the console is.** The program `debugger_window` has a connection of its own to the service `debugger`, and calls the same exports: `attach`, `threads`, `stack`, `locals`, `source`, `hold`, `release`, `step`, `step_line`, `step_over`, `events`, `break_at`, `watch`, `breaks`, `break_remove`, `registers`, `memory`, `detach`. It holds no right over a program. Its grants are the connection to that one service, the boot image for the description of the exports, and the grant to act for the principal.

**The rows come back as records.** A call of a service gave its caller only the number that the export returns. The call of the system library now also copies the records of a Table result into the memory of the caller, at most those that the memory holds. The console had this code for itself; the window uses the shared form.

**The layout of a record is checked at the start.** The window declares the records of the rows that it reads. The description of each export in the file of the service states the size of its record. The window compares the two at its start, and attaches to nothing when one differs.

**The window reads again by a period.** A thread that ran can stop at a breakpoint with no key of the window. The window takes the events of the service and reads the threads again each 500 ms, and the memory view with them.

**The input goes through the elements of the interface.** The window gives the events of its surface to the input of the frame (`interface.window_events`). The name of a program and the debug place are `interface.text_input` fields; the three acts on the debug place are `interface.button` elements; each row that takes a click is an element of the frame (`interface.element_interact`), so a press and a release on one row activate it, and the row joins the order of Tab. A key that no element took is a key of the window. Escape takes the focus from the field, so the letter keys act again. The window acts after the frame, then draws the frame again: an act changes the rows that the frame drew.

**The debug place.** A debug place is a text that names a place of the debugged program, in the form that the export takes: the full name of a procedure (`debug_target::add_step`) or a file and a line (`src/modules/tests/debug_target/main.odin:82`) for `break_at`; an address (`0x403010`) or the value path of a global (`debug_target::rounds`) for `watch` and `memory`. The window passes the text as it is: the service parses it, and its error says what is wrong. The window computes no address.

- **break at** calls `break_at` with the text.
- **watch** calls `watch` with the text and 8 bytes. A last word `1`, `2`, `4` or `8`, after a space, is the length instead: `debug_target::shape.phase 4`. A value path and an address hold no space, so the word is never a part of the place.
- **memory** calls `memory` with the text and 128 bytes: the eight rows of 16 bytes that the card of the memory shows.
- A break or a watch that the service took empties the field: its text is now in the card of the breakpoints. A memory view keeps the text, so the developer reads near it with one edit.

**The memory view.** A card of its own, between the source and the stack, the full width of the right column: each row is its address with no leading zero, 16 bytes in hexadecimal and their printable characters, in the font of the cells. An address of the program is below `USER_END`, so it has 12 hexadecimal digits at most, and a row of 12 + 47 + 16 characters with two gaps of 8 pixels is exactly the width of the card: the program checks that width at its build. The window reads the view again with the threads: a byte that the program writes shows at the next read.

**A click on a row does what a key does.** Each click is an act that a key already has, so a developer learns one set of acts:

- a row of the threads chooses that thread, as up and down do;
- a row of the stack chooses that frame, as page up and page down do;
- a row of the source puts a breakpoint at its line, as `b` does for the line of the chosen frame;
- a row of the breakpoints removes that breakpoint, as the key of its number does.

**The breakpoints have a card of their own**, under the card of the program. Its first row is at a fixed place, so the machine test clicks it with no read of the log.

## The refused forms

- **A window inside the service.** The service would draw, take keys and hold the debug access in one program. A fault of the drawing would then be a fault of the program that can stop any thread.
- **A window that holds the right to debug.** Two programs with the right, two checks of who can debug what.
- **A read of the records by their description**, field by field and by name, as the tool does for a call from the host. It needs no declared record, and it costs a search of a name for each field of each row at each read. The check of the sizes at the start finds the same fault for less.
- **A package of the records that the service and the window both import.** The step that describes the exports of a module reads the records in the source of that module.
- **`interface.list_with_choice` for the stack and the threads.** It takes the pointer and the keys, but it draws each row on one line of 24 pixels and cuts a longer name. The window keeps its rows of the lines that their text needs, and takes the pointer on each one with the same element input.
- **A test of the pointer place by hand.** A second rule of what a click is, beside the one of the interface: the focus, Tab and the release on the same element would differ from every other window.
- **A parse of the place in the window**, to name the error before the call. The service parses it already; a second parser would be a second form of the place that can differ.
- **A choice of the length of a watch by four buttons.** Four elements for one number that the developer types in the same line in the console.
- **A typed count of bytes for the memory.** The card shows eight rows; a larger count gives rows that it does not show, and a smaller one is a part of the same rows.
- **The memory in the card of the variables**, as a third view. That card is 312 pixels wide inside: a row of 16 bytes needs 616.
- **A click on a breakpoint that puts its text in the field.** A useful act, but no key does it; a click that removes keeps one set of acts.

## Subtle points

- **A size is not a layout.** Two fields that change places keep the size of their record. The check finds a record that grew or shrank, which is the change that the service makes when a text gets longer.
- **A frame with no line.** A thread that waits in the kernel is at an instruction of the system library in assembly, which has no source line: its caller is the next frame.
- **The source text.** The service gives the path, the line and the hash of the file at the build. The text of the line is not on the machine: the window says so, as the service does.
- **Who is attached.** While the console is attached to a program, the window attaches to nothing: the export fails, and the status line gives its code.
- **The field holds the keys.** While the debug place field has the focus, `h`, `s` and each other letter are characters of the place. The window starts with the focus in the name field, and a press on a button or a row takes the focus from the field.
- **The row of a removed breakpoint.** The click removes the breakpoint, and the row leaves the next frame with the focus that the press gave it: no element has the focus then, and the keys act on the window.
- **A memory view of a page that ends.** The kernel reads only the pages that the program maps: the view has fewer rows, and the card says how many it shows.

## State

Built: the window, the shared call that gives the records of a Table result, a breakpoint at the line of the chosen frame and its removal, the registers of the chosen thread, the debug place field with a breakpoint, a watch and a memory view at a typed place, a click on a row of the threads, of the stack, of the source and of the breakpoints, the test in the machine of the debugger. Left: the sentence of a failure in place of its code.
