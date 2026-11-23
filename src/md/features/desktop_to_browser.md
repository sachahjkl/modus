# From the desktop of today to a light web browser

The desktop of today has windows of a fixed size, processes with fixed tables, a draw table on the processor, and a network stack with TCP and QUIC. This file records the path from there to a light web browser, and to the run of two programs of other projects in Odin: `gui_toolkit`, a toolkit of immediate-mode interfaces, and `wren`, a web browser built on it. It gives each phase, what it depends on, and why the phases come in this order, with the standard of quality that every phase keeps. The entries of the work are in `ROADMAP.md`; this file holds the reasons and the order.

## The constraints

- Each phase adds a capability to a system that works. No phase replaces a part that works with a part that does not work yet.
- Each phase keeps the properties of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md). The section "The contradictions, and how they were resolved" names each place where the path pulled against a property, and the text that changed.
- A browser reads hostile data from the network: HTML, CSS, pictures, fonts. Each reader of such data is a confined process or module with fuzz targets ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)).
- Each phase keeps the standard of quality below. A phase that makes a measure worse is read to its cause before it is merged.

## The standard of quality

The rule is in [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "18. One 2D interface: the draw table". It lives in property 18 because the three measures are the path from an input to drawn pixels, which the draw table, the drawing module and the compositor own; a new property would hold one rule.

The standard has two quality profiles ([`docs/glossary/desktop.md`](../../../docs/glossary/desktop.md), "Quality profile"). The system chooses its profile at its start, from what the machine has, and writes it on the log.

| Profile | When | The screen | The three measures |
|---|---|---|---|
| GPU profile | A GPU that the system drives | 1920 × 1080 at 120 Hz | A frame in less than 8.3 ms; a key to the screen in less than 20 ms; a window shown less than 100 ms after its start |
| Processor profile | No GPU | 1920 × 1080 at 120 Hz, with no blur (the thresholds below) | The same three measures, with the thresholds below |

- **The measures are measures, never tests.** The tool records them in the measure record of each release and follows them over the releases ([measure_history.md](measure_history.md)). A test never fails on a time (`AGENTS.md`, "Work"). A change that makes a measure worse is a regression that a developer reads to its cause.
- **The processor profile is accepted with no shame.** The test machine has no GPU, and a machine with no GPU still gets a desktop that answers at once.
- **Its thresholds come from numbers.** The first measure is a frame of the desktop at 1920 × 1080 drawn on the processor, before any GPU work. Its number gives the resolution, the rate and the effects of the processor profile.
- **Each measure has one sentence on the log**, which is its identity in the measure record: the time of a frame, from the first record that the compositor reads in the turn that draws it to the flip; the time from the read of a key by the input service to the flip that shows it; the time from `Process_Start` to the first frame of the window.

### The thresholds of the processor profile

| Threshold | Value |
|---|---|
| The resolution | 1920 × 1080, the reference screen: the profile lowers nothing |
| The rate | 120 Hz, as the GPU profile |
| The time of a frame | Less than 8.3 ms, as the GPU profile; the first measure gives 2.0 ms for the heaviest part |
| The effects that the profile keeps | Alpha and sharp shadows; a blur waits for its own measure |

Each value comes from the first measure below, on the test machine (one processor of the host under KVM, a host load of about 19): a clear and a present, median 268.8 us; a full frame of the compositor with 4 windows, median 953.9 us; a frame in its damage, median 86.2 us; a draw table of 339 records that fills the screen, with alpha, median 2043.0 us (`processor_frame: measure:` lines of the measure record). The heaviest part takes a quarter of the 8.3 ms of a frame at 120 Hz, so the processor profile keeps the resolution and the rate of the GPU profile. The two profiles then differ in the effects only: a blur costs a pass over each pixel under it, which no measure gives yet, so it stays out of the processor profile until a measure says it fits. A change that brings a part past 8.3 ms is a regression to read to its cause, and the table changes only from a new measure.

### The three measures on the path of the system

**The start measures are not on the path.** The compositor also measures its copies and fills, a title bar, the blend of the arrow and the bar with its start menu. Those run once, after the first frame, and only in a measure run (`system.measure_run`, the boot image of `modustool measure`): before, they ran at each boot before the first frame, and on the software processor of a browser machine they took more than 100 s (the bar 69 s and 20 s, the copies 17 s). The three measures below are of the path itself, and cost one read of the clock.

The compositor measures all three, with `system.nanoseconds()`, the clock of the system that the kernel keeps for each process: never a clock of the host. Each measure is one sentence of the log, and the tool keeps it in the measure record; no test reads a time.

| Measure | From | To | Its line |
|---|---|---|---|
| The time of a frame | The read of the first record (of the root service, of the input service or of a window) in the turn that draws the frame; the start of the draw when that turn read none | The end of the copy into the screen page and of its page flip | Each 4096 frames, about once a minute, so that the measure does not fill the log of the system; and with each line of the keys; over the last 64 frames |
| The time of a key to the screen | The read of the byte of the key by the input service, which writes the time in its record (not the interrupt: the input service reads the byte just after it) | The flip of the frame that draws the Present that names the key | Each 16 keys that a window named |
| The start of a window | The call of `system.process_start` by the root service, which loads the module and makes `Process_Start` | The flip of the first frame that draws the first Present of the window | One line for each window, when both times are known |

**The time of a frame holds no pacing.** The compositor draws at most one frame each 16 ms. A record that comes during that wait is read in a turn that draws nothing; the frame starts in the turn that draws, so its time is the cost of the frame, and it compares with the 8.3 ms of a frame at 120 Hz. The wait is the rate of the compositor, which the reference screen at 120 Hz changes.

```
compositor: measure: the time of a frame, from the first record that the compositor reads to the flip: least <t> us, median <t> us, over <n> frames
compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it: least <t> us, median <t> us, over <n> keys
compositor: measure: the start of the window <name>, from Process_Start to its first frame: <t> us
```

**The rate of the frames while the pointer moves.** A fourth line, beside the three: over a series of 120 frames that each show a pointer record that came after the frame before, with no gap of more than 250 ms, the compositor writes the frames, the time from the flip of the first to the flip of the last, the frames each second and the pointer records. It says whether a pointer that moves gets a frame at each step of the pacing, which the time of a frame alone does not say. A gap ends a series with no line.

```
compositor: measure: the pointer moved in <n> frames over <t> us: <n> frames each second, for <n> pointer records
```

**The tie of a key to its effect.** A frame shows a key only when the process says so. The path:

1. The input service writes the time of the system in the record of the key.
2. The compositor gives each key with a character a serial, sends it in the event `Key`, and keeps the serial, the window and the time in a table of 32 keys.
3. The console marks the serial of each key that it puts in its edit line, and gives the newest one with the record `Edit` to its terminal.
4. The terminal gives the serial of the edit line that its picture shows to the window layer (`display.key_shown`). Its next `Present` names it.
5. The compositor ties each key of that window up to that serial, and measures each one at the flip of the frame that draws that Present.

So the key is measured to the frame that shows its character, not to a frame that only came after it. A key that does not change the edit line stays sent, and the next edit of the line ties it late; its time is then too long, never too short. The cases:

- a key that the terminal drops because the queue of its process is full, or that the console drops while a line runs and its keys that wait are full;
- a key that the completion list takes, which moves the list and not the line: Tab, Enter or Escape while a list is open (`completion_key` in `src/modules/system/console/completion.odin`); the arrows and Control+R or Control+S have no measure, because the compositor gives a serial only to a key with a character and no Control;
- a character of the history search, which changes the search and not the line.

A window that names no serial ties none. A Present that names a serial past the newest key that its window got is refused and counted, as an `Edit` record whose serial is past the newest key that the terminal forwarded: a process cannot name the key of another window, nor hold the measure with the largest serial. When the table is full, a new key takes the place of the oldest key that is not shown, and of the oldest shown key only when all are shown; each such key is a lost measure, and counted. The counts of the lost keys and of the refused serials come in one line after a line of the keys, when they changed: the table holds measures, not records of input.

**The start of a window.** The root service writes the time before it calls `system.process_start`, and sends it to the compositor after the start, in the control record `Client_Started`, for the ring of the window. The time holds the load of the module, its hash and `Process_Start`, as the principal waits for them. The two times come from two processes in either order: the compositor keeps the time of the first flip of each window, and writes the line when it has both, whichever comes second. The span is the first flip less the start. A record that names no window (the handle 0, a handle of no window, a window that ended), a time of 0 or after now, and a second record are refused. When the control ring is full, the root service writes one line, and the window has no measure.

**The profile at the start.** The compositor writes one line at its start: `compositor: the quality profile is the processor profile: the system drives no GPU device`. The system drives no GPU today, so the decision is one pure procedure of the private part `quality` of the compositor, which the GPU path changes.

**The checks.** No wait of the measure run depends on the order of two processes or on the place of the 16th key. The line of the profile and the start of `locks` are waited for in any order with the steps after them. The line of the keys, with its line of the frames, is waited for after the 24 characters of `start("processor_frame")`: whatever the count of keys before them, more than 16 keys come after the wait before, so a line comes after it. After the machine, the tool checks the form of the lines only, as for `processor_frame`.

**The refused forms.**

- **The first flip after the key.** A frame of a clock, or of a window that ignores the key, would count as its effect, and the number would be too small.
- **The time in the event, sent back by the process.** A process would then write the time that the compositor reads. With a serial, the compositor keeps the time.
- **A line for each frame and each key.** The log would hold thousands of lines in a test; a line for each 16 keys holds the least and the median.
- **The time of the `Client_Add` record.** It goes before the budget and the mappings are made, so it is not the start that the design names. A new control record says when the start ended.
- **The profile in the root service.** The compositor owns the screen, and it is the part that a GPU changes first.

### The first measure: a frame at 1920 × 1080 on the processor

**Its purpose.** It gives the numbers from which the thresholds above come: what a frame of the desktop at the reference screen costs on the processor, with no GPU, split into the parts that a later change moves one by one.

**The three parts.** Each part is drawn 21 times, after one frame that is not counted: that frame pays the pages on first use of each canvas.

1. **A clear and a present.** `graphics.clear` of a canvas of 1920 × 1080, then `graphics.copy` of it into a second canvas, as the compositor copies its frame into a screen page. It writes 8.3 MB, then reads and writes 8.3 MB: the bound of the memory bandwidth. No frame of this size on this path costs less.
2. **A frame of the compositor with four windows**, of 1280 × 800, 960 × 640, 800 × 640 and 640 × 480, in the phases of the compositor ([`docs/SIMD.md`](../../../docs/SIMD.md), "4. The compositor"): the background copied into the frame, one call of the drawing module for each window (the records of its frame and the Picture record of its surface) and one for the bar, then the copy of the frame into a screen page. One line for a full frame. One line for a frame in its damage: a rectangle of 400 × 300 of the surface of the front window and the clock of the bar, the damage of one `Present` and of one second of the bar.
3. **A draw table that fills the screen** with the records of a desktop: twelve cards, each with a gradient, a title and a caption in the interface font, ten lines of a label in the interface font and a value in the font of the cells, a bar, an opaque picture, a picture with alpha and a rectangle with alpha. One call of the drawing module draws it into a canvas of 1920 × 1080, with the fill of the background. The table is built once: the time is its execution, which a GPU back end of the draw table replaces.

**Where it runs: a process on the machine.** The process `processor_frame` runs in the measure run of `modustool measure`, after the other measures of that run, when no other process draws. It makes its canvases and its surfaces with its own budget, and calls the code that the compositor calls: `graphics.clear`, `graphics.copy` (that is `copy_bytes_without_overlap`), and the drawing module through `interface.draw_part_through_module`. So the number is a number of the code of the system, built as the system is, under its kernel, on the machine of the other measures. The measure came before the test machine showed the reference screen, to give the thresholds; it keeps its own canvases, so that its parts stay apart from the rest of a frame of the compositor.

**What it does not measure.** The procedures of the frame of the compositor (`screen_build`, `frame_records`, `draw_areas`) are in the compositor module, and no other module imports them. The process builds the records of each window in the form of the compositor (the gradients of the title bar, the borders, the title, the close button) and runs the same phases. It leaves out the pointer, a blend of at most 48 × 48 pixels, the read of the rings, the page flip, and the swap of red and blue of a screen in that order. The test machine shows 1920 × 1080, so the line "compositor: a full frame of 1920x1080 with ..." of the compositor itself is the number of the compositor, and part 2 is read against it.

**How it reports.** One line for each part, with the least of the 21 frames and their median, in microseconds with one decimal, and the frames in one second that the median gives:

```
processor_frame: measure: a clear and a present of 1920x1080: least <t> us, median <t> us, <n> frames in one second at the median, over 21 frames
```

The least is the cost when the host did not stop the processor during the frame. The median holds the noise of the host. The chart of the measure history follows the least ([measure_history.md](measure_history.md)). The frames in one second come from the median, because a screen shows each frame and not only the fastest one. The line of the draw table names its count of records of each kind before its times.

**No time is a condition.** The scenario of the measure run waits for each line and for the last line of the process. Then the tool reads the four lines and checks their form only: each part ran once, each number is a number, the least is not above the median, the frames in one second agree with the median, and the count of frames is not 0. The process checks its pixels: after each part a pixel that the part writes has its color, and no call of the drawing module was refused.

**The refused forms.**

- **The measure inside the compositor, at its start**, as its measures of the bar and of a title bar. Three canvases of 1920 × 1080 and the four surfaces are about 8 500 pages. The budget of the compositor would hold them at each start of each machine, for a run that only measures. The compositor already prints its full frame at the size of its screen.
- **The frame of the compositor in a support package** that the compositor and the process both import. It measures the code of the compositor itself, but it moves the loop of the compositor for one measure. The reference screen of the test machine gives the number of the compositor itself with no move.
- **A host benchmark alone.** A host test has another runtime of memory, no kernel, no page on first use and no QEMU: its number is a second number, never the only one. It is not built.
- **A rate over one second.** A count of 21 frames needs no duration, and runs the same work on a slow host. The frames in one second are computed from the median.
- **Large pages for the canvases.** The surfaces of today have 4 KiB pages ("Large pages for large buffers" below). The measure takes the pages of today; a measure with both forms is a later step.

**The hazards.** A measure is valid when the load of the host is under 8 ([`docs/SIMD.md`](../../../docs/SIMD.md), "7. How to measure on the machine"). The measure record says the host of the run. A change of the host is not a change of the system.

## The reference screen

The reference screen is 1920 × 1080, the screen of the standard of quality, in place of 1024 × 768. Its scale factor goes from 1 to 2: a layout is made in logical pixels, and the scale factor turns them into pixels of the screen. It comes in two layers, each a system that works.

**The first layer: the screen at scale 1.** Built. The test machines show 1920 × 1080, and a logical pixel is a pixel of the screen.

- **One place for the size.** The contract package `reference_screen` holds the width and the height. The boot program asks the firmware for that mode, `processor_frame` draws at that size, and the tool checks the screenshots and the video memory of its machines against it. The compositor still takes the size of its screen from the framebuffer of the firmware, and the line `compositor: ok <width>x<height>` says which.
- **A firmware with no such mode.** The boot program reads the modes of the firmware, and a pure procedure of the contract (`mode_choose`) takes the mode of the reference screen in 32 bits, else the largest drawable mode whose width and height do not pass it, else none: the firmware keeps its mode. A mode larger than the reference screen is never chosen, because the budget of the compositor is counted at the reference screen. Whenever the screen is not the reference screen, the boot program writes one line, `boot program: the firmware offers no mode 1920x1080 in 32 bits; it keeps <width>x<height>`, with the status of `set_mode` when the firmware refused it. The format word of each mode becomes its enum at one border, and a word that names no format is not drawable. A screen whose frame and background the budget of the compositor cannot pay gives the line `compositor: a screen of <width>x<height> needs <n> pages, the budget holds <m>`, and the compositor stops with its code: the rest of the system runs with no desktop, as for each missing part of the machine. The main machine test reads the size of the line of the compositor and fails at once on another size, with the size that the firmware gave.
- **The video memory.** The standard VGA keeps its 16 MiB, which hold two screen pages of 8 294 400 bytes; the machine passes no option for it (an option for the video memory left the firmware with no graphics output), the tool names the amount, and the compiler checks the two pages ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)).
- **The compositor.** Its frame and its background are each 2025 pages, in place of 768, and the page tables of the two screen pages are 9 at most, in place of 4: its stated working memory grows by these pages.
- **The windows keep their sizes.** Each window fits 1024 × 768 logical pixels under the bar and its title, as before; at a larger scale a window gets a surface of at most the work area, and scrolls a layout that is larger ([window_scroll.md](window_scroll.md)). A window then fills a part of the screen, and the scenarios of the machine test keep the places of their windows; the places that named an edge of the screen (the corner that no window covers, the lowest place that keeps a title on the screen, the middle of the palette) move to the edges of the new screen.
- **The screenshots.** Each picture of `docs/screenshots` and of the site gallery has 1920 × 1080 pixels (`SITE_SCREEN_PICTURE_WIDTH`), so `modustool screenshots` makes each of them again. A picture of an older news entry keeps its size: it records what the screen was.
- **The measures.** The measure "A full frame of the compositor" named no size, and its line had the size of the screen of the run. Its sentence now names 1920 × 1080: the old series ends at the last release at 1024 × 768, and a new series starts, so no chart joins two sizes.

