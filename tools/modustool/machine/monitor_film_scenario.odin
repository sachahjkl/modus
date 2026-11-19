package machine

// The film of the window of monitor, the command `modustool film monitor`
// (docs/TOOLS.md, "The film"): the graphs of the last minute and the
// gauges colored by their intensity (src/md/features/monitor_window.md),
// under a load and after it.
//
// Before the film starts, the scenario waits for the desktop and puts the
// pointer in a corner. Then the worker films:
//
//  1. monitor starts from the start menu and goes to the right of the
//     screen, and its graphs fill with the samples of a quiet machine;
//  2. scheduler starts: its tests run spinners on the four processors, so
//     the processor time rises and the gauges change their color;
//  3. the close button stops scheduler, and the curves come down.
//
// plasma was refused as the load: it draws each frame, but takes 1 % of the
// processors, so no curve and no gauge moves.
//
// Each hold is long enough for the graphs to take samples: a sample comes
// every 500 ms. The places keep both windows whole on the reference screen
// of 1920 by 1080: monitor (520 by 640) at the right, scheduler at its place
// of start, at the left.
@(private = "file")
MONITOR_FILM_SAMPLES_HOLD :: 12_000

@(rodata)
scenario_monitor_film := [?]Step {
	// The boot. The processes write in an order that the system does not fix.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped", any_order = true},
	{kind = .Wait, text = "compositor: the palette has a provider", any_order = true},
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Scene 1: monitor, on a quiet machine.
	{kind = .Launch, text = "monitor"},
	{kind = .Wait, text = "compositor: surface monitor"},
	{kind = .Move, text = "monitor", to_x = 1360, to_y = 48},
	{kind = .Film_Start, text = "monitor"},
	{kind = .Film_Hold, milliseconds = MONITOR_FILM_SAMPLES_HOLD},

	// Scene 2: a load. The tests of scheduler run spinners.
	{kind = .Launch, text = "scheduler"},
	{kind = .Wait, text = "compositor: surface scheduler"},
	{kind = .Film_Hold, milliseconds = MONITOR_FILM_SAMPLES_HOLD},
	{kind = .Film_Hold, milliseconds = MONITOR_FILM_SAMPLES_HOLD},

	// Scene 3: the load stops, and the curves come down.
	{kind = .Close, text = "scheduler"},
	{kind = .Film_Hold, milliseconds = MONITOR_FILM_SAMPLES_HOLD},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ},
	{kind = .Film_Stop},
	{kind = .Quit},
}
