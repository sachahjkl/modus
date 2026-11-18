package root

// A disk process: a process whose module file is an object of the store
// `module_files` of the storage service, and not a file of the boot image
// (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// The command Start_From_Disk names the process and the hash of its file.
// This service reads the object through a connection of its own to the
// storage service, checks the hash of the bytes, and starts them with no
// grant. The storage service is a process that this service started: it is
// not trusted to choose what runs, and it is not waited for. The load is a
// state of the loop of this service (disk_load_step), so each other ring is
// served while the bytes come. An import that the boot image does not hold
// is found in the same store by the hash of its bytes, in more states of
// the same load (import_scan.odin).
//
// The disk grant table of each principal binds a nickname, the name of the
// entry, to the hash of one file, with the grants of that file
// (docs/MODULE_CONTRACT.md, "The grants of a disk process"). Its rules are
// in modus:support/disk_process; this file applies them at each start and
// serves the commands Disk_Grant and Nickname_Move. The store is the one
// grant that a command gives: the store of the nickname, so it follows the
// nickname to its next file.

import "modus:contract/blake3"
import "modus:contract/enum_word"
import process_page "modus:contract/disk_process_page"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/start_grant"
import "modus:support/disk_process"
import "modus:support/display"
import "modus:support/principals"
import "modus:support/random"
import "modus:support/storage"
import "modus:contract/root_ring"
import "modus:support/system"

// What the load that runs waits for.
Disk_Load_Stage :: enum u8 {
	Idle, // No load runs.
	Size, // The answer of the storage service to the question of the size of the object.
	Bytes, // The next bytes of the object.
	List, // A page of the entries of the root tree of the store, for the import scan (import_scan.odin).
	Import_Size, // The size of the entry that the import scan reads.
	Import_Bytes, // The next bytes of that entry.
}

// The one load from the disk that runs. A second command during a load is
// refused: one buffer and one connection bound what a load takes from this
// service.
Disk_Load :: struct {
	stage:          Disk_Load_Stage,
	asker:          ^Started, // The process that sent the command: it receives the completion. nil: it stopped.
	tag:            u32, // The tag of the command.
	name:           [disk_process.NAME_LIMIT]u8, // The name of the process, and of its entry in the store.
	name_length:    int,
	hash:           [disk_process.HASH_SIZE]u8, // The hash that the command names.
	principal:      u64, // The principal of the session of the asker: the store is its store, and the process joins its session.
	connection:     ^Connection, // The connection of this service to the storage service. nil: it ended.
	client:         storage.Client, // The call ring and the call region of that connection, mapped here.
	sent:           storage.Sent_Call, // The call whose answer this service waits for.
	arguments:      [4]isolated.Argument, // The arguments of that call.
	argument_count: int,
	read:           disk_process.Read, // The size of the file, and the bytes that came.
	memory:         system.Handle, // The memory of the file, from the budget of this service. 0: none yet.
	bytes:          []u8, // That memory, mapped.
	deadline:       u64, // The time at which the load ends with no answer.
}

disk_load: Disk_Load

// The caller record of the connection of this service to the storage
// service. This service is no row of its own table of started processes, so
// the connection has this record as its caller: its name is the name of the
// store, and grant_for gives it the limit of that store and no grant to act
// for a principal.
disk_reader: Started

// The disk grant table of each principal. With no machine passphrase, no
// key signs the table of principal 0: it lasts until the machine stops.
// With one, it is read from the disk and written after each change. The
// table of a named principal is read after its first unlock, under the key
// that `unlock` gives with it, and written after each change
// (persisted_grant_table.odin). A caller that acts for a named principal
// is a process of its session, such as a console that the desktop starts
// while the session runs.
disk_grant_tables: [principals.PRINCIPAL_CAPACITY]disk_process.Grant_Table

// disk_grant_table_of gives the table of a principal, or nil for a number
// with no record.
disk_grant_table_of :: proc "contextless" (principal: u64) -> ^disk_process.Grant_Table {
	if principal >= principals.PRINCIPAL_CAPACITY {
		return nil
	}
	return &disk_grant_tables[principal]
}

