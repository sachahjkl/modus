package modustool

import "core:mem"
import "core:slice"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/ring"
import "modus:contract/root_ring"
import "modus:contract/text_encoding"
import "modus:support/display"
import "modus:support/key_path"
import "modus:support/system"
import terminal "modus:support/terminal"

// The fuzz target of the records between programs that a program reads
// from a ring (src/md/infrastructure/fuzzing.md, "The targets, in order of
// value"): the input events of the compositor, the input records of the
// terminal, the commands of the service ring, and the records of the root
// ring with their refusals. Each reader is the border of a word: it gives a
// member that the word names, or a refusal, and it reads no state.

// The records of one input: the reader of a ring takes them one by one.
FUZZ_RING_RECORD_LIMIT :: 16
FUZZ_RING_RECORDS_INPUT_LIMIT :: FUZZ_RING_RECORD_LIMIT * size_of(ring.Record)

// fuzz_ring_records_execute reads the input as records of a ring, and
// gives each one to each reader.
fuzz_ring_records_execute :: proc(input: []u8) -> Fuzz_Verdict {
	count := min((len(input) + size_of(ring.Record) - 1) / size_of(ring.Record), FUZZ_RING_RECORD_LIMIT)
	for index in 0 ..< count {
		record: ring.Record
		copy(mem.ptr_to_bytes(&record), input[index * size_of(ring.Record):])
		// Each reader takes the record by value: a refused record changes
		// nothing by its form, and the oracles check what each one gives.
		verdict := fuzz_ring_record_check(record)
		if verdict.oracle != .None {
			return verdict
		}
	}
	return FUZZ_PASSED
}

@(private = "file")
fuzz_ring_record_check :: proc(record: ring.Record) -> Fuzz_Verdict {
	// The input event of the compositor.
	event, event_ok := display.event_of_record(record)
	if !event_ok {
		if event != (display.Event{}) {
			return fuzz_broken(.Contract, "event_of_record refuses the kind %d and gives an event", record.kind)
		}
	} else {
		switch {
		case event.kind == .None || u32(event.kind) != record.kind:
			return fuzz_broken(.Contract, "event_of_record gives the kind %v for the word %d", event.kind, record.kind)
		case u32(event.character) > text_encoding.CODE_POINT_LAST || event.character < 0:
			return fuzz_broken(.Contract, "event_of_record gives the character %d", event.character)
		case event.kind == .Key && event.character != 0 && u64(event.character) != record.values[1]:
			return fuzz_broken(.Contract, "the character of a key is not the word of the record")
		case event.wheel < -key_path.WHEEL_NOTCHES_LIMIT || event.wheel > key_path.WHEEL_NOTCHES_LIMIT:
			return fuzz_broken(.Contract, "event_of_record gives %d notches of the wheel", event.wheel)
		}
	}
	// The input record of the terminal.
	given, given_ok := terminal.input_of_record(record)
	if !given_ok {
		if given != (terminal.Input_Record{}) {
			return fuzz_broken(.Contract, "input_of_record refuses the kind %d and gives an input", record.kind)
		}
	} else {
		switch {
		case given.kind == .None || u32(given.kind) != record.kind:
			return fuzz_broken(.Contract, "input_of_record gives the kind %v for the word %d", given.kind, record.kind)
		case u32(given.key.character) > text_encoding.CODE_POINT_LAST || given.key.character < 0:
			return fuzz_broken(.Contract, "input_of_record gives the character %d", given.key.character)
		case given.list_first < 0 || given.list_first > int(max(i32)):
			return fuzz_broken(.Contract, "input_of_record gives the first row %d", given.list_first)
		}
	}
	// The command of the service ring.
	service_command, service_ok := system.service_command_of_record(record)
	if service_ok != (service_command != .None) || service_ok && u32(service_command) != record.kind {
		return fuzz_broken(.Contract, "service_command_of_record gives %v, %v for the word %d", service_command, service_ok, record.kind)
	}
	if !service_ok {
		if known, _ := fuzz_isolated_service_command_named(record.kind); known && record.kind != u32(isolated.Service_Command.None) {
			return fuzz_broken(.Contract, "service_command_of_record refuses the command %d", record.kind)
		}
	}
	// The command of the root ring, and its refusal.
	command, command_ok := root_ring.command_of_word(record.kind)
	if command_ok {
		if command == .None || u32(command) != record.kind {
			return fuzz_broken(.Contract, "command_of_word gives %v for the word %d", command, record.kind)
		}
	} else {
		if command != .None {
			return fuzz_broken(.Contract, "command_of_word refuses the word %d and gives %v", record.kind, command)
		}
		refusal := errors.completion_record(root_ring.command_refusal(record.kind))
		if refusal.kind != i64(errors.Kind.Unsupported) || refusal.value != i64(record.kind) || refusal.operation != i64(record.kind) || !fuzz_error_record_named(refusal) {
			return fuzz_broken(.Contract, "the refusal of the word %d is %v", record.kind, refusal)
		}
	}
	// The reader of a command in an error record agrees with the border.
	read, read_ok := root_ring.command_of_record(i64(record.kind))
	if read_ok != command_ok || read != command {
		return fuzz_broken(.Two_Readers, "command_of_record and command_of_word differ on the word %d", record.kind)
	}
	if name := root_ring.root_command_name(i64(record.values[0])); len(name) == 0 {
		return fuzz_broken(.Contract, "root_command_name gives no name for the word %d", record.values[0])
	}
	// The report of a Machine_Key command.
	report, report_status := root_ring.machine_key_report_of_values(record.values)
	if report_status == .Ok {
		if u64(report.state) != record.values[4] || report.state == .Awaited && u64(report.form) != record.values[5] {
			return fuzz_broken(.Contract, "machine_key_report_of_values gives a report that the words do not name")
		}
	} else if report_status != .Bad_Operation || report != (root_ring.Machine_Key_Report{}) {
		return fuzz_broken(.Contract, "machine_key_report_of_values refuses with %v and a report", report_status)
	}
	// A word of a root command that names a member, or its refusal.
	origin, origin_status, origin_refusal := root_ring.member_of_word(root_ring.Principal_Key_Origin, record.values[5], .Principal_Unlock, 5)
	if origin_status == .Ok {
		if u64(origin) != record.values[5] || origin_refusal != ([7]u64{}) {
			return fuzz_broken(.Contract, "member_of_word gives %v for the word %d", origin, record.values[5])
		}
	} else {
		refusal := errors.completion_record(origin_refusal)
		if origin_status != .Bad_Operation || u64(origin) != 0 || refusal.kind != i64(errors.Kind.Bad_Value) || refusal.argument != 5 || refusal.value != i64(min(record.values[5], 1 << 62)) || refusal.limit != i64(max(root_ring.Principal_Key_Origin)) {
			return fuzz_broken(.Contract, "the refusal of the word %d is %v", record.values[5], refusal)
		}
	}
	// A completion that fails carries an error record: its words become
	// members at their borders, or are refused.
	carried := errors.completion_record(record.values)
	if kind, known := errors.kind_of_word(carried.kind); known && i64(kind) != carried.kind {
		return fuzz_broken(.Contract, "kind_of_word gives %v for the word %d", kind, carried.kind)
	}
	if unit, known := errors.unit_of_word(carried.unit); known && i64(unit) != carried.unit {
		return fuzz_broken(.Contract, "unit_of_word gives %v for the word %d", unit, carried.unit)
	}
	if errors.completion_values(carried) != record.values {
		return fuzz_broken(.Round_Trip, "completion_values of completion_record gives other words")
	}
	return FUZZ_PASSED
}

