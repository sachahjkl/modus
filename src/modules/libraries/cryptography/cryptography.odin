// The cryptography of the system as one module of code: each export is a
// primitive of Odin's core:crypto that the system took (src/library/modus/cryptography,
// docs/CRYPTOGRAPHY.md), in the forms of the system.
//
// The code of each export but argon2id is in the private part
// cryptography_primitives, under the same name and with the same
// signature: the QUIC peer of the tool and the host tests of QUIC call that
// code on the host, where no module is loaded. The export reads each
// argument once and passes it on.
//
// - **The caller supplies the memory**: each Text is bytes of the caller,
//   each result is a buffer of the caller, so the module allocates nothing.
// - **Each byte of the caller is read once**, and each input that the code of
//   the origin reads more than once is first copied into memory of the
//   module, with a limit.
// - **The result buffer must be private memory of the caller**.
//   [The module](docs/CRYPTOGRAPHY.md#6-the-module-cryptography) says which
//   arguments must be private.
// - **A failure is an error record** and a negative count, never a boolean
//   that a caller can forget.
// - **The copies of secrets that the module makes are erased**, and so is the
//   stack below each export after the work (`erase_stack_below_the_caller`).
//
// A process says which cryptography it runs by the hash of this module: the
// hash names exactly the code that runs. The names of the algorithms stay as
// their standards write them.
package cryptography

import "modus:contract/call_outcome"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:cryptography_primitives"
import "modus:cryptography/argon2id"
import crypto "modus:cryptography/compatibility_crypto"
import "modus:system"

// seal_with_chacha20_poly1305 encrypts a text and appends its tag of 16 bytes (RFC 8439).
//
// - `key`: 32 bytes.
// - `nonce`: 12 bytes. **A nonce must never come two times with one key**: that is the duty of the caller.
// - `additional`: the additional data, which the tag covers and which is not encrypted: 2048 bytes at most.
// - `text`: the text to encrypt.
// - `result`: room for the bytes of the text and 16 more, in *private memory of the caller*.
//
// **Result**: the count of bytes (the size that the result needs, when it is too small), or a failure with its call outcome and an error record:
//
// - `Empty`, `Too_Small` or `Too_Long`: a key, a nonce or a text of another size;
// - `Bad_Value`: a result that overlaps an argument.
@(export, link_name = "seal_with_chacha20_poly1305")
seal_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.seal_with_chacha20_poly1305(key, nonce, additional, text, result, error)
}

// open_with_chacha20_poly1305 checks the tag of a sealed text and decrypts it (RFC 8439).
//
// The key, the nonce and the additional data are those of the seal ([seal](cryptography.seal_with_chacha20_poly1305)).
// The result must be *private memory of the caller*, with room for the text: the sealed text minus 16 bytes.
//
// **Result**: the count of bytes, or a failure with its call outcome and an error record:
//
// - `Not_Authentic`: the tag does not verify; the result keeps no byte of the text;
// - `Too_Small`: a sealed text under 16 bytes, or a result with no room;
// - `Bad_Value`: a result that overlaps an argument.
@(export, link_name = "open_with_chacha20_poly1305")
open_with_chacha20_poly1305 :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.open_with_chacha20_poly1305(key, nonce, additional, sealed, result, error)
}

// seal_with_aes_128_gcm encrypts a text and appends its tag of 16 bytes (NIST SP 800-38D).
//
// The key has 16 bytes, the nonce 12. **A nonce must never come two times with one key**: with AES-GCM a
// repeated nonce gives away the key of the tag, and with it forgeries. The other rules of the arguments and of
// the result are those of [the seal with ChaCha20-Poly1305](cryptography.seal_with_chacha20_poly1305).
@(export, link_name = "seal_with_aes_128_gcm")
seal_with_aes_128_gcm :: proc "c" (key, nonce, additional, text: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.seal_with_aes_128_gcm(key, nonce, additional, text, result, error)
}

