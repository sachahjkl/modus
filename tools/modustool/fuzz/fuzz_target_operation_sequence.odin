package fuzz

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "modus:contract/enum_word"
import "modus:contract/operation"
import "modus:contract/operation_sequence"
import "modustool:foundation"

// The operation sequence on the host (src/md/infrastructure/kernel_fuzzing.md,
// "The sequence format and the grammar"): the generator that builds a
// sequence from choices with the forms of `OPERATIONS` as its grammar, and
// the two fuzz targets of the format. The raw target gives any bytes to
// `operation_sequence.check`; the generated target checks that each
// sequence of the generator is one that `check` accepts and reads back
// whole. The machine that runs the sequences is a later layer.

// The reference comments of the kernel operations: the generator reads the
// kind of the result of each operation there, as the site reads its
// signature. The file is in the binary, so a fuzz child reads no file.
fuzz_operation_reference := #load("../../../src/library/modus/contract/operation/operation.odin", string)

// The first address of the upper half, which only the kernel maps: a
// canonical address that a process never reaches.
FUZZ_KERNEL_HALF_FIRST :: u64(0xFFFF_8000_0000_0000)

// What the first value of the completion of an operation is, from the
// reference comment of the operation ("-> memory handle").
Fuzz_Operation_Result :: struct {
	handle:  bool, // A handle.
	kind:    operation.Object_Kind, // The kind of the handle; None when the reference names no kind ("the handle in the target").
	address: bool, // An address in the process that a later step can name: the mapping of `Memory_Map`.
}

// One address parameter of `OPERATIONS`, and what the generator writes
// there.
Fuzz_Address_Parameter :: struct {
	operation: operation.Operation,
	parameter: int,
	// The address is code that a thread of the runner runs: the generator
	// names a thread entry of the runner first.
	code:      bool,
	// The record that the operation reads at the address, which the
	// generator writes there (fuzz_operation_records.odin). Plain_Bytes
	// until its record type is described.
	record:    Fuzz_Address_Record,
}

// The address parameters of `OPERATIONS`, one row each. The start of the
// generator refuses an address parameter with no row, so a new operation
// stops the generator until its addresses are described. The addresses
// that read a record with no writer yet stay plain bytes: the address
// ranges of Memory_Protect name mappings, whose addresses a sequence knows
// only at run time; the event rules, the guest registers, the schedules
// and the placements wait for their writers.
@(rodata)
fuzz_address_parameters := [?]Fuzz_Address_Parameter {
	{operation = .Log, parameter = 1},
	{operation = .Memory_Map, parameter = 2},
	{operation = .Memory_Unmap, parameter = 1},
	{operation = .Process_Create, parameter = 1},
	{operation = .Process_Start, parameter = 1},
	{operation = .Process_Start, parameter = 2},
	{operation = .Process_Start, parameter = 3},
	{operation = .Process_State, parameter = 1},
	{operation = .Process_Stop, parameter = 2},
	{operation = .Inspect, parameter = 3},
	{operation = .Thread_Create, parameter = 1, code = true},
	{operation = .Thread_Create, parameter = 2},
	{operation = .Word_Wait, parameter = 0},
	{operation = .Word_Wake, parameter = 0},
	{operation = .Process_Module, parameter = 1},
	{operation = .Memory_Commit, parameter = 2, record = .Page_Range_Table},
	{operation = .Memory_Protect, parameter = 0},
	{operation = .Events_Set, parameter = 2},
	{operation = .Thread_Control, parameter = 3, record = .Thread_Control_Command},
	{operation = .Thread_Control, parameter = 5},
	{operation = .Guest_Run, parameter = 1},
	{operation = .Log_Read, parameter = 4},
}

// The grammar that the start of the generated target reads once.
@(private = "file")
fuzz_operation_results: [operation.Operation]Fuzz_Operation_Result

// fuzz_operation_results_read reads the result of each operation from the
// reference comments. A member of `Operation` that the comments do not
// name stops the start.
fuzz_operation_results_read :: proc(reference: string) -> (results: [operation.Operation]Fuzz_Operation_Result, ok: bool) {
	members, problem := foundation.enumeration_read(reference, foundation.OPERATION_SOURCE, "Operation")
	if problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return {}, false
	}
	found: [operation.Operation]bool
	for member in members {
		named := false
		for candidate in operation.Operation {
			if operation.OPERATIONS[candidate].name != member.name {
				continue
			}
			named = true
			found[candidate] = true
			results[candidate] = fuzz_operation_result_of(foundation.operation_comment_split(member).result)
		}
		if !named {
			fmt.eprintfln("modustool: %s: the member %s of Operation has no row in OPERATIONS", foundation.OPERATION_SOURCE, member.name)
			return {}, false
		}
	}
	for candidate in operation.Operation {
		if !found[candidate] {
			fmt.eprintfln("modustool: %s: no member %s in the enumeration Operation", foundation.OPERATION_SOURCE, operation.OPERATIONS[candidate].name)
			return {}, false
		}
	}
	return results, true
}

