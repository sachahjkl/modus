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

// The nonce refuses the generation 0, and two writes never share one: a
// block number and a generation are each a whole field, so no two pairs
// give one nonce, at the edges too.
@(test)
two_writes_never_share_a_nonce :: proc(t: ^testing.T) {
	_, ok := block_nonce(5, 0)
	testing.expect(t, !ok)
	pairs := [?][2]u64{{0, 1}, {1, 1}, {0, 2}, {1, 2}, {max(u64), 1}, {1, max(u64)}, {max(u64), max(u64)}, {1 << 32, 1}, {1, 1 << 32}}
	for first, i in pairs {
		a, a_ok := block_nonce(first[0], first[1])
		testing.expect(t, a_ok)
		for byte in a[16:] {
			testing.expect(t, byte == 0, "the last 8 bytes are zero")
		}
		for second, j in pairs {
			if i == j {
				continue
			}
			b, _ := block_nonce(second[0], second[1])
			testing.expectf(t, a != b, "%v and %v share a nonce", first, second)
		}
	}
}

// The tag of a node changes with one bit of its bytes, with its place,
// with its generation and with the key.
@(test)
the_tag_of_a_node_binds_its_bytes_its_place_and_its_key :: proc(t: ^testing.T) {
	key := filled(Key, 7)
	bytes: [64]u8
	for index in 0 ..< len(bytes) {
		bytes[index] = u8(index * 3)
	}
	tag := node_tag(key, 10, 4, bytes[:])
	flipped := bytes
	flipped[63] ~= 1
	testing.expect(t, node_tag(key, 10, 4, flipped[:]) != tag)
	testing.expect(t, node_tag(key, 11, 4, bytes[:]) != tag)
	testing.expect(t, node_tag(key, 10, 5, bytes[:]) != tag)
	other := key
	other[0] ~= 1
	testing.expect(t, node_tag(other, 10, 4, bytes[:]) != tag)
	testing.expect(t, node_check(key, 10, 4, bytes[:]) != node_check(key, 10, 4, flipped[:]))
}
