# The action bar

## Purpose

A window that the keyboard drives tells the reader its keys. Each window wrote them as one dim line of text at its bottom: `up, down: module  Tab, Enter: link  Backspace: back`. The line was hard to scan, a key and its action were the same weight, a long list ran past the window or onto four lines, and the pointer could do nothing with it.

The action bar is one element of the interface package for that line. Each item is a key combination drawn as keycaps, then the name of its action. A press on an item runs the action, as its keys do. The items that do not fit go into a list behind a button `more`.

## Constraints

- **One path for an action.** A press on an item and its keys must run the same code. Two paths drift: a fix in one is missing in the other.
- **No text over another text, and no cut text** ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "5. Text"). Each width is measured in the font that draws it, before the place is chosen.
- **Both appearances.** Each color is a token of `graphics.colors`.
- **Rectangular forms** ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"). No rounded blob.
- **One fact once on a screen.** The bar does not say "keys", and an item does not repeat a button or a title of the window.
- **The keys stay the first path.** A window that the bar hides must still take each key. The bar is a reminder and a second path, never the only one.
- **A machine test presses an item by its name** ([test_pointer.md](../infrastructure/test_pointer.md)).
- **Two kinds of window.** Some programs give every event to the interface package (`window_events`). Others read the keys from the events themselves and give the package only the pointer (`manual`, the terminal). The bar must serve both.

## The chosen form

**An item** (`Action_Bar_Item`) is the faces of its keycaps, the name of its action, and a priority that the program gives. The faces are the only statement of the key: the bar derives the key that a press runs from them (`action_bar_key_of`). `{"Shift", "Tab"}` is Shift with Tab; `{"h"}` is the character `h`; `{"Page Up"}` is the key Page Up. A face that names no key gives an item that takes no press.

**A press gives the key back.** A press on an item gives the program the key of the item (`Action_Bar_Result.run`). A program with `window_events` puts it in the input of its next frame (`input_key_add`): the key then goes the way that a typed key goes, through the focus and the elements. A program that reads its keys runs it through its own procedure for a key. In both, the press and the key run one piece of code.

**One row, and a list for the rest.** The bar measures each item. When the items do not fit in one row, it keeps a button `more` at the right end of the row and takes items out of the row, the lowest priority first, until the rest fit beside it. Two items of one priority: the later one goes first. The items in the row keep the order that the program gave; the list keeps that order too. The button says how many items it holds: `3 more`.

**The list opens upward**, aligned to the right edge of the bar, inside the window. Its rows have the same form as the items: keycaps, then the name, with a line between two rows. While it is open:

- Up and Down choose a row. Up from no row chooses the row next to the bar, the last; Down chooses the first. A move stops at an end.
- Enter runs the chosen row and closes the list. Enter with no row closes it.
- Escape closes it.
- Another key closes it and goes to the program, as it would with the list closed.
- A press on a row runs it. A press outside the list closes it and does nothing else.

**Wrap, the other overflow** (`Action_Bar_Overflow.Wrap`). The items flow over two rows, in their order. The items that two rows still do not hold go into the list, by the same rule of priority. The bar of a wrap window is always two rows high, so the content above it does not move when the items change. The default is the list: one row takes less of the window. A window chooses wrap when it has the room for two rows and its keys must all show at once, because its reader learns them there.

**The look** ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "The action bar"):

- The bar is a band of 24 pixels (a line of a table), on `colors.card_bottom`, with a line of 1 pixel of `colors.track` at its top.
- A keycap is a rectangle 20 pixels high, at least 20 wide, with a border of 1 pixel in `colors.not_usable` and inside it the gradient of a card, from `colors.card_top` to `colors.card_bottom`. Its label is in the text color, 6 pixels from each side.
- A face for an arrow key draws a solid triangle of four rows (1, 3, 5 and 7 pixels), as the arrow button of the scroll bar does. The fonts have no arrow character ([data/text_encoding.md](../data/text_encoding.md)). `Page Up` is the word `Page` and the triangle.
- The keycaps of one combination have a dim `+` between them.
- The name of the action is 6 pixels after the last keycap, in the text color.
- Between two items is a divider: a line of 1 by 12 pixels in `colors.track`, in the middle of the band. An item has 8 pixels of room on each side.
- The pointer over an item fills its box with `colors.track`. A held press over it fills it with `colors.chosen` and draws its name in white, as an open button. The button `more` is in `colors.chosen` while its list is open.
- The button `more` is a keycap with three points of 2 by 2 pixels, then the count and the word.
- The list has a border of 1 pixel in `colors.not_usable` and the surface `colors.card_top`. The row under the pointer is on `colors.track`; the row that the keys chose is on `colors.chosen` with its name in white.

