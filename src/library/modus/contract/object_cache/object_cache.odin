// The wire protocol, signed realisations, and substitution policy of the
// object cache (src/md/features/recipes.md, "The object cache and its
// protocol").
//
// An object cache serves two distinct things over a framed byte stream:
//
//   1. Content-addressed objects (Blob or Tree) fetched by exact hash.
//      A Blob is verified by plain blake3.hash; a Tree is verified by
//      tree_hash.tree_hash (canonical encoding plus domain-separated BLAKE3).
//      Objects check themselves and need no signer.
//
//   2. Signed realisations mapping a recipe hash to an output hash and kind.
//      A realisation is trusted only when signed by an Ed25519 public key
//      explicitly listed in the caller's Substitution_Policy.
//
// Every integer on the wire is little-endian. Every enum crosses the wire
// through one border (enum_word.member_of_word) that refuses any value naming
// no member. Every hash on the wire must be non-zero.
//
// This package holds no kernel operation call, imports no support package,
// and allocates no memory.
package object_cache

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/tree_hash"

// The QUIC application protocol (ALPN) of the object cache.
APPLICATION_PROTOCOL :: "modus-object-cache"

// Distinct 4-byte magics prevent a request frame from being decoded as a
// response frame or vice versa.
REQUEST_MAGIC :: [4]u8{'M', 'O', 'C', 'Q'}
RESPONSE_MAGIC :: [4]u8{'M', 'O', 'C', 'R'}

// Current version of the binary wire framing.
WIRE_VERSION :: u8(1)

// Fixed size of the leading frame header for both requests and responses:
//   Request:  [0..4] magic, [4] version, [5] request_kind, [6..8] reserved (0), [8..12] body_length
//   Response: [0..4] magic, [4] version, [5] request_kind, [6] status, [7] reserved (0), [8..12] body_length
FRAME_HEADER_SIZE :: 12

// Sizes of Ed25519 public keys and signatures on the wire.
PUBLIC_KEY_SIZE :: 32
SIGNATURE_SIZE :: 64

// Maximum number of hashes carried in one Has batch request (one bit per hash
// in the 64-bit response bitset).
MAX_HAS_HASHES :: 64

// Upper bound on one blob payload carried in a single frame (16 MiB).
MAX_OBJECT_PAYLOAD_BYTES :: 16 * 1024 * 1024

// Upper bound on one canonical tree payload (matches tree_hash).
MAX_TREE_PAYLOAD_BYTES :: tree_hash.MAX_ENCODED_TREE_BYTES

// Exact wire body sizes for fixed-size messages and message headers.
HAS_HEADER_SIZE :: 4
GET_OBJECT_BODY_SIZE :: blake3.HASH_SIZE + 1 + 3
GET_REALISATION_BODY_SIZE :: blake3.HASH_SIZE
PUT_OBJECT_HEADER_SIZE :: blake3.HASH_SIZE + 1 + 3 + PUBLIC_KEY_SIZE + SIGNATURE_SIZE + 4
REALISATION_WIRE_SIZE :: blake3.HASH_SIZE + blake3.HASH_SIZE + 1 + 3 + PUBLIC_KEY_SIZE + SIGNATURE_SIZE
HAS_RESPONSE_BODY_SIZE :: 8
GET_OBJECT_RESPONSE_HEADER_SIZE :: 1 + 3 + 4

// Maximum valid body lengths for any request or response frame.
MAX_REQUEST_BODY_BYTES :: PUT_OBJECT_HEADER_SIZE + MAX_OBJECT_PAYLOAD_BYTES
MAX_RESPONSE_BODY_BYTES :: GET_OBJECT_RESPONSE_HEADER_SIZE + MAX_OBJECT_PAYLOAD_BYTES

// Domain separation prefixes for Ed25519 signatures.
REALISATION_SIGNING_DOMAIN :: "modus realisation v1"
PUT_OBJECT_SIGNING_DOMAIN :: "modus object put v1"

// Exact canonical sizes of the signable payloads.
//   Realisation signing bytes (120 bytes):
//     [0..20]   "modus realisation v1"
//     [20]      0x00 separator
//     [21]      output_kind (u8)
//     [22..24]  0x0000 reserved
//     [24..56]  recipe_hash
//     [56..88]  output_hash
//     [88..120] signer_public_key
REALISATION_SIGNING_BYTES_SIZE :: len(REALISATION_SIGNING_DOMAIN) + 1 + 1 + 2 + blake3.HASH_SIZE + blake3.HASH_SIZE + PUBLIC_KEY_SIZE

//   Put_Object signing bytes (96 bytes):
//     [0..19]  "modus object put v1"
//     [19]     0x00 separator
//     [20]     object_kind (u8)
//     [21..24] 0x000000 reserved
//     [24..56] object_hash
//     [56..64] payload_length (u64 LE)
//     [64..96] uploader_public_key
PUT_OBJECT_SIGNING_BYTES_SIZE :: len(PUT_OBJECT_SIGNING_DOMAIN) + 1 + 1 + 3 + blake3.HASH_SIZE + 8 + PUBLIC_KEY_SIZE

