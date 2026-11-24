// Shared QUIC server endpoint, held-command queue, and datagram exchange loop
// for services that accept QUIC connections over a UDP listen grant
// (src/md/features/remote_display.md).
//
// Each QUIC service (remote, remote_display, quic_echo) shares the same
// datagram region layout, held-command queue, validation tag packing,
// completion draining, and QUIC server exchange pass. Keeping one
// freestanding, zero-allocation implementation ensures any fix applies to
// every service at once.
package quic_server

import "modus:contract/call_outcome"
import "modus:contract/datagram"
import "modus:contract/ring"
import "modus:network"
import "modus:quic"
import "modus:system"

// The datagram region: 256 places of 2048 bytes each.
PLACE_SIZE :: 2048
PLACE_COUNT :: datagram.REGION_PAGES * system.PAGE_SIZE / PLACE_SIZE

// The most receive places and the most concurrent QUIC connections that one
// shared server endpoint manages.
RECEIVE_PLACES_LIMIT :: 96
VALIDATE_PLACE_BITS :: 5
MAX_CAPACITY :: 1 << VALIDATE_PLACE_BITS

// Tags on the datagram ring:
//   0 ..< receive_places                 Receive of that place.
//   SEND_TAG + place                     Send of that place.
//   CALL_TAG                             Info and Release.
//   VALIDATE_TAG | gen<<5 | place        Validate of the record at place.
//
// A Validate completion that arrives after its record ended and the place
// was reused names the old generation and confirms nothing: 2^26 records
// would have to turn over in one ring round to collide.
SEND_TAG :: 1000
CALL_TAG :: 100_000
VALIDATE_TAG :: u32(1) << 31
VALIDATE_GENERATION_MASK :: (u64(1) << (31 - VALIDATE_PLACE_BITS)) - 1

// Upper bound on commands held when the datagram command ring is full:
// each place appears in at most one Send or Receive, and a Release or
// Validate follows an arrived datagram or an ended record.
HELD_CAPACITY :: PLACE_COUNT + 2 * RECEIVE_PLACES_LIMIT + MAX_CAPACITY

// Rounds of application work and datagram sends in one exchange pass.
SEND_ROUNDS :: 4

// Hang bound for the initial Info completion when opening an endpoint: matches
// system.ANSWER_BOUND_MILLISECONDS (60 s) so a loaded host never turns a slow
// start of the network service into a timeout.
INFO_WAIT_MILLISECONDS :: system.ANSWER_BOUND_MILLISECONDS

// Result of opening a UDP listen endpoint from a process context.
Open_Error :: enum u8 {
	None         = 0,
	Bad_Config   = 1,
	No_Ring      = 2,
	No_Region    = 3,
	Info_Timeout = 4,
	Bad_Grant    = 5,
}

// Per-second rate limiter for log lines from network peers.
Log_Budget :: struct {
	second: u64,
	count:  u64,
	limit:  u64,
}

// State of one UDP listen endpoint shared by a QUIC service: its datagram
// ring, region, free send places, per-place in-flight state, held-command
// queue, and error counters.
Endpoint :: struct {
	datagrams:           ring.Ring,
	region:              []u8,
	local_address:       u32,
	listen_port:         u16,
	receive_places:      int,
	record_capacity:     int,
	held_capacity:       int,
	free_places:         [PLACE_COUNT]u32,
	free_count:          int,
	// Tracks whether each buffer slot (receive or send) is currently owned
	// by an in-flight operation so duplicate or forged completions can never
	// double-free a send slot or post overlapping receives on one slot.
	place_in_flight:     [PLACE_COUNT]bool,
	held_commands:       [HELD_CAPACITY]ring.Record,
	held_command_count:  int,
	held_overflows:      u64,
	datagrams_malformed: u64,
	sends_refused:       u64,
	send_refusal_last:   u32,
	bad_completions:     u64,
	arrivals_dropped:    u64,
	on_held_overflow:    proc "contextless" (),
}

