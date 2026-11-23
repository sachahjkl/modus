# Notes

`notes` is the notes application of a principal: a list of notes, the text of one note, and the versions of that note, in one window. It is the desktop application of property 9: no file, no path, no save action, and a history of each note that the storage service keeps. The guide is [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The notes".

## Purpose

A principal writes short texts: a list, a draft, a reminder. They expect the keys of a text editor, several notes, and no step to keep them. `notes` gives that with the persistence of the system and no code of its own for the history.

Before, the module `notes` was a proof of persistence with one line of text, a count and one commit for each key. That proof is now the test module `persistence_check`, which only the machine tests start: a test needs one commit for each key to know each generation, and a principal needs the opposite.

## Constraints

- [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "Persistence: no save action, and versions for all processes": the store holds each note, and the window has no save action.
- No work in a frame in proportion to the text: the rows of a note are computed after a change and after a resize, never in a frame.
- The text of a note is the text of the editor ([editor.md](editor.md)): UTF-8 with no control character but the line end and the tab, at most 32768 bytes, one call region of the storage service for a whole write.
- [`docs/DESIGN.md`](../../../docs/DESIGN.md), "5. Text": no cut text and no text over another text.

## The chosen form

- **One object for each note** in the private store. A new note gets the name `note_` and a serial of six digits, the next after the largest of the store, so the order of the names is the order of creation and the list needs no object of its own. The store holds a new note from its first commit: an empty new note that the principal leaves is not written. Each other object of the store is a note too, under its own name (a `storage.clone` from the console shows as a note).
- **The title is the first line.** The list shows each note by its first line, cut after a whole character in 60 bytes; a change of the first line renames the note, with no rename of its object. The start reads the first 64 bytes of each object with `read_range`, not the whole note.
- **A commit after a pause, or after 5 seconds.** A change waits until the keys pause for one second, or until 5 seconds have passed since the first change that waits, or until another note is shown, the versions open or the note is deleted; then the whole text is one commit. A sentence typed in one go is one version, not one version for each key. A principal who types with no pause of a second gets a version each 5 seconds: without that bound, the change would wait as long as the keys go on. The loop of the window waits for its events with the nearer of the two ends as its deadline.
- **The text model of the editor.** The gap buffer, the caret, the selection and the moves are `modus:text_model`, which `edit` and `notes` share. Its layout takes the width of a row and the wrap: `notes` wraps by word at the width of the window, `edit` by character at 80 cells. A word that does not fit goes whole to the next row; a word longer than a row is cut by character; a space that does not fit starts the next row.
- **One pane at the left, for the notes or for the versions.** Ctrl+H puts the versions of the note shown in the place of the list, the newest first, each by the date of its commit; Down and Up choose a version, the text pane shows it and no key changes it, Enter restores it in a new commit and Escape goes back. The versions are about one note, so they take the place of the list of the notes, and the text keeps its width.
- **A deletion asks first.** Ctrl+D asks in the status band; Enter removes the object and its versions, Escape keeps it. A deletion is the one act that the versions do not undo.
- **The keys of an editor**, as in `edit`: no modes for the text; Shift selects; Ctrl+C, Ctrl+X and Ctrl+V go through the clipboard of the compositor ([clipboard.md](clipboard.md)) with text of several lines. Ctrl+N makes a note, Ctrl+Page Up and Ctrl+Page Down show the note before and after it, and a press on a line of the list shows that note. The action bar names the keys of the pane in force ([action_bar.md](action_bar.md)).
- **The pure parts** `internal:notes/note_list` (the list, the titles, the object names and the wait of a change) and `internal:notes/store_work` (the records and the queues of the store thread) have host tests at each edge.

### The store thread

The window thread makes no call of the storage service: no read, no write, no list. A second thread, the store thread, holds the connection to the store and does each call. The window thread puts a request (list, load, write, versions, version, restore, remove) in a queue of 4 and goes on drawing; the store thread runs the requests in their order, puts each result in a second queue of 4, and wakes the window thread, which waits for its events, for a result and for the end of the pause in one wait. A slow store never stops a frame.

- **The order of the requests is the order of the acts.** A write before a load before a remove: one queue, one thread, so the store sees what the principal did, in that order.
- **A result names its request.** The serial of the last load and of the last version read: a result of an older one is dropped, so a quick change of note shows the right text.
- **No key acts before the list.** Until the result of the list comes, no key makes, deletes or changes a note: the list from the store then replaces the list of the window, and a note made before it would be written over a stored one.
- **The text waits while it loads.** The status band says "loading", and no key changes a text that the store has not given yet. The keys also wait for the result of the versions and of a restore.
- **An act starts only when the queue takes it whole.** A change of note needs room for the commit and the load; a deletion for the removal and the load of the note shown after it; a restore for the restore and the load after it. Else the status band says that the store is busy, and nothing changed. A change keeps waiting one more pause when the queue is full. The window thread never waits for room.
- **A restore loads the note from the store.** Enter restores only a version whose bytes came, and the window then loads the note that the store made current, never its preview.
- **A note that could not be read is locked.** Its text is empty, no key changes it, and no commit writes it, until another note is shown.
- **Only a connection that ended stops the keeping.** A refusal, a damaged object or a buffer that is too small is the answer of one call: the status band says "not kept" until a write is done again, and the next change writes again. A version that cannot be read says so, and is not restored.
- **A cut is a change.** It waits with the typed keys; a copy changes nothing and needs no gate.
- **The rules are pure** in `internal:notes/note_session`: the gates of the keys, the room of each act, and which result the window takes; a host test gives each order of the acts and the results.
- **The window thread still enters the kernel for the queues**: the wake of the store thread, and a lock that it takes only for the copy of one record. These are the hand over of the work, not a call of a service.

## The refused forms

- **A commit for each key.** It made a version of each key, 35 for one sentence, and a store that grew at each key. It stays the form of `persistence_check`, whose test needs it.
- **The end of a group of changes as in `edit`** (a space, a line end, a move to another line). In a note that is a version for each word. The editor keeps it, as it walks back version by version with Ctrl+Z; `notes` lists its versions by date.
- **A pause in a machine test as a known count of versions.** A test that types waits for the fact of the commit that has its text; it never counts the versions that a pause made, as a slow host can split a word.
- **Rows of 80 cells, as in `edit`.** A note is prose: its lines follow the window. The cost of the layout at each step of a resize is one pass over at most 32768 bytes, at the resize, never in a frame.
- **An index object with the order and the titles of the notes.** A second source of the titles, which a stop between two commits would make wrong; the names give the order, and the first bytes give the titles.
- **A pane of the versions beside the list.** At the least width the text then had no room for a row.
- **The calls of the store on the window thread.** A slow disk or a busy storage service stopped the frames and the keys; the window thread hands each call to the store thread.
- **A save action, or a commit when the window closes.** The system has no save action; the close of a window stops the process with no event, so the wait is the bound of what a stop loses: the keys of the last second, or of the last 5 seconds when the keys never pause.

## Subtle points and hazards

- **A stop loses at most 5 seconds.** A change waits for its commit up to one second after the last key, and never more than 5 seconds after the first change that waits; a stop of the process in that wait loses it. A full queue starts the wait again from the time of the refusal. The status band says "a change waits" while it waits.
- **A note that cannot be read is never written.** A note longer than a text, or that the store cannot give, is not shown and keeps its bytes; a damaged note shows empty, and its next change writes a new text with the damaged one kept as a version.
- **The serials end.** After `note_999999`, no new name exists: the window says that the store refused the note. A deletion does not give a serial back.
- **The list holds 256 notes**, and the pane of the versions the newest 512 versions of a note; past them a fact says what is not shown.

## State

Built: the store thread with its two queues, the list of the notes with their titles, a new note, the deletion with its question, the text with its keys, the selection by keys and by the pointer, the clipboard, the wrap by word at the width of the window, the scroll bar, the commit after a pause or a change of note, the pane of the versions with the restore, and the machine steps of the main test. Left: a search in the notes, an undo by key, and notes larger than one call region: the text model takes a buffer that grows in an arena ([editor.md](editor.md), "The text model"), but the records of the store thread carry the bytes of a note inline, so a note keeps the inline buffer of 32 KiB until those records name bytes in an arena of each thread.
