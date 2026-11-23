// The format of the data disk: what the storage service writes, and what a
// tool reads to check or to damage a disk. A disk lives longer than the
// process that wrote it, so its format is a contract. The model (objects,
// trees, stores) is in docs/STORAGE.md.
//
// The disk is a row of blocks of 4096 bytes. Blocks 0 and 1 are the two
// places of the root block. Each other block is free, or it is a store
// directory node, a store block, a node, an object node, a block of data,
// a version index or a version leaf. A block names another block with a
// Pointer: its number and a check. The check of a block of data is the
// first 8 bytes of its value (Block_Value); the check of each other block
// is the first 8 bytes of the BLAKE3 hash of its 4096 bytes.
//
//   root        the generation, the blocks of the disk, and the Pointer
//               of each store table page
//   store table page
//               63 cells of stores: the name, the limit, the blocks used
//               and the store block of each (Store_Entry)
//   store block one for each store: the root node of its tree, the root
//               node of its removal queue, and its counts
//   node        a node of the B+ tree of one tree: a leaf of entries (a name
//               and an Entry), or a branch of children (a name and a Pointer)
//   object node a node of the block tree of one state of an object: 64
//               children, each a node of the level below, a block of data,
//               or a hole (docs/STORAGE.md, "Large objects")
//   data        4096 bytes of an object, at one place of it
//   version index, version leaf
//               for each object with versions: the index names the leaves,
//               a leaf holds Version_Entry records, the oldest first
//
// Each tree is its own B+ tree. An entry that names a tree holds the
// Pointer of the root node of that tree: a tree inside a tree. The entries
// of a tree are in the order of the bytes of their names.
//
// An object is a tree of blocks: the block n holds the bytes from n * 4096.
// A block that holds only zero bytes is a hole: nothing names it, and it
// reads as zero bytes. So an object of 8 GiB with three blocks of data holds
// a few blocks. The level of the root comes from the size (object_levels).
//
// Versions (docs/ARCHITECTURE.md, "Versions"): each commit that changes an
// object keeps its state before it as a version. A state names the root of
// its block tree; a commit copies the object nodes on the paths of the
// blocks that it changes, and the new state names the other nodes and
// blocks of the state before. So an object node or a block of data can be
// named many times: by the nodes of several states, by an entry and its
// versions, by an object and its clone (a shared block). A store table
// page, a store block, a node, an index and a leaf are named one time. A
// block is named from one store only, or by the store table.
//
// The rule (copy on write): a commit never writes a block that the root on
// the disk names. It writes each changed block to a free block, then the
// parents up to a new root, then the root in the place of the older of the
// two roots. Between these writes it asks the disk to keep what it wrote
// (Flush), so the blocks are on the disk before the root that names them.
// The root has its own check; at the start the service takes the valid root
// with the highest generation. A root that a stop of the machine cut is not
// valid: the root before it names blocks that no commit changed. So a store
// shows the state of one commit, never a part of one. Each block that a
// root names has its check in its Pointer: the start reads each one, and a
// change on the disk outside the service is found, not used.
//
// An object node or a block of data with a wrong check under a valid root
// is damage, not a cut commit: the state of the object that names it is
// damaged, and the other objects are served. A store block or a node with a
// wrong check, or a node that breaks a rule of this format, damages its
// store. A store table page with a wrong check damages each store of its
// cells: the service serves none of them and makes no store in that page.
//
// Who uses it: the storage service (`src/modules/system/storage`, with
// `src/library/internal/storage/storage_tree` and `src/library/internal/storage/storage_object`), and the tools that
// check or damage a disk in the tests. A process never reads the disk: it
// calls the storage service. The parts:
//
// - `Root`, `Store_Table_Page`, `Store_Entry`: the root block, the pages of
//   the store table, and the cell of one store.
// - `Store_Block`: the counts of one store.
// - `Tree_Header`, `Entry_Name`, `Entry`: the nodes of the B+ trees.
// - `Object_Node`, `Object_Child`, `Block_Value`: the block tree of an
//   object.
// - `Version_Index`, `Version_Leaf`, `Version_Entry`: the versions.
// - `Pointer`, `check`, `root_valid`, `disk_blocks_valid`, `disk_bytes`: the checks and geometry of the disk.
// - `name_refusal`: the rule of a name.
//
// See [store](term:store), [tree](term:tree) and [version](term:version).
package store

