package machine

// The five-lesson Modus Practical Course film, `modustool film course`
// (src/md/infrastructure/course_film.md; docs/COURSE.md).
//
// Teaches why modus exists and how to use it daily:
//  1. Typed Console & Lex v3: processes() table pipeline, memory() Record,
//     exact unit arithmetic + pure Lex filter/map, and typed enum refusal.
//  2. Running Code & Built-In Help: s = isolate("sample"), help("s.readings"),
//     s.readings(4) |> where(sensor = 2) |> s.sum_values, plus connect("monitor").
//  3. Declarative plan { ... } & Trusted Consent: schema typo refusal before
//     dialog, one-step plans.apply("evening", ...) holding 5.6 s on the live
//     trusted display consent dialog, Tab+Enter accept returning standing
//     Current directly, and plans.generations().
//  4. Zero Ambient Authority & Desktop Grants: grants("notes") |> where(state
//     = "held") and the live desktop grants window with Revoke buttons.
//  5. Automatic Copy-on-Write Versions: notes auto-commit on pause,
//     Ctrl+H version list, Down read-only preview, and Enter restore.
//
// Generous teaching hold times so a viewer reads both the on-screen output
// and the two-line lower-third caption without pausing.
COURSE_HOLD_TEACH :: 5200
COURSE_HOLD_DIALOG :: 5600

@(rodata)
scenario_course_film := [?]Step {
	// Off-camera boot, monitor startup (for processes()), console positioning,
	// and clear so the viewer opens on a clean desktop and prompt.
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "console: no line history kept: the history starts empty", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Front, text = "console"},
	{kind = .Move, text = "console", to_x = 24, to_y = 44},
	{kind = .Type, text = "start(\"monitor\")"},
	{kind = .Wait, text = "monitor: ok", any_order = true},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Intro card (spliced at 0.000) + Lesson 1 teaching card (before course.l1_start).
	{kind = .Film_Start, text = "course"},

	// Lesson 1: Typed Console & Lex v3.
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "course.l1_start"},
	{kind = .Film_Type, text = "processes() |> where(threads > 1) |> columns(name, slot, resident) |> sort(\"resident\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = " of Process"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Film_Type, text = "memory()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   interrupts"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l1_memory"},

	{kind = .Film_Type, text = "1 MiB + 512 KiB"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 1536 KiB"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Type, text = "let double = (x) => x * 2 in [1, 2, 3, 4] |> filter((x) => x > 2) |> map(double)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] [6, 8]"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l1_units"},

	{kind = .Film_Type, text = "settings.set(font = .comic)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] error: "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l1_enum_refusal"},

	// Lesson 2: The 5 Ways to Run Code & Bound Module Handles.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "course.l2_start"},
	{kind = .Film_Type, text = "s = isolate(\"sample\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Film_Type, text = "help(\"s.readings\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] gives a table of "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l2_help"},

	{kind = .Film_Type, text = "t = s.readings(4)"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] > t = s.readings(4)"},
	{kind = .Film_Type, text = "t |> where(sensor = 2) |> s.sum_values"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 30"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l2_shorthand"},

	{kind = .Film_Type, text = "connect(\"monitor\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   module     monitor"},
	{kind = .Film_Type, text = "monitor.served()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   calls"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l2_connect"},

	{kind = .Type, text = "unload(s)"},
	{kind = .Wait, text = "[console]   module    sample"},

	// Lesson 3: Declarative plan { ... } & Trusted Display Consent.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "course.l3_start"},
	{kind = .Film_Type, text = "plans.apply(\"evening\", plan { locks = { settings = { appearance = .neon } } })"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] error: "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Film_Type, text = "plans.apply(\"evening\", plan { locks = { settings = { appearance = .dark } } }) |> columns(generation, standing)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan evening shows: "},
	// Hold 5.6 s on the live trusted display consent dialog so the viewer
	// reads the exact root-computed diff (well past the 500 ms arm time).
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_DIALOG, text = "course.l3_plan_dialog"},
	{kind = .Key, text = "tab"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: the difference of the plan evening is accepted", fails_on = "compositor: the difference of the plan evening is refused"},
	{kind = .Wait, text = "plans: applied generation 1 for principal 0", any_order = true},
	{kind = .Wait, text = " of Plan_Generation_Row"},

	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "plans.generations() |> columns(generation, timestamp_ms, standing)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = " of Plan_Generation_Row"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l3_plan_applied"},

	{kind = .Type, text = "stop(\"plans\")"},
	{kind = .Wait, text = "root: plans stopped: "},

	// Lesson 4: Zero Ambient Authority & Desktop Grants Window.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "course.l4_start"},
	{kind = .Film_Type, text = "start(\"notes\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "notes: a new store: no note", any_order = true},
	{kind = .Wait, text = "compositor: surface notes", any_order = true},
	{kind = .Wait, text = "notes: ok, the first picture is presented"},
	{kind = .Move, text = "notes", to_x = 700, to_y = 44},
	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "grants(\"notes\") |> where(state = \"held\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = " of Grant"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Film_Type, text = "start(\"grants\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface grants", any_order = true},
	{kind = .Wait, text = "grants: ok"},
	{kind = .Move, text = "grants", to_x = 820, to_y = 44},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l4_grants_window"},

	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"grants\")"},
	{kind = .Wait, text = "root: grants stopped: "},

	// Lesson 5: Automatic Copy-on-Write Versions (Zero Save Button).
	{kind = .Front, text = "notes"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "course.l5_start"},
	{kind = .Film_Type, text = "modus course"},
	{kind = .Wait, text = "notes: the note is \"modus course\", 12 bytes, generation "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "second draft line"},
	{kind = .Generation, text = "notes: the note is \"modus course\", 30 bytes, generation "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l5_second_edit"},

	{kind = .Key, text = "ctrl-h"},
	{kind = .Wait, text = "notes: the version 1 of "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "notes: the version 2 of "},
	{kind = .Wait, text = ": \"modus course\""},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l5_versions_preview"},

	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "notes: restored the version of generation "},
	{kind = .Wait, text = "\", in the commit of generation {generation+1}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "course.l5_versions_restored"},

	// Recap card is spliced cleanly after Film_Stop.
	{kind = .Film_Stop},
	{kind = .Quit},
}
