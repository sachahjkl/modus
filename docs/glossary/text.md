## Text

### Text encoding

The text encoding is the one form of a text in every contract of the system: UTF-8 with no control character, and a length in bytes.

Each record that two parties share holds its text in this form: a line of the log, the name of an object of a store, a `Text` of the module contract. A party checks a text from another party at its border with `text_encoding.text_valid`, and cuts a text only after a whole character (`complete_characters`). A capacity of a field is a count of bytes, not of characters. An identifier of the system (a module, an export, a setting, a process) stays in the visible characters of ASCII, so that it has one form only.

The design: `src/md/data/text_encoding.md`.

Do not use: charset, code page, string encoding.

### Code point

A code point is the number of one character of Unicode, from 0 to 0x10FFFF.

UTF-8 writes a code point in one to four bytes: the code point 233, é, is the two bytes C3 A9. The cell of a text grid holds a code point, so one cell is one character. The console command `character` gives the text of a code point. A surrogate (0xD800 to 0xDFFF) and a control character are code points that no text of the system holds.

The design: `src/md/data/text_encoding.md`.

Do not use: rune (outside the code), character number, Unicode value.

### Invalid sequence

An invalid sequence is bytes of a text that are no character of the text encoding: a broken sequence of UTF-8, or a control character.

The broken forms are an overlong form, a surrogate, a number above 0x10FFFF, a continuation byte with no first byte, and a sequence cut short; each is one byte long. The control characters are 0 to 31, 127 and 128 to 159: a terminal of the host acts on some. A border that checks a text refuses it (the palette table, the name of an object of a store), the kernel writes `?` in place of each of its bytes in a line of the log, and a reader that draws shows the replacement glyph.

The design: `src/md/data/text_encoding.md`.

Do not use: fault (for this), bad byte, mojibake.

### Replacement glyph

The replacement glyph is the outline of a box that a reader draws in place of a character that the font lacks and of an invalid sequence.

Code draws it in each font and at each scale, so no font needs a glyph for it: the box goes from the top of a capital letter to the baseline, inside one cell. A byte is never drawn as a glyph, so a reader always sees that a character is there. Text shaping places it as `REPLACEMENT_GLYPH`, with the advance of `0`. A character that no font of its fallback chain has draws it too, and so does a character whose outline the renderer refuses, at the advance of its font.

The design: `src/md/data/text_encoding.md`.

Do not use: tofu, missing glyph, question mark (for this).

### Font

A font is a set of glyphs of one design, with the measures that place them side by side.

The modus tool subsets each font file at the build and draws its characters into a glyph cache; a process draws a character past the cache from the font outlines of the boot image. The system has three fonts: Paper Mono, the monospace font of the cells; B612, the interface font; and Spleen 8x16, a bitmap font, the fallback with no valid glyph cache. A font here is one file of one weight: Paper Mono SemiBold is a font of its own, with its own cache.

The design: `docs/FONTS.md`, "6. The font file".

Do not use: typeface (for this), font face.

### Glyph

A glyph is the form of one character in one font.

The character is the number (the byte 0x30 is the character `0`); the glyph is the drawing of it. One character can have several glyphs in one font: Paper Mono has a plain zero and a slashed zero, and a font feature chooses between them. A glyph has an outline and an advance; in a glyph cache it is a box of words of coverage. A character past the glyph cache takes the glyph of the first font of its fallback chain that has it, else the replacement glyph.

The design: `docs/FONTS.md`, "5. The glyph cache".

Do not use: character (for the form), symbol.

### Outline

An outline is the set of closed contours of line segments and quadratic curves that bound a glyph or a pointer shape, in units of its font or of its design size.

The outline is what a TrueType font stores in its table `glyf`: points in units of the font, each on or off the curve. The renderer of `src/library/support/vector_font` cuts each curve into segments, scales the points to the grid, applies the grid fit, and accumulates the coverage of each pixel in fixed point. A pointer shape of the theme of the system is also an outline, written in its pointer manifest, and the same renderer draws it. The modus tool reads no outline of CFF (cubic curves) and no SVG file.

