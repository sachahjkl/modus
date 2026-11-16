# The appearance

The desktop has two appearances: dark and light. The principal chooses one, or `auto`, which takes the light appearance during the day and the dark one at night. This file records where the colors of the two appearances live, who decides the appearance in force, when it changes, and what a change redraws. The rules of the colors are in [`docs/DESIGN.md`](../../../docs/DESIGN.md), "4. Color".

## The chosen form

- **One table of color tokens.** A color token is a named color of the design rules: a surface, a concept, a part of the desktop. `graphics.Color_Tokens` holds each token, and `graphics.DARK_COLOR_TOKENS` and `graphics.LIGHT_COLOR_TOKENS` give its value in each appearance. The table is the one place of the values: the desktop, the programs and the light and dark forms of the site read it.
- **A drawer reads a token through the appearance in force.** `graphics.colors` is the record of the tokens of the appearance in force in this program: `graphics.colors.text`, `graphics.colors.card_top`. `graphics.appearance_use` copies the record of one appearance into it. No program holds a value of a token as its own constant.
- **The dark values stay as constants for what is always dark.** `graphics.DARK_KERNEL` and the other `DARK_` constants are the values of the dark appearance. The mark and the tables of the colors of code and of values read them as the accents of the concepts, because those tables are constant data. A program that draws a window never names a `DARK_` constant for what it draws: its window would stay dark in the light appearance. The one use is the pixels of a picture that the program computes, which keep their colors in both appearances.
- **The colors of code and of values follow.** `code_class_color` and `value_kind_color` take the appearance. In the light appearance a class or a kind takes the shade that the light form of the site takes. The scroll bar takes `scroll_bar_colors_of(appearance)`: the light form of the scroll bar is the one of the site.
- **The light appearance is the light form of the site.** The background is the light background of the mark, the cards are white, the text is the dark background of the rules. A concept takes its accent at the shade that keeps 4.5 to 1 on the light surfaces. The blue of the title bar, the chosen blue, the red of the close button and white on them do not change: white keeps its contrast on them in both appearances.

| Token | Dark | Light | Use |
|---|---|---|---|
| `background` | `0x0B1018` | `0xF4F6F8` | Under all cards |
| `point` | `0x18212D` | `0xDDE2E8` | The grid of points on the background |
| `card_top` | `0x17212E` | `0xFFFFFF` | The top of a card |
| `card_bottom` | `0x111822` | `0xF9FAFB` | The bottom of a card |
| `track` | `0x1C2633` | `0xD6DBE0` | The empty part of a bar, a band, a button |
| `firmware` | `0x8E7CC3` | `0x7566A1` | The accent at 83 % in the light appearance |
| `boot_program` | `0xE0A040` | `0x906729` | At 65 % |
| `kernel` | `0x4A9CF0` | `0x3571AF` | At 73 % |
| `program` | `0x58D878` | `0x327C45` | At 58 % |
| `memory` | `0x38C0B0` | `0x247C71` | At 65 % |
| `machine` | `0xD070B0` | `0xA15688` | At 78 % |
| `no_entry` | `0xC8C058` | `0x6D6930` | At 55 % |
| `resource` | `0x9AA8C8` | `0x5C6478` | At 60 % |
| `failed` | `0xF06060` | `0xBA4A4A` | At 78 % |
| `not_usable` | `0x4A5563` | `0xA9B2BD` | Not a text: about 2.1 to 1 on a card in both |
| `text` | `0xDCE4EC` | `0x0B1018` | The text |
| `dim` | `0x7C8A99` | `0x4A525B` | The dim text: the dim color at 60 % in the light appearance |
| `text_strong` | `0xFFFFFF` | `0x000000` | The text that an input types, and the outline of the focus |
| `warning` | `0xF0C050` | `0x886D2D` | A state that asks for attention and is not a failure: a warning of the log, a full ring. At 57 % |
| `link` | `0x6CB4F0` | `0x3B6283` | A link of a page of `manual`. At 55 %: it keeps 4.5 to 1 on the track too, the band of a link with the focus |
| `series` | `0x4696FF`, `0xFF963C`, `0x5AE66E`, `0xDC64FA`, `0xE06890`, `0x60D8D0`, `0xD8D860`, `0x9CC040` | `0x3471C1`, `0xA35F26`, `0x32803D`, `0xA44ABB`, `0xB05171`, `0x367A76`, `0x747433`, `0x617828`: at 76, 64, 56, 75, 79, 57, 54, 63 % | Eight colors that tell apart the members of one series |
| `title` | `0x3F7CC4` | `0x3F7CC4` | The title bar of the window in front, at its left |
| `title_end` | `0x162C45` | `0x162C45` | At its right |
| `chosen` | `0x3C76BB` | `0x3C76BB` | A chosen row |
| `title_quiet` | `0x2A3442` | `0xE4E8ED` | The title bar of another window, at its left |
| `title_quiet_end` | `0x161D27` | `0xD3D9E0` | At its right |
| `stop_program` | `0xB82232` | `0xB82232` | The close button |
| `stop_program_pointer_over` | `0xE0343F` | `0xE0343F` | The close button under the pointer |
| `stop_program_quiet` | `0x4E2229` | `0xF2D5D9` | The close button of another window |
| `stop_program_quiet_mark` | `0xC09098` | `0x8E3A47` | Its `x` |

