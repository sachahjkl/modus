#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

// Each put that the service must refuse keeps nothing and counts nothing:
// a negative kind, the kind 0, the kind 3, an empty object, one byte past
// the most, a tree that is not a canonical node, a caller with no
// connection, and a store that refuses the write.
@(test)
put_object_refusals :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)
	ledger := new(Put_Ledger)
	defer free(ledger)
	big := make([]u8, PUT_OBJECT_BYTES_MOST + 1)
	defer delete(big)
	not_a_tree := []u8{'M', 'O', 'D', 'T', 'R', 'E', 'E', '1', 9, 9}
	cases := [?]struct {
		kind:    i64,
		bytes:   []u8,
		caller:  u64,
		refusal: pr.Recipe_Refusal,
	}{
		{-1, []u8{1}, 7, .Bad_Input_Kind},
		{min(i64), []u8{1}, 7, .Bad_Input_Kind},
		{0, []u8{1}, 7, .Bad_Input_Kind},
		{3, []u8{1}, 7, .Bad_Input_Kind},
		{max(i64), []u8{1}, 7, .Bad_Input_Kind},
		{1, nil, 7, .Malformed_Output},
		{1, big, 7, .Arguments_Too_Large},
		{2, not_a_tree, 7, .Malformed_Output},
		{1, []u8{1}, 0, .Bad_Head_Value},
	}
	for each in cases {
		_, refusal := put_object(state, ledger, each.caller, each.kind, each.bytes)
		testing.expectf(t, refusal == each.refusal, "kind %d, %d bytes: %v, not %v", each.kind, len(each.bytes), refusal, each.refusal)
	}
	testing.expect_value(t, store.writes, 0)
	testing.expect_value(t, ledger.hash_count, 0)
	store.writes_allowed = 0
	_, refused := put_object(state, ledger, 7, 1, []u8{1})
	testing.expect_value(t, refused, pr.Recipe_Refusal.Store_Failed)
	testing.expect_value(t, ledger.hash_count, 0)
	testing.expect_value(t, ledger.callers[0].count, 0)
}

// The quota of a caller: its 256th object is kept, the 257th is refused,
// an object that it put before is kept again and counts once, and another
// caller keeps its own. The most bytes, and a canonical tree, are kept.
@(test)
put_object_quota_then_success :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)
	ledger := new(Put_Ledger)
	defer free(ledger)
	// The memory store holds 64 objects: a store that keeps nothing past
	// them would refuse first, so the quota is counted on a store that
	// takes each write and keeps the last ones.
	state.store.write = proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
		return .Ok
	}
	for index in 0 ..< PUT_OBJECTS_PER_CALLER_MOST {
		bytes := [2]u8{u8(index), u8(index >> 8)}
		_, refusal := put_object(state, ledger, 7, 1, bytes[:])
		testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	}
	past := [2]u8{0xFF, 0xFF}
	_, refusal := put_object(state, ledger, 7, 1, past[:])
	testing.expect_value(t, refusal, pr.Recipe_Refusal.Put_Quota_Reached)
	again := [2]u8{0, 0}
	_, again_refusal := put_object(state, ledger, 7, 1, again[:])
	testing.expect_value(t, again_refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, ledger.callers[0].count, PUT_OBJECTS_PER_CALLER_MOST)
	_, other := put_object(state, ledger, 8, 1, past[:])
	testing.expect_value(t, other, pr.Recipe_Refusal.None)

	// The most bytes in one put, and a canonical tree, through a real store.
	state.store = pr.memory_private_store_port(store)
	most := make([]u8, PUT_OBJECT_BYTES_MOST)
	defer delete(most)
	most_hash, most_refusal := put_object(state, ledger, 8, 1, most)
	testing.expect_value(t, most_refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, most_hash, blake3.hash(most))
	entry, _ := tree_hash.tree_entry_make(.Object, "most", most_hash)
	entries := [1]tree_hash.Tree_Entry{entry}
	node: [256]u8
	written, _ := tree_hash.tree_encode(entries[:], node[:])
	tree, tree_refusal := put_object(state, ledger, 8, 2, node[:written])
	testing.expect_value(t, tree_refusal, pr.Recipe_Refusal.None)
	name := pr.blob_object_name(tree)
	testing.expect(t, pr.memory_private_store_find(store, pr.private_object_name_text(&name)) != nil)
	testing.expect_value(t, len(put_hashes(ledger)), PUT_OBJECTS_PER_CALLER_MOST + 3)
}