The design: `docs/FONTS.md`, "4. Fixed point".

Do not use: path, vector shape, Bézier.

### Coverage

Coverage is the part of a pixel, or of a third of a pixel, that a glyph covers, from 0 (none) to 255 (all).

The renderer computes the coverage of each third of each pixel from the outline. The glyph cache keeps one word for each pixel: the coverage of the red, green and blue subpixel band, and the coverage of the whole pixel for grayscale. The blend mixes the color of the text with the pixel under it, channel by channel, in linear light. Coverage is not an alpha of a picture: an alpha is one premultiplied value for the whole pixel, and coverage is one value for each band.

The design: `docs/FONTS.md`, "3. Subpixel bands".

Do not use: alpha (for this), opacity, mask.

### Subpixel band

A subpixel band is one of the three color stripes of a pixel of the screen, red, green and blue side by side, for which the vector font has a coverage of its own.

With a coverage for each stripe, an edge of a glyph can sit on a third of a pixel, and a stem looks sharp at small sizes. A filter spreads each third over its neighbours, so that a side of a stem does not show one color alone. The order of the stripes is the setting `subpixel_order`: `rgb` (the default), `bgr` or `none` (grayscale); the system cannot read the order of the panel. Enlarged, a screenshot shows orange and blue edges on each letter: that is the bands at work, not a fault.

The design: `docs/FONTS.md`, "3. Subpixel bands".

Do not use: subpixel, ClearType, LCD stripe.

### Grid fit

Grid fit is the move of the baseline, the x-height and the cap height of a font onto whole pixels, so that the tops of the letters are sharp.

At 13 to 14 pixels to the em, the tops of the letters fall between two rows, and a row of half coverage under each top makes the text soft. The grid fit puts the baseline on a whole pixel, moves the x-height and the cap height to the nearest whole pixel, and scales the points between them (`vector_font.place_y`). The vertical stems need no fit: the subpixel bands place them. The system has no other hinting. The grid fit is the setting `grid_fit`: `on`, the default, or `off`.

The design: `docs/FONTS.md`, "Grid fit (the hinting of this system)".

Do not use: hinting (alone), autohint.

### Glyph cache

A glyph cache is a file that holds the glyphs of one font already drawn, as words of coverage, for each character 32 to 126, each character U+00A0 to U+00FF and the euro sign at each scale of the grid.

It moves all the work of a font out of the processes: the modus tool builds it, and the boot image holds it as a resource. The root service checks its hash once, and maps it read-only at a fixed range in each process with a surface. A process validates it once, then each draw reads the words of a glyph with no other check. No process writes it. It is not an atlas of a GPU and not a cache that fills on demand.

The design: `docs/FONTS.md`, "5. The glyph cache".

Do not use: atlas, texture cache, glyph bitmap.

### Added character

An added character is a character past U+00FF that each font of the system draws, named one by one in a list of the glyph cache contract.

The fonts hold two ranges, ASCII 32 to 126 and the Latin-1 Supplement, and the added characters. Today the list `glyph_cache.added_characters` holds the euro sign U+20AC alone, which AltGr with `e` types on the layout of France. A character joins the list only if each font of the system has a glyph for it, and each change of the list is a new version of the glyph cache. The build refuses a font that lacks one: no font draws it with the glyph of another character.

The design: `src/md/data/text_encoding.md`.

Do not use: extra character, extended range.

### Character index

A character index is the number of a character in each table of a font of the system: 0 to 94 for the characters 32 to 126, then 95 to 190 for U+00A0 to U+00FF, then 191 and up for the added characters.

The fonts hold these two ranges and the added characters, so the numbers name each character that a font draws, with no hole: the control characters 127 to 159 have none. A glyph cache keys its glyphs, its advances and its pairs by it, and so do the Spleen data and a placed glyph. `glyph_cache.character_index` gives the number of a code point, and `glyph_cache.character_of_index` the code point of a number. Another code point has no character index: it is a glyph of its fallback chain, or the replacement glyph.

The design: `src/md/data/text_encoding.md`.

