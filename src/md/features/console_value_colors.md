# The color of a field by its value kind

## Purpose

The console draws a record and a table from the description of their record. A field had only its type there: Integer, Text or Handle. So a size in pages, a time in milliseconds and a plain count had one color and no unit: a reader read `120` and did not know what it counted. The log and the site already show a size, a time and a number each in the color of its value kind, with its unit after it ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "The colors of values"). A table of the console is the place where values of mixed kinds follow one another most, so it follows the same rule.

The log facts ([log_facts.md](log_facts.md)) need four more kinds that a line of the log writes today and a description lacked: an address or a check in hexadecimal, a status of the contract by its name, the name of a module, and a hash. The exports take them first, so that each reader of a description knows them before a fact uses them.

## Constraints

- **The drawer knows no command.** It reads the value and the description of the record. So the value kind of a field must be in the description, and nowhere else.
- **No text is classified by its look.** A field named `used_pages` is not a size because of its name. The writer of the description states the kind.
- **A color is never the only sign.** Number and Size have the same accent (the memory teal), and a reader who does not see colors must still read the kind. The unit text is that sign.
- **One fact once on a screen.** The unit of a column is the same in each row, so it is written one time, in the head.
- **One table of colors.** The console takes each color from `graphics.value_kind_colors`, as the log and the site do. No color is new.
- **A description is hostile input.** A byte of a kind comes from a module file: each reader takes it through one border, which refuses a byte that names no member.

## The chosen form

**In the description.** A field of a record states its integer unit (`docs/glossary/running_code.md`, "Integer unit"), as a parameter does: `module.Field.integer_unit`, two bytes that were reserved, the value kind (`Size` or `Time`) and its unit. A plain number, a Text and a Handle have `{}`. The source gives an Integer field a distinct type of `modus:contract/value_kinds` (`time: value_kinds.Time_In_Milliseconds`), as for a parameter; the describe tool writes the unit; a built-in table of the console gives it in the column (`console_results.size_column`, `time_column`). `module.record_type` and `information.check` refuse a unit that is not one of the contract, or a unit on a field that is not an Integer. Two records with another unit on one field are not equal: the check of a replacement and of an import declaration refuse them, because the unit is part of what the field means.

**The field kind** (`docs/glossary/running_code.md`, "Field kind") says how a reader writes a value that is not a plain number or a plain text. It is `module.Field.kind`, the byte of `value_kinds.Field_Kind`, and `module.Field.contract_enum`, the byte of `value_kinds.Contract_Enum` for a status. The two bytes were reserved and zero, and zero is `Plain` and `None`: the meaning of every field before.

| Field kind | Field type | Source type | A reader writes |
|---|---|---|---|
| `Plain` | Integer, Text, Handle | `i64`, `[N]u8`, `Lent({...})` | As before |
| `Hexadecimal` | Integer of 1, 2, 4 or 8 bytes, no unit | `value_kinds.Hexadecimal_8` to `Hexadecimal_64` | `0x` and the digits |
| `Status` | Unsigned Integer, no unit | a contract enum of `value_kinds.CONTRACT_ENUM_TYPES`: `operation.Status`, `operation.Log_Level`, `errors.Kind`, or its word type: `operation.Status_Word`, `errors.Kind_Word`, `errors.Unit_Word` | The name of the member |
| `Module_Name` | Text | `value_kinds.Module_Name_Field`, 32 bytes | The text |
| `Hash` | Bytes, 1 to 32 bytes | `value_kinds.Hash_Field`, 32 bytes; `value_kinds.Hash_Sixteen_Bytes_Field`, 16 bytes | Two hexadecimal digits for each byte |
| `Fact_Values` | Bytes, 144 bytes | `value_kinds.Fact_Values_Field`, 144 bytes | Two hexadecimal digits for each byte, up to the last byte that is not zero |
| `Hexadecimal_Sixteen_Digits` | Unsigned Integer of 8 bytes, no unit | `value_kinds.Hexadecimal_Sixteen_Digits` | 16 hexadecimal digits with no `0x` |
| `Hash_Head` | Bytes, 32 bytes | `value_kinds.Hash_Head_Field` | The digits of the first 4 bytes, then `…` |
| `Hundredths` | Integer, no unit | `value_kinds.Hundredths`, 8 bytes with a sign | n / 100 with two decimals: `1.05`, `-0.50` |
| `Nanoseconds_As_Microseconds` | Unsigned Integer, no unit | `value_kinds.Nanoseconds_As_Microseconds`, 8 bytes | Microseconds with one decimal, cut, then ` us`: `812.4 us` |
| `Tenths` | Integer, no unit | `value_kinds.Tenths`, 8 bytes with a sign | n / 10 with one decimal: `12.3`, `-0.5` |
| `Hexadecimal_No_Leading_Zero` | Unsigned Integer of 8 bytes, no unit | `value_kinds.Hexadecimal_No_Leading_Zero` | `0x` and the digits with no zero before the first: `0x1a2b` |
| `Time_Of_Day` | Unsigned Integer, no unit | `value_kinds.Time_Of_Day`, 8 bytes | The hours and the minutes: `07:04` |
| `Text_View` | Bytes, 16 bytes | `value_kinds.Text_View` | Its text; in a table, which holds no out-of-line area, a text past 12 bytes is its first 4 bytes, `…` and its length |

