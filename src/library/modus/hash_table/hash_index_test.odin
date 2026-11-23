#+build !freestanding
package hash_table

import "core:fmt"
import "core:testing"

// The records of a caller of an index: the key of each record, and the
// records in use. The index maps a key to the number of its record.
Test_Records :: struct($CAPACITY: int) {
	keys:    [CAPACITY]u64,
	in_use:  [CAPACITY]bool,
	index:   Hash_Index(u16, 5), // 80 slots, 70 references: a count of groups that is not a power of two.
}

test_records_hash_of :: proc "contextless" (owner: rawptr, reference: u64) -> u64 {
	records := (^Test_Records(80))(owner)
	return index_hash_word(&records.index, records.keys[reference])
}

// test_records_find gives the record and the slot of a key, or -1.
test_records_find :: proc(records: ^Test_Records(80), key: u64) -> (record, slot: int) {
	search := index_search_begin(&records.index, index_hash_word(&records.index, key))
	for reference, found_slot in index_search_next(&records.index, &search) {
		if records.keys[reference] == key {
			return int(reference), found_slot
		}
	}
	return -1, -1
}

@(test)
index_refuses_a_slot_that_holds_no_reference :: proc(t: ^testing.T) {
	records: Test_Records(80)
	records.keys[3] = 0xABCD
	testing.expect(t, index_insert(&records.index, index_hash_word(&records.index, 0xABCD), 3, &records, test_records_hash_of))
	record, slot := test_records_find(&records, 0xABCD)
	testing.expect_value(t, record, 3)
	before := table_bytes(&records.index)
	slot_count := len(records.index.controls)
	for refused in ([?]int{-1, slot_count, slot_count + 1, max(int), min(int), slot == 0 ? 1 : 0}) {
		testing.expectf(t, !index_remove_slot(&records.index, refused), "the slot %d holds no reference, and its removal was taken", refused)
	}
	testing.expect(t, table_bytes(&records.index) == before, "a refused removal changed the index")
	testing.expect(t, index_remove_slot(&records.index, slot))
	testing.expect(t, !index_remove_slot(&records.index, slot), "a slot was removed twice")
	record, _ = test_records_find(&records, 0xABCD)
	testing.expect_value(t, record, -1)
	testing.expect_value(t, records.index.count, 0)
}

identity_hash_of_reference :: proc "contextless" (owner: rawptr, reference: u64) -> u64 {
	return reference * 0x9E37_79B9_7F4A_7C15
}

@(test)
index_refuses_nil_hash_of_reference :: proc(t: ^testing.T) {
	index: Hash_Index(u16, 1)
	before := table_bytes(&index)
	testing.expect(t, !index_insert(&index, 99, 0, nil, nil), "an index accepted a nil hash_of_reference")
	testing.expect(t, table_bytes(&index) == before, "a refused insert changed the index")
}

@(test)
index_capacity_bound :: proc(t: ^testing.T) {
	index: Hash_Index(u16, 1)
	for reference in 0 ..< 14 {
		testing.expect(t, index_insert(&index, identity_hash_of_reference(nil, u64(reference)), u16(reference), nil, identity_hash_of_reference))
	}
	before := table_bytes(&index)
	testing.expect(t, !index_insert(&index, 99, 14, nil, identity_hash_of_reference), "an index past its bound took a reference")
	testing.expect(t, table_bytes(&index) == before, "a refused insert changed the index")
}

