// Tables and bytes as parameters (docs/MODULE_CONTRACT.md, "Tables and
// bytes as parameters"): one description, three ways to call.
//
// This process calls the exports of the module sample with tables in its
// own memory, in three ways, with the same arguments: a direct call of the
// module that it loaded in its own address space, an isolated call of a
// call host that it starts, and an isolated call of the service "sample"
// (the same module, started by the root service as a process). It shows
// each answer, the hostile cases, and the cost of each way for tables of
// 64, 1024 and 65536 records of 40 bytes.
//
// **What it is for.** It proves that one description of an export serves
// the three ways of a call with the same answer: the caller chooses the
// isolation, and the module has no code of its own for it. A table travels
// as records of fixed size, so the callee checks a count and a size, never
// a pointer of the caller. The hostile cases are exports of the module
// `hostile_exports` that lie on purpose: the call path must refuse each one.
//
// **Start**: `start("tables")` in the console, or the bar of the desktop.
//
// **Grants**, as the root service gives them:
//
// - **Image**: the boot image, read-only: it loads `sample` and
//   `hostile_exports` into its own address space, and starts their call
//   hosts from it.
// - **Connect**: a ring to the root service that serves `Connect` to the
//   service `sample` only. The root service starts `sample` on demand.
//
// **What a reader sees**: a table with one row for each case and one
// column for each way, the hostile cases, and the measures. The log has
// "tables: the ways: direct ready, call host ready, service ready", one
// line for each hostile case, the time of `sum_values` in each way for 64,
// 1024 and 65536 rows, and "tables: ok, N cases in 3 ways and M hostile
// cases", or "tables: wrong answer: ..." for each wrong answer.
//
// **What it does not prove**: a way that does not start is shown as
// "refused" and its cases fail; the process does not retry it.
package tables

import "base:intrinsics"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/random"
import "modus:support/system"

// A table of 65536 readings in a memory object (640 pages), and two call
// hosts (sample, hostile_exports) with their threads.
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2561, processes = 3, threads = 3, window_width = WIDTH, window_height = HEIGHT}

// The records of sample, as this process declares them: the layout is the
// description (a process in C declares the same struct).
Reading :: struct {
	sensor:  i64,
	time:    i64,
	value:   i64,
	minimum: i64,
	maximum: i64,
}
#assert(size_of(Reading) == 40)

Word :: struct {
	start: u32,
	count: u32,
	sum:   i64,
}

Way :: enum {
	Direct,
	Call_Host,
	Service,
}

@(rodata)
way_names := [Way]string {
	.Direct    = "direct call",
	.Call_Host = "call host",
	.Service   = "service",
}

ANSWER_SIZE :: 240 // The sentence of an error record fits: the window shows it whole, on the lines that it needs.

Answer :: struct {
	text:  [ANSWER_SIZE]u8,
	count: int,
	right: bool,
	done:  bool,
}

CASE_CAPACITY :: 12

Case :: struct {
	name:    string,
	answers: [Way]Answer,
}

cases: [CASE_CAPACITY]Case
case_count: int

answer_set :: proc "contextless" (answer: ^Answer, right: bool, parts: ..system.Part) {
	written := system.format(answer.text[:], ..parts)
	answer.count = len(written)
	answer.right, answer.done = right, true
}

image: []u8
image_memory: system.Handle
space: system.Module_Space
sample_file: []u8
sample_base: u64
host: system.Call_Connection
service: system.Call_Connection
// The module of the exports that are wrong on purpose: in this process and
// in a call host of its own; no service holds it.
hostile_file: []u8
hostile_base: u64
hostile_host: system.Call_Connection
hostile_ready: [Way]bool
requests: ring.Ring
ways_ready: [Way]bool

// The table of the measures, in a memory object: the same records are the
// table of a direct call and the table of a lent memory object.
LARGE_COUNT :: 65536
large_memory: system.Handle
large: []Reading

export_of :: proc "contextless" (name: string) -> (index: u32, function: module.Function, address: uintptr) {
	index = module.export_find(sample_file, name)
	function, _ = module.function(sample_file, index)
	address, _ = module.export_address(sample_file, uintptr(sample_base), index)
	return
}

