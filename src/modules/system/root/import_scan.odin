package root

// The import scan of a disk process: the imports that the boot image does
// not hold are found in the store `module_files` of the principal by the hash
// of their bytes (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// The scan runs in the load of the process, after the check of its file
// and before its start, with the same connection, the same deadline and
// the same rules for each answer of the storage service. It lists the root
// tree, reads the bytes of each entry, computes their BLAKE3 hash, and
// keeps the bytes whose hash an import names. No name and no hash that the
// storage service gives decides what runs: a name only says which entry to
// read. The account of the scan and its bounds are in
// modus:disk_process (import_scan.odin).

import "modus:contract/blake3"
import "modus:contract/storage_status"
import "modus:contract/errors"
import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:disk_process"
import "modus:storage"
import "modus:contract/root_ring"
import "modus:contract/value_kinds"
import "modus:system"

// One page of the list: its rows, and the bytes of their names.
LIST_PAGE_ROWS :: 16
LIST_NAME_SIZE :: 64 // The bytes of the name of an entry, at most, as the module file service reads it.
LIST_NAME_BYTES :: LIST_PAGE_ROWS * LIST_NAME_SIZE

// The most pages of one list. A storage service that gives the same page
// again cannot make the list last past it; the scan then notes that it
// left entries out.
LIST_PAGE_LIMIT :: 64

// What the import scan of the load that runs holds.
Disk_Imports :: struct {
	scan:         disk_process.Import_Scan,
	reading:      int, // The entry that is read; -1: none.
	rows:         [LIST_PAGE_ROWS]storage.Listed, // The rows of the last page: the call writes them here.
	names:        [LIST_NAME_BYTES]u8, // The names of those rows.
	after:        [LIST_NAME_SIZE]u8, // The name of the last entry that the list gave: the next page starts after it.
	after_length: int,
	pages:        int,
	read:         disk_process.Read, // The size of the entry that is read, and the bytes that came.
	memory:       system.Handle, // The memory of that entry, from the budget of the disk processes. 0: none.
	bytes:        []u8, // That memory, mapped.
	kept:         [disk_process.SCAN_WANTED_CAPACITY]system.Handle, // The memory of each file that the scan kept, at the place of its wanted hash.
	files:        [disk_process.SCAN_WANTED_CAPACITY]system.Source_File, // Those files, for the load source.
}

disk_imports: Disk_Imports

// disk_imports_files gives the files that the scan kept, for the load
// source of the process. The start comes only when each wanted hash has
// its file, so the files are the first wanted_count places.
disk_imports_files :: proc "contextless" () -> []system.Source_File {
	return disk_imports.files[:disk_imports.scan.wanted_count]
}