import "base:intrinsics"
import "modus:contract/blake3"
import "modus:contract/text_encoding"

BLOCK_SIZE :: 4096 // The bytes of one block of the disk: one page, one block of the block service.
ROOT_MAGIC :: u64(0x36454741524F5453) // The bytes "STORAGE6": a paged store table, names of 255 bytes, the counts of names in a count tree.
NAME_CAPACITY :: 32 // A name of a store: the name that the root service gives, with zero bytes after it.

// The blocks of a disk: at least the two places of the root, and at most
// the count whose bytes a u64 holds, so that no offset of a block wraps.
DISK_BLOCKS_MIN :: u64(2)
DISK_BLOCKS_MAX :: max(u64) / BLOCK_SIZE

// The block tree of an object. A node has 64 children: 64 is a power of
// two, so a node covers a whole subtree of the BLAKE3 tree of the bytes,
// and 64 children with their values fill most of a block. Five levels
// name 64^5 blocks: an object holds up to 4 TiB. The limit is the depth:
// a commit copies one node of each level for each block that it changes,
// and the open takes a deeper tree for damage.
OBJECT_FANOUT :: 64 // The children of one object node.
OBJECT_LEVEL_LIMIT :: 5 // The most levels of the block tree of one object.
OBJECT_BLOCKS_LIMIT :: u64(1) << 30 // 64^5 blocks.
OBJECT_SIZE_LIMIT :: OBJECT_BLOCKS_LIMIT * BLOCK_SIZE // 4 TiB.

// The name of an entry: 1 to 255 bytes of UTF-8 with no control character
// (name_refusal checks it), stored in a 256-byte zero-padded slot so every
// record in a B+ tree node keeps 8-byte alignment for its Entry or Pointer.
// A name has no zero byte (the padding), no byte '/' and is not "." or "..":
// a name is one step down, so no name reaches past the tree that it is
// looked up in.
ENTRY_NAME_CAPACITY :: 255
ENTRY_NAME_STORAGE :: ENTRY_NAME_CAPACITY + 1

// The most levels of the B+ tree of one tree. With keys of 256 bytes a
// branch holds 14 children and at least 4, and a leaf at least 3 entries:
// 10 levels hold about 800000 entries with each node at its least, and
// more than a disk can name with full nodes. The open takes a deeper B+
// tree for damage, and no walk goes deeper.
TREE_DEPTH_LIMIT :: 10

// The most trees on a path from the root of a store: a place holds the
// names of its path, and a commit rewrites one tree on each level of it.
NESTING_LIMIT :: 32

// How a block names another block: its number and its check. A reader that
// follows a pointer reads the block, computes its check and compares: a
// block that does not match is damage, and the reader does not use it.
Pointer :: struct {
	block: u64, // 0: no block.
	check: u64, // The check of the block: `check` of its bytes, or `value_check` of its value for a block of data.
}

// The cell of one store (docs/STORAGE.md: the one thing that changes). 64
// bytes.
Store_Entry :: struct {
	name:  [NAME_CAPACITY]u8, // All zero: the cell is free.
	limit: u64, // The most blocks of the store, as the last grant gave it.
	used:  u64, // The distinct blocks of the store: its store block, its nodes, its object nodes, its data, its versions.
	store: Pointer, // The store block.
}
#assert(size_of(Store_Entry) == 64)

