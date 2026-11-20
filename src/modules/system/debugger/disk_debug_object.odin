package debugger

// The debug object of the module of a disk process
// (docs/MODULE_CONTRACT.md, "The debug object of a disk process"). That
// module is not in the boot image, so the debug image has no object for
// it. Its debug object is an object of the store `module_files`, beside its
// module file, named by the 64 hexadecimal digits of the hash of the
// module. At the attach, this service asks the root service for a
// connection that reads only to that store (Root_Command.Debug_Store),
// reads the object into memory of its own budget, checks it whole, and
// closes the connection. The object stays until the debugging ends.
//
// The same read serves the stop report of a disk process that stopped on a
// fault: the root service kept the report, and gives it with the
// connection (stop_report.odin). That object lives for one export.
//
// The storage service is a transport: it can give any bytes under the
// name. The object is used only when `debug_object.check` takes it and
// when the hash that it names is the hash of the module record.

import debug_object "modus:contract/debug_object"
import "modus:contract/storage_status"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:support/disk_process"
import "modus:support/storage"
import "modus:support/system"

// The answer of the root service to Debug_Store and the read of the object
// have this one deadline together. With the ROOT_ANSWER_MILLISECONDS of the
// answer to Debug, the two waits of `attach` take at most 3500 ms: 1500 ms
// stay under the 5000 ms after which the service `remote` ends a call, for
// the reports of the process, the attach in the kernel and the transit of
// `remote`.
DISK_DEBUG_OBJECT_MILLISECONDS :: 1500
#assert(ROOT_ANSWER_MILLISECONDS + DISK_DEBUG_OBJECT_MILLISECONDS + 1500 <= 5000)

// The debug object of the module of a disk process.
Disk_Debug_Object :: struct {
	module_hash: [32]u8, // The module of the disk process. Zero: the process is no disk process.
	// The principal whose store `module_files` gave the object. The check of
	// the object proves its hash only: the names and the paths are those
	// that this store holds, so the object serves a caller of this
	// principal only.
	principal:   u64,
	memory:      system.Handle, // The memory of the object. 0: none.
	object:      []u8, // The object, mapped, after its whole check. nil: none.
}

// The object of the disk process that the service debugs.
disk_debug_object: Disk_Debug_Object

// debug_object_for gives the debug object of the module with a hash: the
// object of the disk process, or the object of the debug image, or nil.
debug_object_for :: proc "contextless" (module_hash: [32]u8) -> []u8 {
	if disk_debug_object.object != nil && disk_debug_object.module_hash == module_hash {
		return disk_debug_object.object
	}
	return system.debug_object_of(&debug_names, module_hash)
}

// disk_debug_object_forget gives back the memory of the object, when the
// debugging ends.
disk_debug_object_forget :: proc "contextless" () {
	held_object_forget(&disk_debug_object)
}

// held_object_forget gives back the memory of one object.
held_object_forget :: proc "contextless" (held: ^Disk_Debug_Object) {
	if held.object != nil {
		system.memory_unmap(raw_data(held.object))
	}
	if held.memory != 0 {
		system.close(held.memory)
	}
	held^ = {}
}

// disk_module_of gives the module record of the process of the session
// that no module of the boot image is and that the debug image does not
// describe: the module of a disk process. found is false for a process of
// the boot image.
disk_module_of :: proc "contextless" () -> (module_hash: [32]u8, found: bool) {
	for &record in report_modules.modules[:min(report_modules.count, op.PROCESS_MODULE_CAPACITY)] {
		if record.size == 0 || system.image_entry_of(image, record.hash) != nil {
			continue
		}
		if system.debug_object_of(&debug_names, record.hash) != nil {
			continue
		}
		return record.hash, true
	}
	return {}, false
}

// disk_debug_object_read reads the debug object of the module of a disk
// process that the service attached to, for the caller of the connection
// with the call ring `connection_ring`. Each outcome is one line of the
// log; a failure leaves the module with no debug object, and the attach
// goes on.
disk_debug_object_read :: proc "contextless" (name: string, connection_ring: system.Handle, module_hash: [32]u8, principal: u64) {
	disk_debug_object_forget()
	disk_debug_object.module_hash = module_hash
	disk_debug_object.principal = principal
	store_debug_object_read(name, connection_ring, &disk_debug_object, principal, nil)
}

