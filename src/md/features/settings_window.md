# The window of settings

The window of the process `settings` is where a principal reads and changes the choices of the settings page ([`docs/FONTS.md`](../../../docs/FONTS.md), "7. The setting"). This file records the form of the window: what it shows, how it reflows, and what it does not offer. The page, the store and the exports are in the guide; the time zone is in [time_zone.md](time_zone.md); the languages in [interface_language.md](interface_language.md); the appearance in [appearance.md](appearance.md).

## Purpose

A principal who opens the window must see each choice, what it does, the value in force, and change it with one press or one key. The window is also the first window that a principal resizes to fit a small screen at a large scale, so it must reflow at each size.

## Constraints

- **One piece of information once.** A title, a line and a button do not repeat one fact. The value in force is the marked button, not a text beside it.
- **The window is the preview.** Each window draws again in the new font, appearance and scale at the next frame. A sample text of invented numbers shows nothing that the window does not show already, and a principal reads it as data.
- **The scale has a window bound.** `scale_factor.WINDOW_BOUND` (1.375) is the largest scale whose logical screen holds the tallest window of today; the budget of each window counts its pictures at that scale ([`docs/MODULE_CONTRACT.md`](../../../docs/MODULE_CONTRACT.md), "The budget that a module asks for"). The scales from 1.5 to 2 are members of the enum and are refused at the border (`scale_factor.scale_of_word`).
- **The time zone is a fixed offset.** The contract holds minutes from UTC, with no summer time ([time_zone.md](time_zone.md)). A name of a city is a help to find an offset, not a zone with rules.
- **The frame of the window is drawn at the scale of its surface.** The records are logical; a pointer event is logical. The frame takes its scale from the window (`interface.window_frame_start(memory, window)`, whose window argument is not optional).

## The chosen form

- **Four sections, as cards, in the order of use:** Display (scale, appearance, font, color stripes, grid fit), Pointer, Keyboard, Region and language (time zone, languages). Each setting is three parts: its name, one line that says what it does in plain words, and its values. A value is a button with a word that a reader understands: `Auto`, `RGB`, `US (QWERTY)`; the export keeps the names of the enum.
- **The value in force is the marked button**, in the chosen blue; the pointer over a button shades it; the focus has its outline. The interface package draws the three, so each button of the window has them.
- **The scale is a track of stops**, one stop for each member of `scale_factor.Scale`, each with its percentage, 125 % to 200 %, when the widest percentage fits in a stop; in a narrower card the stops are bare and the percentage in force stands beside the track. A press on a stop, or Left and Right with the focus on the track, sets the scale; the desktop draws again at once at the new scale, which is the live preview. The stops past the window bound are outlines with a dim percentage, take no press, and one line says why. The full range shows that the scale is a range, and which part of it waits for which work.
- **The time zone is a list of offsets**, each with places that use it as their standard time: `UTC+05:30  India, Sri Lanka`. The list holds the 38 offsets that the earth uses; the offset in force is the chosen line. A zone that the console set and that the list does not hold shows as its offset in the title of the list. One line says that the offset does not follow summer time.
- **The languages are an ordered list of names**: `1  French (Canada)`, each line with `Up` and `Remove`; under it, `Add` and the names of the common languages that the list does not hold. An empty list says once that the system shows English.
- **The layout reflows from the size of the window.** One column under 720 logical pixels of width, two columns from 720: Display at the left, the three other sections at the right. In a section, the value buttons follow the explanation and wrap to the next line when the width ends. When the content is taller than the window, a vertical scroll bar moves it, and the wheel too. The action bar spans the width of the window at its foot.
- **The window is resizable** from 400 × 320 to 1024 × 800 logical pixels. The least width holds the widest button of a value beside the margins of a card; the least height holds the title of a section, two lines and the action bar. The budget counts the window at its largest size, and the working memory holds a second surface of that size for a resize, as `clock` does ([window_resize.md](window_resize.md)).

## Refused forms

- **A sample card of the text of the system.** It showed invented numbers ("12 345 wakes in one second") as if they were measures, and repeated what each window shows.
- **A row of the two scales that the border takes.** It read as if the system had two scales. The track shows the range.
- **The scales up to 2 in this change.** They need every window to fit the logical screen of 960 × 540 or to be resizable, and the budget of each window counted at 2: about twice the pages of the pictures of each window. That is the roadmap entry "The scales from 1.5 to 2". Scales under 1.25 are refused too: on the reference screen the desktop never draws at 1 ([desktop_to_browser.md](desktop_to_browser.md), "The reference screen").
- **Named zones with rules of summer time.** They need the time zone database in the boot image and a rule engine in `date`; the contract holds an offset.
- **Buttons of steps for the zone** (`-1 h`, `+15 min`): they showed no value in force, and a principal counted the presses.
- **A frame with no window.** The window argument of `window_frame_start` was optional. A frame without it drew in the pixels of the surface while each press came in logical pixels: at 1.25 each press reached the element up and left of the one under the pointer, and a press on `+15 min` chose `dark`.

## Subtle points

- **The act names.** The marked button of each setting names the act `settings.set:<setting>`, so the palette goes to it. Seven settings need seven act names; a record of the window ring holds twelve hashes of 32 bits ([`docs/INTERFACE.md`](../../../docs/INTERFACE.md), "4.2 Act names").
- **The element names are the labels.** A machine test presses a value by its label (`Spleen`, `Light`, `137.5 %`), so two buttons of the window never have one label.
- **A press writes the page in the frame.** The frame that takes the press calls the change, which keeps the record and writes the page; the next frame, woken by the compositor, draws the new value marked. The frame of the press still shows the old mark for one frame.

## State

Built: the sections, the track of the scale, the list of the zones, the list of the languages, the reflow in one or two columns with a scroll bar, the resize, and a host test of the layout at the least, the first and the largest size. Left: the scales past the window bound (roadmap), named zones with summer time.