// call_hostile runs one export of hostile_exports in one way.
call_hostile :: proc "contextless" (way: Way, name: string, arguments: []isolated.Argument) -> (result: i64, status: system.Call_Status) {
	index := module.export_find(hostile_file, name)
	function, _ := module.function(hostile_file, index)
	address, _ := module.export_address(hostile_file, uintptr(hostile_base), index)
	switch way {
	case .Direct:
		return system.call_direct(hostile_file, address, function, arguments)
	case .Call_Host:
		return system.call_isolated(&hostile_host, hostile_file, index, arguments)
	case .Service:
		// No service holds the hostile exports: the caller skips this way.
		return 0, .Refused
	}
	return 0, .Refused
}

// call runs one export with the same arguments in one way.
call :: proc "contextless" (way: Way, name: string, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (result: i64, status: system.Call_Status) {
	index, function, address := export_of(name)
	switch way {
	case .Direct:
		return system.call_direct(sample_file, address, function, arguments, error)
	case .Call_Host:
		return system.call_isolated(&host, sample_file, index, arguments, error)
	case .Service:
		return system.call_isolated(&service, sample_file, index, arguments, error)
	}
	return
}

bytes_of :: proc "contextless" (memory: rawptr, count: int) -> []u8 {
	return ([^]u8)(memory)[:count]
}

GUARD :: u8(0xA5)

guard_fill :: proc "contextless" (bytes: []u8) {
	for &b in bytes {
		b = GUARD
	}
}

answer_text :: proc "contextless" (answer: ^Answer) -> string {
	return string(answer.text[:answer.count])
}

guard_holds :: proc "contextless" (bytes: []u8) -> bool {
	for b in bytes {
		if b != GUARD {
			return false
		}
	}
	return true
}

readings_four :: proc "contextless" (memory: ^[8]Reading) {
	memory^ = {}
	for index in 0 ..< 4 {
		value := i64(index + 1) * 10
		memory[index] = {sensor = i64(index), time = i64(index), value = value, minimum = value, maximum = value}
	}
}

case_add :: proc "contextless" (name: string) -> ^Case {
	item := &cases[case_count]
	item.name = name
	case_count += 1
	return item
}

run_cases :: proc "contextless" () {
	sum := case_add("sum_values  Read, 4 rows")
	scale := case_add("scale_values  Change, x3")
	appended := case_add("append_readings  5 after 2, cap 6")
	empty := case_add("append_readings  capacity 0")
	words := case_add("sum_words  offsets into Bytes")
	outside := case_add("sum_words  a word past the text")
	upper := case_add("upper_case  Bytes(Change)")
	past := case_add("a callee writes past capacity")
	for way in Way {
		if !ways_ready[way] {
			for &item in cases[:case_count] {
				answer_set(&item.answers[way], false, "not reached")
			}
			continue
		}
		memory: [8]Reading
		readings_four(&memory)
		arguments := [3]isolated.Argument{}
		arguments[0].table = {records = bytes_of(&memory, 4 * 40), count = 4}
		result, status := call(way, "sum_values", arguments[:1])
		answer_set(&sum.answers[way], status == .Ok && result == 100, result)

		readings_four(&memory)
		arguments[0].table = {records = bytes_of(&memory, 4 * 40), count = 4}
		arguments[1] = {integer = 3}
		result, status = call(way, "scale_values", arguments[:2])
		answer_set(&scale.answers[way], status == .Ok && result == 4 && memory[3].value == 120 && memory[0].maximum == 30 && memory[4] == {}, result, " rows; row 4: ", memory[3].value)

		// 8 places: the table has a capacity of 6, then a guard of 2 records.
		readings_four(&memory)
		guard_fill(bytes_of(&memory[6], 2 * 40))
		arguments[0] = {integer = 5}
		arguments[1] = {integer = 100}
		arguments[2].table = {records = bytes_of(&memory, 6 * 40), count = 2}
		result, status = call(way, "append_readings", arguments[:3])
		answer_set(&appended.answers[way], status == .Ok && result == 4 && arguments[2].table.count == 7 && memory[2].value == 100 && memory[5].value == 103 && memory[1].value == 20 && guard_holds(bytes_of(&memory[6], 80)), result, " written, count ", arguments[2].table.count)

		arguments[2].table = {count = 0}
		arguments[0] = {integer = 3}
		result, status = call(way, "append_readings", arguments[:3])
		answer_set(&empty.answers[way], status == .Ok && result == 0 && arguments[2].table.count == 3, result, " written, count ", arguments[2].table.count)

		text := "tables go in"
		list := [3]Word{{0, 6, 0}, {7, 2, 0}, {10, 2, 0}}
		arguments[0].table = {records = bytes_of(&list, size_of(list)), count = 3}
		arguments[1] = {}
		arguments[1].table = {records = transmute([]u8)text, count = u64(len(text))}
		error: errors.Error_Record
		result, status = call(way, "sum_words", arguments[:2], &error)
		answer_set(&words.answers[way], status == .Ok && result == 1064 && list[0].sum == 635 && list[1].sum == 214, result, "; words ", list[0].sum, " ", list[1].sum, " ", list[2].sum)

		list[1] = {7, 9, 0}
		error = {}
		result, status = call(way, "sum_words", arguments[:2], &error)
		answer_set(&outside.answers[way], status == .Failed && result == -1 && errors.Kind(error.kind) == .Out_Of_Range && error.found == 2 && error.value == 16 && error.limit == 12, "Out_Of_Range: word ", error.found, ", ", error.value)

		changed: [12]u8
		copy(changed[:], "tables go in")
		arguments[0] = {}
		arguments[0].table = {records = changed[:], count = 12}
		result, status = call(way, "upper_case", arguments[:1])
		answer_set(&upper.answers[way], status == .Ok && result == 10 && string(changed[:]) == "TABLES GO IN", result, " letters: ", string(changed[:]))

		// The export writes 4 records after the capacity, against the rule.
		// A direct call has one address space: the guard is written. An
		// isolated call: the caller copies up to the capacity only.
		memory = {}
		guard_fill(bytes_of(&memory[2], 6 * 40))
		arguments[0] = {}
		arguments[0].table = {records = bytes_of(&memory, 2 * 40), count = 0}
		// No service holds such an export (a network host could name it).
		if way == .Service {
			answer_set(&past.answers[way], module.export_find(sample_file, "append_past_capacity") == 0, "no service holds it")
			continue
		}
		if !hostile_ready[way] {
			answer_set(&past.answers[way], false, "not reached")
			continue
		}
		result, status = call_hostile(way, "append_past_capacity", arguments[:1])
		holds := guard_holds(bytes_of(&memory[2], 6 * 40))
		answer_set(&past.answers[way], way == .Direct ? !holds : holds && status == .Ok, holds ? "the guard holds" : "guard written: one space")
	}
}

// The hostile cases, through the call host.
Hostile :: struct {
	name:   string,
	answer: Answer,
}
hostile: [12]Hostile
hostile_count: int

hostile_add :: proc "contextless" (name: string, right: bool, parts: ..system.Part) {
	item := &hostile[hostile_count]
	item.name = name
	answer_set(&item.answer, right, ..parts)
	hostile_count += 1
}

// raw_call sends an argument record that this process wrote itself, as a
// hostile caller does, and gives the status of the completion.
raw_call :: proc "contextless" (connection: ^system.Call_Connection, export: u32, size: u64) -> (status_word: u32, refusal: errors.Error_Record) {
	connection.tag += 1
	system.send(&connection.calls.commands, ring.Record{kind = export, tag = connection.tag, values = {0 = 0, 1 = size}})
	for {
		wait := system.wait_begin()
		for record in system.receive(&connection.calls.completions) {
			if record.tag == connection.tag {
				// The values of a refusal hold its error record.
				return record.kind, transmute(errors.Error_Record)record.values
			}
		}
		if state, _ := system.process_state(connection.process); state == .Stopped {
			return max(u32), {} // A word that names no status: the process stopped.
		}
		system.wait_records(&wait, &connection.calls.completions)
		system.wait_end(&wait)
	}
}

// refusal_add adds a case whose answer is the sentence of an error record.
refusal_add :: proc "contextless" (name: string, right: bool, refusal: ^errors.Error_Record, export: string, parameter: string) {
	buffer: [ANSWER_SIZE]u8
	writer := system.Writer{buffer = buffer[:]}
	system.error_text(&writer, refusal, export, parameter)
	hostile_add(name, right, system.written(&writer))
}

run_hostile :: proc "contextless" () {
	if !ways_ready[.Call_Host] {
		hostile_add("the hostile cases", false, "no call host")
		return
	}
	index, function, _ := export_of("sum_values")
	arguments := [2]isolated.Argument{}
	arguments[0].table = {records = bytes_of(raw_data(large), LARGE_COUNT * 40), count = LARGE_COUNT}
	_, status := system.call_isolated(&host, sample_file, index, arguments[:1])
	missing := isolated.room_missing(sample_file, function, arguments[:1], u64(len(host.region)))
	hostile_add("65536 rows in the call region", status == .No_Room && missing.needed == LARGE_COUNT * 40, "refused: ", missing.needed, " bytes, ", missing.free, " free")

	arguments[0].table.memory_handle = u64(large_memory)
	result, lent_status := system.call_isolated(&host, sample_file, index, arguments[:1])
	expected := i64(LARGE_COUNT) * (LARGE_COUNT - 1) / 2
	hostile_add("the same rows in a lent memory object", lent_status == .Ok && result == expected, result)

	// The service refuses a table in a memory object: the caller could
	// revoke it while the export runs, and stop the service for each caller.
	if ways_ready[.Service] {
		arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory_handle = u64(large_memory)}
		refusal: errors.Error_Record
		_, service_status := system.call_isolated(&service, sample_file, index, arguments[:1], &refusal, true)
		refusal_add("a memory object to the service", service_status == .Refused && refusal.argument == 1, &refusal, "sum_values", "readings")
	}

	// A Change table in a memory object that this process lends with Read
	// only: the receiver proves the rights of the direction.
	scale_index, scale_function, _ := export_of("scale_values")
	copy_handle, give_status := system.give(0, large_memory, {.Read, .Give})
	receiver: system.Handle
	if give_status == .Ok {
		receiver, give_status = system.give(host.ring_memory, copy_handle, {.Read})
	}
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory_handle = u64(receiver)}
	arguments[1] = {integer = 2}
	_, size, _, _, encoded := isolated.encode(sample_file, scale_function, arguments[:2], host.region)
	refused := u32(isolated.Status.Ok)
	refusal: errors.Error_Record
	if encoded && give_status == .Ok {
		refused, refusal = raw_call(&host, scale_index, size)
	}
	system.handle_revoke(copy_handle)
	system.close(copy_handle)
	hostile_add("a Change table lent with Read only", refused == u32(isolated.Status.Bad_Handle) && large[63].value == 63, "Bad_Handle; rows unchanged")

	// A budget lent as the memory of a table: the receiver checks the kind
	// of the object: a table names a memory object, and no other kind.
	budget_copy, budget_status := system.give(0, system.own_budget(), {.Read, .Give})
	if budget_status == .Ok {
		receiver, budget_status = system.give(host.ring_memory, budget_copy, {.Read})
	}
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory_handle = u64(receiver)}
	_, size, _, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	refused, refusal = u32(isolated.Status.Ok), {}
	if encoded && budget_status == .Ok {
		refused, refusal = raw_call(&host, index, size)
	}
	system.handle_revoke(budget_copy)
	system.close(budget_copy)
	refusal_add("a budget as the memory of a table", refused == u32(isolated.Status.Bad_Handle) && errors.Kind(refusal.kind) == .Handle_Kind, &refusal, "sum_values", "readings")

	// A count larger than the call region, written by hand: the refusal is
	// an error record, so that the caller learns which argument and why.
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64}
	_, size, _, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	field := (^isolated.Table_Field)(raw_data(host.region))
	field.count = 1 << 40
	refused, refusal = u32(isolated.Status.Ok), {}
	if encoded {
		refused, refusal = raw_call(&host, index, size)
	}
	refusal_add("a count of 2^40 rows", refused == u32(isolated.Status.Bad_Arguments) && errors.Kind(refusal.kind) == .Too_Long && refusal.argument == 1, &refusal, "sum_values", "readings")

	// A start that wraps.
	_, size, _, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	field.start = max(u64) - 7
	refused, refusal = u32(isolated.Status.Ok), {}
	if encoded {
		refused, refusal = raw_call(&host, index, size)
	}
	refusal_add("a start that wraps", refused == u32(isolated.Status.Bad_Arguments) && errors.Kind(refusal.kind) == .Out_Of_Range && refusal.argument == 1, &refusal, "sum_values", "readings")

	// A direct call of an export with a Table result: call_direct does not
	// do it, and says so: else it gives the address of the error record
	// where the export reads its buffer.
	readings_index, readings_function, readings_address := export_of("readings")
	arguments[0] = {integer = 4}
	direct_refusal: errors.Error_Record
	_, direct_status := system.call_direct(sample_file, readings_address, readings_function, arguments[:1], &direct_refusal)
	hostile_add("call_direct of a Table result", direct_status == .Not_Done && readings_index != 0, "Not_Done: the result is not an Integer")
}