`module.field_kind_valid` and `information.check` refuse each other pair: a kind on a field of another type, a unit beside a kind, a Status with no enum or with a sign, an enum on a field that is not a Status, a Bytes field that is not a Hash, the head of a hash or the values of a fact, a head of a hash of another size than a whole hash, 16 digits on a field of another size than 8 bytes or with a sign, nanoseconds with a sign, a field of fact values of another size than `op.LOG_FACT_VALUE_CAPACITY`, and a reserved byte that is not 0. A field of the type Bytes exists only for a hash, its head and the values of a log fact: a byte string with no kind has no form for a reader. Two records whose field differs by its kind or its enum are not equal. The four last kinds take their form from the kind alone, and one procedure of the contract writes it, `module.field_kind_text`: the sentence of a fact and a cell of a column write one text for one field ([log_facts.md](log_facts.md), "Field kinds").

**The values of a fact.** `log.fact_records` gives the value bytes of each fact whole, so that a reader renders it ([log_facts.md](log_facts.md), "The reader path"). The bytes have a description: the record of the fact type that the module hash and the fact key of the same row name. So they are not bytes of any content, and their kind says what they are. A reader that has the description writes the sentence; the drawer of a table has only the row, so it writes the raw form: the bytes in hexadecimal up to the last byte that is not zero, as the serial line of a fact. The zeros after it are not written, so a cell of a small fact is short.

**The contract enums.** A status is written by name because each reader compiles the contract in: `module.contract_enum_member_name` gives the name of a member, and refuses a word that names no member of that enum. `Log_Record_Form` is a member of the list, so a row of `log.records` says `Text` or `Fact`. A reader then writes the number in decimal, as a Number, never a name of another member. The list is closed: an enum that a fact needs is a new member of `Contract_Enum`, with its names in the contract. `Stop_Cause` and `Stop_Outcome` came so, for the stop of a process as a log fact of the root service.

**The words of a member in a sentence.** A column and a condition name a member by its name (`Itself`, `Done`), which a principal types. The sentence of a log fact writes the words of the member, `module.contract_enum_member_words`: the name for `Status`, `Log_Level` and `Log_Record_Form`, and the words of a reader for a stop cause and a stop outcome (`itself`, `a holder`, `done`, from `STOP_CAUSE_TEXTS` and `STOP_OUTCOME_TEXTS`). Each line of a stop wrote those words before the facts, and each machine test waits for them: with the name, the template of the stop could not write the sentence of today. The refused form: the words as the names of the members, which a condition then reads with spaces ("a holder") and in two forms of case. An enum of a module has no names in the module file, so its field stays a plain Integer ([log_facts.md](log_facts.md), "Open questions").

**The value kind of a field**, for the drawer (`console_results.cell_of`):

| Field | Value kind | Color token | Non-color sign |
|---|---|---|---|
| Integer, no unit | Number | Memory | The digits at the right of the column |
| Integer, a unit of kind Size | Size | Memory | The unit after the value, or in the head |
| Integer, a unit of kind Time | Time | Boot program | The unit after the value, or in the head |
| Integer, Hexadecimal | Number | Memory | `0x` before the digits |
| Integer, Status | Status | The color of a status | A name of letters, at the left of its column |
| Integer, Status of a word that names no member | Number | Memory | The digits, with no name |
| Handle | Handle | Kernel | The field is a handle in the description, and `Handle` in `describe` |
| Text | None | The color of the text | It is at the left of its column |
| Text, Module_Name | Module | The color of a module | `Module_Name(32)` in `describe` |
| Bytes, Hash | Version | The color of a version | Hexadecimal digits at the left, `Hash(32)` in `describe` |
| Bytes, Fact_Values | Number | Memory | Hexadecimal digits at the left, `Fact_Values(144)` in `describe` |
| Integer, Hexadecimal_Sixteen_Digits | Number | Memory | 16 digits at the right, `Hexadecimal_Sixteen_Digits` in `describe` |
| Bytes, Hash_Head | Version | The color of a version | 8 digits and `…`, `Hash_Head(32)` in `describe` |
| Integer, Hundredths | Number | Memory | A point before the last two digits, at the right |
| Integer, Nanoseconds_As_Microseconds | Time | Boot program | ` us` after the value, in the cell, at the right |

