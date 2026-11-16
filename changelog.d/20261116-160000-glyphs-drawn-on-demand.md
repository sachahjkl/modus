type: Added

**Glyphs drawn on demand**: the new font service `glyphs` draws characters past the 192 of the glyph caches into a demand cache that each program maps read-only. It draws its whole subset, the 47 Greek letters of B612, at its start, so the cache tells no program what another draws. A program asks through its own request ring for a character that the cache does not hold yet, never waits, and draws the replacement glyph until the answer. The program `interface_font` shows the Greek letters.
