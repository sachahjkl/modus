title: Notes, with no save action
date: 2026-11-22
release: next
picture: docs/screenshots/notes.png
kind: Shown
guide: docs/DESIGN.md

The program `notes` keeps the notes of a principal. The list at the left names each note by its first line. The text has the keys of the editor, the selection and the clipboard, and wraps by word at the width of the window.

There is no save action. A change is one commit when the keys pause for one second, or when another note is shown. A sentence is one version, not one version for each key.

Ctrl+H lists the versions of a note by the date of each commit. Down shows an older one, and Enter makes it the note again in a new commit: the note before it stays a version.
