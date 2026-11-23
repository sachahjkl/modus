package root

// The bridge of the core to the delegated service disk_processes
// (src/md/api/root_service_split.md, "The disk processes").
//
// The service reads the module file of a disk process, and the files of
// its import scan, from the store module_files of the principal of the
// load. This service never reads that store for a load: it makes the
// connection of the service to the store, with the right to read only, and
// lends the memory of each file. It is the one commander of the ring of the
// service, and sends one command for each event that it takes, so the loop
// never waits for the service: an event is a word of its one wait, as the
// answers of the wiring service are.
//
// When the service says that a file is whole, this service revokes the
// loan, then computes the hash of the bytes on its own mapping: the
// service, or the storage service behind it, cannot change a byte after
// that check. The request Start_From_Bytes must name what this service
// checked, and the process starts with the grants of the row of its
// nickname, never with a grant that the service names
// (disk_processes.odin).

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/errors"
import "modus:contract/font_outlines"
import op "modus:contract/operation"
import "modus:contract/ring"
import rd "modus:contract/root_delegation"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:disk_process"
import "modus:random"
import "modus:system"

#assert(rd.LOAD_IMPORT_CAPACITY == disk_process.SCAN_WANTED_CAPACITY)
#assert(rd.LOAD_REPLACEMENT_CAPACITY == system.REPLACEMENT_CAPACITY)
#assert(rd.MODULE_BYTES_LIMIT == disk_process.FILE_BYTES_LIMIT)
#assert(rd.NICKNAME_CAPACITY == disk_process.NAME_LIMIT)
#assert(rd.LOAD_CANDIDATE_LOAN_LIMIT == disk_process.SCAN_READ_LIMIT)

// The starts of the service in a row, at most: past them a load from the
// disk is refused until the machine starts again. A load that reaches
// Ready sets the count back to zero, so stops far apart never use it up.
DISK_PROCESSES_RESTART_LIMIT :: 3

// The deadline of the load of the script font set: sixteen times the
// bytes of a module file, so sixteen times its deadline. It frees the one
// place of the load when the storage service gives no answer; it is not a
// measure of the disk.
SCRIPT_FONTS_LOAD_DEADLINE_MILLISECONDS :: 16 * disk_process.LOAD_DEADLINE_MILLISECONDS
#assert(font_outlines.SCRIPT_FONTS_BYTES_LIMIT == 16 * disk_process.FILE_BYTES_LIMIT)

// The time that the service has to answer Cancel with Cancelled. Past it
// the service is stopped: the core then ends each loan with no wait.
DISK_LOAD_CANCEL_BOUND_MILLISECONDS :: 2000

// The service, its ring and its transfer region. nil: it does not run.
disk_processes_process: ^Started
disk_processes_ring_memory: system.Handle
disk_processes_ring: ring.Ring
disk_processes_region_memory: system.Handle
disk_processes_region: []u8
disk_processes_starts: int
disk_processes_next_tag: u32 = 1
// The core asked the kernel to stop the service: it takes no more command,
// and its reap comes.
disk_processes_stopping: bool
// The events with no load that the core takes before it stops the service:
// one event can cross Cancel on the ring.
disk_processes_stray_allowance: int

// One file of a load, in memory that this service made and lends to the
// service until it says the file is whole.
Lent_File :: struct {
	memory: system.Handle, // 0: none.
	bytes:  []u8, // That memory, mapped here: whole pages.
	size:   u64, // The bytes of the file.
}

// The one load from the disk that runs. A second command during a load is
// refused: one service and one connection bound what a load takes.
Disk_Load :: struct {
	step:             rd.Disk_Load_Step,
	asker:            ^Started, // The process that sent the command: it receives the completion. nil: it stopped.
	tag:              u32, // The tag of the command.
	service_tag:      u32, // The tag of the load on the ring of the service.
	name:             [disk_process.NAME_LIMIT]u8, // The name of the process, and of its entry in the store.
	name_length:      int,
	hash:             [disk_process.HASH_SIZE]u8, // The hash that the command names.
	principal:        u64, // The principal of the session of the asker: the store is its store, and the process joins its session.
	connection:       ^Connection, // The connection of the service to the storage service. nil: it ended.
	deadline:         u64, // The time at which the load ends with no answer.
	module:           Lent_File,
	candidate:        Lent_File, // The entry of the scan that the service reads.
	kept:             [rd.LOAD_IMPORT_CAPACITY]Lent_File, // The files that the scan kept, in the order of their Import_Found.
	kept_names:       [rd.LOAD_IMPORT_CAPACITY][rd.LOAD_FILE_NAME_CAPACITY]u8,
	kept_hashes:      [rd.LOAD_IMPORT_CAPACITY]blake3.Hash, // The hash that this service computed on each, after its loan.
	files:            [rd.LOAD_IMPORT_CAPACITY]system.Source_File,
	kept_count:       int,
	candidate_loans:  int, // The loans of entries of the scan: bounded by rd.LOAD_CANDIDATE_LOAN_LIMIT.
	// The handles of this service that the service holds copies of: the
	// storage service, the call ring and the call region of the
	// connection. Their copies are revoked at the end of the load.
	storage_handles:  [3]system.Handle,
	// The load of the start policy that principal 0 chose: no process
	// asked for it, and its end starts it, or the rescue
	// (start_policy_choice.odin).
	for_start_policy: bool,
	// What the load reads: a module file, or the script font set, which no
	// process asked for either, and which this service keeps
	// (script_fonts.odin).
	kind:             rd.Load_Kind,
}

