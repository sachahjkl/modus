title: The programs that show a picture use the shared drawing code
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/INTERFACE.md

The programs heron, life, paint, plasma and temple, and the three programs that compute a picture with several threads, now draw their windows with the drawing module, as 24 other programs did before. The system then holds one copy of that code for 32 programs, and one correction reaches each of them.

A picture of a program used to be named by an address, which an export of a module cannot carry. It is now named by values: the place of its first pixel in one run of pixels of the program, and the pixels from one line to the next. The module reads those pixels where the program has them, with no copy.

The screen shows the same pixels as before. The terminal and the compositor still hold their own copy of the drawing code.
