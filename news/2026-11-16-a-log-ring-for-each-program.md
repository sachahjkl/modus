title: Each program keeps its own last log records
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system in which a program sees no other program. A program reads its own log records back through the log service, but until now all records shared one ring of 2047. A program that wrote many records pushed out the records of the others, and a reader that counted its lost records learned how much the others wrote.

The kernel now also keeps the last 64 records of each program in a ring that only that program fills. The budget of the program pays its 4 pages, and they return to the budget when the program stops. The log service reads a caller's own records there, with one new kernel operation, `Log_Read`. The kernel now has 35 operations.

In the machine test, a child of `log_reader` writes 2111 records after one record of `log_reader`. The whole log no longer holds that record, but `log_reader` still reads it, as its first own record, with nothing lost. A reader that acts for the principal still reads every record of the whole log, in order.