// fuzz_operation_result_of reads the first value of a result text: "memory
// handle, address" is a memory handle; "address" is a mapping.
fuzz_operation_result_of :: proc(text: string) -> Fuzz_Operation_Result {
	first := text
	if comma := strings.index_byte(text, ','); comma >= 0 {
		first = text[:comma]
	}
	first = strings.trim_space(first)
	result: Fuzz_Operation_Result
	if first == "address" {
		result.address = true
		return result
	}
	words := strings.fields(first, context.temp_allocator)
	for word, index in words {
		if word != "handle" {
			continue
		}
		result.handle = true
		if index == 0 {
			break
		}
		for kind in operation.Object_Kind {
			if kind != .None && strings.equal_fold(operation.OBJECT_KIND_NAMES[kind], words[index - 1]) {
				result.kind = kind
			}
		}
		break
	}
	return result
}

// fuzz_address_parameters_problem says what is wrong in a table of the
// address parameters: an address parameter of `OPERATIONS` with no row or
// with two, a row that names no address parameter, a table of ranges whose
// next parameter is not its count, or the records of the commands of
// Thread_Control on another operation. "" when the table is whole.
fuzz_address_parameters_problem :: proc(rows: []Fuzz_Address_Parameter) -> string {
	for row in rows {
		if row.parameter < 0 || row.parameter >= operation_sequence.ARGUMENTS || operation.OPERATIONS[row.operation].parameters[row.parameter].form != .Address {
			return fmt.tprintf("the row %s %d names no address parameter of OPERATIONS", operation.OPERATIONS[row.operation].name, row.parameter)
		}
		switch row.record {
		case .Plain_Bytes:
		case .Page_Range_Table:
			if row.parameter + 1 >= operation_sequence.ARGUMENTS || operation.OPERATIONS[row.operation].parameters[row.parameter + 1].form != .Count {
				return fmt.tprintf("the row %s %d names a table of ranges, and the parameter after it is not its count", operation.OPERATIONS[row.operation].name, row.parameter)
			}
		case .Thread_Control_Command:
			if row.operation != .Thread_Control || operation_parameter_place(row.operation, "command") < 0 {
				return fmt.tprintf("the row %s %d names the records of the commands of Thread_Control", operation.OPERATIONS[row.operation].name, row.parameter)
			}
		}
	}
	for candidate in operation.Operation {
		for parameter, index in operation.OPERATIONS[candidate].parameters {
			if parameter.form != .Address {
				continue
			}
			count := 0
			for row in rows {
				if row.operation == candidate && row.parameter == index {
					count += 1
				}
			}
			if count != 1 {
				return fmt.tprintf("the address parameter %s of %s has %d rows in the table of the address parameters, not 1", parameter.name, operation.OPERATIONS[candidate].name, count)
			}
		}
	}
	return ""
}

// fuzz_operation_sequence_start reads the grammar once: the results of the
// reference comments, and the check of the table of the address
// parameters. The host tests run on several threads, and each one that
// generates calls this start: the first call reads and writes the results,
// and each other call waits for it and then only reads, so no generator
// reads the results while a start writes them.
fuzz_operation_sequence_start :: proc() -> bool {
	sync.once_do(&fuzz_operation_sequence_started, fuzz_operation_sequence_start_once)
	return fuzz_operation_sequence_start_succeeded
}

@(private = "file")
fuzz_operation_sequence_started: sync.Once
@(private = "file")
fuzz_operation_sequence_start_succeeded: bool

@(private = "file")
fuzz_operation_sequence_start_once :: proc() {
	results, ok := fuzz_operation_results_read(fuzz_operation_reference)
	if !ok {
		return
	}
	if problem := fuzz_address_parameters_problem(fuzz_address_parameters[:]); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return
	}
	fuzz_operation_results = results
	fuzz_operation_sequence_start_succeeded = true
}

// ---------------------------------------------------------------------
// The generator.

@(private = "file")
fuzz_member_count :: proc($Enum: typeid) -> int {
	count := 0
	for _ in Enum {
		count += 1
	}
	return count
}

@(private = "file")
fuzz_member_at :: proc($Enum: typeid, place: int) -> Enum {
	count := 0
	for member in Enum {
		if count == place {
			return member
		}
		count += 1
	}
	return {}
}

