# Glyphs past the glyph cache

What changed: the package `fallback_glyphs` became the support package `text_rendering`, with the rasterizer at any text size and a larger private glyph cache keyed by glyph index and text size ([text_rendering.md](text_rendering.md), "The cache" and "The rasterizer"). The names `fallback_glyphs` and "fallback face" below are the names of that design; the face is now `text_rendering.Face`. Layer 0 is as this file says. Layer 1, the demand cache and the font service, left the system: each process draws each glyph past the glyph caches itself ("Layer 1: removed").

## Purpose

The glyph caches of the boot image hold 192 characters: ASCII, the Latin-1 Supplement and the euro sign ([../data/text_encoding.md](../data/text_encoding.md)). Each character of a cache costs about 2.2 KB of drawn words in each cache, at each scale and each position. So each new character of each font makes the boot image larger.

A principal reads and writes words in more languages, and names things with more signs than these 192. This design lets each window draw a character past the glyph cache. The boot image carries the outline of the character (about 200 bytes), not its drawn words at every size. Each process draws such a glyph itself, from outlines that every process maps read-only, into a cache that only it reads.

The guide of the subject is [`docs/FONTS.md`](../../../docs/FONTS.md), "13. Glyphs past the glyph cache".

What changed: no glyph past the glyph caches is drawn by a service. The request ring, the budget of requests and the request handles of the root service left first; then the demand cache and the font service. Each process draws each such glyph into its private glyph cache.

## Constraints

- **A process never waits for another process in its frame.** A process cannot hold the compositor, and a service cannot hold a window ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)). A service that a debugger stops must not stop a window.
- **No shared state tells a process what another process draws.** A cache that each process reads and that fills at the requests of the processes is a channel between them: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17. The time at which a shared service answers is the same channel.
- **Memory is paid by the process that uses it**: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller". The glyphs that one process draws must not take memory that another process or a service pays.
- **No process writes a glyph that another process draws.**
- **The same font and the same renderer give the same pixels.** A glyph past the glyph cache has the bytes that the build would give it, so a picture does not depend on which layer drew a glyph, nor on the order of the draws.
- **The first frame needs no service.** The boot display is drawn before any service runs, and the compositor, the terminal and the console draw their first frame at once.
- **The measure and the draw of one frame agree.** A text is measured, then placed, then drawn. An advance that changes between the measure and the draw puts a text over another.
- **A count, an offset or a length from another party is copied, then checked** (subtle point 5 of [../README.md](../README.md)).
- **A font file is hostile input.** The outlines come from the boot image, whose hash the root service checks, and the parser of `vector_font` checks each read against the bytes of the file. A font that does not come from the boot image is not in this design.

## The chosen form

Two layers, and a chain of fonts. A shared layer between them, layer 1, was built and removed.

### Layer 0: the outlines, shared and read-only

The font outlines are one resource of the boot image, `font_outlines`, in the format of `src/library/modus/contract/font_outlines`: a header, one record for each font (its name, the BLAKE3 hash of its file, its place and its size), then the font files. The modus tool writes it from the subsets in `resources/fonts`: the files of the glyph caches, B612 Regular and Bold, Paper Mono and Paper Mono SemiBold, and Noto Sans, the font of the scripts that they lack. The root service checks its hash once, and maps it read-only at the fixed range `Font_Outlines` in each process that gets the glyph caches (each process with a surface, each terminal, the compositor, a process from a disk). The bytes never change, so they tell no process anything.

A process validates the header once (`font_outlines.validate`), as it validates a glyph cache: the root service maps the pages with the right Read only from the boot image, whose one handle has no right Write.

### Layer 1: removed

Layer 1 was a shared cache of fixed subsets: one memory object of 1 073 pages that the root service paid, which a process of the system drew at each start (the 47 Greek letters of B612 and the 165 characters past the glyph cache of Paper Mono and Paper Mono SemiBold, for four faces), then ended. Each process mapped it read-only, and copied and checked each entry before it drew a word of it. It held the same entries whatever the processes drew, so it kept property 20.

It saved work only, and it left with the step that draws every glyph at any size ([text_rendering.md](text_rendering.md), "The glyph caches of the boot image and the demand cache: removed"): it held the three sizes of the glyph caches only, so at another size it held nothing that a window draws, and its cost (the shared pages, one more process at each start, a contract that a reader must check at each entry) bought nothing there. Each process now draws these characters into its private glyph cache: a terminal that shows the 160 box-drawing characters draws them once, about 0.5 ms at a line of 16 pixels (3.3 µs each).

### Layer 2: the private glyph cache

