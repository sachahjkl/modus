// Tables and bytes as parameters: one description, three ways to call. The
// design: docs/MODULE_CONTRACT.md, "Tables and bytes as parameters".
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
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:layout"
import "modus:random"
import "modus:system"

LARGE_TABLE_PAGES :: 640
#assert(LARGE_TABLE_PAGES == (LARGE_COUNT * size_of(Reading) + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
CALL_HOST_BUDGET_PAGES :: 512
#assert(CALL_HOST_BUDGET_PAGES == system.CALL_HOST_PAGES)
// The 65536-reading table allocated before ready.
MODULE_START_OBJECTS :: [?]system.Start_Object{LARGE_TABLE_PAGES}
// The two call hosts (sample and hostile_exports) started before ready.
MODULE_START_BUDGETS :: [?]system.Start_Budget{CALL_HOST_BUDGET_PAGES, CALL_HOST_BUDGET_PAGES}
// Itself and two call hosts; the tool counts the module, its threads, its
// window at the largest scale, its start objects and its child budgets.
MODULE_BUDGET :: system.Stated_Budget{processes = 3, threads = 3, window_width = WIDTH, window_height = HEIGHT}

// Plan value: draw table record and text capacities, sized for the three cards,
// all case rows, and long error sentences with headroom.
window_memory: interface.Window_Memory(1024, 16384)
// The layout tree of one frame (modus:layout). Lives in module memory, never on stack.
tables_layout_tree: layout.Box_Tree

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
call_hostile :: proc "contextless" (way: Way, name: string, arguments: []isolated.Argument) -> (result: i64, outcome: call_outcome.Call_Outcome) {
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
		return 0, .Operation_Unsupported
	}
	return 0, .Operation_Unsupported
}

// call runs one export with the same arguments in one way.
call :: proc "contextless" (way: Way, name: string, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (result: i64, outcome: call_outcome.Call_Outcome) {
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
		result, outcome := call(way, "sum_values", arguments[:1])
		answer_set(&sum.answers[way], outcome == .Succeeded && result == 100, result)

		readings_four(&memory)
		arguments[0].table = {records = bytes_of(&memory, 4 * 40), count = 4}
		arguments[1] = {integer = 3}
		result, outcome = call(way, "scale_values", arguments[:2])
		answer_set(&scale.answers[way], outcome == .Succeeded && result == 4 && memory[3].value == 120 && memory[0].maximum == 30 && memory[4] == {}, result, " rows; row 4: ", memory[3].value)

		// 8 places: the table has a capacity of 6, then a guard of 2 records.
		readings_four(&memory)
		guard_fill(bytes_of(&memory[6], 2 * 40))
		arguments[0] = {integer = 5}
		arguments[1] = {integer = 100}
		arguments[2].table = {records = bytes_of(&memory, 6 * 40), count = 2}
		result, outcome = call(way, "append_readings", arguments[:3])
		answer_set(&appended.answers[way], outcome == .Succeeded && result == 4 && arguments[2].table.count == 7 && memory[2].value == 100 && memory[5].value == 103 && memory[1].value == 20 && guard_holds(bytes_of(&memory[6], 80)), result, " written, count ", arguments[2].table.count)

		arguments[2].table = {count = 0}
		arguments[0] = {integer = 3}
		result, outcome = call(way, "append_readings", arguments[:3])
		answer_set(&empty.answers[way], outcome == .Succeeded && result == 0 && arguments[2].table.count == 3, result, " written, count ", arguments[2].table.count)

		text := "tables go in"
		list := [3]Word{{0, 6, 0}, {7, 2, 0}, {10, 2, 0}}
		arguments[0].table = {records = bytes_of(&list, size_of(list)), count = 3}
		arguments[1] = {}
		arguments[1].table = {records = transmute([]u8)text, count = u64(len(text))}
		error: errors.Error_Record
		result, outcome = call(way, "sum_words", arguments[:2], &error)
		answer_set(&words.answers[way], outcome == .Succeeded && result == 1064 && list[0].sum == 635 && list[1].sum == 214, result, "; words ", list[0].sum, " ", list[1].sum, " ", list[2].sum)

		list[1] = {7, 9, 0}
		error = {}
		result, outcome = call(way, "sum_words", arguments[:2], &error)
		// The first word holds its sum: a change that the outcome states.
		answer_set(&outside.answers[way], outcome == .Stopped_After_A_Partial_Change && result == 0 && errors.Kind(error.kind) == .Out_Of_Range && error.found == 2 && error.value == 16 && error.limit == 12, "Out_Of_Range: word ", error.found, ", ", error.value)

		changed: [12]u8
		copy(changed[:], "tables go in")
		arguments[0] = {}
		arguments[0].table = {records = changed[:], count = 12}
		result, outcome = call(way, "upper_case", arguments[:1])
		answer_set(&upper.answers[way], outcome == .Succeeded && result == 10 && string(changed[:]) == "TABLES GO IN", result, " letters: ", string(changed[:]))

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
		result, outcome = call_hostile(way, "append_past_capacity", arguments[:1])
		holds := guard_holds(bytes_of(&memory[2], 6 * 40))
		answer_set(&past.answers[way], way == .Direct ? !holds : holds && outcome == .Succeeded, holds ? "the guard holds" : "guard written: one space")
	}
}

