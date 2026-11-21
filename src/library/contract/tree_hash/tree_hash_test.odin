#+build !freestanding
package tree_hash

import "core:fmt"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

@(private = "file")
make_sample_hash :: proc(seed: u8) -> blake3.Hash {
	data := [4]u8{seed, seed ~ 0x5A, seed + 17, 0xA5}
	return blake3.hash(data[:])
}

@(test)
empty_tree_encode_validate_hash_lookup :: proc(t: ^testing.T) {
	buffer: [HEADER_SIZE]u8
	written, refusal := tree_encode(nil, buffer[:])
	testing.expect_value(t, refusal, Tree_Refusal.None)
	testing.expect_value(t, written, HEADER_SIZE)

	count, val_refusal := tree_validate(buffer[:written])
	testing.expect_value(t, val_refusal, Tree_Refusal.None)
	testing.expect_value(t, count, 0)

	hash_a, hash_refusal_a := tree_hash(buffer[:written])
	hash_b, hash_refusal_b := tree_hash(buffer[:written])
	testing.expect_value(t, hash_refusal_a, Tree_Refusal.None)
	testing.expect_value(t, hash_refusal_b, Tree_Refusal.None)
	testing.expect_value(t, hash_a, hash_b)
	// Domain separation: empty tree hash must differ from plain object hash of the same bytes and of empty bytes.
	testing.expect(t, hash_a != blake3.hash(buffer[:written]))
	testing.expect(t, hash_a != blake3.hash(nil))

	_, found, lookup_refusal := tree_lookup(buffer[:written], "missing")
	testing.expect_value(t, lookup_refusal, Tree_Refusal.None)
	testing.expect(t, !found)

	Visit_State :: struct {
		calls: int,
	}
	visit_state: Visit_State
	iter_refusal := tree_iterate(
		buffer[:written],
		proc "contextless" (_: int, _: Tree_Entry, data: rawptr) -> bool {
			(^Visit_State)(data).calls += 1
			return true
		},
		&visit_state,
	)
	testing.expect_value(t, iter_refusal, Tree_Refusal.None)
	testing.expect_value(t, visit_state.calls, 0)
}

@(test)
single_entry_and_multi_entry_roundtrip :: proc(t: ^testing.T) {
	e1, r1 := tree_entry_make(.Object, "alpha", make_sample_hash(1))
	e2, r2 := tree_entry_make(.Tree, "beta", make_sample_hash(2))
	e3, r3 := tree_entry_make(.Object, "gamma.lex", make_sample_hash(3))
	testing.expect_value(t, r1, Tree_Refusal.None)
	testing.expect_value(t, r2, Tree_Refusal.None)
	testing.expect_value(t, r3, Tree_Refusal.None)

	// Single entry tree.
	single_entries := [1]Tree_Entry{e1}
	single_buf: [HEADER_SIZE + ENTRY_SIZE]u8
	single_len, single_ref := tree_encode(single_entries[:], single_buf[:])
	testing.expect_value(t, single_ref, Tree_Refusal.None)
	testing.expect_value(t, single_len, tree_encoded_size(1))
	got1, found1, lref1 := tree_lookup(single_buf[:single_len], "alpha")
	testing.expect_value(t, lref1, Tree_Refusal.None)
	testing.expect(t, found1)
	testing.expect_value(t, got1.kind, Tree_Entry_Kind.Object)
	testing.expect_value(t, got1.hash, e1.hash)
	testing.expect_value(t, tree_entry_name(&got1), "alpha")

	// Multi-entry tree with UTF-8 non-ASCII name too.
	e4, r4 := tree_entry_make(.Object, "résumé", make_sample_hash(4))
	testing.expect_value(t, r4, Tree_Refusal.None)
	entries := [4]Tree_Entry{e1, e2, e3, e4}
	buf: [HEADER_SIZE + 4 * ENTRY_SIZE]u8
	written, refusal := tree_encode(entries[:], buf[:])
	testing.expect_value(t, refusal, Tree_Refusal.None)
	testing.expect_value(t, written, tree_encoded_size(4))

	for &want in entries {
		got, found, lref := tree_lookup(buf[:written], tree_entry_name(&want))
		testing.expect_value(t, lref, Tree_Refusal.None)
		testing.expect(t, found)
		testing.expect_value(t, got.kind, want.kind)
		testing.expect_value(t, got.hash, want.hash)
	}
	_, found_absent, absent_ref := tree_lookup(buf[:written], "delta")
	testing.expect_value(t, absent_ref, Tree_Refusal.None)
	testing.expect(t, !found_absent)

	// Early stop in tree_iterate.
	Stop_State :: struct {
		visited: int,
	}
	stop_state: Stop_State
	iter_ref := tree_iterate(
		buf[:written],
		proc "contextless" (index: int, _: Tree_Entry, data: rawptr) -> bool {
			(^Stop_State)(data).visited += 1
			return index < 1
		},
		&stop_state,
	)
	testing.expect_value(t, iter_ref, Tree_Refusal.None)
	testing.expect_value(t, stop_state.visited, 2)
}

