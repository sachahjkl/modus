## Project

The words of this group name how the project is run and published: the documents that hold its rules and its state, the units of the work, and the site, the changelog and the news that report it.

### Property

A property is one of the 21 fundamental concepts of the system, each with its rule, its reasons and its costs, in `docs/PROPERTIES.md`.

The properties are the reference against which every proposal is measured: a proposal that contradicts one is named as such before any work on it. Each property has a number, a title ("10. One code module") and a status in the summary table of the document. The status page of the site shows each property with its status. A comment in a source never names a property by its number: it states the reason in words. `modustool check` refuses "(property 14)" as a comment breach.

The design: `docs/PROPERTIES.md`.

Do not use: principle (for this), requirement, axiom.

### Reuse list

The reuse list is the table of `docs/PROPERTIES.md` that names each reused work: a work of others that the system ships in a module or in the boot image, or that the repository holds as a copy.

Each row gives the work, its place in the repository, its license as an SPDX identifier, and the file with the text of that license. A font subset, a pointer theme, the copied cryptography and each portrait of the hall of fame are reused works. A tool of the host that builds or tests the system (QEMU, the compiler) is not, and neither is a design or a standard that the system follows. `modustool check` compares the list with the records of the repository.

The design: `src/md/infrastructure/reuse_list.md`.

Do not use: third-party list, dependency list, bill of materials.

### Step

A step is one tested commit on `master` that adds one capability to a system that works.

The project grows in steps: each step leaves the system whole, built and tested, with its documents up to date in the same commit. Several features can be written at once on branches; each merge still needs its build and the test of its own part.

A step is not a stage of the start of the machine (the "Step of the start" of the group "Running code"), not a step of a machine test, which waits for one line of the log, and not a sequence step of an operation sequence.

The design: `AGENTS.md`.

Do not use: iteration, sprint, milestone (for this).

### Review

A review is a read of the work against the properties and the rule "no bad compromise", which lists each concession and what removes it.

The project asks for one after each five steps. Each concession that it finds, and that is planned work, becomes an entry of `ROADMAP.md`. Kernel code, concurrent code and code that reads the network also have an independent review before each merge: a fresh read of the change, often by a new agent session. A finding of a review has a label, and its correction never names that label in a comment of the code.

The design: `AGENTS.md`.

Do not use: audit, code review (for the whole), retrospective.

### Working record

A working record is a document that records the work on the site, not the system: `docs/SITE.md`, and each intent file of `src/md`.

A guide says what the system does and how to use it; a working record holds the design of a part and the state of its work. So the site publishes the guides and not the working records (`SITE_WORKING_RECORDS`): a link of a page to a working record names the file in the repository, and says so. An intent file is a working record for the site by its path under `src/md`.

The design: `docs/SITE.md`, "The pages".

Do not use: internal document, notes.

### Intent file

An intent file is a Markdown file of the folder `src/md` that records why a part of the system has its form.

A design is written there before its code, and a change of a design changes its intent file in the same commit. `src/md/README.md` is the entry point of the folder, with a file index that `modustool check` compares with the folder. An intent file is not a guide: a guide says what the system does and how to use it, and the site publishes it. It is not a review, a log or a plan. Example: `src/md/features/palette.md` says why the palette is a panel of the compositor, and which forms were refused.

The design: `src/md/README.md`, "The rules of this folder".

Do not use: design document, specification, RFC, architecture decision record.

### Similarity finder

The similarity finder is the command `modustool similarity`: it measures how similar the code pieces of the Odin sources of the repository are, groups them in similarity families, and proposes where to factor each family.

It reads `src/` and `tools/` with the parser of Odin, gives a similarity score for each pair that it compares, and writes a report under `build/similarity/`. It ranks the families by the syntax nodes that a factoring saves, and proposes a home that obeys the import rules. A human or an agent decides what to factor: a family that is kept is a line of the kept list. It is not a check: it never fails a build, and it never edits a source.

The design: `src/md/infrastructure/similarity_finder.md`.

Do not use: duplicate finder, clone detector, linter (for this).

### Code piece

A code piece is a procedure, a run of two or more statements of one block, or an expression, that the similarity finder compares with other code pieces.

A code piece is a part of the code that one call can replace, so a factoring of it is a procedure. It has a minimum size in syntax nodes, so that the call costs less than what it replaces. It is not a fragment: a fragment is a file of `changelog.d/`.

The design: `src/md/infrastructure/similarity_finder.md`, "2. The code pieces".

Do not use: fragment, clone (for one piece), snippet.

### Similarity score

The similarity score of two code pieces is a number from 0 to 1: two times the syntax nodes that their factoring template keeps, divided by the sum of their sizes.

It is 1 when the two are equal after the normal form of the similarity finder, and 0 when they share no node. A score of 0.9 says that a tenth of the two code pieces is in the blanks and the statements that only one side has. A score of 1 is not a proof of the same behaviour: the normal form applies only the rules that the syntax proves. `modustool similarity pair` gives the score of any two procedures.

The design: `src/md/infrastructure/similarity_finder.md`, "6. The anti-unification and the similarity score".

Do not use: distance (for this), match percentage.

### Similarity family

A similarity family is a set of two or more code pieces that one factoring template covers, each for at least 70% of its nodes when the members are not equal.

A family has a category: a utility to centralise, a local repetition, a parametric family, similar behaviour, a repeated expression, kept apart by the rules, or a platform variant. Its members are the code pieces, with their file and lines and the arguments of each blank. A family of similar behaviour has a statement in some members only, or a blank that Odin cannot pass as a parameter: no one call replaces it.

The design: `src/md/infrastructure/similarity_finder.md`, "7. The families".

Do not use: clone class, clone group, cluster.

### Factoring template

A factoring template is the code that all the members of a similarity family share, with a blank at each place where they differ: the body of the procedure that a factoring makes to replace them.

The similarity finder computes it by anti-unification, the least general generalization of the members: each node that all the members have stays, and each place where they differ becomes a blank. The report prints it from the source of its first member, with `?1`, `?2` at the blanks. Its template hash names the family in the kept list. It is not an instruction template: an instruction template is an `asm` procedure.

The design: `src/md/infrastructure/similarity_finder.md`, "6. The anti-unification and the similarity score".

Do not use: abstraction, generalization (for the result), macro.

### Blank

A blank is one place of a factoring template where the members of a similarity family differ, with the argument of each member at that place.

A blank has a kind: a value, a type, a place, a procedure, or not a parameter. The kind says how the factored procedure takes it: a parameter, a polymorphic parameter, a pointer parameter, a procedure parameter, or not at all. The same arguments at two places give one blank. It is not a hole: a hole is a part of a stored object whose bytes are zero.

The design: `src/md/infrastructure/similarity_finder.md`, "6. The anti-unification and the similarity score".

Do not use: hole (for this), metavariable, pattern variable.

### Changelog

The changelog is the file `CHANGELOG.md`: the releases of the system, newest first, each with the changes that a reader of the system notices.

It follows the format of Keep a Changelog 1.1.0 and semantic version numbers. Each entry starts with a short bold summary, then says what the system does now, for a reader, not how the code changed. No one edits the file by hand: a branch adds a fragment for each change, and `modustool changelog release` moves the fragments into a new release. The site shows the file at `releases/` and in the feed `releases.xml`. It lists every change for a developer; a news entry reports one thing for a reader who is not a developer.

The design: `docs/SITE.md`, "The pages".

Do not use: release notes (for the file), history, news.

### Release

A release is one section of the changelog, with a release number, a release time and the entries of its changes, on one commit of `master` that carries its release tag.

A release marks a state of `master` that passed its checks. `modustool ship` makes it: it moves the fragments of `changelog.d/` into a new section, writes the release number, commits, tags the commit, and pushes the commit and the tag at once. Example: `## [0.93.0] - 2026-11-15 18:48`. The push of its release tag starts the release workflow, which publishes its release image. It is not a version: a stored object of the system has versions. It is not a build: many builds come between two releases.

