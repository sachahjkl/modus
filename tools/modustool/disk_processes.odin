package modustool

// The disk of the disk processes: a data disk in the format of the storage
// service, which holds the store `module_files` with module files, written by
// the tool with no machine
// (docs/TOOLS.md, "The disk of the disk processes").
// The root service starts a process from it when a principal names the
// process and the hash of its file
// (docs/MODULE_CONTRACT.md, "A module from a disk").
//
// The writer makes one commit of a new disk: the blocks of data and the
// object nodes of each file, one leaf with the entries, the store block,
// then the root. It is not the engine of the storage service: it writes a
// whole disk one time, and changes none. A host test opens its image with
// the code of the open of the service (src/library/private/storage/storage_mount),
// and compares each object and each hash (disk_processes_test.odin).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import debug_object "modus:contract/debug_object"
import "modus:contract/disk_process_page"
import format "modus:contract/store"
import "modus:support/disk_process"
import block_tree "modus:private/storage/storage_object"

// The module that the tool writes on the disk of the test: a row of the
// module table that is not in the boot image.
DISK_MODULE_NAME :: "visitor"

// A library module and a module that imports it: two rows of the module
// table that are not in the boot image. The root service finds the import
// in the store `module_files` by the hash of its bytes.
STORE_LIBRARY_MODULE :: "store_library"
STORE_IMPORTER_MODULE :: "store_importer"

// The path at which the listener of the tool serves the library with one
// byte changed: the module file service writes it over the entry of the
// library, and the import scan then finds no file with the hash of the
// import.
STORE_LIBRARY_CHANGED_PATH :: "/store_library_changed"

TEST_DISK_MODULES_DISK :: BUILD_FOLDER + "/test_disk_modules_disk.img"
TEST_OUTPUT_DISK_PROCESSES :: BUILD_FOLDER + "/test_output_disk_processes_%d.txt"

// The generation of the root that the writer makes. The first root of a
// format has the generation 1 and names no store: the open takes a disk
// with only that root for a disk to format.
MODULE_DISK_GENERATION :: 2

// One module file of the store `module_files`: the name of its entry, and its
// bytes.
Module_File :: struct {
	name:  string,
	bytes: []u8,
}

// The disk that the writer fills: the image, and the next free block.
// Blocks 0 and 1 are the two places of the root.
Module_Disk :: struct {
	image: []u8,
	next:  u64,
	full:  bool, // A block did not fit: the image is not a disk.
}

// module_disk_put writes one block in the next free block, and gives its
// number.
module_disk_put :: proc(disk: ^Module_Disk, bytes: []u8) -> u64 {
	number := disk.next
	if (number + 1) * format.BLOCK_SIZE > u64(len(disk.image)) {
		disk.full = true
		return 0
	}
	disk.next += 1
	copy(disk.image[number * format.BLOCK_SIZE:][:format.BLOCK_SIZE], bytes)
	return number
}

// The object that the writer builds: its bytes, and the value of each of
// its blocks (zero for a hole), for its hash.
Module_Object :: struct {
	bytes:  []u8,
	blocks: u64, // The blocks of the object, holes included.
	values: []format.Block_Value,
}

// module_object_block gives the block `index` of an object, with zero
// bytes after its last byte.
module_object_block :: proc(object: ^Module_Object, index: u64) -> (block: block_tree.Block) {
	start := index * format.BLOCK_SIZE
	if start < u64(len(object.bytes)) {
		copy(block[:], object.bytes[start:])
	}
	return block
}

// module_object_child writes the part of an object under one child of a
// node: a block of data for the level 0, else an object node and what is
// under it. A part whose bytes are all zero is a hole: nothing is written,
// and the child is zero. base is the first block of the part.
module_object_child :: proc(disk: ^Module_Disk, object: ^Module_Object, level: int, base: u64) -> (child: format.Object_Child) {
	if base >= object.blocks {
		return {}
	}
	if level == 0 {
		block := module_object_block(object, base)
		if block_tree.is_zero(block[:]) {
			return {}
		}
		value := block_tree.block_value(&block, base)
		object.values[base] = value
		number := module_disk_put(disk, block[:])
		return {block = number, check = format.value_check(value), blocks = 1, value = value}
	}
	node: format.Object_Node
	held: u64
	count: u32
	for &item, index in node.children {
		item = module_object_child(disk, object, level - 1, base + u64(index) * format.object_span(level - 1))
		if item.block != 0 {
			count += 1
			held += item.blocks
		}
	}
	if count == 0 {
		return {}
	}
	node.header = {level = u32(level), count = count, magic = format.OBJECT_NODE_MAGIC}
	bytes := ([^]u8)(&node)[:format.BLOCK_SIZE]
	number := module_disk_put(disk, bytes)
	return {block = number, check = format.check(bytes), blocks = held + 1, value = block_tree.node_value(&node)}
}

// The two procedures that the hash of an object asks for: the value of a
// whole part before the last block, from the values of its blocks, and the
// bytes of the last block.
module_object_range_value :: proc "contextless" (source: ^block_tree.Hash_Source, first: u64, count: u64) -> (value: format.Block_Value, outcome: block_tree.Read) {
	object := (^Module_Object)(source.data)
	if count == 0 || count > format.OBJECT_FANOUT * format.OBJECT_FANOUT * format.OBJECT_FANOUT || first + count > u64(len(object.values)) {
		return {}, .Wrong
	}
	// A whole part is a power of two of blocks: its value is the value of
	// its two halves.
	if count == 1 {
		return object.values[first], .Good
	}
	left, left_outcome := module_object_range_value(source, first, count / 2)
	right, right_outcome := module_object_range_value(source, first + count / 2, count / 2)
	if left_outcome != .Good || right_outcome != .Good {
		return {}, .Wrong
	}
	return block_tree.pair_value(left, right), .Good
}

module_object_last_block :: proc "contextless" (source: ^block_tree.Hash_Source, index: u64, into: ^block_tree.Block) -> block_tree.Read {
	object := (^Module_Object)(source.data)
	into^ = {}
	start := index * format.BLOCK_SIZE
	if start < u64(len(object.bytes)) {
		copy(into[:], object.bytes[start:])
	}
	return .Good
}

// module_object_write writes the block tree of one object, and gives its
// entry: its size, the root of its block tree, the blocks that it holds,
// and the hash of the object (docs/STORAGE.md, "The hash of an object").
module_object_write :: proc(disk: ^Module_Disk, bytes: []u8) -> (entry: format.Entry, held: u64, ok: bool) {
	size := u64(len(bytes))
	object := Module_Object {
		bytes  = bytes,
		blocks = format.object_blocks(size),
	}
	object.values = make([]format.Block_Value, object.blocks, context.temp_allocator)
	root := module_object_child(disk, &object, format.object_levels(size), 0)
	source := block_tree.Hash_Source {
		range_value = module_object_range_value,
		last_block  = module_object_last_block,
		data        = &object,
	}
	hash, outcome, _ := block_tree.object_hash(size, &source)
	if outcome != .Good || disk.full {
		return {}, 0, false
	}
	entry = {
		kind       = u64(format.Entry_Kind.Object),
		size       = size,
		generation = MODULE_DISK_GENERATION,
		hash       = hash,
		pointer    = {block = root.block, check = root.check},
	}
	return entry, root.blocks, true
}

// The store `module_files` of the named principal 1, as the root service names
// it for a load of a disk process of its session
// (principals.store_name_write).
PRINCIPAL_MODULE_FILES_STORE :: disk_process.STORE_NAME + ".principal.1"