// fuzz_operation_sequence_generate builds a sequence from the choices of a
// fuzz input. Each sequence that it builds is one that
// `operation_sequence.check` accepts; the values in it follow the forms of
// each parameter, or break one form on purpose. The zero choices give the
// simplest value: one area of one page, and no step.
//
// The count of the steps is a choice drawn before each step, so a zero
// choice ends the steps there (src/md/infrastructure/fuzzing.md, "The
// subtle points").
//
// Where an address of a step reads a record, the generator writes that
// record in the content of the area of the address (fuzz_step_records_write).
// When `written` is not nil, it receives each record that the generator
// wrote, for a host test.
fuzz_operation_sequence_generate :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence, written: ^[dynamic]Fuzz_Record_Written = nil) {
	sequence^ = {}
	// The loop runs on a local count: the places of the areas depend only
	// on the choices, never on what the memory of the sequence holds.
	area_count := 1 + fuzz_choice_below(choices, operation_sequence.AREAS_MOST)
	sequence.area_count = area_count
	content_place := 0
	for area in 0 ..< area_count {
		pages := 1 + fuzz_choice_below(choices, operation_sequence.AREA_PAGES_MOST)
		content_bytes := fuzz_choice_below(choices, min(pages * operation.PAGE_SIZE, operation_sequence.CONTENT_BYTES_MOST - content_place) + 1)
		sequence.areas[area] = {pages = pages, content_bytes = content_bytes}
		fuzz_choice_fill(choices, sequence.content[content_place:content_place + content_bytes])
		content_place += content_bytes
	}
	entry_first := 0
	entry_steps := 0
	for sequence.step_count < operation_sequence.STEPS_MOST && fuzz_choice_flag(choices) {
		step := sequence.step_count
		item: operation_sequence.Sequence_Step
		same_entry := step > 0 && entry_steps < operation_sequence.ENTRY_STEPS_MOST && fuzz_choice_rare(choices, 4)
		if same_entry {
			item.flags += {.Same_Entry}
		}
		if fuzz_choice_rare(choices, 8) {
			item.flags += {.No_Error_Details}
		}
		// A result exists only after the kernel entry that gave it ended.
		results_before := entry_first if same_entry else step
		chosen, known, refused := fuzz_operation_step_generate(choices, sequence, results_before, &item)

		// A Budget_Read before and after a step that the form refuses: a
		// refusal must change no amount of the budget. A step of the kernel
		// entry before it cannot get one before it.
		plant_budget_read := refused && !same_entry && step + 3 <= operation_sequence.STEPS_MOST && !fuzz_choice_rare(choices, 4)
		if plant_budget_read {
			fuzz_step_append(sequence, fuzz_planted_budget_read())
		}
		index := sequence.step_count
		if known {
			fuzz_step_records_write(choices, sequence, chosen, &item, index, written)
		}
		fuzz_step_append(sequence, item)
		if same_entry {
			entry_steps += 1
		} else {
			entry_first = index
			entry_steps = 1
		}
		if plant_budget_read {
			entry_first = sequence.step_count
			entry_steps = 1
			fuzz_step_append(sequence, fuzz_planted_budget_read())
		}
		// A Handle_State of a handle that a step gave: the oracle compares
		// its kind with the reference.
		if known && fuzz_operation_results[chosen].handle && sequence.step_count < operation_sequence.STEPS_MOST && !fuzz_choice_rare(choices, 4) {
			entry_first = sequence.step_count
			entry_steps = 1
			fuzz_step_append(sequence, fuzz_planted_handle_state(index))
		}
	}
}

@(private = "file")
fuzz_step_append :: proc(sequence: ^operation_sequence.Sequence, item: operation_sequence.Sequence_Step) {
	sequence.steps[sequence.step_count] = item
	sequence.step_count += 1
}

@(private = "file")
fuzz_planted_budget_read :: proc() -> operation_sequence.Sequence_Step {
	item := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Budget_Read)}
	item.arguments[0] = {source = .Budget}
	return item
}

@(private = "file")
fuzz_planted_handle_state :: proc(step: int) -> operation_sequence.Sequence_Step {
	item := operation_sequence.Sequence_Step{operation = u32(operation.Operation.Handle_State)}
	item.arguments[0] = {source = .Result, step = step}
	return item
}

// fuzz_operation_step_generate chooses an operation and its arguments.
// `results_before` is the first step whose result the step cannot name.
// `known` is false for an operation word that names no operation;
// `refused` says that a value breaks the form of its parameter.
@(private = "file")
fuzz_operation_step_generate :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence, results_before: int, item: ^operation_sequence.Sequence_Step) -> (chosen: operation.Operation, known: bool, refused: bool) {
	if fuzz_choice_rare(choices, 32) {
		// A word that names no operation reaches the kernel as it is.
		unknown := [?]u32{u32(operation.Operation.None), u32(max(operation.Operation)) + 1, ~operation.COMMAND_NAMES_ERROR_DETAILS}
		item.operation = unknown[fuzz_choice_below(choices, len(unknown))]
		for &argument in item.arguments {
			argument = {source = .Value, value = fuzz_choice_word(choices, 8)}
		}
		return .None, false, true
	}
	// The member None is the first of the words above.
	chosen = fuzz_member_at(operation.Operation, 1 + fuzz_choice_below(choices, fuzz_member_count(operation.Operation) - 1))
	item.operation = u32(chosen)
	written_record := Fuzz_Thread_Control_Write.As_Chosen
	written_area := 0
	if chosen == .Thread_Control {
		written_record, written_area = fuzz_thread_control_write_choose(choices, sequence)
	}
	for parameter, index in operation.OPERATIONS[chosen].parameters {
		argument, broken := fuzz_argument_generate(choices, sequence, results_before, chosen, index, parameter)
		if written_record != .As_Chosen {
			argument, broken = fuzz_thread_control_write_argument(written_record, written_area, sequence, parameter, argument, broken)
		}
		item.arguments[index] = argument
		refused = refused || broken
	}
	return chosen, true, refused
}

