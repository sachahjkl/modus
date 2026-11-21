# The clipboard

The principal copies a text in one window and pastes it in another. A process reads the clipboard only at a paste of the principal, and writes it only at a copy of the principal. The guide is [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The clipboard"; the protocol is in `src/library/support/display`.

## Constraints

- **No process reads the clipboard by itself** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 5). The content reaches a process only at a paste action of the principal, and only the window in front.
- **No global name** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "8. No global, mutable, shared file system", and line 11 of property 20). The clipboard is no object that a process names: it is a state of the compositor, and a process reaches its content only by a handle that the compositor gives at a paste.
- **Whoever creates an object pays for it** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller"). The content of a copy is memory of the process that copies.
- **A count or a byte from another party is copied, then checked.** The process that copied keeps the memory that it made: it can write it after the copy.
- **The compositor never waits for a process.**

## The chosen form

### Who holds the clipboard

The compositor. It sees the keys of the principal before any process, and it already holds the one path of the keys to the window in front. The clipboard is one slot of the compositor: a memory handle with Read and Give, the kind of the content, its count of bytes, and the window that copied. The slot is empty at the start.

### The keys

- **Control+C** copies, **Control+X** cuts, **Control+V** pastes. The compositor reads them from the input service by the character of the key (the layout gives it) with the bit Control, takes the press and the release, and gives them to no process as keys. A process never sees them, and no process can send them: a process writes no record of the input ring. Control+C and Control+X both send `Copy_Asked`, with `values[1]` carrying `display.Copy_Action` (`.Copy` or `.Cut`).
- While the palette is open, it takes the keys first, as for each key.
- A paste from a menu comes later: it is the same action with another source of the principal.

### A copy

1. At Control+C, the compositor sends the event `Copy_Asked` with a new serial to the window in front, and keeps that serial as the copy that waits. Each key has its own serial, from one counter of the compositor that starts at 1 and never gives a serial twice. A newer Control+C replaces the copy that waits: a process that lost the event answers the newest one, and no lost event blocks the copies of a window.
2. The process answers once, with the serial of the newest `Copy_Asked`. With a selection, `display.copy_send` checks the text (see "The border of a text"), makes a memory object of the pages of the text with its own budget, writes the text, gives the compositor a handle with Read and Give through the ring of its window, then unmaps and closes its own handle, and sends `Copy` (handle, kind, count, serial). With nothing to copy, or a refused text or budget, it sends `Copy_Declined` (serial).
3. The compositor checks the record at its border (`clipboard.copy_refusal`): a gift of this process through its ring; a number that names no handle that the compositor holds already (the content of now, or its lent copy), which it then neither takes again nor closes; the serial of the copy that waits; a memory object with Read and Give; a kind that names a member; a count of 1 to `CLIPBOARD_TEXT_LIMIT`; memory that holds the count. A refused record changes nothing and is counted. A taken one replaces the slot: the compositor closes the handle of the content before.

The compositor reads no byte of the content: the process that copied can still hold a handle with Write, so a check by the compositor would prove nothing about the bytes that the paste reads.

### A paste

1. At Control+V, with a content in the slot and a window in front, the compositor makes a copy of its handle in its own table (the lent handle), gives the process of the window in front a handle with Read only from that copy, through the ring of its window, and sends the event `Pasted` (handle, kind, count, serial). With no content, nothing goes, and the log has one line.
2. The process calls `display.paste_read` with the memory of its field. It checks the handle (`display.paste_problem`: a gift through its ring, memory, Read, room for the count), maps it with Read, copies the count of bytes into its own memory, unmaps it, closes it, sends `Paste_Taken` (serial), and then checks the copy (see "The border of a text"). A text that the check refuses is not inserted. A paste never carries Enter, Tab or any control character, so a paste never runs a line of the console.
3. At `Paste_Taken`, the compositor revokes the lent handle (each handle and each mapping that came from it ends) and closes it. A `Paste_Taken` is taken only with the serial of the lend that waits for this window: one with no lend, or for a lend that ended, is refused and counted. So a slow answer to a first paste, after a second paste, never ends the second lend. A process that does not answer keeps the handle only until the next copy or paste key, until it ends, or until the process that copied ends: the compositor revokes the lend then.

### The border of a text

`display.clipboard_text_problem` takes a text of 1 to `CLIPBOARD_TEXT_LIMIT` bytes, no more than the room of the place, and a `Clipboard_Text_Form` (`.Single_Line` or `.Multi_Line`). In `.Multi_Line` (used by `copy_send` and multi-line paste targets such as `edit`), LF (`\n`) and tab (`\t`) are allowed while CR (`\r`), NUL, every other C0/C1 control and invalid UTF-8 are refused. In `.Single_Line` (the default of `paste_read`, used by the terminal and single-line text fields), every control character including LF and tab is refused so a paste never runs a line of the console. Both forms also refuse each character that a reader does not see, or that changes the order in which a text shows: U+200B to U+200F (the spaces and the joiners of no width, the marks of direction), U+202A to U+202E (the embeddings and the overrides of direction), U+2066 to U+2069 (the isolates), U+2028 and U+2029 (the separators of lines and of paragraphs) and U+FEFF (the mark of the byte order). A pasted line of the console with one of them could show as another line, which the principal then runs.

