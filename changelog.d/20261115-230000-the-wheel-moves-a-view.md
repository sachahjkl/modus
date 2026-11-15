type: Added

**The wheel of a pointing device moves a view.** The input service asks the PS/2 mouse for the IntelliMouse protocol and reads its wheel; each wheel notch over a view moves it by three lines: the lines and the completion list of a terminal, the text of `manual`, the cards of `hall_of_fame`, a list, and the rows of the palette. Only the window in front gets the notches, as it gets the rest of the input. The log line `input: ok` is now `input: ok, the mouse has a wheel`, and a pointer record has a fourth value, the notches.
