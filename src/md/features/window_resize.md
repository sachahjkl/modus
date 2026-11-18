# Windows that the principal resizes

The principal drags an edge or a corner of a window, and the process draws its next frame at the new size. The guide is [`docs/DESIGN.md`](../../../docs/DESIGN.md), "Windows"; the protocol is in `src/library/support/display`.

## Constraints

- **The compositor never waits for a process.** A process that draws slowly, or never, must not slow a frame, the input or another window.
- **A process never draws into a surface that the compositor resized under it.** The memory of a surface is the memory of the process; its size changes only when the process says so.
- **The budget of the process pays for its surface** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller": whoever creates an object pays for it). A budget that cannot pay is the status `No_Budget`, which the process reads.
- **A window that the process did not draw for a size never shows at that size.** The screen shows whole frames ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)).
- **The process decides.** A process whose layout has fixed sizes stays fixed, and one whose texts need a width states that width as its minimum: no text is ever cut.

## The chosen form

### The declaration: resizable or fixed

A window is fixed unless its process declares it resizable. After `display.open`, the process calls `display.resizable_set(&window, limits)`: the least and the largest width and height of its surface. The command `Resizable` carries them. The compositor checks them at its border (`display.size_limits_of_words`):

- each least size is at least `RESIZABLE_LEAST_WIDTH` × `RESIZABLE_LEAST_HEIGHT` (the title must hold the close button and a part of the title);
- each largest size is at most `SURFACE_LIMIT`;
- each least size is at most its largest size;
- the size of the surface that the process has is inside the limits: the surface of a `Surface_Resize` that waits for its `Present`, or else the surface on the screen.

The compositor refuses limits that break a rule, with one line of the log; the window stays as it was. A second `Resizable` replaces the limits. An answer to a request that comes after narrowed limits is checked against the new limits, on both sides, because the two records cross the ring in order.

### The drag

- **The edges.** The pointer is at an edge when it is on the border of the window, or at most `RESIZE_REACH` pixels outside its frame. A point near two edges is at a corner. The title bar is not an edge, but its left and right columns are the left and right edges, as the border goes up through it; the band above it is the top edge.
- **Which window takes the press** (`bar.resize_target`). A point inside the frame of a window belongs to the first such window from the front: its border, when it is resizable, else no edge. The band outside a frame takes a point only where no window lies: the band of a window in front never takes a press from a window behind it.
- **One request at a time for each window.** From the release until the process answers, the edges of the window take no new drag, and give no resize shape. The process answers each `Resized` once, so the wait ends at its next picture at the latest (see "The new surface"). A process that never reads its events never answers, and then only its own window loses its edges. A bound of time was refused: an answer after the bound would come for a request that the compositor no longer has, and the process would draw into a surface that the screen never shows.
- **The pointer shape.** Over an edge of a resizable window, the shape is `resize_left_right`, `resize_up_down`, `resize_top_left_bottom_right` or `resize_top_right_bottom_left`. During the drag, the shape stays the one of the edge.
- **The size.** The pointer moves the edges that it holds, by a step of the grid of 8. The new size is cut to the limits of the window. An edge never goes past the screen: not left of 0, not right of the screen, not over the bar, not below the screen. A window that is already partly off the screen is never made larger in that direction, and never made smaller by the screen alone. The pointer is on the screen at each moment, so a drag outside the screen is a drag to its edge.
- **The outline.** During the drag, the compositor draws the outline of the new frame, 2 pixels wide, in the color of the title of the window in front, over the windows and under the pointer. The window keeps its picture and its frame. No surface is made during the drag: one size goes to the process, at the release.
- **The release.** The compositor sends the event `Resized` with the new surface size, when it differs from the size now. It keeps the request: the asked size, and which edges the drag held, so that the new surface keeps the opposite edges in place.

### The new surface

- The process reads `Resized` from `display.next_event`. The border (`display.event_of_record`) refuses a size of 0 or past `SURFACE_LIMIT`.
- `next_event` keeps the request in the window. The process calls `display.surface_resize(&window, width, height)` with the size of the event; another size, or no request, gives `Bad_Operation`. It makes a new memory object of two pictures of the new size, paid by its own budget; gives the compositor a handle with Read; sends `Surface_Resize`; then unmaps and closes the old surface. `window.canvas` is a picture of the new surface, which the compositor does not read: the process draws into it at once.
- A budget that cannot pay gives the status `No_Budget` and its error record. The window keeps its old surface and its size, the display package writes one line, and it sends `Resize_Declined`, the other answer. The compositor then takes a drag of the window again.
- The interface package does this in `window_events`, and draws the next frame whole. A process that draws with the interface package reads its size from `window.canvas`, not from constants.