// disk_grant_table_lasts gives the end of the sentence of a change of a
// table: how long the table of the principal lasts.
disk_grant_table_lasts :: proc "contextless" (principal: u64) -> string {
	if principal == principals.MACHINE {
		if persisted_tables[principals.MACHINE].state == .No_Passphrase {
			return "; principal 0 has no passphrase, so its disk grant table lasts until the machine stops"
		}
		return "; the machine passphrase keeps the disk grant table of principal 0 on the disk"
	}
	// A change of the table of a named principal is taken only when the
	// table is kept on the disk (persisted_table_refusal).
	return "; the passphrase of the principal keeps its disk grant table on the disk"
}

// disk_store_limit gives the blocks of the store of a disk process in a
// service: the store of its nickname when its start gave it the grant
// store, and the grant was not revoked; else none.
disk_store_limit :: proc "contextless" (caller: ^Started, service: ^Started) -> u64 {
	if .Store not_in caller.role.grants || .Store in caller.revoked || system.name_of(service.name[:]) != "storage" {
		return 0
	}
	// The budget that a module asks for has no part for a store yet: the
	// store of a nickname has the default limit of a store, which no name
	// of the tables of this service changes for a disk process.
	return STORE_BLOCKS_DEFAULT
}

// disk_process_running gives the disk process of a nickname that runs in
// the session of a principal, or nil.
disk_process_running :: proc "contextless" (nickname: string, principal: u64) -> ^Started {
	for &item in started {
		if item.process != 0 && item.from_disk && item.principal == principal && system.name_of(item.name[:]) == nickname {
			return &item
		}
	}
	return nil
}

// disk_refused writes the line of a refusal on the log, and gives the
// values of the completion.
disk_refused :: proc "contextless" (name: string, values: [7]u64, parts: ..system.Part) -> [7]u64 {
	text: [384]u8
	system.log_in("processes", .Warning, "root: refused ", system.Module_Name{name}, " from the disk: ", system.format(text[:], ..parts))
	return values
}

// disk_name_refusal says if a name cannot be the name of a disk process,
// with the values of the completion. A process of the boot image has its
// grants, its budget and the name of its store by its name, in the tables
// of this service: a file of a disk with such a name would take them. So
// the name of a disk process is the name of no module of the boot image, of
// no row of those tables and of no process of the system.
disk_name_refusal :: proc "contextless" (name: string, values: ^[7]u64) -> (refused: bool) {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	problem, offset := disk_process.name_problem(name)
	switch problem {
	case .None:
	case .Empty:
		values^ = disk_refused(name, errors.ring_fail(kind, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT), "the name has no byte")
		return true
	case .Too_Long:
		values^ = disk_refused(name, errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(len(name)), disk_process.NAME_LIMIT), "the name has more than ", u64(disk_process.NAME_LIMIT), " bytes")
		return true
	case .Bad_Byte:
		values^ = disk_refused(name, errors.ring_fail(kind, .Bad_Byte, .None, 1, i64(offset), 0, i64(name[offset])), "the name is no name of a process: visible characters of ASCII, no \"/\", not \".\" or \"..\"")
		return true
	case .Store_Name:
		values^ = disk_refused(name, errors.ring_fail(kind, .Reserved, .None, 1), "the name is the name of the store of the module files")
		return true
	case .Table_Name:
		values^ = disk_refused(name, errors.ring_fail(kind, .Reserved, .None, 1), "the name is the name of the object of the disk grant table")
		return true
	}
	if name_is_a_system_part(name) || role_names_the_process(name) {
		values^ = disk_refused(name, errors.ring_fail(kind, .Reserved, .None, 1), "the grant table of the root service names it, and a disk process takes no grant by its name")
		return true
	}
	if len(system.image_find(image, name)) != 0 {
		values^ = disk_refused(name, errors.ring_fail(kind, .Exists, .Modules, 1), "a module of the boot image has this name")
		return true
	}
	return false
}

