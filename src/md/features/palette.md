# The palette

The palette is one panel that a key opens. It reaches every operation that the principal of the session can do: start a program, bring a window to the front, close a window, run a command of the console with its arguments, set a setting, set the scheduling strategy. It replaced the launcher, and the term launcher left the system (`docs/DECISIONS.md`, D-236).

What the panel looks like and what each key does is in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "Palette". The provider is in [`docs/CONSOLE.md`](../../../docs/CONSOLE.md), "8. The palette provider". This file records why the palette has this form.

## The problem

Before the palette, two programs held every operation. The compositor held the windows and the start of a program. The console held all the rest: the root ring, the calls of the services, the settings, the principals, the grants, the debugger, the shutdown. "Every operation from one panel" asks for a panel that reaches both sets.

The language of the console is not a set of operations. `where` and `columns` have no meaning alone, and a form with one field for each parameter cannot give a Table. So "every operation" is each act, and one step to the console for a composed line.

## The constraints

- **No ambient access.** A broad grant is rare, visible and revocable. A second program with every grant, beside the console, doubles the richest target of the system.
- **The typed text reaches no program that does not need it, and no program can draw a false palette.** Only the compositor keeps both: it keeps the key super, and it draws over each window.
- **No text between programs.** If the compositor builds the text `revoke("net", "network")` and the console parses it, one program prints and another parses.
- **The loop of the compositor waits for no program**, and does no work in proportion to a table that another program wrote.

## The chosen form: a panel and a provider

The palette is two parts with one ring between them.

- **The panel** is in the compositor. It owns the keys, the pixels, the list and the fuzzy match. It holds no new right. Two kinds of entries are its own, from tables that it already has: the programs and the windows. They work with no console.
- **The palette provider** is the console. It already holds each grant that a command needs. It writes the entry table, a memory object that the compositor maps read-only: one entry for each row of its command table, with the parameters as data. On a choice, it runs the command as a typed line: the line is echoed in its terminal, the drawers draw the result, and the line goes in the line history.
- **The grant** is `Palette`, a grant of the console. `grants("console")` shows it. `revoke("console", "palette")` ends the ring and the mapping, and the palette keeps the programs and the windows.

Why this gives no program a new authority: the compositor already routes each key to the console, so it can already type `shutdown()` there. The ring adds a face, not a power.

- A compromised compositor gains nothing. It already owns each key and each pixel.
- A compromised console can show an entry whose name lies. It needs no palette to do harm: it holds the grants. The compositor, not the provider, draws the confirmation of an entry that destroys.
- A program without the grant gains nothing. The table and the ring are handles that the root service gives to two programs only.

How a program adds its operations: it exports a described function and is a service. It writes no table and no code for the palette. The description of an export is the one source of each front end.

## The refused forms

- **A palette program with its own grants.** It is a second program with every right. It also needs a second command table, a second checker of arguments and a second set of drawers.
- **The compositor dispatches entries that each service contributes.** The compositor must then hold a connection to each service and act for the principal: the program that reads each hostile surface gets the rights of the principal. Or the root service calls an export for a caller, which makes it a deputy. The good part of this form is kept: an entry is data from a described export, and the panel only dispatches.
- **The compositor sends the text of a line.** Refused by the rule of no text between programs. The compositor sends an index and typed values. The console builds its own line.
- **A border of 1 pixel around the whole panel.** The request was an input that is flush with the top, the left and the right edges. The band has no border on those three sides; its fill and the line under it are its edge. The rest of the panel keeps a border, because the design rules allow no shadow and no scrim, and a card on a dark window has too little contrast without an edge.
- **Groups in a ranked list.** A group header takes a row, and the best match must be the first row. Groups exist only when nothing is typed.
- **A record or a table drawn in the panel in the first form.** A table opens in the console: the drawers, the scroll and the line to compose are there. A reader of hostile descriptions in the compositor was not worth one saved step. A Record is now shown in the panel as the runs that the drawer of the console wrote.
- **A store for the recent choices of the compositor.** The recent commands survive a stop through the line history of the console, with no new store and no new grant. The recent programs and windows live in the memory of the compositor.

## The subtle points

