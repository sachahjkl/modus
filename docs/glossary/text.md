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

### Wide character

A wide character is a character that takes two cells of a grid of cells: a CJK ideograph, a kana, a syllable of Hangul, a fullwidth form.

Its width is a fact of the character, its East Asian Width (Unicode Standard Annex 11), never of its glyph: `text_rendering.cell_width_of` gives `Two` for it, `Zero` for a combining mark, `One` for each other character. In the terminal, its first cell is its lead, which holds it, and the second its trail, which draws nothing; a write over one half clears the other. Example: `日本` takes four cells.

The design: `src/md/features/glyphs_on_demand.md`, "Characters of two columns".

Do not use: double-width character, full-width cell, wcwidth.

### Font

A font is a set of glyphs of one design, with the measures that place them side by side.

The modus tool subsets each font file, and the boot image holds the subsets as the font outlines; each process draws each glyph of its text from them. The system has three fonts: Paper Mono, the monospace font of the cells; B612, the interface font; and Spleen 8x16, a bitmap font, the fallback with no valid font outlines. A font here is one file of one weight: Paper Mono SemiBold is a font of its own.

The design: `docs/FONTS.md`, "6. The font file".

Do not use: typeface (for this), font face.

### Glyph

A glyph is the form of one character in one font.

The character is the number (the byte 0x30 is the character `0`); the glyph is the drawing of it. One character can have several glyphs in one font: Paper Mono has a plain zero and a slashed zero, and a font feature chooses between them. A glyph has an outline and an advance; drawn, in the private glyph cache, it is a box of words of coverage. A character takes the glyph of the first font of its fallback chain that has it, else the replacement glyph.

The design: `src/md/features/text_rendering.md`.

Do not use: character (for the form), symbol.

### Outline

An outline is the set of closed contours of line segments and quadratic curves that bound a glyph or a pointer shape, in units of its font or of its design size.

The outline is what a TrueType font stores in its table `glyf`: points in units of the font, each on or off the curve. The renderer of `src/library/modus/vector_font` cuts each curve into segments, scales the points to the grid, applies the grid fit, and accumulates the coverage of each pixel in fixed point. A pointer shape of the theme of the system is also an outline, written in its pointer manifest, and the same renderer draws it. The modus tool reads no outline of CFF (cubic curves) and no SVG file.

The design: `docs/FONTS.md`, "4. Fixed point".

Do not use: path, vector shape, Bézier.

### Coverage

Coverage is the part of a pixel, or of a third of a pixel, that a glyph covers, from 0 (none) to 255 (all).

The renderer computes the coverage of each third of each pixel from the outline. A drawn glyph keeps one word for each pixel: the coverage of the red, green and blue subpixel band, and the coverage of the whole pixel for grayscale. The blend mixes the color of the text with the pixel under it, channel by channel, in linear light. Coverage is not an alpha of a picture: an alpha is one premultiplied value for the whole pixel, and coverage is one value for each band.

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

A glyph cache was a file that held the glyphs of one font already drawn, at each scale of the grid; it left the system.

The boot image held five, and the candidate fonts and the tests of the blend drew from one. Each glyph now comes from a face: a process draws it from the font outlines into its private glyph cache, a candidate font draws through the face of the cells of a font set of its own, and the golden hashes of the faces prove the pixels. The word names only that file of before; the cache of a process is the private glyph cache.

The design: `docs/FONTS.md`, "5. The glyph cache".

Do not use: atlas, texture cache, glyph bitmap.

### Added character

An added character is a character past U+00FF that each font of the system draws, named one by one in a list of the contract `font_characters`.

The fonts hold two ranges, ASCII 32 to 126 and the Latin-1 Supplement, and the added characters. Today the list `font_characters.added_characters` holds the euro sign U+20AC alone, which AltGr with `e` types on the layout of France. A character joins the list only if each font of the system has a glyph for it, and each change of the list moves the character index of each character after it. The build refuses a font that lacks one: no font draws it with the glyph of another character.

The design: `src/md/data/text_encoding.md`.

Do not use: extra character, extended range.

### Character index

A character index is the number of a character in each table of a font of the system: 0 to 94 for the characters 32 to 126, then 95 to 190 for U+00A0 to U+00FF, then 191 and up for the added characters.

The fonts hold these two ranges and the added characters, so the numbers name each character that a font draws, with no hole: the control characters 127 to 159 have none. The Spleen data, a placed glyph and the subsets of the fonts key by it. `font_characters.character_index` gives the number of a code point, and `font_characters.character_of_index` the code point of a number. Another code point has no character index: it is a glyph of its fallback chain, or the replacement glyph.

The design: `src/md/data/text_encoding.md`.

Do not use: glyph id (for this), glyph number, character offset.

### Font outlines

The font outlines are one resource of the boot image that holds the font files of the system, from which each process draws each glyph of its text.

