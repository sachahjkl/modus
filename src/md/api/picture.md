# The Picture record in a description

A Picture record shows pixels that a program holds in its own memory. The drawing module draws a frame through described exports, and a description carries values only. This file records how a Picture names its pixels with values, so that a program that shows a picture draws through the drawing module ([library_modules.md](library_modules.md)).

The border of the drawing module is in [library_modules.md](library_modules.md). The guide is [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "7. Where it lives: the elements in each program, the drawing in a module".

## The constraints

- An export has at most 12 arguments, the error record included (`PARAMETER_CAPACITY`; [call_form_arguments.md](call_form_arguments.md)). When the picture memory was chosen, the bound was six, the integer registers of the call form, and the draw export had six already: the draw table, its text, the rectangles, the pixels of the canvas, the shape and the error record. So the picture memory took the place of the table of the rectangles, and the draw took one rectangle for each call. The draw export now has seven arguments, with the table of the rectangles back (below).
- The description describes each export completely, and a record holds values only: no address, no slice.
- No adapter copies the pixels of a picture across the border.
- A draw record stays 40 bytes, and two records compare by their bytes.
- The compositor shows the surface of each window as a picture. Each surface is a memory object of another program, mapped at an address that the kernel chose.

## The chosen form: a picture memory, and values in the record

A **picture memory** (`docs/glossary/desktop.md`, "Picture memory") is one run of pixels of the program. A Picture record names its pixels in it with four values:

| Field | Value |
|---|---|
| `kind_detail` | The number of the picture memory in `Draw_Table.picture_memories` |
| `text_start` | The index of the first pixel of the picture in that memory |
| `second_color` | The stride: the pixels from one line of the picture to the next |
| `width`, `height` | The size of the picture |
| `text_count` | The generation, as before |

- The draw export takes one picture memory as `Bytes(Read)`. A record of picture memory 0 reads its pixels there, in place. This is the rule that a text record already follows: a field of a record is an offset into another parameter of the same call ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "What the two users pass").
- `draw_picture` takes a canvas of the program, finds the first picture memory that holds each of its pixels, and writes the values. A program keeps its canvases and its views as before.
- **The version.** The fields of a Picture got another meaning in version 8 of the draw record. Version 9 gave the Text_Grid record its values ([text_grid.md](text_grid.md)), version 10 made a cell a code point ([../data/text_encoding.md](../data/text_encoding.md)), version 11 gave each record a header and the fields of its kind ([draw_table.md](draw_table.md)), version 12 took the look of the system out of the format, version 13 made the two text kinds one, version 14 gave the colors an alpha and a Picture its format, version 15 made the two gradients one along any line and let a box start inside a pixel, and the exports are `damage_of_draw_table_15` and `execute_draw_table_in_rectangles_15`. A module of another version has no export of these names, and the load fails by name.
- **One picture memory for each call.** The window layer refuses a frame with more than one picture memory in a program that draws through the module, with one line on the log. The compositor, which shows many memories, draws one part of its table for each call (below).

## The draw export: the rectangles of a frame in one call

`execute_draw_table_in_rectangles_15` takes seven arguments: the draw table, its text, the picture memory, the pixels, the shape of the canvas (`Canvas_Shape`: the width, the height, the stride, the fill of the background and its color), the table of the rectangles (`Table(Damage_Rectangle, Read)`) and the error record.

