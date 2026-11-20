# Enum parameters

An export takes a value of a closed set as an enum. Its module file names the members, and that one description feeds each front end: the completion of the console, the check of a line before its call, and the row of buttons of the palette.

## The problem

- `settings.set(name: string, value: string)` took text for two closed sets. The console could not offer the values, found a wrong one only after the call, and the value of the second argument depended on the first, which no completion knew.
- Three processes each held a copy of the list of the settings: the console (`settings.descriptions`, to write the palette entries), the palette table (`Entry_Kind.Setting`, with the fields `setting` and `setting_value`) and the compositor (`settings_in_use`, to mark the value in use). A new setting, the scale, made the compositor write past an array of 6, and the console and the compositor counted the value in two units.
- The rule of the project says that a closed set is an enum, and that a word becomes its enum at the border. An export that takes text for a closed set breaks that rule at the border itself.

## The constraints

- Each front end reads the same description: no front end keeps its own list of a module.
- A wrong value is refused before the call, at its place in the line.
- No process gets a new right: the palette still dispatches through the console, its provider ([palette.md](palette.md)).
- The cost is paid once, at connect: completion filters a short list at each key.

## The chosen form

- **Enum is a type of the module format.** `module.Type.Enum` is a parameter or a result. The tables `Enums` and `Members` describe each enum: the name of its type, its size and sign, and each member with its name and its value. The format version is 6. A field of a record is never an Enum: a status field keeps its contract enum ([console_value_colors.md](console_value_colors.md)).
- **The describe step reads any enum of the module or of an imported package.** The type of a parameter or of a result that is an enum with a backing type of 1, 2, 4 or 8 bytes becomes an Enum. Each value is an integer literal or the value before plus one; the tool evaluates no other expression. A member is named in lower case: `French` becomes `french`.
- **The call carries the value of the member in a register.** The callee reads the low bytes of the size of the enum, as its compiler passes an enum of that size; a getter writes only those bytes, and each reader takes its result through `module.enum_value_of_register`. The receiver of an isolated call puts the whole register in the completion, as for an Integer (`isolated.completion_value`): a receiver that kept only Integer, Text and Table results gave 0, the first member, for each Enum result.
- **One named argument for each setting.** `settings.set` takes one optional argument for each setting, of the enum of its setting: `settings.set(keyboard_layout = .french)`. Each value is its own parameter, so no value depends on another, and the completion needs no special case. A call may give several settings at once.
- **An optional parameter is an Enum, and its absent word is each bit of its size set.** `Function.optional_parameters`, two bytes that were reserved, has one bit for each parameter that a call may leave out. The console writes -1 in the register; the callee reads all ones at its size (`enum_word.member_of_argument` gives `given` false). No member may have that value: the describe step and `module.enum_type` refuse it. The source states it with the attribute `optional_parameters = "font, scale"`.
- **The value in use comes from a getter that the parameter names.** The detail of an Enum parameter holds the index of its enum and the index of its getter export (`module.enum_detail_of`). The source names it with the attribute `enum_getters = "font = font, ..."`: the pairing is explicit, never found by a name. A getter takes no parameter, gives no error record, and gives an equal enum (`module.function_enums_check`). `settings.font()` and the six others are the getters of `settings.set`.
- **The console completes, checks and writes the member.** A line names a member after a dot, `.french`: Lex has a node `Member`, typed by the Enum parameter that receives it, as a record literal is typed by its Record parameter. The evaluator checks the name against the enum of its parameter at its place, before any argument of the call runs (`Member_Unknown`, `Member_No_Type`). The value of a call is an Enum value, drawn as `.french`; a value of another enum is refused as each argument of another type is. After a `.` at an argument of an Enum parameter, and with Tab at the start of such an argument, the completion lists the members.
- **The palette shows one row of buttons for each Enum parameter of an export whose call with one member is a choice:** an export of one parameter, an Enum, or an export whose parameters are each an optional Enum. Each member is an entry of the kind `Provider_Setting`, whose line is the call with that member; the entries of one parameter share the name of the row (the parameter) and the act name (`settings.set:font`), so the panel joins them into one row. Such an export has no entry of its own beside its rows. An export with other parameters opens as a form, whose Enum field takes its members as closed candidates (`Candidate_Kind.Member`), or in the console.
- **The getters are called when the panel opens.** At `Refresh` the console asks for a refresh of the marks and calls the getter of each row, and keeps each member in use by its act name. The table written after a line keeps those marks. After a line that the palette ran, the console asks for a refresh again, so the row shows the member that the choice set. A row with no getter, or whose getter gave no answer, has no mark: a getter that gave none removes the mark that its row kept.
- **The time zone is no argument of `set`.** A zone is a number of minutes, not a member of a closed set: `settings.set_time_zone("+08:00")` sets it and `settings.time_zone()` gives its text.
- **What went:** `Entry_Kind.Setting` and its fields `setting` and `setting_value` (reserved bytes now, version 7 of the palette table), `Candidate_Kind.Setting`, the built-in command `setting(name, value)`, `settings.get`, the copy of `settings.descriptions` in the console, and `settings_in_use` in the compositor. `settings.descriptions` stays for the window of `settings` only.