disk_load: Disk_Load

// What an ended load still lends to the service: the file that it was
// writing, and the storage connection. The core ends these loans when the
// service answers Cancel with Cancelled, after it unmapped them, so an
// honest service never meets a revoked page; past the bound it stops the
// service.
Disk_Load_Return :: struct {
	pending:         bool,
	service_tag:     u32,
	files:           [2]Lent_File,
	storage_handles: [3]system.Handle,
	deadline:        u64,
	stray_events:    int, // The events of that load that crossed Cancel: one at most.
}

disk_load_return: Disk_Load_Return

// The private copies of what crosses the border: the request that this
// service writes, and the report of each event, copied before its check.
disk_load_request: rd.Load_Request
disk_load_report: rd.Event_Report

// The caller record of the connection of the service to the storage
// service. Neither this service nor the delegated service is the caller
// that the storage service sees: the name of this record is the name of
// the store, and grant_for gives it the limit of that store, the flag that
// it reads only, and no grant to act for a principal.
disk_reader: Started

// Why disk_load_begin did not start a load.
Disk_Load_Begin_Failure :: enum u8 {
	None,
	No_Service, // The service does not run, and does not start.
	No_Connection, // The storage service gives no connection.
	Not_Given, // The handles of the connection do not reach the service.
}

// disk_processes_service_start starts the service on demand, with its
// ring, its transfer region and the boot image that reads only. It gives
// false past DISK_PROCESSES_RESTART_LIMIT starts, or when the start fails.
disk_processes_service_start :: proc "contextless" () -> bool {
	// A service that the core stops takes no load until its reap: the
	// next load starts a fresh one.
	if disk_processes_stopping {
		return false
	}
	if disk_processes_process != nil {
		return true
	}
	if disk_processes_starts >= DISK_PROCESSES_RESTART_LIMIT {
		return false
	}
	name := role_holder_name(.Disk_Processes)
	file := image_file_checked(name)
	if len(file) == 0 {
		return false
	}
	slot := part_place_take()
	if slot == nil {
		return false
	}
	ring_memory, ring_opened, status := system.ring_create()
	region_memory: system.Handle
	region_address: rawptr
	if status == .Ok {
		region_memory, status = system.memory_create(rd.DISK_PROCESSES_REGION_PAGES)
	}
	if status == .Ok {
		region_address, status = system.memory_map(region_memory, {.Write})
	}
	process: system.Handle
	if status == .Ok {
		grants: system.Context_Grants
		values: system.Context_Values
		system.grant_put(&grants, rd.DISK_PROCESSES_RING_SLOT, {ring_memory, {.Read, .Write}})
		system.grant_put(&grants, rd.DISK_PROCESSES_REGION_SLOT, {region_memory, {.Read, .Write}})
		system.grant_put(&grants, rd.DISK_PROCESSES_IMAGE_SLOT, {image_memory, {.Read}})
		system.grant_put(&grants, op.CONTEXT_LOG, log_grant(start_grant_set_of(name)))
		system.value_put(&values, rd.DISK_PROCESSES_VALUE_IMAGE_SIZE, u64(len(image)))
		if context_refused(name, &grants, &values) {
			status = .Bad_State
		} else {
			process, status = system.process_start(file, name, grants.grants, random.values_with_seed(&process_generator, values.values), budget_of(file, name), nil, &prepared, load_source())
		}
	}
	if status != .Ok {
		if region_address != nil {
			system.memory_unmap(region_address)
		}
		if ring_opened.head != nil {
			system.ring_close(&ring_opened)
		}
		for handle in ([2]system.Handle{ring_memory, region_memory}) {
			if handle != 0 {
				system.close(handle)
			}
		}
		system.log_fact(.Warning, Disk_Processes_Service_Start_Failed{status = status})
		return false
	}
	part_place_fill(slot, name, process)
	disk_processes_process = slot
	disk_processes_ring_memory, disk_processes_ring = ring_memory, ring_opened
	disk_processes_region_memory = region_memory
	disk_processes_region = ([^]u8)(region_address)[:rd.DISK_PROCESSES_REGION_PAGES * system.PAGE_SIZE]
	disk_processes_starts += 1
	system.log_fact(.Info, Disk_Processes_Service_Started{starts = u64(disk_processes_starts), start_limit = DISK_PROCESSES_RESTART_LIMIT})
	return true
}