// disk_start_begin runs the command Start_From_Disk of a process with the
// grant Root_Ring. It refuses at once what needs no read, with the values
// of the completion; else it opens the connection to the storage service,
// asks for the size of the object, and holds the completion until the load
// ends (held): the loop of this service goes on.
disk_start_begin :: proc "contextless" (asker: ^Started, record: ring.Record, values: ^[7]u64) -> (status: system.Status, held: bool) {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	hash := transmute([disk_process.HASH_SIZE]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	name_bytes, name_length := disk_process.name_unpack({record.values[4], record.values[5], record.values[6]})
	name := string(name_bytes[:name_length])
	if disk_name_refusal(name, values) {
		return .Bad_Operation, false
	}
	// The nickname rule: two hashes never share a nickname. No hash asked
	// takes the hash of the row of the nickname.
	table := disk_grant_table_of(asker.principal)
	if table == nil {
		values^ = disk_refused(name, errors.ring_fail(kind, .Absent, .Principals, 0), "the asker has no principal with a record")
		return .Bad_State, false
	}
	file, _, problem_of_the_nickname := disk_process.start_file(table, name, hash)
	switch problem_of_the_nickname {
	case .None, .Absent, .Full, .Not_Held, .Same_File, .Zero_Hash, .Zero_Key:
		// start_file gives only None, No_File and Other_File: the start goes on.
	case .No_File:
		values^ = disk_refused(name, errors.ring_fail(kind, .Absent, .Grants, 2), "the nickname has no row in the disk grant table of principal ", asker.principal, ": name the hash of its file")
		return .Bad_Handle, false
	case .Other_File:
		head := transmute([4]u64)file
		values^ = disk_refused(name, errors.ring_fail(kind, .Exists, .Grants, 2, i64(head[0])), "the nickname names the file ", system.Hash{file[:]}, ", and the command names the file ", system.Hash{hash[:]}, "; nickname_move points it to another file")
		return .Bad_Operation, false
	}
	hash = file
	if disk_load.stage != .Idle {
		values^ = disk_refused(name, errors.ring_fail(kind, .Busy, .Requests, 0, 1, 1), "another load from the disk runs")
		return .Bad_State, false
	}
	// The connection: the store `module_files` of the principal of the asker.
	disk_reader = {}
	copy(disk_reader.name[:len(disk_reader.name) - 1], disk_process.STORE_NAME)
	disk_reader.principal = asker.principal
	connection, service, ring_memory, region_memory, open_status := connection_open(&disk_reader, "storage")
	if open_status != .Ok {
		values^ = disk_refused(name, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(open_status)), "no connection to the storage service: status ", open_status)
		return open_status, false
	}
	client, opened := storage.open_handles(ring_memory, region_memory, service.process, system.image_find(image, "storage"))
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
		deadline    = system.time() + disk_process.LOAD_DEADLINE_MILLISECONDS,
	}
	system.log_in("processes", .Info, "root: reads ", system.Module_Name{name}, " from the store ", disk_process.STORE_NAME, " of the storage service, for principal ", asker.principal)
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
// (the connection, the mappings, the memory of the file and of the files
// of the import scan), and the asker
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
	// table of the started processes: it stays.
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
	disk_imports_end()
	if load.asker != nil && load.asker.process != 0 && load.asker.requests.head != nil {
		system.send(&load.asker.requests.completions, ring.Record{kind = u32(status), tag = load.tag, values = values})
	}
	load^ = {}
	return values
}