// The hostile cases, through the call host. A case whose answer is an error
// record keeps the record: its log fact writes the fields of the record.
Hostile :: struct {
	name:         string,
	answer:       Answer,
	refusal_case: Refusal_Case,
	refusal:      errors.Error_Record,
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
// hostile caller does, and gives the outcome of the completion and its
// record, through the border of the completion.
raw_call :: proc "contextless" (connection: ^system.Call_Connection, export: u32, size: u64) -> (outcome: call_outcome.Call_Outcome, refusal: errors.Error_Record) {
	connection.tag += 1
	system.send(&connection.calls.commands, ring.Record{kind = export, tag = connection.tag, values = {0 = 0, 1 = size}})
	for {
		wait := system.wait_begin()
		for record in system.receive(&connection.calls.completions) {
			if record.tag == connection.tag {
				_, outcome, refusal = isolated.answer_of_completion(record)
				return outcome, refusal
			}
		}
		if state, _, _ := system.process_state(connection.process); state == .Stopped {
			return .Callee_Stopped_During_The_Call, {}
		}
		system.wait_records(&wait, &connection.calls.completions)
		system.wait_end(&wait)
	}
}

// refusal_add adds a case whose answer is the sentence of an error record.
refusal_add :: proc "contextless" (name: string, right: bool, refusal: ^errors.Error_Record, export: string, parameter: string, refusal_case: Refusal_Case) {
	buffer: [ANSWER_SIZE]u8
	writer := system.Writer{buffer = buffer[:]}
	system.error_text(&writer, refusal, export, parameter)
	hostile_add(name, right, system.written(&writer))
	hostile[hostile_count - 1].refusal_case = refusal_case
	hostile[hostile_count - 1].refusal = refusal^
}

run_hostile :: proc "contextless" () {
	if !ways_ready[.Call_Host] {
		hostile_add("the hostile cases", false, "no call host")
		return
	}
	index, function, _ := export_of("sum_values")
	arguments := [2]isolated.Argument{}
	arguments[0].table = {records = bytes_of(raw_data(large), LARGE_COUNT * 40), count = LARGE_COUNT}
	room_refusal: errors.Error_Record
	_, room_outcome := system.call_isolated(&host, sample_file, index, arguments[:1], &room_refusal)
	missing := isolated.room_missing(sample_file, function, arguments[:1], u64(len(host.region)))
	hostile_add("65536 rows in the call region", room_outcome == .Argument_Refused && errors.Kind(room_refusal.kind) == .Too_Long && missing.needed == LARGE_COUNT * 40, "refused: ", missing.needed, " bytes, ", missing.free, " free")

	arguments[0].table.memory_handle = u64(large_memory)
	result, lent_outcome := system.call_isolated(&host, sample_file, index, arguments[:1])
	expected := i64(LARGE_COUNT) * (LARGE_COUNT - 1) / 2
	hostile_add("the same rows in a lent memory object", lent_outcome == .Succeeded && result == expected, result)

	// The service refuses a table in a memory object: the caller could
	// revoke it while the export runs, and stop the service for each caller.
	if ways_ready[.Service] {
		arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory_handle = u64(large_memory)}
		refusal: errors.Error_Record
		_, service_outcome := system.call_isolated(&service, sample_file, index, arguments[:1], &refusal, true)
		refusal_add("a memory object to the service", service_outcome == .Argument_Refused && refusal.argument == 1, &refusal, "sum_values", "readings", .Memory_Object_To_Service)
	}

	// A Change table in a memory object that this process lends with Read
	// only: the receiver proves the rights of the direction.
	scale_index, scale_function, _ := export_of("scale_values")
	copy_handle, give_status := system.give(0, large_memory, {.Read, .Give})
	receiver: system.Handle
	if give_status == .Succeeded {
		receiver, give_status = system.give(host.ring_memory, copy_handle, {.Read})
	}
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory_handle = u64(receiver)}
	arguments[1] = {integer = 2}
	_, size, _, encoded := isolated.encode(sample_file, scale_function, arguments[:2], host.region)
	refused := call_outcome.Call_Outcome.Succeeded
	refusal: errors.Error_Record
	if encoded && give_status == .Succeeded {
		refused, refusal = raw_call(&host, scale_index, size)
	}
	system.handle_revoke(copy_handle)
	system.close(copy_handle)
	hostile_add("a Change table lent with Read only", refused == .Grant_Or_Right_Missing && errors.Kind(refusal.kind) == .Handle_Rights && large[63].value == 63, "Handle_Rights; rows unchanged")

	// A budget lent as the memory of a table: the receiver checks the kind
	// of the object: a table names a memory object, and no other kind.
	budget_copy, budget_status := system.give(0, system.own_budget(), {.Read, .Give})
	if budget_status == .Succeeded {
		receiver, budget_status = system.give(host.ring_memory, budget_copy, {.Read})
	}
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64, memory_handle = u64(receiver)}
	_, size, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	refused, refusal = .Succeeded, {}
	if encoded && budget_status == .Succeeded {
		refused, refusal = raw_call(&host, index, size)
	}
	system.handle_revoke(budget_copy)
	system.close(budget_copy)
	refusal_add("a budget as the memory of a table", refused == .Argument_Refused && errors.Kind(refusal.kind) == .Handle_Kind, &refusal, "sum_values", "readings", .Budget_As_Table_Memory)

	// A count larger than the call region, written by hand: the refusal is
	// an error record, so that the caller learns which argument and why.
	arguments[0].table = {records = bytes_of(raw_data(large), 64 * 40), count = 64}
	_, size, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	field := (^isolated.Table_Field)(raw_data(host.region))
	field.count = 1 << 40
	refused, refusal = .Succeeded, {}
	if encoded {
		refused, refusal = raw_call(&host, index, size)
	}
	refusal_add("a count of 2^40 rows", refused == .Argument_Refused && errors.Kind(refusal.kind) == .Too_Long && refusal.argument == 1, &refusal, "sum_values", "readings", .Count_Past_Its_Bound)

	// A start that wraps.
	_, size, _, encoded = isolated.encode(sample_file, function, arguments[:1], host.region)
	field.start = max(u64) - 7
	refused, refusal = .Succeeded, {}
	if encoded {
		refused, refusal = raw_call(&host, index, size)
	}
	refusal_add("a start that wraps", refused == .Argument_Refused && errors.Kind(refusal.kind) == .Out_Of_Range && refusal.argument == 1, &refusal, "sum_values", "readings", .Start_That_Wraps)

	// A direct call of an export with a Table result: call_direct does not
	// do it, and says so with Operation_Unsupported: else it gives the
	// address of the error record where the export reads its buffer.
	readings_index, readings_function, readings_address := export_of("readings")
	arguments[0] = {integer = 4}
	direct_refusal: errors.Error_Record
	_, direct_outcome := system.call_direct(sample_file, readings_address, readings_function, arguments[:1], &direct_refusal)
	hostile_add("call_direct of a Table result", direct_outcome == .Operation_Unsupported && errors.Kind(direct_refusal.kind) == .Unsupported && readings_index != 0, "Operation_Unsupported: the result is not an Integer")
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
					result, outcome := system.call_isolated(connection, sample_file, index, arguments[:], nil, way == .Memory_Object)
					intrinsics.volatile_store(&sink, result)
					if outcome != .Succeeded && ok {
						system.log_fact(.Info, Measure_Call_Refused{rows = u64(size), call = u64(call_number), outcome = call_outcome.Call_Outcome_Word(outcome), way = value_kinds.text_field(measure_names[way], MEASURE_WAY_FIELD_BYTES)})
					}
					ok &&= outcome == .Succeeded
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

