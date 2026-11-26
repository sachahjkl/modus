#+build !freestanding
package storage_object_cache

import "core:testing"
import "modus:contract/blake3"

@(private = "file")
test_hash :: proc(tag: u8, salt: u8 = 0) -> blake3.Hash {
	buf := [2]u8{tag, salt}
	return blake3.hash(buf[:])
}

@(private = "file")
Mock_Holdings :: struct {
	handles: [32]u64,
	counts:  [32]u64,
	oks:     [32]bool,
	len:     int,
}

@(private = "file")
mock_holdings_set :: proc(m: ^Mock_Holdings, handle: u64, count: u64, ok: bool = true) {
	for i in 0 ..< m.len {
		if m.handles[i] == handle {
			m.counts[i] = count
			m.oks[i] = ok
			return
		}
	}
	m.handles[m.len] = handle
	m.counts[m.len] = count
	m.oks[m.len] = ok
	m.len += 1
}

@(private = "file")
mock_holdings_query :: proc "contextless" (memory_handle: u64, user_data: rawptr) -> (holdings: u64, ok: bool) {
	m := (^Mock_Holdings)(user_data)
	for i in 0 ..< m.len {
		if m.handles[i] == memory_handle {
			return m.counts[i], m.oks[i]
		}
	}
	return 0, false
}

// Adversarial border checks: unknown enum words, nil pointers, zero handles,
// zero pages, undersized pages for byte_size, and byte_size overflow.
@(test)
border_and_argument_refusals :: proc(t: ^testing.T) {
	_, ok := cache_class_of_word(2)
	testing.expect(t, !ok)
	_, ok = cache_class_of_word(max(u64))
	testing.expect(t, !ok)
	cls, cls_ok := cache_class_of_word(u64(Cache_Class.Public_System))
	testing.expect(t, cls_ok && cls == .Public_System)
	cls, cls_ok = cache_class_of_word(u64(Cache_Class.Private_Principal))
	testing.expect(t, cls_ok && cls == .Private_Principal)

	_, ok = evict_scope_of_word(2)
	testing.expect(t, !ok)
	_, ok = evict_scope_of_word(max(u64))
	testing.expect(t, !ok)

	// pages_for_bytes edges: 0, 1, 4096, 4097, max(u64)-4095, overflow.
	p, p_ok := pages_for_bytes(0)
	testing.expect(t, p_ok && p == 1)
	p, p_ok = pages_for_bytes(1)
	testing.expect(t, p_ok && p == 1)
	p, p_ok = pages_for_bytes(PAGE_SIZE)
	testing.expect(t, p_ok && p == 1)
	p, p_ok = pages_for_bytes(PAGE_SIZE + 1)
	testing.expect(t, p_ok && p == 2)
	_, p_ok = pages_for_bytes(max(u64))
	testing.expect(t, !p_ok)
	_, p_ok = pages_for_bytes(max(u64) - PAGE_SIZE + 2)
	testing.expect(t, !p_ok)

	cache: Cache
	cache_init(&cache, default_cache_config())
	h := test_hash(1)

	_, res := insert_public(nil, h, 10, 100, 1)
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)
	_, res = insert_public(&cache, h, 0, 100, 1)
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)
	_, res = insert_public(&cache, h, 10, 100, 0)
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)
	_, res = insert_public(&cache, h, 10, PAGE_SIZE + 1, 1) // needs 2 pages
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)
	_, res = insert_public(&cache, h, 10, max(u64), 1)
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)

	_, res = insert_private(nil, 1, 1, h, 10, 100, 1)
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)
	_, res = insert_private(&cache, 1, 1, h, 0, 100, 1)
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)
	_, res = insert_private(&cache, 1, 1, h, 10, 8193, 2) // needs 3 pages
	testing.expect_value(t, res, Insert_Result.Invalid_Argument)

	// Invalid scope cast and nil callback refused.
	mock: Mock_Holdings
	_, eres := evict_candidate(nil, 1, .Same_Principal, mock_holdings_query, &mock)
	testing.expect_value(t, eres, Evict_Result.Invalid_Argument)
	_, eres = evict_candidate(&cache, 1, .Same_Principal, nil, &mock)
	testing.expect_value(t, eres, Evict_Result.Invalid_Argument)
	_, eres = evict_candidate(&cache, 1, Evict_Scope(99), mock_holdings_query, &mock)
	testing.expect_value(t, eres, Evict_Result.Invalid_Argument)

	// Out-of-bounds slot removals refused.
	_, rm_ok := remove_private_slot(&cache, -1)
	testing.expect(t, !rm_ok)
	_, rm_ok = remove_private_slot(&cache, PRIVATE_CACHE_CAPACITY)
	testing.expect(t, !rm_ok)
	_, rm_ok = remove_private_slot(&cache, 0) // unoccupied
	testing.expect(t, !rm_ok)
	_, rm_ok = remove_public_slot(&cache, -1)
	testing.expect(t, !rm_ok)
	_, rm_ok = remove_public_slot(&cache, PUBLIC_CACHE_CAPACITY)
	testing.expect(t, !rm_ok)
	_, rm_ok = remove_public_slot(&cache, 0) // unoccupied
	testing.expect(t, !rm_ok)

	// Nil pin table operations refused safely.
	_, pres := pin_add(nil, 1, 1, h)
	testing.expect_value(t, pres, Pin_Result.Invalid_Argument)
	_, pres = pin_remove(nil, 1, 1, h)
	testing.expect_value(t, pres, Pin_Result.Invalid_Argument)
	testing.expect(t, !is_pinned(nil, 1, h))
}

