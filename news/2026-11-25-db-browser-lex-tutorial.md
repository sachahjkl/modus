title: Building a sandboxed SQLite GUI app on modus
date: 2026-11-25
release: next
picture: docs/screenshots/console_lex.png
kind: Shown
guide: docs/LEX.md
film: docs/films/tutorial.webm

A seven-chapter developer tutorial now walks through one application from its Lex declaration to live copy-on-write version history: `db_browser`, a sandboxed SQLite GUI application for modus.

The tutorial opens `db_browser/project.lex` in `edit`, ingests the source tree into BLAKE3 content-addressed objects, pulls a signed realisation over QUIC as a typed `Project_Build` record, verifies Ed25519 provenance through `recipes.provenance`, and delivers the module by hash. It starts `db_browser` with zero ambient grants, grants one private store through `allow` and inspects active grants in the desktop `grants` window, runs SQLite inside a zero-grant child call host with atomic 4 KiB page commits and off-thread column sorting, and opens automatic copy-on-write `VERSIONS` with `Ctrl+H` to preview and restore an earlier generation atomically.
