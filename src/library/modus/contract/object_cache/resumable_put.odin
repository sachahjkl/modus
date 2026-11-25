// Resumable frame-verified object cache upload state machine
// (src/md/features/recipes.md, "Objects of any size").
//
// Each 1 MiB frame is verified cryptographically against object_hash via its
// Bao inclusion proof (object_frames.odin) before updating the session bitmap
// or advancing the contiguous resume frontier. A refused call leaves session
// untouched.
//
// This contract file imports no support or host package and allocates no
// memory.
package object_cache

import "modus:contract/blake3"
import "modus:contract/enum_word"

// Inline capacity: 64 u64 words track a sliding 4096-frame (4 GiB) receive
// bitmap ahead of contiguous_frames in 512 bytes with zero heap allocation.
RESUMABLE_PUT_BITMAP_WORDS :: 64
RESUMABLE_PUT_WINDOW_FRAMES :: u64(RESUMABLE_PUT_BITMAP_WORDS * 64)

// Closed set of refusals returned by the resumable put state machine.
Resumable_Put_Refusal :: enum u8 {
	None               = 0,
	Bad_Session        = 1,
	Bad_Object_Kind    = 2,
	Zero_Hash          = 3,
	Too_Large          = 4,
	Frame_Out_Of_Range = 5,
	Bad_Frame_Length   = 6,
	Bad_Proof          = 7,
	Hash_Mismatch      = 8,
	Frame_Conflict     = 9,
	Already_Complete   = 10,
}

// Pure zero-allocation state of one resumable Bao-verified object upload.
Resumable_Put_Session :: struct {
	initialized:       bool,
	object_kind:       Cache_Object_Kind,
	object_hash:       blake3.Hash,
	object_size:       u64,
	frame_bytes:       u64,
	frame_count:       u64,
	contiguous_frames: u64,
	received_count:    u64,
	received_bitmap:   [RESUMABLE_PUT_BITMAP_WORDS]u64,
}

// resumable_put_refusal_of_word is the single border converting a raw word
// into a Resumable_Put_Refusal member. Unknown values are refused.
resumable_put_refusal_of_word :: proc "contextless" (word: u64) -> (refusal: Resumable_Put_Refusal, ok: bool) {
	return enum_word.member_of_word(Resumable_Put_Refusal, word)
}

// resumable_put_init initializes session for a resumable 1 MiB frame upload.
// On any refusal, session is zeroed.
resumable_put_init :: proc "contextless" (
	session: ^Resumable_Put_Session,
	object_kind: Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
) -> Resumable_Put_Refusal {
	return resumable_put_init_with(session, object_kind, object_hash, object_size, FRAME_PAYLOAD_BYTES)
}

// resumable_put_init_with initializes session with an explicit power-of-two
// frame size (a multiple of blake3.CHUNK_SIZE), allowing fast host tests over
// multi-frame Bao trees without multi-megabyte buffers.
resumable_put_init_with :: proc "contextless" (
	session: ^Resumable_Put_Session,
	object_kind: Cache_Object_Kind,
	object_hash: blake3.Hash,
	object_size: u64,
	frame_bytes: u64,
) -> Resumable_Put_Refusal {
	if session == nil {
		return .Bad_Session
	}
	session^ = {}
	checked_kind, kind_ok := cache_object_kind_of_word(u64(object_kind))
	if !kind_ok {
		return .Bad_Object_Kind
	}
	if hash_is_zero(object_hash) {
		return .Zero_Hash
	}
	if frame_bytes < blake3.CHUNK_SIZE || frame_bytes > FRAME_PAYLOAD_BYTES || frame_bytes % blake3.CHUNK_SIZE != 0 {
		return .Bad_Session
	}
	chunks := frame_bytes / blake3.CHUNK_SIZE
	if chunks & (chunks - 1) != 0 {
		return .Bad_Session
	}
	if object_size > payload_bound_for_kind(checked_kind) {
		return .Too_Large
	}
	count := frame_count_with(object_size, frame_bytes)
	if count == 0 || count > MAX_FRAME_COUNT {
		return .Too_Large
	}
	if checked_kind == .Tree && count != 1 {
		return .Too_Large
	}
	session^ = {
		initialized = true,
		object_kind = checked_kind,
		object_hash = object_hash,
		object_size = object_size,
		frame_bytes = frame_bytes,
		frame_count = count,
	}
	return .None
}

@(private = "file")
bitmap_bit_is_set :: proc "contextless" (bitmap: ^[RESUMABLE_PUT_BITMAP_WORDS]u64, rel_index: u64) -> bool {
	word := rel_index / 64
	bit := rel_index % 64
	return (bitmap[word] & (u64(1) << bit)) != 0
}

