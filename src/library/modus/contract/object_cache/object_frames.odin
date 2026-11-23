// The frames of an object of any size, the proof of a frame, and the tree
// of frames (src/md/features/recipes.md, "Objects of any size").
//
// An object travels in frames of FRAME_PAYLOAD_BYTES. A blob keeps its one
// name, the BLAKE3 hash of its whole content: BLAKE3 is a tree hash, and a
// frame of a power of two of chunks is a node of its tree, so a frame is
// checked against the hash of the whole blob with the chaining values of
// the siblings on its path (the verified streaming of Bao). The tree above
// the frames has the shape of the tree of BLAKE3: the left child of a node
// of m frames holds the largest power of two of frames less than m.
//
// The parents of the tree of frames are numbered in pre-order, the root 0:
// the outboard of a blob holds the two child values of each parent at its
// number, so the proof of a frame is one read for each level.
package object_cache

import "modus:contract/blake3"

// The bytes of one frame: every frame of an object but the last holds
// this many. The bound protects the memory of each side of a connection.
FRAME_PAYLOAD_BYTES :: 1 << 20

// The chunks of BLAKE3 in one frame: a power of two, so a frame is a node
// of the tree of BLAKE3.
CHUNKS_PER_FRAME :: FRAME_PAYLOAD_BYTES / blake3.CHUNK_SIZE

// The most levels of a proof: 32 levels hold 2^32 frames.
MAX_PROOF_DEPTH :: 32

// The most frames of one object.
MAX_FRAME_COUNT :: u64(1) << MAX_PROOF_DEPTH

// The largest object of the protocol: 4 PiB. The bound that holds in
// practice is the free space of the disk of the receiver.
MAX_OBJECT_BYTES :: u64(FRAME_PAYLOAD_BYTES) << MAX_PROOF_DEPTH

// One level of a proof: the chaining value of a sibling.
PROOF_ENTRY_SIZE :: blake3.HASH_SIZE

// One entry of an outboard: the chaining values of the two children of a
// parent, left then right.
OUTBOARD_ENTRY_SIZE :: 2 * blake3.HASH_SIZE

#assert(FRAME_PAYLOAD_BYTES % blake3.CHUNK_SIZE == 0)
#assert(CHUNKS_PER_FRAME & (CHUNKS_PER_FRAME - 1) == 0)
#assert(MAX_TREE_PAYLOAD_BYTES <= FRAME_PAYLOAD_BYTES)

// The path of a frame from the root of the tree of frames down to it.
Frame_Path :: struct {
	// The levels: the length of the proof, in entries.
	depth:        int,
	// From the root down: the pre-order number of each parent on the path.
	parent_index: [MAX_PROOF_DEPTH]u64,
	// From the root down: true when the frame is in the left child.
	in_left:      [MAX_PROOF_DEPTH]bool,
}

// One parent of the tree of frames that the builder joined: its pre-order
// number and the chaining values of its children.
Frame_Parent :: struct {
	index: u64,
	left:  blake3.Chaining_Value,
	right: blake3.Chaining_Value,
}

// The tree of frames of a blob, built one frame at a time in order. It
// holds at most MAX_PROOF_DEPTH + 1 chaining values, whatever the size of
// the blob.
Frame_Tree_Builder :: struct {
	object_size:  u64,
	frame_bytes:  u64,
	frame_count:  u64,
	next_frame:   u64,
	stack_value:  [MAX_PROOF_DEPTH + 1]blake3.Chaining_Value,
	stack_first:  [MAX_PROOF_DEPTH + 1]u64,
	stack_frames: [MAX_PROOF_DEPTH + 1]u64,
	stack_depth:  int,
	// The BLAKE3 hash of the whole blob, once finished.
	root:         blake3.Hash,
	finished:     bool,
}

// object_offset_to_frame_index checks that offset is aligned to
// FRAME_PAYLOAD_BYTES and within MAX_OBJECT_BYTES, and gives its frame index.
object_offset_to_frame_index :: proc "contextless" (offset: u64) -> (frame_index: u64, ok: bool) {
	if offset >= MAX_OBJECT_BYTES || offset % FRAME_PAYLOAD_BYTES != 0 {
		return 0, false
	}
	return offset / FRAME_PAYLOAD_BYTES, true
}

