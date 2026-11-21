// Store version sync wire protocol and pure three-way version reconciliation
// (src/md/features/several_machines.md, "The exchange of a store between
// machines").
//
// Each machine writes its own private stores immediately even while offline.
// When two paired machines meet, they exchange store heads and missing objects
// by content hash and reconcile versions through a pure three-way state
// machine:
//   - Fast-forward when only one side moved past the common base version.
//   - Conflict fork when both sides diverged from the common base version,
//     preserving both parent commits and conflict values in data so no commit
//     is ever silently overwritten by last-writer-wins.
package machine_mesh

import "modus:contract/blake3"
import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/tree_hash"

// Wire magic, version, and frame header size for store sync frames.
SYNC_WIRE_MAGIC :: [4]u8{'M', 'S', 'Y', 'N'}
SYNC_WIRE_VERSION :: u8(1)
SYNC_FRAME_HEADER_SIZE :: 12

// Domain separation contexts for deterministic version node, conflict fork,
// and conflict value hashes.
VERSION_NODE_HASH_DOMAIN :: "modus version node v1"
CONFLICT_FORK_HASH_DOMAIN :: "modus sync conflict fork v1"
CONFLICT_VALUE_HASH_DOMAIN :: "modus sync conflict value v1"

// Bounds on counts and payloads carried in one sync frame.
MAX_SYNC_HEADS :: 16
MAX_SYNC_WANT_OBJECTS :: 64
MAX_SYNC_OBJECT_BYTES :: 64 * 1024

// Exact wire body sizes for fixed-size frames and variable frame headers.
SYNC_HEADS_OFFER_HEADER_SIZE :: blake3.HASH_SIZE + blake3.HASH_SIZE + 1 + 1 + 2
SYNC_WANT_OBJECTS_HEADER_SIZE :: blake3.HASH_SIZE + 1 + 3
SYNC_SEND_OBJECT_HEADER_SIZE :: blake3.HASH_SIZE + blake3.HASH_SIZE + 1 + 3 + 4
SYNC_ACK_BODY_SIZE :: blake3.HASH_SIZE * 3
SYNC_REFUSAL_BODY_SIZE :: blake3.HASH_SIZE + 1 + 3

MAX_SYNC_BODY_BYTES :: SYNC_SEND_OBJECT_HEADER_SIZE + MAX_SYNC_OBJECT_BYTES

#assert(SYNC_FRAME_HEADER_SIZE == 12)
#assert(SYNC_HEADS_OFFER_HEADER_SIZE == 68)
#assert(SYNC_WANT_OBJECTS_HEADER_SIZE == 36)
#assert(SYNC_SEND_OBJECT_HEADER_SIZE == 72)
#assert(SYNC_ACK_BODY_SIZE == 96)
#assert(SYNC_REFUSAL_BODY_SIZE == 36)

// Closed set of wire frame kinds for store delta synchronization.
Sync_Frame_Kind :: enum u8 {
	Heads_Offer  = 1,
	Want_Objects = 2,
	Send_Object  = 3,
	Sync_Ack     = 4,
	Sync_Refusal = 5,
}

// Closed set of content-addressed object kinds carried in Send_Object frames.
Sync_Object_Kind :: enum u8 {
	Blob         = 1,
	Tree         = 2,
	Version_Node = 3,
}

// Closed set of explicit sync refusal reasons sent over the wire.
Sync_Refusal_Reason :: enum u8 {
	Unauthorized    = 1,
	Unknown_Store   = 2,
	Hash_Mismatch   = 3,
	Object_Too_Large = 4,
	Protocol_Error  = 5,
	Revoked         = 6,
}

// Closed set of framing and validation refusals for sync wire encoding/decoding.
Sync_Wire_Refusal :: enum u8 {
	None                = 0,
	Truncated           = 1,
	Bad_Magic           = 2,
	Unsupported_Version = 3,
	Bad_Frame_Kind      = 4,
	Bad_Object_Kind     = 5,
	Bad_Refusal_Reason  = 6,
	Reserved_Nonzero    = 7,
	Zero_Hash           = 8,
	Bad_Count           = 9,
	Duplicate_Hash      = 10,
	Too_Large           = 11,
	Trailing_Bytes      = 12,
	Buffer_Too_Small    = 13,
	Bad_Flag            = 14,
}