// disk_load_forget takes a process that stops out of the load: the asker
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
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	name := string(load.name[:load.name_length])
	refused_status := errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
	if load.asker == nil {
		disk_load_end(.Bad_State, disk_refused(name, refused_status, "the process that asked for it stopped"))
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
			disk_load_end(.Bad_State, disk_refused(name, errors.ring_fail(kind, .No_Answer, .Milliseconds, 0, 0, disk_process.LOAD_DEADLINE_MILLISECONDS), "the storage service gave no answer in ", u64(disk_process.LOAD_DEADLINE_MILLISECONDS), " ms"))
			return
		}
		system.wait_records(wait, &load.client.calls.completions)
		return
	}
	if storage.export_failed_with(status, value, .Absent) && (load.stage == .Import_Size || load.stage == .Import_Bytes) {
		// An entry of the list that left the store since: the scan goes on
		// without it.
		disk_import_entry_skip(wait)
		return
	}
	if storage.export_failed_with(status, value, .Absent) {
		disk_load_end(.Bad_Handle, disk_refused(name, errors.ring_fail(kind, .Absent, .Objects, 1), "the store ", disk_process.STORE_NAME, " has no object with this name"))
		return
	}
	if status == .Failed {
		sentence: [240]u8
		writer := system.Writer{buffer = sentence[:]}
		storage.error_text(&writer, &load.client, &error)
		disk_load_end(.Bad_State, disk_refused(name, errors.ring_fail(kind, storage.export_failed_with(status, value, .Damaged) ? errors.Kind.Damaged : errors.Kind.Refused, .Objects, 1, 0, 0, value), "the storage service refused the read: ", system.written(&writer)))
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
		answer: disk_process.Size_Answer
		load.read, answer = disk_process.read_begin(size)
		switch answer {
		case .Good:
		case .Empty:
			disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Malformed, .None, 1), "the object has no byte"))
			return
		case .Too_Large:
			disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(min(size, 1 << 62)), disk_process.FILE_BYTES_LIMIT), "the object has ", size, " bytes, and the module file of a disk process has at most ", u64(disk_process.FILE_BYTES_LIMIT)))
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
		step := disk_process.read_step(&load.read, count)
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
		disk_load_complete(wait)
	case .List:
		disk_import_list_answer(value, wait)
	case .Import_Size:
		disk_import_size_answer(value, wait)
	case .Import_Bytes:
		disk_import_bytes_answer(text, wait)
	}
}

// disk_load_deadline gives the time at which the loop of this service must
// run again for the load, or no time when no load runs.
disk_load_deadline :: proc "contextless" () -> u64 {
	return disk_load.stage == .Idle ? system.WAIT_FOREVER : disk_load.deadline
}

// disk_load_complete checks the bytes of the file that came whole, then
// finds its imports that the boot image does not hold (import_scan.odin).
// The hash is computed on the bytes that this service holds: the hash of
// the entry of the storage service is not read. So the storage service
// gives the bytes that the command names, or nothing runs.
disk_load_complete :: proc "contextless" (wait: ^system.Wait) {
	load := &disk_load
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	name := string(load.name[:load.name_length])
	asked := load.hash
	found := blake3.hash(load.bytes)
	if found != asked {
		head := transmute([4]u64)found
		disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Not_Authentic, .None, 2, i64(head[0])), "its bytes have the hash ", system.Hash{found[:]}, ", and the hash asked is ", system.Hash{asked[:]}))
		return
	}
	disk_imports_begin(wait)
}

// disk_load_start starts the file whose bytes this service checked, with
// the files of the store that the import scan kept beside the boot image.
disk_load_start :: proc "contextless" () {
	load := &disk_load
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	name := string(load.name[:load.name_length])
	found := load.hash
	principal := load.principal
	// The grants are read now, not at the command: a change of the table
	// during the load is the table of this start.
	table := disk_grant_table_of(principal)
	if table == nil {
		disk_load_end(.Bad_State, disk_refused(name, errors.ring_fail(kind, .Absent, .Principals, 0), "its principal has no record"))
		return
	}
	file, granted, problem_of_the_nickname := disk_process.start_file(table, name, found)
	if problem_of_the_nickname != .None {
		disk_load_end(.Bad_Operation, disk_refused(name, errors.ring_fail(kind, .Exists, .Grants, 2), "the nickname names the file ", system.Hash{file[:]}, " since the command, and the bytes have the hash ", system.Hash{found[:]}))
		return
	}
	load_error: module.Load_Error
	status := disk_process_run(name, load.bytes, found, principal, granted, disk_imports_files(), &load_error)
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
	grants_text := ", with no grant"
	store_text := ""
	process_buffer, store_buffer: [32]u8
	if .Store in granted && principals.store_name_write(&store_buffer, disk_process.store_process_name(&process_buffer, name), principal, false) {
		grants_text = ", with the grant store: the store "
		store_text = system.name_of(store_buffer[:])
	}
	if principal == principals.MACHINE {
		system.log_in("processes", .Info, "root: started ", system.Module_Name{name}, " from the disk, hash ", system.Hash{found[:]}, grants_text, store_text)
	} else {
		system.log_in("processes", .Info, "root: started ", system.Module_Name{name}, " from the disk, hash ", system.Hash{found[:]}, grants_text, store_text, ", in the session of principal ", principal, " \"", principal_name(principal), "\"")
	}
	disk_load_end(.Ok, {})
}

