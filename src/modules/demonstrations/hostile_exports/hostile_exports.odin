// Exports that are wrong on purpose, for the tests of the callers
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters"). This module
// has no entry: no service holds it, and `remote` cannot reach it. A
// process loads it, or a call host runs it, and only a test does so.
//
// **What it is for.** A caller must survive a callee that breaks the
// rules. Each export breaks one rule of the call form, and the process
// `tables` checks what the caller sees:
//
// - keep and kept: a lent handle ends with its call, so a later use of it
//   gets "no handle";
// - hold and look: a mapping of a lent object ends with its call, so a
//   later read through it faults in the process of the module, not in the
//   caller;
// - append_past_capacity: a write past the capacity of a table reaches the
//   caller only in a direct call, where the two share one address space;
// - mode_set and its getter mode: the palette of the console must never
//   call a getter of a module in its own process, where a direct call has
//   no bound. mode logs a fact, so a test sees each call of it.
//
// The lesson: an isolated call protects the caller; a direct call trusts
// the module.
package hostile_exports

import "modus:contract/enum_word"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:system"

// The value of the Memory_Map command that holds the memory handle, from 1:
// the argument that an error record of the kernel names for it.
MEMORY_MAP_ARGUMENT_MEMORY :: 1

// bytes_of maps a memory object for the time of one export. count is 0 when
// the kernel refuses; then status says why, and the error record holds the
// refusal in the words of the export: argument names the parameter of the
// export that holds the handle. error can be nil.
@(private)
bytes_of :: proc "contextless" (memory: system.Handle, flags: op.Map_Flags, argument: i64 = 0, error: ^errors.Error_Record = nil) -> (bytes: []u8, status: call_outcome.Call_Outcome) {
	refusal: errors.Error_Record
	address: rawptr
	address, status = system.memory_map(memory, flags, error = &refusal)
	if status != .Succeeded {
		if error != nil {
			// The record of the kernel names an argument of Memory_Map, and
			// the kernel operation: the caller called the export, with its
			// own arguments.
			error^ = refusal
			error.operation = 0
			error.argument = refusal.argument == MEMORY_MAP_ARGUMENT_MEMORY ? argument : 0
			if refusal.kind == i64(errors.Kind.None) {
				error^ = errors.error_make(.Refused, .Kernel_Status, found = i64(status))
			}
		}
		return nil, status
	}
	// The map took the handle, so the kernel gives its size: a refusal maps no byte.
	pages, _ := system.memory_size(memory)
	return ([^]u8)(address)[:pages * system.PAGE_SIZE], .Succeeded
}

// total adds the bytes of a memory object.
@(private)
total :: proc "contextless" (memory: system.Lent({.Read}), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	bytes, status := bytes_of(memory.handle, {}, 1, error)
	if status != .Succeeded {
		return status, 0
	}
	sum: i64
	for b in bytes {
		sum += i64(b)
	}
	system.memory_unmap(raw_data(bytes))
	return .Succeeded, sum
}

held: system.Handle

// keep remembers the handle that the caller lent, for a later call of kept.
//
// The result is the sum of the bytes of the object, read during the call. When the kernel refuses the map, the
// result is the outcome of the refusal with the error record of the kernel for the argument memory.
@(export, link_name = "keep")
keep :: proc "c" (memory: system.Lent({.Read}), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	held = memory.handle
	return total(memory, error)
}

// kept uses the handle that keep remembered. The result is the call outcome of
// the kernel: 1 is Argument_Refused, because a lent handle ends with its call.
@(export, link_name = "kept")
kept :: proc "c" () -> i64 {
	bytes, status := bytes_of(held, {})
	if status == .Succeeded {
		system.memory_unmap(raw_data(bytes))
	}
	return i64(status)
}

view: []u8

// hold maps a memory object that the caller lent, keeps the mapping for a
// later call of look, and gives the first byte.
//
// When the kernel refuses the map, the result is the outcome of the refusal with the error record of the kernel
// for the argument memory.
@(export, link_name = "hold")
hold :: proc "c" (memory: system.Lent({.Read}), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	bytes, status := bytes_of(memory.handle, {}, 1, error)
	if status != .Succeeded {
		return status, 0
	}
	view = bytes
	return .Succeeded, i64(bytes[0])
}

// look reads the first byte through the mapping that hold kept. After an
// isolated call the caller revoked what it lent: the kernel removed the
// mapping, and the process of this module stops on a page fault.
//
// In a direct call nothing was revoked: the mapping is still there, and the result is the first byte. With no
// earlier hold, the result is the outcome Nothing_Has_That_Name with an error record: `Absent` of the mappings, for
// the call as a whole.
@(export, link_name = "look")
look :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if len(view) == 0 {
		return call_outcome.fail(error, .Nothing_Has_That_Name, .Absent, .Mappings)
	}
	return .Succeeded, i64(view[0])
}

// A reading of a sensor: the record of sample, 40 bytes.
Reading :: struct {
	sensor:  i64,
	time:    i64,
	value:   i64,
	minimum: i64,
	maximum: i64,
}

// append_past_capacity writes 4 readings after the capacity of the table, against the rule of the direction Append: a test of the caller. In a direct call the caller and the module share one address space, and the caller has no protection. In an isolated call the caller copies back the readings up to the capacity only.
//
// The result is 4, and the count of the table claims 4 records more than its capacity: the caller must not believe
// it.
@(export, link_name = "append_past_capacity")
append_past_capacity :: proc "c" (readings: ^system.Table_To_Append(Reading)) -> i64 {
	for number in readings.capacity ..< readings.capacity + 4 {
		readings.records[number] = {sensor = -1, time = -1, value = -1, minimum = -1, maximum = -1}
	}
	readings.count = readings.capacity + 4
	return 4
}

// A mode of this module: the enum of mode_set, whose members the module
// file names.
Mode :: enum u32 {
	Slow = 0,
	Fast = 1,
}

// The getter mode ran: a test that loaded this module in the console fails
// on this fact while the palette refreshes its marks.
@(log_fact = "hostile_exports: the getter mode ran")
Getter_Ran :: struct {}

// mode_set takes a mode, and changes nothing: the palette shows a row of buttons for it.
//
// - **mode**: `.slow` or `.fast`.
//
// The result is the value of the mode: 0 or 1, or the outcome Argument_Refused with an error record:
//
// - `Bad_Value`: the word names no mode; the record holds it.
@(export, link_name = "mode_set", enum_getters = "mode = mode")
mode_set :: proc "c" (mode: Mode, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	// The caller wrote the register: a word that names no member is
	// refused, never read as a mode.
	member, ok := enum_word.member_of_argument(mode)
	if !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, i64(transmute(u32)mode))
	}
	return .Succeeded, i64(member)
}

// mode gives the mode `.slow`, and logs that it ran.
//
// A console that loaded this module in its own process must never call it from the palette: a getter that loops
// there would hold the console for good.
@(export, link_name = "mode")
mode_get :: proc "c" () -> Mode {
	system.log_fact(.Info, Getter_Ran{})
	return .Slow
}