The resource is `font_outlines` (`src/library/modus/contract/font_outlines`): a header, one record for each font with the BLAKE3 hash of its file, then the font files of the faces. The root service checks its hash once and maps it read-only at the fixed range `Font_Outlines` in each process with a surface, each terminal and the compositor. A process validates its header once. The font outlines are not a glyph cache: they hold outlines, not drawn words.

The design: `src/md/features/text_rendering.md`.

Do not use: font bundle, font pack.

### Fallback chain

A fallback chain is the list of fonts, in order, that give the glyph of a character of a face: the first font of the list that has the character gives its glyph and its advance.

The chains are data, one row for each script (`text_rendering.scripts`): Greek, Cyrillic, the box-drawing characters and the block elements, and a default chain for each other character. The first font of each chain is the first font of the face, and a glyph of another font stands on its baseline, with its capitals as high. A character that no font of its chain has draws the replacement glyph. The chain of the interface is B612, Paper Mono, then Noto Sans; the chain of the cells is Paper Mono, B612, then Noto Sans.

The design: `src/md/features/glyphs_on_demand.md`, "The fallback chain by script".

Do not use: font stack, font fallback list.

### Private glyph cache

The private glyph cache is the memory where a copy of the text rendering module keeps the glyphs that it drew, which no other process reads.

A glyph is drawn at its first use and kept, by its face, font, glyph index, text size and position: 1 MiB of words and 4 096 entries at most. A new glyph that finds no room evicts the glyphs of the oldest frames, never one of the frame in progress; past that it is drawn and not kept. The budget of the process pays for it. It holds no advance. It is not shared, so it tells no process what another draws.

The design: `src/md/features/text_rendering.md`, "The cache".

Do not use: glyph atlas, local cache, per-program cache.

### Setting

A setting is one choice of the principal of the machine that each process follows: the font, the order of the subpixel bands, the pointer theme, the grid fit, the layout of the keyboard, the appearance or the time zone.

Each setting is one value of the settings page, with 0 as its default: `font`, `subpixel_order`, `pointer_theme`, `grid_fit`, `keyboard_layout`, `appearance`, and `time_zone`, a fixed offset from UTC. The process `settings` is the one writer: its window, `settings.set(keyboard_layout = .french)`, `settings.set_time_zone(zone)`, and the getters, `settings.font()`. A caller that does not act for the principal gets `No_Grant`. A change takes effect while processes run, and the values survive a stop in the private store of `settings`. A setting is not a configuration file of one process, and the scheduling strategy is not a setting.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: preference, option, configuration.

### Language tag

A language tag is the name of a language in the form of BCP 47 (RFC 5646): a language, with its script and its region when they matter.

A language tag names the language of a display text in a module file. The languages are an open set, so a tag is a text that keeps a syntax, not an enum. A file stores each tag in its canonical case, and a reader compares tags with no regard to case. A reader that has no text for a tag tries a shorter tag, then `en`.

Example: `en`, `fr-CA`, `zh-Hant-TW`, `sr-Latn`.

The design: `src/md/features/enum_parameters.md`, "The display text of a member".

Do not use: locale, language code, language enum.

### Dead key

A dead key is a key of a layout of the keyboard that gives no character itself, and puts its accent on the character of the next key.

The layout of France has four: the circumflex and the diaeresis on the key right of P, and the tilde and the grave accent with AltGr. `^` then `e` gives ê, because the words of French need accented letters that the keyboard has no other key for. A space after a dead key gives the accent alone; a key with no accented form gives the accent, then its own character. The input service keeps the accent that waits; the tables are in `src/library/internal/input/keyboard_layout`.

The design: `src/md/features/keyboard_layout.md`.

Do not use: compose key (for this), accent key, modifier (for this).

### AltGr

AltGr is the right Alt key of the keyboard, which gives the third level of the layout of France: a third character of a key, after the character without Shift and the character with Shift.

With the layout of France, AltGr with the keys of the row of the digits gives the characters that an AZERTY keyboard prints on their right side, as `#`, `{` and `@`; with the key of `e` it gives the euro sign €. AltGr with the key of 2 or of 7 is a dead key. The left Alt key, and Control with Alt, are not AltGr. With the layout of the United States, AltGr changes no character. The key record carries the character of the third level, and no modifier bit of AltGr.

The design: `src/md/features/keyboard_layout.md`.

Do not use: Option, level-3 shift, compose key (for this).

### Settings page

The settings page is the one page of memory that holds the current value of each setting, which each process with a surface reads.

The root service creates the page. The process `settings` receives it with Write; each process with a surface, each terminal and the compositor map it read-only at the fixed range `Settings_Page`. The page holds the choices and the appearance in force only: no address, no size and no hash of a font file, so its writer cannot point a process at memory that it controls. A reader reads again while the change count is odd. It is not a registry and not a file: a record in the store of `settings` survives a stop.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: registry, config file, dconf.