// The commands of Thread_Control that read a record whose writer exists.
// The choice of the command alone gives each of them about once in 57
// steps of Thread_Control, so half of these steps name one of them, with
// the start of an area as the address and the bytes of the area as the
// size: the record then reaches the checks of its fields.
@(private = "file")
Fuzz_Thread_Control_Write :: enum u8 {
	As_Chosen, // The command, the address and the size of their forms.
	Write_Registers,
	Write_Extended_State,
	Write_Breakpoints,
}

// fuzz_thread_control_write_choose gives the command that a step of
// Thread_Control writes a record for, and its area; the zero choice keeps
// the arguments of their forms.
@(private = "file")
fuzz_thread_control_write_choose :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence) -> (written_record: Fuzz_Thread_Control_Write, area: int) {
	if !fuzz_choice_rare(choices, 2) {
		return .As_Chosen, 0
	}
	written_record = fuzz_member_at(Fuzz_Thread_Control_Write, 1 + fuzz_choice_below(choices, fuzz_member_count(Fuzz_Thread_Control_Write) - 1))
	return written_record, fuzz_choice_below(choices, sequence.area_count)
}

@(private = "file")
fuzz_thread_control_write_argument :: proc(written_record: Fuzz_Thread_Control_Write, area: int, sequence: ^operation_sequence.Sequence, parameter: operation.Parameter_Form, chosen: operation_sequence.Argument, chosen_broken: bool) -> (argument: operation_sequence.Argument, broken: bool) {
	switch parameter.name {
	case "command":
		command: operation.Thread_Control_Command
		switch written_record {
		case .As_Chosen:
			return chosen, chosen_broken
		case .Write_Registers:
			command = .Write_Registers
		case .Write_Extended_State:
			command = .Write_Extended_State
		case .Write_Breakpoints:
			command = .Write_Breakpoints
		}
		return {source = .Value, value = u64(command)}, false
	case "address":
		return {source = .Area_Address, area = area}, false
	case "size":
		return {source = .Value, value = u64(sequence.areas[area].pages * operation.PAGE_SIZE)}, false
	}
	return chosen, chosen_broken
}

@(private = "file")
fuzz_argument_generate :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence, results_before: int, chosen: operation.Operation, index: int, parameter: operation.Parameter_Form) -> (argument: operation_sequence.Argument, refused: bool) {
	switch parameter.form {
	case .None:
		// The kernel must not read a value that the operation does not take.
		if fuzz_choice_rare(choices, 16) {
			return {source = .Value, value = fuzz_choice_word(choices, 8)}, false
		}
		return {source = .Value}, false
	case .Value:
		return {source = .Value, value = fuzz_choice_word(choices, 8)}, false
	case .Handle, .Handle_Or_Zero:
		return fuzz_handle_generate(choices, sequence, results_before, parameter)
	case .Address:
		code := false
		for row in fuzz_address_parameters {
			if row.operation == chosen && row.parameter == index {
				code = row.code
			}
		}
		return fuzz_address_generate(choices, sequence, results_before, code), false
	case .Count:
		return fuzz_count_generate(choices, parameter.limit)
	case .Flags:
		return fuzz_flags_generate(choices, parameter.limit)
	case .Choice, .Bounded:
		return fuzz_largest_generate(choices, parameter.limit)
	}
	return {source = .Value}, false
}

// A handle that a step can name, and the kind of its object.
@(private = "file")
Fuzz_Handle_Candidate :: struct {
	argument: operation_sequence.Argument,
	kind:     operation.Object_Kind,
}

// fuzz_handle_generate gives a handle of the kind of the form, a handle of
// another kind, 0, or a value that names no handle.
@(private = "file")
fuzz_handle_generate :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence, results_before: int, parameter: operation.Parameter_Form) -> (argument: operation_sequence.Argument, refused: bool) {
	candidates := make([dynamic]Fuzz_Handle_Candidate, context.temp_allocator)
	append(&candidates, Fuzz_Handle_Candidate{{source = .Budget}, .Budget}, Fuzz_Handle_Candidate{{source = .Log}, .Log}, Fuzz_Handle_Candidate{{source = .Machine}, .Machine})
	for area in 0 ..< sequence.area_count {
		append(&candidates, Fuzz_Handle_Candidate{{source = .Area_Handle, area = area}, .Memory})
	}
	for step in 0 ..< results_before {
		member, known := enum_word.member_of_word(operation.Operation, u64(sequence.steps[step].operation))
		if known && fuzz_operation_results[member].handle {
			append(&candidates, Fuzz_Handle_Candidate{{source = .Result, step = step}, fuzz_operation_results[member].kind})
		}
	}
	matching := make([dynamic]Fuzz_Handle_Candidate, context.temp_allocator)
	for candidate in candidates {
		if parameter.kind == .None || candidate.kind == parameter.kind {
			append(&matching, candidate)
		}
	}
	form := fuzz_member_at(Fuzz_Handle_Form, fuzz_choice_below(choices, fuzz_member_count(Fuzz_Handle_Form)))
	if form == .Of_The_Kind && len(matching) == 0 {
		form = .Any_Kind
	}
	switch form {
	case .Of_The_Kind:
		return matching[fuzz_choice_below(choices, len(matching))].argument, false
	case .Any_Kind:
		candidate := candidates[fuzz_choice_below(choices, len(candidates))]
		return candidate.argument, parameter.kind != .None && candidate.kind != parameter.kind
	case .Zero:
		return {source = .Value}, parameter.form == .Handle
	case .Names_Nothing:
		nothing := [?]u64{0xFFFF, 1 << 32, max(u64)}
		return {source = .Value, value = nothing[fuzz_choice_below(choices, len(nothing))]}, true
	}
	return {source = .Value}, false
}

