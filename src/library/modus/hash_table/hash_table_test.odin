#+build !freestanding
package hash_table

import "core:fmt"
import "core:testing"
import "modus:fast_hash"

// A generator with a fixed seed, so each host gets the same inputs:
// splitmix64.
Test_Random :: struct {
	state: u64,
}

next_random :: proc(random: ^Test_Random) -> u64 {
	random.state += 0x9E37_79B9_7F4A_7C15
	z := random.state
	z = (z ~ (z >> 30)) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ (z >> 27)) * 0x94D0_49BB_1331_11EB
	return z ~ (z >> 31)
}

// ---- The group match: the SSE2 form against the scalar form.

@(test)
group_forms_give_the_mask_of_the_scalar_form :: proc(t: ^testing.T) {
	when ODIN_ARCH == .amd64 {
		random := Test_Random{state = 1}
		controls: [GROUP_WIDTH]u8
		// Each byte value in each lane, the other lanes random.
		for lane in 0 ..< GROUP_WIDTH {
			for value in 0 ..= 255 {
				for &control in controls {
					control = u8(next_random(&random))
				}
				controls[lane] = u8(value)
				for tag in ([?]u8{0x80, 0x81, 0xFF, u8(value) | FULL_BIT, u8(value)}) {
					testing.expectf(t, group_match_tag_sse2(&controls, tag) == group_match_tag_scalar(&controls, tag), "the tag %2x over %v: the SSE2 mask %4x, the scalar mask %4x", tag, controls, group_match_tag_sse2(&controls, tag), group_match_tag_scalar(&controls, tag))
				}
				testing.expectf(t, group_match_empty_sse2(&controls) == group_match_empty_scalar(&controls), "empty over %v", controls)
				testing.expectf(t, group_match_free_sse2(&controls) == group_match_free_scalar(&controls), "free over %v", controls)
			}
		}
		// The edge groups: all empty, all deleted, all full with one tag.
		for value in ([?]u8{0x00, 0x01, 0x80, 0xFF, 0x7F}) {
			for &control in controls {
				control = value
			}
			testing.expect(t, group_match_tag_sse2(&controls, value) == group_match_tag_scalar(&controls, value))
			testing.expect(t, group_match_empty_sse2(&controls) == group_match_empty_scalar(&controls))
			testing.expect(t, group_match_free_sse2(&controls) == group_match_free_scalar(&controls))
		}
	}
}

@(test)
group_scalar_form_reads_each_mark :: proc(t: ^testing.T) {
	controls: [GROUP_WIDTH]u8
	controls[0] = u8(Control_Mark.Empty)
	controls[1] = u8(Control_Mark.Deleted)
	controls[2] = 0x80 // A full slot with the tag 0.
	controls[15] = 0xFF // A full slot with the tag 0x7F.
	for lane in 3 ..< 15 {
		controls[lane] = 0x85
	}
	testing.expect_value(t, group_match_empty_scalar(&controls), 0b1)
	testing.expect_value(t, group_match_free_scalar(&controls), 0b11)
	testing.expect_value(t, group_match_tag_scalar(&controls, 0x80), 0b100)
	testing.expect_value(t, group_match_tag_scalar(&controls, 0xFF), 0x8000)
	testing.expect_value(t, group_match_tag_scalar(&controls, 0x85), 0x7FF8)
	// The marks are not tags: no full slot has a tag of 0 or 1 with bit 7 clear.
	testing.expect_value(t, group_match_tag_scalar(&controls, 0x00), 0b1)
}

// ---- The edges of a table.

Small_Table :: Hash_Table(u64, u64, 1) // One group: 14 keys at most.
Wide_Table :: Hash_Table(u64, u64, 64)

// table_bytes copies a table, to check that a refusal changed nothing.
table_bytes :: proc(table: ^$T) -> [size_of(T)]u8 {
	return (^[size_of(T)]u8)(table)^
}

@(test)
empty_table_finds_nothing :: proc(t: ^testing.T) {
	table: Small_Table
	before := table_bytes(&table)
	for key in ([?]u64{0, 1, 0x80, max(u64)}) {
		_, found := find(&table, key)
		testing.expectf(t, !found, "the key %x is in an empty table", key)
		testing.expectf(t, !remove(&table, key), "the key %x left an empty table", key)
	}
	place := 0
	_, _, ok := iterate(&table, &place)
	testing.expect(t, !ok)
	testing.expect(t, table_bytes(&table) == before, "a search or a refused remove changed an empty table")
	testing.expect_value(t, entry_capacity(&table), 14)
}