### Appearance

An appearance is one value of each color token: the desktop has two, dark and light.

The dark appearance is the one of the boot display: light text on a dark background. The light appearance is the light form of the site: dark text on a light background, white cards, each concept at a darker shade of its accent. The setting `appearance` chooses `dark`, `light`, or `auto`: the light appearance from 07:00 to 19:00 of the local time and the dark one at night. A picture keeps its pixels in both, and the boot display is always dark.

The design: `src/md/features/appearance.md`.

Do not use: theme (for this: a pointer theme is a set of pointer pictures), dark mode, light mode, skin.

### Appearance in force

The appearance in force is the appearance, dark or light, that each process draws now.

It is one word of the settings page. With `dark` or `light` it is that value; with `auto` it is the rule of the day (`src/library/internal/settings/appearance_rule`) over the date page. The process `settings` is its sole writer: on value changes, date-page changes, and at 07:00 and 19:00 local time. A process reads it at each frame through `src/library/modus/display`, which gives it to `graphics.appearance_use`; the compositor sends `Settings_Changed` to each window when it changes, so each window draws once.

The design: `src/md/features/appearance.md`.

Do not use: current theme, active mode.

### Color token

A color token is a named color of the design rules that has one value in each appearance: a surface, a concept or a part of the desktop.

`graphics.Color_Tokens` holds each token; `graphics.colors` holds their values in the appearance in force of a process, so a drawer writes `graphics.colors.text` and draws the text of the dark or of the light appearance. The `DARK_` constants of the package are the values of the dark appearance, for constant tables and for what is always dark (the boot display, the mark). White, black and the ink of a text on white are not tokens: they are the same in both appearances.

The design: `src/md/features/appearance.md`, and `src/library/modus/graphics/rules.odin`.

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

B612 has 19 different advances in ASCII, and all its digits have one advance, so a column of numbers aligns in it too. Its Bold weight has scale 1 only, for titles. A process uses it through `src/library/modus/interface`: an element that names or explains draws a `Text` record in the interface font, which text shaping places and the faces `Interface` and `Interface_Bold` draw. If the font outlines lack B612, or if the setting `font` is `spleen`, each element draws in the font of the cells.

The design: `docs/FONTS.md`, "12. The interface font and the text shaping module".

Do not use: UI font, system font (for this), sans.

### Interface text

An interface text is a text that a draw table draws in the interface font: the draw record `Text` whose font is `Interface`.

Its rectangle is the measured box of the text widened by the ink margin on each side, so the damage of the record covers every pixel of its ink. Its origin is `text_origin_thirds` thirds of a pixel (0, 1 or 2) after `x` and the margin, so a label can start between two pixels. The table shapes the text and draws its placed glyphs with `graphics.text_proportional`. A text in the font of the cells is the same record with the font `Cells_8x16`, its origin the left edge of its box.

The design: `docs/FONTS.md`, "12.5 What changes in `src/library/modus/interface`".

Do not use: proportional text record.

### Font in use

The font in use is the font that actually draws a text of a draw table: the interface font when the table can draw it, else the font of the cells.

A text asks for the interface font, but three things make it fall back: the table has no interface font (an isolated call: the call host maps no font outlines), the setting `font` is `spleen`, or the text is longer than 256 bytes (`INTERFACE_TEXT_LIMIT`). `interface.font_in_use` decides, and both the measure and the draw call it. So a text is always measured in the font that draws it, and an element never passes its box in either font.

The design: `docs/FONTS.md`, "12.5 What changes in `src/library/modus/interface`".

Do not use: effective font.

### Advance

The advance of a glyph is the distance from its origin to the origin of the next glyph, before any pair adjustment.

In a monospace font the advance is one constant: 8 pixels at scale 1. In a proportional font each character has its own: in B612, `i` is 600 units and `M` 1800. Text shaping reads it from the table `hmtx` of the font file at each measure, at the text size, in 1/64 of a pixel, from 0 to one line. The advance is not the width of the ink: a glyph can have ink before its origin or past its advance, and the ink margin covers that difference.

The design: `docs/FONTS.md`, "14.7 The measure from the font file".

Do not use: width (for this), pitch.

### Pair adjustment

A pair adjustment is the change of the advance that a font gives for one pair of glyphs that follow each other.

Some pairs look too far apart with their advances alone: `T` before `o` leaves a gap under the bar of the T, so the font states a negative adjustment for that pair. Text shaping reads the pair from the table `kern` of the font file when both glyphs come from one font, and adds the rounded advance and the rounded adjustment, within half a line. A face of cells has no pairs.

The design: `docs/FONTS.md`, "14.7 The measure from the font file".

Do not use: kerning pair (for this).

### Font feature

A font feature is a named choice of glyph forms that a font offers in its table `GSUB`, by a tag of four letters.