// The forms of a handle argument, the simplest first.
@(private = "file")
Fuzz_Handle_Form :: enum u8 {
	Of_The_Kind, // A start handle or a result of the kind of the form.
	Any_Kind, // A start handle or a result of any kind.
	Zero, // 0: the caller itself, or no handle.
	Names_Nothing, // A number that no grant gave.
}

// The forms of an address argument, the simplest first.
@(private = "file")
Fuzz_Address_Form :: enum u8 {
	Area_Start,
	Area_Last_Byte,
	Area_End, // Near the end of the area, so that a record crosses into the page with no access.
	Page_After_Area, // In the page with no access after the area.
	Area_Anywhere,
	Thread_Entry, // A thread entry of the runner.
	Mapping, // The address that an earlier `Memory_Map` gave, plus an offset.
	Zero,
	Kernel_Half,
	Not_Canonical,
}

// fuzz_address_generate gives an address in an area (at its start, at its
// last byte, near its end so that a record crosses it, in the page with no
// access after it, or anywhere in it), a thread entry of the runner, a
// mapping that an earlier step made, or a fixed address: 0, the kernel
// half, an address that is not canonical.
@(private = "file")
fuzz_address_generate :: proc(choices: ^Fuzz_Choices, sequence: ^operation_sequence.Sequence, results_before: int, code: bool) -> operation_sequence.Argument {
	form := fuzz_member_at(Fuzz_Address_Form, fuzz_choice_below(choices, fuzz_member_count(Fuzz_Address_Form)))
	// For code, the zero choice gives a thread entry.
	if code && form == .Area_Start {
		form = .Thread_Entry
	} else if code && form == .Thread_Entry {
		form = .Area_Start
	}
	area := fuzz_choice_below(choices, sequence.area_count)
	area_bytes := sequence.areas[area].pages * operation.PAGE_SIZE
	switch form {
	case .Area_Start:
		return {source = .Area_Address, area = area}
	case .Area_Last_Byte:
		return {source = .Area_Address, area = area, offset = u64(area_bytes - 1)}
	case .Area_End:
		return {source = .Area_Address, area = area, offset = u64(area_bytes - 1 - fuzz_choice_below(choices, 64))}
	case .Page_After_Area:
		return {source = .Area_Address, area = area, offset = u64(area_bytes + fuzz_choice_below(choices, operation.PAGE_SIZE))}
	case .Area_Anywhere:
		return {source = .Area_Address, area = area, offset = u64(fuzz_choice_below(choices, area_bytes))}
	case .Thread_Entry:
		entry := fuzz_member_at(operation_sequence.Thread_Entry, fuzz_choice_below(choices, fuzz_member_count(operation_sequence.Thread_Entry)))
		return {source = .Thread_Entry, entry = entry}
	case .Mapping:
		mappings := make([dynamic]int, context.temp_allocator)
		for step in 0 ..< results_before {
			member, known := enum_word.member_of_word(operation.Operation, u64(sequence.steps[step].operation))
			if known && fuzz_operation_results[member].address {
				append(&mappings, step)
			}
		}
		if len(mappings) == 0 {
			return {source = .Area_Address, area = area}
		}
		step := mappings[fuzz_choice_below(choices, len(mappings))]
		return {source = .Result, step = step, offset = u64(fuzz_choice_below(choices, operation_sequence.RESULT_OFFSET_MOST + 1))}
	case .Zero:
		return {source = .Value}
	case .Kernel_Half:
		return {source = .Value, value = FUZZ_KERNEL_HALF_FIRST}
	case .Not_Canonical:
		// The first address past the lower half is not canonical.
		return {source = .Value, value = operation.USER_END}
	}
	return {source = .Value}
}