// module_files_check refuses the files of one store that the root service
// would refuse: a name that is no name of an entry, two files of one name,
// a file with no byte, a file over the limit of a disk process, and more
// files than one leaf holds. It gives the files in the order of their
// names, in temporary memory.
module_files_check :: proc(store_name: string, files: []Module_File) -> (sorted: []Module_File, ok: bool) {
	if len(files) == 0 || len(files) > format.LEAF_CAPACITY {
		fmt.eprintfln("modustool: the store %s of the tool holds 1 to %d files, and %d are given", store_name, format.LEAF_CAPACITY, len(files))
		return nil, false
	}
	sorted = slice.clone(files, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Module_File) -> bool {
		return a.name < b.name
	})
	for file, index in sorted {
		// The object of the disk grant table is no module file: a test puts
		// a table there that the root service must refuse. The debug object
		// of a module file has the hash of the module as its name.
		debug_object_file := disk_process.debug_object_name_is(file.name)
		if problem, _ := disk_process.name_problem(file.name); problem != .None && problem != .Table_Name && !debug_object_file {
			fmt.eprintfln("modustool: %q is no name of a disk process: %v", file.name, problem)
			return nil, false
		}
		if index > 0 && sorted[index - 1].name == file.name {
			fmt.eprintfln("modustool: two files of the store %s have the name %s", store_name, file.name)
			return nil, false
		}
		limit := debug_object_file ? disk_process.DEBUG_OBJECT_BYTES_LIMIT : disk_process.FILE_BYTES_LIMIT
		if len(file.bytes) == 0 || len(file.bytes) > limit {
			fmt.eprintfln("modustool: the file %s has %d bytes; a %s of a disk process has 1 to %d", file.name, len(file.bytes), debug_object_file ? "debug object" : "module file", limit)
			return nil, false
		}
	}
	return sorted, true
}

// module_files_store_put writes the objects of one store, its leaf and its
// store block, and gives the cell of the store in the root. sorted are the
// files that module_files_check gave.
module_files_store_put :: proc(disk: ^Module_Disk, store_name: string, sorted: []Module_File, disk_size: int) -> (cell: format.Store_Entry, ok: bool) {
	leaf: [format.BLOCK_SIZE]u8
	header := (^format.Tree_Header)(&leaf)
	header.magic = format.NODE_MAGIC
	header.count = u32(len(sorted))
	record_size := size_of(format.Entry_Name) + size_of(format.Entry)
	store_block: format.Store_Block
	for file, index in sorted {
		entry, held, written := module_object_write(disk, file.bytes)
		if !written {
			fmt.eprintfln("modustool: the file %s does not fit in a disk of %d bytes", file.name, disk_size)
			return {}, false
		}
		record := leaf[format.TREE_HEADER_SIZE + index * record_size:][:record_size]
		copy(record[:size_of(format.Entry_Name)], file.name)
		copy(record[size_of(format.Entry_Name):], ([^]u8)(&entry)[:size_of(format.Entry)])
		store_block.objects += 1
		store_block.current_blocks += held
	}
	leaf_number := module_disk_put(disk, leaf[:])
	store_block.tree = {block = leaf_number, check = format.check(leaf[:])}
	store_block.node_blocks = 1
	store_bytes := ([^]u8)(&store_block)[:format.BLOCK_SIZE]
	store_number := module_disk_put(disk, store_bytes)
	if disk.full {
		fmt.eprintfln("modustool: the store %s does not fit in a disk of %d bytes", store_name, disk_size)
		return {}, false
	}
	copy(cell.name[:format.NAME_CAPACITY - 1], store_name)
	cell.limit = disk_process.STORE_BLOCKS_LIMIT
	// Its store block, its leaf, and the blocks of its objects.
	cell.used = 2 + store_block.current_blocks
	cell.store = {block = store_number, check = format.check(store_bytes)}
	return cell, true
}

// module_disk_encode gives the bytes of a data disk of disk_size bytes
// that holds the store `module_files` with these files, as one commit, and,
// when principal_files has files, the store `module_files` of the named
// principal 1 with them. The entries of a store are in the order of their
// names, in one leaf: the writer takes at most the entries of one leaf. It
// refuses a name that the root service would refuse as the name of an
// entry, a file with no byte, and a file over the limit of a disk process.
module_disk_encode :: proc(files: []Module_File, disk_size: int, principal_files: []Module_File = nil, allocator := context.allocator) -> (image: []u8, ok: bool) {
	sorted := module_files_check(disk_process.STORE_NAME, files) or_return
	principal_sorted: []Module_File
	if len(principal_files) > 0 {
		principal_sorted = module_files_check(PRINCIPAL_MODULE_FILES_STORE, principal_files) or_return
	}
	disk := Module_Disk {
		image = make([]u8, disk_size, allocator),
		next  = 2,
	}
	defer if !ok {
		delete(disk.image, allocator)
	}
	root := new(format.Root, context.temp_allocator)
	root.magic = format.ROOT_MAGIC
	root.generation = MODULE_DISK_GENERATION
	root.disk_blocks = u64(disk_size) / format.BLOCK_SIZE
	root.stores[0] = module_files_store_put(&disk, disk_process.STORE_NAME, sorted, disk_size) or_return
	if len(principal_sorted) > 0 {
		root.stores[1] = module_files_store_put(&disk, PRINCIPAL_MODULE_FILES_STORE, principal_sorted, disk_size) or_return
	}
	root.check = format.root_check(root)
	copy(disk.image[:format.BLOCK_SIZE], ([^]u8)(root)[:format.BLOCK_SIZE])
	return disk.image, true
}

