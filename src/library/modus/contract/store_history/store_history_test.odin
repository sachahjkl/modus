#+build !freestanding
#+build !modus
package store_history

import "core:fmt"
import "core:testing"
import "core:strings"
import "modus:contract/blake3"
import "modus:contract/tree_hash"

@(private = "file")
hash_of :: proc(text: string) -> blake3.Hash {
	return blake3.hash(transmute([]u8)text)
}

// The memory of a history of a test: its tables and the workspace of one
// commit, from the allocator of the test.
@(private = "file")
Test_History :: struct {
	using history: Store_History,
	workspace:     []u8,
}

@(private = "file")
test_history_make :: proc(snapshots: int = 64, objects: int = 4096) -> ^Test_History {
	made := new(Test_History)
	history_init(&made.history, make([]Snapshot_Record, snapshots), make([]Snapshot_Object, objects))
	made.workspace = make([]u8, tree_hash.MAX_ENCODED_TREE_BYTES)
	return made
}

@(private = "file")
test_history_free :: proc(made: ^Test_History) {
	delete(made.snapshots)
	delete(made.objects)
	delete(made.workspace)
	free(made)
}

@(private = "file")
commit :: proc(made: ^Test_History, objects: []Snapshot_Object_Input, now_ms: u64) -> (u64, blake3.Hash, History_Refusal) {
	return snapshot_commit(&made.history, objects, now_ms, made.workspace)
}

// Enum borders, commit validation refusals, zero-mutation guarantees, and canonical hashing.
@(test)
commit_validation_refusals_and_canonical_tree_hash :: proc(t: ^testing.T) {
	// Closed enum borders.
	kind, ok := diff_change_kind_of_word(2)
	testing.expect(t, ok && kind == .Changed, "2 must decode as Changed")
	_, ok = diff_change_kind_of_word(0)
	testing.expect(t, !ok, "0 is not a valid Diff_Change_Kind")
	_, ok = diff_change_kind_of_word(4)
	testing.expect(t, !ok, "4 is not a valid Diff_Change_Kind")

	history := test_history_make()
	defer test_history_free(history)

	// Invalid names: empty, too long (256 bytes), ".", "..", slash, control char.
	long_name := strings.repeat("a", OBJECT_NAME_CAPACITY + 1, context.temp_allocator)
	bad_inputs := [?][2]string {
		{"", "empty"},
		{long_name, "too_long"},
		{".", "dot"},
		{"..", "dotdot"},
		{"a/b", "slash"},
		{"bad\nname", "newline"},
	}
	for pair in bad_inputs {
		objs := [1]Snapshot_Object_Input{{name = pair[0], object_version = 1, content_hash = hash_of("x")}}
		_, _, r := commit(history, objs[:], 100)
		testing.expect(t, r != .None, "invalid object name must be refused")
	}
	testing.expect_value(t, history.snapshot_count, int(0))
	testing.expect_value(t, history.active_snapshot_id, u64(0))

	// Zero object version refused.
	zero_ver := [1]Snapshot_Object_Input{{name = "alpha", object_version = 0, content_hash = hash_of("a")}}
	_, _, r_zv := commit(history, zero_ver[:], 100)
	testing.expect_value(t, r_zv, History_Refusal.Zero_Object_Version)

	// Duplicate names refused (even when unsorted).
	dups := [3]Snapshot_Object_Input {
		{name = "zeta", object_version = 1, content_hash = hash_of("z")},
		{name = "alpha", object_version = 1, content_hash = hash_of("a1")},
		{name = "alpha", object_version = 2, content_hash = hash_of("a2")},
	}
	_, _, r_dup := commit(history, dups[:], 100)
	testing.expect_value(t, r_dup, History_Refusal.Duplicate_Name)
	testing.expect_value(t, history.snapshot_count, int(0))

	// Too many objects (one past a tree node) refused.
	too_many := make([]Snapshot_Object_Input, MAX_OBJECTS_PER_SNAPSHOT + 1, context.temp_allocator)
	for i in 0 ..< len(too_many) {
		too_many[i] = Snapshot_Object_Input{name = fmt.tprintf("obj_%05d", i), object_version = 1, content_hash = hash_of("v")}
	}
	_, _, r_many := commit(history, too_many[:], 100)
	testing.expect_value(t, r_many, History_Refusal.Too_Many_Objects)
	testing.expect_value(t, history.snapshot_count, int(0))

	// A workspace one byte short of the tree refused, with no change.
	short_objects := [1]Snapshot_Object_Input{{name = "alpha", object_version = 1, content_hash = hash_of("a")}}
	short := make([]u8, snapshot_tree_bytes(short_objects[:]) - 1, context.temp_allocator)
	_, _, r_short := snapshot_commit(&history.history, short_objects[:], 100, short)
	testing.expect_value(t, r_short, History_Refusal.Output_Too_Small)
	testing.expect_value(t, history.snapshot_count, int(0))
	testing.expect_value(t, history.object_count, int(0))

	// Canonical order independence: committing the same objects in opposite order produces identical tree_hash.
	order_a := [3]Snapshot_Object_Input {
		{name = "gamma", object_version = 3, content_hash = hash_of("g")},
		{name = "alpha", object_version = 1, content_hash = hash_of("a")},
		{name = "beta", object_version = 2, content_hash = hash_of("b")},
	}
	order_b := [3]Snapshot_Object_Input {
		{name = "beta", object_version = 2, content_hash = hash_of("b")},
		{name = "gamma", object_version = 3, content_hash = hash_of("g")},
		{name = "alpha", object_version = 1, content_hash = hash_of("a")},
	}
	id1, h1, r1 := commit(history, order_a[:], 1000)
	testing.expect_value(t, r1, History_Refusal.None)
	testing.expect_value(t, id1, u64(1))
	testing.expect_value(t, history.active_snapshot_id, u64(1))

	// Backwards timestamp (999 < 1000) refused without mutation!
	_, _, r_back := commit(history, order_b[:], 999)
	testing.expect_value(t, r_back, History_Refusal.Backwards_Timestamp)
	testing.expect_value(t, history.snapshot_count, int(1))

	// Same timestamp (1000) succeeds and produces identical tree_hash.
	id2, h2, r2 := commit(history, order_b[:], 1000)
	testing.expect_value(t, r2, History_Refusal.None)
	testing.expect_value(t, id2, u64(2))
	testing.expect_value(t, h2, h1)

	// Changing only object_version (same content_hash) MUST change tree_hash.
	order_v := order_a
	order_v[1].object_version = 9
	_, h3, r3 := commit(history, order_v[:], 1001)
	testing.expect_value(t, r3, History_Refusal.None)
	testing.expect(t, h3 != h1, "changing object_version must change canonical tree_hash")
}

