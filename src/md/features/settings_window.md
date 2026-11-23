# The window of settings

The window of the process `settings` is where a principal reads and changes the choices of the settings page ([`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting"). This file records the form of the window: what it shows, how it reflows, and what it does not offer. The page, the store and the exports are in the guide; the time zone is in [time_zone.md](time_zone.md); the languages in [interface_language.md](interface_language.md); the appearance in [appearance.md](appearance.md).

## Purpose

A principal who opens the window must see each choice, what it does, the value in force, and change it with one press or one key. The window is also the first window that a principal resizes to fit a small screen at a large scale, so it must reflow at each size.

## Constraints

- **One piece of information once.** A title, a line and a button do not repeat one fact. The value in force is the marked button, not a text beside it.
- **The window is the preview.** Each window draws again in the new font, appearance and scale at the next frame. A sample text of invented numbers shows nothing that the window does not show already, and a principal reads it as data.
- **The scale is the whole range.** Each member of `scale_factor.Scale`, from 1 to 2, is a value that a principal sets ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen"). The window of settings fits the least work area at 2, so the principal can always set the scale back. A window whose budget cannot pay a scale declines it and shows its frame only ([window_resize.md](window_resize.md), "The rescale").
- **The time zone is a fixed offset.** The contract holds minutes from UTC, with no summer time ([time_zone.md](time_zone.md)). A name of a city is a help to find an offset, not a zone with rules.
- **The frame of the window is drawn at the scale of its surface.** The records are logical; a pointer event is logical. The frame takes its scale from the window (`interface.window_frame_start(memory, window)`, whose window argument is not optional).

## The chosen form

- **Four sections, as cards, in the order of use:** Display (scale, appearance, font, color stripes, grid fit), Pointer, Keyboard, Region and language (time zone, languages). Each setting is three parts: its name, one line that says what it does in plain words, and its values. A value is a button with a word that a reader understands: `Auto`, `RGB`, `US (QWERTY)`; the export keeps the names of the enum.
- **The value in force is the marked button**, in the chosen blue; the pointer over a button shades it; the focus has its outline. The interface package draws the three, so each button of the window has them.
- **The scale is a track of stops**, one stop for each member of `scale_factor.Scale`, 100 % to 200 %, each selectable, each with its percent rounded half up (100, 113, 125 to 200), which fits a stop at each width of the window that a stop holds three digits in; only a narrower card has bare stops, with the percentage in force beside the track. The element of a stop keeps the whole value as its name (`137.5 %`). The stop in force is filled, with its label in the colour of a chosen value; the focus is the outline alone, on a stop that keeps its fill: a stop with the focus never looks chosen. The first form filled the stop with the focus in blue and wrote no label in a stop narrower than `187.5 %`, so at 125 % and at 200 % the focus and the choice were two blue boxes with no value. A press on a stop, or Enter with the focus on it, sets the scale; the desktop draws again at once at the new scale, which is the live preview. When windows declined the scale in force, one line under the track says how many show their frame only: the count comes from the compositor in `Settings_Changed` (`display.windows_that_declined_the_scale`).
- **The time zone is a list of offsets**, each with places that use it as their standard time: `UTC+05:30  India, Sri Lanka`. The list holds the 38 offsets that the earth uses; the offset in force is the chosen line. A zone that the console set and that the list does not hold shows as its offset in the title of the list. One line says that the offset does not follow summer time.
- **The languages are an ordered list of names**: `1  French (Canada)`, each line with `Up` and `Remove`; under it, `Add` and the names of the common languages that the list does not hold. An empty list says once that the system shows English.
- **The layout reflows from the size of the window.** One column under 720 logical pixels of width, two columns from 720: Display at the left, the three other sections at the right. In a section, the value buttons follow the explanation and wrap to the next line when the width ends. When the content is taller than the window, a vertical scroll bar moves it, and the wheel too. The action bar spans the width of the window at its foot.
- **The window is resizable** from 400 × 320 to 1024 × 800 logical pixels. The least width holds the widest button of a value beside the margins of a card; the least height holds the title of a section, two lines and the action bar. The budget counts the window at its largest size, and the working memory holds a second surface of that size for a resize, as `clock` does ([window_resize.md](window_resize.md)).

## Refused forms

- **A sample card of the text of the system.** It showed invented numbers ("12 345 wakes in one second") as if they were measures, and repeated what each window shows.
- **A row of the two scales that the border takes.** It read as if the system had two scales. The track shows the range.
- **A bound of the range by the tallest window.** It made 1.375 the largest scale, and a principal saw a range of two values. The budget at the largest scale and the least work area replace it.
- **Named zones with rules of summer time.** They need the time zone database in the boot image and a rule engine in `date`; the contract holds an offset.
- **Buttons of steps for the zone** (`-1 h`, `+15 min`): they showed no value in force, and a principal counted the presses.
- **A frame with no window.** The window argument of `window_frame_start` was optional. A frame without it drew in the pixels of the surface while each press came in logical pixels: at 1.25 each press reached the element up and left of the one under the pointer, and a press on `+15 min` chose `dark`.

## Subtle points

- **One writer, the store first.** A change is written to the private store of `settings` first, then to the page (`change_decision`, a pure procedure with a host test). A change that the store refuses, or a process that got no store (the fact `No_Store` at its start), leaves the page as it was: the call fails with `Refused` (-4) and the fact `Change_Not_Kept`, and a press of the window shows the value before. The first form wrote the page all the same, so the desktop showed a value that the next start of the machine lost, and a principal could not tell. The boot pass is no change: it writes the page from the kept record, or the defaults, which the page holds already when the store refuses.

- **One process settings at a time.** The process `settings` is the one writer of the settings page, so two never run. The root service decides each start of it in `start()`, whoever asks (`settings.start_answer`, a pure procedure with a contract test): a start of the window while a window runs raises that window (`Control.Settings_Raise`, the focus where it was), the tile Appearance raises it with the focus on the appearance, a start of the window from the desktop while a pass runs waits until the pass stops, the start of another caller then is refused (a connection asks again; a start kept for it would open a window that no principal asked for), and a pass while another process `settings` runs is refused. A second window was refused: two writers of the page each keep a record in the store, and the last write wins over a change that the principal saw in the other window.
- **The holder of the role, not the name.** Each start of a pass, of the window and of a start that waited, starts the holder of Settings in force (`role_holder_name(.Settings)`), and `settings_running`, the decision in `start()` and the start of the desktop find it by its role: a plan of principal 0 can give the role to another module ([declarations.md](declarations.md), "The plan of principal 0 at the start"). The context value `VALUE_PASS` goes to that holder only: a service that its start starts first, the storage service, gets no value.

- **The act names.** The marked button of each setting names the act `settings.set:<setting>`, so the palette goes to it. Seven settings need seven act names; a record of the window ring holds twelve hashes of 32 bits ([`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "4.2 Act names").
- **The element names are the labels.** A machine test presses a value by its label (`Spleen`, `Light`, `137.5 %`), so two buttons of the window never have one label.
- **A press writes the page in the frame.** The frame that takes the press calls the change, which keeps the record and writes the page; the next frame, woken by the compositor, draws the new value marked. The frame of the press still shows the old mark for one frame.

## State

Built: the sections, the track of the scale, the list of the zones, the list of the languages, the reflow in one or two columns with a scroll bar, the resize, and a host test of the layout at the least, the first and the largest size. Left: named zones with summer time.
