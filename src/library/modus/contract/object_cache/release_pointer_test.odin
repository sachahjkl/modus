#+build !freestanding
package object_cache

import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

@(private = "file")
pointer_key :: proc() -> (private_key: ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = u8(index * 3 + 1)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
pointer_signed :: proc(name: string, number: u64) -> Release_Pointer {
	private_key, public_bytes := pointer_key()
	pointer, refusal := release_pointer_make(public_bytes, name, number, blake3.hash(transmute([]u8)string("release tree")))
	assert(refusal == .None)
	signing_bytes, ok := release_pointer_signing_bytes(&pointer)
	assert(ok)
	ed25519.sign(&private_key, signing_bytes[:], pointer.signature[:])
	return pointer
}

// Each field that a pointer must refuse, at its edges: the name, its
// padding, the number, the tree and the key.
@(test)
release_pointer_refuses_each_bad_field :: proc(t: ^testing.T) {
	_, public_bytes := pointer_key()
	tree := blake3.hash(transmute([]u8)string("tree"))
	long_name: [RELEASE_POINTER_NAME_CAPACITY + 1]u8
	for &character in long_name {
		character = 'a'
	}
	cases := [?]struct {
		name:   string,
		number: u64,
		tree:   blake3.Hash,
		want:   Wire_Refusal,
	}{
		{"", 1, tree, .Bad_Name},
		{string(long_name[:]), 1, tree, .Bad_Name},
		{".", 1, tree, .Bad_Name},
		{"..", 1, tree, .Bad_Name},
		{"a/b", 1, tree, .Bad_Name},
		{"a\x00b", 1, tree, .Bad_Name},
		{"line\nbreak", 1, tree, .Bad_Name},
		{"release", 0, tree, .Zero_Number},
		{"release", 1, {}, .Zero_Hash},
	}
	for item in cases {
		_, refusal := release_pointer_make(public_bytes, item.name, item.number, item.tree)
		testing.expectf(t, refusal == item.want, "the name %q and the number %d gave %v, not %v", item.name, item.number, refusal, item.want)
	}
	_, zero_key := release_pointer_make({}, "release", 1, tree)
	testing.expect_value(t, zero_key, Wire_Refusal.Zero_Hash)
	// The edges that pass: a name of 1 byte, of 64 bytes, the largest number.
	_, one_byte := release_pointer_make(public_bytes, "r", max(u64), tree)
	testing.expect_value(t, one_byte, Wire_Refusal.None)
	_, whole_name := release_pointer_make(public_bytes, string(long_name[:RELEASE_POINTER_NAME_CAPACITY]), 1, tree)
	testing.expect_value(t, whole_name, Wire_Refusal.None)
}

// A damaged record: each byte that the decoder must refuse, and a record
// that is one byte short or long.
@(test)
release_pointer_decoder_refuses_damaged_records :: proc(t: ^testing.T) {
	pointer := pointer_signed("release", 97000)
	encoded: [RELEASE_POINTER_WIRE_SIZE]u8
	written, refusal := encode_release_pointer(&pointer, encoded[:])
	testing.expect_value(t, refusal, Wire_Refusal.None)
	testing.expect_value(t, written, RELEASE_POINTER_WIRE_SIZE)

	_, short := decode_release_pointer(encoded[:RELEASE_POINTER_WIRE_SIZE - 1])
	testing.expect_value(t, short, Wire_Refusal.Truncated)
	long: [RELEASE_POINTER_WIRE_SIZE + 1]u8
	copy(long[:], encoded[:])
	_, trailing := decode_release_pointer(long[:])
	testing.expect_value(t, trailing, Wire_Refusal.Trailing_Bytes)

	damaged := encoded
	damaged[33] = 1
	_, reserved := decode_release_pointer(damaged[:])
	testing.expect_value(t, reserved, Wire_Refusal.Reserved_Nonzero)
	damaged = encoded
	damaged[32] = 0
	_, empty_name := decode_release_pointer(damaged[:])
	testing.expect_value(t, empty_name, Wire_Refusal.Bad_Name)
	damaged = encoded
	damaged[32] = RELEASE_POINTER_NAME_CAPACITY + 1
	_, long_name := decode_release_pointer(damaged[:])
	testing.expect_value(t, long_name, Wire_Refusal.Bad_Name)
	damaged = encoded
	damaged[40 + 7] = 'x' // A byte after the name of 7 bytes.
	_, padding := decode_release_pointer(damaged[:])
	testing.expect_value(t, padding, Wire_Refusal.Bad_Name)
	damaged = encoded
	byte_order.write_u64_little_endian(damaged[:], 104, 0)
	_, zero_number := decode_release_pointer(damaged[:])
	testing.expect_value(t, zero_number, Wire_Refusal.Zero_Number)
	damaged = encoded
	for index in 112 ..< 144 {
		damaged[index] = 0
	}
	_, zero_tree := decode_release_pointer(damaged[:])
	testing.expect_value(t, zero_tree, Wire_Refusal.Zero_Hash)

	decoded, decode_refusal := decode_release_pointer(encoded[:])
	testing.expect_value(t, decode_refusal, Wire_Refusal.None)
	testing.expect(t, decoded == pointer)
	testing.expect_value(t, release_pointer_name(&decoded), "release")
}

// The signing bytes bind each field: a change of the name, the number or
// the tree makes the signature fail.
@(test)
release_pointer_signature_binds_each_field :: proc(t: ^testing.T) {
	_, public_bytes := pointer_key()
	pointer := pointer_signed("release", 97000)
	verify :: proc(pointer: ^Release_Pointer, public_bytes: [PUBLIC_KEY_SIZE]u8) -> bool {
		signing_bytes, ok := release_pointer_signing_bytes(pointer)
		if !ok {
			return false
		}
		parsed: ed25519.Public_Key
		key := public_bytes
		if !ed25519.public_key_set_bytes(&parsed, key[:]) {
			return false
		}
		return ed25519.verify(&parsed, signing_bytes[:], pointer.signature[:])
	}
	testing.expect(t, verify(&pointer, public_bytes))
	changed := pointer
	changed.number += 1
	testing.expect(t, !verify(&changed, public_bytes))
	changed = pointer
	changed.name[0] = 'R'
	testing.expect(t, !verify(&changed, public_bytes))
	changed = pointer
	changed.tree_hash[0] ~= 1
	testing.expect(t, !verify(&changed, public_bytes))
	// A realisation signature over the same key never verifies as a pointer:
	// the domains differ.
	signing_bytes, _ := release_pointer_signing_bytes(&pointer)
	testing.expect_value(t, string(signing_bytes[:len(RELEASE_POINTER_SIGNING_DOMAIN)]), RELEASE_POINTER_SIGNING_DOMAIN)
}

// The two requests and the answer: a refused field is refused by the
// encoder and by the decoder, and a whole frame goes and comes back.
@(test)
release_pointer_requests_round_trip :: proc(t: ^testing.T) {
	pointer := pointer_signed("release", 97000)

	put := Cache_Request{kind = .Put_Release_Pointer, release_pointer = pointer}
	put_frame: [FRAME_HEADER_SIZE + RELEASE_POINTER_WIRE_SIZE]u8
	put_written, put_refusal := encode_request(&put, put_frame[:])
	testing.expect_value(t, put_refusal, Wire_Refusal.None)
	testing.expect_value(t, put_written, len(put_frame))
	put_decoded, put_decode_refusal := decode_request(put_frame[:])
	testing.expect_value(t, put_decode_refusal, Wire_Refusal.None)
	testing.expect(t, put_decoded.release_pointer == pointer)

	get := Cache_Request{kind = .Get_Release_Pointer}
	get.release_pointer.publisher_public_key = pointer.publisher_public_key
	get.release_pointer.name_length = pointer.name_length
	get.release_pointer.name = pointer.name
	get_frame: [FRAME_HEADER_SIZE + GET_RELEASE_POINTER_BODY_SIZE]u8
	_, get_refusal := encode_request(&get, get_frame[:])
	testing.expect_value(t, get_refusal, Wire_Refusal.None)
	get_decoded, get_decode_refusal := decode_request(get_frame[:])
	testing.expect_value(t, get_decode_refusal, Wire_Refusal.None)
	testing.expect_value(t, release_pointer_name(&get_decoded.release_pointer), "release")
	testing.expect(t, get_decoded.release_pointer.publisher_public_key == pointer.publisher_public_key)

	// A body of one byte more or less than its kind holds.
	long_get: [FRAME_HEADER_SIZE + GET_RELEASE_POINTER_BODY_SIZE + 1]u8
	copy(long_get[:], get_frame[:])
	byte_order.write_u32_little_endian(long_get[:], 8, GET_RELEASE_POINTER_BODY_SIZE + 1)
	_, long_refusal := decode_request(long_get[:])
	testing.expect_value(t, long_refusal, Wire_Refusal.Trailing_Bytes)
	short_get := get_frame
	byte_order.write_u32_little_endian(short_get[:], 8, GET_RELEASE_POINTER_BODY_SIZE - 1)
	_, short_refusal := decode_request(short_get[:len(short_get) - 1])
	testing.expect_value(t, short_refusal, Wire_Refusal.Truncated)
	// A name that is not a tree entry name, in a Get.
	bad_get := get_frame
	bad_get[FRAME_HEADER_SIZE + 40] = '/'
	_, bad_name := decode_request(bad_get[:])
	testing.expect_value(t, bad_name, Wire_Refusal.Bad_Name)
	// A Put of a pointer with no number is refused before a byte is written.
	zero_number := put
	zero_number.release_pointer.number = 0
	untouched: [FRAME_HEADER_SIZE + RELEASE_POINTER_WIRE_SIZE]u8
	written, zero_refusal := encode_request(&zero_number, untouched[:])
	testing.expect_value(t, zero_refusal, Wire_Refusal.Zero_Number)
	testing.expect_value(t, written, 0)

	answer := Cache_Response{request_kind = .Get_Release_Pointer, status = .Ok, release_pointer = pointer}
	answer_frame: [FRAME_HEADER_SIZE + RELEASE_POINTER_WIRE_SIZE]u8
	_, answer_refusal := encode_response(&answer, answer_frame[:])
	testing.expect_value(t, answer_refusal, Wire_Refusal.None)
	answer_decoded, answer_decode_refusal := decode_response(answer_frame[:])
	testing.expect_value(t, answer_decode_refusal, Wire_Refusal.None)
	testing.expect(t, answer_decoded.release_pointer == pointer)
	// A Put answer with a body is refused.
	put_answer := Cache_Response{request_kind = .Put_Release_Pointer, status = .Ok}
	put_answer_frame: [FRAME_HEADER_SIZE + 1]u8
	_, _ = encode_response(&put_answer, put_answer_frame[:])
	byte_order.write_u32_little_endian(put_answer_frame[:], 8, 1)
	_, put_answer_refusal := decode_response(put_answer_frame[:])
	testing.expect_value(t, put_answer_refusal, Wire_Refusal.Trailing_Bytes)
}