#assert(FRAME_HEADER_SIZE == 12)
#assert(GET_OBJECT_BODY_SIZE == 36)
#assert(GET_REALISATION_BODY_SIZE == 32)
#assert(PUT_OBJECT_HEADER_SIZE == 136)
#assert(REALISATION_WIRE_SIZE == 164)
#assert(GET_OBJECT_RESPONSE_HEADER_SIZE == 8)
#assert(REALISATION_SIGNING_BYTES_SIZE == 120)
#assert(PUT_OBJECT_SIGNING_BYTES_SIZE == 96)

// Closed set of request kinds on the object cache wire protocol.
Cache_Request_Kind :: enum u8 {
	Has             = 1,
	Get_Object      = 2,
	Get_Realisation = 3,
	Put_Object      = 4,
	Put_Realisation = 5,
}

// Closed set of response statuses returned by an object cache server.
Cache_Response_Status :: enum u8 {
	Ok            = 1,
	Not_Found     = 2,
	Refused       = 3,
	Too_Large     = 4,
	Bad_Hash      = 5,
	Bad_Signature = 6,
	Unauthorized  = 7,
}

// Closed set of content-addressed object kinds stored in the cache.
Cache_Object_Kind :: enum u8 {
	Blob = 1,
	Tree = 2,
}

// Closed set of substitution verification outcomes.
Substitution_Decision :: enum u8 {
	Trust_By_Hash           = 1,
	Trust_By_Signer         = 2,
	Refuse_Untrusted_Signer = 3,
	Refuse_Hash_Mismatch    = 4,
	Refuse_Bad_Signature    = 5,
	Refuse_Malformed        = 6,
}

// Closed set of substitution policy modes (src/md/features/recipes.md).
Substitution_Mode :: enum u8 {
	Prefer_Cache = 1,
	Build_Only   = 2,
	Cache_Only   = 3,
	Verify       = 4,
}

// Closed set of framing and validation refusals for wire messages.
Wire_Refusal :: enum u8 {
	None                = 0,
	Truncated           = 1,
	Bad_Magic           = 2,
	Unsupported_Version = 3,
	Bad_Request_Kind    = 4,
	Bad_Response_Status = 5,
	Bad_Object_Kind     = 6,
	Zero_Hash           = 7,
	Too_Large           = 8,
	Trailing_Bytes      = 9,
	Bad_Count           = 10,
	Buffer_Too_Small    = 11,
	Reserved_Nonzero    = 12,
}

// Signed record binding a recipe hash to its output hash and object kind.
Realisation_Record :: struct {
	recipe_hash:       blake3.Hash,
	output_hash:       blake3.Hash,
	output_kind:       Cache_Object_Kind,
	signer_public_key: [PUBLIC_KEY_SIZE]u8,
	signature:         [SIGNATURE_SIZE]u8,
}

// Decoded or buildable request message for the object cache wire protocol.
// For Put_Object, payload borrows directly from the input frame during decode.
Cache_Request :: struct {
	kind:                Cache_Request_Kind,
	hash_count:          u8,
	hashes:              [MAX_HAS_HASHES]blake3.Hash,
	object_hash:         blake3.Hash,
	object_kind:         Cache_Object_Kind,
	recipe_hash:         blake3.Hash,
	uploader_public_key: [PUBLIC_KEY_SIZE]u8,
	uploader_signature:  [SIGNATURE_SIZE]u8,
	payload:             []u8,
	realisation:         Realisation_Record,
}

// Decoded or buildable response message for the object cache wire protocol.
// For Get_Object with status == .Ok, payload borrows directly from the input frame.
Cache_Response :: struct {
	request_kind:   Cache_Request_Kind,
	status:         Cache_Response_Status,
	present_bitset: u64,
	object_kind:    Cache_Object_Kind,
	payload:        []u8,
	realisation:    Realisation_Record,
}

// Policy governing whether a principal trusts a fetched object or realisation.
Substitution_Policy :: struct {
	mode:            Substitution_Mode,
	trusted_signers: [][PUBLIC_KEY_SIZE]u8,
}

// Verification subject for a content-addressed object fetched by exact hash.
Substitution_Object_Subject :: struct {
	expected_hash: blake3.Hash,
	object_kind:   Cache_Object_Kind,
	payload:       []u8,
}

// Verification subject for a signed realisation mapping a recipe to an output.
Substitution_Realisation_Subject :: struct {
	expected_recipe_hash: blake3.Hash,
	realisation:          Realisation_Record,
}

// Closed union of subjects accepted by substitution_check.
Substitution_Subject :: union {
	Substitution_Object_Subject,
	Substitution_Realisation_Subject,
}

// Caller-supplied Ed25519 signature verifier so this contract package imports
// no support cryptography package.
Signature_Verify_Proc :: #type proc "contextless" (
	public_key: [PUBLIC_KEY_SIZE]u8,
	message: []u8,
	signature: [SIGNATURE_SIZE]u8,
	user_data: rawptr,
) -> bool