// Historical lookup, atomic rollback preserving newer snapshots (DAG branching),
// and exact snapshot_diff with dry-run zero-mutation buffer checks.
@(test)
lookup_atomic_rollback_branching_and_diff :: proc(t: ^testing.T) {
	history := test_history_make()
	defer test_history_free(history)

	// Snapshot 1: {config: v1, readme: v1}
	s1_objs := [2]Snapshot_Object_Input {
		{name = "readme", object_version = 1, content_hash = hash_of("hello")},
		{name = "config", object_version = 1, content_hash = hash_of("cfg1")},
	}
	id1, _, r1 := commit(history, s1_objs[:], 100)
	testing.expect_value(t, r1, History_Refusal.None)
	testing.expect_value(t, id1, u64(1))

	// Snapshot 2: {config: v2, notes: v1} (readme removed, config changed, notes added)
	s2_objs := [2]Snapshot_Object_Input {
		{name = "config", object_version = 2, content_hash = hash_of("cfg2")},
		{name = "notes", object_version = 1, content_hash = hash_of("note1")},
	}
	id2, _, r2 := commit(history, s2_objs[:], 200)
	testing.expect_value(t, r2, History_Refusal.None)
	testing.expect_value(t, id2, u64(2))

	// Snapshot 3: empty store (0 objects) is valid and has parent 2.
	id3, _, r3 := commit(history, nil, 300)
	testing.expect_value(t, r3, History_Refusal.None)
	testing.expect_value(t, id3, u64(3))

	// Historical lookups across snapshots 1, 2, 3.
	obj, found, lr := snapshot_lookup_object(history, 1, "config")
	testing.expect_value(t, lr, History_Refusal.None)
	testing.expect(t, found, "config must exist in snapshot 1")
	testing.expect_value(t, obj.object_version, u64(1))
	testing.expect_value(t, obj.content_hash, hash_of("cfg1"))

	obj2, found2, lr2 := snapshot_lookup_object(history, 2, "config")
	testing.expect_value(t, lr2, History_Refusal.None)
	testing.expect(t, found2, "config must exist in snapshot 2")
	testing.expect_value(t, obj2.object_version, u64(2))

	_, found_rm, lr_rm := snapshot_lookup_object(history, 2, "readme")
	testing.expect_value(t, lr_rm, History_Refusal.None)
	testing.expect(t, !found_rm, "readme was removed in snapshot 2")

	// Refusals on zero/unknown snapshot ID and invalid lookup name.
	_, _, r_bad := snapshot_lookup_object(history, 0, "config")
	testing.expect_value(t, r_bad, History_Refusal.Zero_Snapshot_Id)
	_, _, r_bad = snapshot_lookup_object(history, 99, "config")
	testing.expect_value(t, r_bad, History_Refusal.Unknown_Snapshot)
	_, _, r_bad = snapshot_lookup_object(history, 1, "")
	testing.expect_value(t, r_bad, History_Refusal.Empty_Name)

	// Atomic rollback refusals: 0 and unknown leave active_snapshot_id untouched (3).
	testing.expect_value(t, snapshot_rollback(history, 0), History_Refusal.Zero_Snapshot_Id)
	testing.expect_value(t, snapshot_rollback(history, 4), History_Refusal.Unknown_Snapshot)
	testing.expect_value(t, history.active_snapshot_id, u64(3))

	// Atomic rollback to snapshot 1: snapshots 2 and 3 MUST remain intact!
	testing.expect_value(t, snapshot_rollback(history, 1), History_Refusal.None)
	testing.expect_value(t, history.active_snapshot_id, u64(1))
	testing.expect_value(t, history.highest_snapshot_id, u64(3))
	testing.expect_value(t, history.snapshot_count, int(3))

	// Snapshot 2 is still readable after rollback!
	_, still_there, r_still := snapshot_lookup_object(history, 2, "notes")
	testing.expect_value(t, r_still, History_Refusal.None)
	testing.expect(t, still_there, "rollback must not erase newer snapshots")

	// Next commit after rollback gets snapshot_id = 4 (highest + 1) and parent_id = 1!
	s4_objs := [2]Snapshot_Object_Input {
		{name = "config", object_version = 1, content_hash = hash_of("cfg1")},
		{name = "hotfix", object_version = 1, content_hash = hash_of("fix")},
	}
	id4, _, r4 := commit(history, s4_objs[:], 400)
	testing.expect_value(t, r4, History_Refusal.None)
	testing.expect_value(t, id4, u64(4))
	rec4, f4 := snapshot_find(history, 4)
	testing.expect_value(t, f4, History_Refusal.None)
	testing.expect_value(t, rec4.parent_id, u64(1))
	testing.expect_value(t, history.active_snapshot_id, u64(4))

	// Diff between snapshot 1 and snapshot 2:
	// config: Changed (v1 -> v2), notes: Added (v1), readme: Removed (v1).
	// A page of 2 gives the first two changes and the total; the next page
	// from 2 gives the third.
	small: [2]Snapshot_Diff_Entry
	page_count, page_total, dr_small := snapshot_diff(history, 1, 2, small[:])
	testing.expect_value(t, dr_small, History_Refusal.None)
	testing.expect_value(t, page_count, 2)
	testing.expect_value(t, page_total, 3)
	testing.expect_value(t, snapshot_diff_entry_name(&small[1]), "notes")
	rest_count, _, _ := snapshot_diff(history, 1, 2, small[:], 2)
	testing.expect_value(t, rest_count, 1)
	testing.expect_value(t, snapshot_diff_entry_name(&small[0]), "readme")
	past_count, _, _ := snapshot_diff(history, 1, 2, small[:], 3)
	testing.expect_value(t, past_count, 0)
	_, _, dr_negative := snapshot_diff(history, 1, 2, small[:], -1)
	testing.expect_value(t, dr_negative, History_Refusal.Output_Too_Small)

	// Full diff succeeds in sorted name order.
	diffs: [8]Snapshot_Diff_Entry
	n, _, dr := snapshot_diff(history, 1, 2, diffs[:])
	testing.expect_value(t, dr, History_Refusal.None)
	testing.expect_value(t, n, 3)

	testing.expect_value(t, diffs[0].kind, Diff_Change_Kind.Changed)
	testing.expect_value(t, snapshot_diff_entry_name(&diffs[0]), "config")
	testing.expect_value(t, diffs[0].from_version, u64(1))
	testing.expect_value(t, diffs[0].to_version, u64(2))

	testing.expect_value(t, diffs[1].kind, Diff_Change_Kind.Added)
	testing.expect_value(t, snapshot_diff_entry_name(&diffs[1]), "notes")
	testing.expect_value(t, diffs[1].to_version, u64(1))

	testing.expect_value(t, diffs[2].kind, Diff_Change_Kind.Removed)
	testing.expect_value(t, snapshot_diff_entry_name(&diffs[2]), "readme")
	testing.expect_value(t, diffs[2].from_version, u64(1))

	// Diff against self is 0 entries.
	n_self, _, dr_self := snapshot_diff(history, 2, 2, diffs[:])
	testing.expect_value(t, dr_self, History_Refusal.None)
	testing.expect_value(t, n_self, 0)

	// Unknown / zero snapshot diff refusals.
	_, _, dr_bad := snapshot_diff(history, 0, 2, diffs[:])
	testing.expect_value(t, dr_bad, History_Refusal.Zero_Snapshot_Id)
	_, _, dr_bad = snapshot_diff(history, 1, 99, diffs[:])
	testing.expect_value(t, dr_bad, History_Refusal.Unknown_Snapshot)
}

