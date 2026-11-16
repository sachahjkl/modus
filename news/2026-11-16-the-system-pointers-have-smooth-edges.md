title: The pointers of the system have smooth edges
date: 2026-11-16
release: next
picture: docs/screenshots/pointers_system.png
kind: Shown
guide: docs/POINTERS.md

The pointer theme of the system is the pointer of each release image. Its 15 shapes were grids of squares of 2 pixels, with a staircase on each slanted side. They are now outlines: contours of lines and curves in a text file of the repository. The build draws them at 24 and 48 pixels with the rasterizer of the fonts, with the exact part of each pixel that a shape covers. Each shape is a white fill inside a black edge of 1 pixel: the white shows on the dark desktop, the black on a light text. The level and upright edges are on whole pixels, so they stay sharp. `wait` turns a dot around a ring in 8 frames of 125 ms. The compositor and the format of the theme file did not change.
