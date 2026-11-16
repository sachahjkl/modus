title: The screen shows each frame of the desktop whole
date: 2026-11-16
release: next
picture: none
kind: Shown
guide: docs/ARCHITECTURE.md

modus is an operating system in which one program, the compositor, puts the windows of all the programs on the screen. Until now it copied the changed parts of each frame into the memory that the display showed, so the display could show the top of a new frame over the bottom of the frame before.

The video memory of the display of the test machine holds two screens. The compositor now writes each frame into the screen that the display does not show, then one write of a display register makes the display show it, in one step. A window that changes many times a second then never shows a cut between two of its frames.

The compositor counts the frames that it wrote into the screen that the display showed. The main machine test requires that count to be 0.
