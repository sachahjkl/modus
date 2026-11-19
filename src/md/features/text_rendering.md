# Text rendering: one module for text at any size

## Purpose

The text of the system has three sizes: lines of 16, 32 and 48 pixels. The build draws the 192 common characters of each font at these three sizes into the glyph caches of the boot image. A process draws each other character from the outlines into its private glyph cache, at the same three sizes. The design rules say "no other size".

The scale factor of the reference screen needs other sizes: at 1.25, a line of 16 logical pixels is 20 pixels of the screen. A browser, a document and a rich module need any size. Three fixed sizes do not grow into either.

This design gives the system one text rendering module. A process gives a face, a size in 1/64 pixel and a text. The module gives the placed glyphs, the measure, the breaks of the lines and the pixels. The measure and the draw use the same numbers. Each process draws its glyphs at any size into its own private glyph cache.

The guides of today are [`docs/FONTS.md`](../../../docs/FONTS.md), "13. Glyphs past the glyph cache" and "14. Text at any size", and [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "5. Text". Its first step is built; the State says what is left. The parts that it replaces are in [glyphs_on_demand.md](glyphs_on_demand.md) and in [../api/draw_table.md](../api/draw_table.md), "The kinds".

## Constraints

- **The pixels of today do not get worse.** At a line of 16 pixels, each glyph of the font of the cells and of the interface font has the words that its glyph cache has today, byte for byte.
- **The measure and the draw agree.** A text is measured, then placed, then drawn. Another advance at the draw puts a text over another text.
- **Memory is paid by the process that draws** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller").
- **No shared state tells a process what another process draws** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", row 17). This rule covers a cache that fills at the requests of the processes, its evictions, and the time of an answer.
- **A process never waits for another process in its frame** ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)).
- **The damage is never too small.** A frame drawn in its damage gives the bytes of the frame drawn whole ([../api/draw_table.md](../api/draw_table.md), "The constraints").
- **A font file is hostile input.** The font outlines come from the boot image, and each read of the parser is checked.
- **The same font, the same renderer and the same size give the same bytes**, on each build and in each process.
- **The small hot code stays compiled in; the large code called a few times goes behind a module** ([../api/library_modules.md](../api/library_modules.md), "The chosen form: a split, with a coarse border").

## The chosen form

### The text size

The **text size** is the height of the line of a face, in 1/64 pixel. A line of 16 pixels is the size 1 024. The three sizes of today are 1 024, 2 048 and 3 072.

The **frame of a face** maps the text size to the units of its first font:

| Face | Its frame | At the size 1 024 |
|---|---|---|
| A face of cells (Paper Mono, Paper Mono SemiBold) | The advance of the font is half the line | 606 units are 8 pixels: the scale of today |
| A face of the interface (B612, B612 Bold) | The cap height of the font is 10/16 of the line | 1 500 units are 10 rows: the scale of today |

So each frame of today is the frame at the size 1 024, and the scale of a face is a rational number of the size: 2 × size subunits of 1/256 pixel for one cell. The rasterizer already places the points of an outline with a rational scale (`vector_font.Placement`), so any size is exact to the subunit. A glyph of a fallback font is drawn in the frame of the first font of its face, as today.

The text size is the line and not the em, for two reasons:

- The em of Paper Mono at a line of 16 pixels is 8 × 1 000 / 606 pixels: 844.88 units of 1/64 pixel, not a whole number. With the em as the size, no size gives the pixels of today.
- At one em, B612 and Paper Mono have other lines. A label and its value at one text size share one line, as they do today.

### The text size tokens

A process can draw any text size from 4 to 256 pixels. The desktop and the elements of the interface package use five text size tokens, in logical pixels ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "5. Text"):

| Token | Text size | x-height and cap height after the grid fit, at scale 1: B612; Paper Mono | Its elements |
|---|---|---|---|
| `text_caption` | 14 | 6 and 9 rows; 6 and 8 rows | The caption of a card, the detail of a row of a list, the hash prefix after a nickname in the menu of the windows |
| `text_body` | 16 | 7 and 10; 7 and 9 | Each other text |
| `text_heading` | 24 | 11 and 15; 10 and 14 | A heading of a page of `manual`, the heading of a group of a list |
| `text_large` | 32 | | The one number of a card |
| `text_largest` | 48 | | The one number that a whole window is about |

**The caption: 14, the readable floor of both fonts.** The x-height is the height that a reader reads, and the grid fit puts it on whole rows. At 14 the x-height of both fonts is 6 rows, one row under the body. At 13 the x-height of Paper Mono is 5.46 rows, which the grid fit rounds to 5, while B612 keeps 6: the two fonts of one line then differ by a row, and lowercase letters of 5 rows with subpixel bands lose their counters (`e`, `a`, `s`). At 14 a cell of Paper Mono is 7 pixels, a whole count.