A paste goes only at a key of the principal: no record of a process asks for one, and the one record of a paste that a process sends, `Paste_Taken`, is refused when no paste of the principal came before it.

### The kinds of content

`display.Clipboard_Kind` is a closed set: `Text` only today, UTF-8 with no control character. A word that names no member is refused at each border. A new kind (a picture) is a new member, with the checks of its own format at the reader.

### The size limit

`CLIPBOARD_TEXT_LIMIT` is 4096 bytes: one page, a field or a line of the console. The reader copies at most that, and a field with less room refuses the paste whole: a cut text would be a text that the principal did not copy.

### How long a content lives

Until the next copy that the compositor takes, or until the process that copied ends: at its end the compositor closes the handle of the content, and the slot is empty. A lend of what it copied ends with it too (`clipboard.client_end_effects`), also when a newer copy replaced that content, so no handle of the memory of a process that ended stays. A process that ended pays for nothing. A lend in progress keeps its own handle until `Paste_Taken`, the next clipboard key, the end of the pasting process, or the end of the process that copied.

### Where the text goes in the processes

- **The interface package.** `window_events` keeps `Copy_Asked` and `Pasted` in the input of the next frame. The `text_input` element with the focus gives its text to a copy, and inserts a paste at its end. After the frame, `window_frame_end` answers: `copy_send` with the text of the element, `copy_decline` when no element took the copy, and `paste_refuse` when no element took the paste.
- **The terminal, and so the console.** The terminal declines a copy: it has no selection yet. It reads a paste into its own memory and gives each character to the process as a key record with no key code, as the principal could type it, when the queue of the process has room for all of them; else nothing is typed, and the log has one line. The line editor of the console takes them as typed characters.

## The refused forms

- **The compositor copies the bytes into its own memory at the copy.** The compositor would then pay for the content of each copy, a cost that a process chooses (property 14).
- **The process that pastes asks for the content.** Each process could then read the clipboard when it likes (property 20, line 5).
- **The handle of the copy given whole to the paster.** The paster could give it on, and keep it past the paste; the lent handle is revoked at `Paste_Taken`.
- **The compositor checks the text at the copy.** The bytes can change after the check; the reader copies, then checks its copy.
- **The content kept after the end of the process that copied.** The memory would belong to a process that has no budget any more.
- **A part of a paste that is too long for a field.** A cut text is a text that the principal did not copy.
- **A paste into the console as one record of text.** The terminal ring carries keys; a new record of text is a change of the protocol of the terminal for one action, and the key records already carry each character to the line editor.

## Subtle points

- **A known risk: a copier can make the paster fault.** The paster reads the content through a mapping. A process that copied and kept its own handle of the memory, as a hostile process can, can revoke it while the paster reads: each mapping that came from it ends, and the paster faults and stops. The terminal is a paster, so such a process can stop the terminal of the console, when the principal copies from it and pastes there. No kernel operation copies bytes out of a memory object into the memory of the caller with a refusal in place of a fault. A read under the fault ring was refused: it needs a second thread in each paster that answers the fault, for one read of 4096 bytes. `ROADMAP.md` has the entry of a kernel copy; the paster then uses it, and the risk ends.
- A process that reads its events itself and ignores the two events (as `notes`, `paint` or `manual` do today) never answers. Each new Control+C over its window replaces the copy that waits, and its lend ends at the next key of the clipboard. No other window waits.
- The serial of each answer names its key: a late answer to a key that a newer key replaced, or to a lend that ended, never changes the state of now. The machine test waits for the line of the console, `console: the line shows "hello" after a paste`, which the console writes after it gives the terminal its line: the terminal then has a picture due, and the picture waits for it.
- A key of the clipboard is a key record that the compositor counts as each key, so a machine test that waits for its key records still counts them.
- The words of `Pasted` and of `Copy` are read as words: a handle past 32 bits, a kind that names no member, a count of 0 or past the limit, a serial of 0, are refused before any cast.
- The pure decisions are host-tested: `src/library/private/compositor/clipboard` (the key of a record, the refusal of a `Copy`, the serials, the answers to each key, what the end of a client ends) and `src/library/support/display` (the check of a text, of the facts of a paste before its copy, and of the words of the events).

## State

Built: Control+C, Control+X and Control+V in the compositor, the slot and its end with the process that copied, the lent handle of a paste, `copy_send`, `copy_decline` and `paste_read` with `.Single_Line` and `.Multi_Line` text borders, the editor `edit` as a multi-line source and target (copy, cut, paste), the text field of the interface package as a single-line source and target, and the console as a single-line target through the terminal. Left: a selection in single-line fields and the terminal, the palette as a target, a paste from a menu, other kinds, and a kernel copy out of a memory object for the paster (see the known risk).
