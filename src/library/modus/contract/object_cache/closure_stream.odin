// Deterministic offline closure stream format for air-gapped USB transfer
// (src/md/features/program_trees.md).
//
// Binary layout (little-endian, fixed headers, zero padding):
//   Stream Header (CLOSURE_STREAM_HEADER_SIZE = 64 bytes):
//     [0..8]   magic        "MODCLOS1"
//     [8..12]  version      u32 LE (must be CLOSURE_STREAM_VERSION = 1)
//     [12..16] flags        u32 LE (bit 0 = has_realisation; all other bits 0)
//     [16..48] root_hash    32-byte non-zero BLAKE3 or MODTREE2 root hash
//     [48..56] object_count u64 LE (1 ..= CLOSURE_STREAM_MAX_OBJECTS)
//     [56]     root_kind    Cache_Object_Kind (1 = Blob, 2 = Tree)
//     [57..64] reserved     7 zero bytes
//
//   Repeated object_count times in deterministic bottom-up order (root last):
//     Record Header (CLOSURE_RECORD_HEADER_SIZE = 44 bytes):
//       [0]      kind       Cache_Object_Kind (1 = Blob, 2 = Tree)
//       [1..4]   reserved   3 zero bytes
//       [4..12]  size       u64 LE (<= payload_bound_for_kind(kind))
//       [12..44] hash       32-byte non-zero BLAKE3 or MODTREE2 hash
//     Payload:
//       [0..size] raw Blob bytes or canonical MODTREE2 bytes
//
//   Optional trailing Realisation (when has_realisation flag is set):
//     [0..164] canonical REALISATION_WIRE_SIZE Realisation_Record whose
//              output_hash == root_hash and output_kind == root_kind.
//
// This contract file imports no support or host package and allocates no
// memory.
package object_cache

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Format property: magic identifying version 1 of the offline closure stream.
CLOSURE_STREAM_MAGIC :: [8]u8{'M', 'O', 'D', 'C', 'L', 'O', 'S', '1'}

// Format property: current offline closure stream format version.
CLOSURE_STREAM_VERSION :: u32(1)

// Format property: flags bit indicating a trailing 164-byte Realisation_Record.
CLOSURE_STREAM_FLAG_HAS_REALISATION :: u32(1)

// Format property: exact byte sizes of the stream header and per-object header.
CLOSURE_STREAM_HEADER_SIZE :: 8 + 4 + 4 + blake3.HASH_SIZE + 8 + 1 + 7
CLOSURE_RECORD_HEADER_SIZE :: 1 + 3 + 8 + blake3.HASH_SIZE

#assert(CLOSURE_STREAM_HEADER_SIZE == 64)
#assert(CLOSURE_RECORD_HEADER_SIZE == 44)

// Plan value: upper bound on objects in one offline closure stream so a
// corrupt header cannot force unbounded allocation or iteration.
CLOSURE_STREAM_MAX_OBJECTS :: u64(1 << 20)

// Format/contract bound: matches builder maximum nested MODTREE2 tree depth.
CLOSURE_STREAM_MAX_DEPTH :: 32

// Closed set of validation, decoding, and verification refusals for MODCLOS1.
Closure_Stream_Refusal :: enum u8 {
	None                = 0,
	Buffer_Too_Small    = 1,
	Truncated           = 2,
	Bad_Magic           = 3,
	Unsupported_Version = 4,
	Reserved_Nonzero    = 5,
	Bad_Object_Kind     = 6,
	Zero_Hash           = 7,
	Bad_Count           = 8,
	Too_Large           = 9,
	Hash_Mismatch       = 10,
	Malformed_Tree      = 11,
	Bad_Realisation     = 12,
	Untrusted_Signer    = 13,
	Bad_Signature       = 14,
	Trailing_Bytes      = 15,
}

// Decoded stream header of a MODCLOS1 offline closure file.
Closure_Stream_Header :: struct {
	version:         u32,
	has_realisation: bool,
	root_kind:       Cache_Object_Kind,
	root_hash:       blake3.Hash,
	object_count:    u64,
}

