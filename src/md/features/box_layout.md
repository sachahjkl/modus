# The layout tree

## Purpose

A window of modus places its elements by hand today: `interface.Column`, `row_split` and areas in whole pixels that each process computes. A change of a text, of the scale factor or of the size of a window then moves each place by hand. The support package `modus:layout` gives a process a layout tree: the process says what each layout box wants (its size kind, its padding, its gap, its alignment, its overflow), and one solver gives each box its rectangle in whole logical pixels. The same package keeps the state of a box across frames by its element identity, gives the input of a box in one frame, and gives the element tokens: the colors and the spacing tokens of an element by its role.

The model is the box tree of the RAD Debugger, which `gui_toolkit` uses on the host. This package takes its model, not its code: `gui_toolkit` calls the allocator, uses floats and imports the core library of Odin, and a source of `src/` does none of these.

## Constraints

- **Freestanding and with no allocator.** Each procedure is `"contextless"`. The tree, the state table and the token stack are values of a fixed size that the caller puts where its memory is. A table of all zero is empty and valid.
- **No float.** A length is an integer. The solver computes in 1/64 logical pixel, the unit of the places of the draw table ([../api/draw_table.md](../api/draw_table.md)), and snaps each edge to a whole logical pixel at the end only. A ratio (a percent, a strictness, a split ratio) is in parts of 10 000.
- **Logical pixels.** The scale factor and the zoom of a view apply after the layout, in one rounding step of the draw table ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"). A layout at 1.0 and one at 1.5 then give the same tree of rectangles.
- **Each input is checked once, at its border.** A size, a length or an enum value that the contract does not name is refused with its status, and the tree does not change.
- **A bounded cost.** Each pass visits each box once: the solver is linear in the count of boxes. No procedure loops on a count that the caller gives past a capacity.

## The chosen form

**The layout tree.** `Box_Tree` holds `BOX_CAPACITY` (1024) boxes in one flat array, linked by indexes (parent, first and last child, next and previous sibling). Index 0 is "no box", so a zero link is no link. `tree_begin` starts a frame with the root box at the size of the view; `box_open` adds a box as the last child of the open box and opens it, `box_close` closes it, and `box_add` adds a box that has no children. The tree is built again at each frame, as the elements of the interface package are called again at each frame.

**The size kinds.** Each box has one `Size` on each axis: a `Size_Kind`, a value, a strictness and a least size.

- `Pixels`: a length.
- `Text`: the length of the text that the caller measured, with a padding on each side.
- `Percent`: a part of the content of the nearest ancestor whose size does not come from its children.
- `Children_Sum`: the sum of the children along the child axis, with the gaps and the padding, and the largest child across it.
- `None`: no size from the layout.

The strictness says how much of its size a box keeps when its parent has too little room: 10 000 keeps all of it, 0 gives all of it. `fill()` is 100 % with strictness 0: it takes what its siblings leave. `fill_least(n)` is the same, never under n pixels.

**The four passes.** `solve` runs them on the X axis, then on the Y axis:

1. *Standalone sizes*, in pre-order: `Pixels` and `Text`.
2. *Sizes from above*, in pre-order: `Percent` of the nearest ancestor that is not `Children_Sum`. Pre-order makes sure that the ancestor already has its size.
3. *Sizes from below*, in post-order: `Children_Sum`. Post-order makes sure that each child already has its size.
4. *Violations and places*, in pre-order. A box first gives each `Percent` child its part of its final size, because a box can lose room in this pass. Then, if its children are larger than its content, each child gives up to `(1 − strictness)` of its size, in proportion to what it can give, never under its least size or its minimum. Last, the box places its children along the child axis by its alignment, with its scroll offset, and across it by its cross alignment.

Then one pass snaps each edge (not each size) to the nearest whole logical pixel, and gives each box its clipped rectangle: its rectangle inside the clip of each ancestor that clips. Two boxes that touch in 1/64 pixel then touch in pixels, with no gap and no overlap.

**The overflow modes.** `Visible`: the children that the violation pass could not make small enough draw past the edge. `Clip`: they are cut at the edge. `Scroll`: the children keep their sizes on that axis, the box gives its `content_size`, and its scroll offset moves them; `solve` clamps the offset to `[0, content − room]`.

**The split pane and the table columns.** `split_pane` gives the two parts of a box and the rectangle of its divider from a split ratio, clamped to [1 000, 9 000] of 10 000, so neither part disappears. A drag of the divider moves the ratio by the drag over the room of the box. `table_columns` gives the widths of the columns of a table: the columns of a fixed width take their width, the flexible ones share the rest by their weights, and each column boundary has the rectangle of its divider.