// Plan value: nominal logical dimensions of the tables demonstration window.
WIDTH :: 1000
HEIGHT :: 704
// Plan value: height of one case row (16 px text plus 4 px spacing).
LINE :: 20
// Plan value: card header (40 px title) plus bottom padding (8 px).
CARD_HEAD :: graphics.TITLE + graphics.GAP
// Plan value: status mark square size and horizontal advance before the text.
MARK_SIZE :: 8
MARK_OFFSET :: 16
// Plan value: fixed widths and minimum widths of the three cards' columns inside
// their content area (936 px at nominal width).
CASES_NAME_COLUMN :: 276
CASES_ANSWER_COLUMN_LEAST :: 160
// Fits the 16 px mark plus the longest hostile case name (36 cells) plus padding.
HOSTILE_NAME_COLUMN :: MARK_OFFSET + 38 * graphics.CELL_WIDTH + graphics.GAP
HOSTILE_ANSWER_COLUMN_LEAST :: 160
MEASURES_NAME_COLUMN :: 296
MEASURES_VALUE_COLUMN_LEAST :: 120
// Computed: height of the measures card (header plus column row and four ways).
MEASURES_HEIGHT :: CARD_HEAD + 5 * LINE

CASES_COLUMN_COUNT :: 1 + len(Way)
HOSTILE_COLUMN_COUNT :: 2
MEASURES_COLUMN_COUNT :: 1 + len(SIZES)

