# From the desktop of today to a light web browser

The desktop of today has windows of a fixed size, programs with fixed tables, a draw table on the processor, and a network stack with TCP and QUIC. This file records the path from there to a light web browser, and to the run of two programs of other projects in Odin: `gui_toolkit`, a toolkit of immediate-mode interfaces, and `wren`, a web browser built on it. It gives each phase, what it depends on, and why the phases come in this order, with the standard of quality that every phase keeps. The entries of the work are in `ROADMAP.md`; this file holds the reasons and the order.

## The constraints

- Each phase adds a capability to a system that works. No phase replaces a part that works with a part that does not work yet.
- Each phase keeps the properties of [`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md). The section "The contradictions, and how they were resolved" names each place where the path pulled against a property, and the text that changed.
- A browser reads hostile data from the network: HTML, CSS, pictures, fonts. Each reader of such data is a confined program or module with fuzz targets ([../infrastructure/fuzzing.md](../infrastructure/fuzzing.md)).
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
- **Each measure has one sentence on the log**, which is its identity in the measure record: the time of a frame, from the first record that the compositor reads to the flip; the time from the interrupt of a key to the flip that shows it; the time from `Program_Start` to the first frame of the window.

### The thresholds of the processor profile

| Threshold | Value |
|---|---|
| The resolution | 1920 × 1080, the reference screen: the profile lowers nothing |
| The rate | 120 Hz, as the GPU profile |
| The time of a frame | Less than 8.3 ms, as the GPU profile; the first measure gives 2.0 ms for the heaviest part |
| The effects that the profile keeps | Alpha and sharp shadows; a blur waits for its own measure |

Each value comes from the first measure below, on the test machine (one processor of the host under KVM, a host load of about 19): a clear and a present, median 268.8 us; a full frame of the compositor with 4 windows, median 953.9 us; a frame in its damage, median 86.2 us; a draw table of 339 records that fills the screen, with alpha, median 2043.0 us (`processor_frame: measure:` lines of the measure record). The heaviest part takes a quarter of the 8.3 ms of a frame at 120 Hz, so the processor profile keeps the resolution and the rate of the GPU profile. The two profiles then differ in the effects only: a blur costs a pass over each pixel under it, which no measure gives yet, so it stays out of the processor profile until a measure says it fits. A change that brings a part past 8.3 ms is a regression to read to its cause, and the table changes only from a new measure.

### The three measures on the path of the system

The compositor measures all three, with `system.nanoseconds()`, the clock of the system that the kernel keeps for each program: never a clock of the host. Each measure is one sentence of the log, and the tool keeps it in the measure record; no test reads a time.

| Measure | From | To | Its line |
|---|---|---|---|
| The time of a frame | The read of the first record (of the root service, of the input service or of a window) of a turn that left damage, when no earlier record waits for a frame | The end of the copy into the screen page and of its page flip | Each 16 keys of the next measure, over the last 64 such frames |
| The time of a key to the screen | The read of the byte of the key by the input service, which writes the time in its record | The flip of the frame that draws the Present that names the key | Each 16 keys that a window named |
| The start of a window | The call of `system.program_start` by the root service, which loads the module and makes `Program_Start` | The flip of the first frame that draws the first Present of the window | One line for each window |

```
compositor: measure: the time of a frame, from the first record that the compositor reads to the flip: least <t> us, median <t> us, over <n> frames
compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it: least <t> us, median <t> us, over <n> keys
compositor: measure: the start of the window <name>, from Program_Start to its first frame: <t> us
```

**The tie of a key to its effect.** A frame shows a key only when the program says so. The path:

1. The input service writes the time of the system in the record of the key.
2. The compositor gives each key with a character a serial, sends it in the event `Key`, and keeps the serial, the window and the time in a table of 32 keys.
3. The console marks the serial of each key that it puts in its edit line, and gives the newest one with the record `Edit` to its terminal.
4. The terminal gives the serial of the edit line that its picture shows to the window layer (`display.key_shown`). Its next `Present` names it.
5. The compositor ties each key of that window up to that serial, and measures each one at the flip of the frame that draws that Present.

So the key is measured to the frame that shows its character, not to a frame that only came after it. One case ties late: a key that the console takes with no change of its line (a character of the history search) stays sent, and the next edit of the line ties it. Its time is then too long, never too short. A window that names no serial ties none. A serial that the compositor did not send to that window ties nothing. A key that stays untied leaves the table when 32 newer keys take its place: the table holds measures, not records of input.

**The start of a window.** The root service writes the time before it calls `system.program_start`, and sends it to the compositor after the start, in the control record `Client_Started`, for the ring of the window. The time holds the load of the module, its hash and `Program_Start`, as the principal waits for them. A window whose first frame comes before the record has no line.

**The profile at the start.** The compositor writes one line at its start: `compositor: the quality profile is the processor profile: the system drives no GPU device`. The system drives no GPU today, so the decision is one pure procedure of the private part `quality` of the compositor, which the GPU path changes.

**The checks.** The measure run waits for the line of the profile, the start of the window `locks`, and a line of the frames and of the keys after the console takes 16 keys. After the machine, the tool checks their form only, as for `processor_frame`.

**The refused forms.**

- **The first flip after the key.** A frame of a clock, or of a window that ignores the key, would count as its effect, and the number would be too small.
- **The time in the event, sent back by the program.** A program would then write the time that the compositor reads. With a serial, the compositor keeps the time.
- **A line for each frame and each key.** The log would hold thousands of lines in a test; a line for each 16 keys holds the least and the median.
- **The time of the `Client_Add` record.** It goes before the budget and the mappings are made, so it is not the start that the design names. A new control record says when the start ended.
- **The profile in the root service.** The compositor owns the screen, and it is the part that a GPU changes first.

### The first measure: a frame at 1920 × 1080 on the processor

**Its purpose.** It gives the numbers from which the thresholds above come: what a frame of the desktop at the reference screen costs on the processor, with no GPU, split into the parts that a later change moves one by one.

**The three parts.** Each part is drawn 21 times, after one frame that is not counted: that frame pays the pages on first use of each canvas.

1. **A clear and a present.** `graphics.clear` of a canvas of 1920 × 1080, then `graphics.copy` of it into a second canvas, as the compositor copies its frame into a screen page. It writes 8.3 MB, then reads and writes 8.3 MB: the bound of the memory bandwidth. No frame of this size on this path costs less.
2. **A frame of the compositor with four windows**, of 1280 × 800, 960 × 640, 800 × 640 and 640 × 480, in the phases of the compositor ([`docs/SIMD.md`](../../../docs/SIMD.md), "4. The compositor"): the background copied into the frame, one call of the drawing module for each window (the records of its frame and the Picture record of its surface) and one for the bar, then the copy of the frame into a screen page. One line for a full frame. One line for a frame in its damage: a rectangle of 400 × 300 of the surface of the front window and the clock of the bar, the damage of one `Present` and of one second of the bar.
3. **A draw table that fills the screen** with the records of a desktop: twelve cards, each with a gradient, a title and a caption in the interface font, ten lines of a label in the interface font and a value in the font of the cells, a bar, an opaque picture, a picture with alpha and a rectangle with alpha. One call of the drawing module draws it into a canvas of 1920 × 1080, with the fill of the background. The table is built once: the time is its execution, which a GPU back end of the draw table replaces.

**Where it runs: a program on the machine.** The program `processor_frame` runs in the measure run of `modustool measure`, after the other measures of that run, when no other program draws. It makes its canvases and its surfaces with its own budget, and calls the code that the compositor calls: `graphics.clear`, `graphics.copy` (that is `copy_bytes_without_overlap`), and the drawing module through `interface.draw_part_through_module`. So the number is a number of the code of the system, built as the system is, under its kernel, on the machine of the other measures. The test machine keeps its screen of 1024 × 768: the move of the screen is the entry "The reference screen", and the measure comes before it, to give the thresholds.

**What it does not measure.** The procedures of the frame of the compositor (`screen_build`, `frame_records`, `draw_areas`) are in the compositor module, and no other module imports them. The program builds the records of each window in the form of the compositor (the gradients of the title bar, the borders, the title, the close button) and runs the same phases. It leaves out the pointer, a blend of at most 48 × 48 pixels, the read of the rings, the page flip, and the swap of red and blue of a screen in that order. When the test machine shows 1920 × 1080, the line "compositor: a full frame of 1920x1080 with ..." of the compositor itself is the number of the compositor, and part 2 is read against it.

**How it reports.** One line for each part, with the least of the 21 frames and their median, in microseconds with one decimal, and the frames in one second that the median gives:

```
processor_frame: measure: a clear and a present of 1920x1080: least <t> us, median <t> us, <n> frames in one second at the median, over 21 frames
```

The least is the cost when the host did not stop the processor during the frame. The median holds the noise of the host. The chart of the measure history follows the least ([measure_history.md](measure_history.md)). The frames in one second come from the median, because a screen shows each frame and not only the fastest one. The line of the draw table names its count of records of each kind before its times.

**No time is a condition.** The scenario of the measure run waits for each line and for the last line of the program. Then the tool reads the four lines and checks their form only: each part ran once, each number is a number, the least is not above the median, the frames in one second agree with the median, and the count of frames is not 0. The program checks its pixels: after each part a pixel that the part writes has its color, and no call of the drawing module was refused.

**The refused forms.**

- **The measure inside the compositor, at its start**, as its measures of the bar and of a title bar. Three canvases of 1920 × 1080 and the four surfaces are about 8 500 pages. The budget of the compositor would hold them at each start of each machine, for a run that only measures. The compositor already prints its full frame at the size of its screen.
- **The frame of the compositor in a support package** that the compositor and the program both import. It measures the code of the compositor itself, but it moves the loop of the compositor for one measure. The reference screen gives the number of the compositor itself with no move.
- **A host benchmark alone.** A host test has another runtime of memory, no kernel, no page on first use and no QEMU: its number is a second number, never the only one. It is not built.
- **A rate over one second.** A count of 21 frames needs no duration, and runs the same work on a slow host. The frames in one second are computed from the median.
- **Large pages for the canvases.** The surfaces of today have 4 KiB pages ("Large pages for large buffers" below). The measure takes the pages of today; a measure with both forms is a later step.

**The hazards.** A measure is valid when the load of the host is under 8 ([`docs/SIMD.md`](../../../docs/SIMD.md), "6. How to measure on the machine"). The measure record says the host of the run. A change of the host is not a change of the system.

## The reference screen

The reference screen is 1920 × 1080, with a scale factor from 1.25 to 2, in place of 1024 × 768 at scale 1. A layout is made in logical pixels, and the scale factor turns them into pixels of the screen. The change moves:

- **The screenshots.** The test machines show 1920 × 1080; each picture of `docs/screenshots`, of the site gallery (`SITE_SCREEN_PICTURE_WIDTH`) and of the news is made again at that size. The standard VGA must hold two screen pages of 8.3 MB each ([../infrastructure/whole_frame.md](../infrastructure/whole_frame.md)).
- **The sizes of the windows.** Each window states its size in logical pixels; the stated budget of each module grows with its window pages ([module_budget_request.md](module_budget_request.md)).
- **The grid of 8.** The grid stays 8 logical pixels. At scale 1.25 it is 10 pixels of the screen, at 1.5 it is 12: places stay on whole pixels of the screen only at the scales that are a multiple of 1/8.
- **The fonts.** The glyph caches exist at the scales 1, 2 and 3. Scales of 1.25, 1.5 and 1.75 need caches at those sizes, or a draw from the outlines at each size; the font of the cells needs a cell of 10 × 20 at 1.25. Spleen, the fallback font of bitmaps, has whole scales only.
- **The pointers.** The pointer theme has the sizes 24 and 48; a scale of 1.25 needs 30, or the nearest size.
- **The measures.** The measure "a full frame of 1024x768" is a sentence of the log, so its series ends and the measure at 1920 × 1080 starts a new one.

No code changes with this file. The work is its entry in `ROADMAP.md`.

## The order and its reasons

| Phase | What it gives | Depends on |
|---|---|---|
| A. The desktop foundations | Data with no known bound, the measure of a frame on the processor, windows that change size, a resolution, a window manager, the clipboard, sound | Nothing new |
| B. Data in and out | Documents, drag and drop, pictures, notifications, buffers that pass from program to program with no copy | A |
| C. The draw table | Alpha, paths, clips, one text kind | Nothing new; it runs beside A and B |
| D. The web network | TLS over TCP, HTTP, cookies and a cache | A (arenas for the answers) |
| E. A light browser | HTML, a subset of CSS, links, forms, one program for each origin | A, B, C, D |
| F. The GPU and 3D | virtio-gpu, the WebGPU subset, its back end on the processor | C |
| G. A real machine | USB, NVMe, device services for real devices | A for the display modes |
| H. `gui_toolkit` and `wren` | The toolkit of rich programs, then the browser `wren` | A, B, C, G for `wren` on a real machine |
| I. WebAssembly | A portable and confined program format | H |

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
- **I comes after H** because the engine of WebAssembly is a rich program, and its first users are the programs of `gui_toolkit`.

## SIMD on the hot paths

The hot paths of these phases have a vector form after the rules of [`docs/SIMD.md`](../../../docs/SIMD.md), "1. The rule of the same bytes" and "2. One form: SSE2": the vector form gives the bytes of the scalar form, a host test compares the two, and a measure decides each form. `docs/SIMD.md` holds this design; no file of `src/md` repeats it.

- **The rasterizer**: the coverage of a path of the draw table, and the triangles of the processor back end of the WebGPU subset with its shaders.
- **The compositor**: the horizontal gradient, which is scalar today ([`docs/SIMD.md`](../../../docs/SIMD.md), "7. Limits"), and the translucent records over the windows.
- **The blend** in linear light of a translucent rectangle, of an antialiased edge and of a picture with alpha, as the blend of a glyph has today.
- **The picture decoders**: the filters of PNG, the inverse transform and the color conversion of JPEG.

## A. The desktop foundations

- **Memory with no known bound.** Arenas paid by the budget: [memory_without_a_bound.md](memory_without_a_bound.md).
- **The measure of a frame at 1920 × 1080 on the processor.** See "The standard of quality".
- **Layout with intrinsic sizes.** The interface package measures each element first, then places it: a label is as wide as its text, a column as wide as its widest child. Today a window places its elements at sizes that its code states. A window that changes size needs elements that know their size.
- **Windows that change size.** The principal drags an edge of a window that its program declared resizable. The compositor sends the event `Resized`; the program makes the surface of the new size, paid by its budget, and draws its next frame into it; the compositor shows the old one until that frame comes. A budget that cannot pay keeps the old size, with one line. A program never draws into a surface that the compositor resized under it. The program makes the surface, and not the compositor, because whoever creates an object pays for it: [window_resize.md](window_resize.md).
- **A resolution that the principal chooses.** The compositor sets a mode of the display, then a scale factor for the interface, from 1.25 to 2 on the reference screen.
- **A window manager.** Windows float, with snap to the edges and to the halves of the screen, maximize and minimize, and global shortcuts that the compositor keeps. Workspaces come next. Tiling may come later as an option, never as the form of the desktop. One key combination always goes to the system (property 20, line 8).
- **The clipboard.** A copy gives the compositor a read-only handle to a memory object of the program that copies. A paste of the principal gives the program that pastes a read-only handle to that object, at that paste only (property 20, line 5). No program reads the clipboard when the principal does not paste: [clipboard.md](clipboard.md).
- **Sound** through virtio-snd: a device service, and the class protocol of a timed stream, whose records carry the time at which their samples must play.

### The look

The desktop of the system keeps rectangular forms, sober by choice: sharp shadows, short animations that say a change of state, transparency only where it informs, and a blur later, with the GPU ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "2. Forms"). This is the look of the desktop and of its elements. The draw table puts no limit of look on what a program draws ([../api/draw_table.md](../api/draw_table.md), "The limits of the format: cost, never look").

## B. Data in and out

- **The document service with the picker.** Already in `ROADMAP.md`, "A document service with a picker". A browser saves a page and reads a file of the principal through it.
- **Drag and drop** gives the program under the pointer a read-only handle to what was dropped, at the drop only: a grant that follows from an action ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "21. Principals: who acts, without users", the forms of concession).
- **Picture decoders.** PNG first, then JPEG. Each decoder is a module that runs in a call host with no handle but the bytes that it reads and the picture that it writes, and each has fuzz targets. A wrong file stops the call host, never the program that asked. Their hot loops have SSE2 forms (see "SIMD on the hot paths").
- **Notifications.** A program asks the compositor to show a short text. The compositor draws it in a place that a program cannot imitate (property 20, line 8), and a notification never takes the focus.
- **Buffers that pass from hand to hand with no copy.** See the next section.

### Chains with no copy across several programs

A browser moves large buffers through several programs: the bytes of a picture arrive from the network, a decoder makes pixels of them, and the compositor shows the pixels. Each copy of a picture of 8 MiB costs time and memory. The aim: a buffer passes from hand to hand through successive lends of its memory handle, with no copy.

What exists today:

- **The lend of a handle for one call** (`system.lend`, `system.lend_end`; [`docs/glossary/access.md`](../../../docs/glossary/access.md), "Lent handle"). The caller makes a copy of its handle with the rights of the description of the export, gives the callee a handle from that copy, and revokes the copy after the call. A table parameter in a memory object is lent with the rights of its direction, so a callee that only reads a table gets no Write. A revocation reaches each handle and each mapping that came from the copy, through each chain of gifts ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "2. Sandbox by default", the revocation).
- **The datagram region with no copy on send** ([../infrastructure/network_data_path.md](../infrastructure/network_data_path.md), "The send with no copy"). The device reads the data to send from the datagram region of the program; the network service copies and checks 8 bytes of the header only. On receive, the network service still copies each datagram once into the region of the program, and that copy is irreducible with one receive queue.
- **The surfaces of the windows.** A program makes the memory of its surface and gives the compositor a handle with Read only (`display.open`). The compositor reads the pixels in place, with no copy through a ring.

What is missing for a chain:

- **A lend that passes on to a third program.** A lent handle has only the rights of the description, with no Give, so a callee cannot lend the buffer on: the decoder cannot pass the pixels that it wrote to the compositor. The chain needs a description that lets a callee lend a handle on, with at most the rights that it received, and a `lend_end` of the first hand that ends each later hand too. The kernel already revokes through the chain; the form of the description and of the library is what is missing.
- **The read-only narrowing at each hand.** Each hand must pass the buffer on with Read only, and the hand before must lose its Write before the next hand reads, or the next hand must copy before it checks (property 6, "copy, then validate"). Today a program cannot take Write away from an object that another program maps: `Memory_Protect` acts only on an object that this program alone names. The missing part is a narrowing of an object for each holder: after it, no holder writes the object, and a reader can check the bytes in place.

The design of these two parts is not written. It needs a new intent file before any code.

### Large pages for large buffers

A large page maps 2 MiB with one entry of the page table, so a program that reads a large buffer misses the translation cache less ([`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md), "Large pages").