The design: `src/md/infrastructure/releases.md`.

Do not use: version (a stored object has versions), tag, build.

### Release number

The release number is the number of a release, in the form `<major>.<minor>.<patch>`.

The project is before its first major release, so a release number is `0.N.0` for a release of new work and `0.N.1` for a correction after it. `RELEASE_NUMBER` in `src/library/contract/release` holds the newest one, and `modustool release_number` prints it; the foot of each page of the site and the page graph name it. The tool writes it; no one edits it by hand. `modustool ship step` takes the next `0.N.0`, `modustool ship correction` the next `0.N.1`.

The design: `docs/SITE.md`, "The pages"; `src/md/infrastructure/releases.md`.

Do not use: version number, version.

### Release time

The release time is the moment of a release, in UTC, to the minute, as its heading in the changelog writes it: `2026-11-15 18:48`.

`modustool changelog release` writes the time of the clock of the host, in UTC, so two releases of one day keep their order, and two hosts in two time zones write comparable times. The releases page shows it with "UTC" after it, and the feed `releases.xml` writes it as `2026-11-15T18:48:00Z`. An old heading that has its day alone gets its time from `modustool changelog times`, from the commit of its release. It is not the date of a news entry, which is a day alone.

The design: `src/md/infrastructure/releases.md`.

Do not use: release date (for the whole), timestamp.

### Release tag

A release tag is the annotated, signed git tag `v<release number>` on the commit of a release.

`modustool ship` makes it with `git tag -s -a`, so it holds who released, when, and a signature that the git configuration of the publisher of the system makes. It goes to `origin` in one atomic push with the commit of the release: a tag never exists there without its commit. The release workflow starts from it. The releases before the first `ship` have no tag.

It is not the release: the release is the section of the changelog, and the tag names its commit. It is not a release number: the number has no `v`.

The design: `src/md/infrastructure/releases.md`.

Do not use: release label, version tag (for this).

### Release link

A release link is the line `[<release number>]: https://github.com/sachahjkl/modus/releases/tag/v<release number>` at the end of the changelog, one for each release.

Keep a Changelog defines these lines: a forge that renders Markdown then links the number of each heading to the page of its release tag. The lines are newest first, after the last release, with no empty line between them. `modustool changelog release` writes the link of a new release, `modustool changelog times` adds each missing one, and `modustool changelog check` refuses a missing, wrong or extra link, and links in another order.

It is not a link of the site: the releases page gives each release an anchor.

The design: `src/md/infrastructure/releases.md`.

Do not use: reference link, footnote.

### Fragment

A fragment is one file of `changelog.d/` that holds one change that is not in a release yet: its type and the text of its entry.

A branch adds one fragment for each change that a reader notices, in the same commit as the change: `modustool changelog new <type> <subject> - < text.md` writes `changelog.d/<yyyymmdd-hhmmss>-<subject>.md`. Line 1 is `type: <type>` (Added, Changed, Deprecated, Removed, Fixed or Security), line 2 is empty, then one paragraph:

```
type: Added

**The thing**: what the system does now, for a reader, in one or two sentences.
```

A change with no effect that a reader notices (a document, a comment) has no fragment. `modustool changelog release` moves the fragments into a release and deletes them.

The design: `changelog.d/README.md`.

Do not use: changeset, news file, entry (for the file).

### Roadmap

The roadmap is the file `ROADMAP.md`: the planned work of the system, in three sections, Now, Next and Later, then an optional section Maybe.

It is the one place of the plans: the changelog lists the work that is done, the roadmap the work that is planned. **Now** holds the work in progress, **Next** the work that is decided and comes after, **Later** the work that is wanted and has no order, and **Maybe** what is not decided. The file is written by hand, with no date and no name of a person. `modustool roadmap check` checks its form, and the site shows it at `roadmap/`. It is not the status page, which gives the state of each property.

The design: `docs/TOOLS.md`, "The roadmap".

Do not use: plan, backlog, to-do list, next steps, milestones.

### Roadmap entry

A roadmap entry is one item of a section of the roadmap: a short bold summary, then one or two sentences on what the work gives the user.

An entry names one planned work in the words of its user: a user of the system, or a developer who builds on it. Example:

```
- **A window for the debugger.** The debugger gets a window over the exports that the console uses today.
```

When an intent file holds the design of the work, the entry ends with a design link. An entry has no date and no number: its section is its state. When its work is done, the entry is removed in the commit of its changelog fragment.

The design: `docs/TOOLS.md`, "The roadmap".

Do not use: ticket, issue, task, story, item (for an entry), feature request.

### News entry

A news entry is a dated report in prose, for a reader who is not a developer of the system, of one thing that the reader can see or use, with its picture.

Each entry is one file of `news/`, `news/<yyyy-mm-dd>-<subject>.md`, never moved or merged: a head of a few lines, an empty line, then at most 1200 bytes of text. Its kind is Shown, Measured, Decided or Fixed. `modustool news new <subject>` writes an empty entry, which `modustool news check` refuses until a title and a text are written. The site shows each entry as a card on `news/`, and in the feed `news.xml`. The changelog lists every change for a developer; a news entry reports one thing, and names the guide that explains it.

The design: `docs/SITE.md`, "The news".

Do not use: news item, post, announcement, blog post, changelog entry.

### Film

A film is the pictures of the screen of a test machine, taken 30 times in one second while a scenario of the tool sends its keys, as one file that a player shows at the speed of the machine.

`modustool film <name>` makes a film, such as `terminal` or `boot`: an MP4 file and a WebM file from the same pictures, in the build folder. A film is not a test: only its scenario has steps with a fixed time. A news entry can name a film, and the repository then holds its WebM file. The site shows it on the page of the news in a `video` element that plays only when the reader starts it.

The design: `docs/TOOLS.md`, "The film".

Do not use: video (for the file), clip, movie, recording, screencast.

### Feed

A feed is a file of the site in the Atom format (RFC 4287), for a program that follows a site: `news.xml` has the news entries and `releases.xml` the releases, newest first.

A feed reader subscribes to the address of the file and shows each new entry. Each page names both feeds in its head, so a browser finds them. The id of each entry is the address of its file in the repository on `master`, so it does not change when the site gets an address. With no site address the links of a feed are relative and it has no link `self`.

The design: `docs/SITE.md`, "The news", and "The sitemap, robots.txt and the feeds".

Do not use: RSS (for these files), stream, channel.

### Search index

The search index is the file `search.json` of the site: one entry for each page, and for each thing of a page that a reader looks for, with its title, its page, its anchor, its kind and a short text.

Each entry comes from the same data as its page: a term has its short definition, an export its signature as the console prints it. The search field filters the index in the browser with the fuzzy match of the console, so the site needs no server for its search. The command checks that each entry names a page and an id that exist.

It is not the sitemap: the sitemap lists pages for a search engine; the search index lists things inside pages for the search field.

The design: `docs/SITE.md`, "The index".

Do not use: search database, catalog, sitemap.

### Search field

The search field is the one field of a page of the site where a reader types a search.

On each page it is in the site menu of the bar; on the docs home it is a large field in the page, and the bar has none. One script, `search.js`, serves both places: it loads the search index at the first key, and shows the matches in the look of the completion list of the console. `/` puts the focus in it. The query is in the address as `?q=<query>`, so a search can be linked. With no script, the field is hidden and the site stays whole by its links.

The design: `docs/SITE.md`, "The search".

Do not use: search box, search bar, omnibox.

### Mark

The mark is the picture that stands for the system: a heron on a grid of 24 by 24 square cells, each part filled with one gradient.