// The store table: pages of cells, each page one block that the root names.
// A store keeps its cell for the life of the disk, so its number (page *
// STORES_OF_A_PAGE + cell) is stable: the open and the service index their
// tables of stores by it. A commit changes one store, so it writes one page
// again, with copy on write as each other block. A store is never removed,
// so the pages fill in order: each page before the last one is full.
STORE_TABLE_MAGIC :: u32(0x524F5453) // The bytes "STOR".
STORES_OF_A_PAGE :: 63 // The cells of 64 bytes that fit in a block after the 16 bytes of the head of a page.
STORE_PAGE_CAPACITY :: 251 // The Pointers of 16 bytes that fit in the root after its head of 64 bytes and its check.
STORE_CAPACITY :: STORE_PAGE_CAPACITY * STORES_OF_A_PAGE // 15813 stores on one disk.

// One page of the store table. 4096 bytes.
Store_Table_Page :: struct {
	magic:    u32, // STORE_TABLE_MAGIC: a block of another kind is damage.
	reserved: u32, // 0.
	unused:   u64, // 0.
	cells:    [STORES_OF_A_PAGE]Store_Entry, // A free cell has no name.
	padding:  [BLOCK_SIZE - 16 - STORES_OF_A_PAGE * size_of(Store_Entry)]u8, // 0.
}

// The root block: the generation of the last commit, the blocks of the
// disk, and the pages of the store table. It is at block 0 or block 1: a
// commit writes the older of the two, so a cut write leaves the other valid
// (`root_valid`). The service takes the valid root with the highest
// generation. 4096 bytes. See [root block](term:root-block).
Root :: struct {
	magic:            u64, // `ROOT_MAGIC`.
	generation:       u64, // The count of commits of the disk: one more at each commit.
	disk_blocks:      u64, // The blocks of the disk that the format uses: DISK_BLOCKS_MIN ..= DISK_BLOCKS_MAX, at most the blocks of the disk.
	time:             u64, // The time since the format of the disk at this commit, in milliseconds.
	date:             u64, // The date of this commit in seconds since 1970 (UTC). 0: not known.
	store_page_count: u64, // The pages of the store table: store_pages[:store_page_count] name a block each.
	counts:           Pointer, // The top directory of the count tree. No block: the root names no count tree.
	store_pages:      [STORE_PAGE_CAPACITY]Pointer, // The pages of the store table, in the order of the numbers of the stores.
	counts_complete:  u64, // 1: the count tree holds the count of each block of the disk; 0: some leaves are still to write.
	check:            u64, // The hash of the bytes before it.
}
#assert(size_of(Root) == BLOCK_SIZE)

// The count tree: the count of names and the owner of each block of the
// disk, on the disk itself, so that a disk larger than the memory of the
// service opens with no walk (src/md/data/storage_capacity.md, "The counts
// of names live on the disk"). A leaf holds 512 blocks; a directory holds
// 128 children, each a leaf or a directory of the level below, with the
// count of the free blocks under it. A child with no block is 512 * 128^l
// blocks of count 0 and owner 0. Each block of the tree has the count 1 and
// the owner COUNT_TREE_OWNER in the tree itself. The top is always a
// directory. Every page of the tree is copy on write.
COUNTS_OF_A_PAGE :: 512
COUNT_DIRECTORY_FANOUT :: 128
COUNT_PAGE_MAGIC :: u32(0x53544E43) // The bytes "CNTS".
// A list of the states that one commit gave to the removal queue
// (Entry_Kind.Release): one block of up to 127 states, which names the next
// list of the same commit, so a commit that releases any count of large
// states makes one entry of the queue. A block of the store, counted as
// each block of its store; the list before names it, and the entry names
// the first.
RELEASE_LIST_MAGIC :: u32(0x534C4552) // The bytes "RELS".
RELEASES_OF_A_LIST :: 127

// One state of a release list. 32 bytes.
Release_State :: struct {
	root:   Pointer, // The root of the state: the list holds its last name.
	size:   u64, // The bytes of the state.
	cursor: u64, // The first block of data that no step has freed yet.
}
#assert(size_of(Release_State) == 32)

