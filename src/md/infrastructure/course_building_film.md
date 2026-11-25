# Course Part 2 film (`course_building`)

`modustool film course_building` records and composes a self-contained, six-lesson practical developer course video teaching how to prototype C code in a zero-grant sandbox, build and run iterative projects, declare reproducible build environments in `project.lex`, execute sandboxed local builds, publish signed closures over QUIC directly from the `modus` console, and verify, deliver, run, and version the resulting modules. It is paired directly with [`docs/COURSE_BUILDING.md`](../../../docs/COURSE_BUILDING.md).

## Purpose

Part 1 (`modustool film course`, [course_film.md](course_film.md)) teaches the daily console, bound module handles, declarative plans, capabilities, and copy-on-write storage. Part 2 (`modustool film course_building`) teaches the complete software-building and publishing loop on `modus` — what each primitive is, how its sandbox and cryptographic verification work internally, and how to use it live from the console.

## Constraints

- **Every command runs live inside QEMU.** No mocked output, no pre-baked screenshots, and zero private Ed25519 seeds ever shown on screen. An ephemeral host QUIC `cache_server` runs on `127.0.0.1:0` (forwarded to `10.0.2.100:5010` via QEMU `cache_endpoint`) with a deterministic test-only uploader key authorized in `cache_server_open`; off-camera setup runs `recipes.configure_cache`, `recipes.configure_publisher`, `projects.new("calc")`, and `clear()` before `Film_Start`.
- **Two-panel syntax-highlighted slides and rich captions.** Reuses the shared 1920 by 1080 two-panel slide renderer (`tutorial_card_ppm_encode_slide`), `tutorial_ass_format_rich`, `tutorial_ass_format_code_line`, and `chaptered_film_write` from `tools/modustool/machine/tutorial_film_compose.odin`. Each of the six lessons opens with a 6.5-second two-panel slide (`HOW IT WORKS & WHY` left panel, dark `JetBrains Mono` syntax-highlighted `HOW TO USE IT` right panel, and accent-tinted `Key rule` strip), paired with 5.2-second live holds and two-line syntax-colored lower-third captions.
- **Zero timing drift and zero UI overlap.** Every slide and caption anchors to `build/films/course_building.cues` ([film_cues.md](film_cues.md)). At 1.25x UI scale, `console` (`24, 44`) and `edit` (`700, 44` / `740, 44`) stay within physical `y = 45..805`, leaving the lower-third caption band (`y = 856..1036`) completely clear.
- **Native 1080p and 4 MiB WebM bound.** Encodes 1920 by 1080 (`30 fps`) into `build/films/course_building.mp4` (H.264) and `build/films/course_building.webm` (AV1, silent, `<= checks.FILM_DOCUMENT_SIZE_LIMIT`, 4 MiB) with NVENC auto-detection and CPU fallback, and copies the WebM to `docs/films/course_building.webm` when named by a news entry.

## The chosen form

### Lightweight seeded fixture (`course_building_film_setup.odin`)

`course_building_film_prepare` creates a STORAGE7 data disk containing a `"calc"` project store (`main.c` returning `84`, plus a 22-line `project.lex` using `let ... in`, `with`, `2 MiB` / `4 MiB` typed units, `here()`, `recipe(catalog.modules.c_builder, release_build)`, and `console = { modules = [...], stores = [...] }`), and starts an ephemeral host QUIC `cache_server` authorizing the principal's deterministic test publisher public key. Because `recipes` resolves `c_builder`, `c_compiler`, `assemble`, and `host` directly from the verified boot image, the fixture needs no pre-built outside modules and prepares in under one second.

### Six live lessons plus intro and recap two-panel slides

1. **Intro slide (`card_cb_0`, 5.5 s)**: overview of the complete `modus` software build and publishing loop.
2. **Lesson 1 (`card_cb_1`, `cb.l1_*`)**: instant sandboxed C prototyping (`a = compile_c("adder", "long add(long x, long y) { return x + y; }")`, `help(a)`, `a.add(19, 23)` returning `42`, and `unload(a)`).
3. **Lesson 2 (`card_cb_2`, `cb.l2_*`)**: iterative projects (`projects.new("hello")`, `edit("hello", "hello.c")`, first `build("hello", "hello.c")` compiling in a `No_Clock` zero-network sandbox, `run("hello")` returning `42`, second `build("hello", "hello.c")` hitting instant local cache substitution, and `run("hello", "store")` refused because `hello` declares no `store` grant).
4. **Lesson 3 (`card_cb_3`, `cb.l3_*`)**: opening `edit("calc", "project.lex")` live on screen to walk through `let ... in`, `with`, typed size units (`2 MiB`, `4 MiB`), `here()`, `recipe(catalog.modules.c_builder, ...)`, and `console = { modules, stores }`.
5. **Lesson 4 (`card_cb_4`, `cb.l4_*`)**: content-addressed ingestion and sandboxed local build (`tree = "calc" |> recipes.ingest_tree`, `pkg = "calc" |> recipes.build_project("build_only")`, `pkg.recipe |> recipes.provenance` showing `origin: local_build`).
6. **Lesson 5 (`card_cb_5`, `cb.l5_*`)**: live in-OS QUIC cache publishing and verification (`recipes.publisher_key()` showing only the public key, `pub = pkg.recipe |> recipes.publish` uploading the closure bottom-up and signed realisation over QUIC, `verified = "calc" |> recipes.build_project("verify")` pulling over QUIC and rebuilding locally to prove byte-for-byte determinism, `recipes.status()` showing `verify_agreements: 1`, and `recipes.collect_garbage()`).
7. **Lesson 6 (`card_cb_6`, `cb.l6_*`)**: delivering, running, and versioning (`mod = pkg.output |> recipes.deliver_module("module", "calc")`, `run("calc")` returning `84`, `projects.install("calc", "prefer_cache")` demonstrating one-step install, and `edit("hello", "hello.c")` + `Ctrl+H` showing copy-on-write source history), followed by the Recap slide (`card_cb_7`, 5.5 s).

## The refused forms

- **Reusing the heavy `tutorial_film_prepare` fixture.** `tutorial_film_prepare` builds `sqlite.module` and `db_browser.module` from outside C/Odin sources to seed a pre-built cache hit. Course Part 2 teaches building natively inside `modus` and publishing live from the console, so a lightweight `"calc"` data disk plus an empty authorized QUIC cache server proves that every published object originated inside QEMU.
- **Typing private signing seeds on camera.** Exposing a 64-hex Ed25519 seed on screen contradicts the security model of `recipes.publisher_key()`. Configuring the test publisher seed off-camera before `clear()` and `Film_Start` ensures only public keys and content hashes appear on screen.
