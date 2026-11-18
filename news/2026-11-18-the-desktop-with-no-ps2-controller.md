title: The desktop starts on a machine with no PS/2 controller
date: 2026-11-18
release: next
picture: none
kind: Fixed
guide: docs/ARCHITECTURE.md

modus is an operating system with a small kernel, in which the code of each device runs as a process.

On a machine with no PS/2 controller, the input service used to read the status port for ever on one processor. Now it reads a status of all ones as no controller, writes one line and stops, and the desktop comes up with no keyboard and no mouse.
