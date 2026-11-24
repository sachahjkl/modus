#+build !freestanding
package store_encryption

import "core:testing"
import "modus:contract/store"
import "modus:principals"

@(private = "file")
filled :: proc($T: typeid, first: u8) -> (value: T) {
	bytes := transmute([size_of(T)]u8)value
	for index in 0 ..< size_of(T) {
		bytes[index] = first + u8(index)
	}
	return transmute(T)bytes
}

@(private = "file")
test_keys :: proc(first: u8) -> Store_Keys {
	keys, _ := store_keys_of(filled(Key, first), filled(principals.Principal_Identifier, 40), filled(Salt, 90))
	return keys
}

@(private = "file")
block_all_zero :: proc(bytes: []u8) -> bool {
	for b in bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

// Each value of zero bytes is refused: no unlock, creation or store makes
// one, and a key from it would be known to everybody.
@(test)
the_keys_of_a_store_refuse_each_zero_input :: proc(t: ^testing.T) {
	storage := filled(Key, 1)
	identifier := filled(principals.Principal_Identifier, 40)
	salt := filled(Salt, 90)
	_, ok := store_keys_of({}, identifier, salt)
	testing.expect(t, !ok, "a storage key of zero bytes")
	_, ok = store_keys_of(storage, {}, salt)
	testing.expect(t, !ok, "an identifier of zero bytes")
	_, ok = store_keys_of(storage, identifier, {})
	testing.expect(t, !ok, "a salt of zero bytes")
	_, name_ok := name_key_of({})
	testing.expect(t, !name_ok, "a name key of no storage key")
	// One byte past zero is enough.
	one: Salt
	one[SALT_SIZE - 1] = 1
	_, ok = store_keys_of(storage, identifier, one)
	testing.expect(t, ok)
}

// Each input changes each key: another principal, another identifier,
// another salt; and the keys of a store differ.
@(test)
no_two_stores_share_a_key :: proc(t: ^testing.T) {
	storage := filled(Key, 1)
	identifier := filled(principals.Principal_Identifier, 40)
	salt := filled(Salt, 90)
	keys, ok := store_keys_of(storage, identifier, salt)
	testing.expect(t, ok)
	testing.expect(t, keys.cipher != keys.tag && keys.tag != keys.check && keys.cipher != keys.check && keys.nonce != keys.cipher && keys.nonce != keys.tag)
	other_storage := storage
	other_storage[0] ~= 1
	other_identifier := identifier
	other_identifier[31] ~= 1
	other_salt := salt
	other_salt[0] ~= 0x80
	for other in ([?]Store_Keys{
		store_keys_of(other_storage, identifier, salt) or_else {},
		store_keys_of(storage, other_identifier, salt) or_else {},
		store_keys_of(storage, identifier, other_salt) or_else {},
	}) {
		testing.expect(t, other.cipher != keys.cipher && other.tag != keys.tag && other.check != keys.check && other.nonce != keys.nonce)
		testing.expect(t, !key_check_matches(&keys, other.check), "the check of another key passed")
	}
	testing.expect(t, key_check_matches(&keys, keys.check))
	again, _ := store_keys_of(storage, identifier, salt)
	testing.expect(t, again == keys)
}

// A name tag refuses an empty name and a name past the field, takes the
// edge, and differs between two principals and two names.
@(test)
a_name_tag_names_one_store_of_one_principal :: proc(t: ^testing.T) {
	first, _ := name_key_of(filled(Key, 1))
	second, _ := name_key_of(filled(Key, 2))
	_, ok := name_tag(first, "")
	testing.expect(t, !ok)
	long: [NAME_LIMIT + 1]u8
	for index in 0 ..< len(long) {
		long[index] = 'a'
	}
	_, ok = name_tag(first, string(long[:]))
	testing.expect(t, !ok, "a name past the field")
	_, ok = name_tag(first, string(long[:NAME_LIMIT]))
	testing.expect(t, ok, "a name at the field")
	notes_first, _ := name_tag(first, "notes")
	notes_second, _ := name_tag(second, "notes")
	other_first, _ := name_tag(first, "notez")
	testing.expect(t, notes_first != notes_second, "two principals share a tag")
	testing.expect(t, notes_first != other_first, "two names share a tag")
}

// Nonces: two blocks or two checks give two nonces, data_nonce is disjoint
// from block_nonce even for (0, 0), and another key gives another nonce.
@(test)
nonces_follow_kind_block_check_and_key :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	pairs := [?][2]u64{{0, 0}, {1, 0}, {0, 1}, {max(u64), 0}, {0, max(u64)}, {1 << 32, 1}, {1, 1 << 32}}
	for first, i in pairs {
		a := block_nonce(&keys, first[0], first[1])
		d := data_nonce(&keys, first[0], first[1])
		testing.expect(t, a != d, "block_nonce and data_nonce must be domain-separated")
		testing.expect(t, d == data_nonce(&keys, first[0], first[1]))
		testing.expect(t, d != data_nonce(&other, first[0], first[1]), "two keys share a data nonce")
		for second, j in pairs {
			if i != j {
				testing.expectf(t, d != data_nonce(&keys, second[0], second[1]), "%v and %v share a data nonce", first, second)
			}
		}
	}
}