// The capacity is the table of the caller: filling all of it succeeds and
// the next commit is refused cleanly. A table of 200 is past the 64 of the
// fixed table before.
@(test)
history_capacity_bound_refuses_one_past_the_table :: proc(t: ^testing.T) {
	MAX_SNAPSHOTS :: 200
	history := test_history_make(MAX_SNAPSHOTS, MAX_SNAPSHOTS)
	defer test_history_free(history)

	for i in 1 ..= MAX_SNAPSHOTS {
		objs := [1]Snapshot_Object_Input {
			{name = "state", object_version = u64(i), content_hash = hash_of(fmt.tprintf("v%d", i))},
		}
		id, _, r := commit(history, objs[:], u64(i * 10))
		testing.expect_value(t, r, History_Refusal.None)
		testing.expect_value(t, id, u64(i))
	}
	testing.expect_value(t, history.snapshot_count, int(MAX_SNAPSHOTS))

	// One commit past the table refused with zero mutation.
	extra := [1]Snapshot_Object_Input{{name = "state", object_version = MAX_SNAPSHOTS + 1, content_hash = hash_of("one more")}}
	_, _, r_full := commit(history, extra[:], 9999)
	testing.expect_value(t, r_full, History_Refusal.History_Full)
	testing.expect_value(t, history.snapshot_count, int(MAX_SNAPSHOTS))
	testing.expect_value(t, history.highest_snapshot_id, u64(MAX_SNAPSHOTS))
	testing.expect_value(t, history.active_snapshot_id, u64(MAX_SNAPSHOTS))
}

