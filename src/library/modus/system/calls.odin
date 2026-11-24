package system

import "base:intrinsics"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/root_ring"

// The caller side of one description, three ways to call
// (docs/MODULE_CONTRACT.md, "Tables and bytes as parameters"):
//
//   call_direct      a module in this process (a module space): the
//                    registers of the call form, no copy.
//   call_isolated    a call host or a service: the same arguments go into
//                    the call region or into a lent memory object, and
//                    the answer comes back into the memory of the caller.
//
// The arguments are the same isolated.Argument records in each way: the
// export does not know which way ran.

// export_call takes one integer for each argument that a description can
// have: the receiver of an isolated call passes its isolated.Call to it.
#assert(CALL_INTEGERS == module.CALL_WORD_CAPACITY)

// A way to the exports of a module in another process: a call host that
// this process started, or a connection to a service.
Call_Connection :: struct {
	process:       Handle, // The call host or the service: its state says if it stopped.
	ring_memory:   Handle, // The memory of the call ring.
	region_memory: Handle, // The memory of the call region.
	files_memory:  Handle, // A call host: the page of the list of its files.
	calls:         ring.Ring, // The call ring, mapped in this process.
	region:        []u8, // The call region, mapped in this process.
	tag:           u32, // The tag of the last call: each call takes the next one, and its completion must have it.
	module_hash:   [32]u8, // A service: the hash of the module file of its process, which describes its exports (Root_Command.Connect).
}

// call_direct calls an export of a module that is in this process, with
// the call form: an Integer and a Handle in a register, a Text as the
// address of its slice, a Record as its address, a Table or Bytes as the
// address of a table place over the memory of the argument. The export
// works in that memory: a Change table and an Append table are changed in
// place, and the count of an Append table is its new count. An export with
// an error record can fail: it writes the record at `error`, and the call
// outcome says how it ended (src/md/api/call_outcome.md). An export that
// cannot fail gives Succeeded.
// It does the descriptions with an Integer, an Enum or no result; another
// result gives Operation_Unsupported with Unsupported: else it gives the
// address of the error record where the export reads its buffer. It checks the
// description as the receiver of an isolated call does (record_size), and
// the record of each table.
call_direct :: proc "contextless" (file: []u8, address: uintptr, function: module.Function, arguments: []isolated.Argument, error: ^errors.Error_Record = nil) -> (result: i64, outcome: call_outcome.Call_Outcome) {
	function := function
	not_done :: proc "contextless" (error: ^errors.Error_Record, argument: int, value: u64) -> (i64, call_outcome.Call_Outcome) {
		return path_failure(error, .Operation_Unsupported, errors.error_make(.Unsupported, .None, i64(argument), i64(value)))
	}
	if _, described := isolated.record_size(function); !described {
		return not_done(error, 0, 0)
	}
	// Another count of arguments than the description has is a fault of the
	// arguments, as the receiver of an isolated call says.
	if len(arguments) != int(function.parameter_count) {
		return path_failure(error, .Argument_Refused, errors.error_make(.Bad_Value, .None, 0, i64(len(arguments)), i64(function.parameter_count)))
	}
	if function.result != u8(module.Type.Integer) && function.result != u8(module.Type.None) && function.result != u8(module.Type.Enum) {
		return not_done(error, 0, u64(function.result))
	}
	integers: [CALL_INTEGERS]u64
	places: [module.PARAMETER_CAPACITY]module.Table_Place
	slices: [module.PARAMETER_CAPACITY]isolated.Slice
	for word, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		argument := &arguments[index]
		// record_size refused each byte that names no type, and the type
		// None; the border reads the byte again.
		type, type_ok := module.type_of_word(word)
		if !type_ok {
			return not_done(error, index + 1, u64(word))
		}
		// The word of the value in the call form; an optional parameter has
		// its Presence word before it, and an absent one gives 0 and 0.
		word_index := module.parameter_word_index(function, index)
		if module.parameter_optional(function, index) {
			integers[word_index - 1] = u64(argument.presence)
			if argument.presence != .Given {
				continue
			}
		}
		switch type {
		case .None, .Integer, .Handle, .Enum:
			integers[word_index] = argument.integer
		case .Text:
			slices[index] = {u64(uintptr(raw_data(argument.text))), u64(len(argument.text))}
			integers[word_index] = u64(uintptr(&slices[index]))
		case .Record:
			integers[word_index] = u64(uintptr(raw_data(argument.record)))
		case .Table, .Bytes:
			size, _, valid := isolated.table_record(file, word, function.parameter_details[index])
			if !valid {
				return not_done(error, index + 1, u64(function.parameter_details[index]))
			}
			capacity := u64(len(argument.table.records)) / size
			// An Append count can be over the capacity: earlier calls did
			// not fit (docs/MODULE_CONTRACT.md, "Did not fit, across calls").
			if function.parameter_directions[index] != u8(module.Direction.Append) && argument.table.count > capacity {
				return not_done(error, index + 1, argument.table.count)
			}
			places[index] = {address = u64(uintptr(raw_data(argument.table.records))), count = argument.table.count, capacity = capacity}
			integers[word_index] = u64(uintptr(&places[index]))
		}
	}
	// record_size checked that an argument of the call form is free for it.
	local_error: errors.Error_Record
	if function.error_record != 0 {
		integers[module.parameter_word_count(function)] = u64(uintptr(error != nil ? error : &local_error))
	}
	floats: [CALL_FLOATS]u64
	out: [CALL_RESULTS]u64
	export_call(address, &integers, &floats, &out)
	for word, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		if isolated.is_table_or_bytes(word) && function.parameter_directions[index] == u8(module.Direction.Append) {
			arguments[index].table.count = places[index].count
		}
	}
	value, outcome_word := isolated.export_answer(function, {out[0], out[1]})
	// The module of the export is not a module that this process was built
	// with: its word goes through the border.
	unreadable: errors.Error_Record
	outcome, unreadable = call_outcome.outcome_of_word(outcome_word)
	if outcome == .Succeeded {
		return i64(value), .Succeeded
	}
	if unreadable.kind != 0 && error != nil {
		error^ = unreadable
	}
	return 0, outcome
}