- **The rectangles are a table of the caller.** A window gives the damage rectangles of its frame as they are: the `Damage` of the window layer holds its rectangles in the layout of `Damage_Rectangle`, so the table is a place over that memory, with no copy.
- **At most 8 rectangles, checked.** The bound is the most damage rectangles that a frame keeps (`interface.DAMAGE_CAPACITY`), the most that `damage_of_draw_table_15` gives. The module copies the count one time, refuses a count above 8 with `Too_Long` of the argument 6 before it draws, then copies the rectangles into its own frame before it uses them. So a caller that changes its table during the call cannot make the module read past it.
- **In order, with the pixels of one call for each rectangle.** For each rectangle in the order of the table, the module paints the rectangle with the background when the shape asks for it, then draws the records that touch the rectangle, cut to it. It is the loop that a caller ran before with one call for each rectangle, inside the module. So the bytes of the canvas are the bytes of N calls of one rectangle, also when two rectangles overlap.
- **The work stays the same.** The records are read one time for each rectangle, as before. What goes is the crossings and the checks of the shape and of the tables, one time for each rectangle.
- **No rectangle draws nothing.** A table of no rectangle checks the shape and the tables and draws nothing: the result is 0, as for each draw that the module does not refuse.
- **The name.** When the export took the rectangles of a frame in one call, the meaning of the draw record did not change, so the version in the name stayed the same, and the form of the export changed its name: `execute_draw_table_<version>` became `execute_draw_table_in_rectangles_<version>`, and a module that had only the old name failed the load by name. The version of today is 15 ([draw_table.md](draw_table.md)). A description holds the parameters of each export, so the check of a replacement also refuses an export of the old form under the new name.

The count of the calls of a frame, from the code of the window layer and of the compositor:

| Frame | One rectangle for each call | The rectangles in one call |
|---|---|---|
| A window, a frame with damage (at most 8 rectangles) | 1 + 8 = 9 at most | 1 + 1 = 2 |
| A window, a whole frame | 1 | 1 |
| The compositor, the full screen with 17 windows (one rectangle) | 17 + 1 = 18 | 18 |
| The compositor, 8 damage rectangles over 17 windows | 8 × 18 = 144 at most | 18 at most |
| The compositor, 8 damage rectangles over 32 windows | 8 × 33 = 264 at most | 33 at most |

The palette adds one call when it is open, in each form, where it added one for each rectangle before. A full screen is one damage rectangle, so its count does not change: the gain is in the frames with several rectangles, which are the frames of a move and of a program that changes a few places. At 2.4 ns for each crossing, the 126 crossings that a compositor frame of 8 rectangles over 17 windows no longer makes are 0.3 µs (computed, not measured), against 1,296 µs measured for a full frame with 17 windows. The checks of the shape at each call are not measured. The reason of the change is the form, not the time: the export now takes the work of a frame whole, as the border of the module asks ([library_modules.md](library_modules.md), "The chosen form: a split, with a coarse border").

### The refused forms of the draw export

- **One call for each rectangle, as before.** It was the form that the bound of six forced. It crosses the border up to 8 times for one frame of a window, and it lets a change of the settings between two rectangles draw one frame in two fonts.
- **The rectangles in the record of the shape**: refused for the Picture too, below.
- **No bound on the count.** The module copies the rectangles before it uses them, into a fixed array of its frame; a count with no bound needs memory of the size of the count. No caller has more than 8: the damage of a window and of the compositor both stop at 8.
- **The rectangles read in place, with no copy.** A caller can change a rectangle between the check and the draw. The draw cuts each rectangle to the canvas, so no write leaves the pixels, but the rule of the system is one copy and one check of a value of another party ([../README.md](../README.md), "The subtle points"), and 8 rectangles are 256 bytes.
- **A new version of the draw record for the new form.** The records keep their meaning: the version names the meaning of a record, not the form of an export. The name of the export changes instead.

## The compositor: one call for each part

The compositor shows the surface of each window as a picture. Each surface is a memory object of another program, mapped at its own address, so each surface is a picture memory of its own. The heron of the bar is one more. A call takes one picture memory.

