// A system tool: the log of the machine, as records.
//
// Each record has a time, a program, a thread, a level, a channel and a
// text. The kernel writes the records in one memory object; this program
// maps it with the right Read, and waits on its counter. The top part
// counts the records of each channel. The bottom part shows the last
// records: the color of the mark is the level, and the color of the name
// is the program. Each value of a text is in the color of its value kind,
// as the record keeps it (modus:contract/value_kinds); the head of the column of
// the text is the legend of the kinds. A text that starts with its program,
// or its channel, and ": " shows without that start: the columns at its
// left already say it. The record keeps its text whole.
//
// The program needs the grant to read the records of the log. It is also a
// service: records() and value_runs() give the records and their value runs
// as tables (exports.odin).
//
// **What it is for.** The log is the one record of what the machine did:
// the kernel and every program write to it, and the serial port prints the
// same texts. This program shows the log as [log records](term:log-record)
// with typed fields, not as lines of text: a reader sees at once which
// program wrote a record, at which [level](term:level), on which
// [channel](term:channel), and which parts of the text are values (a
// number, a size, a time, a module, a version, a status: the
// [value runs](term:value-run)). It shows that a log is data, not text to
// parse again.
//
// **What a reader sees.** Start it from the menu of the programs, or with
// `start("log")` in the console. The window has:
//
// - a top line: the count of records read, the count gone before its
//   start, the count lost since, and the count of each level;
// - the channels, each with its count of records (at most 12; the others
//   count together);
// - the newest records, in 30 lines: the time in seconds, the program, the
//   channel and the text, with the legend of the value kinds over the
//   column of the text. A text is whole, on the lines that it needs.
//
// At its start it writes two records: `log: the memory of the log: <count>
// records in <size>` and `log: ok, <count> records, <count> gone before its
// start, <count> lost since, <count> channels`.
//
// **Lost records.** The kernel keeps the last 2047 records in a ring of
// memory, and writes over the oldest one when the ring is full. The records
// that the kernel wrote over before this program kept its first record are
// gone before its start: their count says how long the machine ran before
// it. A reader that is slower than the writers loses records after that:
// this program counts them as lost since, in red when the count is not 0.
//
// **Its grants**: **Log_Records**, the memory of the log records with the
// right Read, and **Serve**, its exports. The program writes no record in
// the name of another program: the kernel sets the program, the thread and
// the time of each record.
//
// **Its exports** (`exports.odin`): `records` and `value_runs`: the whole
// log to a caller that [acts for the principal](term:acts-for-the-principal),
// and its [own records](term:own-records) to each other caller.
// `program_records` and `program_value_runs`: the records of one program
// whose program handle the caller lends, such as a child of the caller.
//
// ```
// connect("log")
// log.records(0)
// where(log.records(0), "level", "error")
// ```
package log

import "modus:contract/value_kinds"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/system"

ROWS :: 30
CHANNELS :: 12
MARGIN :: 12
LINE :: 16
COLUMN_PROGRAM :: 11 * 8 // After "00000.000" and two spaces.
COLUMN_CHANNEL :: COLUMN_PROGRAM + 13 * 8
COLUMN_TEXT :: COLUMN_CHANNEL + 11 * 8
TEXT_CHARACTERS :: 80
WIDTH :: 2 * MARGIN + COLUMN_TEXT + TEXT_CHARACTERS * 8
TOP_LINES :: 4
HEIGHT :: 2 * MARGIN + (TOP_LINES + ROWS) * LINE

// level_color gives the color of a level in the appearance in force: a
// record of a program that runs as it must, in the color of a program; a
// debug record of less weight; a warning; a failure.
level_color :: proc "contextless" (level: system.Log_Level) -> graphics.Color {
	switch level {
	case .Info:
		return graphics.colors.program
	case .Debug:
		return graphics.colors.dim
	case .Warning:
		return graphics.colors.warning
	case .Error:
		return graphics.colors.failed
	}
	return graphics.colors.text
}

Channel :: struct {
	name:  [16]u8,
	count: u64,
}