// fuzz_count_generate gives 1, the limit, 0, the limit plus one, the
// largest value, or a count below the limit. With no limit: 1, 0, 2, a
// large count, the largest value, or a small count.
@(private = "file")
fuzz_count_generate :: proc(choices: ^Fuzz_Choices, limit: u64) -> (argument: operation_sequence.Argument, refused: bool) {
	if limit == 0 {
		values := [?]u64{1, 0, 2, 1 << 32, max(u64)}
		form := fuzz_choice_below(choices, len(values) + 1)
		if form == len(values) {
			return {source = .Value, value = fuzz_choice_word(choices, 2)}, false
		}
		return {source = .Value, value = values[form]}, false
	}
	values := [?]u64{1, limit, 0, limit + 1, max(u64)}
	form := fuzz_choice_below(choices, len(values) + 1)
	if form == len(values) {
		return {source = .Value, value = u64(fuzz_choice_below(choices, int(min(limit, 1 << 16)) + 1))}, false
	}
	return {source = .Value, value = values[form]}, values[form] > limit
}

// fuzz_flags_generate gives a set of the known flags, the same with the
// lowest unknown bit, or every bit. With no known flags, a plain word.
@(private = "file")
fuzz_flags_generate :: proc(choices: ^Fuzz_Choices, known: u64) -> (argument: operation_sequence.Argument, refused: bool) {
	if known == 0 {
		return {source = .Value, value = fuzz_choice_word(choices, 8)}, false
	}
	form := fuzz_member_at(Fuzz_Flags_Form, fuzz_choice_below(choices, fuzz_member_count(Fuzz_Flags_Form)))
	subset := known & fuzz_choice_word(choices, 8)
	unknown := ~known
	switch form {
	case .Known:
		return {source = .Value, value = subset}, false
	case .One_Unknown_Bit:
		if unknown != 0 {
			return {source = .Value, value = subset | (unknown & (~unknown + 1))}, true
		}
	case .Every_Bit:
	}
	return {source = .Value, value = max(u64)}, unknown != 0
}

// The forms of a set of flags, the simplest first.
@(private = "file")
Fuzz_Flags_Form :: enum u8 {
	Known, // A subset of the flags that the operation knows.
	One_Unknown_Bit, // The same, with the lowest bit that the operation does not know.
	Every_Bit,
}

// The forms of a choice or a bounded value, the simplest first.
@(private = "file")
Fuzz_Largest_Form :: enum u8 {
	Up_To_The_Largest,
	One_Past_The_Largest,
	Largest_Word,
}

// fuzz_largest_generate gives a choice or a bounded value: up to the
// largest, the largest plus one, or the largest word.
@(private = "file")
fuzz_largest_generate :: proc(choices: ^Fuzz_Choices, largest: u64) -> (argument: operation_sequence.Argument, refused: bool) {
	form := fuzz_member_at(Fuzz_Largest_Form, fuzz_choice_below(choices, fuzz_member_count(Fuzz_Largest_Form)))
	switch form {
	case .Up_To_The_Largest:
		return {source = .Value, value = u64(fuzz_choice_below(choices, int(min(largest, 1 << 16)) + 1))}, false
	case .One_Past_The_Largest:
		return {source = .Value, value = largest + 1}, true
	case .Largest_Word:
	}
	return {source = .Value, value = max(u64)}, largest != max(u64)
}

// ---------------------------------------------------------------------
// The fuzz targets.

// The sequences of one execution, outside the stack: each one is about
// 26 KiB.
@(private = "file")
fuzz_sequence_read: operation_sequence.Sequence
@(private = "file")
fuzz_sequence_generated: operation_sequence.Sequence
@(private = "file")
fuzz_sequence_bytes: [operation_sequence.SEQUENCE_BYTES_MOST]u8
// The generated target has its own memory: the host tests run the two
// targets on two threads at once, where the fuzz engine runs one target in
// each process.
@(private = "file")
fuzz_sequence_generated_bytes: [operation_sequence.SEQUENCE_BYTES_MOST]u8
@(private = "file")
fuzz_sequence_generated_read: operation_sequence.Sequence

// fuzz_operation_sequence_execute: a sequence that check accepts follows
// each rule of its format and writes again to its own bytes; a refusal
// names its problem with the step, the area or the argument that the
// problem names, changes no byte and leaves the sequence zero.
fuzz_operation_sequence_execute :: proc(input: []u8) -> Fuzz_Verdict {
	before := slice.clone(input, context.temp_allocator)
	sequence := &fuzz_sequence_read
	refusal := operation_sequence.check(input, sequence)
	if !slice.equal(before, input) {
		return fuzz_broken(.Contract, "check changed the bytes of the sequence")
	}
	if refusal.problem != .None {
		if sequence^ != (operation_sequence.Sequence{}) {
			return fuzz_broken(.Contract, "the refusal %v left a part of the sequence", refusal.problem)
		}
		if !fuzz_operation_sequence_refusal_named(refusal) {
			return fuzz_broken(.Contract, "the refusal %v names the index %d and the argument %d", refusal.problem, refusal.index, refusal.argument)
		}
		return FUZZ_PASSED
	}
	if text := fuzz_operation_sequence_rule_broken(sequence); text != "" {
		return fuzz_broken(.Contract, "check accepts a sequence where %s", text)
	}
	written, ok := operation_sequence.write(fuzz_sequence_bytes[:], sequence)
	if !ok || !slice.equal(written, input) {
		return fuzz_broken(.Round_Trip, "write of a sequence that check accepted gives other bytes")
	}
	return FUZZ_PASSED
}