- **The palette runs the row that is drawn.** The command table of the console changes (`load`, `unload`, `connect`). A choice carries the change count of the table that the panel showed, the index, and the hash of the name of the entry. The console checks the three against its own copy, and refuses a choice that names another entry. A list that arrives late does not move the choice. This was the test designed to break the form on its first day: Enter before the table moves.
- **The table is hostile input.** The compositor copies the table, then checks the copy: the count of entries, each length, each kind, and a change count that never becomes even. A table that fails gives the programs and the windows only, with one line of the log.
- **The values go as records with kinds, not as a line.** An Integer goes as a number, a Text as bytes. The console checks each value again before the call, as for a typed line. A parameter of the kind Record, Table, Handle or Bytes has no field: the entry opens the console.
- **The confirmation belongs to the compositor.** An entry that destroys asks for a second Enter on a row that says the act in full. The provider cannot skip it. An export of a service has no such fact in its description, so only the built-in commands of the console have the flag.
- **A mark says a fact, never a kind alone.** The kind of a row is in words at its right and in the form of its icon; a color never stands alone for a fact.
- **The ranking of a few hundred entries from another program does not run in the loop of the compositor.** A second thread of the compositor copies the table and ranks. The loop gives it the query with a number, waits on a word in its one wait, and adopts only the list of the newest number.
- **The panel opens with no animation**, in the next frame, and has a fixed height: the input line never moves when the list changes.
- **A locked principal.** The console runs in the session of the machine. With a named principal locked, the palette offers what the console offers. This is a fact of the console, not a new hole of the palette; it is a question for the design of the principals.
- **When the console does not run**, the palette lists the programs and the windows and says that the commands are absent. `console` is a program of the list, so the palette starts it.

## The scheduling strategy

The palette reaches each operation that a command of the console reaches. No command set the scheduling strategy: only the window of the program `scheduler` did.

**The constraint.** A change of the strategy needs the right Schedule on the machine handle. One program holds it: `scheduler`. The console holds Inspect and Stop, not Schedule.

**The chosen form.** The program that holds the right gets a new face, and no program gets a new right over the machine.

- `scheduler` is a service: it exports `strategy_set(name)`. It serves its calls in the loop of its window, after its checks: the checks change the strategy themselves, and a call during them changes what they measure.
- The console has the command `strategy(name)`, the export under a short name, as `setting(name, value)` is `settings.set`. It connects at the first use.
- The provider writes one entry for each strategy, "set strategy to eevdf", as it does for each value of a setting. The line of the entry is `strategy("eevdf")`.
- The program `scheduler` must run, as `settings` must run for a setting. The command starts no program: its error shows in the panel.

The grant that `scheduler` gains is Serve: the right to be called. Each caller still needs a connection, which the root service gives to the console and to no program without the grant to connect.

**A service that uses its own right for a caller.** The rule against the confused deputy says that a service does not combine its own access with a name from the caller ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"). `strategy_set` does use the right of `scheduler` at the request of a caller. It keeps the rule in the way that `settings.set` and `monitor.programs` keep it: it serves only a caller that acts for the principal, a grant of the root service that is recorded, shown by `grants()` and revoked by `revoke()`. The request is then the request of the principal, and the name that the caller gives is one of three values of a closed set, not the name of an object that the caller cannot reach. The host cannot call it: the remote service has no connection to `scheduler`.

**The value in use.** The panel knows the value in use of a setting from the settings page, which each program reads. No page holds the strategy, and the compositor has no right to inspect the machine. The provider says it: the console reads the strategy in the system report, with the right Inspect that it has, and sets the flag `In_Use` of one entry. A console that lies about the mark gains nothing: it can already lie in a name.

**The mark is a fact of now.** The strategy can change with no line of the console: a key in the window of `scheduler`. The console writes its table after a line only. So the panel sends `Refresh` on the ring at each open, and the console writes its table again when the strategy differs from the mark. The list that the open shows can have the mark of before for the time of one answer; the new table then comes as each new table does.

**Refused forms.**

- **The right Schedule for the console.** One line of code, and the richest program of the system gets a right over each thread of the machine.
- **The right Inspect for the compositor**, to read the strategy itself. The program that reads each hostile surface gets the reports of the machine.
- **The strategy as a setting of the service `settings`.** A setting is a value that the service keeps across a stop and that each program reads in a page. The strategy is a state of the kernel, and the kernel is its one source: a page beside it is a second source that can disagree.
- **A list of the exports of each running service in the table.** It makes each export of each service an entry, connected or not, and the console then holds a connection to each service that runs. The palette lists what the console can call now.

## The pointer in the panel

