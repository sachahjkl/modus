package machine

// The six-lesson Modus Practical Course — Part 2 film,
// `modustool film course_building`
// (src/md/infrastructure/course_building_film.md; docs/COURSE_BUILDING.md).
//
// Shows the complete programming cycle on modus with readable pacing:
//  1. Instant Sandboxed C Prototyping (`compile_c`, `help(a)`, `unload(a)`).
//  2. Real Iterative Programming Cycle (`projects.new`, writing multi-line C
//     in `edit`, `build`, `run` -> 36, cache hit, editing source in `edit`,
//     rebuilding -> 42, intentional compile error preserving last working
//     binary, and declared grant refusal).
//  3. Reading Real Project Source & Lex (`edit("calc", "main.c")` then
//     `edit("calc", "project.lex")`).
//  4. Content-Addressed Ingestion & Sandboxed Local Build (`recipes.ingest_tree`,
//     `recipes.build_project("build_only")`, `recipes.provenance`).
//  5. Live In-OS QUIC Cache Upload & Cryptographic Verification
//     (`recipes.publisher_key()`, `recipes.publish`,
//     `recipes.build_project("verify")`, `recipes.status()`,
//     `recipes.collect_garbage()`).
//  6. Delivering, Running, Installing & Copy-on-Write Source History
//     (`recipes.deliver_module`, `run("calc")` -> 84, `projects.install`,
//     and `Ctrl+H` / `Ctrl+Z` restoring earlier `hello.c` revisions in `edit`).
//
// Off-camera before Film_Start, the scenario configures the local signed QUIC
// cache, imports the deterministic test-only publisher key seed into `recipes`,
// registers `"calc"` with `projects.new("calc")`, and clears the console so
// zero private seeds or 64-hex setup keys ever appear on camera.

// Local constant so per-part Nix builds that exclude program_loop_scenario.odin
// still compile this file cleanly.
COURSE_BUILDING_FAILED :: "recipes: the C build failed at the step "