`src/library/support/mark` holds it as data: the rows of the still heron, the colors of each part and the animations of the mark. Every picture of the mark comes from that one table. One generator of the tool draws each picture file, in the variant of the mark that its use names: `modustool logo` for `resources/logo`, `modustool site` for the site, and `modustool mark` for one picture. The system draws the mark on the boot display and in the bar.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: logo, icon, emblem, mascot.

### Name of the mark

The name of the mark is the word "modus" drawn in letters of square cells, 5 columns by 7 rows each, under or beside the heron.

It is drawn from the same cells as the heron, so the files of the mark with a name keep one grid. A picture holds it only where one file must carry the heron and the name: the files `resources/logo/modus*.png` and the picture of the site for other sites. On a page of the site the picture is the heron alone, and the name is text in the font of the name of the mark. The boot display draws it at the right of the heron.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: wordmark, logotype.

### Font of the name of the mark

The font of the name of the mark is a font file whose glyphs are the cells of the letters of the name of the mark.

It lets a page write the name as text and show the letters of the mark: a reader selects the text, and a screen reader says it. `modustool logo` writes it from `mark.name_letters` as `resources/logo/modus_mark.ttf`. It has only the letters of "modus" and the space: it is not a font for a text. One em is 8 cells, so a font size that is a multiple of 8 pixels draws whole cells. Example: the bar of the site shows "modus" in this font at 16 pixels: cells of 2 pixels.

The design: `docs/DESIGN.md`, "The font of the name".

Do not use: logo font, wordmark font, pixel font.

### Still heron

The still heron is the heron of the mark with no animation: the 24 rows of `heron_rows` in `src/library/support/mark`.

Each animation starts from it and ends on it, and it is the frame 0 of each one. A picture that does not move (a file of `resources/logo`, an icon, the boot display) shows it.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: rest pose, idle frame, base frame (a base frame is another thing: see Animation of the mark).

### Animation of the mark

An animation of the mark is a short list of frames in which a few cells of the still heron change.

In a frame a cell takes the letter of another part, or becomes empty. Each frame has a duration, and starts from the still heron or from an earlier frame of the same animation, its base frame. After its last frame the heron is still again. The animations are data in `src/library/support/mark/animation.odin`, from the blink of one cell to the dash. The data does not say when one plays: the order of play of the place that shows them chooses which one comes next.

The design: `docs/DESIGN.md`, "11. The mark".

Do not use: idle animation, clip, tween.

### Order of play

The order of play is the rule that chooses the next animation of the mark, on the home of the site and in the program `heron`: each animation plays once in a round, in an order of chance.

The place that plays keeps a memory of the animations that were played, and chooses the next one among the others, each with the same chance. When the memory holds every animation, a new round starts, and the animation played last is left out of its first choice, so no animation follows itself. The rule is one procedure, `mark.next_animation`: the program `heron` calls it, and the modus tool runs it to check the script of the site. On the site the memory lasts for the visit of the tab.

The design: `docs/SITE.md`, "The rhythm of the animations".

Do not use: playlist, shuffle, random choice.

### Still share

The still share is the part of the time, over a long play, that the heron does not move where its animations play: 40 %.

It holds on the home of the site and in the program `heron` (`mark.STILL_SHARE_PERCENT`). The still time between two animations is chosen by chance around a mean, and the mean follows from the still share and from the times of the animations: the mean time of an animation, times the still share, over the moving share. With 15 animations of 1.29 s on average, the mean still time is 858 ms, and a still time is 429 to 1287 ms. A change of an animation changes the still times, not the share.

The design: `docs/SITE.md`, "The rhythm of the animations".

Do not use: idle ratio, duty cycle, pause.

### Move of the heron

A move of the heron is the list of the forms and of the places that the heron takes during an animation of the mark, each in whole cells.

An animation of the mark changes cells; a move takes the whole heron above the line of the water: across the window in the dash, up in the hop and the flap, wider and lower in a crouch. The water stays in its place. A move is a list of keys in `src/library/support/mark` (`move_keys`): a time, a form of the heron and a place in whole cells. The heron is never between two cells, and no picture of it changes its size. The home of the site and the program `heron` play the same keys.

The design: `docs/DESIGN.md`, "The moves".

Do not use: tween, sprite motion, scale.

### Form of the heron

A form of the heron is one drawing, in whole cells, of the part of the heron above the water: the natural heron, or the heron squashed or stretched.

A cell of the heron is a square of one size, so a squashed heron is not a picture made wider: it is the heron drawn with more columns and fewer rows of the same cells. A form names the columns and the rows of a frame that it repeats or leaves out, chosen by hand, then cells corrected by hand (`form_lines` and `form_corrections` in `src/library/support/mark`). The head, the eye, the beak and the crest are the same in every form. Example: the crouch is 28 by 19 cells.

The design: `docs/DESIGN.md`, "The moves".

Do not use: scaled frame, deformation, sampled frame.

### Move on the grid

A move on the grid is a move of the heron in which each cell stays a square of one size at a place of the grid.

It is the way of the system to draw a squash, a stretch and a travel. On the grid the heron takes a form of the heron, and a travel is a count of whole cells. It is not a filter over a scaled picture: the forms and the places are cells from the start. The other way, the free move, is in the program `heron` only, to compare: its cells are stretched to rectangles, at any pixel. Example: in the run of the dash the heron is 32 by 20 cells.

The design: `docs/DESIGN.md`, "The moves".

Do not use: snap, pixel-perfect scaling, quantized motion.

### Variant of the mark

A variant of the mark is one of the two ways to color the pixels of the heron: smooth, where each pixel takes the gradient at its own place, or cells, where each cell is one color.

A request for a picture of the mark names its variant: nothing chooses it from the cell size. A large picture is the smooth variant: the head of the home of the site, the files of `resources/logo`, the boot display. A small icon, one pixel for a cell, is the cells variant: the bar of the site, the bar of the desktop, the icon of a tab. The smooth variant needs at least 2 pixels for a cell, and a request for it at one pixel is refused.

The design: `docs/DESIGN.md`, "The variants of the mark".

Do not use: style, mode, rendering, pixel art mode.

### Tile map

A tile map is one PNG file that holds each distinct frame of the animations of the mark as a tile, in rows from the top left with the still heron first, and under them, for a place that shows the moves, a tile for each drawn form.

A script that plays the animations shows one tile at a time by its place in the file, so a page loads one picture for all the animations. A frame that two animations share is in the file once. The generator of the pictures of the mark draws a tile map in a variant of the mark, a cell size and a color scheme, and writes its table: the place and the size of each tile, the times, the moves in cells. `modustool mark tile_map` writes one.

The design: `docs/SITE.md`, "The moves of the heron".

Do not use: sprite sheet, atlas, film strip.

### Icon file

An icon file is one file that holds the mark at several sizes, each as one PNG file behind a directory, so that a reader takes the entry of the size that it shows.

The generator of the pictures of the mark writes it: each entry is the PNG file of one picture, byte for byte, at most 256 pixels on a side. The site has one, `favicon.ico`, with an entry of 32 pixels in the cells variant and one of 48 pixels in the smooth variant. `modustool mark still --format ico` writes one. It is not the icon of a phone or of the manifest: each of those is one PNG file.

The design: `docs/SITE.md`, "The icons".

Do not use: favicon file, ICO container, multi-size icon.

### Vector file of the mark

A vector file of the mark is a file that holds the mark in the cells variant as rectangles of one color, so that a reader draws the same cells at each size.

The generator of the pictures of the mark cuts the pixels of a picture into rectangles: a run of cells of one color in a row is one rectangle. The tool computes each color; the reader of the file only fills rectangles. The file can hold a rule that gives the colors of the dark scheme to a reader that asks for dark. The smooth variant is not written as a vector file: the reader would compute the gradient. The site has one, `pictures/icon.svg`. `modustool mark still --format svg` writes one.

