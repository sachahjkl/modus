title: A program reads its own log records
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

The log service gives a program its own records, with their times, levels, channels and value runs. It needs no right to read the whole machine: a connection to the log service is enough. The kernel writes the program slot and the program serial in each record, and the root service writes the two numbers of the caller in the grant of its connection. So a program receives the records of its own run only, and not those of an earlier program in the same slot. The console and `remote` act for the principal, and still read the whole log. The program `log_reader` checks it in the machine test: from the number 0, it receives its own record and no row of another program.