// disk_processes_service_end forgets the service when it stopped: the
// load that runs ends, and the next load starts the service again.
disk_processes_service_end :: proc "contextless" (item: ^Started) {
	if item == nil || item != disk_processes_process {
		return
	}
	disk_processes_stopping = true
	if disk_load.step != .Idle {
		system.log_fact(.Warning, Disk_Load_Refused_Service_Stopped{refused_process = disk_load_name_field()})
		disk_load_end(.Bad_State, disk_load_refused_values())
	}
	disk_load_return_end()
	if raw_data(disk_processes_region) != nil {
		system.memory_unmap(raw_data(disk_processes_region))
	}
	if disk_processes_ring.head != nil {
		system.ring_close(&disk_processes_ring)
	}
	for handle in ([2]system.Handle{disk_processes_ring_memory, disk_processes_region_memory}) {
		if handle != 0 {
			system.close(handle)
		}
	}
	disk_processes_region = nil
	disk_processes_ring = {}
	disk_processes_ring_memory, disk_processes_region_memory = 0, 0
	disk_processes_process = nil
	disk_processes_stopping = false
	disk_processes_stray_allowance = 0
	system.log_fact(.Warning, Disk_Processes_Service_Stopped{})
}

// disk_processes_service_alive says if the service runs and takes
// commands.
disk_processes_service_alive :: proc "contextless" () -> bool {
	return disk_processes_process != nil && !disk_processes_stopping && disk_processes_ring.head != nil
}

// disk_processes_service_stop stops a service that broke its contract, so
// the next load starts a fresh one. Each loan that it holds ends now: the
// faults of a service that stops harm only itself.
disk_processes_service_stop :: proc "contextless" () {
	if disk_processes_process == nil || disk_processes_stopping {
		return
	}
	disk_processes_stopping = true
	started_process_stop(disk_processes_process)
	disk_load_return_end()
}

// disk_processes_fault stops the service for an event that no load takes.
@(private = "file")
disk_processes_fault :: proc "contextless" () {
	system.log_fact(.Warning, Disk_Processes_Service_Faulted{})
	disk_processes_service_stop()
}

// disk_load_running says if a load runs, or if an ended load still waits
// for the memory that it lent: a new load waits for both.
disk_load_running :: proc "contextless" () -> bool {
	return disk_load.step != .Idle || disk_load_return.pending
}

// storage_handles_release ends the copies of the handles of a storage
// connection in the service, then closes the handles of this service.
@(private = "file")
storage_handles_release :: proc "contextless" (handles: ^[3]system.Handle) {
	for &handle in handles {
		if handle == 0 {
			continue
		}
		if disk_processes_process != nil {
			system.handle_revoke(handle, disk_processes_process.process)
		}
		system.close(handle)
		handle = 0
	}
}

// disk_load_return_end ends the loans of an ended load: after Cancelled,
// after the stop of the service, or past the bound.
disk_load_return_end :: proc "contextless" () {
	returned := &disk_load_return
	if !returned.pending {
		return
	}
	for &file in returned.files {
		lent_file_free(&file)
	}
	storage_handles_release(&returned.storage_handles)
	returned^ = {}
}

