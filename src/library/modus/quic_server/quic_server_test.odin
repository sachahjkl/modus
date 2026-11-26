#+build !freestanding
#+build !modus
package quic_server

import "core:testing"
import "modus:contract/call_outcome"
import "modus:contract/errors"
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
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = stale_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = unused_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = oob_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = u32(max(call_outcome.Call_Outcome)) + 1, tag = good_tag, values = {0 = 1}}))
	testing.expect(t, !validation_completed(nil, records[:], ring.Record{kind = max(u32), tag = good_tag, values = {0 = 1}}))
	// Matching live record with valid Status succeeds.
	testing.expect(t, validation_completed(nil, records[:], ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = good_tag, values = {0 = 1}}))
}

@(test)
completions_drain_handles_arrived_refusals_and_hostile_tags :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// Post receive places 3 and 4 and drain their initial commands from the ring.
	testing.expect(t, post_receive(&ep, 3))
	testing.expect(t, post_receive(&ep, 4))
	_, _ = ring.pop(&ep.datagrams.commands)
	_, _ = ring.pop(&ep.datagrams.commands)

	// Take two send places to simulate two in-flight sends.
	send_a, ok_a := place_take(&ep)
	send_b, ok_b := place_take(&ep)
	testing.expect(t, ok_a && ok_b)

	// Push mixed completions: valid receive, failed receive, valid send, refused send, hostile send tag naming rx place 0, unknown tag.
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 3, values = {1 = 64}}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Callee_Unavailable), tag = 4, values = errors.ring_fail(u32(datagram.Command.Receive), .Link_Down)}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = SEND_TAG + send_a}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted), tag = SEND_TAG + send_b, values = errors.ring_fail(u32(datagram.Command.Send), .Over_Limit, .Bytes, 2, 300, 100)}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = SEND_TAG + 0})) // Hostile: rx place as send!
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 500_000})) // Unknown tag.

	records: [4]quic.Server_Record
	arrived: [8]ring.Record
	count := completions_drain_queue(&ep, nil, records[:], arrived[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, arrived[0].tag, u32(3))
	// Both valid send places returned; hostile rx place rejected.
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64)
	testing.expect_value(t, ep.sends_refused, u64(1))
	testing.expect_value(t, ep.send_refusal_last, u32(call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted))
	testing.expect_value(t, ep.bad_completions, u64(2))

	// The failed receive (tag 4) must have been reposted onto commands and marked in flight.
	reposted, has_repost := ring.pop(&ep.datagrams.commands)
	testing.expect(t, has_repost)
	testing.expect_value(t, reposted.kind, u32(datagram.Command.Receive))
	testing.expect_value(t, reposted.tag, u32(4))
	testing.expect(t, ep.place_in_flight[4])
	testing.expect(t, !ep.place_in_flight[3])
}

@(test)
send_datagram_writes_valid_udp_and_refuses_bad_lengths :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	peer := quic.Remote{address = 0x0A00_0202, port = 54321}
	// Refusals: receive place, out-of-range place, send place NOT in flight, negative length, past UDP_DATA_LIMIT (1473..2040).
	testing.expect(t, !send_datagram(&ep, 0, 10, peer))
	testing.expect(t, !send_datagram(&ep, PLACE_COUNT, 10, peer))
	testing.expect(t, !send_datagram(&ep, 64, 10, peer)) // Not taken via place_take!

	place, took := place_take(&ep)
	testing.expect(t, took)
	testing.expect(t, !send_datagram(&ep, place, -1, peer))
	testing.expect(t, !send_datagram(&ep, place, network.UDP_DATA_LIMIT + 1, peer))
	testing.expect(t, !send_datagram(&ep, place, PLACE_SIZE - network.UDP_HEADER, peer))
	testing.expect(t, !send_datagram(&ep, place, PLACE_SIZE - network.UDP_HEADER + 1, peer))
	// No Send command was emitted on any of the refused lengths.
	_, stray := ring.pop(&ep.datagrams.commands)
	testing.expect(t, !stray)

	// Exact UDP_DATA_LIMIT (1472) is accepted.
	place_max, took_max := place_take(&ep)
	testing.expect(t, took_max)
	testing.expect(t, send_datagram(&ep, place_max, network.UDP_DATA_LIMIT, peer))
	cmd_max, has_max := ring.pop(&ep.datagrams.commands)
	testing.expect(t, has_max)
	testing.expect_value(t, cmd_max.values[1], u64(network.UDP_HEADER + network.UDP_DATA_LIMIT))
	testing.expect(t, place_return(&ep, place_max))

	// Valid send writes a verifiable UDP header and queues Send command.
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
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 5, values = {1 = 3, 2 = 0x0A00_0202, 3 = 12345}},
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = PLACE_COUNT, values = {1 = 32, 2 = 0x0A00_0202, 3 = 12345}},
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

