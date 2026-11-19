title: Every glyph is drawn by the process that shows it
date: 2026-11-19
release: next
picture: none
kind: Decided
guide: docs/FONTS.md

modus is an operating system with a small kernel, in which each program draws its window into memory of its own, and the compositor shows it.

The boot image no longer holds glyphs drawn at build time. It held five glyph caches of its two fonts, more than 1.3 MB, at three sizes of text only. Now it holds the font files, about 195 KB, and each window draws each glyph of its text from them once, into its own private glyph cache, with the same pixels. The root service no longer checks the hash of five caches at each start.

A text of the interface font at twice and three times its size now stands at the nearest third of a pixel, as at its first size. Each program that draws text states the pages of its glyphs in its budget: 354 pages for each copy of the text rendering that draws.