// disk_load_begin starts a load: the service, the connection of the
// service to the store of the kind of the load (module_files of the
// principal, or script_fonts of the machine), with the right to read only,
// and the command Load. The caller checked that no load runs, and writes
// the line of a failure.
disk_load_begin :: proc "contextless" (asker: ^Started, tag: u32, name: string, hash: [disk_process.HASH_SIZE]u8, principal: u64, for_start_policy: bool, kind: rd.Load_Kind = .Module) -> (failure: Disk_Load_Begin_Failure, status: system.Status) {
	if !disk_processes_service_start() {
		return .No_Service, .Bad_State
	}
	service_process := disk_processes_process
	disk_reader = {}
	store_name := kind == .Script_Fonts ? font_outlines.SCRIPT_FONTS_STORE_NAME : disk_process.STORE_NAME
	copy(disk_reader.name[:len(disk_reader.name) - 1], store_name)
	disk_reader.principal = principal
	storage_name := role_holder_name(.Storage)
	connection, storage_service, ring_memory, region_memory, open_status := connection_open(&disk_reader, storage_name)
	if open_status != .Ok {
		return .No_Connection, open_status
	}
	// The service receives copies of the handles through its ring. This
	// service keeps its own handles until the end of the load, to revoke
	// the copies then: a service that keeps a handle past its load holds
	// no page of this service. The handle of the storage service is a copy
	// of its own, so its revocation does not reach the handles of its row.
	// The copy has Give so that this service can give it through the ring;
	// the service receives it with Read only.
	storage_copy: system.Handle
	storage_copy, status = system.give(0, storage_service.process, {.Read, .Give})
	sources := [3]system.Handle{storage_copy, ring_memory, region_memory}
	rights := [3]system.Rights{{.Read}, {.Read, .Write}, {.Read, .Write}}
	given: [3]system.Handle
	given_count := 0
	for source, index in sources {
		if status != .Ok {
			break
		}
		given[index], status = give_through_service_ring(service_process.process, disk_processes_ring_memory, source, rights[index], &service_process.service_ring_ready)
		if status != .Ok {
			break
		}
		given_count += 1
	}
	service_tag := disk_processes_next_tag
	disk_processes_next_tag = disk_processes_next_tag == max(u32) ? 1 : disk_processes_next_tag + 1
	if status == .Ok {
		disk_load_request = {}
		disk_load_request.kind = u8(kind)
		disk_load_request.principal = principal
		disk_load_request.module_hash = hash
		disk_load_request.nickname_length = u8(copy(disk_load_request.nickname[:], name))
		disk_load_request.storage_module_length = u8(copy(disk_load_request.storage_module[:], storage_name))
		replacements := load_source().replacements
		disk_load_request.replacement_count = u32(copy(disk_load_request.replacements[:], replacements))
		intrinsics.mem_copy_non_overlapping(&disk_processes_region[rd.LOAD_REQUEST_OFFSET], &disk_load_request, size_of(rd.Load_Request))
		if !system.send(&disk_processes_ring.commands, ring.Record{kind = u32(rd.Disk_Load_Command.Load), tag = service_tag, values = {0 = u64(given[0]), 1 = u64(given[1]), 2 = u64(given[2])}}) {
			status = .No_Slot
		}
	}
	if status != .Ok {
		// A refusal names no handle to the service, so it closes none: the
		// handles given before the failure are revoked here.
		for source in sources[:given_count] {
			system.handle_revoke(source, service_process.process)
		}
		for handle in sources {
			if handle != 0 {
				system.close(handle)
			}
		}
		disconnect(connection)
		return .Not_Given, status
	}
	name_bytes: [disk_process.NAME_LIMIT]u8
	name_length := copy(name_bytes[:], name)
	disk_load = {
		step             = .Module_Asked,
		asker            = asker,
		tag              = tag,
		service_tag      = service_tag,
		name             = name_bytes,
		name_length      = name_length,
		hash             = hash,
		principal        = principal,
		connection       = connection,
		deadline         = system.time() + (kind == .Script_Fonts ? SCRIPT_FONTS_LOAD_DEADLINE_MILLISECONDS : disk_process.LOAD_DEADLINE_MILLISECONDS),
		for_start_policy = for_start_policy,
		storage_handles  = sources,
		kind             = kind,
	}
	return .None, .Ok
}

// disk_load_name_field gives the name of the disk process that the load
// reads, as the field of a fact of its refusal.
disk_load_name_field :: proc "contextless" () -> value_kinds.Module_Name_Field {
	return module_name_field(string(disk_load.name[:disk_load.name_length]))
}

// disk_load_refused_values gives the completion of a load that ended for
// a cause of the services, not of the file.
disk_load_refused_values :: proc "contextless" () -> [7]u64 {
	return errors.ring_fail(u32(root_ring.Root_Command.Start_From_Disk), .Refused, .None, 0, 0, 0, i64(system.Status.Bad_State))
}

// disk_load_import_refused gives the completion of a load that the import
// scan ended, with the kind of the refusal.
@(private = "file")
disk_load_import_refused :: proc "contextless" (status: system.Status, kind_of_error: errors.Kind) -> [7]u64 {
	return errors.ring_fail(u32(root_ring.Root_Command.Start_From_Disk), kind_of_error, .Modules, 2, 0, 0, i64(status))
}

// disk_load_files gives the files that the scan kept, for the load source
// of the process.
disk_load_files :: proc "contextless" () -> []system.Source_File {
	return disk_load.files[:disk_load.kept_count]
}

// disk_load_module gives the bytes of the module file, which this service
// checked.
disk_load_module :: proc "contextless" () -> []u8 {
	return disk_load.module.bytes[:disk_load.module.size]
}

// lent_file_make makes the memory of one file and lends it to the service
// with Read and Write. budget 0 is the budget of this service.
@(private = "file")
lent_file_make :: proc "contextless" (file: ^Lent_File, size: u64, budget: system.Handle) -> (given: system.Handle, status: system.Status) {
	pages := (size + system.PAGE_SIZE - 1) / system.PAGE_SIZE
	file.memory, status = system.memory_create(pages, budget)
	if status != .Ok {
		file.memory = 0
		return 0, status
	}
	address: rawptr
	address, status = system.memory_map(file.memory)
	if status != .Ok {
		lent_file_free(file)
		return 0, status
	}
	file.bytes = ([^]u8)(address)[:pages * system.PAGE_SIZE]
	file.size = size
	service := disk_processes_process
	given, status = give_through_service_ring(service.process, disk_processes_ring_memory, file.memory, {.Read, .Write}, &service.service_ring_ready)
	return given, status
}