// Single borders converting raw transport words into closed enum members.
cache_request_kind_of_word :: proc "contextless" (word: u64) -> (kind: Cache_Request_Kind, ok: bool) {
	return enum_word.member_of_word(Cache_Request_Kind, word)
}

cache_response_status_of_word :: proc "contextless" (word: u64) -> (status: Cache_Response_Status, ok: bool) {
	return enum_word.member_of_word(Cache_Response_Status, word)
}

cache_object_kind_of_word :: proc "contextless" (word: u64) -> (kind: Cache_Object_Kind, ok: bool) {
	return enum_word.member_of_word(Cache_Object_Kind, word)
}

substitution_mode_of_word :: proc "contextless" (word: u64) -> (mode: Substitution_Mode, ok: bool) {
	return enum_word.member_of_word(Substitution_Mode, word)
}

// bytes_all_zero returns true when every byte of input is zero.
bytes_all_zero :: proc "contextless" (input: []u8) -> bool {
	accumulated: u8 = 0
	for value in input {
		accumulated |= value
	}
	return accumulated == 0
}

// hash_is_zero returns true when all 32 bytes of value are zero.
hash_is_zero :: proc "contextless" (value: blake3.Hash) -> bool {
	copy_value := value
	return bytes_all_zero(copy_value[:])
}

// hashes_equal_constant_time compares two 32-byte values without early exit.
hashes_equal_constant_time :: proc "contextless" (left, right: [32]u8) -> bool {
	difference: u8 = 0
	for index in 0 ..< 32 {
		difference |= left[index] ~ right[index]
	}
	return difference == 0
}

// payload_bound_for_kind returns the maximum allowed payload length for kind.
payload_bound_for_kind :: proc "contextless" (kind: Cache_Object_Kind) -> int {
	switch kind {
	case .Blob:
		return MAX_OBJECT_PAYLOAD_BYTES
	case .Tree:
		return MAX_TREE_PAYLOAD_BYTES
	}
	return 0
}

// realisation_signing_bytes constructs the canonical domain-separated byte
// sequence signed by Ed25519 for a Realisation_Record. Refuses zero hashes or
// an unknown output_kind.
realisation_signing_bytes :: proc "contextless" (record: ^Realisation_Record) -> (signing_bytes: [REALISATION_SIGNING_BYTES_SIZE]u8, ok: bool) {
	if record == nil {
		return {}, false
	}
	if hash_is_zero(record.recipe_hash) || hash_is_zero(record.output_hash) {
		return {}, false
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(record.output_kind))
	if !kind_ok {
		return {}, false
	}
	domain := REALISATION_SIGNING_DOMAIN
	copy(signing_bytes[0:len(domain)], domain)
	signing_bytes[20] = 0
	signing_bytes[21] = u8(checked_kind)
	signing_bytes[22] = 0
	signing_bytes[23] = 0
	copy(signing_bytes[24:56], record.recipe_hash[:])
	copy(signing_bytes[56:88], record.output_hash[:])
	copy(signing_bytes[88:120], record.signer_public_key[:])
	return signing_bytes, true
}

// put_object_signing_bytes constructs the canonical domain-separated byte
// sequence signed by an authorized uploader when executing Put_Object.
put_object_signing_bytes :: proc "contextless" (
	object_kind: Cache_Object_Kind,
	object_hash: blake3.Hash,
	payload_length: u64,
	uploader_public_key: [PUBLIC_KEY_SIZE]u8,
) -> (signing_bytes: [PUT_OBJECT_SIGNING_BYTES_SIZE]u8, ok: bool) {
	checked_kind, kind_ok := cache_object_kind_of_word(u64(object_kind))
	if !kind_ok {
		return {}, false
	}
	if hash_is_zero(object_hash) {
		return {}, false
	}
	if payload_length > u64(payload_bound_for_kind(checked_kind)) {
		return {}, false
	}
	domain := PUT_OBJECT_SIGNING_DOMAIN
	hash_copy := object_hash
	key_copy := uploader_public_key
	copy(signing_bytes[0:len(domain)], domain)
	signing_bytes[19] = 0
	signing_bytes[20] = u8(checked_kind)
	signing_bytes[21] = 0
	signing_bytes[22] = 0
	signing_bytes[23] = 0
	copy(signing_bytes[24:56], hash_copy[:])
	byte_order.write_u64_little_endian(signing_bytes[:], 56, payload_length)
	copy(signing_bytes[64:96], key_copy[:])
	return signing_bytes, true
}

