# Changelog

All the changes of the system that a reader notices. The format is [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/).

The project has steps, not separate releases. The merge of step N on `master` is the release `0.N.0`. A correction between two steps is `0.N.1`, `0.N.2`. The release `0.0.0` is the first milestone, before step 1. A heading gives the release time in UTC; an old heading whose time no record holds gives its day alone. Each release from `modustool ship` has the signed release tag `v<number>`, and the links at the end of this file point to the tags. The number of the newest release is `RELEASE_NUMBER` in `src/library/contract/release/release.odin`; `modustool release_number` prints it.

What is not in a release yet is in `changelog.d/`, one fragment for each change. `modustool ship` writes a release from the fragments, commits it, tags it and pushes it. Nobody edits this file by hand.

## [0.96.0] - 2026-11-19 20:51

### Added

- **Paths in the draw record.** Version 16 of the draw record has a `Path` kind: lines and quadratic curves from points in the text table, filled by the nonzero rule and stroked with butt ends and bevel joins, each pixel by the exact part of it that the shape covers, the same pixels in each damage rectangle. A line is now the stroke of a path: across or down it keeps its pixels, at an angle it has antialiased edges, as in the rings of `rings` and the folded gaps of `inspect`, and the kind `Line` and its word 10 leave the format. The window of `rings` draws an arrow on each ring from an outline. The exports of the drawing module are `damage_of_draw_table_16` and `execute_draw_table_in_rectangles_16`.
- **A start policy from the disk.** On a machine whose machine key the TPM seals with no passphrase, `start_policy_choose(nickname, hash)` in the console of principal 0 makes a module of the store `module_files` the start policy of the next start, and `start_policy_default()` ends the choice. At that start the root service reads the choice before any start policy runs, checks the hash of the file, and starts it with the start grant `Start_Policy` only; a file that is absent, has another hash or fails gives way to the rescue start policy. Each start policy, the default one and the rescue too, is measured into PCR 12 before it runs, and the log gives the value of PCR 12, so an attestation sees which one ran; the seal of the machine key still reads PCR 7 and PCR 11 only, so a new choice changes no unseal. A machine with a machine passphrase refuses the choice.
- **The films of the tutorial**: `modustool film desktop`, `film console` and `film program` film the desktop, the console and the start of the module `plasma`, and each film now writes its film cues to `build/films/<name>.cues`: the time of each named state of the film, so that the captions of the tutorial appear when their state is on the screen.
- **A picture of the rescue start policy**: the guide of the trusted boot and the gallery show the console of a machine started with the key R, with its table of the processes of the rescue list.
- **The pipe operator `|>` of the console**: `a |> f(b)` is `f(a, b)`, so `processes() |> where(name = "server") |> columns("name slot")` reads in the order in which its calls run. The operator adds no meaning: the line checks and runs as the same line with calls in calls. A fault of the operator (no value on its left, no call on its right, a command that takes no argument or has 12 already, a `|` alone) fails the line before any call runs. After `|>`, the completion list offers the commands whose first parameter takes the value on the left.
- **The window of `monitor` shows the last minute and colors its bars by intensity**: three sample graphs over the grid of points of the desktop show the memory in use, the processor time of all the processes and the kernel entries in one second for the last 120 samples, and the memory bar and the processor bar of each process take the color of their intensity step: the color of what they measure, the warning color from 60 %, and the new color token `near_limit` from 85 %. The window is 520 × 640.
- **A field of a record states its kind, the second step of log facts**: a record description takes a hexadecimal Integer (`value_kinds.Hexadecimal_32` and the other sizes), a status of a contract enum (`operation.Status`, `operation.Log_Level`), a module name (`value_kinds.Module_Name_Field`) and a hash (`value_kinds.Hash_Field`, a field of the type Bytes), in the bytes of `module.Field` that were reserved, so the format version stays. The console and the palette draw a hexadecimal Integer as `0x` and two digits for each byte, a status by the name of its member in the color of a status, a module name in the color of a module and a hash in hexadecimal in the color of a version; `where`, `sort` and `join` refuse a hash field. Each compile of a package of `src/` now accepts the attribute `log_fact` of a fact type (`-custom-attribute:log_fact`).
- **A process writes a log fact**: `system.log_fact(.Info, Probe{...})` writes the values of a record type whose attribute `log_fact` holds its sentence, in one record of the log with no text; the module file holds the sentence and the record in its new table `Facts` (format version 3), the serial port gets the raw bytes of the fact, and the tool writes its sentence for the machine tests. The build refuses a fact type with padding, a handle, more than 144 bytes, a sentence that leaves a field out, or a key that the code does not hold, and `Log` refuses each wrong fact with its error record.
- **The remote display.** The service `remote_display` sends the screen to a viewer on another machine over QUIC, as lossless screen pieces of the damage of the compositor, one viewer frame in flight, with no pointer in the pixels; a viewer allowed for the input sends keys and a pointer, which take the path of the keys. A principal allows a key with `remote_display_allow(key, "view")` or `"view_and_input"`, `remote_disallow` ends the session at once, and the bar shows the mark `viewer` while a viewer is connected. A key sees the screen only while the session of its principal is in front: a key of principal 0 sees nothing while a named principal is unlocked. A key allowed for the view alone makes no call of `remote`. The test part `remote_display` uses the peer of the tool as the viewer and compares the screen that it rebuilds with a picture of QEMU.
- **The readers write the sentence of a log fact**: the console, under a line, and the window of the log show each log fact as the sentence of its fact template, each value in the color of its kind, from the module file of the boot image that the fact names, and its raw form when the image has no such module. `log.records(0) |> facts(log_reader.Fact_Probe)` gives the fields of one fact type as the columns of a table; the console refuses, before any call, a fact name that no module of the image writes, and completes the fact names. A row of `log.records` gives its level and its record form as members of `Log_Level` and `Log_Record_Form`, and `log.fact_records` gives the 144 value bytes of each fact. The console, the window and the tool write a sentence with one procedure, `module.fact_sentence_write`; the tool now writes the unit of a size or a time. The window of the log has the grant `image`.
- **A machine test waits for a log fact by its fields**: the step `Fact` names a fact type, a process and a condition on one field, as `condition = "value = 42"`, and passes at the first line of that fact whose values pass the condition, whatever its sentence. Before a machine starts, the tool checks each such step against the fact tables of the build and stops with one line for each fault: no process, a fact type that no module writes, a field that the fact type lacks, an operator that the field does not take, a value of another kind or out of the range of its field. The condition has the form of the condition of `where` in the console, and the same package reads it. The main test reads the fact of `log_reader` this way, and with `facts()` in the console.

### Changed

- **The tool in packages.** The tool `modustool` is one command over eight packages, one folder each under `tools/modustool`: `foundation`, `resources`, `build`, `checks`, `fuzz`, `similarity`, `machine` and `site`. A developer reads one concern in one folder, and `modustool check` runs the host tests of each package in its own process. The commands and their arguments do not change.
- **The test machines show 1920 × 1080.** The boot program asks the firmware for the mode of the reference screen, so the desktop, the screenshots and the pictures of the site gallery are 1920 × 1080 in place of 1024 × 768, at scale 1: the windows keep their sizes. The compositor flips between two screen pages of 8.3 MB in the 16 MiB of the standard VGA, and its budget grows by 2526 pages for its frame, its background and their page tables. A firmware with no mode of 1920 × 1080 gets the largest mode inside it, and the boot program writes one line with the mode that it keeps; a screen that the budget of the compositor cannot pay stops the compositor with one line, and the rest of the system runs. The measure of a full frame of the compositor has a new sentence that names the size, so its chart starts again at the reference screen. The scale factor from 1.25 to 2 is the next step.
- **The steps of the boot display in their order.** The boot display lists the boot image before the kernel module, as the boot program checks them, and the boot program checks each file of the boot image before the kernel: a failure of the kernel shows the boot image as done, which it is.
- **A start policy in place of the fixed list of the root service.** The root service now starts one process, the start policy, which reads the start list of the boot image in its order and says when the machine is usable; a start policy that stops before, or that says nothing within the hang bound, gives way to the rescue start policy, which starts the input, the compositor, the console and `remote`, so a failed console no longer stops the machine. The key R held at the start, or the boot entry "modus (rescue)" that the boot program writes in the boot menu of the firmware, starts the rescue at that start, and the build refuses a start list that names no module of its image.
- **A boot display at the scale of the screen.** The boot display takes the largest scale among 1, 1.5, 2 and 4 whose panel fits the screen with a margin of 8 pixels, keeps its proportions and stands in the middle of the screen: 1.5 on the screen of 1920 × 1080, a panel of 1464 × 1062 in place of 976 × 708. Each scale is a size of Spleen, the font of the display, as the console of Linux takes a font by the resolution: 8x16, 12x24, 16x32 and 32x64, so each letter fills its cell. Each card, bar, gap, mark and text is drawn at that scale, each edge rounded once to the nearest pixel. The boot program, the root service and the process `boot` draw every text of the display in Spleen, the titles too, so they show the same pixels. `modustool font` makes the three new sizes from the files of Spleen, 70 656 bytes in the boot program and the root service. A screen that holds no larger scale keeps scale 1.
- **A clip stack in the draw record.** Version 17 of the draw record has the kinds `Clip_Push` and `Clip_Pop` in place of the `Clip` that replaced the cut: a clip inside a clip keeps the outer one, at most 16 clips are open, and a clip is a rectangle of whole pixels. The drawing module refuses a table whose pushes and pops do not match with an error record before it draws, and a table that changes during the call still draws no pixel outside a clip that it pushed. The two lists of the interface package push the clip of their area, so a list never draws past it. The exports of the drawing module are `damage_of_draw_table_17` and `execute_draw_table_in_rectangles_17`.
- **Spacing tokens in place of the grid of 8.** A window goes where the principal drops it and takes the size that the principal drags, to the pixel, and a part of its title of 8 pixels stays on the screen. The spaces between the elements are the named spacing tokens `gap` 8, `margin` 16 and `title` 40, and a width that a text gives is that width: the columns of the start menu, the value buttons of the palette and the columns of a row are no longer rounded up to a multiple of 8.
- **Text at any size.** A glyph that no glyph cache holds, such as a Greek letter or a box-drawing character, is now drawn by the process that shows it into its own private glyph cache, which the process takes from its budget at its first such glyph, with the pixels of today. A text that is wider than its box now breaks its lines between two whole characters only. The packages `fallback_glyphs` and `text_shaping` are now one package, `text_rendering`. A frame whose glyphs fill the cache still draws each glyph right, and writes `text_rendering: the glyphs of one frame fill the private glyph cache` once on the log.
- **The table of the processes starts its service**: `processes()` works at once in each start policy, the rescue included, because the root service starts `monitor` at its first connection; `start("monitor")` is no longer needed first.
- **The kernel records why a process stopped**: each stopped process has a stop cause that no other process can forge: itself, a holder of its process handle, the end of its last thread, the close of its last handle, a fault, a page that is not committed, a return that the processor refused, or a fault that no thread can answer. `Process_State` gives it as its second result, `monitor.processes()` shows it in its column `cause`, and the lines name it: "root: net stopped: a holder", "error: the process calendar stopped: a fault, page fault". The codes 0x100 to 0x500 of the kernel are gone. The demonstrations and the tests give their results through memory that they share with their parent, never in their stop.
- **What a process says about its work when it stops.** A process that stops itself names its stop outcome: done, failed, refused or stopped on request, as in `system.stop(.Done)`; the stop code is gone. The kernel refuses `Process_Stop` of the caller with no outcome, and of another process with one, with `Bad_Operation` and the record `Bad_Value` of the argument 2, so no holder can make a process look done. `Process_State` gives the outcome as its third result, `monitor.processes()` has the column `outcome`, and the lines read "root: settings stopped: itself, done" and "error: the process calendar stopped: refused". A process with no seed, no grant or a word of its context that names nothing stops with refused; the start policy starts no row again after done or refused. `system.process_stop`, `system.process_stop_wait` and `system.process_place` are new, and the tool refuses a conversion to a stop enum and a raw call of `Process_Stop` or `Process_State` outside their packages.
- **The measure of every character from its font file**: a text is measured at any text size from the advances and the pairs of its font file, not from the tables of a glyph cache, with the same numbers at the sizes of the glyph caches; an advance is kept within one line and a pair within half a line at each size, in place of 64 pixels. The library module `text_shaping` becomes `text_rendering`: its exports `shape_text`, `measure_texts` and the new `break_text` take the font outlines as bytes, a face and a text size, and refuse a face that names no member and a size out of 256 to 16 384.
- **Every glyph drawn by its process.** The boot image no longer holds the five glyph caches of Paper Mono and B612, more than 1.3 MB, nor their five fixed ranges: each process draws each glyph of its text from the font outlines into its private glyph cache, the setting `grid_fit` chooses a face of the cells, and each stated budget of a process that draws text holds 354 pages of glyph memory for each copy that draws. A text of the interface font at the scales 2 and 3 now stands at the nearest third of a pixel, not at a whole pixel.
- **`where` takes a condition on a field**: `where(t, block = 12)`, `where(t, level = Warning)`, `where(t, number >= 100)`, in place of `where(t, "block", 12)`, which the console no longer takes. The field is a name of the record, checked before a row is read, and before any call in a line with `|>` when the console knows the record; a status takes the name of a member of its enum, with `=` and `!=` only. The operators are `=`, `!=`, `<`, `<=`, `>` and `>=`. `where`, `sort` and `join` compare an unsigned field as unsigned, so `where(key > 0)` keeps a key of 2^63. In a line with `|>`, the completion offers the fields and the members.
- **A text size in the draw record.** The draw record is version 18: a text record and a text grid carry a text size in 1/64 pixel, from 4 to 256 pixels, in place of one of three scales, and the border refuses a size out of that range, 0 too, with no clamp; the exports of the drawing module are `damage_of_draw_table_18` and `execute_draw_table_in_rectangles_18`. A text of the interface font takes its bold weight at each size, and the pictures of the desktop do not change.
- **The elements at the text size tokens.** The caption of a card is at 14 pixels on the baseline of its title, the one number of a card at 32 with its label as a caption under it, and each page of `manual` has its title as a heading at 24 over its rows, which stays when the rows move. The help line of the palette and the hash prefix after a nickname are captions too, and the result of the palette stays at 48. The interface package gives `draw_caption`, `draw_heading` and the fonts of the tokens, and each element takes the height of its lines at its size.

### Removed

- **No demand cache and no font service**: the shared demand cache, its fixed range and the process `glyphs` that drew it at each start are gone, with their 1 073 shared pages. Each process draws each glyph past the glyph caches itself, into its private glyph cache, with the same pixels; the compositor now writes on the log what each fallback chain lacks, and the terminal tells once for each font of its fallback chain that it drew a cell from it.
- **The log channel leaves, the first step of log facts**: a log record no longer carries a name that its writer chooses to group it, and the text of a record has 168 bytes in place of 152. `system.log` takes the level as its first argument, `system.log(.Warning, "storage: ...")`, and `system.log_in` is gone; the operation `Log` is `(log, address, length, level, runs)`, and its free last value lets it take a table of error details, as the other operations do. A line of a process on the serial port starts with `[name]`, the rows of `log.records` have no field `channel`, the step `Record` of a machine test reads the process and the level, the console groups the records of a line by process, and the window `log` counts the records of each process.

### Fixed

- **The tool checks itself as packages**: a change of a package of the tool that the tool imports now builds each module again, a change of a source in any folder under the tool gives the fuzzing of `modustool check` another seed, git no longer ignores a folder named `build` below the root, and `modustool check` refuses a code span of a guide that names a file of the tool that does not exist.
- **A disk that stops to answer.** A block request that the disk does not answer in 60 s fails, the block service stops with its line, and the storage service writes "storage: the disk does not answer" and refuses each call that needs the disk at once, so the console, `settings` and `unlock` get a refusal or `Gone` in place of a wait with no end.
- **A machine with no screen.** A machine with no screen at its start no longer ends its start on a failure that nobody sees: the root service writes `root: no screen: no console, no window; the other services start`, starts no input service, no compositor and no console, gives no process a window, refuses a process that needs a terminal, and starts the other services of the boot. An `unlock` that needs a typed key writes one line and stops. A compositor that stops later gives one line, refuses the later terminals, and starts nothing.
- **A frame service that stops.** The network service ends its wait when the frame service stops, writes one line and stops, and the root service writes one line and refuses each later process with an endpoint while the other processes start; a machine with no network device gets the same line and runs on.
- **No PS/2 controller.** On a machine with no PS/2 controller the input service no longer reads its status port for ever on one processor: a status of all ones, or a drain that reaches 100 000 bytes, gives `input: no PS/2 controller: no keyboard and no mouse` and a stop with the code 1, and the desktop runs with no keyboard and no mouse.
- **An entropy read that never completes.** A read of the entropy device has a deadline, the hang bound of the system, from its ask: past it, the reads in flight count as refused, the root service writes one line and stops the entropy service, and the seed keeps the sources of the processor, so the fresh bytes no longer stop in silence.
- **A readable stop of the boot program.** When the boot program cannot go on, for memory, for the memory map of the firmware or for a kernel module that it cannot load, its message stays on the boot display with the watchdog of the firmware off, in place of a power off at once; with no screen it stays on the console of the firmware. The buffer of the memory map takes the size that the firmware asks with a margin of 8 descriptors, in place of 16 fixed pages, and a map whose reserved ranges pass the 1024 ranges of the boot record gives one line with their count and their pages, while each usable range is kept.
- **A start of the kernel without a part.** A machine with no 8254 no longer hangs its first processor: the kernel takes the frequency of the cycle counter that CPUID states on a processor of Intel, or writes its line and stops with the code 1 when the processor states none. An IOMMU unit that does not finish its first invalidation leaves the machine with no IOMMU in place of a stop, a missing table of the APIC writes `kernel: the firmware lists no APIC table: one processor`, and a failed proof of xsaveopt makes the kernel save with fxsave. A serial port that takes no byte and an interrupt that the controller does not send no longer hang a processor: each wait has a bound, and the log counts what was dropped.
- **A module that states too many parameters is refused.** The sentence of an error of such a module no longer stops its process: the description of its export is refused, as a damaged description.

## [0.95.0] - 2026-11-18 09:23

### Added

- **The loop of the kernel fuzzing with no counters.** `modustool fuzz operations <executions> [seed]` runs generated operation sequences on machines of the kernel that ships, one machine at a time, and boots a new machine after 1024 sequences or after a fault of the kernel: a stop of the machine, a sequence that does not end within the hang bound, a stop of `operation_fuzzing` or of the root service, or a broken oracle. It keeps each fault one time for its signature, with no number that changes from run to run, minimizes it by machine lives and by steps in at most 256 boots, and writes it to `build/fuzzing/operations/<seed>/`. A run with no count, or a count of 0, is refused.
- **Memory that grows with the data, paid by the budget.** A process holds data with no known bound in an arena of the support package `system`: `arena_create` reserves an uncommitted object, `arena_push` commits the next pages as the arena grows and gives back `No_Budget` with its error record when the budget cannot pay, `arena_reset` keeps the pages for the next frame, and `arena_end` gives every page back to the budget at once. The test module `arena` grows an arena until its budget refuses, and checks that it keeps running and that its budget comes back whole.
- **Windows that the principal resizes.** A process declares its window resizable with its least and largest size (`display.resizable_set`). The principal drags an edge or a corner, with the resize pointer shapes and an outline of the new frame. At the release the process gets the event `Resized`, makes the surface of the new size with its own budget (`display.surface_resize`) and draws its next frame in it; the compositor shows the old surface until that frame. The compositor takes only the asked size, once, so a process cannot resize its window by itself. A budget that cannot pay gives `No_Budget` and keeps the old size, with one line. `clock` is the first resizable window.
- **Copy and paste between windows.** Control+C copies the text of the field that has the focus in the window in front, and Control+V pastes it into the field of another window, or into the line of the console as typed characters. The compositor takes both keys, so no process sees them or sends them. A copy is memory of the process that copies, paid by its budget; a paste lends the window in front a handle with Read for that paste only, and the reader copies the text, then checks that it is UTF-8 with no control character and no character that a reader does not see or that changes the order of the text. A text holds 1 to 4096 bytes and ends with the process that copied it.
- **The corpus of the kernel operations.** The regression inputs of the operation sequences are in `tools/modustool/fuzzing_corpus/operations/regression/`: each holds a minimized life of a fixed finding and the answer of each step of its last sequence on the kernel that ships, its status, its error record and its table of error details. The test part `operation_sequences` runs each one after the seed sequences and checks each answer, so a changed refusal fails the part. `modustool fuzz regression operations <finding>` writes one from a finding folder, and refuses a finding that still breaks an oracle. The three findings of the first long run are regression inputs; their variants, the word 0 and the word past the last operation with and without a table, the commit and the decommit, stay seed cases with their answers.
- **The measure of a frame at 1920 × 1080 on the processor.** The measure run of `modustool measure` now starts the process `processor_frame`, which draws in memory at the reference screen, with no GPU, three parts of a frame: a clear and a present, a frame of the compositor with 4 windows in full and in its damage, and the execution of a draw table of a desktop with texts in both fonts, pictures and alpha. Each part gives one line with the least and the median of 21 frames in microseconds and the frames in one second at the median; the measure record and its history keep the four lines. The tool checks the form of the lines only, and the process checks a pixel of each part.
- **Sound, a timed stream.** A process with the start grant `Sound_Device` plays sound through the new sound service `sound`, the device service of a virtio sound device: it writes its samples in memory of its own, lends it with the right Read only, and sends records that each name the time of their first frame by the system clock. The service plays each frame at its time, 48000 frames in one second of two channels of signed 16-bit samples, with silence between the records and a latency of 30 to 40 ms. A record that comes late, more than 10 s ahead, over the record before it, of an unknown format or past its region is refused whole with its error record, and one process plays at a time: a second one does not start. The process `tone` plays a tone of 440 Hz, and `modustool test sound` finds it in the sound output of the machine at the frame of its time. The error records gain the units `Nanoseconds` and `Frames`.
- **The measures of the standard of quality.** The compositor writes at its start the quality profile that it chose, the processor profile with the reason "the system drives no GPU device", and measures with the clock of the system the three numbers of the standard: the time of a frame from the first record that it reads in the turn that draws it to the page flip, with no wait of its own rate of one frame each 16 ms, the time of a key from the input service to the flip of the frame that shows its character in the console, and the start of each window from `Process_Start` to its first frame. The console names each key that it puts in its line, its terminal names it with the picture, and the compositor ties the two, so a frame that only came after a key is never counted as its effect. The measure run waits for each line, the tool checks their form only, and the measure record and its history keep them.
- **The records at the addresses of the kernel operations.** The generator of the operation sequences writes a table of `Page_Range` where `Memory_Commit` reads one, and a register image, a breakpoint image or the legacy part and the header of an extended state area where a write command of `Thread_Control` reads one, in place of plain bytes, so a sequence reaches the code behind the first check of each record. Of 16 records, 12 are valid, 3 hold one edge value of a field, and 1 holds a word that names nothing, so the refusals of each field still run; half of the steps of `Thread_Control` name one of the three write commands. A seed still gives the same sequences, byte for byte.

### Changed

- **The look of the system out of the draw record**: the grid of points and the folded gap are elements of the interface package, drawn with a rectangle that repeats, rectangles and lines, and the kinds `Point_Grid` and `Folded_Gap` are gone; the border refuses their words as unknown kinds. A `Rectangle` record can hold a pattern: a cell placed on the surface, its size and its steps, cut to the box. The draw record is version 12, the drawing module has the exports `damage_of_draw_table_12` and `execute_draw_table_in_rectangles_12`, and each window of the system draws the same pixels: a folded gap narrower than 6 pixels, a grid of points left of or above the pixel -10, and a folded gap whose line ends past 32 768 pixels, where that line is left out, are the only places that can differ.
- **One text kind in the draw record**: a text in the font of the cells and a text in the interface font are one record `Text`, with its font as a field: the draw record is version 13, and the drawing module exports `damage_of_draw_table_13` and `execute_draw_table_in_rectangles_13`. Each text draws the same pixels. The word 11 of the kind `Interface_Text` now names no kind, and a text in the font of the cells that starts past the coordinate limit has no record.
- **Colors with alpha in the draw record**: a color of a record is `0xAARRGGBB` with straight alpha, and a rectangle, a pattern, a vertical and a horizontal gradient and a picture with the format `Straight_Alpha` blend over what is drawn before them by one rule in linear light, the rule of the text. The interface package writes them with `draw_rectangle_with_alpha`, the two gradients with alpha and `draw_picture_with_alpha`. The draw record is version 14, and the drawing module exports `damage_of_draw_table_14` and `execute_draw_table_in_rectangles_14`. A record with opaque colors draws the same pixels as before; a text and a line stay opaque, and the border refuses a color with alpha 0 that is not 0.
- **Edges inside a pixel and a gradient along any line in the draw record**: a rectangle and a gradient can have a box whose edges lie between two pixels, and the part of an edge pixel inside the box scales its alpha (`draw_rectangle_in_units`, `draw_gradient`). The vertical and the horizontal gradient are one `Gradient` kind with two points and two colors, along any line; a gradient down keeps its pixels, and a gradient across, as in the title bars and the scroll bar, mixes in the steps of 1/255 of a gradient down, so a channel can differ by up to 2. A gradient that is longer than 32 768 pixels is not written, and the frame says that a record was refused. A text takes a color with alpha in each font (`draw_text_with_alpha`). The draw record is version 15, and the drawing module exports `damage_of_draw_table_15` and `execute_draw_table_in_rectangles_15`; the words 2 and 3 of the old gradients name no kind.
- **The file is a module.** The button of the bar that opens the menu of the modules to start is `start`, and the palette shows a module to start as `plasma (module)` under the heading `modules`. The module file service is `module_files` (`module_files.receive`, `module_files.list`, `connect("module_files")`), and its store is the store `module_files`. The command of the tool that writes a data disk of module files is `modustool module-disk`. The boot display, the module pages of the site and the module graph name a module with an entry export a module with an entry.
- **A process in place of a program.** What runs is a process, and the file of code is a module. The kernel operations keep their numbers and change their names: `Process_Create`, `Process_Start`, `Process_Stop`, `Process_State` and `Process_Module`, and the kind `Process_Mappings` of `Inspect`. The contract, the guides, the glossary and the lines of the log say process for what runs and module for the file, so a reader never takes one for the other. A process of the host that the tool starts is a host process, and the argument of `build`, `fuzz` and `repeat` that counts them is `host_processes`. The boot program keeps its name, because it is no process of the kernel.

