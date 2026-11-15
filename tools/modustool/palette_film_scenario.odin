package modustool

// The film of the palette, the command `modustool film palette`
// (docs/TOOLS.md, "The film"). What the panel shows in each state is in the
// design rules (docs/DESIGN.md, "Palette").
//
// Before the film starts, the scenario makes the desktop: the console, the
// monitor and the settings, each at its place, and the pointer in a corner.
// Then the worker films, and each scene opens the panel with the key super:
//
//  1. the desktop;
//  2. the panel opens, with the windows and the programs;
//  3. letters of a program: the list narrows, Enter starts plasma;
//  4. "@" and letters of a title: Enter brings the monitor to the front;
//  5. a command with no parameter: memory() gives a record in the panel;
//  6. a command with a parameter: the form of start, Tab takes "life";
//  7. two fields and a command that destroys: revoke, its question, and
//     Escape: nothing is revoked;
//  8. ":" and a setting: the font of the whole desktop changes behind the
//     open panel, then changes back;
//  9. a number with its unit: buffer takes a count of pages;
// 10. a row of buttons in the band: strategy, Right, and a press on a
//     button;
// 11. go to: the window of settings comes to the front;
// 12. shutdown: the question, and Escape.
//
// Each key of a scene and each wait for a line of the log is one that the
// main scenario of the machine test has (machine.odin): the film shows only
// what the test checks. A scene waits for its line before its hold, so the
// film never shows a state that the machine did not reach. The steps
// Film_Type and Film_Hold are the times of the film, for its viewer.
@(rodata)
scenario_palette_film := [?]Step {
	// The boot, and the console as the palette provider. The programs
	// write in an order that the system does not fix.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped with code 0", any_order = true},
	{kind = .Wait, text = "console: the palette table has ", any_order = true},
	{kind = .Wait, text = "compositor: the palette has a provider", any_order = true},
	// The desktop of the film. The monitor at the right, the console over
	// its left part, the settings at the bottom: their sample of the text
	// of the system stays in sight under the open panel. The service of
	// the settings runs with their window: the palette sets a setting
	// through it.
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 568, to_y = 40},
	{kind = .Move, text = "console", to_x = 8, to_y = 72},
	{kind = .Launch, text = "settings"},
	{kind = .Wait, text = "compositor: surface settings", any_order = true},
	{kind = .Wait, text = "settings: ok, "},
	{kind = .Move, text = "settings", to_x = 448, to_y = 216},
	// The pointer leaves the place of the panel: a press on the background,
	// in the corner of the screen, which no window covers.
	{kind = .Click, x = 1018, y = 762},

	// Scene 1: the desktop.
	{kind = .Film_Start, text = "palette"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Scene 2: the key super opens the panel.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},

	// Scene 3: letters of a program. The list narrows at each key, and
	// Enter starts the program.
	{kind = .Film_Type, text = "pla"},
	{kind = .Wait, text = " for \"pla\": plasma (program)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts plasma"},
	{kind = .Wait, text = "compositor: surface plasma"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Scene 4: the prefix of the windows. Enter brings the window to the
	// front.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "@mon"},
	{kind = .Wait, text = " for \"@mon\": monitor (window)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette brings monitor to the front"},
	{kind = .Wait, text = "compositor: window monitor in front"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Scene 5: a command of the console with no parameter. Its record
	// shows in the panel. The compositor and the console write their lines
	// in the order of their own threads: the line of the compositor is
	// looked for with no move of the place in the log, here and below.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "memo"},
	{kind = .Wait, text = " for \"memo\": memory (command)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends memory to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs memory()"},
	{kind = .Wait, text = "console: the palette gets Record, "},
	{kind = .Wait, text = "compositor: the palette shows a Record"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 6: a command with a parameter. Enter turns the input band into
	// its form; the console gives the candidates of the field, and Tab
	// takes the chosen one.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "start"},
	{kind = .Wait, text = " for \"start\": start (command)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of start"},
	{kind = .Wait, text = " candidates for the parameter 0 of start"},
	{kind = .Wait, text = " candidates for the field 0"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Film_Type, text = "lif"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "compositor: the palette takes the candidate life"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends start with 1 arguments to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs start(\"life\")"},
	{kind = .Wait, text = "compositor: the palette shows no value", any_order = true},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 7: two fields, and a command that destroys. The programs that
	// run for the first field, the grants for the second one, then the
	// question on its red row. Escape goes back to the form, to the search,
	// and closes the panel: the film revokes nothing.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "revoke"},
	{kind = .Wait, text = " for \"revoke\": revoke (command)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of revoke"},
	{kind = .Wait, text = " candidates for the parameter 0 of revoke"},
	{kind = .Wait, text = " candidates for the field 0"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Film_Type, text = "plasm"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = "compositor: the palette takes the candidate plasma"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "tab"},
	{kind = .Wait, text = " candidates for the parameter 1 of revoke"},
	{kind = .Wait, text = " candidates for the field 1"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Type, text = "log"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: revoke"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the arguments"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 8: the prefix of the settings. The font is one setting row,
	// with a button for each value and the value in use marked. Right
	// chooses spleen, and the font of the whole desktop changes behind the
	// open panel; Left chooses vector again on the same row.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = ":font"},
	{kind = .Wait, text = " for \":font\": font (setting)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "right"},
	{kind = .Wait, text = "compositor: the palette chooses the value spleen of font"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette sends set font to spleen to the console", any_order = true},
	{kind = .Wait, text = "console: the palette runs setting(\"font\", \"spleen\")"},
	{kind = .Wait, text = "compositor: the settings changed: font spleen", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: set font to spleen"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "left"},
	{kind = .Wait, text = "compositor: the palette chooses the value vector of font"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: the palette runs setting(\"font\", \"vector\")"},
	{kind = .Wait, text = "compositor: the settings changed: font vector", any_order = true},
	{kind = .Wait, text = "compositor: the palette did: set font to vector"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 9: a field that counts a size shows its unit after the number.
	// The command buffer takes a count of pages: the band says "pages" while
	// the field is empty, and after the 4 that the scene types. Escape
	// leaves with no memory object made.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = ">buffer"},
	{kind = .Wait, text = " for \">buffer\": buffer (command)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks for the arguments of buffer"},
	{kind = .Wait, text = "compositor: the field 0 of buffer takes a number in pages"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Film_Type, text = "4"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 10: a field with a few closed values is a row of buttons in the
	// band. The command strategy takes one of three names: the form shows
	// them as buttons, Right moves the choice, a press on the button
	// round_robin takes it, and Escape leaves with no change: the program
	// scheduler that serves it does not run here.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	// The prefix of the commands: "strategy" alone lists the setting row of
	// the strategy first.
	{kind = .Film_Type, text = ">strategy"},
	{kind = .Wait, text = " for \">strategy\": strategy (command)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = " candidates for the field 0, as a row of buttons"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "right"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Click_Element, text = PALETTE_ELEMENTS, element = "round_robin"},
	{kind = .Wait, text = "compositor: a press takes the button round_robin of the field 0"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 11: go to. The window of settings, open since the start of the
	// film, names the act of each of its rows. The band of ":grid" then
	// offers Shift with Enter, which raises the window of settings and puts
	// the focus on the row of the grid fit.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = ":grid"},
	{kind = .Wait, text = " for \":grid\": grid fit (setting)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "shift-ret"},
	{kind = .Wait, text = "compositor: the palette goes to grid fit in the window settings, now in front", any_order = true},
	{kind = .Wait, text = "interface: settings: the focus is on the element of settings.set:grid_fit", any_order = true},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},

	// Scene 12: a command that destroys asks for a second Enter, on a row
	// that says the act in full. Escape goes back, and nothing stops.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "shutd"},
	{kind = .Wait, text = " for \"shutd\": shutdown (command)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette asks to confirm: shutdown"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette goes back to the search"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "esc"},
	{kind = .Wait, text = "compositor: the palette is closed by the key escape"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Stop},
	{kind = .Quit},
}