// A release list. 4096 bytes.
Release_List :: struct {
	magic:   u32, // RELEASE_LIST_MAGIC.
	count:   u32, // The states: 1 ..= RELEASES_OF_A_LIST.
	next:    Pointer, // The next list of the commit: no block and the check 0 for the last.
	states:  [RELEASES_OF_A_LIST]Release_State,
	padding: [BLOCK_SIZE - 24 - RELEASES_OF_A_LIST * size_of(Release_State)]u8, // 0.
}
#assert(size_of(Release_List) == BLOCK_SIZE)

// release_list_valid says if a block is a release list: its magic, a count
// in its bound, a next list of a block past the two roots or none (then
// with the check 0), and zero bytes in the places of no state and in the
// padding.
release_list_valid :: proc "contextless" (list: ^Release_List) -> bool {
	if list.magic != RELEASE_LIST_MAGIC || list.count == 0 || list.count > RELEASES_OF_A_LIST {
		return false
	}
	if list.next.block == 1 || list.next.block == 0 && list.next.check != 0 {
		return false
	}
	for state in list.states[list.count:] {
		if state != {} {
			return false
		}
	}
	for byte in list.padding {
		if byte != 0 {
			return false
		}
	}
	return true
}

// The owners of a block that are no store: a page of the store table, which
// the root names, and a page of the count tree. A store is its number plus
// 1, below both.
STORE_TABLE_OWNER :: max(u16)
COUNT_TREE_OWNER :: max(u16) - 1
#assert(STORE_CAPACITY < int(COUNT_TREE_OWNER))
COUNT_DIRECTORY_MAGIC :: u32(0x52494443) // The bytes "CDIR".
// The levels of directories that the largest disk needs: 512 * 128^7 is
// 2^58 blocks, more than DISK_BLOCKS_MAX.
COUNT_LEVEL_LIMIT :: 7

// A leaf of the count tree. 4096 bytes.
Count_Page :: struct {
	magic:   u32, // COUNT_PAGE_MAGIC.
	level:   u32, // 0.
	first:   u64, // The first block that it holds: a multiple of COUNTS_OF_A_PAGE.
	counts:  [COUNTS_OF_A_PAGE]u32, // The count of names of each block.
	owners:  [COUNTS_OF_A_PAGE]u16, // The store that names each block, plus 1, or a mark of the service: 0 for a free block.
	padding: [BLOCK_SIZE - 16 - COUNTS_OF_A_PAGE * 6]u8, // 0.
}
#assert(size_of(Count_Page) == BLOCK_SIZE)

// A child of a directory of the count tree. 24 bytes.
Count_Child :: struct {
	block:    u64, // 0: no page: each block under it has the count 0.
	check:    u64, // The check of the page.
	free:     u64, // The blocks of count 0 under it that the disk holds, past the two places of the root.
}
#assert(size_of(Count_Child) == 24)

// A directory of the count tree. 4096 bytes.
Count_Directory :: struct {
	magic:    u32, // COUNT_DIRECTORY_MAGIC.
	level:    u32, // 1 or more: its children are of the level below.
	first:    u64, // The first block under it: a multiple of count_span(level).
	children: [COUNT_DIRECTORY_FANOUT]Count_Child,
	padding:  [BLOCK_SIZE - 16 - COUNT_DIRECTORY_FANOUT * size_of(Count_Child)]u8, // 0.
}
#assert(size_of(Count_Directory) == BLOCK_SIZE)

// count_span gives the blocks under one page of the count tree of a level:
// 512 for a leaf, 512 * 128^level for a directory. A level past
// COUNT_LEVEL_LIMIT gives the span of that limit.
count_span :: proc "contextless" (level: int) -> u64 {
	span := u64(COUNTS_OF_A_PAGE)
	for _ in 0 ..< clamp(level, 0, COUNT_LEVEL_LIMIT) {
		span *= COUNT_DIRECTORY_FANOUT
	}
	return span
}