rows: [ROWS]system.Log_Record // The last records: rows[n % ROWS] is record n of this reader.
row_count: u64
gone_before_start: u64 // The records that the kernel wrote over before this reader kept its first record.
lost: u64 // The records after the first kept record that this reader did not read.
channels: [CHANNELS]Channel
channel_count: int
other_channels: u64 // Records of the channels that have no place in `channels`.
level_counts: [system.Log_Level]u64

// The kinds that the legend shows: the kinds that the logs of the system
// write.
@(rodata)
legend_kinds := [?]value_kinds.Value_Kind{.Number, .Size, .Time, .Module, .Version, .Status}

@(rodata)
legend_names := [?]string{"number", "size", "time", "module", "version", "status"}

// repeated_start gives the count of bytes at the start of a text that say
// its program, then its channel, each followed by ": ": "kernel: boot: " in
// a record of the kernel in the channel boot.
repeated_start :: proc "contextless" (record: ^system.Log_Record, text: string) -> int {
	skip := 0
	fields := [2]string{system.name_of(record.name[:]), system.name_of(record.channel[:])}
	for field in fields {
		rest := text[skip:]
		if field != "" && len(rest) >= len(field) + 2 && rest[:len(field)] == field && rest[len(field):][:2] == ": " {
			skip += len(field) + 2
		}
	}
	return skip
}

// One text of the log, as the window shows it. The kernel keeps a text
// longer than one record in several records, cut at a count of bytes
// (Log_Record.more): the window joins them again, so that the text is whole
// and its lines end at a space (docs/INTERFACE.md, "The text in a box"),
// never inside a word where a record ended.
JOIN_PARTS :: 4 // The records of one text that the window joins: a text of system.log has at most 512 bytes. More records start a second text.
RECORD_TEXT_SIZE :: size_of(system.Log_Record) - offset_of(system.Log_Record, text)
JOIN_CAPACITY :: JOIN_PARTS * RECORD_TEXT_SIZE
JOIN_RUN_CAPACITY :: 64 // The value runs of one joined text that keep their color; a run past them is plain.
NAME_ROOM :: COLUMN_CHANNEL - COLUMN_PROGRAM - 8 // The box of the name of the program.
CHANNEL_ROOM :: COLUMN_TEXT - COLUMN_CHANNEL - 8 // The box of the channel.
TEXT_ROOM :: TEXT_CHARACTERS * 8 // The box of the text.

// A value run of a joined text: its bytes in the joined text.
Joined_Run :: struct {
	start, end: int,
	kind:       value_kinds.Value_Kind,
}

Joined :: struct {
	bytes:     [JOIN_CAPACITY]u8,
	count:     int,
	runs:      [JOIN_RUN_CAPACITY]Joined_Run,
	run_count: int,
	from:      int, // The bytes at the start that repeat the program and the channel: not shown.
}

joined_text: Joined // The text that the window measures or draws now: not on the stack, it has 2 KiB.

// A text of the window: `count` records from the place `first` of the
// records that the window holds, and the lines that it takes.
Group :: struct {
	first, count, lines: int,
}

// record_shown gives the record at a place of the records that the window
// holds, the oldest at 0.
record_shown :: proc "contextless" (place: int) -> ^system.Log_Record {
	held := min(row_count, ROWS)
	return &rows[(row_count - held + u64(place)) % ROWS]
}

// join makes the text of a group: the texts of its records, one after the
// other, and their value runs at their places in the joined text.
join :: proc "contextless" (joined: ^Joined, group: Group) {
	joined.count, joined.run_count = 0, 0
	for part in 0 ..< group.count {
		record := record_shown(group.first + part)
		text_count := min(int(record.text_count), len(record.text))
		base := joined.count
		for index in 0 ..< min(int(record.run_count), len(record.runs)) {
			start, end, ok := value_kinds.value_run_in_text(record.runs[index], text_count)
			if ok && joined.run_count < JOIN_RUN_CAPACITY {
				joined.runs[joined.run_count] = {base + start, base + end, record.runs[index].kind}
				joined.run_count += 1
			}
		}
		joined.count += copy(joined.bytes[joined.count:], record.text[:text_count])
	}
	joined.from = repeated_start(record_shown(group.first), string(joined.bytes[:joined.count]))
}