Refused for the first layer:

- **A whole scale of 2 first.** The glyph caches and the pointers exist at scale 2, but the logical screen is then 960 × 540, and no window of today fits it: each process would change its layout in the same step.
- **A scale of 1.5 first.** The logical screen is 1280 × 720, and a window of 708 pixels with its title does not fit under the bar. The font needs caches at 1.5, and the drawing module needs the transform below: three changes in one step.
- **A larger video memory.** 16 MiB, the amount of QEMU with no option, hold two pages. An option for the video memory, even of 16 MiB, left the firmware with no graphics output, and the check of the compiler says when a screen needs more.

**The second layer: the scale factor.** Built in two parts, each a system that works: first the scale, its border and the transform in the execution of a draw table, with the look of the desktop unchanged; then the desktop at the scale, 1.25 by default and each eighth from 1 to 2 that the principal sets. It rests on the text rendering module and on the draw record with a text size, which come first ([text_rendering.md](text_rendering.md), "State"). The boot display is not a part of it: it is not drawn by the text rendering module, and it takes its own scale from the size of the screen with the rounding below, among the sizes of its bitmap font, Spleen: 1, 1.5, 2 or 4 ([boot_display_scale.md](boot_display_scale.md)). The desktop keeps the scale in eighths from 1 to 2 with the outlines.