@(test)
max_entries_and_one_past_max :: proc(t: ^testing.T) {
	entries := make([]Tree_Entry, MAX_TREE_ENTRIES + 1)
	defer delete(entries)
	for index in 0 ..< MAX_TREE_ENTRIES + 1 {
		name := fmt.tprintf("entry_%04d", index)
		entry, refusal := tree_entry_make(index % 2 == 0 ? .Object : .Tree, name, make_sample_hash(u8(index & 0xFF)))
		testing.expect_value(t, refusal, Tree_Refusal.None)
		entries[index] = entry
	}

	buffer := make([]u8, MAX_ENCODED_TREE_BYTES + ENTRY_SIZE)
	defer delete(buffer)

	// Exact bound: MAX_TREE_ENTRIES succeeds.
	written, refusal := tree_encode(entries[:MAX_TREE_ENTRIES], buffer[:MAX_ENCODED_TREE_BYTES])
	testing.expect_value(t, refusal, Tree_Refusal.None)
	testing.expect_value(t, written, MAX_ENCODED_TREE_BYTES)
	count, val_ref := tree_validate(buffer[:written])
	testing.expect_value(t, val_ref, Tree_Refusal.None)
	testing.expect_value(t, count, MAX_TREE_ENTRIES)

	// Binary search hits first, middle, and last entry at max bound.
	for target_index in ([3]int{0, MAX_TREE_ENTRIES / 2, MAX_TREE_ENTRIES - 1}) {
		target_name := fmt.tprintf("entry_%04d", target_index)
		got, found, lref := tree_lookup(buffer[:written], target_name)
		testing.expect_value(t, lref, Tree_Refusal.None)
		testing.expect(t, found)
		testing.expect_value(t, got.hash, entries[target_index].hash)
	}

	// Domain separation holds even for multi-chunk (> 1024 bytes) canonical trees.
	max_hash, hash_ref := tree_hash(buffer[:written])
	testing.expect_value(t, hash_ref, Tree_Refusal.None)
	testing.expect(t, max_hash != blake3.hash(buffer[:written]))

	// One past bound: MAX_TREE_ENTRIES + 1 refused, output untouched.
	sentinel := make([]u8, len(buffer))
	defer delete(sentinel)
	for &b in sentinel {
		b = 0xCC
	}
	written_over, ref_over := tree_encode(entries[:MAX_TREE_ENTRIES + 1], sentinel)
	testing.expect_value(t, ref_over, Tree_Refusal.Too_Many_Entries)
	testing.expect_value(t, written_over, 0)
	testing.expect_value(t, sentinel[0], u8(0xCC))

	// Crafted wire header with MAX_TREE_ENTRIES + 1 and max(u32) refused with Too_Many_Entries.
	bad_header: [HEADER_SIZE]u8
	magic := HEADER_MAGIC
	copy(bad_header[0:8], magic[:])
	byte_order.write_u32_little_endian(bad_header[:], 8, u32(MAX_TREE_ENTRIES + 1))
	_, ref_wire_over := tree_validate(bad_header[:])
	testing.expect_value(t, ref_wire_over, Tree_Refusal.Too_Many_Entries)

	byte_order.write_u32_little_endian(bad_header[:], 8, max(u32))
	_, ref_wire_max := tree_validate(bad_header[:])
	testing.expect_value(t, ref_wire_max, Tree_Refusal.Too_Many_Entries)
}

