# The scroll bar

## Purpose

A view that shows a part of a longer content has a scroll bar: it says where the view is, and the pointer moves the view with it. The system and the site show the same scroll bar, drawn from one description.

The form before was a flat rectangle on a track, drawn again in each process, with no pointer. A reader did not see it as a control, and it was not one.

## Constraints

- **One standard.** The form is the scroll bar of the desktop shell that the design of the system comes from (the project `shojiwm-desktop`: `crates/shell/src/ui/scroll.rs`, and the same colors in `gtk-theme/_scroll-bar-colours.scss`). Its geometry, its colors and its states are taken as they are. The site had a form of its own before.
- **One description for two drawers.** The system draws rectangles and gradients into a draw table. The site writes a style sheet. Both must show the same numbers, and a change of one number must change both.
- **No blend.** A draw of the system is opaque ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"). The standard has one translucent line.
- **No state in a process.** A process must get the pointer on its scroll bar with one call, and keep nothing between two frames.
- **No wait in a test.** A held arrow button repeats in time. A test of it must not wait.

## The chosen form

**One table.** `src/library/modus/graphics/scroll_bar.odin` holds the sizes, the places of the stops of each gradient and the colors of the dark and of the light form. `src/library/modus/interface/scroll_bar.odin` draws from it. `tools/modustool/site/site_style.odin` writes the variables of the style sheet from it. The rules of the style sheet hold no size and no color: a host test refuses `px`, `#` and `gradient(` in them.

**The parts**, along the bar: an arrow button, the track, an arrow button. The thumb lies on the track.

| Number | Value | From the standard |
|---|---|---|
| Thickness of the bar, side of an arrow button | 17 pixels | `THICKNESS` |
| Border of the track, of a button, of the thumb | 1 pixel | `border(1.0)` |
| Least thumb | 8 % of the track | `MINIMUM_THUMB` |
| Grip | 4 lines of 7 by 1 pixels, 1 pixel apart, on a thumb longer than 20 pixels | the grip of `bar` |
| Stops of the track | 0, 50, 100 % | `horizontal_gradient` of the track |
| Stops of the thumb | 0, 45, 55, 100 % | `horizontal_gradient` of the thumb |
| A held arrow button | repeats after 400 ms, then each 60 ms | `REPEAT_AFTER`, `REPEAT_EVERY` |

**The gradients go across the bar**: from the left to the right of a vertical bar, from the top to the bottom of a horizontal one. The draw record has both directions, with two colors each. A gradient of three or four stops is two or three records, each from the place of one stop to the place of the next; two neighbours share the pixel of their common stop.

**The states** are those of the standard. At rest: the track, the thumb with its quiet border and its grip, and two triangles with no button under them. Lit, when the pointer is over the bar or the thumb is held: each arrow button has a border and a fill, and the thumb has the blue border, the blue fill and the light grip. Hot: the arrow button under the pointer is blue. Pressed: a darker blue for a held button and for a held thumb.

**The inner line of the thumb** is white at 12 % in the standard (40 % in the light form). The system draws the color that this blend gives over each stop of the fill, as an opaque line. The site writes the translucent white: a browser blends it.

**The input** is in the element. A press on an arrow button moves the view by one line. A press on the track moves it by one page. A press on the thumb holds it, and the thumb follows the pointer until the button goes up, also outside the bar. The interface state keeps the held part: one button is down at a time, so one scroll bar at most is held, and a process keeps nothing.

**The repeat of a held button** reads the clock of the frame. A frame carries the time of the system in milliseconds, and the element compares it with the time of the next step. A test gives each frame its time as a number.

**The wheel moves the view under the pointer.** The path of a notch:

- The input service asks the PS/2 mouse for the IntelliMouse protocol: the sample rates 200, 100 and 80, then its identity. A mouse that answers 3 sends packets of 4 bytes, and the fourth byte is the notches, signed; a mouse that answers 4 sends packets of 4 bytes with the notches in the low 4 bits. The log says `input: ok, the mouse has a wheel`. The virtual mouse of QEMU answers 3.
- The compositor gives notches to a window only while the pointer is over its surface: not while a held button sends it the pointer from outside its surface.
- A completion list of a terminal with no scroll bar shows each of its rows: a notch over it moves nothing, and not the lines under it. While the process of the list has not answered a request for a first row, the next notch starts from the row that was asked, so a fast turn loses no row.
- The notches ride in the `Pointer` record of the input ring and in the `Pointer` event of a window, as a fourth value. A notch toward the principal is `display.WHEEL_TOWARD_THE_END`: it moves a view toward the end of its content, as the key Down does.
- The compositor sends them where it sends the pointer: to the palette while it is open, else to the process of the window in front, when the pointer is over its surface.
- The element takes them. A caller gives `scroll_bar` the area of its view (the lines, the rows). When the pointer is over that view or over the bar, each notch moves the view by `SCROLL_WHEEL_LINES_PER_NOTCH` (3) lines of the bar, and the bar takes the notches of the frame: a second view of the frame under the pointer does not move. A view inside another view (the completion list over the lines of a terminal) calls its bar first.
- A view of fewer lines than one notch moves by its height: a notch never passes a line that the view did not show.