// call_isolated calls an export of a module in another process, through a
// connection. It lends the handles and the memory objects of the
// arguments, writes the argument record, waits for the answer, and copies
// the answer of each Change and Append table back into the memory of the
// caller. It gives the value and the call outcome, and the error record at
// `error` when the outcome is not Succeeded: of the export, of the receiver
// that refused the call, or of the path (src/md/api/call_outcome.md, "The
// borders of the isolated call"). Of the tables of an export that failed,
// only its table of error details comes back.
//
// The seam of the three forms: a table argument with a memory object
// (Table_Argument.memory_handle) goes into the call region when it fits there, and
// through its memory object only when it does not: the measures of the
// process tables give the call region the lower cost at each size that
// fits (docs/MODULE_CONTRACT.md). keep_memory_objects lends each memory
// object as given: for a measure, or for a table that the caller wants in
// one place.
//
// `rows`: the memory of the caller for the records of a Table result. The
// result is then the count of the records that were copied there: the
// records that the export gave, at most those that `rows` holds.
//
// `deadline`: a time of the clock of the machine past which the caller
// stops to wait, with Deadline_Passed_During_The_Call, while the other process runs. A call of
// work that the caller does not trust (a compiler on a source of a
// principal, or a builder) gives the hang bound of an answer (answer_deadline):
// else a source that makes it loop holds the caller for ever. The caller then
// ends the call host. WAIT_FOREVER (or 0): only the stop of the process ends it.
call_isolated :: proc "contextless" (connection: ^Call_Connection, file: []u8, export: u32, arguments: []isolated.Argument, error: ^errors.Error_Record = nil, keep_memory_objects := false, rows: []u8 = nil, deadline: u64 = WAIT_FOREVER) -> (result: i64, outcome: call_outcome.Call_Outcome) {
	bound := deadline == 0 ? WAIT_FOREVER : deadline
	// A deadline that passed before the call sends nothing: no work starts.
	// WAIT_FOREVER skips reading the time page so a Process_Flag.No_Clock
	// caller never faults on the unmapped time page.
	if bound != WAIT_FOREVER && deadline_passed(time(), bound) {
		// Nothing left, so nothing ran: the call is not in doubt.
		return path_failure(error, .Callee_Unavailable, errors.error_make(.No_Answer, .Milliseconds))
	}
	function, described := module.function(file, export)
	if !described {
		return path_failure(error, .Operation_Unsupported, errors.error_make(.Unsupported, .None, 0, i64(export)))
	}
	// lend writes the handles of the receiver in the arguments: the caller
	// keeps its own for the next call. (A Handle field of a Record is
	// written in the bytes of the record: give a copy of the record.)
	kept_integers: [module.PARAMETER_CAPACITY]u64
	kept_memories: [module.PARAMETER_CAPACITY]u64
	for argument, index in arguments[:min(len(arguments), module.PARAMETER_CAPACITY)] {
		kept_integers[index], kept_memories[index] = argument.integer, argument.table.memory_handle
	}
	defer for &argument, index in arguments[:min(len(arguments), module.PARAMETER_CAPACITY)] {
		argument.integer, argument.table.memory_handle = kept_integers[index], kept_memories[index]
	}
	if !keep_memory_objects {
		for &argument in arguments[:min(len(arguments), module.PARAMETER_CAPACITY)] {
			argument.table.memory_handle = 0
		}
		// Each table that does not fit takes its memory object back.
		for _ in 0 ..< module.PARAMETER_CAPACITY {
			missing := isolated.room_missing(file, function, arguments, u64(len(connection.region)))
			if missing.parameter == 0 || kept_memories[missing.parameter - 1] == 0 {
				break
			}
			arguments[missing.parameter - 1].table.memory_handle = kept_memories[missing.parameter - 1]
		}
	}
	lending: Lending
	defer lend_end(&lending)
	if lent := lend(file, function, arguments, connection.ring_memory, &lending); lent != .Succeeded {
		return path_failure(error, lent, errors.error_make(.Refused, .Kernel_Status, 0, 0, 0, i64(lent)))
	}
	offset, size, result_place, encoded := isolated.encode(file, function, arguments, connection.region)
	if !encoded {
		missing := isolated.room_missing(file, function, arguments, u64(len(connection.region)))
		return path_failure(error, .Argument_Refused, errors.error_make(.Too_Long, .Bytes, i64(missing.parameter), i64(min(missing.needed, 1 << 62)), i64(len(connection.region))))
	}
	connection.tag += 1
	if !send(&connection.calls.commands, ring.Record{kind = export, tag = connection.tag, values = {0 = offset, 1 = size}}) {
		return path_failure(error, .Callee_Busy, errors.error_make(.Full, .Requests, 0, ring.CAPACITY, ring.CAPACITY))
	}
	for {
		wait := wait_begin()
		// The state before the ring: a process that answered and stopped is
		// read with its answer.
		state, stop_cause, stop_outcome := process_state(connection.process)
		now := bound == WAIT_FOREVER ? u64(0) : time()
		completion, waited := call_answer_step(&connection.calls, connection.tag, now, bound, state)
		switch waited {
		case .Waits:
			wait_records(&wait, &connection.calls.completions)
			if wait_spin(&wait) {
				continue
			}
			wait_end(&wait, bound)
			continue
		case .Stopped:
			// The library cannot tell if the receiver read the command.
			return path_failure(error, .Callee_Stopped_During_The_Call, errors.error_make(.Callee_Stopped, .None, 0, i64(stop_cause), 0, i64(stop_outcome)))
		case .Deadline_Passed:
			// The command left, and the callee can still run it.
			return path_failure(error, .Deadline_Passed_During_The_Call, errors.error_make(.No_Answer, .Milliseconds))
		case .Answered:
		}
		// The other process wrote the completion: it goes through its border.
		value, answered, record := isolated.answer_of_completion(completion)
		if answered != .Succeeded {
			if error != nil {
				error^ = record
			}
			// The error details come back with the error record: one
			// answer. A table of details that came back wrong makes the
			// whole answer unreadable.
			if answered != .Answer_Unreadable && function.error_record != 0 {
				if problem, parameter := isolated.error_details_return(file, function, arguments, connection.region, offset); problem != .None {
					return path_failure(error, .Answer_Unreadable, errors.error_make(.Bad_Value, .Records, i64(parameter), i64(problem)))
				}
			}
			return 0, answered
		}
		if problem, parameter := isolated.tables_return(file, function, arguments, connection.region, offset); problem != .None {
			return path_failure(error, .Answer_Unreadable, errors.error_make(.Bad_Value, .Records, i64(parameter), i64(problem)))
		}
		// A Table result: the records are in the call region, and the
		// count comes from the other process. The caller gets the
		// records that fit `rows`, and the count of them as the result:
		// never more than the region holds.
		if rows != nil && function.result == u8(module.Type.Table) && value > 0 {
			described, has_record := module.record_type(file, function.result_detail)
			if !has_record || described.size == 0 {
				return path_failure(error, .Answer_Unreadable, errors.error_make(.Bad_Value, .Records, 0, i64(function.result_detail)))
			}
			table, _ := isolated.result_table(connection.region, result_place, u64(value), u64(described.size))
			copied := copy(rows, table) / int(described.size)
			return i64(copied), .Succeeded
		}
		return value, .Succeeded
	}
}

