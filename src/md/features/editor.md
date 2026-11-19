# The editor `edit`

`edit` is a native module of modus that edits a text object of a store, in a window. Its keys are the keys that most principals know from other systems: no modes, Shift to select, the mouse. It has no save action: each change is a version of the object, so the undo of the editor survives a restart.

## Purpose

A principal who works in modus writes text: the source of a project, a declaration, a note. Today the system has the console line and no editor of a whole text. The editor comes before the C compiler of [first_compiler.md](first_compiler.md), so that the sources of the first native stages can be written in modus.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Persistence: no save action, and versions for all processes": the document in the store is always current, and the system has no save action.
- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close": the editor reaches only the stores that it was given, and the clipboard only at a copy or a paste of the principal.
- [`docs/DESIGN.md`](../../../docs/DESIGN.md), "5. Text": the text of a window follows the design rules, with no text over another text and no cut text.
- [text_encoding.md](../data/text_encoding.md): UTF-8 with no control character but the line end and the tab.

## The chosen form

- **A native module in Odin**, on the package `interface`, so it has the look, the keys and the damage rules of every window.
- **The keys, with no modes:**
  - Ctrl+Z restores the version before; Ctrl+Y goes forward again.
  - Ctrl+F finds a text in the object.
  - Shift with an arrow, Home, End or a press of the pointer selects.
  - Ctrl+C and Ctrl+V go through the clipboard of the compositor ([clipboard.md](clipboard.md)): the compositor takes the keys, the editor answers `Copy_Asked` with its selection and inserts the text of `Pasted`. Ctrl+X comes with the cut of the clipboard, which is planned work there.
  - The pointer places the caret, selects with a drag, and scrolls.
  - The action bar shows the keys ([action_bar.md](action_bar.md)).
- **No save action.** The editor sends each change to the storage service when it occurs. A change of the object is a version (property 9).
- **Undo is a walk over the versions.** Ctrl+Z restores the version before the current one; Ctrl+Y the version after. After a restart, the versions are still there, so Ctrl+Z still works.

## The frequent tasks

| Task | Expression |
|---|---|
| Edit a text of a store | `edit(notes, "today.txt")` |
| Edit a source of a project, in its environment | `enter(kernel_dev)`, then `edit(kernel, "src/kernel/enter.odin")`, where `kernel` is the store that the environment gives |
| See the versions of the text | `versions(notes, "today.txt")` |

## The refused forms

- **A port of micro.** micro needs the runtime of Go and a POSIX terminal, which the system does not have. Its Ctrl+S is a save action, against property 9.
- **micro in the Linux guest.** It works, but it is a program of Linux in a guest, not a program of modus: it edits the files of the guest, not the objects of a store.
- **Modes, as in vi.** A key with two meanings that the principal must keep in memory.
- **A save action, a swap file or a file of the undo.** Property 9 keeps each change already; the editor keeps no second copy.

## Subtle points and hazards

- **A commit for each key is a cost.** Each commit writes its blocks and a root, and reads them back ([dropped_write.md](dropped_write.md)). The editor sends each change at once as a pending change ([`docs/STORAGE.md`](../../../docs/STORAGE.md), "Ranges"), and commits a group of them: a word, a paste, a move of the caret to another line, the loss of the focus, the stop. A stop of the machine loses at most the group in progress. The size of a group is a measure to make. Property 9 leaves open how a process groups small changes into one step; this is the first answer.
- **The retention rule thins the versions.** All versions for 10 minutes, then one an hour for a day, then one a day. So Ctrl+Z after a day goes back by hours, not by groups.
- **A change after Ctrl+Z.** The versions after the current one stay in the history of the object, and `versions` lists them. Ctrl+Y no longer reaches them: Ctrl+Y goes forward only along the restores that Ctrl+Z made.
- **One object, not a store.** The editor gets a connection to a store; the grant of one object waits for the document service with its picker.
- **A large text.** The editor keeps a line index that it changes at each change, never computes in a frame.

## Open questions

- **The size of a group of changes**, from a measure of the cost of a commit.
- **The grant of one object** in place of a whole store, before the document service.

## State

Designed, not built.
