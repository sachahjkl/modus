title: Text is UTF-8 in every contract
date: 2026-11-15
release: next
picture: none
kind: Decided
guide: docs/glossary/text.md

Each text that two programs share is now UTF-8: an entry of the palette, a result, a record of the terminal, a line of the log, the name of an object of a store. Before, each of these contracts took the bytes 32 to 126 only.

One rule checks each text at its border. It refuses an overlong form, a surrogate, a code point above U+10FFFF, a broken sequence and a control character. The kernel applies it to each line of the log, so no program can write an escape sequence to the serial port.

In the console, `"caf" + character(233)` gives café, and `length(character(233))` gives 2. The fonts have no glyph for é yet: the terminal draws a box in its cell, one cell for one character, never a raw byte.

The names of modules, exports, settings and programs stay ASCII: each keyboard types them, and each has one form only.