// open_with_aes_128_gcm checks the tag of a sealed text and decrypts it.
//
// The rules of the arguments, of the result and of the errors are those of
// [the open with ChaCha20-Poly1305](cryptography.open_with_chacha20_poly1305).
@(export, link_name = "open_with_aes_128_gcm")
open_with_aes_128_gcm :: proc "c" (key, nonce, additional, sealed: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.open_with_aes_128_gcm(key, nonce, additional, sealed, result, error)
}

// sha256 gives the SHA-256 hash of a text: 32 bytes (FIPS 180-4).
//
// - **text**: the bytes to hash, of any length.
// - **result**: a buffer of 32 bytes at least.
//
// **Result**: 32. A buffer under 32 bytes receives nothing, and the result 32 says how much room the hash needs.
// It has no error record: each text has a hash. The stack below the export is erased after the work, because a
// text can be a secret (a transcript, a key).
//
// Example, after `load("cryptography")`: `sha256("abc")` gives the 32 bytes that start with ba 78 16 bf.
@(export, link_name = "sha256")
sha256 :: proc "c" (text: ^string, result: ^[]u8) -> i64 {
	return cryptography_primitives.sha256(text, result)
}

// hmac_sha256 gives the HMAC of a text with a key, with SHA-256: 32 bytes (RFC 2104).
//
// - **key**: the key, of any length; a key longer than 64 bytes is hashed first, as the standard says.
// - **text**: the bytes to authenticate.
// - **result**: a buffer of 32 bytes at least.
//
// **Result**: 32. A buffer under 32 bytes receives nothing. The tag is computed in memory of the module, then
// copied: the buffer of the caller never holds a part of the work. The copy of the tag is erased.
@(export, link_name = "hmac_sha256")
hmac_sha256 :: proc "c" (key, text: ^string, result: ^[]u8) -> i64 {
	return cryptography_primitives.hmac_sha256(key, text, result)
}

// hkdf_sha256_extract gives the pseudorandom key of HKDF from a salt and input keying material, with SHA-256: 32 bytes (RFC 5869, section 2.2).
@(export, link_name = "hkdf_sha256_extract")
hkdf_sha256_extract :: proc "c" (salt, input: ^string, result: ^[]u8) -> i64 {
	return cryptography_primitives.hkdf_sha256_extract(salt, input, result)
}

// hkdf_sha256_expand gives length bytes of output keying material from a pseudorandom key and an info text, with SHA-256 (RFC 5869, section 2.3).
//
// - The key: 32 bytes at least, as [the extract](cryptography.hkdf_sha256_extract) gives it.
// - The info: 1024 bytes at most.
// - The length: 1 to 8160 bytes, 255 times the size of a hash.
//
// **Result**: the count of bytes, or a failure with its call outcome and an error record.
@(export, link_name = "hkdf_sha256_expand")
hkdf_sha256_expand :: proc "c" (key, info: ^string, length: value_kinds.Size_In_Bytes, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.hkdf_sha256_expand(key, info, length, result, error)
}

// header_protection_mask_with_aes_128 gives the 5 bytes of the QUIC header protection mask of a sample of 16 bytes with a key of 16 bytes: AES-128 of the sample (RFC 9001, section 5.4.3). The result is 5, or a failure with its call outcome and an error record for a key or a sample of another size.
//
// - **key**: the header protection key of 16 bytes (argument 1).
// - **sample**: the 16 bytes of the protected packet that the standard names (argument 2).
// - **result**: a buffer of 5 bytes at least; a shorter buffer receives nothing, and the result is 5.
//
// The errors: `Empty`, `Too_Small` or `Too_Long` for a key or a sample of another size, with the number of the
// argument. The copy of the key is erased. The QUIC library of the system calls it for each packet of a suite with
// AES.
@(export, link_name = "header_protection_mask_with_aes_128")
header_protection_mask_with_aes_128 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.header_protection_mask_with_aes_128(key, sample, result, error)
}