What exists today:

- The flag `Large_Pages` of `Memory_Create`: the object is contiguous, its frames are one run aligned on 2 MiB, and its count of pages is a multiple of 512, or `Memory_Create` refuses it. `Memory_Map` uses a large page for each aligned 2 MiB of the mapping.
- A protection change must cover the whole mapping, and a decommit of such an object is refused, because it is contiguous.
- `Uncommitted` with any other flag is refused, so an uncommitted object never has large pages.
- The program `address_space` tests the flag and measures random reads over 64 MiB with large pages and with 4 KiB pages.

What is missing:

- **The surfaces.** `display.open` makes each surface with 4 KiB pages. A surface of 1920 × 1080 with two pictures is 16 MiB, eight large pages.
- **The decoded pictures and the frames of a video.** No program asks for large pages for them.
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
- **One program for each origin.** Each origin runs in its own program, with the network grant of that origin only (property 20, line 3). A page of one origin reads nothing of another. The program of the window holds the address bar and starts the program of each origin.
- **JavaScript** is a separate decision, in `ROADMAP.md`, "Maybe".

## F. 3D

The GPU path and the WebGPU of the system are in [gpu_access.md](gpu_access.md). In order:

1. **virtio-gpu under QEMU for the 2D scanout**: the compositor shows its screen through the virtual GPU in place of the standard VGA.
2. **Vulkan to the host through Venus.** The commands of the system cross the virtual GPU in the serialization of Venus.
3. **The WebGPU subset on it**: only what the draw table, the compositor and 3D need, with WGSL compiled to SPIR-V by the build. The draw table is drawn through it ("Acceleration by the virtual GPU of the test machine" in `ROADMAP.md`).
4. **A real GPU later**, through the Linux driver domain, with the same serialization ("Acceleration by a real GPU" in `ROADMAP.md`).

