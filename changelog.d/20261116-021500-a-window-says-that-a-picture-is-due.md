type: Fixed

**A machine test takes no picture while a window owes one**: a program that draws on its own clock, such as a terminal, now tells the compositor when a change waits for its next picture (`display.picture_due_set`), and `compositor.windows()` gives it in the field `due`. The condition of a picture of the machine tests waits until no window has a due picture. Before, a picture of the console could show the head of a table without its row.