- **The screen table is in parts.** A part is a run of records of the table, with the one picture memory that its Picture records name as number 0. Each window is one part: its frame, then its surface. The bar and its menus are the last part, with the heron. `screen_build` gives the table, for the time of one `draw_picture`, a list of one picture memory: the surface of that window. The record then names memory 0.
- **One call for each part, with the damage rectangles that meet it.** The compositor draws a frame with one call for each window whose outer rectangle meets a damage rectangle of the frame, from the back to the front, then one call for the bar. The table of the rectangles of a call holds the damage rectangles that meet the part, in the order of the damage. A part draws only inside its outer rectangle, so a rectangle that it does not meet would draw nothing. The palette is one more call, with no picture memory and all the rectangles. The order of the calls is the order of the records, so the pixels are the pixels of one call over the whole table.
- **The steps of a frame are in phases.** First the background goes into each damage rectangle, then each part draws in all its rectangles, then the palette, then the pointer and the copy to the screen go in each rectangle. Before, each rectangle took all the steps before the next rectangle started. The pixels are the same because the damage rectangles of the compositor never touch (`damage_rectangle_add` joins two rectangles that touch): each step writes only inside its rectangle, so the steps of two rectangles change no pixel of each other.
- **The work stays the same.** Each call runs the loop over the records of its part one time for each of its rectangles, as before.
- **The cost.** With 17 windows, a frame that damages 8 rectangles of the whole screen makes at most 18 calls, where it made 8 × 18 = 144 (the table above). With 32 windows, the most that the root service starts, the bound is 33 calls, where it was 264.
- **No fill of the background.** The compositor copies its background picture into each rectangle first, then each call draws its records over it, with `fill_background` 0.
- **No origin.** The module draws in the coordinates of the canvas. The compositor gives the whole frame as the canvas, with the damage rectangle in it, so the records stay in the coordinates of the screen. The heron of the bar is built once with the records of the bar moved by the place of the heron, so that its picture shows the bar under it.

### The refused forms for the compositor

- **The interface package compiled in, for the compositor only.** It keeps a second copy of the drawing code in the program that holds the surfaces of every window. A correction of the module would not reach it.
- **A copy of each surface into one picture memory.** It copies the pixels of each window at each frame, and no adapter copies the pixels of a picture across the border.
- **One span of addresses over the surfaces.** It is refused for each program above: the span holds memory that is not pixels, and holes.
- **An export with a table of picture memories.** A memory is an address and a size, so the table holds addresses, which a description cannot carry. The bound of 12 arguments does not change this: the reason is the kind of the parameter, not the count.
- **A table of the parts, to draw the whole screen in one call.** A part is a run of records and its own picture memory. A table of the parts then holds a picture memory for each part: the table of picture memories above, with the same addresses. A table of the parts with no memory serves only the parts with no picture, and each window has one. So the compositor makes one call for each part, with all its rectangles: 18 calls for 17 windows, at 2.4 ns each.
- **One call for each part and each rectangle, as before.** It was the form of the draw export with one rectangle. It makes up to 8 times the calls of a frame for no other gain.
- **One call for each rectangle with all the parts.** It needs the table of the parts, refused above.

## The refused forms

- **A table of picture places beside the bytes** (the record keeps an index, and a `Table(Picture_Place, Read)` holds the offset, the size and the stride of each picture). Two places then hold the size of one picture, and they can disagree. It also needed two more parameters, eight in all, past the bound of six of that time.
- **A lent memory object for each picture.** A direct call runs in the address space of the caller, where the pixels are mapped already: a handle makes the callee map them again at each call. A handle is one register, so the compositor would need 33 parameters. A table too large for the call region of an isolated call already goes in a lent memory object ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "One description, three ways to call", form (iii)): that is the isolated form of the chosen form, not another form.
- **The text and the pixels in one `Bytes`.** It forces a layout of memory that two owners share: the window layer owns the text table, the program owns its pictures, and the table before has a text of its own.
- **One `Bytes` from the lowest to the highest address of the pictures.** It names memory that is not the pixels of the program, and holes that are not mapped. An isolated call copies the whole span.
- **The address of a canvas as an Integer.** The value means nothing in another address space, and an isolated caller cannot give it.
- **The rectangles of the damage in the record of the shape.** A record has no field that is a table: 8 rectangles are 32 named fields, and the count of rectangles becomes a limit of the format.

