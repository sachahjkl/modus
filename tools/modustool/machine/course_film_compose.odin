// Self-contained five-lesson practical course video composition for
// `modustool film course` (src/md/infrastructure/course_film.md; docs/COURSE.md).
//
// Uses two-panel 1920x1080 visual teaching slides (left explanation blocks +
// right syntax-highlighted JetBrains Mono code panel + bottom key-rule callout)
// and rich syntax-colored lower-third captions anchored to build/films/course.cues.
package machine

// Two-panel teaching slide deck: Intro + 5 lesson slides + Recap.

@(private = "file", rodata)
course_intro_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Typed Data and One Language (Lex)",
		body    = "Every command returns typed **Tables**, **Records**, **Units**, and **Enums**.\nThe same language (`Lex`) runs interactive console lines and\ndeclarative system plans with schema checks before execution.",
	},
	{
		heading = "Explicit Isolation and Capabilities",
		body    = "Processes start with **zero ambient authority** and receive only\nexplicit, revocable kernel handles. Four execution verbs let you\nchoose app, service, zero-grant sandbox, or in-process loading.",
	},
	{
		heading = "Trusted Consent and Copy-on-Write History",
		body    = "System changes use declarative `plan { ... }` values reviewed on\nthe **trusted display**. Every store commit keeps an immutable\ncopy-on-write generation you can preview and restore anytime.",
	},
}

@(private = "file", rodata)
course_intro_code := [13]string {
	"// Five live lessons in this course:",
	"",
	"// 1. Typed tables, units, and enum choices",
	"processes() |> where(threads > 1)",
	"1 MiB + 512 KiB  =>  1536 KiB",
	"",
	"// 2. Isolated libraries and live services",
	"s = isolate(\"sample\")  // zero-grant child",
	"help(\"s.readings\")     // inspect export",
	"",
	"// 3. Declarative plan + trusted consent",
	"// 4. Explicit grants & live Revoke window",
	"// 5. Automatic CoW versions (Ctrl+H)",
}

@(private = "file", rodata)
course_lesson1_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Typed Tables and Records",
		body    = "Every command declares its exact return schema and field units.\n`processes()` returns `Process` rows; `memory()` returns a `Memory`\nrecord whose fields preserve exact byte and page counts.",
	},
	{
		heading = "Exact Unit Arithmetic and Pure Lex",
		body    = "Numbers carry real units such as `MiB`, `KiB`, `ms`, and `s`.\nCompatible units convert cleanly; mismatched units refuse early.\nLocal bindings (`let`, `filter`, `map`) transform lists inline.",
	},
	{
		heading = "Closed Named Choices (Enums)",
		body    = "Settings use dotted choices (`.vector` smooth, `.spleen` pixel).\nThe console validates every choice against the module contract\nand prints every valid member before any service call runs.",
	},
}

@(private = "file", rodata)
course_lesson1_code := [13]string {
	"processes()",
	"  |> where(threads > 1)",
	"  |> columns(name, slot, resident)",
	"  |> sort(\"resident\")",
	"// |> sends typed rows into each stage",
	"",
	"1 MiB + 512 KiB",
	"=> 1536 KiB // exact unit conversion",
	"",
	"settings.set(font = .spleen)",
	"// .vector = smooth outline font",
	"// .spleen = crisp pixel bitmap font",
	"// .comic  = refused with valid members",
}

@(private = "file", rodata)
course_lesson2_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Apps and Background Services",
		body    = "`start(\"name\")` launches a built-in app or pinned disk app with\nits declared grants. `connect(\"service\")` (or `mon = connect(...)`)\nattaches to a running background service under its prefix.",
	},
	{
		heading = "Bound Isolated Handles (Zero Grants)",
		body    = "`s = isolate(\"mod\")` spawns a zero-handle child under `s.<name>`.\nBare `isolate` refuses before spawning so nothing shadows global\ncommands; two handles (`a`, `b`) of one module run side by side.",
	},
	{
		heading = "In-Process Loading, Help, and Unload",
		body    = "`m = load(\"mod\")` maps a trusted module in-process under `m.*`.\nCall `help(s)` to list `s`'s exports, `help(\"s.readings\")` for one\nsignature, and `unload(s)` (or reassign `s`) to close that child.",
	},
}

