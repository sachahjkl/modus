// Canonical read-only image-tree binary manifest format, encoder, validator,
// and multi-tree lookup (src/md/features/objects_by_hash.md).
//
// The build tool packs one canonical image tree (`RESOURCE_NAME`) into the
// boot image beside the data files. The storage service validates it on entry
// and resolves exact '/' paths across connection-granted subtrees without
// exposing root-only boot and trust records.
//
// Binary layout (all integers little-endian, zero implicit padding):
//   Header            (24 bytes)
//   Node_Record       (16 bytes * node_count, canonical pre-order; node 0 is root)
//   Entry_Record      (56 bytes * entry_count, grouped contiguously by owner node,
//                      strictly sorted by UTF-8 byte order within each node)
//   Name pool         (names_bytes bytes, contiguous in entry order)
//
// Acyclicity and uniqueness hold by construction: every non-root node has
// parent_node < node_index, every Tree entry targets child_node > owner_node,
// and every non-root node is targeted by exactly one Tree entry in its parent.
//
// Every routine is pure, contextless, and allocates no memory.
package image_tree

import "base:intrinsics"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import "modus:contract/enum_word"
import "modus:contract/store"
import "modus:contract/system_description"

// Resource name of the canonical image-tree manifest in the boot image.
RESOURCE_NAME :: "image_tree"

// Format property: 8-byte header magic identifying version 1 of the canonical
// boot-image tree manifest.
MAGIC :: [8]u8{'I', 'M', 'G', 'T', 'R', 'E', 'E', '1'}
VERSION :: u32(1)

// Format property: fixed byte sizes of wire records.
HEADER_SIZE :: 24
NODE_RECORD_SIZE :: 16
ENTRY_RECORD_SIZE :: 56

// Format property: upper bounds on one boot-image tree manifest.
NODE_CAPACITY :: 4096
ENTRY_CAPACITY :: 16384
NAMES_BYTES_LIMIT :: 1 << 20 // 1 MiB name pool ceiling.

// Format property: root node index and sentinel parent of the root node.
ROOT_NODE :: u32(0)
ROOT_PARENT :: max(u32)

// Internal sentinel for an empty draft list index.
NO_DRAFT_INDEX :: max(u32)

// Closed set of entry kinds in an image tree, matching store.Entry_Kind
// (Object = 1, Tree = 2) explicitly across the binary border.
Entry_Kind :: enum u8 {
	Object = 1,
	Tree   = 2,
}

// entry_kind_of_word is the single border converting a raw wire word into an
// Entry_Kind member. Unknown values are refused.
entry_kind_of_word :: proc "contextless" (word: u64) -> (kind: Entry_Kind, ok: bool) {
	return enum_word.member_of_word(Entry_Kind, word)
}

// Closed set of format validation and encoding refusals.
Problem :: enum u8 {
	None                 = 0,
	Truncated            = 1, // Input or output buffer is smaller than required.
	Trailing_Bytes       = 2, // Bytes follow the end of the name pool.
	Bad_Magic            = 3, // Header magic is not MAGIC.
	Bad_Version          = 4, // Header version is not VERSION.
	Bad_Counts           = 5, // node_count is 0 or exceeds NODE_CAPACITY, or entry/name counts exceed bounds.
	Bad_Node             = 6, // Node reserved word is non-zero, entry span mismatches, or parent mismatches.
	Bad_Entry            = 7, // Entry reserved fields or Tree size/hash are non-zero.
	Bad_Entry_Kind       = 8, // Entry kind byte names no Entry_Kind member.
	Bad_Name_Offset      = 9, // Entry name_offset is not contiguous or overflows names_bytes.
	Invalid_Name         = 10, // Entry name fails store.name_refusal.
	Reserved_Name        = 11, // Entry names or targets a root-only boot or trust record.
	Not_Sorted           = 12, // Sibling entries are not in strict UTF-8 byte order.
	Duplicate_Name       = 13, // Two sibling entries share one name.
	Cycle_Or_Order       = 14, // Child or parent index violates strict forward pre-order (cycle or backward link).
	Orphan_Node          = 15, // A non-root node is not referenced by its parent.
	Shared_Node          = 16, // Two Tree entries target the same child node.
	Too_Deep             = 17, // Subtree depth exceeds store.OBJECT_PATH_DEPTH_LIMIT (32).
	Invalid_Path         = 18, // An Object_Spec path failed store.object_path_validate.
	Path_Conflict        = 19, // One path names both an object and a subtree.
	Scratch_Too_Small    = 20, // Caller-supplied draft scratch slice cannot hold all nodes or entries.
	Resource_Out_Of_Range = 21, // image_entry_index is past the boot-image resource table.
	Resource_Mismatch    = 22, // Object size or hash disagrees with the boot-image resource entry.
}

// problem_of_word converts a transport word into a Problem member.
problem_of_word :: proc "contextless" (word: u64) -> (problem: Problem, ok: bool) {
	return enum_word.member_of_word(Problem, word)
}