Tables_Places :: struct {
	cases_card:       interface.Area,
	hostile_card:     interface.Area,
	measures_card:    interface.Area,
	cases_content:    interface.Area,
	hostile_content:  interface.Area,
	measures_content: interface.Area,
	cases_columns:    [CASES_COLUMN_COUNT]layout.Table_Column_Place,
	hostile_columns:  [HOSTILE_COLUMN_COUNT]layout.Table_Column_Place,
	measures_columns: [MEASURES_COLUMN_COUNT]layout.Table_Column_Place,
}

@(private = "file")
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

@(private = "file")
card_content_of :: proc "contextless" (area: interface.Area) -> interface.Area {
	return {
		x      = area.x + graphics.MARGIN,
		y      = area.y + graphics.TITLE,
		width  = max(area.width - 2 * graphics.MARGIN, 0),
		height = max(area.height - graphics.TITLE - graphics.GAP, 0),
	}
}

// tables_layout computes the three stacked cards and their column places with
// modus:layout.
tables_layout :: proc "contextless" (tree: ^layout.Box_Tree, width, height, cases_height, hostile_height: int) -> (places: Tables_Places, ok: bool) {
	if tree == nil || width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT || cases_height < 0 || cases_height > layout.LENGTH_LIMIT || hostile_height < 0 || hostile_height > layout.LENGTH_LIMIT {
		return {}, false
	}
	margin := i32(graphics.MARGIN)
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y, padding = {.X = margin, .Y = margin}, gap = margin}) != .Done {
		return {}, false
	}
	cases_box, s0 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(i32(cases_height))}})
	_, s1 := layout.box_open(tree, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, overflow = {.X = .Visible, .Y = .Clip}})
	hostile_box, s2 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(i32(hostile_height), 0)}})
	sc0 := layout.box_close(tree)
	measures_box, s3 := layout.box_add(tree, {size = {.X = layout.fill(), .Y = layout.px(MEASURES_HEIGHT)}})
	if s0 != .Done || s1 != .Done || s2 != .Done || sc0 != .Done || s3 != .Done || layout.solve(tree) != .Done {
		return {}, false
	}

	places.cases_card = area_of(tree, cases_box)
	places.hostile_card = area_of(tree, hostile_box)
	places.measures_card = area_of(tree, measures_box)
	places.cases_content = card_content_of(places.cases_card)
	places.hostile_content = card_content_of(places.hostile_card)
	places.measures_content = card_content_of(places.measures_card)

	cases_spec := [CASES_COLUMN_COUNT]layout.Table_Column {
		{width = CASES_NAME_COLUMN},
		{weight = 1, least = CASES_ANSWER_COLUMN_LEAST},
		{weight = 1, least = CASES_ANSWER_COLUMN_LEAST},
		{weight = 1, least = CASES_ANSWER_COLUMN_LEAST},
	}
	cases_rect := layout.Rect{i32(places.cases_content.x), i32(places.cases_content.y), i32(places.cases_content.width), i32(places.cases_content.height)}
	if layout.table_columns(cases_spec[:], places.cases_columns[:], cases_rect, 0) != .Done {
		return {}, false
	}

	hostile_spec := [HOSTILE_COLUMN_COUNT]layout.Table_Column {
		{width = HOSTILE_NAME_COLUMN},
		{weight = 1, least = HOSTILE_ANSWER_COLUMN_LEAST},
	}
	hostile_rect := layout.Rect{i32(places.hostile_content.x), i32(places.hostile_content.y), i32(places.hostile_content.width), i32(places.hostile_content.height)}
	if layout.table_columns(hostile_spec[:], places.hostile_columns[:], hostile_rect, 0) != .Done {
		return {}, false
	}

	measures_spec := [MEASURES_COLUMN_COUNT]layout.Table_Column {
		{width = MEASURES_NAME_COLUMN},
		{weight = 1, least = MEASURES_VALUE_COLUMN_LEAST},
		{weight = 1, least = MEASURES_VALUE_COLUMN_LEAST},
		{weight = 1, least = MEASURES_VALUE_COLUMN_LEAST},
	}
	measures_rect := layout.Rect{i32(places.measures_content.x), i32(places.measures_content.y), i32(places.measures_content.width), i32(places.measures_content.height)}
	if layout.table_columns(measures_spec[:], places.measures_columns[:], measures_rect, 0) != .Done {
		return {}, false
	}

	return places, true
}