// The measures: the least time of several runs, for one call of sum_values
// over 64, 1024 and 65536 readings.
SIZES :: [3]int{64, 1024, LARGE_COUNT}
Measure_Way :: enum {
	Direct,
	Region,
	Memory_Object,
	Service_Region,
}
@(rodata)
measure_names := [Measure_Way]string {
	.Direct         = "direct call",
	.Region         = "call host, call region",
	.Memory_Object  = "call host, memory object",
	.Service_Region = "service, call region",
}
measures: [Measure_Way][3]u64 // Nanoseconds for one call. 0: refused.

measure :: proc "contextless" () {
	index, function, address := export_of("sum_values")
	direct := cast(proc "c" (readings: ^system.Table_To_Read(Reading)) -> i64)rawptr(address)
	sizes := SIZES
	for size, column in sizes {
		repeat := max(4, 262144 / size)
		table := system.Table_To_Read(Reading){records = raw_data(large), count = u64(size), capacity = u64(size)}
		least := max(u64)
		for _ in 0 ..< 5 {
			start := system.nanoseconds()
			for _ in 0 ..< repeat {
				intrinsics.volatile_store(&sink, direct(&table))
			}
			least = min(least, (system.nanoseconds() - start) / u64(repeat))
		}
		measures[.Direct][column] = max(least, 1)
		for way in ([3]Measure_Way{.Region, .Memory_Object, .Service_Region}) {
			connection := way == .Service_Region ? &service : &host
			if !ways_ready[way == .Service_Region ? .Service : .Call_Host] {
				continue
			}
			arguments := [1]isolated.Argument{}
			arguments[0].table = {records = bytes_of(raw_data(large), size * 40), count = u64(size)}
			if way == .Memory_Object {
				arguments[0].table.memory_handle = u64(large_memory)
			}
			calls := way == .Memory_Object ? max(4, repeat / 16) : max(4, repeat / 4)
			least = max(u64)
			for _ in 0 ..< 3 {
				start := system.nanoseconds()
				ok := true
				for call_number in 0 ..< calls {
					result, status := system.call_isolated(connection, sample_file, index, arguments[:], nil, way == .Memory_Object)
					intrinsics.volatile_store(&sink, result)
					if status != .Ok && ok {
						system.log(.Info, "tables: ", measure_names[way], ", ", u64(size), " rows: call ", u64(call_number), " gave the status ", u64(status))
					}
					ok &&= status == .Ok
				}
				if !ok {
					least = 0
					break
				}
				least = min(least, (system.nanoseconds() - start) / u64(calls))
			}
			measures[way][column] = least
		}
	}
	_ = function
}
sink: i64