// Closed set of outcomes from path resolution against granted subtrees.
Lookup_Problem :: enum u8 {
	None             = 0, // Exact single object resolved (and matched expected hash if pinned).
	Manifest_Invalid = 1, // Manifest bytes failed validate.
	Bad_Path         = 2, // Path failed store.object_path_validate.
	Not_Found        = 3, // No granted tree holds the path.
	Is_Subtree       = 4, // Path names a subtree, not an object.
	Ambiguous        = 5, // Two or more granted trees hold an object at the path.
	Hash_Mismatch    = 6, // Object exists at path, but its hash differs from the caller's expected hash.
	Bad_Grant        = 7, // A Subtree_Grant names a node outside the manifest.
}

// lookup_problem_of_word converts a transport word into a Lookup_Problem member.
lookup_problem_of_word :: proc "contextless" (word: u64) -> (problem: Lookup_Problem, ok: bool) {
	return enum_word.member_of_word(Lookup_Problem, word)
}

// Wire header of the canonical image-tree manifest (24 bytes).
Header :: struct {
	magic:       [8]u8,
	version:     u32,
	node_count:  u32,
	entry_count: u32,
	names_bytes: u32,
}
#assert(size_of(Header) == HEADER_SIZE)

// Wire record of one tree node (16 bytes).
Node_Record :: struct {
	first_entry: u32,
	entry_count: u32,
	parent_node: u32, // ROOT_PARENT for node 0; strictly < node_index otherwise.
	reserved:    u32, // Must be 0.
}
#assert(size_of(Node_Record) == NODE_RECORD_SIZE)

// Wire record of one entry inside a tree node (56 bytes).
Entry_Record :: struct {
	kind:         u8, // u8(Entry_Kind)
	name_length:  u8, // 1 ..= 255
	reserved_u16: u16, // Must be 0.
	name_offset:  u32, // Contiguous offset in name pool.
	target_index: u32, // image_entry_index for Object; child node index for Tree.
	reserved_u32: u32, // Must be 0.
	size:         u64, // Byte size for Object (0 allowed); must be 0 for Tree.
	hash:         blake3.Hash, // BLAKE3 hash for Object; must be zero for Tree.
}
#assert(size_of(Entry_Record) == ENTRY_RECORD_SIZE)

// Low-level node description for encode_nodes.
Build_Node :: struct {
	first_entry: u32,
	entry_count: u32,
	parent_node: u32,
}

// Low-level entry description for encode_nodes.
Build_Entry :: struct {
	kind:         Entry_Kind,
	name:         string,
	target_index: u32,
	size:         u64,
	hash:         blake3.Hash,
}

// High-level object description for encode_from_objects.
Object_Spec :: struct {
	path:              string,
	image_entry_index: u32,
	size:              u64,
	hash:              blake3.Hash,
}

// Caller-supplied scratch structs for zero-allocation encode_from_objects.
Draft_Node :: struct {
	first_entry:       u32,
	entry_count:       u32,
	parent_node:       u32,
	depth:             u8,
	final_index:       u32,
	order_draft_index: u32,
}

Draft_Entry :: struct {
	kind:         Entry_Kind,
	name:         string,
	target_index: u32,
	size:         u64,
	hash:         blake3.Hash,
	next_in_node: u32,
}

// One granted subtree root on a storage connection.
Subtree_Grant :: struct {
	tree_name: string, // Label reported in ambiguity records (for example "pointer_themes").
	root_node: u32, // Validated node index inside the manifest (ROOT_NODE for root).
}

// Decoded result of a single object lookup.
Resolved_Object :: struct {
	image_entry_index: u32,
	size:              u64,
	hash:              blake3.Hash,
	grant_index:       int,
}

// One matching tree entry written into a caller-supplied ambiguity table.
Ambiguity_Match :: struct {
	grant_index:       int,
	tree_name:         string,
	image_entry_index: u32,
	size:              u64,
	hash:              blake3.Hash,
}

// Decoded view of one entry returned when listing a node.
Listed_Entry :: struct {
	kind:         Entry_Kind,
	name:         string,
	target_index: u32,
	size:         u64,
	hash:         blake3.Hash,
}

// Root-only boot and trust records that must never be exposed in the image tree.
@(rodata)
RESERVED_BOOT_RECORDS := [?]string {
	system_description.RESOURCE_DESCRIPTION,
	system_description.RESOURCE_SIGNATURE,
	"start_list",
	"rescue_list",
	"replacement_list",
	"default_plan_values",
	"test_plan_values",
	"measure_run",
	RESOURCE_NAME,
}

// is_reserved_boot_record reports whether name is a root-only boot or trust
// record excluded from the image tree.
is_reserved_boot_record :: proc "contextless" (name: string) -> bool {
	for reserved in RESERVED_BOOT_RECORDS {
		if name == reserved {
			return true
		}
	}
	return false
}

