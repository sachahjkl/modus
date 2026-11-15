package root

// A disk program: a program whose module file is an object of the store
// `programs` of the storage service, and not a file of the boot image
// (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// The command Start_From_Disk names the program and the hash of its file.
// This service reads the object through a connection of its own to the
// storage service, checks the hash of the bytes, and starts them with no
// grant. The storage service is a program that this service started: it is
// not trusted to choose what runs, and it is not waited for. The load is a
// state of the loop of this service (disk_load_step), so each other ring is
// served while the bytes come.

import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/disk_program"
import "modus:support/display"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/storage"
import "modus:support/system"

// What the load that runs waits for.
Disk_Load_Stage :: enum u8 {
	Idle, // No load runs.
	Size, // The answer of the storage service to the question of the size of the object.
	Bytes, // The next bytes of the object.
}

// The one load from the disk that runs. A second command during a load is
// refused: one buffer and one connection bound what a load takes from this
// service.
Disk_Load :: struct {
	stage:          Disk_Load_Stage,
	asker:          ^Started, // The program that sent the command: it receives the completion. nil: it stopped.
	tag:            u32, // The tag of the command.
	name:           [disk_program.NAME_LIMIT]u8, // The name of the program, and of its entry in the store.
	name_length:    int,
	hash:           [disk_program.HASH_SIZE]u8, // The hash that the command names.
	principal:      u64, // The principal of the session of the asker: the store is its store, and the program joins its session.
	connection:     ^Connection, // The connection of this service to the storage service. nil: it ended.
	client:         storage.Client, // The call ring and the call region of that connection, mapped here.
	sent:           storage.Sent_Call, // The call whose answer this service waits for.
	arguments:      [3]isolated.Argument, // The arguments of that call.
	argument_count: int,
	read:           disk_program.Read, // The size of the file, and the bytes that came.
	memory:         system.Handle, // The memory of the file, from the budget of this service. 0: none yet.
	bytes:          []u8, // That memory, mapped.
	deadline:       u64, // The time at which the load ends with no answer.
}

disk_load: Disk_Load

// The caller record of the connection of this service to the storage
// service. This service is no row of its own table of started programs, so
// the connection has this record as its caller: its name is the name of the
// store, and grant_for gives it the limit of that store and no grant to act
// for a principal.
disk_reader: Started

// disk_refused writes the line of a refusal on the log, and gives the
// values of the completion.
disk_refused :: proc "contextless" (name: string, values: [7]u64, parts: ..system.Part) -> [7]u64 {
	text: [384]u8
	system.log_in("programs", .Warning, "root: refused ", system.Module_Name{name}, " from the disk: ", system.format(text[:], ..parts))
	return values
}

// disk_name_refusal says if a name cannot be the name of a disk program,
// with the values of the completion. A program of the boot image has its
// grants, its budget and the name of its store by its name, in the tables
// of this service: a file of a disk with such a name would take them. So
// the name of a disk program is the name of no module of the boot image, of
// no row of those tables and of no program of the system.
disk_name_refusal :: proc "contextless" (name: string, values: ^[7]u64) -> (refused: bool) {
	kind := u32(system.Root_Command.Start_From_Disk)
	problem, offset := disk_program.name_problem(name)
	switch problem {
	case .None:
	case .Empty:
		values^ = disk_refused(name, errors.ring_fail(kind, .Empty, .Bytes, 1, 0, disk_program.NAME_LIMIT), "the name has no byte")
		return true
	case .Too_Long:
		values^ = disk_refused(name, errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(len(name)), disk_program.NAME_LIMIT), "the name has more than ", u64(disk_program.NAME_LIMIT), " bytes")
		return true
	case .Bad_Byte:
		values^ = disk_refused(name, errors.ring_fail(kind, .Bad_Byte, .None, 1, i64(offset), 0, i64(name[offset])), "the name is no name of an entry of a tree")
		return true
	case .Store_Name:
		values^ = disk_refused(name, errors.ring_fail(kind, .Reserved, .None, 1), "the name is the name of the store of the module files")
		return true
	}
	of_the_system := name == "root" || name == "input" || name == "compositor" || name == "terminal" || name == "block" || name == "frame"
	if of_the_system || grants_of(name) != {} || callable_of(name) != nil {
		values^ = disk_refused(name, errors.ring_fail(kind, .Reserved, .None, 1), "the grant table of the root service names it, and a disk program takes no grant by its name")
		return true
	}
	if len(system.image_find(image, name)) != 0 {
		values^ = disk_refused(name, errors.ring_fail(kind, .Exists, .Modules, 1), "a module of the boot image has this name")
		return true
	}
	return false
}