// disk_process_run starts a disk process from the bytes of its file, which
// this service checked. The process receives what each process receives
// and nothing of a role: the log with the right Write, a window, the date
// page, the settings page and the glyph caches, read-only. It has no row
// in the tables by name of this service, and the budget of a process that
// no table names. Its grants are the grants of its nickname in the disk
// grant table of its principal: with the grant store, a connection to the
// store of its nickname, in its context as a process of the boot image
// receives its private store. Its modules are copies that its own budget
// pays: it maps no prepared module of this service. store_files are the
// files of the store that the import scan kept: its load source holds them
// beside the boot image.
disk_process_run :: proc "contextless" (name: string, file: []u8, hash: [disk_process.HASH_SIZE]u8, principal: u64, disk_grants: disk_process.Disk_Grants, store_files: []system.Source_File, load_error: ^module.Load_Error) -> system.Status {
	// The storage service runs before a slot is chosen: a start of it
	// takes the first free slot.
	storage_service: ^Started
	if .Store in disk_grants {
		for &item in started {
			if item.process != 0 && item.service.head != nil && system.name_of(item.name[:]) == "storage" {
				storage_service = &item
			}
		}
		if storage_service == nil {
			return .Bad_State
		}
	}
	slot: ^Started
	for &item in started {
		if place_is_free(&item) {
			slot = &item
			break
		}
	}
	if slot == nil {
		return .No_Slot
	}
	slot^ = {}
	// The connection to the storage service names the nickname, its
	// principal, and the grants of its start.
	copy(slot.name[:len(slot.name) - 1], name)
	slot.principal = principal
	slot.from_disk = true
	// Its role is the grants of its row, and never a row of the tables of
	// this service: it has no root ring, so it sends no root command
	// (root_ring.ROOT_RING_GRANTS).
	if .Store in disk_grants {
		slot.role = {grants = {.Store}}
	}
	context_grants: system.Context_Grants
	values: system.Context_Values
	system.grant_put(&context_grants, op.CONTEXT_LOG, {system.context_record().handles[op.CONTEXT_LOG], {.Write}})
	status: system.Status
	// This service does not keep the memory of the ring to the compositor.
	display_memory: system.Handle
	defer if display_memory != 0 {
		system.close(display_memory)
	}
	// With no screen the process gets no window, as a process of the boot
	// image (start_view_give).
	if !screen_absent {
		if display_memory, status = system.memory_create(ring.PAGE_COUNT); status != .Ok {
			return status
		}
		client: system.Handle
		if client, status = system.give(compositor, display_memory, {.Read, .Write}); status != .Ok {
			return status
		}
		slot.client = client
		// The compositor names the window by the nickname, beside the hash
		// prefix of the file that this service checked: the process does not
		// choose the name that the menu of the windows shows.
		nickname := disk_process.name_pack(name)
		system.send(&control.commands, ring.Record{kind = u32(display.Control.Client_Add), values = {0 = u64(client), 1 = nickname[0], 2 = nickname[1], 3 = nickname[2], 4 = process_page.hash_head(hash)}})
		system.grant_put(&context_grants, system.GRANT_DISPLAY, {display_memory, {.Read, .Write}})
	}
	// The date page, the fresh bytes page, the settings page, five glyph
	// caches, the font outlines, the demand cache, the file of the storage
	// service.
	mappings: [12]system.Mapping
	mapping_count := 0
	date_page_give(mappings[:], &mapping_count, &values)
	fresh_bytes_page_give(slot, mappings[:], &mapping_count, &values)
	if system.image_resource_find(image, system.MEASURE_RUN_RESOURCE) != nil {
		system.value_put(&values, op.CONTEXT_VALUE_MEASURE_RUN, 1)
	}
	text_settings_give(mappings[:], &mapping_count, &values)
	// The store of the nickname, as start() gives a private store: the call
	// ring, the call region, the storage service with the right Read, and
	// its file. This service closes its handles of the connection after the
	// start.
	store_ring, store_region: system.Handle
	defer if store_ring != 0 {
		system.close(store_ring)
		system.close(store_region)
	}
	if .Store in disk_grants {
		store_status: system.Status
		_, _, store_ring, store_region, store_status = connection_open(slot, "storage")
		if store_status != .Ok {
			release(slot) // The compositor forgets the ring.
			return store_status
		}
		system.grant_put(&context_grants, system.GRANT_STORAGE_RING, {store_ring, {.Read, .Write}})
		system.grant_put(&context_grants, system.GRANT_STORAGE_REGION, {store_region, {.Read, .Write}})
		system.grant_put(&context_grants, system.GRANT_STORAGE_SERVICE, {storage_service.process, {.Read}})
		for &item in system.image_entries(image) {
			if system.name_of(item.name[:]) == "storage" && item.offset % system.PAGE_SIZE == 0 && item.offset <= u64(len(image)) && item.size <= u64(len(image)) - item.offset {
				system.value_put(&values, system.GRANT_VALUE_STORAGE_FILE_SIZE, item.size)
				mappings[mapping_count] = {memory = image_memory, address = storage.FILE_ADDRESS, first = item.offset / system.PAGE_SIZE, page_count = (item.size + system.PAGE_SIZE - 1) / system.PAGE_SIZE}
				mapping_count += 1
			}
		}
	}
	process: system.Handle
	// Its request, up to the largest budget of a disk process, paid by the
	// one budget of the disk processes: a file of a disk cannot take what
	// the processes of the boot image need. Its name selects no exception.
	disk_processes: system.Handle
	disk_processes, status = disk_processes_budget_get()
	if status == .Ok && context_refused(name, &context_grants, &values) {
		status = .Bad_State
	}
	if status == .Ok {
		process_budget := disk_budget_of(file, name, disk_processes)
		source := load_source()
		source.files = store_files
		process, status = system.process_start(file, name, context_grants.grants, random.values_with_seed(&process_generator, values.values), process_budget, mappings[:mapping_count], nil, source, load_error, disk_processes)
		if status == .No_Budget {
			budget_refusal_log(name, process_budget, disk_processes, "the disk processes")
		}
	}
	if status != .Ok {
		release(slot) // The compositor forgets the ring, and the connection ends.
		return status
	}
	slot.process = process
	slot.hash = hash
	slot.granted += {.Log}
	disk_process_page_add(slot)
	return .Ok
}