**The heading: 24, the step between the body and the large number.** 16, 24 and 32 are steps of 1.5 and 1.33; 20 is a step of 1.25 that a reader hardly sees beside the body and the bold weight. 24 is a multiple of 8, so at each scale in eighths it is a whole count of pixels of the screen (3 for each eighth): its line, its cell of 12 and its baseline stay on whole pixels.

**The steps of the scale.** 16, 24, 32 and 48 are whole pixels at each scale from 1.25 to 2. 14 is a whole count at 1.5 (21) and 2 (28), and half a pixel off at 1.25 (17.5) and 1.75 (24.5). A text size needs no whole pixel: the glyphs are drawn at the fractional size, and only the baseline goes to a whole pixel, which the box of the record holds. A caption never forms a text grid, so no cell of it needs whole pixels.

The two new tokens appear in the second step, with the text size in the draw record: before it, a record holds only the scales 1, 2 and 3.

### The faces

A face is a first font, its frame, its weight, and the grid fit: `Interface`, `Interface_Bold`, `Cells`, `Cells_Without_Grid_Fit` and `Cells_Bold`. These are the fallback faces of today: the concept stays, and the word "fallback" leaves, because each glyph now comes from a face, not only the glyphs past a cache. Each face keeps its fallback chain by script, as data ([glyphs_on_demand.md](glyphs_on_demand.md), "The fallback chain by script").

A text record names a font kind (`Cells`, `Interface`) and a weight. The drawing module takes the grid fit from the settings page, so the record and the measure do not depend on that setting.

### The interface

The module is a support package, `text_rendering`. It is the package `fallback_glyphs` and the package `text_shaping` made one, with the line breaks of `interface.text_wrap_line`. It reads the fonts with `vector_font`. Each procedure takes the font outlines that the process validated once.

| Procedure | Input | Output |
|---|---|---|
| `text_shape` | face, size, text | the placed glyphs, in a table of the caller: the font of the chain, the glyph index in that font, x in 1/64 pixel from the origin, the advance with its pair adjustment, and the first byte of its character (the cluster) |
| `text_measure` | face, size, text | the advance width and the ink box in 1/64 pixel from the origin, the line, and the baseline |
| `text_fit` | face, size, text, room | the longest start of whole characters whose advance width fits the room |
| `line_break` | face, size, text, room | the end of the first line and the start of the rest |
| `ink_margin` | face, size | the most that the ink of a glyph of the chain of the face passes its advance box, on each side |
| `glyph_draw` | face, size, the placed glyphs, an origin, a color, a canvas, a cut | the pixels |