Do not use: glyph id (for this), glyph number, character offset.

### Proportional cache

A proportional cache is a glyph cache of a proportional font: each character has its own advance, each glyph is the box of its ink at each subpixel position, and the cache holds the pair adjustments.

The header flag `FLAG_PROPORTIONAL` marks it. One format serves both kinds of font, and the flag says which rules `validate` applies. A proportional cache keeps three subpixel positions at scale 1, the box of the ink of each glyph, the advance of the font in 1/64 of a pixel, and the sorted pairs. A text of cells refuses it, because its glyphs pass their cells. The two caches of B612 are the resources `interface_glyph_cache` and `interface_glyph_cache_bold`.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: proportional font cache.

### Font outlines

The font outlines are one resource of the boot image that holds the font files of the system, from which each process draws the glyphs past its glyph caches.

The resource is `font_outlines` (`src/library/contract/font_outlines`): a header, one record for each font with the BLAKE3 hash of its file, then the font files of the glyph caches. The root service checks its hash once and maps it read-only at the fixed range `Font_Outlines` in each process that gets the glyph caches. A process validates its header once. The font outlines are not a glyph cache: they hold outlines, not drawn words.

The design: `src/md/features/glyphs_on_demand.md`, "Layer 0: the outlines, shared and read-only".

Do not use: font bundle, font pack.

### Fallback chain

A fallback chain is the list of fonts, in order, that give the glyph of a character past the glyph cache of a face: the first font of the list that has the character gives its glyph and its advance.

The chains are data, one row for each script (`text_rendering.scripts`): Greek, Cyrillic, the box-drawing characters and the block elements, and a default chain for each other character. The first font of each chain is the font of the glyph cache of the face, and a glyph of another font stands on its baseline, with its capitals as high. A character that no font of its chain has draws the replacement glyph. The chain of the interface is B612 then Paper Mono; the chain of the cells is Paper Mono then B612.

The design: `src/md/features/glyphs_on_demand.md`, "The fallback chain by script".

Do not use: font stack, font fallback list.

### Private glyph cache

The private glyph cache is the memory where a copy of the text rendering module keeps the glyphs that it drew, which no other process reads.

A glyph is drawn at its first use and kept, by its face, font, glyph index, text size and position: 1 MiB of words and 4 096 entries at most. A new glyph that finds no room evicts the glyphs of the oldest frames, never one of the frame in progress; past that it is drawn and not kept. The budget of the process pays for it. It holds no advance. It is not shared, so it tells no process what another draws.

The design: `src/md/features/text_rendering.md`, "The cache".

Do not use: glyph atlas, local cache, per-program cache.

### Setting

A setting is one choice of the principal of the machine that each process follows: the font, the order of the subpixel bands, the pointer theme, the grid fit, the layout of the keyboard, the appearance or the time zone.

Each setting is one value of the settings page, with 0 as its default: `font`, `subpixel_order`, `pointer_theme`, `grid_fit`, `keyboard_layout`, `appearance`, and `time_zone`, a fixed offset from UTC. The process `settings` is the one writer: its window, `settings.set(name, value)` and `settings.get(name)`. A caller that does not act for the principal gets `No_Grant`. A change takes effect while processes run, and the values survive a stop in the private store of `settings`. A setting is not a configuration file of one process, and the scheduling strategy is not a setting.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: preference, option, configuration.

### Dead key

A dead key is a key of a layout of the keyboard that gives no character itself, and puts its accent on the character of the next key.

The layout of France has four: the circumflex and the diaeresis on the key right of P, and the tilde and the grave accent with AltGr. `^` then `e` gives ê, because the words of French need accented letters that the keyboard has no other key for. A space after a dead key gives the accent alone; a key with no accented form gives the accent, then its own character. The input service keeps the accent that waits; the tables are in `src/library/private/input/keyboard_layout`.

The design: `src/md/features/keyboard_layout.md`.

Do not use: compose key (for this), accent key, modifier (for this).

### AltGr

AltGr is the right Alt key of the keyboard, which gives the third level of the layout of France: a third character of a key, after the character without Shift and the character with Shift.

