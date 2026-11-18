# The boot display at the scale of the screen

The boot display ([`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md)) is laid out in logical pixels: a panel of 976 × 708. On the reference screen of 1920 × 1080 it filled about half of the screen at scale 1. Now it takes one scale from the size of the screen, keeps its proportions, and draws every element at that scale. Its text is Spleen, a bitmap font that is drawn for several sizes, and the scale is one of those sizes, as the console of Linux takes a size of its font by the resolution. It keeps the rule of the scale factor of the reference screen ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"): a scale in eighths, each edge rounded once to the nearest screen pixel, a half up. The desktop keeps its own scale in eighths with the outlines ([text_rendering.md](text_rendering.md)); only the boot display takes its scale among the sizes of a bitmap font, and it is not a part of the text rendering module.

## The constraints

- The panel keeps its rectangular look: the aspect ratio of 976 × 708 never changes, and it is never stretched to the screen.
- The boot program draws it. It is freestanding, has no allocator, holds no glyph cache, and reads no file of the boot image before it checked it.
- The display is drawn in cells: each letter fills its cell, with no blur and no letter centered in a larger cell.
- No text lies over another text, and no text leaves its box, at each scale.
- Three drawers draw one picture: the boot program, the root service and the process `boot`. Each must find the same scale and draw the same pixels for the same screen.

## The scale

`bootscreen.display_place` is a pure procedure of the width and the height of the screen. It gives the scale in eighths and the place of the panel.

- **The scales.** A cell of the text is 8 logical pixels, so at a scale of `s` eighths it is `s` screen pixels wide. The scales are the widths of the sizes of Spleen: 8 (8x16, scale 1), 12 (12x24, 1.5), 16 (16x32, 2) and 32 (32x64, 4).
- **The rule.** The scale is the largest of 12, 16 and 32 at which the panel and a margin of 8 screen pixels on each side fit the width and the height. The panel is in the middle of the screen. Else the scale is 1.

| Scale | Panel | The least screen | Screens |
|---|---|---|---|
| 8 eighths, 8x16 | 976 × 708 | any | 1024 × 768, 1366 × 768, and each screen below the next row |
| 12 eighths, 12x24 | 1464 × 1062 | 1480 × 1078 | 1920 × 1080, the reference screen |
| 16 eighths, 16x32 | 1952 × 1416 | 1968 × 1432 | 2560 × 1440, 3840 × 2160 |
| 32 eighths, 32x64 | 3904 × 2832 | 3920 × 2848 | 5120 × 2880, 6016 × 3384, 7680 × 4320 |

- 3840 × 2160 takes 16 eighths: the panel at 32 needs 2832 lines. The boot program asks the firmware for the reference screen, and never for a larger mode (`mode_choose`): on the test machines and on each firmware that has that mode, the scale is 12. The larger scales come when a screen of the boot program is larger, and they cost nothing until then but their tables.
- **Below the base size.** A screen narrower than 976 or lower than 708 takes scale 1, with the panel at the top left: the screen cuts its right side or its bottom. No layout of the boot display is smaller. The boot program says on its line which mode it kept (`mode_choose`), so the cut has a cause on the log.
- **A refused size.** A width or a height of 0 or below gives no place: `ok` is false and nothing is drawn.
- **The rounding.** A logical place `v` is the screen place `(v · s + 4) >> 3` for a scale of `s` eighths, from the top left of the panel: the nearest pixel, a half up, the same rule for a negative place. A rectangle has its two edges rounded, and its size is their difference. So two neighbours that share an edge in logical pixels share it on the screen. At 16 and 32 eighths each place is exact; at 12, a place of an odd count of logical pixels rounds.
- **One origin.** Each place is rounded from the top left of the panel, never from the corner of a card. A card gives its content as a logical area, and a place inside it is the place of the area plus the place in it, rounded once.

## Every element is scaled

The code of the display keeps its logical places: the margins, the gaps, the cards, the head, the line of the steps, the tube of the line of time, the bars of the memory, the strip and the tiles of the boot image, the bars of the processes, the grid of points. Each drawing procedure of the package (`fill`, `block`, `write`, `card`) takes an area and logical places, and turns them into screen pixels at its one border.

- **The cards.** The package draws the frame of a card itself, at the scale: the border of 1 logical pixel, the surface, the bar of 4 × 16 and the title. A card reserves at its right the room of the number that the display writes in its title row, so the caption never reaches it.
- **The mark.** The heron and the name of the mark are cells of whole pixels. The heron takes the largest whole cell inside its logical box of 48 × 48, `2 · s / 8` pixels, rounded down, in the middle of that box; the name takes `3 · s / 8`, rounded down, with its bottom on the bottom of the heron: 3 and 4 pixels at 12 eighths, 4 and 6 at 16, 8 and 12 at 32.

## The text

**Spleen only, in each drawer, at the size of the scale.** The boot program, the root service and the process `boot` draw each text of the display with the same procedure (`spleen_text_draw`), so the same screen gives the same pixels. The titles of the cards and the names of the facts are in Spleen too: the display has one font.

- A cell of the text is the cell of a size of Spleen at each scale: 8x16, 12x24, 16x32 or 32x64.
- A cell of the large digits of the times is twice as wide: the size whose cell it is (16x32 at scale 1, 32x64 at 16 eighths), else 8x16 with each pixel a square of a whole factor that fills the cell (3 at 12 eighths, 24 × 48; 8 at 32 eighths, 64 × 128). `spleen_form_of` gives the form of a cell, and refuses a cell that no form fills; the scales of the display give none.
- A character that the font lacks, and an invalid sequence, draw the replacement glyph.
- No glyph cache and no outline draws the display. At scale 1 the root service and the process `boot` drew it from the glyph cache of the vector font; that cache follows the settings `font` and `grid_fit` of a principal, and it is not in the boot program. Spleen 8x16 is the same in each drawer.

**The data.** The command `modustool font` converts the BDF files of Spleen 2.1.0 of the store (the folder `FONT_SOURCE` of the development shell) into `graphics/font.odin` for 8x16, as before, and into `bootscreen/spleen_sizes.odin` for 12x24, 16x32 and 32x64: one row for each line of a glyph, 16 bits for 12x24 and 16x32, 32 bits for 32x64, the left pixel in the high bit. Each table holds the 192 characters of a glyph cache. Their bytes:

| Size | Bytes |
|---|---|
| 8x16, already in `graphics` | 192 × 16 × 1 = 3 072 |
| 12x24 | 192 × 24 × 2 = 9 216 |
| 16x32 | 192 × 32 × 2 = 12 288 |
| 32x64 | 192 × 64 × 4 = 49 152 |

The boot program and the root service grow by 70 656 bytes of read-only data. The license is the license of Spleen, BSD-2-Clause, and the reuse list names the file. The cost in time is the cost of Spleen 8x16: one test and one store for each pixel of a cell.

## The drawers

All three call `bootscreen.draw_screen` with the whole canvas that they own: the framebuffer for the boot program and the root service, the canvas of the window for the process `boot`. `draw_screen` computes the place with `display_place`, fills the screen outside the panel, and draws the panel. So the same size gives the same scale, and no drawer computes a scale of its own. The window of `boot` has the base size: scale 1.

## The refused forms

- **A stretch to the screen.** A scale on each axis fills 1920 × 1080 and breaks the proportions of the cards, the squares of the processors and the heron.
- **A scale for each element.** A card at one scale and its text at another moves the text out of its box, and two neighbours stop sharing their edges.
- **A picture that is drawn once at scale 1 and then scaled.** A stretched picture of pixels blurs the text, or makes two widths of a stroke.
- **A scale of any eighth, with Spleen centered in a larger cell.** At 12 eighths a letter of 8x16 in a cell of 12 × 24 has 4 empty pixels beside it, and a word reads as separate letters.
- **The outlines at any size.** They need a font reader, a rasterizer and their memory in the boot program, and they give a soft look to a display that is drawn in cells.
- **A bitmap font for each eighth.** Spleen has no 10x20 or 14x28: a scale is one of the sizes that the font has, and a table is made by the tool from the files of the font, never by hand.
- **9 eighths, or a scale in hundredths.** The grid of 8 logical pixels stays on whole screen pixels only at a count of eighths, and Spleen has no such size.

## The subtle points

- The scale of a draw is a state of the package, as the order of the channels is: one draw at a time in each drawer. A host test draws the scales one after the other.
- A text measured in cells is measured in logical pixels: 8 for a character. The width on the screen is `s` pixels for a character, exactly, so a text that fits its box at scale 1 fits it at each scale.
- The display reads no setting of the text: the subpixel order, the font and the grid fit of a principal do not change it.

## The state

Built: the scale among the sizes of Spleen and the place of the panel, the scaled drawing of every element, the text in Spleen 8x16, 12x24, 16x32 and 32x64 in each drawer, and the host tests of the scale, of the form of each cell, of the pixels of each size, and of the boxes of a draw at each scale.

Left: the scale factor of the desktop, in its entry of `ROADMAP.md`.
