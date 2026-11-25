title: The modus course part 2: building, Lex recipes, and QUIC cache publishing
date: 2026-11-25
release: next
picture: docs/screenshots/console_lex.png
kind: Shown
guide: docs/COURSE_BUILDING.md
film: docs/films/course_building.webm

Part 2 of the hands-on `modus` course covers building programs, declaring reproducible build environments in `project.lex`, and publishing signed closures over QUIC directly from the `modus` console — both as a six-lesson written guide (`docs/COURSE_BUILDING.md`) and as a six-lesson video with two-panel syntax-highlighted teaching slides (`modustool film course_building`).

The course walks in plain English through inline sandboxed C prototyping (`compile_c`, `help(a)`, `unload(a)`), iterative project stores (`projects.new`, `edit`, `build`, `run`, local cache substitution, and declared grant enforcement), pure Lex build declarations (`let ... in`, `with`, `2 MiB` / `4 MiB`, `here()`, `recipe(catalog.modules.c_builder, ...)`), content-addressed ingestion and sandboxed builds (`recipes.ingest_tree`, `recipes.build_project("build_only")`, `recipes.provenance`), live in-OS QUIC cache uploads and verification (`recipes.publisher_key()`, `recipes.publish`, `recipes.build_project("verify")`, `recipes.status()`, `recipes.collect_garbage()`), module delivery (`recipes.deliver_module`, `run("calc")`, `projects.install`), and automatic copy-on-write source history in `edit` (`Ctrl+H`).