// line_count gives the lines of a text in a box, at least one.
line_count :: proc "contextless" (table: ^interface.Draw_Table, text: string, room: int) -> int {
	return max(interface.text_wrapped_line_count(table, {}, text, room), 1)
}

// row_height gives the height of a row whose longest text has `lines` lines.
row_height :: proc "contextless" (lines: int) -> int {
	return LINE + (lines - 1) * interface.line_height({})
}

// case_row_lines gives the lines of the row of a case: its longest answer.
case_row_lines :: proc "contextless" (table: ^interface.Draw_Table, item: ^Case, answer_room: int) -> (lines: int) {
	lines = 1
	for way in Way {
		lines = max(lines, line_count(table, answer_text(&item.answers[way]), answer_room))
	}
	return lines
}

draw :: proc "contextless" (window: ^display.Window) {
	frame := interface.window_frame_start(&window_memory, window)
	table := frame.table
	width, height := window.width, window.height
	interface.background(&frame, {0, 0, width, height})

	// Match the column widths that tables_layout assigns so wrapped row heights
	// agree with the drawn boxes.
	content_width := max(width - 4 * graphics.MARGIN, 0)
	answer_column_width := max((content_width - CASES_NAME_COLUMN) / len(Way), CASES_ANSWER_COLUMN_LEAST)
	answer_room := max(answer_column_width - MARK_OFFSET - graphics.GAP, graphics.CELL_WIDTH)
	hostile_answer_room := max(content_width - HOSTILE_NAME_COLUMN, HOSTILE_ANSWER_COLUMN_LEAST)

	// The cases: one row for each, one column for each way. An answer has
	// the box of its column, and a row the height of its longest answer:
	// the card is as high as its rows.
	cases_height := CARD_HEAD + LINE
	for &item in cases[:case_count] {
		cases_height += row_height(case_row_lines(table, &item, answer_room))
	}

	// The hostile cases, with their answers: the sentence of an error
	// record, whole. The card of the measures is at the bottom of the
	// window, and this card has the room between the two: it shows the
	// cases that fit, and counts the others on its last line.
	room := max(height - 4 * graphics.MARGIN - cases_height - MEASURES_HEIGHT - CARD_HEAD, 0)
	shown, rows_height := 0, 0
	for &item in hostile[:hostile_count] {
		next := row_height(line_count(table, answer_text(&item.answer), hostile_answer_room))
		kept := shown == hostile_count - 1 ? 0 : LINE // The line of the count, when a case is left.
		if rows_height + next > room - kept {
			break
		}
		rows_height += next
		shown += 1
	}
	hostile_height := CARD_HEAD + rows_height + (shown < hostile_count ? LINE : 0)

	if places, layout_ok := tables_layout(&tables_layout_tree, width, height, cases_height, hostile_height); layout_ok {
		// Card 1: one description, three ways to call.
		cases_inside := interface.card(&frame, places.cases_card, "one description, three ways to call", "module sample, the same arguments", graphics.colors.kernel)
		y := cases_inside.y
		interface.draw_text(table, int(places.cases_columns[0].x), y, "export  table", graphics.colors.dim, interface.FONT_INTERFACE)
		for way in Way {
			interface.draw_text(table, int(places.cases_columns[1 + int(way)].x), y, way_names[way], graphics.colors.dim, interface.FONT_INTERFACE)
		}
		y += LINE
		for &item in cases[:case_count] {
			interface.draw_text(table, int(places.cases_columns[0].x), y, item.name, graphics.colors.text)
			for way in Way {
				answer := &item.answers[way]
				col := places.cases_columns[1 + int(way)]
				x := int(col.x)
				col_room := max(int(col.width) - MARK_OFFSET - graphics.GAP, graphics.CELL_WIDTH)
				interface.mark(&frame, x, y + 4, MARK_SIZE, answer.right ? graphics.colors.process : graphics.colors.failed)
				interface.draw_text_wrapped(table, x + MARK_OFFSET, y, col_room, answer_text(answer), answer.right ? graphics.colors.text : graphics.colors.failed)
			}
			y += row_height(case_row_lines(table, &item, answer_room))
		}

		// Card 2: a hostile caller, through the call host.
		hostile_inside := interface.card(&frame, places.hostile_card, "a hostile caller, through the call host", "isolated.decode, export_serve", graphics.colors.failed)
		row := hostile_inside.y
		hostile_x := int(places.hostile_columns[0].x)
		hostile_ans_x := int(places.hostile_columns[1].x)
		hostile_ans_room := max(int(places.hostile_columns[1].width), graphics.CELL_WIDTH)
		for &item in hostile[:shown] {
			interface.mark(&frame, hostile_x, row + 4, MARK_SIZE, item.answer.right ? graphics.colors.process : graphics.colors.failed)
			interface.draw_text(table, hostile_x + MARK_OFFSET, row, item.name, graphics.colors.text)
			lines := max(interface.draw_text_wrapped(table, hostile_ans_x, row, hostile_ans_room, answer_text(&item.answer), item.answer.right ? graphics.colors.text : graphics.colors.failed), 1)
			row += row_height(lines)
		}
		if shown < hostile_count {
			rest_buffer: [64]u8
			interface.draw_text(table, hostile_x, row, system.format(rest_buffer[:], "and ", u64(hostile_count - shown), " cases more: the window has no line for them"), graphics.colors.dim, interface.FONT_INTERFACE)
		}

		// Card 3: nanoseconds for one call of sum_values.
		measures_inside := interface.card(&frame, places.measures_card, "nanoseconds for one call of sum_values", "rows of 40 bytes, the least of several runs", graphics.colors.memory)
		row = measures_inside.y
		interface.draw_text(table, int(places.measures_columns[0].x), row, "the way", graphics.colors.dim, interface.FONT_INTERFACE)
		sizes := SIZES
		buffer: [24]u8
		for size, column in sizes {
			interface.draw_text(table, int(places.measures_columns[1 + column].x), row, system.format(buffer[:], u64(size), " rows"), graphics.colors.dim, interface.FONT_INTERFACE)
		}
		row += LINE
		for way in Measure_Way {
			interface.draw_text(table, int(places.measures_columns[0].x), row, measure_names[way], graphics.colors.text, interface.FONT_INTERFACE)
			for column in 0 ..< len(SIZES) {
				value := measures[way][column]
				interface.draw_text(table, int(places.measures_columns[1 + column].x), row, value == 0 ? "does not fit" : system.format(buffer[:], value), value == 0 ? graphics.colors.dim : graphics.colors.text)
			}
			row += LINE
		}
	}

	interface.window_frame_end(&window_memory.drawing, &frame, window)
}