### Fixed

- **The kind 0 names no operation**: a command record of the kind 0 (`None`) is now refused with `Bad_Operation` and the error record `Unknown_Operation`, as a kind past the last operation is. The kernel answered `Ok` to it before, so a command record that a process never filled passed as a success.
- **The budget of a commit is always read**: the form of the budget of `Memory_Commit` in `op.OPERATIONS` is now a handle, not a handle or 0, and `op.argument_is_read` says that a commit reads a budget of 0. The kernel refuses that budget with a detail of its own, and the contract now agrees with it. A decommit still reads no budget.

## [0.94.0] - 2026-11-18 00:52

### Added

- **`operation.module_writer_of_word`**: the border of the word of the writer of a module record. It refuses a word that names no writer, and `module_writer_name` names each writer with no default.
- **The first signed release image.** Release 0.93.0 is the first release whose disk image is built with the keys of the publisher of the system, and whose checksum list carries the release signature. A principal checks both with modustool verify and the public key in resources/keys/release_signing_key.public.
- **A window memory for each window.** A program with a window declares one `interface.Window_Memory(RECORDS, TEXT)` record, with its drawing and its two draw tables, and starts each frame with `interface.window_frame_start`: one declaration and one line replace the four buffers, the drawing and the start that each program wrote. The 43 programs that wrote them use it.
- **Fuzzing of the other readers of the system**: `modustool fuzz` and the fuzz check of `modustool check` now also give hostile inputs to the remote protocol (the call request, the call answer, the client table) and to `isolated.decode` of a call region, to the records that a program reads from a ring (the input events, the terminal input, the service commands, the root commands and their refusals), to the disk grant table behind its tag, to the system description and a boot image built and then changed by one byte, to the vector font reader, the glyph caches and the font outlines, to the pointer theme, and to the ACPI tables DMAR, IVRS and MCFG. Each of the 13 new targets has a seed of each form and its edges, and a round trip through its writer where one exists.
- **A machine case for each refused ring word.** The machine test now sends `None`, the word one past the last command and the largest word to the block service and to the network service, which answer each one with `Bad_Command` and the record `Unsupported` and serve the next command, and to the compositor on the ring of a window and to a terminal, which each write one line at the first word and the count 3 at the end. The new test program `hostile_terminal` writes the words to its terminal.
- **Fuzzing of the last readers of the system**: `modustool fuzz` and the fuzz check of `modustool check` now also give hostile inputs to the sentences of the error records, the palette table, the demand cache, the value runs, the text encoding check, the kept stop reports, the kept settings, the answers of the TPM, the shaping tables of the fonts, and the list of the processors in the ACPI table APIC, whose reader moved from the kernel into a package of its own, with host tests. The instrumented build now counts the edges of a package by the name that its sources declare, so the terminal records count too.
- **A check of the tool for a cast of a word to an enum.** `modustool check` refuses a cast of a word to an enum that the code keeps, passes or switches on, with its file, its line and its form, and accepts a cast only as one operand of `==` or `!=` with a member. Each such cast of the system and of the tool now reads its word through a border.
- **The format of the operation sequences and their generator**: the contract package `operation_sequence` gives the format of the fuzz input of the kernel operations, whose reader refuses each damaged sequence with its problem and its step, its area or its argument. `modustool fuzz` and the fuzz check of `modustool check` have two new targets: `operation_sequence` gives hostile bytes to that reader, and `operation_sequence_generated` checks that each sequence that the tool builds from the forms of the kernel operations is one that the reader accepts.
- **A fuzz target of the root ring.** The fuzz check sends records of the root ring with each word and each edge of each argument, from any role of the sender, to `root_ring.dispatch_decide`, the decision of the border and the sender that the root service now takes from its contract, and to the borders of the words of the commands and the records of a refused Replace. It checks each refusal against a model of the table of the senders, and that nothing changed: `modustool fuzz root_ring`.
- **The processors at a failed step.** When a step of a machine test fails while QEMU runs, the tool first reads the registers of each processor through the monitor of QEMU, writes them beside the log of the machine (`<log>_processors.txt`), and prints for each processor its instruction address, whether it is halted, and the code that holds the address: the procedure of the kernel from its debug object, the firmware, the firmware in system management mode, a program, or no known code. A step that ended at its bound then says where the machine stalled.
- **The machine of the operation sequences**: the test part `operation_sequences` runs a seed sequence of each kernel operation, and the seed cases, on the kernel that ships, each in a new program with a new budget, and checks each answer against the statuses of the reference, the forms of the operations, the table of error details and the budget of the sequence. `modustool fuzz replay operations <file>` runs one sequence the same way.

### Changed

- **One table of the context slots, and a start that refuses a taken slot.** The root service writes each handle of a program that it starts through one write that refuses a context slot that holds a handle already: a role whose grants take one slot twice does not start, with one line of the log, and loses no handle in silence. The text region of a terminal moved from the handle 7, the call ring of the private store, to the handle 4.
- **The root service reads the role of a sender, never its name.** Each command of the root ring goes through one border that refuses a word that names no command, then the table of its senders by the start grants that the program received at its start. A rule no longer reads a table by the name of the program after its start, so the nickname of a disk program can never meet a rule of a privileged program; a disk program receives no root ring.
- **A glyph cache with a reserved field that is not 0 is refused**: `glyph_cache.validate` refuses the last reserved field of the header and the reserved field of a size with `Bad_Count`, and the reserved field of a pair with `Bad_Pair`. The tool writes each of them as 0.
- **One type for a QUIC connection identifier**: the QUIC library holds each connection identifier as a `quic.Connection_Identifier`, made by `connection_identifier_make` or `connection_identifier_of_chosen` and read with `connection_identifier_bytes`, in place of an array and a separate `_length` field. The optional identifiers of the transport parameters are a `Maybe` of it, and the fields `has_original_destination_connection_id`, `has_retry_source_connection_id` and `has_initial_source_connection_id` are gone. `transport_parameters_write` no longer refuses an identifier, and `retry_token_make` no longer gives `Too_Long`.
- **A fuzz run always has a count.** modustool fuzz with no count of executions runs the count of the check, and refuses a count of 0, so a forgotten argument never starts a run with no end. A long run names its count.
- **The bars of `crowd`, `disk`, `flow` and `budget` are the bar of the rules.** Each bar has the gradient of the design rules and a full part of 2 pixels at least for a value above 0, with its value after it in its own cell: the new element `interface.bar_with_value`. The windows of these four programs and of `origin`, `rights` and `frames` place their lines with the layout of the interface package, so a text that is longer than its cell no longer runs over the next one.
- **The machine test runs its parts at once, and the full check runs it once.** `modustool test` starts its test parts together, at most one for each four processors of the host, the longest first, each part on a new data disk of its own, and prints the time of each part as a measure. One table of the tool holds the parts, and the guide follows it; the persistence, the self tests of the kernel, the start that fails and the tests of the loader on the host are parts too. `modustool screenshots` takes the pictures and the logs from the check of the flake, which Nix keeps in its store, so a full check runs each machine once in place of twice; the pictures then show the pointer theme of the system.
- **A word in place of each enum field of a shared record.** The tone and the code kind of a run of the terminal, the kind of a value run of the log, the kind of an entry of the palette table, the scope of a replacement row and the writer of a module record are now words that each reader takes through its border. A byte that names no member is refused, and the tables of `inspect.modules()`, `manual.running()` and `program_modules()` leave the writer empty, with a line of the log, where they wrote "unknown" before.
- **A word in place of the other enum fields of a shared record.** The kind of a code run of the terminal, the result and the parameter kinds of an entry of the palette table, the types of a module file, the kinds of an event record and of a fault record of the kernel, the mode of the lockers board, the kind of a storage entry and the self test and the floor states of the boot information are now words that each reader takes through its border, with the same bytes in each record. A value of a setting that the setting does not have now refuses the whole settings page or kept record, where it read as the value 0 before.
- **The kernel parts.** The formats of the IOMMU, the ACPI table of the processors, the debug exception and the processor counters are pure packages of the kernel with host tests, in folders under `src/kernel`, imported as `kernel:iommu` through a second source library that only the kernel, its host tests and the tool get: a module or a package of the library that imports one, by its name or by a relative path, does not build, and the tool names its file and its line. The tool also refuses, in a kernel part, a package variable that is not `@(rodata)`, a variable marked `@(static)` or `@(thread_local)`, a foreign block, an asm template and an intrinsic that reads the machine, so each kernel part keeps host tests that need no machine.
- **The bound of a glossary term in the check.** `modustool check` and `modustool site` refuse a term of the glossary whose explanation has more than 100 words, as they refuse a term with no short definition: the fault names the term, its file, its line and its count of words. The count takes the words between the short definition and the line "Do not use", so a term stays a definition and its guide holds the detail. Ten terms that passed the bound are shorter now.
- **The tool built once.** `nix develop -c modustool <command>` runs the binary `build/tool/modustool`, which compiles itself again only when the build key of its sources changes, and prints the time of each compile as a measure. The check of the flake and the release shell run a binary that Nix builds once for each change of the sources of the tool, so a change of a guide or of a host test no longer compiles the tool.
- **The glossary in one file for each group.** The glossary is the folder `docs/glossary/`: one file for each of its 14 groups, and a `README.md` with the introduction and the list of the groups in their order. A pointer to a term names the file of its group, as (`docs/glossary/storage.md`, "Commit read back"), and finds a term of that group only. The site keeps the same pages and the same anchors of the terms, and the tool refuses a file that the list does not name, a listed file that is missing and a file whose name is not the slug of its group.
- **The host tests of the check at once.** `modustool check` runs the host tests of each folder at the same time as the others, at most one process for each processor, and writes the log of each folder to `build/host_tests/`. It prints the time of each folder as a measure, and for a folder that fails the end of its log.
- **Each context of the root service through the check of a taken slot.** The input service, the compositor, each device service, the TPM service, the font service and `shortage` now get their handles through `system.grant_put`, as each other program does, and every value of every context goes through `system.value_put`, `system.values_put` or `system.range_mapped_put`, which refuse an index that holds a value, an index of the seed or of the fixed ranges, and a fixed range stated twice. A start with a handle or a value written twice does not run, a device service before its device is armed, and the log says which: "root: cannot start NAME: two parts of its start write the value N of its context, and a value would be lost".
- **The grants and the terms of a role in one table.** The role of each program of the boot image is one row of `program_roles` in `src/programs/root/roles.odin`: its start grants, the services that it connects to, its store, its terminal and the reason of each. The build stops when a program of the boot image has no row, a row names no program, a program has two rows, or the grant System_Part is on a row that is no part of the system or missing from a part of the system, and the page of the grants on the site shows each row with its grants and its other terms.
- **The private parts of a module.** The 16 packages of the library that one module alone compiles in leave `modus:support` for `modus:private/<module>/<part>`, with their host tests: `modus:private/storage/storage_tree` and the three other parts of the storage service, the bar and the palette of the compositor, the language and the results of the console, the three parts of the manual, and the parts of `inspect`, `debugger`, `kernel_events`, `input` and `root`. The tool refuses a private part that another module imports, and a support package that fewer than two modules reach, with the folder and the one module that reaches it.
- **One folder of modules by group.** The programs and the other modules are one folder, `src/modules`, in four groups by what each module is for: `system` (the root service, the services, the desktop and the tools of a principal), `libraries` (the modules with no entry that other modules import), `demonstrations` (the programs that each show a property) and `tests` (the test modules that only a machine test starts). The path of a source in a stop report, a stack trace and the debugger names its group: `src/modules/demonstrations/fault/main.odin:15`.
- **The code of the module cryptography is a private part of the library**: `modus:private/cryptography/cryptography_primitives` holds the code of each export but `argon2id`, and the module exports it with the same names, signatures and error records. The QUIC peers of the tool and the host tests of QUIC import that part, and the check of the imports refuses a relative import that lands in the folder of a module, from `src/` and from `tools/`.
- **The draw record in one tagged form**: a draw record is 48 bytes, a header with its kind, its element and its box in 1/64 pixel, then the fields of its kind only, in the contract package `draw_record`. One border reads each record and refuses a word that names no kind, a reserved byte that is not 0, an inverted box, a color with a high byte and a field past its bound; places stay inside 2^23 pixels. The drawing module has the exports `damage_of_draw_table_11` and `execute_draw_table_in_rectangles_11`, every window draws the same pixels, the site shows the byte layout of each kind, and a fuzz target tries the border.

### Removed

- **The rule of a bridge as a contract of its own.** The contract package `modus:contract/bridge_requester` holds the rule that gives the devices behind a conventional bridge of PCI one requester, which the kernel and the root service share. The four packages `modus:contract/iommu`, `modus:contract/acpi_processors`, `modus:contract/debug_exception` and `modus:contract/processor_counters` leave the source library `modus`: only the kernel reads them, and a program outside the repository can no longer import them.

### Fixed

- **`Machine_Stop` refuses a code that the host cannot receive**: a code above `MACHINE_STOP_CODE_MOST` (255) gives `Bad_Operation` with the error record `Bad_Value` of the code, and the machine runs on. Before, the kernel wrote the whole code on the log and gave the host its low byte, so the code 256 ended the machine with 0, the code of a normal end.
- **The error records of the root ring say the cause.** `machine_seal()` on a machine whose firmware did not verify the boot program now gives the record Refused of the principals, and no longer a missing grant; a refused `Machine_Key` from `unlock` now has an error record; and an error record that names no command of the root ring now reads "an unknown command".
- **`ring.open` refuses a count of pages whose capacity wraps**: a count of pages near the top of its type made the capacity wrap to 0, with a mask of every bit, or to a small power of two, and `open` gave a ring. It now refuses each count past the ring of `CAPACITY_LIMIT` records.
- **The cost of a memory object never wraps**: `operation.memory_list_pages` gave 1 list page for a count of pages near the top of its type, and `operation.memory_cost` wrapped to a small cost. The list pages are now exact for each count, and a cost past the type is the largest value, which no budget holds.
- **The runs of memory of the boot report**: a run of no page from the firmware is now counted and not kept, and a run whose end passes the top of the addresses joins no run. Before, the end of a run at the top wrapped to a low address and joined a run there that did not follow it.
- **Each enum read from a word at its border**: an input record of the compositor or of the terminal, a status of the kernel or of the root service, a command of the service ring, a word of an error record, a kind of a value, of a code run, of a list icon, of a palette answer and a scope of a replacement row now name a member or are refused with a line of the log or an error record; no word that names no member is read as a member, and each switch on a closed set of the support library and of the contracts other than the kernel operations names each member. The sentence of a failed call with an error record of zeros says that the call wrote no record, not "no error". The answers of the storage service are one enumeration with the same numbers, a place of a storage connection is its own type, `system.memory_size` gives the status of the kernel, and `ring_open` answers each cause with its own status.
- **A network grant with an unknown bit is refused**: the word of the grant of an endpoint with a bit from 51 to 63 was read as a grant with fewer rights. The network service now refuses such a word with `Bad_Value` and makes or changes no endpoint, and each network program stops at its start when its grant has one.
- **`ring.pop` refuses counters that say more records than the queue holds**: a writer that wrote its counter more than the capacity past the counter of the reader made `pop` give a record for each count. `pop` now gives no record and changes no counter, as `push` refuses such counters.
- **No press of the pointer lost while test parts run at once.** The compositor writes the place of each press of the left button and the first picture of each window. A machine test that moves the pointer with no other way to read it presses again from the place that the compositor wrote, and opens the menu of the windows only once the window is in it.
- **A refused palette table gives no generation.** When an entry of the palette table is refused, the snapshot holds no entry and the generation 0, so a reader that keeps the generation of its last snapshot reads the table again.
- **A call answer with a status that names no status is refused**: `remote.answer_check` accepted an answer of the remote service whose status word named no member of `remote.Status`, and the host then held a status that the service did not name. The host now refuses such an answer as it refuses an answer whose bytes are not its header and its total.
- **A module page of a program with no row of the roles links to no row.** The page of the root service and of a disk program names its grants with no link, where it pointed to a row of the page of the grants that does not exist, and the build of the site stopped.
- **Each enum of the programs and of the kernel read at its border.** A program that writes a word of no member in a ring, a context or a shared page now gets a refusal from the block, frame and network services, the compositor, the console, the terminal and the test programs, with its error record, a line of the log or a stop of the reading program, where it was ignored or read as another member before. Each choice of the programs, of the boot program, of the kernel and of the operation contract now names each member, so a new member stops the build at each place that must choose its case.
- **A refused Integer argument of the palette gives no value**: `palette_table.argument_unpack` refused an Argument command of an Integer with a length of text, but still gave its parameter and its value with the refusal. It now gives the parameter 0 and the zero value, as each other refusal of the palette table does.
- **The diagrams of the guides are drawn.** The site showed each mermaid diagram of a guide as its text; it now draws each one as a picture in the page, in the light and the dark form, with its text under it, and `modustool site` stops on a diagram that it cannot draw, with its file and its line. The diagrams and the pictures of a guide fit the column of the page.
- **A command push that the ring refuses is never ignored.** A thread that leaves the completion queue of its kernel ring full loses no answer: the kernel leaves the next command unrun in the command queue and returns with no wait, then runs it after the thread reads its completions. `system.commands_call` is the one path of `src/library/support/system` into the kernel ring, under each kernel call and each wait, and runs a batch of commands in one entry: on a kernel ring that holds other records it gives `Bad_Operation` with the error record `Busy` and runs nothing, a wait then ends at once, and an answer with another tag than its command gives `Refused`. `system.stop` ends the program whatever its kernel ring holds.
- **A budget no longer pays for the time that the host took.** Under KVM the kernel reads the steal time of each processor and no longer charges a thread, its budgets or its strategy for the time in which the host ran no code of that processor. On a loaded host, the program `limits` read 327 ms used by a budget with a limit of 50 ms in one second, and its check failed. The boot line `kernel: steal time:` says how many processors registered, or why none did.

### Security

- **A damaged disk stopped the storage service**: a branch of a tree, or a root of a tree, with no block and any check in a Pointer made the commit of a change take that check for the number of a slot of its pool, and the storage service stopped on a bounds fault. The storage service now refuses that node or that root as a damaged tree, and writes nothing; the open of the disk marks its store damaged.

## [0.93.0] - 2026-11-17 06:56

### Added

