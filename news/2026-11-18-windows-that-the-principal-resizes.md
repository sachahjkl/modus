title: A window takes the size that the principal drags
date: 2026-11-18
release: next
picture: none
kind: Shown
guide: docs/DESIGN.md

modus is an operating system with a small kernel, in which each program draws its window into memory of its own, and the compositor shows it.

The principal can now drag an edge or a corner of a window whose program declared it resizable. The pointer takes the resize shape over the edge, and an outline shows the new frame during the drag. At the release the program makes a surface of the new size, paid by its own budget, and draws its next frame in it. Until that frame, the window keeps its old size and picture, so the screen never shows a size that the program did not draw, and the compositor never waits for a slow program.

The window of `clock` is the first resizable window: its table takes the width that it gains.
