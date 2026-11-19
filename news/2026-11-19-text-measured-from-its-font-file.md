title: Each text is measured from its font file, at any size
date: 2026-11-19
release: next
picture: none
kind: Decided
guide: docs/FONTS.md

modus is an operating system with a small kernel, in which each program draws its window into memory of its own, and the compositor shows it.

The width of a text no longer comes from tables that the build wrote for three sizes. Each program reads the advance of each character and the adjustment of each pair from the font file, at the size that its layout asks for. At the three sizes of today the numbers are the same, so no text on the screen moves.

A program that does not compile the text code in calls the library module `text_rendering` with the font files as bytes, a face and a size. It places the glyphs of a text, measures many texts in one call, and breaks a text into the lines of a box.
