title: A program from a disk shows which file runs under its name
date: 2026-11-15
release: next
picture: docs/screenshots/disk_program_windows.png
kind: Shown
guide: docs/MODULE_CONTRACT.md

A program from a disk runs under a nickname that the principal chose. The menu of the windows, the palette and the monitor now show that nickname with the first 16 digits of the hash of the file faded beside it, so a reader sees which file runs under the name. A nickname that only looks like the name of a program of the system, such as consoIe, has its digits beside it too.

Both come from the root service, which checked the bytes before the start. The program does not choose them: a program that asks for the title console still gets a window with its own nickname. The title bar of the window shows the nickname without the digits.

The monitor finds each program from a disk on a page that the root service writes, by the place of the program in the kernel. A program from a disk cannot start a child, so no child of it can take the name of another program in the monitor.