// Data block: ciphertext check refusal erases bytes; wrong key, block, or
// data_check never yields plaintext; round trip recovers exact bytes.
@(test)
data_block_encrypt_and_decrypt_refusals_and_round_trip :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	clear := new(Block)
	defer free(clear)
	for index in 0 ..< BLOCK_SIZE {
		clear[index] = u8(index * 7 + 3)
	}
	sealed := new(Block)
	defer free(sealed)
	sealed^ = clear^
	cipher_check := data_block_encrypt(&keys, 20, 99, sealed)
	testing.expect(t, sealed^ != clear^)
	testing.expect_value(t, cipher_check, store.check(sealed[:]))

	// Wrong cipher_check or tampered ciphertext must fail and erase the buffer.
	trial := new(Block)
	defer free(trial)
	trial^ = sealed^
	testing.expect(t, !data_block_decrypt(&keys, 20, cipher_check ~ 1, 99, trial))
	testing.expect(t, block_all_zero(trial[:]), "failed cipher_check must erase buffer")

	trial^ = sealed^
	trial[BLOCK_SIZE - 1] ~= 1
	testing.expect(t, !data_block_decrypt(&keys, 20, cipher_check, 99, trial))
	testing.expect(t, block_all_zero(trial[:]), "tampered ciphertext must erase buffer")

	// Wrong key, block number, or data_check decrypts to garbage, not plaintext.
	for wrong in ([?]struct {
		keys:       ^Store_Keys,
		block:      u64,
		data_check: u64,
	}{{&other, 20, 99}, {&keys, 21, 99}, {&keys, 20, 98}}) {
		trial^ = sealed^
		testing.expect(t, data_block_decrypt(wrong.keys, wrong.block, cipher_check, wrong.data_check, trial))
		testing.expect(t, trial^ != clear^, "data block decrypted under wrong key, block or data_check")
	}

	// Exact round trip.
	trial^ = sealed^
	testing.expect(t, data_block_decrypt(&keys, 20, cipher_check, 99, trial))
	testing.expect(t, trial^ == clear^)
}