// module_disk_write writes the disk of the store `module_files`, and of the
// store `module_files` of the named principal 1 when principal_files has
// files, to a file, and prints the hash of each module file: the hash that
// the principal names in start_from_disk.
module_disk_write :: proc(path: string, files: []Module_File, principal_files: []Module_File = nil) -> bool {
	image := module_disk_encode(files, DATA_DISK_SIZE, principal_files) or_return
	defer delete(image)
	if err := os.write_entire_file(path, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	stores := [2]struct {
		name:  string,
		files: []Module_File,
	}{{disk_process.STORE_NAME, files}, {PRINCIPAL_MODULE_FILES_STORE, principal_files}}
	for store in stores {
		for file in store.files {
			if disk_process.debug_object_name_is(file.name) {
				fmt.printfln("modustool: %s: the store %s holds the debug object of the module %s, %d bytes", path, store.name, file.name, len(file.bytes))
				continue
			}
			hash := blake3.hash(file.bytes)
			digits: [disk_process.HASH_DIGITS]u8
			disk_process.hash_write(&digits, hash)
			fmt.printfln("modustool: %s: the store %s holds %s, %d bytes, hash %s", path, store.name, file.name, len(file.bytes), string(digits[:]))
		}
	}
	return true
}

// module_debug_object_file gives the object of the store `module_files` that
// holds the debug object of a module file: its name is the hash of the
// module (src/md/features/debug_object_of_a_disk_process.md). It refuses
// an object that the readers refuse, and one that names another module: a
// debug object of another build names the wrong procedures.
module_debug_object_file :: proc(module_name: string, module_file: []u8, object: []u8) -> (file: Module_File, ok: bool) {
	if fault := debug_object.check(object); fault != .None {
		fmt.eprintfln("modustool: the debug object of %s is refused: %s", module_name, debug_object.fault_sentences[fault])
		return {}, false
	}
	module_hash := blake3.hash(module_file)
	named, described := debug_object.module_hash_of(object)
	if !described || named != module_hash {
		fmt.eprintfln("modustool: the debug object of %s names the module %s, and the module file has the hash %s: it describes another build", module_name, hash_as_hexadecimal(named), hash_as_hexadecimal(module_hash))
		return {}, false
	}
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.debug_object_name_write(&digits, module_hash)
	return {name = strings.clone(string(digits[:]), context.temp_allocator), bytes = object}, true
}

// The machine of the disk processes: its data disk holds the store
// `module_files` with three entries that hold the module `visitor`, which is
// not in the boot image.
//
//   visitor   the file: the root service starts it, and it says that it
//             holds no grant.
//   changed   the file with one byte changed: its bytes do not have the
//             hash that the line names, and the root service refuses it.
//   notes     the file, under a name that the grant table of the root
//             service gives a store: the name gives nothing, and the root
//             service refuses it before it reads.
//
// The store also holds outsider, the module of visitor built outside the
// sources, and its debug object under the hash of the module: the
// debugger attaches to outsider, reads the debug object through the
// storage service, and names a frame of it by its procedure, its file and
// its line (disk_processes_debugger_steps). And outsider_fault, the same
// copy built to write to the address 0 after its start, with its debug
// object: the root service keeps its stop report, and the debugger names
// its frames with no attach (disk_processes_stop_report_steps).
//
// And two modules that no boot image holds: store_library, a library
// module, and store_importer, a module that imports it.
//
// The store module_files of principal 0 holds 10 objects: 7 module files (visitor, changed, notes,
// outsider, outsider_fault, store_library, store_importer), the debug
// objects of outsider and outsider_fault, and grant_table. The list of the
// module file service skips the debug objects and grant_table, and counts
// received, which it writes: 8 files. The store module_files of principal 1
// holds 2 objects (visitor and grant_table): the open of the storage
// service counts 2 stores and 12 objects.
//
// The storage service runs before the first line that reads the store, so
// no step depends on the time of the open of the disk.
//
// Then the disk grant table of principal 0, which the console acts for: a
// grant that no command gives is refused; the grant store goes to the
// nickname visitor, whose next start has the store disk-visitor and counts
// its visit there; a start of the nickname with another hash is refused
// before any read; two moves of the nickname keep its grant and its store.
// Then the module file service of the machine fetches the same module file
// from the listener of the tool, through QEMU user networking, and stores
// it under the nickname `received`; its list gives the hash of the bytes of
// each file; the root service starts `received` by that hash. Then the
// process store_importer starts with its import store_library, which the
// root service finds in the store by the hash of its bytes; after the
// module file service writes other bytes under the name store_library, the
// same start is refused.
//
// A second machine starts on the same disk. Principal 0 has no passphrase,
// so its table did not last: the nickname has no row. A new grant finds
// the store of the nickname with its two visits. Then the machine
// passphrase is set in the window of unlock: the root service reads the
// table that the tool wrote on the disk, refuses it, as another key signed
// it, and writes its own table.
//
// A third machine starts on the same disk: until the machine passphrase is
// typed, the nickname has no row and a change is refused; a wrong
// passphrase opens nothing; the right one gives back the row, and the
// store of the nickname with its three visits. A row set to last until the
// machine stops leaves the disk. Then the console, which acts for principal
// 0, restores the first version of grant_table, which the tool signed.
//
// A fourth machine starts on the same disk: the machine passphrase opens
// the record, and the table on the disk does not verify under its key. It
// is refused and kept: nothing is written over it, a change is refused, and
// so is a second machine passphrase.
//
// The tool writes, as the object grant_table of the store module_files, a
// table that gives the grant store to the nickname visitor, with a tag
// under a key of zero bytes: what a reader of the disk with no passphrase
// can write. No machine passphrase gives that key.
disk_processes_tests_run :: proc(part: ^Test_Part_Run) -> bool {
	module_file := read_file(module_path(DISK_MODULE_NAME)) or_return
	changed_file := slice.clone(module_file, context.temp_allocator)
	changed_file[len(changed_file) - 1] ~= 0x01
	// A module of another project: built from a folder outside the
	// sources, under a name that the boot image does not have.
	outsider_file, outsider_debug_object := outside_module_for_a_disk() or_return
	// Its debug object, beside it in the store, under the hash of the
	// module: the debugger reads it at an attach.
	outsider_debug_file := module_debug_object_file(OUTSIDE_DISK_MODULE, outsider_file, outsider_debug_object) or_return
	// The same copy, built to fault after its start, with its debug
	// object: the root service keeps its stop report, and the debugger
	// names its frames with no attach.
	fault_file, fault_debug_object := outside_module_for_a_disk(faults = true) or_return
	fault_debug_file := module_debug_object_file(OUTSIDE_FAULT_MODULE, fault_file, fault_debug_object) or_return
	forged: disk_process.Grant_Table
	if disk_process.table_allow(&forged, DISK_MODULE_NAME, blake3.hash(module_file), .Store) != .None {
		fmt.eprintln("modustool: the table of the disk of the disk processes takes no row")
		return false
	}
	forged_key: [disk_process.KEY_SIZE]u8
	forged_bytes: [disk_process.TABLE_SIZE]u8
	disk_process.table_encode(&forged, &forged_key, &forged_bytes)
	library_file := read_file(module_path(STORE_LIBRARY_MODULE)) or_return
	importer_file := read_file(module_path(STORE_IMPORTER_MODULE)) or_return
	// The listener serves these bytes during the machine, after the steps
	// that free the temporary memory: they have memory of their own.
	changed_library_file := slice.clone(library_file)
	defer delete(changed_library_file)
	changed_library_file[len(changed_library_file) - 1] ~= 0x01
	files := [?]Module_File{{DISK_MODULE_NAME, module_file}, {"changed", changed_file}, {"notes", module_file}, {OUTSIDE_DISK_MODULE, outsider_file}, outsider_debug_file, {OUTSIDE_FAULT_MODULE, fault_file}, fault_debug_file, {disk_process.TABLE_OBJECT_NAME, forged_bytes[:]}, {STORE_LIBRARY_MODULE, library_file}, {STORE_IMPORTER_MODULE, importer_file}}
	// The store module_files of the named principal 1, before the principal
	// exists: the module file, and the same forged table.
	principal_files := [?]Module_File{{DISK_MODULE_NAME, module_file}, {disk_process.TABLE_OBJECT_NAME, forged_bytes[:]}}
	module_disk_write(TEST_DISK_MODULES_DISK, files[:], principal_files[:]) or_return
	hash_digits, changed_digits, outsider_digits, fault_digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&outsider_digits, blake3.hash(outsider_file))
	disk_process.hash_write(&fault_digits, blake3.hash(fault_file))
	disk_process.hash_write(&hash_digits, blake3.hash(module_file))
	disk_process.hash_write(&changed_digits, blake3.hash(changed_file))
	// The machine test frees the temporary memory after each step: the
	// texts of the steps stay.
	hash := fmt.aprintf("%s", string(hash_digits[:]))
	changed_hash := fmt.aprintf("%s", string(changed_digits[:]))
	outsider_hash := fmt.aprintf("%s", string(outsider_digits[:]))
	defer delete(outsider_hash)
	fault_hash := fmt.aprintf("%s", string(fault_digits[:]))
	defer delete(fault_hash)
	defer delete(hash)
	defer delete(changed_hash)
	import_hashes := Store_Import_Hashes {
		importer        = hash_digits_of(importer_file),
		library         = hash_digits_of(library_file),
		changed_library = hash_digits_of(changed_library_file),
	}
	defer delete(import_hashes.importer)
	defer delete(import_hashes.library)
	defer delete(import_hashes.changed_library)
	steps := make([dynamic]Step)
	defer delete(steps)
	// The storage service takes the disk of the tool before or after the
	// console has its window: the system fixes no order, so neither wait
	// moves the place of the log.
	append(&steps, Step{kind = .Wait, text = "storage: ok, generation 2: 2 stores, 12 objects", any_order = true})
	append(&steps, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&steps, Step{kind = .Wait, text = "[console]   module     storage"})
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", DISK_MODULE_NAME, hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: reads %s from the store module_files of the storage service, for principal 0", DISK_MODULE_NAME)})
	// The process writes its first line when it runs, and the root service
	// writes its line when the start returned: the system fixes no order.
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s", DISK_MODULE_NAME, hash), any_order = true})
	append(&steps, Step{kind = .Wait, text = "visitor: ok, a process that the boot image does not hold"})
	append(&steps, Step{kind = .Wait, text = "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must"})
	append(&steps, Step{kind = .Wait, text = "visitor: no ring to the root service: the open of its handle is refused: as it must"})
	// The module of another project, from the same store: the root service
	// starts it by its hash, with no grant, as it starts any disk process.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", OUTSIDE_DISK_MODULE, outsider_hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with no grant", OUTSIDE_DISK_MODULE, outsider_hash), any_order = true})
	append(&steps, Step{kind = .Wait, text = "visitor: no ring to the root service: the open of its handle is refused: as it must"})
	disk_processes_debugger_steps(&steps, outsider_hash)
	append(&steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", OUTSIDE_DISK_MODULE)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", OUTSIDE_DISK_MODULE)})
	disk_processes_stop_report_steps(&steps, fault_hash)
	// The bytes of the entry are not the bytes of the hash of the line.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"changed\", \"%s\")", hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: refused changed from the disk: its bytes have the hash %s", changed_hash)})
	// A name of the grant table: refused before any read.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"notes\", \"%s\")", hash)})
	append(&steps, Step{kind = .Wait, text = "root: refused notes from the disk: the grant table of the root service names it, and a disk process takes no grant by its name"})
	// A name with no entry.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"nobody\", \"%s\")", hash)})
	append(&steps, Step{kind = .Wait, text = "root: refused nobody from the disk: the store module_files has no object with this name"})
	// The disk grant table. A grant that no command gives is refused, with
	// its sentence.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("allow(\"%s\", \"root_ring\")", DISK_MODULE_NAME)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: refused the grant Root_Ring to the nickname %s: no command gives it to a disk process, as it reaches the whole machine or the principal", DISK_MODULE_NAME)})
	// The store: the row names the hash of the process that runs.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("allow(\"%s\", \"store\")", DISK_MODULE_NAME)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: the nickname %s, the file %s, has the grant store for principal 0, from its next start; principal 0 has no passphrase, so its disk grant table lasts until the machine stops", DISK_MODULE_NAME, hash)})
	append(&steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", DISK_MODULE_NAME)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", DISK_MODULE_NAME)})
	// Two hashes never share a nickname: refused before any read.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", DISK_MODULE_NAME, changed_hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: refused %s from the disk: the nickname names the file %s, and the command names the file %s; nickname_move points it to another file", DISK_MODULE_NAME, hash, changed_hash)})
	// No hash: the hash of the row, and the store of the nickname.
	disk_processes_store_steps(&steps, hash, 1)
	// Two moves: the grant and the store follow the nickname.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("nickname_move(\"%s\", \"%s\")", DISK_MODULE_NAME, changed_hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: the file %s will get the data of %s", changed_hash, DISK_MODULE_NAME)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: the nickname %s names the file %s, with its grants and its store", DISK_MODULE_NAME, changed_hash)})
	append(&steps, Step{kind = .Type, text = fmt.aprintf("nickname_move(\"%s\", \"%s\")", DISK_MODULE_NAME, hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: the file %s will get the data of %s", hash, DISK_MODULE_NAME)})
	disk_processes_store_steps(&steps, hash, 2)
	disk_processes_network_steps(&steps, hash, changed_hash, len(module_file), len(changed_file))
	disk_processes_import_steps(&steps, import_hashes, len(changed_library_file))
	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	// The listener of the tool is the web server of the module file
	// service: QEMU gives it the address 10.0.2.100 port 80.
	// The listener sends the file during a later step: the memory of
	// context.temp_allocator is free again after each step, so the bytes
	// that it serves live until the end of the test.
	served_bytes := slice.clone(module_file)
	defer delete(served_bytes)
	served := [?]Listener_File{{path = "/" + DISK_MODULE_NAME, bytes = served_bytes}, {path = STORE_LIBRARY_CHANGED_PATH, bytes = changed_library_file}}
	machine_test(part, steps[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 1), exit_status = MACHINE_STOP_OK, data_disk = TEST_DISK_MODULES_DISK, user_network = true, served_files = served[:]}) or_return

	// The second machine, on the same disk.
	again := make([dynamic]Step)
	defer delete(again)
	append(&again, Step{kind = .Wait, text = "storage: ok, generation ", any_order = true})
	append(&again, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&again, Step{kind = .Front, text = "console"})
	append(&again, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&again, Step{kind = .Wait, text = "[console]   module     storage"})
	append(&again, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"\")", DISK_MODULE_NAME)})
	append(&again, Step{kind = .Wait, text = fmt.aprintf("root: refused %s from the disk: the nickname has no row in the disk grant table of principal 0: name the hash of its file", DISK_MODULE_NAME)})
	append(&again, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", DISK_MODULE_NAME, hash)})
	append(&again, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with no grant", DISK_MODULE_NAME, hash), any_order = true})
	append(&again, Step{kind = .Wait, text = "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must"})
	append(&again, Step{kind = .Type, text = fmt.aprintf("allow(\"%s\", \"store\")", DISK_MODULE_NAME)})
	append(&again, Step{kind = .Wait, text = fmt.aprintf("root: the nickname %s, the file %s, has the grant store for principal 0", DISK_MODULE_NAME, hash)})
	append(&again, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", DISK_MODULE_NAME)})
	append(&again, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", DISK_MODULE_NAME)})
	// The store of the nickname kept its two visits across the restart.
	disk_processes_store_steps(&again, hash, 3)
	// The machine passphrase, typed two times in the window of unlock and
	// never in the console. The key comes with a read: the table on the
	// disk has a tag of another key, so it is refused, and the table of
	// this machine is written over it.
	append(&again, Step{kind = .Type, text = "machine_passphrase()"})
	append(&again, Step{kind = .Wait, text = "root: the machine passphrase is set in the window of unlock"})
	append(&again, Step{kind = .Wait, text = "compositor: surface unlock"})
	append(&again, Step{kind = .Front, text = "unlock"})
	append(&again, Step{kind = .Type, text = MACHINE_PASSPHRASE})
	append(&again, Step{kind = .Type, text = MACHINE_PASSPHRASE})
	append(&again, Step{kind = .Wait, text = "unlock: the machine passphrase is set: the machine key is sealed in the store of unlock under a key of Argon2id, 19456 KiB and 2 passes, derived in "})
	// unlock can stop before or after the lines of the root service on the
	// table: this wait does not move the place of the log.
	append(&again, Step{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true})
	append(&again, Step{kind = .Wait, text = "root: refused the disk grant table of principal 0 from the store module_files: its tag does not verify under the key of the principal: another key wrote it, or a byte changed; it gives no grant, and the table of the new machine passphrase is written over it"})
	append(&again, Step{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store module_files: 1 rows, with the tag of the machine key"})
	append(&again, Step{kind = .Front, text = "console"})
	append(&again, Step{kind = .Type, text = "shutdown()"})
	append(&again, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	machine_test(part, again[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 2), exit_status = MACHINE_STOP_OK, data_disk = TEST_DISK_MODULES_DISK}) or_return

	// The third machine, on the same disk, with the machine passphrase.
	third := make([dynamic]Step)
	defer delete(third)
	append(&third, Step{kind = .Wait, text = "storage: ok, generation ", any_order = true})
	append(&third, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&third, Step{kind = .Wait, text = "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed", any_order = true})
	append(&third, Step{kind = .Wait, text = "compositor: surface unlock"})
	// Before the passphrase: the machine runs, the table holds no row, and
	// a change is refused.
	append(&third, Step{kind = .Front, text = "console"})
	append(&third, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"\")", DISK_MODULE_NAME)})
	append(&third, Step{kind = .Wait, text = fmt.aprintf("root: refused %s from the disk: the nickname has no row in the disk grant table of principal 0: name the hash of its file", DISK_MODULE_NAME)})
	append(&third, Step{kind = .Type, text = fmt.aprintf("allow(\"%s\", \"store\")", DISK_MODULE_NAME)})
	append(&third, Step{kind = .Wait, text = "root: refused a change of the disk grant table of principal 0: the machine passphrase is not typed; type it in the window of unlock"})
	// A wrong passphrase opens nothing; the right one gives the key.
	append(&third, Step{kind = .Front, text = "unlock"})
	append(&third, Step{kind = .Type, text = "wrong passphrase"})
	append(&third, Step{kind = .Wait, text = "unlock: the machine passphrase is wrong: the seal does not open, the disk grants of principal 0 stay absent (1 in all)"})
	append(&third, Step{kind = .Type, text = MACHINE_PASSPHRASE})
	append(&third, Step{kind = .Wait, text = "unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only", any_order = true})
	append(&third, Step{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true})
	append(&third, Step{kind = .Wait, text = "root: read the disk grant table of principal 0 from the store module_files: 1 rows, with the tag of the machine key"})
	append(&third, Step{kind = .Front, text = "console"})
	append(&third, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&third, Step{kind = .Wait, text = "[console]   module     storage"})
	// The grant survived the restart, and the store of the nickname has its
	// three visits.
	disk_processes_store_steps(&third, hash, 4)
	// A row that lasts until the machine stops is not written: the table on
	// the disk then holds no row.
	append(&third, Step{kind = .Type, text = fmt.aprintf("disk_persistence(\"%s\", \"forget\")", DISK_MODULE_NAME)})
	append(&third, Step{kind = .Wait, text = fmt.aprintf("root: the row of the nickname %s in the disk grant table of principal 0 has the setting: last until the machine stops; the machine passphrase keeps the disk grant table of principal 0 on the disk", DISK_MODULE_NAME)})
	append(&third, Step{kind = .Wait, text = "root: the disk grant table of principal 0 is written in the store module_files: 0 rows, with the tag of the machine key"})
	// The console acts for principal 0 and restores the first version of
	// the table, which the tool signed with another key: what a holder of
	// the store can do. The first place of a new start is 1.
	append(&third, Step{kind = .Type, text = fmt.aprintf("storage.open_store(\"%s\")", disk_process.STORE_NAME)})
	append(&third, Step{kind = .Wait, text = "[console] 1"})
	append(&third, Step{kind = .Type, text = fmt.aprintf("storage.restore(1, \"%s\", %d)", disk_process.TABLE_OBJECT_NAME, MODULE_DISK_GENERATION)})
	append(&third, Step{kind = .Wait, text = "[console] "})
	append(&third, Step{kind = .Type, text = "shutdown()"})
	append(&third, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	machine_test(part, third[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 3), exit_status = MACHINE_STOP_OK, data_disk = TEST_DISK_MODULES_DISK}) or_return

	// The fourth machine: the machine passphrase opens the record, and the
	// table on the disk does not verify under its key. It is refused and
	// kept: nothing is written over it, and each change is refused.
	fourth := make([dynamic]Step)
	defer delete(fourth)
	append(&fourth, Step{kind = .Wait, text = "storage: ok, generation ", any_order = true})
	append(&fourth, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&fourth, Step{kind = .Wait, text = "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed", any_order = true})
	append(&fourth, Step{kind = .Wait, text = "compositor: surface unlock"})
	append(&fourth, Step{kind = .Front, text = "unlock"})
	append(&fourth, Step{kind = .Type, text = MACHINE_PASSPHRASE})
	append(&fourth, Step{kind = .Wait, text = "unlock: the machine passphrase opens the machine key; the root service receives the key of the disk grant table only", any_order = true})
	append(&fourth, Step{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true})
	append(&fourth, Step{kind = .Wait, text = "root: refused the disk grant table of principal 0 from the store module_files: its tag does not verify under the key of the principal: another key wrote it, or a byte changed; it gives no grant, and it is kept: no change is written over it", fails_on = "root: the disk grant table of principal 0 is written in the store module_files"})
	append(&fourth, Step{kind = .Front, text = "console"})
	append(&fourth, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"\")", DISK_MODULE_NAME)})
	append(&fourth, Step{kind = .Wait, text = fmt.aprintf("root: refused %s from the disk: the nickname has no row in the disk grant table of principal 0: name the hash of its file", DISK_MODULE_NAME)})
	append(&fourth, Step{kind = .Type, text = fmt.aprintf("allow(\"%s\", \"store\")", DISK_MODULE_NAME)})
	append(&fourth, Step{kind = .Wait, text = "root: refused a change of the disk grant table of principal 0: the table on the disk does not verify under the machine key, and it is kept; restore a version of it that verifies, then start the machine again"})
	append(&fourth, Step{kind = .Type, text = "machine_passphrase()"})
	append(&fourth, Step{kind = .Wait, text = "root: refused a machine passphrase: the machine has one, and a change is not built", fails_on = "root: the disk grant table of principal 0 is written in the store module_files"})
	append(&fourth, Step{kind = .Type, text = "shutdown()"})
	append(&fourth, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	machine_test(part, fourth[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 4), exit_status = MACHINE_STOP_OK, data_disk = TEST_DISK_MODULES_DISK}) or_return
	return disk_processes_named_principal_tests_run(part, hash)
}

// The grants of a disk process of a named principal, on the same disk
// (docs/PRINCIPALS.md, "The disk grant table of a named principal").
//
// The fifth machine: the machine passphrase is skipped, and the console
// creates the principal alice. Its first unlock gives the root service the
// key of the tag of its table: the table that the tool wrote in the store
// processes of alice does not verify, and as the principal is new, the table
// of this machine is written over it. A console that the desktop starts
// during the session acts for alice: it starts visitor from the store of
// alice, gives it the grant store, and visitor counts its first visit in
// the store of its nickname for alice. The console also allows the client
// key of the peer, which goes into her table.
//
// The sixth machine: the passphrase of alice gives the key again, the
// table is read with its row and her client key, which holds again, and
// visitor starts by its nickname with the grant store and finds its first
// visit. A call of the peer acts for alice with no new allow; her
// revocation writes the table with no key.
disk_processes_named_principal_tests_run :: proc(part: ^Test_Part_Run, hash: string) -> bool {
	fifth := make([dynamic]Step)
	defer delete(fifth)
	append(&fifth, Step{kind = .Wait, text = "storage: ok, generation ", any_order = true})
	append(&fifth, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&fifth, Step{kind = .Wait, text = "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed", any_order = true})
	append(&fifth, Step{kind = .Wait, text = "compositor: surface unlock"})
	append(&fifth, Step{kind = .Front, text = "unlock"})
	append(&fifth, Step{kind = .Key, text = "ret"})
	append(&fifth, Step{kind = .Wait, text = "unlock: the machine passphrase is not typed: the disk grants of principal 0 stay absent until unlock asks again"})
	append(&fifth, Step{kind = .Wait, text = "root: unlock stopped with code 0"})
	append(&fifth, Step{kind = .Front, text = "console"})
	append(&fifth, Step{kind = .Type, text = "principal_create(\"alice\")"})
	append(&fifth, Step{kind = .Wait, text = "root: started unlock"})
	append(&fifth, Step{kind = .Wait, text = "compositor: surface unlock"})
	append(&fifth, Step{kind = .Front, text = "unlock"})
	append(&fifth, Step{kind = .Type, text = PRINCIPAL_PASSPHRASE})
	append(&fifth, Step{kind = .Type, text = PRINCIPAL_PASSPHRASE})
	append(&fifth, Step{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it"})
	// unlock stops before or after the lines of the root service on the
	// table: this wait does not move the place of the log.
	append(&fifth, Step{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true})
	// The table that the tool wrote has a tag under a key of zero bytes:
	// refused, and written over, as no record of alice signed it.
	append(&fifth, Step{kind = .Wait, text = "root: refused the disk grant table of principal 1 from the store module_files: its tag does not verify under the key of the principal: another key wrote it, or a byte changed; it gives no grant, and the table of the new principal is written over it"})
	append(&fifth, Step{kind = .Wait, text = "root: the disk grant table of principal 1 is written in the store module_files: 0 rows, with the tag of the key of the principal"})
	// A console of the session: it acts for alice, and for no other
	// principal.
	disk_processes_session_console_steps(&fifth)
	append(&fifth, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", DISK_MODULE_NAME, hash)})
	append(&fifth, Step{kind = .Wait, text = fmt.aprintf("root: reads %s from the store module_files of the storage service, for principal 1", DISK_MODULE_NAME)})
	append(&fifth, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with no grant, in the session of principal 1 \"alice\"", DISK_MODULE_NAME, hash), any_order = true})
	append(&fifth, Step{kind = .Wait, text = "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must"})
	append(&fifth, Step{kind = .Front, text = "console"})
	append(&fifth, Step{kind = .Type, text = fmt.aprintf("allow(\"%s\", \"store\")", DISK_MODULE_NAME)})
	append(&fifth, Step{kind = .Wait, text = fmt.aprintf("root: the nickname %s, the file %s, has the grant store for principal 1, from its next start; the passphrase of the principal keeps its disk grant table on the disk", DISK_MODULE_NAME, hash)})
	append(&fifth, Step{kind = .Wait, text = "root: the disk grant table of principal 1 is written in the store module_files: 1 rows, with the tag of the key of the principal; 0 client keys of remote"})
	// The client key of the peer, allowed by alice, is a key of her disk
	// grant table too: the allow writes the table again.
	append(&fifth, Step{kind = .Type, text = "remote_allow(\"{client key}\")"})
	append(&fifth, Step{kind = .Wait, text = "root: principal 1 allowed the client key ", any_order = true})
	append(&fifth, Step{kind = .Wait, text = " of remote: each call of that client acts for it; the disk grant table of the principal keeps the key across a restart"})
	append(&fifth, Step{kind = .Wait, text = "root: the disk grant table of principal 1 is written in the store module_files: 1 rows, with the tag of the key of the principal; 1 client keys of remote"})
	append(&fifth, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", DISK_MODULE_NAME)})
	append(&fifth, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", DISK_MODULE_NAME)})
	disk_processes_principal_store_steps(&fifth, hash, 1)
	append(&fifth, Step{kind = .Type, text = "shutdown()"})
	append(&fifth, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	machine_test(part, fifth[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 5), exit_status = MACHINE_STOP_OK, data_disk = TEST_DISK_MODULES_DISK}) or_return

	// The sixth machine: the grant of alice is back after her unlock.
	sixth := make([dynamic]Step)
	defer delete(sixth)
	append(&sixth, Step{kind = .Wait, text = "storage: ok, generation ", any_order = true})
	append(&sixth, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&sixth, Step{kind = .Wait, text = "unlock: the machine has a passphrase: the disk grants of principal 0 come when it is typed", any_order = true})
	append(&sixth, Step{kind = .Wait, text = "compositor: surface unlock"})
	append(&sixth, Step{kind = .Front, text = "unlock"})
	append(&sixth, Step{kind = .Key, text = "ret"})
	append(&sixth, Step{kind = .Wait, text = "unlock: principal 1 \"alice\" is locked: its passphrase opens its session"})
	append(&sixth, Step{kind = .Type, text = PRINCIPAL_PASSPHRASE})
	append(&sixth, Step{kind = .Wait, text = "unlock: the passphrase of principal 1 \"alice\" opens its seal; the root service receives the key of its disk grant table only, and the secret keys are erased", any_order = true})
	append(&sixth, Step{kind = .Wait, text = "root: the session of principal 1 \"alice\" starts: the desktop starts each process in it"})
	append(&sixth, Step{kind = .Wait, text = "root: unlock stopped with code 0", any_order = true})
	append(&sixth, Step{kind = .Wait, text = "root: read the disk grant table of principal 1 from the store module_files: 1 rows, with the tag of the key of the principal; 1 client keys of remote", fails_on = "root: the disk grant table of principal 1 is written in the store module_files"})
	// The client key of alice holds again from her table, with no new
	// allow.
	append(&sixth, Step{kind = .Wait, text = " of remote holds again for principal 1, from its disk grant table: each call of that client acts for it"})
	disk_processes_session_console_steps(&sixth)
	disk_processes_principal_store_steps(&sixth, hash, 2)
	disk_processes_client_key_steps(&sixth)
	append(&sixth, Step{kind = .Type, text = "shutdown()"})
	append(&sixth, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return machine_test(part, sixth[:], {volume = BOOT_VOLUME, output = self_test_file(TEST_OUTPUT_DISK_PROCESSES, 6), exit_status = MACHINE_STOP_OK, data_disk = TEST_DISK_MODULES_DISK})
}

// disk_processes_session_console_steps adds the steps that start a console
// from the menu of the desktop during the session of alice: the root
// service starts it in that session, and its connections act for alice.
// Its window is the console window in front: the next lines go to it.
disk_processes_session_console_steps :: proc(steps: ^[dynamic]Step) {
	append(steps, Step{kind = .Launch, text = "console"})
	append(steps, Step{kind = .Wait, text = "root: started console, with a terminal, in the session of principal 1 \"alice\""})
	append(steps, Step{kind = .Wait, text = "compositor: surface console"})
	append(steps, Step{kind = .Front, text = "console"})
}

// disk_processes_client_key_steps adds the steps of the client key of the
// peer that alice allowed on the machine before, and that her disk grant
// table kept: `remote` starts, and a call of the peer acts for alice with
// no new allow. Then the console of her session revokes the key: the table
// is written with no key, `remote` ends the open connection with the code
// Revoked, and refuses the key in the next handshake.
disk_processes_client_key_steps :: proc(steps: ^[dynamic]Step) {
	append(steps, Step{kind = .Launch, text = "monitor"})
	append(steps, Step{kind = .Wait, text = "compositor: surface monitor"})
	append(steps, Step{kind = .Launch, text = "remote"})
	// The service prints its key while the root service starts it: the key
	// can come before the line of the start.
	append(steps, Step{kind = .Wait, text = "root: started remote", any_order = true})
	append(steps, Step{kind = .Remote_Key, text = "remote: the public key of this service: "})
	append(steps, Step{kind = .Wait, text = "remote: listening on the UDP port 7100, for the host 10.0.2.2 only, and for the client keys that a principal allowed", any_order = true})
	append(steps, Step{kind = .Call, text = "monitor.served()", expected = "Served{calls = "})
	append(steps, Step{kind = .Wait, text = ": its calls act for principal 1", any_order = true})
	append(steps, Step{kind = .Wait, text = "root: connected remote to the service monitor, acting for principal 1, for the client key ", any_order = true})
	append(steps, Step{kind = .Front, text = "console"})
	append(steps, Step{kind = .Type, text = "remote_disallow(\"{client key}\")"})
	append(steps, Step{kind = .Wait, text = "root: principal 1 revoked the client key ", any_order = true})
	append(steps, Step{kind = .Wait, text = "root: the disk grant table of principal 1 is written in the store module_files: 1 rows, with the tag of the key of the principal; 0 client keys of remote", any_order = true})
	append(steps, Step{kind = .Wait, text = " of principal 1 ended (a revocation, or a lock of its session): the connection from 10.0.2.2 port "})
	append(steps, Step{kind = .Remote_Case, text = "revoked"})
	append(steps, Step{kind = .Wait, text = ": no principal allowed it; the handshake ends before any call"})
}

// disk_processes_principal_store_steps adds the steps of one start of the
// nickname visitor of alice with no hash and the grant store: the root
// service takes the hash of the row of the table of alice, and the process
// finds its count of visits in the store of its nickname for alice. The
// process stops at the end, and the console of the session is in front.
disk_processes_principal_store_steps :: proc(steps: ^[dynamic]Step, hash: string, visit: int) {
	append(steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"\")", DISK_MODULE_NAME)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with the grant store: the store disk-%s.principal.1, in the session of principal 1 \"alice\"", DISK_MODULE_NAME, hash, DISK_MODULE_NAME), any_order = true})
	append(steps, Step{kind = .Wait, text = "visitor: the context holds the log, a window, the budget and a store, and no other handle of a grant: as it must"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("visitor: the store of its nickname holds the visit %d, read again: as it must", visit)})
	append(steps, Step{kind = .Front, text = "console"})
	append(steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", DISK_MODULE_NAME)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", DISK_MODULE_NAME)})
}