Examples: `zero` (the slashed zero), `ss01` (a stylistic set), `numr` (numerators), `half` (the half forms of Devanagari). A feature leads to one or more lookups, and each lookup changes glyphs. The tool reads `zero` of Paper Mono at the build and draws its glyph for the character `0` in the subset, which holds no `GSUB`. At run time, a process reads the features of the script fonts: the forms of Arabic, and the features of Devanagari through the engine of the lookups.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: OpenType feature (for this), font option.

### Single substitution

A single substitution is a lookup of the table `GSUB` that puts one glyph in the place of another (lookup type 1).

It is the simplest lookup: a coverage table lists the glyphs that it changes, and a delta or a list gives the substitute of each one. The feature `zero` of Paper Mono is one: it puts the glyph `zero.zero` in the place of the glyph of the character `0`. The engine of the lookups reads the other kinds: ligatures and contextual forms.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: glyph swap, alternate.

### Engine of the lookups

The engine of the lookups applies the lookups of `GSUB` and `GPOS` of a font to a buffer of at most 32 glyphs, feature by feature, in stages.

A shaper of a script fills the buffer with one syllable and the features of each glyph, then asks for each stage of its model. The engine reads each lookup type but the cursive one, with the lookup flags of `GDEF`. Its nesting, its steps and its rules tried are bounded. It is not a shaper: a shaper reorders its script. Example: the conjunct द्ध of Noto Sans Devanagari is a chaining lookup that calls a ligature.

The design: `src/md/features/written_shaping.md`, "The engine of the lookups".

Do not use: layout engine, shaping engine, OpenType engine.

### Indic syllable

An Indic syllable is the unit that the shaper of the scripts of India shapes at once: consonants joined by viramas, then their vowel signs and their modifiers.

An independent vowel starts a syllable of its own, and a sign with no consonant before it stands on a dotted circle. The shaper reorders the glyphs of a syllable (the reph after its base, the vowel sign ि before it), so a placed glyph of a syllable can stand before the glyph of a character that comes before it in the text. A syllable holds at most 16 characters. Example: नमस्ते is three syllables, न, म and स्ते.

The design: `src/md/features/written_shaping.md`, "Devanagari".

Do not use: akshara (for this), cluster (for this), grapheme.

### Feature variation

A feature variation is a record of a table `GSUB` or `GPOS` 1.1 that puts another feature table in the place of a feature, at the coordinates of a variable font that its conditions name.

The system draws the default instance of a variable font, so the walk of the features takes the first record whose conditions hold at the default coordinates. Example: Noto Sans Oriya gives its feature `rclt` an empty table and its lookups through a feature variation, so ka takes its other form only through it.

The design: `src/md/features/written_shaping.md`, "The scripts of India".

Do not use: feature substitution (alone), variable feature.

### Slashed zero

The slashed zero is a zero with a stroke at an angle inside it, so that it does not look like the capital O.

The plain zero of Paper Mono has the same contours as its capital O, and a reader of a hash or an address cannot tell `0` from `O`. So the character `0` of the system is the slashed zero of Paper Mono: the modus tool reads the font feature `zero` and draws its substitute for `0` in the subset. Each picture of the system with a 0 shows it.

The design: `docs/FONTS.md`, "Paper Mono, the font of the system".

Do not use: crossed zero, zero with a slash.

### Text shaping

Text shaping is the step that turns the characters of a text into placed glyphs, with the advances and the pair adjustments of one font.

A proportional text needs it: the x of each glyph is the sum of the advances and adjustments before it. The package `src/library/modus/text_rendering` does it for a direct call, and the library module `text_rendering` exports the same work over the font outlines of its caller: `shape_text` gives the placed glyphs of one text, `measure_texts` the width of many text ranges in one call, and `break_text` the lines of a text in a box. Text shaping here does advances and pairs only: no ligature, no other script.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: layout (for this), typesetting.

### Placed glyph

A placed glyph is a record of 16 bytes that text shaping gives for one character: the glyph, its x from the origin of the run, and its advance.

The fields of `text_rendering.Placed_Glyph` are `glyph` (the character index, a glyph of the fallback chain, or `REPLACEMENT_GLYPH`), `x` from the origin of the text and `advance` with the pair adjustment that follows it, both in 1/64 of a pixel, and `cluster`, the first byte of the character in the text. `graphics.text_proportional` draws a table of placed glyphs: it rounds each x to the nearest subpixel position. The x keeps the exact sum, so the rounding of one glyph never moves the next one.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: positioned glyph, glyph run entry.

### Ink margin

The ink margin is how far the ink of a text of a proportional font can pass the box that its measure gives, on each side: 2 pixels at scale 1 for B612.

A measure gives the sum of the advances, but ink can start left of the first origin (`j`) and pass the last advance (`K` in Bold), and the subpixel filter spreads it. The damage of a `Text` record in the interface font is its measured box widened by `graphics.PROPORTIONAL_INK_MARGIN`, so a frame drawn in its damage equals a whole frame. The margin is a bound measured for B612: another interface font needs its own.

