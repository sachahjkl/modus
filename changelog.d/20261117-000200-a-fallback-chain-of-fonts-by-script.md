type: Added

**A fallback chain of fonts by script.** A character past the glyph cache takes the first font of the chain of its script that has it, drawn on the baseline and at the cap height of the first font: the cells of the terminal draw the Greek letters of B612 that Paper Mono lacks (`character(945)` shows α), and the interface draws the box-drawing characters of Paper Mono. At its start the font service writes what each chain draws: 47 of the 49 Greek letters (no font has Π and ρ) and none of the 96 Cyrillic letters.