// fuzz_operation_sequence_refusal_named says if a refusal names what its
// problem names: nothing for the header and the size, an area, a step, or
// a step and its argument.
@(private = "file")
fuzz_operation_sequence_refusal_named :: proc(refusal: operation_sequence.Refusal) -> bool {
	step_named := refusal.index >= 0 && refusal.index < operation_sequence.STEPS_MOST
	switch refusal.problem {
	case .None:
		return false
	case .Too_Small, .Magic, .Format, .Step_Count, .Area_Count, .Size:
		return refusal.index == -1 && refusal.argument == -1
	case .Area_Pages, .Area_Content:
		return refusal.index >= 0 && refusal.index < operation_sequence.AREAS_MOST && refusal.argument == -1
	case .Entry_First:
		return refusal.index == 0 && refusal.argument == -1
	case .Operation_Word, .Step_Flags, .Entry_Steps:
		return step_named && refusal.argument == -1
	case .Argument_Source, .Unused_Field, .Area_Index, .Offset, .Thread_Entry, .Result_Later, .Result_Same_Entry, .Result_Place:
		return step_named && refusal.argument >= 0 && refusal.argument < operation_sequence.ARGUMENTS
	}
	return false
}

// fuzz_operation_sequence_rule_broken reads an accepted sequence again by
// the rules of the format, as the runner will rely on them: the bounds of
// the areas, the kernel entries, and each argument. "" when each rule
// holds.
@(private = "file")
fuzz_operation_sequence_rule_broken :: proc(sequence: ^operation_sequence.Sequence) -> string {
	if sequence.step_count < 0 || sequence.step_count > operation_sequence.STEPS_MOST || sequence.area_count < 0 || sequence.area_count > operation_sequence.AREAS_MOST {
		return fmt.tprintf("%d steps and %d areas", sequence.step_count, sequence.area_count)
	}
	content := 0
	for area, index in sequence.areas[:sequence.area_count] {
		if area.pages < 1 || area.pages > operation_sequence.AREA_PAGES_MOST || area.content_bytes < 0 || area.content_bytes > area.pages * operation.PAGE_SIZE {
			return fmt.tprintf("the area %d has %d pages and %d bytes of content", index, area.pages, area.content_bytes)
		}
		content += area.content_bytes
	}
	if content > operation_sequence.CONTENT_BYTES_MOST {
		return fmt.tprintf("the areas hold %d bytes of content", content)
	}
	entry_first := 0
	entry_steps := 0
	for step in 0 ..< sequence.step_count {
		item := &sequence.steps[step]
		if item.operation & operation.COMMAND_NAMES_ERROR_DETAILS != 0 {
			return fmt.tprintf("the step %d has the operation word %x", step, item.operation)
		}
		if .Same_Entry in item.flags {
			entry_steps += 1
			if step == 0 || entry_steps > operation_sequence.ENTRY_STEPS_MOST {
				return fmt.tprintf("the step %d is the step %d of its kernel entry", step, entry_steps)
			}
		} else {
			entry_first = step
			entry_steps = 1
		}
		for argument, index in item.arguments {
			if text := fuzz_operation_argument_rule_broken(sequence, argument, entry_first); text != "" {
				return fmt.tprintf("the argument %d of the step %d %s", index, step, text)
			}
		}
	}
	return ""
}

@(private = "file")
fuzz_operation_argument_rule_broken :: proc(sequence: ^operation_sequence.Sequence, argument: operation_sequence.Argument, entry_first: int) -> string {
	area_named := argument.area >= 0 && argument.area < sequence.area_count
	switch argument.source {
	case .Value, .Budget, .Log, .Machine, .Thread_Entry:
	case .Area_Handle:
		if !area_named {
			return fmt.tprintf("names the area %d", argument.area)
		}
	case .Area_Address:
		if !area_named {
			return fmt.tprintf("names the area %d", argument.area)
		}
		if argument.offset > u64(sequence.areas[argument.area].pages + 1) * operation.PAGE_SIZE - 1 {
			return fmt.tprintf("has the offset %d", argument.offset)
		}
	case .Result:
		if argument.step < 0 || argument.step >= entry_first || argument.place < 0 || argument.place >= operation_sequence.ARGUMENTS || argument.offset > operation_sequence.RESULT_OFFSET_MOST {
			return fmt.tprintf("names the value %d of the step %d plus %d", argument.place, argument.step, argument.offset)
		}
	}
	return ""
}