// Finding 1: per-place in-flight tracking prevents double-free of send slots,
// prevents forged completions from corrupting sends_refused/send_refusal_last,
// and prevents overlapping receives on the same buffer slot.
@(test)
in_flight_tracking_refuses_duplicate_send_and_receive_completions :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// Take two send places so free_count < send_capacity, then return only one.
	send_a, ok_a := place_take(&ep)
	send_b, ok_b := place_take(&ep)
	testing.expect(t, ok_a && ok_b)
	testing.expect(t, place_return(&ep, send_a))
	// Double-returning send_a while send_b is still in flight MUST fail!
	testing.expect(t, !place_return(&ep, send_a))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64 - 1)

	// A forged/duplicate Send completion for free slot send_a with error status
	// must be refused WITHOUT incrementing sends_refused or send_refusal_last.
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Budget_Or_Capacity_Exhausted), tag = SEND_TAG + send_a, values = errors.ring_fail(u32(datagram.Command.Send), .Over_Limit, .Bytes, 2, 300, 100)}))
	// An unposted Receive completion (slot 7 never posted) must be refused.
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 7, values = {1 = 32}}))
	// Post receive slot 8 once; posting a second time while in flight must fail.
	testing.expect(t, post_receive(&ep, 8))
	testing.expect(t, !post_receive(&ep, 8))
	_, _ = ring.pop(&ep.datagrams.commands)
	// Deliver two completions for slot 8: first succeeds, second is refused.
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 8, values = {1 = 32}}))
	testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 8, values = {1 = 32}}))

	records: [4]quic.Server_Record
	arrived: [8]ring.Record
	count := completions_drain_queue(&ep, nil, records[:], arrived[:])
	testing.expect_value(t, count, 1)
	testing.expect_value(t, arrived[0].tag, u32(8))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64 - 1)
	testing.expect_value(t, ep.sends_refused, u64(0))
	testing.expect_value(t, ep.send_refusal_last, u32(0))
	// 3 bad completions: duplicate send_a, unposted rx 7, duplicate rx 8.
	testing.expect_value(t, ep.bad_completions, u64(3))
	// Neither unposted rx 7 nor duplicate rx 8 was reposted.
	_, stray_cmd := ring.pop(&ep.datagrams.commands)
	testing.expect(t, !stray_cmd)
	// Reclaim send_b cleanly.
	testing.expect(t, place_return(&ep, send_b))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64)
}

// Finding 2: info_completion_check validates CALL_TAG, Ok status enum,
// local IPv4 address bounds, and UDP listen grant / required address.
@(test)
info_completion_check_refuses_bad_tag_status_and_grant :: proc(t: ^testing.T) {
	udp_listen := datagram.grant_pack(datagram.Grant{listen = true, port = 7101, address = 0x0A00_0202})
	tcp_listen := datagram.grant_pack(datagram.Grant{tcp = true, listen = true, port = 7101, address = 0x0A00_0202})
	udp_client := datagram.grant_pack(datagram.Grant{listen = false, port = 7101, address = 0x0A00_0202})

	// Wrong tag.
	for bad_tag in ([?]u32{0, 1, SEND_TAG, CALL_TAG + 1, max(u32)}) {
		_, _, err := info_completion_check(ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = bad_tag, values = {0 = 0x0A00_020F, 6 = udp_listen}})
		testing.expectf(t, err == .Bad_Grant, "tag %d must fail", bad_tag)
	}
	// An outcome other than Succeeded, or a word that names no outcome.
	for bad_status in ([?]u32{u32(call_outcome.Call_Outcome.Argument_Refused), u32(call_outcome.Call_Outcome.Grant_Or_Right_Missing), u32(max(call_outcome.Call_Outcome)) + 1, max(u32)}) {
		_, _, err := info_completion_check(ring.Record{kind = bad_status, tag = CALL_TAG, values = {0 = 0x0A00_020F, 6 = udp_listen}})
		testing.expectf(t, err == .Bad_Grant, "status %d must fail", bad_status)
	}
	// Local address past u32.
	{
		_, _, err := info_completion_check(ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = CALL_TAG, values = {0 = u64(max(u32)) + 1, 6 = udp_listen}})
		testing.expect_value(t, err, Open_Error.Bad_Grant)
	}
	// TCP grant, non-listen UDP grant, unknown grant bits, wrong required address.
	for bad_grant in ([?]u64{0, tcp_listen, udp_client, max(u64)}) {
		_, _, err := info_completion_check(ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = CALL_TAG, values = {0 = 0x0A00_020F, 6 = bad_grant}})
		testing.expectf(t, err == .Bad_Grant, "grant %x must fail", bad_grant)
	}
	{
		_, _, err := info_completion_check(ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = CALL_TAG, values = {0 = 0x0A00_020F, 6 = udp_listen}}, 0x0A00_0203, true)
		testing.expect_value(t, err, Open_Error.Bad_Grant)
	}
	// Valid UDP listen grant succeeds with exact address and port.
	addr, port, err := info_completion_check(ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = CALL_TAG, values = {0 = 0x0A00_020F, 6 = udp_listen}}, 0x0A00_0202, true)
	testing.expect_value(t, err, Open_Error.None)
	testing.expect_value(t, addr, u32(0x0A00_020F))
	testing.expect_value(t, port, u16(7101))
}

