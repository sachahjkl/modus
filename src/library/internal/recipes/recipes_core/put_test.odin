#+build !freestanding
package recipes_core

import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/tree_hash"

@(private = "file")
NOW :: u64(10 * PUT_WINDOW_SECONDS)

// Each put that the service must refuse keeps nothing and counts nothing:
// a negative kind, the kind 0, the kind 3, an empty object, one byte past
// the most, a tree that is not a canonical node, a principal that is no
// number, and a store that refuses the write.
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
		kind:      i64,
		bytes:     []u8,
		principal: u64,
		refusal:   pr.Recipe_Refusal,
	}{
		{-1, []u8{1}, 7, .Bad_Input_Kind},
		{min(i64), []u8{1}, 7, .Bad_Input_Kind},
		{0, []u8{1}, 7, .Bad_Input_Kind},
		{3, []u8{1}, 7, .Bad_Input_Kind},
		{max(i64), []u8{1}, 7, .Bad_Input_Kind},
		{1, nil, 7, .Malformed_Output},
		{1, big, 7, .Arguments_Too_Large},
		{2, not_a_tree, 7, .Malformed_Output},
		{1, []u8{1}, max(u64), .Bad_Head_Value},
	}
	for each in cases {
		_, refusal := put_object(state, ledger, each.principal, NOW, each.kind, each.bytes)
		testing.expectf(t, refusal == each.refusal, "kind %d, %d bytes: %v, not %v", each.kind, len(each.bytes), refusal, each.refusal)
	}
	testing.expect_value(t, store.writes, 0)
	testing.expect_value(t, ledger.now.hash_count, 0)
	store.writes_allowed = 0
	_, refused := put_object(state, ledger, 7, NOW, 1, []u8{1})
	testing.expect_value(t, refused, pr.Recipe_Refusal.Store_Failed)
	testing.expect_value(t, ledger.now.hash_count, 0)
	testing.expect_value(t, ledger.now.principals[0].count, 0)
}

// The quota of a principal: its 256th object of a window is kept and the
// 257th refused, whichever connection it calls from; an object that it
// put before is kept again and counts once; another principal keeps its
// own; the next window gives a new quota and keeps the puts of the window
// before for the retention; a gap of two windows forgets both. The most
// bytes, and a canonical tree, are kept.
@(test)
put_object_quota_and_windows :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)
	ledger := new(Put_Ledger)
	defer free(ledger)
	// The memory store holds 64 objects: the quota is counted on a store
	// that takes each write.
	state.store.write = proc "contextless" (user: rawptr, name: string, data: []u8) -> pr.Private_Store_Status {
		return .Ok
	}
	for index in 0 ..< PUT_OBJECTS_PER_PRINCIPAL_MOST {
		bytes := [2]u8{u8(index), u8(index >> 8)}
		// A connection that closes and opens again keeps its principal: the
		// key is the principal, not the connection.
		_, refusal := put_object(state, ledger, 7, NOW + u64(index), 1, bytes[:])
		testing.expect_value(t, refusal, pr.Recipe_Refusal.None)
	}
	past := [2]u8{0xFF, 0xFF}
	_, refusal := put_object(state, ledger, 7, NOW + 300, 1, past[:])
	testing.expect_value(t, refusal, pr.Recipe_Refusal.Put_Quota_Reached)
	again := [2]u8{0, 0}
	_, again_refusal := put_object(state, ledger, 7, NOW + 301, 1, again[:])
	testing.expect_value(t, again_refusal, pr.Recipe_Refusal.None)
	_, other := put_object(state, ledger, 8, NOW + 302, 1, past[:])
	testing.expect_value(t, other, pr.Recipe_Refusal.None)
	hashes := new([2 * PUT_PRINCIPALS_MOST * PUT_OBJECTS_PER_PRINCIPAL_MOST]blake3.Hash)
	defer free(hashes)
	testing.expect_value(t, len(put_hashes(ledger, hashes)), PUT_OBJECTS_PER_PRINCIPAL_MOST + 1)

	// The next window: a new quota, and the puts of the window before stay
	// for the retention.
	_, next := put_object(state, ledger, 7, NOW + PUT_WINDOW_SECONDS, 1, []u8{9, 9, 9})
	testing.expect_value(t, next, pr.Recipe_Refusal.None)
	testing.expect_value(t, len(put_hashes(ledger, hashes)), PUT_OBJECTS_PER_PRINCIPAL_MOST + 2)
	// A clock that goes back keeps the window.
	put_ledger_age(ledger, NOW)
	testing.expect_value(t, ledger.window, (NOW + PUT_WINDOW_SECONDS) / PUT_WINDOW_SECONDS)
	// Two windows later both are forgotten.
	put_ledger_age(ledger, NOW + 3 * PUT_WINDOW_SECONDS)
	testing.expect_value(t, len(put_hashes(ledger, hashes)), 0)

	// The most bytes in one put, and a canonical tree, through a real store.
	state.store = pr.memory_private_store_port(store)
	most := make([]u8, PUT_OBJECT_BYTES_MOST)
	defer delete(most)
	most_hash, most_refusal := put_object(state, ledger, 8, NOW + 3 * PUT_WINDOW_SECONDS, 1, most)
	testing.expect_value(t, most_refusal, pr.Recipe_Refusal.None)
	testing.expect_value(t, most_hash, blake3.hash(most))
	entry, _ := tree_hash.tree_entry_make(.Object, "most", most_hash)
	entries := [1]tree_hash.Tree_Entry{entry}
	node: [256]u8
	written, _ := tree_hash.tree_encode(entries[:], node[:])
	tree, tree_refusal := put_object(state, ledger, 8, NOW + 3 * PUT_WINDOW_SECONDS, 2, node[:written])
	testing.expect_value(t, tree_refusal, pr.Recipe_Refusal.None)
	name := pr.blob_object_name(tree)
	testing.expect(t, pr.memory_private_store_find(store, pr.private_object_name_text(&name)) != nil)
	// Unified layout: content-addressed objects live under their exact 64-hex hash.
	testing.expect_value(t, len(pr.private_object_name_text(&name)), 2 * blake3.HASH_SIZE)
	parsed, parsed_ok := pr.hash_of_blob_object_name(pr.private_object_name_text(&name))
	testing.expect(t, parsed_ok && parsed == tree, "64-hex name round-trips to exact tree hash")
}

