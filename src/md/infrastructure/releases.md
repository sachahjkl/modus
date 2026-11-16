# Releases: the heading with its time, the release links, the tag and the command ship

## Purpose

A release of modus is one section of `CHANGELOG.md`, one commit on `master` and one annotated, signed git tag `v<release number>` on that commit. One command, `modustool ship`, makes all three and pushes them at once. A reader of the changelog, of the releases page and of the feed `releases.xml` sees when each release came out, to the minute, in UTC. A reader of the repository finds each release as a tag, and each section of the changelog links to it.

What changed: a release was a section of the changelog only, with its day, and the coordinator made it with several commands. It now has a tag, a time and a link, and one command makes it. The commands are in [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The release"; the format of the fragments is in `changelog.d/README.md`; the page and the feed are in [`docs/SITE.md`](../../../docs/SITE.md), "The pages".

## Constraints

- A tag never goes out without its commit, and a commit of a release never goes out without its tag.
- Two sessions that release at the same time never publish one release number twice.
- The time of a release is the true time of its commit. The tool never writes a time that no record holds.
- The release number keeps the rule of the project: `0.N.0` for new work, `0.N.1`, `0.N.2` for a correction after it (`docs/GLOSSARY.md`, "Release number").
- The automation is a command of `modustool` that uses the Odin standard library only. It runs `git`; a test never runs `git`.
- The published boot image and its signatures are not part of this design: the release workflow builds them from the tag.

## The chosen form

- **The heading is `## [0.93.0] - 2026-11-15 18:48`.** The day, a space, the hour and the minute, in UTC. Several releases come out on one day: the time tells them apart and orders them. UTC, because the host of the next release can be in another time zone; the text of the heading has no zone, so the zone is fixed by the rule. The format is the format of the other programs of the same publisher, so one reader reads all their changelogs.
- **A release link for each release, at the end of the file.** `[0.93.0]: https://github.com/sachahjkl/modus/releases/tag/v0.93.0`, one line for each release, newest first, after the last release, with no empty line between them. Keep a Changelog defines these lines: the number of a heading then links to its tag on a forge that renders Markdown. `changelog release` writes the line of the new release above the others. `changelog check` refuses a release with no link, a link with another address, a link for a number that is not a release, and links in another order.
- **The tag is `v<release number>`, annotated and signed.** `git tag -s -a`: the git configuration of the publisher signs it, with SSH today. An annotated tag holds who released, when, and the message; a light tag holds none of these. The signature lets a reader prove that the publisher of the system made the release.
- **`modustool ship <step|correction|<release number>> [--dry-run]`.** `step` gives `0.(N+1).0` after the newest release `0.N.x`; `correction` gives `0.N.(x+1)`; an exact number must come after the newest. The newest release is the larger of `RELEASE_NUMBER` in the source and the highest tag `v*`, both read after the fetch: the tool reads the source file, not the constant that it was compiled with.
- **The order of `ship`.** It refuses a branch other than `master`, a tree with changes that are not committed, and a `master` that does not hold `origin/master`. It then runs the release command (`changelog release`), commits `CHANGELOG.md`, the source of `RELEASE_NUMBER`, the deleted fragments and the copy of the measure record ([../features/measure_history.md](../features/measure_history.md)) with the message `Release <number>`, tags the commit, and pushes both with `git push --atomic origin HEAD:refs/heads/master refs/tags/v<number>`.
- **A refused push is undone and tried again.** When `origin/master` moved, the server refuses the atomic push and nothing goes out. `ship` deletes the tag, resets the commit, merges `origin/master`, takes the next number again, and tries again, three times at most. A merge with a conflict stops `ship` with the merge aborted.
- **The plan is data.** Each git command of `ship` is a list of words that a procedure gives (`ship_*_command`). The host tests check those lists; the command runs them. A test never runs git.
- **`--dry-run`** checks the branch, the tree and `origin/master`, gives the number and the tag, prints the commands and the release that it would write, and changes nothing but the remote-tracking branches that the fetch updates.
- **`modustool changelog times`** gives the time to each old heading that has its day alone, from the first of three records that has a commit on that day: the tag `v<number>`; the oldest commit that wrote `RELEASE_NUMBER :: "<number>"`; the oldest commit that added the heading `## [<number>] - ` to `CHANGELOG.md`. The day is compared in the time zone of the committer, because the old headings were written with the local day of the host; the time written is UTC. It also adds each missing release link. It prints each heading that it could not give a time.

## Refused forms

- **A release that is not a git tag.** That was the form before: the release lived in the changelog only. A reader of the repository then had no ref to check out a release, and the release workflow had nothing to start from.
- **A light tag, or an annotated tag with no signature.** A light tag has no author and no date. An unsigned tag proves nothing about who made it.
- **A push of the commit, then a push of the tag.** Between the two, `origin` can hold a release commit with no tag, or a second session can tag the same number. One atomic push sends both or none.
- **A rebase on `origin/master` after a refused push.** A rebase flattens the merges of the branches and can conflict again on each of them. A merge keeps them.
- **The local time in the heading.** The heading has no zone, so a reader cannot compare two local times written on two hosts.
- **A made-up time for an old release.** Most old releases were written together, after the fact, and no commit holds their moment. A time of `00:00`, or the time of the commit that wrote them all, would be false.
- **The tool computes the number from the commit messages.** A message is free text. The source file and the tags are the records.
- **The full check inside `ship`.** The full check takes a long time and drives machines; `ship` runs after it, on the commit that passed it. `ship` checks what can change between the two: the changelog, through the release command.
- **The packages of the other programs of the publisher.** They depend on a window layer that the tool must not import. The formats are copied, not the code.

## Subtle points

- **The old headings.** `changelog times` cannot give a time to a release whose three records are on another day, or absent. Such a heading keeps its day alone. So `changelog check` accepts a heading with its day alone, except for the newest release: every release that `changelog release` writes has a time, so the newest one always has one. The release command refuses a changelog whose newest release has no time.
- **The order of two releases.** Two releases with a time compare by the day and the time. When one has its day alone, they compare by the day. A heading converted to UTC can fall on the day before its local day: a release at 00:30 in a zone one hour east of UTC. A day-alone heading below it, with the same local day, then has a later day. The check refuses that order and names both lines; `changelog times` prints the same fault before it writes nothing.
- **The pathspec of the source of the release number.** The file moved once. The record of the second source searches `*release/release.odin`, whose `*` also matches `/` in a git pathspec, so both paths are found.
- **The merges.** A release of a branch reaches `master` in a merge. `git log` shows no change of a merge to `-S` unless the log names the first parent (`--diff-merges=first-parent`).
- **The news entries.** An entry with `release: next` keeps it after a release. `ship` does not write the news.
- **The site.** The releases page shows `2026-11-15 18:48 UTC`. The feed writes `2026-11-15T18:48:00Z`; a release with its day alone keeps `T00:00:00Z`.

## State

Built: the heading with its time, its parser and its writer; the release links; `changelog times`; `ship` with its retries and its dry run; the time on the releases page, on the home and in the feed.

Left: the tags of the releases before the first `ship`. No tag is made for an old release: its commit is known only for some of them.
