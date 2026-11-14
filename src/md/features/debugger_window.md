# The window of the debugger

## Purpose

A developer follows a program with a key for each step, and reads its threads, its stack, its variables and its source line in one window. Before, the console was the only way: one typed line for each table.

The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The window of the debugger".

## Constraints

- **The debug access is one right, in one place.** The service `debugger` holds the handle with the right to debug a program, and the root service decides which program a caller can debug. A second holder of that right is a second place to check.
- **A command is a function.** The exports of the service are typed functions with described records. A window that reads a text of the console would break that rule.
- **The service debugs one program at a time**, for one caller.

## The chosen form

**A client of the service, as the console is.** The program `debugger_window` has a connection of its own to the service `debugger`, and calls the same exports: `attach`, `threads`, `stack`, `locals`, `source`, `hold`, `release`, `step`, `step_line`, `step_over`, `events`, `break_at`, `breaks`, `break_remove`, `registers`, `detach`. It holds no right over a program. Its grants are the connection to that one service, the boot image for the description of the exports, and the grant to act for the principal.

**The rows come back as records.** A call of a service gave its caller only the number that the export returns. The call of the system library now also copies the records of a Table result into the memory of the caller, at most those that the memory holds. The console had this code for itself; the window uses the shared form.

**The layout of a record is checked at the start.** The window declares the records of the rows that it reads. The description of each export in the file of the service states the size of its record. The window compares the two at its start, and attaches to nothing when one differs.

**The window reads again by a period.** A thread that ran can stop at a breakpoint with no key of the window. The window takes the events of the service and reads the threads again each 500 ms.

## The refused forms

- **A window inside the service.** The service would draw, take keys and hold the debug access in one program. A fault of the drawing would then be a fault of the program that can stop any thread.
- **A window that holds the right to debug.** Two programs with the right, two checks of who can debug what.
- **A read of the records by their description**, field by field and by name, as the tool does for a call from the host. It needs no declared record, and it costs a search of a name for each field of each row at each read. The check of the sizes at the start finds the same fault for less.
- **A package of the records that the service and the window both import.** The step that describes the exports of a module reads the records in the source of that module.

## Subtle points

- **A size is not a layout.** Two fields that change places keep the size of their record. The check finds a record that grew or shrank, which is the change that the service makes when a text gets longer.
- **A frame with no line.** A thread that waits in the kernel is at an instruction of the system library in assembly, which has no source line: its caller is the next frame.
- **The source text.** The service gives the path, the line and the hash of the file at the build. The text of the line is not on the machine: the window says so, as the service does.
- **Who is attached.** While the console is attached to a program, the window attaches to nothing: the export fails, and the status line gives its code.

## State

Built: the window, the shared call that gives the records of a Table result, a breakpoint at the line of the chosen frame and its removal, the registers of the chosen thread, the test in the machine of the debugger. Left: a watch and a breakpoint at a typed place, a click on a row, the memory of the program, and the sentence of a failure in place of its code.