// Cross-principal and cross-store isolation: the exact same BLAKE3 hash stored
// in two principals, in two stores of one principal, and in Public_System must
// produce distinct cache entries and never deduplicate across boundaries.
@(test)
cross_principal_and_cross_store_isolation :: proc(t: ^testing.T) {
	cache: Cache
	cache_init(&cache, default_cache_config())
	shared_hash := test_hash(42)

	// Insert same hash into Public_System, (principal 1, store 10),
	// (principal 1, store 11), and (principal 2, store 10).
	pub_slot, pub_res := insert_public(&cache, shared_hash, 100, 500, 1)
	testing.expect_value(t, pub_res, Insert_Result.Inserted)

	p1s10_slot, r1 := insert_private(&cache, 1, 10, shared_hash, 201, 500, 1)
	testing.expect_value(t, r1, Insert_Result.Inserted)

	p1s11_slot, r2 := insert_private(&cache, 1, 11, shared_hash, 202, 500, 1)
	testing.expect_value(t, r2, Insert_Result.Inserted)

	p2s10_slot, r3 := insert_private(&cache, 2, 10, shared_hash, 203, 500, 1)
	testing.expect_value(t, r3, Insert_Result.Inserted)

	// Distinct private slots; distinct handles; exact page accounting.
	testing.expect(t, p1s10_slot != p1s11_slot)
	testing.expect(t, p1s10_slot != p2s10_slot)
	testing.expect(t, p1s11_slot != p2s10_slot)
	testing.expect_value(t, cache.public_count, 1)
	testing.expect_value(t, cache.private_count, 3)
	testing.expect_value(t, cache.public_pages_used, u64(1))
	testing.expect_value(t, cache.private_pages_used, u64(3))

	// Duplicate insert for the same (principal, store, hash) reports Already_Present.
	dup_slot, dup_res := insert_private(&cache, 1, 10, shared_hash, 999, 500, 1)
	testing.expect_value(t, dup_res, Insert_Result.Already_Present)
	testing.expect_value(t, dup_slot, p1s10_slot)
	testing.expect_value(t, cache.private_count, 3)

	// Each lookup returns only its own handle.
	e_pub, idx_pub, ok_pub := lookup_public(&cache, shared_hash)
	testing.expect(t, ok_pub && idx_pub == pub_slot && e_pub.memory_handle == 100)

	e1, _, ok1 := lookup_private(&cache, 1, 10, shared_hash)
	testing.expect(t, ok1 && e1.memory_handle == 201)

	e2, _, ok2 := lookup_private(&cache, 1, 11, shared_hash)
	testing.expect(t, ok2 && e2.memory_handle == 202)

	e3, _, ok3 := lookup_private(&cache, 2, 10, shared_hash)
	testing.expect(t, ok3 && e3.memory_handle == 203)

	// Principal 3 sees nothing for the same hash and store.
	_, _, ok4 := lookup_private(&cache, 3, 10, shared_hash)
	testing.expect(t, !ok4)
}