@(private = "file", rodata)
course_lesson2_code := [13]string {
	"s = isolate(\"sample\")",
	"// binds demo library \"sample\" to s.*",
	"// bare isolate(\"sample\") refuses early",
	"",
	"help(\"s.readings\") // or help(s)",
	"// prints signature & docs of s.readings",
	"",
	"t = s.readings(4)",
	"t |> where(sensor = 2) |> s.sum_values",
	"=> 30 // 4 demo sensor rows -> sum value",
	"",
	"connect(\"monitor\") // adds monitor.*",
	"unload(s)          // closes handle s",
}

@(private = "file", rodata)
course_lesson3_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "System State as Typed Plan Data",
		body    = "A `plan { ... }` value declares desired defaults (`values`) and\nlocked settings (`locks`) as one structured value. Every field\nis validated against its owner's exported schema up front.",
	},
	{
		heading = "Root-Computed Diff on Trusted Display",
		body    = "`plans.apply` asks the root service for the exact change set.\nThe compositor draws the **TRUSTED PLAN DIFFERENCE** dialog\ndirectly, with **Refuse** focused first and a brief arm delay.",
	},
	{
		heading = "Atomic Commit and Generation History",
		body    = "Accepting (`Tab` then `Enter`) commits generation `1` atomically\nand returns its `Plan_Generation_Row` (`standing: Current`).\nEvery generation stays saved so `plans.rollback()` can revert.",
	},
}

@(private = "file", rodata)
course_lesson3_code := [13]string {
	"// Appearance enum choices for settings:",
	"// .auto, .dark, .light (.neon refuses)",
	"",
	"plans.apply(",
	"  \"evening\",",
	"  plan { locks = { settings = {",
	"    appearance = .dark",
	"  } } }",
	") |> columns(generation, standing)",
	"// Tab -> Accept plan, Enter -> commit",
	"=> generation 1, standing Current",
	"plans.generations()",
	"  |> columns(generation, standing)",
}

@(private = "file", rodata)
course_lesson4_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Explicit Capabilities Only",
		body    = "Every process begins with zero ambient file or network access.\nThe root service hands a process only the exact kernel handles\ndeclared in its grant set, such as `log` and its private `store`.",
	},
	{
		heading = "Queryable as a Typed Grant Table",
		body    = "`grants(\"notes\")` queries the root service and returns a `Grant`\ntable listing each `process`, `grant`, `state`, and `principal`.\nFilter with `where(state = \"held\")` to verify active handles.",
	},
	{
		heading = "Live Revocation in the Grants Window",
		body    = "`start(\"grants\")` opens the desktop **Grants** window showing\nevery running process and each active handle beside a **Revoke**\nbutton that closes the kernel handle immediately.",
	},
}

@(private = "file", rodata)
course_lesson4_code := [13]string {
	"start(\"notes\")",
	"// starts notes with only its declared",
	"// log and private store handles",
	"",
	"grants(\"notes\")",
	"  |> where(state = \"held\")",
	"// returns active capability rows:",
	"//  notes  log    held  0  machine",
	"//  notes  store  held  0  machine",
	"",
	"start(\"grants\")",
	"// opens live desktop Grants window",
	"// click Revoke to cut a handle at once",
}

@(private = "file", rodata)
course_lesson5_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Copy-on-Write (CoW) Atomic Storage",
		body    = "Storage writes modified 4 KiB blocks into fresh disk space and\nflips one verified root block atomically. Older blocks remain\nintact, so power loss never leaves a partially written file.",
	},
	{
		heading = "Automatic Timestamped Commits",
		body    = "Applications such as `notes`, `edit`, and `db_browser` commit\nyour latest edits automatically whenever you pause typing.\nEach commit appends an immutable generation to the store.",
	},
	{
		heading = "Instant Preview and Non-Destructive Restore",
		body    = "Press `Ctrl+H` inside a versioned app to open its **Versions**\nlist. Move with `Down` to preview an older state read-only,\nthen press `Enter` to restore it as a new commit.",
	},
}