// disk_grant_change runs the command Disk_Grant: the principal of the
// caller gives a grant to the file that a nickname names, or takes it. The
// caller acts for its principal, and changes the table of that principal
// only. values is the completion: an error record for a refusal.
disk_grant_change :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Disk_Grant)
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[0], record.values[1], record.values[2]})
	nickname := string(nickname_bytes[:nickname_length])
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	action, action_status, action_refusal := root_ring.member_of_word(root_ring.Disk_Grant_Action, record.values[4], .Disk_Grant, 0)
	if action_status != .Ok {
		values^ = action_refusal
		return action_status
	}
	number := record.values[5]
	asked, known := enum_word.member_of_word(start_grant.Grant, number)
	if !known {
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(number, 1 << 62)), i64(max(start_grant.Grant)))
		return .Bad_Operation
	}
	asked_name := start_grant.GRANT_NAMES[asked]
	grant, answer := disk_process.grant_by_command(asked)
	switch answer {
	case .Given:
	case .Never:
		values^ = errors.ring_fail(kind, .Reserved, .Grants, 2, i64(number))
		system.log_in("processes", .Warning, "root: refused the grant ", asked_name, " to the nickname ", system.Module_Name{nickname}, ": no command gives it to a disk process, as it reaches the whole machine or the principal")
		return .Bad_Operation
	case .Not_Built:
		values^ = errors.ring_fail(kind, .Unsupported, .Grants, 2, i64(number))
		system.log_in("processes", .Warning, "root: refused the grant ", asked_name, " to the nickname ", system.Module_Name{nickname}, ": a command gives a disk process the grant Store only")
		return .Bad_Operation
	}
	problem_of_the_name, offset := disk_process.nickname_grant_problem(nickname)
	switch problem_of_the_name {
	case .None:
	case .Empty:
		values^ = errors.ring_fail(kind, .Empty, .Bytes, 1, 0, disk_process.NAME_LIMIT)
		return .Bad_Operation
	case .Too_Long:
		values^ = errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(nickname_length), disk_process.NAME_LIMIT)
		return .Bad_Operation
	case .Bad_Byte:
		values^ = errors.ring_fail(kind, .Bad_Byte, .None, 1, i64(offset), 0, i64(offset < len(nickname) ? nickname[offset] : 0))
		system.log_in("processes", .Warning, "root: refused the grant ", asked_name, " to the nickname ", system.Module_Name{nickname}, ": a nickname with a grant has letters, digits, '-' and '_' only")
		return .Bad_Operation
	case .Store_Name, .Table_Name:
		values^ = errors.ring_fail(kind, .Reserved, .None, 1)
		system.log_in("processes", .Warning, "root: refused the grant ", asked_name, " to the nickname ", system.Module_Name{nickname}, ": the store of the module files keeps this name for itself")
		return .Bad_Operation
	}
	table := disk_grant_table_of(caller.principal)
	if table == nil {
		values^ = errors.ring_fail(kind, .Absent, .Principals, 0)
		return .Bad_State
	}
	if persisted_table_refusal(caller.principal) {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	grant_name := disk_process.disk_grant_names[grant]
	if action == .Disallow {
		row := disk_process.table_find(table, nickname)
		problem := disk_process.table_disallow(table, nickname, grant)
		if problem != .None {
			values^ = errors.ring_fail(kind, .Absent, .Grants, problem == .Absent ? 1 : 2)
			return .Bad_Handle
		}
		system.log_in("processes", .Info, "root: the nickname ", system.Module_Name{nickname}, ", the file ", system.Hash{row.hash[:]}, ", lost the grant ", grant_name, " for principal ", caller.principal, ", from its next start; its store stays on the disk", disk_grant_table_lasts(caller.principal))
		persisted_table_changed(caller.principal)
		return .Ok
	}
	// The hash that the nickname names now: its row, else the disk process
	// of the nickname that runs, whose bytes this service checked.
	hash: [disk_process.HASH_SIZE]u8
	if row := disk_process.table_find(table, nickname); row != nil {
		hash = row.hash
	} else if running := disk_process_running(nickname, caller.principal); running != nil {
		hash = running.hash
	} else {
		values^ = errors.ring_fail(kind, .Absent, .Processes, 1)
		system.log_in("processes", .Warning, "root: refused the grant ", grant_name, " to the nickname ", system.Module_Name{nickname}, ": it has no row in the disk grant table of principal ", caller.principal, ", and no disk process of that nickname runs; start it by its hash first")
		return .Bad_Handle
	}
	// The name of the store must fit: a cut name can be the name of
	// another store.
	process_buffer, store_buffer: [32]u8
	if grant == .Store && !principals.store_name_write(&store_buffer, disk_process.store_process_name(&process_buffer, nickname), caller.principal, false) {
		values^ = errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(nickname_length), i64(len(store_buffer) - 1))
		system.log_in("processes", .Warning, "root: refused the grant store to the nickname ", system.Module_Name{nickname}, ": the name of its store for principal ", caller.principal, " has more than 31 bytes")
		return .Bad_Operation
	}
	switch disk_process.table_allow(table, nickname, hash, grant) {
	case .None:
	case .Full:
		values^ = errors.ring_fail(kind, .Full, .Grants, 0, 0, disk_process.ROW_CAPACITY)
		return .No_Slot
	case .No_File, .Other_File, .Absent, .Not_Held, .Same_File, .Zero_Hash, .Zero_Key:
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	system.log_in("processes", .Info, "root: the nickname ", system.Module_Name{nickname}, ", the file ", system.Hash{hash[:]}, ", has the grant ", grant_name, " for principal ", caller.principal, ", from its next start", disk_grant_table_lasts(caller.principal))
	persisted_table_changed(caller.principal)
	return .Ok
}

