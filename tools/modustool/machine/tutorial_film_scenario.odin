package machine

// The end-to-end developer tutorial film, the command `modustool film tutorial`
// (docs/TOOLS.md, "The film"). Each hold with a text names the cue of a caption
// (docs/TOOLS.md, "The film cues").
//
// Before the film starts, the scenario boots against a prepared STORAGE7 data
// disk (containing collatz, db_browser, store_explorer, and disk-db_browser)
// and configures recipes to trust the local signed QUIC object cache forwarded
// at 10.0.2.100:5010 through the peer. Then the worker films seven scenes:
//
//  1. tutorial.desktop: the modus desktop and console;
//  2. tutorial.project: Lex pipes and project tree ingestion (collatz, db_browser);
//  3. tutorial.native_build: native in-modus C build of collatz via c_builder;
//  4. tutorial.cache_pull: signed QUIC cache substitution of db_browser,
//     provenance inspection, and verified module delivery into module_files;
//  5. tutorial.launch: sandboxed disk launch of db_browser, explicit store
//     grant, restart with isolated sqlite.module child call host;
//  6. tutorial.query: live SQL INSERT + SELECT committed atomically to the
//     copy-on-write store, followed by off-thread column header sorting;
//  7. tutorial.versions: Ctrl+H copy-on-write version history preview.
//
// Runtime hashes ({cache_server_key}, {cache_signer_key}, {collatz_here},
// {db_browser_here}, {db_browser_recipe}, {db_browser_output},
// {db_browser_hash}) are expanded by tutorial_film_expand_steps before the
// machine starts.
@(rodata)
scenario_tutorial_film := [?]Step {
	// Off-camera boot and remote cache trust configuration.
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "connect(\"recipes\")"},
	{kind = .Wait, text = "[console]   module     recipes"},
	{kind = .Type, text = "recipes.configure_cache(\"{cache_server_key}\", \"{cache_signer_key}\")"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Scene 1: the desktop and console.
	{kind = .Film_Start, text = "tutorial"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE, text = "tutorial.desktop"},

	// Scene 2: Lex pipes and canonical project tree ingestion.
	{kind = .Film_Type, text = "modules() |> where(name = \"recipes\") |> rows"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Film_Type, text = "\"collatz\" |> recipes.ingest_tree"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {collatz_here}"},
	{kind = .Film_Type, text = "\"db_browser\" |> recipes.ingest_tree"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {db_browser_here}"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK, text = "tutorial.project"},

	// Scene 3: native in-modus C compilation of collatz through c_builder.
	{kind = .Film_Type, text = "recipes.build_project(\"collatz\", \"build_only\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] built: recipe "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "tutorial.native_build"},

	// Scene 4: signed QUIC object cache substitution, provenance, and delivery.
	{kind = .Film_Type, text = "recipes.build_project(\"db_browser\", \"prefer_cache\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] cached: recipe {db_browser_recipe} output {db_browser_output}"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Type, text = "recipes.provenance(\"{db_browser_recipe}\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "origin remote_cache signer {cache_signer_key}"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Type, text = "recipes.deliver_module(\"{db_browser_output}\", \"module\", \"db_browser\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {db_browser_hash}"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "tutorial.cache_pull"},

	// Scene 5: sandboxed launch from disk, explicit store grant, and restart
	// with the isolated sqlite.module child call host.
	{kind = .Film_Type, text = "start_from_disk(\"db_browser\", \"{db_browser_hash}\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: started db_browser from the disk, hash {db_browser_hash}", any_order = true},
	{kind = .Wait, text = "compositor: surface db_browser"},
	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "allow(\"db_browser\", \"store\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "has the grant store for principal 0"},
	{kind = .Film_Type, text = "stop(\"db_browser\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: db_browser stopped: "},
	{kind = .Film_Type, text = "start_from_disk(\"db_browser\", \"\")"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "root: started db_browser from the disk, hash {db_browser_hash}, with the grant store: the store disk-db_browser", any_order = true},
	{kind = .Wait, text = "compositor: surface db_browser", any_order = true},
	{kind = .Wait, text = "db_browser: opened database of "},
	{kind = .Move, text = "db_browser", to_x = LOGICAL_SCREEN_WIDTH - 1096, to_y = 64},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "tutorial.launch"},

	// Scene 6: SQL INSERT + SELECT committed atomically, then column header sort.
	{kind = .Front, text = "db_browser"},
	{kind = .Click_Element, text = "db_browser", element = "sql editor"},
	{kind = .Key, text = "ctrl-a"},
	{kind = .Film_Type, text = "INSERT INTO tasks (title, done) VALUES ('ship modus', 1); SELECT id, title, done FROM tasks;"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ctrl-ret"},
	{kind = .Wait, text = "db_browser: committed "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Click_Element, text = "db_browser", element = "column title"},
	{kind = .Wait, text = "db_browser: sorted column "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "tutorial.query"},

	// Scene 7: copy-on-write version history preview (v2 -> v1 -> Esc).
	{kind = .Key, text = "ctrl-h"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_GLANCE},
	{kind = .Key, text = "down"},
	{kind = .Wait, text = "db_browser: previewing version generation "},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_READ, text = "tutorial.versions"},
	{kind = .Key, text = "esc"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},
	{kind = .Film_Stop},
	{kind = .Quit},
}