@(test)
one_entry :: proc(t: ^testing.T) {
	table: Wide_Table
	testing.expect_value(t, insert(&table, 0, 7), Insert_Outcome.Added)
	value, found := find(&table, 0)
	testing.expect(t, found && value^ == 7)
	testing.expect_value(t, insert(&table, 0, 8), Insert_Outcome.Replaced)
	testing.expect_value(t, table.count, 1)
	value, found = find(&table, 0)
	testing.expect(t, found && value^ == 8)
	_, found = find(&table, 1)
	testing.expect(t, !found)
	place := 0
	key, iterated, ok := iterate(&table, &place)
	testing.expect(t, ok && key == 0 && iterated^ == 8)
	_, _, ok = iterate(&table, &place)
	testing.expect(t, !ok)
	testing.expect(t, remove(&table, 0))
	testing.expect_value(t, table.count, 0)
	testing.expect(t, !remove(&table, 0))
}

// A key equal to the byte of a mark, or with every bit set, is a key like
// another: the marks are in the control bytes, never in the keys.
@(test)
keys_equal_to_the_marks :: proc(t: ^testing.T) {
	table: Wide_Table
	keys := [?]u64{0, 1, 0x80, 0x81, 0xFF, max(u64), max(u64) - 1, 0x0101_0101_0101_0101}
	for key, place in keys {
		testing.expect_value(t, insert(&table, key, u64(place)), Insert_Outcome.Added)
	}
	for key, place in keys {
		value, found := find(&table, key)
		testing.expectf(t, found && value^ == u64(place), "the key %x", key)
	}
	for control in table.controls {
		testing.expect(t, control & FULL_BIT != 0 || control == u8(Control_Mark.Empty), "a control byte that is neither full nor empty")
	}
}

// The capacity bound and one past it, in a table of one group: the 14th key
// is taken, the 15th refused with nothing changed, and a key that is in
// the table still takes a new value.
@(test)
capacity_bound_and_one_past :: proc(t: ^testing.T) {
	table: Small_Table
	for key in 0 ..< u64(14) {
		testing.expectf(t, insert(&table, key, key) == .Added, "the key %d", key)
	}
	testing.expect_value(t, table.count, 14)
	before := table_bytes(&table)
	testing.expect_value(t, insert(&table, 14, 14), Insert_Outcome.Full)
	testing.expect_value(t, insert(&table, max(u64), 0), Insert_Outcome.Full)
	testing.expect(t, table_bytes(&table) == before, "a refused insert changed the table")
	testing.expect_value(t, insert(&table, 13, 99), Insert_Outcome.Replaced)
	value, found := find(&table, 13)
	testing.expect(t, found && value^ == 99)
	_, found = find(&table, 14)
	testing.expect(t, !found)
	// A remove makes room again.
	testing.expect(t, remove(&table, 0))
	testing.expect_value(t, insert(&table, 14, 14), Insert_Outcome.Added)
	for key in 1 ..= u64(14) {
		_, found = find(&table, key)
		testing.expectf(t, found, "the key %d", key)
	}
}

// keys_with gives count keys whose hash in the table satisfies a test,
// found by a search over the integers.
keys_with :: proc(table: ^$T/Hash_Table(u64, $V, $N), count: int, wanted: proc(hash: u64) -> bool) -> [dynamic]u64 {
	keys := make([dynamic]u64, context.temp_allocator)
	for key := u64(0); len(keys) < count; key += 1 {
		key := key
		if wanted(hash_of_key(&key, table.prepared_seed)) {
			append(&keys, key)
		}
	}
	return keys
}

// All the keys with one tag: each search compares the key of each slot
// that matches, and finds the right one.
@(test)
all_keys_with_one_tag :: proc(t: ^testing.T) {
	table: Wide_Table
	keys := keys_with(&table, entry_capacity(&table), proc(hash: u64) -> bool {return hash & TAG_MASK == 0x2A})
	for key, place in keys {
		testing.expect_value(t, insert(&table, key, u64(place)), Insert_Outcome.Added)
	}
	for key, place in keys {
		value, found := find(&table, key)
		testing.expectf(t, found && value^ == u64(place), "the key %d", key)
	}
	for key in keys[:100] {
		testing.expect(t, remove(&table, key))
	}
	for key, place in keys[100:] {
		value, found := find(&table, key)
		testing.expectf(t, found && value^ == u64(place + 100), "the key %d after the removes", key)
	}
}

