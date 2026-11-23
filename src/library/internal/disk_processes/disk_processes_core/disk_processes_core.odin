// The load of a disk process in the service disk_processes, with no
// kernel operation: each answer of the storage service and each command of
// the core goes in, and the next action comes out
// (src/md/api/root_service_split.md, "The disk processes").
//
// The service reads the module file of a nickname from the store
// module_files of the principal of the load, into memory that the core
// lends, then the import scan: the imports that the boot image does not
// hold are found in the same store by the hash of their bytes
// (docs/MODULE_CONTRACT.md, "A module from a disk"). No name and no hash
// that the storage service gives decides what runs: a name only says which
// entry to read. The core checks each hash again on its own mapping after
// the end of each loan, so a fault of this service ends a load, and never
// starts other bytes.
//
// Allocates no memory and calls no kernel operation.
package disk_processes_core

import "modus:contract/blake3"
import "modus:contract/errors"
import rd "modus:contract/root_delegation"
import "modus:disk_process"

#assert(disk_process.FILE_BYTES_LIMIT == rd.MODULE_BYTES_LIMIT)
#assert(disk_process.SCAN_WANTED_CAPACITY == rd.LOAD_IMPORT_CAPACITY)
#assert(disk_process.NAME_LIMIT <= rd.LOAD_FILE_NAME_CAPACITY)
#assert(disk_process.SCAN_READ_LIMIT == rd.LOAD_CANDIDATE_LOAN_LIMIT)

// One page of the list of the root tree: its rows, and the bytes of their
// names.
LIST_PAGE_ROWS :: 16
LIST_NAME_SIZE :: rd.LOAD_FILE_NAME_CAPACITY // The bytes of the name of an entry, at most, as the module file service writes it.
LIST_NAME_BYTES :: LIST_PAGE_ROWS * LIST_NAME_SIZE

// The most pages of one list. A storage service that gives the same page
// again cannot make the list last past it; the scan then notes that it
// left entries out.
LIST_PAGE_LIMIT :: 64

// What the load waits for.
Stage :: enum u8 {
	Idle, // No load: the next command is Load.
	Module_Size, // The size of the module file.
	Module_Memory, // Memory_Lent for the module file.
	Module_Bytes, // The next bytes of the module file.
	Module_Reported, // Continue after Module_Filled.
	Scan_Reported, // Continue after Scan_Started.
	List, // A page of the entries of the root tree.
	Candidate_Size, // The size of the entry that the scan reads.
	Candidate_Memory, // Memory_Lent for that entry.
	Candidate_Bytes, // The next bytes of that entry.
	Candidate_Reported, // Continue after Import_Found or Candidate_Dropped.
	Ended, // Ready or Refused was sent: the next command is Load or Cancel.
}

// What the storage service answered to one call, as the shell reads it.
Answer_Kind :: enum u8 {
	Value, // The call gave a value of 0 or more, and bytes for a read.
	Absent, // The export failed: the object is absent.
	Failed, // The export failed for another cause: error, damaged, value.
	Not_Allowed, // An answer that the description of the export does not allow.
	Gone, // The connection ended.
}

// The kind of one row of a list.
Entry_Class :: enum u8 {
	Object,
	Other, // A tree, or another kind that names a member.
	Unknown, // A word that names no kind.
}

// One row of a page of the list, as the shell copied it.
List_Row :: struct {
	name_offset: i64,
	name_count:  i64,
	class:       Entry_Class,
	size:        i64,
}

// One answer of the storage service.
Storage_Answer :: struct {
	kind:    Answer_Kind,
	value:   i64,
	text:    []u8, // The bytes of a read, in the memory of the shell.
	error:   errors.Error_Record, // Failed.
	damaged: bool, // Failed: the store named the object damaged.
	rows:    []List_Row, // A list: the rows of the page.
	names:   []u8, // A list: the bytes of their names.
}

// What the shell does next.
Action_Kind :: enum u8 {
	Wait_Command, // Wait for the next command of the core.
	Ask_Size, // Call size with name.
	Ask_Read, // Call read_range with name from offset.
	Ask_List, // Call list after name.
	Send_Event, // Write report, send event, then wait for the next command.
}

