title: The kernel operations run from operation sequences
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system with a small kernel: a program asks for each of its 35 kernel operations with a command record.

A test machine now runs operation sequences: lists of commands that the tool writes into the memory of the machine. A new program with a new budget runs each sequence on the kernel that ships, and the tool checks each answer. A refusal must have a status that the reference of its operation lists, an error detail for each argument that the form of the operation refuses, and no change of the budget. After the program stops, its budget must hold what it held before.

The test part `operation_sequences` runs a sequence for each operation and a few cases that must succeed. `modustool fuzz replay operations <file>` runs one sequence. This machine is the first part of the fuzzing of the kernel operations.
