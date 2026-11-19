title: The screen for a viewer on another machine
date: 2026-11-19
release: next
picture: none
kind: Shown
guide: docs/QUIC.md

modus is an operating system with a small kernel, in which programs call each other's functions with typed values, and no text goes between processes.

The service `remote_display` sends the screen of the machine to a viewer on another machine over QUIC. It sends only the rectangles that changed, as tiles that a lossless coder in the manner of QOI codes, and the next frame goes only after the viewer took the last one. The compositor copies its damage into memory that the service gives, and never waits for it.

A principal allows the key of a viewer in the console, with `remote_display_allow(key, "view")` for the screen, or `"view_and_input"` to type too. While a viewer is connected, the bar shows the mark `viewer` with the start of its key, which the service cannot hide. `remote_disallow(key)` ends the session at once.

The machine test uses the tool as the viewer: the screen that it rebuilds from the tiles is the picture of QEMU of the same moment, pixel for pixel outside the pointer.