The design: `docs/FONTS.md`, "12.8 The parts, each one working".

Do not use: bleed, overhang (for this).

### Subpixel position

A subpixel position is the fraction of a pixel where a glyph starts: 0, 1/3 or 2/3 of a pixel for a glyph of a proportional face.

A glyph of a proportional font rarely starts on a whole pixel. With subpixel bands, the finest step that the screen shows is one third of a pixel, so a proportional face draws each glyph at three positions, at each size. The draw rounds the x of each placed glyph to the nearest third (`text_rendering.position_of`): the error is at most 1/6 of a pixel and does not add up along a text. A face of cells has one position.

The design: `src/md/features/text_rendering.md`, "The rasterizer".

Do not use: subpixel offset, bucket.

### Spacing

The spacing is what text shaping places a text with: a face at a text size over a set of opened fonts, or one advance for each character of a grid of cells.

`text_rendering.spacing_of(face, size)` gives the spacing of a face over the fonts that the process opened, and refuses the face `None`, a size out of its range, and a face whose first font is not open. The library module opens a set from the bytes of its caller for one call. A spacing holds no table of advances: each number comes from the font file at each measure. It is not the spacing tokens of a layout.

The design: `docs/FONTS.md`, "14.7 The measure from the font file".

Do not use: metrics (for this), kerning data.

### Text range

A text range is a record that names one text in a table of bytes by its first byte and its count, with its width, which the measure writes.

`text_rendering.Text_Range` has 16 bytes: `start`, `count` (at most `TEXT_LIMIT`) and `width` in 1/64 of a pixel. A window passes all its labels as one table of bytes and one table of ranges to `measure_texts`, which writes the width of each range: one call measures a whole frame (the direction Change of a table parameter). `break_text` appends one text range for each line of a text.

The design: `docs/FONTS.md`, "12.3 The text shaping module".

Do not use: span (for this), slice.

### Boot pass

The boot pass is the start of the process `settings` that the root service makes at the start of the machine, with no window, to put the kept settings on the settings page.

The settings survive a stop as one record (`Kept_Settings`) in the private store of `settings`. The root service cannot read the store itself, so it starts `settings` with the pass `Boot` at `VALUE_PASS` of its context. The process reads the record, writes the page, wakes the compositor and stops. A record of another version, or none, gives the defaults. Until the boot pass ends, the boot display and the first frames use the defaults; then each window draws again.

The design: `docs/FONTS.md`, "7. The setting".

Do not use: init script, startup hook.

### Blend table

A blend table is the results of the blend in linear light of one text color over one pixel color, for each coverage of each channel, kept in the memory of a process.

The blend of a partial pixel costs two squares and a square root for each channel. For one text color over one background color, each channel of the result depends on its coverage only: 3 x 256 values. A process keeps a few such tables (`graphics.Blend_Tables`), and fills a value on first use with the formula of the reference blend. A row of a glyph whose two end pixels have one color uses the table of that color. The result is the same bytes as the reference blend.

The design: `docs/FONTS.md`, "Where the time goes, and the fast blend".

Do not use: lookup table (alone), LUT.

### Markdown block

A Markdown block is one unit of the Markdown of a source comment that stands on its own rows: a paragraph, a list item, a fenced block or an example.

The reader of the system (`src/library/internal/manual/source_comment_markdown`) gives the blocks of a documentation text in order. A block is a range of bytes of that text, with its kind. A list item has its mark and its depth, a fenced block has the word after its opening fence, and a block says whether an empty line is before it. The Markdown spans of a block follow it. Example: `manual` starts a row for each block, and draws a band behind a fenced block. It is not a block of storage.

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

A text size is the height of the line of a face, in 1/64 logical pixel, which a process gives to measure and draw a text.

A line of 16 logical pixels is the size 1 024. A text record and a text grid carry it; the border of the record takes a line of 4 to 128 logical pixels and refuses another. The text rendering module draws it at the scale. A label and its value at one text size share one line. It is not an em, not a size in points and not a scale factor.

The design: `src/md/features/text_rendering.md`, "The text size".

Do not use: font size (alone), point size, scale (for this).

### Frame of a face

The frame of a face is the rule that turns a text size into the units of the first font of a face.

In a face of cells the advance of the font is half the line; in a face of the interface the cap height is 10/16 of the line. At a line of 16 pixels each frame gives the scale of today. A glyph of a fallback font is drawn in the frame of the first font of its face, on its baseline. It is not the line box of a text.

The design: `src/md/features/text_rendering.md`, "The text size".

Do not use: font metrics (for this), em box.

### Face

A face is a first font with its frame, its weight and its grid fit, from which each glyph of a text comes.