// group_lines gives the lines of a group: the most of the lines of its
// text, of the name of its program and of its channel, each in its box.
group_lines :: proc "contextless" (joined: ^Joined, group: Group) -> int {
	record := record_shown(group.first)
	text_lines := interface.text_wrapped_line_count(nil, {}, string(joined.bytes[joined.from:joined.count]), TEXT_ROOM)
	name_lines := interface.text_wrapped_line_count(nil, {}, system.name_of(record.name[:]), NAME_ROOM)
	channel_lines := interface.text_wrapped_line_count(nil, {}, system.name_of(record.channel[:]), CHANNEL_ROOM)
	return max(text_lines, name_lines, channel_lines, 1)
}

// lines_draw draws a text in a box, on the lines that it needs.
lines_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, room: int, text: string, color: graphics.Color) {
	rest := text
	for line_y := y; len(rest) > 0; line_y += LINE {
		line: string
		line, rest = interface.text_wrap_line(nil, {}, rest, room)
		graphics.text(canvas, x, line_y, line, color)
	}
}

// joined_text_draw draws the text of a group in its box: each line of the
// text, each value run in the color of its kind and the rest in plain. A
// run that a break of a line cuts has its color on both lines.
joined_text_draw :: proc "contextless" (canvas: graphics.Canvas, x, y: int, joined: ^Joined, plain: graphics.Color) {
	text := string(joined.bytes[:joined.count])
	rest := text[joined.from:]
	for line_y := y; len(rest) > 0; line_y += LINE {
		line_start := len(text) - len(rest)
		line: string
		line, rest = interface.text_wrap_line(nil, {}, rest, TEXT_ROOM)
		line_end := line_start + len(line)
		at := line_start
		left := x
		for run in joined.runs[:joined.run_count] {
			start, end := max(run.start, at), min(run.end, line_end)
			if start >= end {
				continue
			}
			left = graphics.text(canvas, left, line_y, text[at:start], plain)
			left = graphics.text(canvas, left, line_y, text[start:end], graphics.value_kind_color(run.kind, graphics.appearance, plain))
			at = end
		}
		graphics.text(canvas, left, line_y, text[at:line_end], plain)
	}
}

// take keeps one new record: it is the newest of the last 30 rows, and it
// counts for its level and for its channel. A channel that finds no free
// place of the 12 counts in `other_channels`.
take :: proc "contextless" (record: ^system.Log_Record) {
	rows[row_count % ROWS] = record^
	row_count += 1
	level_counts[record.level] += 1
	for &channel in channels[:channel_count] {
		if channel.name == record.channel {
			channel.count += 1
			return
		}
	}
	if channel_count == CHANNELS {
		other_channels += 1
		return
	}
	channels[channel_count] = {name = record.channel, count = 1}
	channel_count += 1
}