// compare_bytes orders two UTF-8 entry names strictly by raw byte value.
@(private = "file")
compare_bytes :: proc "contextless" (left, right: string) -> int {
	limit := min(len(left), len(right))
	for index in 0 ..< limit {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	if len(left) < len(right) {
		return -1
	}
	if len(left) > len(right) {
		return 1
	}
	return 0
}

// encoded_size computes the exact canonical byte count for the given counts,
// or 0 if counts exceed format limits.
encoded_size :: proc "contextless" (node_count, entry_count, names_bytes: u32) -> int {
	if node_count == 0 || node_count > NODE_CAPACITY || entry_count > ENTRY_CAPACITY || names_bytes > NAMES_BYTES_LIMIT {
		return 0
	}
	total := u64(HEADER_SIZE) + u64(node_count) * u64(NODE_RECORD_SIZE) + u64(entry_count) * u64(ENTRY_RECORD_SIZE) + u64(names_bytes)
	return int(total)
}

// read_header copies Header out of bytes before inspecting any field.
@(private = "file")
read_header :: proc "contextless" (bytes: []u8) -> (header: Header, ok: bool) {
	if len(bytes) < HEADER_SIZE {
		return {}, false
	}
	intrinsics.mem_copy_non_overlapping(&header, raw_data(bytes), HEADER_SIZE)
	return header, true
}

// read_node copies Node_Record at index out of a validated buffer.
@(private = "file")
read_node :: proc "contextless" (bytes: []u8, node_index: u32) -> (node: Node_Record) {
	offset := HEADER_SIZE + int(node_index) * NODE_RECORD_SIZE
	intrinsics.mem_copy_non_overlapping(&node, raw_data(bytes[offset:]), NODE_RECORD_SIZE)
	return node
}

// read_entry copies Entry_Record at index out of a validated buffer.
@(private = "file")
read_entry :: proc "contextless" (bytes: []u8, node_count: u32, entry_index: u32) -> (entry: Entry_Record) {
	offset := HEADER_SIZE + int(node_count) * NODE_RECORD_SIZE + int(entry_index) * ENTRY_RECORD_SIZE
	intrinsics.mem_copy_non_overlapping(&entry, raw_data(bytes[offset:]), ENTRY_RECORD_SIZE)
	return entry
}

// name_pool_offset gives the start of the name pool inside a validated buffer.
@(private = "file")
name_pool_offset :: proc "contextless" (header: Header) -> int {
	return HEADER_SIZE + int(header.node_count) * NODE_RECORD_SIZE + int(header.entry_count) * ENTRY_RECORD_SIZE
}

// entry_name_slice returns the UTF-8 name slice of an entry from a validated buffer.
@(private = "file")
entry_name_slice :: proc "contextless" (bytes: []u8, pool_start: int, entry: Entry_Record) -> string {
	return string(bytes[pool_start + int(entry.name_offset):][:int(entry.name_length)])
}

// bitset helpers over [NODE_CAPACITY / 64]u64.
@(private = "file")
node_bit_has :: #force_inline proc "contextless" (bits: ^[NODE_CAPACITY / 64]u64, index: u32) -> bool {
	return (bits[index / 64] & (u64(1) << (index % 64))) != 0
}

@(private = "file")
node_bit_set :: #force_inline proc "contextless" (bits: ^[NODE_CAPACITY / 64]u64, index: u32) {
	bits[index / 64] |= u64(1) << (index % 64)
}

