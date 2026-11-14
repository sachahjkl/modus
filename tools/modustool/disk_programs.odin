package modustool

// The disk of the disk programs: a data disk in the format of the storage
// service, which holds the store `programs` with module files, written by
// the tool with no machine
// (docs/TOOLS.md, "The disk of the disk programs").
// The root service starts a program from it when a principal names the
// program and the hash of its file
// (docs/MODULE_CONTRACT.md, "A program from a disk").
//
// The writer makes one commit of a new disk: the blocks of data and the
// object nodes of each file, one leaf with the entries, the store block,
// then the root. It is not the engine of the storage service: it writes a
// whole disk one time, and changes none. A host test opens its image with
// the code of the open of the service (src/library/support/storage_mount),
// and compares each object and each hash (disk_programs_test.odin).

import "core:fmt"
import "core:os"
import "core:slice"
import "modus:contract/blake3"
import format "modus:contract/store"
import "modus:support/disk_program"
import block_tree "modus:support/storage_object"

// The module that the tool writes on the disk of the test: a row of the
// module table that is not in the boot image.
DISK_PROGRAM_MODULE :: "visitor"

TEST_DISK_PROGRAMS_DISK :: BUILD_FOLDER + "/test_disk_programs_disk.img"
TEST_OUTPUT_DISK_PROGRAMS :: BUILD_FOLDER + "/test_output_disk_programs.txt"

// The generation of the root that the writer makes. The first root of a
// format has the generation 1 and names no store: the open takes a disk
// with only that root for a disk to format.
PROGRAM_DISK_GENERATION :: 2

// One module file of the store `programs`: the name of its entry, and its
// bytes.
Program_File :: struct {
	name:  string,
	bytes: []u8,
}

// The disk that the writer fills: the image, and the next free block.
// Blocks 0 and 1 are the two places of the root.
Program_Disk :: struct {
	image: []u8,
	next:  u64,
	full:  bool, // A block did not fit: the image is not a disk.
}