- **A press in a field of a form puts the caret there**, at the character under the pointer. A press on the name of a parameter puts it at the start of its field. A press on the name of the command, or after the last parenthesis, does nothing. The hit test and the drawing read one layout of the band (`form_band_layout`), so they cannot disagree on a place.
- **A press and a release on one candidate take it**, as Tab does. A move over a candidate chooses it, as a move over an entry does.
- **The scroll bar takes the pointer.** The panel is drawn only at a change, so its owner builds a frame for the pointer only when the scroll bar asks for one (`scroll_bar_wants_frame`), and wakes for a held arrow button at the time that the interface state holds.
- **The view moves, and the choice follows it.** The palette runs the row that is drawn: a choice outside the view is a row that Enter runs and that no frame shows. So a move of the view takes the choice to the nearest entry inside it. The candidates of a form follow the same rule. Before, the view of the candidates was computed from the choice at each draw; it is now a state of the form, which the choice and the scroll bar both move.
- **A press on the scroll bar is on no row.** The rows end where the scroll bar starts: a press there runs no entry, and the pointer has the shape of the arrow.

Refused: a view that leaves its choice behind (above); a scroll bar that the panel draws by itself with its own hit test (the element of the interface package already holds the press, the drag and the repeat).

## The form of an entry, from its descriptions

The panel shows each entry in the form that its action asks for, and offers to go where the action lives (`docs/DECISIONS.md`, D-261). Nothing is written for one command: three rules derive the form.

**Rule 1: the control comes from the field.** One table of the support package of the palette gives a control for a field, from what the field is:

| The field | The control |
|---|---|
| A closed list of at most 6 values | A row of buttons, the value in use marked |
| A closed list of more values | The list of candidates, with kind icons |
| An Integer with a value kind Size or Time | A number, with its unit after it |
| A free Text | A text field |

A closed list is a fact of the candidates: the provider says, in the answer `Candidates_Ready`, whether its candidates are the only values that the parameter takes, or suggestions. The values of a setting are closed: the entries of one setting become one row, `font  [vector] spleen`, in place of one entry for each value. Left and Right choose a value, Enter sets it.

**Rule 2: the mode comes from the facts of the entry.** Three modes: run, destroy, go to. The band of the panel names the mode of the chosen entry and its key: an entry with the flag `Destroys` is destroy, with its second Enter; an entry with a place offers go to on Shift and Enter; each other entry runs on Enter. Enter runs by default.

**Rule 3: the place comes from the window.** An element that a program builds with the interface package can name the action that it acts on: a text, `settings.set:font`. The window layer sends these names to the compositor in one record of the ring of its window, when its set changes. The compositor keeps the places of each window. An entry whose action an open window names offers go to. On go to, the compositor raises the window, and sends it an event with the name; the window layer puts the focus on the element, and the next frame shows it. A program writes no code for go to: it names an element when it builds it.

**Why a provider gives data only.** The panel is in the compositor, which reads each hostile surface. A provider that sent a widget, a layout or a drawing would draw in the program that holds each pixel. The provider gives values, candidates and facts; the panel chooses from its closed set of controls. A program gives names of places, never a rectangle: the window layer finds its own element.

**Refused forms.**

- **A form for each command**, written in the panel or in the provider: each new command and each program of another project needs code in the compositor.
- **A mode "set" beside run.** A setting is a command whose field is a closed list: its row of buttons comes from rule 1, and it runs.
- **Go to as an export of each program.** Each program writes the same code, and a program with no service cannot be called. The window layer of each program already holds its elements and its focus.
- **A place as a rectangle that the program gives.** A program can name a rectangle over another window, or one that moves after the next frame. A name, found by the window layer at the time of the event, cannot point outside its own window.

**The subtle points.**

- **A name of a place is hostile input** for the compositor: it is copied with a bound, and compared byte by byte with the action of an entry; it is never shown as the name of the entry.
- **A window that closes** takes its places with it: the compositor drops them with the window.
- **Two windows that name one action**, as two windows of one program: go to takes the window in front.

## The film

A film of the palette needed a change of the tool: the old step that took pictures stopped the scenario, so a film had no key during its pictures. A worker thread now takes the pictures while the scenario types and waits for its conditions. The capture stays the screendump of QEMU: another capture path needs a display server of the host, and a window can open. See [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The film".

## State

Built: the panel with the programs and the windows; the provider with the commands of the console, their arguments and their candidates; the settings; the scheduling strategy; the four prefixes; the kind icons; the pointer in a field, on a candidate and on the scroll bar; the film.

Left:

- A press in the typed part of the search does not move its caret: the keys do.
- The wheel of the pointing device does not exist in the system: the input service reads no wheel.
- A Table result is not drawn in the panel: it opens in the console.
- A second provider (a service that runs its own entries) waits for a real need.
- The form of an entry from its descriptions (above): decided, the prototype in progress.