// fuzz_operation_sequence_seeds gives a sequence of each argument source,
// the empty sequence, a kernel entry of several steps, the sequences of
// the generator for a few fixed choices, and bytes one short of a whole
// sequence.
fuzz_operation_sequence_seeds :: proc(seeds: ^[dynamic][]u8) {
	write_seed :: proc(seeds: ^[dynamic][]u8, sequence: ^operation_sequence.Sequence) {
		out := make([]u8, operation_sequence.SEQUENCE_BYTES_MOST)
		written, ok := operation_sequence.write(out, sequence)
		if ok {
			append(seeds, written)
		}
	}
	sequence := new(operation_sequence.Sequence, context.temp_allocator)
	write_seed(seeds, sequence)

	sequence.area_count = 2
	sequence.areas[0] = {pages = 1, content_bytes = 5}
	copy(sequence.content[:], "hello")
	sequence.areas[1] = {pages = operation_sequence.AREA_PAGES_MOST}
	sequence.step_count = 4
	sequence.steps[0] = {operation = u32(operation.Operation.Memory_Create)}
	sequence.steps[0].arguments[0] = {source = .Budget}
	sequence.steps[0].arguments[1] = {source = .Value, value = 1}
	sequence.steps[1] = {operation = u32(operation.Operation.Log), flags = {.No_Error_Details}}
	sequence.steps[1].arguments[0] = {source = .Log}
	sequence.steps[1].arguments[1] = {source = .Area_Address, area = 0}
	sequence.steps[1].arguments[2] = {source = .Value, value = 5}
	sequence.steps[2] = {operation = u32(operation.Operation.Thread_Create), flags = {.Same_Entry}}
	sequence.steps[2].arguments[0] = {source = .Budget}
	sequence.steps[2].arguments[1] = {source = .Thread_Entry, entry = .Return}
	sequence.steps[2].arguments[2] = {source = .Area_Address, area = 1, offset = operation_sequence.AREA_PAGES_MOST * operation.PAGE_SIZE - 8}
	sequence.steps[3] = {operation = u32(operation.Operation.Memory_Map)}
	sequence.steps[3].arguments[0] = {source = .Result, step = 0}
	sequence.steps[3].arguments[1] = {source = .Area_Handle, area = 1}
	sequence.steps[3].arguments[2] = {source = .Machine}
	write_seed(seeds, sequence)
	whole := seeds^[len(seeds^) - 1]
	append(seeds, slice.clone(whole[:len(whole) - 1]))

	choice_inputs := [?][]u8{{}, {0xFF}, {3, 2, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}}
	for input in choice_inputs {
		choices := fuzz_choices_of(input)
		fuzz_operation_sequence_generate(&choices, sequence)
		write_seed(seeds, sequence)
	}
}

// fuzz_operation_sequence_regions gives the header, the area records and
// the step records of an input, as far as its bytes and its counts go.
fuzz_operation_sequence_regions :: proc(input: []u8, regions: ^[dynamic]Fuzz_Region) {
	if len(input) < operation_sequence.HEADER_SIZE {
		return
	}
	append(regions, Fuzz_Region{offset = 0, type = operation_sequence.Header_Record, count = 1})
	header := (^operation_sequence.Header_Record)(raw_data(input))^
	area_count := min(int(header.area_count), operation_sequence.AREAS_MOST, (len(input) - operation_sequence.HEADER_SIZE) / operation_sequence.AREA_SIZE)
	if area_count > 0 {
		append(regions, Fuzz_Region{offset = operation_sequence.HEADER_SIZE, type = operation_sequence.Area_Record, count = area_count})
	}
	steps_offset := operation_sequence.step_offset(area_count, 0)
	step_count := min(int(header.step_count), operation_sequence.STEPS_MOST, max(len(input) - steps_offset, 0) / operation_sequence.STEP_SIZE)
	if step_count > 0 {
		append(regions, Fuzz_Region{offset = steps_offset, type = operation_sequence.Step_Record, count = step_count})
	}
}

// fuzz_operation_sequence_generated_execute: each sequence that the
// generator builds is one that the writer writes and `check` accepts, and
// `check` reads it back whole.
fuzz_operation_sequence_generated_execute :: proc(input: []u8) -> Fuzz_Verdict {
	choices := fuzz_choices_of(input)
	generated := &fuzz_sequence_generated
	fuzz_operation_sequence_generate(&choices, generated)
	written, ok := operation_sequence.write(fuzz_sequence_generated_bytes[:], generated)
	if !ok {
		return fuzz_broken(.Contract, "the writer refuses a sequence of the generator: %d steps, %d areas", generated.step_count, generated.area_count)
	}
	refusal := operation_sequence.check(written, &fuzz_sequence_generated_read)
	if refusal.problem != .None {
		return fuzz_broken(.Contract, "check refuses a sequence of the generator: %v at the index %d, the argument %d; %d bytes written, %d steps, %d areas", refusal.problem, refusal.index, refusal.argument, len(written), generated.step_count, generated.area_count)
	}
	if fuzz_sequence_generated_read != generated^ {
		return fuzz_broken(.Round_Trip, "check reads another sequence than the generator built")
	}
	return FUZZ_PASSED
}