With the layout of France, AltGr with the keys of the row of the digits gives the characters that an AZERTY keyboard prints on their right side, as `#`, `{` and `@`; with the key of `e` it gives the euro sign €. AltGr with the key of 2 or of 7 is a dead key. The left Alt key, and Control with Alt, are not AltGr. With the layout of the United States, AltGr changes no character. The key record carries the character of the third level, and no modifier bit of AltGr.

The design: `src/md/features/keyboard_layout.md`.

Do not use: Option, level-3 shift, compose key (for this).

### Settings page

The settings page is the one page of memory that holds the current value of each setting, which each process with a surface reads.

The root service creates the page. The process `settings` receives it with Write; each process with a surface, each terminal and the compositor map it read-only at the fixed range `Settings_Page`. The page holds the choices and the appearance in force only: no address, no size and no hash of a glyph cache, so its writer cannot point a process at memory that it controls. A reader reads again while the change count is odd. It is not a registry and not a file: a record in the store of `settings` survives a stop.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: registry, config file, dconf.

### Appearance

An appearance is one value of each color token: the desktop has two, dark and light.

The dark appearance is the one of the boot display: light text on a dark background. The light appearance is the light form of the site: dark text on a light background, white cards, each concept at a darker shade of its accent. The setting `appearance` chooses `dark`, `light`, or `auto`: the light appearance from 07:00 to 19:00 of the local time and the dark one at night. A picture keeps its pixels in both, and the boot display is always dark.

The design: `src/md/features/appearance.md`.

Do not use: theme (for this: a pointer theme is a set of pointer pictures), dark mode, light mode, skin.

### Appearance in force

The appearance in force is the appearance, dark or light, that each process draws now.

It is one word of the settings page. With the setting `dark` or `light` it is that value; with `auto` it is the value of the rule of the day at this moment, which `src/library/support/appearance` computes from the date page. The process `settings` writes it with each change of the values, and the root service writes it at 07:00 and 19:00 of the local time. A process reads it at each frame through `src/library/support/display`, which gives it to `graphics.appearance_use`; the compositor sends `Settings_Changed` to each window when it changes, so each window draws once.

The design: `src/md/features/appearance.md`.

Do not use: current theme, active mode.

### Color token

A color token is a named color of the design rules that has one value in each appearance: a surface, a concept or a part of the desktop.

`graphics.Color_Tokens` holds each token; `graphics.colors` holds their values in the appearance in force of a process, so a drawer writes `graphics.colors.text` and draws the text of the dark or of the light appearance. The `DARK_` constants of the package are the values of the dark appearance, for constant tables and for what is always dark (the boot display, the mark). White, black and the ink of a text on white are not tokens: they are the same in both appearances.

The design: `src/md/features/appearance.md`, and `src/library/support/graphics/rules.odin`.

Do not use: palette color (the palette is a panel of the desktop), design token, swatch.

### Series color

A series color is one of eight color tokens that tell apart the members of one series: several things of one kind that no concept of the design rules tells apart.

A member takes the series color of its number (`graphics.colors.series[number]`), and a ninth member takes the first color again. The threads of `processors` and the records of `rings` are series. A series color is never the only sign: a number or a word names the member. A record of `rings` carries its series number, not its color, so that it keeps its member when the appearance changes. A series color is not a concept: a thread of a series is not the kernel because it is blue.

The design: `src/md/features/appearance.md`, "The colors of the processes".

Do not use: identity color, tint, palette, hue (for this).

### Intensity step

An intensity step is one of the three ranges of the share that a gauge shows: normal, high from 60 %, and very high from 85 %.

A gauge, as the memory bar and the processor bar of a process in `monitor`, takes the color of its step: the color of the concept that it measures, then `warning`, then `near_limit`. A share at a threshold is in the higher step. The number beside the gauge says the value, so the color is never the only sign. It is not a continuous hue: each color keeps one meaning. `graphics.intensity_of` gives the step, `graphics.intensity_color` its color.

