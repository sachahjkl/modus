# Spacing tokens in place of the grid of 8

## Purpose

The design rules put each place and each size on a grid of 8 pixels, and the compositor moves each window to that grid. The grid came from the cells of 8 by 16 pixels of the first font: each layout was a count of cells. Today the interface font is proportional, its letters are not on the grid, and each size of a text is measured. The grid still rounds each measured width up to a multiple of 8, and it moves a window that the principal drops by up to 4 pixels. With the scale factor and the text at any size, the grid is a limit with no reason left.

This design keeps what the grid gave, a few lengths that every window shares, and drops what it bound.

The rules are in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "6. Spacing".

## Constraints

- **The elements of two windows line up**, and a reader's eye can follow a column. This was the reason of the grid.
- **A size that a content gives is that size.** A label is as wide as its text, a column as wide as its widest value.
- **A window stays where the principal drops it**, and its title stays on the screen so that the principal can take it again ([window_resize.md](window_resize.md)).
- **At each scale factor of the reference screen, the shared lengths are whole pixels of the screen** ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen").

## The chosen form

**The spacing tokens.** A few named lengths in logical pixels, in the one table of the design rules (`src/library/support/graphics/rules.odin`): `gap` 8, `margin` 16, `title` 40. A space between two elements of the desktop is a token or a sum of tokens. The text sizes are tokens too: `text_caption` 14, `text_body` 16, `text_heading` 24, `text_large` 32, `text_largest` 48 ([text_rendering.md](text_rendering.md), "The text size tokens").

**What leaves:**

- the rule "a position and a size are multiples of 8, or of 4 inside a form";
- the round up of a measured width to the grid;
- the move of a new window, of a dropped window and of each edge of a resize to the grid;
- the text sizes locked to multiples of 16.

**What stays:**

- The places of a new window: (64, 56), then 40 pixels to the right and 32 lower for each next one. They are sums of tokens.
- The rule of the places that keeps a part of the title on the screen and under the bar. The part kept is one `gap`.
- The cells of a text grid: a cell is half the text size by the text size, so a terminal stays a grid of cells.
- The heights of the bar, of a button and of a line of a list (32, 24, 24): fixed sizes of their elements, not tokens of spacing.

**Why the scale factor stays in eighths.** The tokens are multiples of 8 logical pixels. At a scale of n/8, each token is a whole count of pixels of the screen: the gap of 8 is n pixels. So two windows at one scale still line up to the pixel.

## The refused forms

- **A grid of 4.** It halves the round up and keeps it. A measured width still moves by up to 3 pixels.
- **The snap of the windows kept, and the grid dropped elsewhere.** A dropped window that moves under the pointer is a place that the principal did not choose. The snap to the edges and the halves of the screen is a part of the window manager ([desktop_to_browser.md](desktop_to_browser.md)), not a grid.
- **Tokens in screen pixels.** A token then changes its meaning with the scale, and each process computes it.
- **One token for every length.** A token names a space that many elements share. The height of a button belongs to the button.

## The subtle points

- **A drag of an edge moves by one logical pixel.** At a scale above 1, one logical pixel is more than one screen pixel; the edge follows the pointer within one logical pixel.
- **The scroll bar is 17 pixels thick**, an odd number, so that its grip is on its middle line. The rule that put the bar and the gap before it on a multiple of 8 leaves; the bar keeps its thickness ([scroll_bar.md](scroll_bar.md)).
- **The grid of the mark is another grid.** A move of the heron on the grid of its cells ([heron_module.md](heron_module.md)) and the cells of 8 CSS pixels of the site are rules of the mark, not of the desktop. They stay.

## State

Built. The spacing tokens are `GAP`, `MARGIN` and `TITLE` in `src/library/support/graphics/rules.odin`, which replaced the constant `GRID` and the card constants of the same lengths. The text size tokens are constants of the same file (`TEXT_CAPTION` to `TEXT_LARGEST`), which the elements read ([text_rendering.md](text_rendering.md), "The text size tokens"). A label under a value takes no gap: the line of the value holds its descent.

- A dropped window, a new window and each edge of a resize go to the pixel; the part of the title kept on the screen is `bar.TITLE_KEPT`, one `gap`.
- No measured width is rounded up: `interface.measured_size`, the columns of the start menu, the value buttons of a setting row and of a form of the palette.
- The palette is in the middle of the screen to the pixel. The scroll bar of `terminal` has a `gap` before it, and the one of `manual` a `gap` after the band of an example.
- The scenarios of the machine test move the windows to places that are multiples of 8, so the places that they read did not change.