WIDTH :: 1000
HEIGHT :: 704
LINE :: 20 // A row of a card: a line of text and 4 pixels. The cases are many.
TEXT_LINE :: graphics.LINE_HEIGHT // One more line of a text that has several.
CARD_X :: 16
CARD_WIDTH :: WIDTH - 2 * CARD_X
CARD_HEAD :: 48 // The title of a card, and the room under its last row.
NAME_X :: 40 // The column of the names, in a card.
ANSWER_X :: 312 // The first column of the answers.
COLUMN_WIDTH :: 220
// The box of an answer of the first card: its column, after its mark.
ANSWER_ROOM :: COLUMN_WIDTH - 16 - 8
// The answer of a hostile case starts after the longest name, "the same
// rows in a lent memory object" (36 characters after its mark), and has
// the rest of the card.
HOSTILE_ANSWER_X :: NAME_X + 16 + 38 * graphics.CELL_WIDTH
HOSTILE_ANSWER_ROOM :: CARD_X + CARD_WIDTH - 16 - HOSTILE_ANSWER_X
MEASURES_HEIGHT :: CARD_HEAD + 5 * LINE
#assert(ANSWER_X + 2 * COLUMN_WIDTH + 16 + ANSWER_ROOM <= CARD_X + CARD_WIDTH - 16)

