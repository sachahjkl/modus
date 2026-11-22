// A role held on a paired machine: the frames of one call of a role
// contract, and the proxy that the machine of the clients keeps for the
// calls in flight (src/md/features/several_machines.md, "A role held on
// another machine").
//
// A call has an outcome, a refusal, or no known outcome. A call whose reply
// did not come before the link broke can have run: the proxy ends it with
// Unknown_Outcome, never with a refusal. It keeps a call that the contract
// marks idempotent, and sends it again when the link holds again. A call
// that starts while the link is broken ends with Unreachable at once. No
// call waits past its bound.
package machine_wire

import "modus:contract/byte_order"
import "modus:contract/enum_word"
import "modus:contract/role_contract"

ROLE_CALLS_AT_ONCE :: 8
ROLE_ARGUMENT_LIMIT :: 1024
ROLE_RESULT_LIMIT :: 1024
ROLE_CALL_HEADER_SIZE :: 24 // The call identifier, the role, the export, the flags, the count of argument bytes.
ROLE_REPLY_HEADER_SIZE :: 24 // The call identifier, the outcome, the count of result bytes, the integer result.

Role_Call_Flag :: enum u32 {
	Idempotent = 0, // The contract marks the export as idempotent: the link can send it again.
}
Role_Call_Flags :: bit_set[Role_Call_Flag;u32]

// role_call_flags_of_word refuses a bit that names no flag.
role_call_flags_of_word :: proc "contextless" (word: u32) -> (flags: Role_Call_Flags, ok: bool) {
	known := Role_Call_Flags{.Idempotent}
	if word & ~transmute(u32)known != 0 {
		return {}, false
	}
	return transmute(Role_Call_Flags)word, true
}

// The outcome of one call. Answered and Refused cross the link; the proxy
// gives Unknown_Outcome and Unreachable itself, and refuses them on the wire.
Role_Outcome :: enum u32 {
	None            = 0,
	Answered        = 1, // The holder ran the call: value and result.
	Refused         = 2, // The holder, or the machine of the holder, refused the call: it did not run.
	Unknown_Outcome = 3, // The link broke, the reply was malformed, or the bound passed: the call can have run.
	Unreachable     = 4, // The link was broken when the call started: it did not run.
}

role_outcome_of_wire_word :: proc "contextless" (word: u32) -> (outcome: Role_Outcome, ok: bool) {
	outcome, ok = enum_word.member_of_word(Role_Outcome, u64(word))
	if !ok {
		return .None, false
	}
	switch outcome {
	case .Answered, .Refused:
		return outcome, true
	case .None, .Unknown_Outcome, .Unreachable:
	}
	return .None, false
}

// role_of_word is the border of the role word of a call.
role_of_word :: proc "contextless" (word: u32) -> (role: role_contract.Role, ok: bool) {
	role, ok = enum_word.member_of_word(role_contract.Role, u64(word))
	if !ok || role == .None {
		return .None, false
	}
	return role, true
}

Role_Call :: struct {
	identifier: u64,
	role:       role_contract.Role,
	export:     u32,
	flags:      Role_Call_Flags,
	arguments:  []u8,
}

Role_Reply :: struct {
	identifier: u64,
	outcome:    Role_Outcome,
	value:      i64,
	result:     []u8,
}

role_call_write :: proc "contextless" (output: []u8, call: Role_Call) -> []u8 {
	if len(call.arguments) > ROLE_ARGUMENT_LIMIT || call.role == .None {
		return nil
	}
	body, ok := frame_begin(output, .Role_Call, ROLE_CALL_HEADER_SIZE + len(call.arguments))
	if !ok {
		return nil
	}
	byte_order.write_u64_little_endian(body, 0, call.identifier)
	byte_order.write_u32_little_endian(body, 8, u32(call.role))
	byte_order.write_u32_little_endian(body, 12, call.export)
	byte_order.write_u32_little_endian(body, 16, transmute(u32)call.flags)
	byte_order.write_u32_little_endian(body, 20, u32(len(call.arguments)))
	copy(body[ROLE_CALL_HEADER_SIZE:], call.arguments)
	return frame_bytes(output, body)
}

role_call_read :: proc "contextless" (body: []u8) -> (call: Role_Call, ok: bool) {
	if len(body) < ROLE_CALL_HEADER_SIZE {
		return {}, false
	}
	call.identifier = byte_order.read_u64_little_endian(body, 0)
	role, role_ok := role_of_word(byte_order.read_u32_little_endian(body, 8))
	flags, flags_ok := role_call_flags_of_word(byte_order.read_u32_little_endian(body, 16))
	count := u64(byte_order.read_u32_little_endian(body, 20))
	if call.identifier == 0 || !role_ok || !flags_ok || count > ROLE_ARGUMENT_LIMIT || count != u64(len(body) - ROLE_CALL_HEADER_SIZE) {
		return {}, false
	}
	call.role = role
	call.export = byte_order.read_u32_little_endian(body, 12)
	call.flags = flags
	call.arguments = body[ROLE_CALL_HEADER_SIZE:]
	return call, true
}

