title: The palette sets the scheduling strategy
date: 2026-11-14
release: next
picture: docs/screenshots/palette_strategy.png
kind: Shown
guide: docs/DESIGN.md

The palette now reaches the scheduling strategy of the machine. Type `:strat` and the list shows one entry for each strategy of the kernel: round robin, fair and EEVDF. The one that the machine uses now says `setting, in use`. Enter sets the chosen one, and the machine changes its strategy with no stop. The program `scheduler` does the change, because it is the one program with that right; it must run. The console has the same act as a command, `strategy("eevdf")`.

The pointer does more in the panel. A press in a field of the form of a command puts the caret there, and a press on a candidate takes it. The scroll bar of the list moves the rows: the arrow buttons, the track and the thumb work as in a terminal. The completion list of the console has the same scroll bar.
