#+build !freestanding
package disk_processes_core

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/errors"
import rd "modus:contract/root_delegation"
import "modus:disk_process"

// The tests drive the machine as the shell of the service does, against a
// store of the test, and check each event at the border of the core, as
// the core reads it (rd.event_report_check and rd.start_from_bytes_check).
// A module file of the test is the byte 'M', a count, then that many
// hashes of imports; a hash whose first byte is IMAGE_TAG is a module of
// the boot image.

@(private = "file")
IMAGE_TAG :: 0xB0

@(private = "file")
READ_CHUNK :: 1000 // The most bytes of one answer of the store of the test.

@(private = "file")
test_image_holds :: proc "contextless" (hash: blake3.Hash) -> bool {
	return hash[0] == IMAGE_TAG
}

@(private = "file")
test_imports_walk :: proc "contextless" (file: []u8, machine: ^Machine) {
	if len(file) < 2 || file[0] != 'M' {
		return
	}
	count := int(file[1])
	for index in 0 ..< count {
		start := 2 + index * 32
		if start + 32 > len(file) {
			return
		}
		hash: blake3.Hash
		copy(hash[:], file[start:][:32])
		want_import(machine, hash)
	}
}

// module_file makes a module file of the test that imports hashes, with
// filler bytes so that its read takes more than one answer.
@(private = "file")
module_file :: proc(imports: []blake3.Hash, filler: int = 2500, tag: u8 = 0) -> []u8 {
	file := make([]u8, 2 + 32 * len(imports) + filler, context.temp_allocator)
	file[0] = 'M'
	file[1] = u8(len(imports))
	for &hash, index in imports {
		copy(file[2 + index * 32:], hash[:])
	}
	for index in 2 + 32 * len(imports) ..< len(file) {
		file[index] = u8(index) ~ tag
	}
	return file
}

@(private = "file")
image_hash :: proc(tag: u8) -> (hash: blake3.Hash) {
	hash[0] = IMAGE_TAG
	hash[1] = tag
	return hash
}

@(private = "file")
Store_Entry :: struct {
	name:  string,
	bytes: []u8,
	class: Entry_Class,
}

// The store of the test. hostile changes one answer: it gives true when
// it wrote the answer itself.
@(private = "file")
Store :: struct {
	entries: []Store_Entry,
	hostile: proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool,
	calls:   int,
	rows:    [LIST_PAGE_ROWS]List_Row,
	names:   [LIST_NAME_BYTES]u8,
}

@(private = "file")
store_find :: proc(store: ^Store, name: string) -> ^Store_Entry {
	for &entry in store.entries {
		if entry.name == name && entry.class == .Object {
			return &entry
		}
	}
	return nil
}

@(private = "file")
store_answer :: proc(store: ^Store, action: Action) -> (answer: Storage_Answer) {
	store.calls += 1
	if store.hostile != nil && store.hostile(action, &answer, store.calls) {
		return answer
	}
	#partial switch action.kind {
	case .Ask_Size:
		entry := store_find(store, action.name)
		if entry == nil {
			return {kind = .Absent}
		}
		return {kind = .Value, value = i64(len(entry.bytes))}
	case .Ask_Read:
		entry := store_find(store, action.name)
		if entry == nil {
			return {kind = .Absent}
		}
		rest := entry.bytes[min(int(action.offset), len(entry.bytes)):]
		text := rest[:min(len(rest), READ_CHUNK)]
		return {kind = .Value, value = i64(len(text)), text = text}
	case .Ask_List:
		count := 0
		used := 0
		started := action.name == ""
		for &entry in store.entries {
			if !started {
				started = entry.name == action.name
				continue
			}
			if count == LIST_PAGE_ROWS {
				break
			}
			store.rows[count] = {name_offset = i64(used), name_count = i64(len(entry.name)), class = entry.class, size = i64(len(entry.bytes))}
			used += copy(store.names[used:], entry.name)
			count += 1
		}
		return {kind = .Value, value = i64(count), rows = store.rows[:], names = store.names[:]}
	}
	return {kind = .Not_Allowed}
}