// The fuzz test of an index: random inserts, finds and removes of keys,
// with the records and the index of a caller, against a list.
@(test)
index_fuzz_against_a_list :: proc(t: ^testing.T) {
	OPERATIONS :: 100_000
	records := new(Test_Records(80), context.temp_allocator)
	index_seed_set(&records.index, 0x1DE_0001)
	reference := make([dynamic]u64, context.temp_allocator)
	random := Test_Random{state = 0x1DE_0002}
	capacity := index_entry_capacity(&records.index)
	refused_as_full, rebuilds := 0, 0
	for operation in 0 ..< OPERATIONS {
		draw := next_random(&random)
		key := next_random(&random) % 120
		at := -1
		for kept, place in reference {
			if kept == key {
				at = place
			}
		}
		record, slot := test_records_find(records, key)
		if (record >= 0) != (at >= 0) || (record >= 0 && records.keys[record] != key) {
			testing.expectf(t, false, "seed %x, operation %d: the key %x: record %d, the list %d", u64(0x1DE_0002), operation, key, record, at)
			return
		}
		switch draw % 3 {
		case 0, 1:
			if record >= 0 {
				continue
			}
			free := -1
			for in_use, place in records.in_use {
				if !in_use {
					free = place
					break
				}
			}
			tombstones_before := records.index.deleted_count
			at_the_load_bound := records.index.count + records.index.deleted_count == capacity
			should_fit := len(reference) < capacity
			taken := free >= 0 && index_insert(&records.index, index_hash_word(&records.index, key), u16(free), records, test_records_hash_of)
			if taken != should_fit {
				testing.expectf(t, false, "seed %x, operation %d: index_insert gave %v; wanted %v (count %d, capacity %d)", u64(0x1DE_0002), operation, taken, should_fit, len(reference), capacity)
				return
			}
			if !taken {
				refused_as_full += 1
				continue
			}
			if at_the_load_bound && tombstones_before > 1 && records.index.deleted_count == 0 {
				rebuilds += 1
			}
			records.keys[free] = key
			records.in_use[free] = true
			append(&reference, key)
		case 2:
			if record < 0 {
				continue
			}
			testing.expect(t, index_remove_slot(&records.index, slot))
			records.in_use[record] = false
			unordered_remove(&reference, at)
		}
		if records.index.count != len(reference) || records.index.count + records.index.deleted_count > capacity {
			testing.expectf(t, false, "seed %x, operation %d: %d references and %d tombstones; the list holds %d", u64(0x1DE_0002), operation, records.index.count, records.index.deleted_count, len(reference))
			return
		}
	}
	for key in reference {
		record, _ := test_records_find(records, key)
		testing.expectf(t, record >= 0 && records.keys[record] == key, "the key %x of the list is not in the index", key)
	}
	fmt.printfln("hash_table: the fuzz test of an index ran %d operations against a list: %d inserts refused as full, %d rebuilds", OPERATIONS, refused_as_full, rebuilds)
	testing.expect(t, refused_as_full > 0, "no insert reached the capacity bound")
	testing.expect(t, rebuilds > 0, "no insert rebuilt the index")
}

// ---- Slice_Hash_Index tests: edge cases, refusals, ZII, and fuzzing.

@(test)
slice_index_refuses_bad_buffers_and_zii :: proc(t: ^testing.T) {
	// Zero-initialised Slice_Hash_Index must be safe and refuse mutations.
	empty: Slice_Hash_Index(u32)
	testing.expect_value(t, slice_index_entry_capacity(&empty), 0)
	testing.expect(t, !slice_index_seed_set(&empty, 42))
	testing.expect(t, !slice_index_insert(&empty, 123, 0, nil, identity_hash_of_reference))
	testing.expect(t, !slice_index_remove_slot(&empty, 0))
	search := slice_index_search_begin(&empty, 123)
	_, _, found := slice_index_search_next(&empty, &search)
	testing.expect(t, !found)

	// Bad buffer sizes: 0, < GROUP_WIDTH, non-multiple of GROUP_WIDTH, short references.
	sentinel_controls: [32]u8
	for &b in sentinel_controls {
		b = 0xAA
	}
	refs: [32]u32
	_, ok_zero := slice_index_init(u32, nil, refs[:])
	testing.expect(t, !ok_zero)
	_, ok_small := slice_index_init(u32, sentinel_controls[:15], refs[:])
	testing.expect(t, !ok_small)
	_, ok_non_mult := slice_index_init(u32, sentinel_controls[:17], refs[:])
	testing.expect(t, !ok_non_mult)
	_, ok_short_refs := slice_index_init(u32, sentinel_controls[:32], refs[:16])
	testing.expect(t, !ok_short_refs)
	// Refused init must not touch caller memory.
	for b in sentinel_controls {
		testing.expect_value(t, b, u8(0xAA))
	}

	// Groups calculation edge cases.
	testing.expect_value(t, slice_index_groups_for_entries(-1), 0)
	testing.expect_value(t, slice_index_groups_for_entries(min(int)), 0)
	testing.expect_value(t, slice_index_groups_for_entries(max(int)), 0)
	testing.expect_value(t, slice_index_groups_for_entries(0), 1)
	testing.expect_value(t, slice_index_groups_for_entries(1), 1)
	testing.expect_value(t, slice_index_groups_for_entries(14), 1)
	testing.expect_value(t, slice_index_groups_for_entries(15), 2)
	testing.expect_value(t, slice_index_groups_for_entries(28), 2)
	testing.expect_value(t, slice_index_groups_for_entries(29), 3)
}