@(private = "file", rodata)
course_lesson5_code := [13]string {
	"// Inside the running notes window:",
	"",
	"// 1. Type \"modus course\" and pause",
	"//    commits generation N atomically",
	"",
	"// 2. Press Enter + \"second draft line\"",
	"//    commits generation N+1 atomically",
	"",
	"// 3. Press Ctrl+H -> open VERSIONS",
	"// 4. Press Down   -> preview N read-only",
	"// 5. Press Enter  -> restore atomically",
	"=> commits generation N+2; history kept",
	"// works identically in edit & db_browser",
}

@(private = "file", rodata)
course_recap_blocks := [3]Tutorial_Slide_Block {
	{
		heading = "Typed Commands and Built-In Help",
		body    = "Pipe `Table` and `Record` values with `|>`, compute exact `MiB`\nand `ms` units, and rely on closed `.enum` schema checks.\nRun `help(s)` or `help(\"name\")` for any handle or command.",
	},
	{
		heading = "Bound Handles, Plans, and Grants",
		body    = "Bind sandboxes with `s = isolate(...)` and unload via `unload(s)`.\nSystem changes flow through `plan { ... }` consent dialogs,\nand `grants` inspects or revokes live handles at any time.",
	},
	{
		heading = "Versioned Storage and Full Guide",
		body    = "Every store commit preserves copy-on-write generations (`Ctrl+H`).\nContinue with `docs/COURSE.md` for live record streams, audit\nchains, and one-step `projects.install(\"db_browser\")`.",
	},
}

@(private = "file", rodata)
course_recap_code := [13]string {
	"// Continue learning with the guide:",
	"//   docs/COURSE.md  (6 hands-on lessons)",
	"//   modus.systems   (guides & reference)",
	"",
	"help(\"start\")            // apps & disk",
	"help(\"projects.install\") // 1-step build",
	"help(\"plans.apply\")      // plan consent",
	"",
	"// Try these commands in the console:",
	"processes() |> sort(\"resident\")",
	"grants(\"notes\") |> where(state = \"held\")",
	"plans.generations()",
	"  |> columns(generation, standing)",
}