// The line of the source of the module visitor where its entry calls
// sleep_for_ever: the place of the frame of the entry while the thread
// sleeps. A change of that file above the call changes it.
VISITOR_LINE_OF_THE_SLEEP :: "93"

// The line of the source of the module visitor where fault_three writes
// to the address 0: the place of the frame 0 of the stop report of the
// copy that faults. A change of that file above the write changes it.
VISITOR_LINE_OF_THE_FAULT :: "169"

// disk_processes_stop_report_steps adds the steps of the stop report of a
// disk process. The copy of the outside module that faults writes to the
// address 0 three calls deep, and stops. The root service holds its only
// handle and reaps it at once, so the kernel forgets its stop report: the
// root service keeps a copy. Then `stop_report` in the console, with no
// attach: the debugger service receives the kept report with a connection
// that reads only to the store, reads the debug object of the module, and
// names the frame 0 by its procedure, its file by the name of the folder of
// the copy, and its line.
//
// The row is drawn through `columns`, so that the widths of its columns
// depend only on values that the scenario knows. A column of an integer is
// as wide as its header or its value, with the value at its right.
disk_processes_stop_report_steps :: proc(steps: ^[dynamic]Step, fault_hash: string) {
	append(steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", OUTSIDE_FAULT_MODULE, fault_hash)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with no grant", OUTSIDE_FAULT_MODULE, fault_hash), any_order = true})
	append(steps, Step{kind = .Wait, text = "visitor: writes to the address 0, three calls deep: its stop report names the frames of its source", fails_on = "visitor: the write did not stop the process: WRONG"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: kept the stop report of %s, a disk process of principal 0: stop_report(\"%s\") names its frames", OUTSIDE_FAULT_MODULE, OUTSIDE_FAULT_MODULE)})
	append(steps, Step{kind = .Type, text = fmt.aprintf("columns(where(stop_report(\"%s\"), \"procedure\", \"visitor::fault_three\"), \"module procedure file line\")", OUTSIDE_FAULT_MODULE)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: gave debugger the kept stop report of %s and a connection that reads only to the store %s of principal 0, for console", OUTSIDE_FAULT_MODULE, disk_process.STORE_NAME)})
	// The object of the store has the hash of the module that faulted as
	// its name.
	append(steps, Step{kind = .Wait, text = fmt.aprintf("debugger: read the debug object %s of %s from the store %s of principal 0: ", fault_hash, OUTSIDE_FAULT_MODULE, disk_process.STORE_NAME)})
	// The root service ends the connection at the end that the debugger
	// sends after the read: it writes its line before or after the
	// console draws the row.
	append(steps, Step{kind = .Wait, text = "root: disconnected module_files from the service storage", any_order = true})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("debugger: the stop report of %s: ", OUTSIDE_FAULT_MODULE)})
	line_padding := strings.repeat(" ", max(0, len("line") - len(VISITOR_LINE_OF_THE_FAULT)), context.temp_allocator)
	append(steps, Step{kind = .Wait, text = fmt.aprintf("[console] %s  visitor::fault_three  %s/main.odin  %s%s", OUTSIDE_FAULT_MODULE, OUTSIDE_DISK_MODULE, line_padding, VISITOR_LINE_OF_THE_FAULT)})
}