// Decoded per-object record header inside a MODCLOS1 stream.
Closure_Record_Header :: struct {
	kind: Cache_Object_Kind,
	size: u64,
	hash: blake3.Hash,
}

// closure_stream_refusal_of_word is the single border converting a raw word
// into a Closure_Stream_Refusal member. Unknown values are refused.
closure_stream_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Closure_Stream_Refusal, ok: bool) {
	return enum_word.member_of_word(Closure_Stream_Refusal, word)
}

// closure_header_write validates header and encodes it into out (64 bytes).
// Refused calls leave out unchanged.
closure_header_write :: proc "contextless" (header: ^Closure_Stream_Header, out: []u8) -> (written: int, refusal: Closure_Stream_Refusal) {
	if header == nil {
		return 0, .Buffer_Too_Small
	}
	if header.version != CLOSURE_STREAM_VERSION {
		return 0, .Unsupported_Version
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(header.root_kind))
	if !kind_ok {
		return 0, .Bad_Object_Kind
	}
	if hash_is_zero(header.root_hash) {
		return 0, .Zero_Hash
	}
	if header.object_count == 0 || header.object_count > CLOSURE_STREAM_MAX_OBJECTS {
		return 0, .Bad_Count
	}
	if len(out) < CLOSURE_STREAM_HEADER_SIZE {
		return 0, .Buffer_Too_Small
	}

	magic := CLOSURE_STREAM_MAGIC
	copy(out[0:8], magic[:])
	byte_order.write_u32_little_endian(out, 8, CLOSURE_STREAM_VERSION)
	flags: u32 = header.has_realisation ? CLOSURE_STREAM_FLAG_HAS_REALISATION : 0
	byte_order.write_u32_little_endian(out, 12, flags)
	copy(out[16:48], header.root_hash[:])
	byte_order.write_u64_little_endian(out, 48, header.object_count)
	out[56] = u8(checked_kind)
	for index in 57 ..< CLOSURE_STREAM_HEADER_SIZE {
		out[index] = 0
	}
	return CLOSURE_STREAM_HEADER_SIZE, .None
}

// closure_header_read validates and decodes the leading 64-byte stream header.
closure_header_read :: proc "contextless" (input: []u8) -> (header: Closure_Stream_Header, refusal: Closure_Stream_Refusal) {
	if len(input) < CLOSURE_STREAM_HEADER_SIZE {
		return {}, .Truncated
	}
	magic := CLOSURE_STREAM_MAGIC
	for index in 0 ..< len(magic) {
		if input[index] != magic[index] {
			return {}, .Bad_Magic
		}
	}
	version := byte_order.read_u32_little_endian(input, 8)
	if version != CLOSURE_STREAM_VERSION {
		return {}, .Unsupported_Version
	}
	flags := byte_order.read_u32_little_endian(input, 12)
	if flags & ~CLOSURE_STREAM_FLAG_HAS_REALISATION != 0 {
		return {}, .Reserved_Nonzero
	}
	for index in 57 ..< CLOSURE_STREAM_HEADER_SIZE {
		if input[index] != 0 {
			return {}, .Reserved_Nonzero
		}
	}
	root_kind, kind_ok := cache_object_kind_of_word(u64(input[56]))
	if !kind_ok {
		return {}, .Bad_Object_Kind
	}
	root_hash: blake3.Hash
	copy(root_hash[:], input[16:48])
	if hash_is_zero(root_hash) {
		return {}, .Zero_Hash
	}
	object_count := byte_order.read_u64_little_endian(input, 48)
	if object_count == 0 || object_count > CLOSURE_STREAM_MAX_OBJECTS {
		return {}, .Bad_Count
	}
	return {
		version         = version,
		has_realisation = (flags & CLOSURE_STREAM_FLAG_HAS_REALISATION) != 0,
		root_kind       = root_kind,
		root_hash       = root_hash,
		object_count    = object_count,
	}, .None
}