// Finding 3: send_datagram refuses nil region / held overflow without leaking slots.
@(test)
send_datagram_failure_leaves_slot_returnable_without_leak :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	peer := quic.Remote{address = 0x0A00_0202, port = 54321}
	place, took := place_take(&ep)
	testing.expect(t, took)

	// Simulate nil region so udp_header_write cannot write a header.
	saved_region := ep.region
	ep.region = nil
	testing.expect(t, !send_datagram(&ep, place, 16, peer))
	ep.region = saved_region
	// No Send record emitted, and slot is still cleanly returnable.
	_, has := ring.pop(&ep.datagrams.commands)
	testing.expect(t, !has)
	testing.expect(t, place_return(&ep, place))
	testing.expect_value(t, ep.free_count, PLACE_COUNT - 64)
}

// Finding 4: bounded drain counts arrivals_dropped when arrived slice is full,
// reposts dropped receive slots, and completions_drain skips wake_writer on idle.
@(test)
drain_counts_arrivals_dropped_and_skips_idle_wake :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// With zero completions and writer_waits=1, completions_drain must NOT call
	// wake_writer (which would issue a kernel syscall on host).
	ep.datagrams.completions.counters.writer_waits = 1
	records: [4]quic.Server_Record
	arrived_small: [2]ring.Record
	testing.expect_value(t, completions_drain(&ep, nil, records[:], arrived_small[:]), 0)
	ep.datagrams.completions.counters.writer_waits = 0

	// Post 4 receives, deliver 4 Ok completions, drain into a 2-slot buffer.
	for slot in u32(0) ..< 4 {
		testing.expect(t, post_receive(&ep, slot))
		_, _ = ring.pop(&ep.datagrams.commands)
		testing.expect(t, ring.push(&ep.datagrams.completions, ring.Record{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = slot, values = {1 = 32}}))
	}
	count := completions_drain_queue(&ep, nil, records[:], arrived_small[:])
	testing.expect_value(t, count, 2)
	testing.expect_value(t, ep.arrivals_dropped, u64(2))
	// Slots 0 and 1 are in arrived_small (idle until exchange reposts); slots 2 and 3 were reposted immediately.
	testing.expect(t, !ep.place_in_flight[0] && !ep.place_in_flight[1])
	testing.expect(t, ep.place_in_flight[2] && ep.place_in_flight[3])
	repost2, has2 := ring.pop(&ep.datagrams.commands)
	repost3, has3 := ring.pop(&ep.datagrams.commands)
	testing.expect(t, has2 && repost2.tag == 2)
	testing.expect(t, has3 && repost3.tag == 3)
}

// Finding 5: exchange explicitly refuses receive completions with oversized
// length (> PLACE_SIZE), undersized length (< UDP_HEADER), upper-bit address
// or port overflow, or a send-place tag, without silent clamping.
@(test)
exchange_refuses_oversized_and_out_of_range_receive_fields :: proc(t: ^testing.T) {
	backing := new(Test_Backing)
	defer free(backing)
	ep, ok := test_endpoint_make(backing, 64, 4)
	testing.expect(t, ok)

	// Write a valid UDP packet into slots 0..3 so only the completion fields are bad.
	for slot in u32(0) ..< 4 {
		buf := place_bytes(&ep, slot)
		_ = network.udp_header_write(buf, 0x0A00_0202, ep.local_address, 50000, ep.listen_port, 16)
	}
	bad_arrived := [5]ring.Record{
		// Oversized length (> PLACE_SIZE): must NOT be clamped to PLACE_SIZE.
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 0, values = {1 = PLACE_SIZE + 1, 2 = 0x0A00_0202, 3 = 50000}},
		// Undersized length (< UDP_HEADER).
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 1, values = {1 = network.UDP_HEADER - 1, 2 = 0x0A00_0202, 3 = 50000}},
		// Remote IPv4 address past u32.
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 2, values = {1 = network.UDP_HEADER + 16, 2 = u64(max(u32)) + 1, 3 = 50000}},
		// Remote UDP port past u16.
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 3, values = {1 = network.UDP_HEADER + 16, 2 = 0x0A00_0202, 3 = u64(max(u16)) + 1}},
		// Tag names a send place (64 >= receive_places), not a receive place.
		{kind = u32(call_outcome.Call_Outcome.Succeeded), tag = 64, values = {1 = network.UDP_HEADER + 16, 2 = 0x0A00_0202, 3 = 50000}},
	}
	srv: quic.Server
	records: [4]quic.Server_Record
	_ = exchange(&ep, &srv, records[:], bad_arrived[:], 1000)
	testing.expect_value(t, ep.datagrams_malformed, u64(5))
	// Slots 0..3 were valid receive slots and are reposted; slot 64 (a send slot) must NOT be posted as Receive.
	reposted_count := 0
	for {
		rec, has := ring.pop(&ep.datagrams.commands)
		if !has {
			break
		}
		testing.expect(t, rec.tag < 64)
		reposted_count += 1
	}
	testing.expect_value(t, reposted_count, 4)
	testing.expect(t, !ep.place_in_flight[64])
}