// nickname_move runs the command Nickname_Move: a nickname of the table of
// the principal of the caller points to another file, and its grants and
// its store follow. The log says it before the change. A process of the
// nickname that runs keeps the grants of its start.
nickname_move :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Nickname_Move)
	hash := transmute([disk_process.HASH_SIZE]u8)[4]u64{record.values[0], record.values[1], record.values[2], record.values[3]}
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[4], record.values[5], record.values[6]})
	nickname := string(nickname_bytes[:nickname_length])
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	table := disk_grant_table_of(caller.principal)
	if table == nil {
		values^ = errors.ring_fail(kind, .Absent, .Principals, 0)
		return .Bad_State
	}
	if persisted_table_refusal(caller.principal) {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	row := disk_process.table_find(table, nickname)
	if row == nil {
		values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
		system.log_in("processes", .Warning, "root: refused the move of the nickname ", system.Module_Name{nickname}, ": it has no row in the disk grant table of principal ", caller.principal)
		return .Bad_Handle
	}
	if hash == {} || hash == row.hash {
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 2)
		return .Bad_Operation
	}
	system.log_in("processes", .Info, "root: the file ", system.Hash{hash[:]}, " will get the data of ", system.Module_Name{nickname})
	if disk_process.table_move(table, nickname, hash) != .None {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	system.log_in("processes", .Info, "root: the nickname ", system.Module_Name{nickname}, " names the file ", system.Hash{hash[:]}, ", with its grants and its store", disk_grant_table_lasts(caller.principal))
	persisted_table_changed(caller.principal)
	return .Ok
}

