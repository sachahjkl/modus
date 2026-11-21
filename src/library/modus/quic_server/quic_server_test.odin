#+build !freestanding
package quic_server

import "core:testing"
import "modus:contract/datagram"
import "modus:contract/ring"
import "modus:network"
import "modus:quic"

// Helper: creates a valid in-memory ring (32-record capacity = 2 pages) and
// full 512 KiB datagram region on the heap/stack for host tests.
Test_Backing :: struct {
	ring_pages: [ring.PAGE_COUNT * ring.PAGE_SIZE]u8,
	region:     [PLACE_COUNT * PLACE_SIZE]u8,
}

test_endpoint_make :: proc(
	backing: ^Test_Backing,
	receive_places: int = 64,
	record_capacity: int = 4,
) -> (ep: Endpoint, ok: bool) {
	backing^ = {}
	r, r_ok := ring.open(&backing.ring_pages[0], ring.PAGE_COUNT)
	if !r_ok {
		return {}, false
	}
	ok = endpoint_init(&ep, r, backing.region[:], 0x0A00_020F, 7100, receive_places, record_capacity)
	return ep, ok
}

@(test)
endpoint_init_refuses_invalid_inputs_and_accepts_bounds :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	r, r_ok := ring.open(&backing.ring_pages[0], ring.PAGE_COUNT)
	testing.expect(t, r_ok)

	ep: Endpoint
	// Nil endpoint, zero ring, undersized regions.
	testing.expect(t, !endpoint_init(nil, r, backing.region[:], 0, 0, 64, 4))
	testing.expect(t, !endpoint_init(&ep, {}, backing.region[:], 0, 0, 64, 4))
	testing.expect(t, !endpoint_init(&ep, r, nil, 0, 0, 64, 4))
	testing.expect(t, !endpoint_init(&ep, r, backing.region[:PLACE_COUNT * PLACE_SIZE - 1], 0, 0, 64, 4))

	// Bad receive_places: negative, 0, past RECEIVE_PLACES_LIMIT, PLACE_COUNT.
	for bad_rx in ([?]int{-1, 0, RECEIVE_PLACES_LIMIT + 1, PLACE_COUNT, max(int)}) {
		testing.expectf(t, !endpoint_init(&ep, r, backing.region[:], 0, 0, bad_rx, 4), "receive_places=%d must be refused", bad_rx)
	}

	// Bad record_capacity: negative, 0, past MAX_CAPACITY.
	for bad_cap in ([?]int{-1, 0, MAX_CAPACITY + 1, max(int)}) {
		testing.expectf(t, !endpoint_init(&ep, r, backing.region[:], 0, 0, 64, bad_cap), "record_capacity=%d must be refused", bad_cap)
	}

	// Minimum valid bounds.
	testing.expect(t, endpoint_init(&ep, r, backing.region[:], 0x0A00_020F, 4433, 1, 1))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 1)
	testing.expect_value(t, ep.held_capacity, PLACE_COUNT + 2 + 1)

	// Maximum valid bounds.
	testing.expect(t, endpoint_init(&ep, r, backing.region[:], 0x0A00_020F, 4433, RECEIVE_PLACES_LIMIT, MAX_CAPACITY))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - RECEIVE_PLACES_LIMIT)
	testing.expect_value(t, ep.held_capacity, HELD_CAPACITY)
}