// deadline_passed says if a caller stops waiting at the time now: 0 and
// WAIT_FOREVER are no deadline, and the time of the deadline itself has passed it.
deadline_passed :: proc "contextless" (now: u64, deadline: u64) -> bool {
	return deadline != 0 && deadline != WAIT_FOREVER && now >= deadline
}

// What one read of a call ring found for a call.
Call_Wait :: enum u8 {
	Answered, // The completion with the tag of the call came.
	Waits, // The process runs and the deadline did not pass: wait again.
	Stopped, // The process stopped, or the handle names none: no answer comes.
	Deadline_Passed, // The process runs and the deadline passed.
}

// call_answer_step reads the completions of a call ring once, after the
// caller read the state of the other process. The completion with the tag
// decides first; a completion with another tag answers a call that the
// caller gave up, and is skipped. With no answer, answer_wait_of decides.
// It is pure, so a host test gives it a process that never answers.
call_answer_step :: proc "contextless" (calls: ^ring.Ring, tag: u32, now, deadline: u64, state: op.Process_State) -> (completion: ring.Record, waited: Call_Wait) {
	for _ in 0 ..< ring.CAPACITY {
		record, has := receive(&calls.completions)
		if !has {
			break
		}
		if record.tag == tag {
			return record, .Answered
		}
	}
	switch answer_wait_of(now, deadline, state) {
	case .Waits:
		return {}, .Waits
	case .Stopped:
		return {}, .Stopped
	case .Silent:
		return {}, .Deadline_Passed
	}
	return {}, .Stopped
}