// encode_realisation_record writes a validated Realisation_Record into output
// in canonical wire format (REALISATION_WIRE_SIZE bytes). Refused calls leave
// output unchanged.
encode_realisation_record :: proc "contextless" (record: ^Realisation_Record, output: []u8) -> (written: int, refusal: Wire_Refusal) {
	if record == nil {
		return 0, .Zero_Hash
	}
	if hash_is_zero(record.recipe_hash) || hash_is_zero(record.output_hash) {
		return 0, .Zero_Hash
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(record.output_kind))
	if !kind_ok {
		return 0, .Bad_Object_Kind
	}
	if len(output) < REALISATION_WIRE_SIZE {
		return 0, .Buffer_Too_Small
	}
	copy(output[0:32], record.recipe_hash[:])
	copy(output[32:64], record.output_hash[:])
	output[64] = u8(checked_kind)
	output[65] = 0
	output[66] = 0
	output[67] = 0
	copy(output[68:100], record.signer_public_key[:])
	copy(output[100:164], record.signature[:])
	return REALISATION_WIRE_SIZE, .None
}

// decode_realisation_record validates and decodes an exact REALISATION_WIRE_SIZE
// slice into a Realisation_Record.
decode_realisation_record :: proc "contextless" (input: []u8) -> (record: Realisation_Record, refusal: Wire_Refusal) {
	if len(input) < REALISATION_WIRE_SIZE {
		return {}, .Truncated
	}
	if len(input) > REALISATION_WIRE_SIZE {
		return {}, .Trailing_Bytes
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(input[64]))
	if !kind_ok {
		return {}, .Bad_Object_Kind
	}
	if input[65] != 0 || input[66] != 0 || input[67] != 0 {
		return {}, .Reserved_Nonzero
	}
	copy(record.recipe_hash[:], input[0:32])
	copy(record.output_hash[:], input[32:64])
	if hash_is_zero(record.recipe_hash) || hash_is_zero(record.output_hash) {
		return {}, .Zero_Hash
	}
	record.output_kind = checked_kind
	copy(record.signer_public_key[:], input[68:100])
	copy(record.signature[:], input[100:164])
	return record, .None
}

// validate_request checks all fields of request and returns the exact wire body
// length required to encode it.
@(private)
validate_request :: proc "contextless" (request: ^Cache_Request) -> (checked_kind: Cache_Request_Kind, body_length: int, refusal: Wire_Refusal) {
	if request == nil {
		return {}, 0, .Bad_Request_Kind
	}
	kind, kind_ok := cache_request_kind_of_word(u64(request.kind))
	if !kind_ok {
		return {}, 0, .Bad_Request_Kind
	}
	switch kind {
	case .Has:
		if request.hash_count == 0 || int(request.hash_count) > MAX_HAS_HASHES {
			return {}, 0, .Bad_Count
		}
		for index in 0 ..< int(request.hash_count) {
			if hash_is_zero(request.hashes[index]) {
				return {}, 0, .Zero_Hash
			}
		}
		return kind, HAS_HEADER_SIZE + int(request.hash_count) * blake3.HASH_SIZE, .None
	case .Get_Object:
		if hash_is_zero(request.object_hash) {
			return {}, 0, .Zero_Hash
		}
		if _, obj_ok := cache_object_kind_of_word(u64(request.object_kind)); !obj_ok {
			return {}, 0, .Bad_Object_Kind
		}
		return kind, GET_OBJECT_BODY_SIZE, .None
	case .Get_Realisation:
		if hash_is_zero(request.recipe_hash) {
			return {}, 0, .Zero_Hash
		}
		return kind, GET_REALISATION_BODY_SIZE, .None
	case .Put_Object:
		if hash_is_zero(request.object_hash) {
			return {}, 0, .Zero_Hash
		}
		obj_kind, obj_ok := cache_object_kind_of_word(u64(request.object_kind))
		if !obj_ok {
			return {}, 0, .Bad_Object_Kind
		}
		if len(request.payload) > payload_bound_for_kind(obj_kind) {
			return {}, 0, .Too_Large
		}
		return kind, PUT_OBJECT_HEADER_SIZE + len(request.payload), .None
	case .Put_Realisation:
		if hash_is_zero(request.realisation.recipe_hash) || hash_is_zero(request.realisation.output_hash) {
			return {}, 0, .Zero_Hash
		}
		if _, obj_ok := cache_object_kind_of_word(u64(request.realisation.output_kind)); !obj_ok {
			return {}, 0, .Bad_Object_Kind
		}
		return kind, REALISATION_WIRE_SIZE, .None
	}
	return {}, 0, .Bad_Request_Kind
}

// encoded_request_size returns the exact frame byte size for a valid request,
// or 0 with the refusal when request is invalid.
encoded_request_size :: proc "contextless" (request: ^Cache_Request) -> (size: int, refusal: Wire_Refusal) {
	_, body_length, check_refusal := validate_request(request)
	if check_refusal != .None {
		return 0, check_refusal
	}
	return FRAME_HEADER_SIZE + body_length, .None
}

