package system

import "base:intrinsics"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import module "modus:contract/module"
import "modus:contract/ring"

// A service that serves its own exports: other processes call the exports of
// this process with isolated calls (package isolated), while it runs.
//
// The exports of a process have descriptions, as the exports of a module
// have: the caller reads them in the file of the process. This process
// reads them too, in the same file, to decode each argument record.
//
// The root service decides who calls. For each caller it makes one
// connection: a call ring and a call region. It names them on the service
// ring of this process (isolated.Service_Command).
//
//   service, _ := system.service_open(ctx)
//   for {
//       wait: system.Wait
//       system.service_wait(&wait, &service)
//       ... add the other things that the process waits for ...
//       system.wait_end(&wait)
//       system.service_run(&service) // The calls execute here, in this thread.
//   }
//
// A process with no grant to serve has a Service that is all zero:
// service_wait and service_run do nothing.

// One caller of a service: its call ring and its call region, as the root
// service named them with `Connect`, and what it is.
Connection :: struct {
	ring_memory:   Handle, // 0: the place is free.
	region_memory: Handle, // The memory of the call region.
	calls:         ring.Ring, // The call ring, mapped in this process.
	region:        []u8, // The call region, mapped in this process.
	caller:        Name, // The name of the caller, as the root service names it.
	grant:         u64, // What the root service grants to the caller here (isolated.CALLER_AMOUNT_MASK, isolated.CALLER_ERASES_VERSIONS, isolated.CALLER_READS_ONLY, isolated.CALLER_ACTS_FOR_PRINCIPAL).
}

// The connection of the call that runs: see service_caller.
@(private)
serving: ^Connection

// service_caller gives the connection of the call that runs, in an export
// that a service serves: the name of the caller and its grant. It gives nil
// outside such a call. The caller cannot choose either: the root service
// writes them.
service_caller :: proc "contextless" () -> ^Connection {
	return serving
}

// The side of a process that serves its own exports: its service ring and
// its callers. `service_open` makes it; `service_wait` and `service_run`
// serve it in a loop (the example above).
Service :: struct {
	file:        []u8, // The file of this process: the descriptions of its exports.
	names:       ring.Ring, // The service ring.
	connections: [isolated.SERVICE_CONNECTION_CAPACITY]Connection, // The callers; a free place has no ring.
	connected:   int, // The callers connected now.
	calls:       u64, // The calls that this process executed.
	// disconnected, when set, runs at the end of each connection, before its
	// handles close: the service ends what it keeps for that caller, so that
	// a later connection whose ring has the same handle starts with nothing.
	disconnected: proc "contextless" (service: ^Service, connection: ^Connection),
	// principal_keys, when set, takes the keys of a named principal that the
	// root service sends (Principal_Identity, Principal_Storage_Key,
	// Principal_Locked). Only the holder of the role Storage sets it; each
	// other service refuses them.
	principal_keys: proc "contextless" (service: ^Service, command: isolated.Service_Command, values: ^[7]u64),
}

// The service ring and the call ring of each caller, two words each, take
// at most half of the largest wait of the kernel: the other half is for the
// other words of the service. Past the 64 words on the stack of a thread
// (op.WORD_WAIT_INLINE), a wait needs a wait set of its own.
#assert(2 * (1 + isolated.SERVICE_CONNECTION_CAPACITY) <= op.WORD_WAIT_MOST / 2)

// service_open opens the service ring of this process (`GRANT_SERVICE`) and
// the file of its exports (`GRANT_VALUE_FILE_ADDRESS`). ok is false, and the
// service is all zero, for a process with no grant to serve, or a ring that
// does not open.
service_open :: proc "contextless" (ctx: ^Context) -> (service: Service, ok: bool) {
	memory := ctx.handles[GRANT_SERVICE]
	if memory == 0 {
		return {}, false
	}
	names, status := ring_open(memory, receive_handles = true)
	if status != .Ok {
		return {}, false
	}
	service.file = ([^]u8)(uintptr(ctx.values[GRANT_VALUE_FILE_ADDRESS]))[:ctx.values[GRANT_VALUE_FILE_SIZE]]
	if module.validate(service.file) != .None {
		ring_close(&names)
		return {}, false
	}
	service.names = names
	return service, true
}

