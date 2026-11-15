title: An export states the unit of a number
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/MODULE_CONTRACT.md

An export of a module now says what its number counts. Type `load("cryptography")` in the console, then `>hkdf_sha256_expand` and Enter in the palette: the field of the length shows `bytes` after the number, as the field of `buffer` shows `pages`. The exports `debugger.memory`, `debugger.watch`, `debugger.wait_stop` and `storage.set_size` state their units too.

The unit is in the description of the export, so the palette needs no code for one program. The unit is also part of the meaning of the export. A replacement whose export takes bytes where the import took pages fails the check of the loader, and the sentence names both units. A program that declares the import with another unit does not build.
