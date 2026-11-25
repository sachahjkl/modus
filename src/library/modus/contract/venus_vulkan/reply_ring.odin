// Sequenced host Vulkan reply frame parser and in-flight submission tracker
// extending venus_ring.odin and venus_exchange.odin
// (src/md/features/gpu_access.md, "The Venus wire").
//
// Matches incoming host reply frames against tracked request sequence IDs,
// command types, and per-request payload bounds. Refuses truncated, corrupt,
// misaligned, mismatched-sequence, or oversized replies without mutating
// caller state or output slices.
package venus_vulkan

import "modus:contract/byte_order"

// Format property: deterministic 24-byte little-endian reply frame header
// ("VNRP") framing host Vulkan replies by sequence number.
REPLY_FRAME_MAGIC :: u32(0x564E_5250)
REPLY_FRAME_HEADER_SIZE :: 24

// Plan value: matches VirtIO-GPU MAX_SUBMIT_3D_BYTES (64 KiB) so one host
// reply frame fits inside one bounded shared-memory transfer without heap use.
REPLY_FRAME_MAX_PAYLOAD_BYTES :: u32(65536)

// Inline capacity: tracks up to 32 concurrent sequenced Venus requests in
// flight on the driver side without dynamic allocation.
REPLY_RING_PENDING_CAPACITY :: 32

// Closed refusal set returned by reply frame and tracker procedures.
Reply_Ring_Refusal :: enum u8 {
	None                  = 0,
	Null_State            = 1,
	Buffer_Too_Short      = 2,
	Bad_Magic             = 3,
	Non_Zero_Reserved     = 4,
	Unknown_Command_Type  = 5,
	Unknown_Vk_Result     = 6,
	Payload_Too_Large     = 7,
	Payload_Misaligned    = 8,
	Truncated_Frame       = 9,
	Trailing_Bytes        = 10,
	Sequence_Mismatch     = 11,
	Command_Type_Mismatch = 12,
	Pending_Queue_Full    = 13,
	Pending_Not_Found     = 14,
	Duplicate_Sequence    = 15,
	Zero_Sequence         = 16,
}

// Fixed 24-byte header of one sequenced host Vulkan reply frame.
Reply_Frame_Header :: struct {
	seqno:         u32,
	command_type:  Command_Type,
	vk_result:     Vulkan_Result,
	payload_bytes: u32,
}

// Decoded host reply frame referencing the caller's validated payload slice.
Reply_Frame :: struct {
	header:  Reply_Frame_Header,
	payload: []u8,
}

// One tracked in-flight Venus submission waiting for its sequenced host reply.
Pending_Reply_Slot :: struct {
	active:          bool,
	seqno:           u32,
	command_type:    Command_Type,
	max_reply_bytes: u32,
}

// Fixed-capacity driver-side tracker of in-flight sequenced Venus requests.
Reply_Ring_Tracker :: struct {
	slots:             [REPLY_RING_PENDING_CAPACITY]Pending_Reply_Slot,
	pending_count:     int,
	completed_count:   u64,
	refused_count:     u64,
}

// reply_frame_encode serializes header and payload into dst. Writes zero bytes
// on any refusal.
reply_frame_encode :: proc "contextless" (
	header: Reply_Frame_Header,
	payload: []u8,
	dst: []u8,
) -> (
	written: int,
	refusal: Reply_Ring_Refusal,
) {
	if header.seqno == 0 {
		return 0, .Zero_Sequence
	}
	if _, ok := command_type_of_word(u32(header.command_type)); !ok {
		return 0, .Unknown_Command_Type
	}
	if _, ok := vulkan_result_of_word(i32(header.vk_result)); !ok {
		return 0, .Unknown_Vk_Result
	}
	if u64(len(payload)) > u64(REPLY_FRAME_MAX_PAYLOAD_BYTES) {
		return 0, .Payload_Too_Large
	}
	if len(payload) % 4 != 0 {
		return 0, .Payload_Misaligned
	}
	total := REPLY_FRAME_HEADER_SIZE + len(payload)
	if len(dst) < total {
		return 0, .Buffer_Too_Short
	}
	byte_order.write_u32_little_endian(dst, 0, REPLY_FRAME_MAGIC)
	byte_order.write_u32_little_endian(dst, 4, header.seqno)
	byte_order.write_u32_little_endian(dst, 8, u32(header.command_type))
	byte_order.write_u32_little_endian(dst, 12, u32(i32(header.vk_result)))
	byte_order.write_u32_little_endian(dst, 16, u32(len(payload)))
	byte_order.write_u32_little_endian(dst, 20, 0) // reserved
	if len(payload) > 0 {
		copy(dst[REPLY_FRAME_HEADER_SIZE:total], payload)
	}
	return total, .None
}