// count_tree_levels gives the level of the top directory of the count tree
// of a disk: the least level, at least 1, whose span holds each block.
count_tree_levels :: proc "contextless" (disk_blocks: u64) -> int {
	level := 1
	for level < COUNT_LEVEL_LIMIT && count_span(level) < disk_blocks {
		level += 1
	}
	return level
}

// count_free_blocks gives the blocks of count 0 that a page of a level
// that starts at `first` would hold if each count were 0: the blocks of
// the disk under it, past the two places of the root.
count_free_blocks :: proc "contextless" (level: int, first: u64, disk_blocks: u64) -> u64 {
	end := first + count_span(level)
	if end > disk_blocks || end < first {
		end = disk_blocks
	}
	start := max(first, 2)
	return end > start ? end - start : 0
}

// The block of one store: the root of its tree, its removal queue, and the
// counts that a commit needs with no walk.
Store_Block :: struct {
	tree:           Pointer, // The root node of the tree of the store. No block: the tree has no entry.
	removals:       Pointer, // The root node of the removal queue: a tree whose entries are trees to free, named by the 8 bytes of next_removal at their remove, big-endian.
	next_removal:   u64, // The number of the next remove: the name of the next entry of the removal queue.
	objects:        u64, // The objects of the store, with those in the removal queue.
	trees:          u64, // The trees inside the tree of the store, with those in the removal queue.
	// The blocks of the current objects: each object node and each block of
	// data of the block tree of each one, a block that two objects share
	// counted two times. A hole costs nothing. With
	// node_blocks and the store block, the least that the store needs with
	// no version: a change past the limit with no version is refused.
	current_blocks: u64,
	node_blocks:    u64, // The nodes of all the trees of the store, and of its removal queue.
	removing:       u64, // The entries of the removal queue.
	reserved:       [4]u64, // 0.
	padding:        [BLOCK_SIZE - 112]u8, // 0.
}

// What an entry of a tree names.
Entry_Kind :: enum u64 {
	None   = 0, // Not an entry: a leaf holds no such record.
	Object  = 1, // An object: bytes, with versions.
	Tree    = 2, // A tree: names of other entries.
	// States of objects that no entry or version names any more, too large
	// to free in one commit: an entry of the removal queue only, which steps
	// free a part at a time. pointer: the first Release_List of the states;
	// the other fields are 0 (src/md/data/storage_capacity.md, "A large state
	// is released in steps").
	Release = 3,
}

// entry_kind_of_word is the border of the kind of an entry (Entry.kind): the
// member, or false for a word that names no kind. The word comes from the
// disk, so a reader takes it through here and never casts it; a reader
// that holds no None refuses that member after the border.
entry_kind_of_word :: proc "contextless" (word: u64) -> (kind: Entry_Kind, ok: bool) {
	for member in Entry_Kind {
		if u64(member) == word {
			return member, true
		}
	}
	return {}, false
}

// The key of an entry: its name (1 to 255 bytes), with zero bytes after it
// up to 256 bytes so the trailing Entry or Pointer is 8-byte aligned. The
// order of the bytes is the order of the entries: a shorter name comes
// before the names that start with it.
Entry_Name :: [ENTRY_NAME_STORAGE]u8

// What an entry names.
//
// The record of a leaf, after its name. The storage service writes it at a
// commit, and gives its fields to a process as the state of an object or of
// a tree. 104 bytes. See [entry](term:entry).
Entry :: struct {
	kind:       u64, // An object or a tree: the word of an Entry_Kind, read through entry_kind_of_word.
	size:       u64, // An object: its bytes. A tree: its entries.
	generation: u64, // The commit of its last change.
	time:       u64, // The time since the format at that commit, in milliseconds.
	date:       u64, // The date of that commit, in seconds since 1970 (UTC). 0: not known.
	hash:       [32]u8, // An object: the hash of its bytes (docs/STORAGE.md, "The hash of an object"), its name in the model. A tree: zero.
	pointer:    Pointer, // An object: the root of its block tree (object_levels), no block when each of its bytes is zero. A tree: its root node (no block when it is empty).
	versions:   Pointer, // An object: its version index. No block: no version.
}