// disk_start_begin runs the command Start_From_Disk of a program with the
// grant Root_Ring. It refuses at once what needs no read, with the values
// of the completion; else it opens the connection to the storage service,
// asks for the size of the object, and holds the completion until the load
// ends (held): the loop of this service goes on.
disk_start_begin :: proc "contextless" (asker: ^Started, record: ring.Record, values: ^[7]u64) -> (status: system.Status, held: bool) {
	kind := u32(system.Root_Command.Start_From_Disk)
	hash := transmute([disk_program.HASH_SIZE]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	name_bytes, name_length := disk_program.name_unpack({record.values[4], record.values[5], record.values[6]})
	name := string(name_bytes[:name_length])
	if disk_name_refusal(name, values) {
		return .Bad_Operation, false
	}
	if hash == {} {
		values^ = disk_refused(name, errors.ring_fail(kind, .Bad_Value, .None, 2), "the hash asked is 32 zero bytes")
		return .Bad_Operation, false
	}
	if disk_load.stage != .Idle {
		values^ = disk_refused(name, errors.ring_fail(kind, .Busy, .Requests, 0, 1, 1), "another load from the disk runs")
		return .Bad_State, false
	}
	// The connection: the store `programs` of the principal of the asker.
	disk_reader = {}
	copy(disk_reader.name[:len(disk_reader.name) - 1], disk_program.STORE_NAME)
	disk_reader.principal = asker.principal
	connection, service, ring_memory, region_memory, open_status := connection_open(&disk_reader, "storage")
	if open_status != .Ok {
		values^ = disk_refused(name, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(open_status)), "no connection to the storage service: status ", open_status)
		return open_status, false
	}
	client, opened := storage.open_handles(ring_memory, region_memory, service.program, system.image_find(image, "storage"))
	if !opened {
		system.close(ring_memory)
		system.close(region_memory)
		disconnect(connection)
		values^ = disk_refused(name, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.No_Memory)), "the call ring and the call region of the storage service do not map")
		return .No_Memory, false
	}
	disk_load = {
		stage       = .Size,
		asker       = asker,
		tag         = record.tag,
		name        = name_bytes,
		name_length = name_length,
		hash        = hash,
		principal   = asker.principal,
		connection  = connection,
		client      = client,
		deadline    = system.time() + disk_program.LOAD_DEADLINE_MILLISECONDS,
	}
	system.log_in("programs", .Info, "root: reads ", system.Module_Name{name}, " from the store ", disk_program.STORE_NAME, " of the storage service, for principal ", asker.principal)
	if !disk_load_ask("size", 0, false) {
		// The asker receives the completion from the caller of this
		// procedure, not from the end of the load.
		disk_load.asker = nil
		values^ = disk_load_end(.Bad_State, disk_refused(name, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State)), "the storage service took no call"))
		return .Bad_State, false
	}
	return .Ok, true
}

// disk_load_ask sends one call of the storage service for the object of
// the load: the place 0 (the root of the store), its name, and for a read
// the offset of the first byte.
disk_load_ask :: proc "contextless" (export: string, offset: u64, with_offset: bool) -> bool {
	load := &disk_load
	load.arguments = {}
	load.arguments[0].integer = u64(storage.ROOT)
	load.arguments[1].text = load.name[:load.name_length]
	load.argument_count = 2
	if with_offset {
		load.arguments[2].integer = offset
		load.argument_count = 3
	}
	status: storage.Status
	load.sent, status = storage.call_send(&load.client, export, load.arguments[:load.argument_count])
	return status == .Ok
}