Each owner of a view writes one line when the wheel moved it: `terminal: the wheel moves the view of console: ...`, `terminal: the wheel moves the completion list of ...`, `compositor: the wheel moves the rows of the palette: the rows from 4`. A list with a choice moves its choice with its view, and its process writes the new choice.

**The press is where the button went down.** One frame can hold a press and the moves after it. The input keeps the place of the press beside the place of the pointer: a press on the thumb followed by a fast move is a drag, not a press on the track where the pointer ended.

## Where the form leaves the standard, and why

- **An arrow button moves the view by one line**, not by a tenth of the content. A line is the unit that a reader of a text follows.
- **The thumb has a least length of 8 pixels**, beside the 8 % of the standard. On a short track 8 % is less than a border, a line and a place for the pointer.
- **A bar shorter than two buttons and a least thumb has no arrow button.** The completion list of the terminal can be one row high. The track takes the whole bar.
- **The triangle is rows of 1, 3, 5 and 7 pixels.** The standard draws a character of a font at 7 pixels. The system draws rectangles, as it draws its icons.
- **The site cannot light the whole bar.** A style sheet reaches a part of a scroll bar only under the pointer. On the site the thumb is hot when the pointer is over the thumb, and a button when the pointer is over that button.
- **The site has a least thumb of 21 pixels.** A style sheet cannot remove the grip of a short thumb, so each thumb is long enough for its grip.

## What it changes in the design rules

The scroll bar is a decoration that the design rules did not have, and it has three exceptions to them. Each is stated in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "The scroll bar".

- Its gradients go across, where the sign of depth of a surface goes from the top down.
- Its thickness is 17 pixels, which is not a multiple of a spacing token. It is odd so that the grip and the point of a triangle are on its middle line. It is a fixed size of the element: a caller puts a `gap` before it, and nothing rounds the bar and the gap together ([spacing_tokens.md](spacing_tokens.md)).
- Its colors are its own: gray-blue tones that no concept has.

## Refused forms

- **A flat bar.** A rectangle of one color on a track says where the view is. It does not say that the pointer can move it, and the pointer could not.
- **A drawing in each process.** The terminal, the lists and the palette each drew a bar of their own, of 2 or 8 pixels. A change of the form was three changes, and none had the pointer.
- **An overlay bar that hides.** A bar that shows only while the view moves takes no room, and a reader cannot find it. The bar is always there, as the standard states for its desktop.
- **Round corners.** The standard has a radius of 3 pixels for the thumb and 2 for a button in one of its themes, and 0 in the theme of this design (`$scroll_radius` in `gtk-theme/_kernel.scss`). The system draws square corners: rectangular forms are the preference of the design, and the draw table has no round rectangle.
- **A blend for the inner line.** One translucent record kind for one line of one element. The opaque color of the blend is the same pixels.
- **A state of the bar in each process.** A process would keep the held part and the time of the next step for each of its bars. The interface state holds them once.
- **A second table for the site.** The site had its own colors, mixed from the colors of the page. They were near the standard and not the standard.
- **The wheel to the window under the pointer, in front or not.** Many desktops do this. Here the input goes only to the process that has the focus ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "20. No ambient access: the other holes to close"): a window behind gets no notch. A principal brings it to the front first, with one press.
- **A record of its own for the wheel.** A notch is a fact of the pointer at a place, as a button is. A second kind of record would carry the same place twice and need a second order with the moves.
- **A count of pixels for each notch.** The units of a view are its lines and its rows; a count of pixels moves a terminal by part of a line, which it cannot show.
- **A notch that waits for a later frame.** A process that draws only after a change drops the notches of an event over no view: else a notch over the edge of the window moves the view at the next frame, under another place of the pointer.
- **A grid thickness of 16 pixels.** The grip of 7 pixels and the point of a triangle then have no middle column, and the form is no longer the standard.

## Subtle points