// The random generator of this process: it gives the seed of each call
// host that this process starts.
process_generator: random.Generator

// The entry of tables: it prepares the three ways, runs the cases, the
// hostile cases and the measures once, then shows the result for ever.
//
// With no seed it stops with `Refused`, with no window with `Failed`. It loads `sample`
// here (the direct way), starts a call host of it (the second way), and
// connects to the service `sample` (the third way); a way that fails is
// marked refused and the process goes on. It does the same for
// `hostile_exports`, with no service. Then it fills a table of 65536
// readings for the measures, runs everything, and writes the result.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	if !random.generator_from_context(&process_generator, ctx) {
		system.log_fact(.Info, No_Random_Seed{})
		system.stop(.Refused)
	}
	window, opened := display.open(ctx, WIDTH, HEIGHT, "tables")
	if !opened {
		system.stop(.Failed)
	}
	image_memory = ctx.handles[system.GRANT_IMAGE]
	if address, status := system.memory_map(image_memory, {}); status == .Succeeded {
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
	status: call_outcome.Call_Outcome
	if host, status = system.call_host_start(image, image_memory, sample_file, "sample host", random.values_with_seed(&process_generator, {}), &load_error); status == .Succeeded {
		ways_ready[.Call_Host] = true
	} else {
		system.log_fact(.Info, Call_Host_Not_Started{status = call_outcome.Call_Outcome_Word(status)})
		call_host_load_error_log(&load_error)
	}
	// The service: the root service starts sample as a process.
	if ring_handle := ctx.handles[system.GRANT_ROOT]; ring_handle != 0 {
		if requests, status = system.ring_open(ring_handle, receive_handles = true); status == .Succeeded {
			connected: call_outcome.Call_Outcome
			service, connected = system.service_connection(&requests, 1, "sample")
			ways_ready[.Service] = connected == .Succeeded
		}
	}
	// The exports that are wrong on purpose: in this process, and in a call host.
	hostile_file = system.image_find(image, "hostile_exports")
	if place, loaded := system.module_space_load(&space, hostile_file, &load_error); loaded {
		hostile_base = space.modules[place].base
		hostile_ready[.Direct] = true
	}
	if hostile_host, status = system.call_host_start(image, image_memory, hostile_file, "hostile host", random.values_with_seed(&process_generator, {}), &load_error); status == .Succeeded {
		hostile_ready[.Call_Host] = true
	}
	system.log_fact(.Info, Ways_Ready{direct = way_state_field(ways_ready[.Direct]), call_host = way_state_field(ways_ready[.Call_Host]), service = way_state_field(ways_ready[.Service])})

	// The table of the measures: 65536 readings in a memory object.
	pages := u64(LARGE_COUNT * size_of(Reading) + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	if large_memory, status = system.memory_create(pages); status == .Succeeded {
		if address, map_status := system.memory_map(large_memory); map_status == .Succeeded {
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
				system.log_fact(.Info, Answer_Wrong{case_name = case_field(item.name), call_way = value_kinds.text_field(way_names[way], WAY_FIELD_BYTES), answer = answer_field(&item.answers[way])})
			}
		}
	}
	for &item in hostile[:hostile_count] {
		if !item.answer.right {
			wrong += 1
			hostile_log(&item, true)
		}
	}
	for &item in hostile[:hostile_count] {
		hostile_log(&item, false)
	}
	for way in Measure_Way {
		system.log_fact(.Info, Sum_Values_Measured{small_table = value_kinds.Time_In_Nanoseconds(measures[way][0]), medium_table = value_kinds.Time_In_Nanoseconds(measures[way][1]), large_table = value_kinds.Time_In_Nanoseconds(measures[way][2]), way = value_kinds.text_field(measure_names[way], MEASURE_WAY_FIELD_BYTES)})
	}
	if wrong == 0 {
		system.log_fact(.Info, Cases_Passed{cases = u64(case_count), hostile_cases = u64(hostile_count)})
	}

	for {
		draw(&window)
		deadline: u64 = system.WAIT_FOREVER
		if wake, due := interface.window_scroll_bar_wake(&window_memory.drawing); due {
			deadline = wake
		}
		display.wait(&window, deadline)
		interface.window_events(&window_memory.drawing, &window)
	}
}
