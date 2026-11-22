# The window of `monitor`

The window of `monitor` shows what the machine does now, from the reports of the kernel: the memory, the counts of the kernel, and one row for each process. This file records three parts of its look: the cards that hold each part, the sample graphs, which show the last minute of three measures, and the intensity steps, which color each gauge by its value. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The window of `monitor`". The colors follow [`docs/DESIGN.md`](../../../docs/DESIGN.md), "4. Color", and [appearance.md](appearance.md).

## The constraints

- **No work in proportion to the data in a frame.** A frame copies what is kept. A value that depends on the samples is computed when a sample comes.
- **No text over another text, and no cut text.** Each text has a box whose width the window knows before it draws.
- **The reference screen.** The window fits a screen of 1920 × 1080 with its title bar, also where the machine tests put it (y = 408 is the lowest place of a picture that must show the whole window).
- **One color is one concept.** A gauge never takes a color whose concept it is not.
- **The draw table.** The window draws with the records that exist: rectangles, the grid of points, paths and texts. It needs no new kind.

## The sample graphs

A sample is one read of the system report and of each process report (`docs/glossary/network.md`, "Sample"). The monitor takes one sample each 500 ms (`INTERVAL`) and draws one frame after each sample. A sample history keeps one value of each of the last 120 samples: the last minute.

| Graph | Value of one sample | Color of the curve | Vertical scale |
|---|---|---|---|
| Memory in use | The pages in use: all the pages less the free pages | `memory` | Fixed: from 0 to all the pages of the machine, written in MiB |
| Processor time | The processor time of all the processes since the sample before, over that time on every processor, in percent | `process` | Fixed: from 0 to 100 % |
| Kernel entries | The kernel entries since the sample before, for one second | `kernel` | Rounded up: from 0 to the largest value of the sample history, rounded up to 1, 2 or 5 times a power of ten |

- **The horizontal axis is the place of the sample, not the clock.** The newest sample is at the right edge; each older sample is one step to the left; the oldest of a full sample history is at the left edge. A step is 1/119 of the width. A sample history that is not full yet starts in the middle of the graph. The period is the aim of the loop: a call that the monitor runs between two samples can make one step longer, and the graph does not show it. The guide states the period as the step.
- **The first sample** has no sample before. Its processor time and its rate of kernel entries are the means since the start of the machine: true values, not zeros.
- **The scale of a rate is the largest value of the minute, rounded up**, so the curve fills the graph, and the top of the scale is a number that a reader reads at once (2000, not 1873). The rounded tops end at 10^19, the largest such number in 64 bits: a larger value draws on the top edge. A fixed scale also draws a value past its top on the top edge: the sample keeps its place in time, and the scale says what the top means.
- **The header of a graph card** holds, on one line: its title in its color, the text of its scale "0 to <top> <unit>" in the dim color, and at the right its value now in its color with its peak of the minute, "peak <value>", in the dim color. A rate of 10 000 or more is written with the suffixes k, M, G, T, P and E, so that a number has at most four digits and one letter. The peak is found at each push, in the same pass over the samples as the rounded top: a frame reads it. A text at the right is drawn only when it stays clear of the texts at the left: no text is cut and none lies over another.
- **The plot.** Each graph is a recess in its card (`recess`), with a line of 1 pixel at each quarter of its height in `point` at alpha 150, inside an outline of 1 pixel in `track`. The lines give a reader the half and the quarters of the scale.
- **The curve** is one path of the samples, stroked 2 pixels wide in the color of its concept, over a second path that closes the area under it, filled with the same color at alpha 64. The places are 1 pixel inside the box, so the stroke stays inside it.

### The sample history

`internal:monitor/sample_history` holds it, with host tests:

- **A fixed array of 120 values in the process**, with the place of the oldest and the count. The newest value replaces the oldest one: no allocation, no copy of the array.
- **The points of the curve are computed at each push and kept** in the record: the stroke (120 points at most) and the area (123 points). A push is one pass over at most 120 values: the largest value for a rounded scale, then the places. A frame gives the two arrays to `draw_path`: no computation over the samples.
- **Fewer than two samples draw no curve**: a path needs a segment. The grid and the scale are drawn.
- **A push refuses** a fixed top of 0 and a sample history whose box was not set by `sample_history_start`; nothing changes. `sample_history_start` refuses a box with a negative edge, a side under 3 pixels, or an edge past `COORDINATE_LIMIT`.
- **The arithmetic does not wrap.** A place is the value times the height over the top; when that product passes 64 bits, the value is divided by the top over the height. A rate is the count times 1000 over the milliseconds, or the count over the milliseconds times 1000 when the product passes; the result saturates at the largest value. The share of the processors saturates at 100 %, because the run times and the time of the report are read at two moments.

The text table of the window grows from 8 KiB to 16 KiB: the three graphs put 2 916 bytes of points each in it, 8 748 for the three.

## The intensity steps

A gauge is a bar on the track whose length is a share: the gauge of each metric card, and the bar of the processor share of each process. A gauge takes the color of its intensity step, in `graphics` (`intensity.odin`), so that another window can use it:

| Step | From | Color | Why |
|---|---|---|---|
| Normal | 0 % | The concept of the measure: `memory` or `process` | The bar says what it measures, as before |
| High | `INTENSITY_HIGH_PERCENT`, 60 % | `warning` | A state that asks for attention and is not a failure: the meaning of the token |
| Very high | `INTENSITY_VERY_HIGH_PERCENT`, 85 % | `near_limit` | A measure near its limit. A new token: no token had this meaning |

