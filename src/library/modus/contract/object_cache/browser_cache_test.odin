#+build !freestanding
#+build !modus
package object_cache

import "base:runtime"
import "core:crypto/ed25519"
import "core:testing"
import "modus:contract/blake3"

@(private = "file")
browser_keypair :: proc(seed_byte: u8) -> (private_key: ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) {
	seed: [ed25519.PRIVATE_KEY_SIZE]u8
	for index in 0 ..< len(seed) {
		seed[index] = seed_byte + u8(index * 3)
	}
	ok := ed25519.private_key_set_bytes(&private_key, seed[:])
	assert(ok)
	ed25519.private_key_public_bytes(&private_key, public_bytes[:])
	return private_key, public_bytes
}

@(private = "file")
browser_ed25519_verify :: proc "contextless" (public_key: [PUBLIC_KEY_SIZE]u8, message: []u8, signature: [SIGNATURE_SIZE]u8, _: rawptr) -> bool {
	context = runtime.default_context()
	key_copy := public_key
	signature_copy := signature
	parsed: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&parsed, key_copy[:]) {
		return false
	}
	return ed25519.verify(&parsed, message, signature_copy[:])
}

// The wire bytes of a realisation of recipe_hash, signed by private_key.
@(private = "file")
browser_signed_realisation :: proc(recipe_hash: blake3.Hash, private_key: ^ed25519.Private_Key, public_bytes: [PUBLIC_KEY_SIZE]u8) -> [REALISATION_WIRE_SIZE]u8 {
	payload := "the output of the recipe"
	record := Realisation_Record {
		recipe_hash       = recipe_hash,
		output_hash       = blake3.hash(transmute([]u8)payload),
		output_kind       = .Blob,
		signer_public_key = public_bytes,
	}
	signing_bytes, ok := realisation_signing_bytes(&record)
	assert(ok)
	ed25519.sign(private_key, signing_bytes[:], record.signature[:])
	wire: [REALISATION_WIRE_SIZE]u8
	written, refusal := encode_realisation_record(&record, wire[:])
	assert(written == REALISATION_WIRE_SIZE && refusal == .None)
	return wire
}

