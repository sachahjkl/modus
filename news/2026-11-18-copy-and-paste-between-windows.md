title: A text copied in one window is pasted in another
date: 2026-11-18
release: next
picture: docs/screenshots/clipboard_paste.png
kind: Shown
guide: docs/DESIGN.md

modus is an operating system with a small kernel, in which a program sees nothing that no one handed to it, the clipboard included.

The principal can now copy the text of a field with Control+C and paste it with Control+V into a field of another window, or into the line of the console. The compositor takes both keys: no program sees them, and no program can send them. A program reads the clipboard only at a paste of the principal, through a handle that the compositor lends for that paste and then revokes. The reader copies the text first, then checks it, so a paste never carries an Enter into the console.
