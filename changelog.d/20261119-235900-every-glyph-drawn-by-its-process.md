type: Changed

**Every glyph drawn by its process.** The boot image no longer holds the five glyph caches of Paper Mono and B612, more than 1.3 MB, nor their five fixed ranges: each process draws each glyph of its text from the font outlines into its private glyph cache, the setting `grid_fit` chooses a face of the cells, and each stated budget of a process that draws text holds 354 pages of glyph memory for each copy that draws. A text of the interface font at the scales 2 and 3 now stands at the nearest third of a pixel, not at a whole pixel.