// draw draws the whole window: the counts, the channels, the legend of the
// value kinds, and the last records. A text drops the start that repeats
// its program and its channel (`repeated_start`).
draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, graphics.colors.background)
	// The log is a ring of the kernel: its title in the color of the kernel.
	graphics.fill(canvas, MARGIN, MARGIN - 4, WIDTH - 2 * MARGIN, 2, graphics.colors.kernel)
	x := graphics.text(canvas, MARGIN, MARGIN, "the log  ", graphics.colors.kernel)
	x = graphics.unsigned(canvas, x, MARGIN, row_count, graphics.colors.text)
	x = graphics.text(canvas, x, MARGIN, " read, ", graphics.colors.dim)
	// Records gone before the start are a fact of the boot, not a fault
	// of this reader: only the count lost since is in the color of a
	// failure (src/md/features/log_window_losses.md).
	x = graphics.unsigned(canvas, x, MARGIN, gone_before_start, graphics.colors.text)
	x = graphics.text(canvas, x, MARGIN, " gone before its start, ", graphics.colors.dim)
	x = graphics.unsigned(canvas, x, MARGIN, lost, lost == 0 ? graphics.colors.text : graphics.colors.failed)
	x = graphics.text(canvas, x, MARGIN, " lost since    ", graphics.colors.dim)
	for count, level in level_counts {
		names := [system.Log_Level]string {
			.Info    = "info ",
			.Debug   = "debug ",
			.Warning = "warning ",
			.Error   = "error ",
		}
		graphics.fill(canvas, x, MARGIN + 4, 8, 8, level_color(level))
		x = graphics.text(canvas, x + 12, MARGIN, names[level], graphics.colors.dim)
		x = graphics.unsigned(canvas, x, MARGIN, count, graphics.colors.text) + 16
	}

	// The channels, with the count of records of each one.
	x = graphics.text(canvas, MARGIN, MARGIN + LINE, "channels ", graphics.colors.dim)
	y := MARGIN + LINE
	for &channel in channels[:channel_count] {
		name := system.name_of(channel.name[:])
		if name == "" {
			name = "(none)"
		}
		width := (len(name) + 1) * 8 + graphics.text_width("00000") + 12
		if x + width > WIDTH - MARGIN {
			x = MARGIN + 9 * 8
			y += LINE
		}
		graphics.fill(canvas, x - 4, y, width - 8, LINE, graphics.colors.card_top)
		after := graphics.text(canvas, x, y, name, graphics.colors.text)
		graphics.unsigned(canvas, after + 8, y, channel.count, graphics.colors.text)
		x += width
	}

	top := MARGIN + TOP_LINES * LINE
	graphics.text(canvas, MARGIN, top - LINE, "time (s)", graphics.colors.dim)
	graphics.text(canvas, MARGIN + COLUMN_PROGRAM, top - LINE, "program", graphics.colors.dim)
	graphics.text(canvas, MARGIN + COLUMN_CHANNEL, top - LINE, "channel", graphics.colors.dim)
	x = graphics.text(canvas, MARGIN + COLUMN_TEXT, top - LINE, "text   ", graphics.colors.dim)
	for kind, index in legend_kinds {
		x = graphics.text(canvas, x, top - LINE, legend_names[index], graphics.value_kind_color(kind, graphics.appearance)) + 16
	}
	// The texts of the records that the window holds: a record whose text
	// continues is one text with the records after it.
	held := int(min(row_count, ROWS))
	joined := &joined_text
	groups: [ROWS]Group
	group_count := 0
	for place := 0; place < held; {
		group := Group{first = place, count = 1}
		for group.count < JOIN_PARTS && place + group.count < held && record_shown(place + group.count - 1).more != 0 {
			group.count += 1
		}
		join(joined, group)
		group.lines = group_lines(joined, group)
		groups[group_count] = group
		group_count += 1
		place += group.count
	}
	// The window has ROWS lines: it shows the newest texts that fit whole.
	// The older ones are in the log, as each record that left the window.
	first_group, used := group_count, 0
	for first_group > 0 && used + groups[first_group - 1].lines <= ROWS {
		first_group -= 1
		used += groups[first_group].lines
	}
	y = top
	for group, index in groups[first_group:group_count] {
		record := record_shown(group.first)
		height := group.lines * LINE
		// Every second row on a band of the top of a card, as a table of
		// the rules (docs/DESIGN.md, "10. Elements").
		if index % 2 == 1 {
			graphics.fill(canvas, MARGIN - 4, y, WIDTH - 2 * MARGIN + 8, height, graphics.colors.card_top)
		}
		graphics.fill(canvas, MARGIN - 4, y, 3, height, level_color(record.level))
		milliseconds := record.time / 1000
		x = graphics.unsigned(canvas, MARGIN + 4, y, milliseconds / 1000, graphics.colors.dim, 4)
		x = graphics.text(canvas, x, y, ".", graphics.colors.dim)
		graphics.unsigned(canvas, x, y, milliseconds % 1000, graphics.colors.dim, 3)
		lines_draw(canvas, MARGIN + COLUMN_PROGRAM, y, NAME_ROOM, system.name_of(record.name[:]), record.program == 0 ? graphics.colors.text : graphics.colors.series[record.program % graphics.SERIES_COLOR_COUNT])
		lines_draw(canvas, MARGIN + COLUMN_CHANNEL, y, CHANNEL_ROOM, system.name_of(record.channel[:]), graphics.colors.dim)
		join(joined, group)
		joined_text_draw(canvas, MARGIN + COLUMN_TEXT, y, joined, record.level == .Error ? graphics.colors.failed : graphics.colors.text)
		y += height
	}
}