// disk_imports_begin notes the imports of the module file that the boot
// image does not hold. With none, the process starts as before; else the
// list of the store starts.
disk_imports_begin :: proc "contextless" (wait: ^system.Wait) {
	imports := &disk_imports
	imports^ = {}
	imports.reading = -1
	load := &disk_load
	name := string(load.name[:load.name_length])
	disk_imports_want(load.bytes, -1, 1)
	if imports.scan.bound_passed {
		disk_import_bound_refusal()
		return
	}
	if imports.scan.wanted_count == 0 {
		disk_load_start()
		return
	}
	system.log_fact(.Info, Import_Scan_Started{imports = u64(imports.scan.wanted_count), loaded_process = module_name_field(name)})
	load.stage = .List
	if !disk_import_list_ask() {
		system.log_fact(.Warning, Disk_Load_Refused_Call_Not_Taken{refused_process = disk_load_name_field()})
		disk_import_refused(.Bad_State, errors.Kind.Refused)
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_imports_want notes each import of a module file whose hash the boot
// image does not hold, and the module of a replacement of the machine for
// it: the loader reads both. importer is the entry of the module, or -1 for
// the process. A file that is not a valid module notes nothing: the loader
// refuses it with its own load error.
disk_imports_want :: proc "contextless" (file: []u8, importer: int, level: int) {
	if module.validate(file) != .None {
		return
	}
	source := load_source()
	for number in 1 ..< module.count(file, .Imports) {
		record, _ := module.record(file, .Imports, number, module.Import)
		disk_import_want_hash(record.hash, importer, level)
		for item in source.replacements {
			if item.from == record.hash {
				disk_import_want_hash(item.to, importer, level)
			}
		}
	}
}

// disk_import_want_hash notes one hash, if no module of the boot image has
// it: a module of the boot image wins over a file of the store.
disk_import_want_hash :: proc "contextless" (hash: [disk_process.HASH_SIZE]u8, importer: int, level: int) {
	if system.image_entry_of(image, hash) != nil {
		return
	}
	disk_process.scan_want(&disk_imports.scan, hash, importer, level)
}

// disk_import_replaced says if a replacement of the machine gives another
// module in place of a hash: the loader then walks the imports of the
// other module, and not of this one.
disk_import_replaced :: proc "contextless" (hash: [disk_process.HASH_SIZE]u8) -> bool {
	for item in load_source().replacements {
		if item.from == hash {
			return true
		}
	}
	return false
}

// disk_import_list_ask asks for the next page of the entries of the root
// tree, after the last name that the list gave.
disk_import_list_ask :: proc "contextless" () -> bool {
	load := &disk_load
	imports := &disk_imports
	load.arguments = {}
	load.arguments[0].integer = u64(storage.ROOT)
	load.arguments[1].text = imports.after[:imports.after_length]
	load.arguments[2].table = {records = ([^]u8)(&imports.rows)[:size_of(imports.rows)], count = 0}
	load.arguments[3].table = {records = imports.names[:], count = 0}
	load.argument_count = 4
	status: storage_status.Status
	load.sent, status = storage.call_send(&load.client, "list", load.arguments[:load.argument_count])
	return status == .Ok
}

// disk_import_ask sends one call of the storage service for the entry that
// the scan reads: its size, or its bytes from an offset.
disk_import_ask :: proc "contextless" (export: string, offset: u64, with_offset: bool) -> bool {
	load := &disk_load
	imports := &disk_imports
	entry := &imports.scan.entries[imports.reading]
	load.arguments = {}
	load.arguments[0].integer = u64(storage.ROOT)
	load.arguments[1].text = entry.name[:entry.name_length]
	load.argument_count = 2
	if with_offset {
		load.arguments[2].integer = offset
		load.argument_count = 3
	}
	status: storage_status.Status
	load.sent, status = storage.call_send(&load.client, export, load.arguments[:load.argument_count])
	return status == .Ok
}

// disk_import_list_answer notes the objects of one page, and asks for the
// next one. An empty page ends the list, and the reads start. The rows and
// the names are in the memory of this service: the call copied them, so
// the storage service cannot change them after their check.
disk_import_list_answer :: proc "contextless" (value: i64, wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	count := int(min(value, LIST_PAGE_ROWS))
	if count == 0 {
		disk_import_read_next(wait)
		return
	}
	for item in imports.rows[:count] {
		if item.name_offset < 0 || item.name_count <= 0 || item.name_count > LIST_NAME_SIZE || item.name_offset > LIST_NAME_BYTES - item.name_count {
			system.log_fact(.Warning, Disk_Load_Refused_Import_Entry_Name_Outside{refused_process = disk_load_name_field()})
			disk_import_refused(.Bad_State, errors.Kind.Refused)
			return
		}
		entry_kind, entry_kind_ok := storage.entry_kind_of_word(item.kind)
		if !entry_kind_ok {
			system.log_fact(.Warning, Disk_Load_Refused_Import_Entry_Kind_Unknown{refused_process = disk_load_name_field()})
			disk_import_refused(.Bad_State, errors.Kind.Refused)
			return
		}
		entry_name := string(imports.names[item.name_offset:][:item.name_count])
		imports.after_length = copy(imports.after[:], entry_name)
		// The entry of the process holds the file that this load checked:
		// a module never imports itself.
		if entry_kind == .Object && entry_name != string(load.name[:load.name_length]) {
			disk_process.scan_entry_add(&imports.scan, entry_name, item.size)
		}
	}
	imports.pages += 1
	if imports.scan.entries_left_out || imports.pages >= LIST_PAGE_LIMIT {
		imports.scan.entries_left_out = true
		disk_import_read_next(wait)
		return
	}
	if !disk_import_list_ask() {
		system.log_fact(.Warning, Disk_Load_Refused_Call_Not_Taken{refused_process = disk_load_name_field()})
		disk_import_refused(.Bad_State, errors.Kind.Refused)
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_import_read_next asks for the size of the next entry to read, or
// ends the scan: the process starts when each wanted hash has its file.
disk_import_read_next :: proc "contextless" (wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	index := disk_process.scan_next(&imports.scan)
	if index < 0 {
		imports.reading = -1
		if disk_process.scan_missing(&imports.scan) >= 0 {
			disk_import_missing_refusal()
			return
		}
		disk_load_start()
		return
	}
	imports.reading = index
	load.stage = .Import_Size
	if !disk_import_ask("size", 0, false) {
		system.log_fact(.Warning, Disk_Load_Refused_Call_Not_Taken{refused_process = disk_load_name_field()})
		disk_import_refused(.Bad_State, errors.Kind.Refused)
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_import_entry_skip notes that the bytes of the entry that is read do
// not come, and reads the next one.
disk_import_entry_skip :: proc "contextless" (wait: ^system.Wait) {
	disk_import_memory_free()
	disk_process.scan_skip(&disk_imports.scan, disk_imports.reading)
	disk_import_read_next(wait)
}

// disk_import_size_answer makes the memory of the entry, from the budget
// of the disk processes, and asks for its first bytes. The size is checked
// one time, here, as the size of the module file is.
disk_import_size_answer :: proc "contextless" (value: i64, wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	size := u64(value)
	answer: disk_process.Size_Answer
	imports.read, answer = disk_process.read_begin(size)
	if answer != .Good {
		disk_import_entry_skip(wait)
		return
	}
	budget, status := disk_processes_budget_get()
	address: rawptr
	if status == .Ok {
		imports.memory, status = system.memory_create((size + system.PAGE_SIZE - 1) / system.PAGE_SIZE, budget)
	}
	if status == .Ok {
		address, status = system.memory_map(imports.memory)
	}
	if status != .Ok {
		entry_name := disk_process.scan_entry_name(&imports.scan, imports.reading)
		system.log_fact(.Warning, Disk_Load_Refused_Import_No_Memory{object_bytes = size, status = op.Status_Word(status), refused_process = disk_load_name_field(), file = text_field(entry_name, 24)})
		disk_import_refused(status, errors.Kind.Refused)
		return
	}
	imports.bytes = ([^]u8)(address)[:size]
	load.stage = .Import_Bytes
	if !disk_import_ask("read_range", 0, true) {
		system.log_fact(.Warning, Disk_Load_Refused_Call_Not_Taken{refused_process = disk_load_name_field()})
		disk_import_refused(.Bad_State, errors.Kind.Refused)
		return
	}
	system.wait_records(wait, &load.client.calls.completions)
}

// disk_import_bytes_answer copies the bytes of one answer, as the load of
// the module file does. When the entry is whole, its hash is computed on
// the bytes that this service holds: bytes whose hash an import names are
// kept for the load source, and their imports are noted; the others are
// freed.
disk_import_bytes_answer :: proc "contextless" (text: []u8, wait: ^system.Wait) {
	load := &disk_load
	imports := &disk_imports
	entry_name := disk_process.scan_entry_name(&imports.scan, imports.reading)
	count := u64(len(text))
	step := disk_process.read_step(&imports.read, count)
	switch step {
	case .More, .Complete:
		copy(imports.bytes[imports.read.received - count:][:count], text)
	case .No_Progress:
		system.log_fact(.Warning, Disk_Load_Refused_Import_No_Byte_At{received_bytes = imports.read.received, object_bytes = imports.read.size, refused_process = disk_load_name_field(), file = text_field(entry_name, 24)})
		disk_import_refused(.Bad_State, errors.Kind.Refused)
		return
	case .Too_Many:
		system.log_fact(.Warning, Disk_Load_Refused_Import_Too_Many_Bytes{given_bytes = count, left_bytes = imports.read.size - imports.read.received, refused_process = disk_load_name_field(), file = text_field(entry_name, 24)})
		disk_import_refused(.Bad_State, errors.Kind.Refused)
		return
	}
	if step == .More {
		if !disk_import_ask("read_range", imports.read.received, true) {
			system.log_fact(.Warning, Disk_Load_Refused_Call_Not_Taken{refused_process = disk_load_name_field()})
			disk_import_refused(.Bad_State, errors.Kind.Refused)
			return
		}
		system.wait_records(wait, &load.client.calls.completions)
		return
	}
	hash := blake3.hash(imports.bytes)
	wanted := disk_process.scan_read_done(&imports.scan, imports.reading, hash)
	if wanted < 0 {
		disk_import_memory_free()
		disk_import_read_next(wait)
		return
	}
	// The file stays mapped until the end of the load: the loader copies
	// it into the process.
	imports.kept[wanted] = imports.memory
	imports.files[wanted] = {hash = hash, bytes = imports.bytes, name = entry_name}
	imports.memory = 0
	imports.bytes = nil
	item := &imports.scan.wanted[wanted]
	name := string(load.name[:load.name_length])
	system.log_fact(.Info, Import_Found{hash = value_kinds.Hash_Field(hash), loaded_process = module_name_field(name), importer = module_name_field(disk_import_importer_name(item.importer)), file = text_field(entry_name, 24)})
	if !disk_import_replaced(hash) {
		disk_imports_want(imports.files[wanted].bytes, imports.reading, item.level + 1)
	}
	if imports.scan.bound_passed {
		disk_import_bound_refusal()
		return
	}
	disk_import_read_next(wait)
}

// disk_import_importer_name gives the name of an importer for the log: the
// process, or the entry of a file that the scan kept.
disk_import_importer_name :: proc "contextless" (importer: int) -> string {
	if importer < 0 {
		return string(disk_load.name[:disk_load.name_length])
	}
	return disk_process.scan_entry_name(&disk_imports.scan, importer)
}

// disk_import_missing_refusal ends the load: a wanted hash has no file of
// the store whose bytes have it. The line names the import and its
// importer.
disk_import_missing_refusal :: proc "contextless" () {
	imports := &disk_imports
	item := &imports.scan.wanted[disk_process.scan_missing(&imports.scan)]
	hash := value_kinds.Hash_Field(item.hash)
	importer := module_name_field(disk_import_importer_name(item.importer))
	if imports.scan.entries_left_out {
		system.log_fact(.Warning, Disk_Load_Refused_Import_Missing_Entries_Left_Out{hash = hash, scan_reads = u64(imports.scan.reads), refused_process = disk_load_name_field(), importer = importer})
	} else {
		system.log_fact(.Warning, Disk_Load_Refused_Import_Missing{hash = hash, scan_reads = u64(imports.scan.reads), refused_process = disk_load_name_field(), importer = importer})
	}
	disk_import_refused(.Bad_Handle, errors.Kind.Absent)
}

// disk_import_bound_refusal ends the load: the imports pass the bounds of
// the scan.
disk_import_bound_refusal :: proc "contextless" () {
	system.log_fact(.Warning, Disk_Load_Refused_Import_Bounds{wanted_capacity = u64(disk_process.SCAN_WANTED_CAPACITY), depth_limit = u64(disk_process.SCAN_DEPTH_LIMIT), refused_process = disk_load_name_field()})
	disk_import_refused(.No_Slot, errors.Kind.Full)
}

// disk_import_refused ends the load with the error record of the command
// with the kind of the refusal. The caller wrote the fact of its cause.
disk_import_refused :: proc "contextless" (status: system.Status, kind_of_error: errors.Kind) {
	kind := u32(root_ring.Root_Command.Start_From_Disk)
	disk_load_end(status, errors.ring_fail(kind, kind_of_error, .Modules, 2, 0, 0, i64(status)))
}

// disk_load_name_field gives the name of the disk process that the load
// reads, as the field of a fact of its refusal.
disk_load_name_field :: proc "contextless" () -> value_kinds.Module_Name_Field {
	return module_name_field(string(disk_load.name[:disk_load.name_length]))
}

// disk_import_memory_free frees the memory of the entry that is read.
disk_import_memory_free :: proc "contextless" () {
	imports := &disk_imports
	if imports.bytes != nil {
		system.memory_unmap(raw_data(imports.bytes))
	}
	if imports.memory != 0 {
		system.close(imports.memory)
	}
	imports.memory = 0
	imports.bytes = nil
}

// disk_imports_end gives back each memory of the scan: the entry that is
// read and each file that it kept. The end of each load calls it.
disk_imports_end :: proc "contextless" () {
	imports := &disk_imports
	disk_import_memory_free()
	for &memory, index in imports.kept {
		if memory == 0 {
			continue
		}
		if imports.files[index].bytes != nil {
			system.memory_unmap(raw_data(imports.files[index].bytes))
		}
		system.close(memory)
		memory = 0
	}
	imports^ = {}
	imports.reading = -1
}