### 3D on the processor: a back end of the same subset

A program that draws 3D on a machine with no GPU uses the processor back end of the WebGPU subset. It has the same objects as the GPU back end: buffers, pipelines, command lists and draw calls. A program writes the same code for the processor and for the GPU, and only the back end changes.

- **Its shaders are a small fixed set**, written in Odin with SIMD: a vertex transform, a flat color, a texture, a light of one direction. A pipeline names one of them. A shader of WGSL that the set does not hold is refused by this back end, with its name.
- **It has no compiler of WGSL for the processor.** Such a compiler is larger than the whole 2D drawing, and property 18 refuses it.
- **Its rasterizer** draws triangles with a depth buffer into a picture memory of the program, and a picture record of the draw table shows it, so the draw table stays the one 2D interface.
- **It must not become a separate drawer of 3D.** Each feature of the processor back end is a feature of the subset that the GPU back end has too. A feature that only the processor back end has is refused: it is a second 3D interface, and a program that uses it does not move to the GPU.

## G. A real machine

- **USB**: a device service of the xHCI controller, then the USB keyboard and the USB pointer.
- **NVMe disks**, served through the block ring.
- **The display of the firmware**: the compositor already shows the framebuffer of the firmware; the page flip on a real display is in `ROADMAP.md`, "A whole frame on the display of a real machine".
- **Device services for real devices**, their trust and their restart: [device_services.md](device_services.md).

