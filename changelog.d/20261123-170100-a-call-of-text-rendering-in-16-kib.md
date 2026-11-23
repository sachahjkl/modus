type: Changed

**A call of the library module text_rendering uses at most 16 KiB of stack**: a caller on a worker thread of 64 KiB keeps three quarters of it. The reader of CFF reads each font dictionary when it draws a glyph, the measure of a font reads its outlines with at most 256 points, and a font with CFF outlines in the place of a font of the boot image is refused, in a process and in a call alike. A host test measures the stack of each export.