// closure_record_header_write validates record and encodes it into out (44 bytes).
// Refused calls leave out unchanged.
closure_record_header_write :: proc "contextless" (record: ^Closure_Record_Header, out: []u8) -> (written: int, refusal: Closure_Stream_Refusal) {
	if record == nil {
		return 0, .Buffer_Too_Small
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(record.kind))
	if !kind_ok {
		return 0, .Bad_Object_Kind
	}
	if hash_is_zero(record.hash) {
		return 0, .Zero_Hash
	}
	if record.size > payload_bound_for_kind(checked_kind) {
		return 0, .Too_Large
	}
	if len(out) < CLOSURE_RECORD_HEADER_SIZE {
		return 0, .Buffer_Too_Small
	}

	out[0] = u8(checked_kind)
	out[1] = 0
	out[2] = 0
	out[3] = 0
	byte_order.write_u64_little_endian(out, 4, record.size)
	copy(out[12:44], record.hash[:])
	return CLOSURE_RECORD_HEADER_SIZE, .None
}

// closure_record_header_read validates and decodes a 44-byte record header.
closure_record_header_read :: proc "contextless" (input: []u8) -> (record: Closure_Record_Header, refusal: Closure_Stream_Refusal) {
	if len(input) < CLOSURE_RECORD_HEADER_SIZE {
		return {}, .Truncated
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(input[0]))
	if !kind_ok {
		return {}, .Bad_Object_Kind
	}
	if input[1] != 0 || input[2] != 0 || input[3] != 0 {
		return {}, .Reserved_Nonzero
	}
	object_size := byte_order.read_u64_little_endian(input, 4)
	if object_size > payload_bound_for_kind(checked_kind) {
		return {}, .Too_Large
	}
	object_hash: blake3.Hash
	copy(object_hash[:], input[12:44])
	if hash_is_zero(object_hash) {
		return {}, .Zero_Hash
	}
	return {
		kind = checked_kind,
		size = object_size,
		hash = object_hash,
	}, .None
}

// closure_record_verify verifies payload against record's kind, size, and hash
// (plain blake3.hash for Blob, canonical MODTREE2 validation + tree_hash for Tree).
closure_record_verify :: proc "contextless" (record: ^Closure_Record_Header, payload: []u8) -> Closure_Stream_Refusal {
	if record == nil {
		return .Buffer_Too_Small
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(record.kind))
	if !kind_ok {
		return .Bad_Object_Kind
	}
	if hash_is_zero(record.hash) {
		return .Zero_Hash
	}
	if record.size > payload_bound_for_kind(checked_kind) {
		return .Too_Large
	}
	if u64(len(payload)) < record.size {
		return .Truncated
	}
	if u64(len(payload)) > record.size {
		return .Trailing_Bytes
	}
	decision := verify_object_content(checked_kind, record.hash, payload)
	switch decision {
	case .Trust_By_Hash:
		return .None
	case .Refuse_Hash_Mismatch:
		return .Hash_Mismatch
	case .Refuse_Malformed:
		return checked_kind == .Tree ? .Malformed_Tree : .Too_Large
	case .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature:
		return .Hash_Mismatch
	}
	return .Hash_Mismatch
}