// validate strictly checks every byte and invariant of a canonical image-tree
// manifest in one linear pass with zero heap allocation.
validate :: proc "contextless" (bytes: []u8) -> (header: Header, problem: Problem) {
	ok: bool
	header, ok = read_header(bytes)
	if !ok {
		return {}, .Truncated
	}
	if header.magic != MAGIC {
		return {}, .Bad_Magic
	}
	if header.version != VERSION {
		return {}, .Bad_Version
	}
	if header.node_count == 0 || header.node_count > NODE_CAPACITY || header.entry_count > ENTRY_CAPACITY || header.names_bytes > NAMES_BYTES_LIMIT {
		return {}, .Bad_Counts
	}
	expected := u64(HEADER_SIZE) + u64(header.node_count) * u64(NODE_RECORD_SIZE) + u64(header.entry_count) * u64(ENTRY_RECORD_SIZE) + u64(header.names_bytes)
	if u64(len(bytes)) < expected {
		return {}, .Truncated
	}
	if u64(len(bytes)) > expected {
		return {}, .Trailing_Bytes
	}

	pool_start := name_pool_offset(header)
	referenced_child: [NODE_CAPACITY / 64]u64
	node_depths: [NODE_CAPACITY]u8

	running_entry: u32 = 0
	running_name_offset: u32 = 0

	for node_index: u32 = 0; node_index < header.node_count; node_index += 1 {
		node := read_node(bytes, node_index)
		if node.reserved != 0 || node.first_entry != running_entry {
			return {}, .Bad_Node
		}
		if u64(node.first_entry) + u64(node.entry_count) > u64(header.entry_count) {
			return {}, .Bad_Node
		}
		if node_index == ROOT_NODE {
			if node.parent_node != ROOT_PARENT {
				return {}, .Bad_Node
			}
			node_depths[0] = 0
		} else {
			if node.parent_node >= node_index {
				return {}, .Cycle_Or_Order
			}
			if !node_bit_has(&referenced_child, node_index) {
				return {}, .Orphan_Node
			}
		}

		previous_name := ""
		for local_index: u32 = 0; local_index < node.entry_count; local_index += 1 {
			entry := read_entry(bytes, header.node_count, node.first_entry + local_index)
			if entry.reserved_u16 != 0 || entry.reserved_u32 != 0 {
				return {}, .Bad_Entry
			}
			kind, kind_ok := entry_kind_of_word(u64(entry.kind))
			if !kind_ok {
				return {}, .Bad_Entry_Kind
			}
			if entry.name_length == 0 {
				return {}, .Invalid_Name
			}
			if entry.name_offset != running_name_offset || u64(entry.name_offset) + u64(entry.name_length) > u64(header.names_bytes) {
				return {}, .Bad_Name_Offset
			}
			name := entry_name_slice(bytes, pool_start, entry)
			if refusal, _, _ := store.name_refusal(name); refusal != .None {
				return {}, .Invalid_Name
			}
			if is_reserved_boot_record(name) {
				return {}, .Reserved_Name
			}
			if local_index > 0 {
				order := compare_bytes(previous_name, name)
				if order == 0 {
					return {}, .Duplicate_Name
				}
				if order > 0 {
					return {}, .Not_Sorted
				}
			}
			previous_name = name

			switch kind {
			case .Object:
				// Any target_index and any size (including 0) are structurally valid;
				// validate_against_resources checks them against the boot image.
			case .Tree:
				if entry.size != 0 || entry.hash != {} {
					return {}, .Bad_Entry
				}
				child := entry.target_index
				if child <= node_index || child >= header.node_count {
					return {}, .Cycle_Or_Order
				}
				if node_bit_has(&referenced_child, child) {
					return {}, .Shared_Node
				}
				child_node := read_node(bytes, child)
				if child_node.parent_node != node_index {
					return {}, .Bad_Node
				}
				child_depth := int(node_depths[node_index]) + 1
				// A subtree at depth OBJECT_PATH_DEPTH_LIMIT can hold no object
				// within OBJECT_PATH_DEPTH_LIMIT segments, and deeper subtrees
				// cannot even be addressed.
				if child_depth >= store.OBJECT_PATH_DEPTH_LIMIT {
					return {}, .Too_Deep
				}
				node_bit_set(&referenced_child, child)
				node_depths[child] = u8(child_depth)
			}
			running_name_offset += u32(entry.name_length)
		}
		running_entry += node.entry_count
	}

	if running_entry != header.entry_count {
		return {}, .Bad_Node
	}
	if running_name_offset != header.names_bytes {
		return {}, .Bad_Name_Offset
	}
	return header, .None
}

// validate_against_resources validates the manifest and checks every Object
// entry against the boot-image resource table: target_index in range, target
// resource is not a reserved boot/trust record, and size and hash match.
validate_against_resources :: proc "contextless" (bytes: []u8, resources: []info.Image_Entry) -> (header: Header, problem: Problem) {
	header, problem = validate(bytes)
	if problem != .None {
		return {}, problem
	}
	for entry_index: u32 = 0; entry_index < header.entry_count; entry_index += 1 {
		entry := read_entry(bytes, header.node_count, entry_index)
		kind, kind_ok := entry_kind_of_word(u64(entry.kind))
		if !kind_ok {
			return {}, .Bad_Entry_Kind
		}
		switch kind {
		case .Tree:
		case .Object:
			if u64(entry.target_index) >= u64(len(resources)) {
				return {}, .Resource_Out_Of_Range
			}
			resource := &resources[entry.target_index]
			res_name := system_description.name_of(&resource.name)
			if is_reserved_boot_record(res_name) {
				return {}, .Reserved_Name
			}
			if entry.size != resource.size || entry.hash != resource.hash {
				return {}, .Resource_Mismatch
			}
		}
	}
	return header, .None
}