// header_protection_mask_with_chacha20 gives the 5 bytes of the QUIC header protection mask of a sample of 16 bytes with a key of 32 bytes: the ChaCha20 keystream at the counter and the nonce that the sample gives (RFC 9001, section 5.4.4). The result is 5, or a failure with its call outcome and an error record for a key or a sample of another size.
//
// - **key**: the header protection key of 32 bytes (argument 1).
// - **sample**: 16 bytes of the protected packet: the first 4 are the counter, the other 12 the nonce (argument 2).
// - **result**: a buffer of 5 bytes at least; a shorter buffer receives nothing, and the result is 5.
//
// The errors are those of [the mask with AES-128](cryptography.header_protection_mask_with_aes_128).
@(export, link_name = "header_protection_mask_with_chacha20")
header_protection_mask_with_chacha20 :: proc "c" (key, sample: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.header_protection_mask_with_chacha20(key, sample, result, error)
}

// x25519 gives the shared secret of a scalar of 32 bytes and a point of 32 bytes (RFC 7748); with the point 9 it is the public key of the scalar.
//
// A point of small order, whose shared secret is 32 zero bytes, is refused with `Bad_Value` (RFC 7748, section
// 6.1): such a secret is known to anyone.
@(export, link_name = "x25519")
x25519_export :: proc "c" (scalar, point: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.x25519(scalar, point, result, error)
}

// ed25519_public_key gives the public key of a private key of 32 bytes (RFC 8032, section 5.1.5).
@(export, link_name = "ed25519_public_key")
ed25519_public_key :: proc "c" (secret: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.ed25519_public_key(secret, result, error)
}

// ed25519_sign gives the signature of a message of 4096 bytes at most, 64 bytes, with a private key of 32 bytes (RFC 8032, section 5.1.6).
@(export, link_name = "ed25519_sign")
ed25519_sign :: proc "c" (secret, message: ^string, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.ed25519_sign(secret, message, result, error)
}

// ed25519_verify checks the signature of a message of 4096 bytes at most with a public key of 32 bytes (RFC 8032, section 5.1.7).
//
// The check is *strict*: a signature with a non-canonical S or R, or a public key of small order, is refused.
//
// **Result**: 0, or a failure with its call outcome and an error record:
//
// - `Not_Authentic`: the signature does not verify;
// - `Bad_Value`: a public key that is not a point.
@(export, link_name = "ed25519_verify")
ed25519_verify :: proc "c" (public, message, signature: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return cryptography_primitives.ed25519_verify(public, message, signature, error)
}

// The limits of the inputs of Argon2id, copied into the module: a
// passphrase typed at the keyboard is far shorter. A salt of 8 bytes at
// least (RFC 9106, section 3.1).
PASSWORD_LIMIT :: 1024
SALT_LEAST :: 8
SALT_LIMIT :: 64
// The KiB of the blocks: 8 for each lane at least (RFC 9106), 4 GiB at
// most, which the parameter of the origin can count.
ARGON2ID_MEMORY_LIMIT :: 4 * 1024 * 1024
ARGON2ID_PASSES_LIMIT :: 64
// The origin computes the lanes one after the other, in one thread: more
// lanes cost the same time, and a limit keeps the record small.
ARGON2ID_LANES_LIMIT :: 16
// The tag: 4 bytes at least (RFC 9106); 64 at most, a key and more.
ARGON2ID_TAG_LEAST :: 4
ARGON2ID_TAG_LIMIT :: 64

// The cost of one derivation of Argon2id, as one record: the numbers of one
// cost go together to each export that derives.
Argon2id_Cost :: struct {
	memory_kibibytes: i64, // The KiB of the blocks: 8 for each lane at least.
	passes:           i64, // 1 to 64.
	lanes:            i64, // 1 to 16.
	tag_bytes:        i64, // The bytes of the result: 4 to 64.
}

