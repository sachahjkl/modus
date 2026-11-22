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
package store_history

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/tree_hash"

// Maximum immutable snapshots stored in one bounded Store_History log.
MAX_SNAPSHOTS :: 64

// Maximum live objects recorded in one whole-store snapshot.
MAX_OBJECTS_PER_SNAPSHOT :: 128

// Maximum UTF-8 byte length of one object name (matches tree_hash).
OBJECT_NAME_CAPACITY :: tree_hash.ENTRY_NAME_CAPACITY

// Exact byte buffer size needed to encode MAX_OBJECTS_PER_SNAPSHOT tree entries.
MAX_SNAPSHOT_TREE_BYTES :: tree_hash.HEADER_SIZE + MAX_OBJECTS_PER_SNAPSHOT * tree_hash.ENTRY_SIZE

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
	History_Full        = 1,
	Too_Many_Objects    = 2,
	Empty_Name          = 3,
	Name_Too_Long       = 4,
	Invalid_Name        = 5,
	Duplicate_Name      = 6,
	Zero_Object_Version = 7,
	Backwards_Timestamp = 8,
	Zero_Snapshot_Id    = 9,
	Unknown_Snapshot    = 10,
	Output_Too_Small    = 11,
}

// Caller-supplied object entry passed to snapshot_commit.
Snapshot_Object_Input :: struct {
	name:           string,
	object_version: u64,
	content_hash:   blake3.Hash,
}

// Canonical immutable object record stored inside a Snapshot_Record.
Snapshot_Object :: struct {
	name_length:    u8,
	name:           [OBJECT_NAME_CAPACITY]u8,
	object_version: u64,
	content_hash:   blake3.Hash,
}

// One immutable whole-store snapshot in the DAG/linear snapshot log.
Snapshot_Record :: struct {
	snapshot_id:     u64,
	parent_id:       u64,
	committed_at_ms: u64,
	tree_hash:       blake3.Hash,
	object_count:    u16,
	objects:         [MAX_OBJECTS_PER_SNAPSHOT]Snapshot_Object,
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

// Bounded whole-store snapshot history with monotonic IDs and atomic rollback.
Store_History :: struct {
	snapshot_count:       u16,
	highest_snapshot_id:  u64,
	active_snapshot_id:   u64,
	last_committed_at_ms: u64,
	snapshots:            [MAX_SNAPSHOTS]Snapshot_Record,
}

// diff_change_kind_of_word converts a transport word to Diff_Change_Kind.
diff_change_kind_of_word :: proc "contextless" (word: u64) -> (kind: Diff_Change_Kind, ok: bool) {
	return enum_word.member_of_word(Diff_Change_Kind, word)
}

// history_refusal_of_word converts a transport word to History_Refusal.
history_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: History_Refusal, ok: bool) {
	return enum_word.member_of_word(History_Refusal, word)
}

