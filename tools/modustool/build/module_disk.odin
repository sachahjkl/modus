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
import tree "internal:storage/storage_tree"

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
// a file with no byte, a file over the limit of a disk process, and no
// file. It gives the files in the order of their names, in temporary
// memory.
module_files_check :: proc(store_name: string, files: []Module_File) -> (sorted: []Module_File, ok: bool) {
	if len(files) == 0 {
		fmt.eprintfln("modustool: the store %s of the tool holds at least 1 file, and none is given", store_name)
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

// The writer of the nodes of the tree of a store: each node to the next
// free block of the disk.
@(private = "file")
Node_Writer :: struct {
	using writer: tree.Writer,
	disk:         ^Module_Disk,
	nodes:        u64,
}

@(private = "file")
node_writer_write :: proc "contextless" (writer: ^tree.Writer, bytes: ^tree.Block) -> format.Pointer {
	nodes := (^Node_Writer)(writer)
	context = {}
	number := module_disk_put(nodes.disk, bytes[:])
	if number == 0 {
		return {}
	}
	nodes.nodes += 1
	return {block = number, check = format.check(bytes[:])}
}

// The source of the nodes: the writer builds the whole tree in the slots of
// one pool, so it never reads a node of the disk.
@(private = "file")
node_source_read :: proc "contextless" (_: ^tree.Source, _: format.Pointer, _: ^tree.Block) -> tree.Read {
	return .Wrong
}

// module_files_store_put writes the objects of one store, the B+ tree of
// its entries (the code of the storage service: src/library/internal/storage/storage_tree)
// and its store block, and gives the cell of the store in the store table.
// sorted are the files that module_files_check gave.
module_files_store_put :: proc(disk: ^Module_Disk, store_name: string, sorted: []Module_File, disk_size: int, limit: u64 = disk_process.STORE_BLOCKS_LIMIT) -> (cell: format.Store_Entry, ok: bool) {
	pool := new(tree.Pool)
	defer free(pool)
	tree.pool_reset(pool)
	source := tree.Source{read = node_source_read}
	work := tree.Work{pool = pool, source = &source, shape = tree.TREE_SHAPE}
	store_block: format.Store_Block
	for file in sorted {
		entry, held, written := module_object_write(disk, file.bytes)
		if !written {
			fmt.eprintfln("modustool: the file %s does not fit in a disk of %d bytes", file.name, disk_size)
			return {}, false
		}
		key := format.entry_name(file.name)
		tree.put(&work, key[:], ([^]u8)(&entry)[:size_of(format.Entry)], false)
		store_block.objects += 1
		store_block.current_blocks += held
	}
	nodes := Node_Writer{writer = {write = node_writer_write}, disk = disk}
	store_block.tree = tree.finish(&work, &nodes.writer)
	if pool.failure != .None {
		fmt.eprintfln("modustool: the tree of the store %s does not fit in a disk of %d bytes, or in one commit: %v", store_name, disk_size, pool.failure)
		return {}, false
	}
	store_block.node_blocks = nodes.nodes
	store_bytes := ([^]u8)(&store_block)[:format.BLOCK_SIZE]
	store_number := module_disk_put(disk, store_bytes)
	if disk.full {
		fmt.eprintfln("modustool: the store %s does not fit in a disk of %d bytes", store_name, disk_size)
		return {}, false
	}
	copy(cell.name[:format.NAME_CAPACITY - 1], store_name)
	cell.limit = limit
	// Its store block, the nodes of its tree, and the blocks of its objects.
	cell.used = 1 + nodes.nodes + store_block.current_blocks
	cell.store = {block = store_number, check = format.check(store_bytes)}
	return cell, true
}

// module_disk_root writes the page of the store table with these cells,
// and the root that names it in block 0. false: the page does not fit.
module_disk_root :: proc(disk: ^Module_Disk, cells: []format.Store_Entry, disk_size: int) -> bool {
	page := new(format.Store_Table_Page, context.temp_allocator)
	page.magic = format.STORE_TABLE_MAGIC
	copy(page.cells[:], cells)
	page_bytes := ([^]u8)(page)[:format.BLOCK_SIZE]
	page_number := module_disk_put(disk, page_bytes)
	if disk.full {
		fmt.eprintfln("modustool: the store table does not fit in a disk of %d bytes", disk_size)
		return false
	}
	root := new(format.Root, context.temp_allocator)
	root.magic = format.ROOT_MAGIC
	root.generation = MODULE_DISK_GENERATION
	root.disk_blocks = u64(disk_size) / format.BLOCK_SIZE
	root.store_page_count = 1
	root.store_pages[0] = {block = page_number, check = format.check(page_bytes)}
	root.check = format.root_check(root)
	copy(disk.image[:format.BLOCK_SIZE], ([^]u8)(root)[:format.BLOCK_SIZE])
	return true
}

// module_disk_encode gives the bytes of a data disk of disk_size bytes
// that holds the store `module_files` with these files, as one commit, and,
// when principal_files has files, the store `module_files` of the named
// principal 1 with them. The entries of a store are a B+ tree in the order
// of their names, as the storage service writes it. It refuses a name that the root service would refuse as the name of an
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
	cells: [2]format.Store_Entry
	cells[0] = module_files_store_put(&disk, disk_process.STORE_NAME, sorted, disk_size) or_return
	count := 1
	if len(principal_sorted) > 0 {
		cells[1] = module_files_store_put(&disk, PRINCIPAL_MODULE_FILES_STORE, principal_sorted, disk_size) or_return
		count = 2
	}
	module_disk_root(&disk, cells[:count], disk_size) or_return
	return disk.image, true
}

// One subtree of a data disk store: its name, its direct objects, and its
// nested subtrees.
Data_Disk_Tree :: struct {
	name:    string,
	objects: []Module_File,
	trees:   []Data_Disk_Tree,
}

// One private store of a data disk that is not module_files: its name, its
// limit of blocks, its root objects, and any nested subdirectories.
Data_Disk_Store :: struct {
	name:    string,
	limit:   u64,
	objects: []Module_File,
	trees:   []Data_Disk_Tree,
}

// data_disk_tree_put writes one directory level of a store (objects and nested
// Entry_Kind.Tree subdirectories) into its own B+ tree, updating store_block
// counts and accumulating node blocks into nodes.
@(private = "file")
data_disk_tree_put :: proc(
	disk: ^Module_Disk,
	store_name: string,
	objects: []Module_File,
	trees: []Data_Disk_Tree,
	depth: int,
	disk_size: int,
	store_block: ^format.Store_Block,
	nodes: ^Node_Writer,
) -> (root: format.Pointer, direct_count: u64, ok: bool) {
	if depth > format.NESTING_LIMIT {
		fmt.eprintfln("modustool: the store %s nests directories deeper than %d", store_name, format.NESTING_LIMIT)
		return {}, 0, false
	}
	Entry_Ref :: struct {
		name:    string,
		is_tree: bool,
		index:   int,
	}
	total := len(objects) + len(trees)
	if total == 0 {
		return {}, 0, true
	}
	refs := make([]Entry_Ref, total, context.temp_allocator)
	at := 0
	for obj, index in objects {
		refs[at] = {name = obj.name, is_tree = false, index = index}
		at += 1
	}
	for sub, index in trees {
		refs[at] = {name = sub.name, is_tree = true, index = index}
		at += 1
	}
	slice.sort_by(refs, proc(a, b: Entry_Ref) -> bool {
		return a.name < b.name
	})
	for ref, index in refs {
		if refusal, _, _ := format.name_refusal(ref.name); refusal != .None || (index > 0 && refs[index - 1].name == ref.name) {
			fmt.eprintfln("modustool: the entry %q of the store %s has no valid entry name (%v) or duplicates another entry", ref.name, store_name, refusal)
			return {}, 0, false
		}
		if !ref.is_tree && len(objects[ref.index].bytes) == 0 {
			fmt.eprintfln("modustool: the object %q of the store %s has no byte", ref.name, store_name)
			return {}, 0, false
		}
	}

	pool := new(tree.Pool)
	defer free(pool)
	tree.pool_reset(pool)
	source := tree.Source{read = node_source_read}
	work := tree.Work{pool = pool, source = &source, shape = tree.TREE_SHAPE}
	for ref in refs {
		entry: format.Entry
		if ref.is_tree {
			sub := trees[ref.index]
			sub_root, sub_count, sub_ok := data_disk_tree_put(disk, store_name, sub.objects, sub.trees, depth + 1, disk_size, store_block, nodes)
			if !sub_ok {
				return {}, 0, false
			}
			entry = {
				kind       = u64(format.Entry_Kind.Tree),
				size       = sub_count,
				generation = MODULE_DISK_GENERATION,
				pointer    = sub_root,
			}
			store_block.trees += 1
		} else {
			obj := objects[ref.index]
			held: u64
			written: bool
			entry, held, written = module_object_write(disk, obj.bytes)
			if !written {
				fmt.eprintfln("modustool: the object %s of the store %s does not fit in a disk of %d bytes", obj.name, store_name, disk_size)
				return {}, 0, false
			}
			store_block.objects += 1
			store_block.current_blocks += held
		}
		key := format.entry_name(ref.name)
		tree.put(&work, key[:], ([^]u8)(&entry)[:size_of(format.Entry)], false)
	}
	root = tree.finish(&work, &nodes.writer)
	if pool.failure != .None || disk.full {
		fmt.eprintfln("modustool: the tree of the store %s does not fit in a disk of %d bytes, or in one commit: %v", store_name, disk_size, pool.failure)
		return {}, 0, false
	}
	return root, u64(total), true
}

// data_disk_store_put writes one Data_Disk_Store (with optional nested trees)
// and its store block, returning its cell for the store table.
@(private = "file")
data_disk_store_put :: proc(disk: ^Module_Disk, store: Data_Disk_Store, disk_size: int) -> (cell: format.Store_Entry, ok: bool) {
	if len(store.name) == 0 || len(store.name) >= format.NAME_CAPACITY {
		fmt.eprintfln("modustool: the store name %q must have 1 to %d bytes", store.name, format.NAME_CAPACITY - 1)
		return {}, false
	}
	if len(store.objects) == 0 && len(store.trees) == 0 {
		fmt.eprintfln("modustool: the store %s of the tool holds at least 1 entry, and none is given", store.name)
		return {}, false
	}
	store_block: format.Store_Block
	nodes := Node_Writer{writer = {write = node_writer_write}, disk = disk}
	store_block.tree, _, ok = data_disk_tree_put(disk, store.name, store.objects, store.trees, 0, disk_size, &store_block, &nodes)
	if !ok {
		return {}, false
	}
	store_block.node_blocks = nodes.nodes
	store_bytes := ([^]u8)(&store_block)[:format.BLOCK_SIZE]
	store_number := module_disk_put(disk, store_bytes)
	if disk.full {
		fmt.eprintfln("modustool: the store %s does not fit in a disk of %d bytes", store.name, disk_size)
		return {}, false
	}
	copy(cell.name[:format.NAME_CAPACITY - 1], store.name)
	cell.limit = store.limit
	cell.used = 1 + nodes.nodes + store_block.current_blocks
	cell.store = {block = store_number, check = format.check(store_bytes)}
	return cell, true
}

// data_disk_encode_stores encodes one or more private stores (each with
// optional nested subdirectories) into a STORAGE7 data disk image as one
// commit. Refuses an empty store list, duplicate store names, invalid entry
// names, empty objects, or images that do not fit in disk_size bytes.
data_disk_encode_stores :: proc(stores: []Data_Disk_Store, disk_size: int, allocator := context.allocator) -> (image: []u8, ok: bool) {
	if len(stores) == 0 || len(stores) > format.STORES_OF_A_PAGE {
		fmt.eprintfln("modustool: data_disk_encode_stores takes 1 to %d stores, got %d", format.STORES_OF_A_PAGE, len(stores))
		return nil, false
	}
	for store, index in stores {
		for other in stores[index + 1:] {
			if store.name == other.name {
				fmt.eprintfln("modustool: two stores of the data disk share the name %q", store.name)
				return nil, false
			}
		}
	}
	disk := Module_Disk {
		image = make([]u8, disk_size, allocator),
		next  = 2,
	}
	defer if !ok {
		delete(disk.image, allocator)
	}
	cells := make([]format.Store_Entry, len(stores), context.temp_allocator)
	for store, index in stores {
		cells[index] = data_disk_store_put(&disk, store, disk_size) or_return
	}
	module_disk_root(&disk, cells, disk_size) or_return
	return disk.image, true
}

// data_disk_encode gives the bytes of a data disk of disk_size bytes that
// holds one store with these objects, as one commit: the private store of
// a process of the boot image, which the storage service gives it by its
// name. It refuses an empty store, two objects of one name, an object with
// no byte, and a store that does not fit.
data_disk_encode :: proc(store: Data_Disk_Store, disk_size: int, allocator := context.allocator) -> (image: []u8, ok: bool) {
	stores := [1]Data_Disk_Store{store}
	return data_disk_encode_stores(stores[:], disk_size, allocator)
}

// data_disk_write_stores writes a multi-store STORAGE7 data disk image to path.
data_disk_write_stores :: proc(path: string, stores: []Data_Disk_Store, disk_size: int = DATA_DISK_SIZE) -> bool {
	image := data_disk_encode_stores(stores, disk_size) or_return
	defer delete(image)
	if err := os.write_entire_file(path, image); err != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", path, err)
		return false
	}
	return true
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