## H. `gui_toolkit` and `wren`

`gui_toolkit` is an immediate-mode toolkit in Odin. On Linux it draws through WebGPU on Vulkan, with a Rust library for text; its packages `platform`, `render` and `font` meet the operating system, and most of the others are pure Odin. `wren` is a web browser in Odin on `gui_toolkit`: Lexbor in C for HTML, Rust libraries for the network, the pictures and the text, and Wasmtime as its one engine of execution.

### The toolkit of rich programs

`gui_toolkit` is ported to the system and becomes the toolkit of rich programs: a program whose interface needs more than the elements of the `interface` package (an editor, a browser, a program of a third party). A rich program is an outside module ([../infrastructure/third_party_module.md](../infrastructure/third_party_module.md)), never a source of `src/`.

1. **A target "modus" for the core library of Odin**, for outside modules only. `core:os` reads and writes the objects of the private store and of the handles that the program was given; `core:thread` runs on `Thread_Create`; `core:time` reads the clock of the system; `core:sync` waits on `Word_Wait`; the allocators of the language run on arenas. A path names an object of the private store or of a given handle, never a global tree. The arguments of a command line and the environment are empty. A write to the standard output is a line of the log of the program, which no program reads as input.
2. **A `gt:platform` back end for modus**: the surface, the input, the fonts and the clipboard. Its `render` draws through the draw table, and through the WebGPU subset when it exists. What the draw table does not have yet (a blur, a blend mode, a transform) is drawn by `gt:paint` on the processor into a picture memory, which a picture record shows.
3. **The look of the system as a style of `gui_toolkit`.** The look of the `interface` package (the grid of points, the gradient of the cards, the folded gap, the colors of each concept, the scroll bar) is possible in `gui_toolkit` as an extended style, so a rich program can look like a program of the system. The style lives in `gui_toolkit`.