// encode_request validates request and writes its complete binary frame into
// output. A refused call writes zero bytes to output.
encode_request :: proc "contextless" (request: ^Cache_Request, output: []u8) -> (written: int, refusal: Wire_Refusal) {
	kind, body_length, check_refusal := validate_request(request)
	if check_refusal != .None {
		return 0, check_refusal
	}
	total_size := FRAME_HEADER_SIZE + body_length
	if len(output) < total_size {
		return 0, .Buffer_Too_Small
	}
	magic := REQUEST_MAGIC
	copy(output[0:4], magic[:])
	output[4] = WIRE_VERSION
	output[5] = u8(kind)
	output[6] = 0
	output[7] = 0
	byte_order.write_u32_little_endian(output, 8, u32(body_length))
	body := output[FRAME_HEADER_SIZE:total_size]
	switch kind {
	case .Has:
		body[0] = request.hash_count
		body[1] = 0
		body[2] = 0
		body[3] = 0
		for index in 0 ..< int(request.hash_count) {
			offset := HAS_HEADER_SIZE + index * blake3.HASH_SIZE
			copy(body[offset:offset + blake3.HASH_SIZE], request.hashes[index][:])
		}
	case .Get_Object:
		copy(body[0:32], request.object_hash[:])
		body[32] = u8(request.object_kind)
		body[33] = 0
		body[34] = 0
		body[35] = 0
	case .Get_Realisation:
		copy(body[0:32], request.recipe_hash[:])
	case .Put_Object:
		copy(body[0:32], request.object_hash[:])
		body[32] = u8(request.object_kind)
		body[33] = 0
		body[34] = 0
		body[35] = 0
		copy(body[36:68], request.uploader_public_key[:])
		copy(body[68:132], request.uploader_signature[:])
		byte_order.write_u32_little_endian(body, 132, u32(len(request.payload)))
		copy(body[PUT_OBJECT_HEADER_SIZE:], request.payload)
	case .Put_Realisation:
		_, record_refusal := encode_realisation_record(&request.realisation, body)
		if record_refusal != .None {
			return 0, record_refusal
		}
	}
	return total_size, .None
}

// inspect_request_header validates only the 12-byte request header so a stream
// reader knows how many body bytes to read before calling decode_request.
inspect_request_header :: proc "contextless" (header: []u8) -> (kind: Cache_Request_Kind, body_length: int, refusal: Wire_Refusal) {
	if len(header) < FRAME_HEADER_SIZE {
		return {}, 0, .Truncated
	}
	magic := REQUEST_MAGIC
	for index in 0 ..< len(magic) {
		if header[index] != magic[index] {
			return {}, 0, .Bad_Magic
		}
	}
	if header[4] != WIRE_VERSION {
		return {}, 0, .Unsupported_Version
	}
	checked_kind, kind_ok := cache_request_kind_of_word(u64(header[5]))
	if !kind_ok {
		return {}, 0, .Bad_Request_Kind
	}
	if header[6] != 0 || header[7] != 0 {
		return {}, 0, .Reserved_Nonzero
	}
	raw_body_length := byte_order.read_u32_little_endian(header, 8)
	if u64(raw_body_length) > u64(MAX_REQUEST_BODY_BYTES) {
		return {}, 0, .Too_Large
	}
	return checked_kind, int(raw_body_length), .None
}