// disk_load_end ends the load: this service gives back what it held for it
// (the connection, the mappings, the memory of the file), and the asker
// receives the completion. It gives the values back, for a caller that
// sends the completion itself.
disk_load_end :: proc "contextless" (status: system.Status, values: [7]u64) -> [7]u64 {
	load := &disk_load
	if load.client.calls.head != nil {
		system.ring_close(&load.client.calls)
	}
	if load.client.region != nil {
		system.memory_unmap(raw_data(load.client.region))
	}
	// The handle of the storage service is the handle of its row in the
	// table of the started programs: it stays.
	for handle in ([2]system.Handle{load.client.ring_memory, load.client.region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	if load.connection != nil {
		disconnect(load.connection)
	}
	if load.bytes != nil {
		system.memory_unmap(raw_data(load.bytes))
	}
	if load.memory != 0 {
		system.close(load.memory)
	}
	if load.asker != nil && load.asker.program != 0 && load.asker.requests.head != nil {
		system.send(&load.asker.requests.completions, ring.Record{kind = u32(status), tag = load.tag, values = values})
	}
	load^ = {}
	return values
}

// disk_load_forget takes a program that stops out of the load: the asker
// receives no completion, and a connection that ended is not ended again.
disk_load_forget :: proc "contextless" (item: ^Started) {
	if disk_load.asker == item {
		disk_load.asker = nil
	}
}

// disk_load_step reads the answer of the storage service to the call of
// the load, if it came, and does the next step. It never waits: with no
// answer, it adds the completions of the connection to the wait of the
// loop, and the loop goes on. Four rules end a load whatever the storage
// service does: its stop, an answer that makes no progress, a file over
// the limit, and the deadline.
disk_load_step :: proc "contextless" (wait: ^system.Wait) {
	load := &disk_load
	if load.stage == .Idle {
		return
	}
	kind := u32(system.Root_Command.Start_From_Disk)
	name := string(load.name[:load.name_length])
	refused_status := errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
	if load.asker == nil {
		disk_load_end(.Bad_State, disk_refused(name, refused_status, "the program that asked for it stopped"))
		return
	}
	if load.connection == nil {
		disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service stopped"))
		return
	}
	error: errors.Error_Record
	value, text, status, answered := storage.call_answer(&load.client, &load.sent, load.arguments[:load.argument_count], &error)
	if !answered {
		if !storage.connected(&load.client) {
			disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service stopped"))
			return
		}
		if system.time() >= load.deadline {
			disk_load_end(.Bad_State, disk_refused(name, errors.ring_fail(kind, .No_Answer, .Milliseconds, 0, 0, disk_program.LOAD_DEADLINE_MILLISECONDS), "the storage service gave no answer in ", u64(disk_program.LOAD_DEADLINE_MILLISECONDS), " ms"))
			return
		}
		system.wait_records(wait, &load.client.calls.completions)
		return
	}
	if status == .Failed && value == storage.ERROR_ABSENT {
		disk_load_end(.Bad_Handle, disk_refused(name, errors.ring_fail(kind, .Absent, .Objects, 1), "the store ", disk_program.STORE_NAME, " has no object with this name"))
		return
	}
	if status == .Failed {
		sentence: [240]u8
		writer := system.Writer{buffer = sentence[:]}
		storage.error_text(&writer, &load.client, &error)
		disk_load_end(.Bad_State, disk_refused(name, errors.ring_fail(kind, value == storage.ERROR_DAMAGED ? errors.Kind.Damaged : errors.Kind.Refused, .Objects, 1, 0, 0, value), "the storage service refused the read: ", system.written(&writer)))
		return
	}
	if status != .Ok || value < 0 {
		disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service gave no answer that the description of its export allows"))
		return
	}
	switch load.stage {
	case .Idle:
	case .Size:
		// The size is copied here and checked one time: no later answer
		// changes it.
		size := u64(value)
		answer: disk_program.Size_Answer
		load.read, answer = disk_program.read_begin(size)
		switch answer {
		case .Good:
		case .Empty:
			disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Malformed, .None, 1), "the object has no byte"))
			return
		case .Too_Large:
			disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(min(size, 1 << 62)), disk_program.FILE_BYTES_LIMIT), "the object has ", size, " bytes, and the module file of a disk program has at most ", u64(disk_program.FILE_BYTES_LIMIT)))
			return
		}
		pages := (size + system.PAGE_SIZE - 1) / system.PAGE_SIZE
		memory, create_status := system.memory_create(pages)
		address: rawptr
		if create_status == .Ok {
			load.memory = memory
			address, create_status = system.memory_map(memory)
		}
		if create_status != .Ok {
			disk_load_end(create_status, disk_refused(name, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(create_status)), "no memory for its ", size, " bytes: status ", create_status))
			return
		}
		load.bytes = ([^]u8)(address)[:size]
		load.stage = .Bytes
		if !disk_load_ask("read_range", 0, true) {
			disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service took no call"))
			return
		}
		system.wait_records(wait, &load.client.calls.completions)
	case .Bytes:
		// The count is the count of the bytes that are in the call region,
		// as this service bounded it (isolated.result_text): it is compared
		// with what the file has left before the copy.
		count := u64(len(text))
		step := disk_program.read_step(&load.read, count)
		switch step {
		case .More, .Complete:
			copy(load.bytes[load.read.received - count:][:count], text)
		case .No_Progress:
			disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service gave no byte at the byte ", load.read.received, " of ", load.read.size))
			return
		case .Too_Many:
			disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service gave ", count, " bytes where the file has ", load.read.size - load.read.received, " left"))
			return
		}
		if step == .More {
			if !disk_load_ask("read_range", load.read.received, true) {
				disk_load_end(.Bad_State, disk_refused(name, refused_status, "the storage service took no call"))
				return
			}
			system.wait_records(wait, &load.client.calls.completions)
			return
		}
		disk_load_complete()
	}
}

// disk_load_deadline gives the time at which the loop of this service must
// run again for the load, or no time when no load runs.
disk_load_deadline :: proc "contextless" () -> u64 {
	return disk_load.stage == .Idle ? system.WAIT_FOREVER : disk_load.deadline
}