// fuzz_isolated_service_command_named says if a word names a member of
// isolated.Service_Command, by the values that the enumeration states.
@(private = "file")
fuzz_isolated_service_command_named :: proc(word: u32) -> (known: bool, command: isolated.Service_Command) {
	for member in isolated.Service_Command {
		if u32(member) == word {
			return true, member
		}
	}
	return false, .None
}

// fuzz_ring_records_seeds gives one record of each kind that each reader
// knows, then the words at the edges: None, the largest member plus one,
// and the largest word.
fuzz_ring_records_seeds :: proc(seeds: ^[dynamic][]u8) {
	records := make([dynamic]ring.Record, context.temp_allocator)
	for kind in display.Event_Kind {
		append(&records, ring.Record{kind = u32(kind), values = {'a', 'a', 1, 0, 0, 0, 0}})
	}
	append(&records, ring.Record{kind = u32(display.Event_Kind.Pointer), values = {max(u64), 1 << 63, 7, u64(key_path.WHEEL_NOTCHES_LIMIT) + 1, 0, 0, 0}})
	append(&records, ring.Record{kind = u32(display.Event_Kind.Key), values = {0, text_encoding.CODE_POINT_LAST + 1, 0, 0, 0, 0, 0}})
	for kind in terminal.Input {
		append(&records, ring.Record{kind = u32(kind), values = {u64(max(i32)) + 1, 0, 0, 0, 0, 0, 0}})
	}
	for kind in root_ring.Root_Command {
		append(&records, ring.Record{kind = u32(kind), values = {u64(kind), 0, 0, 0, u64(root_ring.Machine_Key_State.Awaited), u64(root_ring.Machine_Key_Form.Sealed_By_The_Tpm), 0}})
	}
	append(&records, ring.Record{kind = u32(max(root_ring.Root_Command)) + 1, values = {0, 0, 0, 0, u64(max(root_ring.Machine_Key_State)) + 1, u64(max(root_ring.Principal_Key_Origin)) + 1, 0}})
	append(&records, ring.Record{kind = max(u32), values = {max(u64), max(u64), max(u64), max(u64), max(u64), max(u64), max(u64)}})
	for kind in isolated.Service_Command {
		append(&records, ring.Record{kind = u32(kind)})
	}
	append(&records, ring.Record{kind = u32(max(isolated.Service_Command)) + 1})
	// One record of each in a seed of its own, then the first ring full.
	for &record in records {
		append(seeds, slice.clone(mem.ptr_to_bytes(&record)))
	}
	whole := make([dynamic]u8)
	for &record in records[:min(len(records), FUZZ_RING_RECORD_LIMIT)] {
		append(&whole, ..mem.ptr_to_bytes(&record))
	}
	append(seeds, whole[:])
}

// fuzz_ring_records_regions: each record of an input, for the field
// mutator.
fuzz_ring_records_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	count := min(len(input) / size_of(ring.Record), FUZZ_RING_RECORD_LIMIT)
	if count > 0 {
		append(regions, Fuzz_Region{offset = 0, type = ring.Record, count = count})
	}
}
