// A system tool: the log of the machine, as records.
//
// Each record has a time, a process, a thread, a level and a text. The
// kernel writes the records in one memory object; this process maps it with
// the right Read, and waits on its counter. The top part counts the records
// of each process. The bottom part shows the last records: the color of the
// mark is the level, and the color of the name is the process. Each value
// of a text is in the color of its value kind, as the record keeps it
// (modus:contract/value_kinds); the head of the column of the text is the
// legend of the kinds. A text that starts with its process and ": " shows
// without that start: the column at its left already says it. The record
// keeps its text whole.
//
// The process needs the grant to read the records of the log. It is also a
// service: records() and value_runs() give the records and their value runs
// as tables (exports.odin).
//
// **What it is for.** The log is the one record of what the machine did:
// the kernel and every process write to it, and the serial port prints the
// same texts. This process shows the log as [log records](term:log-record)
// with typed fields, not as lines of text: a reader sees at once which
// process wrote a record, at which [level](term:level), and which parts of
// the text are values (a number, a size, a time, a module, a version, a
// status: the [value runs](term:value-run)). It shows that a log is data,
// not text to parse again.
//
// **What a reader sees.** Start it from the start menu, or with
// `start("log")` in the console. The window has:
//
// - a top line: the count of records read, the count gone before its
//   start, the count lost since, and the count of each level;
// - the processes, each with its count of records, as many as two lines
//   hold; the others count together in the last card;
// - the newest records, in 30 lines: the time in seconds, the process and
//   the text, with the legend of the value kinds over the column of the
//   text. A text is whole, on the lines that it needs. A
//   [log fact](term:log-fact) is the sentence of its fact template with
//   its values, which the window writes from the module file of the boot
//   image that the fact names; a fact whose module the image does not hold
//   is its raw form, the line of the serial port: `#`, the module tag,
//   `:`, the key tag and the value bytes in hexadecimal, with each run of
//   zero bytes as a letter.
//
// At its start it writes two records: `log: the memory of the log: <count>
// records in <size>` and `log: ok, <count> records, <count> gone before its
// start, <count> lost since, <count> processes`.
//
// **Lost records.** The kernel keeps the last 2047 records in a ring of
// memory, and writes over the oldest one when the ring is full. The records
// that the kernel wrote over before this process kept its first record are
// gone before its start: their count says how long the machine ran before
// it. A reader that is slower than the writers loses records after that:
// this process counts them as lost since, in red when the count is not 0.
//
// **Its grants**: **Log_Records**, the memory of the log records with the
// right Read; **Serve**, its exports; **Image**, the boot image read-only,
// in which it finds the module file of a fact. The process writes no
// record in the name of another process: the kernel sets the process, the
// thread and the time of each record.
//
// **Its exports** (`exports.odin`): `records`, `value_runs` and
// `fact_records`: the records of its principal to a caller that
// [acts for the principal](term:acts-for-the-principal), and its
// [own records](term:own-records) to each other caller.
// `process_records` and `process_value_runs`: the records of one process
// whose process handle the caller lends, such as a child of the caller.
//
// ```
// connect("log")
// log.records(0)
// log.records(0) |> where(level = Error)
// ```
package log

import "modus:contract/call_outcome"
import "base:intrinsics"
import "modus:contract/enum_word"
import module "modus:contract/module"
import "modus:contract/isolated"
import "modus:contract/log_scope"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:system"

ROWS :: 30
// The processes that the window counts one by one: two for each process
// slot, so the processes that stopped count beside the ones that run. The
// records of a process past them count with the others.
COUNTED_PROCESSES :: 2 * op.PROCESS_SLOTS_MOST
MARGIN :: 12
LINE :: 16
COLUMN_PROCESS :: 11 * 8 // After "00000.000" and two spaces.
COLUMN_TEXT :: COLUMN_PROCESS + 13 * 8
// The top line of the counts sets the width of the window; the text takes
// the rest of it.
TEXT_CHARACTERS :: 91
// Literals, so the tool reads the window of the budget; the assertions
// keep them the sizes of the layout at the start. Each place in the window
// comes from its layout tree (log_layout), from the size of its picture.
WIDTH :: 944
#assert(WIDTH == 2 * MARGIN + COLUMN_TEXT + TEXT_CHARACTERS * 8)
TOP_LINES :: 4
HEIGHT :: 568
#assert(HEIGHT == 2 * MARGIN + (TOP_LINES + ROWS) * LINE)
// The tool counts the module, its stack and the window at the largest scale
// (measured peak at ready 2863 pages for a floor of 4651 pages); the hand
// picture (524 pages), tables and glyph memory fit inside the floor.
MODULE_BUDGET :: system.Stated_Budget{window_width = WIDTH, window_height = HEIGHT}

