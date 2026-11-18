# The clipboard

The principal copies a text in one window and pastes it in another. A program reads the clipboard only at a paste of the principal, and writes it only at a copy of the principal. The guide is [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The clipboard"; the protocol is in `src/library/support/display`.

## Constraints

- **No program reads the clipboard by itself** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close", line 5). The content reaches a program only at a paste action of the principal, and only the window in front.
- **No global name** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "8. No global, mutable, shared file system", and line 11 of property 20). The clipboard is no object that a program names: it is a state of the compositor, and a program reaches its content only by a handle that the compositor gives at a paste.
- **Whoever creates an object pays for it** ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "14. Memory is supplied by the caller"). The content of a copy is memory of the program that copies.
- **A count or a byte from another party is copied, then checked.** The program that copied keeps the memory that it made: it can write it after the copy.
- **The compositor never waits for a program.**

## The chosen form

### Who holds the clipboard

The compositor. It sees the keys of the principal before any program, and it already holds the one path of the keys to the window in front. The clipboard is one slot of the compositor: a memory handle with Read and Give, the kind of the content, its count of bytes, and the window that copied. The slot is empty at the start.

### The keys

- **Control+C** copies, **Control+V** pastes. The compositor reads them from the input service by the character of the key (the layout gives it) with the bit Control, takes the press and the release, and gives them to no program as keys. A program never sees them, and no program can send them: a program writes no record of the input ring.
- While the palette is open, it takes the keys first, as for each key.
- Control+X (a cut) and a paste from a menu come later: they are the same two actions with another source of the principal.

### A copy

1. At Control+C, the compositor sends the event `Copy_Asked` to the window in front, and keeps that a copy waits for its answer. A second Control+C while it waits sends nothing.
2. The program answers once. With a selection, `display.copy_send` checks the text (UTF-8 with no control character, 1 to `CLIPBOARD_TEXT_LIMIT` bytes), makes a memory object of the pages of the text with its own budget, writes the text, gives the compositor a handle with Read and Give through the ring of its window, then unmaps and closes its own handle, and sends `Copy` (handle, kind, count). With nothing to copy, or a refused text or budget, it sends `Copy_Declined`.
3. The compositor checks the record at its border (`clipboard.copy_refusal`): a copy that it asked, a gift of this program through its ring, a memory object with Read and Give, a kind that names a member, a count of 1 to `CLIPBOARD_TEXT_LIMIT`, memory that holds the count. A refused record changes nothing and is counted. A taken one replaces the slot: the compositor closes the handle of the content before.

The compositor reads no byte of the content: the program that copied can still hold a handle with Write, so a check by the compositor would prove nothing about the bytes that the paste reads.

### A paste

1. At Control+V, with a content in the slot and a window in front, the compositor makes a copy of its handle in its own table (the lent handle), gives the program of the window in front a handle with Read only from that copy, through the ring of its window, and sends the event `Pasted` (handle, kind, count). With no content, nothing goes, and the log has one line.
2. The program calls `display.paste_read` with the memory of its field. It checks the handle (a gift through its ring, memory, Read, room for the count), maps it with Read, copies the count of bytes into its own memory, unmaps it, closes it, sends `Paste_Taken`, and then checks the copy: UTF-8 with no control character. A text that the check refuses is not inserted. A paste never carries Enter, Tab or any control character, so a paste never runs a line of the console.
3. At `Paste_Taken`, the compositor revokes the lent handle (each handle and each mapping that came from it ends) and closes it. A `Paste_Taken` with no lend to this window is refused and counted. A program that does not answer keeps the handle only until the next copy or paste key, or until it ends: the compositor revokes the lend then.

A paste goes only at a key of the principal: no record of a program asks for one, and the one record of a paste that a program sends, `Paste_Taken`, is refused when no paste of the principal came before it.

### The kinds of content

`display.Clipboard_Kind` is a closed set: `Text` only today, UTF-8 with no control character. A word that names no member is refused at each border. A new kind (a picture) is a new member, with the checks of its own format at the reader.

### The size limit

`CLIPBOARD_TEXT_LIMIT` is 4096 bytes: one page, a field or a line of the console. The reader copies at most that, and a field with less room refuses the paste whole: a cut text would be a text that the principal did not copy.

### How long a content lives

Until the next copy that the compositor takes, or until the program that copied ends: at its end the compositor closes the handle of the content, and the slot is empty. A program that ended pays for nothing. A lend in progress keeps its own handle until `Paste_Taken`, the next clipboard key, or the end of the pasting program.

### Where the text goes in the programs

- **The interface package.** `window_events` keeps `Copy_Asked` and `Pasted` in the input of the next frame. The `text_input` element with the focus gives its text to a copy, and inserts a paste at its end. After the frame, `window_frame_end` answers: `copy_send` with the text of the element, `copy_decline` when no element took the copy, and `paste_refuse` when no element took the paste.
- **The terminal, and so the console.** The terminal declines a copy: it has no selection yet. It reads a paste into its own memory and gives each character to the program as a key record with no key code, as the principal could type it, when the queue of the program has room for all of them; else nothing is typed, and the log has one line. The line editor of the console takes them as typed characters.

## The refused forms

- **The compositor copies the bytes into its own memory at the copy.** The compositor would then pay for the content of each copy, a cost that a program chooses (property 14).
- **The program that pastes asks for the content.** Each program could then read the clipboard when it likes (property 20, line 5).
- **The handle of the copy given whole to the paster.** The paster could give it on, and keep it past the paste; the lent handle is revoked at `Paste_Taken`.
- **The compositor checks the text at the copy.** The bytes can change after the check; the reader copies, then checks its copy.
- **The content kept after the end of the program that copied.** The memory would belong to a program that has no budget any more.
- **A part of a paste that is too long for a field.** A cut text is a text that the principal did not copy.
- **A paste into the console as one record of text.** The terminal ring carries keys; a new record of text is a change of the protocol of the terminal for one action, and the key records already carry each character to the line editor.

## Subtle points

- A program that reads its events itself and ignores the two events (as `notes`, `paint` or `manual` do today) never answers: a second Control+C over its window sends nothing, and its lend ends at the next key of the clipboard. Only its own window loses the copy; no other window waits.
- A key of the clipboard is a key record that the compositor counts as each key, so a machine test that waits for its key records still counts them.
- The words of `Pasted` and of `Copy` are read as words: a handle past 32 bits, a kind that names no member, a count of 0 or past the limit, are refused before any cast.
- The pure decisions are host-tested: `src/library/private/compositor/clipboard` (the key of a record, the refusal of a `Copy`, of a `Copy_Declined`, of a `Paste_Taken`) and `src/library/support/display` (the check of a text to copy, and of a copied paste).

## State

Built: Control+C and Control+V in the compositor, the slot and its end with the program that copied, the lent handle of a paste, `copy_send`, `copy_decline` and `paste_read`, the text field of the interface package as a source and a target, and the console as a target through the terminal. Left: a cut, a selection, the palette as a target, a paste from a menu, other kinds.