Action :: struct {
	kind:         Action_Kind,
	name:         string,
	offset:       u64,
	event:        rd.Disk_Load_Event,
	// The shell gives back the lent memory before it sends the event: the
	// core revokes the loan when it takes the event.
	release_lent: bool,
}

// What the load needs of the machine, which the shell gives.
Environment :: struct {
	// The boot image holds a module with this hash: a module of the boot
	// image wins over a file of the store.
	image_holds:  proc "contextless" (hash: blake3.Hash) -> bool,
	// Calls want_import for each import of a module file. A file that is
	// not a valid module notes nothing: the loader of the core refuses it
	// with its own load error.
	imports_walk: proc "contextless" (file: []u8, machine: ^Machine),
}

// The counts of the loads, for the export status.
Counters :: struct {
	loads:             u64,
	starts_requested:  u64,
	refusals:          u64,
	commands_refused:  u64,
}

Machine :: struct {
	stage:             Stage,
	kind:              rd.Load_Kind, // What the load reads, from its request.
	environment:       Environment,
	request:           rd.Load_Request,
	module_byte_count: u64,
	read:              disk_process.Read, // The file that is read: the module, or the entry of the scan.
	lent:              []u8, // The lent memory of that file, mapped by the shell.
	scan:              disk_process.Import_Scan,
	reading:           int, // The entry that the scan reads; -1: none.
	after:             [LIST_NAME_SIZE]u8, // The name of the last entry that the list gave: the next page starts after it.
	after_length:      int,
	pages:             int,
	kept_count:        int,
	kept_hashes:       [rd.LOAD_IMPORT_CAPACITY]blake3.Hash,
	walk_importer:     int, // The importer and the level of the imports that imports_walk notes now.
	walk_level:        int,
	report:            rd.Event_Report,
	counters:          Counters,
}

// machine_init makes an idle machine with its environment.
machine_init :: proc "contextless" (machine: ^Machine, environment: Environment) {
	machine^ = {}
	machine.environment = environment
	machine.reading = -1
}

// nickname gives the nickname of the load.
nickname :: proc "contextless" (machine: ^Machine) -> string {
	return string(machine.request.nickname[:machine.request.nickname_length])
}

// want_import notes one hash that a module file imports, and the module
// that a replacement of the machine gives in its place. imports_walk calls
// it.
want_import :: proc "contextless" (machine: ^Machine, hash: blake3.Hash) {
	want_hash(machine, hash)
	for item in machine.request.replacements[:machine.request.replacement_count] {
		if item.from == hash {
			want_hash(machine, item.to)
		}
	}
}

@(private = "file")
want_hash :: proc "contextless" (machine: ^Machine, hash: blake3.Hash) {
	if machine.environment.image_holds(hash) {
		return
	}
	disk_process.scan_want(&machine.scan, hash, machine.walk_importer, machine.walk_level)
}

// replaced says if a replacement of the machine gives another module in
// place of a hash: the loader then walks the imports of the other module,
// and not of this one.
@(private = "file")
replaced :: proc "contextless" (machine: ^Machine, hash: blake3.Hash) -> bool {
	for item in machine.request.replacements[:machine.request.replacement_count] {
		if item.from == hash {
			return true
		}
	}
	return false
}

@(private = "file")
walk :: proc "contextless" (machine: ^Machine, file: []u8, importer: int, level: int) {
	machine.walk_importer = importer
	machine.walk_level = level
	machine.environment.imports_walk(file, machine)
}

@(private = "file")
send :: proc "contextless" (machine: ^Machine, event: rd.Disk_Load_Event, release_lent: bool = false) -> Action {
	if release_lent {
		machine.lent = nil
	}
	return {kind = .Send_Event, event = event, release_lent = release_lent}
}

@(private = "file")
name_put :: proc "contextless" (field: ^[rd.LOAD_FILE_NAME_CAPACITY]u8, length: ^u32, name: string) {
	field^ = {}
	length^ = u32(copy(field[:], name))
}

// refuse ends the load with a refusal. The caller wrote the fields of its
// cause in the report after it cleared it.
@(private = "file")
refuse :: proc "contextless" (machine: ^Machine, refusal: rd.Disk_Load_Refusal) -> Action {
	machine.report.refusal = u32(refusal)
	machine.stage = .Ended
	machine.counters.refusals += 1
	return send(machine, .Refused, true)
}