@(test)
places_enforce_bounds_and_prevent_corruption :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// Out-of-range places return nil.
	testing.expect(t, place_bytes(&ep, PLACE_COUNT) == nil)
	testing.expect(t, place_bytes(&ep, max(u32)) == nil)
	testing.expect(t, data_bytes(&ep, PLACE_COUNT) == nil)
	testing.expect_value(t, len(place_bytes(&ep, 0)), PLACE_SIZE)
	testing.expect_value(t, len(data_bytes(&ep, 64)), PLACE_SIZE - network.UDP_HEADER)

	// Returning when free stack is already full is refused.
	testing.expect(t, !place_return(&ep, 64))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64)

	// Take one send place, then refuse returning receive places or out-of-range places.
	taken, took := place_take(&ep)
	testing.expect(t, took)
	testing.expect(t, taken >= 64 && taken < PLACE_COUNT)
	testing.expect(t, !place_return(&ep, 0))
	testing.expect(t, !place_return(&ep, 63))
	testing.expect(t, !place_return(&ep, PLACE_COUNT))
	testing.expect(t, !place_return(&ep, max(u32)))
	testing.expect(t, place_return(&ep, taken))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64)

	// Drain every free place and confirm empty refusal.
	taken_all := 0
	for {
		_, got := place_take(&ep)
		if !got {
			break
		}
		taken_all += 1
	}
	testing.expect_value(t, taken_all, PLACE_COUNT - 64)
	testing.expect_value(t, ep.free_count, 0)
}

@(test)
held_command_queue_preserves_fifo_and_refuses_overflow :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 2)
	testing.expect(t, ok)

	@(static) overflow_callbacks: int
	overflow_callbacks = 0
	ep.on_held_overflow = proc "contextless" () {
		overflow_callbacks += 1
	}

	// Fill the 32-record command ring directly.
	ring_cap := int(ring.capacity(&ep.datagrams.commands))
	for index in 0 ..< ring_cap {
		pushed := command_push_or_hold(&ep, ring.Record{kind = u32(datagram.Command.Release), tag = u32(index)})
		testing.expect(t, pushed)
	}
	testing.expect_value(t, ep.held_command_count, 0)

	// Fill held_commands to exact held_capacity.
	for index in 0 ..< ep.held_capacity {
		pushed := command_push_or_hold(&ep, ring.Record{kind = u32(datagram.Command.Release), tag = u32(ring_cap + index)})
		testing.expect(t, pushed)
	}
	testing.expect_value(t, ep.held_command_count, ep.held_capacity)
	testing.expect_value(t, ep.held_overflows, u64(0))

	// One past held_capacity must fail without corrupting existing held records.
	testing.expect(t, !command_push_or_hold(&ep, ring.Record{kind = u32(datagram.Command.Release), tag = 999_999}))
	testing.expect_value(t, ep.held_command_count, ep.held_capacity)
	testing.expect_value(t, ep.held_overflows, u64(1))
	testing.expect_value(t, overflow_callbacks, 1)

	// Pop 5 records from the ring; a new push while held > 0 must NOT jump ahead.
	for index in 0 ..< 5 {
		rec, has := ring.pop(&ep.datagrams.commands)
		testing.expect(t, has)
		testing.expect_value(t, rec.tag, u32(index))
	}
	// Drain held commands in FIFO order and verify every single tag arrives in sequence.
	expected_tag := u32(5)
	for {
		held_commands_push(&ep)
		rec, has := ring.pop(&ep.datagrams.commands)
		if !has {
			break
		}
		testing.expect_value(t, rec.tag, expected_tag)
		expected_tag += 1
	}
	testing.expect_value(t, expected_tag, u32(ring_cap + ep.held_capacity))
	testing.expect_value(t, ep.held_command_count, 0)
}