// closure_realisation_verify decodes and validates the trailing 164-byte
// Realisation_Record of a MODCLOS1 stream against header.root_hash and
// header.root_kind. When trusted_signers is non-empty, verifies through
// substitution_check against those signers. When trusted_signers is empty and
// verify_signature is non-nil, verifies the Ed25519 signature under the
// record's own non-zero signer_public_key.
closure_realisation_verify :: proc "contextless" (
	header: ^Closure_Stream_Header,
	raw_realisation: []u8,
	trusted_signers: [][PUBLIC_KEY_SIZE]u8 = nil,
	verify_signature: Signature_Verify_Proc = nil,
	user_data: rawptr = nil,
) -> (record: Realisation_Record, refusal: Closure_Stream_Refusal) {
	if header == nil {
		return {}, .Bad_Realisation
	}
	if len(raw_realisation) < REALISATION_WIRE_SIZE {
		return {}, .Truncated
	}
	if len(raw_realisation) > REALISATION_WIRE_SIZE {
		return {}, .Trailing_Bytes
	}
	decoded, dec_ref := decode_realisation_record(raw_realisation)
	if dec_ref != .None {
		return {}, .Bad_Realisation
	}
	if !hashes_equal_constant_time(decoded.output_hash, header.root_hash) || decoded.output_kind != header.root_kind {
		return {}, .Bad_Realisation
	}
	if len(trusted_signers) > 0 {
		policy := Substitution_Policy {
			mode            = .Cache_Only,
			trusted_signers = trusted_signers,
		}
		decision := substitution_check(
			policy,
			Substitution_Realisation_Subject{
				expected_recipe_hash = decoded.recipe_hash,
				realisation          = decoded,
			},
			verify_signature,
			user_data,
		)
		switch decision {
		case .Trust_By_Signer:
			return decoded, .None
		case .Refuse_Untrusted_Signer:
			return {}, .Untrusted_Signer
		case .Refuse_Bad_Signature:
			return {}, .Bad_Signature
		case .Trust_By_Hash, .Refuse_Hash_Mismatch, .Refuse_Malformed:
			return {}, .Bad_Realisation
		}
		return {}, .Bad_Realisation
	}
	if verify_signature != nil {
		signer_copy := decoded.signer_public_key
		if bytes_all_zero(signer_copy[:]) {
			return {}, .Bad_Signature
		}
		signing_bytes, sign_ok := realisation_signing_bytes(&decoded)
		if !sign_ok {
			return {}, .Bad_Realisation
		}
		if !verify_signature(decoded.signer_public_key, signing_bytes[:], decoded.signature, user_data) {
			return {}, .Bad_Signature
		}
	}
	return decoded, .None
}

// closure_stream_verify_buffer validates an entire in-memory MODCLOS1 stream:
// header, every object record hash, root-last discipline, optional signed
// realisation, and exact EOF with no trailing bytes.
closure_stream_verify_buffer :: proc "contextless" (
	data: []u8,
	trusted_signers: [][PUBLIC_KEY_SIZE]u8 = nil,
	verify_signature: Signature_Verify_Proc = nil,
	user_data: rawptr = nil,
) -> (header: Closure_Stream_Header, realisation: Realisation_Record, refusal: Closure_Stream_Refusal) {
	hdr, hdr_ref := closure_header_read(data)
	if hdr_ref != .None {
		return {}, {}, hdr_ref
	}
	if len(trusted_signers) > 0 && !hdr.has_realisation {
		return {}, {}, .Untrusted_Signer
	}
	cursor := CLOSURE_STREAM_HEADER_SIZE
	last_hash: blake3.Hash
	last_kind: Cache_Object_Kind
	for _ in u64(0) ..< hdr.object_count {
		if cursor + CLOSURE_RECORD_HEADER_SIZE > len(data) {
			return {}, {}, .Truncated
		}
		rec, rec_ref := closure_record_header_read(data[cursor:cursor + CLOSURE_RECORD_HEADER_SIZE])
		if rec_ref != .None {
			return {}, {}, rec_ref
		}
		cursor += CLOSURE_RECORD_HEADER_SIZE
		remaining := u64(len(data) - cursor)
		if rec.size > remaining {
			return {}, {}, .Truncated
		}
		payload := data[cursor:cursor + int(rec.size)]
		if ver_ref := closure_record_verify(&rec, payload); ver_ref != .None {
			return {}, {}, ver_ref
		}
		cursor += int(rec.size)
		last_hash = rec.hash
		last_kind = rec.kind
	}
	// Bottom-up discipline: the final object record must be the closure root.
	if !hashes_equal_constant_time(last_hash, hdr.root_hash) || last_kind != hdr.root_kind {
		return {}, {}, .Hash_Mismatch
	}
	if hdr.has_realisation {
		if cursor + REALISATION_WIRE_SIZE > len(data) {
			return {}, {}, .Truncated
		}
		real, real_ref := closure_realisation_verify(
			&hdr,
			data[cursor:cursor + REALISATION_WIRE_SIZE],
			trusted_signers,
			verify_signature,
			user_data,
		)
		if real_ref != .None {
			return {}, {}, real_ref
		}
		realisation = real
		cursor += REALISATION_WIRE_SIZE
	}
	if cursor != len(data) {
		return {}, {}, .Trailing_Bytes
	}
	return hdr, realisation, .None
}