@(test)
unsorted_and_duplicate_names_refused :: proc(t: ^testing.T) {
	a, _ := tree_entry_make(.Object, "a", make_sample_hash(1))
	b, _ := tree_entry_make(.Object, "b", make_sample_hash(2))
	buf: [HEADER_SIZE + 2 * ENTRY_SIZE]u8

	// Unsorted at encode.
	unsorted := [2]Tree_Entry{b, a}
	written, ref := tree_encode(unsorted[:], buf[:])
	testing.expect_value(t, ref, Tree_Refusal.Not_Sorted)
	testing.expect_value(t, written, 0)

	// Duplicate at encode.
	dup := [2]Tree_Entry{a, a}
	written_dup, ref_dup := tree_encode(dup[:], buf[:])
	testing.expect_value(t, ref_dup, Tree_Refusal.Duplicate_Name)
	testing.expect_value(t, written_dup, 0)

	// Valid encode, then mutate wire bytes to test validate directly on unsorted and duplicate.
	sorted := [2]Tree_Entry{a, b}
	valid_len, valid_ref := tree_encode(sorted[:], buf[:])
	testing.expect_value(t, valid_ref, Tree_Refusal.None)

	// Make entry 1 equal to entry 0 -> Duplicate_Name.
	dup_wire := buf
	dup_wire[HEADER_SIZE + ENTRY_SIZE + 2] = 'a'
	_, val_dup := tree_validate(dup_wire[:valid_len])
	testing.expect_value(t, val_dup, Tree_Refusal.Duplicate_Name)

	// Swap entry 0 and entry 1 -> Not_Sorted.
	swap_wire := buf
	swap_wire[HEADER_SIZE + 2] = 'b'
	swap_wire[HEADER_SIZE + ENTRY_SIZE + 2] = 'a'
	_, val_unsorted := tree_validate(swap_wire[:valid_len])
	testing.expect_value(t, val_unsorted, Tree_Refusal.Not_Sorted)
}

