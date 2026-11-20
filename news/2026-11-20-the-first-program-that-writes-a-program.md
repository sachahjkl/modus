title: The first program that writes a program in modus
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

modus is an operating system with a small kernel, in which each program is a module named by the hash of its file.

Until now the build tool wrote each module file on another machine. The module `assemble` now writes one in modus. It reads x86-64 assembly, in the syntax that C compilers emit, and a line `export add(a: Integer, b: Integer) -> Integer` that gives the types of an export. A text that it does not take whole is refused, with its line and its column.

In the console, `assemble("…", f)` writes the file into a memory object, and `isolate_memory("adder", f, n)` runs that module in a sandboxed process with no handle of the console. `add(2, 3)` then gives 5.

The assembler is the first native stage of the bootstrap: the stage after it, a C compiler, emits the assembly that it reads.
