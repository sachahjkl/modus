package machine

// The seven-chapter developer tutorial film, `modustool film tutorial`
// (src/md/infrastructure/tutorial_film.md; docs/TOOLS.md, "The film").
//
// Focuses on one coherent story: declaring, cache-building, verifying,
// granting, running, and time-traveling `db_browser` (a sandboxed SQLite GUI
// application on modus).
//
// Off-camera before Film_Start, the scenario positions the console, connects
// to `recipes`, configures the local signed QUIC object cache at
// 10.0.2.100:5010, and clears the console so zero raw 64-hex setup keys appear
// on screen. Every chapter uses Lex variables and typed Record field access
// (`tree`, `pkg.recipe`, `pkg.output`, `mod`) — zero hand-typed 64-hex hashes.
//
// Chapter title cards and lower-third captions are driven directly from the
// cue timestamps recorded here (tutorial_film_compose.odin). All windows stay
// within y = 52..780 so the lower-third caption band (y = 856..1036) never
// overlaps console lines, editor text, grant rows, or db_browser's status bar.
//
// Generous reading hold times for the self-contained silent tutorial.
TUTORIAL_HOLD_EXPLAIN :: 4200
TUTORIAL_HOLD_DETAIL :: 4800

@(rodata)
scenario_tutorial_film := [?]Step {
	// Off-camera boot, console positioning, cache trust configuration, and clear.
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Front, text = "console"},
	{kind = .Move, text = "console", to_x = 32, to_y = 56},
	{kind = .Type, text = "connect(\"recipes\")"},
	{kind = .Wait, text = "[console]   module     recipes"},
	{kind = .Type, text = "recipes.configure_cache(\"{cache_server_key}\", \"{cache_signer_key}\")"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Chapter 1: Intro title card (spliced at 0.000) + clean modus desktop & Lex console.
	{kind = .Film_Start, text = "tutorial"},
	{kind = .Film_Hold, milliseconds = 3200, text = "tutorial.intro"},

	// Chapter 2: Open db_browser/project.lex on screen in the modus editor.
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "tutorial.project_start"},
	{kind = .Film_Type, text = "edit(\"db_browser\", \"project.lex\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface edit: project.lex", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented"},
	{kind = .Move, text = "edit: project.lex", to_x = 920, to_y = 56},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_DETAIL, text = "tutorial.project_lex"},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_EXPLAIN, text = "tutorial.project_grants"},
	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "stop(\"edit\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: edit stopped: "},

	// Chapter 3: Content-addressed ingestion, signed QUIC cache pull, provenance,
	// and verified module delivery using clean Lex variables & typed Records.
	// Variable assignments draw nothing in the console, so each binding is
	// evaluated on the next line to display its hash or typed Record on screen.
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "tutorial.cache_start"},
	{kind = .Film_Type, text = "tree = \"db_browser\" |> recipes.ingest_tree"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "tree"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {db_browser_here}"},
	{kind = .Film_Hold, milliseconds = 3500},

	{kind = .Film_Type, text = "pkg = \"db_browser\" |> recipes.build_project(\"prefer_cache\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Film_Type, text = "pkg"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   output   {db_browser_output}"},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_DETAIL, text = "tutorial.cache_pull"},

	{kind = .Film_Type, text = "pkg.recipe |> recipes.provenance"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   signer  {cache_signer_key}"},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_DETAIL, text = "tutorial.provenance"},

	{kind = .Film_Type, text = "mod = pkg.output |> recipes.deliver_module(\"module\", \"db_browser\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "mod"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {db_browser_hash}"},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_EXPLAIN, text = "tutorial.deliver"},

	// Chapter 4: Sandbox by default (zero store access), explicit store grant,
	// desktop Grants window, and restart with granted private store.
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "tutorial.sandbox_start"},
	{kind = .Film_Type, text = "start_from_disk(\"db_browser\", mod)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: started db_browser from the disk, hash {db_browser_hash}", any_order = true},
	{kind = .Wait, text = "compositor: surface db_browser", any_order = true},
	{kind = .Wait, text = "db_browser: no store granted, running in memory"},
	{kind = .Move, text = "db_browser", to_x = 420, to_y = 52},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_DETAIL, text = "tutorial.sandboxed"},

	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "allow(\"db_browser\", \"store\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "has the grant store for principal 0"},
	{kind = .Film_Type, text = "start(\"grants\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface grants", any_order = true},
	{kind = .Wait, text = "grants: ok"},
	{kind = .Move, text = "grants", to_x = 960, to_y = 56},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_DETAIL, text = "tutorial.grants_window"},

	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "stop(\"grants\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: grants stopped: "},
	{kind = .Film_Type, text = "stop(\"db_browser\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: db_browser stopped: "},
	{kind = .Film_Type, text = "start_from_disk(\"db_browser\", \"\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: started db_browser from the disk, hash {db_browser_hash}, with the grant store: the store disk-db_browser", any_order = true},
	{kind = .Wait, text = "compositor: surface db_browser", any_order = true},
	{kind = .Wait, text = "db_browser: opened database of "},
	{kind = .Move, text = "db_browser", to_x = 420, to_y = 52},

	// Chapter 5: Live SQLite GUI — isolated child host, atomic INSERT + SELECT,
	// and off-thread column header sorting.
	{kind = .Front, text = "db_browser"},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_EXPLAIN, text = "tutorial.sqlite_open"},
	{kind = .Click_Element, text = "db_browser", element = "sql editor"},
	{kind = .Key, text = "ctrl-a"},
	{kind = .Film_Type, text = "INSERT INTO tasks (title, done) VALUES ('ship modus', 1); SELECT id, title, done FROM tasks;"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ctrl-ret"},
	{kind = .Wait, text = "db_browser: committed "},
	{kind = .Film_Hold, milliseconds = 2200, text = "tutorial.sqlite_query"},
	{kind = .Click_Element, text = "db_browser", element = "column title"},
	{kind = .Wait, text = "db_browser: sorted column "},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_EXPLAIN},

	// Chapter 6: Automatic CoW versions — Ctrl+H, preview earlier generation,
	// press Enter to restore atomically, and verify restored rows.
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "tutorial.versions_start"},
	{kind = .Key, text = "ctrl-h"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "db_browser: previewing version generation "},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_EXPLAIN, text = "tutorial.versions_preview"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "db_browser: restored version generation "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Click_Element, text = "db_browser", element = "sql editor"},
	{kind = .Key, text = "ctrl-a"},
	{kind = .Film_Type, text = "SELECT id, title, done FROM tasks;"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ctrl-ret"},
	{kind = .Wait, text = "db_browser: query returned 2 rows, "},
	{kind = .Film_Hold, milliseconds = TUTORIAL_HOLD_DETAIL},

	// Chapter 7 recap card is spliced cleanly after Film_Stop.
	{kind = .Film_Stop},
	{kind = .Quit},
}
