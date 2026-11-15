# The Picture record in a description

A Picture record shows pixels that a program holds in its own memory. The drawing module draws a frame through described exports, and a description carries values only. This file records how a Picture names its pixels with values, so that a program that shows a picture draws through the drawing module (`docs/DECISIONS.md`, D-237).

The border of the drawing module is in [library_modules.md](library_modules.md). The guide is [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "7. Where it lives: the elements in each program, the drawing in a module".

## The constraints

- An export has at most 12 arguments, the error record included (`PARAMETER_CAPACITY`; [call_form_arguments.md](call_form_arguments.md)). When this form was chosen, the bound was six, the integer registers of the call form, and the draw export had six already: the draw table, its text, the rectangles, the pixels of the canvas, the shape and the error record.
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
- **One rectangle for each call.** Under the bound of six, the picture memory took the place of the table of rectangles: the one rectangle of a call is in the record of the shape (`Canvas_Rectangle`). A window crosses the border one time for the difference and one time for each damage rectangle, at most 8. Each call runs the same loop over the records as the call for one rectangle did, so the work of a frame is the same; each more crossing costs an import slot (2.4 ns) and the checks of the shape. The bound is now 12, so the table of rectangles has its place again; the change of the exports is planned work in `ROADMAP.md`.
- **The version.** The fields of a Picture have another meaning, so the draw record is version 8, and the exports are `damage_of_draw_table_8` and `execute_draw_table_8`. A module of version 7 has no export of these names, and the load fails by name.
- **More than one memory is for the package.** The compositor gives one picture memory to each surface and one to the heron of the bar, and keeps the interface package compiled in. The window layer refuses a frame with more than one picture memory in a program that draws through the module, with one line on the log.

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
- **The settings at each call.** The module reads the choice of the settings page at each call, so a change of the font between two rectangles of one frame draws that frame in two fonts. The event `Settings_Changed` makes the next frame whole, so the screen shows such a frame one time at most.
- **A picture across two memories is refused.** The record names one memory. A program puts the pictures that one frame shows in one array: `heron` cuts one stage into tiles with `graphics.view`, and the four squares of `threads` follow each other in one array.
- **The limits of the values**: at most 256 picture memories (a byte), a first pixel and a stride below 2^32, so a picture memory of the module holds up to 16 GiB of pixels.
- **The compositor names no closed window.** It empties its list of picture memories at each build of the screen: a new mapping can have the address of a surface that closed.

## The proof

The host test `the_exports_draw_the_same_bytes_as_the_package` (`src/modules/drawing`) draws two pictures of one picture memory in each frame: a part with the full stride of the memory, and a part at a place that the seed changes. The package and the exports give the same damage rectangles and the same bytes of the canvas. The test `fill_of_the_background_pictures_and_grids` gives Picture records of a hostile caller: a pixel past the memory, a memory that the call does not have, a stride and a first pixel that would wrap.

## What is built and what is left

Built: the picture memory, the Picture record of version 8, the two exports with the picture memory, and the eight programs that show a picture through the module.

Left:

- **The rectangles of a frame in one call.** The draw export takes the table of the damage rectangles, now that an export has room for it.
- **The terminal.** A Text_Grid record names its cells by an address. The damage of a grid compares the cells of two frames, so the damage export needs the two tables of cells: two more parameters, eight in all, which the bound of 12 holds. The nearest form under the bound of six keeps the compare of the cells compiled in (one loop over the cells of a row, called one time for each frame), joins its rectangles to the damage of the module, and gives the draw export the cells of the frame now as a `Table(Text_Grid_Cell, Read)` in place of the picture memory.
- **The compositor.** Its pictures are the surfaces of other programs, one picture memory for each, and an export takes one. It draws its panels over other windows with no fill of the background. A form for it is not designed.
