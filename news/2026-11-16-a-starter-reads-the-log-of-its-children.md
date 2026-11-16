title: A program reads the log records of the programs that it started
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system in which a program sees no other program, only the programs that it started. Its log service gave a program its own records only.

A program that starts programs now also reads what its children wrote. It lends the handle of a child to the log service for one call, and receives the records of that child, and of no other program. The handle is the proof: only the starter received it when it made the child. A grandchild is read only if the child gives its handle. In the machine test, `log_reader` starts two children and reads the one record of each, two times in a row, with no record of the first run in the second.
