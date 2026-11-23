// Whole-store immutable snapshot history DAG and atomic rollback contract
// (docs/STORAGE.md).
//
// Each commit records an immutable whole-store snapshot with a monotonic
// snapshot_id (>= 1), a parent_id pointing to the active snapshot before the
// commit, a timestamp, and a canonical tree_hash computed over every live
// (object_name, object_version, content_hash) entry via modus:contract/tree_hash.
//
// Atomic rollback moves active_snapshot_id to any historical snapshot without
// erasing newer snapshots; a subsequent commit allocates highest_snapshot_id + 1
// with parent_id equal to the rollback target, preserving complete history.
//
// The memory of the history is the memory of its caller (docs/PROPERTIES.md,
// "14. Memory is supplied by the caller"): a table of snapshot records and
// one pool of objects that the snapshots share, each snapshot a run of the
// pool. So the count of snapshots and of the objects of one snapshot is the
// memory that the caller gives, and a full table or pool is a refusal that
// changes nothing. One snapshot holds at most tree_hash.MAX_TREE_ENTRIES
// objects: its hash is the hash of one tree node.
package store_history

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/tree_hash"

// Maximum live objects recorded in one whole-store snapshot: the entries of
// one canonical tree node.
MAX_OBJECTS_PER_SNAPSHOT :: tree_hash.MAX_TREE_ENTRIES

// Maximum UTF-8 byte length of one object name (matches tree_hash).
OBJECT_NAME_CAPACITY :: tree_hash.ENTRY_NAME_CAPACITY

// Domain separation string binding (object_version, content_hash) into a leaf
// hash before canonical tree encoding.
SNAPSHOT_OBJECT_DOMAIN :: "modus store snapshot object v1"

// Closed set of change kinds produced by snapshot_diff.
Diff_Change_Kind :: enum u8 {
	Added   = 1,
	Changed = 2,
	Removed = 3,
}

// Closed set of refusals for Store_History operations.
History_Refusal :: enum u8 {
	None                = 0,
	History_Full        = 1, // The table of snapshot records that the caller gave is full.
	Too_Many_Objects    = 2, // More objects than one tree node holds, or than the pool has room for.
	Empty_Name          = 3,
	Name_Too_Long       = 4,
	Invalid_Name        = 5,
	Duplicate_Name      = 6,
	Zero_Object_Version = 7,
	Backwards_Timestamp = 8,
	Zero_Snapshot_Id    = 9,
	Unknown_Snapshot    = 10,
	Output_Too_Small    = 11, // A diff output, or the workspace of the encoded tree of a commit, is too small.
}

// Caller-supplied object entry passed to snapshot_commit.
Snapshot_Object_Input :: struct {
	name:           string,
	object_version: u64,
	content_hash:   blake3.Hash,
}

// Canonical immutable object record of a snapshot, in the pool of objects.
Snapshot_Object :: struct {
	name_length:    u8,
	name:           [OBJECT_NAME_CAPACITY]u8,
	object_version: u64,
	content_hash:   blake3.Hash,
}

// One immutable whole-store snapshot in the DAG/linear snapshot log. Its
// objects are objects[object_first:][:object_count] of the pool.
Snapshot_Record :: struct {
	snapshot_id:     u64,
	parent_id:       u64,
	committed_at_ms: u64,
	tree_hash:       blake3.Hash,
	object_first:    int,
	object_count:    int,
}

// One object difference between two whole-store snapshots.
Snapshot_Diff_Entry :: struct {
	kind:         Diff_Change_Kind,
	name_length:  u8,
	name:         [OBJECT_NAME_CAPACITY]u8,
	from_version: u64,
	to_version:   u64,
	from_hash:    blake3.Hash,
	to_hash:      blake3.Hash,
}

// A whole-store snapshot history with monotonic IDs and atomic rollback,
// in the memory of its caller.
Store_History :: struct {
	snapshots:            []Snapshot_Record, // The table that the caller gave: snapshots[:snapshot_count] in use.
	objects:              []Snapshot_Object, // The pool that the caller gave: objects[:object_count] in use.
	snapshot_count:       int,
	object_count:         int,
	highest_snapshot_id:  u64,
	active_snapshot_id:   u64,
	last_committed_at_ms: u64,
}