// lent_file_take_back ends the loan of a file: each handle and each
// mapping of it in the service ends. Only then are its bytes read.
@(private = "file")
lent_file_take_back :: proc "contextless" (file: ^Lent_File) -> bool {
	if file.memory == 0 || disk_processes_process == nil {
		return false
	}
	_, status := system.handle_revoke(file.memory, disk_processes_process.process)
	return status == .Ok
}

// lent_file_free ends the loan, if the service still runs, and frees the
// memory.
@(private = "file")
lent_file_free :: proc "contextless" (file: ^Lent_File) {
	if file.memory != 0 && disk_processes_process != nil {
		system.handle_revoke(file.memory, disk_processes_process.process)
	}
	if file.bytes != nil {
		system.memory_unmap(raw_data(file.bytes))
	}
	if file.memory != 0 {
		system.close(file.memory)
	}
	file^ = {}
}

// disk_load_command sends one command of the load to the service.
@(private = "file")
disk_load_command :: proc "contextless" (command: rd.Disk_Load_Command, values: [7]u64 = {}) -> bool {
	return system.send(&disk_processes_ring.commands, ring.Record{kind = u32(command), tag = disk_load.service_tag, values = values})
}

// disk_load_service_fault ends the load: the service gave an event that
// its contract does not allow, or took no command. The service is stopped,
// so the next load starts a fresh one and never trusts this one again.
@(private = "file")
disk_load_service_fault :: proc "contextless" () {
	system.log_fact(.Warning, Disk_Load_Refused_Service_Answer_Not_Allowed{refused_process = disk_load_name_field()})
	disk_processes_service_stop()
	disk_load_end(.Bad_State, disk_load_refused_values())
}

// disk_load_continue sends Continue and moves to the next step.
@(private = "file")
disk_load_continue :: proc "contextless" (step: rd.Disk_Load_Step) {
	if !disk_load_command(.Continue) {
		disk_load_service_fault()
		return
	}
	disk_load.step = step
}

// disk_load_end ends the load: the service is told, this service gives
// back what it held for it (the connection, the memory of each file), and
// the asker receives the completion. It gives the values back, for a
// caller that sends the completion itself.
disk_load_end :: proc "contextless" (status: system.Status, values: [7]u64) -> [7]u64 {
	load := &disk_load
	// A service that runs gets Cancel, and keeps the file that it writes
	// and the storage connection until it answers: their loans end at
	// Cancelled (disk_load_return_end). A service that takes no Cancel is
	// stopped. Each other file was taken back already.
	if disk_processes_service_alive() && load.service_tag != 0 {
		if disk_load_command(.Cancel) {
			returned := &disk_load_return
			returned^ = {pending = true, service_tag = load.service_tag, storage_handles = load.storage_handles, deadline = system.time() + DISK_LOAD_CANCEL_BOUND_MILLISECONDS}
			load.storage_handles = {}
			switch load.step {
			case .Module_Lent:
				returned.files[0] = load.module
				load.module = {}
			case .Candidate_Lent:
				returned.files[1] = load.candidate
				load.candidate = {}
			case .Idle, .Module_Asked, .Module_Checked, .Scan:
			// No file is lent at these steps: nothing waits for Cancelled.
			}
		} else {
			system.log_fact(.Warning, Disk_Processes_Service_Faulted{})
			disk_processes_service_stop()
		}
	}
	storage_handles_release(&load.storage_handles)
	lent_file_free(&load.module)
	lent_file_free(&load.candidate)
	for &file in load.kept {
		lent_file_free(&file)
	}
	if load.connection != nil {
		disconnect(load.connection)
	}
	if load.asker != nil && load.asker.process != 0 && load.asker.requests.head != nil {
		system.send(&load.asker.requests.completions, ring.Record{kind = u32(status), tag = load.tag, values = values})
	}
	for_start_policy := load.for_start_policy
	kind := load.kind
	load^ = {}
	disk_processes_stray_allowance = 1
	if for_start_policy {
		start_policy_chosen_load_ended(status)
	}
	if kind == .Script_Fonts {
		script_fonts_load_ended(status)
	}
	return values
}

// disk_load_forget takes a process that stops out of the load: the asker
// receives no completion.
disk_load_forget :: proc "contextless" (item: ^Started) {
	if disk_load.asker == item {
		disk_load.asker = nil
	}
}

// disk_load_deadline gives the time at which the loop of this service must
// run again for the load, or no time when no load runs.
disk_load_deadline :: proc "contextless" () -> u64 {
	deadline := disk_load.step == .Idle ? system.WAIT_FOREVER : disk_load.deadline
	if disk_load_return.pending {
		deadline = min(deadline, disk_load_return.deadline)
	}
	return deadline
}