// Store block: refuses zero generation, missing owner fields, rollback,
// future generation, wrong check, wrong key, wrong block, and any bit flip.
@(test)
store_block_seal_and_verify_refusals_and_rollback :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	sb := new(store.Store_Block)
	defer free(sb)
	sb.tree = {block = 10, check = 0x11223344}
	sb.objects = 3
	sb.owner = filled([store.OWNER_FIELD_SIZE]u8, 10)
	sb.salt = filled([store.OWNER_FIELD_SIZE]u8, 20)
	sb.key_check = keys.check
	sb.name_sealed = filled([store.OWNER_FIELD_SIZE]u8, 30)

	// Refusal on zero store_generation.
	sb.store_generation = 0
	_, ok := store_block_seal(&keys, 5, sb)
	testing.expect(t, !ok, "store_block_seal must refuse store_generation == 0")

	// Refusal on zero owner / salt / key_check.
	sb.store_generation = 7
	saved_owner := sb.owner
	sb.owner = {}
	_, ok = store_block_seal(&keys, 5, sb)
	testing.expect(t, !ok, "store_block_seal must refuse zero owner")
	sb.owner = saved_owner

	// Seal validly.
	check, seal_ok := store_block_seal(&keys, 5, sb)
	testing.expect(t, seal_ok)
	sealed := new(store.Store_Block)
	defer free(sealed)
	sealed^ = sb^

	trial := new(store.Store_Block)
	defer free(trial)

	// Rollback: store_generation (7) < min_generation (8).
	trial^ = sealed^
	testing.expect(t, !store_block_verify(&keys, 5, check, 8, 20, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Future generation: store_generation (7) > max_generation (6).
	trial^ = sealed^
	testing.expect(t, !store_block_verify(&keys, 5, check, 1, 6, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Wrong key, wrong block, wrong check.
	trial^ = sealed^
	testing.expect(t, !store_block_verify(&other, 5, check, 1, 20, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	trial^ = sealed^
	testing.expect(t, !store_block_verify(&keys, 6, check, 1, 20, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	trial^ = sealed^
	testing.expect(t, !store_block_verify(&keys, 5, check ~ 1, 1, 20, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Bit flip in clear field (recomputing outer check to simulate attacker with disk write).
	trial^ = sealed^
	trial.objects ~= 1
	forged_check := store.check(([^]u8)(trial)[:BLOCK_SIZE])
	testing.expect(t, !store_block_verify(&keys, 5, forged_check, 1, 20, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Bit flip in padding.
	trial^ = sealed^
	trial.padding[len(trial.padding) - 1] ~= 0x80
	forged_check = store.check(([^]u8)(trial)[:BLOCK_SIZE])
	testing.expect(t, !store_block_verify(&keys, 5, forged_check, 1, 20, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Exact boundary acceptance (min == store_generation == max).
	trial^ = sealed^
	testing.expect(t, store_block_verify(&keys, 5, check, 7, 7, trial))
	testing.expect_value(t, trial.tree, sb.tree)
	testing.expect_value(t, trial.store_generation, u64(7))
}

// B+ tree leaf and branch: keeps structural pointers clear for keyless
// mount, encrypts names and secret entry metadata, refuses every tamper,
// swap, wrong key, and out-of-bounds header.
@(test)
tree_node_leaf_and_branch_seal_and_open :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	clear := new(Block)
	defer free(clear)

	// Wrong header refusals on seal: count 0, count > LEAF_CAPACITY, bad magic, level > TREE_DEPTH_LIMIT.
	hdr := (^store.Tree_Header)(clear)
	hdr^ = {level = 0, count = 0, magic = store.NODE_MAGIC}
	_, ok := tree_node_seal(&keys, 10, clear)
	testing.expect(t, !ok, "leaf count 0 must be refused")

	hdr.count = store.LEAF_CAPACITY + 1
	_, ok = tree_node_seal(&keys, 10, clear)
	testing.expect(t, !ok, "leaf count past capacity must be refused")

	hdr^ = {level = 1, count = store.BRANCH_CAPACITY + 1, magic = store.NODE_MAGIC}
	_, ok = tree_node_seal(&keys, 10, clear)
	testing.expect(t, !ok, "branch count past capacity must be refused")

	hdr^ = {level = store.TREE_DEPTH_LIMIT + 1, count = 1, magic = store.NODE_MAGIC}
	_, ok = tree_node_seal(&keys, 10, clear)
	testing.expect(t, !ok, "level past depth limit must be refused")

	// Build a valid leaf at full capacity (11 entries).
	clear^ = {}
	hdr^ = {level = 0, count = store.LEAF_CAPACITY, magic = store.NODE_MAGIC}
	stride :: size_of(store.Entry_Name) + size_of(store.Entry)
	for i in 0 ..< store.LEAF_CAPACITY {
		base := store.TREE_HEADER_SIZE + i * stride
		name := (^store.Entry_Name)(&clear[base])
		name^ = store.entry_name("secret-document-name")
		name[0] = u8('a' + i)
		entry := (^store.Entry)(&clear[base + size_of(store.Entry_Name)])
		entry^ = {
			kind       = u64(store.Entry_Kind.Object),
			size       = u64(100 + i),
			generation = u64(50 + i),
			time       = u64(1000 + i),
			date       = u64(1700000000 + i),
			hash       = filled([32]u8, u8(i + 1)),
			data_check = u64(0xCAFE0000 + i),
			pointer    = {block = u64(100 + i), check = u64(0xBEEF0000 + i)},
			versions   = {block = u64(200 + i), check = u64(0xFEED0000 + i)},
		}
	}

	sealed := new(Block)
	defer free(sealed)
	sealed^ = clear^
	check, seal_ok := tree_node_seal(&keys, 10, sealed)
	testing.expect(t, seal_ok)

	// Verify structural fields remain clear while secret fields changed.
	for i in 0 ..< store.LEAF_CAPACITY {
		base := store.TREE_HEADER_SIZE + i * stride
		clear_name := (^store.Entry_Name)(&clear[base])
		sealed_name := (^store.Entry_Name)(&sealed[base])
		testing.expect(t, sealed_name^ != clear_name^, "entry name must be encrypted")
		clear_entry := (^store.Entry)(&clear[base + size_of(store.Entry_Name)])
		sealed_entry := (^store.Entry)(&sealed[base + size_of(store.Entry_Name)])
		testing.expect_value(t, sealed_entry.kind, clear_entry.kind)
		testing.expect_value(t, sealed_entry.size, clear_entry.size)
		testing.expect_value(t, sealed_entry.pointer, clear_entry.pointer)
		testing.expect_value(t, sealed_entry.versions, clear_entry.versions)
		testing.expect(t, sealed_entry.hash != clear_entry.hash, "entry hash must be encrypted")
	}

	trial := new(Block)
	defer free(trial)
	// Wrong key, wrong block, wrong outer check, bit flip in clear field, secret field, mac, and padding.
	flips := [?]int{
		0, // clear header.level
		16, // header.mac
		store.TREE_HEADER_SIZE, // encrypted name
		store.TREE_HEADER_SIZE + size_of(store.Entry_Name) + int(offset_of(store.Entry, pointer)), // clear pointer
		BLOCK_SIZE - 1, // trailing padding
	}
	for pos in flips {
		trial^ = sealed^
		trial[pos] ~= 1
		forged := store.check(trial[:])
		testing.expectf(t, !tree_node_open(&keys, 10, forged, trial), "bit flip at %d must fail MAC", pos)
		testing.expect(t, block_all_zero(trial[:]), "failed tree_node_open must erase buffer")
	}
	trial^ = sealed^
	testing.expect(t, !tree_node_open(&other, 10, check, trial))
	testing.expect(t, block_all_zero(trial[:]))

	trial^ = sealed^
	testing.expect(t, !tree_node_open(&keys, 11, check, trial))
	testing.expect(t, block_all_zero(trial[:]))

	// Round trip recovers exact clear block (with mac zeroed).
	trial^ = sealed^
	testing.expect(t, tree_node_open(&keys, 10, check, trial))
	testing.expect(t, trial^ == clear^)

	// Branch at full capacity (14 children).
	clear^ = {}
	hdr^ = {level = 1, count = store.BRANCH_CAPACITY, magic = store.NODE_MAGIC}
	branch_stride :: size_of(store.Entry_Name) + size_of(store.Pointer)
	for i in 0 ..< store.BRANCH_CAPACITY {
		base := store.TREE_HEADER_SIZE + i * branch_stride
		name := (^store.Entry_Name)(&clear[base])
		name^ = store.entry_name("branch-separator")
		name[0] = u8('a' + i)
		ptr := (^store.Pointer)(&clear[base + size_of(store.Entry_Name)])
		ptr^ = {block = u64(500 + i), check = u64(0x12340000 + i)}
	}
	sealed^ = clear^
	branch_check, branch_ok := tree_node_seal(&keys, 42, sealed)
	testing.expect(t, branch_ok)
	for i in 0 ..< store.BRANCH_CAPACITY {
		base := store.TREE_HEADER_SIZE + i * branch_stride
		testing.expect(t, (^store.Entry_Name)(&sealed[base])^ != (^store.Entry_Name)(&clear[base])^)
		testing.expect_value(t, (^store.Pointer)(&sealed[base + size_of(store.Entry_Name)])^, (^store.Pointer)(&clear[base + size_of(store.Entry_Name)])^)
	}
	trial^ = sealed^
	testing.expect(t, tree_node_open(&keys, 42, branch_check, trial))
	testing.expect(t, trial^ == clear^)
}

// Object node: holes stay zero, non-hole values are encrypted, non-hole
// count mismatch is refused, and every tamper fails with buffer zeroing.
@(test)
object_node_seal_and_open_refusals_and_round_trip :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	clear := new(store.Object_Node)
	defer free(clear)

	clear.header = {level = 1, count = 2, magic = store.OBJECT_NODE_MAGIC}
	clear.children[0] = {block = 100, check = 0xAA, blocks = 1, value = {1, 2, 3, 4, 5, 6, 7, 8}}
	clear.children[63] = {block = 101, check = 0xBB, blocks = 1, value = {9, 10, 11, 12, 13, 14, 15, 16}}

	// Count mismatch refusal.
	clear.header.count = 3
	_, ok := object_node_seal(&keys, 77, clear)
	testing.expect(t, !ok, "header.count mismatch must be refused")
	clear.header.count = 2

	sealed := new(store.Object_Node)
	defer free(sealed)
	sealed^ = clear^
	check, seal_ok := object_node_seal(&keys, 77, sealed)
	testing.expect(t, seal_ok)

	// Holes stay all-zero; non-holes keep block/check/blocks clear and encrypt value.
	testing.expect_value(t, sealed.children[1], store.Object_Child{})
	testing.expect_value(t, sealed.children[0].block, u64(100))
	testing.expect_value(t, sealed.children[0].check, u64(0xAA))
	testing.expect(t, sealed.children[0].value != clear.children[0].value)
	testing.expect(t, sealed.children[63].value != clear.children[63].value)

	// Cross-kind substitution: a sealed Object_Node must never open as a Tree_Node.
	trial := new(store.Object_Node)
	defer free(trial)
	trial^ = sealed^
	testing.expect(t, !tree_node_open(&keys, 77, check, (^Block)(trial)))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Wrong key, wrong block, bit flip in hole slot.
	trial^ = sealed^
	testing.expect(t, !object_node_open(&other, 77, check, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	trial^ = sealed^
	testing.expect(t, !object_node_open(&keys, 78, check, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	trial^ = sealed^
	trial.children[1].value[0] = 1
	forged := store.check(([^]u8)(trial)[:BLOCK_SIZE])
	testing.expect(t, !object_node_open(&keys, 77, forged, trial))
	testing.expect(t, block_all_zero(([^]u8)(trial)[:BLOCK_SIZE]))

	// Round trip.
	trial^ = sealed^
	testing.expect(t, object_node_open(&keys, 77, check, trial))
	testing.expect(t, trial^ == clear^)
}

// Version_Index, Version_Leaf, and Release_List: bounds, clear pointers,
// encrypted metadata, tamper refusal, and round trip.
@(test)
version_and_release_blocks_seal_and_open :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)

	// Version_Index
	vi := new(store.Version_Index)
	defer free(vi)
	vi.leaf_count = store.VERSION_INDEX_CAPACITY + 1
	_, ok := version_index_seal(&keys, 30, vi)
	testing.expect(t, !ok, "leaf_count past capacity must be refused")

	vi^ = {leaf_count = 2, version_count = 99, retention_time = 123456}
	vi.leaves[0] = {block = 40, check = 0x111}
	vi.leaves[1] = {block = 41, check = 0x222}
	vi_sealed := new(store.Version_Index)
	defer free(vi_sealed)
	vi_sealed^ = vi^
	vi_check, vi_ok := version_index_seal(&keys, 30, vi_sealed)
	testing.expect(t, vi_ok)
	testing.expect_value(t, vi_sealed.leaf_count, u64(2))
	testing.expect_value(t, vi_sealed.leaves[0], vi.leaves[0])
	testing.expect(t, vi_sealed.version_count != vi.version_count || vi_sealed.retention_time != vi.retention_time)

	vi_trial := new(store.Version_Index)
	defer free(vi_trial)
	vi_trial^ = vi_sealed^
	testing.expect(t, !version_index_open(&other, 30, vi_check, vi_trial))
	testing.expect(t, block_all_zero(([^]u8)(vi_trial)[:BLOCK_SIZE]))

	vi_trial^ = vi_sealed^
	vi_trial.leaves[0].block ~= 1
	testing.expect(t, !version_index_open(&keys, 30, store.check(([^]u8)(vi_trial)[:BLOCK_SIZE]), vi_trial))
	testing.expect(t, block_all_zero(([^]u8)(vi_trial)[:BLOCK_SIZE]))

	vi_trial^ = vi_sealed^
	testing.expect(t, version_index_open(&keys, 30, vi_check, vi_trial))
	testing.expect(t, vi_trial^ == vi^)

	// Version_Leaf
	vl := new(store.Version_Leaf)
	defer free(vl)
	vl.count = 0
	_, ok = version_leaf_seal(&keys, 40, vl)
	testing.expect(t, !ok, "leaf count 0 must be refused")
	vl.count = store.VERSION_LEAF_CAPACITY + 1
	_, ok = version_leaf_seal(&keys, 40, vl)
	testing.expect(t, !ok, "leaf count past capacity must be refused")

	vl^ = {count = store.VERSION_LEAF_CAPACITY}
	for i in 0 ..< store.VERSION_LEAF_CAPACITY {
		vl.entries[i] = {
			size       = u64(4096 + i),
			root       = {block = u64(600 + i), check = u64(0x9000 + i)},
			generation = u64(10 + i),
			time       = u64(2000 + i),
			date       = u64(1700000000 + i),
			data_check = u64(0x77770000 + i),
		}
	}
	vl_sealed := new(store.Version_Leaf)
	defer free(vl_sealed)
	vl_sealed^ = vl^
	vl_check, vl_ok := version_leaf_seal(&keys, 40, vl_sealed)
	testing.expect(t, vl_ok)
	testing.expect_value(t, vl_sealed.entries[0].size, vl.entries[0].size)
	testing.expect_value(t, vl_sealed.entries[0].root, vl.entries[0].root)
	testing.expect(t, vl_sealed.entries[0].generation != vl.entries[0].generation)

	vl_trial := new(store.Version_Leaf)
	defer free(vl_trial)
	vl_trial^ = vl_sealed^
	testing.expect(t, !version_leaf_open(&keys, 41, vl_check, vl_trial))
	testing.expect(t, block_all_zero(([^]u8)(vl_trial)[:BLOCK_SIZE]))

	vl_trial^ = vl_sealed^
	testing.expect(t, version_leaf_open(&keys, 40, vl_check, vl_trial))
	testing.expect(t, vl_trial^ == vl^)

	// Release_List
	rl := new(store.Release_List)
	defer free(rl)
	rl.magic = store.RELEASE_LIST_MAGIC
	rl.count = 0
	_, ok = release_list_seal(&keys, 50, rl)
	testing.expect(t, !ok, "release list count 0 must be refused")

	rl.count = 2
	rl.next = {block = 51, check = 0x555}
	rl.states[0] = {root = {block = 700, check = 0xAAA}, size = 8192, cursor = 1}
	rl.states[1] = {root = {block = 701, check = 0xBBB}, size = 4096, cursor = 0}
	rl_sealed := new(store.Release_List)
	defer free(rl_sealed)
	rl_sealed^ = rl^
	rl_check, rl_ok := release_list_seal(&keys, 50, rl_sealed)
	testing.expect(t, rl_ok)
	testing.expect(t, store.release_list_valid(rl_sealed), "sealed release list must remain valid for keyless mount")

	rl_trial := new(store.Release_List)
	defer free(rl_trial)
	rl_trial^ = rl_sealed^
	rl_trial.states[0].cursor = 2
	testing.expect(t, !release_list_open(&keys, 50, store.check(([^]u8)(rl_trial)[:BLOCK_SIZE]), rl_trial))
	testing.expect(t, block_all_zero(([^]u8)(rl_trial)[:BLOCK_SIZE]))

	rl_trial^ = rl_sealed^
	testing.expect(t, release_list_open(&keys, 50, rl_check, rl_trial))
	testing.expect(t, rl_trial^ == rl^)
}