// One event as the core took it.
@(private = "file")
Seen :: struct {
	event:  rd.Disk_Load_Event,
	report: rd.Event_Report,
}

// The run of one load: the events that the core took, the bytes of the
// module that it lent, and the hash that it computed on each kept file.
@(private = "file")
Run :: struct {
	events:      [dynamic]Seen,
	module:      []u8,
	kept_hashes: [dynamic]blake3.Hash,
	border_ok:   bool, // Each event passed the border of the core.
	ended:       bool,
}

@(private = "file")
request_of :: proc(nickname: string, hash: blake3.Hash, replacements: []blake3.Hash = nil) -> (request: rd.Load_Request) {
	request.principal = 3
	request.module_hash = hash
	request.nickname_length = u8(copy(request.nickname[:], nickname))
	request.storage_module_length = u8(copy(request.storage_module[:], "storage"))
	for index := 0; index + 1 < len(replacements); index += 2 {
		request.replacements[request.replacement_count] = {from = replacements[index], to = replacements[index + 1]}
		request.replacement_count += 1
	}
	return request
}

@(private = "file")
machine_make :: proc() -> (machine: Machine) {
	machine_init(&machine, {image_holds = test_image_holds, imports_walk = test_imports_walk})
	return machine
}

// run drives one load to its end as the shell and the core do. Each event
// is checked at the border of the core with the step that the core holds.
@(private = "file")
run :: proc(machine: ^Machine, store: ^Store, request: ^rd.Load_Request, lend_short: bool = false) -> (result: Run) {
	result.events = make([dynamic]Seen, context.temp_allocator)
	result.kept_hashes = make([dynamic]blake3.Hash, context.temp_allocator)
	result.border_ok = true
	step := rd.Disk_Load_Step.Module_Asked
	candidate: []u8
	action := load_begin(machine, request)
	for _ in 0 ..< 100_000 {
		switch action.kind {
		case .Wait_Command:
			return result
		case .Ask_Size, .Ask_Read, .Ask_List:
			answer := store_answer(store, action)
			action = storage_answered(machine, &answer)
			continue
		case .Send_Event:
		}
		report := machine.report
		append(&result.events, Seen{event = action.event, report = report})
		if !rd.event_report_check(step, action.event, &report, len(result.kept_hashes)) {
			result.border_ok = false
		}
		switch action.event {
		case .None, .Ready, .Refused, .Command_Refused:
			result.ended = true
			return result
		case .Memory_Wanted:
			size := int(report.byte_count)
			lent := make([]u8, lend_short ? size - 1 : size, context.temp_allocator)
			if report.place == u32(rd.File_Place.Module) {
				result.module = lent
				step = .Module_Lent
			} else {
				candidate = lent
				step = .Candidate_Lent
			}
			action = memory_lent(machine, lent)
		case .Module_Filled:
			step = .Module_Checked
			action = continue_given(machine)
		case .Scan_Started, .Candidate_Dropped:
			step = .Scan
			action = continue_given(machine)
		case .Import_Found:
			append(&result.kept_hashes, blake3.hash(candidate))
			step = .Scan
			action = continue_given(machine)
		}
	}
	return result
}

@(private = "file")
last :: proc(result: ^Run) -> Seen {
	if len(result.events) == 0 {
		return {}
	}
	return result.events[len(result.events) - 1]
}

@(private = "file")
refusal_of :: proc(result: ^Run) -> rd.Disk_Load_Refusal {
	seen := last(result)
	if seen.event != .Refused {
		return .None
	}
	return rd.Disk_Load_Refusal(seen.report.refusal)
}

