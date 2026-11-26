// Self-contained six-lesson practical course Part 2 video composition for
// `modustool film course_building`
// (src/md/infrastructure/course_building_film.md; docs/COURSE_BUILDING.md).
//
// Uses two-panel 1920x1080 teaching slides (left plain-English explanation
// blocks + right syntax-highlighted JetBrains Mono code panel + bottom
// key-rule callout) and syntax-colored two-line lower-third captions anchored
// directly to build/films/course_building.cues.
package machine

// Two-panel teaching slide deck: Intro + 6 lesson slides + Recap.

@(private = "file", rodata)
cb_intro_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "From One-Line C to Project Stores",
		body    = "Prototype freestanding C inline with `compile_c`, then move into\nversioned project stores using `projects.new`, `edit`, `build`,\nand `run` with automatic local caching and declared grants.",
	},
	{
		heading = "Reproducible Declarations in Pure Lex",
		body    = "Declare multi-file builds in `project.lex` with `let ... in`,\n`with` overrides, checked units (`2 MiB`, `4 MiB`), `here()`,\nand exact `catalog.modules.*` builder hashes.",
	},
	{
		heading = "Signed QUIC Cache Publishing and Verify",
		body    = "Publish verified output closures over QUIC directly from the\nconsole using `recipes.publish`, prove byte-for-byte agreement\nin `verify` mode, and deliver or install modules in one step.",
	},
}

@(private = "file", rodata)
cb_intro_code := [13]string {
	"// Six live lessons in Part 2:",
	"",
	"// 1. Inline sandboxed C prototyping",
	"a = compile_c(\"adder\", \"long add(...)\")",
	"// 2. Iterative projects: edit/build/run",
	"projects.new(\"hello\")",
	"// 3. Declarative project.lex recipes",
	"edit(\"calc\", \"project.lex\")",
	"// 4. Content-addressed sandboxed build",
	"pkg = \"calc\" |> recipes.build_project()",
	"// 5. In-OS QUIC publish + verify mode",
	"pub = pkg.recipe |> recipes.publish",
	"// 6. Deliver, projects.install, Ctrl+H",
}

@(private = "file", rodata)
cb_lesson1_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Compile Freestanding C Inside modus",
		body    = "`compile_c(name, source)` runs the boot image's `c_compiler` and\n`assemble` modules, validates the `.module` binary, and spawns a\nzero-grant isolated child bound to your variable (`a = ...`).",
	},
	{
		heading = "Inspect Exports with Built-In Help",
		body    = "Bare `compile_c` refuses before compiling so no prototype ever\nshadows global commands. Run `help(a)` to inspect the exact\ntyped signatures exported by handle `a`.",
	},
	{
		heading = "Call Across the Ring and Unload Cleanly",
		body    = "Calling `a.add(19, 23)` executes inside `a`'s sandboxed child\nprocess and returns `42`. Calling `unload(a)` stops that child\nimmediately and frees all `a.*` commands.",
	},
}

@(private = "file", rodata)
cb_lesson1_code := [13]string {
	"a = compile_c(",
	"  \"adder\",",
	"  \"long add(long x, long y) { return x + y; }\"",
	")",
	"// binds a zero-grant child under a.*",
	"",
	"help(a)",
	"// prints a.add(x: Integer, y: Integer)",
	"",
	"a.add(19, 23)",
	"=> 42 // runs across isolated call ring",
	"",
	"unload(a) // stops child, frees a.*",
}

@(private = "file", rodata)
cb_lesson2_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Project Stores and Copy-on-Write Editing",
		body    = "`projects.new(\"hello\")` creates a dedicated project store.\n`edit(\"hello\", \"hello.c\")` opens the source file and commits\nevery editing pause atomically as a new store generation.",
	},
	{
		heading = "Deterministic Builds and Cache Hits",
		body    = "`build(\"hello\", \"hello.c\")` compiles in a zero-network sandbox\nand writes the validated module to `module_files`. Building the\nunchanged source again substitutes the cached module at once.",
	},
	{
		heading = "Zero-Grant Execution and Grant Refusals",
		body    = "`run(\"hello\")` executes `main()` inside a zero-grant call host\nand prints `42`. Requesting an undeclared grant such as\n`run(\"hello\", \"store\")` refuses before any child process starts.",
	},
}

