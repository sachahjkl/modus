package machine

// The six-lesson Modus Practical Course — Part 2 film,
// `modustool film course_building`
// (src/md/infrastructure/course_building_film.md; docs/COURSE_BUILDING.md).
//
// Teaches building programs, declaring reproducible build environments in Lex,
// and publishing signed closures over QUIC from inside modus:
//  1. Instant Sandboxed C Prototyping (`compile_c`, `help(a)`, `unload(a)`).
//  2. Real Projects & Iterative Edit / Build / Run (`projects.new`, `edit`,
//     `build`, `run`, local cache substitution, declared grant refusal).
//  3. Reproducible Build Environments in Lex (`edit("calc", "project.lex")`).
//  4. Content-Addressed Ingestion & Sandboxed Local Build (`recipes.ingest_tree`,
//     `recipes.build_project("build_only")`, `recipes.provenance`).
//  5. Live In-OS QUIC Cache Upload & Cryptographic Verification
//     (`recipes.publisher_key()`, `recipes.publish`,
//     `recipes.build_project("verify")`, `recipes.status()`,
//     `recipes.collect_garbage()`).
//  6. Delivering, Running, Installing & Versioning (`recipes.deliver_module`,
//     `run("calc")`, `projects.install("calc", "prefer_cache")`, and `Ctrl+H`
//     / `Ctrl+Z` copy-on-write source history in `edit`).
//
// Off-camera before Film_Start, the scenario configures the local signed QUIC
// cache, imports the deterministic test-only publisher key seed into `recipes`,
// registers `"calc"` with `projects.new("calc")`, and clears the console so
// zero private seeds or 64-hex setup keys ever appear on camera.