The design: `docs/TOOLS.md`, "The pictures of the mark".

Do not use: SVG logo, scalable icon, vector logo.

### Animated file of the mark

An animated file of the mark is one animated PNG file that holds each frame of one animation of the mark as a picture, each for the time that the table of the animations gives it.

The generator of the pictures of the mark writes it, and a test reads each frame back and compares its pixels. It plays with no end, and does not show the move of the heron. It is for a page that runs no script, such as a page of a repository. The repository holds none: `modustool mark animation --animation <name>` writes one. It is not a tile map, which a script plays, and not a film, which shows the running system.

The design: `docs/TOOLS.md`, "The pictures of the mark".

Do not use: GIF, animated logo, sprite animation.

### Hall of fame

The hall of fame is the program `hall_of_fame`: one card for each person whose work inspired the system, with the name of the person and one line on what they made.

A card shows a portrait when a picture of the person has a license that lets the repository hold it with a credit, and then the credit of the picture under it. Each other card shows the name and the line alone, with no picture and no initials. A person is in it for work that the system learned from, not for fame. The arrows, Home, End and the pointer choose a card.

The design: `src/md/features/hall_of_fame.md`.

Do not use: temple, wall of fame, credits screen.

### Portrait credit

A portrait credit is the author and the license of one portrait of the hall of fame, which the program shows under the portrait.

`resources/hall_of_fame/CREDITS.md` holds the source, the author and the license of each picture; the program shows the author and the license, and the page of the licenses of the site shows one row for each picture. A host test of the modus tool checks that the program has the credit of each row.

The design: `src/md/features/hall_of_fame.md`.

Do not use: attribution line, copyright notice.

### Site

The site is the documentation of the system as static pages, with their style sheet and their pictures, that `modustool site` writes in `build/site` from the files of the repository and the logs of the machine tests.

Every fact of the site comes from a file: the guides from `docs/`, the reference tables from the sources, the numbers from the logs or the measure record, the news from `news/`. The command checks every page before it writes one, and stops on a fault, such as a broken link, with the page and the reason. Each page is whole with no script and makes no request to another host. The site workflow publishes it at `https://modus.froment.software/`.

The design: `docs/SITE.md`, "The command".

Do not use: website, homepage, landing page.

### Docs

The docs is the section of the site that holds the guides and the reference: the bar names it "Docs", and the addresses of its pages start with `/docs/`.

Its first page is the docs home. The guides explain how each part of the system is designed and why; the reference lists what exists in this build, from the sources. The status page is not a part of it: it reports the state of the work.

The word "Docs" names the section because "Documentation" is already the term for the text that a module carries.

The design: `docs/SITE.md`, "The sections".

Do not use: documentation (for this: Documentation is the text of a module), manual, help center.

### Docs home

The docs home is the first page of the docs, at `/docs/`: a large search field, the chart of what the search finds, then a card for the guides and a card for the reference.

It is a door, not a list. Its search field is the one field of the page, and the bar has none. Under it, the chart shows one segment and one chip for each kind of the search index, with its count; while a text is in the field, the counts follow the matches, and a chip keeps the results to its kind. The card of the guides lists each guide with its one line of description; the card of the reference lists each reference table with its count. It has the presentation layout.

The design: `docs/SITE.md`, "The docs home".

Do not use: docs landing page, portal, hub.

### Gallery

The gallery is the page of the site, at `/gallery/`, that shows every picture of the screen of the gallery table, in groups, each with its caption and the link to its guide.

A reader who wants to see the system finds each picture there: the desktop, the console, the programs, the developer tools, the fonts, the network, the storage and the boot. A picture on the page is a thumbnail, and its link opens the picture at its full size. It is a button of the bar, and the home links to it. It is not a list that a developer keeps by hand beside the pictures: the page is generated from the gallery table, which is checked against the folder of the pictures.

The design: `docs/SITE.md`, "The page of the gallery".

Do not use: screenshots page, album, lightbox.

### Gallery table

The gallery table is the one table of the tool that names each picture of the screen that the site shows: its file, its group, a caption of one sentence, its guide, and whether the home shows it.

It is `site_gallery_rows` in `tools/modustool/site_gallery.odin`. The gallery and the carousel of the home take their pictures and their captions from it, so a caption is written once. Each PNG file of `docs/screenshots` is in one row of it, or in the short list of the excluded files with its reason: `modustool site` stops on a picture that neither names. Example: the row of `heron.png` has the group of the mark, its caption, the guide of the design rules, and the mark of the home.

The design: `docs/SITE.md`, "The gallery table".

Do not use: picture list, screenshot manifest.

### Carousel

The carousel is the part of the home of the site that shows a few pictures of the gallery table in one row, one picture in view, with a numbered link to each picture.

The home shows a few pictures, so that it stays short; the gallery shows them all. The row scrolls sideways and stops at each picture, and a reader with no script reaches each one by its numbered link, by the scroll bar of the row or by a swipe. A small script adds keys. The carousel never changes its picture by itself.

It is not a film and not an animation: a picture changes only when the reader asks, at once.

The design: `docs/SITE.md`, "The carousel of the home".

Do not use: slideshow, banner, rotator.

### Line of time of the start

The line of time of the start is the part of the home of the site that shows each stage of the start of the machine as a segment of a bar whose width is the time of the stage.

It has two bars, because the firmware takes most of the start: the whole start on one scale, then the stages after the first one on a larger scale. Under the bars, one row for each stage gives its name and its time. Each stage has a card with what it does, its code, its line of the log and its guide. It is not the boot display, which the system draws on the screen: the tool draws the line of time from a log.

The design: `docs/SITE.md`, "The line of time of the start".

Do not use: boot chart, start diagram.

### Measure chart

A measure chart is a chart of the home of the site whose bars are the numbers of one line of a log that have one unit, on one scale from zero.

It exists by the rule "a chart or nothing": the home shows a measure only as such a chart, and each other measure is a row of the page of the measured numbers. The tool draws the chart only when the line holds every number of the chart, in its unit. Example: the kernel entries in one second with 1, 2 and 4 programs are three bars.

It is not the chart of what the search finds, whose segments are counts of entries of the index.

The design: `docs/SITE.md`, "The charts of the measures".

Do not use: benchmark chart, statistics card.

### Site control

A site control is a part of a page of the site that a reader presses: a button of the bar, a door of the home, a numbered link of the carousel, a line of a menu, a row of a list.

Each one has five states: at rest, with the pointer over it, with the focus of the keyboard, pressed, and current. One table of the tool names every site control, and one procedure writes the rules of its states. A state changes a color and never a size, and it shows at once.

It is not a link of a text, which takes the band of the track under the pointer. It is not the control of a thread, which is a capability of the kernel.

The design: `docs/SITE.md`, "The states of a control".

Do not use: widget, clickable.

### Thumbnail

A thumbnail is the picture that the gallery shows in the place of a picture of the screen: the same picture at one half of its width and of its height, which the tool writes when it writes the site.

It exists for the bytes of the page: the gallery has more than 100 pictures, and a thumbnail is about 60 000 bytes where the picture is about 157 000. Each pixel of a thumbnail is the mean of a square of 2 by 2 pixels of the picture, so a line of 1 pixel stays a line and a letter keeps its form. The text of a thumbnail is not meant to be read: the link of the thumbnail opens the picture at its full size. The repository holds no thumbnail.

The design: `docs/SITE.md`, "The thumbnails".

Do not use: miniature, low-resolution copy.

### Guide

A guide is a page of the site made from a document of `docs/`: how a part of the system is designed, and why.

Examples: `docs/ARCHITECTURE.md`, `docs/QUIC.md`, `docs/FONTS.md`. A guide states each rule with no name of a person or a role, no step, no choice and no date: git keeps who decided and when. The working records are not guides and are not published. On the site a guide has the documentation layout, and its code spans link to the declarations and documents that they name.