// connection_to_renew says whether a call of this outcome leaves its
// connection in a state that the caller cannot trust: an outcome of the
// path (Callee_Stopped_During_The_Call, Connection_Ended_During_The_Call,
// Deadline_Passed_During_The_Call, Answer_Unreadable), after which an
// answer can still come on the ring or the callee is gone. The caller ends
// the connection and opens a new one for its next call. Each other outcome
// is an answer of the callee, Callee_Unavailable too, and the connection
// serves on.
connection_to_renew :: proc "contextless" (outcome: call_outcome.Call_Outcome) -> bool {
	return call_outcome.effect_group_of(outcome) == .Change_In_Doubt
}

// path_failure ends a call that the path ended, with no outcome of the
// export: it writes the record of the path at error, and gives the value 0
// with the outcome (src/md/api/call_outcome.md, "The failures of the path").
path_failure :: proc "contextless" (error: ^errors.Error_Record, outcome: call_outcome.Call_Outcome, record: errors.Error_Record) -> (i64, call_outcome.Call_Outcome) {
	if error != nil {
		error^ = record
	}
	return 0, outcome
}

// own_operation_outcome gives the call outcome of a kernel refusal of an
// operation that an export runs on its own objects: its budget, its scratch
// memory, its own grant. A refusal on the callee's own objects never blames
// the caller: no change of its arguments or grants makes the call run.
own_operation_outcome :: proc "contextless" (outcome: call_outcome.Call_Outcome) -> call_outcome.Call_Outcome {
	switch outcome {
	case .Succeeded:
		return .Succeeded
	case .Callee_Busy:
		return .Callee_Busy
	case .Budget_Or_Capacity_Exhausted:
		return .Budget_Or_Capacity_Exhausted
	case .Argument_Refused, .Nothing_Has_That_Name, .Name_Already_Taken, .Grant_Or_Right_Missing, .Wrong_State, .Another_Change_Came_First, .Operation_Unsupported, .Data_Damaged, .Callee_Unavailable, .Stopped_After_A_Partial_Change, .Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call, .Deadline_Passed_During_The_Call, .Answer_Unreadable:
		return .Callee_Unavailable
	}
	return .Callee_Unavailable
}

