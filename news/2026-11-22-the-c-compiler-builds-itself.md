title: The C compiler builds itself to the same bytes
date: 2026-11-22
release: next
picture: none
kind: Measured
guide: docs/TOOLS.md

`chibicc`, the C compiler of modus, now compiles its own 14 C sources, and the assembler of modus makes one module of their texts.

`modustool c-self-host` builds `chibicc` with clang, which compiles the sources into stage 1. Stage 1 compiles the same sources again into stage 2. Stage 1 gives the same text as the build of clang for each source, and the two modules have one BLAKE3 hash: 354 972 bytes, on the host, in one run.

The assembler takes a program of several sources as one text: each source is a unit, and `global` joins the units.
