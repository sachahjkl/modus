# The color of a field by its value kind

## Purpose

The console draws a record and a table from the description of their record. A field had only its type there: Integer, Text or Handle. So a size in pages, a time in milliseconds and a plain count had one color and no unit: a reader read `120` and did not know what it counted. The log and the site already show a size, a time and a number each in the color of its value kind, with its unit after it ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "The colors of values"). A table of the console is the place where values of mixed kinds follow one another most, so it follows the same rule.

## Constraints

- **The drawer knows no command.** It reads the value and the description of the record. So the value kind of a field must be in the description, and nowhere else.
- **No text is classified by its look.** A field named `used_pages` is not a size because of its name. The writer of the description states the kind.
- **A color is never the only sign.** Number and Size have the same accent (the memory teal), and a reader who does not see colors must still read the kind. The unit text is that sign.
- **One fact once on a screen.** The unit of a column is the same in each row, so it is written one time, in the head.
- **One table of colors.** The console takes each color from `graphics.value_kind_colors`, as the log and the site do. No color is new.

## The chosen form

**In the description.** A field of a record states its integer unit (`docs/glossary/running_code.md`, "Integer unit"), as a parameter does: `module.Field.integer_unit`, two bytes that were reserved, the value kind (`Size` or `Time`) and its unit. A plain number, a Text and a Handle have `{}`. The source gives an Integer field a distinct type of `modus:contract/value_kinds` (`time: value_kinds.Time_In_Milliseconds`), as for a parameter; the describe tool writes the unit; a built-in table of the console gives it in the column (`console_results.size_column`, `time_column`). `module.record_type` and `information.check` refuse a unit that is not one of the contract, or a unit on a field that is not an Integer. Two records with another unit on one field are not equal: the check of a replacement and of an import declaration refuse them, because the unit is part of what the field means.

**The value kind of a field**, for the drawer (`console_results.cell_of`):

| Field | Value kind | Color token | Non-color sign |
|---|---|---|---|
| Integer, no unit | Number | Memory | The digits at the right of the column |
| Integer, a unit of kind Size | Size | Memory | The unit after the value, or in the head |
| Integer, a unit of kind Time | Time | Boot program | The unit after the value, or in the head |
| Handle | Handle | Kernel | The field is a handle in the description, and `Handle` in `describe` |
| Text | None | The color of the text | It is at the left of its column |

A Text field has no kind: the description has no place for the kind of a text, and a text is not classified by its look.

**A table.** The head of a column of a Size or a Time is its name, then the unit in parentheses: `time (ms)`. Each cell holds the number only, in the color of its kind, at the right of its column. The column is as wide as its head with its unit. The head is dim, as each head is.

**A record.** One line for each field: the name, then the value, then its unit after one space, both in the color of the kind: `time  120 ms`. This is how the log writes a size or a time.

**The contrast.** Each color is the color of the log on a dark surface, and the console has the background of a dark surface. `src/library/support/graphics/value_colors_test.odin` keeps each kind at 4.5 to 1 or more there.

## Refused forms

- **The unit in each cell.** It repeats one fact in each row, and the widths of a column grow by the unit. The head says it once.
- **The kind of a field from its name.** It is a guess from the look of a text: a name can be in another language, or wrong.
- **A second table of colors for the console.** Two tables drift apart; a reader then sees one kind in two colors.
- **A new field of four bytes for the kind.** The two reserved bytes hold an integer unit exactly, and the parameter already uses that form. A field does not change size, and no reader of a description changes but to read the two bytes.
- **A kind for a Text field (Module, Version, Status).** The source has no type that says it for an array of bytes, and a polymorphic type of the contract for each kind of text is more than this need. It stays plain until a design gives a source form.

## Subtle points

- The unit of a Size column of a built-in table is in its head, so a built-in column has no unit in its name: `memory()` gives `used` in pages, not `used_pages`, and `modules()` gives `size` in bytes.
- `columns` and `join` copy the unit of each field into the new description: a column keeps its kind after the command.
- A record that another party wrote is checked before the drawer reads its unit. The drawer still treats a unit that is not valid as a plain number.
- The log of the console has the text only, with no value run: a machine test reads the head with its unit (`time (ms)`), and the host tests of the drawer check the kind of each cell.

## State

Built: the unit of an Integer field in the module contract, its checks, the describe tool, the drawers of a record and a table, the built-in tables `memory()`, `modules()`, `measure_completion()`, and the record `Program` of the monitor. Left: a kind for a Text field; the unit of a field in the palette and in the manual.
