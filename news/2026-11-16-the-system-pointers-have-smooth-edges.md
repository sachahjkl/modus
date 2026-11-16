title: The pointers of the system have smooth edges and two forms
date: 2026-11-16
release: next
picture: docs/screenshots/pointers_system.png
kind: Shown
guide: docs/POINTERS.md

The pointer theme of the system is the pointer of each release image. Its 15 shapes were grids of squares of 2 pixels, with a staircase on each slanted side. They are now outlines in a text file of the repository, which the build draws at 24 and 48 pixels with the rasterizer of the fonts. The edge is 1 pixel at both sizes, so the larger pointer is finer, not heavier. Each shape has a dark form, white in a dark edge, for a dark desktop, and a light form, dark in a white edge, for a light desktop. A few parts have an accent color: the arc that turns in `wait` and the question mark of `help` in the blue of the focus, the slash of `forbidden` in red, the dot of `crosshair` in amber. The program `pointers` shows both forms of each shape.