// Decoded or buildable store delta sync wire frame.
// For Send_Object, payload borrows directly from the input slice during decode.
Sync_Frame :: struct {
	kind:                 Sync_Frame_Kind,
	store_id:             blake3.Hash,
	has_common_base:      bool,
	common_base_hash:     blake3.Hash,
	head_count:           u8,
	heads:                [MAX_SYNC_HEADS]blake3.Hash,
	want_count:           u8,
	want_hashes:          [MAX_SYNC_WANT_OBJECTS]blake3.Hash,
	object_hash:          blake3.Hash,
	object_kind:          Sync_Object_Kind,
	payload:              []u8,
	acked_head_hash:      blake3.Hash,
	new_common_base_hash: blake3.Hash,
	refusal_reason:       Sync_Refusal_Reason,
}

// Closed outcome of three-way version head reconciliation.
Reconcile_Outcome :: enum u8 {
	Already_Up_To_Date     = 1,
	Fast_Forward_Local     = 2,
	Remote_Behind_Local    = 3,
	Conflict_Fork          = 4,
	Refused_Invalid_Hashes = 5,
}

// Deterministic conflict fork record preserving both diverged heads and their
// common base so no commit is ever lost.
Conflict_Fork_Record :: struct {
	has_common_base:   bool,
	common_base_hash:  blake3.Hash,
	local_head_hash:   blake3.Hash,
	remote_head_hash:  blake3.Hash,
	merge_commit_hash: blake3.Hash,
}

// Result of reconciling a local store head against a remote store head.
Reconcile_Result :: struct {
	outcome:              Reconcile_Outcome,
	resulting_head_hash:  blake3.Hash,
	new_common_base_hash: blake3.Hash,
	conflict_fork:        Conflict_Fork_Record,
}

// Closed per-object three-way merge decision.
Object_Merge_Decision :: enum u8 {
	Unchanged          = 1,
	Take_Local         = 2,
	Take_Remote        = 3,
	Both_Same          = 4,
	Conflict_Keep_Both = 5,
}

// Conflict value kept directly in the store when both machines modified one
// object differently from the common base.
Conflict_Value :: struct {
	base_hash:           blake3.Hash,
	local_hash:          blake3.Hash,
	remote_hash:         blake3.Hash,
	conflict_value_hash: blake3.Hash,
}

// Closed state of one store sync session state machine.
Sync_Session_State :: enum u8 {
	Idle            = 1,
	Waiting_Objects = 2,
	Reconciled      = 3,
	Refused         = 4,
}

// Expected content-addressed object requested during a delta sync receive session.
Expected_Sync_Object :: struct {
	kind: Sync_Object_Kind,
	hash: blake3.Hash,
}

// Pure state machine tracking one peer's delta sync session for a single store.
Sync_Session :: struct {
	state:                Sync_Session_State,
	store_id:             blake3.Hash,
	has_common_base:      bool,
	common_base_hash:     blake3.Hash,
	local_head_hash:      blake3.Hash,
	remote_head_hash:     blake3.Hash,
	expected_count:       u8,
	expected_hashes:      [MAX_SYNC_WANT_OBJECTS]blake3.Hash,
	expected_kinds:       [MAX_SYNC_WANT_OBJECTS]Sync_Object_Kind,
	received_mask:        u64,
	reconcile_result:     Reconcile_Result,
	last_refusal_reason:  Sync_Refusal_Reason,
}

// Single borders converting raw wire bytes into closed enum members.
sync_frame_kind_of_word :: proc "contextless" (word: u64) -> (kind: Sync_Frame_Kind, ok: bool) {
	return enum_word.member_of_word(Sync_Frame_Kind, word)
}

sync_object_kind_of_word :: proc "contextless" (word: u64) -> (kind: Sync_Object_Kind, ok: bool) {
	return enum_word.member_of_word(Sync_Object_Kind, word)
}

sync_refusal_reason_of_word :: proc "contextless" (word: u64) -> (reason: Sync_Refusal_Reason, ok: bool) {
	return enum_word.member_of_word(Sync_Refusal_Reason, word)
}

// sync_object_payload_bound gives the maximum payload size for object_kind.
@(private)
sync_object_payload_bound :: proc "contextless" (kind: Sync_Object_Kind) -> int {
	switch kind {
	case .Blob:
		return MAX_SYNC_OBJECT_BYTES
	case .Tree:
		return tree_hash.MAX_ENCODED_TREE_BYTES
	case .Version_Node:
		return MAX_SYNC_OBJECT_BYTES
	}
	return 0
}

