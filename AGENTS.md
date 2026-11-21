# Rules for an agent that works on this repository

Read `src/md/README.md` first: the system on one page, the points that agents get wrong, and the index of the intent files. `docs/PROPERTIES.md` holds the 22 properties: the fundamental concepts of the system.

Each kind of content has one place. The intent of a design is in `src/md`. A guide of `docs/` says what the system does and how to use it. The planned work is in `ROADMAP.md`. The record of the changes is `CHANGELOG.md`, `changelog.d/` and `news/`. The fixed constraints are `docs/PROPERTIES.md`. The rules of work are this file. Git keeps who decided what, and when. Do not add a document that competes with one of these places.

## Push back

- Compare each proposal of the owner with `docs/PROPERTIES.md` and with the intent files of `src/md`, before any work on it.
- If a proposal contradicts a property or the design of an intent file, say so first. Name the property or the intent file, and state the contradiction in one or two sentences.
- Do not implement the proposal in silence, and do not bend it in silence into something else.
- Propose the nearest form of the idea that keeps the properties, if one exists. If none exists, say that.
- The owner decides. If the owner keeps the proposal, change the property or the intent file first, then implement.
- A proposal that agrees with the properties needs no objection. Do not invent one.
- Apply the same test to your own ideas.

## Intent

- This project follows <https://srcmd.org>, with the Markdown in `src/md`, as the standard suggests. Read `src/md/README.md` first.
- A file of `src/md` is an intent file (`docs/glossary/project.md`): it records the intent of a part of the system: its purpose, its design, the forms that were refused and why, its subtle points. It is not a guide: a guide of `docs/` says what the system does and how to use it, and the site shows it.
- A design goes in `src/md` before its code. A change of design changes its intent file in the same commit as the code.
- Never write a design in a folder outside the repository. A review, a log and a measure of one run are process documents: they do not go in the repository.
- `src/md/README.md` has the section `## File Index`. It lists and links every other file of the folder, one line each, with paths relative to `src/md`. `modustool check` checks it (`intent_index_check`).
- The rules of the form of an intent file are in `src/md/README.md`, "The rules of this folder".
- The folder `src` holds everything that becomes the system. The design of that layout is `src/md/infrastructure/repository_layout.md`.

## Roadmap

- `ROADMAP.md`, at the root of the repository, next to `CHANGELOG.md`, holds the planned work of this project. It is the one place of the plans: do not keep a plan in a guide or in a to-do file outside the repository.
- The file is plain Markdown that a reader understands without a tool: no YAML, no front matter, no metadata field, no HTML.
- Its shape: the title `# Roadmap`, then the sections `## Now`, `## Next` and `## Later`, in this order. Each section is a list. `Now` is the work in progress, `Next` the work that is decided and comes after, `Later` the work that is wanted and has no order. Give no dates.
- An optional last section `## Maybe`, after `## Later`, holds what may be done one day and is not decided: each entry says the ways open and what each waits for.
- A roadmap entry (`docs/glossary/project.md`) is `- **<summary>.** <one or two sentences>`: a short bold summary, then what the work gives the user of the system, or the developer who builds on it. Do not say how the code changes. Name no person.
- If an intent file holds the design of the work, end the entry with its design link: `[Design](src/md/<file>.md)`.
- When you plan a work, add its entry. When a work starts or is decided, move its entry to its section.
- When a work is done, the agent or the coordinator who commits it removes its entry in the same commit as its changelog fragment. Give that fragment the summary of the entry as its bold summary: `modustool roadmap check` then fails until the entry is removed. If a part of the work is left, keep an entry whose summary names that part.
- `modustool roadmap check` checks the format of the file, as `modustool changelog check` checks the changelog. `modustool check` runs it. The rules are in `docs/TOOLS.md`, "The roadmap".
- The site shows the file on the page Roadmap, beside the page Releases (`docs/SITE.md`, "The roadmap"). `modustool site` stops on a fault of the form of the file.

## Changelog

- `CHANGELOG.md`, at the root of the repository, records each release in the Keep a Changelog format. Its version numbers are in `src/library/contract/release/release.odin`.
- A branch adds one fragment in `changelog.d/` for each change that a reader notices (`modustool changelog new`; read `changelog.d/README.md`). A change that a reader sees always gets its fragment.
- Never edit `CHANGELOG.md` or `src/library/contract/release/release.odin`: `modustool changelog release` writes them.
- `modustool ship` makes a release: it assembles the fragments, commits, makes the signed tag `v<number>` and pushes both. The tag starts the release workflow, which publishes the signed release image (`src/md/infrastructure/releases.md`, `src/md/infrastructure/release_image.md`).
- `modustool changelog check` checks the fragments and the file; `modustool check` runs it.

## Work

