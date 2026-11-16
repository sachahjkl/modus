title: Greek letters drawn by a font service
date: 2026-11-16
release: next
picture: docs/screenshots/interface_font.png
kind: Shown
guide: docs/FONTS.md

The window `interface_font` shows two lines of Greek letters in B612. The glyph caches of the boot image do not hold them: they hold 192 characters for each font.

A new program, the font service `glyphs`, holds the outlines of the 48 Greek letters of B612. At its start it draws each of them into one demand cache that each window maps read-only. So the cache is the same whatever the windows draw, and tells no window what another one draws. A window that starts before that work ends draws a box for a letter that it does not find, asks the service, and draws the letter after the answer.

A glyph drawn by the service has the same pixels as a glyph that the build draws from the same font file. A host test compares them word for word.
