#+build !freestanding
package replacement_signature

import "core:testing"
import "modus:contract/replacement_list"
import "modus:contract/system_description"
import "modus:support/cryptography/ed25519"

// list_encode gives the bytes of a list: the header, then the rows. The
// tool has the same procedure; a source of the system calls no allocator.
@(private = "file")
list_encode :: proc(rows: []replacement_list.Row, allocator := context.allocator) -> []u8 {
	bytes := make([]u8, size_of(replacement_list.Header) + len(rows) * size_of(replacement_list.Row), allocator)
	header := replacement_list.Header {
		magic     = replacement_list.MAGIC,
		version   = replacement_list.VERSION,
		row_count = u32(len(rows)),
	}
	copy(bytes, (cast([^]u8)&header)[:size_of(header)])
	if len(rows) > 0 {
		copy(bytes[size_of(header):], (cast([^]u8)raw_data(rows))[:len(rows) * size_of(replacement_list.Row)])
	}
	return bytes
}

// The private key of the test signing key: RFC 8032, section 7.1, TEST 1.
// It is published, as the key of resources/keys/test_signing_key.
@(private = "file")
TEST_SEED :: [32]u8{0x9d, 0x61, 0xb1, 0x9d, 0xef, 0xfd, 0x5a, 0x60, 0xba, 0x84, 0x4a, 0xf4, 0x92, 0xec, 0x2c, 0xc4, 0x44, 0x49, 0xc5, 0x69, 0x7b, 0x32, 0x69, 0x19, 0x70, 0x3b, 0xac, 0x03, 0x1c, 0xae, 0x7f, 0x60}

// Another key that no machine trusts: RFC 8032, section 7.1, TEST 2.
@(private = "file")
OTHER_SEED :: [32]u8{0x4c, 0xcd, 0x08, 0x9b, 0x28, 0xff, 0x96, 0xda, 0x9d, 0xb6, 0xc3, 0x46, 0xec, 0x11, 0x4e, 0x0f, 0x5b, 0x8a, 0x31, 0x9f, 0x35, 0xab, 0xa6, 0x24, 0xda, 0x8c, 0xf6, 0xed, 0x4f, 0xb8, 0xa6, 0xfb}

@(private = "file")
key_of :: proc(t: ^testing.T, seed: [32]u8) -> (key: ed25519.Private_Key, public_key: [replacement_list.PUBLIC_KEY_SIZE]u8) {
	seed_bytes := seed
	testing.expect(t, ed25519.private_key_set_bytes(&key, seed_bytes[:]))
	ed25519.private_key_public_bytes(&key, public_key[:])
	return
}

@(private = "file")
hash_filled :: proc(value: u8) -> (hash: [replacement_list.HASH_SIZE]u8) {
	for &item in hash {
		item = value
	}
	return
}

@(private = "file")
signed_row :: proc(key: ^ed25519.Private_Key, from, to: u8) -> (row: replacement_list.Row) {
	row = {from = hash_filled(from), to = hash_filled(to), scope = .System}
	row_sign(&row, key)
	return
}

@(test)
test_the_seed_gives_the_test_signing_key :: proc(t: ^testing.T) {
	key, public_key := key_of(t, TEST_SEED)
	defer ed25519.private_key_clear(&key)
	testing.expect_value(t, public_key, system_description.TEST_PUBLIC_KEY)
}

@(test)
test_a_signed_row_verifies_under_its_key_only :: proc(t: ^testing.T) {
	key, public_key := key_of(t, TEST_SEED)
	defer ed25519.private_key_clear(&key)
	other, other_public_key := key_of(t, OTHER_SEED)
	defer ed25519.private_key_clear(&other)
	row := signed_row(&key, 1, 2)
	testing.expect(t, row_verifies(&row, public_key))
	testing.expect(t, !row_verifies(&row, other_public_key))
	row_of_another_key := signed_row(&other, 1, 2)
	testing.expect(t, !row_verifies(&row_of_another_key, public_key))
	testing.expect(t, row_verifies(&row_of_another_key, other_public_key))
	// A public key that is not a point.
	not_a_point: [replacement_list.PUBLIC_KEY_SIZE]u8
	for &item in not_a_point {
		item = 0xff
	}
	testing.expect(t, !row_verifies(&row, not_a_point))
}

@(test)
test_a_signature_covers_the_pair_its_direction_and_its_scope :: proc(t: ^testing.T) {
	key, public_key := key_of(t, TEST_SEED)
	defer ed25519.private_key_clear(&key)
	row := signed_row(&key, 1, 2)

	unsigned := row
	unsigned.signature = {}
	testing.expect(t, !row_verifies(&unsigned, public_key))

	other_new := row
	other_new.to = hash_filled(3)
	testing.expect(t, !row_verifies(&other_new, public_key))

	reversed := row
	reversed.from, reversed.to = row.to, row.from
	testing.expect(t, !row_verifies(&reversed, public_key))

	narrower := row
	narrower.scope = .Principal
	narrower.principal = 1
	testing.expect(t, !row_verifies(&narrower, public_key))

	changed_bit := row
	changed_bit.signature[17] ~= 0x04
	testing.expect(t, !row_verifies(&changed_bit, public_key))
}

@(test)
test_the_decision_of_the_root_service :: proc(t: ^testing.T) {
	key, public_key := key_of(t, TEST_SEED)
	defer ed25519.private_key_clear(&key)
	other, _ := key_of(t, OTHER_SEED)
	defer ed25519.private_key_clear(&other)
	rows := [?]replacement_list.Row {
		signed_row(&key, 1, 2), // Signed by the signing key of the system.
		signed_row(&other, 1, 4), // Signed by another key.
		{from = hash_filled(1), to = hash_filled(5), scope = .System}, // No signature.
	}
	list := list_encode(rows[:], context.temp_allocator)

	Case :: struct {
		to:       u8,
		decision: Decision,
	}
	cases := [?]Case{{2, .Accepted}, {4, .Not_Authentic}, {5, .Not_Authentic}, {3, .No_Row}}
	for item in cases {
		decision, problem := system_decision(list, hash_filled(1), hash_filled(item.to), public_key)
		testing.expect_value(t, decision, item.decision)
		testing.expect_value(t, problem, replacement_list.List_Problem.None)
	}
	// The reverse of a signed pair has no row.
	decision, _ := system_decision(list, hash_filled(2), hash_filled(1), public_key)
	testing.expect_value(t, decision, Decision.No_Row)

	decision, _ = system_decision(nil, hash_filled(1), hash_filled(2), public_key)
	testing.expect_value(t, decision, Decision.No_List)

	problem: replacement_list.List_Problem
	decision, problem = system_decision(list[:len(list) - 1], hash_filled(1), hash_filled(2), public_key)
	testing.expect_value(t, decision, Decision.List_Not_Valid)
	testing.expect_value(t, problem, replacement_list.List_Problem.Size)
}

@(test)
test_a_row_of_the_scope_of_a_principal_is_not_a_row_of_the_system :: proc(t: ^testing.T) {
	key, public_key := key_of(t, TEST_SEED)
	defer ed25519.private_key_clear(&key)
	row := replacement_list.Row{from = hash_filled(1), to = hash_filled(2), scope = .Principal, principal = 1}
	row_sign(&row, &key)
	testing.expect(t, row_verifies(&row, public_key))
	rows := [1]replacement_list.Row{row}
	decision, _ := system_decision(list_encode(rows[:], context.temp_allocator), hash_filled(1), hash_filled(2), public_key)
	testing.expect_value(t, decision, Decision.No_Row)
}