@(rodata)
scenario_course_building_film := [?]Step {
	// Off-camera boot, console positioning, QUIC cache + publisher key setup,
	// project registration for `"calc"`, and clear.
	{kind = .Wait, text = "storage: ok, generation ", any_order = true},
	{kind = .Wait, text = "compositor: surface console", any_order = true},
	{kind = .Wait, text = "root: settings stopped: itself, done"},
	{kind = .Front, text = "console"},
	{kind = .Move, text = "console", to_x = 24, to_y = 44},
	{kind = .Type, text = "connect(\"recipes\")"},
	{kind = .Wait, text = "[console]   module     recipes"},
	{kind = .Type, text = "recipes.configure_cache(\"{cache_server_key}\", \"{cache_signer_key}\")"},
	{kind = .Wait, text = "[console] 1"},
	{kind = .Type, text = "recipes.configure_publisher(\"{cache_publisher_seed}\")"},
	{kind = .Wait, text = "[console] {cache_signer_key}"},
	{kind = .Type, text = "projects.new(\"calc\")"},
	{kind = .Wait, text = "projects: made the project calc of principal 0"},
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Click, x = SCREEN_CORNER_X, y = SCREEN_CORNER_Y},

	// Intro card (spliced at 0.000) + Lesson 1 card (before cb.l1_start).
	{kind = .Film_Start, text = "course_building"},

	// Lesson 1: Instant Sandboxed C Prototyping (`compile_c`).
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "cb.l1_start"},
	{kind = .Film_Type, text = "a = compile_c(\"adder\", \"long add(long x, long y) { return x + y; }\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Film_Type, text = "help(a)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "a.add"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l1_help"},

	{kind = .Film_Type, text = "a.add(19, 23)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 42"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l1_call"},

	{kind = .Film_Type, text = "unload(a)"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   module    adder"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	// Lesson 2: Real Projects & Iterative Edit / Build / Run.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "cb.l2_start"},
	{kind = .Film_Type, text = "projects.new(\"hello\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "projects: made the project hello of principal 0"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	{kind = .Film_Type, text = "edit(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: ok, the first picture is presented", any_order = true},
	{kind = .Wait, text = "compositor: surface edit: hello.c"},
	{kind = .Move, text = "edit: hello.c", to_x = 740, to_y = 44},
	{kind = .Front, text = "edit: hello.c"},
	{kind = .Film_Type, text = "long main(void) { return 42; }"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 31 bytes in the generation "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_edit"},

	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: built hello.c into a module of ", fails_on = PROGRAM_BUILD_FAILED},
	{kind = .Wait, text = "module_files: put hello: "},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_build"},

	{kind = .Film_Type, text = "run(\"hello\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: ran hello, module "},
	{kind = .Wait, text = "[console] 42"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_LOOK},

	{kind = .Film_Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: substituted hello.c: the recipe ", fails_on = "recipes: built hello.c"},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_cached"},

	{kind = .Film_Type, text = "run(\"hello\", \"store\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] error: run: the project hello declares no grant store"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_refusal"},

	{kind = .Type, text = "stop(\"edit\")"},
	{kind = .Wait, text = "root: edit stopped: "},

	// Lesson 3: Reproducible Build Environments in Lex (`project.lex`).
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "cb.l3_start"},
	{kind = .Film_Type, text = "edit(\"calc\", \"project.lex\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface edit: project.lex", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented"},
	{kind = .Move, text = "edit: project.lex", to_x = 740, to_y = 44},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l3_lex"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l3_recipe"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"edit\")"},
	{kind = .Wait, text = "root: edit stopped: "},

	// Lesson 4: Content-Addressed Ingestion & Sandboxed Local Build.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "cb.l4_start"},
	{kind = .Film_Type, text = "tree = \"calc\" |> recipes.ingest_tree"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "tree"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {calc_here}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l4_ingest"},

	{kind = .Film_Type, text = "pkg = \"calc\" |> recipes.build_project(\"build_only\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Film_Type, text = "pkg"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   recipe   {calc_recipe}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l4_build"},

	{kind = .Film_Type, text = "pkg.recipe |> recipes.provenance"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   origin  local_build"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l4_provenance"},

	// Lesson 5: Live In-OS QUIC Cache Upload & Cryptographic Verification.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "cb.l5_start"},
	{kind = .Film_Type, text = "recipes.publisher_key()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {cache_signer_key}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_key"},

	{kind = .Film_Type, text = "pub = pkg.recipe |> recipes.publish"},
	{kind = .Key, text = "esc"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: published recipe {calc_recipe}"},
	{kind = .Film_Type, text = "pub"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   bytes_uploaded"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_publish"},

	{kind = .Film_Type, text = "verified = \"calc\" |> recipes.build_project(\"verify\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Film_Type, text = "verified"},
	{kind = .Key, text = "esc"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   recipe   {calc_recipe}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_verify"},

	{kind = .Film_Type, text = "recipes.status()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "verify_agreements"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_status"},

	{kind = .Film_Type, text = "recipes.collect_garbage()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] marked "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_gc"},

	// Lesson 6: Delivering, Running, Installing & Copy-on-Write Versioning.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT, text = "cb.l6_start"},
	{kind = .Film_Type, text = "mod = pkg.output |> recipes.deliver_module(\"module\", \"calc\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "module_files: put calc: "},
	{kind = .Film_Type, text = "run(\"calc\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: ran calc, module "},
	{kind = .Wait, text = "[console] 84"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l6_deliver"},

	{kind = .Film_Type, text = "projects.install(\"calc\", \"prefer_cache\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "module_files: put calc: "},
	{kind = .Wait, text = "[console]   module   "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l6_install"},

	{kind = .Film_Type, text = "edit(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = FILM_HOLD_BEAT},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface edit: hello.c", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented"},
	{kind = .Move, text = "edit: hello.c", to_x = 740, to_y = 44},
	{kind = .Front, text = "edit: hello.c"},
	{kind = .Key, text = "down"},
	{kind = .Film_Type, text = "//v2"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 36 bytes in the generation "},
	{kind = .Key, text = "ctrl-h"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l6_versions"},
	{kind = .Key, text = "ctrl-z"},
	{kind = .Wait, text = "edit: undo: the text has 31 bytes, "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l6_undo"},

	// Recap card is spliced cleanly after Film_Stop.
	{kind = .Film_Stop},
	{kind = .Quit},
}