// history_init resets a Store_History to the empty initial state.
history_init :: proc "contextless" (history: ^Store_History) {
	history.snapshot_count = 0
	history.highest_snapshot_id = 0
	history.active_snapshot_id = 0
	history.last_committed_at_ms = 0
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
	high := int(history.snapshot_count)
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
// and capacity bounds, sorts entries canonically by UTF-8 name order, computes
// the deterministic whole-store tree_hash, and appends one immutable snapshot.
// Any refusal leaves history completely unchanged.
snapshot_commit :: proc "contextless" (
	history: ^Store_History,
	objects: []Snapshot_Object_Input,
	now_ms: u64,
) -> (snapshot_id: u64, root_hash: blake3.Hash, refusal: History_Refusal) {
	if int(history.snapshot_count) >= MAX_SNAPSHOTS {
		return 0, {}, .History_Full
	}
	if len(objects) > MAX_OBJECTS_PER_SNAPSHOT {
		return 0, {}, .Too_Many_Objects
	}
	if history.snapshot_count > 0 && now_ms < history.last_committed_at_ms {
		return 0, {}, .Backwards_Timestamp
	}

	sorted: [MAX_OBJECTS_PER_SNAPSHOT]Snapshot_Object
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
			existing_len := int(sorted[mid].name_length)
			order := tree_hash.compare_name_bytes(sorted[mid].name[:existing_len], name_bytes)
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

	// Build canonical tree_hash entries over (name, versioned_object_hash).
	tree_entries: [MAX_OBJECTS_PER_SNAPSHOT]tree_hash.Tree_Entry
	for i in 0 ..< sorted_count {
		leaf_hash := compute_versioned_object_hash(sorted[i].object_version, sorted[i].content_hash)
		tree_entries[i] = tree_hash.Tree_Entry {
			kind        = .Object,
			name_length = sorted[i].name_length,
			name        = sorted[i].name,
			hash        = leaf_hash,
		}
	}

	encoded_tree: [MAX_SNAPSHOT_TREE_BYTES]u8
	written, enc_refusal := tree_hash.tree_encode(tree_entries[:sorted_count], encoded_tree[:])
	if enc_refusal != .None {
		return 0, {}, map_tree_name_refusal(enc_refusal)
	}
	computed_hash, hash_refusal := tree_hash.tree_hash(encoded_tree[:written])
	if hash_refusal != .None {
		return 0, {}, map_tree_name_refusal(hash_refusal)
	}

	// Commit atomically only after every validation and hash step succeeded.
	new_id := history.highest_snapshot_id + 1
	slot := int(history.snapshot_count)
	history.snapshots[slot] = Snapshot_Record {
		snapshot_id     = new_id,
		parent_id       = history.active_snapshot_id,
		committed_at_ms = now_ms,
		tree_hash       = computed_hash,
		object_count    = u16(sorted_count),
		objects         = sorted,
	}
	history.snapshot_count += 1
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

	low := 0
	high := int(record.object_count)
	for low < high {
		mid := low + (high - low) / 2
		candidate_len := int(record.objects[mid].name_length)
		order := tree_hash.compare_name_bytes(record.objects[mid].name[:candidate_len], name_bytes)
		if order == 0 {
			return record.objects[mid], true, .None
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

// snapshot_diff computes the exact sorted added/changed/removed object list
// transforming snapshot from_id into snapshot to_id. Performs a dry-run count
// first so an undersized changes_out buffer suffers zero mutation and returns
// the required count along with .Output_Too_Small.
snapshot_diff :: proc "contextless" (
	history: ^Store_History,
	from_id: u64,
	to_id: u64,
	changes_out: []Snapshot_Diff_Entry,
) -> (count: int, refusal: History_Refusal) {
	from_rec, from_refusal := snapshot_find(history, from_id)
	if from_refusal != .None {
		return 0, from_refusal
	}
	to_rec, to_refusal := snapshot_find(history, to_id)
	if to_refusal != .None {
		return 0, to_refusal
	}

	from_n := int(from_rec.object_count)
	to_n := int(to_rec.object_count)

	// Pass 1: count total differences without writing changes_out.
	needed := 0
	i := 0
	j := 0
	for i < from_n && j < to_n {
		f_len := int(from_rec.objects[i].name_length)
		t_len := int(to_rec.objects[j].name_length)
		order := tree_hash.compare_name_bytes(from_rec.objects[i].name[:f_len], to_rec.objects[j].name[:t_len])
		if order < 0 {
			needed += 1
			i += 1
		} else if order > 0 {
			needed += 1
			j += 1
		} else {
			if from_rec.objects[i].object_version != to_rec.objects[j].object_version ||
				from_rec.objects[i].content_hash != to_rec.objects[j].content_hash {
				needed += 1
			}
			i += 1
			j += 1
		}
	}
	needed += (from_n - i) + (to_n - j)

	if needed > len(changes_out) {
		return needed, .Output_Too_Small
	}

	// Pass 2: emit sorted Snapshot_Diff_Entry records.
	out_idx := 0
	i = 0
	j = 0
	for i < from_n && j < to_n {
		f_len := int(from_rec.objects[i].name_length)
		t_len := int(to_rec.objects[j].name_length)
		order := tree_hash.compare_name_bytes(from_rec.objects[i].name[:f_len], to_rec.objects[j].name[:t_len])
		if order < 0 {
			changes_out[out_idx] = Snapshot_Diff_Entry {
				kind         = .Removed,
				name_length  = from_rec.objects[i].name_length,
				name         = from_rec.objects[i].name,
				from_version = from_rec.objects[i].object_version,
				from_hash    = from_rec.objects[i].content_hash,
			}
			out_idx += 1
			i += 1
		} else if order > 0 {
			changes_out[out_idx] = Snapshot_Diff_Entry {
				kind       = .Added,
				name_length = to_rec.objects[j].name_length,
				name       = to_rec.objects[j].name,
				to_version = to_rec.objects[j].object_version,
				to_hash    = to_rec.objects[j].content_hash,
			}
			out_idx += 1
			j += 1
		} else {
			if from_rec.objects[i].object_version != to_rec.objects[j].object_version ||
				from_rec.objects[i].content_hash != to_rec.objects[j].content_hash {
				changes_out[out_idx] = Snapshot_Diff_Entry {
					kind         = .Changed,
					name_length  = to_rec.objects[j].name_length,
					name         = to_rec.objects[j].name,
					from_version = from_rec.objects[i].object_version,
					to_version   = to_rec.objects[j].object_version,
					from_hash    = from_rec.objects[i].content_hash,
					to_hash      = to_rec.objects[j].content_hash,
				}
				out_idx += 1
			}
			i += 1
			j += 1
		}
	}
	for i < from_n {
		changes_out[out_idx] = Snapshot_Diff_Entry {
			kind         = .Removed,
			name_length  = from_rec.objects[i].name_length,
			name         = from_rec.objects[i].name,
			from_version = from_rec.objects[i].object_version,
			from_hash    = from_rec.objects[i].content_hash,
		}
		out_idx += 1
		i += 1
	}
	for j < to_n {
		changes_out[out_idx] = Snapshot_Diff_Entry {
			kind        = .Added,
			name_length = to_rec.objects[j].name_length,
			name        = to_rec.objects[j].name,
			to_version  = to_rec.objects[j].object_version,
			to_hash     = to_rec.objects[j].content_hash,
		}
		out_idx += 1
		j += 1
	}
	return out_idx, .None
}