// disk_processes_debugger_steps adds the steps of the debugger on the
// outside module that runs from the disk. The debugger service reads the
// debug object of the module from the store module_files, through a
// connection that reads only and that the root service gives with the
// debug access, and which the root service ends after the read; then a
// frame of the held thread has the procedure, the file and the line of the
// source of the outside module, by the name of its folder.
//
// Each row is drawn through `columns`, so that the widths of its columns
// depend only on values that the scenario knows.
disk_processes_debugger_steps :: proc(steps: ^[dynamic]Step, outsider_hash: string) {
	append(steps, Step{kind = .Type, text = fmt.aprintf("columns(debug(\"%s\"), \"process described\")", OUTSIDE_DISK_MODULE)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: gave debugger a connection that reads only to the store %s of principal 0, for the debug object of %s", disk_process.STORE_NAME, OUTSIDE_DISK_MODULE)})
	// The object of the store has the hash of the module as its name.
	append(steps, Step{kind = .Wait, text = fmt.aprintf("debugger: read the debug object %s of %s from the store %s of principal 0: ", outsider_hash, OUTSIDE_DISK_MODULE, disk_process.STORE_NAME)})
	// The connection lives for the read only: the root service ends it
	// when the debugger read the object. The root service writes its line
	// before or after the console draws the row: the system fixes no order.
	append(steps, Step{kind = .Wait, text = "root: disconnected module_files from the service storage", any_order = true})
	// The one module of the process has a debug object: the one of the store.
	append(steps, Step{kind = .Wait, text = fmt.aprintf("[console] %s          1", OUTSIDE_DISK_MODULE)})
	append(steps, Step{kind = .Type, text = "columns(hold(0), \"thread state\")"})
	append(steps, Step{kind = .Wait, text = "[console]      0  held"})
	// The thread sleeps in a call of the system, whose stub keeps no frame
	// of its own: the walk of the frame pointers reaches the entry of the
	// process, at the line where it calls sleep_for_ever. That frame names
	// the procedure, the source of the copy by the name of its folder, and
	// the line: what only the debug object from the store gives.
	append(steps, Step{kind = .Type, text = "columns(where(stack(0), \"procedure\", \"entry\"), \"module procedure file line\")"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("[console] %s  entry      %s/main.odin    %s", OUTSIDE_DISK_MODULE, OUTSIDE_DISK_MODULE, VISITOR_LINE_OF_THE_SLEEP)})
	// The detach gives the thread back and ends the debug access.
	append(steps, Step{kind = .Type, text = "detach()"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: debugger ended the debugging of %s for console", OUTSIDE_DISK_MODULE)})
}

// The nickname under which the module file service stores the file that
// comes over the network: a name that the disk of the tool does not hold.
RECEIVED_NICKNAME :: "received"

// disk_processes_network_steps adds the steps of the module file service:
// the module file comes from the listener of the tool through the network
// of the machine, under a new nickname, with no new disk. The service
// gives the hash of the bytes that came; the list reads the bytes of each
// file again; the root service checks the bytes at the start.
disk_processes_network_steps :: proc(steps: ^[dynamic]Step, hash: string, changed_hash: string, module_size: int, changed_size: int) {
	append(steps, Step{kind = .Type, text = "connect(\"module_files\")"})
	// The service writes its first line when it runs, and the root service
	// writes its line when the connection is made: the system fixes no
	// order.
	append(steps, Step{kind = .Wait, text = "module_files: serves the store module_files of principal 0: a file from the web server 10.0.2.100 port 80, and the list of the files with the hash of their bytes", any_order = true})
	append(steps, Step{kind = .Wait, text = "root: connected console to the service module_files"})
	append(steps, Step{kind = .Type, text = fmt.aprintf("module_files.receive(\"%s\", \"/%s\")", RECEIVED_NICKNAME, DISK_MODULE_NAME)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("module_files: stored %s from /%s: %d bytes, the BLAKE3 hash of its bytes %s", RECEIVED_NICKNAME, DISK_MODULE_NAME, module_size, hash)})
	// The disk grant table is an object of the same store: the service
	// writes no file over it.
	append(steps, Step{kind = .Type, text = fmt.aprintf("module_files.receive(\"%s\", \"/%s\")", disk_process.TABLE_OBJECT_NAME, DISK_MODULE_NAME)})
	append(steps, Step{kind = .Wait, text = "[console] error: module_files.receive: "})
	// The list, in the order of the names: grant_table has no row.
	append(steps, Step{kind = .Type, text = "module_files.list()"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("module_files: the file changed, %d bytes, the BLAKE3 hash of its bytes %s", changed_size, changed_hash)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("module_files: the file %s, %d bytes, the BLAKE3 hash of its bytes %s", RECEIVED_NICKNAME, module_size, hash)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("module_files: the file %s, %d bytes, the BLAKE3 hash of its bytes %s", DISK_MODULE_NAME, module_size, hash)})
	append(steps, Step{kind = .Wait, text = "module_files: listed 8 module files of the store module_files, each hash computed on its bytes"})
	// The file that came over the network starts by its hash, with no
	// grant: its nickname has no row.
	append(steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", RECEIVED_NICKNAME, hash)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with no grant", RECEIVED_NICKNAME, hash), any_order = true})
	append(steps, Step{kind = .Wait, text = "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must"})
	append(steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", RECEIVED_NICKNAME)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", RECEIVED_NICKNAME)})
}