// All the keys in one first group: they fill it, then the groups of its
// probe sequence; a remove in the full group leaves a tombstone, and each
// key past it is still found.
@(test)
all_keys_in_one_first_group :: proc(t: ^testing.T) {
	table: Wide_Table
	keys := keys_with(&table, 200, proc(hash: u64) -> bool {return first_group(hash, 64) == 5})
	for key in keys {
		testing.expect_value(t, insert(&table, key, key), Insert_Outcome.Added)
	}
	testing.expect_value(t, group_match_free_scalar((^[GROUP_WIDTH]u8)(&table.controls[5 * GROUP_WIDTH])), 0)
	// The first key is in group 5, which is full: its slot becomes a tombstone.
	testing.expect(t, remove(&table, keys[0]))
	testing.expect_value(t, table.deleted_count, 1)
	for key in keys[1:] {
		value, found := find(&table, key)
		testing.expectf(t, found && value^ == key, "the key %d past a tombstone", key)
	}
	// The last key is in a group with empty slots: its slot becomes empty.
	testing.expect(t, remove(&table, keys[len(keys) - 1]))
	testing.expect_value(t, table.deleted_count, 1)
	// A new key of the same first group takes the tombstone.
	testing.expect_value(t, insert(&table, keys[0], 1), Insert_Outcome.Added)
	testing.expect_value(t, table.deleted_count, 0)
	testing.expect(t, find_slot_in_group(&table, keys[0], 5), "the key did not take the tombstone of its first group")
}

find_slot_in_group :: proc(table: ^Wide_Table, key: u64, group: int) -> bool {
	for lane in 0 ..< GROUP_WIDTH {
		if table.controls[group * GROUP_WIDTH + lane] & FULL_BIT != 0 && table.keys[group * GROUP_WIDTH + lane] == key {
			return true
		}
	}
	return false
}

@(test)
remove_then_insert_again :: proc(t: ^testing.T) {
	table: Wide_Table
	for round in 0 ..< u64(50) {
		for key in 0 ..< u64(500) {
			insert(&table, key, key + round)
		}
		for key in 0 ..< u64(500) {
			testing.expect(t, remove(&table, key))
		}
		testing.expect_value(t, table.count, 0)
	}
	for key in 0 ..< u64(500) {
		_, found := find(&table, key)
		testing.expect(t, !found)
	}
	testing.expect(t, table.count + table.deleted_count <= entry_capacity(&table))
}

// Many removes, then inserts past the load bound of keys and tombstones
// together: the rebuild drops the tombstones, and each key stays found.
// Keys come from splitmix64 rather than sequential integers, because
// sequential integers with a multiplicative hash fill every group evenly to
// 14 of 16 slots and leave no full group to turn into a tombstone.
@(test)
many_removes_then_a_rebuild :: proc(t: ^testing.T) {
	table: Wide_Table
	capacity := entry_capacity(&table)
	random := Test_Random{state = 0x70AB_570E}
	keys := make([]u64, capacity + capacity / 2, context.temp_allocator)
	for &key in keys {
		key = next_random(&random)
	}
	for index in 0 ..< capacity {
		testing.expect_value(t, insert(&table, keys[index], keys[index] * 3), Insert_Outcome.Added)
	}
	for index := 0; index < capacity; index += 2 {
		testing.expect(t, remove(&table, keys[index]))
	}
	tombstones := table.deleted_count
	testing.expect(t, tombstones > 0, "a full table left no tombstone")
	rebuilt := false
	for index in capacity ..< len(keys) {
		before := table.deleted_count
		testing.expect_value(t, insert(&table, keys[index], keys[index] * 3), Insert_Outcome.Added)
		if before > 1 && table.deleted_count == 0 {
			rebuilt = true
		}
	}
	testing.expect(t, rebuilt, "inserting past the load bound of keys and tombstones did not rebuild")
	testing.expect_value(t, table.count, capacity)
	testing.expect(t, table.count + table.deleted_count <= capacity)
	for index in 0 ..< len(keys) {
		value, found := find(&table, keys[index])
		if index < capacity && index % 2 == 0 {
			testing.expectf(t, !found, "the removed key %d is found", index)
		} else {
			testing.expectf(t, found && value^ == keys[index] * 3, "the key %d after the rebuild", index)
		}
	}
	testing.expect_value(t, insert(&table, max(u64), 0), Insert_Outcome.Full)
}