// endpoint_init initializes an Endpoint over an already-mapped datagram ring
// and region without issuing any kernel operation. It refuses invalid
// capacities, undersized regions, or a nil ring without modifying state.
endpoint_init :: proc "contextless" (
	endpoint: ^Endpoint,
	datagrams: ring.Ring,
	region: []u8,
	local_address: u32,
	listen_port: u16,
	receive_places: int,
	record_capacity: int,
) -> bool {
	if endpoint == nil || datagrams.head == nil {
		return false
	}
	if len(region) < PLACE_COUNT * PLACE_SIZE {
		return false
	}
	if receive_places < 1 || receive_places > RECEIVE_PLACES_LIMIT || receive_places >= PLACE_COUNT {
		return false
	}
	if record_capacity < 1 || record_capacity > MAX_CAPACITY {
		return false
	}
	endpoint^ = {
		datagrams       = datagrams,
		region          = region[:PLACE_COUNT * PLACE_SIZE],
		local_address   = local_address,
		listen_port     = listen_port,
		receive_places  = receive_places,
		record_capacity = record_capacity,
		held_capacity   = PLACE_COUNT + 2 * receive_places + record_capacity,
	}
	for place in receive_places ..< PLACE_COUNT {
		endpoint.free_places[endpoint.free_count] = u32(place)
		endpoint.free_count += 1
	}
	return true
}

// info_completion_check validates an Info completion record from the network
// service: checks CALL_TAG, Succeeded through the border of a completion, valid IPv4
// local address, and a UDP listen grant (optionally restricted to
// required_address).
info_completion_check :: proc "contextless" (
	info: ring.Record,
	required_address: u32 = 0,
	require_address: bool = false,
) -> (local_address: u32, listen_port: u16, err: Open_Error) {
	if info.tag != CALL_TAG {
		return 0, 0, .Bad_Grant
	}
	if outcome, _ := call_outcome.completion_outcome(info.kind, info.values); outcome != .Succeeded {
		return 0, 0, .Bad_Grant
	}
	if info.values[0] > u64(max(u32)) {
		return 0, 0, .Bad_Grant
	}
	grant, grant_known := datagram.grant_unpack(info.values[6])
	if !grant_known || grant.tcp || !grant.listen {
		return 0, 0, .Bad_Grant
	}
	if require_address && grant.address != required_address {
		return 0, 0, .Bad_Grant
	}
	return u32(info.values[0]), grant.port, .None
}

// endpoint_open opens the datagram ring and region from the process context,
// queries Info from the network service with a fixed deadline, validates the
// Info completion and UDP listen grant, and initializes the Endpoint.
endpoint_open :: proc "contextless" (
	endpoint: ^Endpoint,
	ctx: ^system.Context,
	receive_places: int,
	record_capacity: int,
	required_address: u32 = 0,
	require_address: bool = false,
) -> Open_Error {
	if endpoint == nil || ctx == nil {
		return .Bad_Config
	}
	if receive_places < 1 || receive_places > RECEIVE_PLACES_LIMIT || receive_places >= PLACE_COUNT {
		return .Bad_Config
	}
	if record_capacity < 1 || record_capacity > MAX_CAPACITY {
		return .Bad_Config
	}
	datagrams, ring_status := system.ring_open(ctx.handles[datagram.GRANT_RING])
	if ring_status != .Succeeded {
		return .No_Ring
	}
	address, map_status := system.memory_map(ctx.handles[datagram.GRANT_REGION], {.Write})
	region_pages, size_status := system.memory_size(ctx.handles[datagram.GRANT_REGION])
	if map_status != .Succeeded || size_status != .Succeeded || region_pages < datagram.REGION_PAGES {
		return .No_Region
	}
	region := ([^]u8)(address)[:datagram.REGION_PAGES * system.PAGE_SIZE]
	if !system.send(&datagrams.commands, ring.Record{kind = u32(datagram.Command.Info), tag = CALL_TAG}) {
		return .Info_Timeout
	}
	info: ring.Record
	got_info := false
	deadline := system.time() + INFO_WAIT_MILLISECONDS
	for {
		for _ in 0 ..< system.records_of_turn(&datagrams.completions) {
			record, has := system.receive(&datagrams.completions)
			if !has {
				break
			}
			if record.tag != CALL_TAG {
				continue
			}
			info = record
			got_info = true
			break
		}
		if got_info {
			break
		}
		if system.time() >= deadline {
			return .Info_Timeout
		}
		wait: system.Wait
		system.wait_records(&wait, &datagrams.completions)
		now := system.wait_end(&wait, deadline)
		if now >= deadline {
			// Check once more after waking at the deadline before timing out.
			for _ in 0 ..< system.records_of_turn(&datagrams.completions) {
				record, has := system.receive(&datagrams.completions)
				if !has {
					break
				}
				if record.tag == CALL_TAG {
					info = record
					got_info = true
					break
				}
			}
			break
		}
	}
	if !got_info {
		return .Info_Timeout
	}
	local_address, listen_port, check_err := info_completion_check(info, required_address, require_address)
	if check_err != .None {
		return check_err
	}
	if !endpoint_init(endpoint, datagrams, region, local_address, listen_port, receive_places, record_capacity) {
		return .Bad_Config
	}
	return .None
}