role_reply_write :: proc "contextless" (output: []u8, reply: Role_Reply) -> []u8 {
	if len(reply.result) > ROLE_RESULT_LIMIT || (reply.outcome != .Answered && reply.outcome != .Refused) {
		return nil
	}
	body, ok := frame_begin(output, .Role_Reply, ROLE_REPLY_HEADER_SIZE + len(reply.result))
	if !ok {
		return nil
	}
	byte_order.write_u64_little_endian(body, 0, reply.identifier)
	byte_order.write_u32_little_endian(body, 8, u32(reply.outcome))
	byte_order.write_u32_little_endian(body, 12, u32(len(reply.result)))
	byte_order.write_u64_little_endian(body, 16, u64(reply.value))
	copy(body[ROLE_REPLY_HEADER_SIZE:], reply.result)
	return frame_bytes(output, body)
}

role_reply_read :: proc "contextless" (body: []u8) -> (reply: Role_Reply, ok: bool) {
	if len(body) < ROLE_REPLY_HEADER_SIZE {
		return {}, false
	}
	outcome, outcome_ok := role_outcome_of_wire_word(byte_order.read_u32_little_endian(body, 8))
	count := u64(byte_order.read_u32_little_endian(body, 12))
	if !outcome_ok || count > ROLE_RESULT_LIMIT || count != u64(len(body) - ROLE_REPLY_HEADER_SIZE) {
		return {}, false
	}
	reply.identifier = byte_order.read_u64_little_endian(body, 0)
	reply.outcome = outcome
	reply.value = i64(byte_order.read_u64_little_endian(body, 16))
	reply.result = body[ROLE_REPLY_HEADER_SIZE:]
	return reply, true
}

// The state of the link to the machine of the holder, as the proxy sees it.
Role_Link_State :: enum u8 {
	Up     = 0,
	Broken = 1, // The QUIC connection ended: each new call is Unreachable until the link holds again.
}

Role_Call_Phase :: enum u8 {
	Free             = 0,
	In_Flight        = 1, // Its frame went on a stream; its reply has not come.
	Waiting_For_Link = 2, // The link broke while it was in flight, and it is idempotent: it goes again.
}

Role_Call_Slot :: struct {
	phase:          Role_Call_Phase,
	identifier:     u64,
	role:           role_contract.Role,
	export:         u32,
	flags:          Role_Call_Flags,
	deadline_ms:    u64,
	argument_count: int,
	arguments:      [ROLE_ARGUMENT_LIMIT]u8,
}

// The calls that the machine of the clients has in flight to one holder.
Role_Proxy :: struct {
	link:            Role_Link_State,
	slots:           [ROLE_CALLS_AT_ONCE]Role_Call_Slot,
	next_identifier: u64,
}

// The end of a call that the proxy decided without a reply.
Role_Call_End :: struct {
	identifier: u64,
	outcome:    Role_Outcome,
}

Role_Proxy_Status :: enum u8 {
	Sent              = 1,
	Unreachable       = 2, // The link is broken: the call ends at once, and did not run.
	Refused_Full      = 3, // ROLE_CALLS_AT_ONCE calls are in flight.
	Refused_Too_Large = 4,
	Refused_Bad_Role  = 5,
	Refused_Bad_Bound = 6, // A bound of 0, or a deadline past the largest time: a call must end.
	Refused_Output    = 7, // The output cannot hold the frame.
}

@(private)
role_slot_frame :: proc "contextless" (slot: ^Role_Call_Slot, output: []u8) -> []u8 {
	return role_call_write(output, Role_Call{identifier = slot.identifier, role = slot.role, export = slot.export, flags = slot.flags, arguments = slot.arguments[:slot.argument_count]})
}