// validate_sync_frame checks every semantic field of frame and computes the
// exact wire body length.
@(private)
validate_sync_frame :: proc "contextless" (frame: ^Sync_Frame) -> (checked_kind: Sync_Frame_Kind, body_length: int, refusal: Sync_Wire_Refusal) {
	if frame == nil {
		return {}, 0, .Bad_Frame_Kind
	}
	kind, kind_ok := sync_frame_kind_of_word(u64(frame.kind))
	if !kind_ok {
		return {}, 0, .Bad_Frame_Kind
	}
	if key_is_zero(frame.store_id) {
		return {}, 0, .Zero_Hash
	}
	switch kind {
	case .Heads_Offer:
		if frame.has_common_base {
			if key_is_zero(frame.common_base_hash) {
				return {}, 0, .Zero_Hash
			}
		} else {
			if !key_is_zero(frame.common_base_hash) {
				return {}, 0, .Bad_Flag
			}
		}
		if frame.head_count == 0 || int(frame.head_count) > MAX_SYNC_HEADS {
			return {}, 0, .Bad_Count
		}
		for index in 0 ..< int(frame.head_count) {
			if key_is_zero(frame.heads[index]) {
				return {}, 0, .Zero_Hash
			}
			for earlier in 0 ..< index {
				if keys_equal_constant_time(frame.heads[earlier], frame.heads[index]) {
					return {}, 0, .Duplicate_Hash
				}
			}
		}
		return kind, SYNC_HEADS_OFFER_HEADER_SIZE + int(frame.head_count) * blake3.HASH_SIZE, .None
	case .Want_Objects:
		if frame.want_count == 0 || int(frame.want_count) > MAX_SYNC_WANT_OBJECTS {
			return {}, 0, .Bad_Count
		}
		for index in 0 ..< int(frame.want_count) {
			if key_is_zero(frame.want_hashes[index]) {
				return {}, 0, .Zero_Hash
			}
			for earlier in 0 ..< index {
				if keys_equal_constant_time(frame.want_hashes[earlier], frame.want_hashes[index]) {
					return {}, 0, .Duplicate_Hash
				}
			}
		}
		return kind, SYNC_WANT_OBJECTS_HEADER_SIZE + int(frame.want_count) * blake3.HASH_SIZE, .None
	case .Send_Object:
		if key_is_zero(frame.object_hash) {
			return {}, 0, .Zero_Hash
		}
		obj_kind, obj_ok := sync_object_kind_of_word(u64(frame.object_kind))
		if !obj_ok {
			return {}, 0, .Bad_Object_Kind
		}
		if len(frame.payload) > sync_object_payload_bound(obj_kind) {
			return {}, 0, .Too_Large
		}
		return kind, SYNC_SEND_OBJECT_HEADER_SIZE + len(frame.payload), .None
	case .Sync_Ack:
		if key_is_zero(frame.acked_head_hash) || key_is_zero(frame.new_common_base_hash) {
			return {}, 0, .Zero_Hash
		}
		return kind, SYNC_ACK_BODY_SIZE, .None
	case .Sync_Refusal:
		if _, reason_ok := sync_refusal_reason_of_word(u64(frame.refusal_reason)); !reason_ok {
			return {}, 0, .Bad_Refusal_Reason
		}
		return kind, SYNC_REFUSAL_BODY_SIZE, .None
	}
	return {}, 0, .Bad_Frame_Kind
}

// sync_frame_encoded_size returns the exact wire size of frame, or 0 with the
// refusal when invalid.
sync_frame_encoded_size :: proc "contextless" (frame: ^Sync_Frame) -> (size: int, refusal: Sync_Wire_Refusal) {
	_, body_length, check_refusal := validate_sync_frame(frame)
	if check_refusal != .None {
		return 0, check_refusal
	}
	return SYNC_FRAME_HEADER_SIZE + body_length, .None
}