@(private = "file")
bitmap_bit_set :: proc "contextless" (bitmap: ^[RESUMABLE_PUT_BITMAP_WORDS]u64, rel_index: u64) {
	word := rel_index / 64
	bit := rel_index % 64
	bitmap[word] |= u64(1) << bit
}

// bitmap_shift_right shifts the sliding receive bitmap right by shift_bits
// when contiguous_frames advances.
@(private = "file")
bitmap_shift_right :: proc "contextless" (bitmap: ^[RESUMABLE_PUT_BITMAP_WORDS]u64, shift_bits: u64) {
	if shift_bits == 0 {
		return
	}
	if shift_bits >= RESUMABLE_PUT_WINDOW_FRAMES {
		bitmap^ = {}
		return
	}
	word_shift := int(shift_bits / 64)
	bit_shift := uint(shift_bits % 64)
	for index := 0; index < RESUMABLE_PUT_BITMAP_WORDS; index += 1 {
		src := index + word_shift
		low: u64 = 0
		if src < RESUMABLE_PUT_BITMAP_WORDS {
			low = bitmap[src] >> bit_shift
		}
		high: u64 = 0
		if bit_shift > 0 && src + 1 < RESUMABLE_PUT_BITMAP_WORDS {
			high = bitmap[src + 1] << (64 - bit_shift)
		}
		bitmap[index] = low | high
	}
}

// resumable_put_accept_frame verifies frame frame_index against session's
// root hash and Bao inclusion proof, then marks it received and advances the
// contiguous resume frontier. Refuses out-of-range frames, bad lengths, bad
// proofs, hash mismatches, duplicate frames (Frame_Conflict), or frames past
// completion without mutating session.
resumable_put_accept_frame :: proc "contextless" (
	session: ^Resumable_Put_Session,
	frame_index: u64,
	proof: []u8,
	frame: []u8,
) -> Resumable_Put_Refusal {
	if session == nil || !session.initialized || session.frame_count == 0 {
		return .Bad_Session
	}
	if session.received_count >= session.frame_count {
		return .Already_Complete
	}
	if frame_index >= session.frame_count {
		return .Frame_Out_Of_Range
	}
	expected_len, len_ok := frame_length_with(session.object_size, frame_index, session.frame_bytes)
	if !len_ok || u64(len(frame)) != expected_len {
		return .Bad_Frame_Length
	}
	path, path_ok := object_frame_path(session.frame_count, frame_index)
	if !path_ok || len(proof) != path.depth * PROOF_ENTRY_SIZE {
		return .Bad_Proof
	}

	// Verify Bao proof & frame digest before consulting or mutating session state.
	decision := frame_verify_with(
		session.object_kind,
		session.object_hash,
		session.object_size,
		frame_index,
		proof,
		frame,
		session.frame_bytes,
	)
	switch decision {
	case .Trust_By_Hash:
	case .Refuse_Hash_Mismatch:
		return .Hash_Mismatch
	case .Refuse_Malformed, .Trust_By_Signer, .Refuse_Untrusted_Signer, .Refuse_Bad_Signature:
		return .Bad_Proof
	}

	// Refuse duplicate frames (already below frontier or already set in window).
	if frame_index < session.contiguous_frames {
		return .Frame_Conflict
	}
	rel_index := frame_index - session.contiguous_frames
	if rel_index >= RESUMABLE_PUT_WINDOW_FRAMES {
		return .Frame_Out_Of_Range
	}
	if bitmap_bit_is_set(&session.received_bitmap, rel_index) {
		return .Frame_Conflict
	}

	bitmap_bit_set(&session.received_bitmap, rel_index)
	session.received_count += 1

	advance: u64 = 0
	for advance < RESUMABLE_PUT_WINDOW_FRAMES &&
	    session.contiguous_frames + advance < session.frame_count &&
	    bitmap_bit_is_set(&session.received_bitmap, advance) {
		advance += 1
	}
	if advance > 0 {
		bitmap_shift_right(&session.received_bitmap, advance)
		session.contiguous_frames += advance
	}
	return .None
}

// resumable_put_resume_offset returns the byte offset of the first missing
// frame (contiguous_frames * frame_bytes, clamped to object_size when complete).
resumable_put_resume_offset :: proc "contextless" (session: ^Resumable_Put_Session) -> (offset: u64, ok: bool) {
	if session == nil || !session.initialized {
		return 0, false
	}
	if session.contiguous_frames >= session.frame_count {
		return session.object_size, true
	}
	return session.contiguous_frames * session.frame_bytes, true
}

// resumable_put_is_complete returns true only when every frame of session has
// been cryptographically verified and the contiguous frontier covers all frames.
resumable_put_is_complete :: proc "contextless" (session: ^Resumable_Put_Session) -> bool {
	return session != nil &&
	       session.initialized &&
	       session.frame_count > 0 &&
	       session.received_count == session.frame_count &&
	       session.contiguous_frames == session.frame_count
}