- **One function gives each number.** The advance of a character is the advance of its font file (`hmtx`), scaled to the frame and rounded to 1/64 pixel. The pair adjustment is the pair of `kern` format 0 of the font file, scaled and rounded the same way, when the two glyphs come from one font of the chain of a proportional face; two fonts, and a face of cells, have no pair. The x of a glyph is the sum of the integers before it: the rule of the sum of today ([`docs/FONTS.md`](../../../docs/FONTS.md), "12.4 The glyph cache with subpixel positions"). No number of a measure depends on a cache, on the grid fit or on the order of the stripes, so the measure and the draw give the same x to each glyph. A spacing names its set of fonts: the set of the process, or the set that the library module opens for one call.
- **The bounds hold at any size.** An advance is kept from 0 to one line and a pair within half a line, both functions of the size. The bound of 64 pixels of a glyph cache held only at its three sizes: at a line of 256 pixels a glyph of B612 is wider than it. One line holds the widest advance of the fonts of the system (2 000 units of B612 against 2 400), and with half a line for a pair the x of the last glyph of a text of 65 536 bytes at the largest size stays in an `i32`. A bound of four lines was refused: it breaks that sum.
- **The measure is compiled in. The draw is in the drawing module.** An element measures its texts 30 to 200 times in a frame. The drawing module draws them two times in a frame. So the measure is in each process, and the rasterizer, the private glyph cache and the blend are in the drawing module, which compiles the same package. Both read the same font outlines with the same code, so they give the same advances.
- **The line breaks** keep the order of [text_box.md](text_box.md): the last space that fits; in a word wider than the room, the last `/`, `:` or `_` that fits; else the last character that fits. A break is always between two whole characters. The rule of today breaks the bytes, and can cut a character of several bytes ([text_box.md](text_box.md), "Subtle points"). The line height is the text size.
- **Fallback faces** stay as they are: the first font of the chain of its script that has the glyph gives it, in the frame of the first font. No font: the replacement glyph, with the advance of `0`.
- **What waits.** The bidirectional algorithm: a text draws in the order of its bytes. The shaping of complex scripts: substitutions past the single substitution of the slashed zero, the positions of marks, the joining of Arabic, the order of the scripts of India; the cluster of a placed glyph is ready for them. The line breaking of Unicode (UAX #14) and hyphenation. CFF outlines, variable fonts and color glyphs. A cell of two columns for an ideograph. Each of them is an entry of `ROADMAP.md` when a principal needs it.

### The library module

The library module `text_rendering` exports `shape_text`, `measure_texts` and `break_text` over tables of the caller, for a caller that does not compile the package (a module of a third party, an isolated call). Each takes the font outlines as `Bytes(Read)`, a face and a text size; `break_text` appends one text range for each line. The guide is [`docs/FONTS.md`](../../../docs/FONTS.md), "12.3 The text shaping module".

- **The outlines are bytes of the caller, not a fixed range**, so an isolated call holds them in its call region. The tables of advances and of pairs that the module took before left its parameters: they came from a glyph cache.
- **Each call opens the fonts on its stack and keeps nothing.** A module variable is data of each importing process, and two threads of one process can call the module at once; the fonts of one call point into the bytes of that call, which the next call does not have. The fonts and the memory of one outline for their measures take about 16 KiB of stack. A call opens only the fonts that the chains of its face name (`fonts_of_face`: two for `Interface`, three for a bold face), and each open reads the outlines of 94 characters for the measures of its font: a cost of each call, which a batch export pays once for many texts. The measure of one call of `shape_text` on a label, opening included: `nix develop -c taskset -c 2 odin test src/modules/libraries/text_rendering -vet -collection:modus=src/library -o:speed -define:MEASURE=true -define:ODIN_TEST_NAMES=text_rendering_module.the_time_of_one_call`.
- **The border.** The face is a word that becomes a `Face` at one place, which refuses a word that names no member and the member `None`; the size passes `size_check`, with no clamp. Outlines that `font_outlines.validate` refuses, and outlines with no first font of the face, are refused with an error record that names argument 1.
- **Hostile bytes.** `font_outlines.validate` copies the header and the records once and checks the copies, so a record changed after the check moves no span. The parser checks each read of a font file against its bytes, and each advance and each pair is kept in its bound at its read. A changed byte gives other numbers, never a read out of the bytes. The open refuses a character map whose end codes do not grow strictly, so the lookup of a character is a search by halves: a scan of up to 32 767 segments for each character was refused, as a hostile font made each call slow with it. A `kern` table that the reader refuses leaves the font with no pair, and it still measures.
- **Refused: a copy of the outlines into the module.** About 195 KB at each call, for bytes that each read already checks.
- **Refused: a cache of the opened fonts between calls.** The fonts point into the bytes of the caller, which may not exist at the next call; a key by the hash of the bytes costs a hash of 195 KB at each call, more than the open.

The drawing module compiles the package in. It does not import the library module: the draw table crosses the border once for a frame ([../api/library_modules.md](../api/library_modules.md)).

### The cache

Each copy of the package that draws holds one private glyph cache, in its own memory: the private glyph cache of today, with three changes:

- **It holds every glyph**, not only the glyphs past a glyph cache of the boot image.
- **The key** is one word of 64 bits: the face (4 bits), the font of the chain (4 bits), the glyph index in that font (16 bits), the text size at the scale in force in 1/64 pixel (16 bits) and the subpixel position (2 bits). The glyph index, not the code point, because a substitution gives another glyph for one code point, and the shaping of complex scripts gives glyphs with no code point.
- **The bound** is 262 144 words of coverage (1 MiB) and 4 096 entries, about 1.25 MiB with the table and the blocks; with the render memory, the glyph memory of a copy is about 1.4 MiB. The working set of a window at a line of 32 pixels is about 400 KiB (below), so the bound holds it two times; the measure of the working set is read against it, and a working set past it is a regression to read to its cause.
- **The memory comes at the first use.** The glyph memory is no global: a global is part of the size of the module in memory, which the budget of each process that links the package pays at its start, whether it draws or not. A process that started many copies of a module that draws nothing ran short of its budget. So a copy keeps as globals only the memory of one outline (13 KiB, which the measure needs), a band of one row (11 KiB) and the state of the cache (56 bytes). At the first glyph that needs the glyph memory, the package says so (`memory_wanted`), draws that glyph band by band through its band of one row, and the next `display.text_frame_begin` reserves the memory: one memory object of the pages of `Glyph_Memory`, from the budget of the process, given to the package with `memory_give`, its one entry for memory, which a host test calls with memory of the test. When the budget refuses, the copy never tries again, draws each glyph past its glyph caches band by band with the right pixels, and a process writes one line on its log; it never stops. Drawn band by band rather than refused: a refused glyph is the replacement glyph, a fault that a reader sees; a glyph drawn band by band costs only time.

The cache keeps the blocks that split and join by halves, and the eviction by the order of use in frames ([glyphs_on_demand.md](glyphs_on_demand.md), "Layer 2: the private glyph cache"):

- A glyph used in a frame moves to the newest end once in that frame.
- A new glyph that finds no room evicts the glyphs of the oldest frames.
- A glyph of the frame in progress is never evicted. When the glyphs of one frame do not fit, the package draws the new glyph into its render memory, blends it, and does not keep it. The frame has the right pixels, and costs more time. The package counts each such glyph, and a process writes one line the first time, at the start of the next frame (`display.text_not_kept_tell`): the package calls no operation of the kernel, so its host tests run it whole. The copy in the drawing module counts and writes no line: a line of the log is a list of parts that hold the addresses of their texts, and a library module holds no table of addresses ([../api/library_modules.md](../api/library_modules.md)). Its count reaches the log when the draw export gives it back to its caller, a coming step. After the first glyph that finds no room, the frame keeps no other new glyph: a search that cannot succeed is not run again for each glyph.
- A glyph whose words pass the largest block (16 384 words: a glyph of 128 by 128 pixels) is never kept, and is not drawn whole either: the draw takes its rows band by band, as the rasterizer makes them, and blends each band. So the render memory has the bound of the largest block at any size.

The words of a key are a function of the key and of the font file: an eviction never changes a pixel. A change of the grid fit, of the size or of the scale is another key, so no change clears the cache: the old entries leave by the order of use.

No other process reads the cache, and the eviction is inside the process. The font outlines are pages of the boot image that no process writes. So the cache tells no process what another draws (property 20, row 17).

**Its cost.** A draw finds a glyph by a hash of its key in a table of 8 192 places: one or two compares, about 10 to 20 ns (an estimate). Today a glyph of a glyph cache is one load by its character index, and a glyph costs 109 ns over a flat color at a line of 16. The first draw of a glyph costs its raster, once in each process and each size.

### The glyph caches of the boot image and the demand cache: removed

The glyph caches of the boot image, the demand cache and the font service leave the system. Each glyph is drawn by the process that shows it. The demand cache and the font service left first, with the glyph caches still in the boot image: their removal changes no pixel, since a glyph of the private glyph cache has the words of the same glyph of the demand cache, and it needs no new measure of the text.

The numbers:

| | The glyph caches and the demand cache | Every glyph drawn by its process |
|---|---|---|
| The sizes that they serve | Lines of 16, 32 and 48 pixels only. The scale factor from 1.25 to 2 gives lines of 20 to 32 pixels: of these seven sizes, only 32 is a size of a cache | Each size |
| The boot image | More than 1.3 MB of caches: 390 624 and 397 344 bytes for Paper Mono with and without the grid fit, 424 784 and 108 324 bytes for B612 and B612 Bold, and the cache of Paper Mono SemiBold | The font outlines only: about 195 KB, already in the image |
| The start of the machine | The root service checks the hash of each cache: 796 to 966 µs for 390 624 bytes, about 3 ms for all | Nothing more |
| Shared memory | The demand cache: 4 395 008 bytes, 1 073 pages that the root service pays, and the process `glyphs` at each start | None |
| The first frame of a window | 0 µs for the 192 characters at the three sizes | Each glyph once: 3.3 to 4.1 µs for a glyph of cells and 16.2 µs for a placed glyph at a line of 16 ([glyphs_on_demand.md](glyphs_on_demand.md), "The measures") |
| A later frame | One load of a glyph | One hash of a key |

[glyphs_on_demand.md](glyphs_on_demand.md) refused "every glyph drawn at run time" for two reasons. The first was the boot display, drawn before any service runs. The boot display now keeps its Spleen bitmaps, at the size of Spleen that fits the resolution (8x16, 12x24, 16x32 or 32x64), and is not part of this module ([boot_display_scale.md](boot_display_scale.md)). The second was that each frame draws the 192 characters of its texts again. The cache draws each glyph once in each process, so the second reason does not hold.

One rule of the design rules weighed the other way: "no work at run time that the build can do" ([`docs/FONTS.md`](../../../docs/FONTS.md), first paragraph). The build cannot do this work: the size of the text on the screen is known only when the principal chooses the scale. The build still does the work that it can: the subsets, the font outlines, the check of each font.

The removal is the second step, after the module and its cache: the first step ships the rasterizer and the cache with the glyph caches still in the boot image, so that measure 2 runs before and after the removal with the same rasterizer, and the look of the first step is proved against the code that makes those caches. One shared form comes back only if the measure of the start of a window (measure 2 below) shows that the cold text of a window costs more than one frame of 8.3 ms at the scale in force: the font service draws the 192 characters of each face at the size in force, into a demand cache, at its start and at each change of the scale. Its content then depends on the setting only, not on what the processes draw, so it keeps property 20.

### The rasterizer

One rasterizer for each size: the exact area in integers of `vector_font` ([`docs/FONTS.md`](../../../docs/FONTS.md), "4. Fixed point"), with its filter of five taps, its words `0xGGRRGGBB` and its blend in linear light with a gamma of 2 ([../api/draw_table.md](../api/draw_table.md), "The color and the blending rule").

- **Any size.** The placement takes the frame of the face at the text size. The cell and the work row take their widths from the box of the glyph, not from a fixed 64 pixels: a placed glyph then costs about what a glyph of cells costs ([glyphs_on_demand.md](glyphs_on_demand.md), "The measures"). The box comes from the points of the outline before the raster, as a quadratic curve stays inside its control points, grown by the spread of the filter and one pixel on each side, so no ink reaches a side of the row. A glyph wider than 512 pixels, the widest glyph of a line of 256 pixels with room, is refused: its font is hostile. The accumulation works in bands of 8 rows, as the rasterizer of a path does ([../api/draw_table.md](../api/draw_table.md), "The execution"), so its memory has a bound whatever the size: about 150 KiB with the words of the largest block.
- **The grid fit at each size.** The baseline goes to a whole pixel. The x-height and the cap height go to the nearest whole pixel ([`docs/FONTS.md`](../../../docs/FONTS.md), "Grid fit (the hinting of this system)"). This fit is a function of the pixels of the screen, not of the size, so it holds at a fractional size too. It changes no advance: the measure does not depend on it. The setting `grid_fit` stays.
- **No other hinting.** The subsets hold no instructions, and the vertical stems need no fit: the subpixel bands place them in thirds of a pixel. A fit of each stem, and a darkening of the stems at a small size, wait for a measure of the look.
- **Three subpixel positions across, for each face and each size.** The x of a glyph goes to the nearest third of a pixel. Today the interface font has three positions at a line of 16, and one at 32 and 48; a glyph at 32 or 48 is now at most 1/6 pixel from its place, not 1/2. A glyph of cells at a whole pixel with an advance of whole pixels is always at the position 0, as today.
- **No vertical position.** The baseline is on a whole pixel. A vertical fraction makes the horizontal stems soft and triples the glyphs of the cache. A text placed at a fractional height moves at most half a pixel; its box holds that move.
- **The cut of a cell.** A glyph of a face of cells is cut to its cell at each size, as today, so a cell never draws into its neighbour.
- **The order of the stripes** (`rgb`, `bgr`, `none`) stays a choice of the blend, not of the words, so it is not in the key.
- **The proof.** A host test draws the 192 characters of each face at the sizes of its glyph cache (1 024, 2 048 and 3 072; 1 024 for the bold weights), at each position, and compares the box and each word with the glyph that the build of the glyph caches draws from the same font file, with the code of the tool that makes the caches of the boot image (`vector_font.glyph_cache_build` and `glyph_cache_build_proportional`). The faces of the interface are built with three positions at each size for the test: at 2 048 and 3 072 the position 0 is the glyph of today's cache with one position, and the two other positions are new. A compare with the code, and not with stored hashes or a reference file: while the glyph caches are in the boot image, that code makes them, so the test compares with the bytes of the boot image by construction, and names the glyph and the row that differ. When the glyph caches leave, that code leaves with them, and the test keeps the hash of the words of each face and size, taken from the last build that had both.
- **The golden hash.** The same test prints the golden hash of each face and size: the BLAKE3 hash, over the 192 characters by their character index and at each position, of the box of each glyph that this package draws (four numbers of 32 bits) and of its words, all in little endian. While the compare with the code passes, these are the hashes of the words of the glyph caches. They are stored, from a build that had both, and the test compares with them too, so the proof stays when the code of the glyph caches leaves. The glyphs past the glyph cache that the demand cache held (the Greek letters of B612, the 165 characters past the glyph cache of Paper Mono and its SemiBold, at the sizes and positions of the demand cache) have golden hashes of their own: the code that drew them left with the demand cache, and no other test compares their words. They are taken from the first build without it, whose rasterizer is the one that a host test of the build before compared with the demand cache, word for word. A hash names no glyph that differs; the stored hashes are a last resort, not the first proof.
- **Why each word stays.** The outline keeps the placement of the rasterizer of the glyph caches: the origin at its column 4 and the baseline from the top of the line. The move to the work row across and to the band down is added to the ends of each segment, after the points of the outline and of its curves are computed. Each cut of the exact area is a function of the segment and of the line of the cut, so a move of the segments by whole pixels moves each cut by whole pixels. The clamp of the accumulation at the sides of a row is exact for the pixels inside the row.
- **The move of the placement is refused.** The point between two points off the curve, which TrueType implies, is a division by two that rounds toward zero. A band that moved the placement up gave negative coordinates to the points above it, which then rounded the other way: one subunit off at the first row of a band, in each glyph of B612 with such points. Paper Mono has almost none, so its cells did not show it.

### The draw record

A text record carries a size in place of a scale. Its fields after the header:

| Offset | Field | Type | Meaning |
|---|---|---|---|
| 24 | `first` | u32 | The first byte of the text in the byte table |
| 28 | `count` | u32 | Its bytes: at most `TEXT_BYTES_LIMIT`, 256 |
| 32 | `color` | u32 | A `Draw_Color` |
| 36 | `origin_x`, `origin_y` | 2 × i32 | The origin: the left of the advance box and the top of the line, in 1/64 pixel |
| 44 | `font` | u8 | A `Font_Kind`: `Cells` 0, `Interface` 1 |
| 45 | `weight` | u8 | A `Font_Weight` |
| 46 | `size` | u16 | The text size in 1/64 pixel; 0 is the default size, 1 024 |

- **The version.** The fields change meaning, so the record becomes version 18, with the exports `damage_of_draw_table_18` and `execute_draw_table_in_rectangles_18` ([../api/draw_table.md](../api/draw_table.md), "The version rule").
- **The border refuses** a size from 1 to 255 (under 4 pixels) and a size past `TEXT_SIZE_LIMIT` (16 384: a line of 256 pixels), a font or a weight that names no member, an origin off a third of a pixel across, an origin left of the box, and an origin more than the larger of 16 pixels and one line inside the left of the box. The bound of the size is a bound of cost: the worst record is 256 glyphs of the largest size over one place, each blended once over its box. A larger text is a path. The measure of the worst record (measure 7 below) is read against the bound, not used to choose it.
- **The box holds the ink.** The writer computes it with `text_measure` and `ink_margin`: the advance box grown by the ink margin of the chain of the face on each side, and by one pixel above and below for the move of the baseline and the grid fit. The ink margin is the most that a glyph of a font of the chain passes its advance box, from the `head` and `hhea` tables of each font in the frame of the first font, plus the spread of the filter. Today it is 2 pixels for B612 at a line of 16; it grows with the size.
- **The damage stays never too small.** The execution cuts each record to its box, and the damage of a record is its box rounded out to whole pixels, as for each kind. A margin that is too small cuts the ink of its own record, and damages nothing outside it. The difference compares the 48 bytes with `first` masked, then the bytes of the two texts, as today.
- **A text grid** gets the field `size` at 36 (u16). The cell is half the size by the size. The drawing module rounds the width of a cell to whole pixels of the screen, a half up, and its height is two widths, so a cell is a whole count of pixels at each scale. The difference and the draw of a grid are both in the drawing module, so both use the same cells. The kind `Text_Grid` stays until its measure decides ([../api/draw_table.md](../api/draw_table.md), "The text grid: the measure that decides").

### The scale factor

The scale factor of [desktop_to_browser.md](desktop_to_browser.md), "The reference screen", rests on this module:

- A process lays out its text in logical pixels, at the size of its record. The drawing module multiplies each place by the scale at its one border.
- **The layout is at the size of the record; the glyphs are at the size of the screen.** The drawing module shapes the text at the size of the record, multiplies the x of each glyph and the origin by the scale, and draws each glyph at the size of the record times the scale. So the places of the glyphs on the screen are the places of the measure of the process, scaled. The advances of the font at the size of the screen are not used: they round in another way, and with them a text is up to 1/128 pixel wider or narrower for each glyph than its measure.
- A scale in eighths keeps each spacing token on whole pixels of the screen (8 logical pixels are 10 at 1.25, 14 at 1.75).

### Who uses it

- **Each window** through the interface package: the measure, `text_fit` and the line breaks are compiled in; the draw is in the drawing module.
- **The compositor**: its bar, its menus, its titles and its palette, with the same package and the same module.
- **The terminal**: its grid through the drawing module.
- **The console**: through its terminal and through the palette of the compositor. It draws no pixel.
- **The windows that draw with `graphics`** (`tables`, `server`, `log`, `pages`): `graphics` draws a text through the package, and holds one cache in that copy.
- **Not the boot display.** The boot program, the root service and the process `boot` draw it in Spleen, at the size of Spleen of its scale: 8x16, 12x24, 16x32 or 32x64 ([boot_display_scale.md](boot_display_scale.md)). The root service no longer draws the boot display again in B612, so it needs no vector font.
- **Spleen** stays the fallback of a process whose font outlines are absent or refused, and the value `spleen` of the setting `font`. It draws at the largest whole scale whose line is not above the size, in the middle of the line. The list of the added characters and the character index stay, for the Spleen data only ([../data/text_encoding.md](../data/text_encoding.md)): a character that a vector font lacks takes its fallback chain, and needs no place in a list.

### The cost of the first frame and of a full frame

The processor profile asks for a frame in less than 8.3 ms and a window shown less than 100 ms after its start ([desktop_to_browser.md](desktop_to_browser.md), "The thresholds of the processor profile"). The numbers below are estimates from the measures of one glyph. They decide nothing until the measures after them run.

**The cold text of one window.** A window of cards draws about 60 characters of B612 at three positions (180 glyphs), 26 capitals of B612 Bold at three positions (78), and 60 characters of Paper Mono at one position (60): 318 glyphs.

| Line | The raster of today (placed 16.2 µs, cells 4.1 µs at 16) | A work row at the width of the glyph (placed as cells) |
|---|---|---|
| 16 pixels | 258 × 16.2 + 60 × 4.1 µs: about 4.4 ms | 318 × 4.1 µs: about 1.3 ms |
| 32 pixels | 258 × 32.4 + 60 × 10.3 µs: about 9.0 ms | 318 × 10.3 µs: about 3.3 ms |

So the work row at the width of the glyph is part of the first step: with the raster of today, the first frame of a window at the scale 2 passes 8.3 ms once. Each window draws its first frame in its own process, so the windows of a change of scale draw at once on several processors.

**A full frame.** The draw table of the first measure has 339 records and takes 2043.0 µs at the median. Its glyphs are already in the cache after the first frame, so a frame adds one hash for each glyph: about 1 000 glyphs, 10 to 20 µs. At the scale 2 a glyph has four times the pixels; a glyph of the glyph cache at scale 2 costs 285 ns against 109 ns at scale 1, so the text of that table costs about 0.2 ms more.

**The memory.** The 318 glyphs of a window hold about 25 000 words at a line of 16 (74 to 83 words for each glyph on the mean), 100 KiB, and about four times that at 32. The bound of 1 MiB holds the working set of a window at the scale 2 two times. The demand cache and the caches of the boot image, about 5.7 MB of shared pages, leave.

**The measures.** Each one is a measure, never a test. Measure 2 alone can bring back a shared cache; the others are read against the bounds above:

1. The raster of one glyph of each face at the lines of 16, 20, 24 and 32 pixels, with the work row at the width of the glyph: on the host and in the machine, the least of 200.
2. The start of a window, from `Process_Start` to its first flip, for `interface_elements` and `settings`, at 16, 20 and 32 pixels, before and after the first step: the median of the measure run. It decides whether the shared form of the demand cache comes back.
3. The draw table of `processor_frame` with a warm cache, at 16 pixels before and after the first step, and at the scales 1.25 and 2 after the third.
4. The working set: the entries and the words of the cache of each process after the main machine test, and the most over the processes, against the bound of 1 MiB.
5. The measure of a text from the font file against the tables of a glyph cache: `texts_measure` of 100 lines.
6. The start of the machine: the root service before and after the removal of the caches and of the font service.
7. The worst text record at `TEXT_SIZE_LIMIT`, in one damage rectangle of 1920 by 1080, against the bound of 256 pixels.

## The refused forms

- **The size as the em, in pixels for one em.** No size of today is a whole number of 1/64 pixel, and two faces at one em have two lines (see "The text size").
- **A size in points, with a resolution of the screen.** The system lays out in logical pixels, and the scale factor is the one conversion to the screen.
- **More fixed sizes, as a scale in eighths.** It is the limit of today with more steps: a browser and a document need any size, and each step is one more set of glyphs at the build.
- **The glyph caches of the boot image kept as a speed-up of the first frame.** They serve one of the seven sizes of the scale factor, cost more than 1.3 MB of the boot image and about 3 ms of each start, and save 1 to 4 ms of the first frame of each window at scale 1 only.
- **The demand cache and the font service kept.** Their subsets are drawn at the three sizes of today. At another size they hold nothing that a window draws, and they cost 1 073 shared pages.
- **A shared cache that fills at the requests of the processes.** It is the channel of property 20, row 17 ([glyphs_on_demand.md](glyphs_on_demand.md), "The forms that were refused").
- **The shaping or the measure in a service.** A process then waits for another in its frame, and the time of an answer depends on the work for the others.
- **The measure through the library module only.** An element measures its texts 30 to 200 times in a frame; a call of the module checks its arguments at each call. The measure is small and hot, so it is compiled in, as the elements are.
- **The placed glyphs in the byte table, in place of the text.** The measure and the draw then agree by construction, but each glyph takes 16 bytes in place of one to four, the difference compares those, and a hostile writer gives any place to each glyph. The bytes of a text are the fact that a reader copies; the drawing module shapes them again with the same package.
- **The shaping at the size of the screen at a scale.** The advances round at each size, so the places of the glyphs on the screen are then not the places of the measure.
- **A vertical subpixel position.** It makes the horizontal stems soft and triples the glyphs of the cache.
- **More than three positions across.** The step of the stripes is a third of a pixel; a finer step is not visible ([`docs/FONTS.md`](../../../docs/FONTS.md), "12.9 Where this design is least sure").
- **The interpreter of the TrueType instructions.** The subsets have none, and the fit of the vertical metrics is the hinting of this system.
- **The code point in the key of the cache.** A substitution gives another glyph for one code point.
- **A cache that a process gives at each draw.** Each window then declares the same memory; the working memory of the drawing module is one place to change ([glyphs_on_demand.md](glyphs_on_demand.md), "The forms that were refused").
- **A clear of the cache at a change of the scale.** The size is in the key; the old glyphs leave by the order of use, and come back at once if the scale comes back.
- **A size that the border clamps.** A clamp turns a value that the contract refuses into a value that it accepts ([../infrastructure/choice_constants.md](../infrastructure/choice_constants.md)).

## The subtle points

- **The measure is a pure function** of the font file, the face, the size and the text. The grid fit, the order of the stripes, the cache and the scale do not enter it.
- **The rule of the sum.** The advance and the pair are rounded each on its own, then added. So the x of a glyph is exact to the rounding of each term, and no error adds up along a text.
- **The box at a scale.** The box of a record is in logical pixels; the drawing module scales it with the rounding of each edge. The ink at the size of the screen is the ink of the measure scaled, within the move of the baseline to a whole pixel, which the margin of one pixel above and below holds.
- **One thread of a process draws at a time.** The draw changes the cache. The measure only reads the font outlines, so another thread can measure.
- **The drawing module can be replaced** by a row that the signing key of the system signed. A replacement with another shaper places the glyphs in another way; the box cuts its ink, and no other record is damaged.
- **An isolated call of the interface module** has no font outlines: it draws its elements in Spleen, at the size of the record.
- **A frame larger than the cache** draws right and slowly, with one line on the log; it is never a fault.
- **Two glyph memories in one process.** A process that draws through the drawing module and with its own copy of the package can reserve two glyph memories, 354 pages each. The terminal, the compositor and `interface_font` state both in their budgets, and an `#assert` of `display` ties that number to the size of the glyph memory. Another window that shows a glyph past the glyph caches pays it from the room of its budget; the count of the glyph memory by the tool is an entry of `ROADMAP.md`.
- **The terminal at a scale** gets cells of whole pixels: a cell of 8 logical pixels at a scale in eighths is a whole count of pixels (9 at 1.125, 10 at 1.25). A grid of another text size can get a cell that the rounding moves: the grid is then up to half a pixel for each column narrower or wider than its logical box times the scale, and the execution cuts it to its box.

## State

The boot display in Spleen only, which this module needs first, is built ([boot_display_scale.md](boot_display_scale.md)). The steps are the entries of `ROADMAP.md`, each a working system:

1. Built: the module and its cache at any size, with the look of the desktop unchanged. The package `text_rendering` holds the faces and their chains, the text size and its check, the frame of each face, the measure, the line breaks of `interface.text_wrap_line`, the rasterizer with the work row at the width of the glyph and the rows in bands of 8, and the private glyph cache with its key of 64 bits, its bounds of 1 MiB of words and 4 096 entries, no eviction of a glyph of the frame in progress, and the glyph drawn and not kept with one line on the log of a process (the copy in the drawing module counts it, and its count does not cross the border of the module yet). The packages `fallback_glyphs` and `text_shaping` left. The glyph caches of the boot image still draw the 192 characters; every other glyph comes from the private glyph cache at the size of its scale. The callers give the sizes 1 024, 2 048 and 3 072.
2. The removal of the glyph caches of the boot image, of the demand cache and of the font service, in two parts, each a working system:
   - Built: the demand cache, the font service and its process, its fixed range and its fuzz target leave; each glyph past the glyph caches comes from the private glyph cache; the compositor names what each fallback chain lacks; the test of the words prints the golden hash of each face and size. The characters past the glyph cache that the font subsets hold do not change: their list is in the tool.
   - Built: the measure of every character from its font file, with the pairs of `kern` between two glyphs of one font, at any size; the bounds of the shaper as functions of the size; the library module `text_rendering` with the font outlines as `Bytes(Read)`, the face and the size, and `break_text`. The interface font is used only where its two faces are open. A host test proves that the advances and the pairs at the sizes of the glyph caches are the numbers of their tables, so no place moved.
   - Left: the glyph caches of the boot image leave, and every glyph comes from the private glyph cache; the golden test compares with the stored hashes only; the settings name faces and outlines; each budget of a process that draws text holds its glyph memory. Measures 2, 3 and 6 run before and after it.
3. The draw record with sizes: version 18, `size` in place of `scale` in the text record and in the text grid, and the elements that take their sizes from the text size tokens, with `text_caption` and `text_heading` in the elements of "The text size tokens".
4. The scale factor of the desktop ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen").
5. The grid as spacing tokens ([spacing_tokens.md](spacing_tokens.md)). Built: it depended on no other step.

The measures of the first step: [`docs/FONTS.md`](../../../docs/FONTS.md), "14.6 Measures".