// sync_frame_encode validates frame and writes its complete binary wire frame
// into output. A refused call writes zero bytes to output.
sync_frame_encode :: proc "contextless" (frame: ^Sync_Frame, output: []u8) -> (written: int, refusal: Sync_Wire_Refusal) {
	kind, body_length, check_refusal := validate_sync_frame(frame)
	if check_refusal != .None {
		return 0, check_refusal
	}
	total_size := SYNC_FRAME_HEADER_SIZE + body_length
	if len(output) < total_size {
		return 0, .Buffer_Too_Small
	}
	magic := SYNC_WIRE_MAGIC
	copy(output[0:4], magic[:])
	output[4] = SYNC_WIRE_VERSION
	output[5] = u8(kind)
	output[6] = 0
	output[7] = 0
	byte_order.write_u32_little_endian(output, 8, u32(body_length))
	body := output[SYNC_FRAME_HEADER_SIZE:total_size]
	copy(body[0:32], frame.store_id[:])
	switch kind {
	case .Heads_Offer:
		copy(body[32:64], frame.common_base_hash[:])
		body[64] = frame.has_common_base ? 1 : 0
		body[65] = frame.head_count
		body[66] = 0
		body[67] = 0
		for index in 0 ..< int(frame.head_count) {
			offset := SYNC_HEADS_OFFER_HEADER_SIZE + index * blake3.HASH_SIZE
			copy(body[offset:offset + blake3.HASH_SIZE], frame.heads[index][:])
		}
	case .Want_Objects:
		body[32] = frame.want_count
		body[33] = 0
		body[34] = 0
		body[35] = 0
		for index in 0 ..< int(frame.want_count) {
			offset := SYNC_WANT_OBJECTS_HEADER_SIZE + index * blake3.HASH_SIZE
			copy(body[offset:offset + blake3.HASH_SIZE], frame.want_hashes[index][:])
		}
	case .Send_Object:
		copy(body[32:64], frame.object_hash[:])
		body[64] = u8(frame.object_kind)
		body[65] = 0
		body[66] = 0
		body[67] = 0
		byte_order.write_u32_little_endian(body, 68, u32(len(frame.payload)))
		copy(body[SYNC_SEND_OBJECT_HEADER_SIZE:], frame.payload)
	case .Sync_Ack:
		copy(body[32:64], frame.acked_head_hash[:])
		copy(body[64:96], frame.new_common_base_hash[:])
	case .Sync_Refusal:
		body[32] = u8(frame.refusal_reason)
		body[33] = 0
		body[34] = 0
		body[35] = 0
	}
	return total_size, .None
}

// sync_frame_inspect_header validates the 12-byte sync frame header and returns
// the expected body length so stream readers can bound frame reads up front.
sync_frame_inspect_header :: proc "contextless" (header: []u8) -> (kind: Sync_Frame_Kind, body_length: int, refusal: Sync_Wire_Refusal) {
	if len(header) < SYNC_FRAME_HEADER_SIZE {
		return {}, 0, .Truncated
	}
	magic := SYNC_WIRE_MAGIC
	for index in 0 ..< len(magic) {
		if header[index] != magic[index] {
			return {}, 0, .Bad_Magic
		}
	}
	if header[4] != SYNC_WIRE_VERSION {
		return {}, 0, .Unsupported_Version
	}
	checked_kind, kind_ok := sync_frame_kind_of_word(u64(header[5]))
	if !kind_ok {
		return {}, 0, .Bad_Frame_Kind
	}
	if header[6] != 0 || header[7] != 0 {
		return {}, 0, .Reserved_Nonzero
	}
	raw_body_length := byte_order.read_u32_little_endian(header, 8)
	if u64(raw_body_length) > u64(MAX_SYNC_BODY_BYTES) {
		return {}, 0, .Too_Large
	}
	return checked_kind, int(raw_body_length), .None
}