// object_frame_count gives the frames of an object of object_size bytes:
// the empty object has one frame of 0 bytes. It refuses a size past
// MAX_OBJECT_BYTES.
object_frame_count :: proc "contextless" (object_size: u64) -> (count: u64, ok: bool) {
	if object_size > MAX_OBJECT_BYTES {
		return 0, false
	}
	return frame_count_with(object_size, FRAME_PAYLOAD_BYTES), true
}

// object_frame_length gives the bytes of frame frame_index of an object of
// object_size bytes. It refuses a frame past the end.
object_frame_length :: proc "contextless" (object_size, frame_index: u64) -> (length: u64, ok: bool) {
	if object_size > MAX_OBJECT_BYTES {
		return 0, false
	}
	return frame_length_with(object_size, frame_index, FRAME_PAYLOAD_BYTES)
}

// object_outboard_bytes gives the size of the outboard of an object: one
// entry for each parent of its tree of frames, none for one frame.
object_outboard_bytes :: proc "contextless" (object_size: u64) -> (bytes: u64, ok: bool) {
	count := object_frame_count(object_size) or_return
	return (count - 1) * OUTBOARD_ENTRY_SIZE, true
}

// object_frame_path gives the path of a frame in the tree of an object of
// frame_count frames. It refuses a frame past the end.
object_frame_path :: proc "contextless" (frame_count, frame_index: u64) -> (path: Frame_Path, ok: bool) {
	if frame_count == 0 || frame_count > MAX_FRAME_COUNT || frame_index >= frame_count {
		return {}, false
	}
	first: u64 = 0
	size := frame_count
	index: u64 = 0
	for size > 1 {
		left := left_frames(size)
		path.parent_index[path.depth] = index
		if frame_index < first + left {
			path.in_left[path.depth] = true
			// The left child follows its parent in pre-order.
			index += 1
			size = left
		} else {
			path.in_left[path.depth] = false
			// The right child follows the left subtree, which holds
			// left - 1 parents.
			index += left
			first += left
			size -= left
		}
		path.depth += 1
	}
	return path, true
}

// object_frame_verify checks one frame of an object against the hash of the
// whole object: the frame has the length that its index demands, the proof
// has one entry for each level of its path, and the frame joined with the
// proof gives the hash. A frame of an object of one frame has no proof and
// is checked whole (verify_object_content).
object_frame_verify :: proc "contextless" (
	object_kind: Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
	frame_index: u64,
	proof: []u8,
	frame: []u8,
) -> Substitution_Decision {
	return frame_verify_with(object_kind, object_hash, object_size, frame_index, proof, frame, FRAME_PAYLOAD_BYTES)
}

// frame_tree_builder_start starts the tree of frames of a blob of
// object_size bytes. A tree is one frame and is checked with tree_hash.
frame_tree_builder_start :: proc "contextless" (object_size: u64) -> (builder: Frame_Tree_Builder, ok: bool) {
	if object_size > MAX_OBJECT_BYTES {
		return {}, false
	}
	return frame_tree_builder_start_with(object_size, FRAME_PAYLOAD_BYTES), true
}