course_chapter_cards := [7]Tutorial_Chapter_Card {
	{
		id            = "card_course_0",
		anchor        = .Start_Of_Film,
		duration_ms   = 11000,
		accent        = .System,
		kicker        = "MODUS PRACTICAL COURSE",
		title         = "Inside modus: five core properties in action",
		subtitle      = "A hands-on walkthrough of **typed commands**, **explicit isolation**, **declarative plans**, **grants**, and **versioned storage**.",
		two_panel     = true,
		left_heading  = "WHAT MAKES MODUS DIFFERENT",
		left_blocks   = course_intro_blocks[:],
		right_heading = "COURSE ROADMAP",
		right_lines   = course_intro_code[:],
		callout       = "**Course guide:** Every concept shown here is documented step by step in `docs/COURSE.md` on **modus.systems**.",
		footer        = "modus practical course  |  5 live lessons  |  docs/COURSE.md  |  modus.systems",
	},
	{
		id            = "card_course_1",
		anchor        = .Before_Cue,
		cue_name      = "course.l1_start",
		duration_ms   = 13000,
		accent        = .System,
		kicker        = "LESSON 1  |  TYPED DATA & LEX",
		title         = "Typed Console Functions, Units, and Named Choices",
		subtitle      = "Every command returns structured **Tables** and **Records** validated against its module contract.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = course_lesson1_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = course_lesson1_code[:],
		callout       = "**Key rule:** Field names, size/time units, and dotted `.enum` choices are verified before any call runs.",
		footer        = "Lesson 1 of 5  |  Live: processes(), memory(), unit math, filter/map, and enum refusal",
	},
	{
		id            = "card_course_2",
		anchor        = .Before_Cue,
		cue_name      = "course.l2_start",
		duration_ms   = 13000,
		accent        = .Process,
		kicker        = "LESSON 2  |  RUNNING CODE",
		title         = "How modus Runs Apps, Services, and Libraries",
		subtitle      = "Four explicit console verbs make **process isolation** and **authority** visible every time you run code.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = course_lesson2_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = course_lesson2_code[:],
		callout       = "**Key rule:** `s = isolate(\"mod\")` binds a zero-grant child under `s.*`; `connect(\"svc\")` uses `svc.*`.",
		footer        = "Lesson 2 of 5  |  Live: s = isolate(\"sample\"), help(\"s.readings\"), s.readings(4), connect(\"monitor\")",
	},
	{
		id            = "card_course_3",
		anchor        = .Before_Cue,
		cue_name      = "course.l3_start",
		duration_ms   = 13000,
		accent        = .Grant,
		kicker        = "LESSON 3  |  DECLARATIVE PLANS",
		title         = "Declarative Plans and Trusted Display Consent",
		subtitle      = "System defaults and locks are written as typed `plan { ... }` data and approved on the **trusted display**.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = course_lesson3_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = course_lesson3_code[:],
		callout       = "**Key rule:** Nothing commits until you deliberately accept the root-computed diff on the trusted display.",
		footer        = "Lesson 3 of 5  |  Live: schema refusal (.neon), trusted consent dialog, standing: Current",
	},
	{
		id            = "card_course_4",
		anchor        = .Before_Cue,
		cue_name      = "course.l4_start",
		duration_ms   = 13000,
		accent        = .Grant,
		kicker        = "LESSON 4  |  CAPABILITY GRANTS",
		title         = "Zero Ambient Authority and Live Grant Inspection",
		subtitle      = "Every process starts with **zero access** and holds only explicit, revocable **kernel handles**.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = course_lesson4_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = course_lesson4_code[:],
		callout       = "**Key rule:** Authority is never inherited; every handle is inspectable via `grants()` and revocable live.",
		footer        = "Lesson 4 of 5  |  Live: start(\"notes\"), grants(\"notes\") |> where(state = \"held\"), start(\"grants\")",
	},
	{
		id            = "card_course_5",
		anchor        = .Before_Cue,
		cue_name      = "course.l5_start",
		duration_ms   = 13000,
		accent        = .Version,
		kicker        = "LESSON 5  |  COPY-ON-WRITE VERSIONS",
		title         = "Automatic Copy-on-Write Storage and Time Travel",
		subtitle      = "Every pause commits an **immutable generation** atomically so you can preview and restore any past state.",
		two_panel     = true,
		left_heading  = "HOW IT WORKS & WHY",
		left_blocks   = course_lesson5_blocks[:],
		right_heading = "HOW TO USE IT",
		right_lines   = course_lesson5_code[:],
		callout       = "**Key rule:** Restoring an older version appends a new atomic commit; earlier and later versions stay intact.",
		footer        = "Lesson 5 of 5  |  Live: notes auto-commits, Ctrl+H Versions preview, Enter atomic restore",
	},
	{
		id            = "card_course_6",
		anchor        = .End_Of_Film,
		duration_ms   = 11000,
		accent        = .Process,
		kicker        = "COURSE RECAP",
		title         = "Five Properties, One Coherent System",
		subtitle      = "Every layer of **modus** shares typed contracts, explicit capabilities, trusted consent, and versioned storage.",
		two_panel     = true,
		left_heading  = "WHAT YOU LEARNED",
		left_blocks   = course_recap_blocks[:],
		right_heading = "KEEP EXPLORING",
		right_lines   = course_recap_code[:],
		callout       = "**Next step:** Read `docs/COURSE.md` on **modus.systems** for record streams, audit chains, and `projects.install`.",
		footer        = "docs/COURSE.md  |  modus.systems",
	},
}