// A load whose imports the boot image holds reads the module file into the
// lent memory over several answers, and asks for its start with its bytes:
// the core takes the request.
@(test)
a_module_with_imports_of_the_boot_image_starts_with_no_scan :: proc(t: ^testing.T) {
	file := module_file({image_hash(1), image_hash(2)})
	entries := [?]Store_Entry{{name = "visitor", bytes = file, class = .Object}}
	store := Store{entries = entries[:]}
	machine := machine_make()
	request := request_of("visitor", blake3.hash(file))
	result := run(&machine, &store, &request)
	testing.expect(t, result.border_ok)
	testing.expect_value(t, len(result.events), 3)
	testing.expect_value(t, result.events[0].event, rd.Disk_Load_Event.Memory_Wanted)
	testing.expect_value(t, result.events[1].event, rd.Disk_Load_Event.Module_Filled)
	seen := last(&result)
	testing.expect_value(t, seen.event, rd.Disk_Load_Event.Ready)
	testing.expect(t, string(result.module) == string(file))
	testing.expect_value(t, rd.start_from_bytes_check(&seen.report.start, 3, "visitor", blake3.hash(file), u64(len(file)), nil), rd.Start_From_Bytes_Refusal.None)
	testing.expect_value(t, machine.counters.starts_requested, 1)
}

// The import scan lists the store, reads each entry into lent memory,
// drops the bytes that no import names and keeps the others, an import of
// a kept file included; the start names each kept file.
@(test)
the_import_scan_keeps_each_file_that_an_import_names :: proc(t: ^testing.T) {
	leaf := module_file(nil, 300, 7)
	library := module_file({blake3.hash(leaf), image_hash(3)}, 1500, 9)
	other := module_file(nil, 200, 11)
	file := module_file({blake3.hash(library)})
	entries := [?]Store_Entry {
		{name = "a_tree", class = .Other},
		{name = "other", bytes = other, class = .Object},
		{name = "visitor", bytes = file, class = .Object},
		{name = "library", bytes = library, class = .Object},
		{name = "leaf", bytes = leaf, class = .Object},
	}
	store := Store{entries = entries[:]}
	machine := machine_make()
	request := request_of("visitor", blake3.hash(file))
	result := run(&machine, &store, &request)
	testing.expect(t, result.border_ok)
	seen := last(&result)
	testing.expect_value(t, seen.event, rd.Disk_Load_Event.Ready)
	testing.expect_value(t, len(result.kept_hashes), 2)
	testing.expect_value(t, rd.start_from_bytes_check(&seen.report.start, 3, "visitor", blake3.hash(file), u64(len(file)), result.kept_hashes[:]), rd.Start_From_Bytes_Refusal.None)
	founds, dropped := 0, 0
	for &item in result.events {
		#partial switch item.event {
		case .Import_Found:
			founds += 1
			if founds == 2 {
				testing.expect_value(t, string(item.report.importer_name[:item.report.importer_name_length]), "library")
				testing.expect_value(t, string(item.report.file_name[:item.report.file_name_length]), "leaf")
			}
		case .Candidate_Dropped:
			dropped += 1
		}
	}
	testing.expect_value(t, founds, 2)
	testing.expect_value(t, dropped, 1)
}

// A module file of no byte, past the limit, or absent is refused; a file
// at the limit gets its lent memory.
@(test)
the_size_of_a_module_file_is_checked_once_at_its_edges :: proc(t: ^testing.T) {
	sizes := [?]i64{0, rd.MODULE_BYTES_LIMIT + 1, max(i64)}
	refusals := [?]rd.Disk_Load_Refusal{.Object_Empty, .Object_Too_Large, .Object_Too_Large}
	for size, index in sizes {
		@(static) asked: i64
		asked = size
		store := Store{hostile = proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			answer^ = {kind = .Value, value = asked}
			return true
		}}
		machine := machine_make()
		request := request_of("visitor", image_hash(9))
		result := run(&machine, &store, &request)
		testing.expect(t, result.border_ok)
		testing.expect_value(t, refusal_of(&result), refusals[index])
		if refusals[index] == .Object_Too_Large {
			testing.expect_value(t, last(&result).report.byte_count, u64(size))
		}
	}
	machine := machine_make()
	request := request_of("visitor", image_hash(9))
	action := load_begin(&machine, &request)
	testing.expect_value(t, action.kind, Action_Kind.Ask_Size)
	answer := Storage_Answer{kind = .Value, value = rd.MODULE_BYTES_LIMIT}
	action = storage_answered(&machine, &answer)
	testing.expect_value(t, action.event, rd.Disk_Load_Event.Memory_Wanted)
	testing.expect_value(t, machine.report.byte_count, u64(rd.MODULE_BYTES_LIMIT))

	store := Store{}
	absent := machine_make()
	absent_request := request_of("nobody", image_hash(9))
	result := run(&absent, &store, &absent_request)
	testing.expect(t, result.border_ok)
	testing.expect_value(t, refusal_of(&result), rd.Disk_Load_Refusal.No_Object)
}