#assert(size_of(Entry_Name) == 256)
#assert(size_of(Entry) == 104)

// A node: the header, then `count` records. A record of a leaf is a name
// and its value; a record of a branch is a name and the Pointer of a child.
// In a branch, the name of the record n is at most each name under the
// child n, and more than each name under the child n - 1; the search does
// not read the name of the record 0, which can be larger than the name of
// the record 1. A node that a tree names is never empty; the records of a
// leaf, and the records from 1 of a branch, are in the order of their
// names, each name once.
NODE_MAGIC :: u32(0x45455254) // The bytes "TREE".

TREE_HEADER_SIZE :: 32 // The bytes of the header of a node and of an object node.
// The first 32 bytes of a node of a B+ tree, and of an object node.
Tree_Header :: struct {
	level:    u32, // 0: a leaf.
	count:    u32, // The records in use.
	magic:    u32, // NODE_MAGIC: a block of another kind is damage.
	reserved: u32, // 0.
	unused:   [2]u64, // 0.
}
#assert(size_of(Tree_Header) == TREE_HEADER_SIZE)

LEAF_CAPACITY :: (BLOCK_SIZE - TREE_HEADER_SIZE) / (size_of(Entry_Name) + size_of(Entry)) // 11: the records of a name and an entry that fit in one block.
BRANCH_CAPACITY :: (BLOCK_SIZE - TREE_HEADER_SIZE) / (size_of(Entry_Name) + size_of(Pointer)) // 14: the records of a name and a pointer that fit in one block.
#assert(LEAF_CAPACITY == 11)
#assert(BRANCH_CAPACITY == 14)

// One version of an object: its state at the commit of `generation`.
//
// The service adds one at each commit that changes the object, and the
// retention rule removes old ones (docs/STORAGE.md). 48 bytes.
Version_Entry :: struct {
	generation: u64, // The commit of the state.
	size:       u64, // The bytes of the object in that state.
	time:       u64, // The time since the format, in milliseconds.
	date:       u64, // Seconds since 1970 (UTC). 0: not known.
	root:       Pointer, // The root of the block tree of the state. No block: each of its bytes was zero.
}
#assert(size_of(Version_Entry) == 48)

VERSION_LEAF_CAPACITY :: 85 // The version entries of 48 bytes that fit in one block after the 16 bytes of the head of a leaf.
VERSION_INDEX_CAPACITY :: 254 // The pointers of 16 bytes that fit in one block after the 32 bytes of the head of an index.
VERSIONS_LIMIT :: VERSION_LEAF_CAPACITY * VERSION_INDEX_CAPACITY // 21590 versions of one object.

// One block of version entries of one object. 4096 bytes.
Version_Leaf :: struct {
	count:    u64, // The entries in use, from 1.
	reserved: u64, // 0.
	entries:  [VERSION_LEAF_CAPACITY]Version_Entry, // The oldest first; count of them are used.
}

// The block that names the version leaves of one object: the entry of the
// object names it in `versions`. 4096 bytes.
Version_Index :: struct {
	leaf_count:     u64, // The leaves in use.
	version_count:  u64, // The entries of all its leaves.
	retention_time: u64, // The time since the format of the last application of the retention rule to this object.
	reserved:       u64, // 0.
	leaves:         [VERSION_INDEX_CAPACITY]Pointer, // The oldest leaf first; leaf_count of them are used. No leaf is empty.
}

// The value of a part of an object: the BLAKE3 chaining value of its bytes,
// as a subtree of the BLAKE3 tree of the bytes of the object
// (docs/STORAGE.md, "The hash of an object"). The value of a block of data
// is the chaining value of its 4096 bytes at its place: it is its check, and
// the hash of the object comes from the values. A part whose bytes are all
// zero has the value zero: it is a hole, and costs nothing.
Block_Value :: [8]u32