// put_memory_preflight and put_memory_commit enforce per-principal byte quota
// (PUT_BYTES_PER_PRINCIPAL_MOST), object count quota, kind/size edges, and the
// 75 % RETENTION_PERCENT store guard. Refused calls change nothing.
@(test)
put_memory_byte_quota_and_retention_guard :: proc(t: ^testing.T) {
	state := new(Recipes_State)
	defer free(state)
	store := recipes_test_state_init(state)
	defer free(store)
	ledger := new(Put_Ledger)
	defer free(ledger)

	// Refusal edges: bad kind, 0 size, > PUT_MEMORY_BYTES_MOST, Tree > MAX_ENCODED_TREE_BYTES, bad principal.
	_, ref_kind := put_memory_preflight(state, ledger, 1, NOW, 0, 16)
	testing.expect_value(t, ref_kind, pr.Recipe_Refusal.Bad_Input_Kind)
	_, ref_zero := put_memory_preflight(state, ledger, 1, NOW, 1, 0)
	testing.expect_value(t, ref_zero, pr.Recipe_Refusal.Malformed_Output)
	_, ref_huge := put_memory_preflight(state, ledger, 1, NOW, 1, PUT_MEMORY_BYTES_MOST + 1)
	testing.expect_value(t, ref_huge, pr.Recipe_Refusal.Arguments_Too_Large)
	_, ref_tree := put_memory_preflight(state, ledger, 1, NOW, 2, u64(tree_hash.MAX_ENCODED_TREE_BYTES) + 1)
	testing.expect_value(t, ref_tree, pr.Recipe_Refusal.Arguments_Too_Large)
	_, ref_principal := put_memory_preflight(state, ledger, max(u64), NOW, 1, 16)
	testing.expect_value(t, ref_principal, pr.Recipe_Refusal.Bad_Head_Value)

	// Per-principal byte quota: 32 MiB + 32 MiB succeeds; 1 byte more is refused with Put_Quota_Reached.
	half := PUT_BYTES_PER_PRINCIPAL_MOST / 2
	kind1, r1 := put_memory_preflight(state, ledger, 3, NOW, 1, half)
	testing.expect_value(t, r1, pr.Recipe_Refusal.None)
	testing.expect_value(t, int(kind1), 1)
	testing.expect_value(t, put_memory_commit(ledger, 3, NOW, blake3.hash([]u8{1}), half), pr.Recipe_Refusal.None)

	_, r2 := put_memory_preflight(state, ledger, 3, NOW, 1, half)
	testing.expect_value(t, r2, pr.Recipe_Refusal.None)
	testing.expect_value(t, put_memory_commit(ledger, 3, NOW, blake3.hash([]u8{2}), half), pr.Recipe_Refusal.None)

	_, r_over := put_memory_preflight(state, ledger, 3, NOW, 1, 1)
	testing.expect_value(t, r_over, pr.Recipe_Refusal.Put_Quota_Reached)
	// Another principal still has its own byte quota.
	_, r_other := put_memory_preflight(state, ledger, 4, NOW, 1, 1024)
	testing.expect_value(t, r_other, pr.Recipe_Refusal.None)

	// 75 % RETENTION_PERCENT store guard: a store of 100 blocks allows at most 75 blocks.
	// Write a 280 KiB input blob (70 + 1 = 71 blocks, no removable realisations).
	// A 12 KiB put (3 + 2 = 5 blocks: 71 + 5 = 76 > 75) is refused with Store_Full;
	// an 8 KiB put (2 + 2 = 4 blocks: 71 + 4 = 75 <= 75) fits!
	large := Large_Store{block_limit = 100}
	state_init(state, large_store_port(&large))
	filler := make([]u8, 70 * 4096, context.temp_allocator)
	testing.expect_value(t, pr.private_store_write(&state.store, "filler", filler), pr.Private_Store_Status.Ok)
	_, r_full := put_memory_preflight(state, ledger, 4, NOW, 1, 12 * 1024)
	testing.expect_value(t, r_full, pr.Recipe_Refusal.Store_Full)
	_, r_inline_full := put_object(state, ledger, 4, NOW, 1, make([]u8, 12 * 1024, context.temp_allocator))
	testing.expect_value(t, r_inline_full, pr.Recipe_Refusal.Store_Full)
	_, r_fits := put_memory_preflight(state, ledger, 4, NOW, 1, 8 * 1024)
	testing.expect_value(t, r_fits, pr.Recipe_Refusal.None)
}