// A store that gives no byte, more bytes than the file has left, a
// negative value, an answer that its export does not allow, a failure or
// no connection ends the load with the refusal of that cause.
@(test)
a_hostile_store_ends_the_load_with_its_cause :: proc(t: ^testing.T) {
	file := module_file(nil)
	entries := [?]Store_Entry{{name = "visitor", bytes = file, class = .Object}}
	Case :: struct {
		hostile: proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool,
		refusal: rd.Disk_Load_Refusal,
	}
	cases := [?]Case {
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			if action.kind != .Ask_Read {return false}
			answer^ = {kind = .Value, value = 0}
			return true
		}, .No_Byte_At},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			if action.kind != .Ask_Read {return false}
			@(static) many: [4096]u8
			answer^ = {kind = .Value, value = 4096, text = many[:]}
			return true
		}, .Too_Many_Bytes},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			answer^ = {kind = .Value, value = -1}
			return true
		}, .Answer_Not_Allowed},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			answer^ = {kind = .Not_Allowed}
			return true
		}, .Answer_Not_Allowed},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			if calls < 2 {return false}
			answer^ = {kind = .Gone}
			return true
		}, .Storage_Stopped},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			answer^ = {kind = .Failed, value = -3, damaged = true, error = {kind = 5, argument = 2}}
			return true
		}, .Read_Refused},
	}
	for item in cases {
		store := Store{entries = entries[:], hostile = item.hostile}
		machine := machine_make()
		request := request_of("visitor", blake3.hash(file))
		result := run(&machine, &store, &request)
		testing.expect(t, result.border_ok)
		testing.expect_value(t, refusal_of(&result), item.refusal)
		if item.refusal == .Read_Refused {
			report := last(&result).report
			testing.expect_value(t, report.damaged, 1)
			testing.expect_value(t, report.failed_value, -3)
			testing.expect_value(t, report.read_error, errors.Error_Record{kind = 5, argument = 2})
		}
	}
}

// An import that no file of the store has is refused with its hash, its
// importer and the count of the reads; a file whose bytes changed is
// dropped, and the hash that it had stays missing.
@(test)
a_missing_import_and_a_changed_file_are_refused_with_the_missing_hash :: proc(t: ^testing.T) {
	library := module_file(nil, 400, 3)
	changed := module_file(nil, 400, 4)
	file := module_file({blake3.hash(library)})
	entries := [?]Store_Entry {
		{name = "visitor", bytes = file, class = .Object},
		{name = "library", bytes = changed, class = .Object},
	}
	store := Store{entries = entries[:]}
	machine := machine_make()
	request := request_of("visitor", blake3.hash(file))
	result := run(&machine, &store, &request)
	testing.expect(t, result.border_ok)
	testing.expect_value(t, refusal_of(&result), rd.Disk_Load_Refusal.Import_Missing)
	report := last(&result).report
	testing.expect_value(t, report.hash, blake3.hash(library))
	testing.expect_value(t, report.importer_name_length, 0)
	testing.expect_value(t, report.scan_reads, 1)
	testing.expect_value(t, report.entries_left_out, 0)
	testing.expect_value(t, len(result.kept_hashes), 0)
}

