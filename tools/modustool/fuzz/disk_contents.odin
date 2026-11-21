// The reader of the contents of a disk in the format of the storage
// service: each store, each object and each version that its roots reach.
// The fuzz target of the storage format and the test of the power loss
// both compare disks with it.
package fuzz

import "base:runtime"
import "core:slice"
import "core:strings"
import format "modus:contract/store"
import "internal:storage/storage_mount"
import block_tree "internal:storage/storage_object"
import tree "internal:storage/storage_tree"

// The bytes of an object that the search keeps whole. A larger object is
// compared by the values of its blocks, and a version of it by its root:
// the open checked each block under the root.
CONTENTS_BYTES_LIMIT :: 1 << 20

// One block of data of an object, as an image gives it: its place, its
// check and its value (zero for the block of an object of one block).
Stored_Block :: struct {
	index: u64,
	check: u64,
	value: format.Block_Value,
}

// One version of an object, as an image gives it.
Stored_Version :: struct {
	generation: u64,
	size:       u64,
	root:       format.Pointer,
	bytes:      []u8, // Its bytes, when it has at most CONTENTS_BYTES_LIMIT.
	damaged:    bool,
}

// One entry of a store, as an image gives it: an object with its current
// version and its versions, the oldest first, or a tree. The name is the
// names of its path from the root of the store, joined with "/" for the
// tool only.
Stored_Object :: struct {
	store:    string,
	name:     string,
	tree:     bool,
	size:     u64,
	bytes:    []u8, // Its bytes, when it has at most CONTENTS_BYTES_LIMIT.
	blocks:   []Stored_Block, // Its blocks of data, in their order: a hole is no block.
	damaged:  bool,
	hash_wrong: bool, // The hash of its entry is not the hash that its block tree gives.
	root:     format.Pointer, // The root of its block tree: two names of one object have one root.
	versions: []Stored_Version,
	versions_damaged: bool,
}

// What one image of the disk gives when it is opened.
Disk_Contents :: struct {
	mount:   storage_mount.Mount,
	objects: [dynamic]Stored_Object,
}

// Image_Reader reads blocks of an image in memory for storage_mount.
Image_Reader :: struct {
	using reader: storage_mount.Block_Reader,
	image:        []u8,
	known:        ^Known_Checks,
}

// The checks and the values of the blocks of the durable image, kept for
// the search: an image of the search differs from it only in the blocks
// that a pending write touched, and those are computed each time.
Known_Checks :: struct {
	checks:  []u64, // 0: not computed yet.
	touched: []bool, // A pending write touched the block.
	values:  []format.Block_Value, // The value of a block of data at the place value_places gives.
	value_places: []u64, // 1 + the place of the block in its object; 0: not computed yet.
}

image_check :: proc "contextless" (reader: ^storage_mount.Block_Reader, number: u64, bytes: []u8) -> u64 {
	known := (^Image_Reader)(reader).known
	if known == nil || number >= u64(len(known.checks)) || known.touched[number] {
		return format.check(bytes)
	}
	if known.checks[number] == 0 {
		known.checks[number] = format.check(bytes)
	}
	return known.checks[number]
}

image_value :: proc "contextless" (reader: ^storage_mount.Block_Reader, number: u64, index: u64, bytes: ^block_tree.Block) -> format.Block_Value {
	known := (^Image_Reader)(reader).known
	if known == nil || number >= u64(len(known.checks)) || known.touched[number] {
		return block_tree.block_value(bytes, index)
	}
	if known.value_places[number] != index + 1 {
		known.values[number] = block_tree.block_value(bytes, index)
		known.value_places[number] = index + 1
	}
	return known.values[number]
}

image_read :: proc "contextless" (reader: ^storage_mount.Block_Reader, numbers: []u64, into: []u8) -> bool {
	from := (^Image_Reader)(reader)
	for number, index in numbers {
		offset := number * format.BLOCK_SIZE
		if offset >= u64(len(from.image)) || u64(len(from.image)) - offset < format.BLOCK_SIZE {
			return false
		}
		copy(into[index * format.BLOCK_SIZE:][:format.BLOCK_SIZE], from.image[offset:][:format.BLOCK_SIZE])
	}
	return true
}

// The walk of the trees of one store of an image. The walks of the trees
// and the state of the open keep its address: it lives in the heap, not on
// the stack.
Contents_Walk :: struct {
	state:     ^storage_mount.State,
	reader:    Image_Reader,
	source:    storage_mount.Reader_Source,
	objects_source: storage_mount.Object_Source,
	objects:   [dynamic]Stored_Object,
	store:     string,
	allocator: runtime.Allocator,
	saved:     runtime.Context,
	walks:     [format.NESTING_LIMIT + 1]tree.Walk,
	path:      [format.NESTING_LIMIT]string,
	nesting:   int,
	bytes:     []u8,
	collected: [dynamic]Stored_Block,
	block:     block_tree.Block,
	node:      format.Object_Node,
	nodes:     [format.OBJECT_LEVEL_LIMIT]format.Object_Node,
	hash_room: block_tree.State_Room,
	failed:    bool,
}