- **Three more formats of a file of the mark**: `modustool mark still --format ico` writes an icon file with one PNG entry for each size, `--format svg` writes the cells variant as rectangles, with the rule of the dark scheme on request, and `modustool mark animation --animation <name>` writes one animation as an animated PNG file, each frame for its time. The smooth variant as a vector file is refused with a sentence.
- **A share of the processor for each program**: the program `scheduler` has a share policy. With `scheduler.policy(1)` it gives each program one program weight and divides it between the threads of the program that are ready or that ran, one round each 100 ms, so four programs with 1, 2, 4 and 8 threads that compute have the thread weights 1024, 512, 256 and 128. `scheduler.share("paint", 256)` gives the programs with a name another program weight, from 32 to 1024. A thread keeps a weight that its program lowered, and gets its weight back when the policy goes off. The key S of the window opens the view of the shares: one row for each program, with its share of the processors in the last period. The kernel has no new operation. The policy is off at the start, and it does not see threads that a program creates and ends between two rounds.
- **The palette sets the scheduling strategy**: the palette has one entry for each scheduling strategy, "set strategy to eevdf", and the strategy that the machine uses says so. The console has the command `strategy(name)`, with `round_robin`, `fair` or `eevdf`: it calls the new export `strategy_set` of the program `scheduler`, which holds the right to change the strategy and must run. A press of the pointer in a field of the form of a command puts the caret there, and a press on a candidate takes it.
- **The pointer on the scroll bars of the palette and of a completion list**: the scroll bar of the palette, of the candidates of its form and of the completion list of the console takes the pointer: a press on an arrow button moves the rows by one, a press on the track by one page, and the thumb follows the pointer. The chosen row follows the view. The wheel of a pointing device is not read yet.
- **A module from a source outside the repository**: `modustool module-build <folder>` builds a module whose source is in a folder of another project, with the steps of a module of the system. The folder holds one Odin package and a file `module.txt` with the name of the module, its imports, its settings of the compiler and whether it is a library module, one `key: value` on each line. The tool finds the system with `--system` or with the environment variable `MODUS_SYSTEM`, writes `<name>.module` and `<name>.debug` in the folder `build` of the module, and prints the hash of the module and the names of its exports. A source of such a module is in its folder, in the source library `modus` or in the libraries of the compiler: the tool refuses each other place. The tool does not yet put such a module in the boot image of a machine.
- **Programs from a disk**: the console command `start_from_disk(name, hash)` starts a program whose module file is an object of the store `programs` of the storage service, and not a file of the boot image. The root service reads the bytes without waiting for the storage service, starts them only when their BLAKE3 hash is the hash of the command, and gives the program the log and a window and no grant, whatever its name. `modustool test disk_programs` writes the data disk and runs the machine.
- **Kind icons in the completion list of the console.** Each row of the completion list starts with the kind icon of its name, as each row of the palette does: a command, an export, a command that makes a record, a module, a variable or a line of the history. A reader tells them apart before reading the name.
- **Two rules of the system are checks of the tool.** `modustool check` now compares the count of the kernel operations with the count that the properties state, and refuses a source of the system that calls an allocator. `modustool rule-checks` runs the two checks alone.
- **A step over a call in the debugger.** The command `step_over(thread)` of the console, and the export `debugger.step_over`, run a thread to the next source line of its procedure: a call of the line runs to its end, and the thread does not stop inside it. `step_line` still enters the call.
- **Keyboard layouts.** The setting `keyboard_layout` chooses the layout of the keyboard: `us` (QWERTY) or `french` (AZERTY). The window of `settings` shows it as a row of buttons, and `settings.set("keyboard_layout", "french")` sets it; a change holds from the next key. A key whose character is outside ASCII in a layout gives no character yet.
- **A window for the debugger.** The program `debugger_window` shows the threads of a program, the stack of the chosen thread, and the variables and the source line of the chosen frame. A key does each act: hold a thread, let it run, one instruction, one line, one line over each call, detach.
- **A film of the boot.** `modustool film boot` films the start of a machine: the check of the boot program on the screen, the boot display held at its stage, the desktop, and the window of the boot display with the records of the kernel. The machine of a film has a display with no window, and the scenario starts it, so each state stays readable.
- **The window of the debugger sets breakpoints.** In the window of the debugger, the key `b` puts a breakpoint at the source line of the chosen frame, the keys `0` to `3` remove the breakpoint with that number, and `g` shows the registers of the chosen thread.
- **An outside module in a machine.** The command `modustool program-disk` writes a data disk whose store of the programs holds module files, and prints the line of the console that starts each one. A machine with that disk starts a module that was built from a folder of another project with `start_from_disk`, with no grant and no change of the boot image.
- **The palette builds its form from the descriptions.** A setting is one row of the palette with a button for each value and a line under the value in use: Left and Right choose, Enter or a press sets it; the scheduling strategy is such a row too. A field of a command with a few closed values, such as the field of `strategy`, is a row of buttons. The input band says the mode of the chosen entry: "enter: run", "enter enter: destroy", and "shift enter: go to" when an open window acts on the same thing. Shift and Enter then bring that window to the front with the focus on its element: the window of `settings` names the button of the value in use of each setting, and `scheduler` the tile of the strategy in use. A program names an element with `element_act_name`, and writes no other code for it. The palette table is at version 4.
- **Grants for a disk program.** The principal gives a disk program a grant by its nickname, the name of its entry in the store `programs`: `allow("visitor", "store")` gives it a store of its own, `disk-visitor`, from its next start, and `disallow` takes the grant. The disk grant table binds each nickname to one hash: a start of the nickname with another hash is refused before any read, and `start_from_disk("visitor", "")` starts the file of the row. `nickname_move(nickname, hash)` points the nickname to a new file, and its grant and its store follow. The root service refuses the ring of the root service, a right over the machine or a device, and the right to act for the principal. The table of principal 0 lasts until the machine stops; the store stays on the disk.
- **The IOMMU.** On a machine with the IOMMU of Intel, a device reaches only the memory that its device service declared with `Memory_Physical`, and an access to another page is refused and written on the log as a DMA fault, with the device and the address; no program stops. A machine with no IOMMU writes one line at its start and runs as before. `modustool test iommu` runs the system on such a machine, with a test device service whose read into a page that it did not declare does not arrive.
- **The palette shows a size or a time as a number with its unit.** A field of a command that counts a size or a time shows its unit after the number, also while the field is empty: `buffer(count: 4 pages)`, `wait_stop(milliseconds: 3000 ms)`, and the prompt says "an Integer, in pages". A press and a release on a button of a field take its value, as Tab does. The palette table is version 5, with an integer unit for each parameter.
- **The machine passphrase.** `machine_passphrase()` sets an optional passphrase of principal 0, the machine, typed two times in the window of `unlock`. With it, the disk grant table of principal 0 is kept in the store `programs`, signed by the machine key, and a grant of a disk program survives a restart: the window of `unlock` asks for the passphrase at each start, and until it is typed the machine runs and its disk programs start with no grant. A table that another key signed is refused with a line of the log, gives no grant, and is kept on the disk: only a new passphrase on a machine with no record writes over it. `disk_persistence(nickname, setting)` sets how long a row lasts: `persist`, `forget`, or the global setting. With no machine passphrase, the table lasts until the machine stops, as before.
- **The window of the debugger takes a typed place and a click.** A debug place field and the buttons break at, watch and memory put a breakpoint at a procedure or at a file and a line, a watch on an address or a global, and show 128 bytes of the program from a place, in a new card that the window reads again with the threads. A click on a row does what a key does: a row of the threads or of the stack chooses it, a row of the source puts a breakpoint at its line, and a row of the breakpoints removes it. A developer then needs the console for no act of the debugger.
- **An export states the unit of a number.** An Integer parameter of an export can count a size or a time: its source gives it a type such as `value_kinds.Size_In_Bytes` or `value_kinds.Time_In_Milliseconds`, and the description of the export holds the unit. The palette shows the unit after the number of the field, as for a built-in command of the console: `hkdf_sha256_expand` takes a length in bytes, `debugger.memory` and `debugger.watch` bytes, `debugger.wait_stop` milliseconds, `storage.set_size` bytes. The unit is part of the meaning of the export: a replacement whose export counts in another unit fails the check of the loader, and an import declaration with another unit, or with a plain `i64`, stops the build.
- **A disk program without the tool.** The module file service `programs` puts a module file in the store `programs` on a machine that runs: `programs.receive(nickname, path)` fetches the file from a web server (10.0.2.100 port 80, the address that QEMU gives to a server of the host), stores it under the nickname, and gives the BLAKE3 hash of its bytes to type in `start_from_disk`. `programs.list()` gives each module file of the store with the hash of its bytes, which the service reads again. The service needs no new kind of grant: its private store is the store `programs`, and it serves a caller that acts for the principal of the store only. The root service still checks the bytes at each start. An import of a disk program from the same store is not built.
- **The console writes a character from its code point**: `character(233)` gives the text of é, two bytes of UTF-8, so a line of ASCII can build a text of another language before the keys type it. A control character, a surrogate and a number past 1114111 are refused.
- **The releases page has a Subscribe menu.** On the pages Releases and News of the site, a button "Subscribe" under the heading opens a menu with the Atom feed of the page and a link to watch the releases on GitHub. The menu works with no script, and Escape or a click outside closes it.
- **A disk program imports a module of the store of the programs.** When a disk program imports a module that the boot image does not hold, the root service reads the files of the store `programs` of the principal, computes the BLAKE3 hash of the bytes of each, and gives the loader the file whose hash the import names, under any nickname. The imports of that file are found the same way, with bounds of 64 entries, 8 modules and 4 levels, inside the deadline of the load. The bytes are paid by the budget of the disk programs. A hash that no file has refuses the start with one line of the log that names the import.
- **A guest.** A program runs another system on the processor, with the AMD virtualization support: the new kernel operation `Guest_Run` (the kernel has 34 operations now) runs the guest processor of a program that no thread ran, whose mappings are the guest memory, and gives each exit (a port write or read, `hlt`, `cpuid`, an access to memory) as its completion record. The program `guest_demo` runs seven bytes of 16-bit code that write 42 to the port 0x80, and receives the write; a machine with no support gives `Unsupported`.
- **Interrupt remapping on Intel.** On a machine with the IOMMU of Intel whose units offer interrupt remapping, a device sends only the message interrupts that `Device_Create` made for it: a device service can no longer make its device write another vector into the interrupt addresses. A refused interrupt is a line of the log with the device, the entry and the reason, and a count of its own; nothing stops. `Device_Create` of the kind `Message` now takes the base of a memory base address register of the device, and the kernel tells each unit to forget an entry through its queue of invalidations. `modustool test iommu` runs the system with remapping on, and a test device service whose forged messages are refused.
- **The debug object of an outside module in a machine.** `modustool program-disk` puts the debug object of each module file beside it in the store `programs`, under the hash of the module, and refuses one that names another module. At `attach`, the debugger service reads it through a connection that reads only, which the root service gives with the debug access (the command `Debug_Store` of the root ring), checks that it names the module, and names the procedures, the lines and the variables of a disk program: `outsider  entry      outsider/main.odin    81`. A connection of a service can now read only (`isolated.CALLER_READS_ONLY`, bit 47; the amount has bits 0 to 46).
- **A stop report of a disk program names its procedures and its lines.** The root service keeps the stop report of a disk program that stopped on a fault, with only the frames that a module record holds, 8 reports at most and 4 for one principal, until a run of the nickname ends with no fault, and writes `root: kept the stop report of <nickname>, a disk program of principal 0: stop_report("<nickname>") names its frames`. `stop_report("<nickname>")` in the console calls the new export `stop_report` of the debugger service, with no attach: the service receives the report with the connection that reads only to the store `programs` (the command `Debug_Store`, with the flag values[6]), reads the debug object of the module, and gives one row for each frame with the procedure, the file and the line: `outsider_fault  visitor::fault_three  outsider/main.odin   169`. The caller must act for the principal of the program. The error unit `Stop_Reports` names a nickname with no kept report.
- **The grants of a disk program of a named principal persist across a restart.** A console that the desktop starts during the session of a named principal acts for that principal: its `allow`, `disallow`, `nickname_move` and `disk_persistence` change the disk grant table of that principal. The root service keeps that table as the object `grant_table` of the store `programs.principal.1`, with a tag under a key that `unlock` derives from the unlock key of the principal and gives with `Principal_Unlock` (values 0 to 3, and its origin in value 5). The root service reads the table at the first unlock of a run; a table that does not verify gives no grant, and is written over only at the creation of the principal.
- **A key sealed by the TPM, and a recovery key**: on a machine with Secure Boot on, `machine_seal()` gives principal 0 a machine key that the new TPM service seals to PCR 7 and PCR 11, so the disk grants of the machine persist with no passphrase, and an older or a changed system, or a copy of the disk on another machine, opens nothing. Before each unseal the TPM proves that it made the sealed object under the PCR values of its policy, so a record that another system on the machine wrote is refused. The window of `unlock` shows a recovery key one time; when the TPM refuses, that key opens the machine key, and with Secure Boot on `unlock` seals it again to the system that runs.
- **The nickname of a disk program with its hash in the monitor and the menu.** The menu of the windows, the palette and the monitor show a disk program by its nickname, with the hash prefix of its file (its first 16 hexadecimal digits) faded beside it, both from the root service that checked the bytes; the title bar shows the nickname alone. A mapping that does not fit in the 12 mappings of a start is dropped with one line of the log, no longer in silence. The record `Client_Add` of the control ring of the compositor holds the nickname and the first 8 bytes of the hash; the window of a disk program takes its nickname as its title, whatever title the program asks for. The new disk program page (`modus:contract/disk_program_page`, the fixed range `Disk_Program_Page`) holds the program slot, the program serial, the nickname and the whole hash of each disk program that runs; the root service maps it read-only into each program that it starts with the right Inspect. `Program_State` gives two more results: the program slot and the program serial. The monitor is 520 by 560 pixels, wraps a long name inside its column, and counts the programs whose rows do not fit; the menu of the windows is as wide as a nickname of 23 bytes with its hash prefix.
- **The IOMMU of AMD, with its interrupt remapping.** On a machine with the IOMMU of AMD, which the firmware lists in the ACPI table IVRS, a device reaches only the memory that its service declared with `Memory_Physical`, and sends only the message interrupts that `Device_Create` made for it, as on Intel: the same domains, declarations, device windows, end of a grant and lines of the log, behind one switch on the vendor. Each device with no service has an entry of the device table that refuses every access and every message. A refused access comes from the event log of the unit as the line of a DMA fault, with the device, the address and a count. `Device_Create` of the kind `Message` gives, on AMD, the address of the first processor and the index of the entry of the interrupt table of the device as the value. The virtual wire of the 8259 and the NMI of the chipset pass by the settings that the firmware gives their device. A reserved memory range of every device or of a range of devices, or two units that name one device, leave the IOMMU off, with one line. The line of a machine with no IOMMU now names both tables. `modustool test iommu_amd` runs the system on QEMU with `amd-iommu,dma-remap=on,intremap=on`.
- **A block device that drops a write, as a test.** `modustool test power` now runs the storage service on a disk that answers Ok to the write of one block of a commit and does not keep it. At the next start, the service refuses that commit with one line of the log and uses the commit before it, and the object reads its previous version.
- **The keys of a named principal sealed by the TPM, and their recovery key**: on a machine with the TPM service and Secure Boot on, `principal_create()` has the TPM seal the keys of the new principal to PCR 7, PCR 11 and the passphrase together, so another system, another machine or a copy of the disk opens nothing, and the TPM counts each wrong passphrase and then limits the rate of the tries, while its lockout hierarchy has an authorization value that an attacker does not know. The window of `unlock` shows a recovery key one time; when the TPM refuses, or when the passphrase is lost, that key opens the keys, and a new passphrase seals them again to the system that runs. The TPM service sends `TPM2_Shutdown` after each use of a passphrase that is not a counted failure, so a stop of the machine after an unlock counts no failure.
- **Keys that type characters outside ASCII.** A key record carries a code point: the layout of France gives é, è, ç, à and ù from their keys, and â, ê, î, ô, û, ë, ï, ü and ÿ from the dead keys `^` and `¨`. The line of the console, its history file, the search of the palette and a passphrase are UTF-8, and each key moves over or removes a whole character. Each glyph cache and Spleen draw the Latin-1 Supplement U+00A0 to U+00FF: the glyph cache is version 3, keyed by a character index of 191 characters, and the module `text_shaping` takes 191 advances.
- **The same object is kept one time.** The storage service finds the current object of a store by its hash, so two entries of one store with the same bytes take their blocks one time: an object of 1 MiB written under two names holds 261 blocks of the store, and the second commit writes no block of it. A change of one name copies only the path of the blocks that it changes, and a removal of one name keeps the other. The index is in the memory of the service and the open of the disk makes it from the entries, so a loss of power leaves nothing of it to repair; each candidate is confirmed from its blocks before an entry names it. While a store has a writable share of one of its trees open, its commits write their own blocks and add no root that a later write can find, so the holder of the share cannot learn what the rest of the store holds.
- **The wheel of a pointing device moves a view.** The input service asks the PS/2 mouse for the IntelliMouse protocol and reads its wheel; each wheel notch over a view moves it by three lines: the lines and the completion list of a terminal, the text of `manual`, the cards of `hall_of_fame`, a list, and the rows of the palette. Only the window in front gets the notches, as it gets the rest of the input. The log line `input: ok` is now `input: ok, the mouse has a wheel`, and a pointer record has a fourth value, the notches.
- **The hash of a disk program in the exports of the monitor.** Each row of `monitor.programs()`, and of `programs()` in the console, has a new field `hash`: for a program that the root service started from a disk, the whole BLAKE3 hash of its module file in 64 hexadecimal digits, from the disk program page, with its nickname as its `name`; for each other program, an empty text. The console and the host then read the file of a disk program that the window of the monitor shows, and `join` it with the rows of `manual.running()` by the hash.
- **A release publishes a disk image of the system.** `modustool release image` builds the release volume with the keys of the publisher of the system, puts it in a GPT disk for a USB key, compresses it with zstd, and writes `SHA256SUMS.txt` and its Ed25519 release signature in `dist/`; it refuses the test keys and every boot image of a test. `modustool verify` checks the signature, then the hash, and `docs/INSTALL.md` gives the same check with OpenSSL, the write with `dd`, and the setting of Secure Boot. The release workflow publishes the files at each tag `v<release number>`, the check workflow runs `nix flake check` at each push, and the home and the page of the releases name the files and the release signing key.
- **A release in one command, with a signed tag**: `modustool ship step` (or `correction`, or a release number) writes the release from the fragments, commits it, makes the annotated and signed release tag `v<release number>`, and pushes the commit and the tag to `master` in one atomic push. It refuses a branch other than `master`, a tree with changes that are not committed, and a `master` behind `origin`. When `origin` moved during the release, the push is refused and nothing goes out: `ship` undoes its commit and its tag, merges `origin/master`, and tries again with the next number, three times at most. `--dry-run` prints the number, the commands and the release, and writes nothing.
- **The console colors each field by its value kind.** An Integer field of a record states its integer unit in its description, from a type of the contract such as `value_kinds.Size_In_Pages`, and the checks of a record, of a replacement and of an import declaration compare it. The console draws a size and a time of a table or a record in the color of its kind, a time in the color of the boot program and a size and a number in the color of memory, with the unit once in the head of a column (`time (ms)`) or after the value of a record (`120 ms`). The palette shows the same colors. `memory()`, `modules()`, `measure_completion()` and `monitor.programs()` state their units: their fields are now `memory`, `free`, `used`, `reserved`, `budgets` and `free_no_budget_holds` in `memory()`, `size` in `modules()`, `collect`, `rank`, `rows` and `colors` in `measure_completion()`, and `resident` in place of `pages` in `monitor.programs()`.
- **AltGr on the layout of France.** With the layout of France, AltGr (the right Alt key) with the keys of the row of the digits types `#`, `{`, `[`, `|`, `\`, `^`, `@`, `]` and `}`, and with the key of `$` types `¤`. AltGr with the key of 2 and of 7 gives the dead keys `~` and `` ` ``, which type ã, ñ, õ, à, è, ì, ò, ù and their capitals, such as À. AltGr with `e` types no euro sign yet: the fonts do not draw it.
- **An entropy device.** A machine with the entropy device of virtio (`virtio-rng-pci`) starts the entropy service, and the root service mixes 64 bytes of the device into the generator that seeds each program after it, beside the sources of the processor and never in their place. A read of zeros, of one value, with no byte, or equal to the read before adds nothing and counts as refused; the seed strength does not change. A machine with no such device starts as before and says so on the log, and the window of `randomness` shows the device.
- **The program `manual` opens the links of a page.** A link to a term of the glossary or to a heading of a guide opens its link page, which the boot image carries in the new resource `manual_pages`, and a link to a record opens the page of the module that describes it. Tab and Shift+Tab move the focus between the links that open, Enter opens the link with the focus, and Backspace goes back to the page before. An address of another host is shown after its link and does not open. The table of all the modules moved from Tab to the key `o`.
- **A change of the passphrase of a named principal.** In a console of the session of a named principal, `passphrase_change()` opens the window of `unlock`, which asks for the current passphrase (the TPM counts a wrong one) and then for a new one two times; `recovery_key_change()` asks for the current passphrase and shows a new recovery key one time, and writes the file only after Enter. The window and the line of the console both give the end of the change: what changed, or why nothing changed. The keys stay the same keys. The console of the machine cannot ask, and a lock during a change stops it.
- **Error details for the kernel operations.** A kernel command can name a table of error details: bit 31 of its kind, and the address of the table in its last value (`system.call_with_error_details`). When the kernel refuses the command, the table gets the error record, then one error detail for each other argument that the kernel finds wrong: a handle, a count above its limit, an unknown flag, a choice out of its range. A table that is too small holds the first details and counts each one. A command with no table runs the same lines of the kernel as before: only the default branch of the dispatch, which already refused an unknown operation, reads the bit. `Log` and `Guest_Run` take no table. No kernel operation is added.
- **The euro sign.** Each font of the system draws €, and AltGr with `e` types it on the layout of France, so a principal writes a price such as `5 €`. € is the first added character past the Latin-1 Supplement: the glyph cache is version 4, with 192 characters, and the module `text_shaping` takes 192 advances.
- **The history of each measure, release by release.** Each release keeps a copy of the measure record in `docs/measures/releases/`, which `modustool changelog release` writes when a full check measured the release, and `modustool measure-history` gives the old release tags their copies. The page of the measured numbers draws one chart for each measure over the releases, from zero, with each number, its commit and the noise of the host.
- **The program `manual` shows a declaration that no module describes.** A link of the documentation of a module to a procedure, a type, a constant or a global variable of a support package or of a contract package, such as `system.word_wait`, opens its page: its file and its line, its one line of Odin and its comment. The build takes the page from the source, and the resource `manual_pages` holds one page for each such link.
- **A dropped write found before the next commit.** Each commit of the storage service now reads back the blocks that it wrote before it writes its root, then reads back its root. When the disk answered Ok to a write and did not keep it, the service refuses the commit with `Device`, unit `Dropped_Writes`, writes one line, and goes on at once from the commit before it, with no restart: the program loses that one commit, never the state of an object, and no root of a refused commit reaches the disk. The erase of versions reads back its second root and its zeros too, and counts as zeroed only the blocks that read back as zeros. `storage.stores()` gives the commits refused, the blocks read back and the time of those reads as a measure.
- **Glyphs drawn on demand**: the new font service `glyphs` draws characters past the 192 of the glyph caches into a demand cache that each program maps read-only. It draws its whole subset, the 47 Greek letters of B612, at its start, so the cache tells no program what another draws. The program `interface_font` shows the Greek letters.
- **Processor counters for a program.** A thread counts the instructions retired, the cycles, the cache misses and the branch misses of its own code, in user mode only, with three new commands of `Thread_Control`: `Start_Counters`, `Read_Counters` and `Stop_Counters` (`system.thread_counters_start`, `system.thread_counters_read`, `system.thread_counters_stop`). The start and the read take the machine handle with the new right `Counters`, which the root service gives by the new start grant `Counters`: a count of the misses of a shared cache is a side channel, as a precise clock is. The stop needs no right: it only takes a capability away. The kernel keeps the counts of a thread at each switch, so no count of another thread or of the kernel reaches it. The kernel programs the general counters of Intel (leaf 0xA) and of AMD Zen (the core counter extension); on a machine with neither, the commands give `Unsupported`. The program `counters` counts a loop of 1 000 000 turns and the same reads of 2 MiB in two orders. No kernel operation is added.
- **The deepest stack of the kernel, measured.** Each build prints the deepest chain of calls on the kernel stack of 16 pages, procedure by procedure, with the bytes that stay free, from the frames that `llc` writes and the calls of the linked kernel. It counts the two frames of `execute` of a command with a table of error details and one interrupt over the idle wait, and the build fails when less than 4 pages stay free.
- **A dark and a light appearance of the desktop**: the setting `appearance` takes `auto`, the default, `dark` or `light` (`settings.set("appearance", "light")`). With `auto` the desktop is light from 07:00 to 19:00 and dark at night, by the hours of UTC until the time zone is a setting. At a change each window draws once in the new colors: the background, the bar, the windows, the palette, the console and the windows of the interface package. The colors of the design rules are one table with a value in each appearance, and host tests compute each contrast that the rules name in both. The boot display stays dark, and the colors that a program owns keep their dark value. A test machine now has a real-time clock at 01:00 UTC of the day of the host, so the pictures of the tests are dark at any hour.
- **A program reads its own log records.** A caller of the log service that does not act for the principal now receives its own records from `log.records(after)` and `log.value_runs(after)`, in place of a refusal: the records with its program slot and its program serial, which the kernel now writes in each log record with the own number of the record among the records of its program. Its rows, its `after` and its `lost` count its own records only, so it receives no number or count of the records of other programs, and a new program in the same slot does not read the records of the program before it. A reader of the log never keeps a record that the kernel was writing over during its copy. The program `log_reader` checks it in the machine test, in two runs.
- **The action bar.** The line of keys at the bottom of a window is now the action bar of the interface package: each item is its key combination drawn as keycaps, then the name of its action, with a divider between two items, in the colors of both appearances. A press on an item runs its action, as its key does. The items that do not fit go into a list behind a button `more`, by the priority that the program gives; the list opens upward and takes Up, Down, Enter and Escape. A window can wrap its items on two rows instead. `manual`, the terminal, `settings`, `notes`, the debugger window, `unlock`, `interface_elements`, `tally`, `rings` and `paint` use it.
- **A starter reads the log records of its children.** The log service has two new exports, `program_records(program, after)` and `program_value_runs(program, after)`. They give the records of the program whose program handle the caller lends with the right Read, numbered by the own numbers of that program, and no record of another program. A starter holds the handle of each child, so a test reads what its children wrote without the right to read the whole log. A grandchild is read only with a handle that the child gives. A handle that names no program gives the error record `Handle_Kind`. The program `log_reader` starts two children and checks that it reads the one record of each child, and none of an earlier run.
- **A measure of the similarity of the code.** `modustool similarity` gives a similarity score from 0 to 1 to the code pieces of the Odin sources, groups the similar ones in families with the factoring template that a procedure can take and its blanks, and ranks the families by the syntax nodes that a factoring saves, each node counted once, with a home that obeys the import rules. `similarity near <file>:<line>` lists the procedures most similar to one, and `similarity pair` gives the score of two. It never edits a source; a family kept on purpose is a line of `tools/modustool/similarity_kept.txt`.
- **The machine passphrase and the TPM together.** On a machine with a TPM and Secure Boot on, `machine_passphrase()` has the TPM seal the machine key with the passphrase, in the record `MACHINEP`: the TPM counts each wrong machine passphrase, another system opens nothing even with the right one, and a recovery key, shown one time, opens the key and then seals it again to a new machine passphrase. A machine with no TPM, or with Secure Boot off, keeps the record under the passphrase alone, and a machine key sealed by the TPM with no passphrase keeps its form.
- **The time zone as a setting**: the setting `time_zone` is a fixed offset from UTC, from `-12:00` to `+14:00` by quarters of an hour, with `+00:00` as the default (`settings.set("time_zone", "+08:00")`, or a row of four buttons in the window of `settings`). The bar shows the local date and time, and the setting `appearance` `auto` turns light at 07:00 of the local time. The zone has no summer time: a principal in a zone with summer time changes it twice a year. The date of the system stays in UTC. The kept record of the settings has a new version, so the settings of an older disk read as the defaults once.
- **A machine test of zeros that the disk does not keep**: in `modustool test principals`, the disk of the change of the passphrase answers Ok to the write of zeros over the old file of the principal and keeps its bytes. The test checks the line of the storage service that reports the block, checks that the row of the erase counts only the zeros that the disk kept, and finds no part of the old file outside that block of the image.
- **Fresh bytes for a running program.** Every 30 seconds the root service reads 32 bytes of the entropy device, mixes them into its generator, and writes 32 bytes of its stream for each program in that program's own fresh bytes page (`modus:contract/fresh_bytes`, the fixed range `Fresh_Bytes_Page`), which it maps read-only into each program that it starts by its name, into the compositor and into each disk program. The generator of a program mixes a new change of its page into its key at its next refill and before a key or a child seed, never at each draw, so a key that a program makes late in its life has bytes newer than its start, and a reader who copied the state of a generator once loses it at the next mix. The first refresh writes one line of the log, a refused read one warning, and after 3 refused reads in a row the root service reads no more; a machine with no entropy device writes no fresh bytes. The window of `randomness` shows the mixes of its generator in a new row.
- **The recovery key of a named principal with no wrong try.** The passphrase prompt of a named principal whose keys the TPM seals has the item Ctrl+R "recovery key" in its action bar, as the prompt of the machine passphrase has: it asks for the recovery key at once, so a lost passphrase costs no try that the TPM counts against the principal and the machine. Enter with nothing at the recovery key goes back to the passphrase.
- **The font of the cells on demand.** The font service also draws the 128 box-drawing characters, the 32 block elements and the five Greek letters of Paper Mono (Λ, Ω, λ, μ, π) at its start, in Paper Mono with and without the grid fit and in Paper Mono SemiBold, and the terminal draws them in its cells: `character(9472) + character(955)` in the console shows ─λ. The demand cache keeps the glyphs of each of these glyph caches apart, and grows from 1 150 976 to 4 395 008 bytes.
- **The client keys of `remote` across a restart.** A client key that a principal allowed with `remote_allow` is now also a key of the disk grant table of that principal, under the tag of the table, so it lasts across a restart of the machine as the other grants of the principal do. After the read of the table, at the unlock of a named principal or when principal 0 gets its machine key, the key holds again with no new allow. A key that two principals allowed, one in the run and one in its table, is contested: it acts for neither of them, and `remote` refuses it in the handshake, until one of them revokes it. `remote_disallow` takes the key out of the table and is never refused: it starts the writes of a table whose writes failed again, a read of the run takes out a key revoked before it, and its result is now a sentence that says when the key can come back from the disk at the next start. An allow is refused while the table takes no change, as a change of a disk grant is. `remote_clients()` has a new column `state`: `holds`, `locked` or `contested`. The persisted table has the format 2, with 1136 bytes; a table of the format 1 is refused as an older format that this system does not read.
- **The byte layout of each record of the module file**: the guide of the module contract shows the header, the table directory and one record of each table as a diagram in rows of 8 bytes, with each field as a rectangle over its bytes, its type and its comment under the pointer. The tool takes the offsets and the sizes from the compiler and the types from the source, writes the same layouts as text in the guide, and `modustool check` fails when that text differs from the code.
- **One shared domain for the devices behind a conventional bridge.** The devices behind an older bridge of PCI, which give their accesses one shared requester, now work with the IOMMU on: they have one domain, which the kernel makes at the first declaration of a service only when that service holds the registers of each of them, and ends when it no longer holds one of them. A declaration that misses one gives `Bad_State`, with one line of the log that names the device. A device of the group whose registers come later, and that the service does not hold, ends the domain, and the message interrupts of the group arrive only while the domain lives. The root service gives every device behind such a bridge to the service of the first one that it starts: the registers of each other device come in the grants after its own BARs (`pci.GRANT_BRIDGE_DEVICE`). On AMD, the alias of the table IVRS to the shared requester is accepted when each of its sources is behind the bridge. The machine of `modustool test iommu_amd` has its disk of the measures and an entropy device behind a conventional bridge.
- **Fuzzing of the borders of the system**: `modustool fuzz` gives the readers of the module file, of the debug object, of the storage format, of QUIC and TLS, of TCP and of HTTP millions of inputs on the host, guided by the edge counters that LLVM adds to their packages, and minimizes each fault that it finds. `modustool check` runs the corpus of each fuzz target and a fixed count of new inputs with the seed of the sources.
- **A fallback chain of fonts by script.** A character past the glyph cache takes the first font of the chain of its script that has it, drawn on the baseline and at the cap height of the first font: the cells of the terminal draw the Greek letters of B612 that Paper Mono lacks (`character(945)` shows α), and the interface draws the box-drawing characters of Paper Mono. At its start the font service writes what each chain draws: 47 of the 49 Greek letters (no font has Π and ρ) and none of the 96 Cyrillic letters.

### Changed

