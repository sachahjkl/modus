# The edge of the bar

## Purpose

The principal chooses the edge of the screen that holds the bar of the desktop: the top, or the bottom (`desktop_shell.Bar_Position`, through the export `bar_position` of the compositor or the right-click menu of the desktop). The whole bar moves: its surface, the mark, the buttons `start` and `windows`, the hint of the palette, the clock, the mark of a viewer, the plates of the windows and the badges of the tray. Each menu and each popover that the bar opens opens away from the edge: down from a bar at the top, up from a bar at the bottom.

## Constraints

- **A press lands on what the eye sees.** The compositor draws the bar and tests a press against it, and the modus tool clicks it in the machine test. The three read one table of places.
- **A bar at the top keeps each place that it had.** The machine test clicks the buttons, the lines of the menus, the clock and the close buttons of the windows at fixed places.
- **A place on a closed set.** The edge is an enum, and each `switch` on it is whole.

## The chosen form

**The edge is a field of the layout of the bar.** `bar.Layout` holds the measured widths of the texts, and also the edge (`bar.Edge`: `Top` or `Bottom`) and the logical height of the screen. The zero value of the layout is a bar at the top, so a reader that knows only the widths (the modus tool) gets the places of a bar at the top. Every place of the package (`button`, `menu`, `line`, `windows_menu`, `windows_line`, `mark_y`) comes from `top(layout)` and `menu_top(layout, height)`. The compositor sets the edge at one place (`bar_place_update`), when the setting or the size of the screen changes, and damages the old and the new places.

**The setting and the place are two types.** `desktop_shell.Bar_Position` is the setting of the contract, with four members. `bar.Edge` is the place that the compositor draws, with two. A bar on the left or on the right is not drawn yet: the compositor draws it at the top.

**A menu opens away from the edge.** `menu_top` gives `HEIGHT` under a bar at the top, and `top - height` over a bar at the bottom, never above the screen. The start menu keeps its order of names in both. The menu of the windows over a bar at the bottom puts its first line next to the bar and the next ones above it: a line then has its place with no count of the windows, as under a bar at the top, so `windows_line` and `windows_line_center` keep their arguments.

**The viewer popover of the remote display is moved, not laid out again.** Its package gives its places under a bar at the top; the compositor moves the card up by one vertical shift when the bar is at the bottom, and moves the point of a press down by the same shift before the test.

## Refused forms

- **An offset added at each draw call of the compositor.** Each consumer then adds it again, and one that forgets draws a button where no press lands.
- **`Bar_Position` in the layout.** A bar on the left needs other places for each button. A member that the package cannot place is a case that a whole `switch` must invent.
- **The windows menu in its order over a bar at the bottom.** Each line then moves when a window opens, and each caller of `windows_line` needs the count.

## State

Built: the top and the bottom, the menus, the popovers and the context menu of the desktop. Left: a vertical bar.