- Documents, code and comments are in English, so that one term keeps one concept. The conversation is in the language of the owner.
- One term for one concept. Define a term in `docs/glossary/`, in the file of its group, before its first use.
- A term of the glossary is a heading of level 3 in its group: a short definition of one sentence that stands alone, then an explanation (what it is for, how it is used, what it is not, an example, a reference to its design), then "Do not use:" (`docs/SITE.md`, "The glossary").
- Each step adds one capability to a system that works. Each step is a tested commit on `master`.
- Before 1.0, nothing is kept for compatibility: a behaviour, a sentence, a format or an interface changes when a better one is designed. Do not copy an old behaviour only because it exists. A test that the change breaks is read to its cause; if the new behaviour is the right one, change the test, the guide and the changelog fragment, not the code.
- Finished work is merged into `master` and pushed, and its branch is deleted. No branch stays after its work is done.
- All automation is a command of `tools/modustool`. Run it with `nix develop -c modustool <command>`. The tool uses the Odin standard library only.
- Keep the documentation up to date: a change of the code changes, in the same commit, each document that describes it: the intent file, the guide of its subject, the glossary, `README.md`, the changelog fragment and the news entry when a reader sees the change. A document that says what the code no longer does is a fault, as a failing test is.
- Features first: write several features in parallel. A merge needs its build and the test of its own part. The full check, the release and the publication of the site run once, at the end of a batch.
- Kernel code, concurrent code and code that reads the network get an independent review before the merge: a fresh read of the change, often by a new agent session.
- After each five steps, review the work against the properties and the rule "no bad compromise". Each concession that the review finds, and that is planned work, becomes an entry of `ROADMAP.md`.
- A guide never names a person or a role of the project, a step or a date of a decision. It states the rule.
- A news entry never says "the owner". It states the fact.
- Names: no esoteric, over-compressed name of a type, a function, a field or a file. Use long, descriptive names of complete words (`copy_bytes_without_overlap`, not `memcpy`).
- The code of the system runs on modus, not on a host. A source of `src/` that is not a test imports `base:` and `modus:` packages only: never `core:os`, `core:thread`, `core:sync`, `core:fmt`, `core:time` or any other package of the core library, because they call the host. It reaches the machine through the operations of the kernel and the support packages (`modus:support/system`). The one exception is the copy of the cryptography of Odin, which the reuse list names. A rich module or a ported module that uses `gui_toolkit` is not a source of `src/`: it is an outside module (`src/md/infrastructure/third_party_module.md`), and it imports `gt:` packages and the core library of Odin on the target modus (`src/md/features/desktop_to_browser.md`, "The toolkit of rich modules").
- A test file of `src/` that imports a package of the core library starts with `#+build !freestanding`, so that no build of the system reads it.
- A closed set of choices is an `enum`, never a family of integer constants (`MODE_A :: 0`, `MODE_B :: 1`) passed as a `u64` or an `int`. Give the enum the values of its contract explicitly when the values cross a border.
- A word of transport (a value of the context, a field of a record, an argument of an operation, a word of a ring) becomes its enum at one place only, at the border, and that place refuses a value that names no member. Past the border, the code passes the enum, never the word, and each `switch` on it is checked whole by the compiler (no `#partial` on a closed set, no default case that turns an unknown value into a known one).
- Angles are in turns (1.0 is a whole circle, 0.25 a right angle), never in radians or degrees, and the type or the name says so (`angle_turns`). The trigonometric routines of the system (`modus:support/trigonometry`) take turns. A derivative of a function of an angle in turns gains a factor of 2π: code that takes a formula of calculus from a book must add it. Host code that calls `core:math`, which takes radians, converts at that one call, with a comment (`src/md/data/angles_in_turns.md`).
- A constant stays a constant only when it is a quantity or a place: a size, a capacity, a limit, an address, an index in a fixed array (`CONTEXT_LOG`). A guide names an enum and its members, not the numbers.
- Pictures: each picture that you produce and view goes in `~/Projects/kernel-devlog`, in a dated folder. Never delete a folder of the devlog.
- A test never depends on the speed of the hardware: a test checks a condition, and a time in it only ends a hang. Use the one hang bound (`HANG_BOUND` in the tool, `system.TEST_HANG_BOUND_MILLISECONDS` in a module), on a stall where the case can count its progress. Never assert a speed, a duration or a rate: print it as a measure. A behaviour in time is checked by order and by the clock of the system, with no upper bound but the hang bound. Read `docs/TOOLS.md`, "The bounds of the tests".
- A test that fails once is read to its cause before it is called a flake.
- A test tries to break the code. For each input that the code must refuse (a value that names no member, a size past its bound, a field out of its range, a damaged record, an order that the contract forbids, a missing right), the test gives that input and checks the refusal: its status, its error record, and that nothing changed. The edges come first: 0, 1, the bound, one past the bound, the largest value of the type, a negative value where the type allows one.
- A test never checks that a wrong input is accepted, or that an unknown value becomes a known one. If the code does that, the code is wrong: fix the code, and the test checks the refusal.
- A test of a successful case is the last case, not the only one. A reviewer reads each test and asks what input would break the code that it does not try.
- Performance is a criterion at every level, the tool too. A claim of speed has a measured number.
- A full check is `nix flake check` AND `modustool screenshots`. The machine test runs once, in the check `boot-test` of the flake; `modustool screenshots` builds that check, which Nix takes from the store when it passed on the same tree, copies its pictures and its logs, and runs the measure runs on the host (`src/md/infrastructure/full_check.md`). The flake sees only the tracked files of the folders that `flake.nix` names: add a new file to git, and a new top-level folder to `flake.nix`, before the full check.
- Comments in code: a comment in a source file gives the reason itself, in plain words. It names no number of a property, a choice, a step or a review finding, and no identifier or date of a decision. A pointer to a document is allowed ("docs/MODULE_CONTRACT.md, section 4").
- Forms: rectangular forms are the preference, not an absolute rule. Lines at an angle are allowed; any geometry can be drawn, sparingly. Avoid a look where everything is a rounded blob.
- Subagents: a subagent that writes code compiles it before it reports: `modustool build` and the host tests of the packages that it changed, until both pass. It runs no machine test, no full check, no commit and no merge. Each agent works in its own git worktree, on its own branch, and does not push. The coordinator reviews, runs the machine tests, commits and merges.
- A brief for an agent quotes each rule of this file word for word.
- Never commit under an AI identity.
- No pull request and nothing opened upstream unless the owner asks.
- Do not start the ARM64 port unless the owner asks.
- Posts on X about the project: short, simple, technical, in lower case. A post says what modus is; it does not assume that the reader knows it. It shows the thing with a picture, and tags no person.
