# The place of a new window

A new window takes a place in the work area of the desktop where it covers no window that shows, when such a place exists. The compositor chooses it once, when the window opens; the principal moves it after. The choice is the pure procedure `bar.new_window_free_place`, with host tests.

## Purpose

- A new window is seen whole, and the windows that show stay readable: their titles, with their close buttons, stay uncovered.
- The place depends on what shows, not on how many windows opened before.

## Constraints

- **A window is whole on the screen when it fits** (`new_window_place` of `src/library/internal/compositor/bar/window_place.odin`): in the work area, under or over the bar by its edge.
- **The loop of the compositor waits for no process** and does no work in proportion to the data at each frame: the choice runs once for each new window, over the windows that show, at most the clients of the compositor.
- **The places are in pixels of the desktop**, which the scale in force already gives: the outer box of a window is its surface at the scale in force and its frame.

## The chosen form

The candidates are the places where a free rectangle can start: the left edge and the top of the work area, the place right of each shown window and under it, and the place under the title of each window, with a gap of `graphics.GAP`. For each candidate where the whole window fits in the work area:

1. **A free place.** A candidate where the window covers no shown window is free. Of the free candidates, the one with the most free room is chosen: the width from it to the nearest window or edge on its right, times the height from it to the nearest window or edge under it, over the band of the window. Equal rooms take the place nearest the top, then the left: the reading order.
2. **A cascade place.** With no free candidate, the window takes the first of the eight cascade places (from 64, 56, by 40 and 32) where it covers no title of a shown window: the principal still reads and closes each window.
3. **The least cover.** With neither, the candidate or cascade place that covers the fewest pixels of titles, then the fewest pixels of shown windows: a pixel of a title weighs more than the pixels of any body, because the principal reaches each window by its title. The candidates then also start under the title of each window.

A window larger than the work area takes the place of `new_window_place`: its close button and the start of its title on the screen.

A minimized window does not count: it does not show.

## Refused forms

- **The cascade alone, by the count of the opened windows.** The eighth window went back to the first place, over the first window, and a window that closed left its place empty while new ones piled up.
- **A search over each pixel.** The free places of a rectangle start at an edge of the work area or of a window; the candidates are those starts, at most (1 + n)² for n windows.
- **The place under the pointer.** A window that opens from a key, the palette or a process has no relation to the pointer.

## Subtle points

- **The gap counts as cover.** A window that touches another reads as one block; the gap of `graphics.GAP` between them is part of the room that a window takes.
- **The bar is outside the work area**, at the top or at the bottom: a candidate never puts a title under the bar.

## State

Built: `bar.new_window_free_place` with host tests, and its call in the compositor when a window takes its surface.