// The log records of each second that a call host gets by default.
CALL_HOST_LOG_RECORDS :: 100

// The pages of a call host when its starter names none.
CALL_HOST_PAGES :: 512

// The mappings that a starter adds to a call host, past the files.
CALL_HOST_ADDED_MAPPING_CAPACITY :: 4

// What a starter adds to the context of a call host, past its call ring and
// its call region: the stores of a builder (modus:contract/builder). A
// slot with no handle adds nothing. call_host_start refuses a handle in the
// slot of the call ring or of the call region, and more mappings than
// CALL_HOST_ADDED_MAPPING_CAPACITY.
Call_Host_Context :: struct {
	grants:    [op.CONTEXT_HANDLES]Grant,
	mappings:  []Mapping,
	pages:     u64, // The pages of the budget of the call host. 0: CALL_HOST_PAGES.
	processes: u64, // The processes of the budget of the call host. 0: 1.
	no_clock:  bool, // Create the call host with Process_Flag.No_Clock (no time page, rdtsc/rdtscp trap).
}

// call_host_start starts a call host (the module "host" of the boot
// image) for one module, and maps the file of the module and of its
// imports in it, read-only: the call host has the call ring and the call
// region, and no other handle. image_memory is the handle of the boot
// image. values_with_seed has the random seed of the call host, which the
// caller draws from its own generator (random.values_with_seed of no
// values): a process does not start with no seed. On a failure of the load,
// load_error has the record that the call host wrote. log_records are the
// log records of each second that the call host takes from the budget of
// the caller: 100 by default, so a caller with 1000 records starts nine
// hosts and keeps 100; a caller that starts more gives each fewer.
//
// `added`: the handles, the mappings and the pages that the starter adds
// (Call_Host_Context); nil adds none.
call_host_start :: proc "contextless" (image: []u8, image_memory: Handle, file: []u8, name: string, values_with_seed: [op.CONTEXT_VALUES]u64, load_error: ^module.Load_Error, log_records: u64 = CALL_HOST_LOG_RECORDS, added: ^Call_Host_Context = nil) -> (connection: Call_Connection, status: call_outcome.Call_Outcome) {
	if added != nil && (added.grants[isolated.GRANT_RING].handle != 0 || added.grants[isolated.GRANT_REGION].handle != 0 || len(added.mappings) > CALL_HOST_ADDED_MAPPING_CAPACITY) {
		return {}, .Argument_Refused
	}
	files: [MODULE_SPACE_CAPACITY + IMPORT_CAPACITY]^info.Image_Entry
	source := Load_Source {
		image = image,
	}
	count := source_closure(source, file, &files)
	list_size := size_of(info.Image_Header) + count * size_of(info.Image_Entry)
	if count == 0 || list_size > PAGE_SIZE {
		return {}, .Argument_Refused
	}
	defer if status != .Succeeded {
		call_connection_end(&connection)
	}
	connection.files_memory = memory_create(1) or_return
	page_address := memory_map(connection.files_memory) or_return
	page := ([^]u8)(page_address)[:PAGE_SIZE]
	(^info.Image_Header)(page_address)^ = {magic = info.IMAGE_MAGIC, count = u32(count)}
	entries := ([^]info.Image_Entry)(raw_data(page[size_of(info.Image_Header):]))[:count]
	mappings: [MODULE_SPACE_CAPACITY + IMPORT_CAPACITY + 1 + CALL_HOST_ADDED_MAPPING_CAPACITY]Mapping
	mappings[0] = {memory = connection.files_memory, address = isolated.FILE_ADDRESS}
	offset := u64(PAGE_SIZE)
	for item, index in files[:count] {
		if item.offset % PAGE_SIZE != 0 {
			memory_unmap(page_address)
			return connection, .Argument_Refused
		}
		entries[index] = item^
		entries[index].offset = offset
		pages := (item.size + PAGE_SIZE - 1) / PAGE_SIZE
		mappings[index + 1] = {memory = image_memory, address = isolated.FILE_ADDRESS + offset, first = item.offset / PAGE_SIZE, page_count = pages}
		offset += pages * PAGE_SIZE
	}
	memory_unmap(page_address)
	connection.ring_memory, connection.calls = ring_create() or_return
	connection.region_memory = memory_create(isolated.REGION_PAGES) or_return
	region_address := memory_map(connection.region_memory) or_return
	connection.region = ([^]u8)(region_address)[:isolated.REGION_PAGES * PAGE_SIZE]
	grants: [op.CONTEXT_HANDLES]Grant
	mapping_count := count + 1
	pages := u64(CALL_HOST_PAGES)
	processes := u64(1)
	if added != nil {
		grants = added.grants
		for item in added.mappings {
			mappings[mapping_count] = item
			mapping_count += 1
		}
		if added.pages != 0 {
			pages = added.pages
		}
		if added.processes != 0 {
			processes = added.processes
		}
	}
	values := values_with_seed
	grants[isolated.GRANT_RING] = {connection.ring_memory, {.Read, .Write}}
	grants[isolated.GRANT_REGION] = {connection.region_memory, {.Read, .Write}}
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = offset
	process_flags: op.Process_Flags
	if added != nil && added.no_clock {
		process_flags += {.No_Clock}
	}
	connection.process = process_start(image_find(image, "host"), name, grants, values, {pages = pages, processes = processes, threads = 1, processor = 500_000, log_records = log_records}, mappings[:mapping_count], process_flags = process_flags) or_return
	// The first completion says if the call host loaded the module.
	switch connection_ready_wait(&connection.calls, connection.process) {
	case .Ready:
		return connection, .Succeeded
	case .Load_Failed:
		loaded: module.Load_Error
		intrinsics.mem_copy_non_overlapping(&loaded, raw_data(connection.region), size_of(module.Load_Error))
		if load_error != nil {
			load_error^ = loaded
		}
		return connection, loaded.stage == u32(module.Load_Stage.Find) ? .Nothing_Has_That_Name : .Argument_Refused
	case .Refused:
		return connection, .Callee_Unavailable
	}
	return connection, .Callee_Unavailable
}