@(test)
browser_cache_url_path_refuses_each_wrong_request :: proc(t: ^testing.T) {
	hash := blake3.hash(transmute([]u8)string("an object"))
	output: [BROWSER_CACHE_PATH_LIMIT]u8
	// The kinds 0 and 3 and the largest word name no member.
	for word in ([]u8{0, 3, 0xFF}) {
		written, status := browser_cache_url_path(Browser_Cache_Object_Kind(word), hash, output[:])
		testing.expect_value(t, status, Browser_Cache_Status.Invalid_Request)
		testing.expect_value(t, written, 0)
		testing.expect_value(t, browser_cache_body_limit(Browser_Cache_Object_Kind(word)), 0)
	}
	testing.expect_value(t, output, [BROWSER_CACHE_PATH_LIMIT]u8{})
	// An all-zero hash names no object.
	_, status := browser_cache_url_path(.Blob, {}, output[:])
	testing.expect_value(t, status, Browser_Cache_Status.Invalid_Request)
	// A buffer one byte short of the path.
	short: [len(BROWSER_CACHE_BLOB_PREFIX) + BROWSER_CACHE_HASH_DIGITS - 1]u8
	written: int
	written, status = browser_cache_url_path(.Blob, hash, short[:])
	testing.expect_value(t, status, Browser_Cache_Status.Invalid_Request)
	testing.expect_value(t, written, 0)
	testing.expect_value(t, short, [len(short)]u8{})

	// Last: the two paths, lowercase, at the exact size.
	all_ones: blake3.Hash
	for &value in all_ones {
		value = 0xFF
	}
	written, status = browser_cache_url_path(.Realisation, all_ones, output[:])
	testing.expect_value(t, status, Browser_Cache_Status.Ok)
	testing.expect_value(t, written, BROWSER_CACHE_PATH_LIMIT)
	testing.expect_value(t, string(output[:written]), "/realisations/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
	small: blake3.Hash
	small[0], small[31] = 0x0A, 0x01
	written, status = browser_cache_url_path(.Blob, small, output[:])
	testing.expect_value(t, status, Browser_Cache_Status.Ok)
	testing.expect_value(t, string(output[:written]), "/blobs/0a00000000000000000000000000000000000000000000000000000000000001")
	testing.expect_value(t, browser_cache_body_limit(.Blob), BROWSER_CACHE_OBJECT_LIMIT)
	testing.expect_value(t, browser_cache_body_limit(.Realisation), REALISATION_WIRE_SIZE)
}

@(test)
browser_cache_verify_blob_refuses_each_wrong_body :: proc(t: ^testing.T) {
	body := make([]u8, 4096, context.temp_allocator)
	for &value, index in body {
		value = u8(index * 31)
	}
	hash := blake3.hash(body)
	// An all-zero hash, even for bytes that hash to anything.
	testing.expect_value(t, browser_cache_verify_blob({}, body), Browser_Cache_Status.Invalid_Request)
	// Each single bit flipped: the first, one in the middle, the last.
	for bit in ([]int{0, 4096 * 4 + 3, 4096 * 8 - 1}) {
		body[bit / 8] ~= u8(1) << uint(bit % 8)
		testing.expect_value(t, browser_cache_verify_blob(hash, body), Browser_Cache_Status.Hash_Mismatch)
		body[bit / 8] ~= u8(1) << uint(bit % 8)
	}
	// One byte short, one byte more, and no byte.
	testing.expect_value(t, browser_cache_verify_blob(hash, body[:len(body) - 1]), Browser_Cache_Status.Hash_Mismatch)
	longer := make([]u8, len(body) + 1, context.temp_allocator)
	copy(longer, body)
	testing.expect_value(t, browser_cache_verify_blob(hash, longer), Browser_Cache_Status.Hash_Mismatch)
	testing.expect_value(t, browser_cache_verify_blob(hash, nil), Browser_Cache_Status.Hash_Mismatch)
	// One byte past the bound: refused before any hash.
	oversized := make([]u8, BROWSER_CACHE_OBJECT_LIMIT + 1, context.temp_allocator)
	testing.expect_value(t, browser_cache_verify_blob(blake3.hash(oversized), oversized), Browser_Cache_Status.Too_Large)

	// Last: the body of the hash, and an empty blob at the bound of 0 bytes.
	testing.expect_value(t, browser_cache_verify_blob(hash, body), Browser_Cache_Status.Ok)
	testing.expect_value(t, browser_cache_verify_blob(blake3.hash(nil), nil), Browser_Cache_Status.Ok)
	at_bound := oversized[:BROWSER_CACHE_OBJECT_LIMIT]
	testing.expect_value(t, browser_cache_verify_blob(blake3.hash(at_bound), at_bound), Browser_Cache_Status.Ok)
}

@(test)
browser_cache_verify_realisation_refuses_each_wrong_record :: proc(t: ^testing.T) {
	private_key, public_key := browser_keypair(0x21)
	other_private_key, other_public_key := browser_keypair(0x63)
	recipe := blake3.hash(transmute([]u8)string("a recipe"))
	wire := browser_signed_realisation(recipe, &private_key, public_key)

	// The requests that name nothing: no recipe, no signer, no verifier.
	_, status := browser_cache_verify_realisation({}, public_key, wire[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Invalid_Request)
	_, status = browser_cache_verify_realisation(recipe, {}, wire[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Invalid_Request)
	_, status = browser_cache_verify_realisation(recipe, public_key, wire[:], nil)
	testing.expect_value(t, status, Browser_Cache_Status.Invalid_Request)
	// A body one byte past the record, one byte short, and empty.
	longer: [REALISATION_WIRE_SIZE + 1]u8
	copy(longer[:], wire[:])
	_, status = browser_cache_verify_realisation(recipe, public_key, longer[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Too_Large)
	_, status = browser_cache_verify_realisation(recipe, public_key, wire[:REALISATION_WIRE_SIZE - 1], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Malformed_Record)
	_, status = browser_cache_verify_realisation(recipe, public_key, nil, browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Malformed_Record)
	// An output kind that names no member.
	damaged := wire
	damaged[64] = 9
	_, status = browser_cache_verify_realisation(recipe, public_key, damaged[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Malformed_Record)
	// The record of another recipe, signed well: the page answered another name.
	other_recipe := blake3.hash(transmute([]u8)string("another recipe"))
	_, status = browser_cache_verify_realisation(other_recipe, public_key, wire[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Hash_Mismatch)
	// A record signed well by another key.
	signed_by_other := browser_signed_realisation(recipe, &other_private_key, other_public_key)
	_, status = browser_cache_verify_realisation(recipe, public_key, signed_by_other[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Untrusted_Signer)
	// The trusted key written in a record that the other key signed.
	swapped := signed_by_other
	copy(swapped[68:100], public_key[:])
	_, status = browser_cache_verify_realisation(recipe, public_key, swapped[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Bad_Signature)
	// One bit of the signature, and one bit of the output hash.
	for offset in ([]int{100, 163, 32, 63}) {
		tampered := wire
		tampered[offset] ~= 0x01
		record: Realisation_Record
		record, status = browser_cache_verify_realisation(recipe, public_key, tampered[:], browser_ed25519_verify)
		testing.expectf(t, status == .Bad_Signature, "a bit of byte %d gives %v", offset, status)
		testing.expect_value(t, record, Realisation_Record{})
	}

	// Last: the record of the recipe, signed by the trusted key.
	record: Realisation_Record
	record, status = browser_cache_verify_realisation(recipe, public_key, wire[:], browser_ed25519_verify)
	testing.expect_value(t, status, Browser_Cache_Status.Ok)
	testing.expect_value(t, record.recipe_hash, recipe)
	testing.expect_value(t, record.signer_public_key, public_key)
}

@(test)
browser_cache_words_name_each_member_once :: proc(t: ^testing.T) {
	for word in ([]u64{0, 3, 256, max(u64)}) {
		_, ok := browser_cache_object_kind_of_word(word)
		testing.expectf(t, !ok, "the kind word %d is read", word)
	}
	for word in ([]u64{10, 255, 256, max(u64)}) {
		_, ok := browser_cache_status_of_word(word)
		testing.expectf(t, !ok, "the status word %d is read", word)
	}
	for status in Browser_Cache_Status {
		read, ok := browser_cache_status_of_word(u64(status))
		testing.expect(t, ok && read == status)
	}
	kind, ok := browser_cache_object_kind_of_word(2)
	testing.expect(t, ok && kind == .Realisation)
}