// disk_load_step reads the events of the service, if they came. It never
// waits: with no event, it adds the completions of the ring to the wait of
// the loop. Four rules end a load whatever the services do: the stop of the
// asker, the end of the connection, an event that the contract does not
// allow, and the deadline. One pass reads at most the capacity of the
// ring: a service that floods it does not hold the loop.
disk_load_step :: proc "contextless" (wait: ^system.Wait) {
	load := &disk_load
	if disk_processes_ring.head == nil {
		return
	}
	for _ in 0 ..< ring.CAPACITY {
		if disk_processes_stopping {
			break
		}
		record, has := system.receive(&disk_processes_ring.completions)
		if !has {
			break
		}
		returned := &disk_load_return
		switch {
		case returned.pending && record.tag == returned.service_tag:
			// One event of the ended load can cross Cancel on the ring;
			// then Cancelled ends its loans.
			event, known := rd.disk_load_event_of_word(record.kind)
			if known && event == .Cancelled {
				disk_load_return_end()
			} else if returned.stray_events < 1 {
				returned.stray_events += 1
			} else {
				disk_processes_fault()
			}
		case load.step != .Idle && record.tag == load.service_tag:
			disk_load_event(record)
		case disk_processes_stray_allowance > 0:
			disk_processes_stray_allowance -= 1
		case:
			// A service that sends events that no load asked for would
			// spin the loop of this service: it is stopped.
			disk_processes_fault()
		}
	}
	if disk_load_return.pending && system.time() >= disk_load_return.deadline {
		system.log_fact(.Warning, Disk_Processes_Cancel_Late{bound = DISK_LOAD_CANCEL_BOUND_MILLISECONDS})
		disk_processes_service_stop()
	}
	if disk_processes_stopping || disk_processes_ring.head == nil {
		return
	}
	if load.step == .Idle {
		system.wait_records(wait, &disk_processes_ring.completions)
		return
	}
	if load.asker == nil && !load.for_start_policy && load.kind == .Module {
		system.log_fact(.Warning, Disk_Load_Refused_Asker_Stopped{refused_process = disk_load_name_field()})
		disk_load_end(.Bad_State, disk_load_refused_values())
		return
	}
	if load.connection == nil {
		system.log_fact(.Warning, Disk_Load_Refused_Storage_Stopped{refused_process = disk_load_name_field()})
		disk_load_end(.Bad_State, disk_load_refused_values())
		return
	}
	if system.time() >= load.deadline {
		// The bound of this load: the deadline of the set is 16 times that
		// of a module file.
		bound := u64(load.kind == .Script_Fonts ? SCRIPT_FONTS_LOAD_DEADLINE_MILLISECONDS : disk_process.LOAD_DEADLINE_MILLISECONDS)
		system.log_fact(.Warning, Disk_Load_Refused_No_Answer{bound = value_kinds.Time_In_Milliseconds(bound), refused_process = disk_load_name_field()})
		disk_load_end(.Bad_State, errors.ring_fail(u32(root_ring.Root_Command.Start_From_Disk), .No_Answer, .Milliseconds, 0, 0, i64(bound)))
		return
	}
	system.wait_records(wait, &disk_processes_ring.completions)
}