// program_disk_put writes one block in the next free block, and gives its
// number.
program_disk_put :: proc(disk: ^Program_Disk, bytes: []u8) -> u64 {
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
Program_Object :: struct {
	bytes:  []u8,
	blocks: u64, // The blocks of the object, holes included.
	values: []format.Block_Value,
}

// program_object_block gives the block `index` of an object, with zero
// bytes after its last byte.
program_object_block :: proc(object: ^Program_Object, index: u64) -> (block: block_tree.Block) {
	start := index * format.BLOCK_SIZE
	if start < u64(len(object.bytes)) {
		copy(block[:], object.bytes[start:])
	}
	return block
}

// program_object_child writes the part of an object under one child of a
// node: a block of data for the level 0, else an object node and what is
// under it. A part whose bytes are all zero is a hole: nothing is written,
// and the child is zero. base is the first block of the part.
program_object_child :: proc(disk: ^Program_Disk, object: ^Program_Object, level: int, base: u64) -> (child: format.Object_Child) {
	if base >= object.blocks {
		return {}
	}
	if level == 0 {
		block := program_object_block(object, base)
		if block_tree.is_zero(block[:]) {
			return {}
		}
		value := block_tree.block_value(&block, base)
		object.values[base] = value
		number := program_disk_put(disk, block[:])
		return {block = number, check = format.value_check(value), blocks = 1, value = value}
	}
	node: format.Object_Node
	held: u64
	count: u32
	for &item, index in node.children {
		item = program_object_child(disk, object, level - 1, base + u64(index) * format.object_span(level - 1))
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
	number := program_disk_put(disk, bytes)
	return {block = number, check = format.check(bytes), blocks = held + 1, value = block_tree.node_value(&node)}
}

// The two procedures that the hash of an object asks for: the value of a
// whole part before the last block, from the values of its blocks, and the
// bytes of the last block.
program_object_range_value :: proc "contextless" (source: ^block_tree.Hash_Source, first: u64, count: u64) -> (value: format.Block_Value, outcome: block_tree.Read) {
	object := (^Program_Object)(source.data)
	if count == 0 || count > format.OBJECT_FANOUT * format.OBJECT_FANOUT * format.OBJECT_FANOUT || first + count > u64(len(object.values)) {
		return {}, .Wrong
	}
	// A whole part is a power of two of blocks: its value is the value of
	// its two halves.
	if count == 1 {
		return object.values[first], .Good
	}
	left, left_outcome := program_object_range_value(source, first, count / 2)
	right, right_outcome := program_object_range_value(source, first + count / 2, count / 2)
	if left_outcome != .Good || right_outcome != .Good {
		return {}, .Wrong
	}
	return block_tree.pair_value(left, right), .Good
}

program_object_last_block :: proc "contextless" (source: ^block_tree.Hash_Source, index: u64, into: ^block_tree.Block) -> block_tree.Read {
	object := (^Program_Object)(source.data)
	into^ = {}
	start := index * format.BLOCK_SIZE
	if start < u64(len(object.bytes)) {
		copy(into[:], object.bytes[start:])
	}
	return .Good
}

// program_object_write writes the block tree of one object, and gives its
// entry: its size, the root of its block tree, the blocks that it holds,
// and the hash of the object (docs/STORAGE.md, "The hash of an object").
program_object_write :: proc(disk: ^Program_Disk, bytes: []u8) -> (entry: format.Entry, held: u64, ok: bool) {
	size := u64(len(bytes))
	object := Program_Object {
		bytes  = bytes,
		blocks = format.object_blocks(size),
	}
	object.values = make([]format.Block_Value, object.blocks, context.temp_allocator)
	root := program_object_child(disk, &object, format.object_levels(size), 0)
	source := block_tree.Hash_Source {
		range_value = program_object_range_value,
		last_block  = program_object_last_block,
		data        = &object,
	}
	hash, outcome, _ := block_tree.object_hash(size, &source)
	if outcome != .Good || disk.full {
		return {}, 0, false
	}
	entry = {
		kind       = .Object,
		size       = size,
		generation = PROGRAM_DISK_GENERATION,
		hash       = hash,
		pointer    = {block = root.block, check = root.check},
	}
	return entry, root.blocks, true
}

// program_disk_encode gives the bytes of a data disk of disk_size bytes
// that holds the store `programs` with these files, as one commit. The
// entries are in the order of their names, in one leaf: the writer takes at
// most the entries of one leaf. It refuses a name that the root service
// would refuse as the name of an entry, a file with no byte, and a file
// over the limit of a disk program.
program_disk_encode :: proc(files: []Program_File, disk_size: int, allocator := context.allocator) -> (image: []u8, ok: bool) {
	if len(files) == 0 || len(files) > format.LEAF_CAPACITY {
		fmt.eprintfln("modustool: the store %s of the tool holds 1 to %d files, and %d are given", disk_program.STORE_NAME, format.LEAF_CAPACITY, len(files))
		return nil, false
	}
	sorted := slice.clone(files, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Program_File) -> bool {
		return a.name < b.name
	})
	for file, index in sorted {
		if problem, _ := disk_program.name_problem(file.name); problem != .None {
			fmt.eprintfln("modustool: %q is no name of a disk program: %v", file.name, problem)
			return nil, false
		}
		if index > 0 && sorted[index - 1].name == file.name {
			fmt.eprintfln("modustool: two files of the store %s have the name %s", disk_program.STORE_NAME, file.name)
			return nil, false
		}
		if len(file.bytes) == 0 || len(file.bytes) > disk_program.FILE_BYTES_LIMIT {
			fmt.eprintfln("modustool: the file %s has %d bytes; a module file of a disk program has 1 to %d", file.name, len(file.bytes), disk_program.FILE_BYTES_LIMIT)
			return nil, false
		}
	}
	disk := Program_Disk {
		image = make([]u8, disk_size, allocator),
		next  = 2,
	}
	defer if !ok {
		delete(disk.image, allocator)
	}
	leaf: [format.BLOCK_SIZE]u8
	header := (^format.Tree_Header)(&leaf)
	header.magic = format.NODE_MAGIC
	header.count = u32(len(sorted))
	record_size := size_of(format.Entry_Name) + size_of(format.Entry)
	store_block: format.Store_Block
	for file, index in sorted {
		entry, held, written := program_object_write(&disk, file.bytes)
		if !written {
			fmt.eprintfln("modustool: the file %s does not fit in a disk of %d bytes", file.name, disk_size)
			return nil, false
		}
		record := leaf[format.TREE_HEADER_SIZE + index * record_size:][:record_size]
		copy(record[:size_of(format.Entry_Name)], file.name)
		copy(record[size_of(format.Entry_Name):], ([^]u8)(&entry)[:size_of(format.Entry)])
		store_block.objects += 1
		store_block.current_blocks += held
	}
	leaf_number := program_disk_put(&disk, leaf[:])
	store_block.tree = {block = leaf_number, check = format.check(leaf[:])}
	store_block.node_blocks = 1
	store_bytes := ([^]u8)(&store_block)[:format.BLOCK_SIZE]
	store_number := program_disk_put(&disk, store_bytes)
	if disk.full {
		fmt.eprintfln("modustool: the store %s does not fit in a disk of %d bytes", disk_program.STORE_NAME, disk_size)
		return nil, false
	}
	root := new(format.Root, context.temp_allocator)
	root.magic = format.ROOT_MAGIC
	root.generation = PROGRAM_DISK_GENERATION
	root.disk_blocks = u64(disk_size) / format.BLOCK_SIZE
	copy(root.stores[0].name[:format.NAME_CAPACITY - 1], disk_program.STORE_NAME)
	root.stores[0].limit = disk_program.STORE_BLOCKS_LIMIT
	// Its store block, its leaf, and the blocks of its objects.
	root.stores[0].used = 2 + store_block.current_blocks
	root.stores[0].store = {block = store_number, check = format.check(store_bytes)}
	root.check = format.root_check(root)
	copy(disk.image[:format.BLOCK_SIZE], ([^]u8)(root)[:format.BLOCK_SIZE])
	return disk.image, true
}

// program_disk_write writes the disk of the store `programs` to a file,
// and prints the hash of each module file: the hash that the principal
// names in start_from_disk.
program_disk_write :: proc(path: string, files: []Program_File) -> bool {
	image := program_disk_encode(files, DATA_DISK_SIZE) or_return
	defer delete(image)
	if err := os.write_entire_file(path, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	for file in files {
		hash := blake3.hash(file.bytes)
		digits: [disk_program.HASH_DIGITS]u8
		disk_program.hash_write(&digits, hash)
		fmt.printfln("modustool: %s: the store %s holds %s, %d bytes, hash %s", path, disk_program.STORE_NAME, file.name, len(file.bytes), string(digits[:]))
	}
	return true
}

// The machine of the disk programs: its data disk holds the store
// `programs` with three entries that hold the module `visitor`, which is
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
// The storage service runs before the first line that reads the store, so
// no step depends on the time of the open of the disk.
disk_programs_tests_run :: proc() -> bool {
	module_file := read_file(module_path(DISK_PROGRAM_MODULE)) or_return
	changed_file := slice.clone(module_file, context.temp_allocator)
	changed_file[len(changed_file) - 1] ~= 0x01
	files := [?]Program_File{{DISK_PROGRAM_MODULE, module_file}, {"changed", changed_file}, {"notes", module_file}}
	program_disk_write(TEST_DISK_PROGRAMS_DISK, files[:]) or_return
	hash_digits, changed_digits: [disk_program.HASH_DIGITS]u8
	disk_program.hash_write(&hash_digits, blake3.hash(module_file))
	disk_program.hash_write(&changed_digits, blake3.hash(changed_file))
	// The machine test frees the temporary memory after each step: the
	// texts of the steps stay.
	hash := fmt.aprintf("%s", string(hash_digits[:]))
	changed_hash := fmt.aprintf("%s", string(changed_digits[:]))
	defer delete(hash)
	defer delete(changed_hash)
	steps := make([dynamic]Step)
	defer delete(steps)
	// The storage service takes the disk of the tool before or after the
	// console has its window: the system fixes no order, so neither wait
	// moves the place of the log.
	append(&steps, Step{kind = .Wait, text = "storage: ok, generation 2: 1 stores, 3 objects", any_order = true})
	append(&steps, Step{kind = .Wait, text = "compositor: surface console", any_order = true})
	append(&steps, Step{kind = .Front, text = "console"})
	append(&steps, Step{kind = .Type, text = "connect(\"storage\")"})
	append(&steps, Step{kind = .Wait, text = "[console]   module     storage"})
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"%s\", \"%s\")", DISK_PROGRAM_MODULE, hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: reads %s from the store programs of the storage service, for principal 0", DISK_PROGRAM_MODULE)})
	// The program writes its first line when it runs, and the root service
	// writes its line when the start returned: the system fixes no order.
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: started %s from the disk, hash %s", DISK_PROGRAM_MODULE, hash), any_order = true})
	append(&steps, Step{kind = .Wait, text = "visitor: ok, a program that the boot image does not hold"})
	append(&steps, Step{kind = .Wait, text = "visitor: the context holds the log, a window and the budget, and no handle of a grant: as it must"})
	append(&steps, Step{kind = .Wait, text = "visitor: no ring to the root service: the open of its handle is refused: as it must"})
	// The bytes of the entry are not the bytes of the hash of the line.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"changed\", \"%s\")", hash)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: refused changed from the disk: its bytes have the hash %s", changed_hash)})
	// A name of the grant table: refused before any read.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"notes\", \"%s\")", hash)})
	append(&steps, Step{kind = .Wait, text = "root: refused notes from the disk: the grant table of the root service names it, and a disk program takes no grant by its name"})
	// A name with no entry.
	append(&steps, Step{kind = .Type, text = fmt.aprintf("start_from_disk(\"nobody\", \"%s\")", hash)})
	append(&steps, Step{kind = .Wait, text = "root: refused nobody from the disk: the store programs has no object with this name"})
	append(&steps, Step{kind = .Type, text = fmt.aprintf("stop(\"%s\")", DISK_PROGRAM_MODULE)})
	append(&steps, Step{kind = .Wait, text = fmt.aprintf("root: %s stopped with code ", DISK_PROGRAM_MODULE)})
	append(&steps, Step{kind = .Type, text = "shutdown()"})
	append(&steps, Step{kind = .Wait, text = "kernel: the machine stops with code 0"})
	return machine_test(steps[:], BOOT_VOLUME, TEST_OUTPUT_DISK_PROGRAMS, MACHINE_STOP_OK, TEST_DISK_PROGRAMS_DISK)
}