The faces are `Interface`, `Interface_Bold`, `Cells`, `Cells_Without_Grid_Fit` and `Cells_Bold` (`text_rendering.Face`), each with its fallback chain. A glyph of another font of the chain stands in the frame of the first font: in its cell for a face of cells. A process draws a face once its font outlines hold its first font (`text_rendering.face_opened`). A face is not a font file: two faces can share one.

The design: `src/md/features/text_rendering.md`, "The faces".

Do not use: font face (for this), font slot, typeface.

### Text rendering module

The text rendering module is the support package `text_rendering` and its library module, which shape, measure, break, keep and draw a text at any text size.

Each process compiles the measure in, its fast part; the drawing module compiles the draw and the private glyph cache in. Its rasterizer draws any size with a work row as wide as the glyph, in bands of rows. A caller that compiles nothing calls the library module `text_rendering` with the font outlines as bytes, a face and a text size. It is not a service: no process asks another for a glyph.

The design: `src/md/features/text_rendering.md`.

Do not use: font engine, text service, font server.

### Simple character

A simple character is a character that the fast part of the text rendering module places alone, as the written part would place it.

Its script is Latin, Greek, Cyrillic or Common, its combining class is 0, and it is no mark, no format character, no control and no character of right to left; it joins nothing. `modustool unicode_tables` writes them as one table (`simple_ranges`). A text of simple characters that the fonts of the boot image draw is a simple text. For example, `Settings` and `€ 12,50` are simple texts, and `e` followed by U+0301 is not.

The design: `src/md/features/text_rendering.md`, "Where the written shaping lives".

Do not use: easy character, Latin character, ASCII text.

### Fast part

The fast part is the part of the text rendering module that each module that draws text compiles in: it places a simple text and draws each glyph.

It holds the faces of the boot image, their chains, the character map, the advances, the pairs of `kern`, the line breaks, the rasterizer of `glyf` outlines and the private glyph cache. A line that is not simple goes to the written part, in one call for the line. The fast part never shapes a script of the script font set.

The design: `src/md/features/text_rendering.md`, "Where the written shaping lives".

Do not use: static part, light renderer, basic shaper.

### Written part

The written part is the part of the text rendering module that places every text that is not simple, and reads the script font set.

It holds the clusters and their compositions, the shapers of Arabic, Thai and the scripts of India, the engine of the lookups, the order of a line of mixed direction, the script font set with its caches, and the reader of CFF. The library module `text_rendering`, the drawing module and the root service compile it in; each other module calls the library module for it, over the fonts of its process. The define `WRITTEN_SHAPING_COMPILED_IN` chooses it at compile time.

The design: `src/md/features/text_rendering.md`, "Where the written shaping lives".

Do not use: complex part, slow path, full shaper.

### Text size token

A text size token is a named text size of the design rules, in logical pixels: `text_caption` 14, `text_body` 16, `text_heading` 24, `text_large` 32 and `text_largest` 48.

A token times 64 is the text size of a record. The desktop and the elements of the interface package draw their texts at these sizes only, so the texts of two windows line up; a process can draw any text size. 14 is the smallest size at which both fonts keep an x-height of 6 whole rows. Example: the caption of a card is `text_caption`, its one number `text_large`, the page heading of `manual` `text_heading`.

The design: `src/md/features/text_rendering.md`, "The text size tokens".

Do not use: type scale, font size token.

### Caption

A caption is a short text at the text size token `text_caption`, in the dim color, that says what a text or an element beside it is.

The caption of a card names its record, on the baseline of the title. A label under a value is a caption under its line (`interface.draw_caption`), with no gap. The help line of the chosen row of the palette, and the hash prefix after a nickname, are captions too. A caption keeps the contrast of a text, 4.5 to 1, on each surface of a card. It is not the title of a window: that is the title bar.

The design: `src/md/features/text_rendering.md`, "The text size tokens".

Do not use: small print, fine print.

### Page heading

A page heading is the title of a page of a window, at the text size token `text_heading`, over the content of the page.

`manual` gives each page a page heading: the name of a module, the title of a link page, "All the modules". It is not a row of the page: it stays when the rows move, and it takes whole rows of the column, so each row keeps one height. A page heading wider than its box goes on more lines (`interface.draw_heading`); it is never cut. It is not a heading of a guide, which is a line of Markdown.

The design: `src/md/features/text_rendering.md`, "The text size tokens".

Do not use: page title, masthead.

### Language tag

A language tag is the name of a language and of its conventions in the form of BCP 47: `fr`, `fr-CA`, `ar-EG-u-nu-latn`.

The principal writes it as text, and one border reads it into a locale record: the console with `language("fr-CA")`, the export of `settings`, the tool. The border follows RFC 5646 and UTS #35 part 1, writes the canonical form, and refuses a private use subtag, the extension `t` and a keyword of `u` outside the closed set. No process reads the text of a tag that another wrote. A language tag is not a keyboard identifier and not a time zone.

The design: `src/md/features/interface_language.md`, "1. The identity of a language".

