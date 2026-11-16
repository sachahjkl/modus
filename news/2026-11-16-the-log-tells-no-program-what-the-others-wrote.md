title: The log tells no program what the others wrote
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system in which a program sees no other program. A program reads its own log records back, from a ring that only its own records fill.

Two facts of the log still told it how much the other programs wrote. The kernel refused a record when a budget above the program was full, and a `Log` waited for the lines of the others on the serial port.

Now the log records of each second are an amount of a budget, as its pages: a starter gives each child a part of its own, and each budget counts only its own records. A refusal says only that the program wrote its own amount. `Log` writes the records in memory only; the tick of the first processor writes their lines on the serial port after it, in their order.

The program `log_reader` checks it: its storm child takes 100 of its 112 log records of each second, and gives them back at its stop.
