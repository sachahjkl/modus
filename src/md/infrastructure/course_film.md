# Course film

`modustool film course` records and composes a self-contained, five-lesson practical course video teaching the five core properties of `modus` and how to use them daily, paired directly with [`docs/COURSE.md`](../../../docs/COURSE.md).

## Purpose

A screencast that runs console commands without explanation leaves a newcomer guessing what each property is, how it works internally, why it is designed that way, and how to read the syntax on screen. The course film opens every lesson with a 6.5-second two-panel teaching slide (left explanation blocks for **HOW IT WORKS & WHY** paired with a right syntax-highlighted `JetBrains Mono` code panel for **HOW TO USE IT** and a bottom **Key rule** callout) and pairs each live command with a 5-6 second hold and a rich syntax-colored two-line lower-third caption.

## Constraints

- **Teaches on modus's own terms.** Zero raw 64-hex hash walls, zero unexplained identifiers, and explicit plain-English explanations of every command, enum member (`.vector`, `.spleen`, `.auto`, `.dark`, `.light`), unit (`MiB`, `KiB`, `pages`), built-in library (`sample`, `readings`, `sum_values`), and execution mode (`start`, `start_from_disk`, `connect`, `isolate`, `load`).
- **Rich visual formatting and syntax highlighting.** Inline `**bold**` emphasis and backtick `` `code` `` spans render via `tutorial_ass_format_rich` in `JetBrains Mono ASCII` with token-level syntax colors (gold `.enums`, green `"strings"`, coral operators, lavender numbers/units, sky-blue identifiers) and safe ASS escaping of `\`, `{`, `}`, and `\n` outside override tags.
- **Zero timing drift and zero UI overlap.** Every slide and caption anchors to `build/films/course.cues` ([film_cues.md](film_cues.md)). At 1.25x UI scale (`1536x864` logical on 1920 by 1080), `console` (`24, 44`), `grants` (`820, 44`), `notes` (`700, 44`), and the centered trusted display plan consent dialog stay inside physical `x = 30..1892` and `y = 45..805`, leaving the lower-third caption band (`y = 856..1036`) completely clear.
- **Native 1080p and 4 MiB WebM bound.** Encodes 1920 by 1080 (`30 fps`) into `build/films/course.mp4` (H.264) and `build/films/course.webm` (AV1, silent, `<= checks.FILM_DOCUMENT_SIZE_LIMIT`, 4 MiB) using the shared `chaptered_film_write` pipeline (`tools/modustool/machine/tutorial_film_compose.odin`) with NVENC auto-detection and CPU fallback.

## The chosen form

### Five live lessons plus intro and recap two-panel slides

1. **Intro slide (`card_course_0`, 5.5 s)**: overview of the five core properties of `modus` and the live course roadmap.
2. **Lesson 1 (`card_course_1`, `course.l1_*`)**: typed `processes()` pipeline (`where`, `columns`, `sort`), `memory()` typed `Record`, exact unit arithmetic (`1 MiB + 512 KiB`) and pure Lex (`let`, `filter`, `map`), and typed enum refusal (`settings.set(font = .comic)` listing `.vector`, `.spleen`).
3. **Lesson 2 (`card_course_2`, `course.l2_*`)**: the four execution modes (`start`, `connect`, `isolate`, `load`), live `isolate("sample")`, `help("readings")` showing signature and module documentation live before calling `t = readings(4)` and `t |> where(sensor = 2) |> sum_values`, and `connect("monitor")` (`monitor.served()`).
4. **Lesson 3 (`card_course_3`, `course.l3_*`)**: schema typo refusal before dialog (`appearance = .neon`), one-step `plans.apply("evening", plan { locks = { settings = { appearance = .dark } } }) |> columns(generation, standing)` holding 5.6 seconds on the **TRUSTED PLAN DIFFERENCE** consent dialog before accepting (`Tab`, `Enter`) and returning `standing: Current` directly, plus `plans.generations() |> columns(generation, timestamp_ms, standing)`.
5. **Lesson 4 (`card_course_4`, `course.l4_*`)**: `start("notes")`, `grants("notes") |> where(state = "held")`, and the live desktop `grants` window with `Revoke` buttons.
6. **Lesson 5 (`card_course_5`, `course.l5_*`)**: automatic copy-on-write commits in `notes`, `Ctrl+H` Versions preview (`Down`), and atomic non-destructive `Enter` restore, followed by the Recap two-panel slide (`card_course_6`, 5.5 s) linking `docs/COURSE.md` and `modus.systems`.

## The refused forms

- **Monochrome bullet slides without code examples.** Flat monochrome bullet lists mix prose and code without visual hierarchy and leave unfamiliar syntax unexplained. Drawing two structured panels in the 1920 by 1080 PPM frame paired with syntax-colored `JetBrains Mono` code and `//` annotations makes every lesson readable on its own.
- **Skipping `help("readings")` after `isolate("sample")`.** Jumping straight from `isolate("sample")` to `readings(4)` leaves a viewer guessing what `sample` is and where `readings` comes from. Running `help("readings")` live shows the exported signature and description right before the call.
- **Showing raw 64-character BLAKE3 hashes in console tables.** Unfiltered `plans.apply_poll(t)` wraps long hex columns across lines; piping through `|> columns(...)` keeps the console crisp while teaching column projection.