- **Where the scale lives.** One setting of the settings page, written by the process `settings` as the appearance is, and read by the compositor and by each window. Its value is a count of eighths, the enum `scale_factor.Scale` with the members 8 (1) to 16 (2), whose values are the words of the page. One conversion, `scale_factor.scale_of_word`, refuses each other count, 0, 7 and 17 too, and a refused value keeps the scale in force. The default is 1.25.
- **No window bound: the whole range.** Each member from 1 to 2 is a scale that the principal sets. The range was first bounded at 1.375 (`WINDOW_BOUND`), the largest scale whose logical screen held the tallest window of today with its title; a principal then saw two scales and no range. The bound is gone, by three rules that each keep the desktop usable at 2. (1) The budget of a window counts its pictures at its stated size at the largest scale, `scale_factor.LARGEST` ("The budgets" below), so each window pays its surface at each scale. A window keeps its logical size across a change of the scale, so a window that the principal made larger than the work area of a larger scale would hold more pixels than the screen: a terminal maximized at 1.25, 1536 × 792 logical pixels, needs about 9 500 pages at 2. So before the compositor names a new scale to a window, it fits the window into the work area of that scale (`bar.window_fit`): a maximized window takes the new work area and stays maximized; a window larger than the work area is asked for the size that fits, within its limits; and its place is moved so that the window is on the screen. The window gets the new scale when that request ends, by its answer, its decline or a refusal: the release of a rescale declines a request that waits, so the two in one step would lose the fit. A window that takes no request keeps the old scale until it answers, as a window that reads no events does. No surface then passes the screen in pixels, so a window that budgets two surfaces of the screen, as the terminal does, pays each size at each scale. A window that answers no `Resized` keeps its size and declines a scale that its budget does not pay. Naming the scale first and fitting after was refused: the surface at the new scale of the old size is the one that the budget cannot pay. (2) A holder of the display leaves at each scale the least work area `scale_factor.WORK_AREA_LEAST_HEIGHT`, 360 lines: the least height of the window of settings, 320, with its title of 40, so the principal always reaches the bar and the window that sets the scale back; the logical screen has 540 lines at 2, so a holder keeps at most 180 (`scale_factor.HOLDER_LINES_MOST`), and our compositor states that its bar of 32 fits ([roles_and_contracts.md](roles_and_contracts.md), "The work area"). (3) A window gets a surface of at most the work area, and a window whose layout is larger scrolls it ([window_scroll.md](window_scroll.md)): its least size and its fixed places stay as declared. A window never sets the range of the scale.
- **The setting and its first value.** The word of a value is its place in the names of the setting plus the first word of the setting (`settings.word_of_value`): the place for each setting but the scale, whose first word is 8. The first value of each setting but the scale is its default; the default scale is 1.25, the third value of its range (`settings.choice_default`). The word 0 names no scale, so an all-zero page is refused: the root service writes the defaults into the page that it creates (`settings.page_defaults_write`), and a kept record of fewer settings gives each setting past its count the word of its first value, so a record of the six settings before the scale keeps them and reads the scale 1.25. A scale stored as an index from 0 was refused: the word would then not be the count of eighths that each reader computes with. A scale that is not a multiple of 1/8 has no value: each spacing token, a multiple of 8 logical pixels, is then always a whole count of screen pixels (the gap of 8 is 10 at 1.25, 12 at 1.5, 14 at 1.75, 16 at 2), and so is a cell of the font of the cells.
- **The control of the settings window** is a track of nine stops, one for each member, from 100 % to 200 %, each selectable ([settings_window.md](settings_window.md)). A window that declines a scale (window_resize.md, "The rescale") is counted, and the window of settings says how many show their frame only.
- **How a module learns it.** `display.open` makes the surface at the scale of the settings page, and names that scale in `Surface_Create`. After that the window takes its scale from the compositor only: each `Settings_Changed` names the scale of the compositor, and the window rescales to it, never to a fresh read of the page, which can change again before the compositor reads it. The compositor names its scale at once to a window whose `Surface_Create` names another. The rescale is a state machine on each side, with a surface serial and an answer to each request ([window_resize.md](window_resize.md), "The rescale: one state machine on each side"). A page that the read refuses, or a writer left in its change, keeps the scale in force on both sides.
- **Where the transform is.** A process places in logical pixels, in the draw table, whose places are in 1/64 pixel. The execution of the table, which the drawing module compiles in, reads each record through the border in logical pixels, then turns its places into screen pixels and draws it with the code of its kind in screen pixels (`interface/execute_scale.odin`). The scale crosses the border of the drawing module in the shape of the canvas: a word, 0 for records in pixels of the canvas or a count of eighths from 8 to 16, which one border turns into a `Scale` and refuses with `Bad_Value` for each other word. No process computes a screen pixel. The difference stays in logical pixels, and `damage_at_scale` turns its rectangles into screen rectangles once, where the frame is drawn and presented.
- **The words between a window and the compositor.** The size of `Surface_Create` is logical, with its scale: the compositor computes the pixels of the screen by the rule of each edge, so it never holds a surface whose pixels no logical size gives. The size of a `Surface_Resize` or of a `Surface_Rescale` and the rectangle of a `Present` are pixels of the screen: the compositor reads the pixels of a surface and copies them, and checks each size against the logical size at the scale of the surface. A place of the pointer, a size that `Resized` asks for and the size limits are logical pixels, which mean the same at each scale. Sending each word in pixels of the screen was refused: each window would round places back with its own scale, and a pointer place would come back up to a logical pixel off.
- **The surface stays inside its window.** The compositor copies a surface from the corner of the logical interior of its window on the screen and cuts it to that interior. Until a window rescales, its surface of the old scale is larger or smaller than its interior: the larger one never covers the frame or another window, and the background fills the part that the smaller one leaves.
- **The compositor at the scale.** It lays out the desktop in logical pixels: the screen of 1536 × 864 at 1.25, the places of the windows, the bar, the menus, the palette, the drag and each hit test. It turns them into pixels of the screen at one place each: its damage, the draw of its tables by the drawing module at the scale, the corner of each surface, the pointer picture and the grid of points of the background. The frame of a window is a scaled part of its screen table; its surface is a part with no scale, its pixels copied at the pixel of the screen of its corner. The corner rounds on its own, so the borders of the frame reach one logical pixel under the surface, which is drawn over them: no pixel of the background shows between them.
- **The pointer moves in logical pixels.** One unit of a move of the mouse is one logical pixel, so a press acts at a place of the layout and the pointer reaches each logical pixel; the hot spot is drawn at the screen pixel of that place. A viewer of the remote display sees pixels of the screen, and its pointer goes to the logical pixel that holds its pixel.
- **The windows that draw by hand.** A process that draws pixels with `graphics` draws into a picture of its own, of the logical size of its window (`interface.Hand_Picture`), and shows it as one Picture record: the drawing module puts each pixel on the pixels of the screen of its logical pixel. `log`, `pages`, `tables`, `server`, `pointers`, `boot`, `interface_font` and `vector_glyphs` do so. Its cost is the picture in its budget, and its text is pixels of a picture, not glyphs at the size of the screen: one column in four is wider at 1.25. A transform in `graphics` was refused, as each process would compute screen pixels; the move of each such window to the elements of the interface package is the entry "Every window uses the interface package" of `ROADMAP.md`.
- **The rounding.** One contract package, `scale_factor`, holds each rule, as pure procedures that the host tests try to break. Each edge of a box rounds to the nearest screen pixel, a half up (`screen_edge`); a size is the difference of its two rounded edges. So two rectangles that share an edge in logical pixels share it on the screen, with no gap and no overlap, and the rule grows with the place, so no box turns over. A line of 1 logical pixel keeps at least 1 screen pixel, and 2 at most. A place at a multiple of 8 logical pixels needs no rounding. A point of a path, a point of a gradient, the origin of a text and the width of a stroke round to the nearest 1/64 pixel of the screen (`screen_place`): they keep their part of a pixel, so a curve stays smooth. A box with an edge inside a logical pixel goes to whole screen pixels: a rule that kept the part of a pixel for such an edge and rounded a whole edge was refused, as it does not grow with the place, and a box from 63 to 64 units turned over at 1.25.
- **The pixel of the pointer.** A pixel of the screen belongs to the logical pixel whose box on the screen holds it (`logical_pixel_of_screen_pixel`), so each pixel of the screen belongs to exactly one logical pixel.
- **A picture keeps its pixels.** The size of a picture is its box in logical pixels, and each pixel of the screen takes the pixel of the logical pixel that holds it. At 1.25 one column in four is then twice as wide as the others. A filter that mixes four pixels was refused for this step: it makes colors that the picture does not hold, and the cells of `life` and the strokes of `paint` then get soft edges. A text is never a picture: the rasterizer draws it at its size on the screen.
- **A pattern** places each cell by the rule of each edge: a step of 2 logical pixels is 2 or 3 screen pixels at 1.25, and the cells still never overlap.
- **The fonts.** The text rendering module draws each glyph at the text size of its record times the scale, from the outlines, into the glyph cache of the process, and places it at the place of the measure times the scale ([text_rendering.md](text_rendering.md), "The scale factor"). A cell of the font of the cells is 10 × 20 at 1.25, up to 16 × 32 at 2. Spleen, the fallback of bitmaps, has whole scales only: at a scale between two whole scales it draws at the lower one, in the middle of its cell.
- **The pointers.** The compositor asks for 24 logical pixels at the scale: 24 at 1, 30 at 1.25, 33 at 1.375, 48 at 2. The pointer theme of the system is drawn from outlines at the build, so it has these sizes (`sizes 24 30 33 48`); the theme of the owner, from Xcursor files of fixed sizes, gives 32 at 1.25 and 48 at 1.375 ([vector_pointers.md](vector_pointers.md)).
- **The logical screen.** It is 1920 × 1080 at 1, 1536 × 864 at 1.25 and 960 × 540 at 2. At 1 a logical pixel is a pixel of the screen, and a window fills a smaller part of it; at 2 a window of 1000 × 704 is taller than the work area, keeps its title on the screen, and is moved to show the rest.
- **The budgets.** A window states its size in logical pixels. The tool counts each of its two pictures at that size at the largest scale, 2 (`scale_factor.LARGEST`), so a window pays its surface at each scale that a principal sets (`scale_factor.window_surface_largest`):
  - **A resizable window whose least size fits the logical screen at the largest scale** (960 × 540, `LARGEST_LOGICAL_WIDTH` and `LARGEST_LOGICAL_HEIGHT`) is counted with each axis cut to the reference screen in pixels. The cut is exact: before a scale applies, the compositor fits each resizable window into the work area, within its limits ([window_resize.md](window_resize.md), "The fit at a new scale"), so its surface is at most the larger of its least size and the screen, which is the screen. The screen is never larger than the reference screen (`mode_choose`), the bound that the budget of the compositor also takes. A count with no cut reserved pages that no surface can use: a window of 1536 × 864 counted 10 368 pages, where the screen holds 4 050.
  - **Every other window is counted with no cut.** A window that is not resizable keeps its logical size at each scale, so at 2 its surface can pass the screen: `hall_of_fame`, 1000 × 696, has 2000 × 1392 pixels. A cut count left it no pages for that surface, and it declined the scale. A resizable window whose least size passes the logical screen is also never fitted below that size.
  - **The source states its least size** in two parts of its budget, `window_least_width` and `window_least_height`. Each part names the constant that the source passes to `display.resizable_set`. The describe step refuses each of these: a least part that is a number, one part with no other, least parts with no window parts, a least size larger than the window, least parts in a package with no call of `resizable_set`, and a call of `resizable_set` whose least parts are not those names. The limit of that check: the tool sees a call by the name `resizable_set` alone, so a call through another name is not seen. If the budget states least parts, a call whose record is not a literal of names is refused. A budget with no least parts is counted with no cut, which is never too small.
  - **A module that checks its budget at compile time** writes the same rule from the same constants (`scale_factor.LARGEST`, `LARGEST_LOGICAL_WIDTH`, `LARGEST_LOGICAL_HEIGHT`, `reference_screen.WIDTH` and `HEIGHT`), as a constant cannot call a procedure.

  A window can also state its pictures in its working memory, as the terminal does ([module_budget_request.md](module_budget_request.md)). A window that draws by hand adds its picture to its working memory. A budget is fixed at the start of its process, and no operation of the kernel grows it, so a budget counted at the scale in force was refused: each open window would then refuse each larger scale, and the change of the scale that the principal makes with windows open would fail. The cost is the reservation of the pictures at 2 for each window that runs: a window of 1000 × 704 holds 4 050 pages (the screen) in place of 2 600 at 1.375. Each module with a window states its size, so the least budget of the root service stays 2 048 pages. A module that ran in the least budget states that budget less its window at the scale 1 as its working memory. A rescale holds one surface at a time: the window releases the old one first, so the budget of its pictures pays the new one. A window whose budget still cannot pay (a disk process, whose budget its starter limits, or a window grown past its stated size) declines the scale: it shows its frame with the background until another scale, the desktop goes on, and the window of settings counts it ([window_resize.md](window_resize.md), "The rescale").