// The picture of the window, in its logical pixels: the window draws its
// rows by hand, and the drawing module puts the picture on the screen at
// the scale (interface.Hand_Picture).
hand_picture: interface.Hand_Picture

// level_color gives the color of a level in the appearance in force: a
// record of a process that runs as it must, in the color of a process; a
// debug record of less weight; a warning; a failure.
level_color :: proc "contextless" (level: system.Log_Level) -> graphics.Color {
	switch level {
	case .Info:
		return element_tokens.expected
	case .Debug:
		return element_tokens.text_dim
	case .Warning:
		return element_tokens.warning
	case .Error:
		return element_tokens.failed
	}
	return element_tokens.text
}

// The count of the records of one process. The process slot and the process
// serial name the process, as the log scope names it: two processes with
// one name are two counts.
Process_Count :: struct {
	slot:   u16,
	serial: u32,
	name:   [32]u8,
	count:  u64,
}

rows: [ROWS]system.Log_Record // The last records: rows[n % ROWS] is record n of this reader.
row_count: u64
gone_before_start: u64 // The records that the kernel wrote over before this reader kept its first record.
lost: u64 // The records after the first kept record that this reader did not read.
process_counts: [COUNTED_PROCESSES]Process_Count
process_count: int // The places of `process_counts` in use.
other_processes: u64 // Records of the processes that have no place in `process_counts`.
level_counts: [system.Log_Level]u64

// The kinds that the legend shows: the kinds that the logs of the system
// write.
@(rodata)
legend_kinds := [?]value_kinds.Value_Kind{.Number, .Size, .Time, .Module, .Version, .Status}

@(rodata)
legend_names := [?]string{"number", "size", "time", "module", "version", "status"}

// repeated_start gives the count of bytes at the start of a text that say
// its process, followed by ": ": "kernel: " in a record of the kernel.
repeated_start :: proc "contextless" (record: ^system.Log_Record, text: string) -> int {
	name := system.name_of(record.name[:])
	if name != "" && len(text) >= len(name) + 2 && text[:len(name)] == name && text[len(name):][:2] == ": " {
		return len(name) + 2
	}
	return 0
}

// One text of the log, as the window shows it. The kernel keeps a text
// longer than one record in several records, cut at a count of bytes
// (Log_Record.more): the window joins them again, so that the text is whole
// and its lines end at a space (docs/INTERFACE.md, "The text in a box"),
// never inside a word where a record ended.
// The records of one text that the window joins: a text of system.log has
// at most 512 bytes, and a fact has at most op.LOG_FACT_RECORDS_MOST
// records. More records start a second text.
JOIN_PARTS :: max(4, op.LOG_FACT_RECORDS_MOST)
RECORD_TEXT_SIZE :: size_of(system.Log_Record) - offset_of(system.Log_Record, text)
JOIN_CAPACITY :: JOIN_PARTS * RECORD_TEXT_SIZE
JOIN_RUN_CAPACITY :: 64 // The value runs of one joined text that keep their color; a run past them is plain.
NAME_GAP :: 8 // The room between the name of the process and the text.
CARD_LINES :: TOP_LINES - 2 // The lines of the cards of the processes, between the top line and the heads of the columns.

// The columns of the table of the records.
Record_Column :: enum u8 {
	Time    = 0,
	Process = 1,
	Text    = 2,
}

// The time and the process keep their widths; the text takes the rest of
// the width of the window.
@(rodata)
record_column_widths := [Record_Column]layout.Table_Column {
	.Time    = {width = COLUMN_PROCESS},
	.Process = {width = COLUMN_TEXT - COLUMN_PROCESS},
	.Text    = {weight = 1, least = 16 * graphics.CELL_WIDTH},
}

