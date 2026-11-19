title: Each glyph past the glyph caches comes from the process that draws it
date: 2026-11-19
release: next
picture: none
kind: Decided
guide: docs/FONTS.md

modus is an operating system with a small kernel, in which each program draws its window into memory of its own, and the compositor shows it.

The font service is gone. It was a process of the system that drew the Greek letters and the box-drawing characters into a shared cache at each start, then stopped. Each start of the machine now has one process fewer, and the root service no longer pays 1 073 pages for that cache.

Each window draws these characters itself, into its own private glyph cache, with the same pixels. The log of the compositor names, once at each start, the characters of each script that no font of the system has. The terminal writes one line for each font of its fallback chain from which it drew a cell.