Do not use: language code, LANG, culture, locale string.

### Locale

A locale is the record of 48 bytes that holds a language tag in its typed form: a language, a script, a region, variants, and the keywords of the extension `u` as enums.

`language_tag.Locale` crosses each border in place of the text of a tag. The keywords are the calendar, the numbering system, the first day of the week, the hour cycle, the measurement system, the collation and the region override; each is an enum with 0 for absent. All zeros is the root locale, `und`. The language list and a language pack hold locales. A locale is not the time zone: the setting `time_zone` holds the offset.

The design: `src/md/features/interface_language.md`, "1. The identity of a language".

Do not use: culture, regional settings, locale identifier (for the record).

### Language list

The language list is the setting that holds the languages that the principal reads, in its order: at most 8 locales.

The process `settings` writes it on the settings page: its row "languages", or `settings.set_languages([language("fr"), language("en")])`. For each interface message, a reader takes the first language of the list, then its parents, that holds a valid translation; else the source language, English. An empty list is English. The keywords of its first locale, such as the hour cycle, apply to each text. It is not a list of the languages that the machine holds: those are its language packs.

The design: `src/md/features/interface_language.md`, "1. The identity of a language".

Do not use: preferred languages, LANG, LANGUAGE.

### Interface message

An interface message is a text of the interface with typed variables, written in Unicode MessageFormat 2.0, that a reader renders in its language.

A package names each of its interface messages by a member of its enum `Interface_Message`; the variables are the fields of one record type, as for a log fact. Its source text is English, in `messages/en.mf2`, and the tool compiles it into the tables `Interface_Messages` and `Interface_Message_Parts` of the module file; no process parses it. A translation has its own selectors for plural and gender. It is not a message of TLS, of a signature or of an interrupt.

The design: `src/md/features/interface_language.md`, "2. Interface messages".

Do not use: message (alone, for this), string (for this), resource string, translation key, gettext.

### Message resource

A message resource is a file of the interface messages of one language for one package, in the format `.mf2` that the W3C Internationalization WG incubates.

It starts with `@locale` and holds one `identifier = message` for each interface message, in the syntax of UTS #35 part 9. The source resource of a package is `messages/en.mf2`, beside its source; a translation is `messages/fr.mf2`. The tool reads it at the build only, in the form of the draft of 2026-10-07, which it pins. It is not a file that a process reads, and not a language pack, which holds the compiled form.

The design: `src/md/features/interface_language.md`, "2. Interface messages".

Do not use: catalog, .po file, .ftl file (for this), strings file.

### Interface message key

An interface message key is the number that names one interface message across modules and language packs: SipHash-2-4 of `<package>.<identifier>`.

It uses the key of the fact keys, so the tool computes it from the source. A row of a language pack names its interface message by this key and by the source hash, the BLAKE3 of the compiled source. When the English changes, its source hash changes, and the old translation falls back alone. The key is a name, not the value of a member, so a new member moves no translation.

The design: `src/md/features/interface_language.md`, "2. Interface messages".

Do not use: message key, string id, message number, msgid.

### Language pack

A language pack is a data object that holds the translations of one language and its locale data, named by the hash of its bytes.

The tool builds it from the message resources of a language and from a pinned CLDR. A pack of the boot image is in the signed system description; a pack from the cache is named in the plan of a principal. `language_pack.validate` checks it whole before the machine takes it. The root service maps the packs of the session read-only at the range `Language_Packs` of each process at its start; a new pack reaches a process at its next start. It holds no code, and a translation changes no module hash.

The design: `src/md/features/interface_language.md`, "3. Language packs".

Do not use: translation file, language bundle, locale package, language module.

### Locale data

Locale data is the tables of CLDR for one locale that a reader needs to write a text: plural rules, numbers, dates, units, lists and the names of languages.

The tool reads them from the XML of a pinned release of CLDR, a recipe input, and writes typed tables in a language pack. A plural rule becomes conditions on integers. No process reads XML or JSON. The locale data of one locale is about 25 to 40 KiB, an estimate to measure; its source in CLDR 49 is 338 KiB of JSON for `fr`.

The design: `src/md/features/interface_language.md`, "4. Locale data".

Do not use: CLDR data (for the compiled tables), ICU data, locale database.

### Plural category

A plural category is one of the six forms that CLDR gives a number in a language for the words around it: `zero`, `one`, `two`, `few`, `many`, `other`.

The plural rules of the locale give the category of a number from its operands: the value and the digits that the render writes. English puts 1 in `one`; French puts 0 and 1 in `one`; Arabic uses all six. An interface message selects a variant by the category, so a count reads "1 block" and "2 blocks". An ordinal has its own rules ("1st", "2nd").

The design: `src/md/features/interface_language.md`, "2. Interface messages".

Do not use: plural form (for this), quantity.

### Grapheme cluster

