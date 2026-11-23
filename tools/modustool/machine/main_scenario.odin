package machine

import op "modus:contract/operation"
import "modustool:build"
import "modustool:checks"

// The step that waits for the refusal of a builder that never answers: the
// service recipes waits the bound of one build, a rule of the system
// (builder.BUILD_TIME_BOUND_MILLISECONDS), before it ends the builder, so the
// step outlasts that bound (a host test of the tool checks it).
BUILDER_HANG_STEP_SECONDS :: 300

main_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	return machine_test(part, scenario[:], {volume = build.BOOT_VOLUME, output = checks.TEST_OUTPUT, exit_status = build.MACHINE_STOP_OK})
}

// The line of `errors` that is longer than the text of one log record by
// construction (`JOINED_LINE` in src/modules/demonstrations/errors/main.odin):
// the step Record finds it only when it joins two rows of log.records.
ERRORS_JOINED_LINE :: "errors: a line longer than one log record: its words only make it longer than the text of one record, so that the cut between two records falls inside it, and a reader of the log joins two rows to read it whole: as it must"
#assert(len(ERRORS_JOINED_LINE) > op.LOG_TEXT_CAPACITY)

// The positions below come from src/modules/system/compositor/main.odin: the buttons
// in the bar, and the place of window n at (60 + 36 n, 52 + 30 n).
scenario := [?]Step {
	{kind = .Wait, text = "boot program: ok"},
	// The kernel says if each processor registered its steal-time record,
	// or why the machine has none: under KVM the line names the count of
	// the processors, under TCG the absence (src/md/features/stolen_time.md).
	{kind = .Wait, text = "kernel: steal time: "},
	{kind = .Wait, text = "kernel: ok"},
	// The kernel writes the time of each stage of the boot, on the channel
	// boot. The serial port keeps each line, so this check reads them here:
	// the ring of the log keeps only the newest records, and the window of
	// the log starts long after the boot. The root service runs on another
	// processor while the kernel writes them, so its lines can come
	// between them.
	{kind = .Wait, text = "kernel: boot: firmware: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: boot program: load the kernel, the boot image: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: boot program: page tables, memory map, jump: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: page frames, kernel page table: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: first processor, timer: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: other processors: ", any_order = true},
	{kind = .Wait, text = "kernel: boot: kernel: root service: ", any_order = true},
	// The demonstration pair of the default start list: the start policy
	// starts wired_reader, then wired_writer with the wiring row between
	// them (src/md/features/module_outputs.md, "The wiring rows of a start
	// list"). The writer has its reader at its first instruction, and the
	// reader reads every number from the joined record of 0. The pair runs
	// beside the rest of the start, so its lines have no fixed place.
	{kind = .Wait, text = "wired_writer: wrote 16 numbers to 1 reader, and ended numbers", any_order = true, fails_on = "wired_writer: wrote 16 numbers to 0 reader"},
	// A reader with no writer stops with Done and a plain fact, as on a
	// machine of a principal: the test fails on that fact, then on a
	// record that breaks the order. Each step names one failure.
	{kind = .Wait, text = "wired_reader: read the joined record of 0, the 16 numbers of wired_writer in order, and a clean end", any_order = true, fails_on = "wired_reader: no writer came"},
	{kind = .Wait, text = "wired_reader: read the joined record of 0, the 16 numbers of wired_writer in order, and a clean end", any_order = true, fails_on = "wired_reader: WRONG"},
	{kind = .Wait, text = "root: ok"},
	// The kernel refuses a stop code past one byte, and the machine runs on.
	{kind = .Wait, text = "root: Machine_Stop refused the codes 256 and 18446744073709551615 with Bad_Operation and the record Bad_Value of the code, limit 255, and the machine runs on: as it must"},
	// The virtual mouse of QEMU answers the IntelliMouse sequence: its
	// packets have the wheel. The input service and the compositor run
	// on their own processors, so the line of the compositor can come
	// before this one: an ordered wait here would move the place of the
	// log past it, and the step of the screen pages would never see it.
	{kind = .Wait, text = "input: ok, the mouse has a wheel", any_order = true},
	// The date: the process `date` starts after the input service and reads the real-time clock of the machine,
	// which QEMU takes from the clock of the host. The date must be within a
	// few seconds of the host.
	{kind = .Date, text = " UTC, seconds since 1970 ", any_order = true},
	// The standard VGA of the machine holds two screen pages, and the
	// compositor flips between them (src/md/infrastructure/whole_frame.md).
	{kind = .Wait, text = "compositor: two screen pages: each frame reaches the screen whole, by a page flip", any_order = true, fails_on = "compositor: one screen page"},
	// The firmware gave the mode that the boot program asked for: the
	// compositor shows the reference screen.
	{kind = .Screen_Size, text = SCREEN_SIZE_LINE, any_order = true},
	// The two come in an order that the system does not fix.
	{kind = .Wait, text = "compositor: first frame", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	// The compositor names what the fallback chains lack, once at each
	// boot (docs/FONTS.md, "13. Glyphs past the glyph cache").
	{kind = .Wait, text = "compositor: the script greek: the chain of the interface draws 49 of its 49 characters, the chain of the cells 49", any_order = true},
	{kind = .Wait, text = "compositor: the script cyrillic: the chain of the interface draws 96 of its 96 characters, the chain of the cells 96", any_order = true},
	{kind = .Wait, text = "compositor: the script box drawing: the chain of the interface draws 160 of its 160 characters, the chain of the cells 160", any_order = true},
	// The boot pass of settings: the storage service starts at boot, with
	// the block service of the data disk; a new disk keeps no settings.
	{kind = .Wait, text = "storage: ok, a new disk: generation 1, 16384 blocks", any_order = true},
	// The console asks for the store of its line history at its start: the
	// root service answers after the start of the boot pass, so the storage
	// service runs.
	{kind = .Wait, text = "root: connected console to the store of its line history in the service storage, 4 blocks", any_order = true},
	{kind = .Wait, text = "console: no line history kept: the history starts empty", any_order = true},
	// The first window takes the free place at the top left of the work
	// area (src/md/features/window_placement.md); the steps of this
	// scenario press the titles of the windows that it moves over the
	// console at the place where the console stood in a cascade.
	{kind = .Move, text = "console", to_x = 64, to_y = 56},
	{kind = .Wait, text = "settings: the boot pass: no settings kept: the defaults: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; in ", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},

	// The console: a language with typed commands.
	{kind = .Type, text = "1 + 2 * 3"},
	{kind = .Wait, text = "[console] 7"},
	{kind = .Type, text = "name = \"kernel\""},
	{kind = .Type, text = "length(name + \"!\") * 2"},
	{kind = .Wait, text = "[console] 14"},
	{kind = .Type, text = "hash(\"abc\")"},
	{kind = .Wait, text = "[console] 6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85"},
	// A Text is UTF-8 in every contract: the console writes a character
	// outside ASCII, and the line of the log holds its two bytes C3 A9.
	{kind = .Type, text = "\"caf\" + character(233)"},
	{kind = .Wait, text = "[console] café"},
	{kind = .Type, text = "length(character(233))"},
	{kind = .Wait, text = "[console] 2"},
	// Characters past the glyph cache: the terminal draws each one itself,
	// in its private glyph cache. α is not in Paper Mono: it comes from
	// B612, the second font of the chain of the cells; Ж is in neither: it
	// comes from Noto Sans, the last font of the chain. Ѡ (U+0460) is in no
	// font of the system: the replacement glyph. The terminal tells the
	// first and the last such cell of its view, once for each font.
	{kind = .Type, text = "character(945) + character(1046)"},
	{kind = .Wait, text = "terminal: console shows the character 945 in its cells, drawn by this process from the font b612 of its fallback chain", any_order = true},
	{kind = .Wait, text = "terminal: console shows the character 1046 in its cells, drawn by this process from the font noto_sans of its fallback chain", any_order = true},
	{kind = .Wait, text = "[console] αЖ"},
	{kind = .Type, text = "character(1120)"},
	{kind = .Wait, text = "terminal: console shows the character 1120 in its cells as the replacement glyph: no font of its fallback chain has it", any_order = true},
	{kind = .Wait, text = "[console] Ѡ"},
	// A Greek letter and a box-drawing character of Paper Mono, the first
	// font of the chain: ─ is now the last such cell of the view. The
	// picture console below shows them.
	{kind = .Type, text = "character(955) + character(9472)"},
	{kind = .Wait, text = "terminal: console shows the character 9472 in its cells, drawn by this process from the font paper_mono of its fallback chain", any_order = true},
	{kind = .Wait, text = "[console] λ─"},
	{kind = .Type, text = "character(55296)"},
	{kind = .Wait, text = "error: 55296 is no character of a text"},
	{kind = .Type, text = "length(5)"},
	{kind = .Wait, text = "error: length: argument 1 is Text, not Integer"},
	{kind = .Type, text = "where(modules(), name = \"compositor\")"},
	{kind = .Wait, text = "[console] compositor  "},
	{kind = .Type, text = "start(\"life\")"},
	{kind = .Wait, text = "life: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Shot, text = "console"},

	// The desktop: start processes from the menu of the bar and from the
	// palette, and move the windows.
	{kind = .Move, text = "life", to_x = 24, to_y = 408},
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 520, to_y = 408},
	{kind = .Click_Element, text = "paint", element = "red"},
	{kind = .Drag, x = 560, y = 520, to_x = 760, to_y = 700},
	{kind = .Click_Element, text = "paint", element = "blue"},
	{kind = .Drag, x = 760, y = 520, to_x = 560, to_y = 700},
	{kind = .Drag, x = 800, y = 600, to_x = 960, to_y = 600},
	// No save action (docs/PROPERTIES.md, "Persistence: no save action,
	// and versions for all processes"): the store keeps the picture after a
	// pause of a second. A new start of paint opens it with its drawing.
	{kind = .Wait, text = "paint: the store keeps the picture: "},
	{kind = .Close, text = "paint"},
	{kind = .Wait, text = "root: paint stopped"},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "paint: the picture is open with a drawing: 640 x 352 pixels, "},
	{kind = .Move, text = "paint", to_x = 520, to_y = 408},
	// The palette: the key super opens it. With no letter it lists the
	// windows, the front one first, then the processes.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Shot, text = "palette_open"},
	// Letters of a process: the list narrows at each key, over the windows
	// and the processes in one ranking, and each matched letter is marked.
	// Enter starts the chosen process.
	{kind = .Keys, text = "p"},
	{kind = .Wait, text = "compositor: the palette lists "},
	{kind = .Wait, text = " for \"p\": "},
	{kind = .Shot, text = "palette_modules"},
	{kind = .Keys, text = "la"},
	{kind = .Wait, text = " for \"pla\": plasma (module)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts plasma"},
	{kind = .Wait, text = "plasma: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Move, text = "plasma", to_x = 232, to_y = 144},
	{kind = .Shot, text = "desktop_moved"},
	// Letters of the title of a window: with equal scores the window comes
	// before the process of the same name. Enter brings the window to the
	// front.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "mon"},
	{kind = .Wait, text = " for \"mon\": monitor (window), monitor (module)"},
	{kind = .Shot, text = "palette_windows"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette brings monitor to the front"},
	{kind = .Wait, text = "compositor: window monitor in front"},
	// Escape closes the panel, and no process gets the key.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A part that no name has: the list is empty, and Enter runs nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "xyz"},
	{kind = .Wait, text = "compositor: the palette lists 0 of "},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette has no entry to run"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},
	// The start menu: the button of the bar opens and closes it.
	{kind = .Click, text = BAR_START_BUTTON},
	{kind = .Shot, text = "menu"},
	{kind = .Click, text = BAR_START_BUTTON},
	// The menu of the windows: a press on a line brings the window to the
	// front.
	{kind = .Click, text = BAR_WINDOWS_BUTTON},
	{kind = .Wait, text = "compositor: windows: "},
	{kind = .Shot, text = "windows"},
	{kind = .Click, text = BAR_WINDOWS_BUTTON},
	{kind = .Front, text = "console"},
	{kind = .Front, text = "plasma"},

	// A process that fails stops alone.
	{kind = .Launch, text = "fault"},
	{kind = .Wait, text = "stopped: page fault"},
	{kind = .Wait, text = "root: fault stopped"},
	// The palette closes a window. The match is fuzzy: "closepla" has the
	// letters of "close plasma" in their order. The entry destroys, so the
	// panel asks for a second Enter; another key goes back to the search
	// and stops nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "closepla"},
	{kind = .Wait, text = " for \"closepla\": close plasma (close a window)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: close plasma"},
	{kind = .Shot, text = "palette_confirm"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: close plasma"},
	{kind = .Key, text = "ret"},
	// The compositor and the root service write their lines in either
	// order: the wait of the compositor does not move the mark.
	{kind = .Wait, text = "compositor: the palette closes the window plasma", any_order = true},
	{kind = .Wait, text = "root: plasma stopped"},

	// The commands of the console in the palette: the console is the
	// palette provider. A command with no parameter runs from the panel,
	// as a line of the console: memory() gives a Record, which the panel
	// shows.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "memo"},
	{kind = .Wait, text = " for \"memo\": memory (command)"},
	{kind = .Shot, text = "palette_commands"},
	{kind = .Key, text = "ret"},
	// The compositor and the console write their lines on one log, in the
	// order of their own threads: the line of the compositor is looked for
	// with no move of the place in the log, here and in the steps below.
	{kind = .Wait, text = "compositor: the palette sends memory to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs memory()"},
	{kind = .Wait, text = "console: the palette gets Record, "},
	{kind = .Wait, text = "compositor: the palette shows a Record"},
	{kind = .Shot, text = "palette_result"},
	// Another key leaves the result; Escape then closes the panel.
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A Table is too large for the panel: the panel closes, and the
	// window of the console comes to the front with the line and its table.
	{kind = .Front, text = "monitor"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "processes"},
	{kind = .Wait, text = " for \"processes\": processes (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends processes to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs processes()"},
	{kind = .Wait, text = "console: the result of the palette choice is in the console: Table"},
	{kind = .Wait, text = "compositor: the result of the palette is in the console"},
	{kind = .Wait, text = "compositor: window console in front"},
	// A command with parameters: Enter turns the input band into its form,
	// one field for each parameter. The console gives the candidates of a
	// field: the modules of the boot image for start. Tab takes the chosen
	// one, and Enter in the last field runs the line that the console
	// builds from the typed values.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "start"},
	{kind = .Wait, text = " for \"start\": start (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of start"},
	{kind = .Wait, text = " candidates for the parameter 0 of start"},
	{kind = .Wait, text = " candidates for the field 0"},
	{kind = .Keys, text = "plasm"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "compositor: the palette takes the candidate plasma"},
	{kind = .Shot, text = "palette_arguments"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends start with 1 arguments to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs start(\"plasma\")"},
	{kind = .Wait, text = "compositor: the palette shows no value", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// Two fields, and a command that destroys: the processes that run for
	// the first field, the grants for the second one. The panel asks for a
	// second Enter after the arguments.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "revoke"},
	{kind = .Wait, text = " for \"revoke\": revoke (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of revoke"},
	{kind = .Wait, text = " candidates for the parameter 0 of revoke"},
	{kind = .Wait, text = " candidates for the field 0"},
	{kind = .Keys, text = "plasm"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "compositor: the palette takes the candidate plasma"},
	// A press in the second field puts the caret there: the band shows
	// "revoke(name: plasma, grant: )", and the press is in the middle of
	// "grant: ", on the name of the second parameter. The text typed after
	// it is the value of that field: the line that the console runs has it
	// as its second argument.
	{kind = .Click_Element, text = PALETTE_ELEMENTS, element = "field 1"},
	// The press asks the console for the candidates of the field. The
	// compositor writes its line of the press and the console its line of
	// the candidates in no fixed order: neither wait moves the place of
	// the log. The palette has the candidates after both.
	{kind = .Wait, text = "compositor: a press puts the caret of the palette in the field 1, after 0 characters", any_order = true},
	{kind = .Wait, text = " candidates for the parameter 1 of revoke", any_order = true},
	{kind = .Wait, text = " candidates for the field 1"},
	{kind = .Keys, text = "log"},
	{kind = .Wait, text = "compositor: the field 1 of revoke shows \"log\""},
	{kind = .Shot, text = "palette_arguments_two"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: revoke"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends revoke with 2 arguments to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs revoke(\"plasma\", \"log\")"},
	{kind = .Wait, text = "root: revoked the grant log of plasma"},
	{kind = .Wait, text = "compositor: the palette shows an Integer"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A prefix restricts the kinds: ">" lists the commands only.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ">mem"},
	{kind = .Wait, text = " for \">mem\": memory (command)"},
	{kind = .Shot, text = "palette_prefix"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The scroll bar of the panel takes the pointer: the prefix alone lists
	// each command, more than the 12 rows of the panel, and a press on the
	// arrow button at the bottom moves the rows by one.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ">"},
	{kind = .Wait, text = " for \">\": "},
	{kind = .Click_Element, text = PALETTE_ELEMENTS, element = "scroll bar arrow down"},
	{kind = .Wait, text = "compositor: the scroll bar of the palette: a press on the arrow down, the rows from 1"},
	// The wheel over the rows moves them too: one notch toward the end,
	// three rows (interface.SCROLL_WHEEL_LINES_PER_NOTCH).
	{kind = .Wheel, text = PALETTE_ELEMENTS, element = "scroll bar view", notches = NOTCH_TOWARD_THE_END},
	{kind = .Wait, text = "compositor: the wheel moves the rows of the palette: the rows from 4"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A field that counts a size shows its unit after the number: the
	// console states that buffer takes a count of pages (the picture).
	// Escape leaves the form, and no memory object is made.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ">buffer"},
	{kind = .Wait, text = " for \">buffer\": buffer (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of buffer"},
	// The shot shows the unit of the empty field: no line of the log says
	// that a typed digit is drawn, so a shot after a digit could show it or not.
	{kind = .Wait, text = "compositor: the field 0 of buffer takes a number in pages"},
	{kind = .Shot, text = "palette_unit"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// An export states the unit of a number in its description, as a
	// built-in command states it: the third parameter of
	// hkdf_sha256_expand is a count of bytes. The console loads the module,
	// and the palette shows the unit of the export with no code for it.
	// Escape leaves the form, and nothing runs.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "load(\"cryptography\")"},
	{kind = .Wait, text = "[console]   module     cryptography"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ">hkdf_sha256_expand"},
	{kind = .Wait, text = " for \">hkdf_sha256_expand\": hkdf_sha256_expand (export)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of hkdf_sha256_expand"},
	{kind = .Wait, text = "compositor: the field 2 of hkdf_sha256_expand takes a number in bytes"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "unload(\"cryptography\")"},
	{kind = .Wait, text = "[console]   module    cryptography"},
	// The buttons of a field take the pointer. The field of strategy is a
	// row of three buttons in the band, at the right of the call
	// "strategy(name: )". Right chooses fair; a press and a release on the
	// button round_robin take it, as Tab takes the value that the keys
	// chose. Escape leaves with no change of the strategy.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ">strategy"},
	{kind = .Wait, text = " for \">strategy\": strategy (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = " candidates for the field 0, as a row of buttons"},
	{kind = .Key, text = "right"},
	{kind = .Click_Element, text = PALETTE_ELEMENTS, element = "round_robin"},
	{kind = .Wait, text = "compositor: a press takes the button round_robin of the field 0"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The settings: the palette starts the process settings. Its window
	// names the button of the value in use of each setting, and gives the
	// compositor the set of these act names; the two processes write their
	// lines in an order that the system does not fix. Then ":font" lists
	// the font as one setting row, with a button for each value and the
	// value in use marked. Right chooses spleen, Enter sets it behind the
	// open panel, and the panel shows its list again with the value on its
	// row. Left and Enter set vector back.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "settings"},
	{kind = .Wait, text = " for \"settings\": settings (module)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "compositor: the window settings gave 7 act names", any_order = true},
	{kind = .Wait, text = "settings: ok, ", any_order = true},
	// The rows of the settings come from the enum parameters of the export
	// set: the console lists them once it is connected to the service.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ":font"},
	// The row of font is the first row of ":" already: its line can come
	// before the list of ":font", which keeps the same row and writes no
	// second line. The row line is found from the open, in either order.
	{kind = .Wait, text = "compositor: the palette shows the setting font as one row of 2 values", any_order = true},
	// The entries of the scale say their display text, "1.75", which
	// ":font" does not match: the picture shows the row of the font alone.
	// An entry that names the member, fourteen_eighths, fails the step.
	{kind = .Wait, text = " for \":font\": font (setting)", fails_on = "settings.set scale to fourteen_eighths"},
	{kind = .Key, text = "right"},
	{kind = .Wait, text = "compositor: the palette chooses the value spleen of font"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sets font to spleen, by a key"},
	{kind = .Wait, text = "compositor: the palette sends settings.set font to spleen to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs settings.set(font = .spleen)"},
	// The getter of the row said the new member, and the table marks it:
	// the picture shows the mark on spleen. The console logs the mark
	// after the line that it runs, and the compositor its line "did" in an
	// order that the system does not fix: the mark is found from the line
	// that runs, before the wait for "did" moves the place of the log.
	{kind = .Wait, text = "console: the palette marks .spleen for settings.set font", any_order = true},
	{kind = .Wait, text = "settings: font spleen, ", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font spleen", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: settings.set font to spleen"},
	{kind = .Shot, text = "palette_setting_row"},
	{kind = .Key, text = "left"},
	{kind = .Wait, text = "compositor: the palette chooses the value vector of font"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the palette runs settings.set(font = .vector)"},
	{kind = .Wait, text = "console: the palette marks .vector for settings.set font", any_order = true},
	{kind = .Wait, text = "settings: font vector, ", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font vector", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: settings.set font to vector"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// The display text of a member: the scale has 7 members, so each one
	// is an entry, which says its display text and runs the line with its
	// name. The search finds the entry by its text.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ":1.75"},
	{kind = .Wait, text = " for \":1.75\": settings.set scale to 1.75 (setting)", fails_on = "fourteen_eighths (setting)"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// Go to: the window of settings names what the row of the grid fit
	// acts on, so the band offers Shift with Enter (the picture). Shift
	// with Enter raises the window, and its window layer puts the focus on
	// the button of the value in use.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ":grid"},
	{kind = .Wait, text = " for \":grid\": grid_fit (setting)"},
	{kind = .Shot, text = "palette_go_to"},
	{kind = .Key, text = "shift-ret"},
	{kind = .Wait, text = "compositor: the palette goes to grid_fit in the window settings, now in front", any_order = true},
	{kind = .Wait, text = "interface: settings: the focus is on the element of settings.set:grid_fit", any_order = true},
	{kind = .Close, text = "settings"},
	{kind = .Wait, text = "root: settings stopped"},
	// The console came in front for the load of a module, and its window
	// can cover the close box of plasma: the step Close brings plasma to
	// the front first.
	{kind = .Close, text = "plasma"},
	{kind = .Wait, text = "root: plasma stopped"},
	// The scheduling strategy: the process scheduler holds the right to
	// change it and serves strategy_set after its checks, so the palette
	// starts the process and the scenario waits for the end of the checks.
	// ":strat" then lists the strategies as one setting row, with the mark
	// on the one in use, EEVDF, the last value. Left chooses fair, and
	// Enter sets the strategy through the console, which calls the export,
	// and the process writes the change on the log. The second choice, Right
	// from fair at the next open, gives the machine back the strategy of
	// its start.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "scheduler"},
	{kind = .Wait, text = " for \"scheduler\": scheduler (module)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts scheduler"},
	{kind = .Wait, text = "scheduler: round robin: two threads that wake each other"},
	{kind = .Wait, text = "scheduler: fair: two threads that wake each other"},
	{kind = .Wait, text = "scheduler: EEVDF: two threads that wake each other"},
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: ok, no spinner starved under 3 strategies"},
	{kind = .Wait, text = "scheduler: the window took "},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ":strat"},
	// The row of the setting is drawn at the first list that holds it, which
	// can be the list of a shorter text: the line of the list does not move
	// the place of the log.
	{kind = .Wait, text = " for \":strat\": strategy (setting)", any_order = true},
	{kind = .Wait, text = "compositor: the palette shows the setting strategy as one row of 3 values"},
	{kind = .Shot, text = "palette_strategy"},
	{kind = .Key, text = "left"},
	{kind = .Wait, text = "compositor: the palette chooses the value fair of strategy"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sets strategy to fair, by a key"},
	{kind = .Wait, text = "compositor: the palette sends set strategy to fair to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs strategy(\"fair\")"},
	{kind = .Wait, text = "scheduler: the strategy is now fair, it was EEVDF"},
	// The console marks the strategy in use in a new table; the compositor
	// writes its line on the same log, in an order that the system does not fix.
	{kind = .Wait, text = "console: the palette table has ", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: set strategy to fair"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = ":strat"},
	{kind = .Wait, text = " for \":strat\": strategy (setting)"},
	{kind = .Key, text = "right"},
	{kind = .Wait, text = "compositor: the palette chooses the value eevdf of strategy"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the palette runs strategy(\"eevdf\")"},
	{kind = .Wait, text = "scheduler: the strategy is now EEVDF, it was fair"},
	{kind = .Wait, text = "compositor: the palette did: set strategy to eevdf"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Close, text = "scheduler"},
	{kind = .Wait, text = "root: scheduler stopped"},
	// A command that destroys asks for a second Enter, on a row that says
	// the act in full. Another key goes back, and nothing stops.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "shutd"},
	{kind = .Wait, text = " for \"shutd\": shutdown (command)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: shutdown"},
	{kind = .Shot, text = "palette_confirm_command"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	// A getter of a module in the process of the console is never called:
	// a direct call has no bound. The panel opens with the row of mode_set,
	// and its refresh ends with that getter not called; a call of it logs
	// a fact, which fails the step. The console must still be the provider:
	// a refresh is a part of the provider.
	{kind = .Type, text = "load(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module     hostile_exports"},
	{kind = .Wait, text = "[console]   commands   6"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	// The two processes log in an order that the system does not fix; no
	// refresh before the load had a getter in the console.
	{kind = .Wait, text = "getters sent, 1 getters in the process of the console not called", any_order = true, fails_on = "hostile_exports: the getter mode ran"},
	{kind = .Keys, text = ":mode"},
	{kind = .Wait, text = "mode (setting)", fails_on = "hostile_exports: the getter mode ran"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module    hostile_exports"},
	{kind = .Wait, text = "[console]   commands  6"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	// The grant of the provider ends: the commands leave the list, and the
	// palette keeps the processes and the windows.
	{kind = .Type, text = "revoke(\"console\", \"palette\")"},
	{kind = .Wait, text = "console: the console is no more the palette provider"},
	// The root service and the compositor write in an order that the
	// system does not fix.
	{kind = .Wait, text = "root: revoked the grant palette of console, holdings ended: ", any_order = true},
	{kind = .Wait, text = "compositor: the palette has no provider"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "shutd"},
	{kind = .Wait, text = "compositor: the palette lists 0 of "},
	{kind = .Shot, text = "palette_no_provider"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},

	// Back to the console: the system tools, then stop the machine.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "where(processes(), name = \"paint\")"},
	{kind = .Wait, text = "[console] slot  name"},
	{kind = .Wait, text = "paint  "},
	// A name with a fault of typing gets the names near it: a command, and a
	// field by its unit ("pages" names the fields counted in pages).
	{kind = .Type, text = "proceses()"},
	{kind = .Wait, text = "[console] error: no command has the name proceses; did you mean processes"},
	{kind = .Type, text = "where(processes(), pages > 1000)"},
	{kind = .Wait, text = "[console] error: where: the records Process have no field pages; did you mean resident or mapped? Their fields are slot, name"},
	// A call of `module.export` connects only when the module of the image
	// has the export. A fault in the export of a connected service gets the
	// near name and no second connection; a name that no module has asks
	// for no connection; an export of a module that is no service gets the
	// refusal of connect, adds no command, and frees the slot of the
	// connection, so the same call is refused the same way again.
	{kind = .Type, text = "monitor.procesess()"},
	{kind = .Wait, text = "[console] error: no command has the name monitor.procesess; did you mean monitor.processes", fails_on = "connected console to the service monitor"},
	{kind = .Type, text = "nothing.x()"},
	{kind = .Wait, text = "[console] error: no command has the name nothing.x; try help()", fails_on = "cannot connect"},
	{kind = .Type, text = "math.x()"},
	{kind = .Wait, text = "[console] error: no command has the name math.x", fails_on = "cannot connect"},
	{kind = .Type, text = "math.gcd(84, 36)"},
	{kind = .Wait, text = "[console] error: cannot connect to math: root.Connect: the argument name names none of the services that run"},
	{kind = .Type, text = "math.gcd(84, 36)"},
	{kind = .Wait, text = "[console] error: cannot connect to math: root.Connect: the argument name names none of the services that run", fails_on = "no room for the service"},
	{kind = .Type, text = "describe(\"math.gcd\")"},
	{kind = .Wait, text = "[console] error: describe: no command and no word of Lex has the name math.gcd"},
	// The arguments are forced before the call connects: a refused argument
	// connects nothing.
	{kind = .Type, text = "math.gcd(1 / 0, 2)"},
	{kind = .Wait, text = "[console] error: division by zero", fails_on = "cannot connect"},
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "[console]   interrupts"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	// A command is an export of a module: the console loads the module and
	// calls its exports from their descriptions.
	{kind = .Type, text = "gcd(84, 36)"},
	{kind = .Wait, text = "error: no command has the name gcd"},
	{kind = .Type, text = "load(\"math\")"},
	{kind = .Wait, text = "[console]   module     math"},
	{kind = .Type, text = "gcd(84, 36) + power(2, 10)"},
	{kind = .Wait, text = "[console] 1036"},
	// An export that fails gives an error record in a direct call too.
	{kind = .Type, text = "square_root(1000000) + square_root(-4)"},
	{kind = .Wait, text = "[console] error: square_root: the argument value has -4; it must have at least 0"},
	{kind = .Type, text = "number(\"41\") + fibonacci(10)"},
	{kind = .Wait, text = "[console] 96"},
	// Above 2^40 the search refuses with a record, not with the answer 0.
	{kind = .Type, text = "next_prime(1099511627777)"},
	{kind = .Wait, text = "[console] error: next_prime: the argument from has the value 1099511627777, which the call refuses; it takes at most 1099511627776"},
	{kind = .Type, text = "next_prime(\"x\")"},
	{kind = .Wait, text = "error: next_prime: argument 1 is Integer, not Text"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"plasma\")"},
	{kind = .Wait, text = "exports no command"},
	{kind = .Type, text = "next_prime(1000) * gcd(84, 36)"},
	{kind = .Wait, text = "[console] 12108"},
	// A Text result: the console gives a buffer, the export writes in it.
	{kind = .Type, text = "reverse(roman(2026)) + roman(length(roman(3888)))"},
	{kind = .Wait, text = "[console] IVXXMMXV"},
	{kind = .Type, text = "where(help(), name = \"shutdown\")"},
	{kind = .Wait, text = "[console] shutdown  shutdown()  stop the machine"},
	{kind = .Type, text = "where(help(), name = \"number\")"},
	{kind = .Wait, text = "[console] number  number(text: Text) -> Integer"},
	{kind = .Shot, text = "tools"},

	// An isolated call: the module runs in a sandboxed process. The
	// arguments go through a ring. The description is the same.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"probe\")"},
	{kind = .Wait, text = "[probe] host: ready, 8 exports"},
	{kind = .Wait, text = "[console]   module     probe"},
	{kind = .Wait, text = "[console]   commands   8"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "count() + count() * 10"},
	{kind = .Wait, text = "[console] 21"},
	{kind = .Type, text = "checksum(\"abc\" + name)"},
	{kind = .Wait, text = "[console] 935"},
	// A Text result through the ring: the module writes in the call region.
	{kind = .Type, text = "shout(\"abc\" + name) + shout(\"\")"},
	{kind = .Wait, text = "[console] ABCKERNEL"},
	// A module that gives a false count: the console reads no more than its buffer.
	{kind = .Type, text = "lie(100000)"},
	{kind = .Wait, text = "[console] error: the result of lie has 100000 bytes: it does not fit"},
	{kind = .Type, text = "length(lie(3))"},
	{kind = .Wait, text = "[console] 3"},
	{kind = .Type, text = "checksum(7)"},
	{kind = .Wait, text = "error: checksum: argument 1 is Text, not Integer"},
	// The module has no handle: it cannot stop the machine.
	{kind = .Type, text = "stop_machine(1) + stop_machine(2) + stop_machine(3)"},
	{kind = .Wait, text = "[console] 6"},
	// A fault in the module stops its process only. The next call starts a
	// new process, with new data.
	{kind = .Type, text = "peek(0)"},
	{kind = .Wait, text = "kernel: process probe stopped: page fault"},
	{kind = .Wait, text = "[console] error: the process probe stopped: a fault, page fault"},
	{kind = .Type, text = "count()"},
	{kind = .Wait, text = "[probe] host: ready"},
	{kind = .Wait, text = "[console] 1"},
	// A module that does not return. The line runs in the second thread of
	// the console: the console keeps the keys of the next line, and Escape
	// stops the call. Then the line that waited runs.
	{kind = .Type, text = "spin()"},
	{kind = .Type, text = "count() + gcd(84, 36)"},
	// The picture shows spin() that runs: the console entered it. The keys
	// of the next line wait unseen until the line ends.
	{kind = .Wait, text = "[console] > spin()"},
	// The echo comes before the call: Escape stops the call only once it
	// runs, and an Escape before it is a key of the next line.
	{kind = .Wait, text = "probe: spin runs, and never returns"},
	{kind = .Shot, text = "running"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "console: Escape stops the line after "},
	{kind = .Wait, text = "[console] error: Escape stopped the call of spin"},
	{kind = .Wait, text = "[console] 13"},
	// No key is lost while the console does not take a line: 100 keys
	// typed during a call that does not return wait, in order, and are the
	// next line. The count of the keys that wait is exact, the echo is the
	// exact line, and no queue of the path of a key wrote that a record is
	// lost (docs/ARCHITECTURE.md, "The path of a key").
	{kind = .Type, text = "spin()"},
	// Escape must come once the call runs: the keys before it wait in any
	// case, so the wait for the call comes before them.
	{kind = .Wait, text = "probe: spin runs, and never returns"},
	{kind = .Keys, text = KEYS_HELD_LINE},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "console: Escape stops the line after "},
	{kind = .Wait, text = " ms; keys that wait: 100"},
	{kind = .Wait, text = "[console] error: Escape stopped the call of spin"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > " + KEYS_HELD_LINE, fails_on = "is lost"},
	{kind = .Wait, text = "[console] 976"},
	// The Escape stopped the sandboxed process of probe: a call starts it
	// again, so that the list of the processes has it for the picture.
	{kind = .Type, text = "count()"},
	{kind = .Wait, text = "[probe] host: ready"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Type, text = "where(processes(), name = \"probe\")"},
	{kind = .Wait, text = "probe  "},
	{kind = .Shot, text = "isolated"},

	// A record and a lent handle in an isolated call. The record goes as
	// bytes with described fields. The module receives a copy of the handle
	// with the rights of the description, for the time of the call.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   12"},
	{kind = .Wait, text = "[console]   call       isolated"},
	// The exports that are wrong on purpose are in a module of their own,
	// which no service holds.
	{kind = .Type, text = "isolate(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module     hostile_exports"},
	{kind = .Wait, text = "[console]   commands   6"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "r = Rectangle(1, 2, 30, 4)"},
	{kind = .Type, text = "area(r)"},
	{kind = .Wait, text = "[console] 120"},
	{kind = .Type, text = "grow(r, 5)"},
	{kind = .Wait, text = "[console]   height  14"},
	// The forms of Lex for records (docs/CONSOLE.md, "Records"): a record
	// literal typed by the parameter that receives it, a named argument,
	// `with`, `let`, and the placeholder `_` of "|>". A field that the
	// record does not have, and one that the literal does not give, are
	// refused before the call runs.
	{kind = .Type, text = "area({x = 0, y = 0, width = 11, height = 3})"},
	{kind = .Wait, text = "[console] 33"},
	{kind = .Type, text = "area(r with {width = 10})"},
	{kind = .Wait, text = "[console] 40"},
	{kind = .Type, text = "grow(r, by = 2)"},
	{kind = .Wait, text = "[console]   height  8"},
	{kind = .Type, text = "3 |> grow(r, _)"},
	{kind = .Wait, text = "[console]   height  10"},
	{kind = .Type, text = "let s = {x = 0, y = 0, width = 6, height = 7} in area(s) + area(s)"},
	{kind = .Wait, text = "[console] 84"},
	{kind = .Type, text = "area({x = 1, y = 2, widht = 3, height = 4})"},
	{kind = .Wait, text = "[console] error: Rectangle has no field widht; did you mean width? Its fields are x, y, width, height"},
	{kind = .Type, text = "area({x = 1, y = 2, width = 3})"},
	{kind = .Wait, text = "[console] error: Rectangle needs the field height, which has no default"},
	// The functions of Lex (docs/CONSOLE.md, "Functions and lists"): map on
	// a list, a function that a let binds, a literal made in a body and
	// typed by area after the call, the drawing of a function. A function
	// is refused at the border of an export and by a variable. A recursion
	// stops at the stack bound of the evaluator, and the deepest line of
	// 200 bytes of today runs inside it on the thread of the lines.
	{kind = .Type, text = "map([1, 2, 3], (x) => x * 2)"},
	{kind = .Wait, text = "[console] [2, 4, 6]"},
	{kind = .Type, text = "let double = (x) => x * 2 in area({x = 0, y = 0, width = double(3), height = 4})"},
	{kind = .Wait, text = "[console] 24"},
	{kind = .Type, text = "[1, 2] |> map((w) => area({x = 0, y = 0, width = w, height = 5}))"},
	{kind = .Wait, text = "[console] [5, 10]"},
	{kind = .Type, text = "(x) => x + 1 // a comment ends the line"},
	{kind = .Wait, text = "[console] (x) => x + 1"},
	// A line of only a comment does nothing: the next line gives its value
	// with no error before it.
	{kind = .Type, text = "// a line of only a comment"},
	{kind = .Type, text = "6 * 7"},
	{kind = .Wait, text = "[console] 42", fails_on = "[console] error:"},
	{kind = .Type, text = "area((x) => x)"},
	{kind = .Wait, text = "[console] error: area: argument 1 is a function: a function and a list stay in their line, and no command takes one"},
	{kind = .Type, text = "f = (x) => x"},
	{kind = .Wait, text = "[console] error: a variable keeps no function"},
	// A variable keeps a list, and a later line reads it as its own list
	// (docs/CONSOLE.md, "Functions and lists"): map on it, an assignment
	// that reads its old items, `let` with no `in` as an assignment, and a
	// nested list. Then the bound: one item past it is refused and the
	// variable keeps its old value; the bound itself is kept; a function in
	// a list is refused.
	{kind = .Type, text = "numbers = [1, 2, 3]"},
	{kind = .Type, text = "map(numbers, (n) => n * n)"},
	{kind = .Wait, text = "[console] [1, 4, 9]"},
	{kind = .Type, text = "numbers = map(numbers, (n) => n + 1)"},
	{kind = .Type, text = "numbers"},
	{kind = .Wait, text = "[console] [2, 3, 4]"},
	{kind = .Type, text = "let numbers = [[1, 2], [\"a\"], numbers]"},
	{kind = .Type, text = "numbers"},
	{kind = .Wait, text = "[console] [[1, 2], [\"a\"], [2, 3, 4]]", fails_on = "[console] error:"},
	{kind = .Type, text = "numbers = [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]"},
	{kind = .Wait, text = "[console] error: a variable keeps a list of 64 items at most, the items of its nested lists included; this one has 65 or more"},
	{kind = .Type, text = "numbers"},
	{kind = .Wait, text = "[console] [[1, 2], [\"a\"], [2, 3, 4]]"},
	{kind = .Type, text = "numbers = [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1]"},
	{kind = .Type, text = "where(variables(), name = \"numbers\")"},
	{kind = .Wait, text = "64 items", fails_on = "[console] error:"},
	{kind = .Type, text = "numbers = [(n) => n]"},
	{kind = .Wait, text = "[console] error: a variable keeps no function"},
	// Help on one name: a word of Lex gives its guide, a fault of typing the
	// names near it.
	{kind = .Type, text = "describe(\"let\")"},
	{kind = .Wait, text = "[console] let binds names for one expression"},
	{kind = .Type, text = "describe(\"lte\")"},
	{kind = .Wait, text = "[console] error: describe: no command and no word of Lex has the name lte; did you mean let"},
	{kind = .Type, text = "help(\"let\")"},
	{kind = .Wait, text = "[console] error: help takes no argument: use describe(\"let\") for the help on one name"},
	// The hint of a function written with "->".
	{kind = .Type, text = "map(numbers, n -> n * n)"},
	{kind = .Wait, text = "[console] error: \"->\" is no operator: a function is written (n) => n * n"},
	// The deepest line of calls of a command: 31 calls of hash inside each
	// other and length in 197 bytes, a call of the host at the deepest
	// place. It is the deepest line of the run so far, so its measure of
	// the stack of the evaluator goes to the log before its result.
	{kind = .Type, text = "length(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(hash(\"\"))))))))))))))))))))))))))))))))"},
	{kind = .Wait, text = "console: the deepest line so far took"},
	{kind = .Wait, text = "[console] 64"},
	{kind = .Type, text = "let f = (n) => f(n) in f(1)"},
	{kind = .Wait, text = "[console] error: the line nests deeper than the stack of the evaluator holds: 524288 bytes"},
	{kind = .Type, text = "1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1"},
	{kind = .Wait, text = "[console] 100"},
	// The picture of the colors of Lex: from a clean view, one short line
	// for each form, each after the result of the one before. A record
	// literal, `with` and `let`; a function given to map over a list; "|>"
	// with `_`; a named argument; a comment; a refusal at its place.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "let s = r with {width = 2} in area(s)"},
	{kind = .Wait, text = "[console] 8"},
	{kind = .Type, text = "map([1, 2, 3], (x) => x * x)"},
	{kind = .Wait, text = "[console] [1, 4, 9]"},
	{kind = .Type, text = "1 |> grow(r, _)"},
	{kind = .Wait, text = "[console]   height  6"},
	{kind = .Type, text = "area(rectangle = r)"},
	{kind = .Wait, text = "[console] 120"},
	{kind = .Type, text = "6 * 7 // the answer"},
	{kind = .Wait, text = "[console] 42"},
	{kind = .Type, text = "area(r with {widht = 3})"},
	{kind = .Wait, text = "[console] error: Rectangle has no field widht"},
	{kind = .Shot, text = "console_lex"},
	{kind = .Type, text = "b = buffer(1)"},
	{kind = .Type, text = "fill(b, 3)"},
	{kind = .Wait, text = "[console] 4096"},
	// The module wrote in the memory of the console: the object is shared, not copied.
	{kind = .Type, text = "byte(b, 4095)"},
	{kind = .Wait, text = "[console] 3"},
	// A handle in a field of a record.
	{kind = .Type, text = "span_total(Span(b, 96, 10))"},
	{kind = .Wait, text = "[console] 30"},
	// The description of spoil asks Read: the module cannot write. 7: no right.
	{kind = .Type, text = "spoil(b)"},
	{kind = .Wait, text = "[console] 7"},
	// A lent handle ends with its call. 2: no handle.
	{kind = .Type, text = "keep(b)"},
	{kind = .Wait, text = "[console] 12288"},
	{kind = .Type, text = "kept()"},
	{kind = .Wait, text = "[console] 2"},
	{kind = .Type, text = "area(Span(b, 0, 1))"},
	{kind = .Wait, text = "[console] error: area: argument 1 is Rectangle, not Span"},
	{kind = .Type, text = "b"},
	{kind = .Wait, text = ": Memory (Give, Read, Write, Execute)"},
	{kind = .Shot, text = "records"},

	// Each field in the color of its value kind: a handle in a record, then
	// a table with a text, two numbers, a size in pages and two times, each
	// unit once in the head of its column. The row of the table is the last
	// line but one: the picture waits for it, then for the count of rows.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "Span(b, 96, 10)"},
	{kind = .Wait, text = "[console]   count   10"},
	{kind = .Type, text = "columns(where(processes(), name = \"console\"), name, slot, threads, resident, time, started)"},
	{kind = .Wait, text = "[console] name     slot  threads  resident (pages)  time (ms)  started (us)"},
	{kind = .Wait, text = "[console] console  "},
	{kind = .Wait, text = "[console] 1 row of Process"},
	{kind = .Shot, text = "console_value_kinds"},

	// The pipe operator: the value on its left is the first argument of the
	// call on its right, so this line is the line with calls in calls
	// columns(where(processes(), name = "console"), name, slot). A '|'
	// alone is no operator: its line fails before any call.
	{kind = .Type, text = "processes() |> where(name = \"console\") |> columns(name, slot)"},
	{kind = .Wait, text = "[console] name     slot"},
	{kind = .Wait, text = "[console] 1 row of Process"},
	{kind = .Type, text = "processes() | rows"},
	{kind = .Wait, text = "[console] error: \"|\" is no operator: the pipe operator is \"|>\""},

	// Revocation. The console revokes what it lent at the end of each
	// call: the mapping that the module kept is gone, and the next read
	// stops the process of the module on a page fault.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "hold(b)"},
	{kind = .Wait, text = "[console] 3"},
	{kind = .Type, text = "look()"},
	{kind = .Wait, text = "[console] error: the process hostile_exports stopped: a fault, page fault"},
	// The root service ends one grant of a process that runs. The window of
	// monitor goes below the console for the picture, then back.
	{kind = .Move, text = "monitor", to_x = 568, to_y = 552},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "grants(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor  log      held"},
	{kind = .Wait, text = "[console] monitor  machine  held"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "root: revoked the grant machine of monitor, holdings ended: 1", any_order = true},
	{kind = .Wait, text = "[console] 1", any_order = true},
	{kind = .Wait, text = "monitor: no grant to inspect the machine"},
	{kind = .Type, text = "grants(\"monitor\")"},
	{kind = .Wait, text = "[console] monitor  log      held"},
	{kind = .Wait, text = "[console] monitor  machine  lost"},
	{kind = .Type, text = "revoke(\"monitor\", \"machine\")"},
	{kind = .Wait, text = "[console] error: root.Revoke: the argument grant names none of the grants of the process"},
	{kind = .Type, text = "revoke(\"monitor\", \"keys\")"},
	{kind = .Wait, text = "[console] error: no grant has the name keys"},
	{kind = .Shot, text = "revocation"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Front, text = "console"},
	// The same descriptions serve a direct call. The module is then in the
	// console: it has the handles of the console, and kept gives 0.
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  12"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module    hostile_exports"},
	{kind = .Wait, text = "[console]   commands  6"},
	// The first program of modus that writes a program
	// (src/md/features/assembler.md): the module assemble, in a call host,
	// writes a module file into a memory object of the console; the console
	// isolates the module of that object, and calls its export. A text that
	// the assembler refuses names its line and its column on the log.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "isolate(\"assemble\")"},
	{kind = .Wait, text = "[assemble] host: ready, 2 exports"},
	{kind = .Wait, text = "[console]   module     assemble"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "f = buffer(4)"},
	{kind = .Type, text = "assemble(\"add: movx %rdi, %rax\", f)"},
	{kind = .Wait, text = "assemble: line 1, column 6: no instruction of the subset and no directive has this name"},
	{kind = .Wait, text = "[console] error: assemble: "},
	{kind = .Type, text = "n = assemble(\"export add(a: Integer, b: Integer) -> Integer; add: mov %rdi, %rax; add %rsi, %rax; ret\", f)"},
	{kind = .Wait, text = "assemble: a module file of "},
	{kind = .Type, text = "isolate_memory(\"adder\", f, n)"},
	// The call host is ready before the console writes its line about the
	// module: two processes, in either order.
	{kind = .Wait, text = "[adder] host: ready, 1 exports", any_order = true},
	{kind = .Wait, text = "console: adder is a module from memory: "},
	{kind = .Wait, text = "[console]   module     adder"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "add(2, 3)"},
	{kind = .Wait, text = "[console] > add(2, 3)"},
	{kind = .Wait, text = "[console] 5"},
	// The record of unload names the module: a module from memory whose
	// name the console lost gives the line of the memory with no name
	// before it, and the step fails at once.
	{kind = .Type, text = "unload(\"adder\")"},
	{kind = .Wait, text = "[console]   module    adder", fails_on = "[console]   memory    its sandboxed process stopped"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	// The C compiler (src/md/features/c_compiler.md): chibicc, ported,
	// writes a text that the assembler takes, and the console calls the
	// function of the C source. An empty source is refused at the border,
	// before the C part, so the one compile of the call host is still free;
	// a second compile is refused. add(-7, 2)
	// proves that an export that gives an int extends its sign.
	{kind = .Type, text = "isolate(\"c_compiler\")"},
	{kind = .Wait, text = "[c_compiler] host: ready, 2 exports"},
	{kind = .Wait, text = "[console]   module     c_compiler"},
	{kind = .Type, text = "t = buffer(1)"},
	{kind = .Type, text = "compile(\"\", t)"},
	{kind = .Wait, text = "[console] error: compile: "},
	{kind = .Type, text = "n = compile(\"int add(int a, int b) { return a + b; }\", t)"},
	{kind = .Wait, text = "c_compiler: a text of "},
	{kind = .Type, text = "m = assemble(bytes(t, 0, n), f)"},
	{kind = .Wait, text = "assemble: a module file of "},
	{kind = .Type, text = "isolate_memory(\"c_adder\", f, m)"},
	// The call host is ready before the console writes its line about the
	// module: two processes, in either order.
	{kind = .Wait, text = "[c_adder] host: ready, 1 exports", any_order = true},
	{kind = .Wait, text = "console: c_adder is a module from memory: "},
	{kind = .Type, text = "add(2, 3)"},
	{kind = .Wait, text = "[console] > add(2, 3)"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "add(-7, 2)"},
	{kind = .Wait, text = "[console] > add(-7, 2)"},
	{kind = .Wait, text = "[console] -5"},
	{kind = .Type, text = "compile(\"int other;\", t)"},
	{kind = .Wait, text = "c_compiler: a call host compiles one source: unload the module and isolate it again"},
	{kind = .Type, text = "unload(\"c_adder\")"},
	{kind = .Wait, text = "[console]   module    c_adder", fails_on = "[console]   memory    its sandboxed process stopped"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	{kind = .Type, text = "unload(\"c_compiler\")"},
	{kind = .Wait, text = "[console]   module    c_compiler", fails_on = "[console]   memory    its sandboxed process stopped"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	{kind = .Type, text = "release(t)"},
	{kind = .Type, text = "unload(\"assemble\")"},
	{kind = .Wait, text = "[console]   module    assemble", fails_on = "[console]   memory    its sandboxed process stopped"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	{kind = .Type, text = "release(f)"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   12"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "load(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module     hostile_exports"},
	{kind = .Wait, text = "[console]   commands   6"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "g = grow(r, 5)"},
	{kind = .Type, text = "g.width * g.height + keep(b) + kept()"},
	{kind = .Wait, text = "[console] 12848"},
	// An export that fails gives its error record, not a bare negative
	// number: with no earlier hold in this process, look has no mapping.
	{kind = .Type, text = "look()"},
	{kind = .Wait, text = "[console] error: look: the call names none of the mappings"},
	// An export with nine parameters in a direct call: the numbers 7 and 8,
	// the label and the error record are on the stack. Each number has its
	// own weight, so a word in the wrong place gives another sum.
	{kind = .Type, text = "weigh(1, 2, 3, 4, 5, 6, 7, 8, \"A\")"},
	{kind = .Wait, text = "[console] 269"},
	{kind = .Type, text = "weigh(1, 2, 3, 4, 5, 6, 7, 8, \"a label of twenty bytes\")"},
	{kind = .Wait, text = "[console] error: weigh: the argument label has 23 bytes"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  12"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Type, text = "unload(\"hostile_exports\")"},
	{kind = .Wait, text = "[console]   module    hostile_exports"},
	{kind = .Wait, text = "[console]   commands  6"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Type, text = "release(b)"},
	// The key of the client of the peer, for the calls of the host below
	// (docs/PRINCIPALS.md, "The client keys of remote").
	{kind = .Type, text = "remote_allow(\"{client key}\")"},
	{kind = .Wait, text = "root: principal 0 allowed the client key "},

	// The hall of fame. The process writes its line after it presented its
	// first frame, with the count of the cards that the frame drew; the
	// window draws only after an event, so the picture shows that frame. A key moves the choice to
	// the next card, and a press of the pointer chooses a card of the
	// second row by its element name: the process writes each choice.
	{kind = .Launch, text = "hall_of_fame"},
	{kind = .Wait, text = "hall_of_fame: ok, the first frame drew ", any_order = true},
	{kind = .Wait, text = "compositor: surface hall_of_fame"},
	{kind = .Shot, text = "hall_of_fame"},
	{kind = .Key, text = "right"},
	{kind = .Wait, text = "hall_of_fame: chose Jonathan Blow"},
	{kind = .Click_Element, text = "hall_of_fame", element = "Dax Raad"},
	{kind = .Wait, text = "hall_of_fame: chose Dax Raad"},

	// The heron of the mark plays its animations. The key 8 asks for the
	// dash: the process writes its line when the animation ended, and the
	// line says that a picture had the heron wholly outside the window,
	// and that the move was on the grid, in whole cells.
	// The two pictures are of a state that does not move: the play is
	// paused, the dash is held at its third frame (the key 8 shows the
	// first frame, each dot the next one), where the heron has the form of
	// the run and is still inside the window, and the key l shows the
	// lines of the cells. The first picture has the move on the grid; the
	// key g makes it free, for the second picture of the same frame. The
	// process writes the line of what it shows after it presented that
	// state, so the screen has it when the line is on the log. A wait
	// names the frame, the way and the form; the place and the counts that
	// follow in the line are what the process computed, and no step
	// repeats them. The second dot writes a line of the third frame too,
	// with the lines hidden: the wait after it is for the lines shown.
	// The first line of the process comes after its first picture. No
	// picture of the screen shows a half-drawn heron: each surface has
	// two pictures, and the process draws the one that the compositor
	// does not read (the step "no window drew in a picture on the
	// screen", near the end, checks it for each window).
	{kind = .Launch, text = "heron"},
	{kind = .Wait, text = "heron: ok, the first picture is presented", any_order = true},
	{kind = .Wait, text = "compositor: surface heron"},
	{kind = .Keys, text = "8"},
	{kind = .Wait, text = "heron: dash played: 17 frames, the heron left the window and came back, on the grid"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "heron: paused"},
	{kind = .Keys, text = "8..l"},
	{kind = .Wait, text = "heron: shows dash at frame 3 of 17, held, on the grid: the form run, "},
	{kind = .Wait, text = "; the lines of the cells shown"},
	{kind = .Shot, text = "heron"},
	{kind = .Keys, text = "g"},
	{kind = .Wait, text = "heron: shows dash at frame 3 of 17, held, free: the frame stretched to "},
	{kind = .Shot, text = "heron_free"},
	{kind = .Close, text = "heron"},
	{kind = .Wait, text = "root: heron stopped"},

	// Communication between processes: six processes pass records through
	// six rings. A stopped process takes no record: the records wait.
	{kind = .Launch, text = "rings"},
	{kind = .Wait, text = "rings: ok, 6 processes, 6 rings, 5 records"},
	{kind = .Move, text = "rings", to_x = 176, to_y = 32},
	{kind = .Type, text = "aaa"},
	// The picture has the three records of the keys: one line for each.
	{kind = .Wait, text = "rings: the key a adds a record: "},
	{kind = .Wait, text = "rings: the key a adds a record: "},
	{kind = .Wait, text = "rings: the key a adds a record: "},
	{kind = .Shot, text = "rings"},
	{kind = .Type, text = "4"},
	{kind = .Wait, text = "rings: node 4 stopped"},
	{kind = .Wait, text = "rings: node 4 does not run: "},
	{kind = .Shot, text = "rings_stopped"},
	{kind = .Type, text = "4"},
	{kind = .Wait, text = "rings: node 4 started"},

	// Threads: one process, five threads, one surface. A thread ends and
	// the first thread reads its result. A stopped thread draws no more.
	{kind = .Launch, text = "threads"},
	{kind = .Wait, text = "threads: a thread added the numbers to 1000: 500500"},
	{kind = .Wait, text = "threads: ok, 4 threads draw in one surface"},
	{kind = .Type, text = "3"},
	{kind = .Wait, text = "threads: thread 3 stopped at frame "},
	{kind = .Shot, text = "threads"},
	{kind = .Type, text = "3"},
	{kind = .Wait, text = "threads: thread 3 started"},

	// The lock and the word wait: four threads add to one number, then take
	// tiles from one queue.
	{kind = .Launch, text = "workers"},
	{kind = .Wait, text = "workers: the lock lost no addition"},
	{kind = .Wait, text = "workers: ok, 4 threads computed 140 tiles: "},
	{kind = .Move, text = "workers", to_x = 304, to_y = 328},
	{kind = .Shot, text = "workers"},

	// The calls of the host (docs/MODULE_CONTRACT.md, "A call from the
	// host"). Here, after the steps that press at fixed places inside
	// windows that the compositor placed: a new window moves the place of
	// each window that comes after it. This launch is blind; from the next
	// press on, the tool reads the place of the pointer from the compositor
	// and corrects it before each press.
	{kind = .Launch, text = "remote"},
	// The service prints its key while the root service starts it: the key
	// can come before the line of the start.
	{kind = .Wait, text = "root: started remote", any_order = true},
	{kind = .Remote_Key, text = "remote: the public key of this service: "},
	{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only", any_order = true},
	{kind = .Call, text = "compositor.pointer()", expected = "1 rows of Pointer", pointer = true},
	{kind = .Call, text = "compositor.windows()", expected = "remote"},

	// Rights: a process with a part of the rights of two handles. The
	// kernel refuses each operation that needs another right.
	{kind = .Launch, text = "rights"},
	{kind = .Wait, text = "rights: ok, 4 allowed, 5 refused", any_order = true},
	{kind = .Wait, text = "compositor: surface rights"},
	{kind = .Shot, text = "rights"},

	// The origin of a handle: the kernel ends what came from a handle, in
	// this process and in another one.
	{kind = .Launch, text = "origin"},
	{kind = .Wait, text = "origin: ok, 12 cases", any_order = true},
	{kind = .Wait, text = "origin: lend a handle and take it back: ", any_order = true},
	{kind = .Wait, text = "compositor: surface origin"},
	{kind = .Shot, text = "origin"},

	// Budgets: no object comes from nothing. The process creates until
	// its budget cannot pay; what it frees returns.
	{kind = .Launch, text = "budget"},
	{kind = .Wait, text = "budget: ok, ", any_order = true},
	{kind = .Wait, text = "compositor: surface budget"},
	{kind = .Shot, text = "budget"},

	// The limits of a budget: the kernel stops a thread at the processor
	// time of its budget, and refuses the log records above the limit.
	{kind = .Launch, text = "limits"},
	{kind = .Wait, text = "limits: ok, 4 budgets within their processor time, ", any_order = true},
	{kind = .Wait, text = "compositor: surface limits", any_order = true},
	{kind = .Shot, text = "limits"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"limits\")"},
	{kind = .Wait, text = "root: limits stopped"},

	// One ring between two threads: 200000 records in order, and the
	// kernel entries that they cost, for two capacities and two ways to wait.
	{kind = .Launch, text = "flow"},
	{kind = .Wait, text = "flow: capacity 32, wait at once: ", any_order = true},
	{kind = .Wait, text = "flow: capacity 1024, read the counters then wait: "},
	{kind = .Wait, text = "flow: ok, 4 rings, 0 records lost"},
	{kind = .Shot, text = "flow"},

	// One queue for several writers and several readers, with no lock; one
	// event starts the threads of each run.
	{kind = .Launch, text = "crowd"},
	{kind = .Wait, text = "crowd: shared queue, 1 writers, 1 readers: ", any_order = true},
	{kind = .Wait, text = "crowd: shared queue, 2 writers, 2 readers: "},
	{kind = .Wait, text = "crowd: shared queue, 3 writers, 1 readers: "},
	{kind = .Wait, text = "crowd: shared queue, 1 writers, 3 readers: "},
	{kind = .Wait, text = "crowd: queue with a lock, 2 writers, 2 readers: "},
	{kind = .Wait, text = "crowd: ok, 5 runs, each record written is read one time, each event started all the threads"},
	{kind = .Shot, text = "crowd"},

	// The time is in a page that each process reads: no kernel entry. The
	// demonstration is not in the start menu: the console starts it.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"time_page\")"},
	{kind = .Wait, text = "display: time_page" + WINDOW_TAKEN, any_order = true},
	{kind = .Wait, text = "compositor: window time_page is resizable from 816x336 to 1216x640", any_order = true},
	{kind = .Wait, text = "time_page: the check of the time page: 1000000 reads, 0 kernel entries"},
	{kind = .Wait, text = "time_page: the check of a kernel entry: 100000 reads, "},
	{kind = .Wait, text = "time_page: the time page and the cycle counter: in "},
	{kind = .Wait, text = "time_page: ok, the time never went back, the page and the kernel give the same time, the kernel refuses to remove the time page"},
	{kind = .Shot, text = "time_page"},
	// The pointer drags the corner of the window of time_page: its process
	// makes the surface of the new size and draws its next frame in it,
	// and the compositor shows the window at that size from that frame
	// (src/md/features/window_resize.md).
	{kind = .Resize, text = "time_page", to_x = 880, to_y = 384},
	// The process can draw before the compositor writes its line of the
	// request: the two lines come in either order.
	{kind = .Wait, text = "compositor: window time_page asked to draw at 880x384", any_order = true},
	{kind = .Wait, text = "display: time_page: the first picture of 880x384 after a resize"},
	{kind = .Shot, text = "time_page_resized"},

	// The clock of the desktop (src/md/features/clock_application.md): the
	// stopwatch starts and stops, then a timer of 1 second ends and posts a
	// card through the compositor, labelled with the name of the process.
	{kind = .Launch, text = "clock"},
	{kind = .Wait, text = "clock: ok, the first frame is drawn"},
	{kind = .Click_Element, text = "clock", element = "stopwatch"},
	{kind = .Click_Element, text = "clock", element = "start"},
	{kind = .Wait, text = "clock: the stopwatch started"},
	{kind = .Click_Element, text = "clock", element = "stop"},
	{kind = .Wait, text = "clock: the stopwatch stopped at "},
	{kind = .Click_Element, text = "clock", element = "timer"},
	// From 5 minutes, five steps of -1 min stop at the least duration, 1 s.
	{kind = .Click_Element, text = "clock", element = "-1 min"},
	{kind = .Click_Element, text = "clock", element = "-1 min"},
	{kind = .Click_Element, text = "clock", element = "-1 min"},
	{kind = .Click_Element, text = "clock", element = "-1 min"},
	{kind = .Click_Element, text = "clock", element = "-1 min"},
	{kind = .Click_Element, text = "clock", element = "start"},
	{kind = .Wait, text = "clock: the timer of 1 s ended"},
	{kind = .Wait, text = "clock: the notification "},
	{kind = .Shot, text = "clock_notification"},
	{kind = .Close, text = "clock"},
	{kind = .Wait, text = "root: clock stopped"},
	// The border of notify for a caller that does not act for the
	// principal: the rate, the bound of 3 cards with Full and their count,
	// and the label of a name of 31 bytes, the longest that a process has.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"notify_border_of_the_compositor\")"},
	{kind = .Wait, text = "notify_border_of_the_compositor: ok, the cards of a caller stop at 3 with Full and their count"},
	{kind = .Wait, text = "root: notify_border_of_the_compositor stopped"},

	// Several processors: the kernel says that the four processors ran
	// threads of one process at the same time. Then 1, 2 and 4 threads
	// compute the same picture.
	{kind = .Launch, text = "processors"},
	{kind = .Wait, text = "processors: ok, 4 processors ran the process at the same time"},
	{kind = .Wait, text = "processors: the picture took "},
	{kind = .Shot, text = "processors"},

	// The locks of the kernel: four processes that each work on their own
	// objects, with 1, 2 and 4 at one time; two threads that wake each
	// other. The process checks the counts, not the speed.
	{kind = .Launch, text = "locks"},
	{kind = .Wait, text = "locks: kernel entries, each locker on its own objects: 1 locker 16384, 2 lockers 32768, 4 lockers 65536"},
	{kind = .Wait, text = "locks: pages on first use, each locker in its own memory: 1 locker 2048, 2 lockers 4096, 4 lockers 8192"},
	{kind = .Wait, text = "locks: word wait, two threads wake each other: "},
	{kind = .Wait, text = "locks: frames: "},
	{kind = .Wait, text = "locks: frame caches after the measures (frames now, batches taken, batches given, drains): processor 0: "},
	{kind = .Wait, text = "locks: ok, the kernel counted each entry, each page returned, no wake was lost, each stopped process returned its pages, its slot and its threads"},
	{kind = .Shot, text = "locks"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"locks\")"},
	{kind = .Wait, text = "root: locks stopped"},

	// The scheduling strategies: the same cases under round robin, the
	// fair strategy and EEVDF, then 100 changes of strategy while threads
	// start, stop, wake each other and move. The process checks what does
	// not depend on the load of the host. Two keys change the strategy.
	// The schedule of a live thread: a thread reads and writes its own
	// weight and request, the kernel refuses each write that it must
	// refuse, the weights written through the machine handle order the
	// shares, and writes during the changes of strategy lose no thread. A
	// thread of another process is written through the machine handle, and
	// a weight limit holds against the writes and the new threads of its
	// thread. The placement of a thread on the processors: a thread narrows
	// its own set, the kernel refuses each write that it must refuse, a
	// limit holds against the writes and the new threads of its thread, a
	// thread in each state moves into a new set, two groups of spinners
	// with no common processor stay apart, a queue of threads that a
	// processor cannot take does not stop the balance, and writes during
	// the changes of strategy lose no thread. The machine of the test has
	// 4 processors: the lines name them.
	{kind = .Launch, text = "scheduler"},
	{kind = .Wait, text = "scheduler: a thread created with the weight 300 and the request 700 us read its own schedule: weight 300, request 700 us; after it lowered them to 150 and 350 us: weight 150, request 350 us; its own writes of the weight 300 and of the request 700 us: Bad_Operation and Bad_Operation, and the schedule stayed: 1; the first thread: weight 1024, request 3000 us: as it must"},
	{kind = .Wait, text = "scheduler: refused writes of a schedule: a weight above the full weight Bad_Operation, a request above the limit Bad_Operation, and the schedule stayed: 1; the machine handle with no right Schedule No_Right; a read and a write through the machine handle with Schedule and no Inspect No_Right and No_Right; a thread handle with Inspect and no Control No_Right, and it reads: 1; another command with the machine handle Bad_Handle; the machine number of a thread that ended Bad_State: as it must"},
	{kind = .Wait, text = "scheduler: a thread of another process, the root service, found by its name and its serial: through the machine handle its schedule was read, written, read back and written back: as it must"},
	{kind = .Wait, text = "scheduler: the weight limit 256 written through the machine handle: the thread has the weight 256; its own write of the full weight Bad_Operation, the error record has the weight of the thread: 1; its own write of the full limit changed nothing: 1: as it must"},
	{kind = .Wait, text = "scheduler: under the weight limit 256, 1000 rounds of its own writes of the weights 256, 1, 1024 and 256, then the weight 256 through the machine handle: 2000 of its own accepted, 2000 refused, 1000 raised by the machine handle, a wrong weight or limit 0 times: as it must"},
	{kind = .Wait, text = "scheduler: under the weight limit 256: a new thread with the weight 257 Bad_Operation; a new thread with the weight 0 has the weight 256 and the limit 256, and its own write of the full weight Bad_Operation; after the machine handle wrote the full limit the first thread has the weight 1024: as it must"},
	{kind = .Wait, text = "scheduler: at least 100 rounds on a held spinner under EEVDF, until one had a lag below 0: the spinner lowered to the weight 1 and ran a tick, a Stop, its own writes of the full weight and of the request 1 us, the full weight through the machine handle, a Resume: 0 of its raises were not refused, the reported lag changed after 0 of its writes, and was not 0 after 0 raises of the machine handle: as it must"},
	{kind = .Wait, text = "scheduler: a thread read its own placement: each of the 4 processors in its set and in its limit: 1; its own write of the processor 3 alone: Ok, and it then read that processor alone, with the same limit: 1; in 50 samples of its thread report, each after one more tick of its run, its home or its processor was another one 0 times: as it must"},
	{kind = .Wait, text = "scheduler: refused sets of a placement, on a spinner that the machine handle keeps on the processor 0: through its thread handle a wider set Bad_Operation and a processor that the machine does not have Bad_Operation, with their error records: 1; through the machine handle a limit of no processor of the machine Bad_Operation and a set outside its limit Bad_Operation, with their error records: 1; the placement stayed: 1: as it must"},
	{kind = .Wait, text = "scheduler: the rights of a placement: the machine handle with no right Schedule No_Right; a read and a write through the machine handle with Schedule and no Inspect No_Right and No_Right; a thread handle with Inspect and no Control No_Right, and it reads: 1; the placement stayed: 1; a read and a write by the machine number of a thread that ended Bad_State and Bad_State: as it must"},
	{kind = .Wait, text = "scheduler: the limit of the processors 0 to 1 written through the machine handle: the thread has that set: 1; its own write of each processor Bad_Operation, the error record has the set of the thread: 1; its own write of a wider limit changed nothing: 1: as it must"},
	{kind = .Wait, text = "scheduler: under that limit, 1000 rounds of the own writes of the thread, of the processor 0, of the set of the limit and of each processor, then the limit again through the machine handle: 1000 of its own accepted, 2000 refused, 1000 widened by the machine handle, a wrong set or limit 0 times: as it must"},
	{kind = .Wait, text = "scheduler: under that limit: a new thread has the limit as its set and as its limit: 1, its home is a processor of the limit: 1, and its own write of each processor Bad_Operation; after the machine handle wrote the zero record the first thread has each processor in its set and in its limit: 1: as it must"},
	{kind = .Wait, text = "scheduler: a set without the home of a thread, written through the machine handle: a thread that waits has a home of the set in the next report: 1, and after its wake it ran inside the set: 1, outside in 0 reports; a spinner that a Stop holds has a home of the set in the next report: 1, and after the Resume it ran inside the set: 1, outside in 0 reports: as it must"},
	{kind = .Wait, text = "scheduler: a set without the home of a spinner, written through the machine handle: a spinner in a list ran inside the set: 1, outside in 0 reports after the first one inside; a spinner on a processor ran inside the set: 1, outside in 0 reports after the first one inside: as it must"},
	{kind = .Wait, text = "scheduler: two groups of 3 spinners, each created under the limit of its group, the processors 0 to 1 and 2 to 3: each spinner has that limit as its set and as its limit: 1; each of the 4 processors ran a spinner of its group: 1; in at least 200 reports of the threads a spinner had a home or a processor of the other group 0 times: as it must"},
	{kind = .Wait, text = "scheduler: 5 spinners that only the processor 0 can run make its queue the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to 3: a report showed the two on two processors at one time: 1: as it must"},
	{kind = .Wait, text = "scheduler: 5 threads of a budget with no processor time, in the queue of the processor 0, make it the busiest, and each processor from 2 runs a spinner of its own; two spinners of the queue of the processor 1 got the processors 1 to 3: a report showed the two on two processors at one time: 1: as it must"},
	{kind = .Wait, text = "scheduler: two spinners and the first thread kept on the processor 0; the spinner of the list got the processor 1 too through the machine handle: a report showed it on the processor 1: 1: as it must"},
	{kind = .Wait, text = "scheduler: writes of a placement through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has each processor again: as it must"},
	{kind = .Wait, text = "scheduler: round robin: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: fair: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: EEVDF: two threads that wake each other, a spinner on each processor: "},
	{kind = .Wait, text = "scheduler: the weights 1 2 4 written through the machine handle while 12 spinners ran: each write was read back, and the heavier weight got more under fair and EEVDF: as it must"},
	{kind = .Wait, text = "scheduler: one Strategy_Set, with its kernel entry: "},
	{kind = .Wait, text = "scheduler: stress: 100 changes of strategy while "},
	{kind = .Wait, text = "scheduler: writes of a schedule through the machine handle while the strategy changed 100 times: none was refused, each of the 8 spinners ran after them and has the schedule written last: as it must"},
	// The share policy: four processes with 1, 2, 4 and 8 spinning threads.
	// Each condition is a value that the kernel gives back, or an order of
	// two counts of ticks; the shares are a measure.
	{kind = .Wait, text = "scheduler: the share policy, three rounds: each thread of the processes with 1, 2, 4 and 8 spinning threads has the weight and the weight limit 1024, 512, 256 and 128, and the new-thread weight limit 4; the weights of each process sum to 1024, 1024, 1024 and 1024; the third round wrote none of their threads: 1: as it must"},
	{kind = .Wait, text = "scheduler: under the share policy, a thread of this process created with the weight 30 has the weight 30, and the weight 15 after it lowered itself to 15; after this process started 7 threads more, its 9 threads have the weights 15 to 113, which sum to 919 of 1024: as it must"},
	{kind = .Wait, text = "scheduler: the share policy off: each thread of the 4 processes and the first thread of this process have the weight 1024 and the two full weight limits again, the thread that lowered itself has the weight 15 and the two full weight limits, and no write of the policy was refused: 1: as it must"},
	{kind = .Wait, text = "scheduler: the process with 8 spinning threads against the process with 1, by the ticks of the kernel over one interval: its part is smaller under the share policy than without it: as it must"},
	{kind = .Wait, text = "scheduler: shares of the processes with 1, 2, 4 and 8 spinning threads under EEVDF, by the ticks of the kernel: without the share policy "},
	{kind = .Wait, text = "scheduler: one round of the share policy, over "},
	// A process that keeps short threads alive: the threads that no round
	// saw have the new-thread weight limit of their process; a creating
	// thread whose own value is full creates under the value of its
	// process. All are states; the parts of the two processes are a measure.
	{kind = .Wait, text = "scheduler: the share policy and a process that keeps 6 short threads alive, after one round: 24 of its threads that no round saw, read through the machine handle, each had the weight, the weight limit and the new-thread weight limit 4: 1, and those of one read summed to under 1024: 1: as it must"},
	{kind = .Wait, text = "scheduler: under the share policy the first thread of this process got through the machine handle a new-thread weight limit of its own above 5: 1, and the process has the new-thread weight limit 4; a new thread with the weight 5 Bad_Operation, and the error record names 4; a new thread with the weight 0 has the weight, the weight limit and the new-thread weight limit 4, 4 and 4: as it must"},
	{kind = .Wait, text = "scheduler: the first thread of a process started under the share policy, by a thread whose own new-thread weight limit is above 5, has the weight, the weight limit and the new-thread weight limit 4, 4 and 4: as it must"},
	{kind = .Wait, text = "scheduler: the process of short threads got "},
	{kind = .Wait, text = "scheduler: ok, no spinner starved under 3 strategies, a wake ended "},
	{kind = .Wait, text = "scheduler: the window took "},
	{kind = .Shot, text = "scheduler"},
	{kind = .Key, text = "1"},
	{kind = .Wait, text = "scheduler: the strategy is now round robin, it was EEVDF"},
	// The tiles are buttons of the interface package: Tab moves the focus
	// from tile to tile, Enter chooses the third. The scenario writes no
	// more log lines than with the key 3: the ring of the log is full when
	// the process log reads its oldest records.
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "scheduler: the strategy is now EEVDF, it was round robin"},
	// The two commands of the share policy, from the console: a process
	// weight for the processes with a name, the policy on, the view of the
	// shares, the policy off.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"scheduler\")"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Type, text = "scheduler.share(\"terminal\", 512)"},
	{kind = .Wait, text = "[console] 1024"},
	{kind = .Type, text = "scheduler.share(\"terminal\", 16)"},
	{kind = .Wait, text = "the argument weight has 16; it must have at least 32"},
	{kind = .Type, text = "scheduler.policy(1)"},
	{kind = .Wait, text = "scheduler: the share policy is on: each process has its process weight, divided between its threads that count, one round each 100 ms"},
	{kind = .Front, text = "scheduler"},
	{kind = .Key, text = "s"},
	{kind = .Shot, text = "scheduler_shares"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "scheduler.policy(0)"},
	{kind = .Wait, text = "scheduler: the share policy is off: each thread has the weight that its process asked and the full weight limit"},
	{kind = .Type, text = "stop(\"scheduler\")"},
	{kind = .Wait, text = "root: scheduler stopped"},

	// A process drives its own virtual memory: an arena and a sparse table
	// of 1 GiB of addresses, commit and decommit, a protection change with
	// its shoot-down, a guard page, large pages, the refusals.
	{kind = .Launch, text = "address_space"},
	{kind = .Wait, text = "address_space: arena: 1 GiB of addresses in one mapping, "},
	{kind = .Wait, text = "address_space: sparse table: 1024 pages committed of 262144, 1024 with a frame; decommit: 1024 pages back in the budget at once"},
	{kind = .Wait, text = "address_space: protection of 64 pages, one call with its shoot-down, the middle of 40 calls"},
	{kind = .Wait, text = "address_space: guard page: the child stopped with vector 14 at "},
	{kind = .Wait, text = "address_space: edge case: a map with a flag that the kernel does not know is refused: right", any_order = true},
	{kind = .Wait, text = "address_space: edge case: the end of the last thread stops the process with its own stop cause and no stop outcome: right", any_order = true},
	{kind = .Wait, text = "address_space: edge case: a process gets no Control over itself, and its stop through its own handle is refused: right", any_order = true},
	{kind = .Wait, text = "address_space: edge case: a holder's stop with an outcome and a stop of itself with no outcome are refused, and nothing stops: right", any_order = true},
	{kind = .Wait, text = "address_space: large pages: one random read over 64 MiB: "},
	// Each page table that a mapping made returns to the budget with its
	// unmap, at three levels, for a reservation, for a large page, and
	// while another thread uses a page of the same table.
	{kind = .Wait, text = "address_space: page tables: 64 mappings of one page, each at its own entry of three levels: 3 to 3 pages of tables while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a reservation of 1024 pages: 4 pages of tables, the same after a commit and a decommit of 16 pages, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: a large page: 2 pages of tables above it while mapped, 0 pages kept after the unmap: as it must"},
	{kind = .Wait, text = "address_space: page tables: 1000 rounds of a map and an unmap beside a page that another thread writes and reads: 1000 rounds right, the page of the other thread stayed right, 0 pages kept: as it must"},
	{kind = .Wait, text = "address_space: ok, the arena and the sparse table paid only what they used, the decommit gave each page back, the protection changed with its shoot-down, the guard page stopped the child, the large pages are in the report, each refusal has its error record"},
	{kind = .Shot, text = "address_space"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"address_space\")"},
	{kind = .Wait, text = "root: address_space stopped"},

	// The boot display in a window: how the machine started, with the
	// records that the kernel has now.
	{kind = .Launch, text = "boot"},
	{kind = .Wait, text = "boot: ok, 7 stages, "},
	{kind = .Shot, text = "boot"},
	// The window covers the console: move it down, away from the console.
	{kind = .Move, text = "boot", to_x = 64, to_y = WINDOW_TITLE_ONLY_Y},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"boot\")"},
	{kind = .Wait, text = "root: boot stopped"},
	{kind = .Type, text = "process_modules()"},
	{kind = .Wait, text = "[console] slot  process"},

	// Paging: the kernel reads its own page tables. No page is both
	// writable and executable, and each kernel stack has its guard pages.
	{kind = .Launch, text = "pages"},
	{kind = .Wait, text = "pages: the kernel half: ", any_order = true},
	{kind = .Wait, text = " 0 write and execute, 24 guard pages of 24"},
	{kind = .Wait, text = "pages: ok, the page tables keep the rules"},
	{kind = .Wait, text = "pages: the processor refuses the memory of processes to the kernel"},
	{kind = .Shot, text = "pages"},
	{kind = .Move, text = "pages", to_x = 168, to_y = WINDOW_TITLE_ONLY_Y}, // The window covers the console.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"pages\")"},
	{kind = .Wait, text = "root: pages stopped"},

	// Paging as a tool of the system: pages on first use, and the shared
	// code of a module. The process starts its twins and measures.
	{kind = .Launch, text = "frames"},
	{kind = .Wait, text = "frames: 4 twins: ", any_order = true},
	{kind = .Wait, text = "frames: create and map 8192 pages: ", any_order = true},
	{kind = .Wait, text = "frames: the first use of a page: ", any_order = true},
	{kind = .Wait, text = "frames: start a twin: ", any_order = true},
	{kind = .Wait, text = "frames: ok, 10 cases", any_order = true},
	{kind = .Wait, text = "compositor: surface frames"},
	{kind = .Shot, text = "frames"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"frames\")"},
	{kind = .Wait, text = "root: frames stopped"},

	// A service serves its own exports while it runs. The root service makes
	// the connection; the console reads the descriptions in the file of the
	// process, and each export is a command.
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 520, to_y = 408}, // Below the console, at the right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "connect(\"paint\")"},
	{kind = .Wait, text = "root: connected console to the service paint"},
	{kind = .Wait, text = "[console]   module     paint"},
	{kind = .Wait, text = "[console]   commands   4"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "connect(\"life\")"},
	{kind = .Wait, text = "[console]   module     life"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "connect(\"plasma\")"},
	{kind = .Wait, text = "error: cannot connect to plasma: root.Connect: the argument name names none of the services that run"},
	// The monitor serves its tables; its grant of the machine was revoked
	// above, so the kernel refuses its reports.
	{kind = .Type, text = "connect(\"monitor\")"},
	{kind = .Wait, text = "[console]   module     monitor"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "monitor.count(\"processors\")"},
	{kind = .Wait, text = "[console] error: monitor.count: the kernel refused an operation of the call: a handle names no object of the kind that the operation needs"},
	{kind = .Type, text = "where(help(), name = \"paint.write\")"},
	// The help table fits the window of the console, so the signature
	// breaks between two words, in its own column.
	{kind = .Wait, text = "[console] paint.write  paint.write(x: Integer, y: Integer,"},
	{kind = .Wait, text = "text: Text, color: Integer) -> Integer"},
	// One line for three calls: each result is a line of the log, and the
	// check of the log below needs each record since the boot.
	{kind = .Type, text = "paint.line(40, 30, 440, 250, 4) + paint.line(40, 250, 440, 30, 9) + paint.write(150, 20, \"drawn by isolated calls\", 0)"},
	{kind = .Wait, text = "[console] 26"}, // 1 and 2 lines, and 23 bytes of text.
	{kind = .Type, text = "paint.lines()"},
	{kind = .Wait, text = "[console] 2"},
	{kind = .Type, text = "life.empty()"},
	{kind = .Type, text = "life.glider(10, 10)"},
	{kind = .Type, text = "life.population()"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Front, text = "paint"},
	{kind = .Shot, text = "services"},
	{kind = .Front, text = "console"},
	// The service stops: the call fails, and the console continues. The
	// service starts again: the next call makes a new connection.
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	{kind = .Wait, text = "root: disconnected console from the service paint"},
	{kind = .Type, text = "paint.lines()"},
	{kind = .Wait, text = "error: no service runs with the name paint"},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Move, text = "paint", to_x = 464, to_y = 688}, // The window covers the console: move it down.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "paint.lines()"},
	{kind = .Wait, text = "root: connected console to the service paint"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},

	// One module in each role: the file of tally runs as a process, as a
	// service, as a library in the memory of the console, and as a sandboxed
	// process. Each
	// process that runs the module has its own count.
	{kind = .Launch, text = "tally"},
	{kind = .Wait, text = "tally: ok", any_order = true}, // The compositor can write the line of the surface first.
	{kind = .Wait, text = "compositor: surface tally"},
	{kind = .Move, text = "tally", to_x = 616, to_y = 528}, // Under the console, at the right.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "connect(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "tally.add(5, \"from the console, to the service\")"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "load(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "add(2, \"in the console\") + add(2, \"in the console\")"},
	{kind = .Wait, text = "[console] 6"},
	{kind = .Type, text = "tally.total()"},
	{kind = .Wait, text = "[console] 5"},
	{kind = .Type, text = "isolate(\"tally\")"},
	{kind = .Wait, text = "error: the module tally is loaded; unload(\"tally\") removes it"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console]   module    tally"},
	{kind = .Wait, text = "[console]   commands  5"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Type, text = "total()"},
	{kind = .Wait, text = "error: no command has the name total"},
	{kind = .Type, text = "isolate(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "add(30, \"in a sandboxed process\") + adds()"},
	{kind = .Wait, text = "[console] 31"},
	{kind = .Type, text = "last()"},
	{kind = .Wait, text = "[console] in a sandboxed process"},
	{kind = .Type, text = "tally.last()"},
	{kind = .Wait, text = "[console] from the console, to the service"},
	{kind = .Shot, text = "roles"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console]   module    tally"},
	{kind = .Wait, text = "[console]   commands  5"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	{kind = .Type, text = "tally.total()"},
	{kind = .Wait, text = "[console] 5"},

	// The manual shows the documentation that each module carries. It is a
	// service: the console asks for a page, and reads a description as text.
	{kind = .Launch, text = "manual"},
	{kind = .Wait, text = "compositor: surface manual", any_order = true},
	// The measures of the information functions: all the modules and all
	// their exports, and one reverse question.
	{kind = .Wait, text = "manual: information: ", any_order = true},
	{kind = .Wait, text = "manual: ok, "},
	// The manual reads the Markdown of the documentation: it checks its own
	// page, whose comments have each mark.
	{kind = .Wait, text = "manual: the Markdown of its page: bold, italics, code, list items and links that open a page; no mark is left and no row passes the window: as it must", fails_on = "manual: the Markdown of its page: FAILED"},
	{kind = .Move, text = "manual", to_x = 208, to_y = WINDOW_TITLE_ONLY_Y},
	{kind = .Front, text = "console"},
	// A call that nothing forces connects nothing: the body of a function
	// with no call, and a "|>" in it, which the check before the parse
	// reads.
	{kind = .Type, text = "let f = () => manual.about(\"math\") in 1"},
	{kind = .Wait, text = "[console] 1", fails_on = "connected console to the service manual"},
	{kind = .Type, text = "let f = () => \"math\" |> manual.about() in 2"},
	{kind = .Type, text = "6 * 7"},
	{kind = .Wait, text = "[console] 42", fails_on = "connected console to the service manual"},
	// A call of an export connects its service at its first use, as connect
	// does; connect then gives the record of the connection that exists.
	{kind = .Type, text = "manual.about(\"math\")"},
	{kind = .Wait, text = "root: connected console to the service manual"},
	{kind = .Wait, text = "[console] A module of commands: each command is a function"},
	{kind = .Type, text = "connect(\"manual\")"},
	{kind = .Wait, text = "[console]   module     manual"},
	{kind = .Wait, text = "[console]   commands   17"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "manual.about(\"math\")"},
	{kind = .Wait, text = "[console] A module of commands: each command is a function"},
	{kind = .Type, text = "manual.signature(\"tally\", 1)"},
	{kind = .Wait, text = "[console] add(amount: Integer, note: Text) -> Integer"},
	{kind = .Type, text = "manual.show(\"nothing\")"},
	{kind = .Wait, text = "[console] error: manual.show: the argument name names none of the modules"},
	// A name or a number that names nothing gives an error record, not an
	// empty text: the caller tells a failure from an empty answer.
	{kind = .Type, text = "manual.about(\"nothing\")"},
	{kind = .Wait, text = "[console] error: manual.about: the argument name names none of the modules"},
	{kind = .Type, text = "manual.signature(\"tally\", 9)"},
	{kind = .Wait, text = "[console] error: manual.signature: the argument export has the value 9, which the call refuses; it takes at most 5"},
	{kind = .Type, text = "manual.show(\"tally\")"},
	{kind = .Wait, text = "manual: tally: a module with an entry, 5 exports, "},
	{kind = .Move, text = "manual", to_x = 80, to_y = 64},
	{kind = .Shot, text = "manual"},
	// The keys of the manual: the next module of the list, then the one
	// before. The list is in groups by category, each in the order of the
	// alphabet (src/md/features/manual_module_list.md): after tally comes
	// threads.
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "manual: threads: a module with an entry, "},
	{kind = .Key, text = "pgdn"},
	{kind = .Key, text = "up"},
	{kind = .Wait, text = "manual: tally: a module with an entry, 5 exports, "},
	// A typed word filters the list; Escape empties the filter.
	{kind = .Key, text = "m"},
	{kind = .Wait, text = "manual: the filter \"m\" shows "},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "manual: the filter \"\" shows "},
	// The links of a page (src/md/features/manual_links.md). Tab puts the
	// focus on the first link of the page of the manual, a heading of a
	// guide, and scrolls the page to it. The console shows the page of the
	// manual; then the keys go to the manual again.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "manual.show(\"manual\")"},
	{kind = .Wait, text = "manual: manual: a module with an entry, 17 exports, "},
	{kind = .Front, text = "manual"},
	// The element line of the link comes after the line of the page: before
	// the focus when the view showed the link, after it when Tab scrolled.
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "manual: the focus is on the link the description tables to docs/MODULE_CONTRACT.md#description-tables", any_order = true},
	{kind = .Wait, text = "interface: manual: the element the description tables at "},
	{kind = .Shot, text = "manual_link"},
	// A press on the link opens its link page, from the resource of the
	// boot image; Backspace goes back to the page of the module.
	{kind = .Click_Element, text = "manual", element = "the description tables"},
	{kind = .Wait, text = "manual: the link the description tables opens docs/MODULE_CONTRACT.md#description-tables"},
	{kind = .Wait, text = "manual: the page docs/MODULE_CONTRACT.md#description-tables: Description tables, "},
	{kind = .Key, text = "backspace"},
	{kind = .Wait, text = "manual: back to the page before"},
	{kind = .Wait, text = "manual: manual: a module with an entry, 17 exports, "},
	// Tab twice and Enter: the second link, a term of the glossary.
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "manual: the focus is on the link the description tables to docs/MODULE_CONTRACT.md#description-tables"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "manual: the focus is on the link link page to term:link-page"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "manual: the link link page opens term:link-page"},
	{kind = .Wait, text = "manual: the page term:link-page: Link page, "},
	{kind = .Key, text = "backspace"},
	{kind = .Wait, text = "manual: back to the page before"},
	{kind = .Wait, text = "manual: manual: a module with an entry, 17 exports, "},
	// The third link names a procedure of a support package that no
	// module describes: it opens the page of its declaration, which the
	// build took from the source. Back keeps the first row of the view
	// that showed the second link, under the first link: with no focus,
	// Tab takes the first link at or under the top of the view.
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "manual: the focus is on the link link page to term:link-page"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "manual: the focus is on the link system.word_wait to system.word_wait"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "manual: the link system.word_wait opens system.word_wait"},
	{kind = .Wait, text = "manual: the page system.word_wait: system.word_wait, "},
	{kind = .Shot, text = "manual_declaration"},
	{kind = .Key, text = "backspace"},
	{kind = .Wait, text = "manual: back to the page before"},
	{kind = .Wait, text = "manual: manual: a module with an entry, 17 exports, "},
	{kind = .Move, text = "manual", to_x = 208, to_y = WINDOW_TITLE_ONLY_Y},
	{kind = .Front, text = "console"},

	// A module with imports: agenda imports calendar. The loader finds an
	// import only in what the console was granted: lonely imports a module
	// that is not in the boot image.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "load(\"lonely\")"},
	// An error is a record: the console prints its lines.
	{kind = .Wait, text = "[console] error: cannot load lonely"},
	{kind = .Wait, text = "..., and the load source has no file with its hash"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "where(loaded(), imported_by = \"agenda\")"},
	{kind = .Wait, text = "[console] calendar  direct  agenda"},
	// calendar has a fault: 2000 has 365 days, and February 28.
	{kind = .Type, text = "year_days(2000) + month_days(2, 2000)"},
	{kind = .Wait, text = "[console] 393"},
	// Each module one time: calendar is in the console as the import of agenda.
	{kind = .Type, text = "load(\"calendar\")"},
	{kind = .Wait, text = "[console]   module     calendar"},
	{kind = .Wait, text = "[console]   commands   1"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "unload(\"calendar\")"},
	{kind = .Wait, text = "[console]   module    calendar"},
	{kind = .Wait, text = "[console]   commands  1"},
	{kind = .Wait, text = "[console]   memory    stays: another module imports it"},
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Wait, text = "[console]   module    agenda"},
	{kind = .Wait, text = "[console]   commands  3"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	// Who may replace a module: the root service writes a replacement only
	// for a row of the replacement list that the signing key of the system
	// signed. No row names calendar by math; the row of calendar by lonely
	// is signed by another key. The table does not change, so agenda still
	// runs calendar, with its fault.
	{kind = .Type, text = "replace(\"calendar\", \"math\")"},
	{kind = .Wait, text = "root: refused the replacement of calendar by math: no signed row of the replacement list names it"},
	{kind = .Wait, text = "[console] error: the root service refused the replacement of calendar by math: no signed row names it"},
	{kind = .Type, text = "replace(\"calendar\", \"lonely\")"},
	{kind = .Wait, text = "root: refused the replacement of calendar by lonely: the signature of its row does not verify under the signing key of the system"},
	{kind = .Wait, text = "[console] error: the root service refused the replacement of calendar by lonely: its signature does not verify"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Type, text = "year_days(2000) + month_days(2, 2000)"},
	{kind = .Wait, text = "[console] 393"},
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	// The replacement of an import. The root service holds the table of the
	// machine; the loader checks each export that agenda uses.
	{kind = .Type, text = "replace(\"calendar\", \"calendar_changed\")"},
	{kind = .Wait, text = "root: calendar_changed replaces calendar in each load that follows"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console] error: cannot load agenda"},
	{kind = .Wait, text = "[console] error: agenda imports calendar, and its replacement calendar_changed fails the check"},
	{kind = .Wait, text = "[console] error: export days_in_month of calendar_changed: 3 parameters, calendar has 2"},
	// A replacement that makes an import cycle.
	{kind = .Type, text = "replace(\"calendar\", \"agenda\")"},
	{kind = .Wait, text = "root: agenda replaces calendar in each load that follows"},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console] error: cannot load agenda"},
	{kind = .Wait, text = "[console] error: an import cycle: agenda imports calendar, and agenda still loads its imports"},
	{kind = .Wait, text = "[console] error: the replacement table gives agenda in place of calendar: that makes the cycle"},
	{kind = .Type, text = "replace(\"calendar\", \"calendar_fixed\")"},
	{kind = .Wait, text = "root: calendar_fixed replaces calendar in each load that follows"},
	{kind = .Type, text = "replace(\"calendar_fixed\", \"math\")"},
	{kind = .Wait, text = "[console] error: a chain of replacements is refused: calendar_fixed, math"},
	{kind = .Type, text = "replacements()"},
	{kind = .Wait, text = "calendar  calendar_fixed  "},
	{kind = .Type, text = "load(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "where(loaded(), in_place_of = \"calendar\")"},
	{kind = .Wait, text = "calendar_fixed  direct  agenda       calendar  "},
	{kind = .Type, text = "year_days(2000) + month_days(2, 2000)"},
	{kind = .Wait, text = "[console] 395"},
	{kind = .Type, text = "manual.show(\"agenda\")"},
	{kind = .Wait, text = "manual: agenda: a module with an entry, 3 exports, "},
	// A process that imports calendar: the root service gives it the
	// replacements of the machine when it starts it.
	{kind = .Launch, text = "imports"},
	{kind = .Wait, text = "compositor: surface imports", any_order = true},
	// A process cannot change the module record that its starter wrote:
	// not remove it, not replace it, not unmap or map at its addresses. Its
	// own load is a record of the writer process.
	{kind = .Wait, text = "imports: the module record of the root service: 4 of 4 changes refused with Starter_Module, writer starter; calendar, loaded by this process: writer process"},
	{kind = .Wait, text = "imports: ok, 13 cases"},
	{kind = .Wait, text = "imports: a call through an import slot: "},
	{kind = .Wait, text = "imports: the bind of agenda: "},
	{kind = .Wait, text = "imports: two processes import calendar at two places: one copy of its code, "},
	{kind = .Move, text = "imports", to_x = 136, to_y = 304},
	{kind = .Shot, text = "imports"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "where(process_modules(), replaces = \"calendar\")"},
	{kind = .Wait, text = "calendar_fixed  calendar  "},
	// A fault in the module of the replacement: the kernel names
	// calendar_fixed, not calendar.
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Type, text = "isolate(\"agenda\")"},
	{kind = .Wait, text = "[console]   module     agenda"},
	{kind = .Wait, text = "[console]   commands   3"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "where(loaded(), imported_by = \"agenda\")"},
	{kind = .Wait, text = "[console] calendar_fixed  isolated  agenda"},
	{kind = .Type, text = "year_days(2000)"},
	{kind = .Wait, text = "[console] 366"},
	{kind = .Type, text = "month_days(13, 2000)"},
	{kind = .Wait, text = "kernel: process agenda stopped: invalid instruction"},
	{kind = .Wait, text = ", which replaces "},
	{kind = .Wait, text = "[console] error: the process agenda stopped: a fault, invalid instruction"},
	// The debug image names the procedure of the instruction, in the module
	// that ran: calendar_fixed, not calendar.
	{kind = .Wait, text = "[console] error: the instruction is at "},
	{kind = .Wait, text = " in calendar_fixed"},
	{kind = .Wait, text = "... runs in place of calendar "},
	{kind = .Type, text = "replacements()"},
	{kind = .Wait, text = "calendar  calendar_fixed  "},
	{kind = .Shot, text = "replacement"},
	// The information of the modules: the manual serves tables of records
	// that it reads in the flat tables of the modules, and in the module
	// records of the kernel. The console combines them with generic
	// commands that read the description of the records.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "columns(manual.importers(\"calendar_fixed\"), module, name, replacement, import_slots)"},
	{kind = .Wait, text = "[console] agenda "},
	{kind = .Wait, text = "[console] imports "},
	{kind = .Wait, text = "[console] 2 rows of Import"},
	{kind = .Type, text = "columns(where(manual.running(), module = \"calendar_fixed\"), process, slot, module, replaces)"},
	{kind = .Wait, text = "[console] imports "},
	{kind = .Wait, text = " of Running"},
	// The graph of the modules as it runs: in the process imports, the
	// module imports imports calendar_fixed, which a replacement put in
	// place of calendar. The first column is the importer.
	{kind = .Type, text = "columns(where(manual.edges(), replaces = \"calendar\"), imported_by, module, replaces, process)"},
	{kind = .Wait, text = "[console] imports      calendar_fixed  calendar  imports"},
	{kind = .Wait, text = " of Edge"},
	{kind = .Type, text = "sort(columns(manual.handles(\"Write\"), module, name, rights), \"name\")"},
	{kind = .Wait, text = "[console] sample "},
	{kind = .Wait, text = " of Export"},
	{kind = .Type, text = "join(columns(manual.running(), process, hash), columns(manual.modules(), hash, name, code, exports), \"hash\")"},
	{kind = .Wait, text = " rows of Running_Module"},
	{kind = .Type, text = "rows(manual.exports(\"\")) - rows(manual.exporters(\"show\"))"},
	{kind = .Wait, text = "[console] "},
	{kind = .Type, text = "manual.exports(\"nothing\")"},
	{kind = .Wait, text = "[console] error: manual.exports: the argument name names none of the modules"},
	{kind = .Type, text = "where(manual.modules(), code = \"large\")"},
	{kind = .Wait, text = "[console] error: where: the field code is Integer, the value is Text"},
	{kind = .Type, text = "manual.overview()"},
	{kind = .Wait, text = "manual: overview: "},
	{kind = .Front, text = "manual"},
	{kind = .Move, text = "manual", to_x = 80, to_y = 64},
	{kind = .Shot, text = "modules"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "manual.show(\"calendar_fixed\")"},
	{kind = .Wait, text = "manual: calendar_fixed: no entry, "},
	{kind = .Front, text = "manual"},
	{kind = .Shot, text = "module_information"},
	{kind = .Move, text = "manual", to_x = 208, to_y = WINDOW_TITLE_ONLY_Y},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "unload(\"agenda\")"},
	{kind = .Wait, text = "[console]   module    agenda"},
	{kind = .Wait, text = "[console]   commands  3"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	{kind = .Type, text = "stop(\"imports\")"},
	{kind = .Wait, text = "root: imports stopped"},
	{kind = .Type, text = "stop(\"manual\")"},
	{kind = .Wait, text = "root: manual stopped"},
	{kind = .Type, text = "stop(\"tally\")"},
	{kind = .Wait, text = "root: tally stopped"},

	// The log: records of processes. The kernel sets the process of each
	// record; a process with the grant reads the records.
	{kind = .Launch, text = "log"},
	{kind = .Fact, process = "log", fact = "log.Log_Memory", condition = "memory > 0", any_order = true},
	// The window loses no record once it reads the log: the records gone
	// before its start depend on the length of the boot, and are only a
	// measure (src/md/features/log_window_losses.md).
	{kind = .Wait, text = "[log] log: ok, ", any_order = true},
	{kind = .Wait, text = " gone before its start, 0 lost since, "},
	{kind = .Shot, text = "log"},
	// The window covers the console: move it down.
	{kind = .Move, text = "log", to_x = 96, to_y = WINDOW_TITLE_ONLY_Y},
	// The log records as a table with typed fields, through the remote
	// service: from here on some checks read the process and the level of
	// a record (step Record), not only a line of text.
	{kind = .Call, text = "log.records(0)", expected = " rows of Record"},
	// The process log writes the size of the memory of the log as a log
	// fact, whose field memory is a size in KiB: the step Record reads its
	// sentence, which the tool writes from the fields, and the step Fact
	// reads the field itself, which the check before the run finds in the
	// fact table of the module log. The step Fact comes just after the
	// launch: it reads the serial port after the last Wait, and the line
	// comes before the line "log: ok".
	{kind = .Record, process = "log", level = "Info", text = "log: the memory of the log: "},
	{kind = .Front, text = "console"},
	// The kernel writes a record of its own, and the log keeps it: a
	// process that fails gives a warning of the kernel. A record of now,
	// not of the boot, so that no count of the records before it matters.
	{kind = .Type, text = "start(\"fault\")"},
	{kind = .Wait, text = "stopped: page fault"},
	{kind = .Wait, text = "root: fault stopped"},
	{kind = .Record, process = "kernel", level = "Warning", text = "kernel: process fault stopped: page fault"},
	// The log scope: log_reader has a connection to the log service that
	// does not act for the principal. It reads the log from the own number
	// 0 and receives its own records only: the records of its process slot
	// with its process serial, numbered among its own records. The second
	// run reads none of the records of the first one, which the ring still
	// keeps: same name, same texts, often the same slot, another serial.
	// Before it connects, log_reader starts two children, which each write
	// one record and stop. With the process handle of each child, which it
	// lends for the call, it reads the one record of that child: not its
	// own records, not the record of the other child, and in the second
	// run not the record of the child of the same name of the first run.
	// The children are not in its own records. A memory object in place of
	// a process handle is refused, and the process handle of the log
	// service from connect, with Read and no Give, cannot be lent.
	// After the two children stopped, a third child, "log_reader storm",
	// writes more records than the whole log keeps, which push the records
	// of log_reader and of its two children out of the whole log. Each
	// check above runs after that storm, and still finds each record: the
	// own log ring of each process keeps it, the ring of a stopped child
	// too, while log_reader holds its handle. The storm child takes its log
	// records of each second from the budget of log_reader, which counts
	// only its own, and each child gives them back at its stop. Last, it
	// calls the kernel operation Log itself: each wrong call is refused
	// with its status and its error record and writes no record, and a
	// text at each edge of its length is written.
	{kind = .Type, text = "start(\"log_reader\")"},
	{kind = .Wait, text = "[log_reader child 1] log_reader child: the record that the starter reads back, with the value 1", fails_on = "log_reader: WRONG", any_order = true},
	{kind = .Wait, text = "[log_reader child 2] log_reader child: the record that the starter reads back, with the value 2", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader storm] log_reader storm: the last record, after more records than the whole log keeps", fails_on = "log_reader: WRONG"},
	// The connection is a log fact of the root service: the step reads the
	// field that names the caller, the wait its sentence with the service.
	{kind = .Fact, process = "root", fact = "root.Connected", condition = "caller = \"log_reader\"", any_order = true},
	{kind = .Wait, text = "root: connected log_reader to the service log, for principal 0"},
	{kind = .Wait, text = "[log_reader] log_reader: its own records: 1 rows from the own number 0, its first record, in the slot ", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = ", lost 0: no row of another process or of an earlier run: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the value runs: 1 rows, each of a record of this process, with the run of its value 42: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the records of log_reader child 1: 1 rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: the value runs of log_reader child 1: 1 rows, the run of its value 1: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the records of log_reader child 2: 1 rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: the value runs of log_reader child 2: 1 rows, the run of its value 2: as it must"},
	{kind = .Wait, text = " records after the records of this process and of its two children, more than the "},
	{kind = .Wait, text = " that the whole log keeps, and the own log ring of each one kept its records: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the storm child took 900 of the 1000 log records of each second of this process, which kept 100, and each child gave its records back at its stop: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: a memory object in place of a process handle: the log service refused it with Handle_Kind: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the process handle of the log service from connect, with Read and no Give: the lend failed with No_Right, and it reads no record of the service: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: Log refused 12 wrong calls, each with its status and its error record: the level word, the runs and the length past their bounds, an address that the process cannot read, and a text or its runs past the end of what it can read; the own log ring kept the same ", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = " records, and the budget the same log records and the same refused count: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: Log wrote a text of 0 bytes, of 1 byte and of 4096 bytes in 1, 1 and 25 records, a text at the level Error, a text with 32 runs that keeps 8, and one byte on the last byte of a page: as it must", fails_on = "log_reader: WRONG"},
	// Log of the form Fact: each wrong fact is refused with its status and
	// its error record and writes no record. Then the log fact of
	// log_reader, whose serial line is bytes: the tool writes its sentence
	// from its fields with the template of the module file (fact_render.odin).
	// The step Fact waits for the same line by its fact type and a field,
	// not by its sentence: the tool checked the step against the fact table
	// of log_reader before the machine started (fact_steps.odin).
	{kind = .Wait, text = "[log_reader] log_reader: Log refused 11 wrong facts, each with its status and its error record: the form word, a run, the length below the head and past the whole fact, an address that the process cannot read, and the level; the own log ring kept the same ", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = " records, and the budget the same log records and the same refused count: as it must"},
	{kind = .Fact, process = "log_reader", fact = "log_reader.Fact_Probe", condition = "value = 42", any_order = true},
	{kind = .Wait, text = "[log_reader] log_reader: a log fact with the value 42, the mark 0x4c4f4746 and the number 7", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: the three facts read back: the form Fact, no next record, the reserved bytes 0, the key of each writer, 0, 144 and 16 value bytes, and the hash of this module in the fact of system.log_fact: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: Log wrote a fact of 48 bytes and a fact of 192 bytes, and system.log_fact the fact Fact_Probe, each in one record: as it must", fails_on = "log_reader: WRONG"},
	// A fact of several records through the kernel, read back and joined,
	// and the log limit that refuses such a fact whole.
	{kind = .Wait, text = "[log_reader] log_reader: a fact of 145 value bytes in 2 records and a fact of 1168 value bytes in 9 records, at the bound of a call, read back: each record with its part, the count of its parts and its value bytes, joined whole into the bytes given: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: a child whose log limit holds 4 records: a fact of 9 records and one of 5 were refused whole, each record counted as refused; a fact of as many records as its limit was taken, and one of 3 records after one of 2 in the same budget was refused; its records hold whole facts only: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: ok"},
	// The stop of log_reader is a log fact of the root service, with its
	// stop cause and its stop outcome as fields. The step reads the field
	// that names the process; the console reads the outcome Done of the
	// same fact below (src/md/api/process_stop.md).
	{kind = .Fact, process = "root", fact = "root.Process_Stopped", condition = "stopped_process = \"log_reader\"", any_order = true},
	{kind = .Wait, text = "root: log_reader stopped: itself, done"},
	// The remote service acts for the principal and still reads the whole
	// log in order: the last record of the storm child, then the line of
	// log_reader after it, then the stop that the root service writes. The
	// earlier records of the run are gone from the whole log.
	{kind = .Record, process = "log_reader storm", level = "Info", text = "log_reader storm: the last record, after more records than the whole log keeps"},
	// The console reads the fact of log_reader as a row of a table, by its
	// fields: facts() reads its values through log.fact_records, and where
	// takes a field of the fact type, which the console checks before the
	// call. The rows of log.records start at the last record of the storm,
	// so they fit in the call region of the console; the whole log, from
	// 0, does not. Of the three facts after the storm, two have no module
	// of the image, and one is a Fact_Probe.
	{kind = .Type, text = "connect(\"log\")"},
	{kind = .Wait, text = "[console]   module     log"},
	{kind = .Type, text = "log.records({record}) |> facts(log_reader.Fact_Probe) |> where(value = 42)"},
	{kind = .Wait, text = "[console] 1 row of Fact_Probe"},
	{kind = .Record, process = "log_reader", level = "Info", text = "log_reader: ok"},
	// The step Record reads the stop, a log fact, by its sentence, which
	// the tool writes from log.fact_records.
	{kind = .Record, process = "root", level = "Info", text = "root: log_reader stopped: itself, done"},
	// The console reads the same fact of the root service by its fields,
	// from that record: the stop cause and the stop outcome are statuses of
	// their contract enums, which a condition names by their members. The
	// first condition keeps the stops of log_reader only, so a clean stop
	// of another process after it is not counted.
	{kind = .Type, text = "log.records({record}) |> facts(root.Process_Stopped) |> where(stopped_process = \"log_reader\") |> where(outcome = Done)"},
	{kind = .Wait, text = "[console] 1 row of Process_Stopped"},
	{kind = .Type, text = "start(\"log_reader\")"},
	{kind = .Wait, text = "[log_reader child 1] log_reader child: the record that the starter reads back, with the value 1", fails_on = "log_reader: WRONG", any_order = true},
	{kind = .Wait, text = "[log_reader child 2] log_reader child: the record that the starter reads back, with the value 2", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader storm] log_reader storm: the last record, after more records than the whole log keeps", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "root: connected log_reader to the service log, for principal 0"},
	{kind = .Wait, text = "[log_reader] log_reader: its own records: 1 rows from the own number 0, its first record, in the slot ", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = ", lost 0: no row of another process or of an earlier run: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the value runs: 1 rows, each of a record of this process, with the run of its value 42: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the records of log_reader child 1: 1 rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: the value runs of log_reader child 1: 1 rows, the run of its value 1: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the records of log_reader child 2: 1 rows from the own number 0, its one record, lost 0: no row of this process, of the other child or of an earlier run: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: the value runs of log_reader child 2: 1 rows, the run of its value 2: as it must"},
	{kind = .Wait, text = " that the whole log keeps, and the own log ring of each one kept its records: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the storm child took 900 of the 1000 log records of each second of this process, which kept 100, and each child gave its records back at its stop: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: a memory object in place of a process handle: the log service refused it with Handle_Kind: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: the process handle of the log service from connect, with Read and no Give: the lend failed with No_Right, and it reads no record of the service: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: Log refused 12 wrong calls, each with its status and its error record: the level word, the runs and the length past their bounds, an address that the process cannot read, and a text or its runs past the end of what it can read; the own log ring kept the same ", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = " records, and the budget the same log records and the same refused count: as it must"},
	{kind = .Wait, text = "[log_reader] log_reader: Log wrote a text of 0 bytes, of 1 byte and of 4096 bytes in 1, 1 and 25 records, a text at the level Error, a text with 32 runs that keeps 8, and one byte on the last byte of a page: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: Log refused 11 wrong facts, each with its status and its error record: the form word, a run, the length below the head and past the whole fact, an address that the process cannot read, and the level; the own log ring kept the same ", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = " records, and the budget the same log records and the same refused count: as it must"},
	// A hexadecimal field, with the form of its sentence.
	{kind = .Fact, process = "log_reader", fact = "log_reader.Fact_Probe", condition = "mark = 0x4c4f4746", any_order = true},
	{kind = .Wait, text = "[log_reader] log_reader: a log fact with the value 42, the mark 0x4c4f4746 and the number 7", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: the three facts read back: the form Fact, no next record, the reserved bytes 0, the key of each writer, 0, 144 and 16 value bytes, and the hash of this module in the fact of system.log_fact: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: Log wrote a fact of 48 bytes and a fact of 192 bytes, and system.log_fact the fact Fact_Probe, each in one record: as it must", fails_on = "log_reader: WRONG"},
	// A fact of several records through the kernel, read back and joined,
	// and the log limit that refuses such a fact whole.
	{kind = .Wait, text = "[log_reader] log_reader: a fact of 145 value bytes in 2 records and a fact of 1168 value bytes in 9 records, at the bound of a call, read back: each record with its part, the count of its parts and its value bytes, joined whole into the bytes given: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: a child whose log limit holds 4 records: a fact of 9 records and one of 5 were refused whole, each record counted as refused; a fact of as many records as its limit was taken, and one of 3 records after one of 2 in the same budget was refused; its records hold whole facts only: as it must", fails_on = "log_reader: WRONG"},
	{kind = .Wait, text = "[log_reader] log_reader: ok"},
	{kind = .Fact, process = "root", fact = "root.Process_Stopped", condition = "stopped_process = \"log_reader\"", any_order = true},
	{kind = .Wait, text = "root: log_reader stopped: itself, done"},
	{kind = .Record, process = "log_reader storm", level = "Info", text = "log_reader storm: the last record, after more records than the whole log keeps"},
	{kind = .Record, process = "log_reader", level = "Info", text = "log_reader: ok"},
	{kind = .Record, process = "root", level = "Info", text = "root: log_reader stopped: itself, done"},
	// The names that facts() and a condition read are checked before any
	// call (src/md/features/log_facts.md, "Filters of a reader: one
	// form"): a fact name of two dots, a fact type that the package of
	// log_reader does not write, and an order on the level of the table of
	// a fact type. Each line runs no call, so processes() on the left is
	// never called. A line that reads the fact of log_reader whole is a
	// step of the machine tests that read facts: log.records(0) of a full
	// log does not fit in the call region of the console.
	{kind = .Type, text = "processes() |> facts(log_reader.Fact_Probe.value)"},
	{kind = .Wait, text = "[console] error: facts: no fact type has the name log_reader.Fact_Probe.value; the fact types are "},
	{kind = .Type, text = "processes() |> facts(log_reader.Fact_Probes)"},
	// The console names the fact types of the package of the name: each line
	// of log_reader is a fact, so the list is long, and the wait reads its
	// start.
	{kind = .Wait, text = "[console] error: facts: no fact type has the name log_reader.Fact_Probes; the fact types of log_reader are log_reader."},
	{kind = .Type, text = "processes() |> facts(log_reader.Fact_Probe) |> where(level >= Warning)"},
	{kind = .Wait, text = "[console] error: where: the field level is Status(Log_Level): it takes = and != only, because the order of the members is no order of weight"},
	{kind = .Type, text = "processes() |> facts(log_reader.Fact_Probe) |> where(level = \"Warning\")"},
	{kind = .Wait, text = "[console] error: where: the field level holds a member of Log_Level, and a member is a name, not a text or a number: \"Warning\" is none; the members are Info, Debug, Warning, Error"},
	// An arena grows one page at a time until its budget refuses the
	// commit: the refusal is a value that the process reads, the arena
	// keeps its state, a reset takes the same pages again with no commit,
	// and the end gives every page back to the budget
	// (src/md/features/memory_without_a_bound.md).
	{kind = .Type, text = "start(\"arena\")"},
	{kind = .Wait, text = "arena: grew to ", fails_on = "arena: WRONG"},
	{kind = .Wait, text = "arena: the budget refused the commit with No_Budget, the arena kept its state, a reset took the same pages again with no commit, and its end gave every page back to the budget: as it must", fails_on = "arena: WRONG"},
	{kind = .Wait, text = "root: arena stopped: itself, done"},
	// The record outputs (src/md/features/module_outputs.md, "How a test
	// waits on a record output"): output_wiring starts output_writer and
	// output_reader, wires them with Wire and with the wiring list of
	// Start, and tries each refusal of the root service with its budget
	// unchanged; the writers and the readers write what they read. The
	// processes print in an order that the system does not fix.
	{kind = .Type, text = "start(\"output_wiring\")"},
	{kind = .Wait, text = "output_wiring: Wire before its list page, with a step that names nothing and with a reserved word, and the list page past the budget: refused, each with its status and its error record, the budget unchanged; then the list page, its handle revoked, unmapped and closed, and a new handle of it: as it must", fails_on = "output_wiring: WRONG"},
	{kind = .Wait, text = "output_wiring: 140 lent handles given back with lists of no row, each list refused with its status and its error record and the budget unchanged: as it must", fails_on = "output_wiring: WRONG"},
	{kind = .Wait, text = "output_wiring: the refusals of a wiring, each with its status and its error record and the budget unchanged, 140 lent memory handles among them, 70 conditions that the root service refuses at its border, and the Wire of the second reader: as it must", fails_on = "output_wiring: WRONG", any_order = true},
	{kind = .Wait, text = "output_writer: probes: 8 probes to two readers, the second one after 5, a clean end, and Ended after it: as it must", fails_on = "output_writer: WRONG", any_order = true},
	{kind = .Wait, text = "output_reader: probes: joined after 0 records, the probes 0 to 7 in order, and a clean end: as it must", fails_on = "output_reader: WRONG", any_order = true},
	{kind = .Wait, text = "output_reader: probes: joined after 5 records, the probes 5 to 7 in order, and a clean end: as it must", fails_on = "output_reader: WRONG"},
	{kind = .Wait, text = "output_wiring: the refusals of Start and of its list, each with its status and its error record and the budget unchanged: as it must", fails_on = "output_wiring: WRONG"},
	{kind = .Wait, text = "output_writer: unended: one probe, then the stop with no end record: as it must", fails_on = "output_writer: WRONG", any_order = true},
	{kind = .Wait, text = "output_reader: unended: the joined record of 0, one probe, then the end word Writer_Stopped with the stop itself, done: as it must", fails_on = "output_reader: WRONG", any_order = true},
	{kind = .Wait, text = "output_reader: watched: the joined record and one probe, then this reader stops: as it must", fails_on = "output_reader: WRONG", any_order = true},
	{kind = .Wait, text = "output_writer: watched: the ring ended with the end word Reader_Stopped: as it must", fails_on = "output_writer: WRONG", any_order = true},
	{kind = .Wait, text = "output_wiring: the writer that stopped and the reader that stopped: as it must", fails_on = "output_wiring: WRONG"},
	// The record output log (src/md/features/log_facts.md, "The record
	// output `log`"): log_flood has a log budget of 0, so the kernel
	// refuses each of its calls, and its wired log holds each record. The
	// log of the kernel must hold no line of log_flood: its first line
	// before the line of output_wiring fails the step. A line of the
	// process starts with its name in brackets; the note of the kernel at
	// its stop, "kernel: log_flood: N lines were refused", is expected and
	// does not fail it. A WRONG line of
	// output_wiring ends this wait at the hang bound. No step waits for a
	// line of log_flood.
	{kind = .Wait, text = "wiring: wired the record output log of log_flood to its asker output_wiring, wiring ", fails_on = "output_wiring: WRONG"},
	// The asker reads the stop of log_flood before it writes its line, so
	// the stop of the root service comes first: the wait for it does not
	// move the place, and the line of the asker is looked for from there.
	{kind = .Wait, text = "root: log_flood stopped: itself, done", any_order = true},
	{kind = .Wait, text = "output_wiring: the log of log_flood kept its 605 records in order while the kernel refused its 602 calls; then this asker closed its end, and log_flood, which its log held, stopped with Done: as it must", fails_on = "[log_flood]"},
	{kind = .Wait, text = "output_writer: large: 8 rings, each ended with the end word Revoked: as it must", fails_on = "output_writer: WRONG"},
	{kind = .Wait, text = "output_wiring: 8 wirings, one past them refused with Wire and with a Start, each with its status and its error record and the budget unchanged, then the revocation of the grant wirings: as it must", fails_on = "output_wiring: WRONG"},
	// A side that writes its own words in its wiring ring: the root
	// service ends the wiring whose end it refused, drops a word for a
	// number of no wiring and a second answer of an end, one line each,
	// gives Side_Closed to the reader of an end that the side closed, and
	// refuses an end for a wiring ring that the side never reads with
	// Busy.
	{kind = .Wait, text = "wiring: output_side refused its end of the wiring ", fails_on = "output_wiring: WRONG", any_order = true},
	{kind = .Wait, text = "wiring: output_side wrote a word of its wiring ring that names no wiring of it: it is dropped, and each later one is counted until its stop", fails_on = "output_wiring: WRONG", any_order = true},
	{kind = .Wait, text = "output_side: refused the end of its start; for the end of a Wire, wrote Closed for a number of no wiring, then Taken, Taken again, one probe and Closed; it reads no more commands: as it must", fails_on = "output_side: WRONG", any_order = true},
	{kind = .Wait, text = "wiring: output_side wrote a word of its wiring ring for the wiring ", fails_on = "output_wiring: WRONG", any_order = true},
	{kind = .Wait, text = "output_wiring: the end that a side refused ended with Refused, the wiring that a side closed gave its probe then Side_Closed, and 32 ends filled the wiring ring that it does not read, then one more refused with Busy, its status and its error record and the budget unchanged: as it must", fails_on = "output_wiring: WRONG"},
	{kind = .Wait, text = "output_wiring: the wiring of this asker gave the joined record of 0 and the probe 0, after ", fails_on = "output_wiring: WRONG"},
	{kind = .Wait, text = "output_wiring: ok"},
	{kind = .Wait, text = "output_writer: asked: the ring ended with the end word Asker_Stopped: as it must", fails_on = "output_writer: WRONG"},
	// log.follow (src/md/features/log_facts.md, "The frequent tasks"): a
	// follower that falls behind reads one gap record of the records that
	// the kernel wrote over, where they were. The follower writes the
	// records that the kernel writes over itself, paced by the seconds of
	// its log budget, and writes its last line in a new second: the wait
	// for it never follows more lines than its budget of one second.
	{kind = .Type, text = "start(\"log_follower\")"},
	{kind = .Wait, text = "wiring: wired the record output 1 of log to its asker log_follower, wiring "},
	{kind = .Wait, text = "log_follower: log.follow gave ", fails_on = "log_follower: WRONG"},
	{kind = .Wait, text = "root: log_follower stopped: itself, done"},
	// The generic record inputs, merge and filter, through start lists
	// (src/md/features/module_outputs.md, "Generic record inputs and the
	// utility modules"): the refusals first, then a chain of
	// generic_source, merge and filter in one list, then a filter whose
	// condition names no field. Each process writes a few lines only.
	{kind = .Type, text = "start(\"generic_wiring\")"},
	{kind = .Wait, text = "generic_wiring: a second source of another record, a generic output with no fixed type, a record of no terms into a running generic input, a condition on no field and one source past the wirings of an asker: refused, each with its status and its error record and the budget unchanged: as it must", fails_on = "generic_wiring: WRONG"},
	{kind = .Wait, text = "generic_source: wrote 20 probes into left and into right, and ended both", fails_on = "generic_source: WRONG", any_order = true},
	{kind = .Wait, text = "generic_wiring: generic_source to merge to filter with mark = 1 to this asker, in one start list, after a refused Wire of Other into filter.source kept no type: the joined record of 0, the 20 probes of mark 1 of the two sides, each side in its order, then a clean end: as it must", fails_on = "generic_wiring: WRONG"},
	{kind = .Wait, text = "generic_wiring: filter with a condition on the field 0 ended kept at once with the error record of that field: as it must", fails_on = "generic_wiring: WRONG"},
	{kind = .Wait, text = "generic_wiring: ok, after 5 refusals"},
	{kind = .Wait, text = "root: generic_wiring stopped: itself, done", any_order = true},
	// The streams of the console (src/md/features/module_outputs.md, "The
	// console form"): the console starts output_counter and reads its
	// record output by its typed name. The refusals first, none of which
	// wires the stream; then first with a condition, + on two tables of
	// one record, and the draw of a stream that runs, which Escape ends.
	{kind = .Type, text = "start(\"output_counter\")"},
	{kind = .Wait, text = "output_counter: it writes one record of counts each 200 ms while a reader is wired, and waits for a reader"},
	{kind = .Type, text = "record_outputs(\"output_counter\")"},
	{kind = .Wait, text = "[console] 1 row of Record_Output"},
	// A name that no record output begins with: the completion would end a
	// prefix of `counts` into the name, and the line would run the stream.
	{kind = .Type, text = "output_counter.missing"},
	{kind = .Wait, text = "[console] error: output_counter declares no record output or record input missing; its record outputs are counts"},
	{kind = .Type, text = "sort(output_counter.counts, \"serial\")"},
	{kind = .Wait, text = "[console] error: sort takes a Table; a Stream has no end: first(s, n) or table(s) makes one"},
	{kind = .Type, text = "kept = output_counter.counts"},
	{kind = .Wait, text = "[console] error: a variable keeps no Stream: a Stream is a wiring, and a variable outlives its line; first(s, n) or table(s) makes a Table"},
	{kind = .Type, text = "output_counter.counts |> where(statut = 404)"},
	{kind = .Wait, text = "[console] error: where: the records Counted have no field statut; did you mean status? Their fields are serial, status"},
	{kind = .Type, text = "output_counter.counts |> where(status = 404) |> first(3)"},
	{kind = .Wait, text = "     8     404"},
	{kind = .Wait, text = "[console] 3 rows of Counted"},
	{kind = .Type, text = "first(output_counter.counts, 1) + help()"},
	{kind = .Wait, text = "[console] error: \"+\" joins two tables of one record: the left one has records Counted, the right one Command"},
	{kind = .Type, text = "first(output_counter.counts, 2) + first(output_counter.counts, 1)"},
	{kind = .Wait, text = "[console] 3 rows of Counted"},
	// A stream that runs: its joined record, then its rows as they come,
	// each at the right of a column as wide as its field can be.
	{kind = .Type, text = "output_counter.counts"},
	{kind = .Wait, text = "[console] joined after "},
	{kind = .Wait, text = "                 200"},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "console: Escape stops the line after "},
	{kind = .Wait, text = "[console] Escape closed the stream after "},
	{kind = .Wait, text = "output_counter: counts has no reader after "},
	// The counts of the writer, with the first compartment of a ring.
	{kind = .Type, text = "stream_counts(output_counter.counts)"},
	{kind = .Wait, text = "[console] Writer_Counts"},
	// A condition that no record passes: the writer still writes the
	// joined record with its next write, so the counts come.
	{kind = .Type, text = "stream_counts(where(output_counter.counts, status = 500))"},
	{kind = .Wait, text = "[console] Writer_Counts"},
	// columns with the names of the fields: a name that the record lacks
	// fails the line before any wiring; then the field that it keeps.
	{kind = .Type, text = "output_counter.counts |> columns(statut)"},
	{kind = .Wait, text = "[console] error: columns: the records Counted have no field statut; did you mean status? Their fields are serial, status"},
	{kind = .Type, text = "output_counter.counts |> columns(status) |> first(2)"},
	{kind = .Wait, text = "[console] 2 rows of Counted"},
	// A record input of a module that does not run, by its typed name: no
	// record to draw; and the refusals of wire and of a start with a list,
	// none of which starts a process.
	{kind = .Type, text = "output_count_reader.counts"},
	{kind = .Wait, text = "[console] error: output_count_reader.counts is a record input: it has no record to draw, and wire(from, to) names it"},
	{kind = .Type, text = "wire(output_counter.counts, output_counter.counts)"},
	{kind = .Wait, text = "[console] error: wire: argument 2 is Record_Input, not Stream(Counted)"},
	{kind = .Type, text = "wire(where(where(output_counter.counts, status = 404), serial > 0), output_count_reader.counts)"},
	{kind = .Wait, text = "[console] error: wire: a wiring takes one condition; the record stream output_counter.counts has 2"},
	{kind = .Type, text = "start(\"output_reader\", wire(output_counter.counts, output_count_reader.counts))"},
	{kind = .Wait, text = "[console] error: start: the row 1 wires output_counter to output_count_reader, and names no end of output_reader"},
	{kind = .Type, text = "start(\"output_count_reader\", first(output_counter.counts, 1))"},
	{kind = .Wait, text = "[console] error: start: the list is a Table of Wiring, as wire(from, to) gives it; this one is Table(Counted)"},
	// A row that repeats an earlier row: the console refuses the list
	// before it lends a handle.
	{kind = .Type, text = "start(\"output_count_reader\", wire(output_counter.counts, output_count_reader.counts) + wire(output_counter.counts, output_count_reader.counts))"},
	{kind = .Wait, text = "[console] error: start: the row 2 repeats the row 1 (output_counter.counts to output_count_reader.counts): a repeated row gives its reader each record twice"},
	// A record input of the count One wired twice, by two rows of two
	// conditions: the root service refuses the whole list, and starts
	// nothing.
	{kind = .Type, text = "start(\"output_count_reader\", wire(where(output_counter.counts, status = 404), output_count_reader.counts) + wire(output_counter.counts, output_count_reader.counts))"},
	{kind = .Wait, text = "[console] error: start: output_count_reader: "},
	// The start with its list: the writer writes into that ring only the
	// records of the status 404, and the reader takes the serials that jump.
	{kind = .Type, text = "start(\"output_count_reader\", wire(where(output_counter.counts, status = 404), output_count_reader.counts))"},
	{kind = .Wait, text = "output_count_reader: joined after ", fails_on = "output_count_reader: WRONG"},
	{kind = .Wait, text = "root: output_count_reader stopped: itself, done", any_order = true},
	// merge through the console: its generic record output has no record
	// before a list of this console fixed one; the list of its start
	// fixes it, with a generic record input that wire takes with no type
	// check; then merge.merged reads as the records of output_counter.
	{kind = .Type, text = "merge.merged"},
	{kind = .Wait, text = "[console] error: merge.merged is generic: it writes the record that the first wiring of the generic record input of merge fixed, and no list of a start of merge by this console fixed one"},
	{kind = .Type, text = "start(\"merge\", wire(where(output_counter.counts, status = 404), merge.sources))"},
	{kind = .Wait, text = "wiring: wired the record output 1 of output_counter to merge, wiring "},
	{kind = .Type, text = "merge.merged |> first(2)"},
	{kind = .Wait, text = "[console] 2 rows of Counted"},
	{kind = .Type, text = "stop(\"merge\")"},
	{kind = .Wait, text = "root: merge stopped: "},
	// A writer that writes a record that fails the condition of its
	// wiring: the console refuses it as a fault of the writer, with its
	// error record, and closes the record stream.
	{kind = .Type, text = "start(\"output_liar\")"},
	{kind = .Wait, text = "output_liar: it waits for a reader"},
	{kind = .Type, text = "output_liar.counts |> where(status = 404) |> first(1)"},
	{kind = .Wait, text = "output_liar: wrote a record of the status 200 into a ring whose wiring has a condition: as it must", fails_on = "output_liar: WRONG", any_order = true},
	{kind = .Wait, text = "[console] error: first: the writer of output_liar.counts wrote the record 0, which fails the condition of its wiring (status = 404); the console closed the record stream"},
	{kind = .Wait, text = "[console]   kind       Bad_Value"},
	{kind = .Type, text = "stop(\"output_liar\")"},
	{kind = .Wait, text = "root: output_liar stopped: a holder"},
	{kind = .Type, text = "stop(\"output_counter\")"},
	{kind = .Wait, text = "root: output_counter stopped: a holder"},
	// The refusals of the root service give an error record: the console
	// writes its sentence.
	// No window drew in a picture on the screen: each surface has two
	// pictures, and each Present of a process names the picture that the
	// compositor did not read. The compositor counts, for each window,
	// the Present records that named the picture that it already read.
	// The line gives the count of
	// the windows whose count is not 0. It is exact and has no time: the
	// counts cover each picture since the start of each window.
	{kind = .Type, text = "connect(\"compositor\")"},
	{kind = .Wait, text = "[console]   module     compositor"},
	{kind = .Type, text = "rows(compositor.windows()) - rows(where(compositor.windows(), pictures_drawn_again = 0))"},
	{kind = .Wait, text = "[console] 0"},
	// The screen showed each frame of the compositor whole: the compositor
	// wrote no frame into the screen page that the display showed. The
	// line gives the count of the rows of screen() whose count is not 0.
	{kind = .Type, text = "rows(compositor.screen()) - rows(where(compositor.screen(), frames_on_the_shown_page = 0))"},
	{kind = .Wait, text = "[console] 0"},
	{kind = .Type, text = "start(\"nothing\")"},
	{kind = .Wait, text = "[console] error: root.Start: the argument name names none of the modules"},
	{kind = .Type, text = "stop(\"compositor\")"},
	{kind = .Wait, text = "[console] error: root.Stop: the argument name names a process of the system: it starts at boot, or it is a device service, and the call does not act on it"},
	{kind = .Type, text = "revoke(\"nobody\", \"log\")"},
	{kind = .Wait, text = "[console] error: root.Revoke: the argument name names none of the processes"},
	// A text is never cut in silence. The ring of the root service holds a
	// name of 31 bytes: the console refuses a longer one, which a cut could
	// make the name of another process.
	{kind = .Type, text = "start(\"a_name_longer_than_the_ring_holds_today\")"},
	{kind = .Wait, text = "[console] error: root.Start: the argument name has 39 bytes; it can have at most 31 bytes"},
	// A log text of 1500 bytes: the module in its call host logs it in
	// lines of 512 bytes, and its end is on the log. After the check of the
	// log: these lines take 9 records of the ring.
	{kind = .Type, text = "log_long(1500)"},
	{kind = .Wait, text = "01234 the end of the long text"},
	{kind = .Wait, text = "[console] 1500"},
	// An export that refuses: the console writes the sentence of its error
	// record from the description of the export.
	{kind = .Type, text = "load(\"tally\")"},
	{kind = .Wait, text = "[console]   module     tally"},
	{kind = .Wait, text = "[console]   commands   5"},
	{kind = .Wait, text = "[console]   call       direct"},
	{kind = .Type, text = "add(1, \"a note of forty bytes, four more than 36\")"},
	{kind = .Wait, text = "the argument note has 40 bytes; it can have at most 36 bytes"},
	{kind = .Type, text = "add(-6, \"below zero\")"},
	{kind = .Wait, text = "the argument amount has -6; it must have at least 0"},
	{kind = .Type, text = "unload(\"tally\")"},
	{kind = .Wait, text = "[console]   module    tally"},
	{kind = .Wait, text = "[console]   commands  5"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	{kind = .Launch, text = "paint"},
	{kind = .Wait, text = "compositor: surface paint"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "paint.line(0, 0, 10, 10, 16)"},
	{kind = .Wait, text = "error: paint.line: the argument color has the value 16, which the call refuses; it takes at most 15"},
	// A text below the last row of the picture, and a glider at a negative
	// column: each is refused with its record, and draws nothing. The
	// picture of a new window is 640 x 352.
	{kind = .Type, text = "paint.write(0, 352, \"below the picture\", 0)"},
	{kind = .Wait, text = "error: paint.write: the argument y has the value 352, which the call refuses; it takes at most 351"},
	{kind = .Type, text = "life.glider(-1, 10)"},
	{kind = .Wait, text = "error: life.glider: the argument column has -1; it must have at least 0"},
	{kind = .Type, text = "stop(\"paint\")"},
	{kind = .Wait, text = "root: paint stopped"},
	// (After the check of the log: these lines do not push the boot
	// records out of the log.)
	{kind = .Type, text = "load(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   12"},
	{kind = .Wait, text = "[console]   call       direct"},
	// A table goes into a direct call: the export reads and changes the
	// memory of the variable, with no copy. A table from where() goes in;
	// a table from columns() has another record, and the console refuses it.
	{kind = .Type, text = "clear()"},
	{kind = .Type, text = "t = readings(4)"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 100"},
	{kind = .Type, text = "scale_values(t, 7)"},
	{kind = .Type, text = "t"},
	{kind = .Wait, text = "4 rows of Reading"},
	{kind = .Type, text = "sum_values(where(t, sensor = 2))"},
	{kind = .Wait, text = "[console] 210"},
	{kind = .Type, text = "sum_values(columns(t, sensor, value))"},
	{kind = .Wait, text = "[console] error: sum_values: argument 1 is Table(Reading, Read), not Table(Reading)"},
	{kind = .Shot, text = "table_argument"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  12"},
	{kind = .Wait, text = "[console]   memory    left the console"},
	// A table goes into an isolated call: the rows go into the call
	// region, and the rows of a Change table come back.
	{kind = .Type, text = "isolate(\"sample\")"},
	{kind = .Wait, text = "[console]   module     sample"},
	{kind = .Wait, text = "[console]   commands   12"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Type, text = "t = readings(4)"},
	{kind = .Type, text = "scale_values(t, 3)"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 300"},
	// An export that fails after it changed rows of a Change table: only
	// its error record and its table of error details come back, so the
	// variable keeps its rows. scale_values_up_to changes the readings 1
	// and 2 (30 and 60, by 3, stay under 200), then refuses the reading 3
	// (90 by 3 is 270): with the changes, the sum would be 480.
	{kind = .Type, text = "scale_values_up_to(t, 3, 200)"},
	{kind = .Wait, text = "[console] error: scale_values_up_to: the argument factor has the value 3, which the call refuses; it takes at most 2"},
	{kind = .Type, text = "sum_values(t)"},
	{kind = .Wait, text = "[console] 300"},
	// An export with nine parameters in an isolated call: the receiver
	// decodes ten arguments and puts four of them on the stack.
	{kind = .Type, text = "weigh(1, 2, 3, 4, 5, 6, 7, 8, \"A\")"},
	{kind = .Wait, text = "[console] 269"},
	{kind = .Type, text = "weigh(1, 2, 3, 4, 5, 6, 7, 8, \"a label of twenty bytes\")"},
	{kind = .Wait, text = "[console] error: weigh: the argument label has 23 bytes"},
	{kind = .Type, text = "unload(\"sample\")"},
	{kind = .Wait, text = "[console]   module    sample"},
	{kind = .Wait, text = "[console]   commands  12"},
	{kind = .Wait, text = "[console]   memory    its sandboxed process stopped"},
	// The signature of an export with a table and bytes: one form in the
	// manual, the console and the errors.
	{kind = .Type, text = "start(\"manual\")"},
	{kind = .Wait, text = "root: started manual"},
	{kind = .Wait, text = "manual: ok, "},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "manual.signature(\"sample\", 11)"},
	{kind = .Wait, text = "[console] sum_words(words: Table(Word, Change), text: Bytes(Read)) -> Integer"},
	{kind = .Type, text = "manual.show(\"sample\")"},
	{kind = .Wait, text = "manual: sample: a module with an entry, "},
	{kind = .Front, text = "manual"},
	{kind = .Key, text = "pgdn"},
	{kind = .Key, text = "pgdn"},
	{kind = .Shot, text = "manual_tables"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"manual\")"},
	{kind = .Wait, text = "root: manual stopped"},
	// The scroll bar of the console, with the pointer: the console holds
	// more lines than its window shows. A press on the arrow button at the
	// top moves the view up by one line; a press on the one at the bottom
	// brings it back to the last lines. The picture has the pointer over
	// that button: the bar is lit, the button hot. Then the thumb, which
	// ends over the bottom button, is dragged to the top of the track: the
	// view starts at the oldest line.
	{kind = .Click_Element, text = "console", element = "scroll bar arrow up"},
	{kind = .Wait, text = "terminal: a press on the arrow up of the scroll bar of console: the view starts at line "},
	{kind = .Click_Element, text = "console", element = "scroll bar arrow down"},
	{kind = .Wait, text = "terminal: a press on the arrow down of the scroll bar of console: the view follows the last lines"},
	// The wheel over the lines moves the view: one notch up holds it
	// three lines above the end, one notch down brings it back to the
	// last lines.
	{kind = .Wheel, text = "console", element = "scroll bar view", notches = -NOTCH_TOWARD_THE_END},
	{kind = .Wait, text = "terminal: the wheel moves the view of console: the view starts at line "},
	{kind = .Wheel, text = "console", element = "scroll bar view", notches = NOTCH_TOWARD_THE_END},
	{kind = .Wait, text = "terminal: the wheel moves the view of console: the view follows the last lines"},
	// Over the scroll bar the pointer is the arrow, and over the text of
	// the terminal the text shape: the terminal asks for each one when the
	// pointer crosses the edge of the bar. The picture has the arrow.
	{kind = .Point, inside_window = "console", x = 2 + 200, y = 24 + 200, text = "text"},
	{kind = .Point, inside_window = "console", x = 2 + CONSOLE_SCROLL_BAR_X, y = 24 + CONSOLE_SCROLL_BAR_ARROW_DOWN_Y, text = "arrow"},
	{kind = .Wait, text = "compositor: console asks for the pointer shape arrow over its surface"},
	{kind = .Shot, text = "scroll_bar"},
	{kind = .Drag, inside_window = "console", x = CONSOLE_SCROLL_BAR_X, y = CONSOLE_SCROLL_BAR_THUMB_END_Y, to_x = CONSOLE_SCROLL_BAR_X, to_y = CONSOLE_SCROLL_BAR_TRACK_START_Y},
	{kind = .Wait, text = "terminal: a drag of the thumb of the scroll bar of console: the view starts at line "},
	{kind = .Type, text = "clear()"},
	// The terminal: a process gives text as records with a style, in a ring
	// of 4096 records. The terminal reads them in one thread and draws in
	// another: the display does not slow the process.
	// The root service starts the process and its terminal: the terminal
	// starts no process, and has nothing of the start grant set of the process.
	// flood is a test module: the start menu has no line of it.
	{kind = .Type, text = "start(\"flood\")"},
	{kind = .Wait, text = "flood: ok", any_order = true},
	{kind = .Wait, text = "terminal: ok, flood writes in a ring of 4096 records", any_order = true},
	{kind = .Wait, text = "root: started flood, with a terminal"},
	{kind = .Move, text = "flood", to_x = 160, to_y = 104}, // The place of the pictures and of the clicks below.
	{kind = .Wait, text = "terminal: flood wrote "},
	{kind = .Shot, text = "terminal"},
	// The terminal keeps Page Up and Page Down: its view stays, the process continues.
	{kind = .Key, text = "pgup"},
	{kind = .Wait, text = "terminal: the view stays at line "},
	{kind = .Key, text = "pgup"},
	{kind = .Shot, text = "terminal_held"},
	// Each other key is a record for the process. flood stops its lines at
	// the key Space, and shows it in the line that it changes.
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "terminal: the first key goes to flood", any_order = true},
	{kind = .Wait, text = "flood: Space: no more lines after "},
	{kind = .Shot, text = "terminal_keys"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "flood: Space: the lines continue"},
	// The process stops: its terminal stays, with what the process wrote.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"flood\")"},
	{kind = .Wait, text = "terminal: flood stopped: a holder, after "},
	{kind = .Click, x = 940, y = 400}, // A part of the window that the console does not cover.
	{kind = .Shot, text = "terminal_stopped"},
	// The scenario closes the window: the terminal stops.
	{kind = .Close, text = "flood"},
	{kind = .Wait, text = "root: terminal stopped"},
	// The words of a record of the terminal ring that name no record:
	// None, one past the last kind, the largest word. The terminal sends no
	// answer on the ring: it writes one line at the first word, and the
	// count when the process stops. The process stops after its check.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "start(\"hostile_terminal\")"},
	{kind = .Wait, text = "root: started hostile_terminal, with a terminal", any_order = true},
	{kind = .Wait, text = "terminal: hostile_terminal sent a record of the kind 0, which names no record: it is refused", any_order = true},
	{kind = .Wait, text = "hostile_terminal: the terminal read the kind words 0, 9 and 4294967295, and the line after them: as it must"},
	{kind = .Wait, text = "terminal: hostile_terminal stopped after 3 records whose kind names no record"},
	{kind = .Close, text = "hostile_terminal"},
	{kind = .Wait, text = "root: terminal stopped"},
	// The block service: the root service gives one virtio disk to one
	// block service, and the block ring to its client. The device reads and
	// writes the memory of the client.
	{kind = .Launch, text = "disk"},
	// The start of a device service is a log fact with the place of its
	// device: the step Fact reads the field that names the service on the
	// serial port, the step Record the sentence with the place through
	// log.records and log.fact_records.
	{kind = .Fact, process = "root", fact = "root.Device_Service_Started", condition = "service = \"block\"", any_order = true},
	// The surface of the window of disk is a log fact of the compositor:
	// the step reads the field that names the window.
	{kind = .Fact, process = "compositor", fact = "compositor.Surface_Made", condition = "window = \"disk\"", any_order = true},
	{kind = .Record, process = "root", level = "Info", text = "root: started block for the device at the place 17 of the bus"},
	{kind = .Record, process = "block", level = "Info", text = "block: ok, 8192 blocks of 4096 bytes, a queue of ", any_order = true},
	{kind = .Wait, text = "disk: ok, the disk has 8192 blocks"},
	{kind = .Wait, text = "disk: read, 1 block in each request, 1 in flight: "},
	{kind = .Wait, text = "disk: read, 1 block in each request, 32 in flight: "},
	{kind = .Wait, text = "disk: write, 1 block in each request, 1 in flight: "},
	{kind = .Wait, text = "disk: write, 1 block in each request, 32 in flight: "},
	{kind = .Wait, text = "disk: read, 16 blocks in each request, 8 in flight: "},
	{kind = .Record, process = "disk", level = "Info", text = "disk: ok, 5 runs, 0 errors, write then read back: 0 wrong"},
	{kind = .Wait, text = "disk: a read of 2 blocks from the last block: kind Out_Of_Range, unit Blocks, operation 3, argument 1, value 8193, limit 8192, found 0"},
	// The words of a command record that name no command: None, one past
	// the last command, the largest word. The block service answers what
	// its border decided, and serves the next command.
	{kind = .Wait, text = "disk: the command word 0 of the block ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"},
	{kind = .Wait, text = "disk: the command word 7 of the block ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"},
	{kind = .Wait, text = "disk: the command word 4294967295 of the block ring: refused with Bad_Command and the record Unsupported of the word, and the next Info is served: as it must"},
	// The same three words on the ring of its window: the compositor
	// sends no answer there; it writes one line at the first word, and the
	// count when the window closes.
	{kind = .Wait, text = "compositor: a window sent the word 0, which names no command; the next ones are counted, and the count comes when the window closes", any_order = true},
	// The middle word is the first past the last display command, which
	// grows with the commands: the wait names the rest of the line.
	{kind = .Wait, text = "and 4294967295: the compositor read the three: as it must"},
	{kind = .Shot, text = "disk"},
	// The client stops: its block service stops, and the device stops
	// using memory.
	{kind = .Close, text = "disk"},
	{kind = .Fact, process = "compositor", fact = "compositor.Window_Closed_After_Refused_Commands", condition = "window = \"disk\"", any_order = true},
	{kind = .Wait, text = "compositor: window disk closed after 3 records whose word names no command"},
	{kind = .Record, process = "root", level = "Info", text = "root: disk stopped: a holder"},
	{kind = .Record, process = "root", level = "Info", text = "root: block stopped: a holder"},
	// The storage service runs since the boot (the boot pass of settings
	// needs it), with the block service of the data disk. The console has a
	// private store of 3 blocks, by its name; it acts for the principal, so it
	// also sees all the stores.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"storage\")"},
	{kind = .Record, process = "root", level = "Info", text = "root: connected console to the service storage"},
	{kind = .Type, text = "storage.write(0, \"greeting\", \"kept on the disk\")"},
	// The generation of this commit is the base: the console committed its
	// line history after each line before this one.
	{kind = .Wait, text = "> storage.write(0, \"greeting\", \"kept on the disk\")"},
	{kind = .Generation, text = "[console] "},
	{kind = .Type, text = "storage.read(0, \"greeting\")"},
	{kind = .Wait, text = "[console] kept on the disk"},
	// The limit of the store: one more object needs one more block: its one
	// block of data.
	{kind = .Type, text = "storage.write(0, \"second\", \"one block more\")"},
	{kind = .Wait, text = "[console] error: storage.write: the call needs 4 blocks in all, with no earlier version kept; the limit is 3 blocks"},
	// A change of the object at the limit: the version of its state before
	// does not fit, and the same commit thins it.
	// Each line commits the line history after it: the base and 1 after
	// the line of the base, 2 after the read, 3 after the refused write;
	// this write is the commit 4.
	{kind = .Type, text = "storage.write(0, \"greeting\", \"changed at the limit\")"},
	// The storage service writes its fact before the console writes the
	// result of the call: the step of the fact comes before that Wait.
	{kind = .Fact, process = "storage", fact = "storage_service.Store_At_Limit_Thinned_One_Version", condition = "store = \"console\"", any_order = true},
	{kind = .Wait, text = "[console] {generation+4}"},
	{kind = .Record, process = "storage", level = "Info", text = "storage: the store console is at its limit of 3 blocks: the commit of generation {generation+4} thinned 1 version, the oldest of the store first", any_order = true},
	// An error of a service is a record: the console writes it as a sentence.
	{kind = .Type, text = "storage.write(0, \"\", \"x\")"},
	{kind = .Wait, text = "[console] error: storage.write: the argument name is empty; it must have 1 to 64 bytes"},
	{kind = .Type, text = "storage.read(0, \"nothing\")"},
	{kind = .Wait, text = "[console] error: storage.read: the argument name: the store has no object with this name"},
	{kind = .Type, text = "storage.size(0, \"greeting\")"},
	{kind = .Wait, text = "[console] 20"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console: 1 objects, 0 trees, 0 versions, 3 of 3 blocks, 0 shared, 1 connection"},
	// The scenario lists the grant and revokes it: the store stays on the disk,
	// and the console cannot reach it.
	{kind = .Type, text = "grants(\"console\")"},
	{kind = .Wait, text = "[console] console  log                 held"},
	{kind = .Wait, text = "[console] console  machine             held"},
	{kind = .Wait, text = "[console] console  image               held"},
	{kind = .Wait, text = "[console] console  store               held"},
	{kind = .Wait, text = "[console] console  acts_for_principal  held"},
	{kind = .Type, text = "revoke(\"console\", \"store\")"},
	{kind = .Fact, process = "root", fact = "root.Grant_Revoked_Connections", condition = "holder = \"console\"", any_order = true},
	{kind = .Record, process = "root", level = "Info", text = "root: revoked the grant store of console, connections changed: 1"},
	{kind = .Type, text = "storage.write(0, \"greeting\", \"changed\")"},
	{kind = .Wait, text = "[console] error: storage.write: the caller has no grant for this: a private store"},
	{kind = .Type, text = "storage.stores()"},
	{kind = .Wait, text = "[console] console: 1 objects, 0 trees, 0 versions, 3 of 3 blocks, 0 shared, 0 connections"},
	{kind = .Type, text = "where(grants(\"console\"), state = \"lost\")"},
	// The grant palette was revoked before: the column has its width.
	{kind = .Wait, text = "[console] console  store    lost"},
	{kind = .Shot, text = "storage"},
	// The notes: each note is one object of the store of notes, and a
	// change is one commit when the keys pause or another note is shown: one
	// version for a line typed, not one for each key. The scenario waits for
	// the fact of each commit, never for a count of versions: a slow host
	// can split a line in two commits.
	{kind = .Launch, text = "notes"},
	// The store line comes from the store thread of notes, the surface line
	// from the compositor and the picture line from the window thread: the
	// system fixes no order between the three.
	{kind = .Wait, text = "notes: a new store: no note", any_order = true},
	{kind = .Wait, text = "compositor: surface notes", any_order = true},
	{kind = .Wait, text = "notes: ok, the first picture is presented"},
	{kind = .Keys, text = "versions"},
	{kind = .Wait, text = "notes: the note is \"versions\", 8 bytes, generation "},
	// Enter starts a second line: the title stays the first line. The
	// commit of the whole text is the base of the generations: no other
	// process commits until the restore below.
	{kind = .Key, text = "ret"},
	{kind = .Keys, text = "a second line"},
	{kind = .Generation, text = "notes: the note is \"versions\", 22 bytes, generation "},
	{kind = .Shot, text = "notes"},
	// The pane of the versions: the newest first; Down shows the one
	// before it, and Enter restores it in a new commit.
	{kind = .Key, text = "ctrl-h"},
	{kind = .Wait, text = "notes: the version 1 of "},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "notes: the version 2 of "},
	{kind = .Wait, text = ": \"versions\""},
	{kind = .Shot, text = "notes_versions"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "notes: restored the version of generation "},
	{kind = .Wait, text = "\", in the commit of generation {generation+1}"},
	// The exports of the versions, from the host: the remote service acts
	// for the principal, so it names the store of notes.
	// A place on the store of notes: the first place of the service, 1.
	{kind = .Call, text = "storage.open_store(\"notes\")", expected = "1"},
	{kind = .Call, text = "storage.versions(1, \"note_000001\")", expected = " rows of Version"},
	// The date of the machine, from the host, some minutes after its start:
	// it advanced with the host.
	{kind = .Call, text = "date.now()", expected = "Date{milliseconds = ", date_after = "milliseconds = "},
	{kind = .Call, text = "storage.version(1, \"note_000001\", {generation})", expected = "a second line"},
	{kind = .Call, text = "storage.compare(1, \"note_000001\", {generation}, {generation+1})", expected = "1 rows of Byte_Range"},
	// The generation 1 is the format of the disk: no object has it.
	{kind = .Call, text = "storage.version(1, \"note_000001\", 1)", outcome = .Failed, expected = "error: storage.version: the argument generation: the object has no version of the generation 1"},
	{kind = .Call, text = "storage.restore(1, \"note_000001\", {generation})", expected = "{generation+2}"},
	{kind = .Call, text = "storage.clone(1, \"note_000001\", \"copy\")", expected = "{generation+3}"},
	// A second note, and the first again.
	{kind = .Key, text = "ctrl-n"},
	{kind = .Wait, text = "notes: a new note; 2 notes"},
	{kind = .Keys, text = "groceries"},
	{kind = .Wait, text = "notes: the note is \"groceries\", 9 bytes, generation "},
	{kind = .Key, text = "ctrl-pgup"},
	{kind = .Wait, text = "notes: the note \"versions\" is shown"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "storage.stores()"},
	// The answer of stores() has one line for each store: with the store
	// of the line history, more than 256 bytes. The console prints a
	// result whole, at any length.
	{kind = .Wait, text = "[console] console.history: 1 objects, ", any_order = true},
	{kind = .Wait, text = "[console] notes: 3 objects, 0 trees, "},
	{kind = .Shot, text = "storage_versions"},
	// Alt+Tab: the window used before the console is notes; the release of
	// Alt brings it to the front, and a second Alt+Tab the console again.
	{kind = .Key, text = "alt-tab"},
	{kind = .Wait, text = "compositor: the window switcher lists "},
	{kind = .Wait, text = "compositor: the window switcher brought notes to the front"},
	{kind = .Key, text = "alt-tab"},
	{kind = .Wait, text = "compositor: the window switcher brought console to the front"},
	// The plates of the bar keep the order of opening: the first is the
	// console. A press on the plate of the window in front minimizes it, a
	// second press restores it.
	{kind = .Click, text = BAR_FIRST_PLATE},
	{kind = .Wait, text = "compositor: the plate of console minimized it"},
	{kind = .Click, text = BAR_FIRST_PLATE},
	{kind = .Wait, text = "compositor: the plate of console restored it"},
	// A result of 324 bytes on one line: before, the console cut it at 256
	// bytes in the terminal and at 192 bytes in the log, with no sign.
	{kind = .Type, text = "repeat(\"0123456789\", 30) + \"the end of a long result\""},
	{kind = .Wait, text = "01234567890123456789the end of a long result"},
	{kind = .Type, text = "stop(\"notes\")"},
	{kind = .Wait, text = "root: notes stopped"},
	// The editor: each group of changes is a commit, and undo walks the
	// versions of the store. The space after "first", the line end and
	// the space after "second" each end a group; Ctrl+Z commits the last
	// word, then restores the version before it; Ctrl+Y restores that
	// word again. Shift with Up then selects from the end of the text to
	// the end of the first line, which is shorter: 12 bytes, with the line
	// end, over 2 lines.
	{kind = .Type, text = "start(\"edit\")"},
	{kind = .Wait, text = "edit: a new store: an empty text", any_order = true},
	// The process can present its first picture before the compositor
	// writes its line of the surface: the two lines have no order.
	{kind = .Wait, text = "compositor: surface edit", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented", any_order = true},
	{kind = .Front, text = "edit"},
	{kind = .Keys, text = "first line"},
	{kind = .Key, text = "ret"},
	{kind = .Keys, text = "second line"},
	{kind = .Key, text = "ctrl-z"},
	{kind = .Wait, text = "edit: undo: the text has 18 bytes, the caret at byte 18, the version of generation "},
	{kind = .Key, text = "ctrl-y"},
	{kind = .Wait, text = "edit: redo: the text has 22 bytes, the caret at byte 22, the version of generation "},
	{kind = .Key, text = "shift-up"},
	{kind = .Wait, text = "edit: the selection has 12 bytes, from byte 10 to byte 22, over 2 lines"},
	{kind = .Shot, text = "edit"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"edit\")"},
	{kind = .Wait, text = "root: edit stopped"},
	// Errors that diagnose: each case makes an error for real, and the
	// window shows the sentence of its error record. The process fault
	// stops three calls deep: the tool names the functions of its stack
	// trace from the linked file of the module.
	{kind = .Launch, text = "errors"},
	// The window opens while the cases run: its line can come before or
	// after any case.
	{kind = .Wait, text = "compositor: surface errors", any_order = true},
	{kind = .Trace, text = "errors: stack of fault: ", names = "fault::three fault::two fault::one entry"},
	// The process errors names each frame from the debug image: the
	// procedure, the module and the source file. No step names a line
	// number: a line added to the source of fault moves it. The tool checks
	// the lines of fault::three against the source (trace.odin).
	{kind = .Wait, text = " in fault (" + FAULT_SOURCE_FILE + ":"},
	{kind = .Wait, text = "), fault::two + 0x"},
	{kind = .Wait, text = " in fault (" + FAULT_SOURCE_FILE + ":"},
	{kind = .Wait, text = "), fault::one + 0x"},
	{kind = .Wait, text = "errors: t the pages of another process (Inspect, Pages): Inspect: the argument index has the value 1, which the call refuses"},
	{kind = .Wait, text = "errors: u the pages past the end of the user half: Inspect: the argument address has the value 140737488351232, which the call refuses; it takes at most 140737488093184"},
	{kind = .Wait, text = "errors: v a wrapper: display.open of 0 by 100 pixels: display.open: the argument width has the value 0, which the call refuses; it takes at most 2048"},
	{kind = .Wait, text = "errors: w a wrapper: terminal.open with no terminal: terminal.open: the caller has no grant for this: a terminal"},
	{kind = .Wait, text = "errors: x a ring: root.Connect(\"storage\"), not callable: root.Connect: the caller has no grant for this: a connection to this service"},
	{kind = .Wait, text = "errors: y an export: tally.add, a note of 40 bytes: tally.add: the argument note has 40 bytes; it can have at most 36 bytes"},
	{kind = .Wait, text = "errors: ok, 25 cases, each with the expected error record"},
	// The kernel writes "?" for each byte of a control character and of a
	// broken sequence that a process gives to the operation Log itself:
	// escape, carriage return, U+0085 (two bytes), a lead byte with no
	// continuation. The line holds no byte that a terminal acts on.
	{kind = .Wait, text = "[errors] errors: a log line with control bytes: ?[2J????( as it must"},
	{kind = .Wait, text = "errors: a name of a process with an escape byte is refused: as it must"},
	// The table of error details of a kernel command: each wrong argument,
	// not only the first (src/md/features/kernel_error_details.md).
	{kind = .Wait, text = "errors: detail 1 of 2: Memory_Create: the argument budget, 0x0, names no handle of this process"},
	{kind = .Wait, text = "errors: detail 2 of 2: Memory_Create: the argument flags has the flags 0x100; the call knows the flags 0xf"},
	{kind = .Wait, text = "errors: a kernel command with two wrong arguments gives the two in its table of error details: as it must"},
	{kind = .Wait, text = "errors: a table of 1 place: 1 more error detail did not fit in the table of error details"},
	{kind = .Wait, text = "errors: a table smaller than its error details holds the first and counts each one: as it must"},
	{kind = .Wait, text = "errors: an accepted kernel command leaves its table of error details empty: as it must"},
	{kind = .Wait, text = "errors: Log with a level that names no member and one run past the bound gives the two in its table of error details: as it must", fails_on = "errors: WRONG: Log with two wrong arguments"},
	{kind = .Wait, text = "errors: an accepted Log with a table of error details leaves the table empty: as it must", fails_on = "errors: WRONG: an accepted Log"},
	// A full completion queue of the kernel ring loses no answer
	// (src/md/api/kernel_ring_completion_room.md).
	{kind = .Wait, text = "errors: a command past a full completion queue stays unrun in the kernel ring, and the entry does not wait: as it must"},
	{kind = .Wait, text = "errors: a kernel call on a kernel ring that holds records is refused with Busy, and its command does not run: as it must"},
	{kind = .Wait, text = "errors: a wait of the library on a kernel ring that holds records ends at once and pushes nothing: as it must"},
	{kind = .Wait, text = "errors: each answer of a full completion queue arrives once and in order, and the held command runs once after them: as it must"},
	{kind = .Wait, text = "errors: under contention: "},
	// A text longer than one row of log.records (one log record,
	// op.LOG_TEXT_CAPACITY bytes) by construction: no one row holds it, so
	// the step finds it only when it joins the rows.
	{kind = .Record, process = "errors", level = "Info", text = ERRORS_JOINED_LINE, any_order = true},
	{kind = .Wait, text = " handles; 0 records contradict their status, "},
	{kind = .Wait, text = "errors: a failed call of each family: a wrapper of support (terminal.open with no terminal): ", any_order = true},
	// The child of errors stops on a kernel ring that holds records
	// (src/md/api/kernel_ring_completion_room.md, "The stop of a process").
	{kind = .Wait, text = "errors: a stop on a kernel ring that holds records ends the process as a stop of itself, not a fault: as it must"},
	{kind = .Wait, text = "errors: the report of the slot of the child after its last handle closed gives its state None and its serial, and no fact of the child: as it must", fails_on = "errors: WRONG: the report of the free slot "},
	{kind = .Wait, text = " refused Memory_Create: "},
	{kind = .Wait, text = "errors: a kernel command and its table of error details: accepted with no table "},
	{kind = .Wait, text = "errors: a kernel operation that succeeds: "},
	{kind = .Front, text = "errors"},
	{kind = .Key, text = "b"},
	{kind = .Wait, text = "errors: case b again: Memory_Size: the argument memory, handle "},
	{kind = .Wait, text = " was revoked"},
	{kind = .Shot, text = "errors"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "errors: the window shows the page 2 of the cases"},
	{kind = .Shot, text = "errors_families"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "errors: the window shows the page 1 of the cases"},
	// A developer tool (docs/TOOLS.md): the memory and the execution of one
	// process, from the reports of the kernel. errors still holds the
	// process fault that stopped: its stop report stays.
	// The machine grant of monitor was revoked above: a new monitor has it
	// again, so that the test compares two tools on two reports.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"monitor\")"},
	{kind = .Record, process = "root", level = "Info", text = "root: monitor stopped: a holder"},
	{kind = .Type, text = "start(\"monitor\")"},
	{kind = .Record, process = "monitor", level = "Info", text = "monitor: ok"},
	{kind = .Launch, text = "inspect"},
	{kind = .Wait, text = "inspect: ok, "},
	{kind = .Type, text = "threads"},
	{kind = .Wait, text = "inspect: threads: "},
	{kind = .Wait, text = "inspect: one sample of threads took "},
	{kind = .Agree, text = "threads"},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Type, text = "console"},
	{kind = .Wait, text = "inspect: console: "},
	{kind = .Agree, text = "console"},
	// The whole list again, with console chosen.
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Wait, text = "inspect: the list shows all "},
	{kind = .Shot, text = "inspect"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "inspect: the sample is frozen"},
	{kind = .Key, text = "spc"},
	{kind = .Wait, text = "inspect: the sample is live"},
	// A click on the list: "rk" keeps workers and network; the click on the
	// row of network chooses it. The window writes the line of the choice
	// before it draws the shorter list: the press waits for the new place
	// of the row.
	{kind = .Type, text = "rk"},
	{kind = .Wait, text = "inspect: workers: "},
	// An element line is a log fact of the window: the step reads the
	// field that names the window, and the press reads its rectangle.
	{kind = .Fact, process = "inspect", fact = "interface.Element_Placed", condition = "window = \"inspect\"", any_order = true},
	{kind = .Wait, text = "interface: inspect: the element network at "},
	{kind = .Click_Element, text = "inspect", element = "network"},
	{kind = .Wait, text = "inspect: network: "},
	{kind = .Key, text = "backspace"}, {kind = .Key, text = "backspace"},
	{kind = .Type, text = "fault"},
	// The stop is a fact, then one fact for each frame of the stack.
	{kind = .Wait, text = "inspect: fault stopped: page fault at 0x0"},
	{kind = .Wait, text = "inspect: fault, the frame 0 of the stack: fault::three + 0x"},
	{kind = .Wait, text = " in fault (" + FAULT_SOURCE_FILE + ":"},
	{kind = .Wait, text = "inspect: fault, the frame 1 of the stack: fault::two + 0x"},
	{kind = .Shot, text = "inspect_stopped"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "inspect: the bytes of the memory of inspect"},
	{kind = .Shot, text = "inspect_hex"},
	{kind = .Key, text = "tab"},
	// The same facts as tables, from the host.
	{kind = .Call, text = "inspect.mappings(\"console\")", expected = " rows of Mapping"},
	{kind = .Call, text = "inspect.threads(\"threads\")", expected = " rows of Thread"},
	{kind = .Call, text = "inspect.modules(\"console\")", expected = "console "},
	{kind = .Call, text = "inspect.mappings(\"nothing\")", outcome = .Failed, expected = "error: inspect.mappings: the argument process names none of the processes"},
	// A table from the host: rows of field values go into the call region
	// of the monitor. A Change table is refused by the tool: its rows would
	// not come back. The service sample is not reachable from the network
	// (the row of remote in start_grant_sets).
	{kind = .Call, text = "monitor.counts_named([(\"processes\"), (\"processors\")])", expected = "2 rows of Count"},
	{kind = .Call, text = "monitor.counts_named([(\"processes\"), (\"nothing\")])", outcome = .Failed, expected = "names nothing that exists"},
	// The table of error details: each row that names nothing, not only the first.
	{kind = .Call, text = "monitor.counts_named([(\"nothing\"), (\"processes\"), (\"none\")])", outcome = .Failed, expected = "detail 2 of 2: monitor.counts_named: row 3 of the argument names"},
	{kind = .Call, text = "sample.scale_values([(0, 0, 10, 10, 10)], 2)", outcome = .Wrong, expected = "error: the parameter readings of sample.scale_values is Table(Reading, Change): a call from the host gives tables to read only"},
	{kind = .Call, text = "sample.sum_values([(0, 0, 10, 10, 10)])", outcome = .Refused, expected = "no grant"},
	{kind = .Close, text = "inspect"},
	{kind = .Close, text = "errors"},
	{kind = .Record, process = "root", level = "Info", text = "root: errors stopped: a holder"},
	// The interface package: each element live, the draw table of the last
	// frame, the damage by difference. The keyboard is a first path: Tab
	// moves the focus, Enter presses, the arrows move the choice.
	{kind = .Launch, text = "interface_elements"},
	{kind = .Wait, text = "compositor: surface interface_elements", any_order = true},
	{kind = .Wait, text = "interface_elements: nothing changed: "},
	{kind = .Wait, text = "interface_elements: one number changed: "},
	{kind = .Wait, text = "interface_elements: everything moved: "},
	{kind = .Wait, text = "interface_elements: one whole frame, built and drawn (the least of 20): the font of the cells "},
	{kind = .Wait, text = "interface_elements: ok, the whole frame drawn in "},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "interface_elements: the button was pressed 1 times"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "interface_elements: the list chooses clock"},
	{kind = .Key, text = "tab"},
	{kind = .Keys, text = "hello"},
	{kind = .Wait, text = "interface_elements: the text is \"hello\""},
	{kind = .Shot, text = "interface_elements"},
	// The action bar: each item of the window stands in its row, with its
	// keycaps, since the first frame. A press on an item runs its key:
	// Shift+Tab takes the focus back to the list, and Up on the list
	// chooses the line before.
	{kind = .Shot, text = "action_bar"},
	// The clipboard (src/md/features/clipboard.md): Control+C copies the
	// text "hello" of the field that has the focus in interface_elements,
	// and Control+V puts it in the line of the console as typed
	// characters. The compositor takes both keys: no process sees them.
	// A process can write its line before the compositor writes its own:
	// the first wait of each key leaves the place of the log as it was.
	{kind = .Key, text = "ctrl-c"},
	{kind = .Wait, text = "compositor: the copy key goes to interface_elements", any_order = true},
	// The process sends its copy, then writes its line; the compositor can
	// take the copy and write its own line between the two.
	{kind = .Wait, text = "display: interface_elements: a copy of 5 bytes of text", any_order = true},
	{kind = .Wait, text = "compositor: a copy of 5 bytes of text from interface_elements"},
	{kind = .Front, text = "console"},
	{kind = .Key, text = "ctrl-v"},
	{kind = .Wait, text = "compositor: a paste of 5 bytes of text from interface_elements goes to console", any_order = true},
	{kind = .Wait, text = "display: console: a paste of 5 bytes of text"},
	{kind = .Wait, text = "terminal: a paste of 5 characters goes to console", any_order = true},
	// The console gave the terminal its line with the paste: the terminal
	// says that a picture is due, and the picture waits for it.
	{kind = .Wait, text = "console: the line shows \"hello\" after a paste"},
	{kind = .Shot, text = "clipboard_paste"},
	// The pasted characters leave the line of the console for the steps
	// that type in it later.
	{kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"},
	{kind = .Wait, text = "console: the line is empty again after a paste"},
	{kind = .Click_Element, text = "interface_elements", element = "element before"},
	{kind = .Click_Element, text = "interface_elements", element = "line before"},
	{kind = .Wait, text = "interface_elements: the list chooses boot"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "interface_elements: the damage is shown"},
	{kind = .Shot, text = "interface_damage"},
	// The wheel over the list moves its view by three lines, and the
	// choice follows the view: from clock, in the view of three lines that
	// starts at boot, to compositor, the last line of the view that starts
	// at the fourth name, and the last of the six names.
	{kind = .Wheel, text = "interface_elements", element = "list", notches = NOTCH_TOWARD_THE_END},
	{kind = .Wait, text = "interface_elements: the list chooses compositor"},
	{kind = .Close, text = "interface_elements"},
	{kind = .Wait, text = "root: interface_elements stopped"},
	// The vector font of the system (docs/FONTS.md): the seven candidates,
	// each drawn through the face of the cells of a font set of the
	// process, beside Spleen 8x16.
	{kind = .Launch, text = "vector_glyphs"},
	{kind = .Wait, text = "vector_glyphs: one glyph from its outline, in fixed point"},
	{kind = .Wait, text = "vector_glyphs: ok, "},
	{kind = .Shot, text = "font_candidates"},
	{kind = .Close, text = "vector_glyphs"},
	{kind = .Wait, text = "root: vector_glyphs stopped"},
	// The interface font (docs/FONTS.md, section 12): B612 placed by
	// src/library/modus/text_rendering and drawn by graphics.text_proportional.
	// Its Greek letters are past the glyph cache: the process draws them
	// from B612, the box-drawing characters from Paper Mono, the second
	// font of the chain, and ƀ, Ѡ and Ԁ, which no font of the system has,
	// draw the replacement glyph
	// (docs/FONTS.md, "13. Glyphs past the glyph cache"). The lines come
	// after the first frame; the picture after them.
	{kind = .Launch, text = "interface_font"},
	{kind = .Wait, text = "interface_font: one line of "},
	{kind = .Wait, text = "interface_font: each Greek letter of B612 is drawn by this process: 47 letters: as it must", fails_on = "interface_font: not each Greek letter of B612 is drawn"},
	{kind = .Wait, text = "interface_font: the box-drawing characters come from paper_mono, the second font of the chain of the interface: 7 characters: as it must", fails_on = "interface_font: the fallback chain of the interface is wrong: "},
	{kind = .Wait, text = "interface_font: 3 characters that no font of the chain has draw the replacement glyph: as it must", fails_on = "interface_font: the fallback chain of the interface is wrong: "},
	{kind = .Wait, text = "interface_font: ok, ", any_order = true},
	{kind = .Shot, text = "interface_font"},
	{kind = .Close, text = "interface_font"},
	{kind = .Wait, text = "root: interface_font stopped", any_order = true},
	// The pointer pictures (docs/POINTERS.md): the shape that the compositor
	// chooses for what is under the pointer, and the shape that a process
	// asks for over its own surface. The window of pointers shows each
	// shape of the theme of the owner when the build has it (the default
	// development shell), then of the theme of the system, which the checks
	// of the flake and a release image hold alone. Its first button is the
	// theme of the system in both cases.
	{kind = .Launch, text = "pointers"},
	{kind = .Wait, text = "pointers: ok, ", any_order = true},
	{kind = .Wait, text = "compositor: surface pointers"},
	{kind = .Point, inside_window = "pointers", x = 100, y = 12, text = "move"}, // The title bar.
	{kind = .Point, inside_window = "pointers", x = -14, y = 12, text = "pointing_hand"}, // The close button.
	{kind = .Point, inside_window = "pointers", x = 1, y = 300, text = "arrow"}, // The left border.
	{kind = .Point, inside_window = "pointers", x = 2 + 208 + 60, y = 24 + 368 + 60, text = "wait"}, // The tile of wait (src/modules/demonstrations/pointers, tile_area(6)): the request of the process.
	{kind = .Wait, text = "compositor: pointers asks for the pointer shape wait over its surface"},
	{kind = .Shot, text = "pointers"},
	{kind = .Point, inside_window = "pointers", x = 2 + 16 + 60, y = 24 + 216 + 60, text = "arrow"}, // The tile of arrow.
	{kind = .Point, inside_window = "pointers", x = 2 + 592 + 60, y = 24 + 216 + 60, text = "move"}, // The tile of move.
	{kind = .Click, inside_window = "pointers", x = 100, y = 60}, // The first button: the theme of the system.
	{kind = .Wait, text = "pointers: the theme pointers_system is shown"},
	{kind = .Point, inside_window = "pointers", x = 2 + 784 + 60, y = 24 + 368 + 60, text = "help"}, // The tile of help, in the theme of the system.
	{kind = .Shot, text = "pointers_system"},
	{kind = .Close, text = "pointers"},
	{kind = .Wait, text = "root: pointers stopped"},
	{kind = .Point, x = 26, y = 14, text = "pointing_hand"}, // The button start in the bar.
	{kind = .Point, x = 600, y = 16, text = "arrow"}, // The bar.
	{kind = .Front, text = "console"},
	{kind = .Point, inside_window = "console", x = 200, y = 120, text = "text"}, // The surface of the terminal: its request.
	{kind = .Shot, text = "pointer_text"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Point, x = PALETTE_POINT_X, y = 120, text = "text"}, // The input band of the palette.
	{kind = .Point, x = PALETTE_POINT_X, y = 180, text = "pointing_hand"}, // The first entry of its list, under the heading of its group.
	{kind = .Point, x = PALETTE_POINT_X, y = 476, text = "arrow"}, // Its footer.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is closed by the key super"},
	// The settings of the system: the font, the order of the stripes, the
	// pointer theme and the grid fit change while the processes run; each
	// window draws again, with no code of its own for it. Each change is
	// kept in the private store of settings.
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us"},
	// The process settings is the one writer of the settings page: a
	// second start raises the window that runs, and starts no process. A
	// second surface settings fails the step.
	{kind = .Launch, text = "settings"},
	// The root line and the compositor line come from two processes: the
	// system fixes no order between them.
	{kind = .Wait, text = "root: the start of settings raises the window of settings that runs", any_order = true, fails_on = "compositor: surface settings"},
	{kind = .Wait, text = "compositor: the root service raised the window settings in place of a second process settings", fails_on = "compositor: surface settings"},
	// A restart at once: the console stops settings, and the palette starts
	// it again at once, in the session of the desktop. The new process gets
	// its private store: a change by a call of the host, then one that the
	// console types, is kept, then the page changes. A process with no store
	// writes "settings: no private store".
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"settings\")"},
	{kind = .Wait, text = "root: settings stopped"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "settings"},
	{kind = .Wait, text = " for \"settings\": settings (module)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts settings"},
	{kind = .Wait, text = "settings: ok, font vector", fails_on = "settings: no private store"},
	{kind = .Front, text = "console"},
	{kind = .Call, text = "settings.set(appearance = .light)", expected = "1"},
	{kind = .Wait, text = "settings: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance light, scale 1.25; kept in the store"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance light, "},
	{kind = .Type, text = "settings.set(appearance = .auto)"},
	{kind = .Wait, text = "settings: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; kept in the store"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, "},
	// A click on a value of the window applies it, as the press of a
	// principal does: the compositor tells each window the new value, and
	// settings draws with it. A console call proves the export, not the
	// button, so each value here is a press on its button, at the place
	// that the window drew it at the scale 1.25. The window draws each
	// element at the scale of its surface, so a press reaches the element
	// that the screen shows there: a press on "Light" that reached another
	// button sets no light appearance. At 1.375 the scale goes back with the
	// keys, as a principal with no pointer does: the press gave the stop
	// 137.5 % the focus, Shift+Tab moves it to the stop 125 %, and Enter
	// presses it. No step presses at 1.375: the places of the tool are at
	// 1.25 (scale_places.odin).
	{kind = .Click_Element, text = "settings", element = "Spleen 8x16"},
	{kind = .Wait, text = "compositor: the settings changed: font spleen, ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font spleen, "},
	{kind = .Click_Element, text = "settings", element = "Vector"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font vector, "},
	{kind = .Click_Element, text = "settings", element = "Light"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance light, ", any_order = true},
	{kind = .Wait, text = "interface: settings: a frame in the light appearance"},
	{kind = .Click_Element, text = "settings", element = "Auto"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, ", any_order = true},
	{kind = .Click_Element, text = "settings", element = "137.5 %"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.375; ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.375"},
	{kind = .Key, text = "shift-tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25"},
	{kind = .Front, text = "monitor"},
	{kind = .Move, text = "monitor", to_x = 8, to_y = 408},
	{kind = .Front, text = "settings"},
	{kind = .Move, text = "settings", to_x = 456, to_y = 40},
	{kind = .Shot, text = "font_vector"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   commands   13"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Type, text = "settings.set(font = .spleen)"},
	{kind = .Wait, text = "compositor: the settings changed: font spleen, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; ", any_order = true},
	// The interface text of the console follows the setting: Spleen cells.
	// The terminal reads the setting at each turn of its loop, so its line
	// can come before the line of settings: this wait does not move the mark.
	{kind = .Wait, text = "terminal: console draws its interface text in the font of the cells", any_order = true},
	{kind = .Wait, text = "settings: drawn with font spleen, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us"},
	{kind = .Front, text = "settings"},
	{kind = .Shot, text = "font_spleen"},
	{kind = .Call, text = "settings.font()", expected = ".spleen"},
	// The console refuses a member that the enum of its parameter does not
	// have, before the call, with the members that it has: the call of the
	// tool checks its own members, so only this line shows the check of
	// the console.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "settings.set(font = .comic)"},
	{kind = .Wait, text = "[console] error: settings.set: Font has no member .comic; its members are .vector, .spleen", fails_on = "settings: font "},
	{kind = .Front, text = "settings"},
	{kind = .Call, text = "settings.set(font = .vector)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; ", any_order = true},
	{kind = .Wait, text = "terminal: console draws its interface text in the interface font", any_order = true},
	{kind = .Call, text = "settings.set(grid_fit = .off)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit off, keyboard layout us, appearance auto, scale 1.25; ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit off, keyboard layout us"},
	{kind = .Shot, text = "font_without_grid_fit"},
	{kind = .Call, text = "settings.set(pointer_theme = .of_the_system)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme system, grid fit off, keyboard layout us, appearance auto, scale 1.25; "},
	{kind = .Point, inside_window = "settings", x = 100, y = 12, text = "move"}, // The title bar, in the theme of the system.
	{kind = .Call, text = "settings.set(subpixel_order = .blue_green_red)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order bgr, pointer theme system, grid fit off, keyboard layout us, appearance auto, scale 1.25; "},
	{kind = .Call, text = "settings.subpixel_order()", expected = ".blue_green_red"},
	// The refusals: a name that is no member, a member of another enum and
	// a parameter that the export does not have are refused before the
	// call; a call that gives no setting is refused by the export.
	{kind = .Call, text = "settings.set(font = .comic)", outcome = .Wrong, expected = "error: the parameter font of settings.set is the enum Font, which has no member comic: its members are .vector, .spleen"},
	{kind = .Call, text = "settings.set(font = .french)", outcome = .Wrong, expected = "which has no member french"},
	{kind = .Call, text = "settings.set(colour = .red)", outcome = .Wrong, expected = "error: settings.set has no parameter colour"},
	{kind = .Call, text = "settings.set()", outcome = .Failed, expected = "error: settings.set: the call names nothing that exists"},
	// Three settings in one call.
	{kind = .Call, text = "settings.set(subpixel_order = .red_green_blue, pointer_theme = .of_the_owner, grid_fit = .on)", expected = "1"},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us"},
	// The layout of the keyboard: with the layout of France, the key that
	// gives q in the layout of the United States gives a. The setting holds
	// from the next key, and the tool sets it from the host: a line typed
	// under the other layout would not be the line that the tool means.
	{kind = .Front, text = "console"},
	{kind = .Call, text = "settings.set(keyboard_layout = .french)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout french, appearance auto, scale 1.25; "},
	// A typed name opens the completion list: Escape closes it, so that
	// Enter runs the line and does not take a candidate.
	{kind = .Keys, text = "q"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > a"},
	// The keys of the layout of France give characters of the Latin-1
	// Supplement: the keys 3, 2, t, 2, 3 type "été", the line editor keeps
	// its UTF-8, and the log line holds the bytes C3 A9.
	{kind = .Keys, text = "32t23"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > \"été\""},
	{kind = .Wait, text = "[console] été"},
	// The dead key right of P: ^ then e gives ê; ^ then z gives ^ and z.
	// The text names the keys of a QWERTY keyboard: the key of w is the z
	// of the layout of France.
	{kind = .Keys, text = "3[e[w3"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] ê^z"},
	// AltGr, the right Alt key, gives the third level: the keys of 4, 5, 6,
	// the key right of 0, the key of =, 3, 0 and 8 give {[|]}#@\. AltGr
	// with the key of 2 is the dead tilde: the end quote after it gives ~
	// and the quote. The names are the keys of a QWERTY keyboard.
	{kind = .Keys, text = "3"},
	{kind = .Key, text = "alt_r-4"},
	{kind = .Key, text = "alt_r-5"},
	{kind = .Key, text = "alt_r-6"},
	{kind = .Key, text = "alt_r-minus"},
	{kind = .Key, text = "alt_r-equal"},
	{kind = .Key, text = "alt_r-3"},
	{kind = .Key, text = "alt_r-0"},
	{kind = .Key, text = "alt_r-8"},
	{kind = .Key, text = "alt_r-2"},
	{kind = .Keys, text = "3"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > \"{[|]}#@\\~\""},
	{kind = .Wait, text = "[console] {[|]}#@\\~"},
	// AltGr with e gives the euro sign, a character past the Latin-1
	// Supplement: the keys 3, Shift 5, space, AltGr e, 3 type "5 €". The
	// names are the keys of a QWERTY keyboard: "%" is Shift with the key
	// of 5.
	{kind = .Keys, text = "3% "},
	{kind = .Key, text = "alt_r-e"},
	{kind = .Keys, text = "3"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > \"5 €\""},
	{kind = .Wait, text = "[console] 5 €"},
	// Backspace removes a whole character: "étéx", Backspace two times,
	// gives "ét".
	{kind = .Keys, text = "32t2x"},
	{kind = .Key, text = "backspace"},
	{kind = .Key, text = "backspace"},
	{kind = .Keys, text = "3"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > \"ét\""},
	// The vector font draws é, ê, ^ and € from the glyph cache: no
	// replacement box in the console.
	{kind = .Shot, text = "keys_french"},
	{kind = .Call, text = "settings.set(keyboard_layout = .united_states)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; "},
	{kind = .Keys, text = "q"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > q"},
	// The appearance (src/md/features/appearance.md): the light one, then
	// the dark one, then auto. Each window draws once in the tokens of the
	// new appearance. The tool gave the machine a clock at 01:00 UTC
	// (machine_clock.odin), so auto gives the dark one; the step
	// Appearance_Auto checks the line by the rule over the date that it
	// names, and that date against the clock of the machine.
	{kind = .Call, text = "settings.set(appearance = .light)", expected = "1"},
	// Each window of a process takes each color from the tokens
	// (src/md/features/appearance.md, "The colors of the processes"). A
	// window writes one line at its first frame in the new appearance; a
	// window can read the page before the compositor writes its line, so
	// these waits do not move the place of the log.
	{kind = .Wait, text = "interface: monitor: a frame in the light appearance", any_order = true},
	{kind = .Wait, text = "interface: rings: a frame in the light appearance", any_order = true},
	{kind = .Wait, text = "interface: time_page: a frame in the light appearance", any_order = true},
	{kind = .Wait, text = "settings: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance light, scale 1.25; kept in the store"},
	{kind = .Wait, text = "settings: the appearance in force is light: the setting light"},
	{kind = .Wait, text = "compositor: the pointer form in use: light", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance light, scale 1.25; the appearance in force light; ", any_order = true},
	{kind = .Wait, text = "settings: drawn with font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance light"},
	{kind = .Point, x = 26, y = 14, text = "pointing_hand", form = "light"}, // The button start of the bar: the light form of the pointer.
	{kind = .Front, text = "settings"},
	{kind = .Shot, text = "desktop_light"},
	// The console in the light appearance: a record whose values have the
	// colors of their kinds, which the terminal chooses when it draws.
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"settings\")"},
	{kind = .Wait, text = "[console]   module     settings"},
	{kind = .Wait, text = "[console]   call       service"},
	{kind = .Shot, text = "console_light"},
	// Three windows whose colors were their own: each drew its frame in the
	// light appearance (the waits above), and the front window is whole on
	// the screen.
	{kind = .Front, text = "monitor"},
	{kind = .Shot, text = "monitor_light"},
	{kind = .Front, text = "rings"},
	{kind = .Shot, text = "rings_light"},
	{kind = .Front, text = "time_page"},
	{kind = .Shot, text = "time_page_light"},
	{kind = .Call, text = "settings.set(appearance = .dark)", expected = "1"},
	{kind = .Wait, text = "settings: the appearance in force is dark: the setting dark"},
	{kind = .Wait, text = "compositor: the pointer form in use: dark", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance dark, scale 1.25; the appearance in force dark; "},
	{kind = .Point, x = 26, y = 14, text = "pointing_hand", form = "dark"},
	{kind = .Call, text = "settings.set(appearance = .auto)", expected = "1"},
	{kind = .Appearance_Auto, text = "settings: the appearance in force is "},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; the appearance in force dark; "},
	{kind = .Call, text = "settings.appearance()", expected = ".auto"},
	{kind = .Front, text = "settings"},
	{kind = .Shot, text = "settings"},
	// The time zone (src/md/features/time_zone.md). The clock of the
	// machine is at 01:00 UTC: +08:00 moves its local time into the day.
	// The process date copies the zone into the date page; settings wakes
	// on the date page and gives the light appearance of auto in that zone,
	// and the bar shows the local time. The compositor can tell the windows
	// of the zone and of the appearance in one line or in two: the step
	// waits for the last state only.
	{kind = .Call, text = "settings.set_time_zone(\"+08:00\")", expected = "1"},
	{kind = .Wait, text = "settings: time zone +08:00; kept in the store"},
	{kind = .Bar_Local_Time, text = "compositor: the bar shows the local time ", expected = "+08:00", any_order = true},
	{kind = .Wait, text = "date: the time zone of the date page is +08:00, from the setting time_zone"},
	{kind = .Appearance_Auto, text = "settings: the appearance in force is ", expected = "28800"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; the appearance in force light; the time zone +08:00; "},
	{kind = .Call, text = "settings.time_zone()", expected = "+08:00"},
	{kind = .Call, text = "settings.set_time_zone(\"+8:00\")", outcome = .Failed, expected = "error: settings.set_time_zone: the argument zone "},
	// Back to UTC: the night again, before the next pictures.
	{kind = .Call, text = "settings.set_time_zone(\"+00:00\")", expected = "1"},
	{kind = .Wait, text = "settings: time zone +00:00; kept in the store"},
	{kind = .Bar_Local_Time, text = "compositor: the bar shows the local time ", expected = "+00:00", any_order = true},
	{kind = .Wait, text = "date: the time zone of the date page is +00:00, from the setting time_zone"},
	{kind = .Appearance_Auto, text = "settings: the appearance in force is ", expected = "0"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; the appearance in force dark; the time zone +00:00; "},
	// The scale (src/md/features/window_resize.md, "The rescale"): 1.375,
	// then 1.25 again, with windows open. Each window releases its surface,
	// makes the surface of the scale that the compositor names, and writes
	// its line when the compositor takes it; a refused surface fails the
	// step. A window can take the event before the compositor writes its
	// line, so the waits of the windows come first and do not move the
	// place of the log; each names its size and its scale, so a line of the
	// other scale never matches. The window draws again only when the
	// compositor shows its new surface, at the first Present of its serial:
	// the compositor line of each window. Then the line of the change: each
	// window shows a surface of the new scale, the console and the windows
	// not named here too, so a window that froze between two surfaces
	// fails the step. No step clicks at 1.375: the places of the tool are
	// at 1.25 (scale_places.odin).
	{kind = .Call, text = "settings.set(scale = .eleven_eighths)", expected = "1"},
	{kind = .Wait, text = "display: monitor: the surface of 715x880 at 11 eighths", any_order = true, fails_on = "the holder of the display refused the surface"},
	{kind = .Wait, text = "display: rings: the surface of 990x743 at 11 eighths", any_order = true, fails_on = "the holder of the display refused the surface"},
	{kind = .Wait, text = "display: settings: the surface of 770x946 at 11 eighths", any_order = true, fails_on = "the holder of the display refused the surface"},
	{kind = .Wait, text = "compositor: window monitor shows a surface of 715x880 at 11 eighths", any_order = true},
	{kind = .Wait, text = "compositor: window rings shows a surface of 990x743 at 11 eighths", any_order = true},
	{kind = .Wait, text = "compositor: window settings shows a surface of 770x946 at 11 eighths", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.375; "},
	{kind = .Wait, text = " windows shows a surface at 11 eighths", fails_on = "the holder of the display refused the surface"},
	{kind = .Shot, text = "desktop_at_1_375"},
	{kind = .Call, text = "settings.set(scale = .ten_eighths)", expected = "1"},
	{kind = .Wait, text = "display: monitor: the surface of 650x800 at 10 eighths", any_order = true, fails_on = "the holder of the display refused the surface"},
	{kind = .Wait, text = "display: rings: the surface of 900x675 at 10 eighths", any_order = true, fails_on = "the holder of the display refused the surface"},
	{kind = .Wait, text = "display: settings: the surface of 700x860 at 10 eighths", any_order = true, fails_on = "the holder of the display refused the surface"},
	{kind = .Wait, text = "compositor: window monitor shows a surface of 650x800 at 10 eighths", any_order = true},
	{kind = .Wait, text = "compositor: window rings shows a surface of 900x675 at 10 eighths", any_order = true},
	{kind = .Wait, text = "compositor: window settings shows a surface of 700x860 at 10 eighths", any_order = true},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; "},
	{kind = .Wait, text = " windows shows a surface at 10 eighths", fails_on = "the holder of the display refused the surface"},
	// The whole range with the windows open: 1, where a logical pixel is a
	// pixel of the screen; 1.5; and 2, where the logical screen is 960 x 540
	// and the larger windows keep their titles on the screen. The budget of
	// each window counts its pictures at 2, so no window declines a scale:
	// a decline fails the step. Then 1.25 again for the steps after.
	{kind = .Call, text = "settings.set(scale = .eight_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1; "},
	{kind = .Wait, text = " windows shows a surface at 8 eighths", fails_on = "declined the scale"},
	{kind = .Shot, text = "desktop_at_1"},
	{kind = .Call, text = "settings.set(scale = .twelve_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.5; "},
	{kind = .Wait, text = " windows shows a surface at 12 eighths", fails_on = "declined the scale"},
	{kind = .Shot, text = "desktop_at_1_5"},
	{kind = .Call, text = "settings.set(scale = .sixteen_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 2; "},
	{kind = .Wait, text = " windows shows a surface at 16 eighths", fails_on = "declined the scale"},
	{kind = .Shot, text = "desktop_at_2"},
	{kind = .Call, text = "settings.set(scale = .ten_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; "},
	{kind = .Wait, text = " windows shows a surface at 10 eighths", fails_on = "declined the scale"},
	// The fit at a new scale (src/md/features/window_resize.md, "The fit at
	// a new scale"): the console maximized at 1.25 is 1532 x 806 logical
	// pixels, whose surface at 2 its budget does not pay. The compositor
	// fits it into the work area of 2, 956 x 482, before it names the
	// scale, so the console shows a surface at 2 and declines nothing: a
	// decline fails the step. Back at 1.25 the fit grows it, so it comes
	// after the rescale: the console takes its maximized size again, and a
	// surface that its budget does not pay fails the step. Then the restore.
	{kind = .Front, text = "console"},
	{kind = .Key, text = "ctrl-shift-up"},
	{kind = .Wait, text = "compositor: window console maximized"},
	{kind = .Wait, text = "compositor: window console resized from "},
	{kind = .Call, text = "settings.set(scale = .sixteen_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 2; "},
	{kind = .Wait, text = " windows shows a surface at 16 eighths", fails_on = "declined the scale"},
	{kind = .Call, text = "settings.set(scale = .ten_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; "},
	// The console takes its maximized size before or after the last window
	// shows its surface at 1.25: the wait does not move the place.
	{kind = .Wait, text = "compositor: window console resized from 956x482 to 1532x806", any_order = true, fails_on = "no surface of"},
	{kind = .Wait, text = " windows shows a surface at 10 eighths", fails_on = "declined the scale"},
	{kind = .Key, text = "ctrl-shift-up"},
	{kind = .Wait, text = "compositor: window console restored"},
	{kind = .Wait, text = "compositor: window console resized from "},
	// A window that does not fit the work area (src/md/features/window_scroll.md):
	// settings opened at 2, where the work area is 960 x 508 under the bar.
	// Its surface of 560 x 688 gets at most the room under its frame, 482
	// lines, from its first surface; it lays out at that size, over its least
	// height, and scrolls its sections. Shift+Tab with no focus reaches its
	// last control, at the foot of its content: the view moves to show it.
	// The console and the palette take the keys, so no step presses at 2;
	// the palette starts settings in the session of the desktop, whose store
	// keeps the scale.
	{kind = .Call, text = "settings.set(scale = .sixteen_eighths)", expected = "1"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 2; "},
	{kind = .Wait, text = " windows shows a surface at 16 eighths", fails_on = "declined the scale"},
	// A fixed window whose layout is larger than its view: interface_elements
	// lays out at 816 x 560, past the room under its frame at 2. The
	// compositor clamps its surface, display takes the clamp, and the window
	// layer scrolls the layout in the view. PageDown, which no element takes
	// with no focus, moves the view by a page. Alt+Tab gives the keys back to
	// the console.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "interface_elements"},
	{kind = .Wait, text = " for \"interface_elements\": interface_elements (module)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts interface_elements"},
	// The compositor writes the new size at the release; the window writes
	// that its layout scrolls at its first frame after it: the system fixes
	// no order between the two.
	{kind = .Wait, text = "compositor: window interface_elements resized from 816x560 to 816x", any_order = true, fails_on = "no surface of"},
	{kind = .Wait, text = "interface: interface_elements: the layout of 816x560 scrolls in a view of 816x"},
	{kind = .Key, text = "pgdn"},
	{kind = .Wait, text = "interface: interface_elements: the keys move the view to "},
	{kind = .Key, text = "alt-tab"},
	{kind = .Wait, text = "compositor: the window switcher brought console to the front"},
	{kind = .Type, text = "stop(\"interface_elements\")"},
	{kind = .Wait, text = "root: interface_elements stopped"},
	{kind = .Type, text = "stop(\"settings\")"},
	{kind = .Wait, text = "root: settings stopped"},
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Keys, text = "settings"},
	{kind = .Wait, text = " for \"settings\": settings (module)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts settings"},
	{kind = .Wait, text = "compositor: window settings asked to draw at 560x482"},
	{kind = .Wait, text = "compositor: window settings resized from 560x688 to 560x482", fails_on = "no surface of"},
	{kind = .Key, text = "shift-tab"},
	{kind = .Wait, text = "settings: the focus moves the view to the line "},
	// Back to 1.25 with the keys of the window: Tab past the last control
	// comes back to the first, the stop 100 %; two more reach 125 %, and
	// Enter presses it. The view moves back up to show it.
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "settings: the focus moves the view to the line "},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "tab"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the settings changed: font vector, subpixel order rgb, pointer theme owner, grid fit on, keyboard layout us, appearance auto, scale 1.25; "},
	// The work area grows: settings gets back the size that it wants, which
	// the clamp at 2 cut, after it shows its surface at 1.25. It can come
	// before or after the last window shows its surface.
	{kind = .Wait, text = "compositor: window settings resized from 560x482 to 560x688", any_order = true, fails_on = "no surface of"},
	{kind = .Wait, text = " windows shows a surface at 10 eighths", fails_on = "declined the scale"},
	{kind = .Close, text = "settings"},
	{kind = .Wait, text = "root: settings stopped"},
	// Tables and bytes as parameters: one description, three ways to call
	// (docs/MODULE_CONTRACT.md). The process loads sample, starts a call
	// host of it, and connects to the service sample, which the root
	// service starts: the same module, the same arguments, the same answers.
	{kind = .Launch, text = "tables"},
	{kind = .Wait, text = "compositor: surface tables", any_order = true},
	{kind = .Wait, text = "tables: the ways: direct ready, call host ready, service ready"},
	{kind = .Wait, text = "tables: sum_values, direct call: "},
	{kind = .Wait, text = "tables: ok, 8 cases in 3 ways and 8 hostile cases"},
	{kind = .Shot, text = "tables"},
	{kind = .Close, text = "tables"},
	{kind = .Wait, text = "root: tables stopped"},
	// The interface package as a module for one process: the same frame
	// through the exports of interface_module and with the package compiled
	// in gives the same draw table.
	{kind = .Launch, text = "interface_through_module"},
	{kind = .Wait, text = "compositor: surface interface_through_module", any_order = true},
	{kind = .Wait, text = "interface_through_module: one frame of "},
	{kind = .Wait, text = " records asked, 16 drawn, the count of the full frame"},
	{kind = .Wait, text = "interface_through_module: ok, the two draw tables are equal"},
	// The proof of the same pixels in the machine: one frame drawn by the
	// package compiled in and by the drawing module, with the text settings
	// that each of the two loaded.
	{kind = .Wait, text = " text records, the same bytes: as it must"},
	{kind = .Shot, text = "interface_module"},
	{kind = .Close, text = "interface_through_module"},
	{kind = .Wait, text = "root: interface_through_module stopped"},
	{kind = .Front, text = "console"},
	// The line editor of the console. The console writes a log line only
	// when the input asks (Tab, a take): the lines that the scenario types
	// before this place add no record to the log.
	// Fuzzy completion: "mcnt" holds the letters of monitor.count in their
	// order. The list opens while the line is typed; Escape closes it, Tab
	// opens it again, and Enter takes the first name, with its '('.
	{kind = .Type, text = "clear()"},
	{kind = .Keys, text = "mcnt"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "console: the completion list opens by Tab: "},
	{kind = .Wait, text = " match \"mcnt\", the first is monitor.count; one ranking takes "},
	// The colors of the first row, from the log and not from a pixel:
	// monitor . count, then export of monitor ( name : Text ) -> Integer.
	{kind = .Wait, text = " keys; its first row has 13 runs of code"},
	// The picture shows the signatures of the rows in the colors of code,
	// and the edit line "> mcnt" plain: the name is still being typed.
	{kind = .Shot, text = "console_completion"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the completion gave the line monitor.count("},
	{kind = .Keys, text = "\"processors\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "> monitor.count(\"processors\")"},
	// The cursor inside the line: Home, Right, a character at the cursor,
	// End, Left, Delete, Backspace. The printed text shows each change in
	// its place: "acdf" becomes "abce".
	{kind = .Keys, text = "\"acdf\""},
	{kind = .Key, text = "home"},
	{kind = .Key, text = "right"},
	{kind = .Key, text = "right"},
	{kind = .Keys, text = "b"},
	{kind = .Key, text = "end"},
	{kind = .Key, text = "left"},
	{kind = .Key, text = "left"},
	{kind = .Key, text = "delete"},
	{kind = .Key, text = "backspace"},
	{kind = .Keys, text = "e"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] abce"},
	// The search of the history: Control-R opens it over the lines entered,
	// the newest first; "leng" keeps the lines that start with "length",
	// these two first (equal scores: the newest first). Control-R goes to
	// the older one, Control-S back to the newer one; Enter puts the chosen
	// line in the input, and a second Enter runs it.
	{kind = .Type, text = "length(\"first search line\")"},
	{kind = .Wait, text = "[console] 17"},
	{kind = .Type, text = "length(\"second\")"},
	{kind = .Wait, text = "[console] 6"},
	// The console writes the choice after each key of the search: the
	// picture waits for the last one.
	{kind = .Key, text = "ctrl-r"},
	{kind = .Keys, text = "leng"},
	{kind = .Wait, text = "console: the history search \"leng\" chooses the row 1 of "},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Wait, text = "console: the history search \"leng\" chooses the row 2 of "},
	{kind = .Key, text = "ctrl-s"},
	{kind = .Wait, text = "console: the history search \"leng\" chooses the row 1 of "},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Wait, text = "console: the history search \"leng\" chooses the row 2 of "},
	{kind = .Shot, text = "console_history_search"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the history search gave the line length(\"first search line\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "> length(\"first search line\")"},
	{kind = .Wait, text = "[console] 17"},
	// The builders (src/md/features/recipes.md, "The builder"), after the
	// calls of the storage service from the host: each build opens and closes
	// places, and those calls name the first place of a fresh table.
	// build_check registers recipes of the test builder builder_probe with
	// recipes, which starts the builder as a call host in its sandbox. The
	// refusals come first: each line of the probe says what the sandbox
	// refused, recipes then finds no place build, and build_check finds no
	// realisation. Then an output becomes a realisation, a second build takes
	// it, and the output is the input of the next build. The builder writes
	// before it returns and recipes logs before it answers, so the lines
	// come in this order.
	{kind = .Type, text = "start(\"build_check\")"},
	{kind = .Wait, text = "builder_probe: the input store refused a write: the error kind 20", fails_on = "builder_probe: WRONG"},
	{kind = .Wait, text = "builder_probe: the store out refused ..: the error kind 6", fails_on = "builder_probe: WRONG"},
	{kind = .Wait, text = "builder_probe: the store out refused a/b: the error kind 6", fails_on = "builder_probe: WRONG"},
	{kind = .Wait, text = "builder_probe: the store out refused an open of ..: the error kind 6", fails_on = "builder_probe: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of write_input was refused as asked: the refusal 17", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "builder_probe: the store out refused 17 shares: the error kind 20", fails_on = "builder_probe: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of share_out was refused as asked: the refusal 17", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "builder_probe: no handle past the context of a builder: the slots 7 to 13 are empty", fails_on = "builder_probe: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of network was refused as asked: the refusal 17", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of fail was refused as asked: the refusal 17", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of stop was refused as asked: the refusal 17", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "build_check: the build of a builder that no module is was refused as asked: the refusal 32", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of an input that no build gave was refused as asked: the refusal 33", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", seconds = BUILDER_HANG_STEP_SECONDS, fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the build of hang was refused as asked: the refusal 34", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: a builder made an output: the outcome 2", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "build_check: the second build took the realisation: the outcome 1", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "builder_probe: read the input made from the input store: 29 bytes"},
	{kind = .Wait, text = "recipes: after a build, an open of the place build gives the error kind 17", fails_on = "recipes: after a build, an open of the place build gives the error kind 0"},
	{kind = .Wait, text = "build_check: the output of a build was the input of the next: the outcome 2", fails_on = "build_check: WRONG"},
	{kind = .Wait, text = "build_check: each check of the builders passed", fails_on = "build_check: WRONG"},
	// The time of one key with the list open, for the names of this console
	// and for the worst case of 512 names of 128 bytes.
	{kind = .Type, text = "measure_completion()"},
	{kind = .Wait, text = "console: one key with the completion list: the collect "},
	{kind = .Wait, text = " names (the names of this console, the least of 20 batches of 10)"},
	{kind = .Wait, text = "console: one key with the completion list: the collect "},
	{kind = .Wait, text = " over 512 names (512 names of 128 bytes, the least of 20 batches of 10)"},
	// Each page is free or paid, after all the starts and stops of this test.
	{kind = .Type, text = "memory()"},
	{kind = .Wait, text = "free_no_budget_holds  0 pages"},
	{kind = .Type, text = "shutdown()"},
	{kind = .Wait, text = "kernel: the machine stops with code 0"},
}

// A binary of the tool runs the test part main only when it holds this file
// (test_parts.odin, test_part_scenario_register).
@(init)
main_test_part_register :: proc "contextless" () {
	test_part_scenario_register("main", main_tests_run)
}