@(test)
invalid_names_refused :: proc(t: ^testing.T) {
	// Empty name.
	testing.expect_value(t, tree_name_validate(nil), Tree_Refusal.Empty_Name)

	// Exact bound 64 bytes succeeds, 65 bytes fails with Name_Too_Long.
	max_name: [ENTRY_NAME_CAPACITY]u8
	for &b in max_name {
		b = 'x'
	}
	testing.expect_value(t, tree_name_validate(max_name[:]), Tree_Refusal.None)
	over_name: [ENTRY_NAME_CAPACITY + 1]u8
	for &b in over_name {
		b = 'x'
	}
	testing.expect_value(t, tree_name_validate(over_name[:]), Tree_Refusal.Name_Too_Long)

	// Forbidden path components, separators, control bytes, and malformed UTF-8.
	bad_names := [?][]u8 {
		transmute([]u8)string("."),
		transmute([]u8)string(".."),
		transmute([]u8)string("a/b"),
		transmute([]u8)string("/a"),
		transmute([]u8)string("a/"),
		{0x00},
		{'a', 0x00, 'b'},
		{'a', '\n', 'b'},
		{'a', '\t', 'b'},
		{0x1F},
		{0x7F},
		{0xC2, 0x80}, // U+0080 C1 control
		{0xC2, 0x9F}, // U+009F C1 control
		{0xFF}, // Invalid UTF-8 byte
		{0xC0, 0xAF}, // Overlong '/'
		{0xED, 0xA0, 0x80}, // UTF-16 surrogate U+D800
		{0xF4, 0x90, 0x80, 0x80}, // Above U+10FFFF
		{0xE2, 0x82}, // Truncated 3-byte UTF-8 sequence
	}
	for bad in bad_names {
		testing.expect_value(t, tree_name_validate(bad), Tree_Refusal.Invalid_Name)
	}

	// Non-zero trailing padding byte in canonical wire entry must be refused as Invalid_Name.
	entry, _ := tree_entry_make(.Object, "ok", make_sample_hash(9))
	entries := [1]Tree_Entry{entry}
	buf: [HEADER_SIZE + ENTRY_SIZE]u8
	written, ref := tree_encode(entries[:], buf[:])
	testing.expect_value(t, ref, Tree_Refusal.None)
	buf[HEADER_SIZE + 2 + 2] = 0x01 // Byte right after "ok"
	_, pad_ref := tree_validate(buf[:written])
	testing.expect_value(t, pad_ref, Tree_Refusal.Invalid_Name)
	_, hash_pad_ref := tree_hash(buf[:written])
	testing.expect_value(t, hash_pad_ref, Tree_Refusal.Invalid_Name)

	// Non-zero trailing padding byte in Tree_Entry struct passed to tree_encode refused too.
	dirty_entry := entry
	dirty_entry.name[10] = 'z'
	dirty_list := [1]Tree_Entry{dirty_entry}
	_, dirty_ref := tree_encode(dirty_list[:], buf[:])
	testing.expect_value(t, dirty_ref, Tree_Refusal.Invalid_Name)

	// Wire name_length == 0 and name_length == 65 refused.
	clean_buf: [HEADER_SIZE + ENTRY_SIZE]u8
	_, _ = tree_encode(entries[:], clean_buf[:])
	zero_len_buf := clean_buf
	zero_len_buf[HEADER_SIZE + 1] = 0
	_, zero_len_ref := tree_validate(zero_len_buf[:])
	testing.expect_value(t, zero_len_ref, Tree_Refusal.Empty_Name)

	too_long_buf := clean_buf
	too_long_buf[HEADER_SIZE + 1] = ENTRY_NAME_CAPACITY + 1
	_, too_long_ref := tree_validate(too_long_buf[:])
	testing.expect_value(t, too_long_ref, Tree_Refusal.Name_Too_Long)
}

@(test)
unknown_entry_kind_and_bad_headers_refused :: proc(t: ^testing.T) {
	// Border tree_entry_kind_of_word refuses 0, 3, 255, max(u64).
	for bad_word in ([?]u64{0, 3, 4, 255, max(u64)}) {
		_, ok := tree_entry_kind_of_word(bad_word)
		testing.expect(t, !ok)
	}
	k1, ok1 := tree_entry_kind_of_word(1)
	k2, ok2 := tree_entry_kind_of_word(2)
	testing.expect(t, ok1 && k1 == .Object)
	testing.expect(t, ok2 && k2 == .Tree)

	entry, _ := tree_entry_make(.Object, "item", make_sample_hash(7))
	entries := [1]Tree_Entry{entry}
	buf: [HEADER_SIZE + ENTRY_SIZE]u8
	written, ref := tree_encode(entries[:], buf[:])
	testing.expect_value(t, ref, Tree_Refusal.None)

	// Mutate wire kind byte to 0, 3, and 255.
	for bad_kind in ([?]u8{0, 3, 255}) {
		bad_buf := buf
		bad_buf[HEADER_SIZE] = bad_kind
		_, val_ref := tree_validate(bad_buf[:written])
		testing.expect_value(t, val_ref, Tree_Refusal.Bad_Entry_Kind)
	}

	// Bad header magic.
	bad_magic := buf
	bad_magic[7] = '2'
	_, magic_ref := tree_validate(bad_magic[:written])
	testing.expect_value(t, magic_ref, Tree_Refusal.Bad_Header)

	// Non-zero reserved word in header.
	bad_reserved := buf
	bad_reserved[12] = 1
	_, reserved_ref := tree_validate(bad_reserved[:written])
	testing.expect_value(t, reserved_ref, Tree_Refusal.Bad_Header)
}