// Imports past the wanted capacity, and a chain of imports past the depth
// limit, end the load with Import_Bounds. A loop through a replacement of
// the machine ends: a hash is wanted once.
@(test)
imports_past_the_bounds_and_a_loop_through_a_replacement_end :: proc(t: ^testing.T) {
	wide: [disk_process.SCAN_WANTED_CAPACITY + 1]blake3.Hash
	for &hash, index in wide {
		hash[0] = u8(index + 1)
	}
	file := module_file(wide[:])
	entries := [?]Store_Entry{{name = "visitor", bytes = file, class = .Object}}
	store := Store{entries = entries[:]}
	machine := machine_make()
	request := request_of("visitor", blake3.hash(file))
	result := run(&machine, &store, &request)
	testing.expect(t, result.border_ok)
	testing.expect_value(t, refusal_of(&result), rd.Disk_Load_Refusal.Import_Bounds)

	// A chain one level deeper than the limit.
	chain: [disk_process.SCAN_DEPTH_LIMIT + 1][]u8
	chain[disk_process.SCAN_DEPTH_LIMIT] = module_file(nil, 100, 200)
	for level := disk_process.SCAN_DEPTH_LIMIT - 1; level >= 0; level -= 1 {
		chain[level] = module_file({blake3.hash(chain[level + 1])}, 100, u8(level))
	}
	deep_file := module_file({blake3.hash(chain[0])})
	deep_entries: [disk_process.SCAN_DEPTH_LIMIT + 2]Store_Entry
	deep_entries[0] = {name = "visitor", bytes = deep_file, class = .Object}
	names := [?]string{"c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7"}
	for level in 0 ..= disk_process.SCAN_DEPTH_LIMIT {
		deep_entries[level + 1] = {name = names[level], bytes = chain[level], class = .Object}
	}
	deep_store := Store{entries = deep_entries[:]}
	deep := machine_make()
	deep_request := request_of("visitor", blake3.hash(deep_file))
	deep_result := run(&deep, &deep_store, &deep_request)
	testing.expect(t, deep_result.border_ok)
	testing.expect_value(t, refusal_of(&deep_result), rd.Disk_Load_Refusal.Import_Bounds)

	// The module imports R; the machine replaces R with the library, and
	// the library imports R again.
	replaced_hash: blake3.Hash
	replaced_hash[0] = 0x77
	library := module_file({replaced_hash}, 100, 5)
	loop_file := module_file({replaced_hash})
	loop_entries := [?]Store_Entry{{name = "visitor", bytes = loop_file, class = .Object}, {name = "library", bytes = library, class = .Object}}
	loop_store := Store{entries = loop_entries[:]}
	loop := machine_make()
	loop_request := request_of("visitor", blake3.hash(loop_file), {replaced_hash, blake3.hash(library)})
	loop_result := run(&loop, &loop_store, &loop_request)
	testing.expect(t, loop_result.border_ok)
	testing.expect(t, loop_result.ended)
	testing.expect_value(t, refusal_of(&loop_result), rd.Disk_Load_Refusal.Import_Missing)
	testing.expect_value(t, last(&loop_result).report.hash, replaced_hash)
	testing.expect_value(t, len(loop_result.kept_hashes), 1)
}