- **A window gets one pointer event when the pointer leaves it.** The compositor sent the pointer only while it was over the surface. A bar at the edge of a window then stayed lit when the pointer left by that edge. The compositor now sends one event more, outside the surface, and one when another window takes the front.
- **A process that draws only after a change** asks the element if the pointer needs a frame (`scroll_bar_wants_frame`), and wakes for a held button at the time that the interface state holds (`window_scroll_bar_wake`). A frame for each move of the pointer over the text would make a view of the terminal for nothing.
- **A held scroll bar that a frame does not draw** takes no step: the time of the next step is cleared, so a process that wakes for it sleeps again.
- **A thumb that the pointer did not move keeps its unit.** The place of a thumb is coarser than the units of a long content: a press on the thumb with no move must not shift the view.
- **The scroll bar takes no key and is not in the order of Tab.** The keys of a view belong to the element that owns the view.
- **The list with a choice has a view that follows its choice.** Its scroll bar moves the choice to the last line of the view that the pointer asks for.
- **A list whose choice another party owns.** The completion list of a terminal belongs to the process that writes it: the terminal has only the rows that it shows. The scroll bar of that list is the element, with the pointer, and its result goes to the process as one input record with the first row that the pointer asks for (`terminal.Input.List_First`). The process moves its view there and its choice into the view, and sends the rows. The terminal sends a first row one time: while the process has not answered, the element gives the same row at each frame.
- **The palette** is drawn by the compositor, which has no window of its own: its panel is built only at a change. The owner of the panel gives the frame the pointer and the clock, builds a frame for the pointer only when the element asks (`scroll_bar_wants_frame`), and wakes at the time of the next step of a held button. The view moves the choice, as in the list with a choice ([palette.md](palette.md)).
- **A notch has an order, and notches take one place.** The compositor joins the moves of the pointer to a window whose ring is full into one move. A record with notches is not a move: it waits in order, as a change of a button, so no notch is lost (`key_path.window_queue_put_pointer`). A hand turns the wheel tens of times in one second, and the queue of a window has places for keys and changes of a button: so a record with notches joins the newest record that waits when that one has notches and the same buttons. The notches add, the place is the newer one, and the order does not change, because the joined record has not reached the window. In the backlog of the input service, the notches of two joined packets add too. Each sum is cut to `key_path.WHEEL_NOTCHES_LIMIT`.
- **A lost byte must not give false notches.** The packets of a PS/2 mouse find their start by one bit of the first byte, and a byte of a move can have that bit. The decoder (`key_path.mouse_decoder_byte`, a procedure with no kernel entry) takes a fourth byte only in the range of its protocol: -8 to 7 for the identity 3. Any other byte says that the packet began at a wrong byte, and the decoder starts again one byte later. A packet with an overflow bit is dropped. Without these checks, a byte of a move read as notches moves a view by hundreds of lines.
- **A mouse left in the Explorer protocol.** Some firmware leaves the mouse in the IntelliMouse Explorer protocol, and the default settings do not always leave it. Such a mouse answers the identity 4 and sends 4 bytes, with the notches in the low 4 bits. The decoder reads it. A reset of the mouse was refused: it waits for the self test of the mouse, and the identity already says how to read the packets.
- **An answer of the mouse is a byte of the mouse.** At the start, the service reads the answers of the mouse by the bit of the status port that says that a byte comes from the mouse. A key pressed during the start is dropped and counted on the log: else it is read as the identity of the mouse, and a mouse with a wheel is read as one without.
- **The notches of one frame go to the last place of the pointer.** A window layer adds the notches of the events that came before a frame, and the scroll bar reads the pointer at the end of them. A notch over one view followed by a move to another view in the same frame moves the second view; a notch followed by a move off every view moves nothing. A frame takes a few milliseconds, and a hand does not turn and move faster. A frame for each change of place with notches would fix it, at the cost of more frames for no visible use.
- **The pointer shape over a scroll bar is the arrow.** A scroll bar is a control, not text. A process that asks for another shape over its surface, as the terminal asks for the text shape, asks for the arrow while the pointer is over a scroll bar or holds one, and for its shape again after. The element cannot ask: it has no window, and the shape of a surface is one value that its process owns. The compositor shows the arrow over the scroll bar of the palette by its own rule.
- **At rest the standard is quiet.** The border of the thumb has 2.1 to 1 on the track (2.5 in the light form), and the grip 1.7 to 1 on the thumb (2.7). The parts that the pointer lights have 3 to 1 or more, and a host test holds those.

## State

Built: the table, the element in both directions, the terminal (the lines and the completion list, with the pointer), the process `manual` (the text, with the pointer), the list with a choice (with the pointer), the list of rows (shown only, or with the pointer when its caller names the scroll bar), the palette (the entries and the candidates, with the pointer), the arrow as the pointer shape over the scroll bars of a terminal, the style sheet of the site in both forms, the host tests, and a case of the machine scenario on the scroll bar of the console. The wheel: the IntelliMouse protocol in the input service, the notches in the pointer records, the view of each bar (the lines and the completion list of a terminal, the text of `manual`, the cards of `hall_of_fame`, the list with a choice, the list of rows, the palette), and the cases of the machine scenario on the console, a list and the palette.

Left: the list of the modules of `manual`, which has no scroll bar; a horizontal wheel, which the input service does not ask for.
