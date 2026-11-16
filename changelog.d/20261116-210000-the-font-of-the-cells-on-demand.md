type: Added

**The font of the cells on demand.** The font service also draws the 128 box-drawing characters, the 32 block elements and the five Greek letters of Paper Mono (Λ, Ω, λ, μ, π) at its start, in Paper Mono with and without the grid fit and in Paper Mono SemiBold, and the terminal draws them in its cells: `character(9472) + character(955)` in the console shows ─λ. Paper Mono has no other Greek letter, so a cell of α still draws the replacement glyph. The demand cache keeps the glyphs of each of these glyph caches apart, and grows from 1 150 976 to 4 395 008 bytes.