// text_lines draws a text in a box of `room` pixels, on the lines that it
// needs (the rule of interface.text_wrap_line), and gives their count. This
// window draws with src/library/support/graphics: the rule is the one of
// the interface package, the pixels are its own.
text_lines :: proc "contextless" (canvas: graphics.Canvas, x, y, room: int, text: string, color: graphics.Color) -> (count: int) {
	rest := text
	for len(rest) > 0 {
		line: string
		line, rest = interface.text_wrap_line(nil, {}, rest, room)
		graphics.text(canvas, x, y + count * TEXT_LINE, line, color)
		count += 1
	}
	return count
}

// line_count gives the lines of a text in a box, at least one.
line_count :: proc "contextless" (text: string, room: int) -> int {
	return max(interface.text_wrapped_line_count(nil, {}, text, room), 1)
}

// row_height gives the height of a row whose longest text has `lines` lines.
row_height :: proc "contextless" (lines: int) -> int {
	return LINE + (lines - 1) * TEXT_LINE
}

// case_row_lines gives the lines of the row of a case: its longest answer.
case_row_lines :: proc "contextless" (item: ^Case) -> (lines: int) {
	lines = 1
	for way in Way {
		lines = max(lines, line_count(answer_text(&item.answers[way]), ANSWER_ROOM))
	}
	return lines
}

