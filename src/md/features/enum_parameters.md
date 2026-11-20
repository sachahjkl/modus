# Enum parameters

An export takes a value of a closed set as an enum. Its module file names the members, and that one description feeds each front end: the completion of the console, the check of a line before its call, and the row of buttons of the palette.

## The problem

- `settings.set(name: string, value: string)` takes text for two closed sets. The console cannot offer the values, finds a wrong one only after the call, and the value of the second argument depends on the first, which no completion knows.
- Three processes each hold a copy of the list of the settings: the console (`settings.descriptions`, to write the palette entries), the palette table (`Entry_Kind.Setting`, with the fields `setting` and `setting_value`) and the compositor (`settings_in_use`, to mark the value in use). A new setting, the scale, made the compositor write past an array of 6, and the console and the compositor counted the value in two units.
- The rule of the project says that a closed set is an enum, and that a word becomes its enum at the border. An export that takes text for a closed set breaks that rule at the border itself.

## The constraints

- Each front end reads the same description: no front end keeps its own list of a module.
- A wrong value is refused before the call, at its place in the line.
- No process gets a new right: the palette still dispatches through the console, its provider ([palette.md](palette.md)).
- The cost is paid once, at connect: completion filters a short list at each key.

## The chosen form

- **Enum is a kind of parameter.** The describe step of the tool writes, for a parameter of an enum type, the kind Enum and the names of its members with their values, in the module file. The type is any enum of the contract or of the module, not only the closed list of the contract enums of the field kinds.
- **One named argument for each setting.** `settings.set` takes one optional named argument for each setting: `settings.set(keyboard_layout = .french)`. Each value is its own parameter, so no value depends on another, and the completion needs no special case.
- **The console completes and checks.** After the name of a named argument, or at the place of a positional one, the console offers the members of its type. A member that the type does not name is refused at its place, before the call, as a wrong kind is refused today. The member names come from the module file at connect.
- **The palette shows one row of buttons for each export of one enum parameter.** Each member is a button, and its choice runs the call through the console. The rows of `settings` come from its export, as the row of buttons of a field with a few closed values comes today.
- **The value in use comes from a getter that the export names.** The parameter of the setter names, in the module file, an export that gives its value: `settings.keyboard_layout() -> Keyboard_Layout`. The palette calls it when it opens, one call for each row. A setter with no getter shows its buttons with no value marked.
- **What goes:** `Entry_Kind.Setting` and its fields, the copy of `settings.descriptions` in the console, and `settings_in_use` in the compositor.

## The refused forms

- **Text for a closed set.** The console cannot offer the values and finds a wrong one after the call; the export parses a word that the border already knew.
- **One export `set(name, value)` with a completer for the second argument that reads the first.** It makes the completion of one export a special case, and every other export with a dependent argument needs its own.
- **A table of the settings in the console or in the palette.** It is a second copy of the contract of `settings`, which drifts: the crash of the compositor came from such a copy.
- **A getter found by its name.** A palette that looks for an export with the name of the parameter guesses: a rename breaks it in silence. The pairing is written in the module file.
- **Completion from the line history.** It guesses values; the type knows them.
- **A row of the palette for each enum parameter of each export.** An export with several parameters is a call with arguments, not a choice: it opens in the console with completion, as today.

## The subtle points

- **A member is named, never numbered.** A line names `.french`; the console writes the value of the member that the module file gives. A value that names no member is refused at the border of the export too, as each enum that crosses a border.
- **The value of a member is part of the contract.** An enum that crosses the border gives its values explicitly, so a new member never moves the value of another.
- **The count of entries.** One button for each member of each row is a few tens of entries for the settings. The palette with any count of entries ([palette.md](palette.md), "Any count of entries") removes the bound of the table.

## State

Designed, not built. The roadmap entry "Enum parameters: one description for the completion, the check and the palette" holds the work; `settings` is its first user.
