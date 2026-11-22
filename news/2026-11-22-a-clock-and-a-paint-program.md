title: A clock and a paint program
date: 2026-11-22
release: next
picture: none
kind: Shown
guide: docs/INTERFACE.md

The window `clock` is a clock now. Its first section shows the local time in large digits, the date with the time zone of the settings, and the calendar of the month, with today in blue; Page Up and Page Down change the month. The second section is a stopwatch with laps, the third a countdown timer from 1 second to 99 hours. At the end of the timer the window shows 00:00 in the warning color, and the process asks the compositor for a desktop notification. The checks and the measures of the time page, which the window showed before, are the demonstration `time_page`.

`paint` is a paint program now: a brush, an eraser, a line, a rectangle, an ellipse and a fill, eight sizes from 1 to 34 pixels, 16 colors and any other color by its red, green and blue. Ctrl+Z undoes a change and Ctrl+Shift+Z does it again, up to 64 changes. Ctrl+O opens the list of the pictures: a picture is saved under a name in the private store of the process, and opened from the list. The window is resizable, and a smaller window keeps the part of the picture that it does not show. The status line says the tool, the size, the color and the place of the pointer.