// diff_change_kind_of_word converts a transport word to Diff_Change_Kind.
diff_change_kind_of_word :: proc "contextless" (word: u64) -> (kind: Diff_Change_Kind, ok: bool) {
	return enum_word.member_of_word(Diff_Change_Kind, word)
}

// history_refusal_of_word converts a transport word to History_Refusal.
history_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: History_Refusal, ok: bool) {
	return enum_word.member_of_word(History_Refusal, word)
}

// history_init gives a history the memory of its snapshots and of its
// objects, and empties it.
history_init :: proc "contextless" (history: ^Store_History, snapshots: []Snapshot_Record, objects: []Snapshot_Object) {
	history^ = {snapshots = snapshots, objects = objects}
}

// snapshot_objects gives the objects of a snapshot, in the order of their
// names.
snapshot_objects :: proc "contextless" (history: ^Store_History, record: ^Snapshot_Record) -> []Snapshot_Object {
	return history.objects[record.object_first:][:record.object_count]
}

// snapshot_tree_bytes gives the bytes of the canonical tree of a snapshot
// of these objects: the size of the workspace that snapshot_commit needs.
snapshot_tree_bytes :: proc "contextless" (objects: []Snapshot_Object_Input) -> int {
	size := tree_hash.HEADER_SIZE
	for item in objects {
		size += tree_hash.ENTRY_FIXED_SIZE + min(len(item.name), OBJECT_NAME_CAPACITY)
	}
	return size
}

// snapshot_object_name returns the active UTF-8 slice of a Snapshot_Object name.
snapshot_object_name :: proc "contextless" (object: ^Snapshot_Object) -> string {
	length := min(int(object.name_length), OBJECT_NAME_CAPACITY)
	return string(object.name[:length])
}

// snapshot_diff_entry_name returns the active UTF-8 slice of a Snapshot_Diff_Entry name.
snapshot_diff_entry_name :: proc "contextless" (entry: ^Snapshot_Diff_Entry) -> string {
	length := min(int(entry.name_length), OBJECT_NAME_CAPACITY)
	return string(entry.name[:length])
}

@(private)
map_tree_name_refusal :: proc "contextless" (refusal: tree_hash.Tree_Refusal) -> History_Refusal {
	#partial switch refusal {
	case .None:
		return .None
	case .Empty_Name:
		return .Empty_Name
	case .Name_Too_Long:
		return .Name_Too_Long
	case:
		return .Invalid_Name
	}
}

@(private)
compute_versioned_object_hash :: proc "contextless" (object_version: u64, content_hash: blake3.Hash) -> blake3.Hash {
	payload: [8 + blake3.HASH_SIZE]u8
	byte_order.write_u64_big_endian(payload[:], 0, object_version)
	ch := content_hash
	copy(payload[8:], ch[:])
	return blake3.derive_key(SNAPSHOT_OBJECT_DOMAIN, payload[:])
}

@(private)
object_name_bytes :: #force_inline proc "contextless" (object: ^Snapshot_Object) -> []u8 {
	return object.name[:object.name_length]
}

