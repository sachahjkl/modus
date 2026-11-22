// The frames of the protocols between paired machines, as they cross one
// bidirectional QUIC stream of a connection to the service remote
// (src/md/features/several_machines.md, "The frames on a stream of remote").
//
// A stream of remote carries either a call request of the host
// (modus:contract/remote, Request) or one mesh frame, then the end of the
// stream. The first word of the stream tells them apart: a call request
// starts with the word of Request_Kind.Call, a mesh frame with the word of
// Request_Kind.Mesh. So the two protocols share the stream records, the
// bounds of time and the limit of bytes of remote, and a word that
// request_kind_of_word refuses reaches neither.
//
// The answer on the same stream is one mesh frame: the answer message of
// the request, or a Refusal that names the reason and the status of the
// contract that refused. The stream names the exchange: a frame has no
// request number.
//
// All numbers are little-endian. This package allocates no memory and calls
// no kernel operation.
package machine_wire

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/remote"

// The header of each mesh frame. The body follows it: exactly body_bytes.
FRAME_HEADER_SIZE :: 16

// The largest body of a frame: an object response with the largest object.
FRAME_BODY_LIMIT :: OBJECT_RESPONSE_HEADER_SIZE + OBJECT_BYTES_LIMIT
// The bytes of a whole frame at most. remote.REQUEST_LIMIT holds it, so the
// stream buffer of remote takes each frame whole.
FRAME_LIMIT :: FRAME_HEADER_SIZE + FRAME_BODY_LIMIT
#assert(FRAME_LIMIT <= remote.REQUEST_LIMIT)

// What a mesh frame carries. Each request has one answer message; Refusal
// answers any request.
Message :: enum u32 {
	None                  = 0, // Not a message: refused.
	Refusal               = 1, // The answer to a request that was refused: a reason and a detail.
	Pairing_Element       = 2, // The joiner sends its CPace element and its identity key.
	Pairing_Element_Reply = 3, // The offerer sends its element, its identity key and its confirmation tag.
	Pairing_Confirm       = 4, // The joiner sends its confirmation tag.
	Pairing_Confirmed     = 5, // The offerer wrote the row: the fingerprint of the session key.
	Object_Request        = 6, // A kind and a hash.
	Object_Response       = 7, // The kind, the hash and the bytes of the object.
	Grant_Present         = 8, // The wire bytes of a signed grant.
	Grant_Accepted        = 9, // The serial and the end time of the grant that holds.
	Store_Offer           = 10, // The version of an exchanged store on the sender.
	Store_Offer_Reply     = 11, // The version of the same store on the receiver, before its merge.
	Role_Call             = 12, // One call of a role contract held on the receiver.
	Role_Reply            = 13, // Its outcome, its integer result and its result bytes.
	Relay_Deposit         = 14, // A relay envelope for a routing token.
	Relay_Deposited       = 15, // The relay holds the envelope.
	Relay_Collect         = 16, // A routing token whose oldest envelope the sender takes.
	Relay_Delivery        = 17, // That envelope, as it was deposited.
}

// message_of_word is the border of the message word of a frame header.
message_of_word :: proc "contextless" (word: u32) -> (message: Message, ok: bool) {
	return enum_word.member_of_word(Message, u64(word))
}

// Why a request was refused. The detail of a Refusal is the word of the
// status of the contract that refused, when one did.
Refusal_Reason :: enum u32 {
	None               = 0, // Not a reason: a Refusal with it is malformed.
	Malformed          = 1, // The frame or its body broke the format: detail is a Frame_Status or 0.
	Unexpected_Message = 2, // A message that is not a request, or that comes in the wrong phase.
	Not_Paired         = 3, // The identity key of the handshake has no row of a paired machine.
	Pairing_Refused    = 4, // The pairing contract refused: detail is a machine_mesh.Pairing_Status.
	Object_Absent      = 5, // This machine holds no object with that hash and that kind.
	Grant_Refused      = 6, // The grant check refused: detail is a machine_mesh.Grant_Check_Status.
	Store_Refused      = 7, // The store exchange refused: detail is a Store_Status.
	Role_Refused       = 8, // This machine serves no such role for the peer, or its holder refused.
	Relay_Refused      = 9, // The relay refused: detail is a Relay_Status.
	No_Identity        = 10, // This machine has no identity key yet.
}

refusal_reason_of_word :: proc "contextless" (word: u32) -> (reason: Refusal_Reason, ok: bool) {
	return enum_word.member_of_word(Refusal_Reason, u64(word))
}

// A decoded frame.
Frame :: struct {
	message: Message,
	body:    []u8, // A view of the input bytes.
}

