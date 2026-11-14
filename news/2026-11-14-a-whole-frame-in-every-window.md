title: A window never shows a picture that is being drawn
date: 2026-11-14
release: next
picture: none
kind: Fixed
guide: docs/INTERFACE.md

A film of the program `heron` showed, in one picture of the screen, the head of the heron with no body. The program had cleared a part of its window and had not drawn the heron in it yet, and the compositor read the window at that time. Three programs had a correction of their own. The 48 other programs with a window could show the same mix: a part of a new picture with a part of the old one.

The correction is now a rule of the system. The surface of every window has two pictures. A program draws one picture while the compositor reads the other, and the compositor shows a picture only when its program says that it is complete. A program that stops in the middle of a draw leaves its last complete picture on the screen. A new window shows its first picture whole, and nothing before it.

A program writes no code for the rule. The compositor never waits for a program, and it counts, for each window, the pictures that a program drew while the screen showed them: `compositor.windows()` gives the count, and the main test of the system checks that it is 0 for each window. The cost is memory: one picture more for each window, 2.8 MiB for the largest window.
