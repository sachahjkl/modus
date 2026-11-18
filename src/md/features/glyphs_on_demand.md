# Glyphs past the glyph cache

## Purpose

The glyph caches of the boot image hold 192 characters: ASCII, the Latin-1 Supplement and the euro sign ([../data/text_encoding.md](../data/text_encoding.md)). Each character of a cache costs about 2.2 KB of drawn words in each cache, at each scale and each position. So each new character of each font makes the boot image larger.

A principal reads and writes words in more languages, and names things with more signs than these 192. This design lets each window draw a character past the glyph cache. The boot image carries the outline of the character (about 200 bytes), not its drawn words at every size. Each process draws such a glyph itself, from outlines that every process maps read-only, into a cache that only it reads.

The guide of the subject is [`docs/FONTS.md`](../../../docs/FONTS.md), "13. Glyphs past the glyph cache".

What changed: the glyphs past the subsets are no longer drawn by the font service at the request of a process. The request ring, the budget of requests and the request handles of the root service are removed. Each process draws them into its private glyph cache.

## Constraints

- **A process never waits for another process in its frame.** A process cannot hold the compositor, and a service cannot hold a window ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)). A font service that is stopped by a debugger must not stop a window.
- **No shared state tells a process what another process draws.** A cache that each process reads and that fills at the requests of the processes is a channel between them: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17. The time at which a shared service answers is the same channel.
- **Memory is paid by the process that uses it**: [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller". The glyphs that one process draws must not take memory that another process or a service pays.
- **No process writes a glyph that another process draws.**
- **The same font and the same renderer give the same pixels.** A glyph past the glyph cache has the bytes that the build would give it, so a picture does not depend on which layer drew a glyph, nor on the order of the draws.
- **The first frame needs no service.** The boot display is drawn before any service runs, and the compositor, the terminal and the console draw their first frame at once.
- **The measure and the draw of one frame agree.** A text is measured, then placed, then drawn. An advance that changes between the measure and the draw puts a text over another.
- **A count, an offset or a length from another party is copied, then checked** (subtle point 5 of [../README.md](../README.md)). The demand cache changes while a process reads it.
- **A font file is hostile input.** The outlines come from the boot image, whose hash the root service checks, and the parser of `vector_font` checks each read against the bytes of the file. A font that does not come from the boot image is not in this design.

## The chosen form

Three layers, and a chain of fonts.

### Layer 0: the outlines, shared and read-only

The font outlines are one resource of the boot image, `font_outlines`, in the format of `src/library/contract/font_outlines`: a header, one record for each font (its name, the BLAKE3 hash of its file, its place and its size), then the font files. The modus tool writes it from the subsets in `resources/fonts`: the files of the glyph caches, B612 Regular and Bold, Paper Mono and Paper Mono SemiBold. The root service checks its hash once, and maps it read-only at the fixed range `Font_Outlines` in each process that gets the glyph caches (each process with a surface, each terminal, the compositor, a process from a disk) and in the font service. The bytes never change, so they tell no process anything.

A process validates the header once (`font_outlines.validate`), as it validates a glyph cache: the root service maps the pages with the right Read only from the boot image, whose one handle has no right Write.

### Layer 1: the fixed subsets, shared and read-only

The demand cache stays: one memory object that the root service creates. The font service (the process `glyphs`) draws each character of the subset of each demand face into it at its start, in a fixed order, then ends with the code 0. The subsets are the characters of the primary font of a face past its glyph cache: the 47 Greek letters of B612, and the 165 characters of the cell subset of Paper Mono and Paper Mono SemiBold. So the entries are the same whatever the processes draw.

The root service maps the demand cache read-only in each process that gets the glyph caches. It keeps one handle for it, and no handle for each process. A process reads the cache with the reader of `demand_cache`: it copies each entry and checks it against the constants of the contract.

Layer 1 saves work only. A process whose frame comes before the end of the font service draws the same glyph in layer 2, with the same bytes.

### Layer 2: the private glyph cache

The package `fallback_glyphs` is compiled into each process that draws text, and into the drawing module. It holds, one copy for each copy of the package:

- the opened outlines: each font of the resource, parsed once, with its measures;
- the private glyph cache: 65 536 words of coverage (256 KiB) and 1 024 entries;
- the render memory of `vector_font`.

An entry is keyed by the fallback face, the scale, the position and the code point. It holds one glyph in the form of a glyph cache (`glyph_cache.Glyph_Entry`) and the place of its words. The words are held in blocks of 32 to 4 096 words that split and join by halves (a buddy allocator), so a glyph takes one run of words and the draw reads it as a glyph of a glyph cache.

A process evicts by the order of last use, counted in frames. Each frame of the process (`fallback_glyphs.frame_begin`) gets a new number. A glyph used in a frame moves to the newest end of the order once in that frame. A new glyph that finds no room evicts the oldest glyphs until a block of its size is free. The eviction is inside the process, so it sees only the glyphs of that process.

The cache holds no advance. The advance of a character past the glyph cache is a function of its font file: `fallback_glyphs.advance` reads it from the outlines at each measure. So the measure needs no drawn glyph, and the measure and the draw of a frame always agree. A glyph that the draw does not find is drawn at once, and the frame never waits.

### The fallback face

A fallback face is the glyph cache that a glyph past it stands beside: B612 Regular (`Interface`), B612 Bold (`Interface_Bold`), Paper Mono with the grid fit (`Cells`) and without it (`Cells_Without_Grid_Fit`), and Paper Mono SemiBold (`Cells_Bold`). A process finds the face of a glyph cache by the hash of its font file and its flags (`fallback_glyphs.face_of_cache`). So each spacing of `text_shaping` and each draw of `graphics` finds its face with no new argument, and every window draws characters past the glyph cache: the labels, the titles and the menus of the interface package, the cells of the terminal and the window of each process.

### The fallback chain by script

The fallback chain is data: `fallback_glyphs.scripts`, one row for each script, with the fonts of each fallback face in order. A character takes the first font of the chain of its script and face that has its glyph. A character of no row takes the default chain of its face.

| Script | Interface | Interface_Bold | Cells | Cells_Bold |
|---|---|---|---|---|
| Greek | B612, Paper Mono | B612 Bold, B612, Paper Mono SemiBold | Paper Mono, B612 | Paper Mono SemiBold, B612 Bold, B612 |
| Cyrillic | B612, Paper Mono | B612 Bold, B612, Paper Mono SemiBold | Paper Mono, B612 | Paper Mono SemiBold, B612 Bold, B612 |
| Box drawing and block elements | Paper Mono | Paper Mono SemiBold | Paper Mono | Paper Mono SemiBold |
| Each other character | B612, Paper Mono | B612 Bold, Paper Mono SemiBold | Paper Mono, B612 | Paper Mono SemiBold, B612 |

The face `Cells_Without_Grid_Fit` takes the chain of `Cells`. A new font is one record of the resource, one member of `fallback_glyphs.Outline_Font`, and its place in the rows.

No font of `resources/fonts` covers more than these: the other monospace candidates are subsets of the 192 characters. So the chains draw 47 of the 49 Greek letters (B612 has no Π, U+03A0, and no ρ, U+03C1) and no Cyrillic letter. The font service writes, at its start, one line for each script with the count that each chain draws, so the log names what is missing.

### A fallback font in the frame of the first font

A glyph of a fallback font stands on the baseline of the first font of its face, and its capitals are as high as the capitals of the first font. The style of the glyph (the size of its cell, its baseline and its grid fit) is the style of the first font. Its outlines are scaled so that its cap height equals the cap height of the first font (`fallback_glyphs` sets the units of one cell of the fallback font from the two cap heights). A glyph of a face of cells is drawn as the build draws a cache of cells: the ink cut to the cell, the advance the width of the cell. So a Greek letter of B612 in a cell of the terminal stays in its cell and stands on the baseline of Paper Mono.

### The order of the lookup

For a character that no glyph cache holds:

1. The font is the first font of its chain that has its glyph. No font: the replacement glyph, with the advance of `0`.
2. The advance is the advance of that font, scaled to the face.
3. The words: when the font is the first font of the face and the demand cache holds the character at the generation of the frame, the words of the demand cache; else the words of the private glyph cache, drawn there at the first use.

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

- **A glyph drawn once in each process costs 3 to 46 µs, once.** A window that shows 30 new characters at scale 1 pays under 0.6 ms in the frame of their first use. Layer 1 keeps the most frequent glyphs of the terminal (the box-drawing characters) out of that cost.
- **256 KiB of words hold the working set of 300 glyphs at scale 1**, of Latin, Greek or ideographs, which is the text of a few windows. A working set larger than the cache costs time (glyphs drawn again after an eviction), never a wrong glyph.
- **The placed glyph costs four times the cell glyph** because `glyph_render_placed` clears and filters a work row of 64 pixels whatever the width of the glyph. A work row sized to the advance of the glyph is the next gain, if a measure of a frame asks for it.
- The ideographs of WenQuanYi Micro Hei have 43 points on the mean and 112 at most. The CJK fonts of the host with more points have CFF outlines, which `vector_font` does not read.

## The forms that were refused

- **A demand cache filled at the requests of the processes, shared.** Each process would read in the cache which characters the others asked for, in their order and at their time, across principals: the channel of row 17. The eviction of such a cache is a second channel: a process would see its glyphs go when another draws.
- **A private area for each process inside the font service.** The service would pay with its memory for the glyphs of each process, against property 14, and a process would still ask and wait for an answer: the request ring, its budget and a handle of each process in the root service. The time of an answer would still depend on the work of the service for the others: the channel of row 17, narrowed but open.
- **A cache for each session of a principal.** It closes the channel between principals only: two processes of one principal still read what the other draws, and a process of a principal can be hostile to another process of the same principal. It needs a session object that the root service creates and a font service for each session, and its memory is paid by no process that draws.
- **The request ring and the budget of requests.** They were the transport of a shared cache that fills on demand. With each process that draws its own glyphs, nothing is asked.
- **Every glyph drawn at run time, no glyph cache at build time.** The boot display is drawn before any service runs, and the 192 characters of each text of the system are drawn at each frame of each process: a glyph cache costs 109 ns for a glyph, a glyph from its outline 4 to 46 µs.
- **No layer 1: each terminal draws its box-drawing characters.** Each terminal would draw 160 glyphs at each scale that it shows, about 0.5 ms each time it starts. One drawing at the start of the system costs it nothing.
- **A wait for the glyph in the frame.** A process would be held by another process.
- **The advance in the private glyph cache.** The measure would depend on the content of the cache: a glyph evicted between the measure and the draw, or a cache full for the measure, would change an advance. The advance of a font file is a pure function.
- **An invalidation of the private glyph cache at a change of the settings.** The key holds the scale and the grid fit, so a glyph of another size or another grid fit is another entry, and the old ones leave by the order of use. The words hold the three stripes in the order red, green, blue, and the blend swaps them for a screen with blue first: a change of the order of the stripes reads the same words. A clear of the cache would only draw the same glyphs again when a setting comes back.
- **The cache in the memory of each process, given by the process.** Each process with a window would declare the same memory; a process that draws no glyph past the glyph cache reserves pages and touches none, so the kernel gives it no frame (`docs/ARCHITECTURE.md`, a page gets its frame at its first use). One size in the package is one place to change.
- **Fixed slots of the largest glyph.** A slot for a proportional glyph at scale 3 holds 3 072 words; the mean glyph at scale 1 is 83. Blocks that split by halves waste at most half a block.
- **A ring of words that evicts in the order of the writes.** A glyph that each frame uses (a letter of a title) would leave when the ring turns, and be drawn again.
- **The Greek letters of B612 drawn in the frame of B612 in the cells.** Its baseline is not the baseline of Paper Mono, and its glyphs pass the cell. In the frame of the first font, cut to the cell, they stand beside Paper Mono.
- **A demand glyph beside Spleen 8x16.** A glyph of Paper Mono beside the glyphs of Spleen has another form and another weight. With the setting `font` at `spleen`, a cell past the glyph cache draws the replacement glyph.
- **The code point as the index of a table.** The code points are 1 114 112 places; the characters that a process uses are a few hundred. A hash table keeps the table small.
- **A reader that trusts the fields of the demand cache.** The service writes the cache while a process reads it, and a fault of the service must not make a process read outside the cache.
- **One demand cache for each font.** Each cache needs its own fixed range, and the band has 16 slots.

## Subtle points

- **The drawing module is shared code; its cache is not shared.** The module is one file in the boot image, but the loader gives each process its own copy of its data. So a process that draws through the module has two private glyph caches: the one of the module (the draw of its frames) and the one of the process (the text that it draws itself, as the process `interface_font` does). Both are paid by the budget of that process. Both read the same outlines, so the measure in the process and the draw in the module give the same advances.
- **The memory of a copy.** A copy reserves about 390 KiB: 256 KiB of words, the entries and the table, the blocks, and 75 KiB of render memory. The kernel gives a frame at the first use of a page, so a process that never draws a glyph past the glyph cache uses none of it, and the budget pays the reservation.
- **One thread of a process draws at a time.** The draw changes the private glyph cache, as it changes the blend tables: the rule of the drawing module. The measure only reads the outlines, so another thread can measure.
- **The compositor** draws its bar and its palette through the drawing module and its own code: it gets the outlines and the demand cache as each process does, and pays for its glyphs. A process never draws in the compositor.
- **The terminal** draws its cells through the drawing module. Its first frames can come before the font service ends: a box-drawing cell is then drawn in its private glyph cache, with the bytes of the demand cache. It waits for nothing.
- **A frame number that never moves.** A process that never calls `frame_begin` has one frame for its whole life. Its glyphs still leave by the order of their first use, and a glyph is drawn again when needed: never a wrong glyph.
- **The key holds the face, the scale and the position.** A change of the grid fit, of the scale or of the order of the stripes needs no clear: see the refused invalidation above.
- **A glyph drawn in each process.** The same glyph is drawn once in each process that shows it: 3 to 46 µs each time, and 300 to 6 000 bytes of words in each. It is the price of no shared state.
- **The hash of the font file names the face.** A glyph cache and a record of the outlines with one hash are the same font file. A process uses a fallback face only beside the glyph cache of its first font, and layer 1 only when the demand face names the same hash and flags.
- **The pairs of a character past the glyph cache are 0.** The pair table of a glyph cache is keyed by character indexes.
- **The module `text_shaping` has no fallback.** Its exports take the tables of the caller and hold no outlines: a character past the glyph cache is the replacement glyph there.

## The order of the steps

Each step leaves a working system.

1. Layer 0, layer 2 and the removal of the requests: the resource of the outlines and its range; the package `fallback_glyphs` with the private glyph cache and the fallback faces; the shaper and the draw read it; the font service reads the outlines from the resource, draws layer 1 and ends; the request ring, the budget of requests and the request handles of the root service are removed. Each window draws the Greek letters of B612 and the cells draw the cell subset of Paper Mono.
2. The fallback chain by script, as data, and the frame of the first font: the cells draw the Greek letters of B612, the interface draws the box-drawing characters of Paper Mono, and the font service names what each chain lacks.
3. Later: a font with the whole Greek block, Cyrillic and Latin Extended-A; a TrueType CJK font, with a cell of two columns; the shaping of complex scripts in the process.

## State

Built: the resource `font_outlines` and its fixed range; the package `fallback_glyphs` with the private glyph cache, the fallback faces, the chains by script and the frame of the first font; the shaper and the draws of `graphics` with it, in each process and in the drawing module; the demand cache with its four faces, drawn whole by the font service, which then ends; the root service, which maps the outlines and the demand cache with the glyph caches; the terminal and the process `interface_font` with their machine test lines; the host tests of the cache and of the measure.

Left (`ROADMAP.md`): a font for the missing Greek letters, Cyrillic and Latin Extended-A; a CJK font; the shaping of complex scripts.

Designed, not built: the text rendering module draws each glyph at any size into the private glyph cache, which then holds every glyph; the glyph caches of the boot image, layer 1 and the font service leave ([text_rendering.md](text_rendering.md), "The glyph caches of the boot image and the demand cache: removed").