// place_bytes returns the full PLACE_SIZE buffer for a valid place index, or
// nil if place is out of range.
place_bytes :: proc "contextless" (endpoint: ^Endpoint, place: u32) -> []u8 {
	if endpoint == nil || place >= PLACE_COUNT || len(endpoint.region) < PLACE_COUNT * PLACE_SIZE {
		return nil
	}
	return endpoint.region[int(place) * PLACE_SIZE:][:PLACE_SIZE]
}

// data_bytes returns the payload slice after the UDP header for a valid place
// index, or nil if place is out of range.
data_bytes :: proc "contextless" (endpoint: ^Endpoint, place: u32) -> []u8 {
	buf := place_bytes(endpoint, place)
	if len(buf) < network.UDP_HEADER {
		return nil
	}
	return buf[network.UDP_HEADER:]
}

// command_push_or_hold writes a command directly into the datagram command
// ring when nothing is held and room exists; otherwise it queues the command
// in order. When the held queue is at capacity, it refuses the command,
// increments held_overflows, and invokes on_held_overflow if set.
command_push_or_hold :: proc "contextless" (endpoint: ^Endpoint, record: ring.Record) -> bool {
	if endpoint == nil || endpoint.datagrams.head == nil {
		return false
	}
	if endpoint.held_command_count == 0 && ring.push(&endpoint.datagrams.commands, record) {
		return true
	}
	if endpoint.held_command_count >= endpoint.held_capacity {
		endpoint.held_overflows += 1
		if endpoint.on_held_overflow != nil {
			endpoint.on_held_overflow()
		}
		return false
	}
	endpoint.held_commands[endpoint.held_command_count] = record
	endpoint.held_command_count += 1
	return true
}

// held_commands_push drains as many held commands as fit into the datagram
// command ring while preserving FIFO order. Returns the number pushed.
held_commands_push :: proc "contextless" (endpoint: ^Endpoint) -> int {
	if endpoint == nil || endpoint.datagrams.head == nil || endpoint.held_command_count == 0 {
		return 0
	}
	done := 0
	for done < endpoint.held_command_count && ring.push(&endpoint.datagrams.commands, endpoint.held_commands[done]) {
		done += 1
	}
	if done > 0 {
		copy(endpoint.held_commands[:], endpoint.held_commands[done:endpoint.held_command_count])
		endpoint.held_command_count -= done
	}
	return done
}

// post_receive posts a Receive command for an idle receive place index and
// marks it in flight. Refuses out-of-range places or places already in flight.
post_receive :: proc "contextless" (endpoint: ^Endpoint, place: u32) -> bool {
	if endpoint == nil || place >= u32(endpoint.receive_places) {
		return false
	}
	if endpoint.place_in_flight[place] {
		return false
	}
	if !command_push_or_hold(
		endpoint,
		ring.Record{kind = u32(datagram.Command.Receive), tag = place, values = {0 = u64(place) * PLACE_SIZE, 1 = PLACE_SIZE}},
	) {
		return false
	}
	endpoint.place_in_flight[place] = true
	return true
}

// endpoint_post_receives posts all initial receive places 0 ..< receive_places.
endpoint_post_receives :: proc "contextless" (endpoint: ^Endpoint) -> bool {
	if endpoint == nil || endpoint.receive_places <= 0 {
		return false
	}
	for place in 0 ..< endpoint.receive_places {
		if !post_receive(endpoint, u32(place)) {
			return false
		}
	}
	return true
}

// endpoint_wake wakes the network service to read pending commands.
endpoint_wake :: proc "contextless" (endpoint: ^Endpoint) {
	if endpoint != nil && endpoint.datagrams.head != nil {
		system.wake_reader(&endpoint.datagrams.commands)
	}
}

// place_take pops one free send place index and marks it in flight.
place_take :: proc "contextless" (endpoint: ^Endpoint) -> (place: u32, ok: bool) {
	if endpoint == nil || endpoint.free_count <= 0 {
		return 0, false
	}
	endpoint.free_count -= 1
	place = endpoint.free_places[endpoint.free_count]
	endpoint.place_in_flight[place] = true
	return place, true
}

