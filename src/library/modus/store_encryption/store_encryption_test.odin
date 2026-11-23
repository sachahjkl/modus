#+build !freestanding
package store_encryption

import "core:testing"
import "modus:principals"

@(private = "file")
filled :: proc($T: typeid, first: u8) -> (value: T) {
	bytes := transmute([size_of(T)]u8)value
	for index in 0 ..< size_of(T) {
		bytes[index] = first + u8(index)
	}
	return transmute(T)bytes
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
// another salt; and the three keys of a store differ.
@(test)
no_two_stores_share_a_key :: proc(t: ^testing.T) {
	storage := filled(Key, 1)
	identifier := filled(principals.Principal_Identifier, 40)
	salt := filled(Salt, 90)
	keys, ok := store_keys_of(storage, identifier, salt)
	testing.expect(t, ok)
	testing.expect(t, keys.cipher != keys.tag && keys.tag != keys.check && keys.cipher != keys.check)
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
		testing.expect(t, other.cipher != keys.cipher && other.tag != keys.tag && other.check != keys.check)
		testing.expect(t, !key_check_matches(&keys, other.check), "the check of another key passed")
	}
	testing.expect(t, key_check_matches(&keys, keys.check))
	// The same inputs give the same keys: a store opens again after a start.
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

@(private = "file")
test_keys :: proc(first: u8) -> Store_Keys {
	keys, _ := store_keys_of(filled(Key, first), filled(principals.Principal_Identifier, 40), filled(Salt, 90))
	return keys
}

// The nonce: two blocks or two checks give two nonces, the same pair the
// same nonce, and another key another nonce, at the edges of each field.
@(test)
the_nonce_follows_the_block_the_check_and_the_key :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	pairs := [?][2]u64{{0, 0}, {1, 0}, {0, 1}, {max(u64), 0}, {0, max(u64)}, {1 << 32, 1}, {1, 1 << 32}}
	for first, i in pairs {
		a := block_nonce(&keys, first[0], first[1])
		testing.expect(t, a == block_nonce(&keys, first[0], first[1]))
		testing.expect(t, a != block_nonce(&other, first[0], first[1]), "two keys share a nonce")
		for second, j in pairs {
			if i != j {
				testing.expectf(t, a != block_nonce(&keys, second[0], second[1]), "%v and %v share a nonce", first, second)
			}
		}
	}
}

// A node opens only under its key, at its block, with its check, and with
// each of its bits: each refusal erases the bytes. The round trip last.
@(test)
a_node_opens_only_as_it_was_sealed :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	clear := new(Block)
	defer free(clear)
	for index in 0 ..< BLOCK_SIZE {
		clear[index] = u8(index * 7)
	}
	sealed := new(Block)
	defer free(sealed)
	sealed^ = clear^
	check := node_seal(&keys, 10, sealed)
	testing.expect(t, sealed^ != clear^, "the sealed node is its clear bytes")
	trial := new(Block)
	defer free(trial)
	refusals := [?]struct {
		keys:  ^Store_Keys,
		block: u64,
		check: u64,
		flip:  int,
	}{{&other, 10, check, -1}, {&keys, 11, check, -1}, {&keys, 10, check ~ 1, -1}, {&keys, 10, check, 0}, {&keys, 10, check, BLOCK_SIZE - 1}}
	for refusal in refusals {
		trial^ = sealed^
		if refusal.flip >= 0 {
			trial[refusal.flip] ~= 1
		}
		testing.expect(t, !node_open(refusal.keys, refusal.block, refusal.check, trial), "a node opened as it was not sealed")
		testing.expect(t, trial^ == Block{}, "a refused node kept bytes")
	}
	trial^ = sealed^
	testing.expect(t, node_open(&keys, 10, check, trial))
	testing.expect(t, trial^ == clear^)
}

// A block of data: the encryption changes it, the decryption under the
// same key, block and check gives it back, and any other one does not.
@(test)
a_block_of_data_decrypts_only_as_it_was_encrypted :: proc(t: ^testing.T) {
	keys := test_keys(1)
	other := test_keys(2)
	clear := new(Block)
	defer free(clear)
	for index in 0 ..< BLOCK_SIZE {
		clear[index] = u8(index)
	}
	bytes := new(Block)
	defer free(bytes)
	bytes^ = clear^
	data_encrypt(&keys, 20, 99, bytes)
	testing.expect(t, bytes^ != clear^)
	encrypted := bytes^
	for wrong in ([?]struct {
		keys:  ^Store_Keys,
		block: u64,
		check: u64,
	}{{&other, 20, 99}, {&keys, 21, 99}, {&keys, 20, 98}}) {
		bytes^ = encrypted
		data_decrypt(wrong.keys, wrong.block, wrong.check, bytes)
		testing.expect(t, bytes^ != clear^, "a block of data decrypted under another key, block or check")
	}
	bytes^ = encrypted
	data_decrypt(&keys, 20, 99, bytes)
	testing.expect(t, bytes^ == clear^)
}