// The places of the window that the draw reads after the solve, in the
// pixels of its picture.
Log_Places :: struct {
	counts:       interface.Area, // The top line: the counts of the records and of each level.
	processes:    interface.Area, // The cards of the processes, with their counts.
	heads:        interface.Area, // The heads of the columns and the legend of the value kinds.
	records:      interface.Area, // The newest records.
	record_lines: int, // The lines of the records, at most ROWS: the window holds ROWS records.
	columns:      [Record_Column]layout.Table_Column_Place,
	name_room:    int, // The box of the name of the process.
	text_room:    int, // The box of the text.
}

// The places of the frame that the draw builds.
places: Log_Places

// The layout tree of a frame. A global: the tree is too large for the stack.
layout_tree: layout.Box_Tree

// The colors of the frame, from the appearance in force.
element_tokens: layout.Element_Tokens

// line_box gives a box of a height across the whole width.
line_box :: proc "contextless" (height: i32) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.px(height)}}
}

// log_layout builds and solves the layout tree of the picture of the window:
// the top line of the counts, the cards of the processes, the heads of the
// columns, then the records in the height left, and the columns of the
// table of the records. ok false: the tree or the table refused, and the
// caller keeps the places before.
log_layout :: proc "contextless" (width, height: int) -> (laid_out: Log_Places, ok: bool) {
	tree := &layout_tree
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = MARGIN, .Y = MARGIN}}) != .Done {
		return {}, false
	}
	counts, counts_status := layout.box_add(tree, line_box(LINE))
	processes, processes_status := layout.box_add(tree, line_box(CARD_LINES * LINE))
	heads, heads_status := layout.box_add(tree, line_box(LINE))
	records, records_status := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, overflow = {.X = .Visible, .Y = .Clip}})
	if counts_status != .Done || processes_status != .Done || heads_status != .Done || records_status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
		rect := tree.boxes[index].rect
		return {int(rect.x), int(rect.y), int(rect.width), int(rect.height)}
	}
	laid_out = {
		counts    = area_of(tree, counts),
		processes = area_of(tree, processes),
		heads     = area_of(tree, heads),
		records   = area_of(tree, records),
	}
	laid_out.record_lines = min(laid_out.records.height / LINE, ROWS)
	widths := record_column_widths
	rect := tree.boxes[records].rect
	if layout.table_columns(([^]layout.Table_Column)(&widths)[:len(widths)], ([^]layout.Table_Column_Place)(&laid_out.columns)[:len(laid_out.columns)], rect, 0) != .Done {
		return {}, false
	}
	laid_out.name_room = max(int(laid_out.columns[.Process].width) - NAME_GAP, graphics.CELL_WIDTH)
	laid_out.text_room = int(laid_out.columns[.Text].width)
	return laid_out, true
}

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
	from:      int, // The bytes at the start that repeat the process: not shown.
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

// The boot image: the catalog in which the window finds the module file of
// a log fact. Empty with no grant: each fact then shows its raw form.
image: []u8

// The last modules that the window found by their hash, and the last
// hashes that no module of the image has: the facts of one writer cost one
// search of the image, and a fact of a disk process costs one search too.
FACT_MODULE_CACHE :: 8
Fact_Module :: struct {
	hash: [32]u8,
	file: []u8,
}
fact_modules: [FACT_MODULE_CACHE]Fact_Module
fact_module_next: int
fact_hashes_missing: [FACT_MODULE_CACHE][32]u8
fact_hash_missing_next: int

// fact_module_of_hash gives the module file of the boot image with a hash,
// checked, or nil: no module, a hash of zero, or a file that the checks of
// the module format refuse. The entry of the image states the hash, and the
// boot program hashed each file of the image against the signed system
// description before the kernel ran (src/boot/trust.odin, trust_check,
// which calls system_description.image_check: it compares the hash of the
// bytes of each module with its entry). The image is granted read-only, so
// the bytes at an entry still have its hash: the window does not hash them
// again.
fact_module_of_hash :: proc "contextless" (hash: [32]u8) -> []u8 {
	zero: [32]u8
	if hash == zero {
		return nil
	}
	for item in fact_modules {
		if item.file != nil && item.hash == hash {
			return item.file
		}
	}
	for missing in fact_hashes_missing {
		if missing == hash {
			return nil
		}
	}
	file: []u8
	if entry := system.image_entry_of(image, hash); entry != nil {
		file = image[entry.offset:][:entry.size]
		if module.validate(file) != .None {
			file = nil
		}
	}
	if file == nil {
		fact_hashes_missing[fact_hash_missing_next % FACT_MODULE_CACHE] = hash
		fact_hash_missing_next += 1
		return nil
	}
	fact_modules[fact_module_next % FACT_MODULE_CACHE] = {hash = hash, file = file}
	fact_module_next += 1
	return file
}

