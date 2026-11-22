package machine

// The film of the desktop, the command `modustool film desktop`
// (docs/TOOLS.md, "The film"). It is the chapter "The desktop" of the
// tutorial; each hold with a text names the cue of a caption
// (docs/TOOLS.md, "The film cues"). What each part of the desktop looks
// like is in the design rules (docs/DESIGN.md, "The desktop").
//
// Before the film starts, the scenario waits for the desktop and puts the
// pointer in a corner. Then the worker films:
//
//  1. the desktop at the start: the bar at the top, the console;
//  2. the button start opens the start menu, the list of the modules;
//  3. a press on a line starts monitor, then clock: each process has its
//     window;
//  4. a drag of a title bar moves monitor, then clock;
//  5. a drag of a corner resizes the window of clock, which declares
//     itself resizable;
//  6. the button windows opens the menu of the windows, and a line brings
//     the console to the front;
//  7. the close button stops clock;
//  8. the palette: the key super opens it, "lif" and Enter start life,
//     "@mon" and Enter bring monitor to the front.
//
// The keys and the lines of each scene are those of the main scenario of
// the machine test (main_scenario.odin): the film shows what the test checks.
// Each scene waits for its line before its hold, so the film never shows a
// state that the machine did not reach.
//
// The places keep each window whole on the reference screen of 1920 by
// 1080: monitor (520 by 560) at the right, clock (816 by 336, then 880 by
// 384) under the console, with no window over the title bar of the next
// one that a step drags.
@(rodata)
scenario_desktop_film := [?]Step {
	// The boot. The processes write in an order that the system does not fix.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done", any_order = true},
	{kind = .Wait, text = "compositor: the palette has a provider", any_order = true},
	// The pointer leaves the place of the windows: a press on the
	// background, in the corner of the screen, which no window covers.
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Scene 1: the desktop at the start.
	{kind = .Film_Start, text = "desktop"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "desktop.start"},

	// Scene 2: the start menu. The same button closes it.
	{kind = .Click, text = BAR_START_BUTTON},
	{kind = .Wait, text = "compositor: the start menu is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "desktop.start_menu"},
	{kind = .Click, text = BAR_START_BUTTON},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},

	// Scene 3: a line of the start menu starts a process, and the process
	// opens its window. clock declares its window resizable.
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "desktop.process"},
	{kind = .Launch, text = "clock"},
	{kind = .Wait, text = "compositor: window clock is resizable from 480x420 to 1536x864", any_order = true},
	{kind = .Wait, text = "compositor: surface clock"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Scene 4: a drag of the title bar moves a window. The step reads the
	// place of the window in the log, before and after.
	{kind = .Move, text = "monitor", to_x = LOGICAL_SCREEN_WIDTH - 560, to_y = 48},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE, text = "desktop.move"},
	{kind = .Move, text = "clock", to_x = LOGICAL_SCREEN_WIDTH - 1200, to_y = LOGICAL_SCREEN_HEIGHT - 600},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Scene 5: a drag of the lower left corner resizes the window. The
	// process draws its next picture at the new size, and the compositor
	// shows the window at that size from that picture. The process can
	// draw before the compositor writes its line of the request: the two
	// lines come in either order.
	{kind = .Resize, text = "clock", to_x = 880, to_y = 520},
	{kind = .Wait, text = "compositor: window clock asked to draw at 880x520", any_order = true},
	{kind = .Wait, text = "display: clock: the first picture of 880x520 after a resize"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "desktop.resize"},

	// Scene 6: the menu of the windows, one line for each window; a line
	// brings its window to the front.
	{kind = .Click, text = BAR_WINDOWS_BUTTON},
	{kind = .Wait, text = "compositor: windows: "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "desktop.windows_menu"},
	{kind = .Click, text = BAR_WINDOWS_BUTTON},
	{kind = .Front, text = "console"},
	{kind = .Wait, text = "compositor: window console in front"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Scene 7: the close button stops the process of the window.
	{kind = .Close, text = "clock"},
	{kind = .Wait, text = "root: clock stopped"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "desktop.close"},

	// Scene 8: the palette. The key super opens it; the list narrows at
	// each key, and Enter starts the chosen module.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "desktop.palette"},
	{kind = .Film_Type, text = "lif"},
	{kind = .Wait, text = " for \"lif\": life (module)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette starts life"},
	{kind = .Wait, text = "compositor: surface life"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "desktop.palette_start"},
	// The prefix "@" lists the windows only; Enter brings the chosen one
	// to the front.
	{kind = .Key, text = "meta_l"},
	{kind = .Wait, text = "compositor: the palette is open"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "@mon"},
	{kind = .Wait, text = " for \"@mon\": monitor (window)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE, text = "desktop.palette_window"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the palette brings monitor to the front"},
	{kind = .Wait, text = "compositor: window monitor in front"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Film_Stop},
	{kind = .Quit},
}
