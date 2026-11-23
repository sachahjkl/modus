# A window that scrolls when it does not fit the work area

## Purpose

At a large scale the work area is small: 960 × 508 logical pixels at 2 on the reference screen, under a bar of 32. A window whose least size, or whose fixed size, is larger could not be shown whole, and a part of it was out of reach. Each window now gets a surface of at most the work area, and a window whose layout is larger than its surface scrolls it: the principal reaches each part of each window at each scale, with the pointer, the wheel and the keys.

## Constraints

- **The budget of a window counts its surface at its stated size at the largest scale** ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen", rule 1). A surface larger than the work area passes the screen in pixels: no window may hold one.
- **The layout of a window is its own.** A least size says what the texts of the window need; a fixed window places its elements with constants. Neither may be broken to fit a surface.
- **The drawing module is a border with a versioned export.** Its canvas shape has no origin, and a change of it is a change of each caller.
- **One path for every window of the interface package**, with no code in each process.

## The chosen form

**Two sizes for one window.** `display.Window` keeps the layout size (`width`, `height`), which a process reads to lay out, as before, and the view (`view_width`, `view_height`): the logical size of its surface. They differ only when the compositor clamped the window below its least size, or clamped a fixed window. `display.layout_size_of` (a pure procedure with host tests) gives the layout from the view: a fixed window keeps the size that it opened with; a resizable one takes the larger of the view and its least size.

**The compositor clamps.** It keeps for each window the size that the window opened with or that the principal asked last (`wanted`), and asks, with `Resized`, the size that fits the work area: `bar.window_fit` gives at most the room under the bar on each axis, with no floor at the least size, and moves the window onto the screen. It asks at the creation of the surface, at each change of the work area, and at each size that the principal asks, so no path leaves a surface larger than the work area. A fixed window gets that `Resized` too: it is a clamp, not a choice of the principal. The answer is checked as each answer is: exactly the size asked (`bar.surface_resize_refusal`); a clamp skips the check of the limits and of a fixed window, since the compositor itself chose the size. When the work area grows again, the window gets back its wanted size ([window_resize.md](window_resize.md), "The fit at a new scale").

**The window layer scrolls.** When the layout is larger than the view, `interface` builds the frame in the coordinates of the layout, as each process does today, and then moves each record of the frame by the scroll (`draw_record.record_moved`, a pure procedure with host tests that moves the box and each place in the fields of each kind: the cell of a pattern, the points of a gradient, the origin of a text, the points of a path). The drawing module draws the moved table as any table. The pointer moves the other way: the input of the frame is in the coordinates of the layout. Each axis that does not fit gets a scroll bar of the package at the edge of the view, drawn after the frame, so it takes the input after each view inside the window: an inner view under the pointer takes the wheel first.

**The keys and the focus.** PageUp and PageDown move a window that scrolls by its view, less one line. After each frame the box of the element with the focus is known: the scroll that brings it into the view, with a gap, is the scroll of the next frame (`interface.window_scroll_to_show`), so Tab reaches each element of a window that does not fit. The scroll is clamped to the layout at each frame (`interface.window_scroll_clamp`), so a larger view never shows a part past the end.

**The facts.** A window that starts to scroll writes `interface: <window>: the layout of <w>x<h> scrolls in a view of <w>x<h>`, and one line when the focus moves the view: a machine test reads them.

## Refused forms

- **An origin in the shape of the canvas of the drawing module.** One field, and the execution has the origin already; but the export is versioned, and the change reaches each process that draws through the module and the compositor. The move of the records costs one pass over the table of a frame that scrolls, and none for a window that fits.
- **A scroll in each process.** Settings has one, through its layout tree. Each fixed window would need its own, with its own bar and keys, as each process had its own scroll bar before the scroll bar had one form.
- **A surface larger than the work area, cut by the compositor.** The budget pays the surface at its stated size at the largest scale; a maximized window at 1.25 moved to 2 needs about 9 500 pages, which its budget does not pay. The compositor would also show a part that no input reaches.
- **The least size lowered to the work area.** The texts of the window would be cut, or wrapped past the window, and a fixed window has no least size to lower.
- **A clamp only at a change of the scale.** A window opened at 2 had its declared size, larger than the work area: the clamp is at each path that gives a window a size.

## Subtle points

- **A window that draws its picture by hand** goes through the same path: its picture is one record, which the move moves.
- **A fixed window takes the clamp in `display.next_event`.** Its `Resized` is always a clamp, and its layout keeps its size, so the answer needs no choice of the process: display makes the surface of the view itself, and a process whose loop reads its events with no window layer (`monitor` and `log` did) takes the clamp too. A resizable process that does not answer keeps its size: the next present declines the request, as for each request.
- **PageUp and PageDown go to the window view**, also when a list of the window would take them: a window that scrolls is the larger view, and its list keeps the arrows and the wheel.
- **The places that a window writes in its log** (`interface: <window>: the element ... at x,y`) are in the coordinates of the layout. A machine test that clicks an element of a window that scrolls takes the scroll into account, or uses the keys.
