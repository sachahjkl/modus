title: A kernel command gives each wrong argument
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

A kernel command that the kernel refuses gave one error record: the first argument that was wrong. A program can now give the command a table of error details. The kernel then writes the error record, and one more detail for each other argument that it finds wrong: a handle, a count above its limit, an unknown flag, a choice out of its range. The program `errors` gives `Memory_Create` a budget that names nothing and an unknown flag, and the log shows the two lines. A command with no table runs the same lines of the kernel as before. The program `errors` prints the time of a command with a table and with none.