// encode_nodes validates nodes and entries and writes their canonical binary
// manifest into output. On refusal, output is left untouched and written is 0.
encode_nodes :: proc "contextless" (nodes: []Build_Node, entries: []Build_Entry, output: []u8) -> (written: int, problem: Problem) {
	if len(nodes) == 0 || len(nodes) > NODE_CAPACITY || len(entries) > ENTRY_CAPACITY {
		return 0, .Bad_Counts
	}
	referenced_child: [NODE_CAPACITY / 64]u64
	node_depths: [NODE_CAPACITY]u8
	running_entry: u32 = 0
	total_names: u64 = 0

	// Pass 1: validate every invariant before writing a single byte of output.
	for node, raw_node_idx in nodes {
		node_index := u32(raw_node_idx)
		if node.first_entry != running_entry || u64(node.first_entry) + u64(node.entry_count) > u64(len(entries)) {
			return 0, .Bad_Node
		}
		if node_index == ROOT_NODE {
			if node.parent_node != ROOT_PARENT {
				return 0, .Bad_Node
			}
			node_depths[0] = 0
		} else {
			if node.parent_node >= node_index {
				return 0, .Cycle_Or_Order
			}
			if !node_bit_has(&referenced_child, node_index) {
				return 0, .Orphan_Node
			}
		}

		previous_name := ""
		for local_index: u32 = 0; local_index < node.entry_count; local_index += 1 {
			entry := &entries[node.first_entry + local_index]
			kind, kind_ok := entry_kind_of_word(u64(entry.kind))
			if !kind_ok {
				return 0, .Bad_Entry_Kind
			}
			if refusal, _, _ := store.name_refusal(entry.name); refusal != .None {
				return 0, .Invalid_Name
			}
			if is_reserved_boot_record(entry.name) {
				return 0, .Reserved_Name
			}
			if local_index > 0 {
				order := compare_bytes(previous_name, entry.name)
				if order == 0 {
					return 0, .Duplicate_Name
				}
				if order > 0 {
					return 0, .Not_Sorted
				}
			}
			previous_name = entry.name
			total_names += u64(len(entry.name))
			if total_names > NAMES_BYTES_LIMIT {
				return 0, .Bad_Counts
			}

			switch kind {
			case .Object:
			case .Tree:
				if entry.size != 0 || entry.hash != {} {
					return 0, .Bad_Entry
				}
				child := entry.target_index
				if child <= node_index || child >= u32(len(nodes)) {
					return 0, .Cycle_Or_Order
				}
				if node_bit_has(&referenced_child, child) {
					return 0, .Shared_Node
				}
				if nodes[child].parent_node != node_index {
					return 0, .Bad_Node
				}
				child_depth := int(node_depths[node_index]) + 1
				if child_depth >= store.OBJECT_PATH_DEPTH_LIMIT {
					return 0, .Too_Deep
				}
				node_bit_set(&referenced_child, child)
				node_depths[child] = u8(child_depth)
			}
		}
		running_entry += node.entry_count
	}
	if int(running_entry) != len(entries) {
		return 0, .Bad_Node
	}

	required := encoded_size(u32(len(nodes)), u32(len(entries)), u32(total_names))
	if required == 0 {
		return 0, .Bad_Counts
	}
	if len(output) < required {
		return 0, .Truncated
	}

	// Pass 2: emit canonical bytes.
	header := Header {
		magic       = MAGIC,
		version     = VERSION,
		node_count  = u32(len(nodes)),
		entry_count = u32(len(entries)),
		names_bytes = u32(total_names),
	}
	intrinsics.mem_copy_non_overlapping(raw_data(output), &header, HEADER_SIZE)

	nodes_start := HEADER_SIZE
	for node, index in nodes {
		record := Node_Record {
			first_entry = node.first_entry,
			entry_count = node.entry_count,
			parent_node = node.parent_node,
			reserved    = 0,
		}
		intrinsics.mem_copy_non_overlapping(raw_data(output[nodes_start + index * NODE_RECORD_SIZE:]), &record, NODE_RECORD_SIZE)
	}

	entries_start := nodes_start + len(nodes) * NODE_RECORD_SIZE
	pool_start := entries_start + len(entries) * ENTRY_RECORD_SIZE
	name_cursor: u32 = 0
	for &entry, index in entries {
		record := Entry_Record {
			kind         = u8(entry.kind),
			name_length  = u8(len(entry.name)),
			reserved_u16 = 0,
			name_offset  = name_cursor,
			target_index = entry.target_index,
			reserved_u32 = 0,
			size         = entry.size,
			hash         = entry.hash,
		}
		intrinsics.mem_copy_non_overlapping(raw_data(output[entries_start + index * ENTRY_RECORD_SIZE:]), &record, ENTRY_RECORD_SIZE)
		if len(entry.name) > 0 {
			copy(output[pool_start + int(name_cursor):][:len(entry.name)], entry.name)
		}
		name_cursor += u32(len(entry.name))
	}
	return required, .None
}