// Public_System entries are completely immune to private quota pressure and
// private slot exhaustion.
@(test)
public_entries_immune_to_private_pressure :: proc(t: ^testing.T) {
	cache: Cache
	cache_init(&cache, {
		machine_budget_pages    = 4,
		global_private_pages    = 1024,
		principal_private_pages = 1024,
	})

	// Insert one public system object with holdings == 1 (idle).
	pub_h := test_hash(7)
	_, pub_res := insert_public(&cache, pub_h, 50, 4096, 2)
	testing.expect_value(t, pub_res, Insert_Result.Inserted)

	// Exhaust ALL PRIVATE_CACHE_CAPACITY slots with private entries.
	for i in 0 ..< PRIVATE_CACHE_CAPACITY {
		h := test_hash(u8(i & 0xFF), u8(i >> 8))
		_, res := insert_private(&cache, 1, 1, h, u64(1000 + i), 100, 1)
		testing.expect_value(t, res, Insert_Result.Inserted)
	}
	// Next private insert fails with Table_Full.
	_, full_res := insert_private(&cache, 1, 1, test_hash(250, 99), 9999, 100, 1)
	testing.expect_value(t, full_res, Insert_Result.Table_Full)

	// Public_System still inserts freely from its own slot pool and budget.
	_, pub_res2 := insert_public(&cache, test_hash(8), 51, 4096, 2)
	testing.expect_value(t, pub_res2, Insert_Result.Inserted)
	testing.expect_value(t, cache.public_count, 2)
	testing.expect_value(t, cache.public_pages_used, u64(4))

	// Public budget exhaustion returns Quota_Exceeded without touching private.
	_, pub_over := insert_public(&cache, test_hash(9), 52, 4096, 1)
	testing.expect_value(t, pub_over, Insert_Result.Quota_Exceeded)

	// Private eviction with Any_Private never returns a Public_System handle
	// even if every private entry has holdings > 1 and the public entry has
	// holdings == 1.
	all_active_private :: proc "contextless" (memory_handle: u64, _: rawptr) -> (u64, bool) {
		if memory_handle < 100 {
			return 1, true // Public entries are idle.
		}
		return 2, true // Every private entry is actively mapped.
	}
	_, eres := evict_candidate(&cache, 1, .Any_Private, all_active_private, nil)
	testing.expect_value(t, eres, Evict_Result.None_Eligible)
}

// Non-crashing eviction skips entries with holdings > 1 (or failed query),
// selects the LRU holdings == 1 entry of the appropriate scope, and refuses
// with None_Eligible when every candidate is actively mapped.
@(test)
non_crashing_eviction_skips_active_readers :: proc(t: ^testing.T) {
	cache: Cache
	cache_init(&cache, {
		machine_budget_pages    = 10,
		global_private_pages    = 6,
		principal_private_pages = 4,
	})

	h1 := test_hash(1)
	h2 := test_hash(2)
	h3 := test_hash(3)
	h4 := test_hash(4)
	p2_h := test_hash(5)

	_, r1 := insert_private(&cache, 1, 1, h1, 101, 4096, 2) // tick 1 (oldest)
	testing.expect_value(t, r1, Insert_Result.Inserted)
	_, r2 := insert_private(&cache, 1, 1, h2, 102, 4096, 1) // tick 2
	testing.expect_value(t, r2, Insert_Result.Inserted)
	_, r3 := insert_private(&cache, 1, 1, h3, 103, 4096, 1) // tick 3
	testing.expect_value(t, r3, Insert_Result.Inserted)

	// Principal 1 is now at 4/4 pages; inserting 1 more page hits Quota_Exceeded.
	_, over := insert_private(&cache, 1, 1, h4, 104, 4096, 1)
	testing.expect_value(t, over, Insert_Result.Quota_Exceeded)

	// Principal 2 inserts 2 pages (idle) -> global 6/6.
	_, p2_r := insert_private(&cache, 2, 2, p2_h, 201, 4096, 2)
	testing.expect_value(t, p2_r, Insert_Result.Inserted)

	mock: Mock_Holdings
	// All three of principal 1's entries are actively mapped (holdings > 1).
	// Principal 2's entry is idle (holdings == 1).
	mock_holdings_set(&mock, 101, 3)
	mock_holdings_set(&mock, 102, 2)
	mock_holdings_set(&mock, 103, 2)
	mock_holdings_set(&mock, 201, 1)

	// Same_Principal eviction for principal 1 finds NONE eligible (must NOT
	// evict active handles and must NOT touch principal 2).
	_, eres := evict_candidate(&cache, 1, .Same_Principal, mock_holdings_query, &mock)
	testing.expect_value(t, eres, Evict_Result.None_Eligible)

	// Mark handle 102 and 103 idle, touch 102 via lookup so 103 becomes older.
	mock_holdings_set(&mock, 102, 1)
	mock_holdings_set(&mock, 103, 1)
	_, _, hit := lookup_private(&cache, 1, 1, h2) // updates tick of h2 past h3
	testing.expect(t, hit)

	// Handle 101 is still oldest overall, but has holdings == 3 -> skipped.
	// Between 102 (newer) and 103 (older), 103 must be chosen.
	cand, found_res := evict_candidate(&cache, 1, .Same_Principal, mock_holdings_query, &mock)
	testing.expect_value(t, found_res, Evict_Result.Found)
	testing.expect_value(t, cand.memory_handle, u64(103))

	// Removing the evicted slot frees 1 page, allowing h4 to insert.
	removed, rm_ok := remove_private_slot(&cache, cand.slot_index)
	testing.expect(t, rm_ok && removed.memory_handle == 103)
	testing.expect_value(t, principal_private_pages_used(&cache, 1), u64(3))

	_, r4 := insert_private(&cache, 1, 1, h4, 104, 4096, 1)
	testing.expect_value(t, r4, Insert_Result.Inserted)
	testing.expect_value(t, principal_private_pages_used(&cache, 1), u64(4))

	// Failed holdings query (ok = false) or holdings == 0 is also skipped.
	mock_holdings_set(&mock, 102, 1, false)
	mock_holdings_set(&mock, 104, 0, true)
	_, eres2 := evict_candidate(&cache, 1, .Same_Principal, mock_holdings_query, &mock)
	testing.expect_value(t, eres2, Evict_Result.None_Eligible)
}

