#+build !freestanding
package dhcp_client

import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"

HARDWARE :: [6]u8{0x52, 0x54, 0x00, 0x12, 0x34, 0x56}
TRANSACTION :: u32(0x1234_5678)
SERVER :: u32(0x0A00_0202) // 10.0.2.2
ADDRESS :: u32(0x0A00_020F) // 10.0.2.15
MASK :: u32(0xFFFF_FF00)

// Option: one option of a test message.
@(private = "file")
Option :: struct {
	code:  u8,
	bytes: []u8,
}

@(private = "file")
word_bytes :: proc(value: u32) -> []u8 {
	bytes := make([]u8, 4, context.temp_allocator)
	be32_put(bytes, 0, value)
	return bytes
}

// reply_of writes a BOOTREPLY with its options, then END.
@(private = "file")
reply_of :: proc(address: u32, options: []Option) -> []u8 {
	message := make([]u8, MESSAGE_CAPACITY, context.temp_allocator)
	message[0], message[1], message[2] = 2, 1, 6
	be32_put(message, 4, TRANSACTION)
	be32_put(message, 16, address)
	hardware := HARDWARE
	copy(message[28:34], hardware[:])
	be32_put(message, FIXED_SIZE, MAGIC_COOKIE)
	at := MESSAGE_LEAST
	for option in options {
		message[at], message[at + 1] = option.code, u8(len(option.bytes))
		copy(message[at + 2:], option.bytes)
		at += 2 + len(option.bytes)
	}
	message[at] = OPTION_END
	return message
}

// good_options gives the options of a good ACK or OFFER.
@(private = "file")
good_options :: proc(kind: Message_Type) -> [dynamic]Option {
	options := make([dynamic]Option, context.temp_allocator)
	type_byte := make([]u8, 1, context.temp_allocator)
	type_byte[0] = u8(kind)
	append(&options, Option{OPTION_MESSAGE_TYPE, type_byte}, Option{OPTION_SERVER, word_bytes(SERVER)}, Option{OPTION_LEASE_TIME, word_bytes(86400)}, Option{OPTION_SUBNET_MASK, word_bytes(MASK)}, Option{OPTION_ROUTER, word_bytes(SERVER)})
	return options
}

