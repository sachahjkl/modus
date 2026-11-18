# The text grid in a description

The terminal shows its text as one Text_Grid record: a grid of cells, each a character in its colors. The drawing module draws a frame through described exports, and a description carries values only. This file records how a grid crosses the border of the module, so that the terminal draws through the drawing module.

The border of the drawing module is in [library_modules.md](library_modules.md). The Picture record, which made the same choice for pixels, is in [picture.md](picture.md). The guide is [`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "2.4 Text grid".

## The constraints

- An export has at most 12 arguments, the error record included ([call_form_arguments.md](call_form_arguments.md)). When this form was chosen, the bound was six. The damage export had six already: the two draw tables, their two text tables, the rectangles and the error record. The draw export had six: the draw table, its text table, the picture memory, the pixels, the shape and the error record. So the cells went into the text table because no parameter was left for them. The bound of 12 leaves room for the cells as a table of their own; the form stays because it keeps the rule of the damage in one body of code and needs no new export.
- A record holds values only: no address, no slice.
- The difference of a grid compares the cells of two frames. A change of one cell damages the span of its row only, so a terminal that writes one line draws one line.
- The order of the records is the order of the draw. The border of the completion list is drawn after the grid, and the scroll bar after both.

## The count of a full terminal

The numbers come from the code of the terminal and of the window layer.

- A terminal has at most 104 columns and 32 rows (`COLUMNS_LIMIT`, `ROWS_LIMIT`): 3,328 cells. A cell is 16 bytes (a code point, two flags, two reserved bytes and two colors: [../data/text_encoding.md](../data/text_encoding.md)), so a full grid is 53,248 bytes.
- The draw of a grid makes one call of the glyph code for each run of cells: a run ends at a change of color, at a reverse cell, at the end of a group of filled cells, and at an empty cell. A line of plain text is one run. A line of colored code is one run for each token. The most is one run for each cell: 3,328 runs in one frame.
- With the chosen form, a frame crosses the border one time for the difference and one time for the draw of all its damage rectangles: 2 calls, whatever the count of runs ([picture.md](picture.md), "The draw export: the rectangles of a frame in one call"). When this form was chosen, the draw took one rectangle for each call: at most 9 calls.
- An export for one run of cells would cross the border up to 3,328 times for one frame of a full grid, and each call checks its arguments again.

## The chosen form: the cells are in the text table

`draw_text_grid` copies the cells of the caller into the text table of the frame, row after row, with no gap between two rows. A grid is then a text with a shape, and the rule of a text record holds: a field of a record is an offset into the text table of the same call ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "What the two users pass").

| Field | Value |
|---|---|
| `text_start` | The first byte of the cells in the text table, a multiple of 4 from the start of the table |
| `text_count` | The bytes of the cells: columns × rows × 16 |
| `second_color` | The columns |
| `x`, `y`, `width`, `height` | The place, and columns × 8 by rows × 16 pixels |

- **No new parameter and no new export.** The damage export reads the cells of the frame before in the text table before, and the cells of the frame now in the text table now. The draw export reads the cells in the text table now.
- **The frame before keeps its cells with no memory of its own.** `draw_table_copy` copies the text table, and the cells with it. `Draw_Table.grids` and the copy of each grid are gone.
- **The difference.** Two grid records that are equal except their place in the text table are compared cell by cell, as before. A grid that is not valid in one of the two tables is damaged whole.
- **The version.** The fields of a Text_Grid have another meaning, and the bytes of a cell are now part of the border. The draw record became version 9 for this form, version 10 when a cell became a code point of 16 bytes, and version 11 when each record got a header and the fields of its kind ([draw_table.md](draw_table.md)); the exports are `damage_of_draw_table_11` and `execute_draw_table_in_rectangles_11`.

### The cost

- **One copy of the cells more in each frame.** The terminal copied its cells one time in each frame already: `draw_table_copy` made the copy of the frame before. It now copies them two times. The compositor measures the copy at its start: 923 ns for 65,536 bytes in the guest, so a full grid of 53,248 bytes costs about 0.75 µs more for each frame (computed from that measure, not measured). The difference already reads the two copies of the cells, 106,496 bytes, in each frame.
- **The memory.** The terminal keeps two text tables of 54,276 bytes (1,028 bytes of text and the cells) in place of two of 1,024 bytes and one copy of the cells of 53,248 bytes.

## The refused forms

- **The compare of the cells compiled in.** The program compares the cells of its grids and joins its rectangles to the damage of the module; the module skips the grids that it cannot read. The rule of the damage of one table is then in two bodies of code, and the export gives a damage that is too small for a table with a grid.
- **A second damage export for a grid**, with the cells of the two frames and a record of the shape: five parameters. It is one more crossing in each frame, and its result is joined with the result of the other export: the same split of the rule. The draw export also needed the cells as a seventh parameter, past the bound of six of that time, or a second draw export.
- **The cells of the two frames in one `Bytes` of the program, with their offsets in a record.** The window layer owns the table before; this form makes the program keep the copy of the frame before in its own memory, at a place that the table names. Under the bound of six, the draw export also had no parameter left for the cells.
- **An export for one run of cells.** It is the export that the count above refuses for the terminal: up to 3,328 calls in one frame, and the window layer must cut the table at each grid to keep the order of the draw.
- **The cells by an address in the record.** The value means nothing in another address space, and an isolated caller cannot give it.

## The subtle points

- **The cells hold 4-byte colors, so their place is aligned.** `draw_text_grid` puts the cells at a place whose address is a multiple of 4, and leaves at most 3 bytes unused before it. The text table of a program with a grid starts at an address that is a multiple of 4: the terminal declares its text tables as arrays of 32-bit words. `grid_of` refuses a place whose address is not a multiple of 4: such a record draws nothing, and the difference damages it whole.
- **One place holds the check.** `grid_of` checks a Text_Grid record against its text table, and both the package and the module run it: at least one column, a count of bytes that is a whole count of rows, a range inside the text table, each in 64 bits from values below 2^32.
- **A cell holds no count and no address.** A cell of a hostile caller draws some characters in some colors. No read passes the range that `grid_of` checked.
- **A frame shows the cells of the moment of the copy.** The reader thread of the terminal can change its view after `draw_text_grid`, and the frame stays the frame that was built.
- **A text table that is too small** makes the table full: the grid is not drawn, and the next frame is whole, as for a text.

## What is built and what is left

Built: the cells in the text table, the draw record of version 11, and the terminal through the module.

Left: an export for one run of cells, for the programs that draw cell text themselves with no draw table. The count above shows that it is not the border of the terminal. See [library_modules.md](library_modules.md), "What is left, and what blocks it".