White (`COLOR_WHITE`) and black (`COLOR_BLACK`) are not tokens: white is a text on a fill of the blue or of the red in both appearances, and the pointer is black and white.

## The contrast rules hold in both appearances

The host tests compute each pair that a rule of `docs/DESIGN.md` names, in each appearance (`src/library/support/graphics/appearance_test.odin`, `palette_colors_test.odin`, `value_colors_test.odin`):

- the text and the dim color on the background and on both colors of a card, and the text on the track, at 4.5 to 1;
- each concept that is drawn as a text (the firmware, the boot program, the kernel, a program, memory, the machine, a module with no entry, a resource, a failure, a warning, a link) on the background and on both colors of a card, at 4.5 to 1;
- a link on the track, at 4.5 to 1;
- each series color on the background and on both colors of a card, at 4.5 to 1, and on the track as a graphic, at 3 to 1;
- white on the chosen blue and on the red of the close button, at 4.5 to 1;
- the strong text on the track, at 4.5 to 1; the dim text on the track as a large text, at 3 to 1;
- each class of code on the track and on both colors of a card, at 4.5 to 1;
- each value kind on the background and on both colors of a card, at 4.5 to 1;
- each color of an icon of the palette on both colors of a card, at 3 to 1;
- the `x` of a quiet close button on its quiet red, at 3 to 1.

A concept is not a text on the track: the track holds the label of a button in the text color, and the typed text in the strong text color.

## The setting and the appearance in force

- **The setting `appearance`**: `auto`, the default, `dark` or `light`. The principal changes it as each other setting: the program `settings`, `settings.set("appearance", "light")` in the console, or the palette.
- **The appearance in force** is `dark` or `light`: the appearance that each program draws now. It is one word of the settings page, `appearance_in_force`, beside the values. With the setting `dark` or `light` it is that value. With `auto` it follows the rule of the day.
- **The rule of the day.** The light appearance from 07:00 to 19:00 of the local time, the dark one from 19:00 to 07:00. At 07:00:00 the light appearance holds; at 19:00:00 the dark one. A system with no date is dark. The rule is one pure procedure, `appearance.in_force_of` (`src/library/support/appearance`): the program `settings`, the root service and the modus tool call it, and a host test checks it at each edge.
- **The local time** is the date of the date page and its time zone (`zone_offset_seconds`). The system has no setting of the time zone yet: the zone is 0, so the hours are the hours of UTC. The rule needs no change when the time zone is a setting: it reads the zone of the page.

## Who writes the appearance in force, and when

- **The program `settings` at each change of a setting, and at its boot pass.** It computes the appearance in force with the rule and writes it in the same change of the page as the values. So one change of the setting is one change of the page, and each window draws once.
- **The root service at each edge of the day.** The program `settings` runs only while its window is open, and once at the boot. The root service runs always, and holds the settings page and the date page: it created both. Its loop has one more deadline, the time of the next edge of the rule (07:00 or 19:00 of the local time), and waits on the change count of the date page: a date that comes after the boot pass of `settings` changes the rule. At each turn it computes the rule; when the page holds another appearance, it writes the word `appearance_in_force` alone, with one atomic store, and wakes the waiters of the change count. The setting `dark` or `light`, and a system with no date, give no deadline: no edge changes them.
- **Two writers, two kinds of write.** The program `settings` writes the values and the appearance in force inside one change, with the change count odd. The root service writes one word outside the change count. A reader copies the word inside its loop of reads (`settings.read`), so it sees the old or the new appearance, never a mix. The program `settings` can write between the read of the root service and its store. So after its store the root service reads the change count again; when it moved, it reads the page again and writes the rule of the new values. Both writers compute one rule, so the page holds the right appearance when the root service ends its turn.
- **The root service does not wait on the change count of the settings page.** Its wait list holds at most 64 words, and the rings of the programs that it serves take most of them: a list that is full ends each wait at once. The check after the store needs no wait.
- **No polling.** The root service wakes twice a day for the rule, and the compositor does not wake for it: it already waits on the change count.