// The sentence of a fact, rendered once when the window takes its record:
// a frame draws it and renders nothing. The bytes are as many as a joined
// text holds, so a sentence that fits here fits in the text of its group.
FACT_RUN_CAPACITY :: 16 // The value runs of one sentence that keep their color; a run past them is plain.
Rendered_Fact :: struct {
	bytes:     [JOIN_CAPACITY]u8,
	count:     int,
	runs:      [FACT_RUN_CAPACITY]Joined_Run,
	run_count: int,
}
rendered_facts: [ROWS]Rendered_Fact // rendered_facts[n % ROWS] is the fact of record n of this reader, when it is one.

// fact_render writes the sentence of a whole fact into the place of its
// last record, each value with its value run, from the values of each of
// its records joined. false: the image has no module or no valid
// description for it, or the sentence is longer than the room of a joined
// text: the caller shows the raw form, and no text is cut.
fact_render :: proc "contextless" (rendered: ^Rendered_Fact, record: ^system.Log_Record, values: []u8) -> bool {
	rendered.count, rendered.run_count = 0, 0
	fact := op.log_record_fact(record)
	file := fact_module_of_hash(fact.module_hash)
	if file == nil {
		return false
	}
	runs: [module.FACT_SENTENCE_RUNS_MOST]value_kinds.Value_Run_In_Call
	written, run_count, refusal := module.fact_sentence_write(file, fact.key, values, rendered.bytes[:], runs[:])
	if refusal != .None {
		return false
	}
	for run in runs[:run_count] {
		kind, kind_ok := value_kinds.value_kind_of(run.kind)
		if kind_ok && kind != .None && rendered.run_count < FACT_RUN_CAPACITY {
			rendered.runs[rendered.run_count] = {int(run.start), int(run.start) + int(run.length), kind}
			rendered.run_count += 1
		}
	}
	rendered.count = written
	return true
}

// fact_raw writes the raw form of one record of a fact: its part of the
// line of the serial port. A record after the first that continues the
// raw form of the record before it writes "/" and its values, so the
// joined text of the records is the line of the fact; a record of a fact
// that the window cannot join writes the mark first, and its part alone.
fact_raw :: proc "contextless" (rendered: ^Rendered_Fact, record: ^system.Log_Record, continuation: bool, marked: bool) {
	rendered.count, rendered.run_count = 0, 0
	if marked {
		rendered.count = copy(rendered.bytes[:], op.LOG_FACT_JOIN_BROKEN_MARK)
	}
	raw: [op.LOG_FACT_LINE_BYTES_MOST]u8
	rendered.count += copy(rendered.bytes[rendered.count:], raw[:op.log_fact_line(op.log_record_fact(record), &raw, continuation)])
}

// The join of the records of a fact of several records, in the order in
// which the window takes them, and the place of the first record of the
// open fact among the records that the window took.
fact_records_join: op.Log_Fact_Join
fact_records_join_first: u64

// fact_parts_raw writes again the raw form of the records of the window
// from the place first to the place end, which the window took: the
// records of a fact that it cannot join (marked), or that it cannot render
// (a raw line). A record that the window no longer holds is not written.
fact_parts_raw :: proc "contextless" (first, end: u64, marked: bool) {
	for place in first ..< end {
		if row_count - place > ROWS {
			continue
		}
		fact_raw(&rendered_facts[place % ROWS], &rows[place % ROWS], !marked && place != first, marked)
	}
}

// fact_take takes the record of a fact into the join, and writes what the
// window shows for it: nothing for a record of a fact that waits for its
// next record, the sentence of a whole fact in the place of its last
// record, or the raw forms. A broken fact shows each of its records raw,
// after the mark.
fact_take :: proc "contextless" (record: ^system.Log_Record) {
	was_open, first := fact_records_join.open, fact_records_join_first
	whole, fault := op.log_fact_join_take(&fact_records_join, op.log_fact_part_of_record(record, record.sequence))
	if fault != .None && was_open {
		fact_parts_raw(first, row_count, true)
	}
	rendered := &rendered_facts[row_count % ROWS]
	rendered.count, rendered.run_count = 0, 0
	switch {
	case whole:
		started := fact_records_join.part_count == 1 ? row_count : fact_records_join_first
		if !fact_render(rendered, record, fact_records_join.values[:fact_records_join.value_count]) {
			fact_parts_raw(started, row_count, false)
			fact_raw(rendered, record, started != row_count, false)
		}
	case fact_records_join.open:
		// The record waits for the next records of its fact: the first
		// record keeps the place of the fact.
		if op.log_record_fact(record).part == 0 {
			fact_records_join_first = row_count
		}
	case:
		fact_raw(rendered, record, false, true)
	}
}