// encode_from_objects builds a canonical sorted image-tree manifest from an
// unordered list of Object_Spec paths using caller-supplied scratch slices
// (zero heap allocation). Output is identical regardless of input order, and
// remains untouched on any refusal.
encode_from_objects :: proc "contextless" (
	objects: []Object_Spec,
	nodes_scratch: []Draft_Node,
	entries_scratch: []Draft_Entry,
	output: []u8,
) -> (written: int, problem: Problem) {
	if len(nodes_scratch) < 1 {
		return 0, .Scratch_Too_Small
	}
	nodes_scratch[0] = {
		first_entry = NO_DRAFT_INDEX,
		entry_count = 0,
		parent_node = ROOT_PARENT,
		depth       = 0,
	}
	node_count: u32 = 1
	entry_count: u32 = 0
	total_names: u64 = 0

	// Insert every object path into the sorted draft tree.
	for &obj in objects {
		seg_count, path_problem, _, _ := store.object_path_validate(obj.path)
		if path_problem != .None {
			return 0, .Invalid_Path
		}
		current_node: u32 = ROOT_NODE
		iterator := store.object_path_iterator_make(obj.path)
		step := 0
		for segment in store.object_path_next(&iterator) {
			step += 1
			is_last := step == seg_count
			if is_reserved_boot_record(segment) {
				return 0, .Reserved_Name
			}

			// Search current_node's sorted linked list for segment.
			prev_idx: u32 = NO_DRAFT_INDEX
			cur_idx := nodes_scratch[current_node].first_entry
			found_idx: u32 = NO_DRAFT_INDEX
			for cur_idx != NO_DRAFT_INDEX {
				order := compare_bytes(entries_scratch[cur_idx].name, segment)
				if order == 0 {
					found_idx = cur_idx
					break
				}
				if order > 0 {
					break
				}
				prev_idx = cur_idx
				cur_idx = entries_scratch[cur_idx].next_in_node
			}

			if found_idx != NO_DRAFT_INDEX {
				existing := &entries_scratch[found_idx]
				if is_last {
					if existing.kind == .Object {
						return 0, .Duplicate_Name
					}
					return 0, .Path_Conflict
				}
				if existing.kind != .Tree {
					return 0, .Path_Conflict
				}
				current_node = existing.target_index
				continue
			}

			// Insert new entry before cur_idx.
			if int(entry_count) >= len(entries_scratch) {
				return 0, .Scratch_Too_Small
			}
			if entry_count >= ENTRY_CAPACITY {
				return 0, .Bad_Counts
			}
			total_names += u64(len(segment))
			if total_names > NAMES_BYTES_LIMIT {
				return 0, .Bad_Counts
			}
			new_entry_idx := entry_count
			entry_count += 1

			if is_last {
				entries_scratch[new_entry_idx] = {
					kind         = .Object,
					name         = segment,
					target_index = obj.image_entry_index,
					size         = obj.size,
					hash         = obj.hash,
					next_in_node = cur_idx,
				}
			} else {
				if int(node_count) >= len(nodes_scratch) {
					return 0, .Scratch_Too_Small
				}
				if node_count >= NODE_CAPACITY {
					return 0, .Bad_Counts
				}
				child_depth := int(nodes_scratch[current_node].depth) + 1
				if child_depth >= store.OBJECT_PATH_DEPTH_LIMIT {
					return 0, .Too_Deep
				}
				child_node_idx := node_count
				node_count += 1
				nodes_scratch[child_node_idx] = {
					first_entry = NO_DRAFT_INDEX,
					entry_count = 0,
					parent_node = current_node,
					depth       = u8(child_depth),
				}
				entries_scratch[new_entry_idx] = {
					kind         = .Tree,
					name         = segment,
					target_index = child_node_idx,
					size         = 0,
					hash         = {},
					next_in_node = cur_idx,
				}
				if prev_idx == NO_DRAFT_INDEX {
					nodes_scratch[current_node].first_entry = new_entry_idx
				} else {
					entries_scratch[prev_idx].next_in_node = new_entry_idx
				}
				nodes_scratch[current_node].entry_count += 1
				current_node = child_node_idx
				continue
			}

			if prev_idx == NO_DRAFT_INDEX {
				nodes_scratch[current_node].first_entry = new_entry_idx
			} else {
				entries_scratch[prev_idx].next_in_node = new_entry_idx
			}
			nodes_scratch[current_node].entry_count += 1
		}
	}

	required := encoded_size(node_count, entry_count, u32(total_names))
	if required == 0 {
		return 0, .Bad_Counts
	}
	if len(output) < required {
		return 0, .Truncated
	}

	// Assign canonical pre-order node indices via iterative DFS (depth <= 32).
	Dfs_Frame :: struct {
		next_entry: u32,
	}
	stack: [store.OBJECT_PATH_DEPTH_LIMIT + 1]Dfs_Frame
	stack_top := 0
	next_final: u32 = 0

	nodes_scratch[ROOT_NODE].final_index = next_final
	nodes_scratch[next_final].order_draft_index = ROOT_NODE
	next_final += 1
	stack[0] = {next_entry = nodes_scratch[ROOT_NODE].first_entry}
	stack_top = 1

	for stack_top > 0 {
		frame := &stack[stack_top - 1]
		if frame.next_entry == NO_DRAFT_INDEX {
			stack_top -= 1
			continue
		}
		entry := &entries_scratch[frame.next_entry]
		frame.next_entry = entry.next_in_node
		if entry.kind == .Tree {
			child_draft := entry.target_index
			nodes_scratch[child_draft].final_index = next_final
			nodes_scratch[next_final].order_draft_index = child_draft
			next_final += 1
			stack[stack_top] = {next_entry = nodes_scratch[child_draft].first_entry}
			stack_top += 1
		}
	}

	// Emit canonical binary bytes in pre-order.
	header := Header {
		magic       = MAGIC,
		version     = VERSION,
		node_count  = node_count,
		entry_count = entry_count,
		names_bytes = u32(total_names),
	}
	intrinsics.mem_copy_non_overlapping(raw_data(output), &header, HEADER_SIZE)

	nodes_start := HEADER_SIZE
	entries_start := nodes_start + int(node_count) * NODE_RECORD_SIZE
	pool_start := entries_start + int(entry_count) * ENTRY_RECORD_SIZE

	running_entry: u32 = 0
	name_cursor: u32 = 0
	for final_idx: u32 = 0; final_idx < node_count; final_idx += 1 {
		draft_idx := nodes_scratch[final_idx].order_draft_index
		draft := &nodes_scratch[draft_idx]
		final_parent := ROOT_PARENT
		if final_idx != ROOT_NODE {
			final_parent = nodes_scratch[draft.parent_node].final_index
		}
		node_record := Node_Record {
			first_entry = running_entry,
			entry_count = draft.entry_count,
			parent_node = final_parent,
			reserved    = 0,
		}
		intrinsics.mem_copy_non_overlapping(raw_data(output[nodes_start + int(final_idx) * NODE_RECORD_SIZE:]), &node_record, NODE_RECORD_SIZE)

		cur := draft.first_entry
		for cur != NO_DRAFT_INDEX {
			e := &entries_scratch[cur]
			target := e.target_index
			if e.kind == .Tree {
				target = nodes_scratch[e.target_index].final_index
			}
			entry_record := Entry_Record {
				kind         = u8(e.kind),
				name_length  = u8(len(e.name)),
				reserved_u16 = 0,
				name_offset  = name_cursor,
				target_index = target,
				reserved_u32 = 0,
				size         = e.size,
				hash         = e.hash,
			}
			intrinsics.mem_copy_non_overlapping(raw_data(output[entries_start + int(running_entry) * ENTRY_RECORD_SIZE:]), &entry_record, ENTRY_RECORD_SIZE)
			if len(e.name) > 0 {
				copy(output[pool_start + int(name_cursor):][:len(e.name)], e.name)
			}
			name_cursor += u32(len(e.name))
			running_entry += 1
			cur = e.next_in_node
		}
	}
	return required, .None
}