The package `fallback_glyphs` is compiled into each process that draws text, and into the drawing module. It holds, one copy for each copy of the package:

- the opened outlines: each font of the resource, parsed once, with its measures;
- the private glyph cache: 65 536 words of coverage (256 KiB) and 1 024 entries;
- the render memory of `vector_font`.

An entry is keyed by the fallback face, the scale, the position and the code point. It holds one glyph in the form of a glyph cache (`text_rendering.Glyph_Entry` today) and the place of its words. The words are held in blocks of 32 to 4 096 words that split and join by halves (a buddy allocator), so a glyph takes one run of words and the draw reads it as a glyph of a glyph cache.

A process evicts by the order of last use, counted in frames. Each frame of the process (`fallback_glyphs.frame_begin`) gets a new number. A glyph used in a frame moves to the newest end of the order once in that frame. A new glyph that finds no room evicts the oldest glyphs until a block of its size is free. The eviction is inside the process, so it sees only the glyphs of that process.

The cache holds no advance. The advance of a character past the glyph cache is a function of its font file: `fallback_glyphs.advance` reads it from the outlines at each measure. So the measure needs no drawn glyph, and the measure and the draw of a frame always agree. A glyph that the draw does not find is drawn at once, and the frame never waits.

### The fallback face

A fallback face is the glyph cache that a glyph past it stands beside: B612 Regular (`Interface`), B612 Bold (`Interface_Bold`), Paper Mono with the grid fit (`Cells`) and without it (`Cells_Without_Grid_Fit`), and Paper Mono SemiBold (`Cells_Bold`). A process finds the face of a glyph cache by the hash of its font file and its flags (`fallback_glyphs.face_of_cache`). So each draw of `graphics` finds its face with no new argument, a spacing names its face and its text size ([text_rendering.md](text_rendering.md)), and every window draws characters past the glyph cache: the labels, the titles and the menus of the interface package, the cells of the terminal and the window of each process.

### The fallback chain by script

The fallback chain is data: `fallback_glyphs.scripts`, one row for each script, with the fonts of each fallback face in order. A character takes the first font of the chain of its script and face that has its glyph. A character of no row takes the default chain of its face.

| Script | Interface | Interface_Bold | Cells | Cells_Bold |
|---|---|---|---|---|
| Greek | B612, Paper Mono, Noto Sans | B612 Bold, B612, Paper Mono SemiBold, Noto Sans | Paper Mono, B612, Noto Sans | Paper Mono SemiBold, B612 Bold, B612, Noto Sans |
| Cyrillic | Noto Sans | Noto Sans | Noto Sans | Noto Sans |
| Box drawing and block elements | Paper Mono | Paper Mono SemiBold | Paper Mono | Paper Mono SemiBold |
| Each other character, Latin Extended-A too | B612, Paper Mono, Noto Sans | B612 Bold, Paper Mono SemiBold, Noto Sans | Paper Mono, B612, Noto Sans | Paper Mono SemiBold, B612, Noto Sans |

The face `Cells_Without_Grid_Fit` takes the chain of `Cells`. A new font is one record of the resource, one member of `fallback_glyphs.Outline_Font`, and its place in the rows.

### The font of the missing scripts

B612 has no Π (U+03A0), no ρ (U+03C1), no Cyrillic letter and no letter of Latin Extended-A, and Paper Mono has five Greek letters only. A principal who writes Greek, Russian or a language of Central Europe needs them in every window and in the cells. Noto Sans closes each chain: the subset "Noto Sans LGC" holds the 192 characters, which give its measures, then Latin Extended-A (U+0100 to U+017F), the 49 Greek letters and the 96 basic Cyrillic letters (U+0400 to U+045F), each a simple glyph (`font_outlines.script_fallback_past_cache_ranges`). So every chain of every face draws the 49 Greek letters, the 96 Cyrillic letters and the 128 letters of Latin Extended-A. The compositor writes, at its start, one line for each script with the count that each chain draws, so the log names what is missing once at each boot (`display.script_coverage_tell`); a later chain with a gap shows there.

- **The last font of each chain, never the first.** A letter that B612 or Paper Mono has keeps its glyph: the Greek letters of B612, and the pixels that their golden hashes hold, do not change. The Cyrillic chains name Noto Sans alone, as no font of the faces has a Cyrillic letter.
- **One weight.** Noto Sans Bold would cost another 87 KB of the boot image for the titles and the bold cells only. A bold Cyrillic letter draws in the regular weight, in the frame of the bold face.
- **The 192 characters in the subset too.** The open of a font reads the outlines of the characters 33 to 126 for its measures (`vector_font.font_measures`), and the tool writes each subset in one layout. They cost about 30 KB.
- **Its cost in a call of the library module.** A call opens the fonts of the chains of its face (`fonts_of_face`): Noto Sans is in each chain, so each call reads the outlines of its 94 characters for its measures, as it does for each other font of the chain.