// The words of a setting of persistence, as the log writes them.
@(rodata)
persistence_words := [disk_process.Persistence]string {
	.Global  = "the global setting",
	.Persist = "persist across a restart",
	.Forget  = "last until the machine stops",
}

// disk_grant_persistence runs the command Disk_Grant_Persistence: how long
// a row of the table of the principal of the caller lasts, or with no
// nickname the global setting. The caller acts for its principal. The
// table is written after the change when the principal keeps it on the
// disk: a row that now lasts until the machine stops leaves the disk.
disk_grant_persistence :: proc "contextless" (caller: ^Started, record: ring.Record, values: ^[7]u64) -> system.Status {
	kind := u32(root_ring.Root_Command.Disk_Grant_Persistence)
	nickname_bytes, nickname_length := disk_process.name_unpack({record.values[0], record.values[1], record.values[2]})
	nickname := string(nickname_bytes[:nickname_length])
	if .Acts_For_Principal not_in grants_held(caller) {
		values^ = errors.ring_fail(kind, .No_Grant, .Acts_For_Principal, 1)
		return .No_Right
	}
	setting := record.values[4]
	persistence, persistence_ok := enum_word.member_of_word(disk_process.Persistence, setting)
	if !persistence_ok || nickname == "" && persistence == .Global {
		values^ = errors.ring_fail(kind, .Bad_Value, .None, 2, i64(min(setting, 1 << 62)), i64(max(disk_process.Persistence)))
		return .Bad_Operation
	}
	table := disk_grant_table_of(caller.principal)
	if table == nil {
		values^ = errors.ring_fail(kind, .Absent, .Principals, 0)
		return .Bad_State
	}
	if persisted_table_refusal(caller.principal) {
		values^ = errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
		return .Bad_State
	}
	if disk_process.table_persistence_set(table, nickname, persistence) != .None {
		values^ = errors.ring_fail(kind, .Absent, .Grants, 1)
		system.log_in("processes", .Warning, "root: refused the setting of persistence of the nickname ", system.Module_Name{nickname}, ": it has no row in the disk grant table of principal ", caller.principal)
		return .Bad_Handle
	}
	if nickname == "" {
		system.log_in("processes", .Info, "root: each row of the disk grant table of principal ", caller.principal, " with no exception will ", persistence_words[persistence], disk_grant_table_lasts(caller.principal))
	} else {
		system.log_in("processes", .Info, "root: the row of the nickname ", system.Module_Name{nickname}, " in the disk grant table of principal ", caller.principal, " has the setting: ", persistence_words[persistence], disk_grant_table_lasts(caller.principal))
	}
	persisted_table_changed(caller.principal)
	return .Ok
}