// frame_tree_builder_add adds the next frame. It refuses a frame of
// another length than its index demands, and a frame after the last. The
// parents that the frame completes are written to parents, in the order of
// their join; the last frame completes the root, whose hash is then root.
frame_tree_builder_add :: proc "contextless" (
	builder: ^Frame_Tree_Builder,
	frame: []u8,
	parents: ^[MAX_PROOF_DEPTH]Frame_Parent,
) -> (parent_count: int, ok: bool) {
	if builder == nil || builder.finished || builder.frame_count == 0 {
		return 0, false
	}
	length, length_ok := frame_length_with(builder.object_size, builder.next_frame, builder.frame_bytes)
	if !length_ok || u64(len(frame)) != length {
		return 0, false
	}
	if builder.frame_count == 1 {
		builder.root = blake3.hash(frame)
		builder.next_frame = 1
		builder.finished = true
		return 0, true
	}
	chunks := builder.frame_bytes / blake3.CHUNK_SIZE
	value := blake3.subtree_chaining_value(frame, builder.next_frame * chunks)
	builder_push(builder, value, builder.next_frame, 1)
	builder.next_frame += 1
	// Two subtrees of one size side by side are an aligned power of two of
	// frames inside the object: a node of its tree.
	for builder.stack_depth >= 2 && builder.stack_frames[builder.stack_depth - 1] == builder.stack_frames[builder.stack_depth - 2] {
		builder_join(builder, parents, &parent_count) or_return
	}
	if builder.next_frame == builder.frame_count {
		// The right edge: each subtree left on the stack joins the one
		// before it, and the last join is the root.
		for builder.stack_depth >= 2 {
			builder_join(builder, parents, &parent_count) or_return
		}
		if builder.stack_depth != 0 {
			return 0, false
		}
		builder.finished = true
	}
	return parent_count, true
}

// frame_parent_entry gives the outboard entry of a parent: the chaining
// value of its left child, then of its right child.
frame_parent_entry :: proc "contextless" (parent: Frame_Parent) -> (entry: [OUTBOARD_ENTRY_SIZE]u8) {
	left := blake3.chaining_value_bytes(parent.left)
	right := blake3.chaining_value_bytes(parent.right)
	copy(entry[:blake3.HASH_SIZE], left[:])
	copy(entry[blake3.HASH_SIZE:], right[:])
	return entry
}

// frame_proof_entry gives the level of a proof that an outboard entry on
// the path of a frame holds: the child that is not on the path.
frame_proof_entry :: proc "contextless" (entry: [OUTBOARD_ENTRY_SIZE]u8, in_left: bool) -> (sibling: [PROOF_ENTRY_SIZE]u8) {
	source := entry
	if in_left {
		copy(sibling[:], source[blake3.HASH_SIZE:])
	} else {
		copy(sibling[:], source[:blake3.HASH_SIZE])
	}
	return sibling
}

// The forms with the size of a frame as a parameter: the host tests use
// frames of one chunk, so a small input has a tree of many frames.

@(private)
frame_count_with :: proc "contextless" (object_size, frame_bytes: u64) -> u64 {
	if object_size == 0 {
		return 1
	}
	count := object_size / frame_bytes
	if object_size % frame_bytes != 0 {
		count += 1
	}
	return count
}

@(private)
frame_length_with :: proc "contextless" (object_size, frame_index, frame_bytes: u64) -> (length: u64, ok: bool) {
	count := frame_count_with(object_size, frame_bytes)
	if frame_index >= count {
		return 0, false
	}
	if frame_index < count - 1 {
		return frame_bytes, true
	}
	return object_size - frame_index * frame_bytes, true
}

// left_frames gives the frames of the left child of a node of frames
// frames (at least 2): the largest power of two less than frames.
@(private)
left_frames :: proc "contextless" (frames: u64) -> u64 {
	power: u64 = 1
	for power * 2 < frames {
		power *= 2
	}
	return power
}

// frame_parent_index gives the pre-order number of the parent that covers
// frames frames from first_frame, or false when no parent covers them.
@(private)
frame_parent_index :: proc "contextless" (frame_count, first_frame, frames: u64) -> (index: u64, ok: bool) {
	low: u64 = 0
	size := frame_count
	for size > 1 {
		if low == first_frame && size == frames {
			return index, true
		}
		left := left_frames(size)
		if first_frame < low + left {
			index += 1
			size = left
		} else {
			index += left
			low += left
			size -= left
		}
	}
	return 0, false
}

@(private)
frame_tree_builder_start_with :: proc "contextless" (object_size, frame_bytes: u64) -> Frame_Tree_Builder {
	return Frame_Tree_Builder {
		object_size = object_size,
		frame_bytes = frame_bytes,
		frame_count = frame_count_with(object_size, frame_bytes),
	}
}

