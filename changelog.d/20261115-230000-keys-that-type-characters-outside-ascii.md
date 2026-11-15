type: Added

**Keys that type characters outside ASCII.** A key record carries a code point: the layout of France gives é, è, ç, à and ù from their keys, and â, ê, î, ô, û, ë, ï, ü and ÿ from the dead keys `^` and `¨`. The line of the console, its history file, the search of the palette and a passphrase are UTF-8, and each key moves over or removes a whole character. Each glyph cache and Spleen draw the Latin-1 Supplement U+00A0 to U+00FF: the glyph cache is version 3, keyed by a character index of 191 characters, and the module `text_shaping` takes 191 advances.