// sync_frame_decode strictly parses one complete sync wire frame.
sync_frame_decode :: proc "contextless" (input: []u8) -> (frame: Sync_Frame, refusal: Sync_Wire_Refusal) {
	kind, body_length, header_refusal := sync_frame_inspect_header(input)
	if header_refusal != .None {
		return {}, header_refusal
	}
	expected_total := SYNC_FRAME_HEADER_SIZE + body_length
	if len(input) < expected_total {
		return {}, .Truncated
	}
	if len(input) > expected_total {
		return {}, .Trailing_Bytes
	}
	body := input[SYNC_FRAME_HEADER_SIZE:expected_total]
	if len(body) < blake3.HASH_SIZE {
		return {}, .Truncated
	}
	frame.kind = kind
	copy(frame.store_id[:], body[0:32])
	if key_is_zero(frame.store_id) {
		return {}, .Zero_Hash
	}
	switch kind {
	case .Heads_Offer:
		if len(body) < SYNC_HEADS_OFFER_HEADER_SIZE {
			return {}, .Truncated
		}
		copy(frame.common_base_hash[:], body[32:64])
		base_flag := body[64]
		if base_flag != 0 && base_flag != 1 {
			return {}, .Bad_Flag
		}
		frame.has_common_base = base_flag == 1
		if frame.has_common_base {
			if key_is_zero(frame.common_base_hash) {
				return {}, .Zero_Hash
			}
		} else {
			if !key_is_zero(frame.common_base_hash) {
				return {}, .Bad_Flag
			}
		}
		head_count := body[65]
		if head_count == 0 || int(head_count) > MAX_SYNC_HEADS {
			return {}, .Bad_Count
		}
		if body[66] != 0 || body[67] != 0 {
			return {}, .Reserved_Nonzero
		}
		expected_body := SYNC_HEADS_OFFER_HEADER_SIZE + int(head_count) * blake3.HASH_SIZE
		if len(body) < expected_body {
			return {}, .Truncated
		}
		if len(body) > expected_body {
			return {}, .Trailing_Bytes
		}
		frame.head_count = head_count
		for index in 0 ..< int(head_count) {
			offset := SYNC_HEADS_OFFER_HEADER_SIZE + index * blake3.HASH_SIZE
			copy(frame.heads[index][:], body[offset:offset + blake3.HASH_SIZE])
			if key_is_zero(frame.heads[index]) {
				return {}, .Zero_Hash
			}
			for earlier in 0 ..< index {
				if keys_equal_constant_time(frame.heads[earlier], frame.heads[index]) {
					return {}, .Duplicate_Hash
				}
			}
		}
	case .Want_Objects:
		if len(body) < SYNC_WANT_OBJECTS_HEADER_SIZE {
			return {}, .Truncated
		}
		want_count := body[32]
		if want_count == 0 || int(want_count) > MAX_SYNC_WANT_OBJECTS {
			return {}, .Bad_Count
		}
		if body[33] != 0 || body[34] != 0 || body[35] != 0 {
			return {}, .Reserved_Nonzero
		}
		expected_body := SYNC_WANT_OBJECTS_HEADER_SIZE + int(want_count) * blake3.HASH_SIZE
		if len(body) < expected_body {
			return {}, .Truncated
		}
		if len(body) > expected_body {
			return {}, .Trailing_Bytes
		}
		frame.want_count = want_count
		for index in 0 ..< int(want_count) {
			offset := SYNC_WANT_OBJECTS_HEADER_SIZE + index * blake3.HASH_SIZE
			copy(frame.want_hashes[index][:], body[offset:offset + blake3.HASH_SIZE])
			if key_is_zero(frame.want_hashes[index]) {
				return {}, .Zero_Hash
			}
			for earlier in 0 ..< index {
				if keys_equal_constant_time(frame.want_hashes[earlier], frame.want_hashes[index]) {
					return {}, .Duplicate_Hash
				}
			}
		}
	case .Send_Object:
		if len(body) < SYNC_SEND_OBJECT_HEADER_SIZE {
			return {}, .Truncated
		}
		copy(frame.object_hash[:], body[32:64])
		if key_is_zero(frame.object_hash) {
			return {}, .Zero_Hash
		}
		obj_kind, obj_ok := sync_object_kind_of_word(u64(body[64]))
		if !obj_ok {
			return {}, .Bad_Object_Kind
		}
		if body[65] != 0 || body[66] != 0 || body[67] != 0 {
			return {}, .Reserved_Nonzero
		}
		raw_payload_length := byte_order.read_u32_little_endian(body, 68)
		if u64(raw_payload_length) > u64(sync_object_payload_bound(obj_kind)) {
			return {}, .Too_Large
		}
		expected_body := SYNC_SEND_OBJECT_HEADER_SIZE + int(raw_payload_length)
		if len(body) < expected_body {
			return {}, .Truncated
		}
		if len(body) > expected_body {
			return {}, .Trailing_Bytes
		}
		frame.object_kind = obj_kind
		frame.payload = body[SYNC_SEND_OBJECT_HEADER_SIZE:expected_body]
	case .Sync_Ack:
		if len(body) < SYNC_ACK_BODY_SIZE {
			return {}, .Truncated
		}
		if len(body) > SYNC_ACK_BODY_SIZE {
			return {}, .Trailing_Bytes
		}
		copy(frame.acked_head_hash[:], body[32:64])
		copy(frame.new_common_base_hash[:], body[64:96])
		if key_is_zero(frame.acked_head_hash) || key_is_zero(frame.new_common_base_hash) {
			return {}, .Zero_Hash
		}
	case .Sync_Refusal:
		if len(body) < SYNC_REFUSAL_BODY_SIZE {
			return {}, .Truncated
		}
		if len(body) > SYNC_REFUSAL_BODY_SIZE {
			return {}, .Trailing_Bytes
		}
		reason, reason_ok := sync_refusal_reason_of_word(u64(body[32]))
		if !reason_ok {
			return {}, .Bad_Refusal_Reason
		}
		if body[33] != 0 || body[34] != 0 || body[35] != 0 {
			return {}, .Reserved_Nonzero
		}
		frame.refusal_reason = reason
	}
	return frame, .None
}

