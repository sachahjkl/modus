package venus_vulkan

import "base:intrinsics"

// The exchange of a command and its reply through the ring (Mesa vn_ring.c
// and vn_cs.c, virglrenderer vkr_ring.c and vkr_cs.c). The renderer writes
// each reply into the reply stream: a range of a blob resource that
// vkSetReplyCommandStreamMESA names, at the position that the last
// vkSeekReplyCommandStreamMESA gave. A reply carries no length and no
// header of its own: it is the command type, then the outputs of the
// command, so the driver reserves the size of each reply before it sends
// the command, and the decoders of venus_replies.odin read it.
//
// A submission writes the seek and the command in one ring write, so that
// no other command comes between them. The reply is ready when the head of
// the renderer reaches the sequence number of that write: the renderer
// stores its head after it ran the commands before it.

// The driver side of one reply stream.
Reply_Stream :: struct {
	shared:      []u8, // The range of the resource, mapped here.
	resource_id: u32,
	offset:      u64, // The place of the range in the resource.
	reserved:    u64, // The end of the bytes that a submission reserved.
	pending:     u32, // The submissions whose reply is not read yet.
	bound:       bool, // The renderer received vkSetReplyCommandStreamMESA.
}

// One command sent through the ring, whose reply waits in the reply stream.
Ring_Submission :: struct {
	seqno:          u32,
	command_type:   Command_Type,
	reply_position: u64,
	reply_bytes:    u64,
	read:           bool,
}

// The bytes of the seek and of vkSetReplyCommandStreamMESA that a
// submission writes before its command, at most.
SUBMISSION_PREFIX_BYTES_MOST :: 64

// reply_stream_init prepares the driver side of a reply stream at offset in
// the resource resource_id.
reply_stream_init :: proc "contextless" (shared: []u8, resource_id: u32, offset: u64) -> (stream: Reply_Stream, problem: Venus_Problem) {
	if resource_id == 0 {
		return {}, .Zero_Object_Id
	}
	if len(shared) == 0 {
		return {}, .Zero_Extent
	}
	if len(shared) % 4 != 0 || offset % 4 != 0 {
		return {}, .Misaligned_Length
	}
	if uintptr(raw_data(shared)) % 4 != 0 {
		return {}, .Ring_Memory_Misaligned
	}
	return Reply_Stream{shared = shared, resource_id = resource_id, offset = offset}, .None
}

// venus_ring_submit_command sends one command whose reply the driver waits
// for. command is the whole command, with the flag Generate_Reply, as an
// encoder of this package writes it; reply_bytes is the size of its reply
// (the *_reply_bytes procedures). staging holds the bytes of the ring write
// while they are built. A refused submission changes neither the ring nor
// the stream.
venus_ring_submit_command :: proc "contextless" (ring: ^Ring, stream: ^Reply_Stream, command: []u8, reply_bytes: u64, staging: []u8) -> (submission: Ring_Submission, problem: Venus_Problem) {
	if len(command) == 0 {
		return {}, .Stream_Empty
	}
	if len(command) % 4 != 0 {
		return {}, .Misaligned_Length
	}
	decoder := decoder_init(command)
	decoded := command_decode_next(&decoder) or_return
	if decoder.cursor != len(command) {
		return {}, .Stream_Too_Large
	}
	if .Generate_Reply not_in decoded.flags {
		return {}, .Reply_Not_Requested
	}
	if reply_bytes == 0 {
		return {}, .Zero_Extent
	}
	if reply_bytes % 4 != 0 {
		return {}, .Misaligned_Length
	}
	if reply_bytes > u64(len(stream.shared)) {
		return {}, .Stream_Too_Large
	}
	position := stream.reserved
	if position + reply_bytes > u64(len(stream.shared)) {
		// The stream starts again at 0 only when no reply waits in it.
		if stream.pending > 0 {
			return {}, .Reply_Stream_Full
		}
		position = 0
	}
	encoder := encoder_init(staging)
	if !stream.bound {
		encode_set_reply_command_stream(&encoder, stream.resource_id, stream.offset, u64(len(stream.shared))) or_return
	}
	encode_seek_reply_command_stream(&encoder, position) or_return
	room, room_ok := encoder_room(&encoder, len(command))
	if !room_ok {
		return {}, .Buffer_Too_Short
	}
	copy(staging[room:room + len(command)], command)
	seqno := ring_write(ring, encoder_bytes(&encoder)) or_return
	stream.bound = true
	stream.reserved = position + reply_bytes
	stream.pending += 1
	return Ring_Submission{seqno = seqno, command_type = decoded.command_type, reply_position = position, reply_bytes = reply_bytes}, .None
}

// venus_ring_poll_reply gives the reply of a submission once the renderer
// has run it: ready is false while it has not. The reply is copied into
// destination, so that a decoder reads bytes that the renderer can no
// longer change. A ring whose status has the fatal bit refuses each poll.
venus_ring_poll_reply :: proc "contextless" (ring: ^Ring, stream: ^Reply_Stream, submission: ^Ring_Submission, destination: []u8) -> (reply: []u8, ready: bool, problem: Venus_Problem) {
	if submission.read {
		return nil, false, .Reply_Already_Read
	}
	if submission.reply_bytes == 0 || submission.reply_position + submission.reply_bytes > u64(len(stream.shared)) || stream.pending == 0 {
		return nil, false, .Stream_Truncated
	}
	if u64(len(destination)) < submission.reply_bytes {
		return nil, false, .Buffer_Too_Short
	}
	status := ring_status(ring) or_return
	if .Fatal in status {
		return nil, false, .Ring_Fatal
	}
	reached := ring_seqno_reached(ring, submission.seqno) or_return
	if !reached {
		return nil, false, .None
	}
	// The head was loaded with acquire order: the bytes that the renderer
	// wrote before it stored the head are visible here.
	reply = destination[:submission.reply_bytes]
	source := stream.shared[submission.reply_position:][:submission.reply_bytes]
	intrinsics.mem_copy_non_overlapping(raw_data(reply), raw_data(source), len(reply))
	submission.read = true
	stream.pending -= 1
	return reply, true, .None
}

// The size of each reply, which the encoders of the renderer side measure.

result_reply_bytes :: proc "contextless" (command_type: Command_Type) -> u64 {
	encoder := encoder_measure()
	_ = encode_result_reply(&encoder, command_type, .Success)
	return u64(encoder.used_bytes)
}

create_object_reply_bytes :: proc "contextless" (command_type: Command_Type) -> u64 {
	encoder := encoder_measure()
	_ = encode_create_object_reply(&encoder, command_type, .Success, 1)
	return u64(encoder.used_bytes)
}

enumerate_physical_devices_reply_bytes :: proc "contextless" (device_count: u32) -> u64 {
	if device_count > MAX_ARRAY_ELEMENTS {
		return 0
	}
	ids: [MAX_ARRAY_ELEMENTS]Object_Id
	encoder := encoder_measure()
	_ = encode_enumerate_physical_devices_reply(&encoder, .Success, device_count, ids[:device_count])
	return u64(encoder.used_bytes)
}

physical_device_properties_reply_bytes :: proc "contextless" () -> u64 {
	properties: Physical_Device_Properties
	encoder := encoder_measure()
	_ = encode_get_physical_device_properties_reply(&encoder, &properties)
	return u64(encoder.used_bytes)
}
