title: Each program refuses a word that names nothing
date: 2026-11-17
release: next
picture: none
kind: Fixed
guide: docs/MODULE_CONTRACT.md

modus is an operating system whose programs talk through records in shared memory. A record holds its choices as numbers: the command of a ring, the mode of a child, the tone of a line of text.

Until now, some programs read a number that named no choice as a choice: an unknown role became the parent, an unknown command was ignored with no word. Now each program reads such a number at one place, which refuses it. A service answers with an error record that names the number, a program that a starter gave a wrong mode writes a line and stops, and the compositor and the terminal count the records of a window that they refuse and write the count on the log.

The tables of the modules that `inspect.modules()`, `manual.running()` and `program_modules()` give no longer write "unknown" as the writer of a module record: a writer that names nothing leaves the field empty, with a line of the log.