// A store of 1000 notes with names of up to 255 bytes: one snapshot, past
// the 128 objects of the fixed table before; a pool with no room for the
// next snapshot refuses it with no change.
@(test)
a_snapshot_of_a_thousand_notes :: proc(t: ^testing.T) {
	NOTES :: 1000
	history := test_history_make(4, NOTES + 10)
	defer test_history_free(history)
	notes := make([]Snapshot_Object_Input, NOTES, context.temp_allocator)
	for &note, index in notes {
		// Written in the reverse order: the commit sorts them.
		head := fmt.tprintf("note %04d ", NOTES - 1 - index)
		note = {name = fmt.tprintf("%s%s", head, strings.repeat("n", OBJECT_NAME_CAPACITY - len(head), context.temp_allocator)), object_version = 1, content_hash = hash_of(head)}
	}
	id, _, refusal := commit(history, notes, 10)
	testing.expect_value(t, refusal, History_Refusal.None)
	record, _ := snapshot_find(&history.history, id)
	testing.expect_value(t, record.object_count, NOTES)
	items := snapshot_objects(&history.history, record)
	testing.expect(t, strings.has_prefix(snapshot_object_name(&items[0]), "note 0000 "))
	testing.expect_value(t, len(snapshot_object_name(&items[NOTES - 1])), OBJECT_NAME_CAPACITY)
	found_object, found, _ := snapshot_lookup_object(&history.history, id, notes[500].name)
	testing.expect(t, found && found_object.content_hash == notes[500].content_hash)
	// The pool holds 10 more objects: a second snapshot of the notes is refused.
	_, _, full := commit(history, notes, 20)
	testing.expect_value(t, full, History_Refusal.Too_Many_Objects)
	testing.expect_value(t, history.snapshot_count, 1)
	testing.expect_value(t, history.object_count, NOTES)
}