// fact_join adds the sentence that take() rendered for the record at a
// place of the window to a joined text: a copy, with no render.
fact_join :: proc "contextless" (joined: ^Joined, place: int) {
	held := min(row_count, ROWS)
	rendered := &rendered_facts[(row_count - held + u64(place)) % ROWS]
	base := joined.count
	written := copy(joined.bytes[base:], rendered.bytes[:rendered.count])
	for run in rendered.runs[:rendered.run_count] {
		if run.end <= written && joined.run_count < JOIN_RUN_CAPACITY {
			joined.runs[joined.run_count] = {base + run.start, base + run.end, run.kind}
			joined.run_count += 1
		}
	}
	joined.count += written
}

// join makes the text of a group: the texts of its records, one after the
// other, and their value runs at their places in the joined text. A fact
// is its sentence; a record of a form that the window does not know shows
// that, with no body.
join :: proc "contextless" (joined: ^Joined, group: Group) {
	joined.count, joined.run_count = 0, 0
	for part in 0 ..< group.count {
		record := record_shown(group.first + part)
		form, known := op.log_record_form(record)
		if !known {
			joined.count += copy(joined.bytes[joined.count:], "a record of an unknown form")
			continue
		}
		switch form {
		case .Text:
		case .Fact:
			fact_join(joined, group.first + part)
			continue
		}
		text_count := min(int(record.text_count), len(record.text))
		base := joined.count
		for index in 0 ..< min(int(record.run_count), len(record.runs)) {
			start, end, kind, ok := value_kinds.value_run_in_text(record.runs[index], text_count)
			if ok && joined.run_count < JOIN_RUN_CAPACITY {
				joined.runs[joined.run_count] = {base + start, base + end, kind}
				joined.run_count += 1
			}
		}
		joined.count += copy(joined.bytes[joined.count:], record.text[:text_count])
	}
	joined.from = repeated_start(record_shown(group.first), string(joined.bytes[:joined.count]))
}