// place_return returns an in-flight send place index to the free stack.
// Refuses receive places, out-of-range places, places not currently in
// flight, or a full free stack so a duplicate or forged completion can never
// double-free a DMA send slot.
place_return :: proc "contextless" (endpoint: ^Endpoint, place: u32) -> bool {
	if endpoint == nil {
		return false
	}
	if place < u32(endpoint.receive_places) || place >= PLACE_COUNT {
		return false
	}
	if !endpoint.place_in_flight[place] {
		return false
	}
	send_capacity := PLACE_COUNT - endpoint.receive_places
	if endpoint.free_count >= send_capacity {
		return false
	}
	endpoint.place_in_flight[place] = false
	endpoint.free_places[endpoint.free_count] = place
	endpoint.free_count += 1
	return true
}

// send_datagram writes the UDP header and checksum for payload length bytes
// already placed at data_bytes(endpoint, place), then pushes a Send command.
// Refuses places not in flight, out-of-range payload lengths (including past
// network.UDP_DATA_LIMIT), or any udp_header_write failure without emitting a
// Send record.
send_datagram :: proc "contextless" (endpoint: ^Endpoint, place: u32, length: int, peer: quic.Remote) -> bool {
	if endpoint == nil || place < u32(endpoint.receive_places) || place >= PLACE_COUNT {
		return false
	}
	if !endpoint.place_in_flight[place] {
		return false
	}
	if length < 0 || length > network.UDP_DATA_LIMIT || length > PLACE_SIZE - network.UDP_HEADER {
		return false
	}
	buf := place_bytes(endpoint, place)
	if buf == nil {
		return false
	}
	whole := network.udp_header_write(buf, endpoint.local_address, peer.address, endpoint.listen_port, peer.port, length)
	if whole == 0 {
		return false
	}
	return command_push_or_hold(
		endpoint,
		ring.Record{
			kind = u32(datagram.Command.Send),
			tag = SEND_TAG + place,
			values = {0 = u64(place) * PLACE_SIZE, 1 = u64(whole), 2 = u64(peer.address)},
		},
	)
}

// validate_tag_pack packs a record place and the low generation bits into a
// Validate ring tag. Refuses places outside 0 ..< MAX_CAPACITY.
validate_tag_pack :: proc "contextless" (place: int, generation: u64) -> (tag: u32, ok: bool) {
	if place < 0 || place >= MAX_CAPACITY {
		return 0, false
	}
	return VALIDATE_TAG | u32(generation & VALIDATE_GENERATION_MASK) << VALIDATE_PLACE_BITS | u32(place), true
}

// validate_tag_unpack decodes a Validate ring tag into its record place and
// masked generation bits. Refuses any tag without VALIDATE_TAG set.
validate_tag_unpack :: proc "contextless" (tag: u32) -> (place: int, generation_bits: u64, ok: bool) {
	if tag & VALIDATE_TAG == 0 {
		return 0, 0, false
	}
	place = int(tag & ((1 << VALIDATE_PLACE_BITS) - 1))
	generation_bits = u64(tag & ~VALIDATE_TAG) >> VALIDATE_PLACE_BITS
	return place, generation_bits, true
}

// validate_remote asks the network service to lift the amplification limit
// for peer, tagging the request with place and generation.
validate_remote :: proc "contextless" (endpoint: ^Endpoint, peer: quic.Remote, place: int, generation: u64) -> bool {
	if endpoint == nil || place < 0 || place >= endpoint.record_capacity {
		return false
	}
	tag, ok := validate_tag_pack(place, generation)
	if !ok {
		return false
	}
	return command_push_or_hold(
		endpoint,
		ring.Record{kind = u32(datagram.Command.Validate), tag = tag, values = {0 = u64(peer.address), 1 = u64(peer.port)}},
	)
}

// validation_completed checks a Validate completion against the current
// record at its place and generation, and reports confirmed validation to the
// QUIC server. Returns true when a live matching record was updated.
validation_completed :: proc "contextless" (server: ^quic.Server, records: []quic.Server_Record, completion: ring.Record) -> bool {
	place, generation_bits, tag_ok := validate_tag_unpack(completion.tag)
	if !tag_ok || place < 0 || place >= len(records) {
		return false
	}
	status, _ := call_outcome.completion_outcome(completion.kind, completion.values)
	if status == .Answer_Unreadable {
		return false
	}
	record := records[place]
	if !record.in_use || (record.generation & VALIDATE_GENERATION_MASK) != generation_bits {
		return false
	}
	if server != nil {
		quic.server_validation_confirmed(server, place, record.generation, status == .Succeeded && completion.values[0] == 1)
	}
	return true
}