// command_refused ends the load when the core sends a command out of its
// order, or with a handle that does not hold.
command_refused :: proc "contextless" (machine: ^Machine) -> Action {
	machine.report = {}
	machine.stage = .Ended
	machine.counters.commands_refused += 1
	return send(machine, .Command_Refused, true)
}

// call_failed ends the load when the shell cannot reach the storage
// service: the connection does not map (Not_Mapped), or a call is not
// taken (Call_Not_Taken).
call_failed :: proc "contextless" (machine: ^Machine, refusal: rd.Disk_Load_Refusal) -> Action {
	machine.report = {}
	return refuse(machine, refusal)
}

// load_begin takes the command Load: a request that the border refuses,
// or a load that runs, refuses the command.
load_begin :: proc "contextless" (machine: ^Machine, request: ^rd.Load_Request) -> Action {
	if machine.stage != .Idle && machine.stage != .Ended {
		return command_refused(machine)
	}
	environment := machine.environment
	counters := machine.counters
	machine^ = {}
	machine.environment = environment
	machine.counters = counters
	machine.reading = -1
	machine.request = request^
	kind, _, _, ok := rd.load_request_check(&machine.request)
	if !ok {
		return command_refused(machine)
	}
	machine.kind = kind
	machine.counters.loads += 1
	machine.stage = .Module_Size
	return {kind = .Ask_Size, name = nickname(machine)}
}

// cancel takes the command Cancel: the load ends with no event.
cancel :: proc "contextless" (machine: ^Machine) {
	machine.stage = .Idle
	machine.lent = nil
}

// memory_lent takes the command Memory_Lent with the lent memory, mapped:
// it must hold the whole file.
memory_lent :: proc "contextless" (machine: ^Machine, bytes: []u8) -> Action {
	if machine.stage != .Module_Memory && machine.stage != .Candidate_Memory || u64(len(bytes)) < machine.read.size {
		return command_refused(machine)
	}
	machine.lent = bytes[:machine.read.size]
	if machine.stage == .Module_Memory {
		machine.stage = .Module_Bytes
		return {kind = .Ask_Read, name = nickname(machine), offset = 0}
	}
	machine.stage = .Candidate_Bytes
	return {kind = .Ask_Read, name = disk_process.scan_entry_name(&machine.scan, machine.reading), offset = 0}
}

// continue_given takes the command Continue after an event that waits for
// it.
continue_given :: proc "contextless" (machine: ^Machine) -> Action {
	#partial switch machine.stage {
	case .Module_Reported:
		// The core ends a load of the script font set after Module_Filled:
		// it starts nothing, so a Continue is not its command.
		if machine.kind != .Module {
			return command_refused(machine)
		}
		if machine.scan.bound_passed {
			machine.report = {}
			return refuse(machine, .Import_Bounds)
		}
		if machine.scan.wanted_count == 0 {
			return ready(machine)
		}
		machine.report = {}
		machine.report.import_count = u64(machine.scan.wanted_count)
		machine.stage = .Scan_Reported
		return send(machine, .Scan_Started)
	case .Scan_Reported:
		machine.stage = .List
		return {kind = .Ask_List, name = ""}
	case .Candidate_Reported:
		if machine.scan.bound_passed {
			machine.report = {}
			return refuse(machine, .Import_Bounds)
		}
		return read_next(machine)
	}
	return command_refused(machine)
}

// storage_answered takes one answer of the storage service to the call of
// the last action.
storage_answered :: proc "contextless" (machine: ^Machine, answer: ^Storage_Answer) -> Action {
	machine.report = {}
	candidate := machine.stage == .Candidate_Size || machine.stage == .Candidate_Bytes
	switch answer.kind {
	case .Value:
		if answer.value < 0 {
			return refuse(machine, .Answer_Not_Allowed)
		}
	case .Gone:
		return refuse(machine, .Storage_Stopped)
	case .Not_Allowed:
		return refuse(machine, .Answer_Not_Allowed)
	case .Absent:
		if candidate {
			// An entry of the list that left the store since: the scan goes
			// on without it.
			return entry_skip(machine)
		}
		return refuse(machine, .No_Object)
	case .Failed:
		machine.report.read_error = answer.error
		machine.report.damaged = answer.damaged ? 1 : 0
		machine.report.failed_value = answer.value
		return refuse(machine, .Read_Refused)
	}
	#partial switch machine.stage {
	case .Module_Size:
		return module_size_answer(machine, u64(answer.value))
	case .Module_Bytes:
		return bytes_answer(machine, answer.text)
	case .List:
		return list_answer(machine, answer)
	case .Candidate_Size:
		return candidate_size_answer(machine, u64(answer.value))
	case .Candidate_Bytes:
		return bytes_answer(machine, answer.text)
	}
	// An answer that no call of the load asked for.
	return refuse(machine, .Answer_Not_Allowed)
}

