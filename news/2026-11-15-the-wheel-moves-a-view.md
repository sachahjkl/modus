title: The wheel moves a view
date: 2026-11-15
release: next
picture: none
kind: Shown
guide: docs/INTERFACE.md

The wheel of the mouse now moves the view under the pointer. One notch moves it by three lines. This works over the lines of a terminal and its completion list, the text of the program `manual`, the cards of `hall_of_fame`, a list, and the rows of the palette. A view shorter than three lines moves by its own height, so a notch never skips a line that the view did not show. Only the window in front gets the wheel, as it gets the keys: a window behind does not move. The input service asks the mouse for its wheel at the start, and the log says `input: ok, the mouse has a wheel`. The machine test turns the wheel over the console, a list and the palette, and waits for the line of each view that moved.