- **The bound of a text size.** The border takes a size of a record up to 128 logical pixels (`draw_record.TEXT_SIZE_LIMIT`), the largest size of the rasterizer, 256 pixels of the screen, at the largest scale, 2. So the writer, the border and the rasterizer keep one bound, and each text that the border takes has its glyphs at each scale; the record is version 19. A bound of the rasterizer at 512 pixels was refused: the widest glyph and the render memory of the rasterizer double, a cost that each process pays, for sizes that no element writes (the largest is 48). A larger text is a path.

Refused for the second layer: a scale in hundredths (1.3 gives places between screen pixels on the grid), a scale in each process (two windows with two scales on one screen), the transform in each process (each process would round in its own way), a size of each window in screen pixels (a window would have to know the scale to state its budget), and a stretch of each surface by the compositor (the glyphs of a text drawn at scale 1 then stretched are soft).

**The machine tests at the scale.** A test machine runs at the default scale, 1.25. A step presses and moves in logical pixels, which the compositor, the windows and their elements give; the places that name an edge of the screen are on the logical screen of the machine (`LOGICAL_SCREEN_WIDTH`, `LOGICAL_SCREEN_HEIGHT`). A step that reads pixels of a picture turns a logical place into a pixel of the screen with the rule of the drawing module (`screen_place_of_logical`), and reads the cells of Spleen at the step of a cell of the scale. The main scenario sets the scales 1, 1.375, 1.5 and 2 with windows open, waits until each window shows a surface of the scale, takes a picture of the desktop at 1, 1.5 and 2, and sets 1.25 back; no step presses at a scale other than 1.25.

**What is left.** A window that scrolls its whole content inside the work area when its least size does not fit it, in the window layer of the interface package, so a fixed window is whole at 2 with no move; the windows that draw by hand moved to the elements of the interface package; a measure of the free pages of a test machine with each window open, at each scale.

## The order and its reasons

| Phase | What it gives | Depends on |
|---|---|---|
| A. The desktop foundations | Data with no known bound, the measure of a frame on the processor, windows that change size, a resolution, a window manager, the clipboard, sound | Nothing new |
| B. Data in and out | Documents, drag and drop, pictures, notifications, buffers that pass from process to process with no copy | A |
| C. The draw table | Alpha, paths, clips, one text kind | Nothing new; it runs beside A and B |
| D. The web network | TLS over TCP, HTTP, cookies and a cache | A (arenas for the answers) |
| E. A light browser | HTML, a subset of CSS, links, forms, one process for each origin | A, B, C, D |
| F. The GPU and 3D | virtio-gpu, the WebGPU subset, its back end on the processor | C |
| G. A real machine | USB, NVMe, device services for real devices | A for the display modes |
| H. `gui_toolkit` and `wren` | The toolkit of rich modules, then the browser `wren` | A, B, C, G for `wren` on a real machine |
| I. WebAssembly | A portable and confined code format | H |

The reasons:

- **A comes first** because each later phase needs it. A page of the web has no known size, so a browser needs arenas before its first parser. A browser in a window of a fixed size cannot show a page at the width that its reader chooses.
- **The measure of a frame on the processor comes first in A** because it gives the thresholds of the processor profile, and every later phase is read against them.
- **Sound comes early, in A**, because virtio-snd is quick to serve, and it forces the design of a class of timed streams: samples that must reach the device at a time. Video and the frames of a display at a rate are the same class.
- **C runs beside A and B.** The steps of the draw table are decided and touch only the drawing; they do not wait for the desktop. A browser needs alpha, clips and paths, so E waits for C.
- **D comes before E** because a browser with no HTTPS reads almost no page of the web of today.
- **E is light on purpose.** It is the smallest browser that reads a page of documents: no script, a subset of CSS. It tests every phase before it with real data.
- **F comes after C** because the GPU draws the same draw table, and 3D draws into a picture that the draw table shows.
- **G is late** because the test machine is virtual (property 7). A real machine is a goal, not a condition of the earlier phases.
- **H comes after the foundations** because it needs the system as a target of the core library of Odin, and for `wren` a large part of the web stack.
- **I comes after H** because the engine of WebAssembly is a rich module, and its first users are the modules of `gui_toolkit`.

## SIMD on the hot paths

The hot paths of these phases have a vector form after the rules of [`docs/SIMD.md`](../../../docs/SIMD.md), "1. The rule of the same bytes" and "2. One form: SSE2": the vector form gives the bytes of the scalar form, a host test compares the two, and a measure decides each form. `docs/SIMD.md` holds this design; no file of `src/md` repeats it.

- **The rasterizer**: the coverage of a path of the draw table, and the triangles of the processor back end of the WebGPU subset with its shaders.
- **The compositor**: the row of colors of a gradient across, which is scalar today ([`docs/SIMD.md`](../../../docs/SIMD.md), "8. Limits"), and the translucent records over the windows.
- **The blend** in linear light of a translucent rectangle, of an antialiased edge and of a picture with alpha, as the blend of a glyph has today.
- **The picture decoders**: the filters of PNG, the inverse transform and the color conversion of JPEG.

## A. The desktop foundations

