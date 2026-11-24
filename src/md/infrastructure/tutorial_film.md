# Tutorial film

`modustool film tutorial` records and composes a self-contained, seven-chapter developer tutorial showing how to declare, cache-build, verify, grant, run, and time-travel one real sandboxed GUI application (`db_browser`) on `modus`.

## Purpose

A raw screencast of console commands and 64-character hexadecimal hashes teaches a viewer nothing without external editing. The tutorial film must stand on its own as a silent video (`docs/SITE.md`, "The film of a news entry"): crisp chapter title cards, generous on-screen explanations driven by exact machine cues, authentic `project.lex` code shown on screen, zero hand-typed 64-hex hashes, and WebM AV1 output strictly within the 4 MiB site budget.

## Constraints

- **One coherent story.** The scenario focuses solely on `db_browser` (an outside Lex project running `sqlite.module` inside a zero-grant child call host). No unrelated fixture (`collatz`) appears.
- **Zero timing drift.** Every chapter title card and lower-third caption is anchored to the cue timestamps written in `build/films/tutorial.cues` ([film_cues.md](film_cues.md)), never hand-guessed wall-clock delays.
- **Zero UI overlap.** The reference screen is 1920 by 1080 at 1.25x UI scale (`1536x864` logical). Windows (`console`, `edit: project.lex`, `grants`, and `db_browser` resized to `1080x580` logical) stay within physical `x = 30..1892` and `y = 45..805`, so the lower-third caption band (`y = 856..1036`, `x = 180..1740`) never covers console output, editor text, grant rows, or `db_browser`'s status and action bars.
- **Native 1080p and 4 MiB WebM bound.** The tutorial renders at 1920 by 1080 (`30 fps`) into `build/films/tutorial.mp4` (H.264) and `build/films/tutorial.webm` (AV1, silent, `<= checks.FILM_DOCUMENT_SIZE_LIMIT`, 4 MiB).
- **Zero raw 64-hex hash typing.** `recipes.build_project` and `recipes.provenance` return typed `Record` values (`Project_Build` and `Provenance`), so the console chains `tree`, `pkg.recipe`, `pkg.output`, and `mod` through Lex variables and pipes. Cache trust setup runs off-camera before `Film_Start` and clears the screen with `clear()`.

## The chosen form

### Seven chapters

1. **Intro card and desktop (`tutorial.intro`)**: dark chapter card introducing the story, followed by the clean `modus` desktop and Lex console.
2. **Project declaration (`tutorial.project_start`, `tutorial.project_lex`, `tutorial.project_grants`)**: opens `src/outside/projects/db_browser/project.lex` live in `edit` (`edit("db_browser", "project.lex")`), highlighting `let`, `here()`, typed units (`4 MiB`), `with`, `recipe(...)`, and least-privilege `store(...)`.
3. **Signed cache and recipes (`tutorial.cache_start`, `tutorial.cache_pull`, `tutorial.provenance`, `tutorial.deliver`)**: ingests the tree, pulls the signed realisation from the local QUIC object cache, prints the `Project_Build` record (`pkg`), inspects Ed25519 signer provenance via `pkg.recipe |> recipes.provenance`, and delivers the verified module into `module_files`.
4. **Sandbox by default and grants (`tutorial.sandbox_start`, `tutorial.sandboxed`, `tutorial.grants_window`)**: starts `db_browser` with zero grants (runs in memory only), grants its private store (`allow("db_browser", "store")`), opens the desktop `grants` window (`start("grants")`), and restarts `db_browser` with its granted private store.
5. **Live SQLite GUI (`tutorial.sqlite_open`, `tutorial.sqlite_query`)**: runs `INSERT` and `SELECT` against `main.db` through the isolated `sqlite.module` child call host, commits dirty 4 KiB pages atomically, and sorts results off-thread by clicking a column header.
6. **Automatic CoW versions (`tutorial.versions_start`, `tutorial.versions_preview`)**: opens `VERSIONS` with `Ctrl+H`, previews the earlier database generation read-only, restores it atomically with `Enter`, and re-queries `tasks` to show the restored rows.
7. **Recap card**: dark summary card covering the four pillars and `modus.systems`.

### Card splicing and ASS subtitle composition

`tools/modustool/machine/tutorial_film_compose.odin` generates the chaptered 1920 by 1080 film deterministically in pure Odin before invoking `ffmpeg`:

- **Chapter cards**: pure Odin writes 1920 by 1080 RGB `.ppm` backgrounds (dark surface `#11151B`, 1-pixel border `#30363D`, 6-pixel rectangular left accent bar in the semantic accent color of `docs/DESIGN.md`) and splices them into `pictures.ffconcat` at exact cue boundaries (`0.000` for Chapter 1, chapter-start cues for Chapters 2 through 6, and end-of-recording for Chapter 7, repeating the final `file` line without a duration and passing `-t <total_ms>` to `ffmpeg` so the final card lasts exactly 4.0 s without trailing blank frames).
- **Cue-shifted ASS subtitles (`tutorial.ass`)**: maps every raw cue timestamp through the cumulative duration of preceding spliced cards, emitting exact-pixel (`PlayResX: 1920`, `PlayResY: 1080`) vector card boxes and text using the repository fonts in `resources/fonts/` (`B612 ASCII Bold`, `B612 ASCII`, `JetBrains Mono ASCII`). `ffmpeg` burns them with `-vf "fps=30,scale=1920:1080:flags=neighbor,ass=filename=...:fontsdir=resources/fonts,scale=out_color_matrix=bt709:out_range=tv"`.
- **WebM size guard**: encodes `tutorial.webm` with `libsvtav1` and checks `checks.film_document_problem`. If the WebM exceeds `checks.FILM_DOCUMENT_SIZE_LIMIT`, the composer steps the AV1 CRF up across a bounded ladder (`42`, `46`, `50`, `54`) until the file passes the 4 MiB bound.

## Refused forms

- **`ffmpeg` `drawtext` filter chains.** Complex multi-chapter quoting, colon escaping, and line wrapping in one filtergraph string are fragile and hard to unit-test. An ASS file with vector cards and `fontsdir=resources/fonts` is plain structured text testable on the host.
- **Hand-typed 64-hex hashes in console scenes.** Breaks readability and contradicts property 19; typed `Record` results let Lex expressions pass `pkg.recipe` and `pkg.output` directly.
- **Doubling to 3840 by 2160 (`FILM_SCALE = 2`) for the long tutorial.** Four times the pixels risks exceeding the 4 MiB WebM document budget for a multi-chapter film; native 1920 by 1080 keeps text sharp at 1:1 while fitting well under 4 MiB.
- **Overlaying chapter cards over moving desktop frames.** Splicing cards directly into `pictures.ffconcat` pauses the visual stream cleanly during each card without hiding any live action.

## State

Built: `tools/modustool/machine/tutorial_film_compose.odin`, seven-chapter `tutorial_film_scenario.odin`, `db_browser`-focused `tutorial_film_setup.odin`, typed `Project_Build` and `Provenance` record results in `src/modules/system/console/recipes_wiring.odin`, upgraded Lex v3 `src/outside/projects/db_browser/project.lex`, and host tests in `tools/modustool/machine/tutorial_film_test.odin`.