@(private = "file", rodata)
cb_lesson2_code := [13]string {
	"projects.new(\"hello\")",
	"edit(\"hello\", \"hello.c\")",
	"// type: long main(void) { return 42; }",
	"",
	"build(\"hello\", \"hello.c\")",
	"// compiles in sandbox -> module_files",
	"run(\"hello\")",
	"=> 42 // runs in zero-grant call host",
	"",
	"build(\"hello\", \"hello.c\")",
	"// unchanged hash -> instant cache hit",
	"run(\"hello\", \"store\")",
	"// refused: hello declares no grant store",
}

@(private = "file", rodata)
cb_lesson3_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Reusable Local Bindings and Unit Checks",
		body    = "Use `let ... in` to define base build records (`default_build`)\nwith checked size units (`2 MiB`) and derive variants strictly\nwith `default_build with { heap = 4 MiB }`.",
	},
	{
		heading = "Content-Addressed Inputs via here()",
		body    = "`here()` evaluates to the canonical `MODTREE2` BLAKE3 hash of\nthe project store (`\"calc\"`). Pinning `catalog.modules.*` fixes\nthe exact compiler, assembler, host, and builder binaries.",
	},
	{
		heading = "Recipes and Scoped Project Consoles",
		body    = "`recipe(catalog.modules.c_builder, release_build)` turns inputs\nand arguments into one recipe hash. The `console` block names\nonly the modules and store rights that project consoles need.",
	},
}

@(private = "file", rodata)
cb_lesson3_code := [13]string {
	"let",
	"  default_build = {",
	"    source = here(), path = \"main.c\",",
	"    compiler = catalog.modules.c_compiler,",
	"    assembler = catalog.modules.assemble,",
	"    host = catalog.modules.host, heap = 2 MiB,",
	"  },",
	"  release_build = default_build",
	"    with { heap = 4 MiB },",
	"in project {",
	"  outputs = { default = recipe(",
	"    catalog.modules.c_builder, release_build) },",
	"}",
}

@(private = "file", rodata)
cb_lesson4_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Freeze and Ingest the Source Tree",
		body    = "`\"calc\" |> recipes.ingest_tree` hashes every file and directory\nin sorted byte order into canonical `MODTREE2` nodes and stores\nthem in `recipes`, returning the exact `here()` tree hash.",
	},
	{
		heading = "Sandboxed Local Build (No_Clock)",
		body    = "`recipes.build_project(\"build_only\")` evaluates `project.lex`\nin an isolated evaluator, then runs `c_builder` with `No_Clock`,\nno network, and a fixed random seed derived from the recipe.",
	},
	{
		heading = "Typed Records and Provenance Lookup",
		body    = "`pkg` is a typed `Project_Build` record (`outcome`, `recipe`,\n`output`). Pipe `pkg.recipe |> recipes.provenance` directly to\nread `origin: local_build` without copying raw hashes by hand.",
	},
}

@(private = "file", rodata)
cb_lesson4_code := [13]string {
	"tree = \"calc\" |> recipes.ingest_tree",
	"tree",
	"// canonical MODTREE2 hash of calc/",
	"",
	"pkg = \"calc\"",
	"  |> recipes.build_project(\"build_only\")",
	"pkg",
	"// Project_Build: outcome, recipe, output",
	"",
	"pkg.recipe |> recipes.provenance",
	"=> origin  local_build",
	"// dot access avoids copying 64-hex text",
	"// builder ran with No_Clock, no network",
}

@(private = "file", rodata)
cb_lesson5_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Private Publisher Keys Stay in recipes",
		body    = "`recipes.publisher_key()` returns only your principal's Ed25519\npublic key. The signing seed stays sealed inside `recipes`'s\nprivate store and never crosses a call ring or console history.",
	},
	{
		heading = "Bottom-Up Signed QUIC Cache Upload",
		body    = "`pub = pkg.recipe |> recipes.publish` verifies each blob and\ntree node, uploads children before roots over QUIC UDP:5010,\nand signs the `Realisation_Record` with your publisher key.",
	},
	{
		heading = "Verify Reproducibility and Reclaim Space",
		body    = "`recipes.build_project(\"verify\")` pulls the signed realisation\nover QUIC, rebuilds locally, and proves byte-for-byte equality.\n`recipes.status()` and `recipes.collect_garbage()` report stats.",
	},
}

