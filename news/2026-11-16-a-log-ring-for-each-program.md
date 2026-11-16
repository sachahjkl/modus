title: Each program keeps its own last log records
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system in which a program sees no other program. A program reads its own log records back through the log service, but until now all records shared one ring of 2047. A program that wrote many records pushed out the records of the others, and a reader that counted its lost records learned how much the others wrote.

The kernel now also keeps the last 64 records of each program in a ring that only that program fills. The budget of the program pays its 4 pages, and they return to the budget when the last handle to the stopped program closes. The log service reads there, with one new kernel operation, `Log_Read`, a caller's own records and the records of a child whose handle a starter lends. The kernel now has 35 operations.

In the machine test, a child of `log_reader` writes 2111 records after one record of `log_reader` and one record of each of its two other children. The whole log no longer holds those three records, but `log_reader` still reads each one, as the first record of its program, with nothing lost. A reader that acts for the principal still reads every record of the whole log, in order.
