title: Greek letters drawn by a font service
date: 2026-11-16
release: next
picture: docs/screenshots/interface_font.png
kind: Shown
guide: docs/FONTS.md

The window `interface_font` shows two lines of Greek letters in B612. The glyph caches of the boot image do not hold them: they hold 192 characters for each font.

A new program, the font service `glyphs`, holds the outlines of the 47 Greek letters of B612: the font has no capital pi and no small rho. At its start it draws each of them into one demand cache that each window maps read-only. So the cache is the same whatever the windows draw, and tells no window what another one draws. A window that starts before that work ends draws the letter itself, with the same pixels.

A glyph drawn by the service has the same pixels as a glyph that the build draws from the same font file. A host test compares them word for word.