// role_call_begin starts one call: it writes the frame to send on a new
// stream, and keeps the call until its reply, its bound, or a break of the link.
role_call_begin :: proc "contextless" (
	proxy: ^Role_Proxy,
	role: role_contract.Role,
	export: u32,
	flags: Role_Call_Flags,
	arguments: []u8,
	now_ms: u64,
	bound_ms: u64,
	output: []u8,
) -> (identifier: u64, frame: []u8, status: Role_Proxy_Status) {
	if role == .None {
		return 0, nil, .Refused_Bad_Role
	}
	if len(arguments) > ROLE_ARGUMENT_LIMIT {
		return 0, nil, .Refused_Too_Large
	}
	if bound_ms == 0 || bound_ms > max(u64) - now_ms {
		return 0, nil, .Refused_Bad_Bound
	}
	if proxy.link == .Broken {
		return 0, nil, .Unreachable
	}
	for &slot in proxy.slots {
		if slot.phase != .Free {
			continue
		}
		proxy.next_identifier += 1
		slot = Role_Call_Slot{phase = .In_Flight, identifier = proxy.next_identifier, role = role, export = export, flags = flags, deadline_ms = now_ms + bound_ms, argument_count = len(arguments)}
		copy(slot.arguments[:], arguments)
		frame = role_slot_frame(&slot, output)
		if frame == nil {
			slot = {}
			return 0, nil, .Refused_Output
		}
		return slot.identifier, frame, .Sent
	}
	return 0, nil, .Refused_Full
}

@(private)
role_slot_find :: proc "contextless" (proxy: ^Role_Proxy, identifier: u64) -> ^Role_Call_Slot {
	for &slot in proxy.slots {
		if slot.phase != .Free && slot.identifier == identifier {
			return &slot
		}
	}
	return nil
}

// role_reply_accept takes the answer of the stream of call identifier. A
// refusal that says the call did not run is a Refused outcome. Each other
// answer that is not a well formed reply of this call (a fault of the
// holder after it ran, a malformed answer, a reply that names another call)
// is Unknown_Outcome, never a refusal: the call can have run. A call that is
// not in flight gives found false.
role_reply_accept :: proc "contextless" (proxy: ^Role_Proxy, identifier: u64, answer: []u8) -> (reply: Role_Reply, found: bool) {
	slot := role_slot_find(proxy, identifier)
	if slot == nil || slot.phase != .In_Flight {
		return {}, false
	}
	slot^ = {}
	body, reason, _, ok := answer_expect(answer, .Role_Reply)
	if !ok {
		switch reason {
		case .Role_Refused, .Not_Paired, .Use_Not_Granted, .No_Identity:
			return Role_Reply{identifier = identifier, outcome = .Refused}, true
		case .None, .Malformed, .Unexpected_Message, .Pairing_Refused, .Object_Absent, .Grant_Refused, .Store_Refused, .Relay_Refused, .No_Principal, .Role_Holder_Fault:
		}
		return Role_Reply{identifier = identifier, outcome = .Unknown_Outcome}, true
	}
	read, read_ok := role_reply_read(body)
	if !read_ok || read.identifier != identifier {
		return Role_Reply{identifier = identifier, outcome = .Unknown_Outcome}, true
	}
	return read, true
}

// role_link_broken is the end of the QUIC connection to the holder. Each
// call in flight ends with Unknown_Outcome, except an idempotent call, which
// waits for the link. Each later call is Unreachable until role_link_restored.
role_link_broken :: proc "contextless" (proxy: ^Role_Proxy) -> (ended: [ROLE_CALLS_AT_ONCE]Role_Call_End, count: int) {
	proxy.link = .Broken
	for &slot in proxy.slots {
		if slot.phase != .In_Flight {
			continue
		}
		if .Idempotent in slot.flags {
			slot.phase = .Waiting_For_Link
			continue
		}
		ended[count] = Role_Call_End{identifier = slot.identifier, outcome = .Unknown_Outcome}
		count += 1
		slot = {}
	}
	return ended, count
}

// role_link_restored is a new connection to the holder: a record of the
// role, so a client that waits for it gets a wake.
role_link_restored :: proc "contextless" (proxy: ^Role_Proxy) {
	proxy.link = .Up
}

// role_resend_next writes the frame of one idempotent call that waits for
// the link, and puts it in flight again. found is false when none waits or
// the link is broken.
role_resend_next :: proc "contextless" (proxy: ^Role_Proxy, output: []u8) -> (identifier: u64, frame: []u8, found: bool) {
	if proxy.link == .Broken {
		return 0, nil, false
	}
	for &slot in proxy.slots {
		if slot.phase != .Waiting_For_Link {
			continue
		}
		frame = role_slot_frame(&slot, output)
		if frame == nil {
			return 0, nil, false
		}
		slot.phase = .In_Flight
		return slot.identifier, frame, true
	}
	return 0, nil, false
}

// role_calls_expire ends each call past its bound with Unknown_Outcome.
role_calls_expire :: proc "contextless" (proxy: ^Role_Proxy, now_ms: u64) -> (ended: [ROLE_CALLS_AT_ONCE]Role_Call_End, count: int) {
	for &slot in proxy.slots {
		if slot.phase == .Free || now_ms < slot.deadline_ms {
			continue
		}
		ended[count] = Role_Call_End{identifier = slot.identifier, outcome = .Unknown_Outcome}
		count += 1
		slot = {}
	}
	return ended, count
}
