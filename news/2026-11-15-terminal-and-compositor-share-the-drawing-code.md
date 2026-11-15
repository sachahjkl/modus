title: The terminal and the compositor use the shared drawing code
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/INTERFACE.md

The terminal and the compositor now draw with the drawing module, as 32 other programs did before. The system holds one copy of that code for 34 programs, and one correction reaches each of them, the screen of the desktop too.

The text of a terminal is a grid of up to 104 by 32 cells. Its cells now travel with the texts of the frame, so the module compares and draws them with no new argument. A frame of the terminal crosses into the module at most 9 times, whatever the count of colors in its lines.

Each window on the desktop shows the memory of another program. The compositor now draws each window with a call of its own. With 17 windows, a frame of 8 changed rectangles makes at most 144 calls: about 0.35 microseconds, against about 1.3 milliseconds for the whole screen.

The screen shows the same pixels as before.