The `interface` package of the system stays, for the programs of `src/modules`. It is limited today: fixed sizes, one pass of layout. It grows by the steps of phase A. Whether the programs of the system later move to `gui_toolkit` is not decided: it needs a change of the rule of property 18 for the code of the system, and of the import rule of `src/`.

### `wren` by stages

- Its Odin code first.
- Lexbor, with a small library of C on the same target.
- Its Rust libraries, through a Rust target for modus, or replaced by Odin code.
- Wasmtime: see "I. WebAssembly as a program format".
- Drawing through the draw table, then the WebGPU subset when the GPU layers exist. WebGL in `wren` draws through the WebGPU subset; wgpu is not ported into the code of the system, and a port of it stays open as a module of `wren` itself.

**A fast path.** `wren` whole, in a Linux guest, through the driver domain of the GPU. It needs no port, and it waits for "Linux in a guest" ([foreign_systems.md](foreign_systems.md)).

## I. WebAssembly as a program format

WebAssembly becomes a portable and confined program format, after the port of `gui_toolkit` ([`docs/PROPERTIES.md`](../../../docs/PROPERTIES.md), "15. Isolation inside a program"). A WebAssembly file is data named by its hash. An engine, a module of the system named by its hash, runs it inside one program, with only the imports that the program gives it. A WebAssembly file is not a module: the system keeps one module format (property 10).