// decode_request strictly validates a complete binary request frame.
// Refuses bad magic, unknown version, unknown enum words, non-zero reserved
// bytes, zero hashes, oversized payloads, truncation, and trailing bytes.
decode_request :: proc "contextless" (frame: []u8) -> (request: Cache_Request, refusal: Wire_Refusal) {
	kind, body_length, header_refusal := inspect_request_header(frame)
	if header_refusal != .None {
		return {}, header_refusal
	}
	expected_total := FRAME_HEADER_SIZE + body_length
	if len(frame) < expected_total {
		return {}, .Truncated
	}
	if len(frame) > expected_total {
		return {}, .Trailing_Bytes
	}
	body := frame[FRAME_HEADER_SIZE:expected_total]
	request.kind = kind
	switch kind {
	case .Has:
		if len(body) < HAS_HEADER_SIZE {
			return {}, .Truncated
		}
		count := body[0]
		if count == 0 || int(count) > MAX_HAS_HASHES {
			return {}, .Bad_Count
		}
		if body[1] != 0 || body[2] != 0 || body[3] != 0 {
			return {}, .Reserved_Nonzero
		}
		expected_body := HAS_HEADER_SIZE + int(count) * blake3.HASH_SIZE
		if len(body) < expected_body {
			return {}, .Truncated
		}
		if len(body) > expected_body {
			return {}, .Trailing_Bytes
		}
		request.hash_count = count
		for index in 0 ..< int(count) {
			offset := HAS_HEADER_SIZE + index * blake3.HASH_SIZE
			copy(request.hashes[index][:], body[offset:offset + blake3.HASH_SIZE])
			if hash_is_zero(request.hashes[index]) {
				return {}, .Zero_Hash
			}
		}
	case .Get_Object:
		if len(body) < GET_OBJECT_BODY_SIZE {
			return {}, .Truncated
		}
		if len(body) > GET_OBJECT_BODY_SIZE {
			return {}, .Trailing_Bytes
		}
		copy(request.object_hash[:], body[0:32])
		if hash_is_zero(request.object_hash) {
			return {}, .Zero_Hash
		}
		obj_kind, obj_ok := cache_object_kind_of_word(u64(body[32]))
		if !obj_ok {
			return {}, .Bad_Object_Kind
		}
		if body[33] != 0 || body[34] != 0 || body[35] != 0 {
			return {}, .Reserved_Nonzero
		}
		request.object_kind = obj_kind
	case .Get_Realisation:
		if len(body) < GET_REALISATION_BODY_SIZE {
			return {}, .Truncated
		}
		if len(body) > GET_REALISATION_BODY_SIZE {
			return {}, .Trailing_Bytes
		}
		copy(request.recipe_hash[:], body[0:32])
		if hash_is_zero(request.recipe_hash) {
			return {}, .Zero_Hash
		}
	case .Put_Object:
		if len(body) < PUT_OBJECT_HEADER_SIZE {
			return {}, .Truncated
		}
		copy(request.object_hash[:], body[0:32])
		if hash_is_zero(request.object_hash) {
			return {}, .Zero_Hash
		}
		obj_kind, obj_ok := cache_object_kind_of_word(u64(body[32]))
		if !obj_ok {
			return {}, .Bad_Object_Kind
		}
		if body[33] != 0 || body[34] != 0 || body[35] != 0 {
			return {}, .Reserved_Nonzero
		}
		copy(request.uploader_public_key[:], body[36:68])
		copy(request.uploader_signature[:], body[68:132])
		raw_payload_length := byte_order.read_u32_little_endian(body, 132)
		if u64(raw_payload_length) > u64(payload_bound_for_kind(obj_kind)) {
			return {}, .Too_Large
		}
		expected_body := PUT_OBJECT_HEADER_SIZE + int(raw_payload_length)
		if len(body) < expected_body {
			return {}, .Truncated
		}
		if len(body) > expected_body {
			return {}, .Trailing_Bytes
		}
		request.object_kind = obj_kind
		request.payload = body[PUT_OBJECT_HEADER_SIZE:expected_body]
	case .Put_Realisation:
		record, record_refusal := decode_realisation_record(body)
		if record_refusal != .None {
			return {}, record_refusal
		}
		request.realisation = record
	}
	return request, .None
}

// validate_response checks all fields of response and returns the exact wire
// body length required to encode it.
@(private)
validate_response :: proc "contextless" (response: ^Cache_Response) -> (checked_kind: Cache_Request_Kind, checked_status: Cache_Response_Status, body_length: int, refusal: Wire_Refusal) {
	if response == nil {
		return {}, {}, 0, .Bad_Response_Status
	}
	kind, kind_ok := cache_request_kind_of_word(u64(response.request_kind))
	if !kind_ok {
		return {}, {}, 0, .Bad_Request_Kind
	}
	status, status_ok := cache_response_status_of_word(u64(response.status))
	if !status_ok {
		return {}, {}, 0, .Bad_Response_Status
	}
	if status != .Ok {
		return kind, status, 0, .None
	}
	switch kind {
	case .Has:
		return kind, status, HAS_RESPONSE_BODY_SIZE, .None
	case .Get_Object:
		obj_kind, obj_ok := cache_object_kind_of_word(u64(response.object_kind))
		if !obj_ok {
			return {}, {}, 0, .Bad_Object_Kind
		}
		if len(response.payload) > payload_bound_for_kind(obj_kind) {
			return {}, {}, 0, .Too_Large
		}
		return kind, status, GET_OBJECT_RESPONSE_HEADER_SIZE + len(response.payload), .None
	case .Get_Realisation:
		if hash_is_zero(response.realisation.recipe_hash) || hash_is_zero(response.realisation.output_hash) {
			return {}, {}, 0, .Zero_Hash
		}
		if _, obj_ok := cache_object_kind_of_word(u64(response.realisation.output_kind)); !obj_ok {
			return {}, {}, 0, .Bad_Object_Kind
		}
		return kind, status, REALISATION_WIRE_SIZE, .None
	case .Put_Object:
		return kind, status, 0, .None
	case .Put_Realisation:
		return kind, status, 0, .None
	}
	return {}, {}, 0, .Bad_Request_Kind
}

// encoded_response_size returns the exact frame byte size for a valid response,
// or 0 with the refusal when response is invalid.
encoded_response_size :: proc "contextless" (response: ^Cache_Response) -> (size: int, refusal: Wire_Refusal) {
	_, _, body_length, check_refusal := validate_response(response)
	if check_refusal != .None {
		return 0, check_refusal
	}
	return FRAME_HEADER_SIZE + body_length, .None
}

