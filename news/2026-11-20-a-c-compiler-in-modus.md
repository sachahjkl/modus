title: A C compiler in modus
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

modus is an operating system with a small kernel, in which each program is a module named by the hash of its file.

The module `c_compiler` is `chibicc`, a C11 compiler of about 9 000 lines, ported. It runs in a sandboxed process of the console, reads no file and no clock, and writes its assembly into a memory object. Each C function that is not `static` becomes an export, with its types.

In the console, `compile("int add(int a, int b) { return a + b; }", t)` writes the text, `assemble` turns it into a module file, `isolate_memory` runs that module, and `add(2, 3)` gives 5.

The source of `chibicc` is not in the repository: the build fetches it at one commit and applies four small patches. The assembler takes only a part of what `chibicc` emits today: each other instruction is refused with its line and its column.
