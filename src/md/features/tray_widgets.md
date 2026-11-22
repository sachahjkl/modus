# The tray widgets

## Purpose

The tray of the bar shows the state of the desktop. Three parts of it also open a card over the desktop, a tray widget: the button of the control center, the button of the notifications, and the clock. A tray widget gives the principal the state and the acts of the desktop that the compositor owns, one press from the bar, with no module to start: the bar edge, the magnifier, the appearance and the display in force, the history of the notifications, and the month of today.

The places, the hit tests, the history of the notifications, the grid of a month and the state of the press are in `src/library/internal/compositor/bar/tray_widgets.odin`, so a host test gives each edge. The compositor draws and acts (`src/modules/system/compositor/tray_widgets.odin`).

## Constraints

- **A press lands on what the eye sees.** Each place is a procedure of the bar package from the bar layout and the width of the screen. The compositor draws from it and tests a press against it; no reader adds an offset ([bar_edge.md](bar_edge.md)).
- **One card at a time.** A tray widget, the start menu, the menu of the windows, the list of the viewers and the context menu of the desktop never show together: opening one closes the others.
- **The marks that a capture or an assistive holder asks for are never left out.** The tray buttons have fixed places at the right of the tray, next to the clock; the mark of a viewer, the marks of the assistive holders and the pills of the tray start at their left.
- **Each part of a card says one fact once.** A tile says its name and its value; the blue plate says that a switch is on; the dot of the bell says that the history is not empty.
- **The keys reach each act** (`src/md/features/accessibility.md`, "3. Keyboard access to everything"). The two buttons and the clock are items of the bar for the keys; Down and Up walk the acts of an open card, Enter does the chosen one.

## The chosen form

**The places.** From the right: the clock, the hairline, the button of the notifications, the button of the control center, then the rest of the tray. A tray button is 28 by 24 pixels at the top and the height of a pill (`TRAY_Y`, `TRAY_HEIGHT`), with an icon of 16 pixels in its middle. The clock is a button too: its plate is the place of its text with 4 pixels on each side, so it never covers the hairline. The clock keeps its place of before.

**The look of a button.** Flat on the bar at rest, a quiet plate under the pointer, the chosen blue while its card is open: the look of the button of the windows. The bell has a square of 4 pixels in the coral of `failed` at its top right while the history holds a notification.

**The card.** The card of a menu of the bar (`menu_card_records`): a sharp shadow on the side away from the bar, a border of `edge`, the gradient from `card_top` to `card_bottom`, a line of light under its top edge. It opens away from the bar edge (`menu_top`), its right edge on the right edge of its button, kept 8 pixels inside the screen.

**The control center.** A grid of 2 by 2 tiles, then a hairline, then a row of 4 launch buttons.

- The tile of the bar edge says `Top` or `Bottom`; a press moves the bar.
- The tile of the magnifier says `On` or `Off`; a press turns it on or off. On, the tile is a plate of the chosen blue with white text.
- The tile of the appearance says `Dark` or `Light`: the appearance in force.
- The tile of the display says `VirtIO-GPU 1.2` when the compositor found the device, else `Processor`, and the size of the screen in pixels. It is blue while the frame goes to the VirtIO-GPU scanout.
- The launch buttons start `settings`, `monitor`, `browser` and `edit` with `Start`, as a line of the start menu does, and close the card.

An off tile is sunk in the card: `recess`, a border of `track`, a line of `shadow` under its top edge. A tile that a press changes has a border of the title blue under the pointer; the tiles of the appearance and of the display take no press, and have no look under the pointer.

**The notification center.** The last 6 notifications that the desktop showed, the newest first, each with its title, its body and its time of day. Its head has the caption `notifications` and the button `Clear all`. With no notification, the card is one line: `No notifications`. The history is a copy that the compositor keeps: a banner that expires stays in it.

**The calendar.** The month and the year, a row of the days of the week from Monday, a grid of 6 rows of 7 days on a recessed plate, and a foot with the time zone and the time since the boot. Today is a plate of the chosen blue with white text; a day of the month before or after is dim. With no date, the card says `No date` and its foot gives the time since the boot only. The grid comes from `modus:calendar`: `days_from_civil` gives the weekday of the first day, `days_in_month` the length.

**The export.** `compositor.tray_widget_open(widget)` opens a tray widget (1 the control center, 2 the notifications, 3 the calendar) or closes the one that is open (0), for a caller that acts for the principal. A word that names no member of `bar.Tray_Widget` is refused with `Bad_Value`. The export `pointer` names the open card in its field `menu`: `control_center`, `notifications` or `calendar`.

## Refused forms

- **A tile that switches the appearance.** The compositor reads the settings page and does not write it: the appearance is a setting of the principal, and the module `settings` is its one place. The tile says the appearance in force; the launch button of `settings` changes it.
- **A heading on the control center and on the calendar.** The button that opened the card says what it is; the month heads the calendar.
- **The tray buttons after the pills.** A pill can come and go; a tray button keeps one place, so the pointer and the machine test find it.
- **The notification center as the queue of the banners.** A banner leaves after 8 seconds; the history must keep it.
- **Rounded tiles and round buttons.** The look of the desktop is rectangles, bevels and lines of light (`docs/DESIGN.md`).

## Subtle points

- A press outside an open card closes it and reaches nothing under it, as a press outside a menu.
- A press on a tile keeps the card open, so the principal sees the new value; a press on a launch button closes it.
- After a move of the bar, the card opens from the other edge at the next frame: each place comes from the bar layout.
- The foot of the calendar changes each second: the compositor damages the card with the clock while it is open.

## State

Built: the three buttons, the three cards, the history of the notifications, the keys, the export `tray_widget_open`. Left: a vertical bar.