// encode_response validates response and writes its complete binary frame into
// output. A refused call writes zero bytes to output.
encode_response :: proc "contextless" (response: ^Cache_Response, output: []u8) -> (written: int, refusal: Wire_Refusal) {
	kind, status, body_length, check_refusal := validate_response(response)
	if check_refusal != .None {
		return 0, check_refusal
	}
	total_size := FRAME_HEADER_SIZE + body_length
	if len(output) < total_size {
		return 0, .Buffer_Too_Small
	}
	magic := RESPONSE_MAGIC
	copy(output[0:4], magic[:])
	output[4] = WIRE_VERSION
	output[5] = u8(kind)
	output[6] = u8(status)
	output[7] = 0
	byte_order.write_u32_little_endian(output, 8, u32(body_length))
	if status != .Ok {
		return total_size, .None
	}
	body := output[FRAME_HEADER_SIZE:total_size]
	switch kind {
	case .Has:
		byte_order.write_u64_little_endian(body, 0, response.present_bitset)
	case .Get_Object:
		body[0] = u8(response.object_kind)
		body[1] = 0
		body[2] = 0
		body[3] = 0
		byte_order.write_u32_little_endian(body, 4, u32(len(response.payload)))
		copy(body[GET_OBJECT_RESPONSE_HEADER_SIZE:], response.payload)
	case .Get_Realisation:
		_, record_refusal := encode_realisation_record(&response.realisation, body)
		if record_refusal != .None {
			return 0, record_refusal
		}
	case .Put_Object:
		// No response body on Ok.
	case .Put_Realisation:
		// No response body on Ok.
	}
	return total_size, .None
}

// inspect_response_header validates only the 12-byte response header so a
// stream reader knows how many body bytes to read before calling decode_response.
inspect_response_header :: proc "contextless" (header: []u8) -> (kind: Cache_Request_Kind, status: Cache_Response_Status, body_length: int, refusal: Wire_Refusal) {
	if len(header) < FRAME_HEADER_SIZE {
		return {}, {}, 0, .Truncated
	}
	magic := RESPONSE_MAGIC
	for index in 0 ..< len(magic) {
		if header[index] != magic[index] {
			return {}, {}, 0, .Bad_Magic
		}
	}
	if header[4] != WIRE_VERSION {
		return {}, {}, 0, .Unsupported_Version
	}
	checked_kind, kind_ok := cache_request_kind_of_word(u64(header[5]))
	if !kind_ok {
		return {}, {}, 0, .Bad_Request_Kind
	}
	checked_status, status_ok := cache_response_status_of_word(u64(header[6]))
	if !status_ok {
		return {}, {}, 0, .Bad_Response_Status
	}
	if header[7] != 0 {
		return {}, {}, 0, .Reserved_Nonzero
	}
	raw_body_length := byte_order.read_u32_little_endian(header, 8)
	if u64(raw_body_length) > u64(MAX_RESPONSE_BODY_BYTES) {
		return {}, {}, 0, .Too_Large
	}
	return checked_kind, checked_status, int(raw_body_length), .None
}

// decode_response strictly validates a complete binary response frame.
decode_response :: proc "contextless" (frame: []u8) -> (response: Cache_Response, refusal: Wire_Refusal) {
	kind, status, body_length, header_refusal := inspect_response_header(frame)
	if header_refusal != .None {
		return {}, header_refusal
	}
	expected_total := FRAME_HEADER_SIZE + body_length
	if len(frame) < expected_total {
		return {}, .Truncated
	}
	if len(frame) > expected_total {
		return {}, .Trailing_Bytes
	}
	response.request_kind = kind
	response.status = status
	body := frame[FRAME_HEADER_SIZE:expected_total]
	if status != .Ok {
		if len(body) > 0 {
			return {}, .Trailing_Bytes
		}
		return response, .None
	}
	switch kind {
	case .Has:
		if len(body) < HAS_RESPONSE_BODY_SIZE {
			return {}, .Truncated
		}
		if len(body) > HAS_RESPONSE_BODY_SIZE {
			return {}, .Trailing_Bytes
		}
		response.present_bitset = byte_order.read_u64_little_endian(body, 0)
	case .Get_Object:
		if len(body) < GET_OBJECT_RESPONSE_HEADER_SIZE {
			return {}, .Truncated
		}
		obj_kind, obj_ok := cache_object_kind_of_word(u64(body[0]))
		if !obj_ok {
			return {}, .Bad_Object_Kind
		}
		if body[1] != 0 || body[2] != 0 || body[3] != 0 {
			return {}, .Reserved_Nonzero
		}
		raw_payload_length := byte_order.read_u32_little_endian(body, 4)
		if u64(raw_payload_length) > u64(payload_bound_for_kind(obj_kind)) {
			return {}, .Too_Large
		}
		expected_body := GET_OBJECT_RESPONSE_HEADER_SIZE + int(raw_payload_length)
		if len(body) < expected_body {
			return {}, .Truncated
		}
		if len(body) > expected_body {
			return {}, .Trailing_Bytes
		}
		response.object_kind = obj_kind
		response.payload = body[GET_OBJECT_RESPONSE_HEADER_SIZE:expected_body]
	case .Get_Realisation:
		record, record_refusal := decode_realisation_record(body)
		if record_refusal != .None {
			return {}, record_refusal
		}
		response.realisation = record
	case .Put_Object:
		if len(body) > 0 {
			return {}, .Trailing_Bytes
		}
	case .Put_Realisation:
		if len(body) > 0 {
			return {}, .Trailing_Bytes
		}
	}
	return response, .None
}