- **One source library for a program of a third party**: everything that becomes the system is in the folder `src`, and the code that the programs share is one source library, `modus`, in `src/library`. A source imports a package by one name, `import "modus:support/system"` or `import "modus:contract/ring"`, in place of `"support:system"` and `"contract:ring"`, and the compiler gets one flag, `-collection:modus=src/library`, in place of two. A program outside the repository writes the same import lines and gives the same flag. The kernel gets the same library as a program, so the tool, not the compiler, now refuses an import of a support package in the kernel or in a contract package: each build stops on it with the file and the line, and `modustool library-imports` runs that check alone.
- **The icons of the site from the generator of the mark**: the icon file, the vector icon, the icon of a phone and the icons of the manifest are rows of the one table of the files of the mark, which `modustool mark uses` prints. The vector icon `icon.svg` is now the cells variant, one rectangle of one color for each run of cells, so the browser computes no color of the heron; the other icons keep their pixels.
- **The tool of the project is `modustool`.** The command `kerneltool` and the folder `tools/kerneltool` have the name of the system: `nix develop -c modustool <command>`, in `tools/modustool`. The tool builds the whole system, not only its kernel. Each line that the tool prints starts with `modustool:`.
- **The QUIC library follows two more rules to the letter.** Each PATH_CHALLENGE of a peer gets its own PATH_RESPONSE, for at most 8 challenges that wait; before, a second challenge replaced the first. A known extension of TLS in a message where the standard does not specify it now fails with illegal_parameter, and no longer with unsupported_extension.
- **A module states the budget that it asks for.** A module file has the new table `Budget`: the pages, the programs and the threads that its source states in the constant `MODULE_BUDGET`, with the reasons in its comment. The root service gives a program of the boot image its request up to 16384 pages, 8 programs and 32 threads, writes a line on the log when it gives less, and keeps two exceptions, each with its reason; a module with no request gets 2048 pages, one program and one thread. A disk program gets its request up to 8192 pages, one program and 4 threads, from one budget of 16384 pages, 4 programs and 16 threads that pays all disk programs, so a file of a disk cannot take what the programs of the system need. A start that fails for the budget names the part that is short. The new table changes the hash of each module.
- **The focus of a button is a white frame.** A button with the focus has a white frame of 2 pixels inside it. A button that is open, or that shows the value in use, is blue already, so the blue of the focus alone did not show where the focus was: after a go to of the palette, the frame shows the button that the palette went to.
- **The tool counts the parts of the budget that a module asks for.** The constant `MODULE_BUDGET` of a source now has the type `system.Stated_Budget` and states only what the tool cannot count: the working memory, the programs, the threads and the size of the window, as the constants `WIDTH` and `HEIGHT` that the program passes to `display.open`. The build adds the pages of the module and of each module that it imports, 68 pages for the first thread and 19 for each other one, and the two pictures of the window, and writes the sum in the table `Budget`; a module that grows asks for more with no change of its source. `modustool test descriptions` prints the four parts of each request, and the measure of a build has one line with the request of each module. The 39 programs that state a budget ask for the same totals as before.
- **A send with no copy in the network service.** The network device reads the data of each datagram and segment that a program sends from the datagram region of that program: the network service copies only the first 8 bytes of the header, for the check of the ports, and writes the headers of IPv4 and Ethernet. The frame service holds each datagram region with the right Read only, as a read region (the commands `Read_Region_Add` and `Read_Region_Remove` of the frame contract), so on a machine with the IOMMU the device reads it and cannot write it. The completion of a `Send` now comes when the device read the datagram, not after a copy: a program writes its place again only after it. When an endpoint ends, the log says how many bytes of the data the network service read on send: 0.
- **The programs that show a picture import the drawing module.** A Picture record now names its pixels by values: the number of its picture memory, the index of its first pixel there and its stride, in draw record version 8. The drawing module reads one picture memory of the program in place, and its exports are `damage_of_draw_table_8` and `execute_draw_table_8`, which draws one damage rectangle for each call. `heron`, `life`, `paint`, `plasma`, `processors`, `temple`, `threads` and `workers` draw their windows through it: 32 programs in all. The terminal and the compositor keep the interface package compiled in.
- **The terminal and the compositor import the drawing module.** A Text_Grid record now names its cells by values: `draw_text_grid` copies the cells into the text table of the frame, and the record holds their first byte, their bytes and the columns, in draw record version 9; the exports are `damage_of_draw_table_9` and `execute_draw_table_9`, with the same six parameters. The compositor draws its screen table in parts, one call for each window that a damage rectangle meets and one for the bar, each with the one picture memory of its surface. 34 programs draw through the module; the interface package has `difference_through_module` and `draw_part_through_module` for a program with no window layer.
- **An export takes more than six parameters**: an export takes up to 12 arguments, its parameters, the buffer of a result and the error record included; the first six go in registers and the others on the stack, as the C convention of the machine passes them. The console, the call from the host, a call host and a service call such an export, and the tool describes it and checks the declaration of its import. The module format is version 2, with a description of 168 bytes for each export, so a module of an earlier release does not load. The palette lists no command with more than six parameters: the console line calls it.
- **Text is UTF-8 in every contract**: the palette table (version 6), the result runs, the candidates, the typed values of the palette, the records of the terminal and the names of the objects of a store hold UTF-8 in place of the bytes 32 to 126, checked at each border by one rule that refuses an overlong form, a surrogate, a code point above U+10FFFF, a broken sequence and a control character. A writer cuts a text after a whole character, the cells of the terminal hold one character each (a cell of a text grid is a code point of 16 bytes: draw record version 10, exports `damage_of_draw_table_10` and `execute_draw_table_10` of the drawing module), and a character that the font lacks draws one replacement glyph, a box, never a byte. The names that are identifiers of the system (modules, exports, fields, settings, programs, channels of the log, and the name, act name, setting row and value of a palette entry) stay ASCII. A name of an object of a store with a control character or bytes that are not UTF-8 is now refused.
- **The IOMMU covers several units, bridges and reserved ranges.** The kernel programs up to 4 remapping units of Intel, as a real machine has, and gives each device the unit that the firmware names for it. A device behind a bridge of PCI Express has its own domain; a device behind a conventional bridge gets none, with one line on the log, because every device behind it shares one requester. A device that a reserved memory range of the firmware names keeps that range, so a machine with such ranges runs with the IOMMU on, and no program gets the range. An invalidation forgets only the domain of the device that changed. A domain lives while its service holds or maps the registers of the device. On a machine with the IOMMU, `Memory_Physical` accepts a memory object that is not contiguous and gives a device window where its pages follow each other, so the datagram region of an endpoint no longer needs 512 KiB of contiguous memory when the unit of the network device gives such windows; `Device_Create` of the registers of a device says whether it has a domain and windows, and `Boot_Report.iommu_unit_count` says whether an IOMMU is in use. `Memory_Map` refuses to map the registers of a device with a domain into another program. The test machine with the IOMMU has its disk of the measures behind a root port.
- **The drawing exports take the rectangles of a frame in one call.** The draw export of the drawing module is now `execute_draw_table_in_rectangles_10`: it takes the shape of the canvas (`Canvas_Shape`) and a table of up to 8 damage rectangles, refuses more with `Too_Long`, and draws them in order with the same pixels as one call for each rectangle; `execute_draw_table_10` is gone. A window crosses the border of the module 2 times for a frame with damage, where it crossed it up to 9 times, and draws all the rectangles of one frame in one font. The compositor makes one call for each part of its screen with all the rectangles that the part meets: at most 18 calls for a frame of 8 rectangles over 17 windows, where it made up to 144.
- **The temple of Jon is now a Hall of fame**: the program `hall_of_fame` replaces `temple`. It shows the 16 people whose work inspired modus, each on a card with the name and one line on what they made, in whole rows that the arrows, Home, End, the pointer and a scroll bar move. Five cards have a portrait with its author and its license under it; the others have no picture. The command `modustool portraits` replaces `modustool portrait`, and the page of the licenses has one row for each portrait.
- **The machines of the TPM run in the full check.** `modustool test trusted_boot` now runs the two machines of the measure, and `modustool test principals` runs the six machines of the machine key sealed by the TPM; the forms `test trusted_boot tpm` and `test principals tpm` are gone. The lost answer of the software TPM was a fault of QEMU 10.2 with its io_uring main loop, and the development shell now builds QEMU without io_uring: in two runs of each part, each of the 16 machines of the TPM had one `Startup` and no abandoned command.
- **A release gives its time**: the heading of a release in the changelog gives the day and the minute in UTC, `## [0.93.0] - 2026-11-15 18:48`, so two releases of one day keep their order. The releases page shows the time with "UTC", and the feed `releases.xml` gives the true time in place of 00:00. Each release has a release link at the end of the changelog, to its release tag. `modustool changelog times` gives an old heading the time of the commit of its release, and adds the missing links; an old release whose commit is not known keeps its day alone.
- **The reuse list of the properties is checked.** The reuse list of `docs/PROPERTIES.md` now names each work of others that the system ships or copies: the font subsets, Spleen, the Posy pointer theme, the cryptography of Odin and fiat-crypto, the runtime of the Odin compiler and `core:reflect`, and each portrait of the hall of fame, with its SPDX license and its license file. The candidates that the system does not use, the designs and the tools of the host left the list. `modustool check` refuses a work with no row, a row for a work that the repository does not hold, a license that is not the recorded one, and a missing license file.
- **The machines of Secure Boot with a TPM.** The machines of `modustool test principals` that seal the machine key and the keys of a named principal now run the firmware with Secure Boot on and a software TPM, on signed volumes, so the seal is tested on the rule of a real machine. The test build of the root service that sealed with Secure Boot off, and its two boot volumes, are gone. One machine starts the same system with Secure Boot off: only PCR 7 differs, the TPM refuses, and no new seal is made.
- **A release image holds the pointer theme of the system only.** `modustool release image` builds its boot image with the MIT pointer theme of the system, and refuses to package a boot image that holds the Posy theme, by its resource name or by the CC-BY-NC-4.0 license in the header of any pointer theme file. The release workflow and the checks of the flake no longer fetch the Posy theme; the default development shell keeps it.
- **Every service gives an error record.** Each export that fails now gives an error record, not a bare negative number: `manual.show`, `fill`, `total` and `span_total` of `sample`, `keep`, `hold` and `look` of `hostile_exports`, and the six draw exports of `interface_module`. The console prints why the call failed, as `error: manual.show: the argument name names none of the modules (-1)`. A refusal of the kernel inside an export names the argument of the export. `modustool check` refuses an export that gives -1, a negated status or a negative constant with no error record.
- **A name that names nothing gives an error record.** `manual.about`, `manual.signature`, `manual.problem` and `settings.get` with a name or a number that names nothing, `storage.stores` for a caller that does not act for a principal, and `next_prime` above 2^40 fail with an error record, where they gave an empty text, 0 or the text "no grant to see the stores". The console then writes the sentence, for example "error: manual.about: the argument name names none of the modules (-1)", and a caller tells an empty answer from a failure.
- **The pointer theme of the system has smooth edges, two forms and accents.** Its 15 shapes are outlines that the build draws with exact coverage at 24 and 48 pixels, in place of grids of squares: a fill inside an edge of 1 pixel at both sizes, with each level and upright edge on whole pixels. The dark form is white in a dark edge, the light form dark in a white edge; the compositor draws the form of the appearance in force, and changes it with the appearance at the next frame. The arc that turns in `wait` and `busy_with_arrow` and the question mark of `help` are in the blue of the focus, the slash of `forbidden` in the red of "stop a program", the dot of `crosshair` in amber. A pointer theme file has the version 2, with a form count, and a pointer manifest names its layers by role and its colors by token.
- **The light values of the colors that programs own.** Each window of the twenty programs that drew colors of their own (`monitor`, `clock`, `log`, `manual`, `rings` and others) now takes each color from the color tokens by its meaning, so it follows the light appearance with 4.5 to 1 for each text: the kernel entries are in the kernel blue, the pages in the color of memory, a wrong answer in the color of a failure. Three tokens are new: the warning color, the link color and eight series colors that tell apart the threads, the programs of the log, the records of a ring and the protections of a page. The boot display and the stage of `heron` stay dark.
- **The window of the log tells the records gone before its start from the records that it lost**: its top line and its line "log: ok, ..." now give two counts in place of one. "Gone before its start" counts the records that the ring no longer held when the window started, and says only how long the machine ran before it. "Lost since" counts the records that the window was too slow to read, and only that count is red when it is not 0. The main machine test requires "0 lost since", so a new line of the log before the window starts no longer fails it. The window no longer writes its count of the records of the kernel in the channel boot, which depended on the same length; it writes the records and the size of the memory of the log in its place.
- **The pushes and the indirect tail calls in the measure of the kernel stack**: the build now follows the stack pointer through each compiled procedure of the kernel. It adds the arguments that a caller pushes outside its frame before a call (32 bytes before `thread_create` in `execute`), and it takes a jump through a register where no frame stays as a tail call that needs a row with its targets. A chain in the measure line shows "(... bytes pushed for the call)". A `ret` or a tail call that finds bytes on the stack stops the build, so the scan proves its own reading. The margin of a quarter of each stack is now only for a chain of the graph that no input runs.
- **A machine whose hypervisor refuses the counters that it lists still starts**: each processor tries each access to the registers of the performance counters once at its start, before any thread runs, and a protection fault of that access is an outcome and not a stop of the machine. When the processor refuses an access, when a counter does not keep the value that the kernel wrote, or when the firmware left a counter on for another user, the kernel uses no counters, names the register on the line of the boot, and the commands of the thread counters give `Unsupported`. The self test 7 of the kernel proves the way back from a refused register on the test machine.
- **The roadmap has a section Maybe**: an optional last section holds what may be done one day and is not decided, and each of its entries says the ways open and what each waits for. The page Roadmap of the site shows it under the three columns, and the work that waits for a machine, a host or another project moved there from Next and Later.
- **The screen shows each frame of the compositor whole**: on the standard VGA of the test machine, the compositor writes each frame into the one of two screen pages that the display does not show, then a page flip of the display registers of Bochs shows it in one step, so a window that changes many times a second never shows a cut between two frames. The compositor reads each flip back, and goes back to one screen page with one line of the log when the display refuses it. `compositor.screen()` gives `page_flips` and `frames_on_the_shown_page`, which the main machine test requires to be 0. `Device_Create` has the kind `Display_Memory`: device memory over the video memory of a display, mapped with the page attribute of the framebuffer of the firmware and not with no cache, and accepted only for a range that holds that framebuffer. QEMU has no vertical blank to wait for.
- **Every window draws characters on demand.** Each program draws a character past the glyph caches itself, from the font outlines of the boot image (the new resource `font_outlines`), into a private glyph cache that its own budget pays and that no other program reads, so the labels, titles, menus and cells of every window, of the compositor and of a program from a disk show the Greek letters of B612 and the box-drawing characters of Paper Mono. The advance of such a character comes from its font file, and a frame never waits for another program. The font service draws its fixed subsets into the demand cache at its start, then ends; the request ring of each program and its budget of requests are gone. The first draw of a glyph costs 3 to 46 µs, once in each program (on an AMD Ryzen 7 5800X), and the cache keeps 256 KiB of glyphs, which it evicts in the order of their last use.
- **The check of the imports covers the whole system**: `modustool` now reads each source of `src/`, refuses a package of `core:` in a source that is not a test, and refuses a test that imports one with no `#+build !freestanding` as its first build line, with the file and the line of each breach. The files that the manifest of the cryptography of Odin names keep the imports of their origin.
- **The transport parameters that a side sends have a record of their own**: `transport_parameters_write` of `support/quic` takes a `Sent_Transport_Parameters`, which has a field only for each parameter that the system sends, so a value that the writer would lose cannot be set. The writer refuses, and writes nothing for, each record that would not read back to itself: an identifier that only a server sends in the record of a client, a server with no `original_destination_connection_id`, an identifier length out of range, and a value that the reader refuses. `transport_parameters_of_sent` gives the record that a reader finds in the bytes.
- **An idle timeout that QUIC cannot carry is refused at the start**: `connection_start_client`, `connection_start_server` and `server_init` of `support/quic` give `Bad_Value` with the unit `Milliseconds` for an `idle_timeout_milliseconds` over 2^62 - 1, in place of a `Too_Long` of the transport parameters later. A record of transport parameters that the writer refuses is now `Bad_Value` too; `Too_Long` means only that the parameters do not fit.

### Removed

- **The record documents are gone: each design is in its intent file.** The records of the decisions, of the choices of each step, of the reviews and of the hand-off are removed from the repository. The status page shows each property with what the test shows of it, with no list of gaps, the home shows no count of steps, and the planned work of those records is on the page Roadmap.

### Fixed

- **A window never shows a picture that is being drawn.** The surface of every window has two pictures: its program draws one while the compositor reads the other, and the compositor shows a picture only when it is complete. Before, 48 of the 51 programs with a window drew in the memory that the compositor read, and the screen could show a part of a new picture with a part of the old one. A program writes no code for the rule, the option `two_pictures` of `display.open` is removed, and `compositor.windows()` gives for each window the count `pictures_drawn_again`, which is 0 for a program that keeps the rule.
- **The pointer over the scroll bar of a terminal is the arrow**: the pointer kept the text shape over the scroll bars of a terminal window, such as the window of the console. It is now the arrow over a scroll bar and while a scroll bar holds the press, and the text shape over the text.
- **No text over a text, and no cut text, in five windows.** A text that is wider than its place in a window now goes on more lines: a line ends at a space, and a path or a long name ends a line after a `/`, a `:` or a `_`. The program `manual` draws a long name of its list on two lines and no fact of a page over another; `errors` and `inspect` show each frame of a stack trace whole; `notes` shows its keys and a version of 60 characters whole. The same rule holds in the other windows that had the fault: the answers of `fetch`, `net`, `imports` and `tables`, the sentences of `quic_echo`, `return_fault` and `fault_ring`, the targets of the requests of `server`, the columns of `pages`, the measures of `interface_font`, and the name of the processor on the boot display. The window of `log` shows each text whole and breaks a line at a space, where it cut a text at 80 characters and showed a word in two parts. The windows of `extended_state` and `fault_ring` fit the screen with their borders. A card that cannot show each of its rows says how many it does not show.
- **The picture of the program `notes` after a stop shows its note.** The picture `notes_crash` was taken before the program drew its first picture. The program now writes a line after that picture, the test waits for it, and the gallery of the site shows the picture.
- **A picture of the screen waits for the terminal that draws a window.** The tool took a picture when the program of each window was at rest. The window of the console is drawn by a terminal, which the condition did not read, so a picture could miss the completion list. The condition now reads each terminal too.
- **A machine test takes no picture while a window owes one**: a program that draws on its own clock, such as a terminal, now tells the compositor when a change waits for its next picture (`display.picture_due_set`), and `compositor.windows()` gives it in the field `due`. The condition of a picture of the machine tests waits until no window has a due picture. Before, a picture of the console could show the head of a table without its row.
- **A virtio device service takes the places of the registers only inside its memory**: a capability whose registers are not inside the memory of its BAR, or a notify register of a queue outside the notify registers, is refused, and the block, frame and entropy services stop with a line that names it, in place of a fault on an address that is not mapped. The size of each queue is a power of two, so its counters stay in order when they wrap.
- **The tail of the arrow pointer sits on its axis.** The tail of the system arrow now leaves the head centered on the bisector of its point, in place of hugging the notch, in the arrow, the busy arrow and the help arrow.
- **The share policy counts a thread that starts and ends between two rounds.** A program could create threads just after a round of the share policy that ended before the next one: no round saw them, and each one had the whole program weight. A thread and a program now each have a new-thread weight limit, which only the machine handle writes: a new thread gets the smaller of the two as its weight limit, and `Thread_Create` refuses a weight above it. Two new commands of `Thread_Control`, `Read_Program_Schedule` and `Write_Program_Schedule`, read and write the value of a program. The share policy writes the program weight divided by 32 to each program before it reads its threads, so after the first round of a program the threads that no round saw sum to under one program weight. `op.Thread_Schedule` grows from 12 to 16 bytes, and a new-thread weight limit above 1024 is refused. The kernel still has 33 operations.
- **A log record is never read half written.** A reader of the log, the window `log` and `log.records` included, could keep a copy of the oldest record of the ring while the kernel wrote the next record over it: the head of one record with the text of another. Such a record now counts as lost, as the records that the kernel wrote over do, so a reader copies the last 2046 records at most.
- **A word that names no choice is refused, and never read as a known one**: `unlock` stops with a line of the log for a mode that names no mode, where it ran an unlock; a seed whose strength names no strength is refused, where it was read as the strongest; the root service refuses a word of the root ring that names no action, state, change or origin; the console says that a state of a client key or a cause of a refused change names nothing, where it showed "holds" or "the mode is not a change"; a twin of `frames` stops for a mode that names no mode, where it slept. `modustool rule-checks` refuses a family of integer constants that the code uses as a closed set of choices.
- **A terminal that always draws the end of an output**: a record that comes while the terminal draws a picture now makes a due picture before the terminal waits for its next frame. Before, the terminal waited up to 16 ms with that change and said that no picture was due, so a machine test could take a settled picture of the console that showed a running call and not its result. The stop of the program of a terminal now ends its wait at once, where it waited up to 250 ms, and a frame whose `Present` did not reach the compositor is drawn again at the next frame, where the older picture stayed until the next record or key.
- **The serial port keeps up with an idle machine**: since `Log` stopped writing the serial port, only the ticks wrote it, 100 µs at each, about 4.5 KB in each second for a processor under KVM, where a port write costs 22 µs; the boot writes about 120 KB of lines, so the serial port lagged the system by seconds, and a test that acted on the moment of a line acted too late. A processor with nothing to run now writes the serial port at the rate of the port, with a window for interrupts after each byte, and leaves at once when a thread becomes ready or an interrupt comes. On a machine with an idle processor, a line reaches the serial port about when its program goes on. A machine whose processors are all busy still drains at the ticks only. The measure line of the drain now says the bytes of the idle loop and of the ticks, and the serial port ends each run with the largest lag of a line.
- **One debug record for each int1 under KVM on AMD**: KVM with SVM before Linux 7.3, on some AMD processors, gives an `int1` whose delivery it cut again as a fault at the `int1` itself, so the program got two Debug records, the first at the address of the instruction with the status 0. The kernel now drops a debug exception with no status at a byte F1 whose byte before is not F1 or cannot be read: the thread runs the `int1` again and gets its one record. A cut `int1` after any byte F1 (another `int1`, or an instruction such as `89 F1`), or with a prefix, still gives its record two times. The root service no longer sizes the base address registers of the standard VGA while the screen shows it: that turned its memory off, and under KVM it threw away every nested page table of the machine, which made the case `int1` of `test fault_ring` fail at each run on an AMD host.
- **The cut of a loss of power at a counted commit**: in `modustool test power`, the disk that the tool serves counts the commits itself and loses its power at a commit that the case names, so the cut falls in the loop of range commits of `ranges`, in the count of `notes` and in the records of `settings.repeat(1000)` whatever the speed of the machine and the lag of its serial port; before, the tool cut a few writes after it read a line of the log, and the cut of `ranges` often came after the end of its loop, so no write came and the test failed.

### Security

- **A module replacement needs a signature.** The root service no longer writes any pair of modules that the console names into the replacement table: a replacement puts the code of another module into each importer, such as the drawing module into the compositor and the terminal, with all their memory and handles. It writes a replacement only for a replacement row of the boot image, the resource `replacement_list`, whose Ed25519 signature over the old hash, the new hash and the importer scope verifies under the signing key of the system. The build signs the rows with the key that signs the system description. `replace("calendar", "math")` is refused with "root: refused the replacement of calendar by math: no signed row of the replacement list names it", a row signed by another key with "... the signature of its row does not verify under the signing key of the system", and the importer keeps the module that its import names.
- **The kernel checks the text of a line of the log**: a program that called the operation `Log` itself could write a carriage return, an escape sequence or a control character of C1 to the serial port, and forge or hide a line on a terminal of the host; a program could also name a child program with such bytes, and that name starts each line of the child. The kernel now writes `?` in place of each byte of each invalid sequence of UTF-8 in its copy of the text, ends a record of the log after a whole character, and `Program_Create` refuses a name with a byte outside the visible characters of ASCII (`Bad_Operation`).
- **A share of a tree no longer reaches the root of its store.** The holder of a share of one tree could call `storage.open_store` with the name of the store of its maker, get a place on the root of that store, and read and change the whole store. A share now names no store: `open_store` refuses it with `No_Grant`, unit `Acts_For_Principal`, as for any other store.
- **A share of a tree sees the counts of its own tree only.** `storage.usage()` through a share of a tree gave the counts of the whole store, so its holder could learn whether the rest of the store holds the bytes of an object of its tree, or whether the maker wrote bytes that it guessed. It now gives the objects, the trees, the versions and the blocks of that tree only, from a walk of at most 4096 reads; a larger tree gives `USAGE_NOT_COUNTED`. A root that the storage service finds damaged now leaves the hash index, so a rewrite of the damaged object can share its blocks again.
- **A lockout authorization value that the TPM service sets**: before the first seal or unseal with a passphrase in a run, when the lockout hierarchy of the TPM has an empty authorization value, the TPM service sets a random one that nothing keeps, and at each start it writes the count limits of the TPM on the log. Before, any other system on the machine could reset the count of the wrong passphrases of a named principal, or change its limits, with `TPM2_DictionaryAttackLockReset` or `TPM2_DictionaryAttackParameters`, and then guess in the window of `unlock` at the cost of Argon2id alone; now the TPM refuses both to every system. A start that uses no passphrase with the TPM leaves the lockout hierarchy as it found it, a value that is set already is left as it is, and a clear of the TPM needs the menu of the firmware.
- **A system description that cannot be rolled back**: a signed system description stayed valid for ever, so an older system with a known flaw, or a system that a stolen signing key signed, started on each machine. Now the TPM keeps floors that only rise: the boot program refuses, before the kernel starts, a boot program whose key number is below the key floor, and a system description whose security version is below the version floor of its key number. With Secure Boot on, the boot program then raises the floors to its own numbers before it measures the system, under a policy that no kernel or program satisfies, and it replaces an index that another system planted. The header of the system description has the security version (format 2, 24 bytes), and `resources/keys/key_numbers` gives each signing key its number, the key of the publisher 2 (`docs/TRUSTED_BOOT.md`, "10. The TPM floors").
- **The old versions of the file of a principal are erased.** A change of the passphrase or of the recovery key of a named principal, and the new seal after a recovery, left the file from before as a version on the disk, which opened with the old secret. Now `unlock` erases the versions of the file after each such write and after each unlock that the current file opens: the new export `storage.erase_versions(place, name)` ends each version of an object in one commit, reads its blocks back, writes the root again so that no root on the disk names a freed block, and then writes zeros over each freed block that no other state names. Only a program with the new start grant `Versions_Erase` may call it; today that is `unlock`. A loss of power leaves the versions or none. A copy that the disk device or the host keeps under the blocks is not reached.
- **A grant for the key of a client of `remote`.** A client of `remote` now proves an Ed25519 key of its own in the QUIC handshake (mutual TLS 1.3 with raw public keys), and `remote` takes only a key that a principal allowed with `remote_allow(key)` in a console that acts for it. Each call of that client acts for that principal, and for no other. A key that no principal allowed is refused in its handshake with access_denied, before any call, with one line of the log. `remote_disallow(key)` and a lock of the session of the principal end the grant: the root service ends the connections to services of that key, and `remote` ends the open connection of the client with the code Revoked. `remote_clients()` lists the keys of a principal; one principal allows 4 keys at most, of the 8 of the machine. Before, `remote` admitted the host by its address alone, and each program of the host called as the principal of the session of `remote`. `modustool run` prints the key of the client of its peer, which the console allows.
- **A log ring for each program.** The kernel keeps the last 64 log records of each program in a ring that only that program fills, paid by its own budget, and the log service reads the own records of a caller there with the new kernel operation `Log_Read` (the kernel has 35 operations). A log storm of one program no longer pushes out the records of another, so a reader of its own records learns nothing of how many records the other programs wrote; the whole log keeps every record, in order, for a reader that acts for the principal.
- **Two reads of hostile bytes that a bound did not catch.** A module whose import slot names a place near the top of the address space no longer passes the check of the loader and stops the root service; a node of the disk whose reference to a slot is out of the pool is a damaged node, and no longer reads before the pool. The fuzzing of the borders pointed at both.
- **A log limit and a log time that the other programs do not set**: a program that read its own log records could still learn how much the other programs wrote, from a `Log` that the kernel refused while its own count was low, or from the time of a `Log`. The log records of each second are now an amount that a budget holds, as its pages: a child budget takes them from its starter with its part of the count of this second, and gives both back at its end; a budget counts only its own records, and a `Log` spends each record that its text takes. `Budget_Read` gives the records that a budget still holds after its children. A program still gets 1000 records in each second, and a starter divides its own among its children. The kernel writes at most 64 records of its own in each second. `system.log` never waits: a refused line is dropped and counted, the next accepted line comes after one record "<count> lines of this program were refused by its log limit", and the kernel writes the count at the stop of a program whose refusals no later line said. `Log` no longer writes the serial port: the tick of each processor writes the lines of the new records in their order, only while the device takes bytes and for 100 µs at most, and the kernel writes the lines that are left before the machine stops, before the report of a fault, and in a wait for a lock longer than 1 s. In a flood the serial port can lose lines: it says how many, and each scenario of the tool fails on that line.
- **Module records protected from their program.** A program could remove or replace the module record that its starter wrote, or unmap the code of that module and map its own code there, so a report named its code by the hash of another module. The kernel now writes the writer of each module record (`op.Module_Writer`: `starter` or `program`; the record grows from 80 to 88 bytes), and refuses with `No_Right` and the new error kind `Starter_Module` a `Program_Module`, a `Memory_Unmap` or a `Memory_Map` of a program in itself over a record of its starter; an address that the kernel chooses avoids such a record. The starter keeps each right. A program handle that `Handle_Give` copies into the program that it names loses Control and Give, so a program cannot pass the authority of its starter to a child. A disk program built before this change must be built again: `Stop_Report` and `Module_Report` grew, and `Program_State` writes the new size. `inspect.modules()`, `manual.running()` and `program_modules()` have a field `writer`, and the program `imports` writes `imports: the module record of the root service: 4 of 4 changes refused with Starter_Module, writer starter; calendar, loaded by this program: writer program`. The kernel still has 35 operations.
- **No window of `unlock` outlives a lock.** A lock now also stops the window of `unlock` that the session asked for: the setting of the machine passphrase, the seal of the machine key, a change of the passphrase or a new recovery key. Before, anyone at the keyboard of the locked machine could read the recovery key of a new machine passphrase or set the machine passphrase. Each window that shows a new recovery key writes its record or its file only after Enter, so a lock, a close or a fault before Enter leaves the disk as it was, and no recovery key that nobody wrote down opens anything. The creation of a principal starts its session after Enter too.
- **A module table of records of no byte is refused.** A module file of 80 bytes could state 67 million segments of no byte: the check of the loader accepted it, then each loop over the table ran for minutes, and the start of the program never ended. The loader now refuses a table that has records and states a record size of 0, so the bytes of the file bound the count of its records. The fuzzing of the module file found it.