@(private)
builder_push :: proc "contextless" (builder: ^Frame_Tree_Builder, value: blake3.Chaining_Value, first_frame, frames: u64) {
	builder.stack_value[builder.stack_depth] = value
	builder.stack_first[builder.stack_depth] = first_frame
	builder.stack_frames[builder.stack_depth] = frames
	builder.stack_depth += 1
}

// builder_join joins the two subtrees at the top of the stack into their
// parent, and writes the parent. The parent of the whole object is the root.
@(private)
builder_join :: proc "contextless" (builder: ^Frame_Tree_Builder, parents: ^[MAX_PROOF_DEPTH]Frame_Parent, parent_count: ^int) -> bool {
	if parent_count^ >= MAX_PROOF_DEPTH {
		return false
	}
	right := builder.stack_value[builder.stack_depth - 1]
	right_frames := builder.stack_frames[builder.stack_depth - 1]
	left := builder.stack_value[builder.stack_depth - 2]
	first := builder.stack_first[builder.stack_depth - 2]
	frames := builder.stack_frames[builder.stack_depth - 2] + right_frames
	builder.stack_depth -= 2
	index, index_ok := frame_parent_index(builder.frame_count, first, frames)
	if !index_ok {
		return false
	}
	parents[parent_count^] = Frame_Parent {
		index = index,
		left  = left,
		right = right,
	}
	parent_count^ += 1
	if first == 0 && frames == builder.frame_count {
		builder.root = blake3.root_of_children(left, right)
		return true
	}
	builder_push(builder, blake3.parent_chaining_value(left, right), first, frames)
	return true
}

@(private)
frame_verify_with :: proc "contextless" (
	object_kind: Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
	frame_index: u64,
	proof: []u8,
	frame: []u8,
	frame_bytes: u64,
) -> Substitution_Decision {
	if hash_is_zero(object_hash) {
		return .Refuse_Malformed
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(object_kind))
	if !kind_ok {
		return .Refuse_Malformed
	}
	if object_size > payload_bound_for_kind(checked_kind) {
		return .Refuse_Malformed
	}
	count := frame_count_with(object_size, frame_bytes)
	length, length_ok := frame_length_with(object_size, frame_index, frame_bytes)
	if !length_ok || u64(len(frame)) != length {
		return .Refuse_Malformed
	}
	path, path_ok := object_frame_path(count, frame_index)
	if !path_ok || len(proof) != path.depth * PROOF_ENTRY_SIZE {
		return .Refuse_Malformed
	}
	if count == 1 {
		return verify_object_content(checked_kind, object_hash, frame)
	}
	// A tree is one frame: its hash is not the tree of BLAKE3 of its bytes.
	switch checked_kind {
	case .Tree:
		return .Refuse_Malformed
	case .Blob:
	}
	value := blake3.subtree_chaining_value(frame, frame_index * (frame_bytes / blake3.CHUNK_SIZE))
	for level := path.depth - 1; level >= 1; level -= 1 {
		sibling := proof_level_value(proof, level)
		if path.in_left[level] {
			value = blake3.parent_chaining_value(value, sibling)
		} else {
			value = blake3.parent_chaining_value(sibling, value)
		}
	}
	top_sibling := proof_level_value(proof, 0)
	root: blake3.Hash
	if path.in_left[0] {
		root = blake3.root_of_children(value, top_sibling)
	} else {
		root = blake3.root_of_children(top_sibling, value)
	}
	if hashes_equal_constant_time(root, object_hash) {
		return .Trust_By_Hash
	}
	return .Refuse_Hash_Mismatch
}

@(private)
proof_level_value :: proc "contextless" (proof: []u8, level: int) -> blake3.Chaining_Value {
	bytes: [PROOF_ENTRY_SIZE]u8
	copy(bytes[:], proof[level * PROOF_ENTRY_SIZE:(level + 1) * PROOF_ENTRY_SIZE])
	return blake3.chaining_value_of_bytes(bytes)
}
