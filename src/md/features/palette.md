# The palette

The palette is one panel that a key opens. It reaches every operation that the principal of the session can do: start a process, bring a window to the front, close a window, run a command of the console with its arguments, set a setting, set the scheduling strategy. It replaced the launcher, and the term launcher left the system.

What the panel looks like and what each key does is in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "Palette". The provider is in [`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "8. The palette provider". This file records why the palette has this form.

## The problem

Before the palette, two processes held every operation. The compositor held the windows and the start of a process. The console held all the rest: the root ring, the calls of the services, the settings, the principals, the grants, the debugger, the shutdown. "Every operation from one panel" asks for a panel that reaches both sets.

Lex, the language of the console, is not a set of operations. `where` and `columns` have no meaning alone, and a form with one field for each parameter cannot give a Table. So "every operation" is each act, and one step to the console for a composed line.

## The constraints

- **No ambient access.** A broad grant is rare, visible and revocable. A second process with every grant, beside the console, doubles the richest target of the system.
- **The typed text reaches no process that does not need it, and no process can draw a false palette.** Only the compositor keeps both: it keeps the key super, and it draws over each window.
- **No text between processes.** If the compositor builds the text `revoke("net", "network")` and the console parses it, one process prints and another parses.
- **The loop of the compositor waits for no process**, and does no work in proportion to a table that another process wrote.

## The chosen form: a panel and a provider

The palette is two parts with one ring between them.

- **The panel** is in the compositor. It owns the keys, the pixels, the list and the fuzzy match. It holds no new right. Two kinds of entries are its own, from tables that it already has: the processes and the windows. They work with no console. The window in front adds three entries of its own, "move window" and "resize window" (the second when the window is resizable and no resize of it waits for its process), whose choice gives the arrows to the compositor ([accessibility.md](accessibility.md), "3. Keyboard access to everything"), and "maximize window", named "restore window" while the window is maximized, whose choice toggles it ([window_resize.md](window_resize.md), "The maximize").
- **The palette provider** is the console. It already holds each grant that a command needs. It writes the entry table, a memory object that the compositor maps read-only: one entry for each row of its command table, with the parameters as data. On a choice, it runs the command as a typed line: the line is echoed in its terminal, the drawers draw the result, and the line goes in the line history.
- **The grant** is `Palette`, a grant of the console. `grants("console")` shows it. `revoke("console", "palette")` ends the ring and the mapping, and the palette keeps the processes and the windows.

Why this gives no process a new authority: the compositor already routes each key to the console, so it can already type `shutdown()` there. The ring adds a face, not a power.

- A compromised compositor gains nothing. It already owns each key and each pixel.
- A compromised console can show an entry whose name lies. It needs no palette to do harm: it holds the grants. The compositor, not the provider, draws the confirmation of an entry that destroys.
- A process without the grant gains nothing. The table and the ring are handles that the root service gives to two processes only.

How a module adds its operations: it exports a described function and is a service. It writes no table and no code for the palette. The description of an export is the one source of each front end.

## The refused forms

- **A palette process with its own grants.** It is a second process with every right. It also needs a second command table, a second checker of arguments and a second set of drawers.
- **The compositor dispatches entries that each service contributes.** The compositor must then hold a connection to each service and act for the principal: the process that reads each hostile surface gets the rights of the principal. Or the root service calls an export for a caller, which makes it a deputy. The good part of this form is kept: an entry is data from a described export, and the panel only dispatches.
- **The compositor sends the text of a line.** Refused by the rule of no text between processes. The compositor sends an index and typed values. The console builds its own line.
- **A border of 1 pixel around the whole panel.** The request was an input that is flush with the top, the left and the right edges. The band has no border on those three sides; its fill and the line under it are its edge. The rest of the panel keeps a border, because the design rules allow no shadow and no scrim, and a card on a dark window has too little contrast without an edge.
- **Groups in a ranked list.** A group header takes a row, and the best match must be the first row. Groups exist only when nothing is typed.
- **A record or a table drawn in the panel in the first form.** A table opens in the console: the drawers, the scroll and the line to compose are there. A reader of hostile descriptions in the compositor was not worth one saved step. A Record is now shown in the panel as the runs that the drawer of the console wrote.
- **A store for the recent choices of the compositor.** The recent commands survive a stop through the line history of the console, with no new store and no new grant. The recent processes and windows live in the memory of the compositor.

## The subtle points

- **The palette runs the row that is drawn.** The command table of the console changes (`load`, `unload`, `connect`). A choice carries the change count of the table that the panel showed, the index, and the hash of the name of the entry. The console checks the three against its own copy, and refuses a choice that names another entry. A list that arrives late does not move the choice. This was the test designed to break the form on its first day: Enter before the table moves.
- **The table is hostile input.** The compositor copies the table, then checks the copy: the count of entries, each length, each kind, and a change count that never becomes even. A table that fails gives the processes and the windows only, with one line of the log.
- **The values go as records with kinds, not as a line.** An Integer goes as a number, a Text as bytes. The console checks each value again before the call, as for a typed line. A parameter of the kind Record, Table, Handle or Bytes has no field: the entry opens the console.
- **The confirmation belongs to the compositor.** An entry that destroys asks for a second Enter on a row that says the act in full. The provider cannot skip it. An export of a service has no such fact in its description, so only the built-in commands of the console have the flag. This confirmation is a duty of the role of the trusted display, under the same contract as a grant dialog ([powerbox.md](powerbox.md), "The trusted display"): a replacement compositor that holds the role draws it, with the same rules.
- **A mark says a fact, never a kind alone.** The kind of a row is in words at its right and in the form of its icon; a color never stands alone for a fact.
- **The ranking of a few hundred entries from another process does not run in the loop of the compositor.** A second thread of the compositor copies the table and ranks. The loop gives it the query with a number, waits on a word in its one wait, and adopts only the list of the newest number.
- **The panel opens with no animation**, in the next frame, and has a fixed height: the input line never moves when the list changes.
- **A locked principal.** The console runs in the session of the machine. With a named principal locked, the palette offers what the console offers. This is a fact of the console, not a new hole of the palette; it is a question for the design of the principals.
- **When the console does not run**, the palette lists the processes and the windows and says that the commands are absent. `console` is a process of the list, so the palette starts it.

## Enter with nothing to run

Enter in the search with no chosen entry runs nothing, and the panel stays open with its typed part, so the principal can change it. It is not silent: the detail line, where the chosen entry says what it does, says "nothing to run" in the color of a failure (`palette.nothing_to_run_show`, `palette.detail_note`). The note goes at the next edit of the typed part and at the next open, and a chosen entry takes the line again. The list says why when it is empty ("nothing has … in its name"); the note says what Enter did, which the list cannot say. A refused form: Enter that closes the panel, which loses the typed part for a key that did nothing.

## The scheduling strategy

The palette reaches each operation that a command of the console reaches. No command set the scheduling strategy: only the window of the process `scheduler` did.

**The constraint.** A change of the strategy needs the right Schedule on the machine handle. One process holds it: `scheduler`. The console holds Inspect and Stop, not Schedule.

**The chosen form.** The process that holds the right gets a new face, and no process gets a new right over the machine.

- `scheduler` is a service: it exports `strategy_set(name)`. It serves its calls in the loop of its window, after its checks: the checks change the strategy themselves, and a call during them changes what they measure.
- The console has the command `strategy(name)`, the export under a short name. It connects at the first use.
- The provider writes one entry for each strategy, "set strategy to eevdf", as it does for each member of an enum parameter of an export ([enum_parameters.md](enum_parameters.md)). The line of the entry is `strategy("eevdf")`.
- The process `scheduler` must run, as `settings` must run for a setting. The command starts no process: its error shows in the panel.

The grant that `scheduler` gains is Serve: the right to be called. Each caller still needs a connection, which the root service gives to the console and to no process without the grant to connect.

**A service that uses its own right for a caller.** The rule against the confused deputy says that a service does not combine its own access with a name from the caller ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). `strategy_set` does use the right of `scheduler` at the request of a caller. It keeps the rule in the way that `settings.set` and `monitor.processes` keep it: it serves only a caller that acts for the principal, a grant of the root service that is recorded, shown by `grants()` and revoked by `revoke()`. The request is then the request of the principal, and the name that the caller gives is one of three values of a closed set, not the name of an object that the caller cannot reach. The host cannot call it: the remote service has no connection to `scheduler`.

**The value in use.** No page holds the strategy, and the compositor has no right to inspect the machine. The provider says it: the console reads the strategy in the system report, with the right Inspect that it has, and sets the flag `In_Use` of one entry, as it does for the member of a row that a getter gave ([enum_parameters.md](enum_parameters.md)). A console that lies about the mark gains nothing: it can already lie in a name.

**The mark is a fact of now.** The strategy and a setting can change with no line of the console: a key in the window of `scheduler` or of `settings`. The console writes its table after a line only. So the panel sends `Refresh` on the ring at each open, and the console reads the strategy and calls the getter of each row, then writes its table again when a mark moved. The list that the open shows can have the mark of before for the time of one answer; the new table then comes as each new table does.

**Refused forms.**

- **The right Schedule for the console.** One line of code, and the richest process of the system gets a right over each thread of the machine.
- **The right Inspect for the compositor**, to read the strategy itself. The process that reads each hostile surface gets the reports of the machine.
- **The strategy as a setting of the service `settings`.** A setting is a value that the service keeps across a stop and that each process reads in a page. The strategy is a state of the kernel, and the kernel is its one source: a page beside it is a second source that can disagree.
- **A list of the exports of each running service in the table.** It makes each export of each service an entry, connected or not, and the console then holds a connection to each service that runs. The palette lists what the console can call now.

## The pointer in the panel

- **A press in a field of a form puts the caret there**, at the character under the pointer. A press on the name of a parameter puts it at the start of its field. A press on the name of the command, or after the last parenthesis, does nothing. The hit test and the drawing read one layout of the band (`form_band_layout`), so they cannot disagree on a place.
- **A press and a release on one candidate take it**, as Tab does. A move over a candidate chooses it, as a move over an entry does.
- **A press and a release on one button of a field take its value**, as Tab does. The hit test reads the layout of the buttons that the drawing reads (`form_buttons_layout`), with the draw table of the last frame for the widths of the names, so a press lands on the button that the frame showed. A press on a button puts no caret: the buttons are to the right of the last character of the band.
- **The scroll bar takes the pointer.** The panel is drawn only at a change, so its owner builds a frame for the pointer only when the scroll bar asks for one (`scroll_bar_wants_frame`), and wakes for a held arrow button at the time that the interface state holds.
- **The view moves, and the choice follows it.** The palette runs the row that is drawn: a choice outside the view is a row that Enter runs and that no frame shows. So a move of the view takes the choice to the nearest entry inside it. The candidates of a form follow the same rule. Before, the view of the candidates was computed from the choice at each draw; it is now a state of the form, which the choice and the scroll bar both move.
- **A press on the scroll bar is on no row.** The rows end where the scroll bar starts: a press there runs no entry, and the pointer has the shape of the arrow.

Refused: a view that leaves its choice behind (above); a scroll bar that the panel draws by itself with its own hit test (the element of the interface package already holds the press, the drag and the repeat).

## The form of an entry, from its descriptions

The panel shows each entry in the form that its act asks for, and offers to go where the act lives. Nothing is written for one command: three rules derive the form. What an element or an entry acts on is its act name (`docs/glossary/desktop.md`): the word "action" is already what a key asks of the panel (`palette.Action`), and "place" is a term of the storage service.

**Rule 1: the control comes from the field.** One table of the private part `palette` of the compositor gives a control for a field, from what the field is:

| The field | The control |
|---|---|
| A closed list of at most 6 values | A row of buttons, the value in use marked |
| A closed list of more values | The list of candidates, with kind icons |
| An Integer with a value kind Size or Time | A number, with its unit after it |
| A free Text | A text field |

A closed list is a fact of the candidates: the provider says, in the answer `Candidates_Ready`, whether its candidates are the only values that the parameter takes, or suggestions. The scheduling strategies, the members of an enum, and the rows of a `choices_export` (`Candidate_Kind.Choice`) are closed; the processes, the modules, the grants, and the range stops of a ranged Integer (`Candidate_Kind.Range_Stop`) are suggestions. The table of the controls is `field_control` in the support package.

**Ranges and choices from `Parameter_Settings`.** The provider reads `module.parameter_setting` for each described export. For a ranged Integer parameter, it computes evenly spaced stops via `module.range_stops` and offers them as `Provider_Setting` rows (up to 6 stops) and as `.Range_Stop` form candidates. For a parameter with a `choices_export`, it calls that table export within the getter budget and offers its choices as `Provider_Setting` rows and `.Choice` form candidates.

**12 parameters and chunked Text arguments (version 11).** `palette_table.PARAMETER_CAPACITY` matches `module.PARAMETER_CAPACITY` (12), so commands with 7 to 12 parameters appear in the palette and open in the form. `ARGUMENT_INLINE_TEXT_CAPACITY` (48 bytes) is the inline fast path that fits in one ring record (`values[1..6]`); longer Text arguments up to `ARGUMENT_TEXT_CAPACITY` (1024 bytes, matching `chosen_values.TEXT_BYTES_MOST`) cross as ordered `Command.Argument` chunk records reassembled by `palette_table.Argument_Assembly`, which counts multi-record transfers in `chunked_arguments` and refuses out-of-order chunks, mismatched totals, invalid UTF-8, or quotes.

**The setting row.** The members of an enum parameter are closed too: the entries of one parameter become one row, `font  [vector] spleen`, in place of one entry for each member ([enum_parameters.md](enum_parameters.md)). The provider gives each Provider_Setting entry the name of its row, the parameter, and the name of its value, the member, in fields of the table. The panel joins the entries that follow each other in the table and have the same kind, the same name of a row and the same act name: they differ only in their value. The row has the name of the parameter, which the typed part matches, then one button for each member, the member in use marked by a line under its name. Left and Right choose a value, Enter sets it: the panel sends the entry of that value, as it sent one entry before, so the provider and its checks do not change. A press on a button chooses the row and the value, and sets it. A run of more than 6 values stays entries, one for each value.

**A field with a few closed values.** In a form, a field whose candidates are closed and at most 6 shows them as a row of buttons, in the band at the right of the call when they fit there, else on the first row under the band. Left and Right choose, Tab takes the chosen value, and Enter takes it before it goes on, so one key sets a strategy. A press and a release on one button take its value, as Tab does: the pointer reaches each button that a key reaches.

**A number with its unit.** A command says what an Integer parameter counts: an integer unit (`docs/glossary/running_code.md`), a value kind Size or Time with one unit of that kind, `pages` or `milliseconds`. The provider writes the integer unit of each parameter in the entry, beside its kind. The band of the form shows the unit after the number, in the color of its value kind, also while the field is empty: `buffer(count: 4 pages)`. The prompt under the band says it in words: "an Integer, in pages". The principal types the number in the unit that the command reads, and the panel sends the number as it is: the panel converts nothing.

- **Why the unit is data of the entry, and the text is the contract.** The entry carries a value kind and a unit number; the panel takes the text of the unit from the tables of `value_kinds`, the ones that the log uses. A text from the provider could say anything in the band. A table of command names in the panel is the form for each command that rule 1 refuses.
- **Why the unit belongs to the command.** The console states the integer unit of each of its built-in commands that take a size or a time where it states the command. An export states it in its description, so the console copies it into the command when it adds the export, and the provider writes it as it writes the unit of a built-in command. The panel cannot tell the two apart, and needs no new code.
- **Refused: a field that converts between units**, such as `4 MiB` typed for a parameter in pages. The panel then holds the arithmetic of each unit, and the line that the console echoes differs from what the principal typed. The unit says what to type; it is not a second parser.

**An export states the unit of a number.** The unit of an Integer parameter of an export is part of the description of the export, so each front end reads it from the one source: the palette, the check of a replacement, the check of an import declaration.

- **Where it lives: the detail of an Integer parameter.** The detail of a parameter is the word that says what its type needs: the index of a record, the rights of a handle. An Integer parameter had the detail 0 and no reader of it. It now holds the integer unit: byte 1 the value kind, byte 2 the unit, bytes 0 and 3 zero (`value_kinds.integer_unit_detail`). The record `module.Function` does not change, so the format version stays 1. Byte 0 stays zero because the console reuses the detail of a command for the size of an Integer field (1, 2 or 4), and a detail 2 must not read as a size in bytes.
- **How a source states it: a distinct type of the contract.** A parameter has the type `value_kinds.Size_In_Bytes`, `Size_In_Pages`, `Time_In_Milliseconds` and the others of the table `INTEGER_UNIT_TYPES`, in place of `i64`. Each type is `distinct i64`: the call form does not change, and the compiler refuses a number of another unit, or a plain `i64`, at each call in the build, with no conversion that names the unit. The describe tool reads the name of the type and finds its unit in the table, so the names and the units have one source. The tool reads the name only through an import of the package `value_kinds`: a type of the same name in another package is refused as each unknown type is.
- **How the checks treat it: the unit is part of the meaning.** The check of a replacement compares the details of each Integer parameter, as it compares the rights of a handle: a replacement that takes bytes where the import took pages fails with `Difference.Parameter_Detail`, and its sentence names both units. The check of an import declaration compares the unit of each Integer parameter: a declaration with `i64` for an export in bytes fails, so an importer writes the unit too and the compiler checks its calls. The unit is to an Integer what the version in the name of an export is to a record: a fact of the meaning that the layout does not show.
- **What it does not prove.** The unit says what the number counts. It does not prove that the code of the export counts that: a type is a statement of its author.

Refused forms:

- **A comment marker that the describe tool reads**, such as `// unit: pages`. No compiler sees it: a call in the build can pass a count of bytes, and a marker on the wrong line is read in silence.
- **A plain alias, `Size_In_Pages :: i64`.** The compiler takes any `i64` for it, so only the tool checks the unit, at the border of a module, and never inside a build.
- **A new field of the parameter record**, beside the detail. It raises the size of `module.Function` and the format version for a word that is free today.
- **The unit in the name of a parameter**, such as `length_bytes`. A name is for a reader, and the checks do not compare names: a replacement could rename it.
- **A unit on a result, or on an Integer field of a record.** No reader needs it now: the palette shows a result in the drawer of its kind, and a field of a record has its own detail, its size.

**Rule 2: the mode comes from the facts of the entry.** Three modes: run, destroy, go to. The input band names the mode of the chosen entry and its key, at its right: an entry with the flag `Destroys`, and the close of a window, is "enter enter: destroy", with its second Enter; each other entry is "enter: run". An entry whose act name an open window names adds "shift enter: go to". Enter runs by default. The words are measured against the room that the typed part leaves: the word of a prefix leaves first, then the mode. The footer keeps the act of Enter on the entry ("enter: close", "enter: start"): the mode is the kind of the act, the footer the act itself.

**Rule 3: where to go comes from the window.** An element that a process builds with the interface package can name what it acts on: an act name, a text of at most 32 bytes, such as `settings.set:font`. The window layer sends the set of the act names of a frame to the compositor in one record of the ring of its window, only when the set changes. The compositor keeps the act names of each window. The provider writes the act name of each entry in the table, so the compositor reads it and never parses the name of an entry. An entry whose act name an open window names offers go to. On go to, the compositor raises the window, and sends it an event with the act name; the window layer puts the focus on the element, and the next frame shows it. A module writes no code for go to: it names an element when it builds it.

**One record, so a hash.** A record of a ring holds 7 values of 8 bytes. The names of the settings already need more than 56 bytes. So the record holds a count and at most 12 hashes, the FNV-1a hash of 32 bits of each name (`display.act_name_hash`), two in each value, and the event holds one hash. Hashes of 64 bits gave room for 6, and the window of `settings` names 7 settings: the seventh had no go to. A hash of 32 bits is enough here: two names with one hash only offer a go to that finds no element. The panel hashes the act name of an entry when it collects the list, on its second thread. The window layer keeps the text of each name of its last frame, for its own line of the log. A second record for each name was refused: the set of a window then arrives in parts, and the compositor needs a state for a set that is not whole.

**Which element takes the focus.** The first element of the frame with the act name. A process chooses which element names it: `settings` names the button of the value in use of each setting, and `scheduler` the tile of the strategy in use, so go to puts the focus on what the machine uses now.

**Why a provider gives data only.** The panel is in the compositor, which reads each hostile surface. A provider that sent a widget, a layout or a drawing would draw in the process that holds each pixel. The provider gives values, candidates and facts; the panel chooses from its closed set of controls. A process gives act names, never a rectangle: the window layer finds its own element.

**Refused forms.**

- **A form for each command**, written in the panel or in the provider: each new command and each module of another project needs code in the compositor.
- **A mode "set" beside run.** A setting is a command whose field is a closed list: its row of buttons comes from rule 1, and it runs.
- **Go to as an export of each module.** Each module writes the same code, and a module with no service cannot be called. The window layer of each process already holds its elements and its focus.
- **A rectangle that the process gives, in place of a name.** A process can name a rectangle over another window, or one that moves after the next frame. A name, found by the window layer at the time of the event, cannot point outside its own window.

**The subtle points.**

- **A set of act names is hostile input** for the compositor: it copies the record, refuses a count over 12, a hash of 0 in the count and a hash after it (`display.act_names_of_values`), and compares a hash with the hash of the act name of an entry; a hash is never shown. A window that names an act that it does not have gains nothing: go to raises that window only, and its window layer finds no element.
- **A window that closes** takes its act names with it: the compositor drops them with the window. The compositor writes a line for the first 8 sets of a window only, so a window that changes its set at each frame does not fill the log.
- **Two windows that name one act**, as two windows of one process: go to takes the window in front.
- **A frame with more than 12 act names** sends the first 12; the window layer writes one line for the life of the window.
- **Left and Right on a setting row** choose a value, so they do not move the caret of the typed part there; Home and End still do.

## Any count of entries

The list of the panel draws only the visible viewport window (`first_visible ..< first_visible + LIST_ROWS`), so drawing cost per frame is O(`LIST_ROWS`) regardless of entry count. The provider protocol (`modus:contract/palette_table`, since version 8) has no fixed cap of entries:

- `Header` carries `entry_count`, `byte_length` and `entries_object`, checked strictly at the border (`header_read` and `snapshot_take`): `byte_length` must equal `ENTRIES_OFFSET + entry_count * size_of(Entry)` without overflow, `entries_object` must name the place of the entries that the reader holds, and the entries must fit in that place. Truncated regions and malformed headers are refused with no state change.
- `Snapshot` holds a caller-sized `entries: []Entry` slice instead of a fixed array. The entries stay in the table that the root service made while they fit. Past it, the provider makes an object of the entries alone, gives a read-only handle through the palette ring, and sends `Outcome.Table_Replaced` with the number of the object; the header names that number from its next write. The header, the result area and the candidates never leave the table.
- **The compositor never maps memory of the provider.** The provider made the object of the entries: it could revoke it in the compositor while the compositor reads it, or make it Uncommitted and leave pages with no frame, and a read through a mapping would then fault and stop the trusted display. So the ranking thread proves the object (it came through the ring, a memory object, Read with no Write and no Execute, not Uncommitted, a number past the one held) and copies its entries by the kernel (`system.memory_read`, the operation `Memory_Read`), which gives a status where a mapping would fault: the snapshot is then `Entries_Lost`, and the list has no entry of the provider. The interface thread reads only the table that the root service made, which the provider can neither revoke in the compositor nor leave with no frame. A header that names an object that the ranking thread does not hold yet is `Entries_Moving`: the list shows no entry of the provider for that turn, and the log has no line, because the `Table_Replaced` comes.
- Refused: the object of the entries mapped, as the table before it was (the faults above); the whole table moved to the object of the provider (the interface thread would read memory of the provider: the change count, the result, the candidates); the root service making the larger object (it would pay with its own budget for a provider whose count of entries has no bound).
- In `internal:compositor/palette`, `List` stores caller-sized slices (`entries`, `rows`, `candidates`, `ranked`, and `snapshot.entries`) with `u32` entry indexes. `rows_rank` matches all entries off the main thread using `line_editor.fuzzy_match` (SIMD) with frecency bonus and sorts matches in place in O(M log M) without heap allocation. The compositor's ranking thread grows its two double-buffered list memory objects on demand off the main thread, never during a frame.
- Viewport scroll offset clamping (`list_first_row`) clamps `first_row` to `0 ..= max(row_count - LIST_ROWS, 0)` across drawing, hit testing, and scrolling so top, middle, bottom, and past-end offsets always show a valid viewport.

Refused: a larger fixed table, which moves the bound and costs its memory on each machine; pages of entries asked on a scroll, which make each scroll a request to the provider. Built.

## The candidates of a field, by pages

A parameter has any count of candidates: the modules of a large image, the processes of a busy machine, the members of a large enum. The candidate area of the table holds one page (`palette_table.CANDIDATE_CAPACITY`), and the list goes by pages (version 9 of the table):

- **The request names a cursor and a search text.** `Candidates` carries the place in the list where the page starts; an `Argument` of the same tag before it carries the text of the field. The provider counts each name that the text matches (`line_editor.fuzzy_match`), writes the names of the page, and answers the count of the page, the count of the whole list that matches, and the cursor of the page.
- **The panel checks the page against its list** (`palette_table.candidate_page_valid`): a page inside the list, no more names than the area holds, and a page that ends the list or is full. A page that fails gives no candidate.
- **A page that holds the whole list** is narrowed by the panel itself, as each key types, with no request. **A page that does not** asks the provider again at each change of the text: the provider holds the whole list.
- **A move of the choice past the edge of a page** asks for the page after, or the page before with its last candidate chosen when it comes. Tab waits for that page, as it waits for the first.

Refused: a candidate area that grows with the list in the table of the provider, which moves the entries at each request; a search in the panel only, which never finds a name past the first page.

## The film

A film of the palette needed a change of the tool: the old step that took pictures stopped the scenario, so a film had no key during its pictures. A worker thread now takes the pictures while the scenario types and waits for its conditions. The capture stays the screendump of QEMU: another capture path needs a display server of the host, and a window can open. See [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The film".

## State

Built: the panel with the processes and the windows; the provider with the commands of the console, their arguments and their candidates; the rows of the enum parameters of the exports, the settings among them, with their getters; the scheduling strategy; the four prefixes; the kind icons; the pointer in a field, on a candidate and on the scroll bar; the film; the setting row; the row of buttons of a field with a few closed values; the mode in the input band; go to, with the act names of `settings` and `scheduler`; the number with its unit, for the built-in commands `buffer`, `debug_memory` and `wait_stop` (`bytes` states its unit too, and opens in the console for its Handle); the unit of an Integer parameter of an export, stated by `cryptography.hkdf_sha256_expand`, `debugger.memory`, `debugger.watch`, `debugger.wait_stop` and `storage.set_size`; the pointer on the buttons of a field; the wheel over the entries and the candidates, which moves the view and the choice with it ([scroll_bar.md](scroll_bar.md)).

Left:

- A press in the typed part of the search does not move its caret: the keys do.
- A Table result is not drawn in the panel: it opens in the console.
- A second provider (a service that runs its own entries) waits for a real need.
- The manual, the site and the signature that the console prints show the type of an Integer parameter with no unit: only the palette and the sentence of a failed check name it.