- **Memory with no known bound.** Arenas paid by the budget: [memory_without_a_bound.md](memory_without_a_bound.md).
- **The measure of a frame at 1920 × 1080 on the processor.** See "The standard of quality".
- **Layout with intrinsic sizes.** The interface package measures each element first, then places it: a label is as wide as its text, a column as wide as its widest child. Today a window places its elements at sizes that its code states. A window that changes size needs elements that know their size.
- **Per-view independent zoom.** Every view in the UI framework (`interface` and `gui_toolkit`) carries its own zoom factor in eighths (`0.5x` to `4.0x`, default `1.0x`), composed in one rounding step with the desktop scale factor (`scale_factor`). Each program gets crisp vector and font zoom (`Ctrl++`, `Ctrl+-`, `Ctrl+0`, `Ctrl+wheel`) and content reflow inside its view with no per-application zoom code.
- **Windows that change size.** The principal drags an edge of a window that its process declared resizable. The compositor sends the event `Resized`; the process makes the surface of the new size, paid by its budget, and draws its next frame into it; the compositor shows the old one until that frame comes. A budget that cannot pay keeps the old size, with one line. A process never draws into a surface that the compositor resized under it. The process makes the surface, and not the compositor, because whoever creates an object pays for it: [window_resize.md](window_resize.md).
- **A resolution that the principal chooses.** The compositor sets a mode of the display, then a scale factor for the interface, from 1 to 2 on the reference screen.
- **A window manager.** Windows float, with minimize/maximize/close controls and a bottom-right resize grip on server-decorated windows, optional client-side decorations (`Window_Decoration.Client`) so apps can paint edge-to-edge while the compositor retains unforgeable system shortcuts and trusted surfaces (property 20, line 8), snap to the edges and halves of the screen, workspaces, a positionable taskbar (`Top`, `Bottom`, `Left`, `Right`) with module grouping and a system tray, and a filterable fuzzy right-click context menu primitive (`interface.Context_Menu_State`).
- **The clipboard.** A copy gives the compositor a read-only handle to a memory object of the process that copies. A paste of the principal gives the process that pastes a read-only handle to that object, at that paste only (property 20, line 5). No process reads the clipboard when the principal does not paste: [clipboard.md](clipboard.md).
- **Sound** through virtio-snd: a device service, and the class protocol of a timed stream, whose records carry the time at which their samples must play: [timed_stream.md](timed_stream.md).

### The look

The desktop of the system keeps rectangular forms, sober by choice: sharp shadows, short animations that say a change of state, transparency only where it informs, and a blur later, with the GPU ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"). This is the look of the desktop and of its elements. The draw table puts no limit of look on what a process draws ([../api/draw_table.md](../api/draw_table.md), "The limits of the format: cost, never look").

## B. Data in and out

- **The document service with the picker.** Already in `ROADMAP.md`, "A document service with a picker". A browser saves a page and reads a file of the principal through it.
- **Drag and drop** gives the process under the pointer a read-only handle to what was dropped, at the drop only: a grant that follows from an action ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users", the forms of concession).
- **Picture decoders.** PNG first, then JPEG. Each decoder is a module that runs in a call host with no handle but the bytes that it reads and the picture that it writes, and each has fuzz targets. A wrong file stops the call host, never the process that asked. Their hot loops have SSE2 forms (see "SIMD on the hot paths").
- **Notifications.** A process asks the compositor to show a short text. The compositor draws it in a place that a process cannot imitate (property 20, line 8), and a notification never takes the focus.
- **Buffers that pass from hand to hand with no copy.** See the next section.

### Chains with no copy across several processes

A browser moves large buffers through several processes: the bytes of a picture arrive from the network, a decoder makes pixels of them, and the compositor shows the pixels. Each copy of a picture of 8 MiB costs time and memory. The aim: a buffer passes from hand to hand through successive lends of its memory handle, with no copy.

What exists today:

- **The lend of a handle for one call** (`system.lend`, `system.lend_end`; [`docs/glossary/access.md`](../../../docs/glossary/access.md), "Lent handle"). The caller makes a copy of its handle with the rights of the description of the export, gives the callee a handle from that copy, and revokes the copy after the call. A table parameter in a memory object is lent with the rights of its direction, so a callee that only reads a table gets no Write. A revocation reaches each handle and each mapping that came from the copy, through each chain of gifts ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", the revocation).
- **The datagram region with no copy on send** ([../infrastructure/network_data_path.md](../infrastructure/network_data_path.md), "The send with no copy"). The device reads the data to send from the datagram region of the process; the network service copies and checks 8 bytes of the header only. On receive, the network service still copies each datagram once into the region of the process, and that copy is irreducible with one receive queue.
- **The surfaces of the windows.** A process gives the compositor a budget of its surface; the compositor makes the memory of the surface and gives the process a copy with Read and Write (`display.open`, [window_resize.md](window_resize.md), "The compositor makes each surface"). The compositor reads the pixels in place, with no copy through a ring.

What is missing for a chain:

- **A lend that passes on to a third process.** A lent handle has only the rights of the description, with no Give, so a callee cannot lend the buffer on: the decoder cannot pass the pixels that it wrote to the compositor. The chain needs a description that lets a callee lend a handle on, with at most the rights that it received, and a `lend_end` of the first hand that ends each later hand too. The kernel already revokes through the chain; the form of the description and of the library is what is missing.
- **The read-only narrowing at each hand.** Each hand must pass the buffer on with Read only, and the hand before must lose its Write before the next hand reads, or the next hand must copy before it checks (property 6, "copy, then validate"). Today a process cannot take Write away from an object that another process maps: `Memory_Protect` acts only on an object that this process alone names. The missing part is a narrowing of an object for each holder: after it, no holder writes the object, and a reader can check the bytes in place.

The design of these two parts is not written. It needs a new intent file before any code.

### Large pages for large buffers

A large page maps 2 MiB with one entry of the page table, so a process that reads a large buffer misses the translation cache less ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Large pages").

What exists today:

- The flag `Large_Pages` of `Memory_Create`: the object is contiguous, its frames are one run aligned on 2 MiB, and its count of pages is a multiple of 512, or `Memory_Create` refuses it. `Memory_Map` uses a large page for each aligned 2 MiB of the mapping.
- A protection change must cover the whole mapping, and a decommit of such an object is refused, because it is contiguous.
- `Uncommitted` with any other flag is refused, so an uncommitted object never has large pages.
- The process `address_space` tests the flag and measures random reads over 64 MiB with large pages and with 4 KiB pages.

What is missing:

- **The surfaces.** `display.open` makes each surface with 4 KiB pages. A surface of 1920 × 1080 with two pictures is 16 MiB, eight large pages.
- **The decoded pictures and the frames of a video.** No process asks for large pages for them.
- **The arenas.** An arena is an uncommitted object ([memory_without_a_bound.md](memory_without_a_bound.md)), and the kernel refuses large pages for it. Large pages in an arena need a commit by whole runs of 2 MiB, which is a change of the kernel.
- **A measure.** The gain is measured for random reads only. A surface is mostly written and read in rows, where the gain can be small. The use for surfaces and pictures waits for a measure of a frame of the compositor with both forms. A contiguous run of 2 MiB can also fail on a fragmented machine, where 4 KiB pages succeed, so each use needs its refusal path.

## C. The draw table

The seven steps of the draw table, already in `ROADMAP.md`, "Next": [../api/draw_table.md](../api/draw_table.md). A browser needs alpha for its colors, paths for its borders and its icons, and the clip stack for its scroll boxes. The format has no limit of look: its bounds are bounds of cost only ([../api/draw_table.md](../api/draw_table.md), "The limits of the format: cost, never look").

## D. The web network

- **TLS 1.3 over TCP.** The handshake and the record layer of the TLS of QUIC, over a TCP connection of the TCP library. One TLS code for both.
- **HTTP/1.1 and HTTP/3.** HTTP/1.1 over TLS over TCP, and HTTP/3 over QUIC. HTTP/2 is not planned: HTTP/3 serves the servers that offer it, and HTTP/1.1 serves each other server.
- **Cookies and a cache for each principal.** In the private store of the browser, for the principal of its session, so two principals share no cookie and no cache.

## E. A light browser

- **An HTML tokenizer and parser** after the algorithm of the WHATWG, with fuzz targets: the parser reads hostile bytes, so it runs with no handle but its input and its output.
- **A subset of CSS.** Block layout first, then inline layout, then flex. No grid, no animation.
- **Text layout** with the shaping that exists ([glyphs_on_demand.md](glyphs_on_demand.md)).
- **Painting into the draw table.** The boxes of a page become draw records; the browser draws no pixel itself.
- **Links, a history and forms.**
- **One process for each origin.** Each origin runs in its own process, with the network grant of that origin only (property 20, line 3). A page of one origin reads nothing of another. The process of the window holds the address bar and starts the process of each origin.
- **JavaScript** is a separate decision, in `ROADMAP.md`, "Maybe".

### The window of the browser

The first layer is one process with one window, `browser` (`src/modules/demonstrations/browser`), with no grant but its window. It shows the pipeline of a page end to end on pages built into it, before any process of an origin exists.