The design: `src/md/features/monitor_window.md`, "The intensity steps".

Do not use: heat color, severity, load level, color scale.

### Warning color

The warning color is the color token of a state that asks for attention and is not a failure.

A record of the log of the level Warning, a ring of `rings` that is full and a gauge at its high intensity step have it (`graphics.colors.warning`). It is a yellow apart from the orange of the boot program, so that "starts" and "take care" are two colors; a failure has the color `failed`. A warning color is never the only sign: the level or a word says the state.

The design: `src/md/features/appearance.md`, "The colors of the processes".

Do not use: caution color, alert color.

### Near limit color

The near limit color is the color token of a measure near its limit: the very high intensity step of a gauge.

A gauge of `monitor` at 85 % or more has it (`graphics.colors.near_limit`). It is an orange between the yellow of the warning color and the coral of `failed`: a load near its limit asks for more attention than a warning, and it is not a failure, because the machine still does what it must. It is never the only sign: the number beside the gauge says the value.

The design: `src/md/features/monitor_window.md`, "The intensity steps".

Do not use: danger color, critical color, overload color.

### Link color

The link color is the color token of a link: a name in a page that leads to another page.

`manual` draws each link of a page in it (`graphics.colors.link`). A link has the band of the track when it has the focus, so the link color keeps 4.5 to 1 on the track as on the background and a card, in both appearances. The site draws a link in the text color with a line under it: its pages have a form of their own.

The design: `docs/DESIGN.md`, "5. Text", and `src/md/features/appearance.md`.

Do not use: hyperlink color, accent (for this).

### Monospace font

A monospace font is a font whose characters all have one advance, so that a text is a row of equal cells.

The system has two: Paper Mono and Spleen 8x16. The font of the cells is monospace because the grid of the system is cells of 8 x 16 pixels: the terminal fills one cell and draws one character, and a glyph never leaves its cell. A text stays monospace when it is a grid of cells, or when a reader compares it character by character or copies it: hashes, addresses, code, a log record. A text that names or explains is in the interface font.

The design: `docs/FONTS.md`, "12.6 Which text stays monospace".

Do not use: fixed-width font (for this), terminal font.

### Interface font

The interface font is the proportional font of the titles, the labels, the buttons, the menus and the bar: B612.

B612 has 19 different advances in ASCII, and all its digits have one advance, so a column of numbers aligns in it too. Its Bold weight has scale 1 only, for titles. A process uses it through `src/library/support/interface`: an element that names or explains draws a `Text` record in the interface font, which text shaping places with a proportional cache. If its caches are absent or refused, or if the setting `font` is `spleen`, each element draws in the font of the cells.

The design: `docs/FONTS.md`, "12. The interface font and the text shaping module".

Do not use: UI font, system font (for this), sans.

### Interface text

An interface text is a text that a draw table draws in the interface font: the draw record `Text` whose font is `Interface`.

Its rectangle is the measured box of the text widened by the ink margin on each side, so the damage of the record covers every pixel of its ink. Its origin is `text_origin_thirds` thirds of a pixel (0, 1 or 2) after `x` and the margin, so a label can start between two pixels. The table shapes the text and draws its placed glyphs with `graphics.text_proportional`. A text in the font of the cells is the same record with the font `Cells_8x16`, its origin the left edge of its box.

The design: `docs/FONTS.md`, "12.5 What changes in `src/library/support/interface`".

Do not use: proportional text record.

### Font in use

The font in use is the font that actually draws a text of a draw table: the interface font when the table can draw it, else the font of the cells.

A text asks for the interface font, but three things make it fall back: the table has no interface font (an isolated call: the call host maps no glyph cache), the setting `font` is `spleen`, or the text is longer than 256 bytes (`INTERFACE_TEXT_LIMIT`). `interface.font_in_use` decides, and both the measure and the draw call it. So a text is always measured in the font that draws it, and an element never passes its box in either font.

The design: `docs/FONTS.md`, "12.5 What changes in `src/library/support/interface`".

Do not use: effective font.

### Advance

The advance of a glyph is the distance from its origin to the origin of the next glyph, before any pair adjustment.