// compare_hashes_lexicographically orders two 32-byte hashes so conflict fork
// hashes are symmetric across both machines regardless of which side calls
// itself local or remote.
@(private)
compare_hashes_lexicographically :: proc "contextless" (left, right: blake3.Hash) -> int {
	for index in 0 ..< blake3.HASH_SIZE {
		if left[index] != right[index] {
			return left[index] < right[index] ? -1 : 1
		}
	}
	return 0
}

// compute_conflict_fork_hash derives a deterministic, order-independent merge
// commit hash over the base hash and the sorted pair of diverged head hashes.
// Both machines therefore compute the exact same merge commit hash on a fork.
compute_conflict_fork_hash :: proc "contextless" (
	has_common_base: bool,
	common_base_hash: blake3.Hash,
	local_head_hash: blake3.Hash,
	remote_head_hash: blake3.Hash,
) -> blake3.Hash {
	first := local_head_hash
	second := remote_head_hash
	if compare_hashes_lexicographically(first, second) > 0 {
		first, second = second, first
	}
	input: [1 + blake3.HASH_SIZE * 3]u8
	base_copy := common_base_hash
	input[0] = has_common_base ? 1 : 0
	copy(input[1:33], base_copy[:])
	copy(input[33:65], first[:])
	copy(input[65:97], second[:])
	return blake3.derive_key(CONFLICT_FORK_HASH_DOMAIN, input[:])
}

// reconcile_heads runs the pure three-way version reconciliation rule.
//
// Cases:
//   - local == remote (both non-zero): Already_Up_To_Date.
//   - local == base (or local is empty on initial pull) and remote != base:
//     Fast_Forward_Local to remote_head_hash.
//   - remote == base and local != base: Remote_Behind_Local (local kept).
//   - local != base and remote != base and local != remote: Conflict_Fork
//     preserving both parents under a deterministic merge commit hash so no
//     commit is ever silently dropped.
reconcile_heads :: proc "contextless" (
	has_common_base: bool,
	common_base_hash: blake3.Hash,
	local_head_hash: blake3.Hash,
	remote_head_hash: blake3.Hash,
) -> Reconcile_Result {
	if has_common_base && key_is_zero(common_base_hash) {
		return Reconcile_Result{outcome = .Refused_Invalid_Hashes}
	}
	if !has_common_base && !key_is_zero(common_base_hash) {
		return Reconcile_Result{outcome = .Refused_Invalid_Hashes}
	}
	local_zero := key_is_zero(local_head_hash)
	remote_zero := key_is_zero(remote_head_hash)
	if local_zero && remote_zero {
		return Reconcile_Result{outcome = .Refused_Invalid_Hashes}
	}
	if local_zero {
		if has_common_base {
			return Reconcile_Result{outcome = .Refused_Invalid_Hashes}
		}
		return Reconcile_Result {
			outcome              = .Fast_Forward_Local,
			resulting_head_hash  = remote_head_hash,
			new_common_base_hash = remote_head_hash,
		}
	}
	if remote_zero {
		if has_common_base {
			return Reconcile_Result{outcome = .Refused_Invalid_Hashes}
		}
		// Keep common base empty until the remote has pulled and acknowledged
		// local_head_hash; advancing it now would lose local commits if the
		// remote commits offline before pulling.
		return Reconcile_Result {
			outcome              = .Remote_Behind_Local,
			resulting_head_hash  = local_head_hash,
			new_common_base_hash = {},
		}
	}
	if keys_equal_constant_time(local_head_hash, remote_head_hash) {
		return Reconcile_Result {
			outcome              = .Already_Up_To_Date,
			resulting_head_hash  = local_head_hash,
			new_common_base_hash = local_head_hash,
		}
	}
	if has_common_base && keys_equal_constant_time(local_head_hash, common_base_hash) {
		return Reconcile_Result {
			outcome              = .Fast_Forward_Local,
			resulting_head_hash  = remote_head_hash,
			new_common_base_hash = remote_head_hash,
		}
	}
	if has_common_base && keys_equal_constant_time(remote_head_hash, common_base_hash) {
		return Reconcile_Result {
			outcome              = .Remote_Behind_Local,
			resulting_head_hash  = local_head_hash,
			new_common_base_hash = common_base_hash,
		}
	}
	merge_hash := compute_conflict_fork_hash(has_common_base, common_base_hash, local_head_hash, remote_head_hash)
	return Reconcile_Result {
		outcome              = .Conflict_Fork,
		resulting_head_hash  = merge_hash,
		new_common_base_hash = merge_hash,
		conflict_fork = Conflict_Fork_Record {
			has_common_base   = has_common_base,
			common_base_hash  = common_base_hash,
			local_head_hash   = local_head_hash,
			remote_head_hash  = remote_head_hash,
			merge_commit_hash = merge_hash,
		},
	}
}