// Principal_Locked / Principal_Reclaim purges EVERY private entry of that
// principal regardless of holdings > 1, even across multiple bounded drain
// passes, while leaving Public_System and other principals intact.
@(test)
reclaim_principal_purges_active_entries_and_isolates_others :: proc(t: ^testing.T) {
	cache: Cache
	cache_init(&cache, default_cache_config())

	// Public entry (principal 0) and principal 2 entry must survive.
	_, r_pub := insert_public(&cache, test_hash(1), 10, 4096, 2)
	testing.expect_value(t, r_pub, Insert_Result.Inserted)
	_, r_p0 := insert_private(&cache, 0, 1, test_hash(2), 20, 4096, 1)
	testing.expect_value(t, r_p0, Insert_Result.Inserted)
	_, r_p2 := insert_private(&cache, 2, 5, test_hash(3), 30, 4096, 3)
	testing.expect_value(t, r_p2, Insert_Result.Inserted)

	// Principal 1 has 5 entries across two stores (simulate active readers).
	for i in 0 ..< 5 {
		_, r := insert_private(&cache, 1, u32(10 + (i % 2)), test_hash(u8(10 + i)), u64(100 + i), 4096, 2)
		testing.expect_value(t, r, Insert_Result.Inserted)
	}
	testing.expect_value(t, principal_private_pages_used(&cache, 1), u64(10))

	// Drain in bounded chunks of 2 to verify multi-pass draining drops nothing.
	buf: [2]Evicted_Entry
	total_reclaimed := 0
	for {
		written, remaining := reclaim_principal(&cache, 1, buf[:])
		total_reclaimed += written
		for i in 0 ..< written {
			testing.expect_value(t, buf[i].principal_id, u64(1))
			testing.expect_value(t, buf[i].class, Cache_Class.Private_Principal)
		}
		if remaining == 0 {
			break
		}
		testing.expect_value(t, written, 2)
	}
	testing.expect_value(t, total_reclaimed, 5)
	testing.expect_value(t, principal_private_pages_used(&cache, 1), u64(0))
	testing.expect_value(t, cache.private_count, 2) // p0 + p2 remain
	testing.expect_value(t, cache.private_pages_used, u64(4))
	testing.expect_value(t, cache.public_count, 1)
	testing.expect_value(t, cache.public_pages_used, u64(2))

	// Reclaiming principal 0 clears principal 0's private entries only, NEVER Public_System.
	w0, rem0 := reclaim_principal(&cache, 0, buf[:])
	testing.expect_value(t, w0, 1)
	testing.expect_value(t, rem0, 0)
	testing.expect_value(t, cache.public_count, 1)
	_, _, pub_alive := lookup_public(&cache, test_hash(1))
	testing.expect(t, pub_alive)

	// Principal 2 still intact.
	_, _, p2_alive := lookup_private(&cache, 2, 5, test_hash(3))
	testing.expect(t, p2_alive)
}