// group_lines gives the lines of a group: the most of the lines of its
// text and of the name of its process, each in its box.
group_lines :: proc "contextless" (joined: ^Joined, group: Group) -> int {
	record := record_shown(group.first)
	text_lines := interface.text_wrapped_line_count(nil, {}, string(joined.bytes[joined.from:joined.count]), places.text_room)
	name_lines := interface.text_wrapped_line_count(nil, {}, system.name_of(record.name[:]), places.name_room)
	return max(text_lines, name_lines, 1)
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
		line, rest = interface.text_wrap_line(nil, {}, rest, places.text_room)
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
// counts for its level and for its process. A process that finds no free
// place counts in `other_processes`. The sentence of a fact is rendered
// here, once. The record is in memory that the kernel writes: its level
// byte becomes the enum at this one place, and a byte that names no level
// gives false: the caller counts the record as lost.
take :: proc "contextless" (record: ^system.Log_Record) -> bool {
	level, level_ok := enum_word.member_of_word(op.Log_Level, u64(transmute(u8)record.level))
	if !level_ok {
		return false
	}
	if form, form_known := op.log_record_form(record); form_known && form == .Fact {
		fact_take(record)
	} else if fact_records_join.open && op.log_fact_join_other_record(&fact_records_join, record.sequence, op.log_fact_writer(record)) != .None {
		fact_parts_raw(fact_records_join_first, row_count, true)
	}
	rows[row_count % ROWS] = record^
	row_count += 1
	level_counts[level] += 1
	for &counted in process_counts[:process_count] {
		if counted.slot == record.process && counted.serial == record.process_serial {
			counted.count += 1
			return true
		}
	}
	if process_count == COUNTED_PROCESSES {
		other_processes += 1
		return true
	}
	process_counts[process_count] = {slot = record.process, serial = record.process_serial, name = record.name, count = 1}
	process_count += 1
	return true
}

// card_width gives the width of the card of a count: its name, a space, the
// digits of the count, and the gap to the next card.
card_width :: proc "contextless" (name: string, count: u64) -> int {
	digits := 1
	for rest := count / 10; rest != 0; rest /= 10 {
		digits += 1
	}
	return graphics.text_width(name) + 8 + digits * graphics.text_width("0") + 12
}

// card_draw draws the card of a count at its place: a band, its name, and
// the count.
card_draw :: proc "contextless" (canvas: graphics.Canvas, x, y, width: int, name: string, count: u64) {
	graphics.fill(canvas, x - 4, y, width - 8, LINE, element_tokens.surface_card)
	after := graphics.text(canvas, x, y, name, element_tokens.text)
	graphics.unsigned(canvas, after + 8, y, count, element_tokens.text)
}

// draw draws the whole window: the counts, the processes, the legend of the
// value kinds, and the last records, each in the place that the layout
// tree gave. A text drops the start that repeats its process
// (`repeated_start`).
draw :: proc "contextless" (canvas: graphics.Canvas) {
	// graphics holds only members of the appearance: the tokens of the
	// standard contrast are the colors that the window drew with before.
	element_tokens, _ = layout.tokens_for(graphics.appearance, .Standard)
	// The size of the picture now. A size that the tree refuses keeps the
	// places before.
	if laid_out, laid_out_ok := log_layout(canvas.width, canvas.height); laid_out_ok {
		places = laid_out
	}
	graphics.clear(canvas, element_tokens.surface_background)
	// The log is a ring of the kernel: its title in the color of the kernel.
	counts := places.counts
	graphics.fill(canvas, counts.x, counts.y - 4, counts.width, 2, graphics.colors.kernel)
	x := graphics.text(canvas, counts.x, counts.y, "the log  ", graphics.colors.kernel)
	x = graphics.unsigned(canvas, x, counts.y, row_count, element_tokens.text)
	x = graphics.text(canvas, x, counts.y, " read, ", element_tokens.text_dim)
	// Records gone before the start are a fact of the boot, not a fault
	// of this reader: only the count lost since is in the color of a
	// failure (src/md/features/log_window_losses.md).
	x = graphics.unsigned(canvas, x, counts.y, gone_before_start, element_tokens.text)
	x = graphics.text(canvas, x, counts.y, " gone before its start, ", element_tokens.text_dim)
	x = graphics.unsigned(canvas, x, counts.y, lost, lost == 0 ? element_tokens.text : element_tokens.failed)
	x = graphics.text(canvas, x, counts.y, " lost since    ", element_tokens.text_dim)
	for count, level in level_counts {
		names := [system.Log_Level]string {
			.Info    = "info ",
			.Debug   = "debug ",
			.Warning = "warning ",
			.Error   = "error ",
		}
		graphics.fill(canvas, x, counts.y + 4, 8, 8, level_color(level))
		x = graphics.text(canvas, x + 12, counts.y, names[level], element_tokens.text_dim)
		x = graphics.unsigned(canvas, x, counts.y, count, element_tokens.text) + 16
	}

	// The processes, with the count of records of each one, on the lines
	// between the top line and the heads of the columns. A card that does
	// not fit there counts with the others, in the last card, so no card
	// covers the heads of the columns.
	cards := places.processes
	cards_left := cards.x + graphics.text_width("processes ")
	cards_right := cards.x + cards.width
	graphics.text(canvas, cards.x, cards.y, "processes ", element_tokens.text_dim)
	others_width := card_width("others", max(u64))
	x = cards_left
	y := cards.y
	last_line_y := cards.y + cards.height - LINE
	others := other_processes
	for &counted, index in process_counts[:process_count] {
		name := system.name_of(counted.name[:])
		width := card_width(name, counted.count)
		card_x, card_y := x, y
		if card_x + width > cards_right {
			card_x = cards_left
			card_y += LINE
		}
		// The last line keeps the room of the card of the others while a
		// card of the others can come after this one.
		room := cards_right
		if card_y == last_line_y && (index < process_count - 1 || other_processes > 0) {
			room -= others_width
		}
		if card_y > last_line_y || card_x + width > room {
			for &rest in process_counts[index:process_count] {
				others += rest.count
			}
			break
		}
		card_draw(canvas, card_x, card_y, width, name, counted.count)
		x, y = card_x + width, card_y
	}
	if others > 0 {
		// The room is kept on the last line: the card fits there, or on
		// the line of the cards when that line is before the last one.
		if x + others_width > cards_right {
			x = cards_left
			y += LINE
		}
		card_draw(canvas, x, y, card_width("others", others), "others", others)
	}

	columns := &places.columns
	heads := places.heads
	graphics.text(canvas, int(columns[.Time].x), heads.y, "time (s)", element_tokens.text_dim)
	graphics.text(canvas, int(columns[.Process].x), heads.y, "process", element_tokens.text_dim)
	x = graphics.text(canvas, int(columns[.Text].x), heads.y, "text   ", element_tokens.text_dim)
	for kind, index in legend_kinds {
		x = graphics.text(canvas, x, heads.y, legend_names[index], graphics.value_kind_color(kind, graphics.appearance)) + 16
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
	// The window shows the newest texts that fit whole in the lines of its
	// records. The older ones are in the log, as each record that left the
	// window.
	first_group, used := group_count, 0
	for first_group > 0 && used + groups[first_group - 1].lines <= places.record_lines {
		first_group -= 1
		used += groups[first_group].lines
	}
	records := places.records
	y = records.y
	for group, index in groups[first_group:group_count] {
		record := record_shown(group.first)
		height := group.lines * LINE
		// Every second row on a band of the top of a card, as a table of
		// the rules (docs/DESIGN.md, "10. Elements").
		if index % 2 == 1 {
			graphics.fill(canvas, records.x - 4, y, records.width + 8, height, element_tokens.surface_card)
		}
		graphics.fill(canvas, records.x - 4, y, 3, height, level_color(record.level))
		milliseconds := record.time / 1000
		x = graphics.unsigned(canvas, int(columns[.Time].x) + 4, y, milliseconds / 1000, element_tokens.text_dim, 4)
		x = graphics.text(canvas, x, y, ".", element_tokens.text_dim)
		graphics.unsigned(canvas, x, y, milliseconds % 1000, element_tokens.text_dim, 3)
		lines_draw(canvas, int(columns[.Process].x), y, places.name_room, system.name_of(record.name[:]), record.process == 0 ? element_tokens.text : graphics.colors.series[record.process % graphics.SERIES_COLOR_COUNT])
		join(joined, group)
		joined_text_draw(canvas, int(columns[.Text].x), y, joined, record.level == .Error ? element_tokens.failed : element_tokens.text)
		y += height
	}
}

// entry opens the window of the log and runs its loop: it shows each new
// log record until the process is stopped.
//
// **What it sets up**: a window, the reader of the log records (the memory
// of the records that the grant **Log_Records** gives, mapped read-only),
// and the service ring of its exports, which read the same memory.
//
// **The loop.** One wait covers the window, the counter of the log and the
// service ring. After each wake it takes every new record (`take`): the
// counts of each level and of each process, and the last 30 records. It
// adds the records that the kernel wrote over before the read to the count
// gone before its start while it kept no record, and to the count lost
// since after that. It draws the window again only when a record came. At
// the first turn it writes two records of its own: the records that the
// ring keeps and the size of the memory of the log, then `log: ok, <count>
// records, <count> gone before its start, <count> lost since, <count>
// processes`. Then it runs the calls of its exports.
//
// **The stop**: with no window, it stops with `Failed`. With no grant of
// the log records, it writes `log: cannot read the records of the log:
// status <status>` at the level error, and stops with `Failed`. Else it
// never returns.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	window, ok := display.open(ctx, WIDTH, HEIGHT, "log")
	if !ok {
		system.stop(.Failed)
	}
	if interface.hand_picture_open(&hand_picture, &window) != .Succeeded {
		system.stop(.Failed)
	}
	reader, status := system.log_open(ctx.handles[system.GRANT_LOG_RECORDS])
	if status != .Succeeded {
		system.log_fact(.Error, Records_Not_Readable{status = call_outcome.Call_Outcome_Word(status)})
		system.stop(.Failed)
	}
	// The service reads the same memory object: exports.odin. Its handle
	// also reads the own log ring of a caller (Log_Read).
	reader_head, reader_records = reader.head, reader.records
	// The first follower joins from the head of the log, not from its
	// first record, also when it joins before the first pass of the pump.
	log_memory = ctx.handles[system.GRANT_LOG_RECORDS]
	session_table_open(ctx) // principal_scope.odin
	follow_next = intrinsics.atomic_load(&reader_head.written)
	window_scope := log_scope.Scope{kind = .Principal_Records, principal = window_principal}
	// The catalog of the facts: with no image, each fact shows raw.
	if address, mapped := system.memory_map(ctx.handles[system.GRANT_IMAGE], {}); mapped == .Succeeded {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	service, _ = system.service_open(ctx)
	system.wiring_ring_open()
	logged := false
	picture_owed := true // The window does not show each record that was taken.
	for {
		// The pass first: the window takes the settled records of its
		// principal only (principal_scope.odin).
		settle_deadline := principals_settle()
		for reader.next < settled_next {
			record, late, has := system.log_next(&reader)
			// Before the first kept record, a gap only says how long the
			// machine ran before this process; after it, a gap is a
			// record that this reader was too slow to read.
			if row_count == 0 {
				gone_before_start += late
			} else {
				lost += late
			}
			if !has {
				break
			}
			place, settled := record_settled(record.sequence)
			if !settled || !log_scope.record_in_scope(window_scope, place.principal, place.known) {
				continue
			}
			if !take(&record) {
				// A level byte that names no member: no reader can read
				// the record, so it counts as a record that this reader
				// did not read.
				if row_count == 0 {
					gone_before_start += 1
				} else {
					lost += 1
				}
				continue
			}
			picture_owed = true
		}
		// The followers of log.follow: the records since the last pass, or
		// the record that a full ring refused at it, and a gap where the
		// kernel wrote over records first (follow.odin).
		follow_pump()
		for event in interface.window_next_event(&hand_picture.drawing, &window) {
			// A new appearance or a new font: each pixel of the window
			// changes, with no new record.
			if event.kind == .Presentation {
				picture_owed = true
			}
		}
		// The scroll of a window that does not fit the work area: its bars,
		// the wheel and the page keys need a picture.
		if interface.window_scroll_frame_take(&hand_picture.drawing) {
			picture_owed = true
		}
		// This service never waits for the compositor: while the
		// compositor did not take the last picture, the window owes its
		// picture, and the wait below ends when the compositor has read.
		// The whole canvas is drawn: it is the other picture of the
		// surface.
		if picture_owed && display.canvas_free(&window) {
			draw(hand_picture.canvas)
			interface.hand_picture_show(&hand_picture, &window)
			picture_owed = false
		}
		if !logged {
			logged = true
			// The memory object of the log is its head and its records,
			// each of the size of one record.
			memory_bytes := (reader.head.capacity + 1) * size_of(system.Log_Record)
			system.log_fact(.Info, Log_Memory{capacity = reader.head.capacity, memory = value_kinds.Size_In_Kibibytes(memory_bytes / 1024)})
			system.log_fact(.Info, Window_Ready{records = row_count, gone_before_start = gone_before_start, lost = lost, processes = u64(process_count)})
			continue
		}
		// The list comes after the reads and after the question to the
		// canvas: a record or a call that arrived since ends the wait at
		// once.
		log_wait_follow_the_ends() // follow.odin
		wait := system.wait_of_set(&log_wait.set)
		display.wait_events(&wait, &window)
		// A new record of the log ends the wait; a record that waits for
		// its row ends it at the deadline of the pass.
		system.wait_word(&wait, (^u32)(&reader.head.written), u32(intrinsics.atomic_load(&reader.head.written)))
		// A new end of log.follow: the pump takes it at the next pass, so
		// the follower joins without a wait for the next log record.
		system.wait_wiring(&wait)
		// A follower whose full ring refused a row: its read wakes the
		// pump, which writes the row that it kept, or the gap of the
		// records that the kernel wrote over meanwhile. The list holds each
		// ring of follow and leaves the words of the service after them.
		follow_rings := max(system.wait_room_left(&wait) - 2 * (1 + isolated.SERVICE_CONNECTION_CAPACITY), 0) / system.OUTPUT_ROOM_WAIT_WORDS
		_ = system.wait_output_room(&wait, &follow, follow_rings)
		system.service_wait(&wait, &service)
		system.wait_end(&wait, settle_deadline)
		system.service_run(&service)
	}
}
