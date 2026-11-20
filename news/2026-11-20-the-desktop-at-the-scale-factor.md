title: The desktop draws at a scale factor of 1.25
date: 2026-11-20
release: next
picture: none
kind: Shown
guide: docs/INTERFACE.md

modus is an operating system with a small kernel, in which each window is a process that describes its frame as a table of draw records.

Until now the desktop of the screen of 1920 × 1080 drew one pixel of the screen for each pixel of a layout, so its text was small. It now draws at a scale of 1.25 by default: the windows, the bar, the menus, the palette, the text and the pointer are a quarter larger, on a layout of 1536 × 864. The row `scale` of the settings window sets 1.375.

A process still places in logical pixels and never computes a pixel of the screen. The drawing module turns each place into the screen, with each edge rounded to the nearest pixel, so two boxes that share an edge meet with no gap. In a window built from the elements of the interface, each glyph is drawn at its size on the screen, not stretched. A few windows still draw their pixels by hand, as the log: they show a picture of their layout, whose text is less sharp until they move to the elements.

The scales from 1.5 to 2 come when every window fits their smaller layout.
