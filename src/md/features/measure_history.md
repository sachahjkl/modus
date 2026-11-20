# The measure history: the numbers of each release, and a chart of each measure

## Purpose

The measure record holds one run: the last full check. Each run replaces it. A reader then sees the numbers of today, and cannot see whether a change made the system faster or slower.

The measure history keeps the measure record of each release. The page of the measured numbers draws one small chart for each measure, with the releases on the horizontal axis. What a reader sees, and the commands, are in [`docs/SITE.md`](../../../docs/SITE.md), "The measure history", and [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The release".

## Constraints

- **No number is invented.** A point of a chart is a number of a line of a log that a full check wrote, before the release that the point names. A release with no record of its own has no point.
- **A file of the repository, read on a clean checkout.** The site workflow runs no machine and has no tag history to walk at each build.
- **The release command writes it.** No step of a release is a step by hand.
- **The measure record keeps its form.** A second form for the same facts is a second parser and a second place to break.
- **The noise is said.** The host that runs the full check runs other work. Two runs of one build differ.
- **The page holds no script.** A chart is SVG markup and rules of the style sheet.

## The chosen form

### One copy of the measure record for each release

The history is the folder `docs/measures/releases/`. It holds one file for each release: `<release number>.txt`, the bytes of `docs/measures/measures.txt` at the release, in the form of the measure record.

- `modustool changelog release <number>` copies the measure record to `docs/measures/releases/<number>.txt`. `ship` adds the folder to the commit of the release.
- **The same run is copied once.** When the record holds the run of the newest copy (the same `time` and the same `commit`), the release command writes no copy and says so. No full check ran between the two releases, so the new release has no numbers of its own. A copy would draw a flat step that no run measured.
- A file is never changed after its release. Two branches never write the same file, because one release number is made once.

### The old releases: from their tags, once

`modustool measure-history` walks the release tags `v*`, oldest first. For each tag it reads `git show v<number>:docs/measures/measures.txt`. A tag whose tree holds a record that reads in the form gets its copy, with the same rule of the same run. A file that exists is kept: the command prints a file whose bytes differ, and changes none. It prints the count of the tags, of the tags with a record, and of the files written.

The command is for the releases that came before the release command copied the record. At its first run, 89 tags existed, and one of them, `v0.92.0`, held a measure record: the first record was written after `v0.91.0`.

The record in the tree of a tag says `release 0.91.0` for `v0.92.0`: the full check ran before the release commit, on the newest release of its changelog. The history names a copy by the release whose tree holds it, the file name, and not by its line `release`. The numbers are the numbers of the code that the release shipped, or of a commit just before it; the page gives the commit of the run.

### The identity of a measure: its sentence

A measure is the same measure across releases when its sentence (the key `number` of the record, the sentence of `measure_entries`) is the same. A measure whose meaning changes (another count, another size, another machine) gets a new sentence: its history then starts again, and the old sentence is not drawn.

### The number that a chart follows

A line of a log holds several numbers: the lock measure gives 1, 2 and 4 lockers; the scheduler gives wakes, delays and shares. The chart of a measure follows one number, the one that its sentence names first. The table `measure_history_series` gives, for each sentence: the title, the words of the line just before the number, the words just after it (its unit as the log writes it), the unit in words, and whether a higher or a lower number is faster.

The number is read from the words of the line, as the home reads its bar charts. A line whose words changed gives no number for that release: the chart has a gap, never a wrong point. The value is the text of the log, digits with at most one decimal point.

A measured line that its writer writes as a log fact is read in its sentence: the tool renders the line of the fact with the module files of the build before it searches the log (`measure_log_rendered`), for the record, for the check of a line and for the page. The run of the tool keeps one catalog of the module files: it reads a module file once, and again only when its size or its time of change differs, so the logs of one record do not read and hash each module file again (`build.fact_lines_render_of_build`). The fact template is the line of before, so the record keeps its form and the history keeps its series. The record holds sentences, not fields: a number read from a field, with no words around it, needs a field of the record for each value, which is a second form of the record ([log_facts.md](log_facts.md), "The machine tests").

### The chart

- One card for each measure with at least two points. The rule "a chart or nothing" holds: a measure with one point has no chart, and the section says how many releases the history holds.
- The horizontal axis is the releases of the history, in their order, at equal steps. It is not a scale of time: the page says so. Every chart has the same places, so a release is at the same place in each chart.
- The vertical axis starts at zero and ends at the largest number of the measure. Two lines mark zero and that number, and the text over the chart states both.
- A run of points of consecutive releases is one line; a release with no number breaks it. Each point is a square in the accent of the measure, with a title that gives its release and its number.
- The release numbers are text of the page under the chart, not text of the SVG: the first and the last, in a row that wraps. A label for each of 90 releases cannot fit in a card without a text over a text.
- Under the chart, a `details` element lists each release with its number, its commit, and its host when the history has more than one host. A phone has no pointer: the list gives each number with no hover.

### The noise

The section says, before the charts: each point is one run of a full check, on a host that runs other work; two runs of the same build differ; a step between two releases that is not larger than that spread says nothing; and a change of the host is not a change of the system.

## Refused forms

- **A file of rows: a release, a measure, a number.** It is a second form for facts that the record holds, and it keeps the number but not its line. The number that a chart follows can change later, or a second number can get a chart: a row keeps only the choice of the day, a copy of the record keeps the whole line.
- **The tags read at each build of the site.** A clean checkout of the site workflow can be shallow, the walk runs git once for each tag at each build, and a test runs no git.
- **Copy the record at each full check.** The history would hold runs of commits that no release shipped, and a release would have many points.
- **Name a copy by its line `release`.** That line is the newest release in the tree of the run, the release before the one that shipped the code.
- **A copy for each release, also with the run of the release before.** A flat line between two releases would say "no change" when nothing was measured.
- **The numbers of the old changelog and news entries.** A number in prose has no log line and no run, and some were measured on other hosts in other forms. Taking them would invent a history.
- **All the numbers of a line in one chart, one line each.** The lines then need a legend and a way to tell them apart that is not the color: the colors are the colors of the concepts. And the scheduler line has several units.
- **A scale of time on the horizontal axis.** Several releases come out in one hour, and then none for a day: the points would pile up, and the gap would look like a long flat step.
- **A vertical axis from the smallest number.** A change of 1 % would fill the chart. The rule of the site is that a scale never lies ([site_home.md](site_home.md)).
- **The labels of the releases in the SVG.** The SVG scales with its card, so a text in it has no width that the tool can compute.
- **A chart of the home.** The home shows bars of one run; a history is a record, on the page of the records.

## Subtle points

- **The release command reads the record before it writes any file**, and refuses a record that does not read. A release then never has half its files.
- **A ship that fails after the copy** puts the tree back with `git reset --hard`, which keeps a new file that git does not track. `ship` also cleans the folder of the history: the tree was clean when `ship` started, so the only file there that git does not track is the copy of this release.
- **The folder must exist before a release.** `git add -A -- <folder>` fails on a path that matches no file. The folder holds the copies of the old releases from `measure-history`, so it exists from the first run of that command on.
- **The same run is the same `time` and `commit`.** Two records of one commit, measured at two times, are two runs, and both are kept.
- **A measure that leaves `measure_entries`** keeps its lines in the old copies, and no chart reads them: a sentence of `measure_history_series` must be a sentence of `measure_entries`, and a host test checks it.
- **A record that names no commit** (`commit unknown`) still has its points; the list says "unknown".

## State

Built: the folder of the copies, the copy in the release command and in `ship`, the command `measure-history`, the table of the followed numbers, the charts and the list on the page of the measured numbers, and the host tests of the read of a number, of the decision of a copy and of the SVG of one chart.

Left: nothing. The first chart appears with the second release that has a run of its own.
