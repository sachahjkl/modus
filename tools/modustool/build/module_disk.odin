// The writer of a data disk that holds module files: the store module_files
// of the storage service, which `module-disk` writes for a module built
// outside the repository and which the machine test of the disk processes
// boots (docs/TOOLS.md, "The disk of the disk processes").
package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "modus:contract/blake3"
import debug_object "modus:contract/debug_object"
import format "modus:contract/store"
import "modus:disk_process"
import block_tree "internal:storage/storage_object"

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