- **The pipeline.** The window composes the style sheet of the appearance and the HTML of the page into one document, and sends it to the origin worker of its address ("The origin worker" below). The worker parses it with `html_css` under that document origin (`parse_html`), reads its `<style>` blocks (`parse_document_styles`), lays out its document boxes at the width of the view (`compute_layout`) and paints them as draw records (`emit_draw_records`). The window copies the records that its view shows into its own draw table, moved by its scroll and cut by a clip of the view. It lays the document out again only when the width of the view changes. The document tree, the style sheet, the document boxes, the records and the tables of the window are in arenas of the budget ("The memory of a document"). An address has up to 2048 bytes: a host of 253 (RFC 1035), a path and a query of 1024 each, a fragment of 256.
- **The text in the cells.** `html_css` measures a text at half its size for each byte, the width of the font of the cells, and gives a text that wraps one box of several lines. The window draws it in the font of the cells, at the spaces when its lines then fit the box, else at the width of the box: a text never leaves the box that the layout gave it.
- **The chrome by the layout tree.** The top band (back, forward, reload, the address field in a recessed well, go, and a badge of the document origin that the parse bound, with its mark, as wide as its whole text), the bookmarks band (one button for each page built in, the button of the page shown marked as open; a press loads its page and pushes it on the history), the page with its scroll bar, and the status band (the title, the counts of the nodes and of the document boxes, then the link under the pointer) are layout boxes of `modus:layout`, solved at each frame at the size of the window. The window is resizable from 640 × 420 to 1280 × 900; the top band holds its least address field at 640 pixels, which a compile-time check of the widths keeps.
- **Links and forms.** A press on the box of the page follows the link of the document box on top under the pointer: each node of an element `a` with an `href`, and each node under it, has that link as its target. A button inside a form sends it. Each element `input` with a name gets a text input of the interface package over its document box, when the view shows that box whole; a send writes the named values into the query of the action, encoded, and loads that address.
- **The history** holds 32 addresses with the scroll of each. A load drops the entries after the page shown; a full history drops its oldest entry. The history is a state of the window, not of an origin. The values typed in the fields of a page are a state of its origin: the window asks the origin worker to keep them when it leaves the page, and to give them back on back, forward, reload and a change of the appearance.
- **The state of a document origin.** A form result keeps its query in the storage of its document origin. A read names the document origin of the reader and the one of the state, and the worker refuses it when they differ: the page of `modus://welcome/peek` asks for the state of `modus://forms`, and the window shows the refusal.
- **An address of HTTP or HTTPS** gets a page, under its own document origin, that shows the request that the worker of that origin writes ("The fetch of a page"), with the cookies of that origin only, and says that the window has no grant of the network.

Refused for this layer:

- **A scheme for the built-in pages outside the contract.** Each page must have a document origin, and a scheme of HTTPS with a made-up host would say that a page came from the network. `Document_Scheme` has the member `Modus` for a page of a program of the system.
- **The text of a page in the interface font.** `html_css` measures the cells; a proportional font would draw a text narrower or wider than its document box, and the boxes would overlap.
- **A layout at each frame.** The cascade of the rules of a page over its nodes is far more work than the copy of the records, and it changes only with the width of the view, the page or the appearance.
- **The network grant in the window.** A page of HTTP or HTTPS would then come through the one process that holds every origin; property 20 gives the grant of an origin to the process of that origin only. The window builds no connection: the worker of the origin writes the request, and its process will send it.

### The memory of a document

A page of the web has no known size, so a document has no fixed table ([memory_without_a_bound.md](memory_without_a_bound.md)). The tree, the style sheet and the layout tree of `html_css` hold slices of memory of the caller, one for each part (the nodes, the attributes, the text, the work of the order; the rules and the names; the styles, the boxes and the matched rules), and a grow procedure that the parse calls when a part is full. The support package `web` gives each part an arena of the budget (`web.Document_Arenas`): a growth is a push at the end of its arena, so each entry keeps its place, which the parser needs, as it holds places in the tree across a growth. The window keeps its records, their text and the targets of the nodes in arenas of its own, grown to the boxes and the nodes of the page.

- **The bound is the budget.** Each arena reserves the pages that the budget holds at the start, so no part is bounded by less than the budget. A part that the budget does not pay cuts the document there, and the tree says that it is cut (`truncated`), as a cut of the parse always did: the rest of the window goes on. The stated budget of the browser holds a page of 1 MiB of HTML with 20 000 nodes and 1 000 rules.
- **A page gives back what the next one does not need.** After each page is laid out, each arena gives back its pages past twice what the page holds (`web.document_memory_trim`, `system.arena_trim`), and so do the tables of the window: a large page leaves only what a page of its size needs, so a later page of another shape (more rules, fewer nodes) finds the budget. Twice is the margin of a growth: a next page of the same size commits nothing. A page committed again is zero, so a trim also wipes.
- **The wipe reaches each byte written.** The order of the nodes can cut the tree after its nodes are written, so the tree keeps how far it wrote the nodes and the order (`nodes_written`, `order_written`), and its clear wipes to those marks, not to the counts that stay.
- **A node gives one box at most.** `compute_layout` makes a box for each node that it lays out once (a table lays out its rows and groups itself; a measure makes no box; wrapped text is one box), so the boxes never pass the nodes, and the origin worker refuses a tree with more boxes than nodes as damaged.
- **A node index is 32 bits.** `NO_NODE` and the marker of the active formatting elements are its two largest values; 16 bits bounded a page to 65 535 nodes, which a long page of today passes.
- **Nothing of a page is on the stack.** The cascaded styles and the matched rules of the cascade are parts of the layout tree, and the work of the order of the nodes is a part of the tree: on the stack, their size bounded the nodes.
- **Refused**: a fixed table at the largest page (it pays the largest page for every page, and bounds the page); a copy of a part into a larger memory at a growth (each place in the tree would move under the parser); one arena for all the parts (they grow apart, so one would cut another).

### The share of a principal

A principal of modus is a person. The cookie jar and the response cache of `http_client` serve the principals that the caller declares at their start (`cookie_jar_init`, `response_cache_init`), and no principal ever touches an entry of another: each has a part of the memory of its own, a region of entries and, in a cache, a region of bodies, at places that its part fixes, a share each.

- **The share is fixed by the caller**: the quota of a principal (`cookies_of_a_principal`, `entries_of_a_principal`, `body_bytes_of_a_principal`), by default the room over the principals that the caller declares it serves, never over the principals that hold something now. So one principal that fills its part never changes what another can hold, nor what another sees.
- **At its share, a principal evicts only its own entry used least**; a set, a lookup, a compaction of the bodies and an eviction read and write its region only. A body that can never fit its share is refused before any eviction.
- **A part is given at the first use of a principal, and kept**; a principal past the principals that the caller declared gets no part, and is refused. The memory of a part grows to its region when it is given: the place of a region follows the index of its part, not what the other parts hold.
- **Refused: a shared room with cross eviction** (a principal under its share took the place of the entry used least of the principal that held the most). An eviction is a signal: a principal that makes another lose a cookie or a cached answer, and sees a store refuse or answer differently, learns what the other holds. That breaks the strict isolation of principals ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), property 20, "No ambient access"), so the room of each is its own, even when the room of another is empty.
- **Refused: one memory with a count for each principal.** A count bounds what each holds, but the growth of the memory is shared: when the budget refuses it, a principal that came later is refused because another filled the memory, which is again a signal.
### The HTML parser

`html_css.parse_html` follows the parsing algorithm of the WHATWG, with fixed pools, no allocation and no recursion. The design keeps the structure of the standard, so that each later part of it is a new case of an existing mode, not a new parser.

- **The tokenizer** reads the states of the data, of a tag and of its attributes, of a markup declaration (a comment, with the abrupt ends `<!-->` and `<!--->` and the end `--!>`; a doctype and its name; CDATA, which is a bogus comment in HTML), of a bogus comment (`<?...>`, `</ x>`), and of the text-only elements: `script` and `style` as raw text, `title` and `textarea` as text with references. A tag that the end of the input cuts is dropped, a second attribute of the same name is dropped, and the flag of a self-closing tag has no effect on an element that is not void.
- **Character references.** The named ones of a small table, the legacy ones with no semicolon (`&amp`, `&lt`, `&nbsp`, ...) except in an attribute before a letter, a digit or `=`, and the numeric ones with or with no semicolon. 0, a surrogate and a value past U+10FFFF become U+FFFD; 0x80 to 0x9F are read as windows-1252; a long number saturates and never wraps. The text pool never holds a part of a character.
- **The tree builder** has the insertion modes of the document (initial, before html, before head, in head, after head), of the body, of a table (in table, in caption, in table body, in row, in cell) and after the body. The html, head and body elements are always made; an element of the head after `</head>` goes into the head. The implied end tags of `p`, `li`, `dt` and `dd` follow the scopes of the standard (default, list item, button, table). A part of a table outside a table is dropped; content that a table cannot hold goes before it (foster parenting); a row and a row group that a page omits are made.
- **The formatting elements.** `a`, `b`, `i`, `u`, `s`, `small`, `strong`, `em` and `code` enter the list of active formatting elements, with its markers at each cell and caption, and the clause that keeps at most 3 alike copies. The list is reconstructed before content, and an end tag runs the adoption agency algorithm in at most 8 outer rounds, with the bound of 3 of its inner loop, as the standard says. `<b><i>text</b>more</i>` gives `b(i(text)) i(more)`.
- **The bounds.** The nodes, the attributes and the text that the memory of the document holds ("The memory of a document"), 64 open elements, 16 entries of active formatting elements, 64 attributes for each tag. A page past a bound gives a tree that stops there and says that it is cut (`truncated`); an element past the 64th open one is not made, and its content goes to the deepest open element. The work is linear in the length of the page: each token touches at most the open elements, the list and the children of one parent.
- **The order of the nodes.** The adoption agency and foster parenting move nodes after they are made. The last step of the parse puts the nodes in preorder in place, along the cycles of the permutation, and computes their depths: the cascade and the browser read a parent before each child, as before.

