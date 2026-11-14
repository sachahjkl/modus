title: A window for the debugger
date: 2026-11-14
release: next
picture: docs/screenshots/debugger_window.png
kind: Shown
guide: docs/TOOLS.md

The debugger has a window. Start `debugger_window` from the menu of the programs, type the name of a program that runs and press Enter: the window attaches to it. Four cards show what the console showed as tables: the threads, the stack of the chosen thread, and the variables and the source line of the chosen frame.

A key does each act. `h` holds a thread and `r` lets it run. `s` runs one instruction and `l` one source line. `o` runs one line over each call: the thread does not stop inside a procedure that the line calls. The console has that step too, as `step_over(thread)`.

The window holds no right over a program. It calls the service `debugger`, as the console does, through a connection of its own, and the root service decides which program a caller can debug.