// Each field of a hostile message is refused at the border, at each edge,
// and the client changes nothing for it.
@(test)
a_hostile_reply_is_refused :: proc(t: ^testing.T) {
	good := reply_of(ADDRESS, good_options(.Ack)[:])
	reply, problem := reply_read(good, TRANSACTION, HARDWARE)
	testing.expect(t, problem == .None && reply.kind == .Ack && reply.address == ADDRESS && reply.prefix == 24 && reply.renew_seconds == 43200 && reply.rebind_seconds == 75600)
	Case :: struct {
		message: []u8,
		problem: Reply_Problem,
	}
	cases := make([dynamic]Case, context.temp_allocator)
	append(&cases, Case{good[:MESSAGE_LEAST - 1], .Too_Short}, Case{good[:0], .Too_Short})
	{
		m := reply_of(ADDRESS, good_options(.Ack)[:]); m[0] = 1
		append(&cases, Case{m, .Not_A_Reply})
		n := reply_of(ADDRESS, good_options(.Ack)[:]); n[2] = 16
		append(&cases, Case{n, .Not_Ethernet})
		o := reply_of(ADDRESS, good_options(.Ack)[:]); be32_put(o, 4, TRANSACTION + 1)
		append(&cases, Case{o, .Other_Transaction})
		p := reply_of(ADDRESS, good_options(.Ack)[:]); p[33] ~= 1
		append(&cases, Case{p, .Other_Client})
		q := reply_of(ADDRESS, good_options(.Ack)[:]); q[FIXED_SIZE] = 0
		append(&cases, Case{q, .No_Cookie})
	}
	// An option whose length passes the end, and a code at the last byte.
	{
		m := reply_of(ADDRESS, good_options(.Ack)[:])
		m[MESSAGE_LEAST + 1] = 255
		append(&cases, Case{m[:MESSAGE_LEAST + 100], .Option_Past_End})
		n := good[:MESSAGE_LEAST + 1]
		append(&cases, Case{n, .Option_Past_End})
	}
	// A byte after END that is not padding.
	{
		m := reply_of(ADDRESS, good_options(.Ack)[:])
		m[len(m) - 1] = 7
		append(&cases, Case{m, .Bytes_After_End})
	}
	twice := good_options(.Ack)
	append(&twice, Option{OPTION_SERVER, word_bytes(SERVER)})
	append(&cases, Case{reply_of(ADDRESS, twice[:]), .Option_Twice})
	long_type := good_options(.Ack)
	long_type[0].bytes = word_bytes(5)
	append(&cases, Case{reply_of(ADDRESS, long_type[:]), .Bad_Option_Length})
	short_router := good_options(.Ack)
	short_router[4].bytes = word_bytes(SERVER)[:3]
	append(&cases, Case{reply_of(ADDRESS, short_router[:]), .Bad_Option_Length})
	no_type := good_options(.Ack)
	ordered_remove(&no_type, 0)
	append(&cases, Case{reply_of(ADDRESS, no_type[:]), .No_Message_Type})
	for kind in ([?]u8{0, 1, 3, 4, 7, 8, 9, 255}) {
		other := good_options(.Ack)
		other[0].bytes = make([]u8, 1, context.temp_allocator)
		other[0].bytes[0] = kind
		append(&cases, Case{reply_of(ADDRESS, other[:]), .Bad_Message_Type})
	}
	no_server := good_options(.Ack)
	ordered_remove(&no_server, 1)
	append(&cases, Case{reply_of(ADDRESS, no_server[:]), .No_Server})
	no_lease := good_options(.Ack)
	ordered_remove(&no_lease, 2)
	append(&cases, Case{reply_of(ADDRESS, no_lease[:]), .No_Lease})
	zero_lease := good_options(.Ack)
	zero_lease[2].bytes = word_bytes(0)
	append(&cases, Case{reply_of(ADDRESS, zero_lease[:]), .Zero_Lease})
	for mask in ([?]u32{0, 0xFF00_FF00, 0xFE00_0000, 0xFFFF_FFFE, 0xFFFF_FFFF, 0x00FF_FFFF}) {
		bad := good_options(.Ack)
		bad[3].bytes = word_bytes(mask)
		append(&cases, Case{reply_of(ADDRESS, bad[:]), .Bad_Mask})
	}
	no_mask := good_options(.Ack)
	ordered_remove(&no_mask, 3)
	append(&cases, Case{reply_of(ADDRESS, no_mask[:]), .Bad_Mask})
	for address in ([?]u32{0, 0xFFFF_FFFF, 0x0A00_0200, 0x0A00_02FF, 0x7F00_0001, 0xE000_0001, 0xF000_0001, 0x0000_0001}) {
		append(&cases, Case{reply_of(address, good_options(.Ack)[:]), .Bad_Address})
	}
	for router in ([?]u32{0x0A00_0302, 0x0A00_0200, 0x0A00_02FF, 0xC0A8_0001}) {
		outside := good_options(.Ack)
		outside[4].bytes = word_bytes(router)
		append(&cases, Case{reply_of(ADDRESS, outside[:]), .Router_Outside})
	}
	Times :: struct {
		renew, rebind: u32,
	}
	for times in ([?]Times{{50000, 40000}, {43200, 43200}, {80000, 86400}, {86400, 90000}, {1, 86400}}) {
		bad := good_options(.Ack)
		append(&bad, Option{OPTION_RENEW_TIME, word_bytes(times.renew)}, Option{OPTION_REBIND_TIME, word_bytes(times.rebind)})
		append(&cases, Case{reply_of(ADDRESS, bad[:]), .Bad_Times})
	}
	overload := good_options(.Ack)
	append(&overload, Option{OPTION_OVERLOAD, []u8{3}})
	append(&cases, Case{reply_of(ADDRESS, overload[:]), .Overload})
	for item, index in cases {
		_, refused := reply_read(item.message, TRANSACTION, HARDWARE)
		testing.expectf(t, refused == item.problem, "case %d gives %v, not %v", index, refused, item.problem)
	}
	// A refused reply changes nothing of a client that waits for an offer.
	client: Client
	client_start(&client, HARDWARE, 0)
	out: [MESSAGE_CAPACITY]u8
	first := client_tick(&client, out[:], 0, TRANSACTION)
	testing.expect(t, first.send && first.broadcast && client.phase == .Selecting)
	before := client
	for item in cases {
		output, _ := client_receive(&client, item.message, out[:], 10)
		testing.expect(t, !output.send && output.event == .None)
		testing.expect(t, client == before)
	}
	// What is taken at the edges: a NAK needs no lease, a router list of
	// two, an infinite lease with no times, a prefix of 8 and of 30.
	nak := make([dynamic]Option, context.temp_allocator)
	append(&nak, Option{OPTION_MESSAGE_TYPE, []u8{u8(Message_Type.Nak)}}, Option{OPTION_SERVER, word_bytes(SERVER)})
	nak_reply, nak_problem := reply_read(reply_of(0, nak[:]), TRANSACTION, HARDWARE)
	testing.expect(t, nak_problem == .None && nak_reply.kind == .Nak)
	two_routers := good_options(.Ack)
	two_routers[4].bytes = make([]u8, 8, context.temp_allocator)
	be32_put(two_routers[4].bytes, 0, SERVER)
	be32_put(two_routers[4].bytes, 4, 0x0A00_0203)
	_, two_problem := reply_read(reply_of(ADDRESS, two_routers[:]), TRANSACTION, HARDWARE)
	testing.expect_value(t, two_problem, Reply_Problem.None)
	infinite := good_options(.Ack)
	infinite[2].bytes = word_bytes(INFINITE_LEASE)
	_, infinite_problem := reply_read(reply_of(ADDRESS, infinite[:]), TRANSACTION, HARDWARE)
	testing.expect_value(t, infinite_problem, Reply_Problem.None)
	for mask in ([?]u32{0xFF00_0000, 0xFFFF_FFFC}) {
		edge := good_options(.Ack)
		edge[3].bytes = word_bytes(mask)
		edge[4].bytes = word_bytes(mask == 0xFF00_0000 ? 0x0A00_0001 : 0x0A00_020D)
		address := mask == 0xFF00_0000 ? ADDRESS : u32(0x0A00_020E)
		_, edge_problem := reply_read(reply_of(address, edge[:]), TRANSACTION, HARDWARE)
		testing.expectf(t, edge_problem == .None, "the mask %x gives %v", mask, edge_problem)
	}
}

