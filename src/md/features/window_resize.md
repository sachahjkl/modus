# Windows that the principal resizes

The principal drags an edge or a corner of a window, and the program draws its next frame at the new size. The guide is [`docs/DESIGN.md`](../../../docs/DESIGN.md), "Windows"; the protocol is in `src/library/support/display`.

## Constraints

- **The compositor never waits for a program.** A program that draws slowly, or never, must not slow a frame, the input or another window.
- **A program never draws into a surface that the compositor resized under it.** The memory of a surface is the memory of the program; its size changes only when the program says so.
- **The budget of the program pays for its surface** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller": whoever creates an object pays for it). A budget that cannot pay is the status `No_Budget`, which the program reads.
- **A window that the program did not draw for a size never shows at that size.** The screen shows whole frames ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)).
- **The program decides.** A program whose layout has fixed sizes stays fixed, and one whose texts need a width states that width as its minimum: no text is ever cut.

## The chosen form

### The declaration: resizable or fixed

A window is fixed unless its program declares it resizable. After `display.open`, the program calls `display.resizable_set(&window, limits)`: the least and the largest width and height of its surface. The command `Resizable` carries them. The compositor checks them at its border (`display.size_limits_of_record`):

- each least size is at least `RESIZABLE_LEAST_WIDTH` × `RESIZABLE_LEAST_HEIGHT` (the title must hold the close button and a part of the title);
- each largest size is at most `SURFACE_LIMIT`;
- each least size is at most its largest size;
- the size of the surface now is inside the limits.

The compositor refuses limits that break a rule, with one line of the log; the window stays fixed. A second `Resizable` replaces the limits.

### The drag

- **The edges.** The pointer is at an edge when it is on the border of the window, or at most `RESIZE_REACH` pixels outside its frame. A point near two edges is at a corner. The title bar is not an edge; the band above it is the top edge. The window in front at that place takes the press; a window behind it does not.
- **The pointer shape.** Over an edge of a resizable window, the shape is `resize_left_right`, `resize_up_down`, `resize_top_left_bottom_right` or `resize_top_right_bottom_left`. During the drag, the shape stays the one of the edge.
- **The size.** The pointer moves the edges that it holds, by a step of the grid of 8. The new size is cut to the limits of the window. An edge never goes past the screen: not left of 0, not right of the screen, not over the bar, not below the screen. A window that is already partly off the screen is never made larger in that direction, and never made smaller by the screen alone. The pointer is on the screen at each moment, so a drag outside the screen is a drag to its edge.
- **The outline.** During the drag, the compositor draws the outline of the new frame, 2 pixels wide, in the color of the title of the window in front, over the windows and under the pointer. The window keeps its picture and its frame. No surface is made during the drag: one size goes to the program, at the release.
- **The release.** The compositor sends the event `Resized` with the new surface size, when it differs from the size now. It keeps which edges the drag held, so that the new surface keeps the opposite edges in place.

### The new surface

- The program reads `Resized` from `display.next_event`. The border (`display.event_of_record`) refuses a size of 0 or past `SURFACE_LIMIT`.
- The program calls `display.surface_resize(&window, width, height)`. It makes a new memory object of two pictures of the new size, paid by its own budget; gives the compositor a handle with Read; sends `Surface_Resize`; then unmaps and closes the old surface. `window.canvas` is a picture of the new surface, which the compositor does not read: the program draws into it at once.
- A budget that cannot pay gives the status `No_Budget` and its error record. The window keeps its old surface and its size, and the display package writes one line. The compositor learns nothing: it never asked for memory.
- The interface package does this in `window_events`, and draws the next frame whole. A program that draws with the interface package reads its size from `window.canvas`, not from constants.

### When the compositor changes the window

- At `Surface_Resize`, the compositor checks the handle as it checks `Surface_Create` (a gift of this program, Read, memory for two pictures) and the size against the limits, then maps it. A refused record changes nothing and is counted.
- The old surface stays on the screen. The window changes at the first `Present` after `Surface_Resize`: its frame takes the new size, the edges opposite to the drag stay in place, and the old mapping is unmapped. The old memory object ends then, because the program closed its handle before: the budget of the program pays for both surfaces only between the two records.
- A second `Surface_Resize` before a `Present` replaces the first one, whose mapping the compositor unmaps.
- Each `Surface_Resize` that the compositor takes is shown: the program and the compositor never disagree on the size, whatever the order of a drag and of an answer.

### A program that does not handle `Resized`

It ignores the event. The window keeps its old size and its old picture, and a later drag asks again. A program that never declares itself resizable never gets the event, and its edges give no resize shape.

## The refused forms

- **The compositor makes the new surface.** The compositor cannot pay with the budget of the program: it holds no budget handle of it, and a budget handle of each program in the compositor gives it a right that no other task needs. If it paid with its own budget, a program could make the compositor pay for any size.
- **A new surface at each step of the drag.** Each step costs a memory object and a whole frame of the program; a slow program then shows a size that the principal left. One size at the release costs one surface.
- **The old picture stretched or cut during the drag.** A stretched picture is a picture that the program did not draw, and a cut one hides a part of the content.
- **The compositor waits for the new picture before it draws again.** One program could then stop the desktop.
- **A serial number that ties an answer to a request.** The compositor takes each answer within the limits, so no answer is stale and no state waits for a match.
- **A resizable window by default.** A window whose layout has fixed sizes would get a size that it cannot draw.
- **The minimum from the compositor alone.** Only the program knows the width of its widest text.

## Subtle points

- `Resizable`, `Surface_Resize` and `Resized` cross a border as words: the size limits as `u64`, read before any cast to `int`, so a word past the limit is refused and never becomes a negative size.
- The edges of a drag are a `bit_set` of an enum (`bar.Resize_Edges`), and a corner is two members. The pure procedures of the edges and the sizes are in `src/library/private/compositor/bar/window_size.odin`, with host tests.
- The drag moves an edge by steps of 8, to the nearest step, so a window on the grid stays on it at its left and top, except where a limit or the screen cuts the size.
- The budget of `clock` counts its window at its largest size, and its working memory holds the old surface for the moment that both exist. A program whose budget counts its window at its first size gets `No_Budget` for a larger one: the designed refusal.
- The compositor maps the new surface beside the old one for the time between `Surface_Resize` and `Present`: its page tables for two surfaces of a window come from its own budget.
- The machine test reads the size from the compositor: `compositor: surface <title> <width>x<height> at <x>,<y>` is written again when the window takes the new surface.

## State

Built: the declaration, the drag of each edge and corner with its shapes and its outline, `Resized`, `surface_resize` with its refusal, the change at the first `Present`, the interface package, and `clock` as a resizable window. The terminal (and so the console) stays fixed: its text grid has a size that the terminal ring states, and a change of it is a change of the protocol of the terminal.