// verify_object_content verifies that payload matches expected_hash under the
// hashing rule of object_kind: plain blake3.hash for Blob, or canonical
// validation plus domain-separated tree_hash.tree_hash for Tree.
verify_object_content :: proc "contextless" (
	object_kind: Cache_Object_Kind,
	expected_hash: blake3.Hash,
	payload: []u8,
) -> Substitution_Decision {
	if hash_is_zero(expected_hash) {
		return .Refuse_Malformed
	}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(object_kind))
	if !kind_ok {
		return .Refuse_Malformed
	}
	switch checked_kind {
	case .Blob:
		if len(payload) > MAX_OBJECT_PAYLOAD_BYTES {
			return .Refuse_Malformed
		}
		computed := blake3.hash(payload)
		if hashes_equal_constant_time(computed, expected_hash) {
			return .Trust_By_Hash
		}
		return .Refuse_Hash_Mismatch
	case .Tree:
		if len(payload) > MAX_TREE_PAYLOAD_BYTES {
			return .Refuse_Malformed
		}
		computed, tree_refusal := tree_hash.tree_hash(payload)
		if tree_refusal != .None {
			return .Refuse_Malformed
		}
		if hashes_equal_constant_time(computed, expected_hash) {
			return .Trust_By_Hash
		}
		return .Refuse_Hash_Mismatch
	}
	return .Refuse_Malformed
}

// signer_is_trusted checks whether candidate matches any public key in
// trusted_signers using constant-time key comparison.
signer_is_trusted :: proc "contextless" (trusted_signers: [][PUBLIC_KEY_SIZE]u8, candidate: [PUBLIC_KEY_SIZE]u8) -> bool {
	candidate_copy := candidate
	if bytes_all_zero(candidate_copy[:]) {
		return false
	}
	matched := false
	for key in trusted_signers {
		if hashes_equal_constant_time(key, candidate) {
			matched = true
		}
	}
	return matched
}

// substitution_check evaluates whether a fetched object or realisation may be
// accepted under policy.
//
// - A content-addressed object (Substitution_Object_Subject) is verified solely
//   by recomputing its BLAKE3 or domain-separated tree hash: no signer is
//   needed, and a single differing bit returns Refuse_Hash_Mismatch.
// - A realisation (Substitution_Realisation_Subject) must match
//   expected_recipe_hash, carry a valid output_kind and non-zero hashes, name a
//   signer public key present in policy.trusted_signers (and not in Build_Only
//   mode), and pass Ed25519 signature verification via verify_signature.
substitution_check :: proc "contextless" (
	policy: Substitution_Policy,
	subject: Substitution_Subject,
	verify_signature: Signature_Verify_Proc = nil,
	user_data: rawptr = nil,
) -> Substitution_Decision {
	checked_mode, mode_ok := substitution_mode_of_word(u64(policy.mode))
	if !mode_ok {
		return .Refuse_Malformed
	}
	switch item in subject {
	case Substitution_Object_Subject:
		return verify_object_content(item.object_kind, item.expected_hash, item.payload)
	case Substitution_Realisation_Subject:
		if hash_is_zero(item.expected_recipe_hash) {
			return .Refuse_Malformed
		}
		if hash_is_zero(item.realisation.recipe_hash) || hash_is_zero(item.realisation.output_hash) {
			return .Refuse_Malformed
		}
		if _, kind_ok := cache_object_kind_of_word(u64(item.realisation.output_kind)); !kind_ok {
			return .Refuse_Malformed
		}
		if !hashes_equal_constant_time(item.realisation.recipe_hash, item.expected_recipe_hash) {
			return .Refuse_Malformed
		}
		signer_copy := item.realisation.signer_public_key
		if bytes_all_zero(signer_copy[:]) {
			return .Refuse_Malformed
		}
		// In Build_Only mode no remote realisation is ever substituted.
		switch checked_mode {
		case .Build_Only:
			return .Refuse_Untrusted_Signer
		case .Prefer_Cache, .Cache_Only, .Verify:
			// Allowed to verify against trusted_signers.
		}
		if !signer_is_trusted(policy.trusted_signers, item.realisation.signer_public_key) {
			return .Refuse_Untrusted_Signer
		}
		record_copy := item.realisation
		signing_bytes, signing_ok := realisation_signing_bytes(&record_copy)
		if !signing_ok {
			return .Refuse_Malformed
		}
		if verify_signature == nil {
			return .Refuse_Bad_Signature
		}
		if !verify_signature(item.realisation.signer_public_key, signing_bytes[:], item.realisation.signature, user_data) {
			return .Refuse_Bad_Signature
		}
		return .Trust_By_Signer
	}
	return .Refuse_Malformed
}