Refused for the parser:

- **A recursive tree builder.** A hostile page sets the depth; a loop with a stack of fixed size keeps the stack of the process the same for each page.
- **Growing the pools for a long page.** The parser runs in the memory that the caller gives it; a page past it is cut, never a fault.
- **Unbounded adoption.** Without the bounds of the standard, a page of misnested formatting elements makes a number of clones quadratic in its length.

Left of the standard: foreign content (SVG and MathML), `template`, `select`, `frameset`, the quirks mode, the escaped states of the data of a script (here a `</script>` inside `<!--` in a script ends it), and the whole table of named references.

### The CSS engine

- **Selectors.** A selector is at most 4 compound selectors joined by a descendant combinator (a space) or a child combinator (`>`); a compound selector has an optional tag or `*`, at most 4 classes and one id. Their names are in a pool of 8 KiB of the style sheet, so a rule stays small. A selector list that holds a selector that the engine does not read (an attribute, a pseudo-class, a sibling combinator, a tag that it does not know) drops its whole rule, as CSS drops it.
- **Specificity** is the triple (ids, classes, tags) summed over the compound selectors, packed as `ids << 16 | classes << 8 | tags`: the order of the packed numbers is the order of the triples. The cascade sorts the rules that match by specificity, then by source order; the inline `style` attribute comes last.
- **The match** reads a selector from its right along the ancestors of the node, with one pass for each compound and no backtracking: `.y > .x p` matches a far `.x` whose parent is `.y` when the nearest `.x` has another parent. The work is the compounds times the ancestors, whatever the page.
- **Properties.** `display` (block, inline, flex, none, table, table-row-group, table-row, table-cell), `flex-direction`, `gap`, `width`, `height`, `margin` and `padding` with 1 to 4 values, `border`, `border-width`, `border-style`, `border-color`, `text-align`, `color`, `background` and `font-size`. The width and the height are those of the border box: they hold the padding and the border. A border of style none takes no room; each other style paints as a solid line, in the color of the text when it names none.
- **Text alignment** moves each finished line of a block to its center or its right; it is inherited, and a line wider than its block stays at its left. A box that shrinks to its content aligns nothing.
- **Tables.** A table is as wide as its columns, or as the width that it names, over which its columns spread. Each column is as wide as the widest cell in it, measured with nothing wrapped; when the columns do not fit, they are cut in proportion. Each row is as high as its highest cell, and each cell box is stretched to it. At most 64 columns: a cell past them gets no box.

Refused for the engine: a selector match that backtracks over the ancestors, whose work a hostile style sheet multiplies; full selector names stored in each rule, which would make a style sheet several MiB.

### The fetch of a page

The framing of HTTP/1.1 is the one of `modus:contract/http_client` ("D. The web network"): its encoder refuses a header that a value injects, and its parser refuses a smuggled or broken body. `browser/fetch.odin` adds what a browser decides, before a byte of an answer reaches the parser:

- **The request** is `GET` with the path and the query, never the fragment, `Host` with the port only when it is not the one of the scheme, `Accept: text/html`, `Connection: close`, and the cookies of the origin of the address only.
- **The answer.** The bound of a body is the memory that the caller gives it, the memory of the body without its framing and of the body as UTF-8, so the caller gives memory of an arena of its budget, and a page has no fixed size. A length past that memory is refused from the head alone; a chunked body past it is refused when it gets there. A status from 200 to 299 needs `Content-Type: text/html` with no charset or the charset UTF-8. Each byte that starts no UTF-8 sequence becomes U+FFFD. The first `Set-Cookie` is kept, as a name and a value, for the origin of the answer.
- **Redirects** 301, 302, 303, 307 and 308 are resolved against the address that the answer is for. The browser follows 5; the sixth is refused, as is a redirect to a page of the system (`modus:`) and one from HTTPS down to HTTP.

The window has no transport: the worker of an origin writes the request, and the page of the address shows it. The process of each origin, with its network grant, sends it through TLS 1.3 over TCP (`tls_tcp`) and gives the answer to this policy.

### The origin worker

`browser/origin_worker.odin` holds the state of each document origin, and the parse of its pages, behind one border of messages. It is the boundary of the process of each origin, built before the process: the bytes that cross it are the bytes that will cross a process border.

- **The messages** are records of fixed size with no pointer: an `Origin_Request` (its kind, the origin of the document that asks, the origin whose state it names, the width of the view, a key and a value), and its answer, an `Origin_Render_Tree` for a render (the counts of the document, its title, its height, whether it is cut, whether the style sheet was reused) or an `Origin_Reply` for each other kind. Each crosses as its bytes; the decoder refuses a size but the exact one, a word of a kind, a status or a scheme that names no member, a count past its capacity, a flag that is not 0 or 1, and a width past the window.
- **A request names its own origin only.** The worker refuses a request whose two origins differ before it reads any state; the refusal says nothing of the state of the other origin, not even whether it exists.
- **The state is partitioned.** Each of 32 origins has its own storage (16 keys), its cookies (16), the values of the fields of 8 of its pages, and the key of its style sheet. A full table gives the state used least to a new origin, wiped first. A read makes no state.
- **The workspace is wiped.** The tree, the boxes, the records, their text and the fields of the document are one workspace; each render clears it, so a page reads no byte of the page before it. The fields of the workspace belong to the origin of its document: a request of another origin to keep or to fill them is refused.
- **The style sheet** is reused only for the origin that parsed it and the same text of its style blocks; the same text under another origin is parsed again.

Refused for the worker:

- **One table of state that each read filters by origin.** A fault in one filter gives one origin the state of another; with a partition, a worker reaches the state of the owner of its request only.
- **The history in the origin.** The history is the navigation of the window across origins: it stays in the window, and the values of the fields of each page stay in the origin of the page.

What is left of this phase: the process of each document origin, started by the window, with the network grant of that origin only, that holds its origin worker and sends its requests through `tls_tcp` and `net`; the window then sends each request to that process, and each page comes from it.

## F. 3D

The GPU path and the WebGPU of the system are in [gpu_access.md](gpu_access.md). In order:

1. **virtio-gpu under QEMU for the 2D scanout**: the compositor shows its screen through the virtual GPU in place of the standard VGA.
2. **Vulkan to the host through Venus.** The commands of the system cross the virtual GPU in the serialization of Venus.
3. **The WebGPU subset on it**: only what the draw table, the compositor and 3D need, with WGSL compiled to SPIR-V by the build. The draw table is drawn through it ("Acceleration by the virtual GPU of the test machine" in `ROADMAP.md`).
4. **A real GPU later**, through the Linux driver domain, with the same serialization ("Acceleration by a real GPU" in `ROADMAP.md`).

### 3D on the processor: a back end of the same subset

A process that draws 3D on a machine with no GPU uses the processor back end of the WebGPU subset. It has the same objects as the GPU back end: buffers, pipelines, command lists and draw calls. A process writes the same code for the processor and for the GPU, and only the back end changes.

- **Its shaders are a small fixed set**, written in Odin with SIMD: a vertex transform, a flat color, a texture, a light of one direction. A pipeline names one of them. A shader of WGSL that the set does not hold is refused by this back end, with its name.
- **It has no compiler of WGSL for the processor.** Such a compiler is larger than the whole 2D drawing, and property 18 refuses it.
- **Its rasterizer** draws triangles with a depth buffer into a picture memory of the process, and a picture record of the draw table shows it, so the draw table stays the one 2D interface.
- **It must not become a separate drawer of 3D.** Each feature of the processor back end is a feature of the subset that the GPU back end has too. A feature that only the processor back end has is refused: it is a second 3D interface, and a process that uses it does not move to the GPU.

## G. A real machine

- **USB**: a device service of the xHCI controller, then the USB keyboard and the USB pointer.
- **NVMe disks**, served through the block ring.
- **The display of the firmware**: the compositor already shows the framebuffer of the firmware; the page flip on a real display is in `ROADMAP.md`, "A whole frame on the display of a real machine".
- **Device services for real devices**, their trust and their restart: [device_services.md](device_services.md).

## H. `gui_toolkit` and `wren`

`gui_toolkit` is an immediate-mode toolkit in Odin. On Linux it draws through WebGPU on Vulkan, with a Rust library for text; its packages `platform`, `render` and `font` meet the operating system, and most of the others are pure Odin. `wren` is a web browser in Odin on `gui_toolkit`: Lexbor in C for HTML, Rust libraries for the network, the pictures and the text, and Wasmtime as its one engine of execution.

### The toolkit of rich modules

`gui_toolkit` is ported to the system and becomes the toolkit of rich modules: a module whose interface needs more than the elements of the `interface` package (an editor, a browser, a module of a third party). A rich module is an outside module ([../infrastructure/third_party_module.md](../infrastructure/third_party_module.md)), never a source of `src/`.