@(private = "file")
module_size_answer :: proc "contextless" (machine: ^Machine, size: u64) -> Action {
	read, answer := disk_process.read_begin(size, rd.load_bytes_limit(machine.kind))
	switch answer {
	case .Good:
	case .Empty:
		return refuse(machine, .Object_Empty)
	case .Too_Large:
		machine.report.byte_count = size
		return refuse(machine, .Object_Too_Large)
	}
	machine.read = read
	machine.module_byte_count = size
	machine.report.place = u32(rd.File_Place.Module)
	machine.report.byte_count = size
	machine.stage = .Module_Memory
	return send(machine, .Memory_Wanted)
}

@(private = "file")
candidate_size_answer :: proc "contextless" (machine: ^Machine, size: u64) -> Action {
	read, answer := disk_process.read_begin(size, rd.MODULE_BYTES_LIMIT)
	if answer != .Good {
		disk_process.scan_skip(&machine.scan, machine.reading)
		return read_next(machine)
	}
	machine.read = read
	machine.report.place = u32(rd.File_Place.Candidate)
	machine.report.byte_count = size
	name_put(&machine.report.file_name, &machine.report.file_name_length, disk_process.scan_entry_name(&machine.scan, machine.reading))
	machine.stage = .Candidate_Memory
	return send(machine, .Memory_Wanted)
}

// bytes_answer copies the bytes of one answer into the lent memory. The
// count is compared with what the file has left before the copy.
@(private = "file")
bytes_answer :: proc "contextless" (machine: ^Machine, text: []u8) -> Action {
	candidate := machine.stage == .Candidate_Bytes
	count := u64(len(text))
	step := disk_process.read_step(&machine.read, count)
	switch step {
	case .More, .Complete:
		copy(machine.lent[machine.read.received - count:][:count], text)
	case .No_Progress:
		machine.report.received_bytes = machine.read.received
		machine.report.byte_count = machine.read.size
		if candidate {
			name_put(&machine.report.file_name, &machine.report.file_name_length, disk_process.scan_entry_name(&machine.scan, machine.reading))
			return refuse(machine, .Import_No_Byte_At)
		}
		return refuse(machine, .No_Byte_At)
	case .Too_Many:
		machine.report.received_bytes = count
		machine.report.left_bytes = machine.read.size - machine.read.received
		if candidate {
			name_put(&machine.report.file_name, &machine.report.file_name_length, disk_process.scan_entry_name(&machine.scan, machine.reading))
			return refuse(machine, .Import_Too_Many_Bytes)
		}
		return refuse(machine, .Too_Many_Bytes)
	}
	if step == .More {
		name := candidate ? disk_process.scan_entry_name(&machine.scan, machine.reading) : nickname(machine)
		return {kind = .Ask_Read, name = name, offset = machine.read.received}
	}
	if !candidate {
		// The imports are noted now: the lent memory goes back with the
		// event, and the core checks its hash before Continue. The script
		// font set is no module and imports nothing.
		if machine.kind == .Module {
			walk(machine, machine.lent, -1, 1)
		}
		machine.stage = .Module_Reported
		return send(machine, .Module_Filled, true)
	}
	return candidate_complete(machine)
}

