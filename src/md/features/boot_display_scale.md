# The boot display at the scale of the screen

The boot display ([`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md)) is laid out in logical pixels: a panel of 976 × 708. On the reference screen of 1920 × 1080 it filled about half of the screen at scale 1. Now it takes one scale factor from the size of the screen, keeps its proportions, and draws every element at that scale. It is the first user of the scale factor of the reference screen ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"), and it keeps the two rules that that design fixed: a scale in eighths, and each edge rounded once to the nearest screen pixel, a half up.

## The constraints

- The panel keeps its rectangular look: the aspect ratio of 976 × 708 never changes, and it is never stretched to the screen.
- The boot program draws it. It is freestanding, has no allocator, and holds no glyph cache: Spleen 8x16 is the one font of its binary.
- No text lies over another text, and no text leaves its box, at each scale.
- Three drawers draw one picture: the boot program, the root service and the process `boot`. Each must find the same scale for the same screen.

## The scale

`bootscreen.display_place` is a pure procedure of the width and the height of the screen. It gives the scale in eighths and the place of the panel.

- **The rule.** The scale is the largest count of eighths from 10 (1.25) to 16 (2) such that the scaled panel and a margin of 8 screen pixels on each side fit the width and the height. The panel is in the middle of the screen. 1920 × 1080 gives 12 (1.5): a panel of 1464 × 1062, 9 pixels from the top. 3840 × 2160 gives 16, the top of the range.
- **No scale of the range fits.** The scale is 8 (1), the look of before: a screen of the base size or larger, up to the first size that holds 1.25, has the panel at scale 1 in its middle. 9 eighths is not a scale: the range of the scale factor starts at 10, and a scale of 1.125 makes a cell of 9 pixels with no glyph and no grid of 8 on whole pixels.
- **Below the base size.** A screen narrower than 976 or lower than 708 still takes scale 1, with the panel at the top left: the screen cuts its right side or its bottom. No layout of the boot display is smaller, and a text below scale 1 is not readable. The boot program says on its line which mode it kept (`mode_choose`), so the cut has a cause on the log.
- **A refused size.** A width or a height of 0 or below gives no place: `ok` is false and nothing is drawn. A framebuffer of that size is not a screen.
- **The rounding.** A logical place `v` is the screen place `(v · s + 4) >> 3` for a scale of `s` eighths, from the top left of the panel: the nearest pixel, a half up, the same rule for a negative place. A rectangle has its two edges rounded, and its size is their difference. So two neighbours that share an edge in logical pixels share it on the screen: no gap of a pixel and no overlap. A rectangle of 1 logical pixel keeps at least 1 screen pixel, as the scale is at least 1.
- **One origin.** Each place is rounded from the top left of the panel, never from the corner of a card. A card gives its content as a logical area, and a place inside it is the place of the area plus the place in it, rounded once. A view rounded at the corner of a card, then again inside it, can move a neighbour by one pixel.

## Every element is scaled

The code of the display keeps its logical places: the margins, the gaps, the cards, the head, the line of the steps, the tube of the line of time, the bars of the memory, the strip and the tiles of the boot image, the bars of the processes, the grid of points. Each drawing procedure of the package (`fill`, `block`, `write`, `card`) takes an area and logical places, and turns them into screen pixels at its one border. A layout that is right at scale 1 is right at each scale, since each place is the same function of the scale.

- **The cards.** The package draws the frame of a card itself, at the scale: the border of 1 logical pixel, the surface, the bar of 4 × 16 and the title. A card reserves at its right the room of the number that the display writes in its title row (the time of the line of time, the count of files, the count of processes), so the caption never reaches it.
- **The mark.** The heron and the name of the mark are cells of whole pixels: a cell of a fraction of a pixel makes two widths of a stroke. The heron takes the largest whole cell inside its logical box of 48 × 48, `2 · s / 8` pixels, rounded down, in the middle of that box; the name takes `3 · s / 8`, rounded down, with its bottom on the bottom of the heron. At 12 eighths the heron has cells of 3 pixels, which fill its box exactly, and the name has cells of 4 pixels in place of 4.5.
- **The text.** A cell of the text is 8 × 16 logical pixels, so `s × 2s` screen pixels: the width of a text is its count of characters times 8 logical pixels at each scale, and the places that the code computes from it stay right.

## The text

The glyph caches exist at the whole scales 1, 2 and 3 only: cells of 8 × 16, 16 × 32 and 24 × 48. A scale of eighths needs cells of 10 × 20 to 15 × 30, and 20 × 40 to 30 × 60 for the large digits of the times.

**The chosen form: the vector outlines at the size of the cell, where the drawer has them.**

- A cell whose width is a whole scale of the caches, 8, 16 or 24 pixels, draws from the glyph cache, or from Spleen at that scale, as before.
- Another cell of 24 pixels or less draws from the outlines of the font of the cells (Paper Mono), at that cell, with the renderer that built the glyph caches (`vector_font.glyph_render`, with the grid fit). It is the glyph that the planned caches of the scale factor will hold: a cell of 12 × 24 at 1.5.
- The drawer gives the font file and the memory of the glyphs (`bootscreen.cell_font_use`). The package draws each glyph at its first use and keeps the rows of its ink, keyed by the cell and the character, until the scale changes. A full memory of the glyphs empties and starts again: a stated limit, which one display does not reach.
- A cell past 24 pixels (the large digits from 13 eighths), and each cell when the drawer gave no font, draws at the largest whole scale of the caches inside the cell, at most 3, in the middle of the cell. This is the rule of Spleen in the design of the scale factor. The text is then smaller than its cell, and never larger, so it stays inside its box.

**Which drawer has which.**

- **The root service** has the outlines: it checks their hash and their format once (`text_settings_create`), takes the font file whose hash the glyph cache of the cells names, and gives it to the package with memory of its own. Its screen at 12 eighths draws the cells and the large digits (24 × 48, scale 3 of the cache) from the vector font.
- **The boot program** gives no font: it draws Spleen at scale 1 in the middle of each cell, at each scale between 1 and 2. Its failure screens come before or at the check of the boot image, when no font file of the image is trusted; it parses no file that it did not check. Its other screens last a few milliseconds before the root service draws. So its cost at the start is the cost of today: no glyph is drawn from outlines, and the fill of the larger panel is the only new work.
- **The process `boot`** draws in a window of the base size: the scale is 1, and its text is the text of the glyph caches, as before.

**Its cost.** The root service draws each character of the display once at each size: about 80 characters of the cells and 15 of the large digits. The renderer takes 3 to 46 µs for one glyph on the host ([glyphs_on_demand.md](glyphs_on_demand.md), "The measures"). The host test `bootscreen.scaled_glyph_measure` prints the time of the glyphs of one display at each scale, and the words that they keep:

```
MODUS_MEASURE_BOOT_DISPLAY=1 odin test src/library/support/bootscreen -o:speed -collection:modus=src/library -define:ODIN_TEST_NAMES=bootscreen.scaled_glyph_measure
```

**The interface font.** The proportional caches of B612 exist at whole scales only, with positions of thirds of a pixel. At scale 1 the root service draws the titles and the names of the facts in B612, as before. At another scale they are in the font of the cells, as the boot program has always drawn them: a text in B612 at an eighth scale needs the advances of its font at that size and its own placed glyphs, which the caches of the scale factor will give.

## The drawers

All three call `bootscreen.draw_screen` with the whole canvas that they own: the framebuffer for the boot program and the root service, the canvas of the window for the process `boot`. `draw_screen` computes the place with `display_place`, fills the screen outside the panel, and draws the panel. So the same size gives the same scale, and no drawer computes a scale of its own.

## The refused forms

- **A stretch to the screen.** A scale on each axis fills 1920 × 1080 and breaks the proportions of the cards, the squares of the processors and the heron.
- **A scale for each element.** A card at one scale and its text at another moves the text out of its box, and two neighbours stop sharing their edges.
- **A picture that is drawn once at scale 1 and then scaled.** A stretched picture of pixels blurs the text, or makes two widths of a stroke with no filter. The display is drawn again at each step, and each draw is at the scale of the screen.
- **The nearest whole scale of the caches for every text.** At 12 eighths a cell of 12 × 24 holds a glyph of 8 × 16: the text is a third smaller than its card, and its letters stand apart. The scale 2 of the caches does not fit the cell: the text leaves its box.
- **The outlines in the boot program.** It reads the outlines only after the check of the boot image, and its screens before that check are the screens that stay. The parser of a font in the trusted path of the start gives nothing that a reader sees.
- **A scale in hundredths, or 9 eighths.** The grid of 8 logical pixels stays on whole screen pixels only at a count of eighths, and the range of the scale factor starts at 10.

## The subtle points

- The scale of a draw is a state of the package, as the order of the channels is: one draw at a time in each drawer. A host test draws the scales one after the other.
- A text measured in cells is measured in logical pixels: 8 for a character. The width on the screen is `s` pixels for a character, exactly, so a text that fits its box at scale 1 fits it at each scale.
- The glyphs of the outlines blend with the tables of the text state of the process (`graphics.text_state`), in the order of the stripes of the screen, as the glyphs of the caches do.

## The state

Built: the scale and the place of the panel, the scaled drawing of every element, the glyphs of the cells from the outlines in the root service, Spleen in the middle of its cell in the boot program, and the host tests of the scale and of the boxes of a draw at 10, 12 and 16 eighths.

Left: the interface font at a scale of eighths, which waits for the glyph caches of the scale factor; the scale factor of the desktop, in its entry of `ROADMAP.md`.