### When the compositor changes the window

- At `Surface_Resize`, the compositor decides with `bar.surface_resize_refusal`, a pure procedure with host tests: a gift of this process with Read, memory for two pictures, a resizable window, a request that waits, its asked size, and that size inside the limits. Then it maps the memory, and the request ends. Any other `Surface_Resize` is refused and counted, and nothing changes: a process cannot change the size of its window when the principal did not ask for it, and a second answer to one request is refused.
- `Resize_Declined` ends a request with no change. With no request, it is refused and counted.
- The old surface stays on the screen. The window changes at the first `Present` after `Surface_Resize`: its frame takes the new size and the edges opposite to the drag stay in place. Then the rule of the places (`bar.window_place_kept`) keeps a part of the title on the screen and under the bar, so the principal can always take the window and its close button. The old mapping is unmapped. The old memory object ends then, because the process closed its handle before: the budget of the process pays for both surfaces between the two records.
- The compositor takes the one answer of the one request, so the process and the compositor never disagree on the size, whatever the order of a drag, an answer and a `Present`.

### A process that does not handle `Resized`

It ignores the event. Its next `present` sends `Resize_Declined` before the picture, because `next_event` kept the request: the window keeps its old size and its old picture, and a later drag asks again. A process that never declares itself resizable never gets the event, and its edges give no resize shape.

## The refused forms

- **The compositor makes the new surface.** The compositor cannot pay with the budget of the process: it holds no budget handle of it, and a budget handle of each process in the compositor gives it a right that no other task needs. If it paid with its own budget, a process could make the compositor pay for any size.
- **A new surface at each step of the drag.** Each step costs a memory object and a whole frame of the process; a slow process then shows a size that the principal left. One size at the release costs one surface.
- **The old picture stretched or cut during the drag.** A stretched picture is a picture that the process did not draw, and a cut one hides a part of the content.
- **The compositor waits for the new picture before it draws again.** One process could then stop the desktop.
- **A serial number that ties an answer to a request.** One request waits at most for each window, so the asked size names it.
- **Any answer within the limits.** A process could then grow its window when the principal did not ask, and with the edges of an old drag move it under the bar or off the screen.
- **A bound of time on a request.** See "One request at a time for each window".
- **A resizable window by default.** A window whose layout has fixed sizes would get a size that it cannot draw.
- **The minimum from the compositor alone.** Only the process knows the width of its widest text.

## Subtle points

- The process side refuses what the compositor refuses (another size, no request, a size outside the limits) before any kernel operation, so an honest process never makes a surface that the compositor refuses. A host test runs these refusals and `No_Slot` on a ring in plain memory; `No_Budget` comes from the kernel, and no test makes it yet.
- `Resizable`, `Surface_Resize` and `Resized` cross a border as words: the size limits as `u64`, read before any cast to `int`, so a word past the limit is refused and never becomes a negative size.
- The edges of a drag are a `bit_set` of an enum (`bar.Resize_Edges`), and a corner is two members. The pure procedures of the edges and the sizes are in `src/library/private/compositor/bar/window_size.odin`, with host tests.
- The drag moves an edge by steps of 8, to the nearest step, so a window on the grid stays on it at its left and top, except where a limit or the screen cuts the size.
- The budget of `clock` counts its window at its largest size, and its working memory holds a second surface at the largest size, for a resize between two large sizes, when both exist. A process whose budget counts its window at its first size gets `No_Budget` for a larger one: the designed refusal.
- The compositor maps the new surface beside the old one for the time between `Surface_Resize` and `Present`. Its budget counts the page tables of one such second mapping of the largest surface for each client (19 pages, 608 for 32 clients); the arithmetic is beside `MODULE_BUDGET` in `src/modules/system/compositor/main.odin`.
- The machine test reads the size from the compositor: `compositor: surface <title> <width>x<height> at <x>,<y>` is written again when the window takes the new surface.

## State

Built: the declaration, the drag of each edge and corner with its shapes and its outline, `Resized` with one request at a time, `surface_resize` and `Resize_Declined`, the change at the first `Present` with the place kept on the screen, the interface package, and `clock` as a resizable window. The terminal (and so the console) stays fixed: its text grid has a size that the terminal ring states, and a change of it is a change of the protocol of the terminal.
