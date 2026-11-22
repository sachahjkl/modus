# The byte layout of a record of a format

## Purpose

A reader of a format asks where each byte is. The module file is a header, a table directory and records of fixed size. A byte layout draws one record as the header diagrams of an RFC do: rows of 8 bytes, the offset of each row at its left, a ruler of the bytes and of the bits on top, and each field as a rectangle that covers its bytes, with its name and its size. The site shows it in each guide that describes a format, beside the prose that says what each field means: the module file, the draw record, the output ring, the records of the kernel, the fault ring and the blocks of the data disk.

The details of the page are in [`docs/SITE.md`](../../../docs/SITE.md), "The byte layouts".

## Constraints

- The layout must never differ from the code. The names, the offsets and the sizes come from the contract (`src/library/modus/contract/module/format.odin`, `operation/operation.odin`, `store/store.odin`, ...) at each build of the site.
- A reader of the raw Markdown, on the host of the repository or in a terminal, must get the facts too: the guide holds a text form.
- The page holds no style attribute and no script of its own: the rules are in the style sheet (`site_inline_code_problem`).
- No text is cut, and no text lies over another text, at every width of the window.
- The diagram follows the light and the dark form of the site, and it is crisp at every zoom.
- Rectangular forms.

## The chosen form

**The tool reads the offsets from the compiler.** `modustool` imports `modus:contract/module` already. `type_info_of(module.Header)` gives the name, the offset and the size of each field, as the compiler lays out the struct that the system uses: no reading of the text, no sum of sizes. The parser of Odin (`core:odin/parser`) reads the same struct in `format.odin` for the comment of each field and for its type as the source writes it (`[PARAMETER_CAPACITY]u32`, not `[12]u32`). The two must name the same fields in the same order: the command stops when they do not.

**Rows of 8 bytes.** Each record of the module format is a multiple of 8 bytes, and each offset and size of the file is a 64-bit field: the format has no 32-bit variant ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "Requirements"). A row of 8 bytes holds a `u64` in one rectangle. A row of 32 bits, the width of the RFCs, cuts each `u64` over two rows and doubles the height of a diagram.

**A field over whole rows is one tall rectangle.** A field that starts at a row and covers two rows or more (`Import.hash`, `Function.parameter_names`) is one rectangle of 8 bytes wide and as many rows high. A field that does not start at a row, or that ends inside one, has one rectangle for each row that it crosses; the first holds its name and its size, the others its name and "continued". A run of bytes that no field uses is a rectangle "padding". The format has no padding today; a struct of the tests has some.

**A rectangle of more than 8 rows is folded.** A block of the data disk is 4096 bytes: 512 rows, and the array of the stores of the root block alone is 480. Drawn whole, a diagram is meters high, and the few fields around the array are lost in it. A rectangle of whole rows with more than `BYTE_LAYOUT_FOLD_ROWS` (8) rows is drawn 2 rows high: its first row and its last row, each with its offset, so the jump of the offsets at the left shows the fold. Its outline is dashed, and its text says the rows that it folds beside its size. The rectangles after it move up by the rows that it hides. 8 rows is one line of the cache: a field of that size or less is drawn whole, as before. The text form folds nothing: it is a list, one line for each field.

**HTML and a CSS grid, with classes.** The diagram is a grid of 9 columns: the offsets, then the 8 bytes. A rectangle is placed by classes (`byte-column-3`, `byte-span-4`, `byte-row-2`, `byte-rows-6`), because a style attribute is refused. The style sheet holds the rules of the classes up to the most rows of the grid of a layout of today, folds counted, which the tool computes from the type information. The lines are the outline of each rectangle in the color of a line of the site: 1 pixel of the screen at every zoom. A text is HTML text in the fonts of the site: it is sharp at every zoom, it wraps after each `_` of a name and grows its row, and a narrow window scrolls the box of the diagram sideways, as a table.

**A title gives the rest.** A pointer that rests on a rectangle shows the type of the field as the source writes it, its offset, its size and its comment. The caption names the struct as a type reference, which opens its type card.

**A fence is the marker, and its text is the text form.** A guide writes a fenced block with the language `byte-layout` and the names of the layouts after it: `module.Header module.Table_Entry`. Its body is the text form of each layout: a table of offsets, sizes, names and types in plain text. The site writes the diagrams in the place of the block. The body must be the text that the tool makes from the code: the site stops on another body, `modustool check` fails on it, and `modustool byte-layouts write` writes it again. So the raw Markdown never differs from the code either.

**One table of sources.** `byte_layout_sources` names each layout: the header, the entry of the table directory, the record of each table kind, then the draw record, the output ring, the records of the kernel, the fault ring and the blocks of the data disk, each group from its own procedure. A table kind with no record of a fixed size (the table Strings, bytes) states why. A host test fails on a table kind that has neither, so a new table of the format reaches the guide. The rebase table is words, not records: its layout is one word of `REBASE_WORD_SIZE` bytes, with the comment of that constant.

## Refused forms

- **A diagram drawn by hand in the guide.** It drifts the first time a field changes, and nothing checks it. The guide had only an outline of the file, for that reason.
- **An image file (PNG).** It is pixels: blurred when the reader zooms, one appearance only or two files, its text not found by the search of the browser and not read by a screen reader. It would also be a file to write again at each change of the format.
- **SVG.** It is crisp, and it can take the tokens of the style sheet. But the text of an SVG does not wrap: a name wider than its rectangle needs a width computed from the metrics of a font that the tool does not have (the site uses the fonts of the reader's system), so either the text is cut or every rectangle takes the width of the longest name. HTML wraps a name in its box with no measure.
- **Rows of 32 bits.** Each `u64` of the format crosses two rows.
- **A tall rectangle drawn whole.** A block of the disk is 512 rows high, and its few fields are lost in it.
- **Layouts of the records inside a block only, with no layout of the block.** The fields of the root block before and after its array of stores, and the padding that fills each block, would show nowhere.
- **A fold in the text form too.** The text form is a list of fields: a field is one line, whatever its size.
- **Inline styles for the place of a rectangle.** The page refuses a style attribute, so that a policy of the host can forbid inline style.
- **A table element.** A `table` gives each cell one row; a field of 6 rows is 6 cells, or a `rowspan` with a grid of empty cells to keep. A grid places a rectangle by its first byte and its span.
- **A body of the fence with the names only.** The raw Markdown would then hold no fact.
- **A text form with the grid of the RFCs in characters.** A field of 1 byte has a column of 9 characters: `parameter_count` does not fit. A list of offsets does not cut any name.

## Subtle points

- **The order of the fields of the type information is the order of the source**, and the check compares the names one by one. A field that the source adds and the type information does not have (a build of the tool from an older contract) stops the command.
- **The pass of the headings.** The site reads each guide twice; the first pass keeps the headings only. A fault of a fence is recorded in the second pass only, so it is printed once.
- **The rules of the rows.** A layout with more rows than the rules of the style sheet would have rectangles with no place. The rules come from the same table of sources, so a larger record gets its rules at the same build. The style sheet is written with no read of the sources, so the rules take the layout of each source from its type information alone (`byte_layout_of_type`): the folds need only the offsets and the sizes.

## State

Built: the table of sources, the reader of the comments, the HTML diagram with its folds, the text form and its check (site, `modustool check`, host test), the command `byte-layouts write`, and the diagrams of the guides: the module file, the output ring, the context and the error record (`docs/MODULE_CONTRACT.md`), the draw record (`docs/INTERFACE.md`), the record of a ring, the fault ring and the log record (`docs/ARCHITECTURE.md`), and the blocks of the data disk (`docs/STORAGE.md`).