card :: proc "contextless" (canvas: graphics.Canvas, x, y, width, height: int, title, caption: string, accent: graphics.Color) {
	graphics.block(canvas, x, y, width, height, graphics.colors.card_top, graphics.colors.card_bottom)
	graphics.outline(canvas, x, y, width, height, 1, graphics.mix(graphics.colors.card_bottom, accent, 72))
	graphics.fill(canvas, x, y, 4, height, accent)
	graphics.text(canvas, x + 16, y + 12, title, accent)
	graphics.text(canvas, x + width - 16 - graphics.text_width(caption), y + 12, caption, graphics.colors.dim)
}

// mark draws the square of an answer: the color of a process when it is
// the expected answer, the color "failed" when it is not.
mark :: proc "contextless" (canvas: graphics.Canvas, x, y: int, right: bool) {
	graphics.fill(canvas, x, y + 4, 8, 8, right ? graphics.colors.process : graphics.colors.failed)
}

draw :: proc "contextless" (canvas: graphics.Canvas) {
	graphics.clear(canvas, graphics.colors.background)
	for y := 12; y < HEIGHT; y += 24 {
		for x := 12; x < WIDTH; x += 24 {
			graphics.fill(canvas, x, y, 2, 2, graphics.colors.point)
		}
	}
	// The cases: one row for each, one column for each way. An answer has
	// the box of its column, and a row the height of its longest answer:
	// the card is as high as its rows.
	y := 16
	height := CARD_HEAD + LINE
	for &item in cases[:case_count] {
		height += row_height(case_row_lines(&item))
	}
	card(canvas, CARD_X, y, CARD_WIDTH, height, "one description, three ways to call", "module sample, the same arguments", graphics.colors.kernel)
	y += 40
	graphics.text(canvas, NAME_X, y, "export  table", graphics.colors.dim)
	for way in Way {
		graphics.text(canvas, ANSWER_X + int(way) * COLUMN_WIDTH, y, way_names[way], graphics.colors.dim)
	}
	y += LINE
	for &item in cases[:case_count] {
		graphics.text(canvas, NAME_X, y, item.name, graphics.colors.text)
		for way in Way {
			answer := &item.answers[way]
			x := ANSWER_X + int(way) * COLUMN_WIDTH
			mark(canvas, x, y, answer.right)
			text_lines(canvas, x + 16, y, ANSWER_ROOM, answer_text(answer), answer.right ? graphics.colors.text : graphics.colors.failed)
		}
		y += row_height(case_row_lines(&item))
	}
	// The hostile cases, with their answers: the sentence of an error
	// record, whole. The card of the measures is at the bottom of the
	// window, and this card has the room between the two: it shows the
	// cases that fit, and counts the others on its last line.
	y = 16 + height + 16
	measures_y := HEIGHT - 16 - MEASURES_HEIGHT
	room := measures_y - 16 - y - CARD_HEAD
	shown, rows_height := 0, 0
	for &item in hostile[:hostile_count] {
		next := row_height(line_count(answer_text(&item.answer), HOSTILE_ANSWER_ROOM))
		kept := shown == hostile_count - 1 ? 0 : LINE // The line of the count, when a case is left.
		if rows_height + next > room - kept {
			break
		}
		rows_height += next
		shown += 1
	}
	hostile_height := CARD_HEAD + rows_height + (shown < hostile_count ? LINE : 0)
	card(canvas, CARD_X, y, CARD_WIDTH, hostile_height, "a hostile caller, through the call host", "isolated.decode, export_serve", graphics.colors.failed)
	row := y + 40
	for &item in hostile[:shown] {
		mark(canvas, NAME_X, row, item.answer.right)
		graphics.text(canvas, NAME_X + 16, row, item.name, graphics.colors.text)
		row += row_height(text_lines(canvas, HOSTILE_ANSWER_X, row, HOSTILE_ANSWER_ROOM, answer_text(&item.answer), item.answer.right ? graphics.colors.text : graphics.colors.failed))
	}
	if shown < hostile_count {
		rest_buffer: [64]u8
		graphics.text(canvas, NAME_X, row, system.format(rest_buffer[:], "and ", u64(hostile_count - shown), " cases more: the window has no line for them"), graphics.colors.dim)
	}
	// The measures.
	y = measures_y
	card(canvas, CARD_X, y, CARD_WIDTH, MEASURES_HEIGHT, "nanoseconds for one call of sum_values", "rows of 40 bytes, the least of several runs", graphics.colors.memory)
	row = y + 40
	graphics.text(canvas, NAME_X, row, "the way", graphics.colors.dim)
	sizes := SIZES
	buffer: [24]u8
	for size, column in sizes {
		graphics.text(canvas, ANSWER_X + 16 + column * 160, row, system.format(buffer[:], u64(size), " rows"), graphics.colors.dim)
	}
	row += LINE
	for way in Measure_Way {
		graphics.text(canvas, NAME_X, row, measure_names[way], graphics.colors.text)
		for column in 0 ..< 3 {
			value := measures[way][column]
			graphics.text(canvas, ANSWER_X + 16 + column * 160, row, value == 0 ? "does not fit" : system.format(buffer[:], value), value == 0 ? graphics.colors.dim : graphics.colors.text)
		}
		row += LINE
	}
}