A plain Text field has no kind: a text is not classified by its look.

**A table.** The head of a column of a Size or a Time is its name, then the unit in parentheses: `time (ms)`. Each cell holds the number only, in the color of its kind, at the right of its column. The column is as wide as its head with its unit. The head is dim, as each head is. The other kinds have no unit, so their head is the name only.

**A record.** One line for each field: the name, then the value, then its unit after one space, both in the color of the kind: `time  120 ms`. This is how the log writes a size or a time.

**The palette.** A result that the console draws in the palette has the same parts: `palette_table.Run_Part` has one member for each part of `console_results.Part`, `Module` and `Version` too.

**The contrast.** Each color is the color of the log on a dark surface, and the console has the background of a dark surface. `src/library/modus/graphics/value_colors_test.odin` keeps each kind at 4.5 to 1 or more there.

## Refused forms

- **The unit in each cell.** It repeats one fact in each row, and the widths of a column grow by the unit. The head says it once.
- **The kind of a field from its name.** It is a guess from the look of a text: a name can be in another language, or wrong.
- **A second table of colors for the console.** Two tables drift apart; a reader then sees one kind in two colors.
- **A new field of four bytes for the kind.** The two reserved bytes hold an integer unit exactly, and the parameter already uses that form. A field does not change size, and no reader of a description changes but to read the two bytes.
- **The field kind in the integer unit.** A hash and a module name are not a unit of an Integer, and a Status needs its enum beside it. The four other reserved bytes hold the kind, the enum and two reserved bytes, so the field keeps its 24 bytes.
- **A hash as a Text field.** A Text ends at its first zero byte and is UTF-8; a hash has zero bytes and is not text. It is a Bytes field.
- **A Bytes field of any content.** A reader has no form for bytes that say nothing of what they are. A Bytes field is a hash or the values of a log fact, whose description the same row names, until a design gives another kind.
- **The values of a fact as a Hash.** A hash has at most 32 bytes and the color of a version; the values have 144 bytes and are no version. One kind for two meanings is the guess that this file refuses.
- **The values of a fact as 18 Integer fields.** A reader then joins 18 columns again into one byte string, and a table of the rows draws 18 numbers that mean nothing alone.
- **The names of a status from the runtime type information.** Its tables hold addresses that the loader rebases, and they describe the types of one language. The contract holds a table of names for each enum of the list.
- **A Status with a sign.** A member of a contract enum is never negative, and an unsigned field gives each word one meaning.

## Subtle points

- The unit of a Size column of a built-in table is in its head, so a built-in column has no unit in its name: `memory()` gives `used` in pages, not `used_pages`, and `modules()` gives `size` in bytes.
- `columns` and `join` copy the unit and the kind of each field into the new description: a column keeps its kind after the command.
- A record that another party wrote is checked before the drawer reads its unit and its kind. The drawer still treats a unit that is not valid as a plain number, and a Status word that names no member as a number.
- `where`, `sort` and `join` compare an Integer or a Text. A Hash field and a field of fact values are neither, and the console refuses them there with the type of the field. `variable.field` of a Hash field gives its bytes, which the console draws as Bytes. A record with a Hash field gets no command that makes it: the console has no value of a hash to type.
- The log of the console has the text only, with no value run: a machine test reads the head with its unit (`time (ms)`), and the host tests of the drawer check the kind of each cell.
- The format version of a module does not change for the kinds: the bytes were reserved and zero, and zero keeps its meaning. The version changes with the table `Facts` of the log facts.

## State

Built: the unit of an Integer field in the module contract, its checks, the describe tool, the drawers of a record and a table, the built-in tables `memory()`, `modules()`, `measure_completion()`, and the record `Process` of the monitor. The field kinds `Hexadecimal`, `Status`, `Module_Name`, `Hash` and `Fact_Values`, the contract enums `Status`, `Log_Level`, `Log_Record_Form`, `Stop_Cause` and `Stop_Outcome`, the words of a member in a sentence, their source types, their borders and checks, the describe tool, the drawers of the console and of the palette, and the pages of the types of the site. Left: the unit of a field in the palette and in the manual; a module of the system that takes a field of a new kind in an export.