// release_remote asks the network service to forget an admitted remote.
release_remote :: proc "contextless" (endpoint: ^Endpoint, peer: quic.Remote) -> bool {
	if endpoint == nil {
		return false
	}
	return command_push_or_hold(
		endpoint,
		ring.Record{kind = u32(datagram.Command.Release), tag = CALL_TAG, values = {0 = u64(peer.address), 1 = u64(peer.port)}},
	)
}

// completions_drain_bounded drains at most one turn's worth of completions
// (bounded by system.records_of_turn) without issuing any kernel wake.
@(private)
completions_drain_bounded :: proc "contextless" (
	endpoint: ^Endpoint,
	server: ^quic.Server,
	records: []quic.Server_Record,
	arrived: []ring.Record,
) -> (count: int, popped: int) {
	if endpoint == nil || endpoint.datagrams.head == nil {
		return 0, 0
	}
	held_commands_push(endpoint)
	turn_limit := system.records_of_turn(&endpoint.datagrams.completions)
	for _ in 0 ..< turn_limit {
		record, has := ring.pop(&endpoint.datagrams.completions)
		if !has {
			break
		}
		popped += 1
		status, _ := call_outcome.completion_outcome(record.kind, record.values)
		status_ok := status != .Answer_Unreadable
		switch {
		case record.tag < u32(endpoint.receive_places):
			if !endpoint.place_in_flight[record.tag] {
				endpoint.bad_completions += 1
				continue
			}
			endpoint.place_in_flight[record.tag] = false
			if status == .Succeeded {
				if count < len(arrived) {
					arrived[count] = record
					count += 1
				} else {
					endpoint.arrivals_dropped += 1
					post_receive(endpoint, record.tag)
				}
			} else {
				if !status_ok {
					endpoint.bad_completions += 1
				}
				post_receive(endpoint, record.tag)
			}
		case record.tag & VALIDATE_TAG != 0:
			if !status_ok {
				endpoint.bad_completions += 1
			} else {
				validation_completed(server, records, record)
			}
		case record.tag >= SEND_TAG && record.tag < SEND_TAG + PLACE_COUNT:
			place := record.tag - SEND_TAG
			if !place_return(endpoint, place) {
				endpoint.bad_completions += 1
				continue
			}
			if status != .Succeeded {
				endpoint.sends_refused += 1
				endpoint.send_refusal_last = record.kind
			}
		case record.tag == CALL_TAG:
			if !status_ok {
				endpoint.bad_completions += 1
			}
		case:
			endpoint.bad_completions += 1
		}
	}
	return count, popped
}

// completions_drain_queue drains up to one turn of completions without
// issuing any kernel wake: pushes held commands, collects arrived Receive
// records into arrived, applies Validate completions, and returns completed
// in-flight Send places.
completions_drain_queue :: proc "contextless" (
	endpoint: ^Endpoint,
	server: ^quic.Server,
	records: []quic.Server_Record,
	arrived: []ring.Record,
) -> (count: int) {
	count, _ = completions_drain_bounded(endpoint, server, records, arrived)
	return count
}

// completions_drain drains up to one turn of completions and wakes the
// network service only when at least one completion was popped.
completions_drain :: proc "contextless" (
	endpoint: ^Endpoint,
	server: ^quic.Server,
	records: []quic.Server_Record,
	arrived: []ring.Record,
) -> (count: int) {
	popped: int
	count, popped = completions_drain_bounded(endpoint, server, records, arrived)
	if popped > 0 && endpoint != nil && endpoint.datagrams.head != nil {
		system.wake_writer(&endpoint.datagrams.completions)
	}
	return count
}