@(test)
truncated_and_trailing_bytes_refused :: proc(t: ^testing.T) {
	entry, _ := tree_entry_make(.Tree, "sub", make_sample_hash(11))
	entries := [1]Tree_Entry{entry}
	buf: [HEADER_SIZE + ENTRY_SIZE + 4]u8
	written, ref := tree_encode(entries[:], buf[:])
	testing.expect_value(t, ref, Tree_Refusal.None)

	// Truncated inputs: 0 bytes, 1 byte, 15 bytes, header only (claims 1 entry), 1 byte short of entry.
	for length in ([?]int{0, 1, HEADER_SIZE - 1, HEADER_SIZE, written - 1}) {
		_, val_ref := tree_validate(buf[:length])
		testing.expect_value(t, val_ref, Tree_Refusal.Truncated)
	}

	// Trailing garbage: 1 byte and 4 bytes past valid tree.
	buf[written] = 0x00
	_, trail_one := tree_validate(buf[:written + 1])
	testing.expect_value(t, trail_one, Tree_Refusal.Trailing_Bytes)
	_, trail_four := tree_validate(buf[:written + 4])
	testing.expect_value(t, trail_four, Tree_Refusal.Trailing_Bytes)

	// Encode into too-small buffer fails with Truncated and writes nothing.
	small_buf: [HEADER_SIZE + ENTRY_SIZE - 1]u8
	for &b in small_buf {
		b = 0xAA
	}
	w_small, r_small := tree_encode(entries[:], small_buf[:])
	testing.expect_value(t, r_small, Tree_Refusal.Truncated)
	testing.expect_value(t, w_small, 0)
	testing.expect_value(t, small_buf[0], u8(0xAA))
}

@(test)
deterministic_hash_stability_and_sensitivity :: proc(t: ^testing.T) {
	e_obj, _ := tree_entry_make(.Object, "file", make_sample_hash(42))
	e_tree, _ := tree_entry_make(.Tree, "file", make_sample_hash(42))
	e_other_hash, _ := tree_entry_make(.Object, "file", make_sample_hash(43))
	e_other_name, _ := tree_entry_make(.Object, "filf", make_sample_hash(42))

	buf_obj, buf_tree, buf_other_hash, buf_other_name: [HEADER_SIZE + ENTRY_SIZE]u8
	w1, _ := tree_encode([]Tree_Entry{e_obj}, buf_obj[:])
	w2, _ := tree_encode([]Tree_Entry{e_tree}, buf_tree[:])
	w3, _ := tree_encode([]Tree_Entry{e_other_hash}, buf_other_hash[:])
	w4, _ := tree_encode([]Tree_Entry{e_other_name}, buf_other_name[:])

	h_obj, r1 := tree_hash(buf_obj[:w1])
	h_obj_2, _ := tree_hash(buf_obj[:w1])
	h_tree, r2 := tree_hash(buf_tree[:w2])
	h_other_hash, r3 := tree_hash(buf_other_hash[:w3])
	h_other_name, r4 := tree_hash(buf_other_name[:w4])

	testing.expect_value(t, r1, Tree_Refusal.None)
	testing.expect_value(t, r2, Tree_Refusal.None)
	testing.expect_value(t, r3, Tree_Refusal.None)
	testing.expect_value(t, r4, Tree_Refusal.None)

	// Deterministic across calls.
	testing.expect_value(t, h_obj, h_obj_2)
	// Kind change (Object vs Tree with same name & hash) gives distinct tree hash.
	testing.expect(t, h_obj != h_tree)
	// Child hash change gives distinct tree hash.
	testing.expect(t, h_obj != h_other_hash)
	// Entry name change gives distinct tree hash.
	testing.expect(t, h_obj != h_other_name)
	// Domain separation against plain object hash.
	testing.expect(t, h_obj != blake3.hash(buf_obj[:w1]))
	testing.expect(t, h_tree != blake3.hash(buf_tree[:w2]))
}
