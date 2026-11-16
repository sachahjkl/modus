title: Every window follows the light appearance
date: 2026-11-16
release: next
picture: docs/screenshots/monitor_light.png
kind: Shown
guide: docs/DESIGN.md

Twenty programs drew some colors of their own, and those colors stayed dark in the light appearance: the bars of `monitor`, the measures of `clock`, the levels of the log, the headings of `manual`, the states of `rings`. Each window now takes each color from the color tokens, by its meaning, so it changes with the appearance.

A color keeps its meaning in both appearances. A kernel entry is in the kernel blue, a page in the color of memory, an answer that is not the expected one in the color of a failure. Each text keeps a contrast of at least 4.5 to 1, and host tests compute each pair.

Three tokens are new: a warning color, a link color, and eight series colors that tell apart things of one kind, such as the threads of a program or the records of a ring. The boot display stays dark: it draws before any setting is read. The stage of `heron` stays dark too: it is a picture of the dark mark.