**The state of a box across frames.** `Box_States` is a `modus:hash_table` keyed by the element identity of a box. The identity of a box is the identity of its parent with its label (`identity_in`), so one label under two parents gives two identities. An entry keeps the scroll offsets, the split ratio, a collapse, the chosen index, the sort column and order, the rectangle and the clipped rectangle of the last frame, and the frame where the box was seen last. An entry that no frame saw for `STALE_FRAMES` frames is stale: a search finds it as a new entry, and an insert into a full table removes the stale entries first. A second call for one identity in one frame is refused: two boxes with one identity would share one state.

**The input of a box.** `box_input` gives what the input of this frame does to a box: the pointer over it, held, activated (a press and a release on it, or Enter or Space with the focus), activated twice, the secondary press, a drag and its distance, the focus and the scroll. It reads the clipped rectangle of the last frame: the input of a frame acts on what the principal saw. Of the boxes under the pointer, the box placed last in the last frame takes the press, as it is drawn on top.

**The element tokens.** `Element_Tokens` names each color and length of an element by its role: the surfaces, the borders and the outline of the focus, the texts, the chosen color and the states, and the spacing tokens. `tokens_for(appearance, contrast_mode)` takes each value from the one table of the color tokens (`graphics.colors_for_contrast_mode`) and from the spacing tokens of `graphics`: it holds no color of its own. `Token_Stack` holds 16 records, so a part of a window can draw with other tokens and give them back.

## The refused forms

- **A fork of `gui_toolkit`.** It calls the allocator, uses `f32` and imports `core:`. A copy would also be a second body of code to keep in step.
- **Places in whole pixels from each process.** A text that grows, a scale factor or a window that the principal resizes moves each place by hand, and two windows place one element in two ways.
- **Floats.** The draw table refuses them, and two machines must give the same rectangles for the same tree.
- **Sizes snapped in each pass.** A rounding in each pass accumulates: ten fill boxes of 10.3 pixels are then 100 pixels, not 103. The snap is of the edges, once, at the end.
- **A heap tree with pointers.** It needs an allocator, and a pointer stays valid across frames only by luck.
- **A clamp of a wrong input.** A negative size or an unknown size kind is refused with its status, not turned into a valid value.
- **A five-step spacing scale and fixed element heights as tokens.** The spacing tokens are `gap`, `margin` and `title` ([spacing_tokens.md](spacing_tokens.md)); the height of a button belongs to the button.
- **Color values of the package.** The one table of the color tokens is in `graphics` ([appearance.md](appearance.md)). A second table drifts.

## The subtle points

- **A percent inside a box that its children size** is a part of a farther ancestor, as in the RAD Debugger. A child of 100 % inside a `Children_Sum` row is then as wide as the window. Give the row a size of its own.
- **Pass 4 resolves a percent again.** Pass 2 gave a percent from the size of the ancestor before the ancestor lost room. A box whose size does not come from its children gives its `Percent` children their part of its final size before it fixes their violations.
- **Exact shares.** The share of the violation of each child is computed from the running sum (`floor(V × sum_i / B) − floor(V × sum_{i−1} / B)`), so the shares add up to the violation with no remainder lost.
- **A scroll offset is clamped by the solver**, and written back into the box: the caller keeps the clamped offset in the state of the box, so a content that becomes shorter does not keep an offset past its end.
- **The input of a frame reads the rectangles of the frame before.** The first frame of a box gives no input: the box was not on the screen.

## State

Built: the package `modus:layout` with the four passes, the snap and the clip, the split pane, the table columns, the state table, the input of a box, the element tokens and their stack, and host tests, which `modustool check` runs.

Its owners are seven windows of the system, each building its tree at each frame from the live window size and taking its colors and spacing from `tokens_for`:

- `monitor` places its summary, its three graphs and the process table via `table_columns` ([monitor_window.md](monitor_window.md), "The layout").
- `settings` places its two cards, each row of `SETTINGS`, the time zone and language rows, the preview card and the action bar.
- `edit` is resizable with a top band, the text with its scroll bar, a draggable split pane for store versions (`Ctrl+H`), and a status band.
- `debugger_window` is resizable with a top band, a draggable split pane of two card columns (`THREADS`, `BREAKPOINTS`, `SOURCE`, `MEMORY`, `STACK`, `VARIABLES`), and a status band.
- `notes` places its lines one under the other and its action bar at the bottom, solving twice so the wrapped status fits cleanly.
- `inspect` places the process list card at the left and address space / modules / threads / bytes at the right, taking all four tables' columns from `table_columns`.
- `log` places the counts, process cards, column heads, and records table columns from `table_columns`.

**What the windows taught.** A split pane is sized before the tree is built: the width of the workspace is known from the size of the view, so `split_pane` gives the widths of the two parts as `Pixels` boxes, and the divider is a box with an identity whose state keeps the ratio and whose input gives the drag. Fixed siblings stay strict so the one fill box of a column takes the room left. Left: the elements of the interface package, making the remaining fixed-budget windows resizable, and the other windows, which [ROADMAP.md](../../../ROADMAP.md) names.