In a monospace font the advance is one constant: 8 pixels at scale 1. In a proportional font each character has its own: in B612, `i` is 600 units and `M` 1800. The glyph cache keeps the advance of each character at each scale in 1/64 of a pixel. The advance is not the width of the ink: a glyph can have ink before its origin or past its advance, and the ink margin covers that difference.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: width (for this), pitch.

### Pair adjustment

A pair adjustment is the change of the advance that a font gives for one pair of glyphs that follow each other.

Some pairs look too far apart with their advances alone: `T` before `o` leaves a gap under the bar of the T, so the font states a negative adjustment for that pair. The tool reads the pairs from the table `kern` and writes them, sorted, in 1/64 of a pixel, into the proportional cache. Text shaping adds the rounded advance and the rounded adjustment. A monospace cache has no pairs.

The design: `docs/FONTS.md`, "12.1 What B612 has, read in its files".

Do not use: kerning pair (for this).

### Font feature

A font feature is a named choice of glyph forms that a font offers in its table `GSUB`, by a tag of four letters.

Examples: `zero` (the slashed zero), `ss01` (a stylistic set), `numr` (numerators). A feature leads to one or more lookups, and each lookup changes glyphs. The system uses one feature, `zero` of Paper Mono, and only at the build: the tool reads it with `vector_font.single_substitution` and draws its glyph for the character `0` in the subset. The subset holds no `GSUB`, and no process reads features at run time.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: OpenType feature (for this), font option.

### Single substitution

A single substitution is a lookup of the table `GSUB` that puts one glyph in the place of another (lookup type 1).

It is the simplest lookup: a coverage table lists the glyphs that it changes, and a delta or a list gives the substitute of each one. The feature `zero` of Paper Mono is one: it puts the glyph `zero.zero` in the place of the glyph of the character `0`. The system reads no other kind of lookup: no ligature, no contextual form.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: glyph swap, alternate.

### Slashed zero

The slashed zero is a zero with a stroke at an angle inside it, so that it does not look like the capital O.

The plain zero of Paper Mono has the same contours as its capital O, and a reader of a hash or an address cannot tell `0` from `O`. So the character `0` of the system is the slashed zero of Paper Mono: the modus tool reads the font feature `zero` and draws its substitute for `0` in the subset. Each picture of the system with a 0 shows it.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: crossed zero, zero with a slash.

### Text shaping

Text shaping is the step that turns the characters of a text into placed glyphs, with the advances and the pair adjustments of one font.

A proportional text needs it: the x of each glyph is the sum of the advances and adjustments before it. The package `src/library/support/text_rendering` does it for a direct call, and the module `text_shaping` exports the same work: `shape_text` gives the placed glyphs of one text, and `measure_texts` the width of many text ranges in one call. The module holds no font and no state: the caller passes the spacing. Text shaping here does advances and pairs only: no ligature, no other script, no line break.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: layout (for this), typesetting.

### Placed glyph

A placed glyph is a record of 16 bytes that text shaping gives for one character: the glyph, its x from the origin of the run, and its advance.

The fields of `text_shaping.Placed_Glyph` are `glyph` (the character index, a glyph of the fallback chain, or `REPLACEMENT_GLYPH`), `x` from the origin of the text and `advance` with the pair adjustment that follows it, both in 1/64 of a pixel, and `cluster`, the first byte of the character in the text. `graphics.text_proportional` draws a table of placed glyphs: it rounds each x to the nearest subpixel position. The x keeps the exact sum, so the rounding of one glyph never moves the next one.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: positioned glyph, glyph run entry.

### Ink margin

The ink margin is how far the ink of a text of a proportional font can pass the box that its measure gives, on each side: 2 pixels at scale 1 for B612.

A measure gives the sum of the advances, but ink can start left of the first origin (`j`) and pass the last advance (`K` in Bold), and the subpixel filter spreads it. The damage of a `Text` record in the interface font is its measured box widened by `graphics.PROPORTIONAL_INK_MARGIN`, so a frame drawn in its damage equals a whole frame. The margin is a bound measured for B612: another interface font needs its own.