// Argon2id stays in the module: no host program calls it, and its cost
// record is a record of the description of the exports.
@(private)
argon2id_run :: #force_no_inline proc "contextless" (password_text, salt_text: string, cost: Argon2id_Cost, work: system.Bytes_To_Change, output: []u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	// The context of the code of the origin is all zero: it uses no
	// allocator here, and a module has no thread-local state for the
	// default random generator.
	context = {}
	password := transmute([]u8)password_text
	salt := transmute([]u8)salt_text
	if len(password) > PASSWORD_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, i64(len(password)), PASSWORD_LIMIT)
	}
	if len(salt) < SALT_LEAST {
		return call_outcome.fail(error, .Argument_Refused, len(salt) == 0 ? .Empty : .Too_Small, .Bytes, 2, i64(len(salt)), SALT_LEAST)
	}
	if len(salt) > SALT_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 2, i64(len(salt)), SALT_LIMIT)
	}
	// The record is a copy: the caller cannot change it after these checks.
	if cost.lanes < 1 || cost.lanes > ARGON2ID_LANES_LIMIT || cost.passes < 1 || cost.passes > ARGON2ID_PASSES_LIMIT || cost.tag_bytes < ARGON2ID_TAG_LEAST || cost.tag_bytes > ARGON2ID_TAG_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3)
	}
	if cost.memory_kibibytes < 8 * cost.lanes || cost.memory_kibibytes > ARGON2ID_MEMORY_LIMIT {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 3, cost.memory_kibibytes, ARGON2ID_MEMORY_LIMIT)
	}
	// The header of the work memory is read once (the argument is a copy).
	needed := u64(cost.memory_kibibytes) * 1024
	if work.bytes == nil || work.capacity < needed || uintptr(work.bytes) % 8 != 0 {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, 4, i64(min(work.capacity, 1 << 62)), i64(needed))
	}
	tag_size := int(cost.tag_bytes)
	if len(output) < tag_size {
		return .Succeeded, i64(tag_size)
	}
	password_copy: [PASSWORD_LIMIT]u8
	salt_copy: [SALT_LIMIT]u8
	tag: [ARGON2ID_TAG_LIMIT]u8
	copy(password_copy[:], password)
	copy(salt_copy[:], salt)
	defer crypto.zero_explicit(&password_copy, size_of(password_copy))
	defer crypto.zero_explicit(&tag, size_of(tag))
	parameters := argon2id.Parameters {
		memory_size = u32(cost.memory_kibibytes),
		passes      = u32(cost.passes),
		parallelism = u32(cost.lanes),
	}
	// The origin erases the blocks at its end (sanitize).
	if argon2id.derive(&parameters, password_copy[:len(password)], salt_copy[:len(salt)], tag[:tag_size], work_memory = work.bytes[:needed]) != .None {
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, 4, i64(min(work.capacity, 1 << 62)), i64(needed))
	}
	copy(output, tag[:tag_size])
	return .Succeeded, i64(tag_size)
}

// argon2id derives a key from a password and a salt with Argon2id (RFC 9106), at the cost of the record: the KiB of the blocks, the passes, the lanes and the bytes of the key.
//
// 1. The password: 1024 bytes at most.
// 2. The salt: 8 to 64 bytes.
// 3. The cost: an `Argon2id_Cost`.
// 4. The work: the blocks, which the caller supplies: `memory_kibibytes * 1024` bytes of its own memory,
//    aligned on 8 bytes, which the module erases at the end.
//
// **Result**: the count of the bytes of the key, or a failure with its call outcome and an error record:
//
// - `Too_Long`: the password (argument 1);
// - `Too_Small` or `Too_Long`: the salt (argument 2);
// - `Bad_Value`: the cost (argument 3);
// - `Too_Small`: the work memory (argument 4).
@(export, link_name = "argon2id")
argon2id_export :: proc "c" (password, salt: ^string, cost: ^Argon2id_Cost, work: ^system.Bytes_To_Change, result: ^[]u8, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	outcome, value = argon2id_run(password^, salt^, cost^, work^, result^, error)
	crypto.erase_stack_below_the_caller()
	return
}