// Syntax-colored two-line lower-third captions anchored directly to scenario_course_film cues.
@(rodata)
course_captions := [17]Tutorial_Caption {
	{
		cue_name = "course.l1_start",
		accent   = .System,
		kicker   = "LESSON 1  |  TYPED TABLE PIPELINES",
		heading  = "`processes()` returns a typed `Process` table you filter and sort directly",
		body     = "`|>` passes the table from `processes()` into `where(threads > 1)`, `columns(...)`, and `sort(\"resident\")`.\nNotice `(pages)` in the `resident` column header: every column preserves its real type and unit.",
	},
	{
		cue_name = "course.l1_memory",
		accent   = .System,
		kicker   = "LESSON 1  |  TYPED RECORDS",
		heading  = "`memory()` returns a structured `Memory` record with exact unit fields",
		body     = "Each field carries its true quantity: `MiB` for total/free RAM, `pages` for resident/reserved budgets, and handle counts.\nAssign `m = memory()` and read `m.free` directly in later console lines.",
	},
	{
		cue_name = "course.l1_units",
		accent   = .System,
		kicker   = "LESSON 1  |  EXACT UNITS & PURE LEX",
		heading  = "Exact unit conversion and functional list pipelines in one language",
		body     = "`1 MiB + 512 KiB` converts cleanly to `1536 KiB` (incompatible units such as `1 MiB + 1 ms` refuse before running).\n`let double = (x) => x * 2` binds a local function; `filter` keeps `[3, 4]` and `map(double)` returns `[6, 8]`.",
	},
	{
		cue_name = "course.l1_enum_refusal",
		accent   = .Grant,
		kicker   = "LESSON 1  |  CLOSED ENUM CHECKS",
		heading  = "Dotted `.enum` choices are validated against the module contract first",
		body     = "`settings.set(font = .comic)` checks `Font` before contacting the `settings` service.\nThe refusal names the enum and lists its exact valid choices: `.vector` (smooth outline) and `.spleen` (pixel bitmap).",
	},
	{
		cue_name = "course.l2_start",
		accent   = .Process,
		kicker   = "LESSON 2  |  BOUND ISOLATED HANDLES",
		heading  = "`s = isolate(\"sample\")` binds a zero-grant child under `s.*`",
		body     = "Bare `isolate(\"sample\")` refuses before spawning so no library ever pollutes or shadows global commands.\nBinding `s` keeps all 12 exports of `sample` under `s.*` and lets multiple isolated instances coexist.",
	},
	{
		cue_name = "course.l2_help",
		accent   = .Process,
		kicker   = "LESSON 2  |  BUILT-IN HANDLE HELP",
		heading  = "`help(\"s.readings\")` prints one export; `help(s)` lists all exports of `s`",
		body     = "Every export and record constructor of `s` stays scoped under `s.<name>`, keeping the global namespace clean.\n`help(\"s.readings\")` confirms it takes `count: Integer` and returns a `Table(Reading)` of demo sensor rows.",
	},
	{
		cue_name = "course.l2_shorthand",
		accent   = .Process,
		kicker   = "LESSON 2  |  ISOLATED HANDLE PIPELINES",
		heading  = "Typed tables flow across the sandbox border into `s.sum_values`",
		body     = "`t = s.readings(4)` fetches 4 demo `Reading` rows (`sensor` 0..3, values 10..40) across the call ring.\n`t |> where(sensor = 2) |> s.sum_values` filters row `sensor = 2` in the console and sums its value (`30`) in the child.",
	},
	{
		cue_name = "course.l2_connect",
		accent   = .Process,
		kicker   = "LESSON 2  |  SERVICES & UNLOADING HANDLES",
		heading  = "`connect(\"monitor\")` attaches to a service; `unload(s)` closes handle `s`",
		body     = "Connected services use `monitor.served()` (or an explicit handle `mon = connect(\"monitor\")`).\nCalling `unload(s)` or reassigning `s` stops only `s`'s sandboxed child process and reclaims its command names.",
	},
	{
		cue_name = "course.l3_start",
		accent   = .Grant,
		kicker   = "LESSON 3  |  SCHEMA CHECKS ON PLANS",
		heading  = "`plan { ... }` catches invalid enum values before any consent dialog opens",
		body     = "`settings.appearance` accepts only `.auto`, `.dark`, or `.light` for the display theme.\nPassing `.neon` fails immediately against `settings`' exported schema; no dialog opens and nothing changes.",
	},
	{
		cue_name = "course.l3_plan_dialog",
		accent   = .Grant,
		kicker   = "LESSON 3  |  TRUSTED DISPLAY CONSENT",
		heading  = "`plans.apply` opens the root-computed diff on the trusted display",
		body     = "The compositor draws **TRUSTED PLAN DIFFERENCE** directly (`plan evening`, `+ lock settings.appearance = 1`).\n**Refuse** is focused first after an arm delay; pressing `Tab` then `Enter` accepts and commits in one step.",
	},
	{
		cue_name = "course.l3_plan_applied",
		accent   = .Process,
		kicker   = "LESSON 3  |  ATOMIC PLAN COMMIT & HISTORY",
		heading  = "`plans.apply` commits generation `1` (`Current`); `plans.generations()` lists history",
		body     = "Piping `|> columns(generation, standing)` displays the typed `standing` enum (`Current`) with zero raw hashes.\nEvery accepted plan stays versioned in `plans` so `plans.rollback()` can revert through the same consent dialog.",
	},
	{
		cue_name = "course.l4_start",
		accent   = .Grant,
		kicker   = "LESSON 4  |  CAPABILITY INSPECTION",
		heading  = "`grants(\"notes\")` lists every kernel capability as a filterable table",
		body     = "`start(\"notes\")` launches the notes app on the right with only its declared `log` and private `store` handles.\n`grants(\"notes\") |> where(state = \"held\")` confirms those exact two grants and zero network or foreign store access.",
	},
	{
		cue_name = "course.l4_grants_window",
		accent   = .Grant,
		kicker   = "LESSON 4  |  DESKTOP GRANTS WINDOW",
		heading  = "`start(\"grants\")` opens live capability inspection and revocation",
		body     = "The **grants** window on the right lists every running process and each active handle beside a **Revoke** button.\nRevoking a grant closes the live kernel handle immediately without restarting the rest of the system.",
	},
	{
		cue_name = "course.l5_start",
		accent   = .Version,
		kicker   = "LESSON 5  |  AUTOMATIC COPY-ON-WRITE COMMITS",
		heading  = "Typing in `notes` commits a copy-on-write generation automatically",
		body     = "Pausing after typing `\"modus course\"` writes modified 4 KiB blocks and flips the store root atomically.\nOlder blocks stay untouched on disk so every committed state remains available for instant time travel.",
	},
	{
		cue_name = "course.l5_second_edit",
		accent   = .Version,
		kicker   = "LESSON 5  |  IMMUTABLE GENERATIONS",
		heading  = "Adding `\"second draft line\"` appends a new generation beside the first",
		body     = "When typing pauses again, storage writes a fresh generation while preserving the previous `\"modus course\"` commit.\nBoth generations carry exact timestamps in the store's copy-on-write history tree.",
	},
	{
		cue_name = "course.l5_versions_preview",
		accent   = .Version,
		kicker   = "LESSON 5  |  CTRL+H VERSION PREVIEW",
		heading  = "`Ctrl+H` opens **VERSIONS**; `Down` previews an earlier commit read-only",
		body     = "The left pane lists committed timestamps newest-first; selecting the older entry previews `\"modus course\"` safely.\nThe exact same copy-on-write storage model powers `notes`, `edit`, and `db_browser` (SQLite) across **modus**.",
	},
	{
		cue_name = "course.l5_versions_restored",
		accent   = .Process,
		kicker   = "LESSON 5  |  ATOMIC NON-DESTRUCTIVE RESTORE",
		heading  = "Pressing `Enter` restores `\"modus course\"` as a brand-new commit",
		body     = "Restoring appends a new generation pointing back to the chosen snapshot; `\"second draft line\"` remains in history.\nRead `docs/COURSE.md` on **modus.systems** for Lesson 6: streams, audit chains, and `projects.install`.",
	},
}

// course_film_write composes the five-lesson 1920x1080 course film.
course_film_write :: proc(name: string) -> bool {
	return chaptered_film_write(name, course_chapter_cards[:], course_captions[:])
}