// The hashes of the files of the import scan, as 64 hexadecimal digits.
Store_Import_Hashes :: struct {
	importer:        string, // The process store_importer.
	library:         string, // The module store_library: the hash that the import of store_importer names.
	changed_library: string, // That module with one byte changed.
}

// hash_digits_of gives the BLAKE3 hash of bytes as 64 hexadecimal digits,
// in memory that the caller deletes: a text of a step outlives the
// temporary memory of the step.
hash_digits_of :: proc(bytes: []u8) -> string {
	digits: [disk_process.HASH_DIGITS]u8
	disk_process.hash_write(&digits, blake3.hash(bytes))
	return fmt.aprintf("%s", string(digits[:]))
}

// disk_processes_import_steps adds the steps of the import scan. The
// process store_importer imports store_library, and the boot image holds
// neither: the root service finds the library in the store by the hash of
// its bytes, and the process calls it. Then the module file service writes
// the library with one byte changed over its entry: no file of the store
// has the hash of the import any more, and the start is refused with one
// line. The scan reads each of the 7 files of the store but the importer
// and the disk grant table: changed, notes, outsider, outsider_fault,
// received, store_library and visitor.
disk_processes_import_steps :: proc(steps: ^[dynamic]Step, hashes: Store_Import_Hashes, changed_library_size: int) {
	append(steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", STORE_IMPORTER_MODULE, hashes.importer)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: %s imports 1 modules that the boot image does not hold: the import scan reads the store module_files to find them by the hash of their bytes", STORE_IMPORTER_MODULE)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: %s: the import %s of %s is the file %s of the store module_files, checked on its bytes", STORE_IMPORTER_MODULE, hashes.library, STORE_IMPORTER_MODULE, STORE_LIBRARY_MODULE)})
	// The process writes its line when it runs, and the root service
	// writes its line when the start returned: the system fixes no order.
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with no grant", STORE_IMPORTER_MODULE, hashes.importer), any_order = true})
	append(steps, Step{kind = .Wait, text = "store_importer: triple(14) of the module store_library of the store module_files gives 42: as it must"})
	disk_processes_nickname_steps(steps, hashes.importer)
	append(steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", STORE_IMPORTER_MODULE)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", STORE_IMPORTER_MODULE)})
	// The entry of the library now holds other bytes under the same name:
	// the name gives nothing, and the start is refused.
	append(steps, Step{kind = .Type, text = fmt.aprintf("module_files.receive(\"%s\", \"%s\")", STORE_LIBRARY_MODULE, STORE_LIBRARY_CHANGED_PATH)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("module_files: stored %s from %s: %d bytes, the BLAKE3 hash of its bytes %s", STORE_LIBRARY_MODULE, STORE_LIBRARY_CHANGED_PATH, changed_library_size, hashes.changed_library)})
	append(steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", STORE_IMPORTER_MODULE, hashes.importer)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: refused %s from the disk: %s imports %s, and no file of the boot image or of the store module_files has bytes with this hash; the import scan read 7 files", STORE_IMPORTER_MODULE, STORE_IMPORTER_MODULE, hashes.library), fails_on = "root: started store_importer from the disk"})
}