// A list row whose name is out of its page, or whose kind names no kind,
// ends the load; an entry that leaves the store during the scan is
// skipped.
@(test)
a_hostile_list_ends_the_scan_and_a_vanished_entry_is_skipped :: proc(t: ^testing.T) {
	library := module_file(nil, 100, 1)
	file := module_file({blake3.hash(library)})
	entries := [?]Store_Entry{{name = "visitor", bytes = file, class = .Object}, {name = "gone", bytes = library, class = .Object}, {name = "library", bytes = library, class = .Object}}
	Case :: struct {
		hostile: proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool,
		refusal: rd.Disk_Load_Refusal,
	}
	cases := [?]Case {
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			if action.kind != .Ask_List {return false}
			@(static) rows: [1]List_Row
			@(static) names: [8]u8
			rows[0] = {name_offset = LIST_NAME_BYTES, name_count = 1, class = .Object, size = 1}
			answer^ = {kind = .Value, value = 1, rows = rows[:], names = names[:]}
			return true
		}, .Import_Entry_Name_Outside},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			if action.kind != .Ask_List {return false}
			@(static) rows: [1]List_Row
			@(static) names: [8]u8
			rows[0] = {name_offset = -1, name_count = 1, class = .Object, size = 1}
			answer^ = {kind = .Value, value = 1, rows = rows[:], names = names[:]}
			return true
		}, .Import_Entry_Name_Outside},
		{proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
			if action.kind != .Ask_List {return false}
			@(static) rows: [1]List_Row
			@(static) names: [8]u8
			names[0] = 'x'
			rows[0] = {name_offset = 0, name_count = 1, class = .Unknown, size = 1}
			answer^ = {kind = .Value, value = 1, rows = rows[:], names = names[:]}
			return true
		}, .Import_Entry_Kind_Unknown},
	}
	for item in cases {
		store := Store{entries = entries[:], hostile = item.hostile}
		machine := machine_make()
		request := request_of("visitor", blake3.hash(file))
		result := run(&machine, &store, &request)
		testing.expect(t, result.border_ok)
		testing.expect_value(t, refusal_of(&result), item.refusal)
	}

	vanished := Store{entries = entries[:], hostile = proc(action: Action, answer: ^Storage_Answer, calls: int) -> bool {
		if action.name != "gone" || action.kind == .Ask_List {return false}
		answer^ = {kind = .Absent}
		return true
	}}
	machine := machine_make()
	request := request_of("visitor", blake3.hash(file))
	result := run(&machine, &vanished, &request)
	testing.expect(t, result.border_ok)
	testing.expect_value(t, last(&result).event, rd.Disk_Load_Event.Ready)
	testing.expect_value(t, len(result.kept_hashes), 1)
}

// Each command out of its order, a request that the border refuses, and
// lent memory that does not hold the whole file are refused with
// Command_Refused, and the load ends.
@(test)
commands_out_of_order_and_short_lent_memory_are_refused :: proc(t: ^testing.T) {
	machine := machine_make()
	testing.expect_value(t, continue_given(&machine).event, rd.Disk_Load_Event.Command_Refused)
	machine = machine_make()
	bytes: [16]u8
	testing.expect_value(t, memory_lent(&machine, bytes[:]).event, rd.Disk_Load_Event.Command_Refused)

	machine = machine_make()
	bad := request_of("visitor", {})
	testing.expect_value(t, load_begin(&machine, &bad).event, rd.Disk_Load_Event.Command_Refused)
	bad = request_of("visitor", image_hash(1))
	bad.replacement_count = rd.LOAD_REPLACEMENT_CAPACITY + 1
	testing.expect_value(t, load_begin(&machine, &bad).event, rd.Disk_Load_Event.Command_Refused)

	machine = machine_make()
	good := request_of("visitor", image_hash(1))
	testing.expect_value(t, load_begin(&machine, &good).kind, Action_Kind.Ask_Size)
	testing.expect_value(t, load_begin(&machine, &good).event, rd.Disk_Load_Event.Command_Refused)
	testing.expect_value(t, machine.stage, Stage.Ended)

	file := module_file(nil)
	entries := [?]Store_Entry{{name = "visitor", bytes = file, class = .Object}}
	store := Store{entries = entries[:]}
	short := machine_make()
	request := request_of("visitor", blake3.hash(file))
	result := run(&short, &store, &request, lend_short = true)
	testing.expect_value(t, last(&result).event, rd.Disk_Load_Event.Command_Refused)

	// After Cancel the next load runs.
	cancel(&machine)
	testing.expect_value(t, load_begin(&machine, &good).kind, Action_Kind.Ask_Size)
}
