title: The palette shows the unit of a number
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/DESIGN.md

A field of a command in the palette now shows what its number counts. Type `>buffer` and Enter: the band shows `buffer(count:  pages)`, and the unit stays after the number while it is typed. The command `wait_stop` shows `ms` after its number. The unit is in the color of a size or of a time, as in the log. The number is typed in the unit that the command reads; the palette converts nothing.

The buttons of a field now take the pointer. The command `strategy` shows its three strategies as buttons in the band: a press on one takes it, as Tab takes the one that Left and Right chose.
