#+build !freestanding
#+build !modus
package venus_vulkan

import "core:testing"
import "modus:contract/byte_order"

@(test)
reply_frame_encode_decode_refuses_corrupt_truncated_and_oversized :: proc(t: ^testing.T) {
	payload := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	hdr := Reply_Frame_Header {
		seqno        = 11,
		command_type = .Create_Buffer,
		vk_result    = .Success,
	}
	wire: [REPLY_FRAME_HEADER_SIZE + 8]u8
	out_payload: [16]u8

	// Zero sequence, unknown command, unknown VkResult, misaligned payload, short buffer.
	bad_hdr := hdr
	bad_hdr.seqno = 0
	_, r := reply_frame_encode(bad_hdr, payload[:], wire[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Zero_Sequence)

	bad_hdr = hdr
	bad_hdr.command_type = Command_Type(99999)
	_, r = reply_frame_encode(bad_hdr, payload[:], wire[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Unknown_Command_Type)

	bad_hdr = hdr
	bad_hdr.vk_result = Vulkan_Result(123456)
	_, r = reply_frame_encode(bad_hdr, payload[:], wire[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Unknown_Vk_Result)

	_, r = reply_frame_encode(hdr, payload[:3], wire[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Payload_Misaligned)

	_, r = reply_frame_encode(hdr, payload[:], wire[:len(wire) - 1])
	testing.expect_value(t, r, Reply_Ring_Refusal.Buffer_Too_Short)

	// Valid encode & decode round-trip.
	written, ok_r := reply_frame_encode(hdr, payload[:], wire[:])
	testing.expect(t, ok_r == .None && written == len(wire))
	decoded, dec_r := reply_frame_decode(wire[:], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.None)
	testing.expect_value(t, decoded.header.seqno, u32(11))
	testing.expect_value(t, decoded.header.command_type, Command_Type.Create_Buffer)
	testing.expect_value(t, decoded.header.vk_result, Vulkan_Result.Success)
	testing.expect_value(t, len(decoded.payload), 8)
	testing.expect_value(t, decoded.payload[7], u8(8))

	// Corrupt cases must leave out_payload untouched.
	out_payload = {}
	out_payload[0] = 0xAA
	// Truncated header & truncated payload.
	_, dec_r = reply_frame_decode(wire[:REPLY_FRAME_HEADER_SIZE - 1], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.Truncated_Frame)
	_, dec_r = reply_frame_decode(wire[:len(wire) - 1], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.Truncated_Frame)
	testing.expect_value(t, out_payload[0], u8(0xAA))

	// Bad magic & non-zero reserved word.
	bad := wire
	bad[0] ~= 0xFF
	_, dec_r = reply_frame_decode(bad[:], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.Bad_Magic)

	bad = wire
	byte_order.write_u32_little_endian(bad[:], 20, 1)
	_, dec_r = reply_frame_decode(bad[:], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.Non_Zero_Reserved)

	// Oversized payload declared in header.
	bad = wire
	byte_order.write_u32_little_endian(bad[:], 16, REPLY_FRAME_MAX_PAYLOAD_BYTES + 4)
	_, dec_r = reply_frame_decode(bad[:], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.Payload_Too_Large)

	// Trailing extra byte refused.
	trailing: [len(wire) + 1]u8
	copy(trailing[:], wire[:])
	_, dec_r = reply_frame_decode(trailing[:], out_payload[:])
	testing.expect_value(t, dec_r, Reply_Ring_Refusal.Trailing_Bytes)
	testing.expect_value(t, out_payload[0], u8(0xAA))
}

@(test)
reply_ring_tracker_matches_sequences_and_refuses_mismatches_without_mutation :: proc(t: ^testing.T) {
	tracker: Reply_Ring_Tracker
	testing.expect_value(t, reply_ring_track_submit(&tracker, 100, .Create_Instance, 16), Reply_Ring_Refusal.None)
	testing.expect_value(t, reply_ring_track_submit(&tracker, 100, .Create_Instance, 16), Reply_Ring_Refusal.Duplicate_Sequence)
	testing.expect_value(t, tracker.pending_count, 1)

	wire: [REPLY_FRAME_HEADER_SIZE + 8]u8
	payload := [8]u8{9, 8, 7, 6, 5, 4, 3, 2}
	out_buf: [16]u8
	out_buf[0] = 0x55

	// Wrong sequence number -> Sequence_Mismatch; pending slot stays intact, out_buf untouched.
	_, _ = reply_frame_encode({seqno = 101, command_type = .Create_Instance, vk_result = .Success}, payload[:], wire[:])
	_, r := reply_ring_consume_frame(&tracker, 100, wire[:], out_buf[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Sequence_Mismatch)
	testing.expect_value(t, tracker.pending_count, 1)
	testing.expect_value(t, out_buf[0], u8(0x55))

	// Wrong command type -> Command_Type_Mismatch.
	_, _ = reply_frame_encode({seqno = 100, command_type = .Create_Device, vk_result = .Success}, payload[:], wire[:])
	_, r = reply_ring_consume_frame(&tracker, 100, wire[:], out_buf[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Command_Type_Mismatch)
	testing.expect_value(t, tracker.pending_count, 1)

	// Payload larger than tracked max_reply_bytes (16) -> Payload_Too_Large without mutating out_buf.
	big_payload: [20]u8
	big_wire: [REPLY_FRAME_HEADER_SIZE + 20]u8
	_, _ = reply_frame_encode({seqno = 100, command_type = .Create_Instance, vk_result = .Success}, big_payload[:], big_wire[:])
	_, r = reply_ring_consume_frame(&tracker, 100, big_wire[:], out_buf[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Payload_Too_Large)
	testing.expect_value(t, tracker.pending_count, 1)
	testing.expect_value(t, out_buf[0], u8(0x55))

	// Valid matching frame consumes slot cleanly.
	_, _ = reply_frame_encode({seqno = 100, command_type = .Create_Instance, vk_result = .Success}, payload[:], wire[:])
	frame, ok_r := reply_ring_consume_frame(&tracker, 100, wire[:], out_buf[:])
	testing.expect_value(t, ok_r, Reply_Ring_Refusal.None)
	testing.expect_value(t, tracker.pending_count, 0)
	testing.expect_value(t, tracker.completed_count, u64(1))
	testing.expect_value(t, frame.payload[0], u8(9))

	// Replaying the consumed sequence is refused.
	_, r = reply_ring_consume_frame(&tracker, 100, wire[:], out_buf[:])
	testing.expect_value(t, r, Reply_Ring_Refusal.Pending_Not_Found)

	// Capacity bound check.
	for i in 0 ..< REPLY_RING_PENDING_CAPACITY {
		testing.expect_value(t, reply_ring_track_submit(&tracker, u32(200 + i), .Queue_Submit, 4), Reply_Ring_Refusal.None)
	}
	testing.expect_value(t, reply_ring_track_submit(&tracker, 999, .Queue_Submit, 4), Reply_Ring_Refusal.Pending_Queue_Full)
}