The design: `docs/FONTS.md`, "12.8 The parts, each one working".

Do not use: bleed, overhang (for this).

### Subpixel position

A subpixel position is the fraction of a pixel where a glyph starts: 0, 1/3 or 2/3 of a pixel in the glyph cache of a proportional font.

A glyph of a proportional font rarely starts on a whole pixel. With subpixel bands, the finest step that the screen shows is one third of a pixel, so a proportional cache keeps each glyph at scale 1 drawn at three positions. The draw rounds the x of each placed glyph to the nearest third (`glyph_cache.position_of`): the error is at most 1/6 of a pixel and does not add up along a text. At the scales 2 and 3, and in a monospace cache, the cache keeps one position.

The design: `docs/FONTS.md`, "12.4 The glyph cache with subpixel positions".

Do not use: subpixel offset, bucket.

### Spacing

The spacing is the two tables that text shaping reads for one font at one scale: the advances of the characters of a glyph cache and the pair adjustments, in 1/64 of a pixel.

`text_shaping.spacing_of` takes them from a validated glyph cache: 192 advances by character index and the sorted pairs (`glyph_cache.Pair_Entry`). The caller then passes them to `shape_text` or `measure_texts` as tables. So the module of text shaping holds no font, and an isolated call receives the spacing in its call region like the text.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: metrics (for this), kerning data.

### Text range

A text range is a record that names one text in a table of bytes by its first byte and its count, with its width, which the measure writes.

`text_shaping.Text_Range` has 16 bytes: `start`, `count` (at most `TEXT_LIMIT`) and `width` in 1/64 of a pixel. A window passes all its labels as one table of bytes and one table of ranges to `measure_texts`, which writes the width of each range: one call measures a whole frame (the direction Change of a table parameter). `interface.texts_measure` measures the lines of a list this way.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: span (for this), slice.

### Boot pass

The boot pass is the start of the process `settings` that the root service makes at the start of the machine, with no window, to put the kept settings on the settings page.

The settings survive a stop as one record (`Kept_Settings`) in the private store of `settings`. The root service cannot read the store itself, so it starts `settings` with the value 1 at `VALUE_BOOT_PASS` of its context. The process reads the record, writes the page, wakes the compositor and stops. A record of another version, or none, gives the defaults. Until the boot pass ends, the boot display and the first frames use the defaults; then each window draws again.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: init script, startup hook.

### Blend table

A blend table is the results of the blend in linear light of one text color over one pixel color, for each coverage of each channel, kept in the memory of a process.

The blend of a partial pixel costs two squares and a square root for each channel. For one text color over one background color, each channel of the result depends on its coverage only: 3 x 256 values. A process keeps a few such tables (`graphics.Blend_Tables`), and fills a value on first use with the formula of the reference blend. A row of a glyph whose two end pixels have one color uses the table of that color. The result is the same bytes as the reference blend.

The design: `docs/FONTS.md`, "Where the time goes, and the fast blend".

Do not use: lookup table (alone), LUT.

### Markdown block

A Markdown block is one unit of the Markdown of a source comment that stands on its own rows: a paragraph, a list item, a fenced block or an example.

The reader of the system (`src/library/private/manual/source_comment_markdown`) gives the blocks of a documentation text in order. A block is a range of bytes of that text, with its kind. A list item has its mark and its depth, a fenced block has the word after its opening fence, and a block says whether an empty line is before it. The Markdown spans of a block follow it. Example: `manual` starts a row for each block, and draws a band behind a fenced block. It is not a block of storage.

The design: `docs/SITE.md`, "The reader of the system".

Do not use: element, node (for this).

### Markdown span

A Markdown span is a run of bytes of a Markdown block with one set of styles: bold, italic, code, link.

A span has no mark: the stars, the backticks and the brackets are outside its range. A span can have several styles, and a span of a link names the bytes of its target. In a paragraph, a line feed in a span is one space; in a fenced block, a span is one line, kept as it is. Example: `manual` draws a bold span in the bold weight, a code span in the font of the cells, and a span of a link in the link color.