@(private = "file")
candidate_complete :: proc "contextless" (machine: ^Machine) -> Action {
	hash := blake3.hash(machine.lent)
	entry_name := disk_process.scan_entry_name(&machine.scan, machine.reading)
	wanted := disk_process.scan_read_done(&machine.scan, machine.reading, hash)
	machine.stage = .Candidate_Reported
	if wanted < 0 || machine.kept_count >= rd.LOAD_IMPORT_CAPACITY {
		return send(machine, .Candidate_Dropped, true)
	}
	item := &machine.scan.wanted[wanted]
	machine.kept_hashes[machine.kept_count] = hash
	machine.kept_count += 1
	machine.report.hash = hash
	name_put(&machine.report.file_name, &machine.report.file_name_length, entry_name)
	if item.importer >= 0 {
		name_put(&machine.report.importer_name, &machine.report.importer_name_length, disk_process.scan_entry_name(&machine.scan, item.importer))
	}
	if !replaced(machine, hash) {
		walk(machine, machine.lent, machine.reading, item.level + 1)
	}
	return send(machine, .Import_Found, true)
}

// entry_skip notes that the bytes of the entry that is read do not come.
// With lent memory, the core gets it back with Candidate_Dropped; else the
// scan reads the next entry.
@(private = "file")
entry_skip :: proc "contextless" (machine: ^Machine) -> Action {
	disk_process.scan_skip(&machine.scan, machine.reading)
	if machine.stage == .Candidate_Bytes {
		machine.stage = .Candidate_Reported
		return send(machine, .Candidate_Dropped, true)
	}
	return read_next(machine)
}

// list_answer notes the objects of one page, and asks for the next one.
// An empty page ends the list, and the reads start. The rows and the names
// are in the memory of the shell: the call copied them, so the storage
// service cannot change them after their check.
@(private = "file")
list_answer :: proc "contextless" (machine: ^Machine, answer: ^Storage_Answer) -> Action {
	count := int(min(answer.value, LIST_PAGE_ROWS, i64(len(answer.rows))))
	if count == 0 {
		return read_next(machine)
	}
	names_length := i64(min(len(answer.names), LIST_NAME_BYTES))
	for item in answer.rows[:count] {
		if item.name_offset < 0 || item.name_count <= 0 || item.name_count > LIST_NAME_SIZE || item.name_offset > names_length - item.name_count {
			return refuse(machine, .Import_Entry_Name_Outside)
		}
		if item.class == .Unknown {
			return refuse(machine, .Import_Entry_Kind_Unknown)
		}
		entry_name := string(answer.names[item.name_offset:][:item.name_count])
		machine.after_length = copy(machine.after[:], entry_name)
		// The entry of the process holds the file that this load read: a
		// module never imports itself.
		if item.class == .Object && entry_name != nickname(machine) {
			disk_process.scan_entry_add(&machine.scan, entry_name, item.size)
		}
	}
	machine.pages += 1
	if machine.scan.entries_left_out || machine.pages >= LIST_PAGE_LIMIT {
		machine.scan.entries_left_out = true
		return read_next(machine)
	}
	return {kind = .Ask_List, name = string(machine.after[:machine.after_length])}
}

// read_next asks for the size of the next entry to read, or ends the scan.
@(private = "file")
read_next :: proc "contextless" (machine: ^Machine) -> Action {
	machine.report = {}
	index := disk_process.scan_next(&machine.scan)
	if index < 0 {
		machine.reading = -1
		missing := disk_process.scan_missing(&machine.scan)
		if missing >= 0 {
			item := &machine.scan.wanted[missing]
			machine.report.hash = item.hash
			machine.report.scan_reads = u64(machine.scan.reads)
			machine.report.entries_left_out = machine.scan.entries_left_out ? 1 : 0
			if item.importer >= 0 {
				name_put(&machine.report.importer_name, &machine.report.importer_name_length, disk_process.scan_entry_name(&machine.scan, item.importer))
			}
			return refuse(machine, .Import_Missing)
		}
		return ready(machine)
	}
	machine.reading = index
	machine.stage = .Candidate_Size
	return {kind = .Ask_Size, name = disk_process.scan_entry_name(&machine.scan, index)}
}

// ready ends the load with Start_From_Bytes.
@(private = "file")
ready :: proc "contextless" (machine: ^Machine) -> Action {
	machine.report = {}
	start := &machine.report.start
	start.principal = machine.request.principal
	start.module_hash = machine.request.module_hash
	start.module_byte_count = machine.module_byte_count
	start.nickname = machine.request.nickname
	start.nickname_length = machine.request.nickname_length
	start.import_count = u32(machine.kept_count)
	start.import_hashes = machine.kept_hashes
	machine.stage = .Ended
	machine.counters.starts_requested += 1
	return send(machine, .Ready, true)
}