@(private = "file", rodata)
cb_lesson5_code := [13]string {
	"recipes.publisher_key()",
	"// public Ed25519 key only; seed sealed",
	"",
	"pub = pkg.recipe |> recipes.publish",
	"pub // objects_uploaded, bytes_uploaded",
	"",
	"verified = \"calc\"",
	"  |> recipes.build_project(\"verify\")",
	"verified // cache pull == local rebuild",
	"",
	"recipes.status()",
	"=> verify_agreements: 1",
	"recipes.collect_garbage() // sweep store",
}

@(private = "file", rodata)
cb_lesson6_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Deliver Verified Modules and Run Them",
		body    = "`pkg.output |> recipes.deliver_module(\"module\", \"calc\")` reads\nthe verified `.module` entry, validates its format, and stores\nit into `module_files` so `run(\"calc\")` executes it (`84`).",
	},
	{
		heading = "One-Step projects.install Workflow",
		body    = "`projects.install(\"calc\", \"prefer_cache\")` combines ingestion,\n`project.lex` evaluation, cache pull or local build, provenance\ncheck, validation, and delivery in one typed `Project_Install`.",
	},
	{
		heading = "Copy-on-Write Source History in edit",
		body    = "Every edit to `hello.c` commits an immutable store generation.\nPress `Ctrl+H` inside `edit` to toggle the **Versions** pane,\nand press `Ctrl+Z` to restore the prior generation atomically.",
	},
}

@(private = "file", rodata)
cb_lesson6_code := [13]string {
	"mod = pkg.output",
	"  |> recipes.deliver_module(\"module\", \"calc\")",
	"run(\"calc\")",
	"=> 84 // built by c_builder, zero grants",
	"",
	"projects.install(\"calc\", \"prefer_cache\")",
	"// one-step ingest + cache/build + deliver",
	"",
	"edit(\"hello\", \"hello.c\")",
	"// append //v2 -> commits gen N+1",
	"// Ctrl+H -> show Versions history pane",
	"// Ctrl+Z -> atomic storage.restore",
	"=> restores 31-byte v1; history kept",
}

@(private = "file", rodata)
cb_recap_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "One Path from Prototype to Project",
		body    = "Start with `compile_c` in a zero-grant child, grow into project\nstores with `edit`/`build`/`run`, and pin reproducible builds\nin pure Lex `project.lex` declarations.",
	},
	{
		heading = "Cryptographic Cache & Reproducibility",
		body    = "Content-addressed `MODTREE2` trees, `No_Clock` sandboxes, and\nin-OS `recipes.publish` over QUIC let any machine fetch signed\nrealisations or verify byte-for-byte agreement independently.",
	},
	{
		heading = "Verified Delivery and Versioned Source",
		body    = "Use `projects.install` for one-step verified delivery, and rely\non copy-on-write generations (`Ctrl+H` / `Ctrl+Z`) across every\nproject store. Full text: `docs/COURSE_BUILDING.md`.",
	},
}

@(private = "file", rodata)
cb_recap_code := [13]string {
	"// Read the full Part 2 written guide:",
	"//   docs/COURSE_BUILDING.md",
	"//   modus.systems  (courses & guides)",
	"",
	"a = compile_c(\"adder\", \"...\") // inline",
	"build(\"hello\", \"hello.c\")     // cached",
	"pkg = \"calc\" |> recipes.build_project()",
	"pub = pkg.recipe |> recipes.publish",
	"projects.install(\"calc\", \"prefer_cache\")",
	"",
	"// Explore Part 1 and reference guides:",
	"//   docs/COURSE.md  (Part 1)",
	"//   docs/LEX.md     (Lex reference)",
}