The design: `docs/SITE.md`, "The pages".

Do not use: article, tutorial (for this).

### Reference table

A reference table is a page of the site that the tool generates from the code or the files that define a thing: what exists in this build, each row with a link to its source line.

The tables: the kernel operations, the context of a program, the error kinds, the grants of the root service, the fixed ranges, the commands of the console and of the tool, the types, the licenses, the numbers, the modules and the module graph. Each one reads one form of its source file; when a file loses that form, the command stops with the file and the line. A row with an id is a symbol.

The design: `docs/SITE.md`, "The reference tables".

Do not use: API docs, listing.

### Module page

A module page is the reference page of the site for one module of the build: its documentation, its exports, its imports and, for a program, its grants and its budget.

The page `docs/reference/modules/<name>/` gives the documentation of the module (the comment before `package` in its source), its identity card, its source folder, its size in the boot image, its imports and the modules that import it, a figure of its neighbours in the module graph, and each export as a symbol with its signature as the console prints it. For a program it lists the grants and the budget that the root service gives it. The pages come from the same reader as the build: no module needs to be built.

The design: `docs/SITE.md`, "The module pages".

Do not use: API page, package page.

### Status page

The status page is the page of the site that gives the state of each property: its status, what it promises, what the machine test shows of it, and what is not done.

It writes no sentence of its own: each cell is a part of `docs/PROPERTIES.md` or of `docs/DEMONSTRATIONS.md`. What is not done is on it as plainly as what is done. It is a section of its own, outside the docs, and a line of the project menu of the bar. It is not the roadmap: the status page says what is built and what is missing, the roadmap says what work is planned, and one line of the status page leads to it.

The design: `docs/SITE.md`, "The status page".

Do not use: progress page, "what runs today".

### Site address

The site address is the absolute address where a host serves the site, in the form `https://<host>/<path>`.

`SITE_ADDRESS` holds it (`https://modus.froment.software/`), and `modustool site --address` sets another for one run. Some parts of a page must be absolute to be right for the program that reads them, so they exist only with a site address: the canonical address, Open Graph, the page graph and the sitemap. With no site address the pages have relative links only, and work from a folder of a disk.

The design: `docs/SITE.md`, "What other sites read".

Do not use: base URL, domain (for this), root.

### Canonical address

The canonical address of a page is its one absolute address, which the page names in its head with `<link rel="canonical">`: the site address and the folder of the page, with a final slash.

A page can be reached at several addresses (with `index.html`, through a redirect page); the canonical address tells a search engine which one is the page. Example: `https://modus.froment.software/docs/reference/licenses/`. The command checks that each page has its own and that no two pages share one.

The design: `docs/SITE.md`, "What other sites read".

Do not use: permalink, URL (for this).

### Redirect page

A redirect page is a small file of the site at an old address of a page, which sends the reader straight to the address of today.

The addresses of the site changed twice, and the old ones were public: first `.html` files (`reference/licenses.html`), then folders before the move under the docs (`reference/licenses/`). A rule gives each old path from the path of today, and a redirect page is written at each one: a refresh with a delay of 0 and one visible link, with no script. It is not a page of the site: it is in no sitemap, no search index and no feed, and it never names another redirect page.

The design: `docs/SITE.md`, "The redirect pages".

Do not use: redirect, alias, forward (for this).

### Page graph

The page graph is the JSON-LD of one page: one `@graph` of schema.org nodes, built from the data that the page shows, whose nodes name each other by their `@id`.

It tells a search engine what the page is: the site with its search, the system as a `SoftwareApplication`, its source code, the page and its breadcrumbs, and what the page is about (a `TechArticle` for a guide, a `DefinedTermSet` for the glossary, a `Blog` for the news). No value is typed for the graph. It exists only with a site address, and the command parses each graph and checks that each `@id` that it names exists.

The design: `docs/SITE.md`, "The page graph".

Do not use: structured data (for this), schema, rich snippet.

### Sitemap

The sitemap is the file `sitemap.xml` of the site: the canonical address of each page, for a search engine.

It lists each page that the command writes, once, and no redirect page. A page has a `lastmod` only when the tool knows the date of its last change (the news and the releases): a wrong date teaches a search engine to ignore the field. `robots.txt` names it. Both exist only with a site address.

The design: `docs/SITE.md`, "The sitemap, robots.txt and the feeds".

Do not use: site index, page list.

### Site menu

The site menu is the menu of the bar of the site: one `details` element that holds the sections and the search field.

One list of links serves every width, so a screen reader reads each section once. Under 720 pixels it is a square button with three lines, and the open menu lies over the page. On a wide screen it is open and its button hidden, so it reads as the bar. On the docs home it holds the sections only. With no script, the button still opens it.

The design: `docs/SITE.md`, "The site menu".

Do not use: burger menu, hamburger, drawer.

### Project menu

The project menu is the menu of the bar of the site that holds the sections that are not buttons: Status, Releases and Roadmap.

The bar is one line, so three sections are buttons, the ones that a first reader looks for: Docs, Gallery and News. The three pages that report how the project goes are the lines of one menu, under a button with the word "Project". The menu is a `details` element, so it opens and closes with no script. Under 720 pixels its three sections are lines of the site menu. It is not the site menu, which holds every section and the search field on a narrow screen.

The design: `docs/SITE.md`, "The buttons and the menu of the bar".

Do not use: dropdown, more menu, submenu, overflow menu.

### Subscribe menu

The subscribe menu is the menu under the heading of the page of the releases and of the page of the news that holds the ways to follow the changes of the system.

Its button has the word "Subscribe" and a chevron that turns when the menu opens. Its panel has two links: "Atom feed", the feed of the page (`releases.xml` or `news.xml`), and "Watch releases on GitHub", the releases of the repository. It is a `details` element, as the project menu: it opens and closes with no script, and the panel is as wide as its longest line. It is not the project menu, which is in the bar.

The design: `docs/SITE.md`, "The subscribe menu".

Do not use: RSS menu, follow button.

### Documentation layout

The documentation layout is the layout of a page of the docs: the documentation tree at the left, the text in the middle, "On this page" at the right.

Each guide, reference page, module page, the glossary, the status page and the index pages use it. The home, the docs home, the news and the releases have the presentation layout: one centred column of at most 1152 pixels. The writer of each page states its layout; the tool does not guess it from a path. Under 1100 pixels "On this page" folds above the text; under 720 pixels the tree moves into the site menu.

The design: `docs/SITE.md`, "The two layouts".

Do not use: docs theme, sidebar layout.

### Documentation tree

The documentation tree is the list of the documentation pages of the docs, generated from the pages that exist, at the left of each documentation page.

Its first link is the docs home. Then come the guides in their reading order, the reference pages, the modules in their groups (Kernel, Programs, Modules) and the status. It is one `nav` on each page, in the site menu on a narrow screen. Tree lines show its levels.

The design: `docs/SITE.md`, "The two layouts".

Do not use: sidebar, navigation tree, table of contents (for this).

### On this page

"On this page" is the list of the headings and the symbols of one documentation page, each a link to its id.

It lists the headings of levels 2 and 3 and each symbol, in the order of the page: on a module page, each export. A heading of level 3 or a symbol is a branch of the heading of level 2 before it, with a tree line. From 1100 pixels it is a column at the right of the text with its own scroll; on a narrower screen it is a `details` above the text.

The design: `docs/SITE.md`, "The two layouts".

Do not use: table of contents (for this), outline, minitoc.

### Tree line

A tree line is a line of 1 pixel that joins an item of a navigation of the site to the item above it in the tree.

A vertical line runs down from under a parent, beside its branches, and a short horizontal line, the branch, goes from it to each item. The vertical line stops at the branch of the last item. The documentation tree and "On this page" have tree lines at each level under their first list; the lines that lead to the current item are in the color of the line under a link. A list of the text of a page has none.