// The refusals of frame_decode.
Frame_Status :: enum u8 {
	Ok             = 1,
	Too_Short      = 2, // Fewer bytes than a header.
	Not_Mesh       = 3, // The first word is not the word of Request_Kind.Mesh.
	Bad_Message    = 4, // The message word names no Message, or names None.
	Reserved_Set   = 5, // The last word of the header is not zero.
	Length_Differs = 6, // body_bytes is not the count of the bytes after the header.
	Too_Large      = 7, // The body is over FRAME_BODY_LIMIT.
}

// stream_is_mesh says whether the bytes of a stream start with the word of
// Request_Kind.Mesh: the dispatch of remote reads this one word before it
// chooses request_check or frame_decode.
stream_is_mesh :: proc "contextless" (bytes: []u8) -> bool {
	if len(bytes) < 4 {
		return false
	}
	kind, known := remote.request_kind_of_word(byte_order.read_u32_little_endian(bytes, 0))
	return known && kind == .Mesh
}

// frame_decode reads the bytes of a whole stream as one mesh frame. It is
// the border of the message word: a frame that it accepts names a member
// of Message other than None.
frame_decode :: proc "contextless" (bytes: []u8) -> (frame: Frame, status: Frame_Status) {
	if len(bytes) < FRAME_HEADER_SIZE {
		return {}, .Too_Short
	}
	if !stream_is_mesh(bytes) {
		return {}, .Not_Mesh
	}
	message, known := message_of_word(byte_order.read_u32_little_endian(bytes, 4))
	if !known || message == .None {
		return {}, .Bad_Message
	}
	body_bytes := u64(byte_order.read_u32_little_endian(bytes, 8))
	if byte_order.read_u32_little_endian(bytes, 12) != 0 {
		return {}, .Reserved_Set
	}
	if body_bytes > FRAME_BODY_LIMIT {
		return {}, .Too_Large
	}
	if body_bytes != u64(len(bytes) - FRAME_HEADER_SIZE) {
		return {}, .Length_Differs
	}
	return Frame{message = message, body = bytes[FRAME_HEADER_SIZE:]}, .Ok
}

// frame_begin writes the header of a frame whose body has body_bytes, and
// gives the place of the body. ok is false when output cannot hold the
// whole frame or the body is over the limit.
frame_begin :: proc "contextless" (output: []u8, message: Message, body_bytes: int) -> (body: []u8, ok: bool) {
	if message == .None || body_bytes < 0 || body_bytes > FRAME_BODY_LIMIT || len(output) < FRAME_HEADER_SIZE + body_bytes {
		return nil, false
	}
	byte_order.write_u32_little_endian(output, 0, u32(remote.Request_Kind.Mesh))
	byte_order.write_u32_little_endian(output, 4, u32(message))
	byte_order.write_u32_little_endian(output, 8, u32(body_bytes))
	byte_order.write_u32_little_endian(output, 12, 0)
	return output[FRAME_HEADER_SIZE:][:body_bytes], true
}

// frame_bytes gives the whole frame whose body frame_begin placed.
frame_bytes :: proc "contextless" (output: []u8, body: []u8) -> []u8 {
	return output[:FRAME_HEADER_SIZE + len(body)]
}

REFUSAL_BODY_SIZE :: 8

// refusal_write writes a Refusal frame: the reason and the status word of
// the contract that refused. An output too small for it gives no bytes.
refusal_write :: proc "contextless" (output: []u8, reason: Refusal_Reason, detail: u32) -> []u8 {
	body, ok := frame_begin(output, .Refusal, REFUSAL_BODY_SIZE)
	if !ok {
		return nil
	}
	byte_order.write_u32_little_endian(body, 0, u32(reason))
	byte_order.write_u32_little_endian(body, 4, detail)
	return frame_bytes(output, body)
}

// refusal_read reads the body of a Refusal. ok is false for a body of
// another size, or a reason that names no member or names None.
refusal_read :: proc "contextless" (body: []u8) -> (reason: Refusal_Reason, detail: u32, ok: bool) {
	if len(body) != REFUSAL_BODY_SIZE {
		return .None, 0, false
	}
	reason, ok = refusal_reason_of_word(byte_order.read_u32_little_endian(body, 0))
	if !ok || reason == .None {
		return .None, 0, false
	}
	return reason, byte_order.read_u32_little_endian(body, 4), true
}

// answer_expect decodes an answer frame and checks that it is the expected
// message. A Refusal gives its reason and its detail, with ok false.
answer_expect :: proc "contextless" (bytes: []u8, expected: Message) -> (body: []u8, reason: Refusal_Reason, detail: u32, ok: bool) {
	frame, status := frame_decode(bytes)
	if status != .Ok {
		return nil, .Malformed, u32(status), false
	}
	if frame.message == .Refusal {
		refusal_reason, refusal_detail, read_ok := refusal_read(frame.body)
		if !read_ok {
			return nil, .Malformed, 0, false
		}
		return nil, refusal_reason, refusal_detail, false
	}
	if frame.message != expected {
		return nil, .Unexpected_Message, u32(frame.message), false
	}
	return frame.body, .None, 0, true
}