course_building_chapter_cards := [8]Tutorial_Chapter_Card {
	{
		id            = "card_cb_0",
		anchor        = .Start_Of_Film,
		duration_ms   = 11000,
		accent        = .System,
		kicker        = "MODUS PRACTICAL COURSE  |  PART 2",
		title         = "Building Programs, Lex Recipes, and QUIC Publishing",
		subtitle      = "A live walkthrough from **compile_c** prototypes to **reproducible project.lex builds** and **signed QUIC cache uploads**.",
		two_panel     = true,
		left_heading  = "WHAT YOU WILL BUILD",
		left_blocks   = cb_intro_blocks[:],
		right_heading = "PART 2 ROADMAP",
		right_lines   = cb_intro_code[:],
		callout       = "**Companion guide:** Every command and declaration in this film is documented in `docs/COURSE_BUILDING.md` on **modus.systems**.",
		footer        = "modus practical course part 2  |  6 live lessons  |  docs/COURSE_BUILDING.md  |  modus.systems",
	},
	{
		id            = "card_cb_1",
		anchor        = .Before_Cue,
		cue_name      = "cb.l1_start",
		duration_ms   = 13000,
		accent        = .Process,
		kicker        = "LESSON 1  |  SANDBOXED C PROTOTYPING",
		title         = "Instant Zero-Grant C Modules with compile_c",
		subtitle      = "Compile C source inline inside **modus**, bind its exports to one variable, inspect with `help(a)`, and unload cleanly.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = cb_lesson1_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = cb_lesson1_code[:],
		callout       = "**Key rule:** `a = compile_c(...)` requires a binding variable and runs your C code in a zero-grant isolated child.",
		footer        = "Lesson 1 of 6  |  Live: compile_c(\"adder\", ...), help(a), a.add(19, 23), unload(a)",
	},
	{
		id            = "card_cb_2",
		anchor        = .Before_Cue,
		cue_name      = "cb.l2_start",
		duration_ms   = 13000,
		accent        = .Process,
		kicker        = "LESSON 2  |  ITERATIVE PROJECTS",
		title         = "Write, Build, Run, Edit, and Rebuild Live",
		subtitle      = "Create a project store with `projects.new`, write multi-line C in `edit`, iterate live with caching, and enforce grants.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = cb_lesson2_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = cb_lesson2_code[:],
		callout       = "**Key rule:** Unchanged builds substitute immediately; edited source recompiles cleanly into a new verified module.",
		footer        = "Lesson 2 of 6  |  Live: edit hello.c -> build -> run (36) -> edit -> rebuild -> run (42)",
	},
	{
		id            = "card_cb_3",
		anchor        = .Before_Cue,
		cue_name      = "cb.l3_start",
		duration_ms   = 13000,
		accent        = .System,
		kicker        = "LESSON 3  |  DECLARATIVE PROJECT.LEX",
		title         = "Project Source Code and Pure Lex Build Specs",
		subtitle      = "Inspect real C source (`main.c`) alongside its reproducible `project.lex` inputs, checked units, and console scopes.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = cb_lesson3_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = cb_lesson3_code[:],
		callout       = "**Key rule:** `here()` and `catalog.modules.*` fix every input byte, so one `project.lex` produces one recipe hash.",
		footer        = "Lesson 3 of 6  |  Live: edit(\"calc\", \"main.c\") and edit(\"calc\", \"project.lex\")",
	},
	{
		id            = "card_cb_4",
		anchor        = .Before_Cue,
		cue_name      = "cb.l4_start",
		duration_ms   = 13000,
		accent        = .System,
		kicker        = "LESSON 4  |  CONTENT-ADDRESSED BUILDS",
		title         = "Ingesting Source Trees and Sandboxed Local Builds",
		subtitle      = "Freeze a project tree into `MODTREE2` nodes, build in a `No_Clock` sandbox, and query typed provenance.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = cb_lesson4_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = cb_lesson4_code[:],
		callout       = "**Key rule:** Builders run with `No_Clock`, zero network, and a recipe-derived seed; pass `pkg.recipe` by field access.",
		footer        = "Lesson 4 of 6  |  Live: recipes.ingest_tree, recipes.build_project(\"build_only\"), recipes.provenance",
	},
	{
		id            = "card_cb_5",
		anchor        = .Before_Cue,
		cue_name      = "cb.l5_start",
		duration_ms   = 13000,
		accent        = .Grant,
		kicker        = "LESSON 5  |  QUIC CACHE PUBLISHING",
		title         = "In-OS Signed QUIC Uploads and Reproducibility Checks",
		subtitle      = "Publish verified output closures with `recipes.publish`, verify byte-for-byte equality, and sweep unused objects.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = cb_lesson5_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = cb_lesson5_code[:],
		callout       = "**Key rule:** Private publisher seeds never leave `recipes`; `verify` mode checks remote cache outputs against local rebuilds.",
		footer        = "Lesson 5 of 6  |  Live: publisher_key(), publish, build_project(\"verify\"), status(), collect_garbage()",
	},
	{
		id            = "card_cb_6",
		anchor        = .Before_Cue,
		cue_name      = "cb.l6_start",
		duration_ms   = 13000,
		accent        = .Version,
		kicker        = "LESSON 6  |  DELIVERY, INSTALL & VERSIONS",
		title         = "Delivering Modules, projects.install, and Source History",
		subtitle      = "Deliver verified outputs to `module_files`, install in one step, and inspect copy-on-write history in `edit`.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = cb_lesson6_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = cb_lesson6_code[:],
		callout       = "**Key rule:** Every delivered module is format-validated before storage; `Ctrl+H` and `Ctrl+Z` keep full source history.",
		footer        = "Lesson 6 of 6  |  Live: deliver_module, run(\"calc\"), projects.install, edit Ctrl+H / Ctrl+Z",
	},
	{
		id            = "card_cb_7",
		anchor        = .End_Of_Film,
		duration_ms   = 11000,
		accent        = .Process,
		kicker        = "PART 2 RECAP",
		title         = "Deterministic, Verified Builds from Console to Cache",
		subtitle      = "Every build on **modus** is sandboxed, content-addressed, cryptographically signed, and versioned on disk.",
		two_panel     = true,
		left_heading  = "WHAT YOU LEARNED",
		left_blocks   = cb_recap_blocks[:],
		right_heading = "KEEP BUILDING",
		right_lines   = cb_recap_code[:],
		callout       = "**Next step:** Read `docs/COURSE_BUILDING.md` and `docs/LEX.md` on **modus.systems** for complete references.",
		footer        = "docs/COURSE_BUILDING.md  |  docs/COURSE.md  |  modus.systems",
	},
}