- **A value at a threshold is in the higher step**: 60 % is high, 85 % is very high. A value past 100 % is very high: the processor share of a process with several threads can pass 100 % before the window cuts it, and it is a measure, not a wrong input.
- **The color is never the only sign.** The share is written at the right of each bar, and the number of each metric card above its gauge.
- **The new token `near_limit`.** Dark `0xF2843C`, an orange between the yellow of `warning` and the coral of `failed`. Light `0xA85C29`, `shade(DARK_NEAR_LIMIT, 70)`: the shade that keeps 4.5 to 1 on the light surfaces, by the rule of every concept.

The contrast of each color of a gauge, which the host tests compute (`src/library/modus/graphics/intensity_test.odin`, `appearance_test.odin`):

| Color | Dark: on the track `0x1C2633` | Dark: on the background | Light: on the track `0xD6DBE0` | Light: on the background |
|---|---|---|---|---|
| `process` | 8.37 | 10.45 | 3.67 | 4.72 |
| `memory` | 6.79 | 8.47 | 3.59 | 4.62 |
| `warning` | 8.99 | 11.22 | 3.53 | 4.54 |
| `near_limit` | 5.92 | 7.39 | 3.56 | 4.58 |

A bar is a graphic on the track: 3 to 1. As each concept, `near_limit` is a text on the background and on both colors of a card at 4.5 to 1 (4.58, 4.97 and 4.75 in the light appearance).

## The layout

The window is 520 × 640 at its start. From the top: a row of three metric cards, three graph cards, then the card of the table of the processes. 640 keeps the window and its title bar of 24 pixels inside the screen at y = 408.

Each place comes from a layout tree of `modus:layout` ([box_layout.md](box_layout.md)), solved at each frame at the size that the window has then (`monitor_layout`): no place is a constant of the window. A host test checks the places at the size of the start (`src/modules/system/monitor/monitor_test.odin`).

- **The cards.** Each part is a card (`docs/DESIGN.md`, "3. Surfaces"): the gradient of a card, its border of 1 pixel in its accent, a light line on its top edge, and an accent rail of 3 pixels along its left edge, in the color of its concept: `memory`, `process` or `kernel`; the table is `process`. The cards are 8 pixels (the gap token) from the edges of the window and from each other. The content of a card starts 13 pixels inside it: the rail and 10 pixels.
- **A metric card** has five lines: its title in capitals in its color, its one number at the large size (32) in `text_strong`, a detail and a second detail at the caption size, and a gauge of 6 pixels, cut in tenths by lines of the card. A memory card: the share in use, "<used> / <all> MiB", "<reserved> MiB reserved", the gauge of the pages in use. A processor card: the processor time of the last sample, the processes, the processors, the gauge of the processor time. A kernel card: the kernel entries since the start as a compact number, the interrupts, the waits of the locks of the kernel of all their takes with the kind that waited most, and a gauge of the share of the takes that waited. The second detail has three forms, from the longest; the card draws the first that fits its width.
- **A graph card** is a header of 20 pixels and the plot, 40 pixels high, at the width of the card less its insets. A wider window gives a wider graph: the sample history places its curve again in the new box, once for the change (`sample_history_box_set`), never at a frame with the same box.
- **The table card** takes the height left: its title, the band of the column titles in `recess`, then the rows, every second one on a band of `recess` at alpha 150. `table_columns` gives its columns: the name (184 pixels and a gap), the pages (68, the number at the right), the bar of the processor share, which takes the width left, never under 100 pixels, and the share (`100%`, 32 pixels, at the right) at the edge of the content. At the start size the table holds ten rows of one line; the last line counts the rows that do not fit, as before.

## The refused forms

- **A continuous gradient of hue for a gauge.** Each value would have its own color, and no color would have a meaning: an orange at 71 % names no concept. A reader would compare hues to read a value that the number already gives. Three steps with stated thresholds give three meanings.
- **The `failed` color for the very high step.** A load near its limit is not a failure: the machine still does what it must. "One color is one concept" ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "4. Color") then forbids it, so the step has a token of its own.
- **A graph redrawn from all the samples at each frame.** The work of a frame would grow with the length of the sample history. The places are computed once, at the push.
- **A curve in the color of the step of each sample.** One path has one stroke color, so a curve of several colors is one path for each segment: 119 records. And a graph shows a sample history, a gauge the present: the curve keeps the color of its concept.
- **A scale from the largest value since the start.** One peak at the start would flatten the curve for the whole run. The scale of the last minute follows the load.
- **A scale with any top.** A top of 1873 is read slowly; 1, 2 and 5 times a power of ten are the steps of a ruler.
- **The samples placed by their time.** The monitor waits for its period, so the steps are equal but for a late call; places by time would need the times of 120 samples in the record and a scale of time in the window, for a difference that a reader does not see.
- **A sample history in a shared service.** The monitor reads the reports itself, and keeps what it shows; a second process that kept a sample history would need the grant to inspect the machine too.
- **Graphs side by side.** Three graphs in the width of 520 pixels are 160 pixels each, and "kernel entries" with its scale does not fit one line of that width. The metric cards are side by side because each holds short texts on lines of its own.
- **The grid of points in the plots.** The plots once showed the grid of points of the desktop, with their boxes on multiples of 24 pixels. A plot in a card is a recess; the quarter lines read the scale, the points did not, and the boxes no longer need the grid.
- **A text cut to fit a metric card.** A cut number or a cut unit says a wrong fact. The second detail has shorter forms instead, and a card draws the first that fits.
- **A larger window.** At 700 pixels the window passes the bottom of the screen at y = 408, where a machine test puts it.

## State

Built: the cards, the three metric cards and their gauges, the three sample graphs with their value now and their peak, the sample history with its host tests, the intensity steps in `graphics` with the token `near_limit` and their host tests, the gauges and the processor bars in the color of their step, and the host test of the layout.

Left: none of this design.