// value_check gives the check of a block of data: the first 8 bytes of its
// value.
value_check :: #force_inline proc "contextless" (value: Block_Value) -> u64 {
	return u64(value[0]) | u64(value[1]) << 32
}

// One child of an object node: a node of the level below, or a block of
// data under a node of level 1, or a hole (block 0, and each other field
// zero).
Object_Child :: struct {
	block:  u64, // The block of the child. 0: a hole.
	check:  u64, // A node: the first 8 bytes of the BLAKE3 hash of its block. A block of data: value_check(value).
	blocks: u64, // The blocks of the child: itself and each block under it.
	value:  Block_Value, // The value of the 64^level blocks that the child covers, zero bytes past the size included.
}
#assert(size_of(Object_Child) == 56)

// An object node. Its header has the level (1 to OBJECT_LEVEL_LIMIT), the
// count of the children that are not holes (never 0: a node with no child
// is a hole), and OBJECT_NODE_MAGIC. A child whose blocks start at or past
// the size of the state is a hole.
OBJECT_NODE_MAGIC :: u32(0x424F4C42) // The bytes "BLOB".

// One node of the block tree of an object. 4096 bytes.
Object_Node :: struct {
	header:   Tree_Header, // The level, the count of children that are not holes, `OBJECT_NODE_MAGIC`.
	children: [OBJECT_FANOUT]Object_Child, // Child n covers the blocks from n * 64^(level - 1) under the node.
	padding:  [BLOCK_SIZE - TREE_HEADER_SIZE - OBJECT_FANOUT * size_of(Object_Child)]u8, // 0.
}

#assert(size_of(Root) == BLOCK_SIZE)
#assert(size_of(Store_Table_Page) == BLOCK_SIZE)
#assert(size_of(Store_Block) == BLOCK_SIZE)
#assert(size_of(Object_Node) == BLOCK_SIZE)
#assert(size_of(Version_Leaf) == BLOCK_SIZE)
#assert(size_of(Version_Index) == BLOCK_SIZE)

// disk_blocks_valid says if a count of blocks can be a disk: at least the
// two places of the root, and at most DISK_BLOCKS_MAX.
disk_blocks_valid :: proc "contextless" (disk_blocks: u64) -> bool {
	return disk_blocks >= DISK_BLOCKS_MIN && disk_blocks <= DISK_BLOCKS_MAX
}

// disk_bytes gives the bytes of a disk of disk_blocks blocks, or false for
// a count that no disk has.
disk_bytes :: proc "contextless" (disk_blocks: u64) -> (bytes: u64, ok: bool) {
	if !disk_blocks_valid(disk_blocks) {
		return 0, false
	}
	return disk_blocks * BLOCK_SIZE, true
}

// bitmap_words_for_blocks gives the words of 64 bits that hold one bit for
// each block of a disk. The division rounds up from disk_blocks - 1, so it
// never wraps.
bitmap_words_for_blocks :: proc "contextless" (disk_blocks: u64) -> (words: u64, ok: bool) {
	if !disk_blocks_valid(disk_blocks) {
		return 0, false
	}
	return (disk_blocks - 1) / 64 + 1, true
}

// object_blocks gives the blocks of an object of `size` bytes, holes
// included.
//
// Example: `object_blocks(4097)` is 2.
object_blocks :: proc "contextless" (size: u64) -> u64 {
	return size / BLOCK_SIZE + u64(size % BLOCK_SIZE != 0)
}

// object_levels gives the level of the root of the block tree of an object:
// 0 when it has at most one block (the root is its block of data), else
// the least level whose node covers each of its blocks.
//
// Example: an object of 1 MiB (256 blocks) has the level 2: a node of
// level 1 covers 64 blocks, a node of level 2 covers 4096.
object_levels :: proc "contextless" (size: u64) -> int {
	count := object_blocks(size)
	levels := 0
	span: u64 = 1
	for span < count && levels < OBJECT_LEVEL_LIMIT {
		span *= OBJECT_FANOUT
		levels += 1
	}
	return levels
}