@(test)
seed_set_only_on_an_empty_table :: proc(t: ^testing.T) {
	table: Wide_Table
	testing.expect(t, seed_set(&table, 0x0123_4567_89AB_CDEF))
	testing.expect_value(t, table.prepared_seed, fast_hash.seed_prepare(0x0123_4567_89AB_CDEF))
	insert(&table, 5, 5)
	before := table_bytes(&table)
	testing.expect(t, !seed_set(&table, 1), "a table with a key took a new seed")
	testing.expect(t, table_bytes(&table) == before)
	// A tombstone also depends on the seed.
	for key in 0 ..< u64(entry_capacity(&table)) {
		insert(&table, key, key)
	}
	remove(&table, 5)
	for key in 0 ..< u64(entry_capacity(&table)) {
		remove(&table, key)
	}
	testing.expect_value(t, table.count, 0)
	if table.deleted_count > 0 {
		testing.expect(t, !seed_set(&table, 1), "a table with tombstones took a new seed")
	}
	clear(&table)
	testing.expect_value(t, table.prepared_seed, fast_hash.seed_prepare(0x0123_4567_89AB_CDEF))
	testing.expect(t, seed_set(&table, 1))
}

// A key of bytes: the hash of a key that is not 8 bytes long.
Byte_Key :: struct {
	bytes: [12]u8,
	kind:  u32,
}

@(test)
keys_of_bytes :: proc(t: ^testing.T) {
	table: Hash_Table(Byte_Key, int, 8)
	keys: [100]Byte_Key
	for &key, place in keys {
		key.bytes[place % 12] = u8(place)
		key.kind = u32(place / 12)
		testing.expect_value(t, insert(&table, key, place), Insert_Outcome.Added)
	}
	for key, place in keys {
		value, found := find(&table, key)
		testing.expectf(t, found && value^ == place, "the key %v", key)
	}
	other := keys[3]
	other.kind = 99
	_, found := find(&table, other)
	testing.expect(t, !found)
}

// ---- The fuzz test: random operations against a list.

Reference_Entry :: struct {
	key:   u64,
	value: u64,
}

reference_find :: proc(reference: []Reference_Entry, key: u64) -> int {
	for entry, place in reference {
		if entry.key == key {
			return place
		}
	}
	return -1
}

// fuzz_table runs operations on a table and on a list, and compares them
// after each one. It gives the operations run; the seed is in each fault.
fuzz_table :: proc(t: ^testing.T, table: ^$T/Hash_Table(u64, u64, $N), seed: u64, operations: int, key_space: u64, counts: ^Fuzz_Counts) -> int {
	random := Test_Random{state = seed}
	reference := make([dynamic]Reference_Entry, context.temp_allocator)
	capacity := entry_capacity(table)
	for operation in 0 ..< operations {
		counts.operations += 1
		draw := next_random(&random)
		key := next_random(&random) % key_space
		// Edge keys sometimes.
		switch draw % 64 {
		case 0:
			key = 0
		case 1:
			key = max(u64)
		}
		value := next_random(&random)
		at := reference_find(reference[:], key)
		switch draw % 100 {
		case 0 ..< 45:
			tombstones_before := table.deleted_count
			at_the_load_bound := table.count + table.deleted_count == capacity
			outcome := insert(table, key, value)
			wanted: Insert_Outcome = at >= 0 ? .Replaced : (len(reference) >= capacity ? .Full : .Added)
			if outcome == .Full {
				counts.refused_as_full += 1
			}
			if outcome == .Added && at_the_load_bound && tombstones_before > 1 && table.deleted_count == 0 {
				counts.rebuilds += 1
			}
			if outcome != wanted {
				testing.expectf(t, false, "seed %x, operation %d: insert %x gave %v; the list wants %v", seed, operation, key, outcome, wanted)
				return operation
			}
			switch wanted {
			case .Replaced:
				reference[at].value = value
			case .Added:
				append(&reference, Reference_Entry{key, value})
			case .Full:
			}
		case 45 ..< 80:
			removed := remove(table, key)
			if removed != (at >= 0) {
				testing.expectf(t, false, "seed %x, operation %d: remove %x gave %v", seed, operation, key, removed)
				return operation
			}
			if at >= 0 {
				unordered_remove(&reference, at)
			}
		case 80 ..< 99:
			found_value, found := find(table, key)
			if found != (at >= 0) || (found && found_value^ != reference[at].value) {
				testing.expectf(t, false, "seed %x, operation %d: find %x gave %v", seed, operation, key, found)
				return operation
			}
		case:
			// Rare: a clear.
			if draw % 1000 == 999 {
				clear(table)
				resize(&reference, 0)
			}
		}
		if table.count != len(reference) || table.count + table.deleted_count > capacity {
			testing.expectf(t, false, "seed %x, operation %d: %d keys and %d tombstones; the list holds %d", seed, operation, table.count, table.deleted_count, len(reference))
			return operation
		}
		// The whole content, from time to time and at the end.
		if operation % 97 == 0 || operation == operations - 1 {
			for entry in reference {
				found_value, found := find(table, entry.key)
				if !found || found_value^ != entry.value {
					testing.expectf(t, false, "seed %x, operation %d: the key %x of the list is not in the table", seed, operation, entry.key)
					return operation
				}
			}
			place, iterated := 0, 0
			for iterated_key, iterated_value in iterate(table, &place) {
				at_key := reference_find(reference[:], iterated_key)
				if at_key < 0 || reference[at_key].value != iterated_value^ {
					testing.expectf(t, false, "seed %x, operation %d: the iterate gave the key %x, which the list does not hold", seed, operation, iterated_key)
					return operation
				}
				iterated += 1
			}
			if iterated != len(reference) {
				testing.expectf(t, false, "seed %x, operation %d: the iterate gave %d keys; the list holds %d", seed, operation, iterated, len(reference))
				return operation
			}
		}
	}
	return operations
}

