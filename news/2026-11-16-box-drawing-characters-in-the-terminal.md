title: Box-drawing characters in the terminal
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/FONTS.md

The terminal draws the box-drawing characters, the block elements and the five Greek letters of Paper Mono in its cells. In the console, `character(9472) + character(955)` shows ─λ.

The glyph caches of the boot image hold 192 characters for each font, and these 165 are past them. The font service draws them at its start, beside each glyph cache of the cells: Paper Mono with the grid fit, Paper Mono with no grid fit, and Paper Mono SemiBold. Each glyph stays in its cell, as each glyph of a glyph cache of cells does.

Paper Mono has no other Greek letter.
