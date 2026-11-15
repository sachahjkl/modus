title: The hash of a disk program in the table of the programs
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The table of the programs that run has a new column, `hash`. For a program that the root service started from a disk, it holds the whole hash of the file that the root service checked: 64 hexadecimal digits. For each program of the system, it is empty.

The window of the monitor shows the first 16 digits under the nickname. The console and the host now read all 64 digits from the same source: `columns(where(programs(), "name", "visitor"), "name hash")`. A reader can compare that hash with the hash of a file, or join the table with the modules that run.