@(test)
fuzz_against_a_list :: proc(t: ^testing.T) {
	OPERATIONS :: 100_000
	counts: Fuzz_Counts
	{
		table: Hash_Table(u64, u64, 1)
		fuzz_table(t, &table, 0x5157_0001, OPERATIONS, 40, &counts)
	}
	{
		table: Hash_Table(u64, u64, 2)
		fuzz_table(t, &table, 0x5157_0002, OPERATIONS, 60, &counts)
	}
	{
		// Counts of groups that are not a power of two.
		table: Hash_Table(u64, u64, 3)
		fuzz_table(t, &table, 0x5157_0005, OPERATIONS, 70, &counts)
	}
	{
		table: Hash_Table(u64, u64, 5)
		fuzz_table(t, &table, 0x5157_0006, OPERATIONS, 110, &counts)
	}
	{
		table: Hash_Table(u64, u64, 8)
		seed_set(&table, 0xDEAD_BEEF)
		fuzz_table(t, &table, 0x5157_0003, OPERATIONS, 200, &counts)
	}
	{
		// Below the bound of keys: the tombstones alone reach the load
		// bound, so the rebuilds come from them.
		table := new(Hash_Table(u64, u64, 16), context.temp_allocator)
		fuzz_table(t, table, 0x5157_0004, OPERATIONS, 250, &counts)
	}
	fmt.printfln("hash_table: the fuzz test ran %d operations against a list: %d inserts refused as full, %d rebuilds", counts.operations, counts.refused_as_full, counts.rebuilds)
	// A fuzz test that never reaches the bound or a rebuild tests neither.
	testing.expect(t, counts.refused_as_full > 0, "no insert reached the capacity bound")
	testing.expect(t, counts.rebuilds > 0, "no insert rebuilt the table")
}

Fuzz_Counts :: struct {
	operations:      int,
	refused_as_full: int,
	rebuilds:        int,
}

// A hash with no spread: every key of a table of tags with one value and
// one first group, as a party that knows the seed can choose. Each search
// is bounded by the groups, and the table stays right.
@(test)
keys_with_one_tag_and_one_group :: proc(t: ^testing.T) {
	table: Hash_Table(u64, u64, 8)
	keys := keys_with(&table, entry_capacity(&table), proc(hash: u64) -> bool {return hash & TAG_MASK == 1 && first_group(hash, 8) == 3})
	for key in keys {
		testing.expect_value(t, insert(&table, key, key), Insert_Outcome.Added)
	}
	for key in keys {
		value, found := find(&table, key)
		testing.expect(t, found && value^ == key)
	}
}
