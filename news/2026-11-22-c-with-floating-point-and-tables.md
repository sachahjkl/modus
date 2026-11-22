title: The C compiler takes float, double, atomics and tables of pointers
date: 2026-11-22
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

The assembler of modus now takes the scalar SSE2 instructions that `chibicc` writes for `float` and `double`, the atomic `xchg` and `lock cmpxchg`, and the numeric local labels `1:`, `1f` and `1b`. Each new form gives the bytes that `llvm-mc` gives for the same line.

A global table of functions or of strings is now a `quad` of each address. The module records a rebase there, and the loader adds the base of the load.

So `compile` and `assemble` turn C with `float`, `double`, `alloca`, the atomic builtins and calls through a table of functions into a module that runs. A floating constant such as `1.5` and `long double` are still refused, with their line and their column.