A grapheme cluster is the text that a reader sees as one character: one or more code points, found by the rules of UAX #29.

é written as `e` then U+0301 is two code points and one grapheme cluster; a flag of two regional indicators is one too. The line editor moves, deletes and selects by grapheme cluster, and a line break falls between two of them. The cell of a text grid holds a code point, so a cluster of several code points needs the shaping of its script.

The design: `src/md/features/interface_language.md`, "5. Text processing".

Do not use: character (for this), letter, glyph (for this).

### Combining mark

A combining mark is a character that draws on the character before it, its base: an accent, a dot below, a vowel sign of Hebrew or Arabic.

The shaper reads a base and its marks as one cluster. It composes them by the compositions of Unicode when a font draws the result: `e` then U+0301 is é. A mark that does not compose is a placed glyph with the advance 0, placed by the mark anchors of its font, else centred on its base. A mark with no base, at the start of a text or after a space, stands on a dotted circle (U+25CC). In a grid of cells a mark takes no cell.

The design: `src/md/features/written_shaping.md`.

Do not use: accent (for this), diacritic (for the character), zero-width character.

### Joining form

A joining form is the shape that a letter of Arabic takes by its neighbours: isolated, initial, medial or final.

The shaper gives each letter its form from its joining type (Unicode) and the joining types of the letters on each side; a mark or an invisible format character between two letters does not break the join. The form is the substitution of the font: Noto Sans Arabic makes beh a dotless body and its dot, then the form of the body. A font that makes no form takes the presentation form that Unicode names. Lam then alef is one glyph, their ligature. Example: in بيت the beh is initial, the yeh medial and the teh final.

The design: `src/md/features/written_shaping.md`.

Do not use: contextual form, positional form, glyph variant.

### Line direction

The line direction is the order on the screen of the runs of one line that mixes left-to-right and right-to-left text, by the rules of UAX #9.

The first strong letter of the text, outside any isolate, gives the direction of the line; each run of the other direction is reversed in place, numbers keep their order, and a bracket in a right-to-left run draws its mirrored glyph. An isolate (LRI, RLI or FSI to PDI) is one unit of the line around it, with its own direction inside; its controls draw nothing. The placed glyphs stay in the order of the text; only their x changes. Example: `abc אבג 123` shows a b c, then 1 2 3, then ג ב א.

The design: `src/md/features/written_shaping.md`.

Do not use: bidi (alone), RTL mode, visual order (for the text).

### Mark anchor

A mark anchor is a point that a font gives a glyph, where a mark attaches: the anchor of the mark falls on the anchor of its base, or of the mark before it.

The table `GPOS` of a font holds them (the features `mark` and `mkmk`). The shaper places each mark of a cluster by them, with an x from the origin of its base and a y above the baseline; a mark that no anchor places is centred on its base. The dots of a letter of Arabic, the points of Hebrew and the tone marks of Thai stacked on a vowel are placed so. Example: in ก่ำ the tone mark sits on the NIKHAHIT of SARA AM, which sits on ก.

The design: `src/md/features/written_shaping.md`.

Do not use: attachment point (for this), mark offset, diacritic position.

### Script font set

The script font set is the fonts of the scripts that the boot image lacks, one data object that a plan names by its hash and that a process opens at a fixed range.

It holds fifteen whole Noto fonts, Arabic, Thai, nine scripts of India and CJK among them, 40.0 MB. `modustool script_fonts` writes it; the boot image names it by the resource `script_fonts_name`, and the plan of principal 0 can name another. On a machine it is an object of the store `script_fonts`; the root service reads it when the machine is usable, checks its hash, and maps it into each process that starts after that. A process with no set draws the replacement glyph for those scripts, and nothing waits for the set.

The design: `src/md/features/script_fonts.md`.

Do not use: font pack, font download, extra fonts.

### Collation

A collation is the order of texts that a reader of one language expects, from the Unicode Collation Algorithm, the root order of CLDR and the tailoring of a locale.

`sort(name, language = language())` sorts by the collation of the first language of the principal; `sort(name)` keeps the order of code points, the same on every machine. Swedish puts ä after z, and `fr-CA` compares accents from the end. A comparison at the primary strength ignores case and accents: `matches(name, "ete", language())`. A collation is not a comparison of bytes.

The design: `src/md/features/interface_language.md`, "5. Text processing".

Do not use: locale order, natural sort, strcoll.

### Input method

An input method is a process with a grant that turns keys into text through a composition and a candidate window, for a script with more characters than keys.

When a text field in focus asks for it, the compositor sends the keys to the input method in place of the window. The input method sends back a composition, a commit and the place of its candidate window, its own surface at the caret. The window receives text events, not keys. A field of a passphrase asks for none. A layout of the keyboard is not an input method: it maps one key to one character.

The design: `src/md/features/interface_language.md`, "7. Input".

Do not use: IME (alone), input editor, input source.
