// The object cache of a browser machine: the paths that the page fetches
// with fetch(), and the checks of the bytes that the page gives back
// (src/md/features/browser_machine.md, "The object cache of the page").
//
// The page is a pipe that the system does not trust. It may give any bytes
// for any request: each byte is accepted only after its BLAKE3 hash, and a
// realisation only after its recipe hash, its signer and its Ed25519
// signature. A refused answer changes nothing: the caller drops the bytes.
package object_cache

import "modus:contract/blake3"
import "modus:contract/enum_word"

// The largest body of one blob that a single fetch() of the page holds whole
// in memory (16 MiB). Larger blobs need ranged fetches with proofs.
BROWSER_CACHE_OBJECT_LIMIT :: 16 * 1024 * 1024

// The parts of a path: a prefix of the kind, then the hash in 64 lowercase
// hexadecimal digits.
BROWSER_CACHE_BLOB_PREFIX :: "/blobs/"
BROWSER_CACHE_REALISATION_PREFIX :: "/realisations/"
BROWSER_CACHE_HASH_DIGITS :: 2 * blake3.HASH_SIZE

// The size of the longest path: a buffer of this size holds each path.
BROWSER_CACHE_PATH_LIMIT :: len(BROWSER_CACHE_REALISATION_PREFIX) + BROWSER_CACHE_HASH_DIGITS

#assert(BROWSER_CACHE_PATH_LIMIT == 78)

// What the page fetches. The words cross the border of the page: the host
// names the same values (browser_machine_host.js, BrowserCacheObjectKind).
Browser_Cache_Object_Kind :: enum u8 {
	Blob        = 1,
	Realisation = 2,
}

// The answer of one request. The host names the same values
// (browser_machine_host.js, BrowserCacheStatus).
Browser_Cache_Status :: enum u8 {
	Ok               = 0,
	Absent           = 1, // The cache has no object with this hash.
	Hash_Mismatch    = 2, // The bytes are not the object of the hash, or the record names another recipe.
	Too_Large        = 3, // The body passes the bound of its kind.
	Not_Configured   = 4, // The page names no object cache.
	Invalid_Request  = 5, // A kind that is no member, an all-zero hash or key, a buffer too small.
	Transport_Error  = 6, // The fetch failed: no answer, a refused origin, a redirect, a status of the server.
	Malformed_Record = 7, // A realisation that does not decode.
	Untrusted_Signer = 8, // A realisation signed by another key than the trusted one.
	Bad_Signature    = 9, // A realisation whose signature does not verify.
}

browser_cache_object_kind_of_word :: proc "contextless" (word: u64) -> (kind: Browser_Cache_Object_Kind, ok: bool) {
	return enum_word.member_of_word(Browser_Cache_Object_Kind, word)
}

browser_cache_status_of_word :: proc "contextless" (word: u64) -> (status: Browser_Cache_Status, ok: bool) {
	return enum_word.member_of_word(Browser_Cache_Status, word)
}

// browser_cache_body_limit gives the largest body that a fetch of kind may
// hold; 0 for a kind that names no member.
browser_cache_body_limit :: proc "contextless" (kind: Browser_Cache_Object_Kind) -> int {
	checked, ok := browser_cache_object_kind_of_word(u64(kind))
	if !ok {
		return 0
	}
	switch checked {
	case .Blob:
		return BROWSER_CACHE_OBJECT_LIMIT
	case .Realisation:
		return REALISATION_WIRE_SIZE
	}
	return 0
}

// browser_cache_url_path writes the path of the object of kind and hash
// into output: "/blobs/<hash>" or "/realisations/<hash>", the hash in
// lowercase hexadecimal. A refused call writes nothing.
browser_cache_url_path :: proc "contextless" (kind: Browser_Cache_Object_Kind, hash: blake3.Hash, output: []u8) -> (written: int, status: Browser_Cache_Status) {
	checked, ok := browser_cache_object_kind_of_word(u64(kind))
	if !ok || hash_is_zero(hash) {
		return 0, .Invalid_Request
	}
	prefix: string
	switch checked {
	case .Blob:
		prefix = BROWSER_CACHE_BLOB_PREFIX
	case .Realisation:
		prefix = BROWSER_CACHE_REALISATION_PREFIX
	}
	size := len(prefix) + BROWSER_CACHE_HASH_DIGITS
	if len(output) < size {
		return 0, .Invalid_Request
	}
	digits := "0123456789abcdef"
	copy(output, prefix)
	for value, index in hash {
		output[len(prefix) + 2 * index] = digits[value >> 4]
		output[len(prefix) + 2 * index + 1] = digits[value & 0x0F]
	}
	return size, .Ok
}

// browser_cache_verify_blob checks that received is the blob of
// expected_hash. The bound comes before the hash, so a body past it costs
// no hash.
browser_cache_verify_blob :: proc "contextless" (expected_hash: blake3.Hash, received: []u8) -> Browser_Cache_Status {
	if hash_is_zero(expected_hash) {
		return .Invalid_Request
	}
	if len(received) > BROWSER_CACHE_OBJECT_LIMIT {
		return .Too_Large
	}
	switch verify_object_content(.Blob, expected_hash, received) {
	case .Trust_By_Hash:
		return .Ok
	case .Refuse_Hash_Mismatch:
		return .Hash_Mismatch
	case .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature, .Refuse_Malformed:
		return .Invalid_Request
	}
	return .Invalid_Request
}

// browser_cache_verify_realisation checks that received is a realisation
// of expected_recipe_hash, signed by signer_public_key, with a signature
// that verify_signature accepts. The record comes back only with Ok.
browser_cache_verify_realisation :: proc "contextless" (
	expected_recipe_hash: blake3.Hash,
	signer_public_key: [PUBLIC_KEY_SIZE]u8,
	received: []u8,
	verify_signature: Signature_Verify_Proc,
	user_data: rawptr = nil,
) -> (
	record: Realisation_Record,
	status: Browser_Cache_Status,
) {
	signer := signer_public_key
	if hash_is_zero(expected_recipe_hash) || bytes_all_zero(signer[:]) || verify_signature == nil {
		return {}, .Invalid_Request
	}
	if len(received) > REALISATION_WIRE_SIZE {
		return {}, .Too_Large
	}
	decoded, refusal := decode_realisation_record(received)
	if refusal != .None {
		return {}, .Malformed_Record
	}
	if !hashes_equal_constant_time(decoded.recipe_hash, expected_recipe_hash) {
		return {}, .Hash_Mismatch
	}
	trusted := [1][PUBLIC_KEY_SIZE]u8{signer}
	policy := Substitution_Policy {
		mode            = .Verify,
		trusted_signers = trusted[:],
	}
	subject := Substitution_Realisation_Subject {
		expected_recipe_hash = expected_recipe_hash,
		realisation          = decoded,
	}
	switch substitution_check(policy, subject, verify_signature, user_data) {
	case .Trust_By_Signer:
		return decoded, .Ok
	case .Refuse_Untrusted_Signer:
		return {}, .Untrusted_Signer
	case .Refuse_Bad_Signature:
		return {}, .Bad_Signature
	case .Refuse_Hash_Mismatch:
		return {}, .Hash_Mismatch
	case .Trust_By_Hash, .Refuse_Malformed:
		return {}, .Malformed_Record
	}
	return {}, .Malformed_Record
}