## What a change redraws

- **Each window once.** The compositor reads the page after each wake. When the values or the appearance in force differ from what it told the windows last, it sends `Settings_Changed` to each window, draws its whole screen again, and writes one line on the log. `display.next_event` gives the new appearance to the program before the event, as it gives the new font.
- **Each frame reads the appearance.** `interface.window_frame_begin` reads the appearance in force from the page. When it differs from the appearance of the last frame, the next frame of each picture is a whole frame. So a window that the interface package draws never shows two appearances, also when it draws a frame before the event.
- **One line at the first frame of a new appearance.** A window of the interface package writes `interface: <title>: a frame in the light appearance` when it presents its first frame in another appearance than its frame before. A machine test waits for that line before it takes a picture of the window: the picture then holds the new colors. The first frame of a window writes nothing, so the line is one for each window at each change.
- **A window that draws its canvas whole.** `log` draws again at the event `Settings_Changed`, also with no new record. `pages` draws its whole canvas at each read of its reports, each 500 ms.
- **The compositor** draws the background again with its grid of points, the bar, the title bars and the frames of the windows, the menus and the palette, in the tokens of the new appearance. The mark of the bar is drawn again over the new color of the bar, in the colors of the light background in the light appearance.
- **The terminal, the console and the results of the console** draw their cells in the tokens: the text, the dim color, the colors of code, the colors of values, the completion list.

## What does not change

- **The pictures.** A Picture record shows pixels that a program holds: a portrait of the hall of fame, the stage of the program `heron`, the pictures of `paint`. The mark of the bar is the one picture that follows: the compositor draws it again in the colors of the light background of the mark (its darker neck), as the bar of the light page of the site shows it.
- **The pointer.** It is black and white, and its themes are pictures: [../../../docs/POINTERS.md](../../../docs/POINTERS.md).
- **The boot display.** The boot program has no settings page: it draws before the root service exists. The root service draws the boot display again before the boot pass of `settings` reads the store. Both are dark. The program `boot` shows the same display in a window, dark too: the display is the model of the rules, and its colors are its facts.
- **The stage of `heron`.** It is a picture of the program: the mark in its dark variant, on the dark background of the mark, drawn in pixels that the program keeps between frames. A light stage is a second set of pixels of the light variant, drawn again at each change: the stage is the model of the dark mark, and it stays dark. The band under it follows the tokens.
- **A picture that a program computes.** The pictures of `processors` and `workers` are in the series color of each thread in the dark appearance (`graphics.DARK_SERIES`). The legend of a thread takes its series color of the appearance in force: the same hue at another shade.

## The colors of the programs

Each window takes each of its colors from the tokens: no program holds a color value of its own. Where a program drew a color of its own, the color became the token of its meaning:

- **An expected answer and a check that did not pass.** The expected answer is `program`, a refusal that the program expects too: the words of the answer say that it is a refusal (`budget`, `rights`, `origin`, `frames`, `imports`, `limits`). Another answer is `failed`, as the token says: a check that did not pass. A lost addition of `workers` is `failed`.
- **The concepts of a measure.** The records that a program moves are `program`, the kernel entries `kernel` (`clock`, `crowd`, `disk`, `flow`); the time page of `clock` is `memory`. The pages of `budget` and of `monitor` are `memory`; the share of the processor of a program is `program`; the load of a processor is `machine`; the waits of a lock are waits in the kernel, `kernel` (`processors`, `workers`). The run of `crowd` with one lock is the comparison: `dim`.
- **Values.** A value is in the text color, or in the color of its value kind: the count of `tally` and of `notes` is memory, a generation of `notes` is a version (the color of the boot program). The amounts of `tally` are values in the text color: the sign says whether an amount adds. The mark of a limit of `limits` says the number of the limit: the text color.
- **States.** A warning of the log and a full ring of `rings` are `warning`. A stopped node of `rings` is there and cannot be used: its border is `not_usable`, and its word, which is a text, is `dim`. The word "stopped" of `threads` is `text`: more weight than the dim count of frames of a thread that runs. A guard page of `pages` is a place where an access fails: `failed`.
- **The surfaces.** A band of a row of the log, a chip of a channel and a node of `rings` are `card_top`, as a band of a table and a card. A line of a ring is `dim`; the empty part of the work of a node is `track`; the line under the counts of `tally` is `track`.
- **`manual`.** A module has one color in the list, in the overview and in the title of its page: `program` for a program that serves calls or that runs, `no_entry` for a library, `failed` for a module that breaks a rule. A heading names the part under it: `dim`, as a name and the title of a column. An export is a procedure, `kernel`; a record is a type, `firmware`; an import is a module, `program`; a replacement is a fact of the machine, `machine`. Code is in the font of the cells and in the text color. A link is `link`. The chosen module of the list is a chosen row: `chosen`, its texts in white. The link with the focus is on a band of the track, with the line of the focus in `text_strong`.
- **Members of a series.** The threads of `limits`, `processors` and `workers`, the programs of the log, the records of `rings` and the three protections of a run of `pages` (execute, write, read) take the series color of their number. A record of `rings` carries its series number, not a color, so it keeps its identity when the appearance changes; `rings` takes the number modulo the count of the series, because a node, another program, writes it.

