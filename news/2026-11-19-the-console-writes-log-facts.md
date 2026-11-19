title: The console and the window of the log write the sentence of a log fact
date: 2026-11-19
release: next
picture: none
kind: Shown
guide: docs/CONSOLE.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

A log fact is a record of typed values in the log, with no text. The console, under a line, and the window of the log now write its sentence from the module file that the fact names, each value in the color of its kind. A fact whose module the boot image does not hold shows its bytes in hexadecimal.

In the console, `log.records(0) |> facts(log_reader.Fact_Probe)` gives the fields of one fact type as the columns of a table. `where` takes a condition on a field: `log.records(0) |> where(level = Warning)`. The console checks the fact name, the field and the member of the level before any call, and completes them.