// service_wait adds the service to a wait list: the thread waits while no
// connection has a call, and while the root service names no connection.
service_wait :: proc "contextless" (wait: ^Wait, service: ^Service) {
	if service.names.head == nil {
		return
	}
	wait_records(wait, &service.names.commands)
	for &connection in service.connections {
		if connection.calls.head != nil {
			wait_records(wait, &connection.calls.commands)
		}
	}
}

// service_command_of_record is the border of a command of the service
// ring: the member, or false for a kind that names no command, None
// included. It reads and changes no state.
service_command_of_record :: proc "contextless" (command: ring.Record) -> (service_command: isolated.Service_Command, ok: bool) {
	read := enum_word.member_of_word(isolated.Service_Command, u64(command.kind)) or_return
	return read, read != .None
}

// service_run adds and removes the connections that the root service
// names, then executes the calls that wait. It gives the count of calls.
service_run :: proc "contextless" (service: ^Service) -> (calls: int) {
	if service.names.head == nil {
		return 0
	}
	for _ in 0 ..< ring.CAPACITY {
		// The ring of the root service can carry the storage key of a
		// principal: each record is erased in the ring as it is taken, and
		// its copy here at the end of its turn.
		command, has_command := receive_erasing(&service.names.commands)
		defer intrinsics.mem_zero_volatile(&command, size_of(command))
		if !has_command {
			break
		}
		ring_memory, region_memory := Handle(command.values[0]), Handle(command.values[1])
		// A word that names no command holds no handle that this process
		// knows of: it closes nothing.
		service_command, known := service_command_of_record(command)
		if !known {
			log(.Warning, "service: the root service sent a command of the kind ", u64(command.kind), ", which names no service command: it is refused")
			continue
		}
		switch service_command {
		case .None:
			// service_command_of_record refuses None.
		case .Connect:
			if !connection_add(service, ring_memory, region_memory, name_unpack({command.values[2], command.values[3], command.values[4], command.values[5]}), command.values[6]) {
				close(ring_memory)
				close(region_memory)
			}
		case .Grant:
			for &connection in service.connections {
				if connection.calls.head != nil && connection.ring_memory == ring_memory {
					connection.grant = command.values[6]
				}
			}
		case .Principal_Identity, .Principal_Storage_Key, .Principal_Locked:
			// The words are keys, never handles: nothing to close.
			if service.principal_keys == nil {
				log(.Warning, "service: the root service sent the keys of a principal to a service that takes none: they are refused")
				continue
			}
			service.principal_keys(service, service_command, &command.values)
		case .Disconnect:
			for &connection in service.connections {
				if connection.calls.head != nil && connection.ring_memory == ring_memory {
					if service.disconnected != nil {
						service.disconnected(service, &connection)
					}
					ring_close(&connection.calls)
					memory_unmap(raw_data(connection.region))
					close(connection.ring_memory)
					close(connection.region_memory)
					connection = {}
					service.connected -= 1
				}
			}
		}
	}
	for &connection in service.connections {
		if connection.calls.head == nil {
			continue
		}
		for _ in 0 ..< ring.CAPACITY {
			command, has_command := receive(&connection.calls.commands)
			if !has_command {
				break
			}
			serving = &connection
			send(&connection.calls.completions, export_serve(service.file, op.PROCESS_BASE, connection.region, connection.ring_memory, command, false))
			serving = nil
			calls += 1
		}
	}
	service.calls += u64(calls)
	return calls
}

