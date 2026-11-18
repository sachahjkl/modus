title: The boot display at the scale of the screen
date: 2026-11-18
release: next
picture: docs/screenshots/boot.png
kind: Shown
guide: docs/DESIGN.md

modus is an operating system with a small kernel. While the machine starts, it shows the boot display: the stages of the start with their times, the memory, the machine, the files of the boot image and the first processes.

The boot display was 976 by 708 pixels, half of a screen of 1920 by 1080. Its font is Spleen, a bitmap font drawn for several sizes. It now takes the largest of the scales 1, 1.5, 2 and 4 at which it fits the screen with a margin of 8 pixels: each of them is a size of Spleen, so each letter fills its cell. On a screen of 1920 by 1080 the scale is 1.5, the text is Spleen 12 by 24, and the display is 1464 by 1062 pixels in the middle of the screen. It keeps its proportions: it is never stretched across. Each card, bar, gap and text is drawn again at that scale, not enlarged from a picture.
