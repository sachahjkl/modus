# The Picture record in a description

A Picture record shows pixels that a program holds in its own memory. The drawing module draws a frame through described exports, and a description carries values only. This file records how a Picture names its pixels with values, so that a program that shows a picture draws through the drawing module (`docs/DECISIONS.md`, D-237).

The border of the drawing module is in [library_modules.md](library_modules.md). The guide is [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "7. Where it lives: the elements in each program, the drawing in a module".

## The constraints

- An export has at most six parameters, the error record included (`PARAMETER_CAPACITY`: the integer registers of the call form). The draw export had six already: the draw table, its text, the rectangles, the pixels of the canvas, the shape and the error record.
- The description describes each export completely, and a record holds values only: no address, no slice.
- No adapter copies the pixels of a picture across the border.
- A draw record stays 40 bytes, and two records compare by their bytes.
- The compositor shows the surface of each window as a picture. Each surface is a memory object of another program, mapped at an address that the kernel chose.

## The chosen form: a picture memory, and values in the record

A **picture memory** (`docs/GLOSSARY.md`, "Picture memory") is one run of pixels of the program. A Picture record names its pixels in it with four values:

| Field | Value |
|---|---|
| `kind_detail` | The number of the picture memory in `Draw_Table.picture_memories` |
| `text_start` | The index of the first pixel of the picture in that memory |
| `second_color` | The stride: the pixels from one line of the picture to the next |
| `width`, `height` | The size of the picture |
| `text_count` | The generation, as before |

- The draw export takes one picture memory as `Bytes(Read)`. A record of picture memory 0 reads its pixels there, in place. This is the rule that a text record already follows: a field of a record is an offset into another parameter of the same call ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "What the two users pass").
- `draw_picture` takes a canvas of the program, finds the first picture memory that holds each of its pixels, and writes the values. A program keeps its canvases and its views as before.
- **One rectangle for each call.** The picture memory takes the place of the table of rectangles: the one rectangle of a call is in the record of the shape (`Canvas_Rectangle`). A window crosses the border one time for the difference and one time for each damage rectangle, at most 8. Each call runs the same loop over the records as the call for one rectangle did, so the work of a frame is the same; each more crossing costs an import slot (2.4 ns) and the checks of the shape.
- **The version.** The fields of a Picture got another meaning in version 8 of the draw record. Version 9 gave the Text_Grid record its values ([text_grid.md](text_grid.md)), and the exports are `damage_of_draw_table_9` and `execute_draw_table_9`. A module of another version has no export of these names, and the load fails by name.
- **One picture memory for each call.** The window layer refuses a frame with more than one picture memory in a program that draws through the module, with one line on the log. The compositor, which shows many memories, draws one part of its table for each call (below).

## The compositor: one call for each part

The compositor shows the surface of each window as a picture. Each surface is a memory object of another program, mapped at its own address, so each surface is a picture memory of its own. The heron of the bar is one more. A call takes one picture memory.

- **The screen table is in parts.** A part is a run of records of the table, with the one picture memory that its Picture records name as number 0. Each window is one part: its frame, then its surface. The bar and its menus are the last part, with the heron. `screen_build` gives the table, for the time of one `draw_picture`, a list of one picture memory: the surface of that window. The record then names memory 0.
- **One call for each part that meets a damage rectangle.** The compositor draws a damage rectangle with one call for each window whose outer rectangle meets it, from the back to the front, then one call for the bar. A part draws only inside its outer rectangle, so a part that the rectangle does not meet would draw nothing. The palette is one more call, with no picture memory. The order of the calls is the order of the records, so the pixels are the pixels of one call over the whole table.
- **The work stays the same.** Each call runs the loop over the records of its part only, so the records are read one time for each rectangle, as before. Each part costs one more crossing and the checks of the shape.
- **The cost.** With 17 windows, a frame that damages 8 rectangles of the whole screen makes at most 8 × 18 = 144 calls. At 2.4 ns for each crossing that is 0.35 µs. The compositor measured a full frame with 17 windows in 1,296 µs. With 32 windows, the most that the root service starts, the bound is 8 × 33 = 264 calls, 0.63 µs. The checks of the shape at each call are not measured.
- **No fill of the background.** The compositor copies its background picture into the rectangle first, then each call draws its records over it, with `fill_background` 0.
- **No origin.** The module draws in the coordinates of the canvas. The compositor gives the whole frame as the canvas, with the damage rectangle in it, so the records stay in the coordinates of the screen. The heron of the bar is built once with the records of the bar moved by the place of the heron, so that its picture shows the bar under it.