// disk_processes_nickname_steps adds the steps of the nickname of a disk
// process in the windows. store_importer asks for the title console; the
// compositor names its window store_importer, the nickname that the root
// service gave in Client_Add. The monitor shows the nickname with the hash
// prefix of the file from the disk process page, and the menu of the
// windows shows it faded beside the nickname. The picture holds the menu
// open over the monitor. The console is in front at the end.
disk_processes_nickname_steps :: proc(steps: ^[dynamic]Step, importer_hash: string) {
	prefix := importer_hash[:disk_process_page.HASH_PREFIX_DIGITS]
	append(steps, Step{kind = .Wait, text = fmt.aprintf("compositor: surface %s ", STORE_IMPORTER_MODULE)})
	append(steps, Step{kind = .Launch, text = "monitor"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("monitor: the disk process %s, hash prefix %s, the file %s, from the root service", STORE_IMPORTER_MODULE, prefix, importer_hash)})
	append(steps, Step{kind = .Click, text = BAR_WINDOWS_BUTTON})
	append(steps, Step{kind = .Wait, text = "compositor: windows: "})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("compositor: the menu of the windows shows the disk process %s with the hash prefix %s, from the root service", STORE_IMPORTER_MODULE, prefix)})
	append(steps, Step{kind = .Shot, text = "disk_process_windows"})
	append(steps, Step{kind = .Click, text = BAR_WINDOWS_BUTTON})
	append(steps, Step{kind = .Front, text = "console"})
	// The export of the monitor gives what its window shows: the nickname
	// and the whole hash of the file. The short name processes() calls
	// monitor.processes() and connects to the monitor itself. The name
	// column is as wide as the nickname, and the hash as wide as its
	// header, so the line has no padding.
	append(steps, Step{kind = .Type, text = fmt.aprintf("columns(where(processes(), \"name\", \"%s\"), \"name hash\")", STORE_IMPORTER_MODULE)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("[console] %s  %s", STORE_IMPORTER_MODULE, importer_hash)})
}

// The machine passphrase of the test. It is a constant of the tool: a test
// passphrase guards nothing.
MACHINE_PASSPHRASE :: "a machine of the test"

// disk_processes_store_steps adds the steps of one start of the nickname
// visitor with no hash and the grant store: the root service takes the
// hash of the row, and the process finds its count of visits in the store
// of its nickname. The process stops at the end.
disk_processes_store_steps :: proc(steps: ^[dynamic]Step, hash: string, visit: int) {
	append(steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"\")", DISK_MODULE_NAME)})
	// The process writes its first line when it runs, and the root service
	// writes its line when the start returned: the system fixes no order.
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s, with the grant store: the store disk-%s", DISK_MODULE_NAME, hash, DISK_MODULE_NAME), any_order = true})
	append(steps, Step{kind = .Wait, text = "visitor: the context holds the log, a window, the budget and a store, and no other handle of a grant: as it must"})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("visitor: the store of its nickname holds the visit %d, read again: as it must", visit)})
	append(steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", DISK_MODULE_NAME)})
	append(steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", DISK_MODULE_NAME)})
}