The design: `docs/SITE.md`, "The reader of the system".

Do not use: run (alone), token, inline.

### Link page

A link page is a page of the process `manual` for the target of a link that no module describes: a term of the glossary, a heading of a guide, or a declaration of the sources.

The documentation of a module links terms, headings of the guides and declarations of the support packages, but the manual reads only the boot image. So the build writes the page of each such target that the modules of the image link, in the resource `manual_pages`. The page of a term is its name, its short definition and its explanation; the page of a heading is its text and its subheadings; the page of a declaration comes from its source. A link page is not a copy of the site: it holds no picture.

The design: `src/md/features/manual_links.md`.

Do not use: document page.

### Text box

A text box is the place and the width that a window gives to one text: the text is drawn inside it, on one line or on more lines.

A text that is wider than its text box goes on more lines: a line ends at the last space that fits, and a word wider than the whole box ends a line after its last `/`, `:` or `_` that fits. No byte is left out, and the caller gives the box the height of its lines. Example: in `inspect`, a frame of a stop report takes three lines in a card. A text box is not a text grid, and not a cut, which ends with the cut mark.

The design: `docs/INTERFACE.md`, "The text in a box".

Do not use: label box, text area, text field (a text input is the element that takes typed text).

### Text size

A text size is the height of the line of a face, in 1/64 pixel, which a process gives to measure and draw a text.

A line of 16 pixels is the size 1 024, so the three scales of a text record are 1 024, 2 048 and 3 072. The text rendering module takes any size from 256 to 16 384, a line of 4 to 256 pixels, and refuses another. The frame of a face turns it into units of the font. A label and its value at one text size share one line. It is not an em, not a size in points and not a scale factor.

The design: `src/md/features/text_rendering.md`, "The text size".

Do not use: font size (alone), point size, scale (for this).

### Frame of a face

The frame of a face is the rule that turns a text size into the units of the first font of a face.

In a face of cells the advance of the font is half the line; in a face of the interface the cap height is 10/16 of the line. At a line of 16 pixels each frame gives the scale of today. A glyph of a fallback font is drawn in the frame of the first font of its face, on its baseline. It is not the line box of a text.

The design: `src/md/features/text_rendering.md`, "The text size".

Do not use: font metrics (for this), em box.

### Face

A face is a first font with its frame, its weight and its grid fit, from which each glyph of a text comes.

The faces are `Interface`, `Interface_Bold`, `Cells`, `Cells_Without_Grid_Fit` and `Cells_Bold` (`text_rendering.Face`), each with its fallback chain. A glyph of another font of the chain stands in the frame of the first font: in its cell for a face of cells. A process finds the face of a glyph cache by the hash of its font file and its flags. A face is not a font file: two faces can share one.

The design: `src/md/features/text_rendering.md`, "The faces".

Do not use: font face (for this), font slot, typeface.

### Text rendering module

The text rendering module is the support package `text_rendering` and its library module, which shape, measure, break, keep and draw a text at any text size.

Each process compiles the measure in; the drawing module compiles the draw and the private glyph cache in. Its rasterizer draws any size with a work row as wide as the glyph, in bands of rows. A caller that compiles nothing calls the library module `text_shaping`, which takes the spacing of a glyph cache; the module with the font outlines as bytes is a coming step. It is not a service: no process asks another for a glyph.

The design: `src/md/features/text_rendering.md`.

Do not use: font engine, text service, font server.

### Text size token

A text size token is a named text size of the design rules, in logical pixels: `text_caption` 14, `text_body` 16, `text_heading` 24, `text_large` 32 and `text_largest` 48.

It is the design of the coming steps. The desktop and the elements of the interface package draw their texts at these sizes only, so the texts of two windows line up; a process can draw any text size. 14 is the smallest size at which both fonts keep an x-height of 6 whole rows. Example: the caption of a card is `text_caption`, its one number `text_large`.

The design: `src/md/features/text_rendering.md`, "The text size tokens".

Do not use: type scale, font size token.