Two ways are open, and the choice is open (`ROADMAP.md`, "Maybe"):

- **A compiler at run time.** The engine compiles the file to code of the processor, writes it, then runs it. The rule of property 11 holds: that code is confined to its program, in its own memory, never shared with another program and never kept as a module; the compiler is a module named by its hash. The kernel refuses a page that is Write and Execute together, so this way needs a design of an explicit switch of a page from Write to Execute. It waits for that design and for a measure against the interpreter.
- **An interpreter first.** The engine reads the file and runs it with no code written at run time. It needs no switch and no change of property 11. It is slower; it waits for a measure that says if it is enough for the programs of `gui_toolkit`.

## The contradictions, and how they were resolved

- **Property 18, "uses no existing toolkit".** The rule now binds the code of the system: the kernel, the boot program, `src/library` and the modules of `src/modules`. A rich program and a ported program can use `gui_toolkit`; each is an outside module, and each still draws through the draw table. The text of property 18 changed in this way.
- **The refused form of [../infrastructure/release_image.md](../infrastructure/release_image.md), "Import the package `signing` of gui_toolkit".** It stays refused, for its own reason: two packages named `ed25519` in one build. Its text now says that this is no rule against `gui_toolkit`.
- **The import rule of `src/`.** It does not change for a source of `src/`: `base:`, `modus:` and, for the kernel, `kernel:`; `gt:` and the core library are refused. The rule now says that it binds the code of the system only, and that an outside module imports `gt:` and the core library on the target modus (`AGENTS.md`, "Work"; [../infrastructure/repository_layout.md](../infrastructure/repository_layout.md), "The rules of the imports").
- **The objective, "no foreign interface", and property 19.** The target modus of the core library is a binding of the language over the concepts of the system, inside the program: no global tree of paths, no arguments, no environment, no stream that a program reads.
- **Property 11, code named by its hash.** Property 11 has a rule for code that a compiler writes at run time, and its field "Open" holds the choice between a compiler and an interpreter.
- **Property 7, "support for hardware that nobody on the project owns".** The forbid now binds the boot image. A device service that a principal grants from the disk is not support of the system, and property 7 has a rule for the device services.

## State

Built: the first measure of the standard of quality, a frame at 1920 × 1080 on the processor in three parts, by the program `processor_frame` in the measure run, with its four lines in the measure record and the check of their form.

Built: the three measures of the standard of quality on the path of the system (the time of a frame, of a key to the screen through the console, of the start of a window), the line of the quality profile at the start of the compositor, and the check of the form of their lines in the measure run.

Left: the measures of the GPU profile, which wait for the GPU path; a key to the screen in a window other than the console, which must name its serial; a host measure as a second number. The draw table, phase C, is the next work of `ROADMAP.md`; arenas, windows that change size, the clipboard and sound come next.