// The random generator of this process: it gives the seed of each call
// host that this process starts.
process_generator: random.Generator

// The entry of tables: it prepares the three ways, runs the cases, the
// hostile cases and the measures once, then shows the result for ever.
//
// With no seed or no window it stops with the code 1. It loads `sample`
// here (the direct way), starts a call host of it (the second way), and
// connects to the service `sample` (the third way); a way that fails is
// marked refused and the process goes on. It does the same for
// `hostile_exports`, with no service. Then it fills a table of 65536
// readings for the measures, runs everything, and writes the result.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		system.log(.Info, "tables: no random seed in the context")
		system.stop(1)
	}
	window, opened := display.open(ctx, WIDTH, HEIGHT, "tables")
	if !opened {
		system.stop(1)
	}
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Ok {
		image = ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	}
	sample_file = system.image_find(image, "sample")

	// The direct way: the module in this process.
	space = {source = {image = image}, next = op.MODULE_BASE}
	load_error: module.Load_Error
	if place, loaded := system.module_space_load(&space, sample_file, &load_error); loaded {
		sample_base = space.modules[place].base
		ways_ready[.Direct] = true
	}
	// The call host: the module in a process of its own.
	status: system.Status
	if host, status = system.call_host_start(image, image_memory, sample_file, "sample host", random.values_with_seed(&process_generator, {}), &load_error); status == .Ok {
		ways_ready[.Call_Host] = true
	} else {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		system.load_error_text(&writer, &load_error)
		system.log(.Info, "tables: the call host did not start: status ", u64(status), "; ", system.written(&writer))
	}
	// The service: the root service starts sample as a process.
	if ring_handle := ctx.handles[system.GRANT_ROOT]; ring_handle != 0 {
		if requests, status = system.ring_open(ring_handle); status == .Ok {
			if service, status = system.service_connection(&requests, 1, "sample"); status == .Ok {
				ways_ready[.Service] = true
			}
		}
	}
	// The exports that are wrong on purpose: in this process, and in a call host.
	hostile_file = system.image_find(image, "hostile_exports")
	if place, loaded := system.module_space_load(&space, hostile_file, &load_error); loaded {
		hostile_base = space.modules[place].base
		hostile_ready[.Direct] = true
	}
	if hostile_host, status = system.call_host_start(image, image_memory, hostile_file, "hostile host", random.values_with_seed(&process_generator, {}), &load_error); status == .Ok {
		hostile_ready[.Call_Host] = true
	}
	system.log(.Info, "tables: the ways: direct ", ways_ready[.Direct] ? "ready" : "refused", ", call host ", ways_ready[.Call_Host] ? "ready" : "refused", ", service ", ways_ready[.Service] ? "ready" : "refused")

	// The table of the measures: 65536 readings in a memory object.
	pages := u64(LARGE_COUNT * size_of(Reading) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	if large_memory, status = system.memory_create(pages); status == .Ok {
		if address, map_status := system.memory_map(large_memory); map_status == .Ok {
			large = ([^]Reading)(address)[:LARGE_COUNT]
			for &reading, index in large {
				reading = {sensor = i64(index), value = i64(index)}
			}
		}
	}

	run_cases()
	run_hostile()
	if len(large) != 0 {
		measure()
	}
	wrong := 0
	for &item in cases[:case_count] {
		for way in Way {
			if !item.answers[way].right {
				wrong += 1
				system.log(.Info, "tables: wrong answer: ", item.name, ", ", way_names[way], ": ", answer_text(&item.answers[way]))
			}
		}
	}
	for &item in hostile[:hostile_count] {
		if !item.answer.right {
			wrong += 1
			system.log(.Info, "tables: wrong answer: ", item.name, ": ", answer_text(&item.answer))
		}
	}
	for &item in hostile[:hostile_count] {
		system.log(.Info, "tables: ", item.name, ": ", answer_text(&item.answer))
	}
	for way in Measure_Way {
		system.log(.Info, "tables: sum_values, ", measure_names[way], ": ", measures[way][0], " ns for 64 rows, ", measures[way][1], " ns for 1024 rows, ", measures[way][2], " ns for 65536 rows (0: refused)")
	}
	if wrong == 0 {
		system.log(.Info, "tables: ok, ", u64(case_count), " cases in 3 ways and ", u64(hostile_count), " hostile cases")
	}

	for {
		// The canvas is the picture that the compositor does not read,
		// after it took the picture before: the whole canvas is drawn.
		if display.canvas_wait(&window) {
			draw(window.canvas)
			display.present(&window)
		}
		display.wait(&window)
		for _ in display.next_event(&window) {
		}
	}
}