### The refused forms for the compositor

- **The interface package compiled in, for the compositor only.** It keeps a second copy of the drawing code in the program that holds the surfaces of every window. A correction of the module would not reach it.
- **A copy of each surface into one picture memory.** It copies the pixels of each window at each frame, and no adapter copies the pixels of a picture across the border.
- **One span of addresses over the surfaces.** It is refused for each program above: the span holds memory that is not pixels, and holes.
- **An export with a table of picture memories.** A memory is an address and a size, so the table holds addresses, which a description cannot carry.

## The refused forms

- **A table of picture places beside the bytes** (the record keeps an index, and a `Table(Picture_Place, Read)` holds the offset, the size and the stride of each picture). It needs two more parameters, eight in all. Two places then hold the size of one picture, and they can disagree.
- **A lent memory object for each picture.** A direct call runs in the address space of the caller, where the pixels are mapped already: a handle makes the callee map them again at each call. A handle is one register, so the compositor would need 33 parameters. A table too large for the call region of an isolated call already goes in a lent memory object ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "One description, three ways to call", form (iii)): that is the isolated form of the chosen form, not another form.
- **The text and the pixels in one `Bytes`.** It forces a layout of memory that two owners share: the window layer owns the text table, the program owns its pictures, and the table before has a text of its own.
- **One `Bytes` from the lowest to the highest address of the pictures.** It names memory that is not the pixels of the program, and holes that are not mapped. An isolated call copies the whole span.
- **The address of a canvas as an Integer.** The value means nothing in another address space, and an isolated caller cannot give it.
- **The rectangles of the damage in the record of the shape.** A record has no field that is a table: 8 rectangles are 32 named fields, and the count of rectangles becomes a limit of the format.

## The subtle points

- **One place holds the check.** `picture_of` in the interface package checks a Picture record against its picture memory, and both the package and the module run it. The record comes from a caller that can write any bytes, so the check is in 64 bits with each factor below 2^32: `first + (height - 1) * stride + width` cannot wrap. A record that fails draws nothing.
- **A direct call is not a border of trust.** The module reads the pixels of a picture with plain reads, as it reads the draw records. A caller that changes them during the call reaches only its own memory.
- **The settings at each call.** The module reads the choice of the settings page at each call, so a change of the font between two rectangles of one frame draws that frame in two fonts. The event `Settings_Changed` makes the next frame whole, so the screen shows such a frame one time at most.
- **A picture across two memories is refused.** The record names one memory. A program puts the pictures that one frame shows in one array: `heron` cuts one stage into tiles with `graphics.view`, and the four squares of `threads` follow each other in one array.
- **The limits of the values**: at most 256 picture memories (a byte), a first pixel and a stride below 2^32, so a picture memory of the module holds up to 16 GiB of pixels.
- **The compositor names no closed window.** It empties its list of parts at each build of the screen: a new mapping can have the address of a surface that closed.
- **A clip does not cross a part.** Each call starts with no clip. The screen table has no Clip record; a clip in a part ends with its part.
- **The compositor holds every surface.** A replacement of the drawing module runs in the compositor too, with the mapping of each surface and the input. The rule of [library_modules.md](library_modules.md) holds: a replacement of a library module is for a test.

## The proof

The host test `the_exports_draw_the_same_bytes_as_the_package` (`src/modules/drawing`) draws two pictures of one picture memory in each frame: a part with the full stride of the memory, and a part at a place that the seed changes. The package and the exports give the same damage rectangles and the same bytes of the canvas. The test `fill_of_the_background_pictures_and_grids` gives Picture records of a hostile caller: a pixel past the memory, a memory that the call does not have, a stride and a first pixel that would wrap.

The host test `the_parts_of_a_screen_draw_the_same_bytes_as_the_package` draws a screen of several surfaces, each in its own picture memory, that overlap, over a background, with a bar and its heron: one call of the package over the whole table with all the memories, against one call of the export for each part. The two canvases are the same bytes in each damage rectangle.

## What is built and what is left

Built: the picture memory, the Picture record, the two exports with the picture memory, the eight programs that show a picture through the module, and the compositor through the module, one call for each part.
