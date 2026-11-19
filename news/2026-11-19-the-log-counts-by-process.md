title: The log counts its records by process
date: 2026-11-19
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

A log record no longer carries a free name that its writer chooses to group it. The window of the log shows a card for each process with the count of its records, and the console groups the records of a line by process. A line of a process on the serial port starts with the name of the process in brackets. The text of one record grew from 152 to 168 bytes. This is the first step of log facts: the next steps give each record that matters a type, which a reader filters by field.