// connection_make opens a connection that this process made itself, with
// a call ring and a call region that it created: the storage service makes
// one for each share (docs/STORAGE.md, "Places"). It is not one of the
// connections that the root service names: the process keeps it, serves it
// with connection_serve, and ends it with connection_end.
connection_make :: proc "contextless" (ring_memory, region_memory: Handle, caller: Name) -> (connection: Connection, ok: bool) {
	region_pages, size_status := memory_size(region_memory)
	if size_status != .Ok {
		return {}, false
	}
	calls, ring_status := ring_open(ring_memory, receive_handles = true)
	if ring_status != .Ok {
		return {}, false
	}
	bytes, region_status := memory_map(region_memory)
	if region_status != .Ok {
		ring_close(&calls)
		return {}, false
	}
	return {ring_memory = ring_memory, region_memory = region_memory, calls = calls, region = ([^]u8)(bytes)[:region_pages * PAGE_SIZE], caller = caller}, true
}

// connection_end closes a connection that connection_make opened.
connection_end :: proc "contextless" (connection: ^Connection) {
	if connection.calls.head != nil {
		ring_close(&connection.calls)
		memory_unmap(raw_data(connection.region))
	}
	close(connection.ring_memory)
	close(connection.region_memory)
	connection^ = {}
}

// connection_serve executes the calls that wait on a connection that this
// process made itself, as service_run does for the connections of the root
// service. It gives the count of calls.
connection_serve :: proc "contextless" (service: ^Service, connection: ^Connection) -> (calls: int) {
	for _ in 0 ..< ring.CAPACITY {
		command, has_command := receive(&connection.calls.commands)
		if !has_command {
			break
		}
		serving = connection
		send(&connection.calls.completions, export_serve(service.file, op.PROCESS_BASE, connection.region, connection.ring_memory, command, false))
		serving = nil
		calls += 1
	}
	service.calls += u64(calls)
	return calls
}

// connection_add maps the two memory objects of a new caller in a free
// place. false: no place is free, or a memory object does not map.
@(private)
connection_add :: proc "contextless" (service: ^Service, ring_memory, region_memory: Handle, caller: Name, grant: u64) -> bool {
	for &connection in service.connections {
		if connection.calls.head != nil {
			continue
		}
		region_pages, size_status := memory_size(region_memory)
		if size_status != .Ok {
			return false
		}
		calls, ring_status := ring_open(ring_memory, receive_handles = true)
		if ring_status != .Ok {
			return false
		}
		bytes, region_status := memory_map(region_memory)
		if region_status != .Ok {
			ring_close(&calls)
			return false
		}
		connection = {
			ring_memory   = ring_memory,
			region_memory = region_memory,
			calls         = calls,
			region        = ([^]u8)(bytes)[:region_pages * PAGE_SIZE],
			caller        = caller,
			grant         = grant,
		}
		service.connected += 1
		// The ring is mapped with the consent to receive handles: the caller
		// can lend from now (src/md/api/call_ring_ready.md).
		send(&connection.calls.completions, isolated.ready_record())
		return true
	}
	return false
}

// export_serve executes one isolated call: it calls the export that the
// command record names, in the module file at base, and gives the
// completion record. The description of the export says how to read the
// argument record; the caller does not send the types. The entry of a
// module is not callable.
// ring_memory is the memory of the call ring. The caller lends each handle
// through it; this code proves each handle before the call (handle_state),
// and closes each one after it. The caller also revokes what it lent
// (lend_end). An export never receives a handle that this process holds for
// itself.
// A refusal has its outcome in the kind of the completion and its error
// record in the values: Argument_Refused for a call record or a handle that
// the receiver refuses, Grant_Or_Right_Missing for a handle without the
// right of the description, Operation_Unsupported for an export that the
// module does not have. The record says which argument and why.
// memory_objects_allowed: a table in a lent memory object is taken. A call
// host takes it; a service does not: the caller can revoke the
// lent memory while the export runs, and the fault of the export would stop
// the service for each of its callers. A call host serves one caller.
// lent_handle_outcome gives the outcome of the tests of the lent handles of
// a call, in the order of the tests of a callee (call_outcome.Callee_Test):
// a handle that did not come through the call ring, or a table whose
// handle names no memory object, breaks a rule of an argument, before a
// handle that lacks a right. Succeeded when none holds.
lent_handle_outcome :: proc "contextless" (absent: bool, wrong_kind: bool, rights_missing: bool) -> call_outcome.Call_Outcome {
	holding: bit_set[call_outcome.Callee_Test; u16]
	if absent || wrong_kind {
		holding += {.Argument_Breaks_A_Rule}
	}
	if rights_missing {
		holding += {.Grant_Or_Right_Absent}
	}
	return call_outcome.first_outcome(holding)
}