// disk_load_event takes one event of the service. Its report is copied,
// then checked whole at the border before any field is read.
@(private = "file")
disk_load_event :: proc "contextless" (record: ring.Record) {
	load := &disk_load
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	event, known := rd.disk_load_event_of_word(record.kind)
	intrinsics.mem_copy_non_overlapping(&disk_load_report, &disk_processes_region[rd.EVENT_REPORT_OFFSET], size_of(rd.Event_Report))
	report := &disk_load_report
	if !known || !rd.event_report_check(load.kind, load.step, event, report, load.kept_count, load.candidate_loans) {
		disk_load_service_fault()
		return
	}
	switch event {
	case .None, .Command_Refused, .Cancelled:
		disk_load_service_fault()
	case .Memory_Wanted:
		place, _ := rd.file_place_of_word(report.place)
		if place == .Module {
			given, status := lent_file_make(&load.module, report.byte_count, 0)
			if status != .Ok {
				system.log_fact(.Warning, Disk_Load_Refused_No_Memory{object_bytes = report.byte_count, status = op.Status_Word(status), refused_process = disk_load_name_field()})
				disk_load_end(status, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(status)))
				return
			}
			if !disk_load_command(.Memory_Lent, {0 = u64(given)}) {
				disk_load_service_fault()
				return
			}
			load.step = .Module_Lent
			return
		}
		budget, status := disk_processes_budget_get()
		given: system.Handle
		if status == .Ok {
			given, status = lent_file_make(&load.candidate, report.byte_count, budget)
		}
		if status != .Ok {
			file_name := string(report.file_name[:report.file_name_length])
			system.log_fact(.Warning, Disk_Load_Refused_Import_No_Memory{object_bytes = report.byte_count, status = op.Status_Word(status), refused_process = disk_load_name_field(), file = text_field(file_name, 24)})
			disk_load_end(status, disk_load_import_refused(status, .Refused))
			return
		}
		load.candidate_loans += 1
		if !disk_load_command(.Memory_Lent, {0 = u64(given)}) {
			disk_load_service_fault()
			return
		}
		load.step = .Candidate_Lent
	case .Module_Filled:
		// The hash is computed on the bytes that this service holds, after
		// the end of the loan: the hash of the entry of the storage service
		// is not read. So the storage service gives the bytes that the
		// command names, or nothing runs.
		if !lent_file_take_back(&load.module) {
			disk_load_service_fault()
			return
		}
		found := blake3.hash(disk_load_module())
		if found != load.hash {
			head := transmute([4]u64)found
			system.log_fact(.Warning, Disk_Load_Refused_Hash_Differs{found_hash = value_kinds.Hash_Field(found), hash = value_kinds.Hash_Field(load.hash), refused_process = disk_load_name_field()})
			disk_load_end(.Bad_Operation, errors.ring_fail(kind, .Not_Authentic, .None, 2, i64(head[0])))
			return
		}
		// The script font set starts nothing: this service keeps its
		// bytes, and the load ends here, cleanly.
		if load.kind == .Script_Fonts {
			script_fonts_take(&load.module)
			disk_processes_starts = 0
			disk_load_end(.Ok, {})
			return
		}
		disk_load_continue(.Module_Checked)
	case .Scan_Started:
		system.log_fact(.Info, Import_Scan_Started{imports = report.import_count, loaded_process = disk_load_name_field()})
		disk_load_continue(.Scan)
	case .Import_Found:
		if !lent_file_take_back(&load.candidate) {
			disk_load_service_fault()
			return
		}
		candidate := &load.candidate
		hash := blake3.hash(candidate.bytes[:candidate.size])
		if hash != report.hash {
			disk_load_service_fault()
			return
		}
		for kept in load.kept_hashes[:load.kept_count] {
			if kept == hash {
				disk_load_service_fault()
				return
			}
		}
		index := load.kept_count
		load.kept[index] = candidate^
		candidate^ = {}
		load.kept_hashes[index] = hash
		load.kept_names[index] = report.file_name
		file_name := string(load.kept_names[index][:report.file_name_length])
		load.files[index] = {hash = hash, bytes = load.kept[index].bytes[:load.kept[index].size], name = file_name}
		load.kept_count += 1
		importer := string(load.name[:load.name_length])
		if report.importer_name_length > 0 {
			importer = string(report.importer_name[:report.importer_name_length])
		}
		system.log_fact(.Info, Import_Found{hash = value_kinds.Hash_Field(hash), loaded_process = disk_load_name_field(), importer = module_name_field(importer), file = text_field(file_name, 24)})
		disk_load_continue(.Scan)
	case .Candidate_Dropped:
		lent_file_free(&load.candidate)
		disk_load_continue(.Scan)
	case .Ready:
		// Start_From_Bytes: the request names what this service checked.
		if rd.start_from_bytes_check(&report.start, load.principal, string(load.name[:load.name_length]), load.hash, load.module.size, load.kept_hashes[:load.kept_count]) != .None {
			disk_load_service_fault()
			return
		}
		// A load that ends cleanly: the stops of the service before were not
		// in a row.
		disk_processes_starts = 0
		disk_load_start()
	case .Refused:
		disk_load_refused(report)
	}
}