// Pause durations (ms) sized for unhurried reading without pausing the video.
COURSE_HOLD_BEFORE_ENTER :: 1600
COURSE_HOLD_RESULT :: 4500
COURSE_HOLD_CODE :: 9000

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
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER, text = "cb.l1_start"},
	{kind = .Film_Type, text = "a = compile_c(\"adder\", \"long add(long x, long y) { return x + y; }\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   call       isolated"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH},

	{kind = .Film_Type, text = "help(a)"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "a.add"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l1_help"},

	{kind = .Film_Type, text = "a.add(19, 23)"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] 42"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l1_call"},

	{kind = .Film_Type, text = "unload(a)"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   module    adder"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_RESULT},

	// Lesson 2: Real Iterative Programming Cycle (write -> build -> run -> edit -> rebuild -> run -> error safety).
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER, text = "cb.l2_start"},
	{kind = .Film_Type, text = "projects.new(\"hello\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "projects: made the project hello of principal 0"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_RESULT},

	{kind = .Film_Type, text = "edit(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: ok, the first picture is presented", any_order = true},
	{kind = .Wait, text = "compositor: surface edit: hello.c"},
	{kind = .Move, text = "edit: hello.c", to_x = 740, to_y = 44},
	{kind = .Front, text = "edit: hello.c"},
	// Write a real multi-line C program live inside edit (version 1 -> returns 36).
	{kind = .Film_Type, text = "long square(long x) {"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "  return x * x;"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "}"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "long main(void) {"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "  return square(6);"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "}"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 80 bytes in the generation "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_CODE, text = "cb.l2_edit"},

	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: built hello.c into a module of ", fails_on = COURSE_BUILDING_FAILED},
	{kind = .Wait, text = "module_files: put hello: "},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_build"},

	{kind = .Film_Type, text = "run(\"hello\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: ran hello, module "},
	{kind = .Wait, text = "[console] 36"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_RESULT},

	{kind = .Film_Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: substituted hello.c: the recipe ", fails_on = "recipes: built hello.c"},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_cached"},

	// Complete the cycle: modify hello.c live -> rebuild -> run new result (42).
	{kind = .Front, text = "edit: hello.c"},
	{kind = .Key, text = "ctrl-a"},
	{kind = .Film_Type, text = "long square(long x) {"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "  return x * x;"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "}"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "long main(void) {"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "  return square(6) + 6;"},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "}"},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "edit: kept a text of 84 bytes in the generation "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_RESULT},

	{kind = .Front, text = "console"},
	{kind = .Film_Type, text = "build(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: built hello.c into a module of ", fails_on = COURSE_BUILDING_FAILED},
	{kind = .Wait, text = "module_files: put hello: "},
	{kind = .Wait, text = "[console] hello: module "},
	{kind = .Film_Type, text = "run(\"hello\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: ran hello, module "},
	{kind = .Wait, text = "[console] 42"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_iterate"},

	{kind = .Film_Type, text = "run(\"hello\", \"store\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] error: run: the project hello declares no grant store"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l2_refusal"},

	{kind = .Type, text = "stop(\"edit\")"},
	{kind = .Wait, text = "root: edit stopped: "},

	// Lesson 3: Inspect Real Project Source (`calc/main.c`) and Declarative Lex (`calc/project.lex`).
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER, text = "cb.l3_start"},
	{kind = .Film_Type, text = "edit(\"calc\", \"main.c\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface edit: main.c", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented"},
	{kind = .Move, text = "edit: main.c", to_x = 740, to_y = 44},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_CODE, text = "cb.l3_source"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"edit\")"},
	{kind = .Wait, text = "root: edit stopped: "},

	{kind = .Film_Type, text = "edit(\"calc\", \"project.lex\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface edit: project.lex", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented"},
	{kind = .Move, text = "edit: project.lex", to_x = 740, to_y = 44},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_CODE, text = "cb.l3_lex"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_CODE, text = "cb.l3_recipe"},
	{kind = .Front, text = "console"},
	{kind = .Type, text = "stop(\"edit\")"},
	{kind = .Wait, text = "root: edit stopped: "},

	// Lesson 4: Content-Addressed Ingestion & Sandboxed Local Build.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER, text = "cb.l4_start"},
	{kind = .Film_Type, text = "tree = \"calc\" |> recipes.ingest_tree"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Film_Type, text = "tree"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {calc_here}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l4_ingest"},

	{kind = .Film_Type, text = "pkg = \"calc\" |> recipes.build_project(\"build_only\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Film_Type, text = "pkg"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   recipe   {calc_recipe}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l4_build"},

	{kind = .Film_Type, text = "pkg.recipe |> recipes.provenance"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   origin  local_build"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l4_provenance"},

	// Lesson 5: Live In-OS QUIC Cache Upload & Cryptographic Verification.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER, text = "cb.l5_start"},
	{kind = .Film_Type, text = "recipes.publisher_key()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] {cache_signer_key}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_key"},

	{kind = .Film_Type, text = "pub = pkg.recipe |> recipes.publish"},
	{kind = .Key, text = "esc"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: published recipe {calc_recipe}"},
	{kind = .Film_Type, text = "pub"},
	{kind = .Key, text = "esc"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   bytes_uploaded"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_publish"},

	{kind = .Film_Type, text = "verified = \"calc\" |> recipes.build_project(\"verify\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "recipes: build completed with outcome "},
	{kind = .Film_Type, text = "verified"},
	{kind = .Key, text = "esc"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console]   recipe   {calc_recipe}"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_verify"},

	{kind = .Film_Type, text = "recipes.status()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "verify_agreements"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_status"},

	{kind = .Film_Type, text = "recipes.collect_garbage()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "[console] marked "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l5_gc"},

	// Lesson 6: Delivering, Running, Installing & Copy-on-Write Source History.
	{kind = .Type, text = "clear()"},
	{kind = .Wait, text = "[console] > clear()"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER, text = "cb.l6_start"},
	{kind = .Film_Type, text = "mod = pkg.output |> recipes.deliver_module(\"module\", \"calc\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "module_files: put calc: "},
	{kind = .Film_Type, text = "run(\"calc\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "console: ran calc, module "},
	{kind = .Wait, text = "[console] 84"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l6_deliver"},

	{kind = .Film_Type, text = "projects.install(\"calc\", \"prefer_cache\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "module_files: put calc: "},
	{kind = .Wait, text = "[console]   module   "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_TEACH, text = "cb.l6_install"},

	// Re-open hello.c: show its copy-on-write source history (v1 square(6) vs v2 square(6) + 6)
	// and restore v1 atomically with Ctrl+Z.
	{kind = .Film_Type, text = "edit(\"hello\", \"hello.c\")"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_BEFORE_ENTER},
	{kind = .Key, text = "ret"},
	{kind = .Wait, text = "compositor: surface edit: hello.c", any_order = true},
	{kind = .Wait, text = "edit: ok, the first picture is presented"},
	{kind = .Move, text = "edit: hello.c", to_x = 740, to_y = 44},
	{kind = .Front, text = "edit: hello.c"},
	{kind = .Key, text = "ctrl-h"},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_CODE, text = "cb.l6_versions"},
	{kind = .Key, text = "ctrl-z"},
	{kind = .Wait, text = "edit: undo: the text has "},
	{kind = .Film_Hold, milliseconds = COURSE_HOLD_CODE, text = "cb.l6_undo"},

	// Recap card is spliced cleanly after Film_Stop.
	{kind = .Film_Stop},
	{kind = .Quit},
}