// Durable pin accounting: quota exhaustion, count limit saturation, underflow
// refusal, GC protection across multiple principals, release once all principals
// unpin, principal reclaim cleanup, and bounded pins_list inspection.
@(test)
durable_pin_accounting_and_gc_protection :: proc(t: ^testing.T) {
	pins: Pin_Table
	pin_table_init(&pins, 2) // Per-principal quota = 2 distinct objects.

	h1 := test_hash(11)
	h2 := test_hash(12)
	h3 := test_hash(13)

	// Initially unpinned; remove refuses underflow.
	testing.expect(t, !is_pinned(&pins, 7, h1))
	_, rm_res := pin_remove(&pins, 1, 7, h1)
	testing.expect_value(t, rm_res, Pin_Result.Not_Found)

	// Principal 1 pins h1 twice and h2 once -> quota 2/2 reached.
	cnt, res := pin_add(&pins, 1, 7, h1)
	testing.expect(t, res == .Ok && cnt == 1)
	cnt, res = pin_add(&pins, 1, 7, h1)
	testing.expect(t, res == .Ok && cnt == 2)
	cnt, res = pin_add(&pins, 1, 7, h2)
	testing.expect(t, res == .Ok && cnt == 1)

	// Adding a 3rd distinct object for principal 1 hits Quota_Exceeded.
	_, res = pin_add(&pins, 1, 7, h3)
	testing.expect_value(t, res, Pin_Result.Quota_Exceeded)

	// Principal 2 has its own quota and can pin h1 in the same store.
	cnt, res = pin_add(&pins, 2, 7, h1)
	testing.expect(t, res == .Ok && cnt == 1)
	testing.expect(t, is_pinned(&pins, 7, h1))

	// GC protection stays active while principal 1 unpins h1 completely,
	// because principal 2 still holds a pin on (store 7, h1).
	cnt, res = pin_remove(&pins, 1, 7, h1)
	testing.expect(t, res == .Ok && cnt == 1)
	testing.expect(t, is_pinned(&pins, 7, h1))
	cnt, res = pin_remove(&pins, 1, 7, h1)
	testing.expect(t, res == .Ok && cnt == 0)
	testing.expect(t, is_pinned(&pins, 7, h1)) // still pinned by principal 2!

	// Extra unpin by principal 1 refuses underflow.
	_, res = pin_remove(&pins, 1, 7, h1)
	testing.expect_value(t, res, Pin_Result.Not_Found)

	// Once principal 2 unpins h1, GC can reclaim (store 7, h1).
	cnt, res = pin_remove(&pins, 2, 7, h1)
	testing.expect(t, res == .Ok && cnt == 0)
	testing.expect(t, !is_pinned(&pins, 7, h1))

	// Count saturation up to PIN_COUNT_LIMIT refuses further increments cleanly.
	for step in 1 ..= PIN_COUNT_LIMIT {
		c, r := pin_add(&pins, 2, 9, h3)
		testing.expect(t, r == .Ok && c == step)
	}
	c_sat, r_sat := pin_add(&pins, 2, 9, h3)
	testing.expect(t, r_sat == .Count_Limit && c_sat == PIN_COUNT_LIMIT)

	// pins_list reports exact totals even when caller buffer is smaller.
	small_out: [1]Pin_Info
	written, total := pins_list(&pins, 0, false, small_out[:])
	testing.expect_value(t, written, 1)
	testing.expect_value(t, total, 2) // p1:h2 and p2:h3

	p2_out: [4]Pin_Info
	w2, t2 := pins_list(&pins, 2, true, p2_out[:])
	testing.expect_value(t, w2, 1)
	testing.expect_value(t, t2, 1)
	testing.expect_value(t, p2_out[0].principal_id, u64(2))
	testing.expect_value(t, p2_out[0].store_index, u32(9))
	testing.expect_value(t, p2_out[0].pin_count, PIN_COUNT_LIMIT)

	// Principal_Reclaim removes all durable pins of principal 2 immediately.
	rm_entries, rm_pins := reclaim_principal_pins(&pins, 2)
	testing.expect_value(t, rm_entries, 1)
	testing.expect_value(t, rm_pins, u64(PIN_COUNT_LIMIT))
	testing.expect(t, !is_pinned(&pins, 9, h3))
	testing.expect(t, is_pinned(&pins, 7, h2)) // principal 1 unaffected
}