export_serve :: proc "contextless" (file: []u8, base: u64, region: []u8, ring_memory: Handle, command: ring.Record, memory_objects_allowed: bool) -> (completion: ring.Record) {
	completion.tag = command.tag
	head, _ := module.header(file)
	function, described := module.function(file, command.kind)
	address, has_address := module.export_address(file, uintptr(base), command.kind)
	if !described || !has_address || command.kind == head.entry_export {
		return isolated.refusal_completion(command.tag, .Operation_Unsupported, errors.error_make(.Unsupported, .None, 0, i64(command.kind)))
	}
	prepared: isolated.Call
	refusal: errors.Error_Record
	refused :: proc "contextless" (completion: ^ring.Record, outcome: call_outcome.Call_Outcome, refusal: errors.Error_Record) -> ring.Record {
		return isolated.refusal_completion(completion.tag, outcome, refusal)
	}
	if !isolated.decode(file, function, command.values[0], command.values[1], region, &prepared, &refusal) {
		return refused(&completion, .Argument_Refused, refusal)
	}
	// The proof of each handle, and the deferred close of each one that came
	// through the call ring, come first: each refusal after this point
	// closes them; a refusal that came before the deferred close, as the
	// refusal of a memory object to a service, would leave them open.
	lent := prepared.lent[:prepared.lent_count]
	came: [module.HANDLE_CAPACITY]bool
	first_absent, first_unproven := -1, -1
	held_rights: Rights
	for item, index in lent {
		_, rights, through := handle_state(Handle(item.handle), ring_memory)
		came[index] = through
		if first_absent < 0 && !through {
			first_absent = index
		}
		if first_unproven < 0 && through && !(transmute(Rights)item.rights <= rights) {
			first_unproven, held_rights = index, rights
		}
	}
	// Close what the caller lent, after the call or in place of it.
	defer for item, index in lent {
		if came[index] {
			close(Handle(item.handle))
		}
	}
	if !memory_objects_allowed && prepared.mapping_count > 0 {
		item := prepared.mappings[0]
		return refused(&completion, .Argument_Refused, errors.error_make(.Bad_Value, .Lent_Handles, i64(item.parameter + 1), i64(item.handle), 0))
	}
	// The tests of the lent handles, in the order of the tests of a callee
	// (lent_handle_outcome): a handle that did not come through the call
	// ring, or a table whose handle names no memory object, breaks a rule
	// of an argument; a handle that came lacks a right of the description
	// (note 4).
	first_wrong_kind, wrong_kind := -1, op.Object_Kind.None
	if first_absent < 0 {
		for item, index in prepared.mappings[:prepared.mapping_count] {
			if kind, _, _ := handle_state(Handle(item.handle)); kind != .Memory {
				first_wrong_kind, wrong_kind = index, kind
				break
			}
		}
	}
	switch lent_handle_outcome(first_absent >= 0, first_wrong_kind >= 0, first_unproven >= 0) {
	case .Argument_Refused:
		if first_absent >= 0 {
			return refused(&completion, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, 0, i64(lent[first_absent].handle)))
		}
		item := prepared.mappings[first_wrong_kind]
		return refused(&completion, .Argument_Refused, errors.error_make(.Handle_Kind, .Lent_Handles, i64(item.parameter + 1), i64(item.handle), i64(op.Object_Kind.Memory), i64(wrong_kind)))
	case .Grant_Or_Right_Missing:
		item := lent[first_unproven]
		return refused(&completion, .Grant_Or_Right_Missing, errors.error_make(.Handle_Rights, .Lent_Handles, 0, i64(item.handle), i64(item.rights), i64(transmute(u32)held_rights)))
	case .Succeeded, .Nothing_Has_That_Name, .Name_Already_Taken, .Callee_Busy, .Budget_Or_Capacity_Exhausted, .Wrong_State, .Another_Change_Came_First, .Operation_Unsupported, .Data_Damaged, .Callee_Unavailable, .Stopped_After_A_Partial_Change, .Callee_Stopped_During_The_Call, .Connection_Ended_During_The_Call, .Deadline_Passed_During_The_Call, .Answer_Unreadable:
	}
	// A table in a memory object (form iii): map it for the time of the
	// export, Write only for Change and Append, and check that the records
	// are inside it.
	mapped: [module.PARAMETER_CAPACITY]rawptr
	defer for address_of_mapping in mapped {
		if address_of_mapping != nil {
			memory_unmap(address_of_mapping)
		}
	}
	// Only the pages of the records, at the same address at each call.
	for item, index in prepared.mappings[:prepared.mapping_count] {
		memory := Handle(item.handle)
		object_pages, object_status := memory_size(memory)
		if object_status != .Ok {
			// The kernel refused the handle: the record says which argument.
			return refused(&completion, .Argument_Refused, errors.error_make(.Handle_Absent, .Lent_Handles, i64(item.parameter + 1), i64(item.handle)))
		}
		object_size := object_pages * PAGE_SIZE
		if item.start > object_size || item.size > object_size - item.start {
			return refused(&completion, .Argument_Refused, errors.error_make(.Out_Of_Range, .Bytes, i64(item.parameter + 1), i64(min(item.start, 1 << 62) + min(item.size, 1 << 62)), i64(object_size)))
		}
		// A work-around of a fault of the kernel (a mapping with no chosen
		// address never reuses its range of addresses): the same address at
		// each call.
		mapping_address := isolated.TABLE_ADDRESS + u64(item.parameter) * isolated.TABLE_SPAN
		if item.size == 0 {
			prepared.places[item.parameter].address = mapping_address // An empty table: nothing to reach.
			continue
		}
		first := item.start / PAGE_SIZE
		pages := (item.start + item.size + PAGE_SIZE - 1) / PAGE_SIZE - first
		start, status := memory_map(memory, item.writable ? {.Write} : {}, 0, mapping_address, first, pages)
		if status != .Ok {
			// A lent object that does not map is a fault of the caller; a
			// kernel that has no memory or no slot for the mapping is short
			// of a capacity of this receiver, which no change of the
			// arguments mends.
			return refused(&completion, outcome_of_status(status), errors.error_make(.Refused, .Kernel_Status, i64(item.parameter + 1), 0, 0, i64(status)))
		}
		mapped[index] = start
		prepared.places[item.parameter].address = u64(uintptr(start)) + item.start % PAGE_SIZE
	}
	floats: [CALL_FLOATS]u64
	out: [CALL_RESULTS]u64
	export_call(address, &prepared.arguments, &floats, &out)
	value, outcome_word := isolated.export_answer(function, {out[0], out[1]})
	if outcome_word == 0 {
		isolated.result_store(function, &prepared, region)
	}
	isolated.counts_store(function, &prepared, region)
	// A failure: the record of the export goes in the completion, and names
	// the export, which does not know its own number.
	return isolated.answer_completion(command.tag, command.kind, value, outcome_word, prepared.error_record)
}

