title: Every window draws the characters past its glyph cache
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/FONTS.md

Each window now draws a character past the 192 of its glyph cache itself: its labels, its titles, its menus and its cells. It reads the font files of the system, which the root service maps read-only in each window, and keeps the glyphs that it drew in its own memory. No other window reads that memory, so it tells no window what another draws.

A character takes the first font of the chain of its script that has it. In the console, `character(945)` shows α in a cell: Paper Mono has no α, so the terminal draws the α of B612, on the baseline of Paper Mono and inside its cell. Π, ρ and the Cyrillic letters are in no font of the system: they draw a box, and the log names them.

The first draw of a glyph costs 3 to 46 µs in each window, on an AMD Ryzen 7 5800X.
