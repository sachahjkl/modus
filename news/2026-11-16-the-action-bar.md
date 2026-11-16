title: The keys of a window are an action bar
date: 2026-11-16
release: next
picture: docs/screenshots/action_bar_more.png
kind: Shown
guide: docs/INTERFACE.md

A window that the keyboard drives names its keys in an action bar at its bottom. Each item is a key combination drawn as keycaps, then the name of the action. A press on an item runs the action, as its key does. When the items do not fit, the items of lowest priority go into a list behind a button `more`. The list opens upward, inside the window, and Up, Down, Enter and Escape move in it. The picture shows the debugger window with its list open: detach has the lowest priority, so it is in the list. The machine test opens the list and detaches with a press on that row. The window `interface_elements` shows all its items in one row (`action_bar.png`). Before, each window wrote its keys as one line of dim text, and the pointer could do nothing with it. Ten windows use the bar: `manual`, the terminal, `settings`, `notes`, the debugger window, `unlock`, `interface_elements`, `tally`, `rings` and `paint`.