// The exchange: DISCOVER, OFFER, REQUEST of the offer, ACK; an ACK of
// another server or of another address is no answer; the waits double up
// to their last one; T1 renews by unicast, T2 rebinds by broadcast, and the
// end of the lease drops the address and starts again.
@(test)
the_exchange_and_the_times_of_a_lease :: proc(t: ^testing.T) {
	client: Client
	out: [MESSAGE_CAPACITY]u8
	client_start(&client, HARDWARE, 1000)
	testing.expect(t, !client_tick(&client, out[:], 999, TRANSACTION).send)
	discover := client_tick(&client, out[:], 1000, TRANSACTION)
	testing.expect(t, discover.send && discover.broadcast && discover.length >= MESSAGE_LEAST)
	testing.expect(t, out[0] == 1 && be32(out[:], 4) == TRANSACTION && out[MESSAGE_LEAST] == OPTION_MESSAGE_TYPE && out[MESSAGE_LEAST + 2] == u8(Message_Type.Discover))
	// The waits double: 4 s, 8 s, ... up to 64 s.
	now := u64(1000)
	for expected in ([?]u64{8_000, 16_000, 32_000, 64_000, 64_000}) {
		now = client.deadline
		again := client_tick(&client, out[:], now, TRANSACTION + 9)
		testing.expectf(t, again.send && client.wait == expected && client.transaction == TRANSACTION, "the wait is %d, not %d", client.wait, expected)
	}
	offer, _ := client_receive(&client, reply_of(ADDRESS, good_options(.Offer)[:]), out[:], now)
	testing.expect(t, offer.send && offer.broadcast && client.phase == .Requesting)
	testing.expect(t, out[MESSAGE_LEAST + 2] == u8(Message_Type.Request) && be32(out[:], MESSAGE_LEAST + 5) == ADDRESS)
	// An ACK of another server, or of another address, is no answer.
	other_server := good_options(.Ack)
	other_server[1].bytes = word_bytes(0x0A00_0203)
	ignored, _ := client_receive(&client, reply_of(ADDRESS, other_server[:]), out[:], now)
	testing.expect(t, ignored.event == .None && client.phase == .Requesting)
	ignored, _ = client_receive(&client, reply_of(ADDRESS + 1, good_options(.Ack)[:]), out[:], now)
	testing.expect(t, ignored.event == .None && client.phase == .Requesting)
	bound, _ := client_receive(&client, reply_of(ADDRESS, good_options(.Ack)[:]), out[:], now)
	testing.expect(t, bound.event == .Bound && client.phase == .Bound && client.lease.address == ADDRESS)
	start := now
	testing.expect_value(t, client.deadline, start + 43200 * 1000)
	// A message to a client that holds its lease and waits for no answer
	// changes nothing.
	stray, _ := client_receive(&client, reply_of(ADDRESS, good_options(.Ack)[:]), out[:], start + 5)
	testing.expect(t, stray.event == .None && client.bound_at == start)
	// T1: a REQUEST by unicast to the server, with the address in ciaddr.
	renew := client_tick(&client, out[:], start + 43200 * 1000, TRANSACTION + 1)
	testing.expect(t, renew.send && !renew.broadcast && renew.destination == SERVER && client.phase == .Renewing && be32(out[:], 12) == ADDRESS)
	// T2: a REQUEST by broadcast.
	rebind := client_tick(&client, out[:], start + 75600 * 1000, TRANSACTION + 2)
	testing.expect(t, rebind.send && rebind.broadcast && client.phase == .Rebinding)
	// The end of the lease: the address is lost, and the next tick sends a
	// DISCOVER of a new transaction.
	lost := client_tick(&client, out[:], start + 86400 * 1000, TRANSACTION + 3)
	testing.expect(t, lost.event == .Lost && client.phase == .Init)
	again := client_tick(&client, out[:], start + 86400 * 1000, TRANSACTION + 4)
	testing.expect(t, again.send && client.phase == .Selecting && client.transaction == TRANSACTION + 4)
}