// entry opens the window of the log and runs its loop: it shows each new
// log record until the program is stopped.
//
// **What it sets up**: a window, the reader of the log records (the memory
// of the records that the grant **Log_Records** gives, mapped read-only),
// and the service ring of its exports, which read the same memory.
//
// **The loop.** One wait covers the window, the counter of the log and the
// service ring. After each wake it takes every new record (`take`): the
// counts of each level and of each channel, and the last 30 records. It
// adds the records that the kernel wrote over before the read to the count
// gone before its start while it kept no record, and to the count lost
// since after that. It draws the window again only when a record came. At
// the first turn it writes two records of its own on the channel `log`: the
// records that the ring keeps and the size of the memory of the log, then
// `log: ok, <count> records, <count> gone before its start, <count> lost
// since, <count> channels`. Then it runs the calls of its exports.
//
// **The stop**: with no window, it stops with the code 1. With no grant of
// the log records, it writes `log: cannot read the records of the log:
// status <status>` at the level error, and stops with the code 1. Else it
// never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "log")
	if !ok {
		system.stop(1)
	}
	reader, status := system.log_open(ctx.handles[system.GRANT_LOG_RECORDS])
	if status != .Ok {
		system.log_in("log", .Error, "log: cannot read the records of the log: status ", u64(status))
		system.stop(1)
	}
	// The service reads the same memory object: exports.odin. Its handle
	// also reads the own log ring of a caller (Log_Read).
	reader_head, reader_records = reader.head, reader.records
	log_memory = ctx.handles[system.GRANT_LOG_RECORDS]
	service, _ = system.service_open(ctx)
	logged := false
	picture_owed := true // The window does not show each record that was taken.
	for {
		for {
			record, late, has := system.log_next(&reader)
			// Before the first kept record, a gap only says how long the
			// machine ran before this program; after it, a gap is a
			// record that this reader was too slow to read.
			if row_count == 0 {
				gone_before_start += late
			} else {
				lost += late
			}
			if !has {
				break
			}
			take(&record)
			picture_owed = true
		}
		for event in display.next_event(&window) {
			// A new appearance or a new font: each pixel of the window
			// changes, with no new record.
			if event.kind == .Settings_Changed {
				picture_owed = true
			}
		}
		// This service never waits for the compositor: while the
		// compositor did not take the last picture, the window owes its
		// picture, and the wait below ends when the compositor has read.
		// The whole canvas is drawn: it is the other picture of the
		// surface.
		if picture_owed && display.canvas_free(&window) {
			draw(window.canvas)
			display.present(&window)
			picture_owed = false
		}
		if !logged {
			logged = true
			// The memory object of the log is its head and its records,
			// each of the size of one record.
			memory_bytes := (reader.head.capacity + 1) * size_of(system.Log_Record)
			system.log_in("log", .Info, "log: the memory of the log: ", reader.head.capacity, " records in ", system.Size{memory_bytes / 1024, .Kibibytes})
			system.log_in("log", .Info, "log: ok, ", row_count, " records, ", gone_before_start, " gone before its start, ", lost, " lost since, ", u64(channel_count), " channels")
			continue
		}
		// The list comes after the reads and after the question to the
		// canvas: a record or a call that arrived since ends the wait at
		// once.
		wait: system.Wait
		display.wait_events(&wait, &window)
		system.wait_log(&wait, &reader)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
	}
}
