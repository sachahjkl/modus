title: The boot display at the scale of the screen
date: 2026-11-18
release: next
picture: docs/screenshots/boot.png
kind: Shown
guide: docs/DESIGN.md

modus is an operating system with a small kernel. While the machine starts, it shows the boot display: the stages of the start with their times, the memory, the machine, the files of the boot image and the first processes.

The boot display was 976 by 708 pixels, half of a screen of 1920 by 1080. It now takes one scale from 1.25 to 2, in steps of one eighth: the largest at which it fits the screen with a margin of 8 pixels. On a screen of 1920 by 1080 the scale is 1.5, and the display is 1464 by 1062 pixels in the middle of the screen. It keeps its proportions: it is never stretched across. Each card, bar, gap and text is drawn again at that scale, so the text of the cells is drawn from the outlines of its font at 12 by 24 pixels, and not enlarged from a picture.