## The subtle points

- **One place holds the check.** `picture_of` in the interface package checks a Picture record against its picture memory, and both the package and the module run it. The record comes from a caller that can write any bytes, so the check is in 64 bits with each factor below 2^32: `first + (height - 1) * stride + width` cannot wrap. A record that fails draws nothing.
- **A direct call is not a border of trust.** The module reads the pixels of a picture with plain reads, as it reads the draw records. A caller that changes them during the call reaches only its own memory.
- **The settings at each call.** The module reads the choice of the settings page one time at each call, before the first rectangle. A window draws all its rectangles in one call, so a change of the font draws all the rectangles of one frame of a window in one font. The compositor makes one call for each part, so a change between two of its calls can draw two parts of one frame in two fonts. The event `Settings_Changed` makes the next frame whole, so the screen shows such a frame one time at most.
- **Two rectangles that overlap are drawn in order.** The module paints and draws each rectangle in the order of the table, as N calls did. A blend of a text then runs two times where the rectangles overlap, but each rectangle is painted with the background first, so the second draw starts from the same pixels as the first. A caller with no fill of the background (the compositor) must give rectangles that do not overlap, or the text where they overlap is blended two times: the damage of the compositor never has two rectangles that touch.
- **A picture across two memories is refused.** The record names one memory. A program puts the pictures that one frame shows in one array: `heron` cuts one stage into tiles with `graphics.view`, and the four squares of `threads` follow each other in one array.
- **The limits of the values**: at most 256 picture memories (a byte), a first pixel and a stride below 2^32, so a picture memory of the module holds up to 16 GiB of pixels.
- **The compositor names no closed window.** It empties its list of parts at each build of the screen: a new mapping can have the address of a surface that closed.
- **A clip does not cross a part.** Each call starts with no clip. The screen table has no Clip record; a clip in a part ends with its part.
- **The compositor holds every surface.** A replacement of the drawing module runs in the compositor too, with the mapping of each surface and the input. The rule of [library_modules.md](library_modules.md) holds: a replacement of a library module is for a test.

## The proof

The host test `the_exports_draw_the_same_bytes_as_the_package` (`src/modules/libraries/drawing`) draws two pictures of one picture memory in each frame: a part with the full stride of the memory, and a part at a place that the seed changes. The package and the exports give the same damage rectangles and the same bytes of the canvas. The test `fill_of_the_background_pictures_and_grids` gives Picture records of a hostile caller: a pixel past the memory, a memory that the call does not have, a stride and a first pixel that would wrap.

The host test `the_parts_of_a_screen_draw_the_same_bytes_as_the_package` draws a screen of several surfaces, each in its own picture memory, that overlap, over a background, with a bar and its heron: one call of the package over the whole table with all the memories in each damage rectangle, against one call of the export for each part with all the damage rectangles of the frame, in the phases of the compositor. The damage rectangles of a frame do not touch, as in the compositor. The two canvases are the same bytes.

The host test `one_call_with_the_rectangles_draws_as_one_call_for_each` draws frames of every kind of record in 1 to 8 rectangles that the seed chooses: rectangles that overlap, that pass the edges of the canvas, and that are empty. One call with the N rectangles, N calls with one rectangle each, and the package give the same bytes, with the fill of the background and with none. The test `canvas_shape_that_wraps_is_refused` gives a table of 9 rectangles and a count that a hostile caller writes: the export refuses it with `Too_Long` of the argument 6, and draws nothing.

## What is built and what is left

Built: the picture memory, the Picture record, the two exports with the picture memory, the draw of the rectangles of a frame in one call, the eight programs that show a picture through the module, and the compositor through the module, one call for each part with all its rectangles.

Left: nothing of this design.
