title: The palette shows a setting as one row, and goes to the window of a setting
date: 2026-11-14
release: next
picture: docs/screenshots/palette_setting_row.png
kind: Shown
guide: docs/DESIGN.md

Type `:font` in the palette, and the font is one row: its name, then one button for each value, with a line under the font in use. Right chooses the next value, and Enter sets it behind the open panel. The scheduling strategy is one row of three buttons too.

The input band now says what the chosen entry does: `enter: run`, or `enter enter: destroy` for an entry that asks for a second Enter. When a window of the desktop acts on the same setting, it adds `shift enter: go to`. Shift and Enter bring the window of `settings` to the front, with the focus on the button of that setting. A program names its buttons for this in one call, and the palette finds them.
