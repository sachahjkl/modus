title: A program cannot change the module record of its starter
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The kernel keeps a module record for each module in a program: its addresses and its hash. The reports of a fault, the manual and the console name the code of a program with these records.

Now the kernel marks each record with its writer: `starter` when the program that started the program wrote it, `program` when the program wrote it for itself. A program cannot remove or replace a record of its starter. It cannot unmap the code of that module or map other memory at its addresses either. So a record of the writer `starter` names the code that really runs at those addresses.

`program_modules()` in the console, `inspect.modules()` and `manual.running()` show the writer in a field `writer`. In the main machine test, the program `imports` tries the four changes, and the kernel refuses each one.