@(test)
validate_tags_and_completions_reject_stale_and_hostile_values :: proc(t: ^testing.T) {
	// Edge cases for validate_tag_pack.
	for bad_place in ([?]int{-1, MAX_CAPACITY, MAX_CAPACITY + 1, max(int)}) {
		tag, ok := validate_tag_pack(bad_place, 1)
		testing.expectf(t, !ok && tag == 0, "place=%d must be refused", bad_place)
	}
	// Edge cases for validate_tag_unpack: tags without VALIDATE_TAG bit.
	for bad_tag in ([?]u32{0, 1, SEND_TAG, CALL_TAG, 0x7FFF_FFFF}) {
		place, gen, ok := validate_tag_unpack(bad_tag)
		testing.expectf(t, !ok && place == 0 && gen == 0, "tag=%x must be refused", bad_tag)
	}

	// Round-trip at 0 and max bounds.
	tag0, ok0 := validate_tag_pack(0, 0)
	testing.expect(t, ok0)
	p0, g0, u0 := validate_tag_unpack(tag0)
	testing.expect(t, u0 && p0 == 0 && g0 == 0)

	tag_max, ok_max := validate_tag_pack(MAX_CAPACITY - 1, max(u64))
	testing.expect(t, ok_max)
	pm, gm, um := validate_tag_unpack(tag_max)
	testing.expect(t, um && pm == MAX_CAPACITY - 1 && gm == VALIDATE_GENERATION_MASK)

	// validation_completed checks record existence, generation match, and valid Status word.
	records: [4]quic.Server_Record
	records[2] = {in_use = true, generation = 0x12345}
	good_tag, _ := validate_tag_pack(2, 0x12345)
	stale_tag, _ := validate_tag_pack(2, 0x12344)
	unused_tag, _ := validate_tag_pack(1, 1)
	oob_tag, _ := validate_tag_pack(5, 1)

	// Stale generation, unused slot, out-of-range place, and unknown Status word all refused.
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(datagram.Status.Ok), tag = stale_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(datagram.Status.Ok), tag = unused_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(datagram.Status.Ok), tag = oob_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(max(datagram.Status)) + 1, tag = good_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = max(u32), tag = good_tag, values = {0 = 1}}))
	// Matching live record with valid Status succeeds.
	testing.expect(t, validation_completed(nil, records[:], ring.Record{kind = u32(datagram.Status.Ok), tag = good_tag, values = {0 = 1}}))
}

@(test)
completions_drain_handles_arrived_refusals_and_hostile_tags :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// Take two send places to simulate two in-flight sends.
	send_a, ok_a := place_take(&ep)
	send_b, ok_b := place_take(&ep)
	testing.expect(t, ok_a && ok_b)

	// Push mixed completions: valid receive, failed receive, valid send, refused send, hostile send tag naming rx place 0, unknown tag.
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(datagram.Status.Ok), tag = 3, values = {1 = 64}}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(datagram.Status.Link_Down), tag = 4}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(datagram.Status.Ok), tag = SEND_TAG + send_a}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(datagram.Status.Amplification), tag = SEND_TAG + send_b}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(datagram.Status.Ok), tag = SEND_TAG + 0})) // Hostile: rx place as send!
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(datagram.Status.Ok), tag = 500_000})) // Unknown tag.

	records: [4]quic.Server_Record
	arrived: [8]ring.Record
	count := completions_drain_queue(&ep, nil, records[:], arrived[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, arrived[0].tag, u32(3))
	// Both valid send places returned; hostile rx place rejected.
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64)
	testing.expect_value(t, ep.sends_refused, u64(1))
	testing.expect_value(t, ep.send_refusal_last, u32(datagram.Status.Amplification))
	testing.expect_value(t, ep.bad_completions, u64(2))

	// The failed receive (tag 4) must have been reposted onto commands.
	reposted, has_repost := ring.pop(&ep.datagrams.commands)
	testing.expect(t, has_repost)
	testing.expect_value(t, reposted.kind, u32(datagram.Command.Receive))
	testing.expect_value(t, reposted.tag, u32(4))
}

@(test)
send_datagram_writes_valid_udp_and_refuses_bad_lengths :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	peer := quic.Remote{address = 0x0A00_0202, port = 54321}
	// Refusals: receive place, out-of-range place, negative length, oversized length.
	testing.expect(t, !send_datagram(&ep, 0, 10, peer))
	testing.expect(t, !send_datagram(&ep, PLACE_COUNT, 10, peer))
	testing.expect(t, !send_datagram(&ep, 64, -1, peer))
	testing.expect(t, !send_datagram(&ep, 64, PLACE_SIZE - network.UDP_HEADER + 1, peer))

	// Valid send writes a verifiable UDP header and queues Send command.
	place, took := place_take(&ep)
	testing.expect(t, took)
	payload := data_bytes(&ep, place)
	copy(payload, "hello-quic")
	testing.expect(t, send_datagram(&ep, place, len("hello-quic"), peer))

	cmd, has := ring.pop(&ep.datagrams.commands)
	testing.expect(t, has)
	testing.expect_value(t, cmd.kind, u32(datagram.Command.Send))
	testing.expect_value(t, cmd.tag, SEND_TAG + place)
	testing.expect_value(t, cmd.values[0], u64(place) * PLACE_SIZE)
	testing.expect_value(t, cmd.values[1], u64(network.UDP_HEADER + len("hello-quic")))
	testing.expect_value(t, cmd.values[2], u64(peer.address))

	// Verify the written UDP datagram checksum and payload round-trip.
	raw := place_bytes(&ep, place)[:cmd.values[1]]
	data, whole := network.udp_data_read(raw, ep.local_address, peer.address, .Verify)
	testing.expect(t, whole)
	testing.expect_value(t, string(data), "hello-quic")
}