// disk_load_refused writes the line of the cause that the service gave,
// and ends the load with its completion.
@(private = "file")
disk_load_refused :: proc "contextless" (report: ^rd.Event_Report) {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	name := disk_load_name_field()
	refusal, _ := rd.disk_load_refusal_of_word(report.refusal)
	in_scan := disk_load.step == .Module_Checked || disk_load.step == .Scan || disk_load.step == .Candidate_Lent
	switch refusal {
	case .None:
		disk_load_service_fault()
	case .Not_Mapped:
		system.log_fact(.Warning, Disk_Load_Refused_Not_Mapped{refused_process = name})
		disk_load_end(.No_Memory, errors.ring_fail(kind, .Refused, .None, 0, 0, 0, i64(system.Status.No_Memory)))
	case .Call_Not_Taken:
		system.log_fact(.Warning, Disk_Load_Refused_Call_Not_Taken{refused_process = name})
		disk_load_end(.Bad_State, in_scan ? disk_load_import_refused(.Bad_State, .Refused) : disk_load_refused_values())
	case .Storage_Stopped:
		system.log_fact(.Warning, Disk_Load_Refused_Storage_Stopped{refused_process = name})
		disk_load_end(.Bad_State, disk_load_refused_values())
	case .No_Object:
		// A data disk with no script font set is the usual machine: one
		// line says what the machine draws, and nothing is refused.
		if disk_load.kind == .Script_Fonts {
			script_fonts_not_on_disk()
		} else {
			system.log_fact(.Warning, Disk_Load_Refused_No_Object{refused_process = name})
		}
		disk_load_end(.Bad_Handle, errors.ring_fail(kind, .Absent, .Objects, 1))
	case .Read_Refused:
		// The error record is a fact of its own fields after the line of
		// the refusal.
		system.log_fact(.Warning, Disk_Load_Refused_Read_Refused{refused_process = name})
		system.log_fact(.Warning, Disk_Load_Read_Refused(errors.error_record_fact_fields(report.read_error)))
		disk_load_end(.Bad_State, errors.ring_fail(kind, report.damaged == 1 ? errors.Kind.Damaged : errors.Kind.Refused, .Objects, 1, 0, 0, report.failed_value))
	case .Answer_Not_Allowed:
		system.log_fact(.Warning, Disk_Load_Refused_Answer_Not_Allowed{refused_process = name})
		disk_load_end(.Bad_State, disk_load_refused_values())
	case .Object_Empty:
		system.log_fact(.Warning, Disk_Load_Refused_Object_Empty{refused_process = name})
		disk_load_end(.Bad_Operation, errors.ring_fail(kind, .Malformed, .None, 1))
	case .Object_Too_Large:
		size := report.byte_count
		limit := rd.load_bytes_limit(disk_load.kind)
		if disk_load.kind == .Script_Fonts {
			system.log_fact(.Warning, Script_Fonts_Refused_Too_Large{object_bytes = size, set_bytes_limit = limit})
		} else {
			system.log_fact(.Warning, Disk_Load_Refused_Object_Too_Large{object_bytes = size, file_bytes_limit = limit, refused_process = name})
		}
		disk_load_end(.Bad_Operation, errors.ring_fail(kind, .Too_Long, .Bytes, 1, i64(min(size, 1 << 62)), i64(limit)))
	case .No_Byte_At:
		system.log_fact(.Warning, Disk_Load_Refused_No_Byte_At{received_bytes = report.received_bytes, object_bytes = report.byte_count, refused_process = name})
		disk_load_end(.Bad_State, disk_load_refused_values())
	case .Too_Many_Bytes:
		system.log_fact(.Warning, Disk_Load_Refused_Too_Many_Bytes{given_bytes = report.received_bytes, left_bytes = report.left_bytes, refused_process = name})
		disk_load_end(.Bad_State, disk_load_refused_values())
	case .Import_Entry_Name_Outside:
		system.log_fact(.Warning, Disk_Load_Refused_Import_Entry_Name_Outside{refused_process = name})
		disk_load_end(.Bad_State, disk_load_import_refused(.Bad_State, .Refused))
	case .Import_Entry_Kind_Unknown:
		system.log_fact(.Warning, Disk_Load_Refused_Import_Entry_Kind_Unknown{refused_process = name})
		disk_load_end(.Bad_State, disk_load_import_refused(.Bad_State, .Refused))
	case .Import_No_Byte_At:
		// The border bounded the length of the name for each refusal.
		file_name := text_field(string(report.file_name[:report.file_name_length]), 24)
		system.log_fact(.Warning, Disk_Load_Refused_Import_No_Byte_At{received_bytes = report.received_bytes, object_bytes = report.byte_count, refused_process = name, file = file_name})
		disk_load_end(.Bad_State, disk_load_import_refused(.Bad_State, .Refused))
	case .Import_Too_Many_Bytes:
		file_name := text_field(string(report.file_name[:report.file_name_length]), 24)
		system.log_fact(.Warning, Disk_Load_Refused_Import_Too_Many_Bytes{given_bytes = report.received_bytes, left_bytes = report.left_bytes, refused_process = name, file = file_name})
		disk_load_end(.Bad_State, disk_load_import_refused(.Bad_State, .Refused))
	case .Import_Missing:
		importer := string(disk_load.name[:disk_load.name_length])
		if report.importer_name_length > 0 {
			importer = string(report.importer_name[:report.importer_name_length])
		}
		hash := value_kinds.Hash_Field(report.hash)
		if report.entries_left_out == 1 {
			system.log_fact(.Warning, Disk_Load_Refused_Import_Missing_Entries_Left_Out{hash = hash, scan_reads = report.scan_reads, refused_process = name, importer = module_name_field(importer)})
		} else {
			system.log_fact(.Warning, Disk_Load_Refused_Import_Missing{hash = hash, scan_reads = report.scan_reads, refused_process = name, importer = module_name_field(importer)})
		}
		disk_load_end(.Bad_Handle, disk_load_import_refused(.Bad_Handle, .Absent))
	case .Import_Bounds:
		system.log_fact(.Warning, Disk_Load_Refused_Import_Bounds{wanted_capacity = u64(disk_process.SCAN_WANTED_CAPACITY), depth_limit = u64(disk_process.SCAN_DEPTH_LIMIT), refused_process = name})
		disk_load_end(.No_Slot, disk_load_import_refused(.No_Slot, .Full))
	}
}