Refused:

- **A subset of the missing letters alone, made by hand with another tool.** It has no outline of the characters 33 to 126, so the open refuses it for its measures; and a subset that the modus tool does not write has no record of its source and no check of its license.
- **A Cyrillic or Greek row in the cells with a monospace font.** No monospace candidate of the system has Cyrillic. In the frame of the first font, cut to its cell, a letter of Noto Sans stands beside Paper Mono, as a Greek letter of B612 does.
- **Noto Sans in place of B612.** The interface font keeps its form; Noto Sans only fills the gaps.

### A fallback font in the frame of the first font

A glyph of a fallback font stands on the baseline of the first font of its face, and its capitals are as high as the capitals of the first font. The style of the glyph (the size of its cell, its baseline and its grid fit) is the style of the first font. Its outlines are scaled so that its cap height equals the cap height of the first font (`fallback_glyphs` sets the units of one cell of the fallback font from the two cap heights). A glyph of a face of cells is drawn as the build draws a cache of cells: the ink cut to the cell, the advance the width of the cell. So a Greek letter of B612 in a cell of the terminal stays in its cell and stands on the baseline of Paper Mono.

### Characters of two columns

A terminal gives each character the cells of its East Asian Width (Unicode Standard Annex 11). `text_rendering.cell_width_of` gives a closed enum, `Cell_Width`: `Two` for a wide or fullwidth character (the CJK ideographs and their extension A and compatibility forms, Hiragana and Katakana, the syllables of Hangul, the fullwidth forms), `Zero` for a combining mark, a joiner or a variation selector, `One` for each other character. It is a table of ranges in order, searched by halves: no table of the annex is copied whole, and a character out of the table takes one cell, as an ambiguous character does in a terminal of the West.

The terminal lays out each row of its view with `internal:terminal/wide_cells`. A wide character takes the cell of its column as its lead and the next cell as its trail. A write over either half clears the other half, so no half of a glyph stays alone. The edit line flows over the rows under it: a wide character that finds one column left starts the next row, and that column stays empty. A line of the text does not wrap: a wide character that does not fit ends the row with the continuation mark, which clears the half that it covers. The drawer gets the 16-byte cells of the text grid as before: the lead holds the character, the trail is a blank cell of the same style. The cursor of the edit line, the anchor of the completion list and the hint line count the cells the same way. The console cuts a long line of output into rows by the same widths (`text_rendering.cell_part`), so a wide character never crosses the right edge.

Until a font with the ideographs is in a chain, a wide character draws the replacement glyph in its lead cell: the columns of a line are already the columns of the text, and the font changes the glyph only.

### The order of the lookup

For a character that no glyph cache holds:

1. The font is the first font of its chain that has its glyph. No font: the replacement glyph, with the advance of `0`.
2. The advance is the advance of that font, scaled to the face.
3. The words: the words of the private glyph cache, drawn there at the first use.

## The measures

Host: AMD Ryzen 7 5800X, one core (`taskset`), `-o:speed`, each time the least of 200 batches (host test `private_glyph_measure`). The words are the box of the ink, as the cache keeps it; an entry adds 48 bytes.

| Glyphs | Scale 1 | Scale 2 | Scale 3 | Words at scale 1, mean and most |
|---|---|---|---|---|
| Latin of B612, placed | 16.2 µs | 32.4 µs | 40.2 µs | 83, 182 |
| Greek of B612, placed | 16.5 µs | 31.8 µs | 46.3 µs | 97, 135 |
| Latin of Paper Mono, in cells | 4.1 µs | 10.3 µs | 21.1 µs | 74, 104 |
| Box drawing of Paper Mono, in cells | 3.3 µs | 9.7 µs | 19.7 µs | 90, 128 |
| 500 ideographs of WenQuanYi Micro Hei, placed | 18.0 µs | 29.5 µs | 43.1 µs | 198, 224 |

| A working set of | 300 glyphs | 3 000 glyphs | 10 000 glyphs |
|---|---|---|---|
| Latin of B612, scale 1 | 112 KiB | 1 117 KiB | 3 723 KiB |
| Ideographs, scale 1 | 247 KiB | 2 466 KiB | 8 222 KiB |
| Ideographs, scale 3 | 1 743 KiB | 17 430 KiB | 58 101 KiB |

The decisions that they made:

- **A glyph drawn once in each process costs 3 to 46 µs, once.** A window that shows 30 new characters at scale 1 pays under 0.6 ms in the frame of their first use.
- **256 KiB of words hold the working set of 300 glyphs at scale 1**, of Latin, Greek or ideographs, which is the text of a few windows. A working set larger than the cache costs time (glyphs drawn again after an eviction), never a wrong glyph.
- **The placed glyph costs four times the cell glyph** because `glyph_render_placed` clears and filters a work row of 64 pixels whatever the width of the glyph. A work row sized to the advance of the glyph is the next gain, if a measure of a frame asks for it.
- The ideographs of WenQuanYi Micro Hei have 43 points on the mean and 112 at most. The CJK fonts of the host with more points have CFF outlines, which `vector_font` does not read.

## The forms that were refused

- **A shared cache filled at the requests of the processes.** Each process would read in the cache which characters the others asked for, in their order and at their time, across principals: the channel of row 17. The eviction of such a cache is a second channel: a process would see its glyphs go when another draws.
- **A private area for each process inside the font service.** The service would pay with its memory for the glyphs of each process, against property 14, and a process would still ask and wait for an answer: the request ring, its budget and a handle of each process in the root service. The time of an answer would still depend on the work of the service for the others: the channel of row 17, narrowed but open.
- **A cache for each session of a principal.** It closes the channel between principals only: two processes of one principal still read what the other draws, and a process of a principal can be hostile to another process of the same principal. It needs a session object that the root service creates and a font service for each session, and its memory is paid by no process that draws.
- **The request ring and the budget of requests.** They were the transport of a shared cache that fills on demand. With each process that draws its own glyphs, nothing is asked.
- **Every glyph drawn at run time, no glyph cache at build time.** The boot display is drawn before any service runs, and the 192 characters of each text of the system are drawn at each frame of each process: a glyph cache costs 109 ns for a glyph, a glyph from its outline 4 to 46 µs.
- **Layer 1 kept: the fixed subsets in a shared cache, drawn by a service at each start.** It was built, and left: see "Layer 1: removed". It served the three sizes of the glyph caches only.
- **A wait for the glyph in the frame.** A process would be held by another process.
- **The advance in the private glyph cache.** The measure would depend on the content of the cache: a glyph evicted between the measure and the draw, or a cache full for the measure, would change an advance. The advance of a font file is a pure function.
- **An invalidation of the private glyph cache at a change of the settings.** The key holds the scale and the grid fit, so a glyph of another size or another grid fit is another entry, and the old ones leave by the order of use. The words hold the three stripes in the order red, green, blue, and the blend swaps them for a screen with blue first: a change of the order of the stripes reads the same words. A clear of the cache would only draw the same glyphs again when a setting comes back.
- **The cache in the memory of each process, given by the process.** Each process with a window would declare the same memory; a process that draws no glyph past the glyph cache reserves pages and touches none, so the kernel gives it no frame (`docs/ARCHITECTURE.md`, a page gets its frame at its first use). One size in the package is one place to change.
- **Fixed slots of the largest glyph.** A slot for a proportional glyph at scale 3 holds 3 072 words; the mean glyph at scale 1 is 83. Blocks that split by halves waste at most half a block.
- **A ring of words that evicts in the order of the writes.** A glyph that each frame uses (a letter of a title) would leave when the ring turns, and be drawn again.
- **The Greek letters of B612 drawn in the frame of B612 in the cells.** Its baseline is not the baseline of Paper Mono, and its glyphs pass the cell. In the frame of the first font, cut to the cell, they stand beside Paper Mono.
- **A wide glyph in a cell of the text grid of two cells.** A field of the cell that says "lead" or "trail" changes the format of 16 bytes that crosses the border of the drawing module ([../api/text_grid.md](../api/text_grid.md)). The terminal keeps the two halves in its own rows, and the grid stays the same.
- **The whole table of the East Asian Width.** It holds about 1 000 ranges for characters that a terminal of the system does not meet yet. The ranges of the scripts that a principal writes come first; a range joins the table with its test of its edges.
- **A width from the advance of the glyph.** The advance depends on the font of the chain that has the glyph: the columns of a line would change with a setting. The width is a fact of the character.
- **A glyph of Paper Mono beside Spleen 8x16.** A glyph of Paper Mono beside the glyphs of Spleen has another form and another weight. With the setting `font` at `spleen`, a cell past the glyph cache draws the replacement glyph.
- **The code point as the index of a table.** The code points are 1 114 112 places; the characters that a process uses are a few hundred. A hash table keeps the table small.

## Subtle points