// The copies that a caller made for one isolated call: see lend.
Lending :: struct {
	copies: [module.HANDLE_CAPACITY]Handle, // The copies in this process, to close after the call.
	count:  int, // The copies in use.
}

// lend prepares the handles of the arguments of an isolated call: the
// caller side of module.Type.Handle. For each Handle argument, for each
// Handle field of each Record argument, and for the memory object of each
// table argument that names one (Table_Argument.memory_handle), it makes a copy of the handle in
// this process with the rights of the description, and gives the receiver
// a handle that comes from the copy, through the call ring. It writes the
// handle of the receiver in place of the handle of the caller: give it
// copies of the records. Call it before isolated.encode.
//   file:        the module of the export: the descriptions.
//   ring_memory: the memory of the call ring.
// The handle of the caller needs the Give right and each right of the
// description. After the call, or in place of it, call lend_end: it
// revokes each copy. What the receiver has from the call ends then: its
// handle if it kept it, and each mapping that it made with it. The kernel
// does this; the receiver cannot refuse. If one handle fails, lend ends
// the copies itself.
lend :: proc "contextless" (file: []u8, function: module.Function, arguments: []isolated.Argument, ring_memory: Handle, lending: ^Lending) -> (status: Status) {
	function := function
	lending.count = 0
	lend_one_handle :: proc "contextless" (ring_memory: Handle, handle: Handle, wanted: Rights, lending: ^Lending) -> (result: Handle, status: Status) {
		if handle == 0 {
			return 0, .Ok
		}
		if lending.count == len(lending.copies) {
			return 0, .No_Slot
		}
		kind, held, _ := handle_state(handle)
		if kind == .None {
			return 0, .Bad_Handle
		}
		if !(wanted + {.Give} <= held) {
			return 0, .No_Right
		}
		copy := give(0, handle, wanted + {.Give}) or_return
		lending.copies[lending.count] = copy
		lending.count += 1
		return give(ring_memory, copy, wanted)
	}
	each: for word, index in function.parameters[:min(int(function.parameter_count), len(arguments))] {
		type, type_ok := module.type_of_word(word)
		if !type_ok {
			status = .Bad_Operation
			break each
		}
		switch type {
		case .None, .Integer, .Text, .Enum:
			// No handle and no memory object: nothing to lend.
		case .Handle:
			result: Handle
			result, status = lend_one_handle(ring_memory, Handle(arguments[index].integer), transmute(Rights)function.parameter_details[index], lending)
			if status != .Ok {
				break each
			}
			arguments[index].integer = u64(result)
		case .Table, .Bytes:
			// A table in a memory object: the rights of the copy are the
			// direction, so the callee gets no right to write a table that it
			// only reads.
			if arguments[index].table.memory_handle != 0 {
				direction, direction_ok := module.direction_of_word(function.parameter_directions[index])
				if !direction_ok {
					status = .Bad_Operation
					break each
				}
				result: Handle
				result, status = lend_one_handle(ring_memory, Handle(arguments[index].table.memory_handle), isolated.direction_rights(direction), lending)
				if status != .Ok {
					break each
				}
				arguments[index].table.memory_handle = u64(result)
			}
		case .Record:
			described, ok := module.record_type(file, function.parameter_details[index])
			if !ok || len(arguments[index].record) != int(described.size) {
				status = .Bad_Operation
				break each
			}
			for number in 0 ..< described.field_count {
				item, _ := module.field(file, described, number)
				if item.type != u8(module.Type.Handle) {
					continue
				}
				place := (^Handle)(&arguments[index].record[item.offset])
				place^, status = lend_one_handle(ring_memory, place^, transmute(Rights)item.detail, lending)
				if status != .Ok {
					break each
				}
			}
		}
	}
	if status != .Ok {
		lend_end(lending)
	}
	return status
}

// lend_end takes back what lend gave: see lend.
lend_end :: proc "contextless" (lending: ^Lending) {
	for copy in lending.copies[:lending.count] {
		handle_revoke(copy)
		close(copy)
	}
	lending.count = 0
}