// call_host_start_from_memory starts a call host from in-memory host and
// target module bytes (zero external imports), allowing a zero-grant builder
// module without GRANT_IMAGE to invoke c_compiler and assemble in isolated
// child call hosts.
call_host_start_from_memory :: proc "contextless" (host_file: []u8, module_memory: Handle, module_file: []u8, name: string, values_with_seed: [op.CONTEXT_VALUES]u64, load_error: ^module.Load_Error, log_records: u64 = CALL_HOST_LOG_RECORDS, added: ^Call_Host_Context = nil) -> (connection: Call_Connection, status: call_outcome.Call_Outcome) {
	if len(host_file) == 0 || module_memory == 0 || len(module_file) == 0 {
		return {}, .Argument_Refused
	}
	if module.validate(host_file) != .None || module.validate(module_file) != .None {
		return {}, .Argument_Refused
	}
	if module.count(module_file, .Imports) > 1 {
		return {}, .Argument_Refused
	}
	if added != nil && (added.grants[isolated.GRANT_RING].handle != 0 || added.grants[isolated.GRANT_REGION].handle != 0 || len(added.mappings) > CALL_HOST_ADDED_MAPPING_CAPACITY) {
		return {}, .Argument_Refused
	}
	defer if status != .Succeeded {
		call_connection_end(&connection)
	}
	connection.files_memory = memory_create(1) or_return
	page_address := memory_map(connection.files_memory) or_return
	page := ([^]u8)(page_address)[:PAGE_SIZE]
	(^info.Image_Header)(page_address)^ = {magic = info.IMAGE_MAGIC, count = 1}
	entry := (^info.Image_Entry)(raw_data(page[size_of(info.Image_Header):]))
	entry^ = {
		offset = PAGE_SIZE,
		size   = u64(len(module_file)),
		hash   = blake3.hash(module_file),
	}
	copy(entry.name[:len(entry.name) - 1], name)
	memory_unmap(page_address)

	module_pages := (u64(len(module_file)) + PAGE_SIZE - 1) / PAGE_SIZE
	offset := u64(PAGE_SIZE) + module_pages * PAGE_SIZE
	mappings: [2 + CALL_HOST_ADDED_MAPPING_CAPACITY]Mapping
	mappings[0] = {memory = connection.files_memory, address = isolated.FILE_ADDRESS}
	mappings[1] = {memory = module_memory, address = isolated.FILE_ADDRESS + PAGE_SIZE, first = 0, page_count = module_pages}
	mapping_count := 2

	connection.ring_memory, connection.calls = ring_create() or_return
	connection.region_memory = memory_create(isolated.REGION_PAGES) or_return
	region_address := memory_map(connection.region_memory) or_return
	connection.region = ([^]u8)(region_address)[:isolated.REGION_PAGES * PAGE_SIZE]
	grants: [op.CONTEXT_HANDLES]Grant
	pages := u64(CALL_HOST_PAGES)
	processes := u64(1)
	if added != nil {
		grants = added.grants
		for item in added.mappings {
			mappings[mapping_count] = item
			mapping_count += 1
		}
		if added.pages != 0 {
			pages = added.pages
		}
		if added.processes != 0 {
			processes = added.processes
		}
	}
	values := values_with_seed
	grants[isolated.GRANT_RING] = {connection.ring_memory, {.Read, .Write}}
	grants[isolated.GRANT_REGION] = {connection.region_memory, {.Read, .Write}}
	values[isolated.VALUE_FILE_ADDRESS] = isolated.FILE_ADDRESS
	values[isolated.VALUE_FILE_SIZE] = offset
	child_no_clock := added != nil && added.no_clock
	process_flags: op.Process_Flags
	if child_no_clock {
		process_flags += {.No_Clock}
	}
	connection.process = process_start(host_file, name, grants, values, {pages = pages, processes = processes, threads = 1, processor = 500_000, log_records = log_records}, mappings[:mapping_count], process_flags = process_flags) or_return
	switch connection_ready_wait(&connection.calls, connection.process, no_clock = child_no_clock) {
	case .Ready:
		return connection, .Succeeded
	case .Load_Failed:
		loaded: module.Load_Error
		intrinsics.mem_copy_non_overlapping(&loaded, raw_data(connection.region), size_of(module.Load_Error))
		if load_error != nil {
			load_error^ = loaded
		}
		return connection, loaded.stage == u32(module.Load_Stage.Find) ? .Nothing_Has_That_Name : .Argument_Refused
	case .Refused:
		return connection, .Callee_Unavailable
	}
	return connection, .Callee_Unavailable
}