@(test)
slice_index_refuses_nil_callback_bad_slot_and_capacity :: proc(t: ^testing.T) {
	controls: [GROUP_WIDTH]u8
	refs: [GROUP_WIDTH]u32
	idx, ok := slice_index_init(u32, controls[:], refs[:], 0x55AA)
	testing.expect(t, ok)
	testing.expect_value(t, entry_capacity(&idx), 14)

	// Refuse nil hash_of_reference without mutating.
	testing.expect(t, !slice_index_insert(&idx, 99, 0, nil, nil))
	testing.expect_value(t, idx.count, 0)

	// Fill to capacity (14), then refuse 15th.
	for r in 0 ..< 14 {
		testing.expect(t, slice_index_insert(&idx, identity_hash_of_reference(nil, u64(r)), u32(r), nil, identity_hash_of_reference))
	}
	testing.expect(t, !slice_index_seed_set(&idx, 77))
	testing.expect(t, !slice_index_insert(&idx, 99, 14, nil, identity_hash_of_reference))
	testing.expect_value(t, idx.count, 14)

	// Refuse out-of-range slots and double removal.
	for bad in ([?]int{-1, GROUP_WIDTH, GROUP_WIDTH + 1, max(int), min(int)}) {
		testing.expect(t, !slice_index_remove_slot(&idx, bad))
	}
	s := slice_index_search_begin(&idx, identity_hash_of_reference(nil, 5))
	found_slot := -1
	for ref, slot in slice_index_search_next(&idx, &s) {
		if ref == 5 {
			found_slot = slot
			break
		}
	}
	testing.expect(t, found_slot >= 0)
	testing.expect(t, slice_index_remove_slot(&idx, found_slot))
	testing.expect(t, !slice_index_remove_slot(&idx, found_slot))
	testing.expect_value(t, idx.count, 13)

	// Clear resets count/tombstones and allows seed_set again.
	clear(&idx)
	testing.expect_value(t, idx.count, 0)
	testing.expect_value(t, idx.deleted_count, 0)
	testing.expect(t, seed_set(&idx, 0x9999))
}

@(test)
slice_index_fuzz_against_a_list :: proc(t: ^testing.T) {
	Slice_Records :: struct {
		keys:   [80]u64,
		in_use: [80]bool,
		index:  Slice_Hash_Index(u32),
	}
	hash_of :: proc "contextless" (owner: rawptr, reference: u64) -> u64 {
		recs := (^Slice_Records)(owner)
		return slice_index_hash_word(&recs.index, recs.keys[reference])
	}
	find_key :: proc(recs: ^Slice_Records, key: u64) -> (record, slot: int) {
		search := slice_index_search_begin(&recs.index, slice_index_hash_word(&recs.index, key))
		for reference, found_slot in slice_index_search_next(&recs.index, &search) {
			if recs.keys[reference] == key {
				return int(reference), found_slot
			}
		}
		return -1, -1
	}

	OPERATIONS :: 100_000
	controls: [5 * GROUP_WIDTH]u8
	refs: [5 * GROUP_WIDTH]u32
	recs := new(Slice_Records, context.temp_allocator)
	init_ok: bool
	recs.index, init_ok = slice_index_init(u32, controls[:], refs[:], 0x511C_0001)
	testing.expect(t, init_ok)

	reference := make([dynamic]u64, context.temp_allocator)
	random := Test_Random{state = 0x511C_0002}
	capacity := entry_capacity(&recs.index)
	refused_as_full, rebuilds := 0, 0
	for operation in 0 ..< OPERATIONS {
		draw := next_random(&random)
		key := next_random(&random) % 120
		at := -1
		for kept, place in reference {
			if kept == key {
				at = place
			}
		}
		record, slot := find_key(recs, key)
		if (record >= 0) != (at >= 0) || (record >= 0 && recs.keys[record] != key) {
			testing.expectf(t, false, "slice_index op %d: key %x record %d list %d", operation, key, record, at)
			return
		}
		switch draw % 3 {
		case 0, 1:
			if record >= 0 {
				continue
			}
			free := -1
			for in_use, place in recs.in_use {
				if !in_use {
					free = place
					break
				}
			}
			tombstones_before := recs.index.deleted_count
			at_bound := recs.index.count + recs.index.deleted_count == capacity
			should_fit := len(reference) < capacity
			taken := free >= 0 && slice_index_insert(&recs.index, slice_index_hash_word(&recs.index, key), u32(free), recs, hash_of)
			if taken != should_fit {
				testing.expectf(t, false, "slice_index op %d: insert %v != %v", operation, taken, should_fit)
				return
			}
			if !taken {
				refused_as_full += 1
				continue
			}
			if at_bound && tombstones_before > 1 && recs.index.deleted_count == 0 {
				rebuilds += 1
			}
			recs.keys[free] = key
			recs.in_use[free] = true
			append(&reference, key)
		case 2:
			if record < 0 {
				continue
			}
			testing.expect(t, slice_index_remove_slot(&recs.index, slot))
			recs.in_use[record] = false
			unordered_remove(&reference, at)
		}
		if recs.index.count != len(reference) || recs.index.count + recs.index.deleted_count > capacity {
			testing.expectf(t, false, "slice_index op %d: count mismatch %d vs %d", operation, recs.index.count, len(reference))
			return
		}
	}
	for key in reference {
		record, _ := find_key(recs, key)
		testing.expectf(t, record >= 0 && recs.keys[record] == key, "slice_index missing key %x", key)
	}
	testing.expect(t, refused_as_full > 0)
	testing.expect(t, rebuilds > 0)
}
