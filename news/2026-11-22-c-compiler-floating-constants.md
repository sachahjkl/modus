title: The C compiler reads floating constants
date: 2026-11-22
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

`compile` now takes floating constants in C: `3.141592653589793`, `.5`, `2.5E+10`, `1e-6`, the hexadecimal `0x1.8p+1`, and `1.5f` for a `float`.

The `strtold` of the thin libc gives each constant the nearest `double`, with integer arithmetic only. A host test compares its bits, its end and its `errno` with the `strtod` of glibc for 1 874 412 texts, with no difference.

`compile` and `assemble` also take a source of up to 256 KiB, in place of 64 KiB.
