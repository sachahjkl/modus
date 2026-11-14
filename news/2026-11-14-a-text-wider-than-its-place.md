title: A text wider than its place takes more lines
date: 2026-11-14
release: next
picture: docs/screenshots/inspect_stopped.png
kind: Fixed
guide: docs/INTERFACE.md

Several windows drew a text over another text, or stopped a text at the edge of a panel. The stack trace of a stop report ended in the middle of a path. A long name of a module ran over the page beside it. The interface package now has one rule for a text that is wider than its place. The text goes on more lines. A line ends at a space. A path or a long name has no space, so its line ends after a `/`, a `:` or a `_`. No character is left out, and the text under it starts lower. Each of the 112 pictures of the screen was read for this fault, and 17 programs and the boot display were corrected: among them `manual`, `errors`, `inspect`, `notes`, `fetch`, `net`, `imports`, `tables`, `server` and `log`. In `errors`, a page now holds the cases that fit in its height, each with its whole sentence. The window of `log` shows each text whole, where it cut it at 80 characters. A card that cannot show each of its rows ends with a line that counts the rows that it does not show.