// node_find_entry performs O(log K) binary search for exact single-step name
// inside node_index of an already-validated manifest.
@(private = "file")
node_find_entry :: proc "contextless" (bytes: []u8, header: Header, pool_start: int, node_index: u32, name: string) -> (entry: Entry_Record, kind: Entry_Kind, found: bool) {
	node := read_node(bytes, node_index)
	low := u32(0)
	high := node.entry_count
	for low < high {
		mid := low + (high - low) / 2
		candidate := read_entry(bytes, header.node_count, node.first_entry + mid)
		candidate_name := entry_name_slice(bytes, pool_start, candidate)
		order := compare_bytes(candidate_name, name)
		if order == 0 {
			decoded_kind, ok := entry_kind_of_word(u64(candidate.kind))
			if !ok {
				return {}, .Object, false
			}
			return candidate, decoded_kind, true
		}
		if order < 0 {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return {}, .Object, false
}

// resolve_from_node walks a validated path from start_node inside a validated
// manifest, returning the final entry and its kind if present.
@(private = "file")
resolve_from_node :: proc "contextless" (bytes: []u8, header: Header, pool_start: int, start_node: u32, path: string) -> (entry: Entry_Record, kind: Entry_Kind, found: bool) {
	current := start_node
	iterator := store.object_path_iterator_make(path)
	segment, has_segment := store.object_path_next(&iterator)
	for has_segment {
		next_segment, has_next := store.object_path_next(&iterator)
		found_entry, found_kind, hit := node_find_entry(bytes, header, pool_start, current, segment)
		if !hit {
			return {}, .Object, false
		}
		if !has_next {
			return found_entry, found_kind, true
		}
		if found_kind != .Tree {
			return {}, .Object, false
		}
		current = found_entry.target_index
		segment = next_segment
		has_segment = true
	}
	return {}, .Object, false
}

// subtree_resolve validates manifest and path and returns the node index of
// the named subtree from ROOT_NODE. Use ROOT_NODE directly for the root tree.
subtree_resolve :: proc "contextless" (manifest: []u8, path: string) -> (node_index: u32, problem: Lookup_Problem, path_problem: store.Object_Path_Problem) {
	header, val_problem := validate(manifest)
	if val_problem != .None {
		return 0, .Manifest_Invalid, .None
	}
	_, p_problem, _, _ := store.object_path_validate(path)
	if p_problem != .None {
		return 0, .Bad_Path, p_problem
	}
	pool_start := name_pool_offset(header)
	entry, kind, found := resolve_from_node(manifest, header, pool_start, ROOT_NODE, path)
	if !found {
		return 0, .Not_Found, .None
	}
	if kind != .Tree {
		return 0, .Not_Found, .None
	}
	return entry.target_index, .None, .None
}

// lookup_in_grants validates manifest, path, and grants, then resolves path
// across every granted subtree:
//   - 0 object matches -> .Not_Found (or .Is_Subtree if a subtree matched);
//   - >1 object matches -> .Ambiguous, collecting up to len(ambiguity_out)
//     matching tree records and returning the true total match_count;
//   - 1 object match with has_expected_hash and mismatched hash -> .Hash_Mismatch
//     (maps to Another_Change_Came_First, never Data_Damaged);
//   - 1 object match (unpinned or matching hash) -> .None with Resolved_Object.
lookup_in_grants :: proc "contextless" (
	manifest: []u8,
	grants: []Subtree_Grant,
	path: string,
	has_expected_hash: bool,
	expected_hash: blake3.Hash,
	ambiguity_out: []Ambiguity_Match,
) -> (
	resolved: Resolved_Object,
	match_count: int,
	problem: Lookup_Problem,
	path_problem: store.Object_Path_Problem,
) {
	header, val_problem := validate(manifest)
	if val_problem != .None {
		return {}, 0, .Manifest_Invalid, .None
	}
	_, p_problem, _, _ := store.object_path_validate(path)
	if p_problem != .None {
		return {}, 0, .Bad_Path, p_problem
	}
	for grant in grants {
		if grant.root_node >= header.node_count {
			return {}, 0, .Bad_Grant, .None
		}
	}

	pool_start := name_pool_offset(header)
	first_match: Resolved_Object
	saw_subtree := false

	for grant, grant_index in grants {
		entry, kind, found := resolve_from_node(manifest, header, pool_start, grant.root_node, path)
		if !found && grant.root_node != ROOT_NODE && len(grant.tree_name) > 0 {
			// Accept a path qualified by this grant's own subtree prefix
			// (for example "pointer_themes/posy" against a "pointer_themes"
			// grant) without letting the lookup escape the granted subtree.
			if path == grant.tree_name {
				saw_subtree = true
				continue
			}
			prefix_len := len(grant.tree_name)
			if len(path) > prefix_len + 1 && path[:prefix_len] == grant.tree_name && path[prefix_len] == '/' {
				entry, kind, found = resolve_from_node(manifest, header, pool_start, grant.root_node, path[prefix_len + 1:])
			}
		}
		if !found {
			continue
		}
		switch kind {
		case .Tree:
			saw_subtree = true
		case .Object:
			if match_count < len(ambiguity_out) {
				ambiguity_out[match_count] = {
					grant_index       = grant_index,
					tree_name         = grant.tree_name,
					image_entry_index = entry.target_index,
					size              = entry.size,
					hash              = entry.hash,
				}
			}
			if match_count == 0 {
				first_match = {
					image_entry_index = entry.target_index,
					size              = entry.size,
					hash              = entry.hash,
					grant_index       = grant_index,
				}
			}
			match_count += 1
		}
	}

	if match_count > 1 {
		return {}, match_count, .Ambiguous, .None
	}
	if match_count == 0 {
		if saw_subtree {
			return {}, 0, .Is_Subtree, .None
		}
		return {}, 0, .Not_Found, .None
	}

	// Single match: clear the temporary first ambiguity slot so callers never
	// observe stale records on a non-ambiguous lookup.
	if len(ambiguity_out) > 0 {
		ambiguity_out[0] = {}
	}
	if has_expected_hash && first_match.hash != expected_hash {
		return first_match, 1, .Hash_Mismatch, .None
	}
	return first_match, 1, .None, .None
}

// node_entry_count returns the entry count of node_index inside a validated
// manifest, or false if the manifest is invalid or node_index is out of range.
node_entry_count :: proc "contextless" (manifest: []u8, node_index: u32) -> (count: int, ok: bool) {
	header, problem := validate(manifest)
	if problem != .None || node_index >= header.node_count {
		return 0, false
	}
	node := read_node(manifest, node_index)
	return int(node.entry_count), true
}

// node_entry_at returns the index-th sorted entry of node_index inside a
// validated manifest.
node_entry_at :: proc "contextless" (manifest: []u8, node_index: u32, index: int) -> (listed: Listed_Entry, ok: bool) {
	header, problem := validate(manifest)
	if problem != .None || node_index >= header.node_count || index < 0 {
		return {}, false
	}
	node := read_node(manifest, node_index)
	if u32(index) >= node.entry_count {
		return {}, false
	}
	entry := read_entry(manifest, header.node_count, node.first_entry + u32(index))
	kind, kind_ok := entry_kind_of_word(u64(entry.kind))
	if !kind_ok {
		return {}, false
	}
	pool_start := name_pool_offset(header)
	return {
		kind         = kind,
		name         = entry_name_slice(manifest, pool_start, entry),
		target_index = entry.target_index,
		size         = entry.size,
		hash         = entry.hash,
	}, true
}