// store_debug_object_read asks the root service for the connection to the
// store `module_files`, reads there the debug object of the module
// `into.module_hash`, checks it, and closes the connection. With `kept`,
// the command asks for the stop report that the root service kept of the
// disk process `name`: the report comes with the connection, is copied to
// `kept`, and names the module, so `into` starts empty. When the session
// holds the object of that module already, no object is read: the caller
// uses the one of the session.
//
// completion and answered: the answer of the root service, for an export
// that gives its refusal. report_received: `kept` holds the report.
store_debug_object_read :: proc "contextless" (name: string, connection_ring: system.Handle, into: ^Disk_Debug_Object, principal: u64, kept: ^disk_process.Kept_Stop_Report) -> (completion: ring.Record, answered: bool, report_received: bool) {
	limit := system.time() + DISK_DEBUG_OBJECT_MILLISECONDS
	for_report := kept != nil
	tag := root_request_send(name, connection_ring, false, store = true, kept = for_report)
	if tag == 0 {
		system.log_fact(.Info, Debug_Object_Command_Not_Sent{debugged_process = value_kinds.module_name_field(name)})
		return
	}
	completion, answered = root_answer_wait(tag, limit)
	if !answered {
		system.log_fact(.Info, Debug_Object_Connection_Silent{bound = value_kinds.Time_In_Milliseconds(DISK_DEBUG_OBJECT_MILLISECONDS), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	if system.Status(completion.kind) != .Ok {
		system.log_fact(.Info, Debug_Object_Connection_Refused{status_word = u64(completion.kind), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	// The connection lives for the read only: after it, on each path, the
	// root service ends it, so it holds no connection place of the storage
	// service for the rest of the debugging. This defer runs after the
	// defer below that closes the side of this service.
	defer root_request_send(name, connection_ring, true, store = true, kept = for_report)
	// The handles are numbers from another process: each must be of its
	// kind, and must have come through the ring to the root service.
	service_handle := system.Handle(completion.values[0])
	ring_handle := system.Handle(completion.values[1])
	region_handle := system.Handle(completion.values[2])
	service_kind, _, service_through := system.handle_state(service_handle, requests_memory)
	ring_kind, _, ring_through := system.handle_state(ring_handle, requests_memory)
	region_kind, _, region_through := system.handle_state(region_handle, requests_memory)
	valid := service_kind == .Process && service_through && ring_kind == .Memory && ring_through && region_kind == .Memory && region_through
	store_principal := principal
	held_by_the_session := false
	if for_report {
		// The page of the report: one page that the root service made,
		// with the right Read. It is copied, then closed.
		page := system.Handle(completion.values[3])
		if page_kind, _, page_through := system.handle_state(page, requests_memory); page_kind == .Memory && page_through {
			if address, mapped := system.memory_map(page, {}); mapped == .Ok {
				kept^ = (^disk_process.Kept_Stop_Report)(address)^
				system.memory_unmap(address)
				report_received = true
			}
			system.close(page)
		}
		store_principal = completion.values[4]
		into.module_hash = kept.module_hash
		into.principal = store_principal
		// The object of the session serves only when the store of the same
		// principal gave it: another store can hold other names under the
		// same hash.
		held_by_the_session = disk_debug_object.object != nil && disk_debug_object.module_hash == kept.module_hash && disk_debug_object.principal == store_principal
	}
	storage_file := system.image_find(image, "storage")
	client: storage.Client
	opened := false
	if valid && (!for_report || report_received && !held_by_the_session) && module.validate(storage_file) == .None {
		client, opened = storage.open_handles(ring_handle, region_handle, service_handle, storage_file)
	}
	if !opened {
		throughs := [3]bool{service_through, ring_through, region_through}
		for handle, index in ([3]system.Handle{service_handle, ring_handle, region_handle}) {
			if throughs[index] {
				system.close(handle)
			}
		}
		switch {
		case for_report && !report_received:
			system.log_fact(.Info, Stop_Report_Not_Mapped{debugged_process = value_kinds.module_name_field(name)})
		case held_by_the_session:
			// The object of the session describes the module: no read.
		case:
			system.log_fact(.Info, Debug_Object_Connection_Not_Opened{debugged_process = value_kinds.module_name_field(name)})
		}
		return
	}
	module_hash := into.module_hash
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.debug_object_name_write(&digits, module_hash)
	// The connection is closed in each case: the object is read whole in
	// this export.
	defer {
		system.ring_close(&client.calls)
		system.memory_unmap(raw_data(client.region))
		system.close(client.ring_memory)
		system.close(client.region_memory)
		system.close(client.service)
	}
	arguments: [3]isolated.Argument
	arguments[0].integer = u64(storage.ROOT)
	arguments[1].text = digits[:]
	answer_value, text, status, done := store_call(&client, "size", arguments[:2], limit)
	if !done {
		system.log_fact(.Info, Debug_Object_Size_Silent{bound = value_kinds.Time_In_Milliseconds(DISK_DEBUG_OBJECT_MILLISECONDS), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	if storage.export_failed_with(status, answer_value, .Absent) {
		system.log_fact(.Info, Debug_Object_Absent{principal = store_principal, module_hash = value_kinds.Hash_Field(module_hash), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	if status != .Ok || answer_value < 0 {
		system.log_fact(.Info, Debug_Object_Size_Status_Refused{status = status, module_hash = value_kinds.Hash_Field(module_hash), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	// The size is copied here and checked one time: no later answer
	// changes it.
	object_read, size_answer := disk_process.read_begin(u64(answer_value), disk_process.DEBUG_OBJECT_BYTES_LIMIT)
	if size_answer != .Good {
		system.log_fact(.Info, Debug_Object_Size_Refused{size = value_kinds.Size_In_Bytes(answer_value), size_limit = u64(disk_process.DEBUG_OBJECT_BYTES_LIMIT), module_hash = value_kinds.Hash_Field(module_hash), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	object_memory, create_status := system.memory_create((object_read.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE)
	if create_status != .Ok {
		system.log_fact(.Info, Debug_Object_Memory_Refused{size = value_kinds.Size_In_Bytes(object_read.size), status = op.Status_Word(create_status), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	into.memory = object_memory
	address, map_status := system.memory_map(object_memory)
	if map_status != .Ok {
		held_object_forget(into)
		into.module_hash = module_hash
		system.log_fact(.Info, Debug_Object_Map_Refused{status = op.Status_Word(map_status), debugged_process = value_kinds.module_name_field(name)})
		return
	}
	bytes := ([^]u8)(address)[:object_read.size]
	for {
		arguments[2].integer = object_read.received
		answer_value, text, status, done = store_call(&client, "read_range", arguments[:3], limit)
		problem := ""
		switch {
		case !done:
			problem = "the storage service gave no bytes before the deadline"
		case status != .Ok || answer_value < 0:
			problem = "the storage service refused a read"
		}
		read_answer: disk_process.Read_Step
		if problem == "" {
			// The count is the count of the bytes that are in the call
			// region, as the client bounded it: it is compared with what
			// the object has left before the copy.
			count := u64(len(text))
			read_answer = disk_process.read_step(&object_read, count)
			switch read_answer {
			case .More, .Complete:
				copy(bytes[object_read.received - count:][:count], text)
			case .No_Progress:
				problem = "the storage service gave no byte before the end"
			case .Too_Many:
				problem = "the storage service gave more bytes than the object has left"
			}
		}
		if problem != "" {
			system.memory_unmap(address)
			held_object_forget(into)
			into.module_hash = module_hash
			system.log_fact(.Info, Debug_Object_Read_Stopped{debugged_process = value_kinds.module_name_field(name), problem = value_kinds.text_field(problem, READ_PROBLEM_FIELD_BYTES)})
			return
		}
		if read_answer == .Complete {
			break
		}
	}
	// The storage service chose the bytes: the object must be whole, and
	// must describe this module.
	named, described := debug_object.module_hash_of(bytes)
	fault := debug_object.check(bytes)
	if !described || named != module_hash || fault != .None {
		system.memory_unmap(address)
		held_object_forget(into)
		into.module_hash = module_hash
		debug_object_refused_log(fault, named, module_hash, name)
		return
	}
	into.object = bytes
	system.log_fact(.Info, Debug_Object_Read{principal = store_principal, size = value_kinds.Size_In_Bytes(object_read.size), module_hash = value_kinds.Hash_Field(module_hash), debugged_process = value_kinds.module_name_field(name)})
	return
}

// store_call sends one call to the storage service and waits for its
// answer until the time `limit`. done is false when no answer came in that
// time; a call that the client cannot send is done, with its status.
store_call :: proc "contextless" (client: ^storage.Client, export: string, arguments: []isolated.Argument, limit: u64) -> (result_value: i64, text: []u8, status: storage_status.Status, done: bool) {
	sent: storage.Sent_Call
	if sent, status = storage.call_send(client, export, arguments); status != .Ok {
		return 0, nil, status, true
	}
	for {
		answered: bool
		if result_value, text, status, answered = storage.call_answer(client, &sent, arguments); answered {
			return result_value, text, status, true
		}
		if !storage.connected(client) {
			return 0, nil, .Gone, true
		}
		wait: system.Wait
		system.wait_records(&wait, &client.calls.completions)
		if system.wait_end(&wait, limit) >= limit {
			return 0, nil, .Ok, false
		}
	}
}