The design: `docs/SITE.md`, "The tree lines".

Do not use: guide line, indent guide, connector.

### Symbol

A symbol is one documented thing of a reference page or a module page: a kernel operation, a command of the console or of the tool, an export of a module, or a row of a reference table with an id.

A symbol shows its name as a heading with an id (`operation-<name>`, `export-<name>`), its signature in a block of code, the text of its source comment as Markdown, its facts (the statuses of an operation, the parameters and error record of an export) and a link to its source line. "On this page" lists it.

It is not a symbol of an object file: a module exports by index, and a name is looked up only at build time. A declaration of the sources is in the declaration index, not a symbol.

The design: `docs/SITE.md`, "The reference tables".

Do not use: entry, item, API (for this).

### Value kind

A value kind is what a technical value is for a reader, such as a number, a size, a time, a handle, a status or a module, so that every place that shows the value can give it one look.

The kinds are one enumeration of the system, `value_kinds.Value_Kind` (`src/library/contract/value_kinds`). One table gives each kind its color in each color scheme, and another its kind icon. The site and the log use the same kinds, so a size has one color on a page and in the log. The writer of a table, a symbol or a line of the log states the kind of each value: no text is classified by its look. It is not a type of a language: `Size` and `Number` can both be an `int`.

The design: `docs/SITE.md`, "The kinds of values".

Do not use: value type, badge, chip, tag (for this).

### Declaration index

The declaration index is the list of every top-level declaration of the sources of the system, which `modustool site` reads with the parser of Odin so that a code span can link to what it names.

It reads each source file of the system but the tests. For each procedure, type, constant and global variable, it keeps its package, its file and line, its kind, its one line of Odin and its comment. A code span of a guide, a news entry, the glossary or a source comment whose whole text is a name (`graphics.text_proportional`) then becomes a link with a declaration card.

It is not a symbol table of an object file, and its entries are not symbols: a symbol is a documented thing of a reference page.

The design: `docs/SITE.md`, "The declaration index".

Do not use: symbol table, symbol index (a symbol is a documented thing of a reference page), ctags.

### Declaration card

A declaration card is the short card of one declaration of the declaration index, which opens over a link that names it.

It shows the name, the kind and the package, the one line of Odin colored, the first sentence of the comment ("A procedure with no comment in its source." when there is none), and the file and line as a link. A page holds the card of each declaration that it links to once. The script opens it when the pointer rests 400 ms on the link or the focus reaches it; with no script the link works and no card opens.

The design: `docs/SITE.md`, "The declarations of the sources".

Do not use: tooltip, hover card (for this).

### Type card

A type card is what the site states of one type of the contract: its kind, its size, its alignment, its fields with their offsets and the padding, or its members with their values, where it is named, and its source line.

The size, the alignment, the offsets and the values come from the compiler that builds the tool (`type_info_of`), so they are the numbers of the build, not a reading of the text. The page of the types holds each whole card; a page that names a type holds a short card that its name opens. A reader of a record of a ring sees with it where each byte is.

The design: `docs/SITE.md`, "The types".

Do not use: tooltip, type info, hover card (for this).

### Byte layout

A byte layout is the diagram of the bytes of one record of a format: rows of 8 bytes, the offset of each row, and each field as a rectangle over its bytes with its name and its size.

It answers "where is each byte?" in the manner of the header diagrams of the RFCs. The offsets and the sizes come from the compiler that builds the tool, and the type and the comment of each field from the source, so the diagram cannot differ from the code. A guide marks its place with a fence `byte-layout`, which the tool writes and checks. A byte layout is not a type card: the card lists the fields of a type; the layout draws them in place.

The design: `docs/SITE.md`, "The byte layouts".

Do not use: packet diagram, struct diagram, byte map.

### Guide diagram

A guide diagram is a picture in SVG that the tool draws, when it builds the site, from a fence `mermaid` of a guide: a flowchart or a sequence diagram.

It shows the parts of the system and their order, or a flow in time, with the colors of the site and no script. The tool reads a stated subset of mermaid, measures each label with the font of the diagrams, and lays out the boxes and the lines. A diagram that it cannot draw stops the build of the site with its line. The text of the diagram stays under the picture. It is not a byte layout, which draws a record from the code.

The design: `docs/SITE.md`, "The diagrams".

Do not use: mermaid chart, rendered mermaid.

### Identity card

An identity card is what the site states of one module: its name, its kind, its hash, its size, the counts of its exports, its imports and the modules that import it, its license, and the first sentence of its documentation.

It answers "what is this module?" in one box: the hash is its identity (64 hexadecimal digits), the counts place it in the module graph, and the license comes from the license rows of its source folder. The module page shows it after the documentation; the page of the module graph shows it for the node under the pointer or the focus.

The design: `docs/SITE.md`, "The identity card".

Do not use: tooltip, hover card, module info (for this).

### Document pointer

A document pointer is a part of a source comment that names a document of `docs/` and a place in it, for a reader of the code.

Examples: `(docs/ARCHITECTURE.md, "Kernel systems")`, `docs/FONTS.md, section 12.4`. A pointer is how a comment stays short: the comment gives the reason in a few words and points to the guide for the rest. `modustool site` checks every pointer of every source file: a label that finds no heading stops the command. On a page, the site writes a document reference in its place.

The design: `docs/SITE.md`, "The forms of a pointer".

Do not use: doc link, citation (for this).

### Comment breach

A comment breach is a comment of a source that names a property, a choice, a step, a review, a finding or a decision by its number, its label or its date, in place of the reason.

A number means nothing to a reader of the code, and it goes stale when the record changes. So a comment states the reason in plain words, or points to a heading of a guide. `modustool check` reads every comment of the sources and fails on each breach, with its file, its line and its form: "(property 14)", "(P20)", "choice 186", "D-047".

The design: `docs/TOOLS.md`, "The comments of the sources".

Do not use: violation, lint error (for this).

### Document reference

A document reference is what a page of the site writes for a document pointer, or for a code span that names a document: a link with the title of the document and the text of the heading that the pointer names.

Example: the pointer `(docs/ARCHITECTURE.md, "Kernel systems")` becomes the link "Architecture: Kernel systems", in the color and with the icon of the value kind Guide. A comment shows its references on one line "See:" after its text, so no reference breaks a sentence. A reference to a working record links to the file in the repository, and says so. The command prints the count of references and those whose labels found no heading.

The design: `docs/SITE.md`, "The references to documents".

Do not use: tag, badge, cross-reference (for this).

### Wire form

A wire form is one of the types of the call form of the module contract, a member of `Type` of `src/library/contract/module`: Integer, Text, Record, Handle, Table or Bytes.

It says how a call carries a parameter or a result: in one word of the call form, and what that word holds or points to. An Integer is the value; a Text, a Record, a Table and Bytes are an address of memory of the caller with a header; a Handle is a handle number. Because each parameter has a wire form in the description of an export, one export serves a direct call, an isolated call and the console with no glue code.

The design: `docs/MODULE_CONTRACT.md`, "5. The types".

Do not use: marshalling type, ABI type.

### File version

A file version is the first 8 bytes of the BLAKE3 hash of a file of the site, in hexadecimal, added as `?v=<version>` to each link to that file.

A proxy in front of the site keeps a file for hours. The style sheet, the scripts and the search index change between builds, so each link names their bytes: `style.css?v=<16 hexadecimal digits>`. A new build gives a new address, and no proxy serves an old file with a new page. The same bytes give the same address. A page itself cannot carry a version; the line "This page is from an older build: reload" covers that case.

The design: `docs/SITE.md`, "The versions of the files".

Do not use: cache buster, fingerprint, hash suffix.

### Site workflow

The site workflow is the workflow of GitHub Actions `.github/workflows/site.yml`, which builds the site at each push to `master` and gives it to GitHub Pages.

