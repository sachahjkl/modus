package machine

// The film of the console, the command `modustool film console`
// (docs/TOOLS.md, "The film"). It is the chapter "The console" of the
// tutorial; each hold with a text names the cue of a caption
// (docs/TOOLS.md, "The film cues"). What the console does with a line is
// in docs/CONSOLE.md.
//
// Before the film starts, the scenario waits for the desktop and brings
// the console to the front. Then the worker films:
//
//  1. the console, alone;
//  2. an expression: a line is typed, Enter runs it, the result is a value
//     with a kind;
//  3. a variable, and a call of a command with it;
//  4. a call with an argument of the wrong kind: the error says which
//     argument and which kind;
//  5. the completion list: "memo" opens it, Escape closes it, Tab opens it
//     again, Enter takes memory; the call gives a record;
//  6. a command that gives a table: the processes that run;
//  7. the history search: Control-R and "leng" find the older lines, a
//     second Control-R goes to the next one, Enter puts it in the input,
//     and a second Enter runs it.
//
// The lines and the waits are those of the main scenario of the machine
// test (machine.odin): the film shows what the test checks. A typed line
// is a step Film_Type, so a viewer sees it typed; Enter is its own step,
// and the scene waits for the echo of the line or for its result before
// its hold.
@(rodata)
scenario_console_film := [?]Step {
	// The boot. The console asks for the store of its line history at its
	// start; the history of a new disk is empty.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "console: no line history kept: the history starts empty", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
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
	{kind = .Film_Start, text = "console"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "console.start"},

	// Scene 2: an expression, and its value.
	{kind = .Film_Type, text = "1 + 2 * 3"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 7"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "console.expression"},

	// Scene 3: a variable keeps a value; a command takes it as an argument.
	{kind = .Film_Type, text = "name = \"modus\""},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > name = \"modus\""},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "length(name) * 2"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 10"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "console.command"},

	// Scene 4: the console checks each argument against the description
	// of the command before the call.
	{kind = .Film_Type, text = "length(5)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "error: length: argument 1 is Text, not Integer"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "console.error"},

	// Scene 5: the completion list. It opens at the first character of a
	// name; Escape closes it, Tab opens it again and writes its line; Enter
	// takes the first name with its '('.
	{kind = .Film_Type, text = "memo"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "console: the completion list opens by Tab: "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "console.completion"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the completion gave the line memory("},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Film_Type, text = ")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   interrupts"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "console.record"},

	// Scene 6: a table. A command gives rows with typed columns.
	{kind = .Film_Type, text = "processes()"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] slot  name"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ + FILM_HOLD_LOOK, text = "console.table"},

	// Scene 7: the history search. The lines that hold "leng" in their
	// order, the newest first: Control-R goes to the older one, Enter puts
	// it in the input, a second Enter runs it.
	{kind = .Key, text = "ctrl-r"},
	{kind = .Film_Type, text = "leng"},
	{kind = .Wait, text = "console: the history search \"leng\" chooses the row 1 of "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "console.history"},
	{kind = .Key, text = "ctrl-r"},
	{kind = .Wait, text = "console: the history search \"leng\" chooses the row 2 of "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the history search gave the line length(name) * 2"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > length(name) * 2"},
	{kind = .Wait, text = "[console] 10"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Film_Stop},
	{kind = .Quit},
}