**The state of a bar** (`Action_Bar_State`) is memory of the program: the list is open or not, its chosen row, the keys of the items in the list, the places of the last frame, the part that holds a press, and the pointer of the frame. The bar keeps it because the keys reach the list before the bar draws: the keys of the list need the items of the last frame.

**The order in a frame.** `action_bar_input_take` comes first, after `window_frame_begin`. It takes the keys of an open list, and it takes the press and the pointer when the list is open or the pointer is over the bar: no element under the list sees them. `action_bar` comes last, so the list is drawn over the content. A program that reads its keys calls `action_bar_key` for each key first, and does not act on a press for which `action_bar_takes_pointer` says yes.

**The names.** The name of the action of an item is its element name; a row of the list too, while the list is open; the button has the name `more`. An item is in the row or in the list, never both, so one name has one rectangle.

## Refused forms

- **A table of actions with an index for each.** A press would give an index, and the program would map it to a procedure beside its map of keys. That is two paths, and the faces would be a third statement of the key.
- **An item with alternative keys.** `up, down: module` is two actions. A press on it could run neither. Each item is one action: `Up` module before, `Down` module after.
- **The items in the order of Tab.** Tab belongs to the window: `manual` moves its links with it, `settings` its buttons. The keys of each item are the keyboard path of the item.
- **A press that clears the focus.** `settings` has the item `Tab` next button: a press must move the focus from where it is. A window that needs it clears the focus itself (the debugger window, where the letters must act and not type in the field).
- **A press outside the open list that also acts.** The reader aims at the list; a press that misses it must not change the content under it.
- **The state in the interface state.** One window can have no bar, and the interface state is one record for each window that the package fixes. The bar is the one element that needs it, and its program owns it.
- **Glyphs for the keys.** `⌫`, `↑` and `⋯` are not in the fonts. A triangle and three points are rectangles, which the draw table has.
- **A bar that shrinks its items.** A cut name or a narrow keycap says nothing. An item is whole, or it is in the list.
- **Round keycaps.** A keycap of the design is a rectangle.
- **A lower edge of a darker color under a keycap**, as a key of a keyboard has. The design rules have one sign of depth, the gradient from lighter at the top to darker at the bottom; a keycap has it.
- **A name cut to its room.** A name is whole or absent ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "1. What is on the screen"). A row of a list narrower than its item shows its keycaps only.
- **A label "keys:" before the items.** The keycaps say it.

## Subtle points

- **An item is made by a call.** Odin takes no literal of a fixed array with fewer values than the array, so `action_bar_item(name, priority, faces..)` copies the faces into the fixed array of the item, and drops a face past the capacity. A slice of faces was refused: it pointed into the stack of a procedure that had returned. A freestanding program runs no call before its entry, so a program writes its items in a procedure that returns the array, and calls it where it draws the bar.

- **The key of a press is synthetic.** A face of one character gives the character with the code 0. A program that compares a key code with a letter does not see it: compare the character.
- **The list must fit above the bar.** The bar gives the list the room from its top to the top of the window (`Action_Bar_Options.top`). Rows that do not fit are not shown, and `Action_Bar_Result.list_rows_not_shown` counts them; a host test checks the count.
- **An element line for each change of a rectangle.** An item whose place changes at each frame writes a line at each frame. A bar has a fixed area. The terminal puts its bar at the right of a line whose text changes: its items stand from the right edge (`Action_Bar_Options.alignment = .Right`), so they do not move while the text at the left changes.
- **A press on an item of a window that types.** In the debugger window the letters type in the debug place field while it has the focus. A press on an item takes the focus from the field first, so `h` holds the thread.
- **The frame after a press.** A program that draws only after a change builds the frame that runs the key. `action_bar_wants_frame` says when a pointer event needs a frame: over the bar, the list open, a held press, or a bar lit in the last frame.

## State

Built: the element, its layout as a pure procedure, the list with its keys and its pointer, wrap, the host tests (the fit, the overflow at several widths, the order of priority, the place of the list, the keys of the list), and the bar of each window that listed its keys: `manual`, the terminal, `settings`, `notes`, the debugger window, `unlock`, `interface_elements`, `tally`, `rings`, `paint`. The machine scenario takes a picture of `interface_elements` with all its items, opens the list of the debugger window, and runs `detach` from the list.

Left: the band of keys of the palette, which the compositor draws with its own panel; a window whose surface can change its width, which no program of the system has.