It holds no logic: each step calls `modustool` or an action pinned by its version tag. It builds the boot image (`modustool build`) and the site (`modustool site`), then deploys `build/site`. A failed check of the site stops the run, and the site of the last run stays online. It runs no machine test: the numbers come from the measure record.

The design: `docs/SITE.md`, "How the site is published".

Do not use: pipeline, CI job, deploy script.

### Release workflow

The release workflow is the workflow of GitHub Actions `.github/workflows/release.yml`, which publishes the release image, the checksum list and the release signature of a release at each push of a tag `v<release number>`.

It holds no logic: each step calls `modustool`, Nix or an action pinned by the commit of its version. A first job runs `nix flake check` of the tagged commit. A second job, the one that reads the keys, checks that the tag names the release number, writes the key folder and makes the files. A third job, with no key, creates the release of the tag with the files and with the notes of the release from `CHANGELOG.md`. A failure stops the run, and nothing is published.

The design: `src/md/infrastructure/release_image.md`.

Do not use: release pipeline, deploy script.

### Check workflow

The check workflow is the workflow of GitHub Actions `.github/workflows/ci.yml`, which runs `nix flake check` at each push.

It holds no logic: one step calls Nix. `nix flake check` runs the hooks and `modustool check` in an empty folder, with the machine tests. A newer push of the same branch cancels an older run.

The design: `docs/TOOLS.md`, "The commands of the tool".

Do not use: CI pipeline, build job.

### Test part

A test part is one row of the table of the machine test: one or more machines that share a data disk, a TPM state or a value from one machine to the next, and nothing with another test part.

`modustool test <part>` runs one test part alone and builds only its boot volumes; `modustool test` runs every test part, several at once, at most one for each four processors of the host. Each test part starts from a new data disk of its own, so it does the same work alone and in the whole test. Example: the test part `random` runs three machines, and its last step checks that the values that the three machines drew differ.

The design: `src/md/infrastructure/machine_test_parts.md`; `docs/TOOLS.md`, "The parts of the machine test".

Do not use: test suite, test group, shard.

### Full check

A full check is `nix flake check` and `modustool screenshots`, both passed.

`nix flake check` runs the hooks and `modustool check` in the sandbox of Nix: the host tests, the checks of the sources, the whole machine test and the second build. `modustool screenshots` takes the pictures and the logs of that check from the store, with no second run of the machine test, runs the measure runs on the host, and writes the measure record. A full check runs once at the end of a batch of features, before the release and the publication of the site.

The design: `src/md/infrastructure/full_check.md`; `docs/TOOLS.md`, "What each tool reads".

Do not use: CI run, test suite, full test.

### Incremental build

An incremental build is a build that keeps each output of an earlier build whose inputs are the same, and builds only the others.

It rests on the rule of the reproducible build: the same inputs give the same bytes. `modustool build` keeps a module when the build record of each of its two steps has the build key of its inputs, and each output has its recorded hash. It runs the conversion alone when only the file of an import changed. The tool builds in every case of doubt: no record, a damaged record, a changed or missing file. It is not a cache: the kept output is the file of the build folder itself.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: build cache, cached build, partial build.

### Build key

A build key is one BLAKE3 hash over the inputs of the build of one thing (one step of a module, one boot volume, or the binary of the tool in the development shell), in a fixed order.

A module has two keys, one for each step of its build. The key of the compile step covers each source file that the compiler reads, the commands with each flag, the programs of the build and the tool. The key of the conversion covers the key of the compile step, the linked file and the module file of each import. The tool never records and never compares a key with an input that it cannot read. It is not the hash of a module, which names the output.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: cache key, fingerprint, input hash (for the whole key).

### Build record

A build record is the small text file that the tool writes after it built one thing: its build key, the hash of each output, and the list of the files that the compiler read.

A module has one for each step of its build, in `build/modules/`; a boot volume has one in `build/boot/`; the binary of the tool has one in `build/tool/`. At the next build, the tool computes the key again from the recorded files, and keeps the outputs when the key and each hash of an output are the same. A record that is absent or damaged is no record: the tool builds, with no error.

It is not the measure record and not the line of the reproducible build that the site quotes.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: cache entry, stamp, manifest (for this).

### Compile step

The compile step is the first of the two steps of the build of a module: the compiler, `llc`, the assembler and the link, which give the linked file of the module.

It reads the sources of the module and no file of an import: a source declares an export of an import in a `foreign` block, and the link leaves that symbol not defined. So its build key holds no import, and a change inside an import does not run it. The tool runs it when a source, a command, a program of the build or the tool changed, or when the linked file is gone.

It is not the whole build of a module: the conversion follows it.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: compile phase, compiler stage, object step.

### Conversion

The conversion is the second of the two steps of the build of a module: the tool writes the module file from the linked file, with the description of the exports and the hash of the file of each import, then the debug object.

It is the one step that reads the file of an import. When the file of an import changed and the sources of the importer did not, the tool runs the conversion alone. A converted module has a new hash, so each module that imports it is converted too. Example: a change of the body of an export of a library builds the library and converts each of its importers.

It is not a link: no code of the import enters the module.

The design: `docs/TOOLS.md`, "The incremental build", and `docs/MODULE_CONTRACT.md`, "The steps of one module, as implemented".

Do not use: relink, repackage, packaging step.

### Whole build

A whole build is a build that ignores every build record: it builds each module and each boot volume, and writes new records.

`modustool build whole` asks for one. The commands that prove the build are always whole builds: `check` and `repeat` compare the results of two runs of the compiler, and a kept output would be compared with itself. `nix flake check` builds in an empty folder, so its build has no record to read.

The design: `docs/TOOLS.md`, "The incremental build".

Do not use: clean build, fresh build, full build.

### Measure record

The measure record is the file `docs/measures/measures.txt`: the measured numbers of the last full check, each as the whole line of its log, with the facts of its run.

The site workflow runs no machine test, so the pass that commits the pictures also commits the numbers. `modustool screenshots` writes the record: one line `key value` for each fact (its time, its release, its commit, the state of its tree, its host, the count of checks that passed), then each number with its log, its line and its machine, and the stages of the start. A number of speed is a measure: it is printed and recorded, and never makes a test fail.

The design: `docs/SITE.md`, "The measure record".

Do not use: benchmark results, metrics file, numbers cache.

### Measure history

The measure history is the folder `docs/measures/releases/`: one copy of the measure record for each release that a full check measured, named by its release number.

It lets a reader see whether a change made the system faster or slower. `modustool changelog release` writes the copy of each new release. A release whose record holds the same run as the release before gets no copy. The page of the measured numbers draws, from the copies, one chart for each measure over the releases: one number of its line, at equal steps, from zero. It is not a record of each full check: a full check between two releases replaces the measure record only.

The design: `src/md/features/measure_history.md`; `docs/SITE.md`, "The measure history".

Do not use: benchmark history, performance log, trend file.

### Measure run

A measure run is a machine whose boot image holds the resource `measure_run`, in which each program measures its rates over a duration.

In a test, a program runs its checks by a count of work and writes no rate. In a measure run, the root service says so in the context of each program; the program reads it with `system.measure_run()`, runs the same work for a fixed duration, and writes its rates. Only the boot image differs from the test: it has one resource more. `modustool measure` starts a measure run; `modustool test` never does. It is not the measure build, a build of the kernel with no check.

The design: `docs/TOOLS.md`, "A check by count, a measure by time".

Do not use: benchmark mode, benchmark run, performance mode.

### Settled screen

A settled screen is a screen that shows the last picture of each window: each program sent the picture of its last change, and the compositor drew each picture that it received.

The machine test takes a picture only of a settled screen. When it can call the compositor, it reads the state of the programs before and after it reads the windows and the screen: a program that waited in the two reads, with the same count of kernel entries, did not run between them. When it cannot call, it takes pictures until two in a row are the same. A window that draws with no end is left out. It is not a fixed time before a picture.