// A NAK to a REQUEST starts again from DISCOVER; a NAK to a renewal drops
// the address; a renewal of another address is no answer.
@(test)
a_refused_request_starts_again :: proc(t: ^testing.T) {
	client: Client
	out: [MESSAGE_CAPACITY]u8
	client_start(&client, HARDWARE, 0)
	client_tick(&client, out[:], 0, TRANSACTION)
	client_receive(&client, reply_of(ADDRESS, good_options(.Offer)[:]), out[:], 1)
	nak := make([dynamic]Option, context.temp_allocator)
	append(&nak, Option{OPTION_MESSAGE_TYPE, []u8{u8(Message_Type.Nak)}}, Option{OPTION_SERVER, word_bytes(SERVER)})
	refused, _ := client_receive(&client, reply_of(0, nak[:]), out[:], 2)
	testing.expect(t, refused.event == .None && client.phase == .Init)
	client_tick(&client, out[:], 2, TRANSACTION)
	client_receive(&client, reply_of(ADDRESS, good_options(.Offer)[:]), out[:], 3)
	client_receive(&client, reply_of(ADDRESS, good_options(.Ack)[:]), out[:], 4)
	testing.expect(t, client.phase == .Bound)
	client_tick(&client, out[:], 4 + 43200 * 1000, TRANSACTION + 1)
	testing.expect(t, client.phase == .Renewing)
	other := make([dynamic]Option, context.temp_allocator)
	for option in good_options(.Ack) {
		append(&other, option)
	}
	// The transaction of the renewal.
	moved := reply_of(ADDRESS + 1, other[:])
	be32_put(moved, 4, TRANSACTION + 1)
	ignored, _ := client_receive(&client, moved, out[:], 5 + 43200 * 1000)
	testing.expect(t, ignored.event == .None && client.phase == .Renewing)
	nak_renew := reply_of(0, nak[:])
	be32_put(nak_renew, 4, TRANSACTION + 1)
	lost, _ := client_receive(&client, nak_renew, out[:], 6 + 43200 * 1000)
	testing.expect(t, lost.event == .Lost && client.phase == .Init)
}
// The static address of the plan: no field asks DHCP; a part missing, a
// prefix out of 8 to 30, an address that a machine cannot hold, and a
// gateway outside the subnet or equal to the address are refused; a whole
// address is taken.
@(test)
a_static_address_of_the_plan_is_read_at_its_border :: proc(t: ^testing.T) {
	plan_of :: proc(changes: []chosen_values.Change) -> (plan: plan_values.Owner_Values) {
		bytes := make([]u8, chosen_values.HEADER_SIZE + 8 * chosen_values.ENTRY_SIZE, context.temp_allocator)
		written, _ := chosen_values.write_record({}, changes, bytes)
		plan.locks, _ = chosen_values.read_record(bytes[:written])
		return plan
	}
	_, none_found, none_refused := static_of({})
	testing.expect(t, !none_found && !none_refused)
	Case :: struct {
		address, prefix, gateway: u64,
		with_prefix: bool,
	}
	for item in ([?]Case{{u64(ADDRESS), 0, 0, false}, {u64(ADDRESS), 7, 0, true}, {u64(ADDRESS), 31, 0, true}, {0, 24, 0, true}, {0x0A00_0200, 24, 0, true}, {0x0A00_02FF, 24, 0, true}, {0x7F00_0001, 8, 0, true}, {u64(ADDRESS), 24, 0x0A00_0302, true}, {u64(ADDRESS), 24, u64(ADDRESS), true}, {1 << 32, 24, 0, true}}) {
		changes := make([dynamic]chosen_values.Change, context.temp_allocator)
		append(&changes, chosen_values.Change{name = STATIC_ADDRESS_FIELD, kind = .Choose, value = item.address})
		if item.with_prefix {
			append(&changes, chosen_values.Change{name = STATIC_PREFIX_FIELD, kind = .Choose, value = item.prefix})
		}
		if item.gateway != 0 {
			append(&changes, chosen_values.Change{name = STATIC_GATEWAY_FIELD, kind = .Choose, value = item.gateway})
		}
		_, found, refused := static_of(plan_of(changes[:]))
		testing.expectf(t, found && refused, "%v is taken", item)
	}
	static, found, refused := static_of(plan_of({{name = STATIC_ADDRESS_FIELD, kind = .Choose, value = u64(ADDRESS)}, {name = STATIC_PREFIX_FIELD, kind = .Choose, value = 24}, {name = STATIC_GATEWAY_FIELD, kind = .Choose, value = u64(SERVER)}}))
	testing.expect(t, found && !refused && static.address == ADDRESS && static.mask == MASK && static.prefix == 24 && static.gateway == SERVER)
}
