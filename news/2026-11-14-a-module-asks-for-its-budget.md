title: A module asks for its budget
date: 2026-11-14
release: next
picture: none
kind: Decided
guide: docs/MODULE_CONTRACT.md

A program now says what it needs. The source of a module states one constant, `MODULE_BUDGET`: the pages, the programs and the threads that it asks for, with the reasons in its comment. The build writes it in the module file, so the hash of the module names it.

The root service decides. It gives a program its request up to 16384 pages, 8 programs and 32 threads, and writes a line on the log when it gives less. Two programs have an exception, each with its reason. A module with no request gets 2048 pages, one program and one thread. A program from a disk, or from another project, gets its request up to 8192 pages, one program and 4 threads, from one budget that pays all such programs, so a new program needs no change of the root service, and a file of a disk cannot take what the programs of the system need.

The page of each program on the site shows the budget that it asks for, beside its grants.
