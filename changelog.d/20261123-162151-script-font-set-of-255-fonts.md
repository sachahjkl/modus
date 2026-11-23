type: Changed

**A script font set of up to 255 fonts**: a reader takes the count of fonts from the header of the set, and the cache of glyphs and each direct glyph name a font in 9 bits, so a new script adds its font to the set with no change of the readers. A set with more fonts than the room of its reader is refused with the sentence `their count of fonts is past the room of the reader`.