// Syntax-colored two-line lower-third captions anchored directly to scenario_course_building_film cues.
@(rodata)
course_building_captions := [28]Tutorial_Caption {
	{
		cue_name = "cb.l1_start",
		accent   = .Process,
		kicker   = "LESSON 1  |  INLINE SANDBOXED C",
		heading  = "`a = compile_c(\"adder\", ...)` compiles C into a zero-grant isolated child",
		body     = "The console invokes `c_compiler` and `assemble` from the boot image, validates the `.module`, and binds handle `a`.\nThe `Loaded` record confirms `binding: a`, `module: adder`, `commands: 1`, and `call: isolated`.",
	},
	{
		cue_name = "cb.l1_help",
		accent   = .Process,
		kicker   = "LESSON 1  |  HANDLE HELP",
		heading  = "`help(a)` inspects every typed export bound to handle `a`",
		body     = "Because `compile_c` binds to a plain variable instead of global scope, `a.add` never shadows built-in commands.\n`help(a)` reads the compiled module's export table and shows the exact parameter and return types.",
	},
	{
		cue_name = "cb.l1_call",
		accent   = .Process,
		kicker   = "LESSON 1  |  ISOLATED CALL & UNLOAD",
		heading  = "`a.add(19, 23)` returns `42` across the call ring; `unload(a)` stops the child",
		body     = "Arguments cross shared memory into `a`'s zero-grant process and return typed integer `42` directly to the console.\nNext, `unload(a)` ends the child process cleanly and removes `a.*` from the command table.",
	},
	{
		cue_name = "cb.l2_start",
		accent   = .Process,
		kicker   = "LESSON 2  |  NEW PROJECT STORE",
		heading  = "`projects.new(\"hello\")` creates a dedicated project store for your source",
		body     = "Each project gets its own named store (`\"hello\"`) registered with the `projects` service for principal 0.\nNext, `edit(\"hello\", \"hello.c\")` opens `hello.c` directly inside that project's store.",
	},
	{
		cue_name = "cb.l2_edit",
		accent   = .Version,
		kicker   = "LESSON 2  |  WRITING C SOURCE IN EDIT",
		heading  = "Writing `square(x)` and `main()` commits `hello.c` automatically",
		body     = "When typing pauses, `edit` writes 80 bytes to the `\"hello\"` store as an immutable copy-on-write generation.\nBoth windows stay side by side so you see source code on the right and build/run results on the left.",
	},
	{
		cue_name = "cb.l2_build",
		accent   = .Process,
		kicker   = "LESSON 2  |  SANDBOXED C BUILD",
		heading  = "`build(\"hello\", \"hello.c\")` compiles in a sandbox; `run(\"hello\")` returns `36`",
		body     = "`recipes.build_c` runs `c_compiler` and `assemble` inside zero-grant call hosts and validates the `.module` binary.\nNext, `run(\"hello\")` loads the verified module hash into a zero-grant call host and prints `36`.",
	},
	{
		cue_name = "cb.l2_cached",
		accent   = .System,
		kicker   = "LESSON 2  |  CONTENT-ADDRESSED CACHE HIT",
		heading  = "A second `build(\"hello\", \"hello.c\")` substitutes the cached module at once",
		body     = "`recipes` hashes `hello.c` plus the compiler and assembler hashes and matches the stored local realisation.\nNo compiler runs: `recipes` verifies the stored output bytes and delivers the identical module immediately.",
	},
	{
		cue_name = "cb.l2_iterate",
		accent   = .Process,
		kicker   = "LESSON 2  |  EDIT -> REBUILD -> RUN CYCLE",
		heading  = "Editing `hello.c` to `square(6) + 6` recompiles and `run(\"hello\")` prints `42`",
		body     = "Changing source in `edit` commits a new 84-byte generation; `build` detects the new content hash and recompiles.\n`run(\"hello\")` executes the freshly built module immediately and returns `42`.",
	},
	{
		cue_name = "cb.l2_refusal",
		accent   = .Grant,
		kicker   = "LESSON 2  |  DECLARED GRANT ENFORCEMENT",
		heading  = "`run(\"hello\", \"store\")` refuses because `hello` declares no `store` grant",
		body     = "Every project runs with zero ambient authority; asking for an undeclared grant fails before any call host starts.\nThe refusal names the exact missing grant (`error: run: the project hello declares no grant store`).",
	},
	{
		cue_name = "cb.l3_start",
		accent   = .System,
		kicker   = "LESSON 3  |  OPENING PROJECT SOURCE",
		heading  = "`edit(\"calc\", \"main.c\")` opens the project's C source code directly",
		body     = "Before inspecting `project.lex`, let's read the actual C program stored inside the `\"calc\"` project store.\n`edit` reads `main.c` directly from the content-addressed project store on disk.",
	},
	{
		cue_name = "cb.l3_source",
		accent   = .System,
		kicker   = "LESSON 3  |  C SOURCE OF CALC",
		heading  = "`calc/main.c` defines `double_sum(a, b)` and calls `double_sum(19, 23)` -> `84`",
		body     = "Freestanding C modules compile cleanly with the boot image's `c_compiler` and `assemble` modules.\nNext, `edit(\"calc\", \"project.lex\")` opens the pure Lex declaration that builds this source tree.",
	},
	{
		cue_name = "cb.l3_lex",
		accent   = .System,
		kicker   = "LESSON 3  |  LET, WITH, AND CHECKED UNITS",
		heading  = "`let ... in`, `with`, and `2 MiB` / `4 MiB` define typed build parameters",
		body     = "`default_build` pins `source = here()`, `path = \"main.c\"`, and `catalog.modules.*` for `c_compiler`, `assemble`, and `host`.\n`release_build = default_build with { heap = 4 MiB }` overrides `heap` strictly while preserving every other field.",
	},
	{
		cue_name = "cb.l3_recipe",
		accent   = .System,
		kicker   = "LESSON 3  |  RECIPE & PROJECT CONSOLE",
		heading  = "`recipe(catalog.modules.c_builder, release_build)` defines `outputs.default`",
		body     = "Evaluating `outputs.default` produces one deterministic BLAKE3 recipe hash from the builder and all inputs.\nThe `console` block declares least-privilege modules (`c_builder`) and store rights (`store(\"calc\", .read, .write)`).",
	},
	{
		cue_name = "cb.l4_start",
		accent   = .System,
		kicker   = "LESSON 4  |  CONTENT-ADDRESSED INGESTION",
		heading  = "`tree = \"calc\" |> recipes.ingest_tree` freezes the source store into `recipes`",
		body     = "Every file in `\"calc\"` (`main.c`, `project.lex`) is hashed in sorted byte order into canonical `MODTREE2` nodes.\nEvaluating `tree` on the next line displays the exact 64-hex `here()` root digest stored in `recipes`.",
	},
	{
		cue_name = "cb.l4_ingest",
		accent   = .System,
		kicker   = "LESSON 4  |  CANONICAL MODTREE2 DIGEST",
		heading  = "`tree` holds the canonical `MODTREE2` root hash of `\"calc\"`",
		body     = "Changing even one byte of `main.c` or `project.lex` produces a different `here()` hash and a fresh recipe identity.\nNext, `pkg = \"calc\" |> recipes.build_project(\"build_only\")` evaluates `project.lex` and compiles in a sandbox.",
	},
	{
		cue_name = "cb.l4_build",
		accent   = .Process,
		kicker   = "LESSON 4  |  NO_CLOCK SANDBOXED BUILD",
		heading  = "`pkg` returns a typed `Project_Build` record (`outcome`, `recipe`, `output`)",
		body     = "`c_builder` compiled `main.c` inside a zero-network sandbox with `No_Clock` and a seed derived from `pkg.recipe`.\nBecause `pkg` is a typed record, you pass `pkg.recipe` and `pkg.output` forward by field name instead of copying hashes.",
	},
	{
		cue_name = "cb.l4_provenance",
		accent   = .System,
		kicker   = "LESSON 4  |  PROVENANCE INSPECTION",
		heading  = "`pkg.recipe |> recipes.provenance` confirms `origin: local_build`",
		body     = "`recipes` tracks how every realisation entered your local store: either `local_build` or `remote_cache`.\nBecause we built locally with `\"build_only\"`, `origin` is `local_build` and the signer key is all zeros.",
	},
	{
		cue_name = "cb.l5_start",
		accent   = .Grant,
		kicker   = "LESSON 5  |  PUBLISHER PUBLIC KEY",
		heading  = "`recipes.publisher_key()` returns only your principal's Ed25519 public key",
		body     = "Each principal has its own publisher key stored inside `recipes`'s private store.\nThe private signing seed never leaves `recipes`, never crosses a call ring, and never appears in console history.",
	},
	{
		cue_name = "cb.l5_key",
		accent   = .Grant,
		kicker   = "LESSON 5  |  PUBLISHING OVER QUIC",
		heading  = "The local QUIC object cache trusts this exact Ed25519 publisher key",
		body     = "Next, `pub = pkg.recipe |> recipes.publish` walks the output tree bottom-up, signs each object and realisation,\nand streams them live over QUIC (UDP:5010) to the cache server without leaving the `modus` console.",
	},
	{
		cue_name = "cb.l5_publish",
		accent   = .Process,
		kicker   = "LESSON 5  |  SIGNED QUIC UPLOAD COMPLETE",
		heading  = "`pub` confirms uploaded objects, bytes transferred, and the Ed25519 signer",
		body     = "`recipes.publish` uploaded the compiled `.module` blob before its parent `MODTREE2` tree, then the signed realisation.\nThe `Publish_Result` record reports `objects_uploaded`, `objects_skipped`, `bytes_uploaded`, and `signer`.",
	},
	{
		cue_name = "cb.l5_verify",
		accent   = .Process,
		kicker   = "LESSON 5  |  BYTE-FOR-BYTE VERIFICATION",
		heading  = "`recipes.build_project(\"verify\")` proves remote cache equals local rebuild",
		body     = "`\"verify\"` fetches our freshly published signed realisation over QUIC, verifies its Ed25519 signature and hashes,\nthen rebuilds `calc` locally in the `No_Clock` sandbox and confirms the two outputs match byte for byte.",
	},
	{
		cue_name = "cb.l5_status",
		accent   = .System,
		kicker   = "LESSON 5  |  RECIPES SERVICE COUNTERS",
		heading  = "`recipes.status()` reports `verify_agreements: 1` and zero disagreements",
		body     = "Aggregate service counters track total builds, local and remote cache hits, local builds, and verification outcomes.\nAny non-reproducible build mismatch would increment `verify_disagreements` and refuse automatically.",
	},
	{
		cue_name = "cb.l5_gc",
		accent   = .Version,
		kicker   = "LESSON 5  |  MARK-AND-SWEEP RETENTION",
		heading  = "`recipes.collect_garbage()` sweeps unreferenced content-addressed objects",
		body     = "Mark-and-sweep walks live realisations, registered recipes, and active builds, then removes unreferenced blobs.\nEvery live input and output needed by `\"calc\"` and `\"hello\"` stays intact.",
	},
	{
		cue_name = "cb.l6_start",
		accent   = .Process,
		kicker   = "LESSON 6  |  MODULE DELIVERY",
		heading  = "`recipes.deliver_module(\"module\", \"calc\")` validates and installs `calc`",
		body     = "Reads the `\"module\"` entry from `pkg.output`, checks its BLAKE3 hash and `.module` format, and writes `module_files`.\nThen `run(\"calc\")` executes `calc`'s `main()` in a zero-grant isolated call host.",
	},
	{
		cue_name = "cb.l6_deliver",
		accent   = .Process,
		kicker   = "LESSON 6  |  RUNNING THE DELIVERED MODULE",
		heading  = "`run(\"calc\")` prints `84` from our `project.lex`-built module",
		body     = "The module built by `c_builder`, uploaded over QUIC, and verified byte-for-byte now runs directly in a zero-grant host.\nNext, `projects.install(\"calc\", \"prefer_cache\")` performs the entire workflow in one typed command.",
	},
	{
		cue_name = "cb.l6_install",
		accent   = .Process,
		kicker   = "LESSON 6  |  ONE-STEP PROJECTS.INSTALL",
		heading  = "`projects.install(\"calc\", \"prefer_cache\")` returns a full `Project_Install` record",
		body     = "One command ingests the project, evaluates `project.lex`, checks the cache, validates the module, and delivers it.\nEvery hash (`recipe`, `output`, `module`), `origin`, and `signer` appears cleanly in one typed record.",
	},
	{
		cue_name = "cb.l6_versions",
		accent   = .Version,
		kicker   = "LESSON 6  |  COPY-ON-WRITE SOURCE HISTORY",
		heading  = "Pressing `Ctrl+H` inside `edit` lists every committed revision of `hello.c`",
		body     = "The **Versions** pane on the right lists both our 80-byte `square(6)` commit and our 84-byte `square(6) + 6` edit.\nEach copy-on-write commit stays immutable on disk so earlier source revisions are never overwritten.",
	},
	{
		cue_name = "cb.l6_undo",
		accent   = .Version,
		kicker   = "LESSON 6  |  ATOMIC GENERATION RESTORE",
		heading  = "Pressing `Ctrl+Z` restores the earlier generation atomically via `storage.restore`",
		body     = "`edit` steps back to the earlier source revision live while keeping the newer `hello.c` commit in history.\nRead `docs/COURSE_BUILDING.md` on **modus.systems** for the complete Part 2 written guide.",
	},
}

// course_building_film_write composes the six-lesson 1920x1080 Part 2 course film.
course_building_film_write :: proc(name: string) -> bool {
	return chaptered_film_write(name, course_building_chapter_cards[:], course_building_captions[:])
}
