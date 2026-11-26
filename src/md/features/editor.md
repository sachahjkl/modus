# The editor `edit`

`edit` is a native module of modus that edits a text object of a store, in a window. Its keys are the keys that most principals know from other systems: no modes, Shift to select, the mouse. It has no save action: each change is a version of the object, so the undo of the editor survives a restart. The guide is [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The editor".

## Purpose

A principal who works in modus writes text: the source of a project, a declaration, a note. Today the system has the console line and no editor of a whole text. The editor comes before the C compiler of [first_compiler.md](first_compiler.md), so that the sources of the first native stages can be written in modus.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Persistence: no save action, and versions for all processes": the document in the store is always current, and the system has no save action.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": the editor reaches only the stores that it was given, and the clipboard only at a copy or a paste of the principal.
- [`docs/DESIGN.md`](../../../docs/DESIGN.md), "5. Text": the text of a window follows the design rules, with no text over another text and no cut text.
- [text_encoding.md](../data/text_encoding.md): UTF-8 with no control character but the line end and the tab.
- No work in a frame in proportion to the text: a frame reads the rows that it shows, and nothing else.

## The chosen form

- **A native module in Odin**, on the package `interface`, so it has the look, the keys and the damage rules of every window.
- **A resizable window on the layout tree.** The window is placed by `modus:layout` ([box_layout.md](box_layout.md)) at each frame, at the size that the principal gives it: the top band (the search field and the state label), the workspace (the gutter, the text, the scroll bar, and the pane of the versions with its divider), the status band and the action bar. The colors come from the element tokens of the appearance in force. A taller window shows more rows; Page Up and Page Down move by the rows that the last frame showed. The least width holds a row of 80 cells, the gutter and the scroll bar, so no row is cut.
- **The pane of the versions.** Ctrl+H shows the versions of the object at the right of a divider, the newest first, the current one on the chosen color: a reader sees that each group of changes is a version. The pane is a split pane: a drag of the divider moves its ratio, which the state of the divider box keeps across frames.
- **The keys, with no modes:**
  - Ctrl+Z restores the version before; Ctrl+Y goes forward again.
  - Ctrl+F opens the incremental search bar; Enter or F3 finds the next match, Shift+Enter or Shift+F3 finds the previous match wrapping around the text, and Escape closes search and returns focus to the caret.
  - Shift with an arrow, Home, End, Page Up or Page Down, Ctrl+A, or a drag of the pointer, selects.
  - Ctrl+C (copy), Ctrl+X (cut) and Ctrl+V (paste) go through the clipboard of the compositor ([clipboard.md](clipboard.md)): the compositor takes the keys, sends `Copy_Asked` with `Copy_Action` (`.Copy` or `.Cut`) and `Pasted`, and the editor copies, cuts or inserts multi-line UTF-8 text (preserving LF line ends and tabs). On a cut, the selection is deleted and committed only after `copy_send` succeeds.
  - The pointer places the caret, selects with a drag, and scrolls.
  - Ctrl+H shows or hides the pane of the versions.
  - Ctrl+Shift+F formats an open `.lex` document canonically through `modus:lex_tools` and commits the result atomically.
  - **Syntax highlighting without per-frame O(N) work.** When opening a `.c`, `.h`, `.lex`, `.recipe`, or `.odin` object, `modus:text_model` precomputes one `Syntax_Carry` byte per display row (block-comment depth, Odin raw backtick strings, wrapped-row string state) in `layout_refresh` whenever the text changes — never during a frame. Each frame classifies only the visible display rows (at most 80 cells per row) into `graphics.Code_Class` and draws normal runs with `graphics.code_class_color` for the active dark or light appearance while keeping selection and search match contrast intact.
  - The action bar shows the keys (`Ctrl+F`, `Ctrl+Z`, `Ctrl+Y`, `Ctrl+H`, [action_bar.md](action_bar.md)).
- **No save action.** The editor sends each group of changes to the storage service when the group ends. A commit of the object is a version (property 9).
- **Undo is a walk over the versions.** Ctrl+Z restores the version before the current one; Ctrl+Y the version after. After a restart, the versions are still there, so Ctrl+Z still works.

### The text model

The text, its layout and the walk over the versions are pure procedures in the support package `modus:text_model`, with host tests, which `edit` and `notes` ([notes.md](notes.md)) share. They call no operation of the system: the module gives them the bytes from the store and the keys.

- **A gap buffer whose memory the caller gives.** A key moves the gap to the caret and writes into it, so a run of keys at one place copies no byte of the rest. The model holds an inline fast-path buffer of `TEXT_CAPACITY` (32 KiB, inline capacity sized to cover typical modus source files and notes with zero arena calls) for a caller that gives nothing; `text_init_buffer` gives it a buffer and a growth (`Buffer_Grow`), and the layout and the search take a buffer and a growth of their own (`layout_init_buffer`, `search_init_buffer`). Each move onto or growth of the slower external tier increments a visible `tier_moves` counter on `Text`, `Layout`, and `Search`. `edit` and `notes` give each one growth, `system.arena_grow`, which the compiler makes for the bytes, the rows and the matches: it extends the one buffer of an arena in place. The model calls no operation of the system: a growth that the caller refuses is the refusal `Too_Long` of an insert, `Rows_Full` of a layout, or a search that keeps the matches that fit (`matches_truncated`), and nothing else changes.
- **`edit` grows each buffer in an arena of its budget.** One arena for each buffer, reserved once: the text, the display rows, the places of the matches, and a transfer arena for a read, a clean copy, a copy and a paste. `system.arena_extend_to` grows the one buffer of an arena in place, so its bytes never move and a growth copies nothing. A text has the size that the budget of `edit` pays, not a size of the source: a budget that refuses a commit refuses the key with "the memory of the editor is full", and the text stays.
- **A text passes the call region by ranges.** A call region holds 64 KiB. `edit` reads the object by its size, then by `read_range` in pieces into the transfer arena; it writes a text of at most 32 KiB in one `write`, and a longer one by `set_size`, `write_range` in pieces of 32 KiB and one `commit`, so each group is still one version. The two forms are `storage.read_whole` and `storage.write_whole`, which `notes` uses too. The storage service holds the pending changes of a commit for its connection, sized to the commit (`docs/STORAGE.md`, "Ranges"): a commit that the service cannot hold is refused, and the status says that the changes are not kept.
- **A restore comes before its read.** `version` gives a version through one call region only. So Ctrl+Z and Ctrl+Y ask the store to restore the version first, then read the current text by ranges. A read that fails after the restore ends the keeping: the store keeps the version as its current text, and the editor never writes over it.
- **Each border checks.** An insert that is not text of the editor (an invalid sequence, a control character but the line end and the tab), an empty insert, and an insert past the bound are refused whole: the text and the selection do not change. A place from outside the model (a press of the pointer) is clamped to the text and moved back to the start of its character. The caret is never inside a character.
- **A text from the store is cleaned, never refused for its bytes.** Each invalid sequence and each control character but the line end and the tab becomes the replacement character, U+FFFD, and the log counts them. The store keeps the old bytes until the next commit writes the clean text.
- **The layout is display rows.** The layout takes the cells of a row and the wrap (by character or by word); the editor gives 80 cells and the wrap by character. A row holds 80 cells; a tab goes to the next multiple of 4; a line longer than a row goes on the next rows. Each row has its start and its line, so the gutter numbers the first row of each line. The layout is computed whole after each change of the text: its cost is one pass over the text, at a key, never in a frame. Each row starts at a byte after the start of the row before it, so a text of n bytes has at most n + 1 rows, in the arena of the rows.
- **The caret moves by rows.** Up and Down keep a goal column, so a short row on the way does not move the caret to the left for the rows after it. Home and End go to the ends of the line, not of the row.

### The groups of changes

A commit writes the whole text with one `storage.write`, at the end of a group. A group ends:

- after a typed space, tab or line end: the end of a word;
- before a change of another kind: a deletion after typed characters, a typed character after a deletion;
- when the caret moves to another line, by a key or by the pointer;
- before an undo and before a redo.

A stop of the process loses the group in progress: at most a word, or the deletions since the last word.

### The walk over the versions

The walk keeps the generation that the editor shows after a restore, and a list of the generations that Ctrl+Z left.

- Ctrl+Z commits the group in progress, lists the versions of the object, and restores the newest version below the generation shown (the current one after a change). The restore is a commit, so it is a version too; the walk goes back from the generation that it restored, not from that commit.
- Ctrl+Y restores the generation that the last Ctrl+Z left. A change of the text ends the list: Ctrl+Y then has nothing to go forward along.
- The walk is told of a step only after the store took the restore: a refused restore leaves the walk and the text as they were.
- The caret goes to the end of the part that the restore changed, found by the bytes in common at the start and at the end of the two texts, moved back to the start of a character.

## The frequent tasks

| Task | Expression |
|---|---|
| Edit the text of the editor | `start("edit")` |
| Edit a text of a store | `edit(notes, "today.txt")` |
| Edit a source of a project, in its console | `projects.enter(kernel)`, then `edit(kernel, "src/modulus/enter.odin")`; in the child console, `kernel` is the store that the field `console` of the project grants |
| See the versions of the text | `versions(notes, "today.txt")` |

## The refused forms

- **A port of micro.** micro needs the runtime of Go and a POSIX terminal, which the system does not have. Its Ctrl+S is a save action, against property 9.
- **micro in the Linux guest.** It works, but it is a program of Linux in a guest, not a program of modus: it edits the files of the guest, not the objects of a store.
- **Modes, as in vi.** A key with two meanings that the principal must keep in memory.
- **A save action, a swap file or a file of the undo.** Property 9 keeps each change already; the editor keeps no second copy.
- **An undo list in memory.** It would be a second copy of what the store keeps, and it would end with the process: Ctrl+Z after a restart would do nothing.
- **Pending changes by range at each key.** An insert in the middle moves each byte after it, so a range write is the whole rest of the text; and the end of a connection drops its pending changes, so they lose what a group in progress loses. A group writes the whole text in one commit: one call up to 32 KiB, ranges and their commit past it.
- **A pause as the end of a group.** A commit after some seconds with no key would make the versions depend on the speed of the hands, and a machine test on the speed of the host.
- **A cut row at the edge of the window.** A cut text breaks the design rules; a long line goes on more rows.
- **A layout of the text in each frame.** Its cost would grow with the text in each frame. The layout tree of the window is built at each frame: its cost is its dozen boxes, not the text.
- **Rows that follow the width of the window.** The display rows would be computed again at each step of a drag of an edge, with a cost in proportion to the text, and the caret would go to another row at each step. The rows keep 80 cells; a wider window gives room to the pane of the versions.
- **A read of the versions in a frame.** A frame calls no service: the pane reads the list before the frame, only when a commit or a restore made it old and the pane is shown.
- **Buttons for find, undo and redo in the top band.** The action bar names each key once, and a press on its item runs the key: a second button would say the same thing twice.

## Subtle points and hazards

- **A commit for each group is a cost.** Each commit writes its blocks and a root, and reads them back ([dropped_write.md](dropped_write.md)). The size of a group is a measure to make. Property 9 leaves open how a process groups small changes into one step; this is the first answer.
- **The retention rule thins the versions.** All versions for 10 minutes, then one an hour for a day, then one a day. So Ctrl+Z after a day goes back by hours, not by groups.
- **A change after Ctrl+Z.** The versions after the current one stay in the history of the object, and `versions` lists them. Ctrl+Y no longer reaches them: Ctrl+Y goes forward only along the restores that Ctrl+Z made. The walk goes back by generation, so a later Ctrl+Z can reach a version that an earlier Ctrl+Z left: the history of the object is one line, as the store keeps it.
- **The list of the versions has a bound.** The store gives the oldest first; the editor lists 1024. An object with more versions refuses the undo with one line of the log, until the thinning removes some.
- **A text that the editor cannot hold is never written.** A damaged object starts an empty text that the next change writes as a new version, with the old one kept. An object that cannot be read, or that is too long, ends the keeping: the editor keeps nothing, so it never writes over a text that it did not read.
- **One object, not a store.** The editor gets a connection to a store; the grant of one object waits for the document service with its picker.
- **Edit any object of a store (`edit(store, name)`).** The console validates the store name and `/`-separated object path and sends `Root_Command.Start_Edit` to the root service. The root service checks `Acts_For_Principal` and principal isolation (`principals.store_name_principal`), connects the started `edit` process to that store (without giving `edit` `Acts_For_Principal`), and maps a read-only `Edit_Target` page at `fixed_addresses.EDIT_TARGET_PAGE_ADDRESS`. `edit` walks any parent trees with `storage.open_tree` and reads, commits and walks versions on that object.
- **The wheel goes to the scroll bar.** The scroll bar of the frame takes the notches over the text and over itself, before the rows are drawn, so a notch moves the frame that it comes with. The pointer events of the text do not scroll: two readers of one notch would move the view twice.
- **The divider takes the press, not the text.** The input of the divider comes from `layout.box_input` on the rectangles of the last frame; the caret takes a press only inside the gutter and the text of the last frame.
- **Multi-line clipboard border.** `display.clipboard_text_problem` takes `Clipboard_Text_Form` (`.Single_Line` or `.Multi_Line`). `copy_send` allows LF (`\n`) and tab (`\t`) while refusing CR (`\r`), NUL, all other C0/C1 controls, hidden characters and invalid UTF-8 in a text of the size of the selection, which the transfer arena holds. `paste_read` defaults to `.Single_Line`, so the terminal and single-line text fields refuse line ends and tabs; `edit` reads pastes with `.Multi_Line` for the document and `.Single_Line` for the search bar, into a room of the size of the paste in its transfer arena.

## Open questions

- **The size of a group of changes**, from a measure of the cost of a commit.
- **The grant of one object** in place of a whole store, before the document service.

## State

Built: the module `edit`, with its own store and the object `text`, and any text object of any store of the principal via `edit(store, name)` (`Root_Command.Start_Edit` and `Edit_Target_Page`); the text model, incremental search, and logical-line-aware syntax highlighting (`.c`/`.h`, `.lex`/`.recipe`, `.odin`) with their host tests; the keys of the caret and of the selection, Ctrl+A, Backspace, Delete, Escape; multi-line clipboard Copy (Ctrl+C), Cut (Ctrl+X) and Paste (Ctrl+V); incremental search (Ctrl+F, Enter/F3, Shift+Enter/Shift+F3, Escape, match count and visible match highlights); canonical Lex formatting (Ctrl+Shift+F, exposed as `Format` in the action bar on `.lex` and `.recipe` files); the pointer (a press, a drag, the wheel); the display rows with the gutter; the groups of changes as commits; Ctrl+Z and Ctrl+Y as the walk over the versions; the resizable window on the layout tree, with its scroll bar, its status band, its state label and the pane of the versions (Ctrl+H) with its divider; the machine step that types two lines, undoes, redoes and selects. Left: the loss of the focus as the end of a group, a machine step that resizes the window and drags the divider, and a text whose one commit passes the pending changes of the storage service.