The design: `docs/TOOLS.md`, "When the tool takes a picture".

Do not use: idle screen, stable frame, quiescent.

### Due picture

A due picture is a picture that a program owes its window: a change waits for it while the program waits on its clock or for the compositor.

A program that paces its pictures, such as a terminal, says it before such a wait with the record `Picture_Due` (`display.picture_due_set`), and its next `Present` ends it. The compositor gives it as `due` in `compositor.windows()`, and the screen is not a settled screen while a window has one. The terminal decides it at the start of each turn of its loop, so a record that came while it drew its last picture is a due picture too. It is not a picture that the compositor has and did not draw yet: that is `waits`.

The design: `src/md/features/terminal_due_picture.md`.

Do not use: pending frame, redraw flag, frame request.

### Hang bound

The hang bound is the one time in a test: it ends a test that waits for ever, and checks nothing about speed.

A test checks a condition. A time in it has one role, to end a hang, so it is generous and the same for each wait: `HANG_BOUND` for a step of a machine test, and `system.TEST_HANG_BOUND_MILLISECONDS` for the checks of a program, so that the program reports its own hang before the tool ends the machine. A bound of its own needs a named constant with its reason. It is not a timeout that a test asserts: no test fails because the host is slow.

The design: `docs/TOOLS.md`, "The bounds of the tests".

Do not use: timeout (for a test), deadline (for a test), time limit.

### Stall

A stall is a case that writes a count of its progress and whose count did not grow for the hang bound.

A long case (the fault ring under load, for example) can take any time on a slow host and still be right. So the test bounds a stall, not the whole run: it ends the case when the count stays still for `system.TEST_HANG_BOUND_MILLISECONDS`, or after 600 s in all. The report names the step where the count stopped, which tells a lost wake from a slow host.

The design: `docs/TOOLS.md`, "The bounds of the tests".

Do not use: freeze, no progress timeout, watchdog.

### Fuzz target

A fuzz target is a procedure of the tool that gives one fuzz input to the real code of the system on the host and checks its oracles.

It calls the procedures that the system runs, from the source library `modus`, never a copy of them. A raw target gives the input as the bytes that the system reads; a generated target reads the input as choices and builds a whole value from them. The tool runs a target in a child process, so a fault ends the child and not the tool. `modustool fuzz list` names the targets. It is not a host test: a host test checks the cases that its writer chose, a fuzz target the cases that the engine makes.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: fuzzer harness, fuzz driver, fuzz test.

### Fuzz input

A fuzz input is the bytes of one execution of a fuzz target.

For a raw target, they are the bytes that the code of the system reads. For a generated target, they are a choice sequence: the generator reads its next choice from them at each decision, and reads zeros when they end. Both kinds are bytes, so one engine, one minimizer and one corpus serve both.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: test case (for this), seed (for this), sample.

### Corpus

The corpus is the set of fuzz inputs of each fuzz target that the repository keeps, one file for each input, named by the BLAKE3 hash of its bytes.

It has the regression inputs, one for each fuzz finding after its fix, which stay for ever, and the reach inputs, the smallest set of inputs that gives each edge class that the long runs reached. `modustool check` runs each input of the corpus again and refuses a corpus over its bounds.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: seed corpus, test suite (for this).

### Edge counter

An edge counter is a byte that instrumented code adds one to each time it passes one edge of its control flow.

`opt` of the LLVM of the build adds the counters to the IR of the packages under test, and the fuzz target reads them after each execution. An input is kept when it gives an edge a count in a class that no kept input gave. In the planned fuzzing of the kernel operations, the counted kernel gets counters too, which only the tool reads, through the memory file of the machine (`src/md/infrastructure/kernel_fuzzing.md`). It is not the coverage of a glyph.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: coverage (for this), code coverage, bitmap.

### Oracle

An oracle is a condition that a fuzz target checks after each execution of a fuzz input.

The oracles are, in order: no fault, an end before the hang bound, the contract of the reader, a round trip through the writer, a model that gives the same answers, and a second reader of the system that agrees.

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: assertion (for this), checker.

### Fuzz finding

A fuzz finding is a fuzz input that breaks an oracle, with its signature: the oracle and the place of the fault.

Two inputs with one signature are one fuzz finding. The tool minimizes each one while its signature stays. After its fix, its input enters the corpus as a regression input, and a host test names the expected answer when it is more than "no fault".

The design: `src/md/infrastructure/fuzzing.md`.

Do not use: crash (for every finding), bug report.

### Operation sequence

An operation sequence is the fuzz input of the kernel operations: a list of sequence steps whose arguments follow the forms of `OPERATIONS`, which a child program runs in a test machine.

Its format is the contract package `operation_sequence`: a header, the sequence areas, the sequence steps, and the content of the areas. A handle argument names a start handle or the result of an earlier sequence step by its place, so the sequence does not depend on the values of the handles of one run. The tool builds sequences from choices with a generator, and `check` reads them; the machine that runs them is planned work of `ROADMAP.md`.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: syscall program, call trace.

### Sequence step

A sequence step is one command of an operation sequence: an operation word, its flags, and seven arguments, each with its argument source.

The runner writes one command record for each sequence step, and enters the kernel for each one, or once for the steps that the flag "same kernel entry" joins. A sequence step names the result of an earlier step by the place of that step, never by a handle number. It is not a step of the project, which is a commit, and not a step of a machine test.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: call (for this), syscall, instruction.

### Argument source

An argument source is where the value of one argument of a sequence step comes from: a plain value, a start handle, an address in a sequence area, a thread entry of the runner, or the result of an earlier sequence step.

It is the enumeration `operation_sequence.Argument_Source`. `check` refuses a word that names no member, and a word that the source does not use and that is not 0. The runner converts each argument into the word of the command record at its run, so one sequence means the same at each run.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: argument kind, argument type (for this).

### Sequence area

A sequence area is a memory object of 1 to 16 pages that the runner maps for an operation sequence, with a page with no access after it, and that an address argument names with an offset.

The sequence gives the bytes of the start of each area, at most 4096 bytes for all its areas. An offset can reach the page with no access, so a record that crosses the end of an area is an input of the kernel. The runner holds a start handle with each right of memory for each area. It is not a thread area and not the extended state area.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: buffer (for this), region (for this).

### Counted kernel

The counted kernel is the test kernel `kernel_edge_counters`: the sources of the kernel built with an edge counter at each edge, which counts only for a counted program.

The tool reads its counters through the memory file of the test machine, and no program of the system reads them. The release refuses it by its hash, by its signature and by its bytes. A finding on it is confirmed on the kernel that ships, which has no counter. It is planned work of `ROADMAP.md`. It is not the measure build, and not the test build of the kernel checks, which every kernel of the tests has.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: instrumented kernel, coverage kernel.

### Counted program

A counted program is a program whose commands and exceptions the counted kernel counts: the runner of the operation sequences, by its name, and each program that a counted program creates.

The counters then say which kernel code one operation sequence reached, and not what the tick, the scheduler or another program did. The kernel that ships has no counted program. It is planned work of `ROADMAP.md`.

The design: `src/md/infrastructure/kernel_fuzzing.md`.

Do not use: traced program, program under test (for this).

### Tagline

The tagline is the one line under the name in the head of the home of the site: the first sentence of the first paragraph of `README.md`.

The rest of that paragraph is a section "What it is" lower on the home, after the news, so the first screen of a phone holds the mark, the name, the tagline and the links. The description of the home in its head and in the page graph stays the whole paragraph, cut at 160 bytes. Like every description of the project, it says what the system does for its user, and names no technical part.

The design: `docs/SITE.md`, "The pages".

Do not use: slogan, subtitle, hero text.
