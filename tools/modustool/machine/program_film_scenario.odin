package machine

// The film of a program, the command `modustool film program`
// (docs/TOOLS.md, "The film"). It is the end of the chapter "Writing a
// program" of the tutorial, after the code of the module `plasma`
// (src/modules/demonstrations/plasma/main.odin), which the tutorial shows
// as it is typed; each hold with a text names the cue of a caption
// (docs/TOOLS.md, "The film cues").
//
// plasma is the smallest module of the system that draws a window: one
// file of about 90 lines, with its comments. The film shows that module,
// the one of the code, start in the system and run as a process.
//
// Before the film starts, the scenario waits for the desktop and brings
// the console to the front. Then the worker films:
//
//  1. the console;
//  2. start("plasma"): the root service starts the module, the module
//     opens its window and shows its first picture;
//  3. a drag of the title bar moves the window beside the console;
//  4. the row of plasma in the table of the processes;
//  5. stop("plasma"): the process stops and its window closes.
//
// The lines and the waits are those of the main scenario of the machine
// test (machine.odin): the film shows what the test checks.
@(rodata)
scenario_program_film := [?]Step {
	// The boot. The processes write in an order that the system does not fix.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped with code 0", any_order = true},
	// processes() reads the service monitor, which the start list does not
	// start: it starts before the film, out of the picture of the scenes.
	{kind = .Type, text = "start(\"monitor\")"},
	{kind = .Wait, text = "monitor: ok", any_order = true},
	{kind = .Front, text = "console"},
	// The pointer leaves the window: a press on the background, in the
	// corner of the screen, which no window covers. The console keeps the
	// keys.
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Scene 1: the console.
	{kind = .Film_Start, text = "program"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},

	// Scene 2: a command starts the module. "plasma: ok" comes after its
	// first picture; the compositor and plasma write in either order.
	{kind = .Film_Type, text = "start(\"plasma\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "plasma: ok", any_order = true},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "program.start"},

	// Scene 3: the window goes to the right of the console. The window of
	// plasma is 324 by 226 pixels with its frame.
	{kind = .Move, text = "plasma", to_x = 1184, to_y = 120},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "program.window"},

	// Scene 4: the process in the table of the processes.
	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "where(processes(), \"name\", \"plasma\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] slot  name"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ + FILM_HOLD_LOOK, text = "program.process"},

	// Scene 5: a command stops the process; its window closes.
	{kind = .Film_Type, text = "stop(\"plasma\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: plasma stopped"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "program.stop"},
	{kind = .Film_Stop},
	{kind = .Quit},
}
