title: The kernel operations are fuzzed on the kernel that ships
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/TOOLS.md

modus is an operating system with a small kernel: a program asks for each of its 35 kernel operations with a command record.

`modustool fuzz operations <executions>` now writes generated operation sequences into a test machine of the kernel that ships, and checks each answer. A stop of the machine, a sequence that does not end, or an answer that breaks an oracle is a fault of the kernel. The tool keeps each fault one time, minimizes it on new machines to the fewest sequences and steps that still give it, and boots a new machine to go on.