// service_connection asks the root service for a connection to the
// service with a name, through a ring to the root service (GRANT_ROOT): a
// ring of the grant Root_Ring or of the grant Connect. It is the one path
// of a Connect: it waits for the answer and for the ready completion with
// the hang bound, and ends what is left when either does not come.
// refused: the answer of a refusal, with its error record, when the caller
// asks for it. The outcome is that of the answer of the root service, or
// of the kernel refusal of a step that maps the connection.
service_connection :: proc "contextless" (requests: ^ring.Ring, tag: u32, name: string, refused: ^ring.Record = nil) -> (connection: Call_Connection, outcome: call_outcome.Call_Outcome) {
	packed := name_pack(name)
	if !send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Connect), tag = tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return {}, .Callee_Busy
	}
	// The root service can start the service first: only the hang bound
	// ends this wait.
	record, answered := root_answer_wait(requests, tag)
	if !answered {
		connect_give_up(requests, tag, tag, packed)
		return {}, .Deadline_Passed_During_The_Call
	}
	if answer, _ := call_outcome.completion_outcome(record.kind, record.values); answer != .Succeeded {
		if refused != nil {
			refused^ = record
		}
		return {}, answer
	}
	connection = {process = Handle(record.values[0]), ring_memory = Handle(record.values[1]), region_memory = Handle(record.values[2])}
	connection.module_hash = transmute([32]u8)[4]u64{record.values[3], record.values[4], record.values[5], record.values[6]}
	status: call_outcome.Call_Outcome
	region_pages: u64
	address: rawptr
	if connection.calls, status = ring_open(connection.ring_memory, receive_handles = true); status == .Succeeded {
		if region_pages, status = memory_size(connection.region_memory); status == .Succeeded {
			address, status = memory_map(connection.region_memory)
		}
	}
	if status != .Succeeded {
		// The root service holds its side of the connection: it ends it,
		// else it refuses the next Connect of this caller to the service.
		service_disconnection(requests, tag, packed)
		call_connection_end(&connection)
		return {}, own_operation_outcome(status)
	}
	connection.region = ([^]u8)(address)[:region_pages * PAGE_SIZE]
	// The service maps the ring when it reads the Connect of the root
	// service, which can be after its start on demand: no call before.
	if connection_ready_wait(&connection.calls, connection.process) != .Ready {
		service_disconnection(requests, tag, packed)
		call_connection_end(&connection)
		return {}, .Callee_Unavailable
	}
	return connection, .Succeeded
}

// service_disconnection asks the root service to end its side of a
// connection that this process gives up: else the root service keeps it,
// and refuses the next Connect of this caller to the service. It waits for
// the answer, so that no answer with the tag stays in the ring for a later
// request that uses the same tag.
@(private = "file")
service_disconnection :: proc "contextless" (requests: ^ring.Ring, tag: u32, packed: [4]u64) {
	if !send(&requests.commands, ring.Record{kind = u32(root_ring.Root_Command.Disconnect), tag = tag, values = {0 = packed[0], 1 = packed[1], 2 = packed[2], 3 = packed[3]}}) {
		return
	}
	root_answer_wait(requests, tag)
}

// call_connection_end closes what this process holds of a connection. A
// call host stops: no handle names it. A service continues.
call_connection_end :: proc "contextless" (connection: ^Call_Connection) {
	if connection.calls.head != nil {
		ring_close(&connection.calls)
	}
	if connection.region != nil {
		memory_unmap(raw_data(connection.region))
	}
	for handle in ([4]Handle{connection.process, connection.ring_memory, connection.region_memory, connection.files_memory}) {
		if handle != 0 {
			close(handle)
		}
	}
	connection^ = {}
}