title: An editor of text with no save action
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/DESIGN.md

modus is an operating system with a small kernel, in which each program keeps its state in a private store with versions, and has no save action.

`start("edit")` opens the editor of a text. It has no modes: a character goes in at the caret, Shift with an arrow selects, and the pointer places the caret and selects with a drag. A line longer than the window goes on more rows, and a gutter numbers the lines.

The editor writes the text to its store after each word, each line end, and each move to another line. Each write is a version of the object. Ctrl+Z restores the version before from the store, so it also works after a restart of the machine, and Ctrl+Y goes forward again.

A text holds at most 32768 bytes. Copy and paste, the search and the edit of another text come next.