// disk_contents opens an image as the storage service does, and reads each
// entry of each tree of each store, checked. The strings and the bytes are
// in the allocator.
disk_contents :: proc(image: []u8, state: ^storage_mount.State, allocator := context.temp_allocator, known: ^Known_Checks = nil) -> (contents: Disk_Contents) {
	walking := new(Contents_Walk)
	defer free(walking)
	walking.reader = Image_Reader{reader = {read = image_read, check = image_check, value = image_value}, image = image, known = known}
	contents.mount = storage_mount.mount(state, &walking.reader, u64(len(image)) / format.BLOCK_SIZE)
	contents.objects = make([dynamic]Stored_Object, allocator)
	if contents.mount.failed || contents.mount.needs_format {
		return contents
	}
	walking.state = state
	walking.source = storage_mount.reader_source(&walking.reader, state.disk_size)
	walking.objects_source = storage_mount.object_source(&walking.reader, state.disk_size)
	walking.objects = contents.objects
	walking.allocator = allocator
	walking.saved = context
	walking.bytes = make([]u8, CONTENTS_BYTES_LIMIT, allocator)
	walking.collected = make([dynamic]Stored_Block, context.temp_allocator)
	for &store, store_index in state.root.stores {
		if store.name[0] == 0 || state.store_damaged[store_index] {
			continue
		}
		walking.store = strings.clone(string(cstring(&store.name[0])), allocator)
		contents_walk_tree(walking, state.store_blocks[store_index].tree, 0)
	}
	contents.objects = walking.objects
	if walking.failed {
		contents.mount.wrong += 1 // A tree that the open walked whole and this walk cannot: never with a disk that the open accepted.
	}
	return contents
}

contents_walk_tree :: proc(walking: ^Contents_Walk, root: format.Pointer, nesting: int) {
	if nesting > format.NESTING_LIMIT || root.block == 0 {
		return
	}
	one := &walking.walks[nesting]
	one.source = &walking.source.source
	one.shape = tree.TREE_SHAPE
	one.visit_node = nil
	one.visit_record = contents_visit
	one.data = walking
	before := walking.nesting
	walking.nesting = nesting
	if tree.walk_tree(one, root) != .None {
		walking.failed = true
	}
	walking.nesting = before
}

contents_collect :: proc "contextless" (data: rawptr, index: u64, pointer: format.Pointer, value: format.Block_Value) {
	walking := (^Contents_Walk)(data)
	context = walking.saved
	append(&walking.collected, Stored_Block{index = index, check = pointer.check, value = value})
}

// contents_state_bytes reads the bytes of one state of an object, when it has at
// most CONTENTS_BYTES_LIMIT: ok is false when a block is wrong.
contents_state_bytes :: proc(walking: ^Contents_Walk, state: block_tree.State) -> (bytes: []u8, ok: bool) {
	if state.size > CONTENTS_BYTES_LIMIT {
		return nil, true
	}
	count, outcome := block_tree.range_read(&walking.objects_source.source, state, 0, walking.bytes[:state.size], &walking.block, &walking.node)
	if outcome != .Good || count != state.size {
		return nil, false
	}
	return slice.clone(walking.bytes[:state.size], walking.allocator), true
}

contents_visit :: proc "contextless" (one: ^tree.Walk, key: []u8, value: []u8) {
	walking := (^Contents_Walk)(one.data)
	context = walking.saved
	name_key := (^format.Entry_Name)(raw_data(key))^
	entry := (^format.Entry)(raw_data(value))^
	name := strings.clone(format.name_of(&name_key), walking.allocator)
	nesting := walking.nesting
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, ..walking.path[:nesting])
	append(&parts, name)
	item := Stored_Object {
		store = walking.store,
		name  = strings.join(parts[:], "/", walking.allocator),
		tree  = entry.kind == u64(format.Entry_Kind.Tree),
	}
	if entry.kind == u64(format.Entry_Kind.Tree) {
		append(&walking.objects, item)
		if nesting < format.NESTING_LIMIT {
			walking.path[nesting] = name
			contents_walk_tree(walking, entry.pointer, nesting + 1)
		}
		return
	}
	state := walking.state
	reader := &walking.reader
	current := block_tree.State{root = entry.pointer, size = entry.size}
	item.size = entry.size
	item.root = entry.pointer
	bytes_ok: bool
	item.bytes, bytes_ok = contents_state_bytes(walking, current)
	clear(&walking.collected)
	blocks_outcome := block_tree.walk_blocks(&walking.objects_source.source, current, contents_collect, walking, &walking.nodes)
	item.blocks = slice.clone(walking.collected[:], walking.allocator)
	item.damaged = !bytes_ok || blocks_outcome != .Good
	// The hash of the entry: the hash that the block tree gives, from the
	// path of its last block.
	hash, hash_outcome := block_tree.state_hash(&walking.objects_source.source, current, &walking.hash_room)
	item.hash_wrong = hash_outcome != .Good || hash != entry.hash
	entries := make([]format.Version_Entry, format.VERSIONS_LIMIT, context.temp_allocator)
	count, versions_ok := storage_mount.versions_read(state, reader, entry.versions, entries)
	item.versions_damaged = !versions_ok
	versions := make([]Stored_Version, min(count, len(entries)), walking.allocator)
	for &version, index in versions {
		version_entry := entries[index]
		version.generation = version_entry.generation
		version.size = version_entry.size
		version.root = version_entry.root
		version_ok: bool
		version.bytes, version_ok = contents_state_bytes(walking, {root = version_entry.root, size = version_entry.size})
		version.damaged = !version_ok
	}
	item.versions = versions
	append(&walking.objects, item)
}