- **The drawing module is shared code; its cache is not shared.** The module is one file in the boot image, but the loader gives each process its own copy of its data. So a process that draws through the module has two private glyph caches: the one of the module (the draw of its frames) and the one of the process (the text that it draws itself, as the process `interface_font` does). Both are paid by the budget of that process. Both read the same outlines, so the measure in the process and the draw in the module give the same advances.
- **The memory of a copy.** A copy carries about 25 KiB of globals: the memory of one outline and a band of one row. The glyph memory, about 1.4 MiB (the private glyph cache and the render memory), is no global: a process reserves it from its budget at the frame after its first glyph past the glyph caches, so a copy that never draws one pays nothing for it. The figures and the rule: [text_rendering.md](text_rendering.md), "The cache", and [`docs/FONTS.md`](../../../docs/FONTS.md), "14.4 The private glyph cache".
- **One thread of a process draws at a time.** The draw changes the private glyph cache, as it changes the blend tables: the rule of the drawing module. The measure only reads the outlines, so another thread can measure.
- **The compositor** draws its bar and its palette through the drawing module and its own code: it gets the outlines as each process does, and pays for its glyphs. A process never draws in the compositor.
- **The terminal** draws its cells through the drawing module, which draws each box-drawing cell in its private glyph cache at its first use. It waits for nothing.
- **A frame number that never moves.** A process that never calls `frame_begin` has one frame for its whole life, and a glyph of the frame in progress is never evicted ([text_rendering.md](text_rendering.md), "The cache"). Once its cache is full, each new glyph is drawn and not kept: right pixels, more time, never a wrong glyph. Such a process also never reserves its glyph memory, since the reservation is at a frame start: it draws each glyph past the glyph caches band by band.
- **The key holds the face, the scale and the position.** A change of the grid fit, of the scale or of the order of the stripes needs no clear: see the refused invalidation above.
- **A glyph drawn in each process.** The same glyph is drawn once in each process that shows it: 3 to 46 µs each time, and 300 to 6 000 bytes of words in each. It is the price of no shared state.
- **The hash of the font file names the face.** A glyph cache and a record of the outlines with one hash are the same font file. A process uses a fallback face only beside the glyph cache of its first font.
- **The pairs of a character past the glyph cache are 0.** The pair table of a glyph cache is keyed by character indexes.
- **The library module `text_rendering` has the fallback chains.** Its exports take the font outlines of the caller and open them for one call: a character past the glyph cache that a font of the chain has is placed there as in a process.

## The order of the steps

Each step leaves a working system.

1. Layer 0, layer 2 and the removal of the requests: the resource of the outlines and its range; the package `fallback_glyphs` with the private glyph cache and the fallback faces; the shaper and the draw read it; the font service reads the outlines from the resource, draws layer 1 and ends; the request ring, the budget of requests and the request handles of the root service are removed. Each window draws the Greek letters of B612 and the cells draw the cell subset of Paper Mono.
2. The fallback chain by script, as data, and the frame of the first font: the cells draw the Greek letters of B612, the interface draws the box-drawing characters of Paper Mono, and the font service names what each chain lacks.
3. Layer 1 and the font service removed: each process draws every glyph past the glyph caches; the compositor names what each chain lacks.
4. The font of the missing scripts: Noto Sans closes each chain, and the chains draw every Greek letter, the basic Cyrillic letters and Latin Extended-A.
5. The cells of two columns: the table of the East Asian Width, the lead and the trail of a wide character in the rows of the terminal, and the cut of the output lines of the console by cells.
6. Later: a TrueType CJK font in the chains; the shaping of complex scripts in the process.

## State

Built: the resource `font_outlines` and its fixed range; the package `fallback_glyphs`, now `text_rendering`, with the private glyph cache (its form of today: [text_rendering.md](text_rendering.md), "The cache"), the fallback faces, the chains by script and the frame of the first font; the shaper and the draws of `graphics` with it, in each process and in the drawing module; the root service, which maps the outlines with the settings page; the compositor, which names what each chain lacks; the font of the missing scripts, Noto Sans; the terminal and the process `interface_font` with their machine test lines; the host tests of the cache and of the measure; the cells of two columns, with host tests of the table at the edges of each range and of the rows of the terminal (the right edge, a write over each half, Backspace, the lines of the scrollback). Layer 1 and the font service are removed.

Left (`ROADMAP.md`): a CJK font; the shaping of complex scripts. A name of the completion list with a wide character takes one cell for each character, and a combining mark is not drawn: it takes no cell, and the cell model holds one character for each cell.

Built after it: the text rendering module draws each glyph at any size into the private glyph cache, which holds every glyph; the glyph caches of the boot image left ([text_rendering.md](text_rendering.md), "The glyph caches of the boot image and the demand cache: removed").