// snapshot_find locates an immutable Snapshot_Record by snapshot_id using
// binary search over monotonically ordered IDs.
snapshot_find :: proc "contextless" (
	history: ^Store_History,
	snapshot_id: u64,
) -> (record: ^Snapshot_Record, refusal: History_Refusal) {
	if snapshot_id == 0 {
		return nil, .Zero_Snapshot_Id
	}
	low := 0
	high := history.snapshot_count
	for low < high {
		mid := low + (high - low) / 2
		candidate := history.snapshots[mid].snapshot_id
		if candidate == snapshot_id {
			return &history.snapshots[mid], .None
		}
		if candidate < snapshot_id {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return nil, .Unknown_Snapshot
}

// snapshot_commit validates all input entries, checks timestamp monotonicity
// and capacity bounds, sorts entries canonically by UTF-8 name order into the
// pool, encodes the canonical tree in workspace (snapshot_tree_bytes), computes
// the deterministic whole-store tree_hash, and appends one immutable snapshot.
// Any refusal leaves the history unchanged: the objects of a refused commit
// sit past object_count, where the next commit writes over them.
snapshot_commit :: proc "contextless" (
	history: ^Store_History,
	objects: []Snapshot_Object_Input,
	now_ms: u64,
	workspace: []u8,
) -> (snapshot_id: u64, root_hash: blake3.Hash, refusal: History_Refusal) {
	if history.snapshot_count >= len(history.snapshots) {
		return 0, {}, .History_Full
	}
	if len(objects) > MAX_OBJECTS_PER_SNAPSHOT || len(objects) > len(history.objects) - history.object_count {
		return 0, {}, .Too_Many_Objects
	}
	if history.snapshot_count > 0 && now_ms < history.last_committed_at_ms {
		return 0, {}, .Backwards_Timestamp
	}
	sorted := history.objects[history.object_count:][:len(objects)]
	sorted_count := 0

	// Validate each input object and insertion-sort into canonical UTF-8 byte order.
	for item in objects {
		name_bytes := transmute([]u8)item.name
		if name_refusal := map_tree_name_refusal(tree_hash.tree_name_validate(name_bytes)); name_refusal != .None {
			return 0, {}, name_refusal
		}
		if item.object_version == 0 {
			return 0, {}, .Zero_Object_Version
		}

		// Binary search insertion position to detect duplicates early.
		low := 0
		high := sorted_count
		for low < high {
			mid := low + (high - low) / 2
			order := tree_hash.compare_name_bytes(object_name_bytes(&sorted[mid]), name_bytes)
			if order == 0 {
				return 0, {}, .Duplicate_Name
			}
			if order < 0 {
				low = mid + 1
			} else {
				high = mid
			}
		}

		// Shift tail up by one slot to maintain sorted order.
		for move := sorted_count; move > low; move -= 1 {
			sorted[move] = sorted[move - 1]
		}
		entry: Snapshot_Object
		entry.name_length = u8(len(name_bytes))
		copy(entry.name[:len(name_bytes)], name_bytes)
		entry.object_version = item.object_version
		entry.content_hash = item.content_hash
		sorted[low] = entry
		sorted_count += 1
	}

	// The canonical tree over (name, versioned_object_hash), written one
	// entry at a time into the workspace of the caller.
	required := snapshot_tree_bytes(objects)
	if len(workspace) < required {
		return 0, {}, .Output_Too_Small
	}
	magic := tree_hash.HEADER_MAGIC
	copy(workspace[0:8], magic[:])
	byte_order.write_u32_little_endian(workspace, 8, u32(sorted_count))
	byte_order.write_u32_little_endian(workspace, 12, 0)
	offset := tree_hash.HEADER_SIZE
	for &object in sorted {
		leaf_hash := compute_versioned_object_hash(object.object_version, object.content_hash)
		name_length := int(object.name_length)
		workspace[offset] = u8(tree_hash.Tree_Entry_Kind.Object)
		workspace[offset + 1] = object.name_length
		copy(workspace[offset + 2:][:name_length], object.name[:name_length])
		copy(workspace[offset + 2 + name_length:][:blake3.HASH_SIZE], leaf_hash[:])
		offset += tree_hash.ENTRY_FIXED_SIZE + name_length
	}
	computed_hash, hash_refusal := tree_hash.tree_hash(workspace[:offset])
	if hash_refusal != .None {
		return 0, {}, map_tree_name_refusal(hash_refusal)
	}

	// Commit atomically only after every validation and hash step succeeded.
	new_id := history.highest_snapshot_id + 1
	history.snapshots[history.snapshot_count] = Snapshot_Record {
		snapshot_id     = new_id,
		parent_id       = history.active_snapshot_id,
		committed_at_ms = now_ms,
		tree_hash       = computed_hash,
		object_first    = history.object_count,
		object_count    = sorted_count,
	}
	history.snapshot_count += 1
	history.object_count += sorted_count
	history.highest_snapshot_id = new_id
	history.active_snapshot_id = new_id
	history.last_committed_at_ms = now_ms
	return new_id, computed_hash, .None
}

// snapshot_lookup_object looks up an object's exact version and content hash
// as of historical snapshot snapshot_id in O(log N) binary search.
snapshot_lookup_object :: proc "contextless" (
	history: ^Store_History,
	snapshot_id: u64,
	name: string,
) -> (object: Snapshot_Object, found: bool, refusal: History_Refusal) {
	record, find_refusal := snapshot_find(history, snapshot_id)
	if find_refusal != .None {
		return {}, false, find_refusal
	}
	name_bytes := transmute([]u8)name
	if name_refusal := map_tree_name_refusal(tree_hash.tree_name_validate(name_bytes)); name_refusal != .None {
		return {}, false, name_refusal
	}
	items := snapshot_objects(history, record)
	low := 0
	high := len(items)
	for low < high {
		mid := low + (high - low) / 2
		order := tree_hash.compare_name_bytes(object_name_bytes(&items[mid]), name_bytes)
		if order == 0 {
			return items[mid], true, .None
		}
		if order < 0 {
			low = mid + 1
		} else {
			high = mid
		}
	}
	return {}, false, .None
}

// snapshot_rollback atomically moves active_snapshot_id back to
// target_snapshot_id without erasing newer snapshots or lowering
// highest_snapshot_id. Refuses zero or unknown IDs with zero mutation.
snapshot_rollback :: proc "contextless" (
	history: ^Store_History,
	target_snapshot_id: u64,
) -> History_Refusal {
	if _, find_refusal := snapshot_find(history, target_snapshot_id); find_refusal != .None {
		return find_refusal
	}
	history.active_snapshot_id = target_snapshot_id
	return .None
}

@(private)
diff_entry_of :: proc "contextless" (kind: Diff_Change_Kind, from: ^Snapshot_Object, to: ^Snapshot_Object) -> (entry: Snapshot_Diff_Entry) {
	entry.kind = kind
	named := to != nil ? to : from
	entry.name_length = named.name_length
	entry.name = named.name
	if from != nil {
		entry.from_version, entry.from_hash = from.object_version, from.content_hash
	}
	if to != nil {
		entry.to_version, entry.to_hash = to.object_version, to.content_hash
	}
	return entry
}

// snapshot_diff computes the sorted added/changed/removed object list
// transforming snapshot from_id into snapshot to_id, from the change
// `first` on: a caller with a small output reads the changes in pages, each
// page from the count that the page before gave. It gives the count of the
// changes of the page. A change past the output is left for the next page;
// `total` is the count of every change. A first past the total gives 0.
snapshot_diff :: proc "contextless" (
	history: ^Store_History,
	from_id: u64,
	to_id: u64,
	changes_out: []Snapshot_Diff_Entry,
	first: int = 0,
) -> (count: int, total: int, refusal: History_Refusal) {
	from_record, from_refusal := snapshot_find(history, from_id)
	if from_refusal != .None {
		return 0, 0, from_refusal
	}
	to_record, to_refusal := snapshot_find(history, to_id)
	if to_refusal != .None {
		return 0, 0, to_refusal
	}
	if first < 0 {
		return 0, 0, .Output_Too_Small
	}
	from_items := snapshot_objects(history, from_record)
	to_items := snapshot_objects(history, to_record)

	emit :: proc "contextless" (changes_out: []Snapshot_Diff_Entry, first: int, total: ^int, count: ^int, entry: Snapshot_Diff_Entry) {
		if total^ >= first && count^ < len(changes_out) {
			changes_out[count^] = entry
			count^ += 1
		}
		total^ += 1
	}
	i, j := 0, 0
	for i < len(from_items) || j < len(to_items) {
		order: int
		switch {
		case i == len(from_items):
			order = 1
		case j == len(to_items):
			order = -1
		case:
			order = tree_hash.compare_name_bytes(object_name_bytes(&from_items[i]), object_name_bytes(&to_items[j]))
		}
		if order < 0 {
			emit(changes_out, first, &total, &count, diff_entry_of(.Removed, &from_items[i], nil))
			i += 1
		} else if order > 0 {
			emit(changes_out, first, &total, &count, diff_entry_of(.Added, nil, &to_items[j]))
			j += 1
		} else {
			if from_items[i].object_version != to_items[j].object_version || from_items[i].content_hash != to_items[j].content_hash {
				emit(changes_out, first, &total, &count, diff_entry_of(.Changed, &from_items[i], &to_items[j]))
			}
			i += 1
			j += 1
		}
	}
	return count, total, .None
}