// disk_load_complete checks the bytes of the file that came whole, and
// starts them. The hash is computed on the bytes that this service holds:
// the hash of the entry of the storage service is not read. So the storage
// service gives the bytes that the command names, or nothing runs.
disk_load_complete :: proc "contextless" () {
	load := &disk_load
	kind := u32(system.Root_Command.Start_From_Disk)
	name := string(load.name[:load.name_length])
	asked := load.hash
	found := blake3.hash(load.bytes)
	if found != asked {
		head := transmute([4]u64)found
		disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Not_Authentic, .None, 2, i64(head[0])), "its bytes have the hash ", system.Hash{found[:]}, ", and the hash asked is ", system.Hash{asked[:]}))
		return
	}
	principal := load.principal
	load_error: module.Load_Error
	status := disk_program_run(name, load.bytes, found, principal, &load_error)
	if status != .Ok {
		if load_error.stage != .None {
			buffer: [512]u8
			writer := system.Writer{buffer = buffer[:]}
			system.load_error_text(&writer, &load_error)
			disk_load_end(status, disk_refused(name, errors.ring_fail(kind, .Malformed, .None, 1, i64(load_error.file_error)), "the loader refused its file: ", system.written(&writer)))
		} else {
			disk_load_end(status, disk_refused(name, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status)), "it does not start: status ", status))
		}
		return
	}
	if principal == principals.MACHINE {
		system.log_in("programs", .Info, "root: started ", system.Module_Name{name}, " from the disk, hash ", system.Hash{found[:]}, ", with no grant")
	} else {
		system.log_in("programs", .Info, "root: started ", system.Module_Name{name}, " from the disk, hash ", system.Hash{found[:]}, ", with no grant, in the session of principal ", principal, " \"", principal_name(principal), "\"")
	}
	disk_load_end(.Ok, {})
}

// disk_program_run starts a disk program from the bytes of its file, which
// this service checked. The program receives what each program receives
// and nothing of a role: the log with the right Write, a window, the date
// page, the settings page and the glyph caches, read-only. It has no row
// in the tables of this service, so it has no grant, and the budget of a
// program that no table names. Its modules are copies that its own budget
// pays: it maps no prepared module of this service.
disk_program_run :: proc "contextless" (name: string, file: []u8, hash: [disk_program.HASH_SIZE]u8, principal: u64, load_error: ^module.Load_Error) -> system.Status {
	slot: ^Started
	for &item in started {
		if item.program == 0 {
			slot = &item
			break
		}
	}
	if slot == nil {
		return .No_Slot
	}
	slot^ = {}
	grants: [op.CONTEXT_HANDLES]system.Grant
	values: [op.CONTEXT_VALUES]u64
	grants[op.CONTEXT_LOG] = {system.context_record().handles[op.CONTEXT_LOG], {.Write}}
	display_memory, status := system.memory_create(ring.PAGE_COUNT)
	if status != .Ok {
		return status
	}
	// This service does not keep the memory of the ring to the compositor.
	defer system.close(display_memory)
	client: system.Handle
	if client, status = system.give(compositor, display_memory, {.Read, .Write}); status != .Ok {
		return status
	}
	slot.client = client
	system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(client)}})
	grants[system.GRANT_DISPLAY] = {display_memory, {.Read, .Write}}
	// The date page, the settings page, five glyph caches.
	mappings: [8]system.Mapping
	mapping_count := 0
	date_page_give(mappings[:], &mapping_count, &values)
	if system.image_resource_find(image, system.MEASURE_RUN_RESOURCE) != nil {
		values[op.CONTEXT_VALUE_MEASURE_RUN] = 1
	}
	text_settings_give(mappings[:], &mapping_count, &values)
	copy(slot.name[:len(slot.name) - 1], name)
	slot.principal = principal
	program: system.Handle
	// Its request, up to the largest budget of a disk program, paid by the
	// one budget of the disk programs: a file of a disk cannot take what
	// the programs of the boot image need. Its name selects no exception.
	disk_programs: system.Handle
	disk_programs, status = disk_programs_budget_get()
	if status == .Ok {
		program_budget := disk_budget_of(file, name, disk_programs)
		program, status = system.program_start(file, name, grants, random.values_with_seed(&program_generator, values), program_budget, mappings[:mapping_count], nil, load_source(), load_error, disk_programs)
		if status == .No_Budget {
			budget_refusal_log(name, program_budget, disk_programs, "the disk programs")
		}
	}
	if status != .Ok {
		release(slot) // The compositor forgets the ring.
		return status
	}
	slot.program = program
	slot.hash = hash
	slot.role = {}
	slot.granted += {.Log}
	return .Ok
}