1. **A target "modus" for the core library of Odin**, for outside modules only. `core:os` reads and writes the objects of the private store and of the handles that the process was given; `core:thread` runs on `Thread_Create`; `core:time` reads the clock of the system; `core:sync` waits on `Word_Wait`; the allocators of the language run on arenas. A path names an object of the private store or of a given handle, never a global tree. The arguments of a command line and the environment are empty. A write to the standard output is a line of the log of the process, which no process reads as input.

   **A ported module adapts to the system.** The system has no global path, no `PATH`, no environment and no ambient settings, and it gets none for a ported module. Each need of a module on another system has its form here:
   - a file or a folder (`HOME`, `TMPDIR`, a path): a handle that the start record gives, such as the private store;
   - a process to start (`PATH`): a module, named by its hash or by its name in the signed image;
   - a service (`DISPLAY`, a socket path): `connect` to the root service, which answers only with a grant;
   - a setting (`LANG`, `TZ`, a theme): the settings service and its read-only page, whose change comes as an event;
   - the parameters of a start (`argv`): the values of the context, which a border reads as their types;
   - a secret: a handle to an object or a grant, never a text.

   A port changes the code of the module where it reads one of these: a new constraint gives a new rule, and the module follows it. Each read of the module becomes explicit in its start record, typed and refusable, where an environment is inherited, untyped and invisible.

   A compatibility layer stays open. It would build, for a ported module only, an environment and arguments from its start record: `HOME` to its private store, `LANG` from the settings. It would never exist for the code of the system. It is decided when the first ports show what they read, from that measure and not before (`ROADMAP.md`, "Maybe").
2. **A `gt:platform` back end for modus**: the surface, the input, the fonts and the clipboard. Its `render` draws through the draw table, and through the WebGPU subset when it exists. What the draw table does not have yet (a blur, a blend mode, a transform) is drawn by `gt:paint` on the processor into a picture memory, which a picture record shows.
3. **The look of the system as a style of `gui_toolkit`.** The look of the `interface` package (the grid of points, the gradient of the cards, the folded gap, the colors of each concept, the scroll bar) is possible in `gui_toolkit` as an extended style, so a rich module can look like a module of the system. The style lives in `gui_toolkit`.

The `interface` package of the system stays, for the modules of `src/modules`. It is limited today: fixed sizes, one pass of layout. It grows by the steps of phase A. Whether the modules of the system later move to `gui_toolkit` is not decided: it needs a change of the rule of property 18 for the code of the system, and of the import rule of `src/`.

### `wren` by stages

- Its Odin code first.
- Lexbor, with a small library of C on the same target.
- Its Rust libraries, through a Rust target for modus, or replaced by Odin code.
- Wasmtime: see "I. WebAssembly as a code format".
- Drawing through the draw table, then the WebGPU subset when the GPU layers exist. WebGL in `wren` draws through the WebGPU subset; wgpu is not ported into the code of the system, and a port of it stays open as a module of `wren` itself.

**A fast path.** `wren` whole, in a Linux guest, through the driver domain of the GPU. It needs no port, and it waits for "Linux in a guest" ([foreign_systems.md](foreign_systems.md)).

## I. WebAssembly as a code format

WebAssembly becomes a portable and confined code format, after the port of `gui_toolkit` ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "15. Isolation inside a process"). A WebAssembly file is data named by its hash. An engine, a module of the system named by its hash, runs it inside one process, with only the imports that the process gives it. A WebAssembly file is not a module: the system keeps one module format (property 10).

Two ways are open, and the choice is open (`ROADMAP.md`, "Maybe"):

- **A compiler at run time.** The engine compiles the file to code of the processor, writes it, then runs it. The rule of property 11 holds: that code is confined to its process, in its own memory, never shared with another process and never kept as a module; the compiler is a module named by its hash. The kernel refuses a page that is Write and Execute together, so this way needs a design of an explicit switch of a page from Write to Execute. It waits for that design and for a measure against the interpreter.
- **An interpreter first.** The engine reads the file and runs it with no code written at run time. It needs no switch and no change of property 11. It is slower; it waits for a measure that says if it is enough for the modules of `gui_toolkit`.

## The contradictions, and how they were resolved

- **Property 18, "uses no existing toolkit".** The rule now binds the code of the system: the kernel, the boot program, `src/library` and the modules of `src/modules`. A rich module and a ported module can use `gui_toolkit`; each is an outside module, and each still draws through the draw table. The text of property 18 changed in this way.
- **The refused form of [../infrastructure/release_image.md](../infrastructure/release_image.md), "Import the package `signing` of gui_toolkit".** It stays refused, for its own reason: two packages named `ed25519` in one build. Its text now says that this is no rule against `gui_toolkit`.
- **The import rule of `src/`.** It does not change for a source of `src/`: `base:`, `modus:` and, for the kernel, `kernel:`; `gt:` and the core library are refused. The rule now says that it binds the code of the system only, and that an outside module imports `gt:` and the core library on the target modus (`AGENTS.md`, "Work"; [../infrastructure/repository_layout.md](../infrastructure/repository_layout.md), "The rules of the imports").
- **The objective, "no foreign interface", and property 19.** The target modus of the core library is a binding of the language over the concepts of the system, inside the process: no global tree of paths, no arguments, no environment, no stream that a process reads.
- **Property 11, code named by its hash.** Property 11 has a rule for code that a compiler writes at run time, and its field "Open" holds the choice between a compiler and an interpreter.
- **Property 7, "support for hardware that nobody on the project owns".** The forbid now binds the boot image. A device service that a principal grants from the disk is not support of the system, and property 7 has a rule for the device services.

## State

Built: the first measure of the standard of quality, a frame at 1920 × 1080 on the processor in three parts, by the process `processor_frame` in the measure run, with its four lines in the measure record and the check of their form. Sound through virtio-snd, the first timed stream ([timed_stream.md](timed_stream.md)).

Built: the three measures of the standard of quality on the path of the system (the time of a frame, of a key to the screen through the console, of the start of a window), the line of the quality profile at the start of the compositor, and the check of the form of their lines in the measure run. The first layer of the reference screen: the test machines at 1920 × 1080, at scale 1.

Built: the second layer of the reference screen, the desktop at the scale factor: the contract package `scale_factor` (the scale in eighths from 1 to 2, its border, the rounding of each edge and each place, the logical screen); the execution of a draw table at a scale, each kind of record; the setting `scale` in the page, the kept record, the window and the export of `settings`, 1.25 by default and each eighth from 1 to 2; each surface at the scale that the compositor names, made again at a change of the scale by the rescale of `display` and of the compositor, with its surface serial, its answers and the cut of a surface to its window; the scale word of the canvas of the drawing module; the compositor laid out in logical pixels; the windows that draw by hand through their picture; the pointer theme at 24, 30, 33 and 48, the next larger size at the other scales; the window pages counted at the largest scale, 2, and a stated window for each module with a window; the bound of a text size at 128 logical pixels, version 19 of the record; the places of the machine scenarios in logical pixels.

Built: SSE2 vector forms in `modus:graphics` for translucent solid span blends (`blend_span_simd`), horizontal gradients (`horizontal_gradient_span_simd`, `horizontal_gradient_with_alpha_span_simd`, `mix_with_alpha_span_simd`), and path coverage scanline accumulation and compositing (`path_coverage_span_simd`), wired into `blend_fill`, `gradient`, `gradient_with_alpha`, and draw-table path and gradient execution, verified bit-for-bit against their scalar references. Built: freestanding, zero-allocation PNG and baseline JPEG decoders in `modus:contract/image_decode` with CRC-32, zlib/DEFLATE (stored, fixed, and dynamic Huffman), Adler-32, strict safety bounds, zero pixel writes on refusal, and bit-for-bit SSE2 forms for PNG scanline filters, JPEG 8x8 integer 2D IDCT, and YCbCr-to-RGBA color conversion.

Built: the freestanding web network and light browser core packages: `modus:tls_tcp` (RFC 8446 TLS 1.3 over TCP record layer, SHA-256 HKDF key schedule, X25519 + Ed25519 client and server handshake over `TLS_AES_128_GCM_SHA256` and `TLS_CHACHA20_POLY1305_SHA256` reusing `modus:cryptography_primitives`, strict downgrade and sequence-exhaustion refusals); `modus:contract/http_client` (strict HTTP/1.1 request encoder and response parser with request/response smuggling and chunked-encoding overflow refusals, HTTP/3 framing bridge, and per-principal cookie jar and HTTP response cache, each principal in a part of the memory of its own, bounded by a share that the caller fixes); `modus:contract/html_css` (iterative fixed-pool WHATWG-subset HTML tokenizer and origin-isolated DOM tree builder in memory of the caller that grows, bounded at depth 64, CSS selector cascade and inheritance resolver, block/inline/flex layout engine, and canonical `draw_record` primitive emitter).

Built: the HTML parser after the insertion modes of the WHATWG, with the adoption agency algorithm and the tables ("The HTML parser"); the CSS engine with combinators, the specificity of the standard, borders, text alignment and tables ("The CSS engine"); the fetch policy of the browser ("The fetch of a page"); the origin worker and its messages ("The origin worker").

Left: the scroll of a window whose least size does not fit the work area, and the windows that draw by hand moved to the elements ("What is left"); the measures of the GPU profile, which wait for the GPU path; a key to the screen in a window other than the console, which must name its serial; a host measure as a second number. The draw table, phase C, is the next work of `ROADMAP.md`; arenas, windows that change size and the clipboard are built.