// reply_frame_decode validates a framed host Vulkan reply and copies its
// payload into payload_out only after every border check passes.
reply_frame_decode :: proc "contextless" (
	src: []u8,
	payload_out: []u8,
) -> (
	frame: Reply_Frame,
	refusal: Reply_Ring_Refusal,
) {
	if len(src) < REPLY_FRAME_HEADER_SIZE {
		return {}, .Truncated_Frame
	}
	if byte_order.read_u32_little_endian(src, 0) != REPLY_FRAME_MAGIC {
		return {}, .Bad_Magic
	}
	seqno := byte_order.read_u32_little_endian(src, 4)
	if seqno == 0 {
		return {}, .Zero_Sequence
	}
	cmd_type, cmd_ok := command_type_of_word(byte_order.read_u32_little_endian(src, 8))
	if !cmd_ok {
		return {}, .Unknown_Command_Type
	}
	vk_res, res_ok := vulkan_result_of_word(i32(byte_order.read_u32_little_endian(src, 12)))
	if !res_ok {
		return {}, .Unknown_Vk_Result
	}
	payload_bytes := byte_order.read_u32_little_endian(src, 16)
	reserved := byte_order.read_u32_little_endian(src, 20)
	if reserved != 0 {
		return {}, .Non_Zero_Reserved
	}
	if payload_bytes > REPLY_FRAME_MAX_PAYLOAD_BYTES {
		return {}, .Payload_Too_Large
	}
	if payload_bytes % 4 != 0 {
		return {}, .Payload_Misaligned
	}
	expected_len := u64(REPLY_FRAME_HEADER_SIZE) + u64(payload_bytes)
	if u64(len(src)) < expected_len {
		return {}, .Truncated_Frame
	}
	if u64(len(src)) > expected_len {
		return {}, .Trailing_Bytes
	}
	if u64(len(payload_out)) < u64(payload_bytes) {
		return {}, .Buffer_Too_Short
	}
	out_slice := payload_out[:payload_bytes]
	if payload_bytes > 0 {
		copy(out_slice, src[REPLY_FRAME_HEADER_SIZE:expected_len])
	}
	return Reply_Frame {
		header = Reply_Frame_Header {
			seqno         = seqno,
			command_type  = cmd_type,
			vk_result     = vk_res,
			payload_bytes = payload_bytes,
		},
		payload = out_slice,
	}, .None
}

// reply_ring_track_submit registers one in-flight sequenced Venus submission.
// Leaves tracker unmodified on refusal.
reply_ring_track_submit :: proc "contextless" (
	tracker: ^Reply_Ring_Tracker,
	seqno: u32,
	command_type: Command_Type,
	max_reply_bytes: u32,
) -> Reply_Ring_Refusal {
	if tracker == nil {
		return .Null_State
	}
	if seqno == 0 {
		return .Zero_Sequence
	}
	if _, ok := command_type_of_word(u32(command_type)); !ok {
		return .Unknown_Command_Type
	}
	if max_reply_bytes > REPLY_FRAME_MAX_PAYLOAD_BYTES {
		return .Payload_Too_Large
	}
	if max_reply_bytes % 4 != 0 {
		return .Payload_Misaligned
	}
	free_index := -1
	for index in 0 ..< REPLY_RING_PENDING_CAPACITY {
		slot := tracker.slots[index]
		if slot.active {
			if slot.seqno == seqno {
				return .Duplicate_Sequence
			}
		} else if free_index < 0 {
			free_index = index
		}
	}
	if free_index < 0 {
		return .Pending_Queue_Full
	}
	tracker.slots[free_index] = Pending_Reply_Slot {
		active          = true,
		seqno           = seqno,
		command_type    = command_type,
		max_reply_bytes = max_reply_bytes,
	}
	tracker.pending_count += 1
	return .None
}

// reply_ring_consume_frame decodes wire, verifies it matches the pending entry
// for expected_seqno (sequence ID, command type, and declared max_reply_bytes),
// and retires the pending slot only after full validation succeeds.
reply_ring_consume_frame :: proc "contextless" (
	tracker: ^Reply_Ring_Tracker,
	expected_seqno: u32,
	wire: []u8,
	payload_out: []u8,
) -> (
	frame: Reply_Frame,
	refusal: Reply_Ring_Refusal,
) {
	if tracker == nil {
		return {}, .Null_State
	}
	if expected_seqno == 0 {
		tracker.refused_count += 1
		return {}, .Zero_Sequence
	}
	slot_index := -1
	for index in 0 ..< REPLY_RING_PENDING_CAPACITY {
		if tracker.slots[index].active && tracker.slots[index].seqno == expected_seqno {
			slot_index = index
			break
		}
	}
	if slot_index < 0 {
		tracker.refused_count += 1
		return {}, .Pending_Not_Found
	}
	slot := tracker.slots[slot_index]

	// Validate header and payload length against slot.max_reply_bytes BEFORE
	// copying into payload_out so an oversized reply never mutates payload_out.
	if len(wire) < REPLY_FRAME_HEADER_SIZE {
		tracker.refused_count += 1
		return {}, .Truncated_Frame
	}
	if byte_order.read_u32_little_endian(wire, 0) != REPLY_FRAME_MAGIC {
		tracker.refused_count += 1
		return {}, .Bad_Magic
	}
	wire_seq := byte_order.read_u32_little_endian(wire, 4)
	if wire_seq != expected_seqno {
		tracker.refused_count += 1
		return {}, .Sequence_Mismatch
	}
	wire_cmd, cmd_ok := command_type_of_word(byte_order.read_u32_little_endian(wire, 8))
	if !cmd_ok {
		tracker.refused_count += 1
		return {}, .Unknown_Command_Type
	}
	if wire_cmd != slot.command_type {
		tracker.refused_count += 1
		return {}, .Command_Type_Mismatch
	}
	wire_payload := byte_order.read_u32_little_endian(wire, 16)
	if wire_payload > slot.max_reply_bytes {
		tracker.refused_count += 1
		return {}, .Payload_Too_Large
	}

	decoded, dec_r := reply_frame_decode(wire, payload_out)
	if dec_r != .None {
		tracker.refused_count += 1
		return {}, dec_r
	}
	tracker.slots[slot_index] = {}
	tracker.pending_count -= 1
	tracker.completed_count += 1
	return decoded, .None
}