// exchange runs one full QUIC server pass over the arrived datagram records:
// validates receive tags, field ranges, and UDP framing, orders known
// connections before new handshakes, feeds datagrams to the QUIC server,
// advances timers, runs up to SEND_ROUNDS of application work and outgoing
// datagram sends, sweeps ended connections, and reposts valid arrived receive
// places.
exchange :: proc "contextless" (
	endpoint: ^Endpoint,
	server: ^quic.Server,
	records: []quic.Server_Record,
	arrived: []ring.Record,
	now_microseconds: u64,
	work: proc "contextless" () = nil,
) -> (deadline: u64) {
	if endpoint == nil || server == nil {
		return max(u64)
	}
	batch: [RECEIVE_PLACES_LIMIT]quic.Server_Datagram
	batch_count := 0
	for record in arrived {
		if batch_count >= RECEIVE_PLACES_LIMIT {
			break
		}
		if record.tag >= u32(endpoint.receive_places) {
			endpoint.datagrams_malformed += 1
			continue
		}
		if record.values[1] < network.UDP_HEADER || record.values[1] > PLACE_SIZE || record.values[2] > u64(max(u32)) || record.values[3] > u64(max(u16)) {
			endpoint.datagrams_malformed += 1
			continue
		}
		buf := place_bytes(endpoint, record.tag)
		if buf == nil {
			endpoint.datagrams_malformed += 1
			continue
		}
		// QUIC authenticates every packet; skipping UDP checksum verification
		// avoids a redundant pass over payload bytes.
		data, whole := network.udp_data_read(buf[:record.values[1]], u32(record.values[2]), endpoint.local_address, .Do_Not_Verify)
		if !whole {
			endpoint.datagrams_malformed += 1
			continue
		}
		batch[batch_count] = {data, quic.Remote{u32(record.values[2]), u16(record.values[3])}}
		batch_count += 1
	}
	order: [RECEIVE_PLACES_LIMIT]int
	count := quic.server_batch_order(server, batch[:batch_count], order[:])
	for index in order[:count] {
		bytes, peer := batch[index].bytes, batch[index].remote
		answer_place, has_place := place_take(endpoint)
		answer: []u8
		if has_place {
			answer = data_bytes(endpoint, answer_place)
		}
		outcome := quic.server_datagram_receive(server, bytes, peer, answer, now_microseconds)
		if outcome.answer_length > 0 && has_place {
			if !send_datagram(endpoint, answer_place, outcome.answer_length, peer) {
				place_return(endpoint, answer_place)
			}
		} else if has_place {
			place_return(endpoint, answer_place)
		}
		if outcome.validate_remote && outcome.record >= 0 && outcome.record < len(records) {
			validate_remote(endpoint, peer, outcome.record, records[outcome.record].generation)
		}
		if outcome.release_remote {
			release_remote(endpoint, peer)
		}
	}
	quic.server_time_passes(server, now_microseconds)
	for _ in 0 ..< SEND_ROUNDS {
		if work != nil {
			work()
		}
		sent := 0
		for endpoint.free_count > 0 {
			place, has := place_take(endpoint)
			if !has {
				break
			}
			length, peer := quic.server_datagram_send(server, data_bytes(endpoint, place), now_microseconds)
			if length <= 0 {
				place_return(endpoint, place)
				break
			}
			if !send_datagram(endpoint, place, length, peer) {
				place_return(endpoint, place)
				break
			}
			sent += 1
		}
		if sent == 0 {
			break
		}
	}
	ended: [MAX_CAPACITY]quic.Remote
	ended_count := quic.server_sweep(server, ended[:min(len(records), MAX_CAPACITY)])
	for peer in ended[:ended_count] {
		release_remote(endpoint, peer)
	}
	for record in arrived {
		if record.tag < u32(endpoint.receive_places) {
			post_receive(endpoint, record.tag)
		}
	}
	return quic.server_deadline(server)
}

// hex_text formats bytes as lowercase hexadecimal digits into buffer.
hex_text :: proc "contextless" (buffer: []u8, bytes: []u8) -> string {
	digits := "0123456789abcdef"
	count := 0
	for byte in bytes {
		if count + 2 > len(buffer) {
			break
		}
		buffer[count], buffer[count + 1] = digits[byte >> 4], digits[byte & 0x0F]
		count += 2
	}
	return string(buffer[:count])
}

// address_text formats an IPv4 address and UDP port into buffer as
// "<a.b.c.d> port <p>".
address_text :: proc "contextless" (buffer: []u8, peer: quic.Remote) -> string {
	output := system.Writer{buffer = buffer}
	network.address_write(&output, peer.address)
	system.write_bytes(&output, transmute([]u8)string(" port "))
	system.write_unsigned(&output, u64(peer.port))
	return system.written(&output)
}

// log_allowed enforces a per-second log line budget. Returns false when
// limit is 0 or already exceeded in the current second.
log_allowed :: proc "contextless" (budget: ^Log_Budget, now_milliseconds: u64) -> bool {
	if budget == nil || budget.limit == 0 {
		return false
	}
	second := now_milliseconds / 1000
	if second != budget.second {
		budget.second, budget.count = second, 0
	}
	if budget.count >= budget.limit {
		return false
	}
	budget.count += 1
	return true
}