@(test)
log_budget_and_formatting_helpers :: proc(t: ^testing.T) {
	// Zero limit always refuses.
	zero_budget := Log_Budget{limit = 0}
	testing.expect(t, !log_allowed(&zero_budget, 1000))
	testing.expect(t, !log_allowed(nil, 1000))

	// Limit of 2 allows 2 per second and resets on next second.
	budget := Log_Budget{limit = 2}
	testing.expect(t, log_allowed(&budget, 5000))
	testing.expect(t, log_allowed(&budget, 5500))
	testing.expect(t, !log_allowed(&budget, 5999))
	testing.expect(t, log_allowed(&budget, 6000))
	testing.expect(t, log_allowed(&budget, 6001))
	testing.expect(t, !log_allowed(&budget, 6999))

	// hex_text edge cases: empty, 1-byte buffer, full buffer.
	sample := [3]u8{0x0a, 0xbc, 0xff}
	buf0: [0]u8
	buf1: [1]u8
	buf4: [4]u8
	buf6: [6]u8
	testing.expect_value(t, hex_text(buf0[:], sample[:]), "")
	testing.expect_value(t, hex_text(buf1[:], sample[:]), "")
	testing.expect_value(t, hex_text(buf4[:], sample[:]), "0abc")
	testing.expect_value(t, hex_text(buf6[:], sample[:]), "0abcff")

	// address_text formats IPv4 and port cleanly.
	addr_buf: [40]u8
	testing.expect_value(t, address_text(addr_buf[:], quic.Remote{address = 0x0A00_0202, port = 7101}), "10.0.2.2 port 7101")
}

@(test)
exchange_counts_malformed_datagrams_and_reposts_places :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// Nil endpoint or nil server returns max(u64) without crashing.
	srv: quic.Server
	records: [4]quic.Server_Record
	testing.expect_value(t, exchange(nil, &srv, records[:], nil, 1000), max(u64))
	testing.expect_value(t, exchange(&ep, nil, records[:], nil, 1000), max(u64))

	// Put a truncated (3-byte) UDP datagram in receive place 5 and an out-of-range place tag.
	arrived := [2]ring.Record{
		{kind = u32(datagram.Status.Ok), tag = 5, values = {1 = 3, 2 = 0x0A00_0202, 3 = 12345}},
		{kind = u32(datagram.Status.Ok), tag = PLACE_COUNT, values = {1 = 32, 2 = 0x0A00_0202, 3 = 12345}},
	}
	@(static) work_calls: int
	work_calls = 0
	work_fn :: proc "contextless" () {
		work_calls += 1
	}
	deadline := exchange(&ep, &srv, records[:], arrived[:], 1000, work_fn)
	testing.expect_value(t, deadline, max(u64))
	testing.expect_value(t, ep.datagrams_malformed, u64(2))
	testing.expect_value(t, work_calls, 1)

	// Place 5 must be reposted; out-of-range place PLACE_COUNT must not be posted.
	reposted, has := ring.pop(&ep.datagrams.commands)
	testing.expect(t, has)
	testing.expect_value(t, reposted.kind, u32(datagram.Command.Receive))
	testing.expect_value(t, reposted.tag, u32(5))
	_, has_more := ring.pop(&ep.datagrams.commands)
	testing.expect(t, !has_more)
}