// object_span gives the blocks that a node of a level covers: 64^level.
object_span :: proc "contextless" (level: int) -> u64 {
	return u64(1) << uint(6 * level)
}

// check gives the check of a block: the first 8 bytes of its BLAKE3 hash.
check :: proc "contextless" (bytes: []u8) -> u64 {
	hash := blake3.hash(bytes)
	return intrinsics.unaligned_load((^u64)(&hash[0]))
}

// root_check gives the check of a root: the check of the bytes before its
// field check.
root_check :: proc "contextless" (value: ^Root) -> u64 {
	return check(([^]u8)(value)[:offset_of(Root, check)])
}

// root_valid says if a root block is one that a commit finished.
root_valid :: proc "contextless" (value: ^Root, disk_blocks: u64) -> bool {
	if value.magic != ROOT_MAGIC || value.check != root_check(value) {
		return false
	}
	if !disk_blocks_valid(value.disk_blocks) || value.disk_blocks > disk_blocks {
		return false
	}
	return value.store_page_count <= STORE_PAGE_CAPACITY
}

// store_place gives the page and the cell of the store of a number.
store_place :: #force_inline proc "contextless" (number: int) -> (page: int, cell: int) {
	return number / STORES_OF_A_PAGE, number % STORES_OF_A_PAGE
}

// entry_name gives the key of a name. The name must have passed
// name_refusal, or be a name of the removal queue.
entry_name :: proc "contextless" (name: string) -> (key: Entry_Name) {
	copy(key[:ENTRY_NAME_CAPACITY], name)
	return key
}

// name_of gives the name of a key: its bytes before the first zero byte.
name_of :: proc "contextless" (key: ^Entry_Name) -> string {
	count := 0
	for count < ENTRY_NAME_CAPACITY && key[count] != 0 {
		count += 1
	}
	return string(key[:count])
}

// removal_name gives the name of an entry of the removal queue: the number
// of the remove, big-endian, so that the queue is in the order of the
// removes. It is no name of an entry that a process makes: it has zero
// bytes.
removal_name :: proc "contextless" (number: u64) -> (key: Entry_Name) {
	for index in 0 ..< 8 {
		key[index] = u8(number >> uint(56 - 8 * index))
	}
	return key
}

// Why a name cannot be the name of an entry: the result of `name_refusal`.
// The storage service turns it into the error kinds `Empty`, `Too_Long` and
// `Bad_Byte`.
Name_Refusal :: enum {
	None, // The name is valid.
	Empty, // The name has no byte.
	Too_Long, // More than ENTRY_NAME_CAPACITY bytes.
	Bad_Byte, // A zero byte or a byte '/', or the first byte of an invalid sequence: at `offset`. "." and "..": offset 0.
}

// name_refusal says why a name cannot be the name of an entry, or None. A
// name is one step down in a tree: it has no separator and does not name
// the tree above, so a name looked up under a place never reaches an entry
// outside it.
name_refusal :: proc "contextless" (name: string) -> (refusal: Name_Refusal, offset: int, byte: u8) {
	if len(name) == 0 {
		return .Empty, 0, 0
	}
	if len(name) > ENTRY_NAME_CAPACITY {
		return .Too_Long, 0, 0
	}
	for index in 0 ..< len(name) {
		if name[index] == 0 || name[index] == '/' {
			return .Bad_Byte, index, name[index]
		}
	}
	if name == "." || name == ".." {
		return .Bad_Byte, 0, '.'
	}
	// A name is a text that a principal reads: UTF-8 with no control
	// character (src/library/modus/contract/text_encoding).
	if place, found := text_encoding.invalid_sequence_find(transmute([]u8)name); found {
		return .Bad_Byte, place, name[place]
	}
	return .None, 0, 0
}
