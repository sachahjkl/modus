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

- **A native module in Odin**, on the package `interface`, so it has the look, the keys and the damage rules of every window. The window has a fixed size: 80 cells and 28 rows of text.
- **The keys, with no modes:**
  - Ctrl+Z restores the version before; Ctrl+Y goes forward again.
  - Ctrl+F finds a text in the object.
  - Shift with an arrow, Home, End, Page Up or Page Down, or a drag of the pointer, selects.
  - Ctrl+C and Ctrl+V go through the clipboard of the compositor ([clipboard.md](clipboard.md)): the compositor takes the keys, the editor answers `Copy_Asked` with its selection and inserts the text of `Pasted`. Ctrl+X comes with the cut of the clipboard, which is planned work there.
  - The pointer places the caret, selects with a drag, and scrolls.
  - The action bar shows the keys ([action_bar.md](action_bar.md)).
- **No save action.** The editor sends each group of changes to the storage service when the group ends. A commit of the object is a version (property 9).
- **Undo is a walk over the versions.** Ctrl+Z restores the version before the current one; Ctrl+Y the version after. After a restart, the versions are still there, so Ctrl+Z still works.

### The text model

The text, its layout and the walk over the versions are pure procedures in the private part `modus:private/edit/text_model`, with host tests. They call no operation of the system: the module gives them the bytes from the store and the keys.

- **A gap buffer of 32768 bytes.** A key moves the gap to the caret and writes into it, so a run of keys at one place copies no byte of the rest. The bound is the call region of the storage service (64 KiB): a whole write of the text and its name goes in one call.
- **Each border checks.** An insert that is not text of the editor (an invalid sequence, a control character but the line end and the tab), an empty insert, and an insert past the bound are refused whole: the text and the selection do not change. A place from outside the model (a press of the pointer) is clamped to the text and moved back to the start of its character. The caret is never inside a character.
- **A text from the store is cleaned, never refused for its bytes.** Each invalid sequence and each control character but the line end and the tab becomes the replacement character, U+FFFD, and the log counts them. The store keeps the old bytes until the next commit writes the clean text.
- **The layout is display rows.** A row holds 80 cells; a tab goes to the next multiple of 4; a line longer than a row goes on the next rows. Each row has its start and its line, so the gutter numbers the first row of each line. The layout is computed whole after each change of the text: its cost is one pass over at most 32768 bytes, at a key, never in a frame. Each row but the last of a line holds 80 cells, and a byte takes at most 4 cells, so a text has at most 32769 rows: the array of rows has a fixed size.
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
| Edit a source of a project, in its environment | `enter(kernel_dev)`, then `edit(kernel, "src/kernel/enter.odin")`, where `kernel` is the store that the environment gives |
| See the versions of the text | `versions(notes, "today.txt")` |

## The refused forms

- **A port of micro.** micro needs the runtime of Go and a POSIX terminal, which the system does not have. Its Ctrl+S is a save action, against property 9.
- **micro in the Linux guest.** It works, but it is a program of Linux in a guest, not a program of modus: it edits the files of the guest, not the objects of a store.
- **Modes, as in vi.** A key with two meanings that the principal must keep in memory.
- **A save action, a swap file or a file of the undo.** Property 9 keeps each change already; the editor keeps no second copy.
- **An undo list in memory.** It would be a second copy of what the store keeps, and it would end with the process: Ctrl+Z after a restart would do nothing.
- **Pending changes by range at each key.** An insert in the middle moves each byte after it, so a range write is the whole rest of the text; and the end of a connection drops its pending changes, so they lose what a group in progress loses. The whole write of at most 32 KiB at the end of a group is one call. Ranges come back with texts larger than one call region.
- **A pause as the end of a group.** A commit after some seconds with no key would make the versions depend on the speed of the hands, and a machine test on the speed of the host.
- **A cut row at the edge of the window.** A cut text breaks the design rules; a long line goes on more rows.
- **A layout in each frame.** Its cost would grow with the text in each frame.

## Subtle points and hazards

- **A commit for each group is a cost.** Each commit writes its blocks and a root, and reads them back ([dropped_write.md](dropped_write.md)). The size of a group is a measure to make. Property 9 leaves open how a process groups small changes into one step; this is the first answer.
- **The retention rule thins the versions.** All versions for 10 minutes, then one an hour for a day, then one a day. So Ctrl+Z after a day goes back by hours, not by groups.
- **A change after Ctrl+Z.** The versions after the current one stay in the history of the object, and `versions` lists them. Ctrl+Y no longer reaches them: Ctrl+Y goes forward only along the restores that Ctrl+Z made. The walk goes back by generation, so a later Ctrl+Z can reach a version that an earlier Ctrl+Z left: the history of the object is one line, as the store keeps it.
- **The list of the versions has a bound.** The store gives the oldest first; the editor lists 1024. An object with more versions refuses the undo with one line of the log, until the thinning removes some.
- **A text that the editor cannot hold is never written.** A damaged object starts an empty text that the next change writes as a new version, with the old one kept. An object that cannot be read, or that is too long, ends the keeping: the editor keeps nothing, so it never writes over a text that it did not read.
- **One object, not a store.** The editor gets a connection to a store; the grant of one object waits for the document service with its picker.
- **The clipboard refuses a line end.** A text of the clipboard holds no control character ([clipboard.md](clipboard.md), "The border of a text"), and a line end and a tab are control characters. A copy of a selection over two lines is then refused. The clipboard needs a kind of text with line ends and tabs before the editor copies more than one line.

## Open questions

- **The size of a group of changes**, from a measure of the cost of a commit.
- **The grant of one object** in place of a whole store, before the document service.
- **A text with line ends on the clipboard**: a new member of `Clipboard_Kind`, or a border that takes the line end and the tab for every text.

## State

Built: the module `edit`, with its own store and the object `text`; the text model with its host tests; the keys of the caret and of the selection, Backspace, Delete, Escape; the pointer (a press, a drag, the wheel); the display rows with the gutter; the groups of changes as commits; Ctrl+Z and Ctrl+Y as the walk over the versions; the machine step that types two lines, undoes, redoes and selects. Left: the clipboard (the editor declines a copy and refuses a paste), Ctrl+F, the edit of another object (`edit(store, name)`), a resizable window, the loss of the focus as the end of a group, and texts larger than one call region.