// reconcile_object applies three-way comparison to a single store object's
// hashes. When both sides changed the object to distinct hashes, it preserves
// the base and both sides in a deterministic Conflict_Value rather than
// picking one winner.
reconcile_object :: proc "contextless" (
	base_hash: blake3.Hash,
	local_hash: blake3.Hash,
	remote_hash: blake3.Hash,
) -> (decision: Object_Merge_Decision, chosen_hash: blake3.Hash, conflict: Conflict_Value) {
	local_same_as_base := keys_equal_constant_time(local_hash, base_hash)
	remote_same_as_base := keys_equal_constant_time(remote_hash, base_hash)
	if local_same_as_base && remote_same_as_base {
		return .Unchanged, base_hash, {}
	}
	if remote_same_as_base && !local_same_as_base {
		return .Take_Local, local_hash, {}
	}
	if local_same_as_base && !remote_same_as_base {
		return .Take_Remote, remote_hash, {}
	}
	if keys_equal_constant_time(local_hash, remote_hash) {
		return .Both_Same, local_hash, {}
	}
	first := local_hash
	second := remote_hash
	if compare_hashes_lexicographically(first, second) > 0 {
		first, second = second, first
	}
	input: [blake3.HASH_SIZE * 3]u8
	base_copy := base_hash
	copy(input[0:32], base_copy[:])
	copy(input[32:64], first[:])
	copy(input[64:96], second[:])
	conflict_hash := blake3.derive_key(CONFLICT_VALUE_HASH_DOMAIN, input[:])
	return .Conflict_Keep_Both, conflict_hash, Conflict_Value {
		base_hash           = base_hash,
		local_hash          = local_hash,
		remote_hash         = remote_hash,
		conflict_value_hash = conflict_hash,
	}
}

// version_node_hash computes the domain-separated BLAKE3 hash of a store
// version node so version nodes can never collide with plain Blob or Tree hashes.
version_node_hash :: proc "contextless" (payload: []u8) -> blake3.Hash {
	return blake3.derive_key(VERSION_NODE_HASH_DOMAIN, payload)
}

// sync_object_verify verifies that payload matches expected_hash according to
// object_kind: plain BLAKE3 for Blob, canonical tree hash for Tree, and
// domain-separated BLAKE3 for Version_Node.
sync_object_verify :: proc "contextless" (
	object_kind: Sync_Object_Kind,
	expected_hash: blake3.Hash,
	payload: []u8,
) -> bool {
	if key_is_zero(expected_hash) {
		return false
	}
	checked_kind, kind_ok := sync_object_kind_of_word(u64(object_kind))
	if !kind_ok {
		return false
	}
	if len(payload) > sync_object_payload_bound(checked_kind) {
		return false
	}
	switch checked_kind {
	case .Blob:
		computed := blake3.hash(payload)
		return keys_equal_constant_time(computed, expected_hash)
	case .Tree:
		computed, refusal := tree_hash.tree_hash(payload)
		if refusal != .None {
			return false
		}
		return keys_equal_constant_time(computed, expected_hash)
	case .Version_Node:
		computed := version_node_hash(payload)
		return keys_equal_constant_time(computed, expected_hash)
	}
	return false
}