## The refused forms

- **Text for a closed set.** The console cannot offer the values and finds a wrong one after the call; the export parses a word that the border already knew.
- **One export `set(name, value)` with a completer for the second argument that reads the first.** It makes the completion of one export a special case, and every other export with a dependent argument needs its own.
- **A table of the settings in the console or in the palette.** It is a second copy of the contract of `settings`, which drifts: the crash of the compositor came from such a copy.
- **A getter found by its name.** A palette that looks for an export with the name of the parameter guesses: a rename breaks it in silence. The pairing is written in the module file.
- **Completion from the line history.** It guesses values; the type knows them.
- **A row of the palette for each enum parameter of each export.** An export with a required parameter beside its enum is a call with arguments, not a choice: it opens as a form or in the console.
- **The Enum as an Integer with a mark in its detail.** Each reader that does not know enums would then read a member as a plain number and call with any value. A new type makes the compiler name each switch that must take it.
- **A sentinel member, `Unchanged`, for a setting left out.** The console would complete it and the palette would show it as a button: it is no value of the setting.
- **A getter called after each line.** It is one call for each row after each line; the design calls each getter when the panel opens, where the mark is read.
- **The rows of `settings` with no connection.** The palette lists what the console can call now ([palette.md](palette.md), "The scheduling strategy"): the rows appear after `connect("settings")`, as each export of a service does.
- **A default value of the source as the mark of an optional parameter.** A default of a parameter of a procedure "c" is a fact of the Odin callers only, and no reader of the call sees it.

## The subtle points

- **A member is named, never numbered.** A line names `.french`; the console writes the value of the member that the module file gives. A value that names no member is refused at the border of the export too: `settings.choice_of_arguments` takes each argument through `enum_word.member_of_argument`.
- **The value of a member is part of the contract.** An enum that crosses the border gives its values explicitly, so a new member never moves the value of another. Two enums are one when their names, sizes, signs, member names and values are equal (`module.enums_equal`): the check of a replacement compares them so, and an optional bit too; the getter is an index of one file and is not compared.
- **The absent word is a word, not a member.** The bytes of the size all set: 255 for an enum of one unsigned byte, -1 for a signed one. `Scale` is an enum of one byte from 10 to 16, so 255 is free.
- **A member past the window bound.** `scale_factor.Scale` names the scales up to 2; the export refuses those past the window bound with `Out_Of_Range`. The palette shows each member: the type has them, and the refusal is a fact of the export, which the panel shows in words.
- **The count of entries.** One entry for each member of each row is a few tens of entries for the settings: 29 for the seven settings, within the 256 of the table. The palette with any count of entries ([palette.md](palette.md), "Any count of entries") removes the bound of the table.
- **A getter is a call of a service or of an isolated process, on the thread of the lines.** The first thread holds the keys and never waits for another process: at `Refresh` it sets one word and wakes the thread of the lines, which owns the rings of the services. That thread calls the getters when no line waits, and a line typed meanwhile waits for the end of the refresh. The panel opens at once on the table of now, and the marks arrive when the getters answer.
  - **One bound for the whole refresh**, 1 s (`PALETTE_GETTERS_LIMIT`): N rows of a slow service hold the thread of the lines for at most that time, not for N times it. A service that missed a getter (no answer, a refused call, or a stop) is asked nothing more in that refresh.
  - **No getter of a module in the process of the console.** A direct call has no bound: a getter that loops would hold the console for good. A module that `load` placed in the console has rows with no mark; `isolate` gives its getters a bound.
  - **Refused: the getters on the first thread.** A slow service held the keys for 1 s for each row, and a direct getter that loops froze them for good.
  - **Refused: to clear the marks at each open.** The marks of the last refresh stay until the getters answer, so a mark does not blink at each open; a getter that gives no member removes its mark.
- **A name in a line of the palette is a name of Lex.** The line of a row is built from the name of the export, of its service and of its parameter, which another party wrote in its module file: `h.f(a = .x)`. The console makes no command of an export whose name or a name of a parameter is no name of Lex (`lex_parser.name_valid`), so a parameter named `a=shutdown(),b` cannot put a call of its own in that line. A member name is checked by `module.enum_type`.
- **The flag of the compiler.** `log_fact`, `enum_getters` and `optional_parameters` are custom attributes that the compiler ignores with one flag (`foundation.CUSTOM_ATTRIBUTES_FLAG`); the tool reads them from the syntax tree.

## State

Built: the type Enum and the tables of the format, their checks (`module.enum_type`, `module.function_enums_check`, the manual's check of a file, the writer of module files, the check of a replacement), the describe step with the two attributes, the border `enum_word.member_of_argument`, the console (the member of Lex, its check, the optional parameters, the completion, the drawer), the call of the tool (`modustool call` with named arguments and members), the palette rows with their getters, and `settings.set` with its seven getters, `set_time_zone` and `time_zone`.

Left:

- An import declaration of an export with an Enum parameter: the tool reads no enum in a `foreign` declaration yet, so an importer cannot declare one.
- A record field of an enum of a module stays a plain Integer: the field kind Status names contract enums only.
- The manual shows an Enum parameter by the name of its enum; a page that lists its members waits for a need.