## [0.92.0] - 2026-11-14 12:08

### Added

- **The boot verifies a signed system description and measures it**: before the kernel starts, the boot program verifies the Ed25519 signature of the system description, the list of the kernel and of each module and resource with its BLAKE3 hash, then compares each file with it. One changed byte or a wrong signature stops the boot, with the file and both hashes on the boot display. The firmware then extends PCR 11 of the TPM with the SHA-256 hash of the description, and the root service checks the boot image again before the first program starts. The boot display says which key signed the system, and says "not trusted" for the test signing key of the repository. Nothing verifies the boot program itself until Secure Boot is built. `kerneltool key new` writes a signing key outside the repository; `kerneltool test trusted_boot` runs four machines, two of them with a software TPM.
- **Secure Boot verifies the boot program**: the build signs the boot program with a firmware signing key, an RSA key and its certificate, because the firmware cannot verify Ed25519. With Secure Boot on and that certificate enrolled, the firmware starts only the signed boot program, and the boot display says "verified by: the firmware (Secure Boot), then the boot program". A signed boot program with one changed byte, and an unsigned one, never start. `kerneltool key new` now also makes the firmware signing key. Beside each boot volume, a file says which key signed it, and that a volume signed by the test keys must not be installed on a real machine.
- **The console colors its code**: the line that the person types, the line that it writes back, and the signatures in the completion list show functions, types, texts, numbers and punctuation in the colors of code of the site, from one table of the system. A name that the console does not know is marked quietly once the person typed past it, and a text with no end quote keeps the color of a text while it is typed.
- **The foot of each page names the maker**: "modus · by Froment Software", with a link to its site.
- **Every fault kind of a thread can go to the fault ring**: a fault handler names the kinds that it takes (divide error, invalid opcode, protection fault, breakpoint, the floating-point errors, and page faults), and a fault of such a kind becomes a record with its kind and its error code in place of a stop. A breakpoint answered Resume goes on after its int3; Resume after a fault other than a page fault is refused, so a handler cannot make a thread fault again forever, and Stop gives the report of the fault. A handler that asks for nothing gets page faults only, as before. A program with no handler that runs int3 now stops on a breakpoint, not on a protection fault.
- **A program stops one of its threads, reads and writes its registers, and resumes it**: the new kernel operation `Thread_Control` (33) has six commands: `Stop`, `Resume`, `Read_Registers`, `Write_Registers`, `Read_Extended_State` and `Write_Extended_State`. A stop is a count: two stops need two resumes. A thread of another program needs a thread handle with `Inspect` to stop, resume and read it, and with `Inspect` and `Write` to write it; `Control`, the right to end a thread, gives neither. The kernel refuses a written frame with the code selector of the kernel, an I/O privilege level, interrupts off, an instruction address that is not canonical, or an extended state that the processor would refuse, and nothing changes. `Thread_State` gives the stop count and the size of the extended state area. After a write, `Fault_Answer` accepts `Resume` for every fault kind: a handler can skip a divide error. The kernel has 33 operations.
- **Principals: the machine, one named principal, its unlock and its session**: principal 0 is the machine, with the measure of the system. `principal_create("name")` in the console creates a named principal whose passphrase is typed in the window of `unlock`; Argon2id derives the key that seals its keys, a wrong passphrase opens nothing, and `lock()` stops the programs of its session. A program that the desktop starts during the session has stores of its own, and `grants` names the principal of each program. The seal by the TPM, recovery and the encryption of the stores are not built (`docs/PRINCIPALS.md`).
- **Code spans link to the declarations of the sources**: a procedure, a type, a constant or a global variable that a guide, a news entry or a source comment names links to its line or its module page, with the icon of its kind and a card that shows its line of Odin and its comment; a span that is a fragment of Odin is colored.
- **A stop report names its procedures and its source lines**: the build writes a debug object for each module (its procedures and its line table, made from the DWARF of the compiler) and puts them in a debug image beside the boot program, not in the boot image. The console, `errors` and `inspect` now show a frame as `fault::three + 0x8 in fault (programs/fault/main.odin:15)`; the module bytes are the same with and without debug information, and `kerneltool check` proves it with a third build.
- **The module graph on the site**: a page of the reference draws each module and program of the build as a bar as long as its bytes, and each import as a line, in columns by the depth of the imports; a pointer or the focus on a module marks its imports and its importers and shows its identity card, and a table under the picture gives every import. Each module page shows its identity card and a figure of what it imports and what imports it.
- **The imports of what runs**: `manual.edges()` gives one row for each module of each program that runs, with the module of the same program that imports it and the module that a replacement put it in place of; the console combines it with `where` and `columns`.
- **The log shows each value in the color of its kind**: a log record keeps where each number, size, time, module, hash and status of its text is, and the program `log` draws each one in the color that the site gives its kind, with a legend, and without the start of a text that repeats its program and channel. `log.value_runs(after)` gives these runs as a table. The text of a record and the serial port do not change; a record now has 152 bytes of text, and the operation `Log` takes the runs in its seventh value.
- **The reference pages render the source comments as Markdown**: bold, italics, lists, examples in code and links to operations, exports, declarations, terms and guides. A link that names nothing stops the build of the site. The 33 kernel operations, `manual`, `cryptography` and the exports of `storage` have a full text: arguments, results, statuses and the rights in bold. A module carries the same text with the marks removed, so `manual` and the help of the console show plain lines as before.
- **The debug object of a module describes its variables and its types**: beside the names of the procedures and the source lines, it now holds the types, the global variables, and the parameters and the local variables of each procedure, each with its range of instructions and where its value is (a register, or memory at the frame pointer, the stack pointer or another register plus an offset; "not readable" when the compiler gives no such location). It also holds the BLAKE3 hash of the content of each source file at the build, so a reader shows a source line only from the same version of the file, and it is used only for the module whose hash it names. The module file does not change, and two builds give the same debug object.
- **A program sets the weight and the request of a thread that runs**: `Thread_Control` has two new commands, `Read_Schedule` and `Write_Schedule`, with the record `Thread_Schedule` (weight, request, weight limit). A program lowers the weight and the request of its own threads, and never raises them; a thread handle reads with Inspect and lowers with Control; the machine handle with Schedule and Inspect names any thread by its machine number, which the thread report now gives (`Thread_Report.machine_number`; the record grows from 72 to 80 bytes), and it alone raises a weight or a request (a raised thread starts again as a new thread for its strategy) and writes the weight limit of a thread: the thread and the threads that it creates then stay at or under that weight. `Thread_Create` refuses a weight above the weight limit of the calling thread. The kernel still has 33 operations.
- **The kernel parts of a debugger**: a program with the right `Debug` on the handle of another program becomes its debugger. It receives the debug exceptions and the breakpoints of that program, sets four breakpoints for each thread (an instruction, or bytes that the thread writes or reads) with no write to the shared code, runs a thread one instruction at a time, and reads the memory of the program, one page at most in each read. When the debugger ends or detaches, the kernel gives the program back each thread that the debugger held. The kernel still has 33 operations. The commands of the console are not built yet.
- **The placement of a thread on the processors**: each thread has a set of the processors that can run it, which `Thread_Control` reads and writes while the thread runs (`Read_Placement`, `Write_Placement`; no new kernel operation). A program only narrows the set of its own threads. The holder of the machine handle with `Schedule` and `Inspect` writes any set and a limit, which a new thread and a started program get from their creator: two programs whose limits share no processor never run on the same processor. A thread that never gets a placement is scheduled as before.
- **The debugger: a service, and its commands in the console**: `debug("clock")` attaches the service `debugger` to a program, and `break_at`, `watch`, `threads`, `hold`, `resume`, `continue_all`, `registers`, `stack`, `locals`, `value`, `source`, `step`, `step_line`, `debug_memory`, `events`, `wait_stop` and `detach` give tables with the procedures, the lines, the types and the variables of the debug objects. The root service gives the debug access by one rule over grants, with no name of a program: the caller acts for the principal of the program, and holds each grant that the program holds; a program with no grant can be debugged, and a service, a device service and a program with a private store, a terminal or an endpoint of the network cannot. A revocation of a grant of the caller ends a debugging that the rule no longer gives. The same exports are called from the host through `remote` (`kerneltool call <key> "debugger.stack(0)"`), and the tool prints the source line from the repository when the file has the hash of the build. The kernel did not change.
- **A news entry can show a film**: an entry names a film with the line `film: docs/films/<name>.webm`, and the page of the news plays it when the reader starts it, with the picture of the entry in its place before that. `kerneltool film <name>` now writes a WebM file with AV1 beside its MP4 file, and puts it in the repository when an entry names it: for the film of the palette, 36.8 s of the whole screen, 1 572 784 bytes, half of the MP4 file. The entry of the palette has its film; the feed `news.xml` names it as an enclosure.
- **Each row of the palette has the icon of its kind**: a window, a program, a command, an export, a setting and an entry that destroys each have their own picture of 12 by 12 pixels at the left of the row, and the word of the kind stays at the right. The color of the icon says one fact, as the square mark did: a program that has a window is green and one that has none is dim, the window that has the focus is blue, the value of a setting in use is in the text color. The candidates of a field of a form have the icon of a module or of a grant. The icons are one table of cells, `support/kind_icons`, that the site draws too: a module or a command has the same picture on the site and on the desktop.
- **The program `heron` plays the animations of the mark**: start it from the menu of the programs or with `start("heron")`. The heron stands in its water in a window and plays its fifteen animations by the rule of the home of the site: each one once in a round, in an order of chance, still for about 40 % of the time. In the dash it leaves the window by the right and comes back by the left. A squash, a stretch and a travel are in whole square cells; the key `g` draws them in a free way to compare. The keys `1` to `9` and `a` to `f` play one animation, Space pauses, `.` shows the next frame, `s` plays slower, `l` shows the lines of the cells and the cells that a frame changes, `z` changes the cell size. The exports `heron.play("dash")`, `heron.animations()` and `heron.grid(1)` do the same from the console.
- **The site has a gallery, and the home a carousel**: the page Gallery shows 109 pictures of the screen in 11 groups, each with a caption of one sentence and a link to its guide; a picture opens at its full size. The home shows 8 of them in one row, one picture in view, with a numbered link to each; it works with no script and never changes its picture by itself. A picture of `docs/screenshots` that the table of the gallery does not name stops `kerneltool site`.
- **The program `heron` has a film**: `kerneltool film heron` films the heron while it plays, the dash at full speed and four times slower, the dash frame by frame with the changed cells outlined, one frame in the free way and on the grid, and the three cell sizes. The news entry of the program shows the film.
- **One generator for the pictures of the mark**: `kerneltool mark` writes the still mark, a frame of an animation, a tile map or its table, in the smooth variant (each pixel takes the gradient at its own place) or in the cells variant (each cell is one color), at a cell size and in a color scheme that the command names. The head of the home of the site and the window of the program `heron` keep the smooth variant; the bar and the icon of a tab are the cells variant, one pixel for a cell. The files of the mark of the repository and of the site are now one table, which `kerneltool mark uses` prints, and each PNG file of the mark is written at the smallest size that loses no pixel. A request with no sense, as the smooth variant at one pixel for a cell, is refused with a sentence.
- **The roadmap**: the planned work of the system is one file, `ROADMAP.md`, in three sections: what is in work now, what comes next, and what comes later. Each entry says what the work gives the user. The site shows it on the new page Roadmap, beside the page Releases, and the search finds each entry by its summary. `kerneltool roadmap check` checks the form of the file, and `kerneltool check` runs it.

### Changed