// sync_session_begin_receive starts a receiving delta sync session when a peer
// offers a remote head and lists the typed objects missing locally. If
// missing_objects is empty, reconciliation completes immediately without
// waiting for objects.
sync_session_begin_receive :: proc "contextless" (
	store_id: blake3.Hash,
	has_common_base: bool,
	common_base_hash: blake3.Hash,
	local_head_hash: blake3.Hash,
	remote_head_hash: blake3.Hash,
	missing_objects: []Expected_Sync_Object,
) -> (session: Sync_Session, ok: bool) {
	if key_is_zero(store_id) || len(missing_objects) > MAX_SYNC_WANT_OBJECTS {
		return Sync_Session{state = .Refused, last_refusal_reason = .Protocol_Error}, false
	}
	preview := reconcile_heads(has_common_base, common_base_hash, local_head_hash, remote_head_hash)
	if preview.outcome == .Refused_Invalid_Hashes {
		return Sync_Session{state = .Refused, last_refusal_reason = .Protocol_Error}, false
	}
	for item, index in missing_objects {
		if key_is_zero(item.hash) {
			return Sync_Session{state = .Refused, last_refusal_reason = .Protocol_Error}, false
		}
		if _, kind_ok := sync_object_kind_of_word(u64(item.kind)); !kind_ok {
			return Sync_Session{state = .Refused, last_refusal_reason = .Protocol_Error}, false
		}
		for earlier in 0 ..< index {
			if keys_equal_constant_time(missing_objects[earlier].hash, item.hash) {
				return Sync_Session{state = .Refused, last_refusal_reason = .Protocol_Error}, false
			}
		}
	}
	session.store_id = store_id
	session.has_common_base = has_common_base
	session.common_base_hash = common_base_hash
	session.local_head_hash = local_head_hash
	session.remote_head_hash = remote_head_hash
	session.expected_count = u8(len(missing_objects))
	for item, index in missing_objects {
		checked_kind, _ := sync_object_kind_of_word(u64(item.kind))
		session.expected_hashes[index] = item.hash
		session.expected_kinds[index] = checked_kind
	}
	if len(missing_objects) == 0 {
		session.reconcile_result = preview
		session.state = .Reconciled
	} else {
		session.state = .Waiting_Objects
	}
	return session, true
}

// sync_session_receive_object processes one incoming Send_Object frame.
// Refuses wrong state, wrong store, unexpected object hash, mismatched object
// kind, duplicate delivery, or hash mismatch without mutating previously
// verified progress. Once every missing object is verified, the session
// transitions to Reconciled with the deterministic fast-forward or
// conflict-fork outcome.
sync_session_receive_object :: proc "contextless" (
	session: ^Sync_Session,
	frame: ^Sync_Frame,
) -> (reason: Sync_Refusal_Reason, ok: bool) {
	if session == nil || frame == nil {
		return .Protocol_Error, false
	}
	if session.state != .Waiting_Objects || frame.kind != .Send_Object {
		return .Protocol_Error, false
	}
	if !keys_equal_constant_time(frame.store_id, session.store_id) {
		return .Unknown_Store, false
	}
	checked_kind, kind_ok := sync_object_kind_of_word(u64(frame.object_kind))
	if !kind_ok {
		return .Protocol_Error, false
	}
	slot := -1
	for index in 0 ..< int(session.expected_count) {
		if keys_equal_constant_time(session.expected_hashes[index], frame.object_hash) {
			slot = index
			break
		}
	}
	if slot < 0 {
		return .Protocol_Error, false
	}
	if checked_kind != session.expected_kinds[slot] {
		return .Protocol_Error, false
	}
	bit := u64(1) << u64(slot)
	if session.received_mask & bit != 0 {
		return .Protocol_Error, false
	}
	if !sync_object_verify(checked_kind, frame.object_hash, frame.payload) {
		return .Hash_Mismatch, false
	}
	session.received_mask |= bit
	all_mask: u64
	if session.expected_count == 64 {
		all_mask = ~u64(0)
	} else {
		all_mask = (u64(1) << u64(session.expected_count)) - 1
	}
	if session.received_mask == all_mask {
		session.reconcile_result = reconcile_heads(
			session.has_common_base,
			session.common_base_hash,
			session.local_head_hash,
			session.remote_head_hash,
		)
		session.state = .Reconciled
	}
	return {}, true
}