Three tokens came with this work, each because no token had the meaning: `warning` (the log had the color of the boot program for a warning, a second meaning of one color), `link` (the color of a link is a rule of [`docs/DESIGN.md`](../../../docs/DESIGN.md), "5. Text", and had no token), and `series` (the threads, the programs of the log and the records of a ring each had their own list of hues).

## The refused forms

- **The sunrise and the sunset.** They need the place of the machine on the earth, and the system has no such fact. A setting of the place would be a fact of the principal that only this rule reads, and the hours of the light change each day. Fixed hours give the principal a rule that one sentence says.
- **The hours of UTC as the rule.** The rule reads the zone of the date page, so it is right on the day that the time zone becomes a setting. Until then the zone is 0.
- **The program `settings` as a service that stays.** It would need a second instance with no window beside the instance of the window, and two writers of the values. The root service already runs, and holds both pages.
- **A wake each minute.** A wake each minute is a polling loop: 1 440 wakes a day for two changes. The root service waits for the next edge.
- **The appearance in force computed by each reader.** Each program would need the date page and the rule, and two programs could draw two appearances at one moment. One word on the page is one answer for all.
- **The appearance as a second set of constants that each program chooses.** A program would hold an `if` for each color, and a program that forgot one would draw a dark part in the light appearance with no fault of the build. The tokens are one record that one procedure changes; the `DARK_` constants are the one exception, and their name says that they do not follow.
- **A remap of each pixel by its color.** A table from each dark value to its light value, applied to the pixels of a surface, misses each color that `mix`, `shade` or a gradient computed, and changes the colors of a picture. The tokens change the colors before the draw.
- **A dark and a light value for each color that a program owns.** Twenty programs held about sixty colors. Each with two values in its program is sixty pairs that no host test reads, and two programs could give one meaning two colors. Each became the token of its meaning, and only three meanings needed a new token.
- **A token named by its program.** A token `rings_blocked` or `manual_heading` holds a color for one window, and a second program with the same meaning takes another. A token is named by its meaning.
- **A color of the rules by its value.** The kernel entries had the value of the boot program, `0xE0A040`. A token by value is a color with a wrong meaning: the kernel entries take the kernel blue.
- **The light series as the dark series at one shade.** At one shade the darkest hue fails on white, or the lightest hue is far darker than it must be. Each member has the shade that keeps 4.5 to 1.

## Subtle points

- **The test machines have a fixed hour.** The tool gives each machine a real-time clock at 01:00 UTC of the day of the host (`-rtc base=`), and keeps the difference to the clock of the host: a check of a date of the machine takes the difference off before it compares by order. So the default `auto` gives the dark appearance in each picture of a test, whatever the hour of the host, and a run of six hours stays in the night.
- **The test of `auto` cannot choose the hour, and need not.** The program `settings` writes the time that the rule read with the appearance that it gave: "the appearance in force is dark: auto, light from 07:00 to 19:00 of the local time; the local time is 01:04 with a zone of 0 s, at 1794791040 s since 1970". The step `Appearance_Auto` of the tool checks the date by order against the clock that it gave the machine, then calls the same rule over that date and that zone, and compares the two appearances.
- **A frame and the event.** A window can draw a frame between the new page and the event `Settings_Changed`. The read of each frame makes that frame whole, so the event then draws a whole frame of the same appearance: one more frame, never a mix.
- **The track is not a surface for a concept.** In the light appearance a concept at its light shade has about 3.6 to 1 on the track. No rule draws a concept as a text there; a program that did would fail the contrast.

## State

Built: the two appearances as one table of tokens, the setting and the appearance in force on the settings page, the rule of the day with its host tests, the edge in the root service, the compositor, the interface package, the palette, the terminal and the results of the console in the tokens, each window of a program in the tokens, the host tests of the contrast in both appearances, and the machine test that sets `light`, `dark` and `auto` and takes `desktop_light.png`, `console_light.png`, `monitor_light.png`, `rings_light.png` and `clock_light.png`.

Left: the setting of the time zone, which the rule then reads.