- **`remote` over QUIC**: the calls of the host go to `remote` over QUIC, one stream for each call, up to 8 at one time, with the public key of `remote` pinned by the host; its own datagrams are gone. Its listen grant admits the address of the host only, and a Retry proves that address, where one forged datagram made a call before. `kerneltool call` now takes the public key that the window of `remote` shows, and gives the call to the peer of the tool on a socket that only its user reaches.
- **The bar of the site stays at the top.** On every page of the site, the bar with the sections and the search stays at the top of the window while the page scrolls. A link to a heading or a symbol lands under the bar, not behind it.
- **References to documents on the site**: a comment of the source that names a document, as `(docs/ARCHITECTURE.md, "Kernel systems")`, is now a link with the title of the guide and the heading ("Architecture: Kernel systems") in a line "See:" after the text, with an icon of its own; code in backticks in a comment is shown as code; a guide that names another guide links to the heading too; the page of `kernel_without_return_check` says that it is the kernel built with a test setting; and `kerneltool site` stops on a pointer whose heading does not exist.
- **The tables of the site have their natural width, and a link goes to its anchor at once.** A table is as wide as its content needs, so a column of numbers or of names no longer holds empty room. The page no longer scrolls by itself to an anchor: it is there at once, also after a reload.
- **A chosen row keeps 4.5 to 1**: the chosen line of the completion list, of the menus of the bar, of the launcher and of the lists of the interface is now a slightly darker blue, where its white text has 4.67 to 1 in place of 4.29. A matched character on a chosen row of the completion list is drawn as the chosen blue on a white cell.
- **One Docs section on the site**: the bar names Docs, Status, News and Releases; the guides are now at /docs/guides/ and the reference at /docs/reference/, and each old address, in the .html form or the folder form, sends the reader to the new page. The new page /docs/ is the home of the docs: a large search field over the whole site, what the search knows, a card for the guides and a card for the reference with their counts. The bar of that page has no search field; every other page keeps the field of its bar.
- **A chart of what the search finds on /docs/**: the paragraph of counts under the search field is gone. Under the cards of the guides and of the reference, a bar chart gives the count of each kind of entry of the search, the largest first, each with the icon and the color that the list of results now shows for it, and a link to the page that lists the kind. While the field holds a text, each row shows how many entries of its kind match, and a press on a row keeps the list of results to that kind.
- **The cards of /docs/ list everything**: the card of the guides shows every guide with one line that says what it holds, and the card of the reference every reference table with its count. The chart of the search is under the reference, and no card has an empty part.
- **The card of the boot image names its files**: a size strip shows the bytes of each file by kind, and one row for each kind (programs, modules with no entry, resources) gives its count, its bytes and the whole names of its largest files; the boot image of the last build shows 12 names, where the grid of tiles showed 2. A line "check" counts the verified files, or names the file that failed its hash whole and in red, also in the strip and on its tile.
- **No test depends on the speed of the computer that runs it**: a time in a test only ends a test that hangs, with one generous bound (120 s for each step of a machine test, 60 s in the checks of a program, a stall of 60 s with no progress for a long case), and a number of speed is printed, never checked. The idle end of a QUIC connection and the bounds of a call stream of `remote` now check only that the end came no earlier than its bound, and print how late it came; `scheduler` checks that a wake ends turns under EEVDF and none under round robin, and prints how many times as often EEVDF woke as a measure.
- **A store holds trees of entries, and a program can give a part of it**: a store names one tree, and a tree holds objects and trees inside it, each tree a B+ tree on the disk with no limit of entries but the disk (the table of 39 objects is gone; the disk format is `STORAGE3`). Each export of the storage service takes a place (0 is the root of the connection) and a name of one step: `..`, `.` and `/` are refused. New exports: `open`, `close`, `add` (256 entries in one commit), `list` (a page in the order of the names), `rename`, `share` and `unshare`, `open_store` (the exports of versions take a place of it in place of the name of a store) (a connection rooted at a tree, read only or not, revoked by the kernel), `usage`; `remove` of a tree frees its blocks in steps after its commit; `objects` is gone. The program `hierarchy` makes 100000 objects in 1100 trees and checks them after a new start (`docs/STORAGE.md`).
- **The grant person is acts_for_principal**: `revoke("remote", "acts_for_principal")` in place of `revoke("remote", "person")`; `isolated.CALLER_PERSON` is `CALLER_ACTS_FOR_PRINCIPAL`, and the grant of a connection carries the number of the principal of the caller in bits 48 to 62. A refusal says "to act for the principal". `flood` writes "flood: Space: ...", and the console "error: Escape stopped the call of ...".
- **The chart of the search is under the search field of the docs home**: one bar of colored segments and one row of chips, one for each kind of entry, over the whole width, so the reader sees it change while typing; the list of results opens under it.
- **The scroll bars of the site have the form of those of the system**: a button with a triangle at each end, a square thumb with a grip, blue under the pointer, in both color schemes; Firefox shows their colors.
- **An object of a store is a tree of blocks, written by ranges**: an object can hold 4 TiB, and a block of zero bytes is a hole that costs no block (an object of 8 GiB from three writes holds 13 blocks; the limit of 32 blocks and the format `STORAGE3` are gone, the disk format is `STORAGE4`). New exports of the storage service: `read_range`, `write_range` and `set_size` (pending changes of the connection, with no commit and no hash) and `commit` (one commit of the pending changes, with the counts of the blocks that it hashed and wrote). A commit hashes the blocks that it changed and the nodes above them, never the whole object: 1000 writes spread over an object of 8 GiB hash 1001 blocks and 1018 object nodes. The check of a block of data is its BLAKE3 chaining value at its place, and the hash of an object comes from those values; a hole counts as zero in it. `write` and `read` of a whole object use the same mechanism. The program `ranges` and `kerneltool test ranges` test it, and a third loss of power comes in a loop of range commits (`docs/STORAGE.md`, "Large objects").
- **The glossary explains each term**: a term is an entry with a short definition that stands alone, then what it is for, how a program gets and uses it, what it is not, an example and a reference to its design. The groups Code, Running code, Access and Communication are written this way (201 terms), and a link to a term on another page shows its short definition as a tooltip.
- **The glossary is one page for each group, with an index from A to Z**: the single page had passed 1 MB. The index lists every term with its group and its short definition; each link to a term opens the page of its group, and an old address of an entry at the index goes on to it.
- **A table of the site is readable on a phone**: under 720 pixels of width a row is a block, with its first cell as its title and each other cell under the name of its column. A table no longer scrolls sideways there, and no column is squeezed to a few words a line.
- **A command of the console gives a result, and the console draws it by its kind**: no built-in command prints. `help`, `programs`, `modules`, `grants`, `principals`, `replacements`, `variables` and five more give a table that `where`, `sort` and `columns` take; `memory`, `load`, `isolate`, `connect` and `unload` give a record; an error shows its sentence, then the values of its error record. One drawer for each kind (number, text, record, table, handle, bytes, error) colors each value by its value kind, draws 20 rows of a table and says how many it does not show, and cuts no value. The log records of the programs that a line calls show under the line, read from the service `log`. `programs()` is now the export `monitor.programs()`. An integer of a line that does not fit in 64 bits is an error, not a wrapped number. New commands: `describe`, `program_modules`, `locks`, `loaded`, `bytes`, `skip`.
- **The manual reads the Markdown of the documentation of a module**: the program `manual` shows a bold word in the bold weight, a word in italics with a thin line under it, code in the font of the cells, a list item with its mark and its indentation, an example as a block, and a link as a colored name. A click on a link to a module or to an export of the boot image shows that page. A module now carries its documentation text with the marks of its comment; the line of help of an export stays plain, so `help()` in the console prints the same lines. A new library, `support/source_comment_markdown`, reads that part of Markdown with no allocator.
- **A program checks by count in a test and measures by time in a measure run**: `clock`, `flow`, `crowd`, `disk`, `locks` and `scheduler` no longer measure a rate for a fixed time at each start. Their windows and their log lines show the counts of their checks (for example "200000 records read in order, 0 lost"), and the rates in one second are in a measure run: `kerneltool measure`, `kerneltool measure scheduler` and the new `kerneltool measure clock|crowd|disk|flow|limits`. A measure run uses the same modules as the test; the value 22 of the context tells a program that it runs for a measure.
- **The console holds 256 commands**: the command table of the console has 256 places, where it had 192, for the 20 commands of the debugger and the exports of the service `debugger`.
- **The machine test takes a picture when the screen is settled**: the fixed time of 400 ms before each picture is gone. The compositor has the export `screen()`, and each row of `windows()` says how many pictures its program sent and whether one waits for a frame.
- **The site writes the name of the system in the letters of the mark**: the bar, the foot and the title of the home show "modus" as text in a font made from the cells of the mark (`resources/logo/modus_mark.ttf`, written by `kerneltool logo`). The pictures of the mark on a page are the heron alone, and the heron of the home plays an animation each 2.4 s on average, in place of each 4.7 s.
- **The trees of the site show tree lines**: in the documentation tree and in "On this page", a line of 1 pixel runs down from each parent and a branch goes to each item under it, as in a file tree, in place of indentation alone. The lines from the top of the tree to the current page are in the color of a link. "On this page" now puts each heading of level 3 and each symbol under its heading of level 2.
- **The network service computes no checksum of UDP or TCP, and reads each byte of a datagram or a segment one time**: the program checks the checksum of what it receives (`support/tcp` for a segment, `network.udp_data_read` for a datagram) and writes the UDP header and the checksum of what it sends (`network.udp_header_write`), so a `Send` and a `Receive` of a datagram endpoint now name the whole datagram, with its header of 8 bytes, 1480 bytes at most. The network service still refuses, in its own copy of the header, a source port that is not a local port of the endpoint and a remote that the grant does not name; a datagram or a segment with a wrong checksum now reaches the endpoint of its port, and the program drops it and counts it. When an endpoint ends, the log has the passes of the network service over its bytes: one on receive and one on send, where the passes were two on receive, and two on send for UDP.
- **The palette replaces the launcher**: the key super opens one panel that lists the programs and the windows in one ranked list, with the fuzzy match of the console and each matched character marked. Enter starts the chosen program or brings the chosen window to the front; the close of a window asks for a second Enter. The input band is the top of the panel, flush with its top, left and right edges, and the typed part is at twice the size of the font. The pointer chooses and runs a row too. The commands of the console are in the list too: a command with no parameter runs from the panel, which shows an Integer, a Text of one line, a Record or an error, and a Table brings the console to the front; a command with parameters gets a form in the input band, one typed field for each parameter, with the candidates that the console gives (programs, modules, grants); each value of each setting is an entry ("set font to spleen"); a first character restricts the list (`>` commands, `@` windows, `:` settings, `?` the manual); `shutdown`, `lock` and `history_clear` ask for a second Enter. The console has a new grant, `palette`: `revoke("console", "palette")` leaves the programs and the windows in the palette. The field `launcher` of `compositor.pointer()` is now `palette`, the state of the panel as a number, and the hint of the bar is "palette: super".
- **The drawing of a window is a module**: 23 programs with a window no longer hold a copy of the code that finds the damage of a frame and draws its records, its text and its blends. They import the module `drawing`, which has two exports, `damage_of_draw_table_7` and `execute_draw_table_7`: a window calls them two times for a frame, with its draw tables and the pixels of its surface by address, with no copy. The elements, the layout and the input stay in each program. The hash of each of these programs changed, and the module graph has one edge from each of them to `drawing`. The module `interface_module` keeps its six element exports and lost its two drawing exports. The build now refuses a `foreign` declaration of an import that does not agree with the description of the export: before, it built with no error. In a build of two programs alone, the file of `clock` went from 92 112 to 72 864 bytes and the file of `monitor` from 114 688 to 94 208 bytes (one build, QEMU with KVM for the times: the draw time of `clock` stayed inside the spread of two runs of the same code).
- **The heron of the home of the site has fifteen animations and moves most of the time**: eight animations are new: a dash in which the heron runs out of the window by its right edge and comes back by its left edge, with a squash at its start and at its stop; a hop; a fish that jumps in front of it; a doze; a stretch; the wind in its crest; a change of the leg it stands on; a flap of its wing. The heron is still for about 40 % of the time. Each animation plays once before one plays again, in an order of chance, and a visit keeps what was played from one page to the next. A reader who asks for reduced motion sees a heron that does not move.
- **The heron of the home squashes and stretches on its grid**: a cell of the heron is now a square of one size in every picture. Before, the dash, the hop, the stretch and the flap made the whole picture wider or higher, so the cells became rectangles. Now a squashed or a stretched heron is another drawing in whole cells (ten forms, from 20 to 32 columns and from 19 to 26 rows; the head, the eye and the beak are the same in each), and the heron travels by whole cells. The times of the animations did not change.
- **The bar of the site has three buttons and one menu**: Docs, Gallery and News are buttons, and a button "Project" opens a panel with Status, Releases and Roadmap. The six sections fit one line from a window of 720 pixels, with the search field. The gallery is one click from each page. The menu opens and closes with no script; under 720 pixels its three sections are lines of the site menu.
- **The scroll bar has arrow buttons, a thumb with a grip, and the pointer**: each scroll bar of the system is one element, 17 pixels thick, with an arrow button at each end, a track and a thumb with a border, a gradient, an inner line and a grip. The bar takes blue tones under the pointer. In a terminal and in `manual`, a press on an arrow button moves the view by one line and repeats while it is held, a press on the track moves it by one page, and the thumb follows the pointer. The scroll bars of the site have the same sizes and colors, from the same table, in the dark and in the light form.
- **The same module with and without debug information**: the build asks the compiler for a kind of debug information that adds no instruction to the code, `-debug-info:same-code`, an option of the fork of Odin that the flake pins. Each of the 89 modules is the same bytes with and without debug information, so the full check passes again. A debugger loses little: for `inspect`, the locations of the local variables cover 0.3 % fewer bytes.
- **The home of the site shows a line of time, charts and a release band, and every control shows its state**: the start of the machine is a line of time with two bars, each on a scale that the page states, a row with the name and the time of each stage, and a card for each stage that says what it does, which code runs it and where its guide is. The measures of the home are bar charts of one unit (the kernel entries with 1, 2 and 4 programs, the time of one glyph); a measure that is not such a chart is on the page of the measured numbers only. The newest release is a band with its number, its counts and its first changes as links. A news card with no picture has its text at its top. A click, a tap, Enter or Space on the heron plays an animation at once. Each button, door, numbered link and line of a menu shows the pointer, the focus and a press, in the colors of the desktop.

### Fixed

- **The search of the site finds the types.** A type of the contract, such as `Time_Record`, is now an entry of the search, and the result opens its card on the page of the types.
- **The tiles of the boot image show whole names.** On the home of the site, a tile of a small module was narrower than its name, and the name was cut. A tile is now at least as wide as its name.
- **Typing in the search of the site no longer scrolls the page.** Each key in the search field moved the page up a little.
- **The published site shows the measured numbers**: the page of the numbers and the start of the machine on the home said "Not measured in this build." for every number, because the site is built on a clean checkout with no machine test. They now come from the measure record that the last full check commits, and each row says which full check and which commit measured it.
- **The measure record names its commit.** The first record held bytes of a screen in place of the commit that it was measured on.
- **A refused measure is said, and the boot display shows whole names**: when the TPM refuses to measure the system description, the boot program tries 4 times, then the boot display says "TPM refused the measure" in red and the root service writes a warning, where before the display said "not measured" as for a machine with no TPM. The tiles of the boot image show the whole name of each module or no name, never a cut name, and the trust record takes one line under them. No text of the boot program lies over the boot display any more.
- **The icons of the values show with the page**: the style sheet now holds the 16 icons of the kinds of values, so a page asks for no file to draw them. Before, a browser asked for each icon alone after the style sheet, and on /docs/ an icon arrived up to 635 ms after the start, after the first paint.
- **An unmap gives back the page tables that it empties**: a page table that a mapping made returns to the budget that paid for it when the last mapping in it ends, at each level of the table. Before, it stayed until the program ended: a program that mapped at many addresses lost one page for each 2 MiB that it ever used, and a parent was one page short after its first child. An Uncommitted object of 1 GiB now keeps 0 pages after its unmap, where it kept 513.
- **The reference pages of the site show a list of names as a list, never as source code**: on the page of the grants, each grant of a program is a link to its row and the column of the reasons keeps its place; the imports of the modules, the edges of the module graph, the statuses of an operation, the parameters of a command and the gaps of a property wrap between their names. No page shows the bare name of a document any more, and a page that a cache kept from an older build says so, with a button that reloads it.
- **Faults of the QUIC library**: a server gives the remote of each connection that ended, also when the caller has few places for them; the handshake gives no packet keys after its secrets are erased; the bytes of the streams are erased when their connection ends; a server that names its preferred groups in EncryptedExtensions is accepted; a ClientHello with a session identifier closes with PROTOCOL_VIOLATION; a `preferred_address` that is malformed is a TRANSPORT_PARAMETER_ERROR; a connection closes for reserved bits only on a packet that proved authentic; and each error record names the argument at fault with the value that it had.
- **Small faults that a reading of the code found**: `Memory_Map` refuses a flag that the kernel does not know with `Bad_Operation` and a record `Bad_Flags`, as the other memory operations do; `kerneltool test <word>` refuses a word that is not a part, lists the parts and ends with the exit code 2, where it ran the whole test; a virtio device that does not finish its reset stops its device service with "the device did not finish its reset" after 1 000 000 reads of its status, where the service waited with no end; `life.glider` refuses a negative column or row, `paint.write` refuses a place that is not on the paper (x 0 to 479, y 0 to 295), and `math.gcd` refuses the most negative integer, each with an error record; the help of `settings.set` and `settings.get` says "a setting of the system".
- **A `Stop` and a `Resume` of `Thread_Control` no longer forgive what a thread owes**: a thread that a `Stop` took out of its run queue came back as a new thread, so a thread that had run more than its share ran again before the threads that waited. It now leaves the queue as a thread that starts to wait, and comes back as a woken thread.
- **The program `clock` no longer fails when its thread leaves its processor between two reads of the time**: it checked that a kernel entry and a read of the time page were at most 1 ms apart, which a busy machine does not give. It now checks that the time of a kernel entry is between two reads of the page around it.
- **A queue of threads that cannot run no longer keeps the other processors idle**: a processor that looks for work tried only the busiest other run queue. When that queue held only threads whose budget had no processor time left, the processor took nothing and went idle while threads waited in a third queue. It now tries the next busiest queue, each queue one time.
- **Keys typed while a line of the console runs keep their meaning**: a line ends when its result is drawn, and the save of the line history no longer holds the keys after it. Escape typed during a line that is in no call of a sandboxed program or of a service now waits in order with the other keys and acts on the edit line; before, it was taken out of order as a stop of the line, so a list that the keys before it opened stayed open.
- **A damaged TCP segment no longer ends a connection of `server`**: a segment from the remote of a live connection with a wrong checksum or a malformed option made `server` ask the network service to forget that remote, and the connection ended by a timeout. `server` now releases a remote only when no connection has it. The network service also keeps a listen port taken after a revocation until its endpoint is removed, and ends a Send that waits for the answer of ARP when the grant of its endpoint changes.
- **No key is lost in silence**: four queues between the keyboard and a program dropped a key with no count and no log line when they were full, and a typed line was lost once in a machine test. The input service now leaves the bytes in the keyboard controller while its ring to the compositor is full. The compositor keeps 256 records for a window whose ring is full and sends them in order. The console leaves the keys in its terminal ring while 128 keys wait for the end of a line. Where a writer cannot wait, each lost record is counted, and the log has one line when the loss begins and one with the count when it ends; `compositor.pointer()` and `compositor.windows()` give the counts (`keys_refused`, 0 on a system that works).
- **A refused debug access names the grant**: `debug("notes")` in the console, and `debugger.attach` from the host, now print "the debug access to this program: the grant Store of the program refuses it". Before, the sentence gave a number ("the grant 7 of the root service") that changed when a grant was added, and only the log of the root service gave the name. The list of the start grants and their names is now a contract, `contract/start_grant`, which the root service and the reader of an error record both read; the number of a start grant no longer changes.
- **The window of the program `heron` no longer shows a half-drawn heron**: during a fast move, one picture of the screen could show the head of the heron and none of its body, which a reader sees as a flicker. The program now draws a picture that the screen does not read, and the screen takes it when it is complete. Each key of the program also writes one line on the log: the pause, the speed, the cell size, and the frame that the window holds.

### Security

- **A program no longer reads where the kernel placed its tables**: on a processor with UMIP, `sgdt`, `sidt`, `sldt`, `smsw` and `str` of a program give a protection fault, where they gave the addresses of the segment table and of the interrupt table of the kernel; the kernel now writes its own control registers on each processor (an x87 error and an alignment check are faults of the thread on every machine, no breakpoint of the firmware stays on), and a boot line says whether UMIP is on.
- **A debug trap at the entry of the kernel no longer runs on a stack or with a gs that a program chose**: a program that runs `mov ss` or `pop ss` with the trap flag set, just before `syscall`, `int3`, `int1` or an instruction that faults, could, on a processor that gives the held trap at the first instruction of the kernel, make the processor push the frame of the trap on the stack of the program at privilege 0, or run the kernel with the gs of the program: the machine stopped, or values that the program chose went to an address of the kernel that it chose. The debug exception, the non-maskable interrupt and the machine check now have their own stack on each processor. The kernel drops each such trap with no code that reads gs; after `int1` the frame of the program is lost, and the kernel stops that program with the stop code of a debug exception. An NMI, a machine check or a double fault runs with the gs of the kernel and stops the machine with its line.
- **A program no longer sees the data selectors of the program before it**: the kernel did not keep `ds`, `es`, `fs` and `gs` for a thread, so a value that one program loaded stayed for the next program on that processor, a channel of a few bits between programs. Each return to a program now loads the null selector in each.

## [0.91.0] - 2026-11-12 11:20

### Added

- **The site shows the state and the reference of the system**: a status page gives each property with its status, the evidence and the gaps that name it, then every gap and the next steps; reference tables list the kernel operations, the context, the error kinds and units, the grants, the fixed ranges and the commands of the console, each row read from the file that defines it; each module has a page with its documentation and the signatures of its exports; the home shows the tiles of the boot image.
- **The documentation of the system as a site**: `kerneltool site` writes static pages in `build/site`: a home that shows the system, a guide for each document of `docs/`, reference tables (the glossary, the commands of the tool, the measured numbers, the licenses) and every release. Each page names the files and the commit that it comes from; the command checks every link, title and picture before it writes a page.
- **The mark on a transparent background**: `kerneltool logo` also writes `resources/logo/modus_transparent.png` and `modus_light_transparent.png`, and the README shows the one that fits the color scheme of the reader.
- **The news of the system**: a dated report in prose of each thing that a person can now see or use, one file of `news/` for each, beside the technical list of the changelog. `kerneltool news new` and `kerneltool news check` write and check them; the site shows them on its page News, the three newest on the home, a link from each release, and the feed `news.xml`. Eleven entries tell what the system shows from the vector font to the QUIC server.
- **A search on the site**: a box at the right of the bar finds a page, a module, an export, a kernel operation, an error kind, a command, a term, a section of a guide, a news entry or a release with the fuzzy match and the order of the console of the system, with no server and no request to another host. Up, Down, Enter and Escape work as in the console, `/` puts the focus in the box, and a search can be linked with `?q=`. With no script, the box is not shown and every page is reachable by its links.
- **What other sites read of the site**: `kerneltool site --address https://<host>/<path>` gives each page its canonical address, Open Graph with the picture of the mark, and one JSON-LD graph built from the page (the system, its source code, the guides as articles, the glossary as defined terms, the modules as a list, the news as posts), and writes `sitemap.xml` and `robots.txt`; the command checks all of them. With no address it writes none of them and says so. Each page also names a manifest, the new feed of the releases `releases.xml` and the guides before and after it, the site has an `llms.txt`, and the site writes each picture of the repository compressed, with the same pixels: a screen picture of the repository is stored with no compression.
- **The site on a phone, its author, and its publication**: under 720 pixels the sections and the search of the site are behind one square menu button, with one list of links and no inline script; the news cards of the home line up their titles, pictures and texts in a row; each page names its author from the line `Copyright` of `LICENSE`, in its head, in its JSON-LD graph and in the feeds; a GitHub workflow builds the site with `kerneltool` and publishes it on GitHub Pages at each push to `master`; the head of the home shows one short tagline, with the rest of the first paragraph of `README.md` lower on the page; and the site has a `favicon.ico` at its root, an SVG icon, an icon for a phone and a maskable icon, each drawn from the cells of the heron at a whole scale; and each table of the site gives each column the least width of what it holds (a date never breaks, a line of a log has room for about 60 characters), keeps the first column in view, and scrolls sideways in its own box, which the keyboard reaches, when it is wider than the page.
- **The heron of the home moves**: the large mark of the home of the site and the icon of its tab play seven small idle animations (a blink, a look, the raised leg, a ripple of the water, a dip of the neck, a preen of the back, a scratch of the ground) between still times of 2.2 to 5.5 seconds. Nothing moves for a person who asks for reduced motion, and nothing runs in a hidden tab. `kerneltool logo` writes `build/mark_animations.png` with every frame.
- **A program can repair its own page faults**: a program names one of its threads as its fault handler (`Fault_Handler_Set`); a page fault of another thread then does not stop the program but becomes a record in the thread record of the handler, and the thread waits until a thread of the program answers (`Fault_Answer`: resume, or stop with the report of today). Guard pages, a stack that grows and memory committed at its first touch need no policy in the kernel. The kernel has 31 operations; a full ring, a fault of the handler itself, and the end or the change of the handler while a thread waits stop the program, with a report. Only the program of a thread can answer for it.
- **The kernel records its own work for a program that has the grant**: a program with the new right Events on the machine gives the kernel a table of up to 16 rules (`Events_Set`, the 32nd operation of the kernel). The kernel then writes one 64-byte record into a ring for each processor for each operation of a kernel entry, switch of threads, fault or wait for a kernel lock that a rule accepts, filtered by program, detail, least duration or one in N. A full ring counts the records that it loses; the table ends with the program that gave it, or when its right is revoked; the address of a page fault is given only for a rule that names the program. With no rule, each event point costs one branch. The program `kernel_events` checks the exact counts.
- **The types of the site have a card, and the code has colors**: the new reference page Types shows each type of the contract, each wire form of the module contract, each record of a module and the basic types, with the size, the alignment, the fields with their offsets and padding, or the members with their values, all from the compiler. Each type in a signature, a declaration, a fact or a table of the reference opens its short card with a click, a tap, the keyboard or a pointer that rests on it. The declarations, the signatures and the Odin blocks of the guides are colored by the tokenizer of the Odin compiler when the site is built, with no script. The scroll bars, the selection, the focus and the marks of the site follow the palette of the system in both color schemes.

### Changed

- **The kernel runs its small instructions in place**: the ports, the model-specific registers, the control registers, `invlpg`, the read of the record of the processor and the copy of `user_copy` are instruction templates of Odin, which the compiler puts in the code of each caller with no call and no return; the code that owns the stack or the frame stays in the assembler file.
- **Shorter addresses on the site**: each page is now at a folder, as `https://modus.froment.software/reference/licenses/` in place of `.../reference/licenses.html`; each old address of a page opens a small page that sends the browser to the new address, so that links from before keep working; a site written with no address keeps links that a browser opens from a disk.
- **The documentation of the site has the layout of a documentation site**: each guide, reference page and module page uses the whole window, with the tree of the documentation at the left, the text in the middle and "On this page" at the right, which marks the part in view. Each kernel operation, command and export of a module is documented on its own with its signature, the text of its source comment and a link to its source line. The working record `FIRST_MILESTONE.md` is no longer a guide, and a new build never shows an old style sheet behind the cache of the proxy. Each technical value of the reference, the module pages and the status page (a handle, a number, a status, a type, a module, a file and the others) is in the monospace font, in the color of its kind, with a small pixel icon of its kind; the reference index has the legend of the kinds.
- **The pictures of the screen are compressed PNG files**: the kernel tool writes each PNG file with the encoder of the Odin standard library, so a picture of 1024 by 768 pixels is no longer 2.36 MB of stored data. The same pixels give the same bytes. `kerneltool screenshots compress` converts the pictures that are not compressed yet, with no machine, and checks each pixel of each converted file.

### Security

- **A program can no longer stop the machine at the return from the kernel**: a `syscall` in the last two bytes below the half of a program (its return address 2^47 is not canonical), or the flag nested task set with `popfq` before a `syscall`, made the processor fault in the kernel at its return, and the kernel stopped the machine. The kernel now checks the frame of each thread before it returns to it and stops that thread's program as its own fault, with the stop code 0x400 and the refused address in its stop report; it clears nested task at each `syscall`; and a fault at the return instruction itself is a fault of the thread.

## [0.86.0] - 2026-11-12 05:05

### Changed

- **The desktop names things in B612 too.** The buttons of the bar, its menus, the titles of the windows and the launcher are in the interface font B612, and the clock, the date and what the person types stay in Paper Mono; the buttons are as wide as their names in that font. The display of the boot, after its first screen, has its titles and names in B612 too.

## [0.85.0] - 2026-11-12 05:04

### Fixed

- **A QUIC server frees the connection of a client that went silent at its idle timeout**: a client that vanished while the server had data in flight kept its connection, and its place in the table of `quic_echo`, for about two hours, because each unanswered probe pushed the idle timeout further. It now ends after 30 s, whatever the probes. A replayed packet can no longer keep a silent connection alive, a server can no longer be started with no idle timeout, and `quic_echo` logs how long each idle end took against its bound.

## [0.84.0] - 2026-11-12 05:04

### Fixed

- **No text of the system is cut in silence**: a log line longer than 512 bytes was cut with no sign, and so was each text that a program formats in a buffer too small; the log now takes a text whole, in several lines, and a text that a place cannot hold ends with "... and N bytes more". The console refuses a program name longer than 31 bytes, which the root service cut before.

## [0.83.0] - 2026-11-12 04:10

### Added

- **The console keeps its line history across a stop**: after each line, the history goes to a store of its own in the storage service (4 blocks, apart from the store of the person), and at the next start Up and Control-R find the lines of before, also after a stop of the machine. history_clear() forgets it, in memory and on the disk.

### Fixed

- **The console prints a long result whole**: a result of more than 256 bytes was cut in the terminal and in the log with no sign, and a line of more than 192 bytes was cut in the log; the console now prints each result at any length.

## [0.82.0] - 2026-11-12 03:44

### Changed

- **Windows name things in B612.** The titles, captions, labels, buttons and lists of every window drawn with the interface package are in the interface font B612, and their values (numbers, typed text, tables, terminals) stay in Paper Mono; a window with no interface font draws everything in Paper Mono with the same layout.

## [0.81.0] - 2026-11-12 03:14

### Added

- **Programs can use AVX and AVX-512**: the kernel saves the extended state of each thread with `xsaveopt` (x87, SSE, AVX, and AVX-512 when the processor has it; one save writes at most 832 bytes with AVX and 2688 with AVX-512, and each thread entry of the kernel holds an area of 2688 bytes), sets `CR4` and `XCR0` itself on each processor, and logs what it saves at boot. A processor without `xsave` keeps the save with `fxsave`. A program reads what it can use with `support/instruction_sets`, and the program `extended_state` shows that each register of each thread is kept.

### Changed

- **A kernel entry no longer saves the vector registers of a program**: the kernel saves and restores the x87, SSE and AVX registers of a thread only when a processor leaves it for another thread, and the kernel itself has no instruction that uses them, which the build proves on each kernel that it makes. One kernel entry takes 120 to 124 ns where it took 176 to 178 ns (the machine of the test, two runs each), and one hand-over between two threads takes 125 to 133 ns with the registers saved and restored.

### Fixed

- **A program that used AVX no longer gets the high halves of its ymm registers from another thread**: before, the kernel saved only 512 bytes with `fxsave` and kept the `XCR0` that the firmware left, so AVX could work with wrong values and no error. Now a register state component is enabled only when the kernel saves it.
- **A reset QUIC stream no longer closes the whole connection**: when a stream was reset while flow control still held back some of its bytes, the reset named the bytes written instead of the bytes sent, and a correct peer closed the connection. The bytes of a stream are now erased from memory when the stream ends.

## [0.80.0] - 2026-11-12 01:57

### Added

- **Several streams in one QUIC connection**: a client of `quic_echo` can open 4 streams at once, and each one is echoed on its own, with its own flow control and its own reset; a lost datagram of one stream no longer holds the others. `kerneltool test quic` runs one client with 4 streams.

### Security

- **A QUIC server can no longer be stopped by a few dozen real addresses**: the budget of Initial checks of each address can no longer be renewed by addresses that take turns, so 33 hosts no longer stop every new client of `quic_echo`. A new address gets no check while the table of 1024 addresses is busy, and `quic_echo` counts it.

## [0.79.0] - 2026-11-12 01:54

### Added

- **The interface font is drawn.** The program `interface_font` shows B612 Regular and Bold placed with their pairs at a third of a pixel: a paragraph, three pairs with and without their adjustment, one word at the three positions of a pixel, the digits in columns, and the time of one line.

### Changed

- **The zero of the system is slashed.** Every window, the console and the terminal draw the character 0 as the slashed zero of Paper Mono, which its feature zero gives, so a 0 no longer looks like the capital O.
- **The caches of the interface font come with the system.** The two glyph caches of B612 are in the boot image, checked once by the root service and shared read-only by every program with a window, and a program learns which shared ranges it received from one value of its context; the program `interface_font` no longer builds its own caches.

## [0.78.0] - 2026-11-12 01:27

### Added

- **The time of one key of the completion list is measured**: measure_completion() in the console gives the collect, the rank and the rows of one key, for the names of the console and for 512 names of 128 bytes; in the quotes of connect and stop, a key no longer reads the programs that run again.

### Changed

- **The text of the console no longer moves when the line under the input comes or goes**: the terminal keeps one free row under the edit line, and draws the hint there; a hint that is too long for the window shows its short form.

### Fixed

- **The status line of a terminal names the lines of the text in view**: after a clear it said "line 738 of 737", because it counted the edit line as a line of the text; it now says "lines 709 to 736 of 737", or "none in view".
- **An export that fails in a sandboxed program or a service no longer changes a table of the console**: the console copied back the rows that a failed export wrote in a Change table; it now copies back only the table of error details, as the contract says.
- **A completion list shows only the rows that its program gave for it**: a list with no rows of its own showed the rows of the list before; when more names exist than the list reads, the line under the input says so.
- **A failed isolated call keeps the reason of its failure**: when the table of error details came back wrong, the error record of the export was replaced by a record about the table; it now stays, and a separate status says that the details are missing.

### Security

- **Long names of one length no longer slow each key of the console**: the order of two names in the completion list read whole names, up to 64 times for each name, so a service with long export names of one length made each key slow; it now reads at most 256 bytes of a name, and one key has a fixed bound.

## [0.77.0] - 2026-11-12 01:24

### Added

- **The mark in the system**: the heron is at the left of the bar of the desktop, in the place of the word "kernel", and the heron with the name modus is in the head of the boot display. Both are drawn from the data of `support/mark`, with no picture file in the boot image.

### Security

- **The program `settings` can no longer make the keys of the person get lost.** A new count of changes on the settings page with the same values made the compositor send one record into the ring of each window, the ring that also carries the keys and the pointer; it now tells the windows only when the values differ from the values that it told last.

## [0.76.0] - 2026-11-12 00:44

### Added

- **A QUIC server on the network**: `quic_echo` listens on the UDP port 4433 with QUIC in the program, writes back each stream, shows its public key, its connections and what it refused in its window, and makes no key when the random seed of the program is weak; `kerneltool test quic` runs a client of the host against it through the network service, with loss, many clients and a flood of forged packets.
- **A program can listen on a UDP port**: the network service gives a listen grant of UDP, which answers only the remotes that sent a datagram of 1200 bytes at least to the port, as the listen grant of TCP does for a SYN.
- **A test of QUIC against OpenSSL**: `kerneltool test quic-real` connects `openssl s_client -quic` of the host to `quic_echo` through QEMU user networking, pins the key that the machine printed, and checks the echo; the development shell has OpenSSL.

### Changed

- **`kerneltool test quic-real` reaches the machine through the peer of the tool**: QEMU user networking dropped every UDP datagram of the machine, so OpenSSL never received the Retry. The test now goes through a UDP relay of the peer on the loopback of the host, and on a failure prints each datagram that the relay carried and the close of the connection.
- **`quic_echo` logs why a connection ended**: the error code and the frame type of the close, and the reason phrase that the client gave.
- **`quic_echo` resists a flood of new connections better**: one host with a valid token can no longer stop the new clients of others, each token of a Retry takes a connection once, and the budgets of work for new connections refill continuously, so a burst at the turn of a second no longer gets twice the budget. Its log and its window count the Initials over the budget of one address and the tokens used again.

### Fixed

- **Two datagrams of a new QUIC connection that arrive together are both taken**: `quic_echo` lost the second one, and the client waited for its probe timeout. A connection whose client came back just after the server released it is now validated by the network service, so it is no longer held to 3 times the bytes that its client sent.

### Security

- **A QUIC server keeps nothing for a client that did not prove its address**: `quic_echo` answers a first Initial with a Retry and takes a connection only for a client that came back with its token, so forged source addresses no longer hold its handshake places; the work of new connections has a budget in each second.
- **The network service limits what a UDP listen grant sends to an unproven address**: at most 3 times the bytes that came from the remote, until the program marks it validated with the new command `Validate`; a send no longer keeps a remote admitted.

## [0.75.0] - 2026-11-12 00:12

### Added

- **The mark of the system**: a heron of square cells with one gradient in each part, and the name modus under it. `kerneltool logo` writes its files in `resources/logo` from the data of `support/mark`, at 1024 pixels on a dark and on a light background and at the sizes 24 to 768.

### Changed

- **Text over a gradient or a picture is drawn with the SSE2 blend.** The text of every window over a title bar or a picture takes the SSE2 form of the blend, with the same pixels as before.

### Security

- **No program chooses where another program reads its glyph caches.** The program `settings` could write the address and the size of the glyph caches on the settings page, and so make each program that started later read and draw memory that `settings` controlled; the caches are now at fixed addresses with their sizes in the context that the root service writes, mapped read-only for every program. A program also no longer waits for ever on a settings page left in the middle of a change.
- **A hostile font file no longer stops the reader.** A glyph made of thousands of empty parts made the font reader run for an unbounded time; the reader now stops at 64 parts, and a glyph cache whose monospace glyphs leave their cells, or whose header has unknown flags or a name with no end, is refused.

## [0.74.0] - 2026-11-11 22:46

### Added

- **The pointer theme and the grid fit are settings.** The window `settings` and `settings.set("pointer_theme", "system")` or `settings.set("grid_fit", "off")` change them while every program runs.
- **Settings survive a stop.** The font, the order of the color stripes, the pointer theme and the grid fit of the text are kept in the store of the program `settings` and come back at the next boot; a loss of power gives the old settings or the new ones, never a mix.
- **A module of text shaping, and the interface font B612 as data.** The module `text_shaping` places the characters of a text with the advances and the pair adjustments of a proportional font, and measures many texts in one call; the build makes the glyph caches of B612 Regular and Bold, which no window draws yet.

### Changed

- **The titles of the cards are bold.** Each card of a window and of the boot display draws its title in the SemiBold weight of the font of the system.
- **Text on cards and in the console draws faster.** A glyph of the vector font over a plain background costs 109 ns in place of 181 ns on the host (the least of many runs), with the same pixels.
- **Paper Mono is the font of the system.** The console, the terminal and every window draw their text in Paper Mono on the same grid of 8 x 16 pixels, in place of JetBrains Mono, and the titles of the cards in Paper Mono SemiBold.

## [0.73.0] - 2026-11-11 22:24

### Added

- **A caret in the line of the console**: Left, Right, Home, End, Delete and Backspace edit the line at the caret, and a character goes in at the caret.
- **A completion list in the console**: while the person types, a list under the line shows the commands, the exports, the services, the variables and the modules that match by a fuzzy match (`mcnt` finds `monitor.count`), the matched letters lit, each name with its signature; Tab or Enter takes one, and the line under the input shows the signature of the call at the caret.
- **A longer line history in the console, with a search**: 256 lines in place of 8; Control-R opens a search over them with the same fuzzy match, Control-R and Control-S move to an older and a newer line, and Enter puts the line in the input.

### Changed

- **A terminal gives its program the modifiers of each key**, so that Control with a key reaches the console; a cell of the text grid of the interface package can have a fill color (draw record version 5).

## [0.72.0] - 2026-11-11 21:48

### Changed

- **BLAKE3 hashes four chunks at a time**: in an input of more than 4096 bytes, the four chunks of each subtree of four chunks are compressed side by side in the SSE2 registers, with the same hash as before. The root service checks the hash of each module and resource at its start with it.
- **The text of the vector font is blended four pixels at a time**: the blend of a glyph over a pixel, in linear light with the three subpixel bands, runs in the SSE2 registers and gives the same pixels as before.
- **The pointer picture is blended four pixels at a time**, in the SSE2 registers, with the same pixels as before.

## [0.71.0] - 2026-11-11 21:22

### Added

- **A table of error details**: an export can give each thing that went wrong, not only the first, in an optional table of error records that the caller gives. A caller with no table gets the one error record of before. `monitor.counts_named` names each row that names no count, and the console and `kerneltool call` print each detail on its own line after the error.
- **A load names each missing import**: when `load` in the console fails because a module is missing or has the wrong hash, it prints a line for each import of the whole graph that is missing or wrong, not only the first.

### Changed

- **The call request of `remote` has 112 bytes**: it names the place of the table of error details, and the answer of a failed call carries the details and their count. The remote service refuses a request of a tool built before this change.

## [0.70.0] - 2026-11-11 20:55

### Added

- **A cryptography module**: the module `cryptography` gives ChaCha20-Poly1305, AES-128-GCM, SHA-256, HMAC, HKDF, X25519 and Ed25519 to each program, from the code of Odin's `core:crypto` with a check that proves each changed line; a tag or a signature that does not verify is an error with no byte given, and the program `cryptography_vectors` runs the published vectors through it and shows the speed of each primitive.
- **QUIC packet protection**: the library `support/quic` reads QUIC version 1 packet headers as hostile input, derives the Initial keys of a connection, and seals and opens packets with header protection, with AES-128-GCM or ChaCha20-Poly1305 from the module `cryptography`; it gives the packets of RFC 9001 appendix A byte for byte.
- **A program chooses how strong its random seed must be**: a key drawn with `random.fill_for_a_key` names the least seed strength that the program accepts (weak, processor or entropy), and a weaker seed gives the error "the random seed of this program has the strength ..." with nothing made; QUIC and TLS ask for processor at least.
- **TLS 1.3 for QUIC with raw public keys**: `support/quic` runs the handshake of TLS 1.3 for a client and a server, with X25519, Ed25519 and ChaCha20-Poly1305, and a client accepts the server only when it proves the public key that its caller pinned; no certificate authority and no X.509 are used.
- **A QUIC connection over memory**: `support/quic` runs one connection of QUIC with acknowledgements, loss detection, the probe timeout, flow control, one bidirectional stream, the idle timeout, the anti-amplification limit and the close, with the TLS 1.3 handshake inside; a test sends 1 MiB each way through a channel that loses 5 % of the datagrams.

### Changed

- **The context of a program has 24 values**: the values 16 to 23 are for the roles that the system fixes for every program, and the strength of the random seed is the value 16. The 16 values before were full, and two roles wanted one number.
- **TLS for QUIC refuses a configuration that would accept a weak seed or that pins no key, and takes a large ClientHello**: a least seed strength under processor, or a client pinned key of zeros, stops the start with an error; the transcript holds 8192 bytes; handshake bytes left at a level whose keys were replaced close the connection.

### Fixed

- **A QUIC packet no longer stops the program with its header protection sample**: a ChaCha20 sample that starts with `ff ff ff ff` gives its mask, and an Initial packet with a token of up to 2008 bytes is sealed and opened.
- **A thread with a short stack stops at its guard page**: the erasure of the stack after a cryptographic call writes from the top down, so no memory under the stack is written first; a thread that calls the module `cryptography` or draws random bytes needs 24 KiB of stack.
- **A QUIC connection no longer stops for ever when its data has many holes, and a forged Initial no longer takes a server**: data that had no place is not acknowledged, so the peer sends it again; a server takes a client only with an Initial that opens, and a handshake that does not complete within 10 s ends; an old packet whose number was forgotten is refused; a peer cannot move a timer into the past.

### Security

- **One datagram could stop a program that uses ChaCha20 for QUIC header protection**: the ChaCha20 code taken from Odin refused the block with the last counter, and the sender of a packet chooses that counter. The taken file has the correction as listed adjustments, and the correction is offered to Odin. No program used this path yet.

## [0.69.0] - 2026-11-11 20:08

### Added

- **A line in the draw table**: a straight line between two points with a thickness of 1 to 32 pixels. `rings`, `threads`, `workers` and `processors` now draw through the interface package.

### Fixed

- The window of `crowd` has the same margin at its right as at its left.
- **A dragged window stays reachable**: a window dragged to an edge of the screen keeps 8 pixels of its title on the screen, so a person can always take it again. Before, a drag to the right or bottom edge could put the whole window off the screen. A window wider than the screen now opens with its close button on the screen.
- **A new font reaches every window**: after a change of the font in `settings`, the terminal, the console and the manual draw their whole window again. Before, these windows mixed the old font and the new one.
- **The status line of a terminal stays readable**: in a terminal with no rates, the keys hint no longer runs over the status of the program, and a status with a very large total no longer gives a wrong bar.
- **No old pixels after a full command ring**: when a window cannot send its picture to the compositor, its next picture is drawn whole, so the screen never keeps the old pixels of that part.

### Security

- **The compositor takes only a surface that the program gave**: a program could name, in its command to create a surface, a handle that the compositor holds for another program. The compositor then showed the memory of the other program and closed its handle. The compositor now asks the kernel to prove that the handle came through the ring of the program, and closes each handle that it was given, also when it refuses the command.

## [0.68.0] - 2026-11-11 19:55

### Fixed

- A build in an empty folder could fail: two module processes of the parallel build made the same folder at the same time, and one of them stopped with "cannot create ... Exist".
- The report of a fault of the kernel no longer reads through the `gs` register (with the `gs` of a program that read faulted again, with no end and no report), a fault inside the report stops the machine with one line, and the wait for a line of another processor is bounded in time, not in loops.

### Security

- **One program could stop the machine**: a thread made with a first instruction that is not an address of a program made the processor fault in the kernel when the thread first ran, and the kernel stopped the machine. The kernel now refuses such a thread, and such a stack.

## [0.67.0] - 2026-11-11 19:38

### Added

- **Every program gets versions of its data.** The storage service keeps the state of an object before each change, with no save action and no code in the program: a program, or the person through the console or the host, lists the versions of an object, reads one, compares two, restores one (the state before the restore stays a version) and clones an object, which shares its blocks until one side changes. Each version is kept for 10 minutes, then one an hour for a day, then one a day, by the smaller of its age by the date and its age in running time, so a clock that was wrong on one start thins nothing; at the limit of a store the oldest versions go first, and a change that cannot fit with no version is refused. A version that a damaged block makes unreadable is dropped at the next change of its object, which still works. A disk of the earlier format is not read.
- **Undo to any earlier note in notes.** Up and Down step through the versions of the note, with the date of each, Enter restores the version shown, and Escape goes back to the current note.
- **The system knows the date.** The bar shows the date and the time of day in UTC, the HTTP server sends the field Date, and each version keeps the date of its change. The date comes from the clock of the machine, read again each 10 seconds; the service date gives it to a caller with now(). The clock gives the years 2020 to 2099; a clock with an empty battery, or a reading that is not a date, gives no date, and the bar then shows the time since the start.

## [0.66.0] - 2026-11-11 19:13

### Added

- **A program drives its own virtual memory**: a memory object made `Uncommitted` holds a range of addresses (1 GiB in one mapping) and its budget pays only for the pages that the program commits; `Memory_Commit` commits and decommits tables of ranges, and a decommit gives the pages back to the budget at once; `Memory_Protect` changes the protection of pages, with `No_Access` for a guard page; an object made `Large_Pages` is mapped with pages of 2 MiB. The program `address_space` shows each case with its numbers.
- **A test of the real shortage of page frames**: a machine of the test gives one program nearly all the memory; its four threads take every frame, the kernel takes back the frames that sit in the stacks of the processors, and every frame returns.

### Changed

- **Two new kernel operations and a narrow right on budgets**: the kernel has 29 operations (`Memory_Commit` 28, `Memory_Protect` 29). A commit names the budget that pays for the object; the new right `Commit` on a budget handle lets another program commit pages of that object and nothing else, so a program can let another one grow its object without letting it create objects on its budget.

### Fixed

- **A program that maps and unmaps no longer grows its page tables**: a mapping with no address takes the first free range between the mappings of the program; before, each such mapping took a new range and new page tables until the budget refused (a call host refused its 61st call).

## [0.65.0] - 2026-11-11 19:13

### Added

- **Tables and bytes as parameters**: an export takes a table of records or a run of bytes, to read, to change or to append to, in memory of the caller. The same description works in a direct call, in a call host and in a service; the console, `kerneltool call` and `remote` take a table as an argument. A table of 65536 records can pass as a memory object, with no copy.
- **The interface package as a module**: `interface_module` gives the elements of the interface through exports that append to the draw table of the caller, and `interface_through_module` draws its window with it.

### Fixed

- A picture or a text grid that changed its index in the draw table, with the same size, was not drawn again.

## [0.64.0] - 2026-11-11 19:13

### Changed

- **The compiler runs on all its threads, with no patch**: with the release dev-2026-11a of Odin, the same source gives the same module for any count of compiler threads (20 builds of each of the 64 modules, one result each). The patch of 0.59.0 and the option `-thread-count:1` are removed.

## [0.63.0] - 2026-11-11 19:13

### Changed

- **The compiler is Odin dev-2026-11a**, pinned by the flake itself: the system used the release of May through Nixpkgs. The instructions `rdrand` and `rdseed` are `asm` templates of the new compiler, inline in the code, and the copied ChaCha20 is taken again from the new release.

## [0.62.0] - 2026-11-11 17:26

### Added

- **The changelog**: `CHANGELOG.md` lists what each release of the system brings, from the first milestone (0.0.0) to step 59 (0.59.0). A branch adds one fragment in `changelog.d/` for each change; `kerneltool changelog new`, `check`, `assemble`, `release` and `notes` write, check and release them, and `kerneltool release_number` prints the release number.

### Changed

- **`kerneltool build` builds the modules in parallel**: one process of the tool for each module, each with one compiler on one thread, as many at once as the processors. The modules and the boot image are the same bytes as with one process.

### Fixed

- **The kernel reports its own fault as whole lines**: the report took no lock, and a line of another processor arrived mixed with it on the serial port, so nobody could read the fault. The processor that reports is now the only writer.
- The machine test lost typed keys on a loaded host (`start("fetch")` arrived as `start("ETCH")`). The tool now sends a key only after the compositor received the key before it.

## [0.61.0] - 2026-11-11 17:26

### Added

- `kerneltool measure windows` starts each window of the interface package alone and prints the time of its pictures with the load of the host; above a load of 8 it says that the table is not valid.

### Changed

- **The compositor draws its screen as one draw table** of the interface package: the frame of each window, its surface, the bar and the menus. The terminal draws its view as one text grid, and `paint`, `plasma`, `temple` and the boot display use the package too.
- **Windows sit on the grid of 8 pixels**: a new window, and a window that the person moves, has its corner on the grid.

### Fixed

- The terminal showed rows of two frames: with two pictures, a frame presented only its difference with its own picture, and the screen showed the other one.
- A card cuts its caption to the room between its title and its count, and the boot display cuts a fact after its last whole word.

## [0.60.0] - 2026-11-11 17:26

### Added

- **Each program has a random generator**: ChaCha20 with fast key erasure, in the memory of the program. A draw makes no kernel entry and no call. The starter of a program writes its seed of 32 bytes in the context values 9 to 12, and a start with a seed of zeros is refused.
- **The seed of the system**: the root service gathers it at its start from `rdseed`, `rdrand` and samples of the cycle counter, mixed with BLAKE3, and logs its strength: "entropy", "processor" or "weak". A machine with neither instruction starts and says "weak". The program `randomness` shows these facts.
- **ChaCha20 from `core:crypto` of Odin**, copied into `support/cryptography` with only its imports changed. `kerneltool cryptography-origin`, which the check runs, proves that each copied file is its origin, pinned by its hash, with the listed changes only.

## [0.59.0] - 2026-11-11 17:07

### Added

- `kerneltool repeat all <count>` builds every module and the boot program again and again, and gives one row for each: the count of distinct modules, LLVM IR files and objects. `kerneltool check` and `kerneltool repeat` keep each distinct result beside the first one.

### Changed

- The rewrite of the LLVM IR of 0.53.0, which fixed the names of static variables, is removed: the cause is corrected.

### Fixed

- **One source gives one module**: the Odin compiler started one worker thread beside its main thread also with `-thread-count:1`, and the two threads changed the order of the declarations. A module could differ from one build to the next (`host` in 1 build of 12 to 39, `console` with 3 distinct LLVM IR files in 60 builds). The flake applies a patch of 91 lines to the compiler: with `-thread-count:1` the main thread runs each task. `kerneltool repeat all 100` gave one module, one LLVM IR file and one object for each of the 61 modules and the boot program.

## [0.58.0] - 2026-11-11 17:07

### Added

- **A vector font is the text of the system**: every window, the console, the terminal and the boot display draw JetBrains Mono (SIL OFL 1.1) with subpixel bands, blended in linear light. The font is monospace on the grid of 8 by 16 pixels, so no window changes its size; the scales 2 and 3 are drawn from the outline.
- **A glyph cache in the boot image**: the build draws each character 32 to 126 at three scales, in fixed point, into one file of 390 624 bytes. The root service checks its hash once and maps it read-only into each program. One glyph from the cache takes 309 ns, against 35 ns for Spleen 8x16 (in the machine of the test).
- **The program `settings`**: the person chooses the font (the vector font or Spleen 8x16) and the order of the subpixel bands (`rgb`, `bgr`, `none`), and every window draws again while it runs. `settings.set("font", ...)` does the same from the console. The setting is not kept across a stop of the machine.
- **`kerneltool vector_fonts`** makes ASCII subsets of six candidate fonts (14 to 21 KB each, with their licenses in `resources/fonts`) and a picture that compares them.

### Changed

- **The default font is the vector font** (owner, 2026-11-11). Spleen 8x16 is the fallback and a choice of the person. The value 13 of the context of each program with a surface names the settings page.
- The rasterizer of the vector font works in fixed point. It replaces the prototype in floating point of 0.51.0.

## [0.57.0] - 2026-11-11 17:07

### Added

- **A loss of power, tested**: the kernel tool serves the data disk over NBD and sees each write and each flush. At a loss of power during the commits of `notes`, it builds the 306 images that a real disk can hold (72 with a torn write) and opens each one on the host: 227 give the last durable commit, 79 the commit in flight, none a mix. A second machine starts on a hard image, and `notes` restores its text. `kerneltool test power` runs it.
- **Error records in the other calls**: a ring completion that fails holds an error record (the block, frame, datagram, network control and root rings), and the wrappers `display.open`, `terminal.open` and `system.ring_open` take one. `start`, `stop`, `connect` and `revoke` in the console write the cause of a refusal of the root service.
- `errors` has 25 cases on two pages: one case for each family of calls.

### Changed

- `paint.line`, `paint.write` and `tally.add` refuse with an error record what they cut or dropped with no word before.

### Fixed

- `log.records` (0.47.0) left places of its result empty. It fills each place now, and a long text comes in two rows with a continuation mark.

## [0.56.0] - 2026-11-11 17:07

### Changed

- `server` accepts the absolute form of a target, reads HTTP/1.2 as HTTP/1.1, and ignores two empty lines before the request line (RFC 9112). Each answer says `X-Content-Type-Options: nosniff`, and an answer to HTTP/1.0 with keep-alive says `Connection: keep-alive`.

### Fixed

- The body of a request that is not `/sink` was read as the next request. The server now ends that connection after its answer.
- A refused `server.put` changed the bytes that the server served, and a refused `server.remove` gave 404. Both now ask the store first.

### Security

- **One segment held a connection record of `server` for ever**: a whole request and one more byte. 24 such connections from each of two addresses took the 48 records. The bytes left after an answer now start the time limit of the next head: 408 after 10 s.
- **A `server.put` or `server.remove` while a remote read that page** made the server read past the page and stop, or serve mixed bytes. Each page has a generation now, and an answer whose page changed ends with a RST.
- A connection that the server had closed had no time limit. The limits now run until its last byte leaves.

## [0.55.0] - 2026-11-11 17:07

### Added

- **Pointer pictures**: the compositor draws the pointer from a theme file, with its hot spot, and chooses the shape from what is under the pointer. A program asks for a shape over its own surface (`display.pointer_shape_set`). The program `pointers` shows each shape of a theme.
- **Posy's Cursor is the default pointer theme.** The build converts it from an input of the flake; no file of it is in the repository, because its license is CC BY-NC 4.0. The theme of the system, 15 shapes as grids of squares, is the fallback.
- **Resources of the boot image**: a file with a name and a hash, which the root service checks and gives read-only to one program. The pointer themes are the first ones.
- **`kerneltool pointers`** converts a text manifest (`resources/pointers/*.manifest`) and a folder of Xcursor files to a pointer theme file. It reads the Xcursor files as hostile input.

### Changed

- The log keeps 2047 records (1023 before).

## [0.54.0] - 2026-11-11 17:07

### Added

- Draw records version 2: `Folded_Gap`, and `Picture` (the pixels of a picture of the program, with a generation that the damage sees). `life` draws its board as one picture, and a frame with no change draws nothing.

### Changed

- **The interface package draws the windows of 19 more programs**: `inspect`, `scheduler`, `manual`, `life`, and `locks`, `net`, `errors`, `monitor`, `budget`, `rights`, `origin`, `limits`, `frames`, `imports`, `flow`, `crowd`, `disk`, `tally`, `notes`. None of them has a direct drawing call left.

### Fixed

- In a text input, Enter after typed characters now activates the text so far, and the keys after Enter in the same frame are not taken.
- A frame with more than 16 keys lost the keys after the 16th. They now wait for the next frame.
- A `Present` of the whole surface from a place of its own damaged the screen past the window. It damages the window only.
- The prototype of the vector font wrote a cell outside its row for a vertical edge on the last column.

## [0.53.0] - 2026-11-11 17:07

### Added

- **A cache of free page frames on each processor**: a stack of at most 256 frames under its own lock, so a page on first use takes its frame with no frame lock. With 4 programs that work at once, the waits on the frame lock fell from 303 382 to 405 521 to under 2 000, and pages on first use rose from 4.79 to 6.49 million to 7.3 to 8.1 million in one second (`locks`, the machine of the test).
- **`kerneltool measure scheduler N`** runs the program `scheduler` alone N times. `kerneltool measure without_checks` and `kerneltool run without_checks` build the kernel with no check of the lock order and of the sums of the frames.

### Changed

- The test build checks the sums of the frames at each report; the measure build has none of the checks of the kernel. The checks cost about 30 % of the rate of system reports.

### Fixed

- The name of a static variable changed from one build to the next, so two builds of one source could give two `kernel.module` files. It is the same now.

## [0.52.0] - 2026-11-11 17:07

### Added

- **An HTTP/1.1 server**: `server` keeps connections open, answers pipelined requests in order, answers `HEAD`, and gives the statuses 400, 404, 405, 408, 413, 414, 431, 501 and 505. Its pages are in its private store: `server.put` and `server.remove` change them from the console, for a caller that acts for the person. `PUT` and `DELETE` over the network give 405, because the network has no authentication. No TLS, no chunked body, no ranges.
- `web.request_read` reads a request head as hostile input (8192 bytes, 64 fields, 1024 bytes of target at most), with host tests of each bound and of 50 000 damaged heads.
- The window of `server` has a table of the last requests, and each request has a log record.

### Fixed

- `GET /hello` from `fetch` took 43 ms: `fetch` waited for its own ACK timer of 40 ms. It takes 2.7 ms.
- A full command ring lost places in `server` and `fetch`. A command that the ring does not take now waits for the next pass.
- A simultaneous open never ended, and a passive open that a RST ended gave no event.
- A SYN to a full table of connections now takes the oldest record in TIME-WAIT at once. With a new connection for each request, `server` answers 239 to 250 requests in one second, against 4 before.

### Security

- **A listen port could be closed for good**: any segment admitted its sender, so a bare RST from 64 source ports took the 64 places of the admitted remotes. Now a remote is admitted only on a SYN, when a Receive waits, from an address that can answer. A place with no segment for 60 s serves again.
- **32 silent connections from one host filled `server`**: it never freed a connection that made no progress. It now ends one after 10 s, and one address holds at most 24 of its 48 records.
- A RST with data was accepted after the cut, zero-window probes never gave up, and a half-open connection held a record for about 243 s. Each is closed; 18 host tests cover the hostile cases, and 15 of them failed before their correction.

## [0.51.0] - 2026-11-11 17:07

### Added

- **The interface package** (`support/interface`): a program describes each frame as a table of draw records of 40 bytes in its own memory. The damage is the difference of two tables, the layout is one pass on the grid, and Tab, Enter and the arrows reach each element. `clock`, the window of `remote` and the launcher use it: `clock` draws one picture in 12 to 14 us, against 109 us before.
- **The program `interface_elements`** shows each element of the package live, the draw table of the last frame, and the damage of each frame.
- `display.present_rectangle`: a program names the part of its surface that changed, and the compositor draws only that part again.
- **A prototype of a vector font**, as research: the program `vector_glyphs` shows DejaVu Sans Mono at 13, 16 and 32 pixels beside Spleen 8x16, from a reader of a TrueType subset that checks each read.

### Changed

- **The close button of a window is a deep red** (`0xB82232`), brighter under the pointer and quiet on a window that is not in front: the color of the concept "stop a program" (owner, 2026-11-11).

## [0.50.0] - 2026-11-11 17:07

### Added

- **The developer tool `inspect`** shows one program live: its address space as a band with folded gaps, its mappings with the pages that have a frame, its modules with their hashes, its threads with the fields of the scheduler, the stop report of a stopped program as `module + offset`, and a hex view of its own memory. It reads no byte of another program. A sample takes 34 to 63 us.
- Four reports of the kernel for the right Inspect: `Program_Mappings`, `Threads`, `Stop` and `Pages`. The exports `inspect.mappings`, `inspect.threads` and `inspect.modules` give the same facts to `kerneltool call`.
- `errors` keeps its stopped program `fault` until the next run of its case, so that a developer tool can show its stop report.

## [0.49.0] - 2026-11-11 17:07

### Added

- **The system has its own copy and fill of memory** (`runtime/memory.asm`) in every module, in the kernel and in the boot program: `copy_bytes_without_overlap`, `copy_bytes_with_overlap` and `fill_bytes_with_value`, with forms chosen by measure. A copy of 4096 bytes takes 34 ns in the machine, against 1170 ns with the loop of 0.45.0. The first use of a page went from 830 ns to about 700 ns.

### Changed

- 20 programs take the colors of the design rules from `support/graphics`.

## [0.48.0] - 2026-11-11 17:07

### Added

- **TCP, as a library in the program** (`support/tcp`): an open from each side, reassembly, the retransmission timer of RFC 6298, Reno with NewReno, zero-window probes, the FIN states, RST, and the challenge ACKs of RFC 5961. A connection is one record of 400 bytes in the memory of the program, and one call `tcp.step` serves a batch.
- **A segment endpoint** in the network service, with a client grant (one remote, 64 local ports) or a listen grant (one port, and the remotes that send to it). The network service checks the TCP checksum and the ports of each segment, and keeps no state of a connection.
- **The programs `server` and `fetch`**: a small HTTP server (`GET /`, `GET /large`, `POST /sink`) and a client with eight cases. The TCP of the host fetches 1 MiB from `server` through QEMU user networking (libslirp), a stack that this project did not write.
- The test runs a TCP client in the kernel tool against `server`, with seeded loss, reorder and duplicates. 1 MiB from `server` took 52.9 ms in one run, under load.

### Changed

- The network service is also on the data path of TCP segments (one copy, the IPv4 header, the checksum, the grant). The note of property 5 says so.

## [0.47.0] - 2026-11-11 17:07

### Added

- **The compositor is a service**: `compositor.pointer()` and `compositor.windows()` give the place of the pointer, the windows, the focus, the keys, the open menu and the launcher. The kernel tool reads the pointer before each press of the test, and moves it again until it is at the place of the step.
- **`log.records(after)`** gives the log as a table of typed records. The test reads 11 of its checks through it.
- `monitor.counts()` gives the scheduling strategy and its changes.

### Changed

- `kerneltool call` reads and hashes each module file one time: a call that confirms the place of the pointer takes 0.3 ms, not 3.7 ms.
- `monitor` writes no log line for each call, and `remote` writes one sentence for a refusal.

## [0.46.0] - 2026-11-11 17:07

### Added

- **Three scheduling strategies** behind one interface of six functions: round robin, fair (the idea of CFS: a virtual time and weights) and EEVDF. A program with the right `Schedule` changes the strategy while the machine runs (`Strategy_Set`, operation 27).
- **Wake preemption**, also on another processor: a woken thread no longer waits for the end of a slice of 10 ms when each processor is busy.
- A thread has a weight and a request, given at `Thread_Create`. A program can only lower its weight.
- **The program `scheduler`** measures four cases under each strategy and changes the strategy 100 times under load. Two threads that wake each other beside a spinner on each processor: round robin 80 to 84, fair 461 732 to 498 800, EEVDF 313 601 to 332 954 wakes in one second (three runs, while other tests ran on the host).
- `docs/SCHEDULING.md`: the research note on CFS, EEVDF and `sched_ext`.

### Changed

- **EEVDF is the strategy at boot.**
- The machine handle has one more right, `Schedule`. The kernel has 27 operations.

## [0.45.0] - 2026-11-11 17:07

### Added

- **The launcher**: the left Super key opens a panel, each typed key narrows the list of programs, the arrows move the choice, Enter starts the program, and Escape closes it.
- The title bar of the window in front goes from the blue `0x3F7CC4` to a darker blue at its right.

### Changed

- **The desktop follows the design rules**: the bar, the menus as cards, the window frame, the pointer and the background are rectangles on the grid, in the colors of one table (`support/graphics/rules.odin`). The close button is no longer red, because red means "failed" in the rules.
- `support/launcher` is now `support/bar`.

### Fixed

- `graphics.copy` called the `memcpy` of the freestanding Odin runtime, which copies one byte at a time. A full frame with 15 windows took 26.6 ms; it takes 2.1 ms.

## [0.44.0] - 2026-11-11 17:07

### Added

- **A call from the host**: `kerneltool call "monitor.programs()"` calls an export of a service of the machine that `kerneltool run` started, and prints the typed result. The program `remote` relays the call to the services that its grant names (`manual`, `monitor`, `storage`), and refuses a call for another module hash. The calls go over UDP with no authentication: while `remote` runs, a program of the host that sends to its port acts for the person.
- **`monitor` is a service**: `programs()`, `counts()`, `count()` and `served()`.
- The person starts `remote` from the menu, and `revoke("remote", "person")` cuts its right to act for the person.
- The test step `Call` checks typed results in place of lines of the log.

## [0.43.0] - 2026-11-11 17:07

### Added

- `system.nanoseconds()` gives a fine time from the cycle counter, with no kernel entry. The time page has the cycle counter at the time 0.

### Fixed

- The milliseconds of the time page lost the ticks that came late on a loaded host. They now come from the cycle counter: `clock` shows the page 0 to 3 ms behind it.

## [0.42.0] - 2026-11-11 17:07

### Added

- **Errors that diagnose**: a kernel operation that fails gives an error record of 56 bytes in its completion record: the kind, the operation, the number of the argument, its value, the limit, and what the kernel found. An export gives one through its last parameter. There is no global last error, and a call that succeeds runs none of this code.
- **A fault gives a stack trace** from the frame pointers, one line for each frame (`module + offset`).
- The storage service, the manual and `math` give error records, and the console writes each record as a sentence.
- **The program `errors`**: 19 cases, each one an error made for real, with the sentence of its record.
- `kerneltool repeat <module> <count>` builds one module again and again and compares each build with the first.

### Changed

- Each module is compiled through LLVM IR and `llc`, to keep the frame pointers. A call through a slot takes 4.1 to 4.8 ns, against 3.6 to 3.7 ns before.

## [0.41.0] - 2026-11-10

### Added

- **The program `locks`** measures kernel entries, pages on first use and the word wait with 1, 2 and 4 programs that work on their own objects, then stops 120 programs under stress. `kerneltool measure` runs it with only the desktop. `memory()` and `monitor` show the takes and the waits of each kind of lock.

### Changed

- **The kernel lock is split by data**: eight kinds of lock in one order that the kernel checks at each take, a lock for each program, and a run queue for each processor. No kernel entry takes a lock for all the kernel; the control lock serves only the paths that cross programs. With 4 programs at once, kernel entries went from 2.78 to 3.25 million to 6.68 to 7.24 million in one second, and pages on first use from 1.62 to 1.82 million to 3.32 to 3.63 million (three runs, only the desktop).
- An idle processor, or one with less load, takes a waiting thread from the queue of another processor.

## [0.40.0] - 2026-11-10

### Added

- **The first layer of the network**: a frame service drives the virtio network device, and the network service speaks Ethernet, ARP, IPv4, ICMP echo and UDP. A program gets an endpoint whose grant names one remote. The kernel has no network code.
- **The program `net`** shows ten cases with their answers, and its measures: the round trip of a datagram of 64 bytes in 60 to 88 us at least, and 57 886 to 81 733 datagrams in one second with 64 in flight, 0 lost (ten runs).
- A frame from the wire never faults the network service: a malformed frame is a refused row of an endpoint or of the machine, which `net` reads with the right Inspect.
- `revoke("net", "network")` ends the endpoint of a program that runs.
- The time page has the frequency of the cycle counter.

## [0.39.0] - 2026-11-10

### Added

- `docs/DESIGN.md`: the design rules, taken from the boot display. Each thing on the screen is a fact of a record, each form is a rectangle, one color is one concept, one font in three sizes, a grid of 8 pixels.

### Changed

- **A new boot display**: a path of ten steps of the start, the stages as one tube on a line of time, cards, and a tile for each module of the boot image in the color of its hash. No form has a round corner.

## [0.38.0] - 2026-11-10

### Fixed

- **One build gives one hash**: the threads of the compiler changed the order of the functions, and 13 of 48 modules differed between two builds in one folder. The compiler now runs on one thread, and 0 differed in three builds. `kerneltool check` builds the modules two times and compares them.

## [0.37.0] - 2026-11-10

### Changed

- The format of the data disk is a contract (`contract/store`), which the storage service and the kernel tool read.

### Fixed

- **A wrong block under a valid root damages one object, not the storage service.** Before, it stopped the service for every program. The service takes the root before the newest one when only the newest names a wrong block.
- A damaged object is never read as an empty object: `size` answers -8, and the client gives the status `Damaged`. Before, `notes` wrote over its note after a disk error.
- A data disk whose first format a stop cut is formatted again. Before, the service refused it for good.

### Security

- A program could change the name of an object in the call region between the check of the storage service and its use. The service now copies the name one time, then checks and uses the copy.

## [0.36.0] - 2026-11-10

### Added

- **Functions that give the information of the modules**: the manual serves tables of the modules, their exports, their imports, who imports a module, the replacements, and what runs, read from the flat tables and from the module records of the kernel. All 45 modules and their 65 exports take about 150 us. The system has no SQLite.
- **The console combines tables** with `where`, `sort`, `join` and `columns`.
- A description can have a Table result, and Text fields of a fixed size in a record.
- A malformed module gives a `Problem` with its sentence, never a fault.

## [0.35.0] - 2026-11-10

### Added

- **The code of an imported module is one copy** for all the programs that one starter starts, at any base. The program `imports` starts two programs that import `calendar` at two places.

## [0.34.0] - 2026-11-10

### Added

- **Replacement of an import**: after `replace("calendar", "calendar_fixed")`, each next load uses the corrected module in place of the faulty one, and the module that imports it does not change. The loader checks the description of each export that a slot uses, and refuses a module whose description changed.
- The kernel keeps the module records of each program (`Program_Module`, operation 26), and the stop report names the module that ran.
- The program `imports` shows the loader in its cases: a call through an import slot takes 3.5 ns.

### Changed

- The kernel has 26 operations.

## [0.33.0] - 2026-11-10

### Added

- **A program loads a module with imports**: the loader finds each import by its hash in the files that the program was granted, loads each module one time, and binds its slots. The console loads `agenda`, which imports `calendar`.
- A failed load gives a record with its detail (`Load_Error`): the stage, the module, the import, and the hash that the load source does not have.

## [0.32.0] - 2026-11-10

### Added

- **A persistent program**: `notes` keeps a note and a count in its private store across a restart of the machine; each key is one commit. The test runs four machines on one data disk: a clean stop, an end of QEMU during 1000 commits, and a cut root block.

## [0.31.0] - 2026-11-10

### Added

- **The storage service**: each program has a private store on the data disk, named by the root service, with a limit in blocks. The engine is new: copy on write, two places for the root block, and a check in each pointer.
- The storage service starts at the first connection. `storage.stores()` lists the stores for the person, and `revoke(name, "store")` cuts the grant of a program.

## [0.30.0] - 2026-11-10

### Added

- **A block service**: a program drives a virtio disk through device memory, a message interrupt, and memory with a physical address. The root service finds the device on the bus and gives it.
- The program `disk` measures it: with 32 requests in flight, 165 000 to 300 000 blocks read in one second, with one kernel entry for 10 to 20 requests (two runs).
- `Memory_Physical` (operation 25) gives the physical address of a memory object to a holder of the right Physical.

### Changed

- `Device_Create` makes device memory and message interrupts. The kernel has 25 operations.

### Fixed

- A Ports handle that a program received while its ports were open on the processor did not open its ports, and the program stopped on a protection fault.

## [0.29.0] - 2026-11-10

### Added

- **Shared code**: the programs of one module map the same pages of code and constants with no Write, each with its own writable data. Four programs `twin` use 311 pages in place of 320.
- The programs `frames` and `twin` show ten cases of pages on first use and of shared code, each with the answer of the kernel.

## [0.28.0] - 2026-11-10

### Changed

- **Pages on first use**: a memory object reserves its pages in its budget at its creation, and gets each page frame at its first use. There is no overcommit. An object of 8192 pages is ready in 74 us, against 2 560 us with all its frames at once; the first use of a page takes 722 ns.
- The frames of a memory object are in a frame list, not contiguous. The reports and `memory()` show the reserved pages.

## [0.27.0] - 2026-11-10

### Added

- **The menu of the windows** in the bar: a press on the title of a window brings it to the front.

### Fixed

- The kernel tool read lines of the log that QEMU had not finished. It was a cause of a machine test that failed sometimes.

## [0.26.0] - 2026-11-10

### Added

- **Limits of a budget**: a limit of processor time and a limit of log records for each second. The kernel counts processor time with the cycle counter and applies the limit in each period of 100 ms. A limit counts in each budget above.
- `thread_start` takes a budget. The program `limits` runs three threads at 5 %, 20 % and 60 % of one processor.

## [0.25.0] - 2026-11-10

### Added

- **Revocation of a grant**: the kernel keeps the origin of each handle and each mapping, and `Handle_Revoke` (operation 24) ends all that came from a handle. A lent handle is revoked after its call.
- The root service records its grants: `grants` and `revoke` in the console. The program `origin` shows twelve cases.
- `Handle_Give` with the target 0 copies a handle in the same program.

### Changed

- The kernel has 24 operations. A lent handle costs its caller 5 kernel entries and 2000 ns (2 entries before).

### Fixed

- The compositor wrote past its table of windows when it removed a window with 17 programs open, and stopped on a bounds check.

## [0.24.0] - 2026-11-10

### Added

- **Records and handles in a description**: an export takes a Record (bytes with described fields) and a Handle, which is lent with the rights of the description and ends with its call. The console has Record and Handle values: `Rectangle(1, 2, 30, 4)`, `buffer(1)`, `byte(b, 4095)`.
- `Handle_State` (operation 23) proves where a handle came from.
- The module `sample` shows a record and a lent handle in an isolated call.

### Changed

- The kernel has 23 operations.

## [0.23.0] - 2026-11-10

### Changed

- **The console runs in a terminal** and has no surface. The terminal sends key records to its program, and the program owns its edit line. The root service starts a program and its terminal together.
- A terminal draws after a change only.

## [0.22.0] - 2026-11-10

### Added

- The command `kerneltool` in the development shell.

### Changed

- **Two source libraries**: `contract:` (what two parties agree on; the kernel compiles with it only) and `support:` (what a program compiles in). An import names its library; no relative import is left.

## [0.21.0] - 2026-11-10

### Added

- **One module in each role**: `tally` runs as a program, as a service, as a library in the console and as a sandboxed program, with the same hash.
- **A module carries its documentation**, and the program `manual` shows it: the exports, their parameters, and the ways to use the module.
- `unload` in the console removes a module.

## [0.20.0] - 2026-11-10

### Added

- **The time page**: the kernel writes the time in one page that each program reads, so `system.time()` does not enter the kernel. `clock` reads it 879 to 1 491 million times in one second, against 1.9 to 2.4 million with a kernel entry (four runs).

## [0.19.0] - 2026-11-10

### Added

- **A shared queue**: several writers and several readers with no lock, and an event that several threads wait on. `crowd` moves 33.9 million records in one second with 1 writer and 1 reader, with 2 to 6 kernel entries for one million records (alone in the machine).

## [0.18.0] - 2026-11-10

### Added

- **The terminal**: a program sends typed records of text with a style, with no escape sequence. A reader thread and a drawer thread show them, and the display does not slow the program: `flood` writes 1.7 to 3.0 million lines in one second (five runs).
- A surface can have two pictures.
- `kerneltool film` films the terminal.

### Fixed

- A ring of 0.17.0 could lose a wake.

## [0.17.0] - 2026-11-10

### Added

- **A ring has a capacity, chosen at its creation**: one wake serves many records, and `wait_spin` spins a short time before it waits. `flow` moves 29.8 million records in one second with a capacity of 1024 and `wait_spin`, with 56 kernel entries for one million records (one run).

### Changed

- A full ring slows its writer to the speed of its reader: a ring does not grow.

## [0.16.0] - 2026-11-10

### Added

- **A program that runs serves its own exports**: `connect("paint")` in the console, then `paint.line(...)`. The root service makes each connection, and a call has the same description and the same form as the call of a module. `paint` and `life` serve exports.

## [0.15.0] - 2026-11-10

### Added

- **The log is records in channels**: each record has a time, a program, a thread, a level, a channel and a text. The kernel is the one writer; a reader maps the records with the right Read. The program `log` shows them.

## [0.14.0] - 2026-11-10

### Changed

- **The launcher is a menu**: one button in the bar opens one line for each program.

## [0.13.0] - 2026-11-10

### Added

- **Paging protects the kernel from itself**: guard pages around each kernel stack, no page writable and executable, the direct map not executable, SMEP and SMAP, and one place where the kernel uses the memory of a program (`user_copy`).
- Six tests of the kernel on itself: each one does a thing that the page tables refuse, and checks the report of the fault. The program `pages` shows what the page tables give.

## [0.12.0] - 2026-11-10

### Added

- **The boot display**: a boot record with the stages of the start, drawn by the boot program, then by the root service, then by the program `boot`. A start that fails keeps the display, with its cause.

## [0.11.0] - 2026-11-10

### Added

- **Several processors**: the kernel runs on each processor under one kernel lock, with a processor record and a timer for each. `processors` shows four processors that run one program: a picture takes 404 ms with 1 thread and 148 ms with 4 (one run).

## [0.10.0] - 2026-11-10

### Added

- **Budgets**: no kernel operation creates an object from nothing. A memory object, a program and a thread take a budget handle with the right Spend. `Budget_Create` and `Budget_Read` are operations 21 and 22. The program `budget` shows each page come back.
- The log is an object: `Log` takes a Log handle with the right Write.

### Changed

- The kernel has 22 operations.

## [0.9.0] - 2026-11-10

### Added

- **Rights on handles**: each handle has a set of rights, `Handle_Give` copies a handle with fewer rights, and an operation without its right gives `No_Right`. The machine is one object with the rights Inspect, Devices and Stop. In the program `rights` the kernel does four operations and refuses five.

## [0.8.0] - 2026-11-10

### Changed

- **Descriptions come from the source**: the kernel tool reads the name of each parameter and the help from the comment of each export, and the test checks them.

## [0.7.0] - 2026-11-10

### Added

- **The console runs a line in a second thread**: it keeps the keys during a call, and Escape stops an isolated call.

### Removed

- The limit of 2000 ms of an isolated call. The person decides with Escape.

## [0.6.0] - 2026-11-10

### Changed

- **One wait**: rings wait on words, and each thread has an event word.

### Removed

- The operation `Wake(memory)`. The kernel has 20 operations.

## [0.5.0] - 2026-11-10

### Added

- **The word wait and a lock**: `Word_Wait` and `Word_Wake` (operations 19 and 20) on a word in shared memory, and `system.Lock` as a library over them. `workers` shows four threads on one number, and one queue of 140 tiles.
- The kernel tool writes the boot volume itself.

### Changed

- The kernel has 21 operations.

## [0.4.0] - 2026-11-10

### Added

- **Several threads in a program**, each with its own kernel ring: `Thread_Create`, `Thread_Stop` and `Thread_State`. `threads` draws one square from each of five threads.

### Changed

- The kernel has 19 operations.

## [0.3.0] - 2026-11-10

### Added

- **Text results**: an export writes text into a buffer of the caller and gives a count of bytes.

## [0.2.0] - 2026-11-10

### Added

- **The program `rings`**: six programs pass records through six rings, drawn live from the shared memory. A stopped program takes no record: the records wait in its ring.

## [0.1.0] - 2026-11-10

### Added

- **The isolated call**: `isolate("probe")` in the console runs a module in a call host, a sandboxed program with no handle, and calls its exports through a ring. A module that faults or loops stops alone.

## [0.0.0] - 2026-11-10

### Added

- **The system boots under QEMU to a desktop**: a UEFI boot program loads the kernel module and the boot image. The kernel has one entry point and runs the operations of the kernel ring of each thread (16 operations). The root service starts the other programs in user space and grants their handles.
- **The console**: integers, texts, variables, arithmetic and typed commands. `load("math")` makes the exports of a module commands.
- **The desktop**: the compositor with a bar, a clock, windows, focus, drag and close; it draws only the damaged rectangles. The programs `monitor`, `plasma`, `life`, `paint` and `temple`; `fault` shows that a fault stops one program only.
- **The module format**: a module is named by the BLAKE3 hash of its content. The kernel tool converts a linked ELF image to a module, builds the boot image, and tests the machine under QEMU.

[0.96.0]: https://github.com/sachahjkl/modus/releases/tag/v0.96.0
[0.95.0]: https://github.com/sachahjkl/modus/releases/tag/v0.95.0
[0.94.0]: https://github.com/sachahjkl/modus/releases/tag/v0.94.0
[0.93.0]: https://github.com/sachahjkl/modus/releases/tag/v0.93.0
[0.92.0]: https://github.com/sachahjkl/modus/releases/tag/v0.92.0
[0.91.0]: https://github.com/sachahjkl/modus/releases/tag/v0.91.0
[0.86.0]: https://github.com/sachahjkl/modus/releases/tag/v0.86.0
[0.85.0]: https://github.com/sachahjkl/modus/releases/tag/v0.85.0
[0.84.0]: https://github.com/sachahjkl/modus/releases/tag/v0.84.0
[0.83.0]: https://github.com/sachahjkl/modus/releases/tag/v0.83.0
[0.82.0]: https://github.com/sachahjkl/modus/releases/tag/v0.82.0
[0.81.0]: https://github.com/sachahjkl/modus/releases/tag/v0.81.0
[0.80.0]: https://github.com/sachahjkl/modus/releases/tag/v0.80.0
[0.79.0]: https://github.com/sachahjkl/modus/releases/tag/v0.79.0
[0.78.0]: https://github.com/sachahjkl/modus/releases/tag/v0.78.0
[0.77.0]: https://github.com/sachahjkl/modus/releases/tag/v0.77.0
[0.76.0]: https://github.com/sachahjkl/modus/releases/tag/v0.76.0
[0.75.0]: https://github.com/sachahjkl/modus/releases/tag/v0.75.0
[0.74.0]: https://github.com/sachahjkl/modus/releases/tag/v0.74.0
[0.73.0]: https://github.com/sachahjkl/modus/releases/tag/v0.73.0
[0.72.0]: https://github.com/sachahjkl/modus/releases/tag/v0.72.0
[0.71.0]: https://github.com/sachahjkl/modus/releases/tag/v0.71.0
[0.70.0]: https://github.com/sachahjkl/modus/releases/tag/v0.70.0
[0.69.0]: https://github.com/sachahjkl/modus/releases/tag/v0.69.0
[0.68.0]: https://github.com/sachahjkl/modus/releases/tag/v0.68.0
[0.67.0]: https://github.com/sachahjkl/modus/releases/tag/v0.67.0
[0.66.0]: https://github.com/sachahjkl/modus/releases/tag/v0.66.0
[0.65.0]: https://github.com/sachahjkl/modus/releases/tag/v0.65.0
[0.64.0]: https://github.com/sachahjkl/modus/releases/tag/v0.64.0
[0.63.0]: https://github.com/sachahjkl/modus/releases/tag/v0.63.0
[0.62.0]: https://github.com/sachahjkl/modus/releases/tag/v0.62.0
[0.61.0]: https://github.com/sachahjkl/modus/releases/tag/v0.61.0
[0.60.0]: https://github.com/sachahjkl/modus/releases/tag/v0.60.0
[0.59.0]: https://github.com/sachahjkl/modus/releases/tag/v0.59.0
[0.58.0]: https://github.com/sachahjkl/modus/releases/tag/v0.58.0
[0.57.0]: https://github.com/sachahjkl/modus/releases/tag/v0.57.0
[0.56.0]: https://github.com/sachahjkl/modus/releases/tag/v0.56.0
[0.55.0]: https://github.com/sachahjkl/modus/releases/tag/v0.55.0
[0.54.0]: https://github.com/sachahjkl/modus/releases/tag/v0.54.0
[0.53.0]: https://github.com/sachahjkl/modus/releases/tag/v0.53.0
[0.52.0]: https://github.com/sachahjkl/modus/releases/tag/v0.52.0
[0.51.0]: https://github.com/sachahjkl/modus/releases/tag/v0.51.0
[0.50.0]: https://github.com/sachahjkl/modus/releases/tag/v0.50.0
[0.49.0]: https://github.com/sachahjkl/modus/releases/tag/v0.49.0
[0.48.0]: https://github.com/sachahjkl/modus/releases/tag/v0.48.0
[0.47.0]: https://github.com/sachahjkl/modus/releases/tag/v0.47.0
[0.46.0]: https://github.com/sachahjkl/modus/releases/tag/v0.46.0
[0.45.0]: https://github.com/sachahjkl/modus/releases/tag/v0.45.0
[0.44.0]: https://github.com/sachahjkl/modus/releases/tag/v0.44.0
[0.43.0]: https://github.com/sachahjkl/modus/releases/tag/v0.43.0
[0.42.0]: https://github.com/sachahjkl/modus/releases/tag/v0.42.0
[0.41.0]: https://github.com/sachahjkl/modus/releases/tag/v0.41.0
[0.40.0]: https://github.com/sachahjkl/modus/releases/tag/v0.40.0
[0.39.0]: https://github.com/sachahjkl/modus/releases/tag/v0.39.0
[0.38.0]: https://github.com/sachahjkl/modus/releases/tag/v0.38.0
[0.37.0]: https://github.com/sachahjkl/modus/releases/tag/v0.37.0
[0.36.0]: https://github.com/sachahjkl/modus/releases/tag/v0.36.0
[0.35.0]: https://github.com/sachahjkl/modus/releases/tag/v0.35.0
[0.34.0]: https://github.com/sachahjkl/modus/releases/tag/v0.34.0
[0.33.0]: https://github.com/sachahjkl/modus/releases/tag/v0.33.0
[0.32.0]: https://github.com/sachahjkl/modus/releases/tag/v0.32.0
[0.31.0]: https://github.com/sachahjkl/modus/releases/tag/v0.31.0
[0.30.0]: https://github.com/sachahjkl/modus/releases/tag/v0.30.0
[0.29.0]: https://github.com/sachahjkl/modus/releases/tag/v0.29.0
[0.28.0]: https://github.com/sachahjkl/modus/releases/tag/v0.28.0
[0.27.0]: https://github.com/sachahjkl/modus/releases/tag/v0.27.0
[0.26.0]: https://github.com/sachahjkl/modus/releases/tag/v0.26.0
[0.25.0]: https://github.com/sachahjkl/modus/releases/tag/v0.25.0
[0.24.0]: https://github.com/sachahjkl/modus/releases/tag/v0.24.0
[0.23.0]: https://github.com/sachahjkl/modus/releases/tag/v0.23.0
[0.22.0]: https://github.com/sachahjkl/modus/releases/tag/v0.22.0
[0.21.0]: https://github.com/sachahjkl/modus/releases/tag/v0.21.0
[0.20.0]: https://github.com/sachahjkl/modus/releases/tag/v0.20.0
[0.19.0]: https://github.com/sachahjkl/modus/releases/tag/v0.19.0
[0.18.0]: https://github.com/sachahjkl/modus/releases/tag/v0.18.0
[0.17.0]: https://github.com/sachahjkl/modus/releases/tag/v0.17.0
[0.16.0]: https://github.com/sachahjkl/modus/releases/tag/v0.16.0
[0.15.0]: https://github.com/sachahjkl/modus/releases/tag/v0.15.0
[0.14.0]: https://github.com/sachahjkl/modus/releases/tag/v0.14.0
[0.13.0]: https://github.com/sachahjkl/modus/releases/tag/v0.13.0
[0.12.0]: https://github.com/sachahjkl/modus/releases/tag/v0.12.0
[0.11.0]: https://github.com/sachahjkl/modus/releases/tag/v0.11.0
[0.10.0]: https://github.com/sachahjkl/modus/releases/tag/v0.10.0
[0.9.0]: https://github.com/sachahjkl/modus/releases/tag/v0.9.0
[0.8.0]: https://github.com/sachahjkl/modus/releases/tag/v0.8.0
[0.7.0]: https://github.com/sachahjkl/modus/releases/tag/v0.7.0
[0.6.0]: https://github.com/sachahjkl/modus/releases/tag/v0.6.0
[0.5.0]: https://github.com/sachahjkl/modus/releases/tag/v0.5.0
[0.4.0]: https://github.com/sachahjkl/modus/releases/tag/v0.4.0
[0.3.0]: https://github.com/sachahjkl/modus/releases/tag/v0.3.0
[0.2.0]: https://github.com/sachahjkl/modus/releases/tag/v0.2.0
[0.1.0]: https://github.com/sachahjkl/modus/releases/tag/v0.1.0
[0.0.0]: https://github.com/sachahjkl/modus/releases/tag/v0.0.0
