# The window of `monitor`

The window of `monitor` shows what the machine does now, from the reports of the kernel: the memory, the counts of the kernel, and one row for each process. This file records two parts of its look: the sample graphs, which show the last minute of three measures, and the intensity steps, which color each gauge by its value. The guide is [`docs/TOOLS.md`](../../../docs/TOOLS.md), "The window of `monitor`". The colors follow [`docs/DESIGN.md`](../../../docs/DESIGN.md), "4. Color", and [appearance.md](appearance.md).

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
- **The text of a scale** is "0 to <top> <unit>" under the name, in the dim color. A rate of 10 000 or more is written with the suffixes k, M, G, T, P and E, so that a top has at most four digits and one letter. The current value of memory is the line at the top of the window, so its graph does not repeat it.
- **The grid.** Each graph is the grid of points of the background (`interface.draw_point_grid`), the pattern that the compositor draws under the windows, inside an outline of 1 pixel in `track`. The pattern is placed on the surface, so the graphs and the desktop show one grid. The boxes start and end on multiples of `POINT_STEP` (24 pixels), so the points of a graph are 12 pixels inside each edge.
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

A gauge is a bar on the track whose length is a share: the memory bar under the line of the memory, and the bar of the processor share of each process. A gauge takes the color of its intensity step, in `graphics` (`intensity.odin`), so that another window can use it:

| Step | From | Color | Why |
|---|---|---|---|
| Normal | 0 % | The concept of the measure: `memory` or `process` | The bar says what it measures, as before |
| High | `INTENSITY_HIGH_PERCENT`, 60 % | `warning` | A state that asks for attention and is not a failure: the meaning of the token |
| Very high | `INTENSITY_VERY_HIGH_PERCENT`, 85 % | `near_limit` | A measure near its limit. A new token: no token had this meaning |

- **A value at a threshold is in the higher step**: 60 % is high, 85 % is very high. A value past 100 % is very high: the processor share of a process with several threads can pass 100 % before the window cuts it, and it is a measure, not a wrong input.
- **The color is never the only sign.** The share is written at the right of each bar, and the memory in MiB above its bar.
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

The window is 520 × 640 (it was 520 × 560). From the top: the line of the memory and its bar, the kernel entries, the interrupts, the locks of the kernel, the three graphs, then the rows of the processes. A graph is 288 × 40 pixels from x = 216: its name and its scale are two lines of 20 pixels in the column of the names (184 pixels, the column of a nickname), at its left. The graphs take 148 pixels; the window grew 80 pixels, so the list of the processes has 68 pixels less, and the last line counts the rows that do not fit, as before. 640 keeps the window and its title bar of 24 pixels inside the screen at y = 408.

## The refused forms

- **A continuous gradient of hue for a gauge.** Each value would have its own color, and no color would have a meaning: an orange at 71 % names no concept. A reader would compare hues to read a value that the number already gives. Three steps with stated thresholds give three meanings.
- **The `failed` color for the very high step.** A load near its limit is not a failure: the machine still does what it must. "One color is one concept" ([`docs/DESIGN.md`](../../../docs/DESIGN.md), "4. Color") then forbids it, so the step has a token of its own.
- **A graph redrawn from all the samples at each frame.** The work of a frame would grow with the length of the sample history. The places are computed once, at the push.
- **A curve in the color of the step of each sample.** One path has one stroke color, so a curve of several colors is one path for each segment: 119 records. And a graph shows a sample history, a gauge the present: the curve keeps the color of its concept.
- **A scale from the largest value since the start.** One peak at the start would flatten the curve for the whole run. The scale of the last minute follows the load.
- **A scale with any top.** A top of 1873 is read slowly; 1, 2 and 5 times a power of ten are the steps of a ruler.
- **The samples placed by their time.** The monitor waits for its period, so the steps are equal but for a late call; places by time would need the times of 120 samples in the record and a scale of time in the window, for a difference that a reader does not see.
- **A sample history in a shared service.** The monitor reads the reports itself, and keeps what it shows; a second process that kept a sample history would need the grant to inspect the machine too.
- **Graphs side by side.** Three graphs in the width of 520 pixels are 160 pixels each, and "kernel entries" with its scale does not fit one line of that width.
- **A larger window.** At 700 pixels the window passes the bottom of the screen at y = 408, where a machine test puts it.

## State

Built: the three sample graphs, the sample history with its host tests, the intensity steps in `graphics` with the token `near_limit` and their host tests, the memory bar and the processor bars in the color of their step.

Left: none of this design.
