// The network service: the one client of the frame service of the network
// device, and the service that gives each process with the grant one
// endpoint of datagrams (src/library/modus/contract/datagram).
//
// It speaks Ethernet, ARP, IPv4 and ICMP echo (request and answer), with
// the protocol library src/library/modus/network: this process does the input and
// output, the library reads and writes the frames. UDP and TCP are in the
// process that holds the endpoint: this service reads the header of a
// datagram or a segment, never its data. It has one static address
// (10.0.2.15/24, the gateway 10.0.2.2: the network of QEMU).
//
// The root service names the grant of each endpoint. A datagram endpoint
// reaches one remote address and one remote UDP port, or listens on one
// local UDP port and answers the remotes that came to it. A segment endpoint
// (TCP) has a client grant (one remote, from a block of local TCP ports) or
// a listen grant (one local TCP port, and the remotes that sent a segment
// to it). A request to another remote is refused with the detail of the
// grant; a datagram or a segment from another remote does not reach the
// process. TCP itself is in the process (src/library/modus/tcp), and so are the
// header and the checksum of UDP (src/library/modus/network, udp_header_write and
// udp_data_read): this service checks the IPv4 header, the lengths and the
// ports of each datagram and each segment, computes no checksum of their
// bytes, and keeps no state of a connection
// (docs/NETWORK.md, "The path of a datagram and of a segment").
//
// One thread. It waits on the completions of the frame ring, on the
// control ring of the root service, and on the command queue of each
// endpoint, with the deadline of the oldest request that waits for an
// answer. A datagram or a segment that arrives is copied one time, from
// the frame region to the datagram region of the process: the one pass of
// this service over its bytes. One that leaves is not copied: this service
// copies its first 8 bytes (the ports, and the length of UDP) into the
// frame for the check, writes the headers of IPv4 and Ethernet before them,
// and the device reads the rest from the datagram region, which the frame
// service holds as a read region (src/md/infrastructure/network_data_path.md,
// "The send with no copy"). The service counts the bytes of each pass, for
// each endpoint and each direction, and writes the counts when the endpoint
// ends. The kernel is not on the path of the data, so data moves with no
// kernel entry.
//
// **What it is for.** It is the one place where the frames of the machine
// meet the grants of the processes. A process never sees a frame and never
// names an address that its grant does not hold, so a process with a
// network grant reaches one remote, or answers on one port, and nothing
// else. A process writes the header of what it sends; this service checks
// the ports of that header in its own copy, so a process sends only from
// the local ports of its endpoint.
//
// **Start**: no line starts it. The root service starts it, with the frame
// service of the device, before the first process with the grant
// **Network** (net, server, fetch, quic_echo, remote).
//
// **Grants**, as the root service gives them:
//
// - **Network_Device**: the frame ring of the frame service of the network
//   device, the frame service with the right Read, and a control ring from
//   the root service. The root service
//   sends on the control ring the endpoint of each process that it starts
//   with the grant **Network**, with the grant of that endpoint.
//
// **What a reader sees**: no window. The log has "network: ok, the address
// 10.0.2.15/24 ..., the gateway 10.0.2.2, the link is up, ...", then the
// cost of the headers of IPv4 and Ethernet of one frame. When an endpoint
// ends, the log has its counts, and how many times this service read each
// byte of its datagrams or segments: one time on receive; on send, 8 bytes
// of each header and no byte of the data.
// A process reads its own counts and problem rows through its endpoint;
// a process with the grant to inspect the machine also reads the counts of
// the whole service.
//
// **What it does not do**: no DHCP and no DNS (the address is static), no
// fragments of IPv4 (a fragment is a problem `Unsupported`), and no state
// of a TCP connection.
//
// The design: `docs/NETWORK.md`,
// (docs/NETWORK.md, "The path of a datagram and of a segment") and
// (docs/NETWORK.md, "The listen grant of UDP").
package network_service

import "base:intrinsics"
import "modus:contract/byte_order"
import "modus:contract/datagram"
import "modus:contract/errors"
import "modus:contract/frame"
import "modus:contract/ring"
import "modus:contract/value_kinds"
import "modus:network"
import "modus:system"

LOCAL_ADDRESS :: 0x0A00020F // 10.0.2.15
GATEWAY_ADDRESS :: 0x0A000202 // 10.0.2.2
PREFIX :: 24
NETWORK_MASK :: 0xFFFF_FF00 // The prefix of 24 bits.

PLACE_COUNT :: 256 // The places of the frame region, frame.PLACE_SIZE bytes each.
RECEIVE_PLACES :: 128 // Places 0 to 127: frames that arrive. 128 to 255: frames to send.
REGION_PAGES :: PLACE_COUNT * frame.PLACE_SIZE / system.PAGE_SIZE

ENDPOINT_CAPACITY :: 8
RECEIVE_CAPACITY :: 128 // The Receive requests of one endpoint that wait at the same time.
PORT_FIRST :: 49152 // The local UDP port of endpoint n is PORT_FIRST + n.
TCP_PORT_FIRST :: 50176 // A client grant of endpoint n: the local TCP ports from TCP_PORT_FIRST + n * datagram.PORT_BLOCK.
ECHO_IDENTIFIER :: 0x6E00 // The identifier of an echo request of endpoint n is ECHO_IDENTIFIER + n.
ANSWER_TIME :: 1000 // Milliseconds for an answer of ARP or of an echo.
TCP_SYN :: 0x02 // Flags of the byte 13 of a TCP header.
TCP_RST :: 0x04
TCP_ACK :: 0x10
PENDING_CAPACITY :: 64

// The tags of the frame ring: a place for Receive and Send.
TAG_ATTACH :: 1000
TAG_INFO :: 1001
TAG_STATISTICS :: 1002
TAG_READ_REGION_ADD :: 1100 // + the place of the endpoint.
TAG_READ_REGION_REMOVE :: 1200 // + the place of the endpoint.

// The bytes of a datagram or a segment to send that this service copies
// into the frame: the two ports and the length field of UDP, which the
// check reads. For TCP: the two ports and the sequence number. The device
// reads the rest from the datagram region.
SEND_HEADER_COPIED :: 8

// A request that the process sent and that waits for the wire.
Pending_Kind :: enum u8 {
	None,
	Send, // The frame is in a send place; it waits for the hardware address.
	Resolve,
	Echo, // Before the echo request: it waits for the hardware address.
	Echo_Sent, // It waits for the echo reply.
	Statistics, // It waits for the statistics of the frame service.
}

Pending :: struct {
	kind:       Pending_Kind,
	endpoint:   int,
	tag:        u32,
	address:    u32, // The address that must answer: the next hop for Send and Echo.
	target:     u32, // The address of the request.
	deadline:   u64,
	start:      u64,
	place:      int, // Send: the send place.
	bytes:      int, // Echo: the bytes of data.
	length:     int, // Send: the bytes of the datagram or the segment.
	data_place: u64, // Send: its place in the datagram region.
	sequence:   u16, // Echo.
}

// What this service did to the datagrams or the segments of one endpoint in
// one direction. bytes_passed counts each byte one time for each pass of
// this service over it: a copy, or a sum for a checksum. With one copy and
// no checksum, bytes_passed is payload_bytes. data_bytes_read counts the
// bytes of those passes that are after the least header of UDP or TCP:
// bytes of the data.
Data_Count :: struct {
	units:           u64, // The datagrams or the segments.
	payload_bytes:   u64, // Their bytes: the header of UDP or TCP, and the data.
	bytes_passed:    u64, // The bytes that this service read, one count for each pass.
	data_bytes_read: u64, // The bytes of the data among them.
}

// The owner of a frame in a send place: the Send of a process, which
// completes when the frame service completes the frame, because the device
// reads the data of the process until then.
Send_Owner :: struct {
	busy:     bool,
	endpoint: int,
	tag:      u32,
}

Posted :: struct {
	tag:   u32,
	place: u64,
	room:  u64,
}

Endpoint :: struct {
	ring_memory:     system.Handle, // 0: the place is free.
	datagram_ring:   ring.Ring,
	region_memory:   system.Handle,
	region:          []u8,
	grant:           datagram.Grant, // All zero: no grant (a revocation).
	tcp:             bool, // A segment endpoint. It stays after a revocation.
	listen:          bool, // Its local port is a listen port that its creation named. It stays after a revocation, as its port does.
	local_port:      u16, // The first local port.
	port_count:      u16, // 1, or datagram.PORT_BLOCK for a client grant of TCP.
	admitted:        network.Admitted, // A listen grant: the remotes that sent a segment to its port.
	name:            system.Name,
	posted:          [RECEIVE_CAPACITY]Posted,
	posted_first:    int,
	posted_count:    int,
	in_flight:       u32, // Commands taken that have no completion yet.
	held:            ring.Record, // A Send that waits for a free send place.
	has_held:        bool,
	changed:         bool, // A completion was written: wake the process.
	sent:            u64,
	received:        u64,
	dropped:         u64,
	arrived_data:    Data_Count, // What this service did to the bytes that it gave to the process.
	left_data:       Data_Count, // What it did to the bytes that it took from the process.
	// The datagrams that reached the local port of this endpoint from a
	// remote that its grant does not name: facts of this endpoint only.
	problems:        network.Problem_Table,
}

frames: ring.Ring
frames_memory: system.Handle
frames_changed: bool // A command was written in the frame ring: wake the frame service.
// The frame service, with the right Read: its stop is an event of this
// process (frame.GRANT_SERVICE). The loop reads its state again only after
// an event, so a pass costs no kernel call while it runs.
frame_service: system.Handle
frame_service_events: u32
frame_service_state_read: bool // Until the first read in the loop, the state is not known.
region: []u8
free_sends: [PLACE_COUNT - RECEIVE_PLACES]int
free_send_count: int
send_owners: [PLACE_COUNT - RECEIVE_PLACES]Send_Owner // By send place - RECEIVE_PLACES.
hardware: network.Hardware
link_up: bool
control: ring.Ring
control_memory: system.Handle
endpoints: [ENDPOINT_CAPACITY]Endpoint
pending: [PENDING_CAPACITY]Pending
neighbors: network.Neighbors
identification: u16

// The facts of the machine: an endpoint reads them only with the right
// Inspect of its grant: they tell of the traffic of other processes, and a
// process sees no other process.
answered: u64 // Echo requests from the wire that this service answered.
machine_problems: network.Problem_Table // The frames that no endpoint owns.

fail :: proc "contextless" (text: string) -> ! {
	system.log_fact(.Error, Service_Failed{failure = value_kinds.text_field(text, FAILURE_FIELD_BYTES)})
	system.stop(.Failed)
}

place_bytes :: proc "contextless" (place: int) -> []u8 {
	return region[place * frame.PLACE_SIZE:][:frame.PLACE_SIZE]
}

frame_command :: proc "contextless" (command: frame.Command, tag: u32, values: [7]u64 = {}) {
	if !ring.push(&frames.commands, ring.Record{kind = u32(command), tag = tag, values = values}) {
		// The accounting of the places keeps room: this does not happen.
		system.log_fact(.Error, Frame_Ring_Full{})
	}
	frames_changed = true
}

frame_receive :: proc "contextless" (place: int) {
	frame_command(.Receive, u32(place), {0 = u64(place * frame.PLACE_SIZE), 1 = frame.PLACE_SIZE})
}

send_place_take :: proc "contextless" () -> (place: int, ok: bool) {
	if free_send_count == 0 {
		return 0, false
	}
	free_send_count -= 1
	return free_sends[free_send_count], true
}

send_place_free :: proc "contextless" (place: int) {
	free_sends[free_send_count] = place
	free_send_count += 1
}

// frame_send gives a frame of a send place to the frame service.
frame_send :: proc "contextless" (place: int, length: int) {
	frame_command(.Send, u32(place), {0 = u64(place * frame.PLACE_SIZE), 1 = u64(length)})
}

next_identification :: proc "contextless" () -> u16 {
	identification += 1
	return identification
}

// next_hop gives the address whose hardware address a frame to address needs.
next_hop :: proc "contextless" (address: u32) -> u32 {
	return address & NETWORK_MASK == LOCAL_ADDRESS & NETWORK_MASK ? address : GATEWAY_ADDRESS
}

neighbor_of :: proc "contextless" (address: u32) -> (hardware: network.Hardware, ok: bool) {
	return network.neighbor_find(&neighbors, address)
}

// neighbor_answer takes an ARP frame from address: the table learns it only
// if a request of this service waits for it (network.neighbor_learn). It
// says if a request asked for it.
neighbor_answer :: proc "contextless" (address: u32, found: network.Hardware, now: u64) -> (asked: bool) {
	busy: [PENDING_CAPACITY]u32
	busy_count := 0
	for item in pending {
		if item.kind == .None {
			continue
		}
		busy[busy_count] = item.address
		busy_count += 1
		if item.address == address && (item.kind == .Send || item.kind == .Resolve || item.kind == .Echo) {
			asked = true
		}
	}
	network.neighbor_learn(&neighbors, address, found, now, asked, busy[:busy_count])
	return asked
}

// arp_request sends a request for the hardware address of address.
arp_request :: proc "contextless" (address: u32) {
	place, ok := send_place_take()
	if !ok {
		return // The request that waits ends without an answer.
	}
	length := network.arp_frame(place_bytes(place), network.ARP_REQUEST, hardware, LOCAL_ADDRESS, {}, address)
	frame_send(place, length)
}

complete :: proc "contextless" (endpoint: ^Endpoint, tag: u32, status: datagram.Status, values: [7]u64 = {}) {
	ring.push(&endpoint.datagram_ring.completions, ring.Record{kind = u32(status), tag = tag, values = values})
	endpoint.changed = true
}

// complete_taken completes a command that was in flight.
complete_taken :: proc "contextless" (endpoint: ^Endpoint, tag: u32, status: datagram.Status, values: [7]u64 = {}) {
	endpoint.in_flight -= 1
	complete(endpoint, tag, status, values)
}

pending_add :: proc "contextless" (item: Pending) -> bool {
	for &slot in pending {
		if slot.kind == .None {
			slot = item
			return true
		}
	}
	return false
}

// problem counts a refused frame that no endpoint owns: a fact of the machine.
problem :: proc "contextless" (found: datagram.Problem) {
	network.problem_count(&machine_problems, found, .Machine)
}

// payload_send builds the frame of a datagram or a segment of length bytes,
// for a next hop with a known hardware address, and sends it. The send
// place holds the copy of its first SEND_HEADER_COPIED bytes; the rest is
// at data_place + SEND_HEADER_COPIED in the datagram region, where the
// device reads it. The process wrote the header of UDP or TCP and its
// checksum: this service writes the headers of IPv4 and Ethernet, and
// reads no byte of the data. The Send of the process completes with the
// frame (Send_Owner).
payload_send :: proc "contextless" (endpoint: ^Endpoint, index: int, tag: u32, place: int, destination: network.Hardware, address: u32, length: int, data_place: u64) {
	protocol := u8(endpoint.tcp ? network.PROTOCOL_TCP : network.PROTOCOL_UDP)
	// The length that ipv4_frame gives counts zero bytes after a short
	// frame; the device adds those itself after the second part, so the
	// first part ends after the copy of the header.
	network.ipv4_frame(place_bytes(place), destination, hardware, LOCAL_ADDRESS, address, protocol, length, next_identification())
	headers := network.IPV4_DATA + SEND_HEADER_COPIED
	frame_command(.Send, u32(place), {0 = u64(place * frame.PLACE_SIZE), 1 = u64(headers), 2 = data_place + SEND_HEADER_COPIED, 3 = u64(length - SEND_HEADER_COPIED), 4 = u64(index)})
	send_owners[place - RECEIVE_PLACES] = {busy = true, endpoint = index, tag = tag}
	endpoint.sent += 1
}

// data_pass counts one pass of this service over bytes of a datagram or a
// segment. Each place of this process that reads those bytes calls it, so
// the count says how many times the service is on the path of the data.
// data_bytes: the bytes of that pass after the least header of UDP or TCP.
data_pass :: proc "contextless" (count: ^Data_Count, bytes: int, data_bytes: int) {
	count.bytes_passed += u64(bytes)
	count.data_bytes_read += u64(data_bytes)
}

// header_least gives the bytes of the least header of the transport of an
// endpoint: the bytes of a pass after it are bytes of the data.
header_least :: proc "contextless" (endpoint: ^Endpoint) -> int {
	return endpoint.tcp ? datagram.SEGMENT_LEAST : datagram.UDP_HEADER
}

// data_counted counts one datagram or one segment that this service handled.
data_counted :: proc "contextless" (count: ^Data_Count, bytes: int) {
	count.units += 1
	count.payload_bytes += u64(bytes)
}

echo_send :: proc "contextless" (endpoint_index: int, destination: network.Hardware, address: u32, sequence: u16, bytes: int) -> bool {
	place := send_place_take() or_return
	frame_bytes := place_bytes(place)
	for index in 0 ..< bytes {
		frame_bytes[network.ICMP_DATA + index] = u8(index)
	}
	length := network.echo_frame(frame_bytes, destination, hardware, LOCAL_ADDRESS, address, network.ICMP_ECHO_REQUEST, u16(ECHO_IDENTIFIER + endpoint_index), sequence, bytes, next_identification())
	frame_send(place, length)
	return true
}

// region_range checks that count bytes at place are in the region of an endpoint.
region_range :: proc "contextless" (endpoint: ^Endpoint, place, count: u64) -> bool {
	size := u64(len(endpoint.region))
	return place <= size && count <= size - place
}

// granted checks a remote against the grant of an endpoint, and completes
// the command with the detail of a refusal. A listen grant names no remote:
// a datagram or a segment goes to an admitted remote only (header_granted).
granted :: proc "contextless" (endpoint: ^Endpoint, tag: u32, address: u64, port: u64, check_port: bool, command: u32, argument: i64) -> bool {
	grant := endpoint.grant
	if !grant.listen && grant.address != 0 && address == u64(grant.address) && (!check_port || port == u64(grant.port)) {
		return true
	}
	complete(endpoint, tag, .Not_Granted, not_granted(command, argument, u32(address), u16(port), grant_remote(grant)))
	return false
}

// grant_remote gives the remote of a grant (errors.Unit.Endpoint): 0 when
// it names none.
grant_remote :: proc "contextless" (grant: datagram.Grant) -> i64 {
	return grant.listen || grant.address == 0 ? 0 : errors.endpoint_pack(grant.address, grant.port)
}

// not_granted gives the values of the error record of a remote that the
// grant does not name.
not_granted :: proc "contextless" (command: u32, argument: i64, address: u32, port: u16, granted: i64, local: u16 = 0) -> [7]u64 {
	return errors.ring_fail(command, .No_Grant, .Endpoint, argument, errors.endpoint_pack(address, port), granted, i64(local))
}

// header_granted checks a datagram or a segment of count bytes to send, in
// the copy of its first SEND_HEADER_COPIED bytes that this service made
// (header): the process cannot change that copy, and this procedure reads
// no byte of the region of the process. The two ports are at the same
// place in the header of UDP and of TCP.
//
// - The source port is a local port of the endpoint: a process sends from
//   its own ports only.
// - The remote (the address of the command, which goes in the IPv4 header
//   that this service writes, and the destination port of the copy) is the
//   remote of a client grant, or an admitted remote of a listen grant.
// - A datagram: its length field is its count of bytes, and a UDP listen
//   grant sends to a remote that did not prove its address at most 3 times
//   the bytes of data that came from it. A send does not keep a place of
//   the admitted remotes alive.
//
// The checksum is not checked: a wrong one harms only the packet of the
// process that wrote it.
header_granted :: proc "contextless" (endpoint: ^Endpoint, tag: u32, address: u32, header: []u8, count: int, now: u64) -> bool {
	SEND :: u32(datagram.Command.Send)
	local := byte_order.read_u16_big_endian(header, 0)
	port := byte_order.read_u16_big_endian(header, 2)
	grant := endpoint.grant
	in_block := local >= endpoint.local_port && local - endpoint.local_port < endpoint.port_count
	if !in_block {
		complete(endpoint, tag, .Not_Granted, not_granted(SEND, 3, address, port, grant_remote(grant), local))
		return false
	}
	if !endpoint.tcp {
		if length := byte_order.read_u16_big_endian(header, 4); int(length) != count {
			complete(endpoint, tag, .Bad_Command, errors.ring_fail(SEND, .Bad_Value, .Bytes, 2, i64(length), i64(count)))
			return false
		}
	}
	switch {
	case grant.listen && endpoint.tcp:
		if network.admitted_find(&endpoint.admitted, address, port, now) {
			return true
		}
		complete(endpoint, tag, .Not_Granted, not_granted(SEND, 3, address, port, 0))
	case grant.listen:
		allowed, admitted, send_limit, would_send := network.admitted_send_allowed(&endpoint.admitted, address, port, u64(count - network.UDP_HEADER))
		switch {
		case allowed:
			return true
		case !admitted:
			complete(endpoint, tag, .Not_Granted, not_granted(SEND, 3, address, port, 0))
		case:
			complete(endpoint, tag, .Amplification, errors.ring_fail(SEND, .Over_Limit, .Bytes, 2, i64(min(would_send, 1 << 62)), i64(min(send_limit, 1 << 62))))
		}
	case grant.address != 0 && address == grant.address && port == grant.port:
		return true
	case:
		complete(endpoint, tag, .Not_Granted, not_granted(SEND, 3, address, port, grant_remote(grant)))
	}
	return false
}

// command does one command of an endpoint. false: the command waits for a
// send place (it is held).
command :: proc "contextless" (endpoint: ^Endpoint, index: int, record: ring.Record, now: u64) -> bool {
	values := record.values
	tag := record.tag
	kind := record.kind
	// The process of the endpoint writes the word: a word that names no
	// command, and None, are refused with their record.
	command_kind, command_kind_ok := datagram.command_of_ring_word(record.kind)
	if !command_kind_ok {
		complete(endpoint, tag, .Bad_Command, errors.ring_fail(kind, .Unsupported, .None, 0, i64(kind)))
		return true
	}
	switch command_kind {
	case .None:
		// The border refused None above.
	case .Info:
		hardware_value: u64
		for byte, place in hardware {
			hardware_value |= u64(byte) << (8 * uint(place))
		}
		complete(endpoint, tag, .Ok, {LOCAL_ADDRESS, u64(endpoint.local_port), GATEWAY_ADDRESS, PREFIX, hardware_value, u64(link_up), datagram.grant_pack(endpoint.grant)})
	case .Send:
		place, count := values[0], values[1]
		if endpoint.region == nil {
			complete(endpoint, tag, .No_Region, errors.ring_fail(kind, .Absent, .Region))
			return true
		}
		if !region_range(endpoint, place, count) {
			complete(endpoint, tag, .Out_Of_Range, region_refusal(endpoint, kind, place, count))
			return true
		}
		limit := u64(endpoint.tcp ? datagram.SEGMENT_LIMIT : datagram.DATAGRAM_LIMIT)
		if count > limit {
			complete(endpoint, tag, .Too_Large, errors.ring_fail(kind, .Too_Long, .Bytes, 2, i64(count), i64(limit)))
			return true
		}
		least := u64(endpoint.tcp ? datagram.SEGMENT_LEAST : datagram.DATAGRAM_LEAST)
		if count < least {
			complete(endpoint, tag, .Bad_Command, errors.ring_fail(kind, .Too_Small, .Bytes, 2, i64(count), i64(least)))
			return true
		}
		if !link_up {
			complete(endpoint, tag, .Link_Down, errors.ring_fail(kind, .Link_Down))
			return true
		}
		send_place, ok := send_place_take()
		if !ok {
			return false
		}
		// The one pass of this service over the bytes: the copy of the
		// first SEND_HEADER_COPIED bytes, from the region of the process to
		// the frame. Each check of the header reads the copy, which the
		// process cannot change; the region is not read again. The device
		// reads the data from the region (payload_send).
		copied := place_bytes(send_place)[network.IPV4_DATA:][:SEND_HEADER_COPIED]
		copy(copied, endpoint.region[place:][:SEND_HEADER_COPIED])
		data_counted(&endpoint.left_data, int(count))
		data_pass(&endpoint.left_data, SEND_HEADER_COPIED, max(SEND_HEADER_COPIED - header_least(endpoint), 0))
		remote_address := u32(values[2])
		if !header_granted(endpoint, tag, remote_address, copied, int(count), now) {
			send_place_free(send_place)
			return true
		}
		hop := next_hop(remote_address)
		if destination, known := neighbor_of(hop); known {
			payload_send(endpoint, index, tag, send_place, destination, remote_address, int(count), place)
			endpoint.in_flight += 1
			return true
		}
		if !pending_add({kind = .Send, endpoint = index, tag = tag, address = hop, target = remote_address, deadline = now + ANSWER_TIME, start = now, place = send_place, length = int(count), data_place = place}) {
			send_place_free(send_place)
			complete(endpoint, tag, .Busy, busy(kind, PENDING_CAPACITY))
			return true
		}
		endpoint.in_flight += 1
		arp_request(hop)
	case .Receive:
		if endpoint.region == nil {
			complete(endpoint, tag, .No_Region, errors.ring_fail(kind, .Absent, .Region))
			return true
		}
		if !region_range(endpoint, values[0], values[1]) {
			complete(endpoint, tag, .Out_Of_Range, region_refusal(endpoint, kind, values[0], values[1]))
			return true
		}
		if endpoint.posted_count == RECEIVE_CAPACITY {
			complete(endpoint, tag, .Busy, errors.ring_fail(kind, .Busy, .Requests, 0, RECEIVE_CAPACITY, RECEIVE_CAPACITY))
			return true
		}
		endpoint.posted[(endpoint.posted_first + endpoint.posted_count) % RECEIVE_CAPACITY] = {tag = tag, place = values[0], room = values[1]}
		endpoint.posted_count += 1
		endpoint.in_flight += 1
	case .Resolve, .Echo:
		if !granted(endpoint, tag, values[0], 0, false, kind, 1) {
			return true
		}
		if command_kind == .Echo && values[2] > network.ICMP_DATA_LIMIT {
			complete(endpoint, tag, .Too_Large, errors.ring_fail(kind, .Too_Long, .Bytes, 3, i64(min(values[2], 1 << 62)), network.ICMP_DATA_LIMIT))
			return true
		}
		if !link_up {
			complete(endpoint, tag, .Link_Down, errors.ring_fail(kind, .Link_Down))
			return true
		}
		address := u32(values[0])
		hop := next_hop(address)
		item := Pending{kind = .Resolve, endpoint = index, tag = tag, address = hop, target = address, deadline = now + ANSWER_TIME, start = now, bytes = int(values[2]), sequence = u16(values[1])}
		destination, known := neighbor_of(hop)
		if command_kind == .Echo {
			item.kind = known ? .Echo_Sent : .Echo
		}
		if !pending_add(item) {
			complete(endpoint, tag, .Busy, busy(kind, PENDING_CAPACITY))
			return true
		}
		endpoint.in_flight += 1
		if item.kind == .Echo_Sent {
			echo_send(index, destination, address, item.sequence, item.bytes)
		} else {
			arp_request(hop) // Resolve asks again, also when the address is known.
		}
	case .Statistics:
		if !pending_add({kind = .Statistics, endpoint = index, tag = tag, deadline = now + ANSWER_TIME}) {
			complete(endpoint, tag, .Busy, busy(kind, PENDING_CAPACITY))
			return true
		}
		endpoint.in_flight += 1
		frame_command(.Statistics, TAG_STATISTICS)
	case .Problems:
		room := values[1]
		if room > u64(len(endpoint.region)) / size_of(datagram.Problem_Row) || !region_range(endpoint, values[0], room * size_of(datagram.Problem_Row)) {
			complete(endpoint, tag, .Out_Of_Range, region_refusal(endpoint, kind, values[0], min(room, 1 << 40) * size_of(datagram.Problem_Row)))
			return true
		}
		rows := ([^]datagram.Problem_Row)(raw_data(endpoint.region[values[0]:]))[:room]
		count := network.problem_rows(&endpoint.problems, &machine_problems, endpoint.grant.inspect, rows)
		complete(endpoint, tag, .Ok, {0 = u64(count)})
	case .Release:
		if !endpoint.grant.listen {
			complete(endpoint, tag, .Bad_Command, errors.ring_fail(kind, .Unsupported, .None, 0, i64(kind)))
			return true
		}
		released := network.admitted_release(&endpoint.admitted, u32(values[0]), u16(values[1]))
		complete(endpoint, tag, .Ok, {0 = u64(released)})
	case .Validate:
		if !endpoint.grant.listen || endpoint.tcp {
			complete(endpoint, tag, .Bad_Command, errors.ring_fail(kind, .Unsupported, .None, 0, i64(kind)))
			return true
		}
		validated := network.admitted_validate(&endpoint.admitted, u32(values[0]), u16(values[1]))
		complete(endpoint, tag, .Ok, {0 = u64(validated)})
	}
	return true
}

// region_refusal gives the values of the error record of a place that is
// not in the region of an endpoint.
region_refusal :: proc "contextless" (endpoint: ^Endpoint, command: u32, place, count: u64) -> [7]u64 {
	return errors.ring_fail(command, .Out_Of_Range, .Bytes, 1, i64(min(place, 1 << 62) + min(count, 1 << 62)), i64(len(endpoint.region)))
}

// busy gives the values of the error record of a full table of the
// requests that wait for an answer: the requests of all the endpoints are
// in it, so the record gives the capacity only: a count would tell of the
// requests of other processes.
busy :: proc "contextless" (command: u32, capacity: int) -> [7]u64 {
	return errors.ring_fail(command, .Busy, .Requests, 0, 0, i64(capacity))
}

// arrived reads one frame that the frame service received, in a receive place.
arrived :: proc "contextless" (place: int, length: int, now: u64) {
	bytes := place_bytes(place)[:min(length, frame.PLACE_SIZE)]
	packet, found := network.parse(bytes)
	if found.kind != .None {
		problem(found)
		return
	}
	switch packet.kind {
	case .None:
	case .Arp:
		if packet.target_address != LOCAL_ADDRESS {
			return // For another machine of the link.
		}
		asked := neighbor_answer(packet.sender_address, packet.sender_hardware, now)
		if packet.operation == network.ARP_REQUEST {
			if send_place, ok := send_place_take(); ok {
				total := network.arp_frame(place_bytes(send_place), network.ARP_REPLY, hardware, LOCAL_ADDRESS, packet.sender_hardware, packet.sender_address)
				frame_send(send_place, total)
			}
		}
		if asked {
			resolved(packet.sender_address, packet.sender_hardware, now)
		}
	case .Icmp:
		if packet.destination_address != LOCAL_ADDRESS {
			return
		}
		if packet.icmp_kind == network.ICMP_ECHO_REQUEST {
			// The answer goes to the hardware address that sent the request.
			send_place, ok := send_place_take()
			if !ok {
				return
			}
			reply := place_bytes(send_place)
			copy(reply[network.ICMP_DATA:], packet.data)
			total := network.echo_frame(reply, packet.source, hardware, LOCAL_ADDRESS, packet.source_address, network.ICMP_ECHO_REPLY, packet.identifier, packet.sequence, min(len(packet.data), network.ICMP_DATA_LIMIT), next_identification())
			frame_send(send_place, total)
			answered += 1
			return
		}
		for &item in pending {
			if item.kind == .Echo_Sent && item.target == packet.source_address && u16(ECHO_IDENTIFIER + item.endpoint) == packet.identifier && item.sequence == packet.sequence {
				complete_taken(&endpoints[item.endpoint], item.tag, .Ok, {0 = u64(packet.sequence), 1 = u64(len(packet.data)), 2 = u64(packet.ttl)})
				item = {}
				return
			}
		}
	case .Udp:
		if packet.destination_address != LOCAL_ADDRESS {
			return
		}
		endpoint := udp_endpoint_of(packet.destination_port)
		if endpoint == nil {
			problem({kind = .No_Endpoint, layer = .Udp, offset = network.ETHERNET_HEADER + network.IPV4_HEADER + 2, value = u32(packet.destination_port)})
			return
		}
		grant := endpoint.grant
		switch {
		case grant.listen:
			if !udp_remote_admitted(endpoint, packet, now) {
				return
			}
		case grant.address == 0 || packet.source_address != grant.address || packet.source_port != grant.port:
			network.problem_count(&endpoint.problems, {kind = .Not_Granted, layer = .Udp, offset = network.ETHERNET_HEADER + network.IPV4_HEADER, value = u32(packet.source_port), limit = u32(grant.port)}, .Endpoint)
			return
		}
		deliver(endpoint, packet)
	case .Tcp:
		if packet.destination_address != LOCAL_ADDRESS {
			return
		}
		// The endpoint of the local TCP port: a listen port, or a port of
		// the block of a client grant.
		endpoint: ^Endpoint
		for &item in endpoints {
			if item.ring_memory == 0 || !item.tcp {
				continue
			}
			if packet.destination_port >= item.local_port && packet.destination_port - item.local_port < item.port_count {
				endpoint = &item
				break
			}
		}
		if endpoint == nil {
			problem({kind = .No_Endpoint, layer = .Tcp, offset = network.ETHERNET_HEADER + network.IPV4_HEADER + 2, value = u32(packet.destination_port)})
			return
		}
		grant := endpoint.grant
		offset := u16(network.ETHERNET_HEADER + network.IPV4_HEADER)
		switch {
		case grant.listen:
			if network.admitted_find(&endpoint.admitted, packet.source_address, packet.source_port, now) {
				break
			}
			// A remote is admitted on a SYN only (no ACK, no RST): a stray
			// segment of an unknown remote takes no place, and the process
			// does not see it. And only from an address that can answer, and
			// only when a Receive waits for the SYN.
			if packet.tcp_flags & (TCP_SYN | TCP_RST | TCP_ACK) != TCP_SYN {
				network.problem_count(&endpoint.problems, {kind = .Not_Granted, layer = .Tcp, offset = offset, value = u32(packet.source_port), limit = u32(grant.port)}, .Endpoint)
				return
			}
			if !network.source_valid(packet.source_address, LOCAL_ADDRESS, NETWORK_MASK) {
				network.problem_count(&endpoint.problems, {kind = .Bad_Header, layer = .Ipv4, offset = network.ETHERNET_HEADER + 12, value = packet.source_address}, .Endpoint)
				return
			}
			if endpoint.posted_count == 0 {
				endpoint.dropped += 1
				return
			}
			if !network.admitted_add(&endpoint.admitted, packet.source_address, packet.source_port, now) {
				network.problem_count(&endpoint.problems, {kind = .Full, layer = .Tcp, offset = offset, value = u32(packet.source_port), limit = datagram.ADMITTED_CAPACITY}, .Endpoint)
				return
			}
		case grant.address == 0 || packet.source_address != grant.address || packet.source_port != grant.port:
			network.problem_count(&endpoint.problems, {kind = .Not_Granted, layer = .Tcp, offset = offset, value = u32(packet.source_port), limit = u32(grant.port)}, .Endpoint)
			return
		}
		deliver(endpoint, packet)
	}
}

// udp_endpoint_of gives the datagram endpoint of a local UDP port: the port
// PORT_FIRST + n of a client grant, or the port of a UDP listen grant. nil:
// no endpoint has it.
udp_endpoint_of :: proc "contextless" (port: u16) -> ^Endpoint {
	index := int(port) - PORT_FIRST
	if index >= 0 && index < ENDPOINT_CAPACITY {
		item := &endpoints[index]
		if item.ring_memory != 0 && !item.tcp && !item.listen {
			return item
		}
	}
	// By the port that the creation of the endpoint named, not by its
	// grant: an endpoint whose grant was revoked still owns its listen
	// port, and the check of its grant then refuses the datagram.
	for &item in endpoints {
		if item.ring_memory != 0 && !item.tcp && item.listen && item.local_port == port {
			return &item
		}
	}
	return nil
}

// udp_remote_admitted says if a datagram reaches a UDP listen endpoint: its
// remote is admitted, or it is admitted now. A new remote is admitted on a
// datagram of datagram.LISTEN_FIRST_LEAST bytes of data at least (a stray small
// datagram takes no place), from an address that can answer, and only when
// a Receive waits for it: the rules of the TCP listen grant, with the size
// in the place of the SYN.
udp_remote_admitted :: proc "contextless" (endpoint: ^Endpoint, packet: network.Packet, now: u64) -> bool {
	// The bytes of data: the length of the datagram less its header, which
	// network.parse checked. The data itself is not read.
	data_bytes := len(packet.data) - network.UDP_HEADER
	if network.admitted_received(&endpoint.admitted, packet.source_address, packet.source_port, u64(data_bytes), now) {
		return true
	}
	offset := u16(network.ETHERNET_HEADER + network.IPV4_HEADER)
	switch {
	case endpoint.grant.address != 0 && packet.source_address != endpoint.grant.address:
		// A UDP listen grant that names one remote address admits that
		// address only: a datagram of another one never reaches the process,
		// whatever its size.
		network.problem_count(&endpoint.problems, {kind = .Not_Granted, layer = .Udp, offset = network.ETHERNET_HEADER + 12, value = packet.source_address, limit = endpoint.grant.address}, .Endpoint)
		return false
	case data_bytes < datagram.LISTEN_FIRST_LEAST:
		network.problem_count(&endpoint.problems, {kind = .Bad_Length, layer = .Udp, offset = offset + 4, value = u32(data_bytes), limit = datagram.LISTEN_FIRST_LEAST}, .Endpoint)
		return false
	case !network.source_valid(packet.source_address, LOCAL_ADDRESS, NETWORK_MASK):
		network.problem_count(&endpoint.problems, {kind = .Bad_Header, layer = .Ipv4, offset = network.ETHERNET_HEADER + 12, value = packet.source_address}, .Endpoint)
		return false
	case endpoint.posted_count == 0:
		endpoint.dropped += 1
		return false
	case !network.admitted_add(&endpoint.admitted, packet.source_address, packet.source_port, now):
		network.problem_count(&endpoint.problems, {kind = .Full, layer = .Udp, offset = offset, value = u32(packet.source_port), limit = datagram.ADMITTED_CAPACITY}, .Endpoint)
		return false
	}
	// The bytes of the first datagram count for the limit of what goes to
	// this remote.
	network.admitted_received(&endpoint.admitted, packet.source_address, packet.source_port, u64(data_bytes), now)
	return true
}

// deliver gives a datagram or a segment to the first Receive of an endpoint.
deliver :: proc "contextless" (endpoint: ^Endpoint, packet: network.Packet) {
	if endpoint.posted_count == 0 {
		endpoint.dropped += 1
		return
	}
	posted := endpoint.posted[endpoint.posted_first]
	endpoint.posted_first = (endpoint.posted_first + 1) % RECEIVE_CAPACITY
	endpoint.posted_count -= 1
	// The one copy, and the one pass of this service over the bytes: from
	// the frame to the region of the process. No checksum of the datagram
	// or the segment was computed before: the process checks it. The place
	// was checked when it was posted.
	count := min(u64(len(packet.data)), posted.room)
	data_counted(&endpoint.arrived_data, int(count))
	if region_range(endpoint, posted.place, count) {
		copy(endpoint.region[posted.place:][:count], packet.data[:count])
		data_pass(&endpoint.arrived_data, int(count), max(int(count) - header_least(endpoint), 0))
	}
	endpoint.received += 1
	complete_taken(endpoint, posted.tag, .Ok, {0 = posted.place, 1 = count, 2 = u64(packet.source_address), 3 = u64(packet.source_port), 4 = u64(packet.destination_port)})
}

// resolved continues each request that waited for the hardware address of
// address.
resolved :: proc "contextless" (address: u32, found: network.Hardware, now: u64) {
	for &item in pending {
		if item.address != address {
			continue
		}
		endpoint := &endpoints[item.endpoint]
		switch item.kind {
		case .None, .Echo_Sent, .Statistics:
			// No place, an echo that waits for its reply, and the statistics
			// wait for no hardware address.
		case .Send:
			// It stays in flight: the frame service completes it.
			payload_send(endpoint, item.endpoint, item.tag, item.place, found, item.target, item.length, item.data_place)
			item = {}
		case .Resolve:
			value: u64
			for byte, place in found {
				value |= u64(byte) << (8 * uint(place))
			}
			complete_taken(endpoint, item.tag, .Ok, {0 = value, 1 = u64(address)})
			item = {}
		case .Echo:
			if echo_send(item.endpoint, found, item.target, item.sequence, item.bytes) {
				item.kind = .Echo_Sent
				item.deadline = now + ANSWER_TIME
			}
		}
	}
}

// expire ends each request whose answer did not come in time.
expire :: proc "contextless" (now: u64) -> (deadline: u64) {
	deadline = system.WAIT_FOREVER
	for &item in pending {
		if item.kind == .None {
			continue
		}
		if item.deadline > now {
			deadline = min(deadline, item.deadline)
			continue
		}
		endpoint := &endpoints[item.endpoint]
		switch item.kind {
		case .None:
		case .Send:
			send_place_free(item.place)
			complete_taken(endpoint, item.tag, .No_Answer, errors.ring_fail(u32(datagram.Command.Send), .No_Answer, .Milliseconds, 0, i64(item.address), i64(now - item.start), i64(errors.Unanswered.Hardware_Address)))
		case .Resolve, .Echo:
			command := item.kind == .Resolve ? datagram.Command.Resolve : datagram.Command.Echo
			complete_taken(endpoint, item.tag, .No_Answer, errors.ring_fail(u32(command), .No_Answer, .Milliseconds, 0, i64(item.address), i64(now - item.start), i64(errors.Unanswered.Hardware_Address)))
		case .Echo_Sent:
			complete_taken(endpoint, item.tag, .No_Answer, errors.ring_fail(u32(datagram.Command.Echo), .No_Answer, .Milliseconds, 0, i64(item.target), i64(now - item.start), i64(errors.Unanswered.Echo)))
		case .Statistics:
			complete_taken(endpoint, item.tag, .No_Answer, errors.ring_fail(u32(datagram.Command.Statistics), .No_Answer, .Milliseconds, 0, 0, i64(now - item.start), i64(errors.Unanswered.Device)))
		}
		item = {}
	}
	return deadline
}

// sends_waiting_refuse ends each Send of an endpoint that waits for a
// hardware address, when the grant of the endpoint changes. The grant that
// was checked for such a Send is gone: without this, the frame would leave
// after a revocation, when the answer of ARP comes. The place is free
// again, and the process gets the refusal of a remote that the grant does
// not name.
sends_waiting_refuse :: proc "contextless" (endpoint: ^Endpoint, index: int) {
	for &waiting in pending {
		if waiting.kind != .Send || waiting.endpoint != index {
			continue
		}
		port := byte_order.read_u16_big_endian(place_bytes(waiting.place)[network.IPV4_DATA:], 2)
		send_place_free(waiting.place)
		complete_taken(endpoint, waiting.tag, .Not_Granted, not_granted(u32(datagram.Command.Send), 3, waiting.target, port, grant_remote(endpoint.grant)))
		waiting = {}
	}
}

// controlled does one command of the root service.
controlled :: proc "contextless" (record: ring.Record) {
	result := datagram.Status.Ok
	values: [7]u64
	handle := system.Handle(record.values[0])
	// The root service writes the word: a word that names no control, and
	// None, are refused with their record.
	control_kind, control_kind_ok := datagram.control_of_ring_word(record.kind)
	if !control_kind_ok {
		system.send(&control.completions, ring.Record{kind = u32(datagram.Status.Bad_Command), tag = record.tag, values = errors.ring_fail(record.kind, .Unsupported, .None, 0, i64(record.kind))})
		return
	}
	switch control_kind {
	case .None:
		// The border refused None above.
	case .Endpoint_Add:
		region_handle := system.Handle(record.values[1])
		kind, _, through := system.handle_state(handle, control_memory)
		region_kind, region_rights, region_through := system.handle_state(region_handle, control_memory)
		free := -1
		for &item, index in endpoints {
			if item.ring_memory == 0 {
				free = index
				break
			}
		}
		// A listen port is one port of one endpoint: a port that no other
		// endpoint of the same protocol has, and not in the range of the
		// ports of client grants. The ports of an endpoint are the ones of
		// its creation, whatever its grant is now: an endpoint whose grant
		// was revoked keeps its port taken until it is removed.
		asked, asked_refusal, asked_known := network.endpoint_add_grant(record.values[2])
		taken := false
		if asked_known && asked.listen {
			held: [ENDPOINT_CAPACITY]network.Local_Ports
			for &item, index in endpoints {
				if item.ring_memory != 0 {
					held[index] = {tcp = item.tcp, first = item.local_port, count = item.port_count}
				}
			}
			if asked.tcp {
				taken = network.listen_port_taken(true, asked.port, TCP_PORT_FIRST, ENDPOINT_CAPACITY * datagram.PORT_BLOCK, held[:])
			} else {
				taken = network.listen_port_taken(false, asked.port, PORT_FIRST, ENDPOINT_CAPACITY, held[:])
			}
		}
		// A refused word or a taken port: no endpoint is made, so the region
		// is not mapped and the ring is not opened.
		if taken || !asked_known {
			free = -1
		}
		region_address: rawptr
		region_status := system.Status.Bad_Handle
		// Give: this service gives the region to the frame service, with
		// Read only, so that the device reads the data of each send there.
		needed := system.Rights{.Read, .Write, .Give}
		if free >= 0 && region_kind == .Memory && region_through && needed <= region_rights {
			if region_pages, size_status := system.memory_size(region_handle); size_status == .Ok && region_pages == datagram.REGION_PAGES {
				region_address, region_status = system.memory_map(region_handle, {.Write})
			}
		}
		opened: ring.Ring
		ring_status := system.Status.Bad_Handle
		if kind == .Memory && through && free >= 0 && region_status == .Ok {
			opened, ring_status = system.ring_open(handle)
		}
		ADD :: u32(datagram.Control.Endpoint_Add)
		if !asked_known {
			// A bit that names no right: the endpoint is not made, so that
			// no grant with fewer rights than the root service wrote exists.
			result = .Bad_Command
			values = asked_refusal
		} else if taken {
			result = .Busy
			values = errors.ring_fail(ADD, .Bad_Value, .None, 3, i64(asked.port)) // A listen port that another endpoint has.
		} else if free < 0 {
			result = .Busy
			values = errors.ring_fail(ADD, .Full, .Records, 0, 0, ENDPOINT_CAPACITY)
		} else if region_status != .Ok || ring_status != .Ok {
			result = .No_Region
			refused: bool
			if values, refused = system.region_refusal(region_handle, control_memory, ADD); refused {
				values[3] = 2 // The argument: the region.
			} else if size, size_status := system.memory_size(region_handle); size_status != .Ok {
				values = errors.ring_fail(ADD, .Refused, .None, 2, i64(region_handle), 0, i64(size_status))
			} else if size != datagram.REGION_PAGES {
				values = errors.ring_fail(ADD, .Bad_Value, .Pages, 2, i64(size), datagram.REGION_PAGES)
			} else if values, refused = system.region_refusal(handle, control_memory, ADD); !refused {
				values = errors.ring_fail(ADD, .Refused, .None, 0, 0, 0, i64(region_status != .Ok ? region_status : ring_status))
			}
		}
		read_region: system.Handle
		if result == .Ok {
			give_status: system.Status
			if read_region, give_status = system.give(frames_memory, region_handle, {.Read}); give_status != .Ok {
				result = .No_Region
				values = errors.ring_fail(ADD, .Refused, .None, 2, i64(region_handle), 0, i64(give_status))
			}
		}
		if result != .Ok {
			if ring_status == .Ok {
				system.ring_close(&opened)
			}
			if region_status == .Ok {
				system.memory_unmap(region_address)
			}
			system.close(handle)
			system.close(region_handle)
		} else {
			// The frame service holds the region from here, as a read
			// region at the place of the endpoint; the commands of this
			// endpoint come after this one in the frame ring.
			frame_command(.Read_Region_Add, TAG_READ_REGION_ADD + u32(free), {0 = u64(read_region), 1 = u64(free)})
			endpoint := &endpoints[free]
			name := system.name_unpack({record.values[3], record.values[4], record.values[5], record.values[6]})
			grant := asked
			endpoint^ = {ring_memory = handle, datagram_ring = opened, region_memory = region_handle, region = ([^]u8)(region_address)[:datagram.REGION_PAGES * system.PAGE_SIZE], grant = grant, tcp = grant.tcp, listen = grant.listen, local_port = u16(PORT_FIRST + free), port_count = 1, name = name}
			owner := owner_field(name)
			switch {
			case grant.tcp && grant.listen:
				endpoint.local_port = grant.port
				system.log_fact(.Info, Endpoint_Listens_Tcp{listen_port = u64(grant.port), owner = owner})
			case grant.listen && grant.address != 0:
				endpoint.local_port = grant.port
				system.log_fact(.Info, Endpoint_Listens_Udp_From_Address{listen_port = u64(grant.port), owner = owner, remote_address = address_field(grant.address)})
			case grant.listen:
				endpoint.local_port = grant.port
				system.log_fact(.Info, Endpoint_Listens_Udp{listen_port = u64(grant.port), owner = owner})
			case grant.tcp:
				endpoint.local_port = u16(TCP_PORT_FIRST + free * datagram.PORT_BLOCK)
				endpoint.port_count = datagram.PORT_BLOCK
				system.log_fact(.Info, Endpoint_Connects_Tcp{first_local_port = u64(endpoint.local_port), last_local_port = u64(endpoint.local_port) + datagram.PORT_BLOCK - 1, remote_port = u64(grant.port), owner = owner, remote_address = address_field(grant.address)})
			case:
				system.log_fact(.Info, Endpoint_Connects_Udp{local_port = u64(endpoint.local_port), remote_port = u64(grant.port), owner = owner, remote_address = address_field(grant.address)})
			}
			values[0] = u64(endpoint.local_port)
		}
	case .Endpoint_Grant:
		result = .Bad_Command
		values = errors.ring_fail(record.kind, .Absent, .None, 1, i64(handle))
		for &item, index in endpoints {
			if item.ring_memory != 0 && item.ring_memory == handle {
				// The local ports and their check of overlap come from
				// Endpoint_Add only: a new grant keeps the form of the creation.
				form := network.Endpoint_Form{tcp = item.tcp, listen = item.listen, local_port = item.local_port}
				refusal, changed := network.endpoint_grant_change(form, &item.grant, record.values[1])
				if !changed {
					values = refusal
					break
				}
				item.admitted = {}
				sends_waiting_refuse(&item, index)
				if datagram.granted(item.grant) {
					system.log_fact(.Info, Endpoint_Grant_Changed_To_Remote{owner = owner_field(item.name)})
				} else {
					system.log_fact(.Info, Endpoint_Grant_Changed_To_None{owner = owner_field(item.name)})
				}
				result = .Ok
				values = {}
			}
		}
	case .Endpoint_Remove:
		result = .Bad_Command
		values = errors.ring_fail(record.kind, .Absent, .None, 1, i64(handle))
		for &item, index in endpoints {
			if item.ring_memory == 0 || item.ring_memory != handle {
				continue
			}
			for &waiting in pending {
				if waiting.kind != .None && waiting.endpoint == index {
					if waiting.kind == .Send {
						send_place_free(waiting.place)
					}
					waiting = {}
				}
			}
			// A frame of this endpoint in flight completes after its end, and
			// a new endpoint can take the same place: its completion only
			// frees the send place.
			for &owner in send_owners {
				if owner.busy && owner.endpoint == index {
					owner = {}
				}
			}
			// The frame service closes its handle of the region after the
			// last frame that reads it; the frames of the region stay until
			// then, whatever this service and the process close.
			frame_command(.Read_Region_Remove, TAG_READ_REGION_REMOVE + u32(index), {0 = u64(index)})
			system.ring_close(&item.datagram_ring)
			system.close(item.ring_memory)
			if item.region_memory != 0 {
				system.memory_unmap(raw_data(item.region))
				system.close(item.region_memory)
			}
			system.log_fact(.Info, Endpoint_Ended{datagrams_sent = item.sent, datagrams_received = item.received, owner = owner_field(item.name)})
			data_passes_log(&item)
			item = {}
			result = .Ok
			values = {}
		}
	}
	system.send(&control.completions, ring.Record{kind = u32(result), tag = record.tag, values = values})
}

// data_passes_log writes what this service did to the bytes of the
// datagrams or the segments of an endpoint that ends: a measure, the
// passes for each byte in hundredths, then the structural fact: one pass
// on receive (the copy to the region of the process); on send, the copy of
// the first SEND_HEADER_COPIED bytes of each, for the check, and no byte of
// the data, which the device read from the region; no pass for a checksum.
data_passes_log :: proc "contextless" (endpoint: ^Endpoint) {
	hundredths :: proc "contextless" (count: Data_Count) -> value_kinds.Hundredths {
		return value_kinds.Hundredths(count.bytes_passed * 100 / max(count.payload_bytes, 1))
	}
	name := system.name_of(endpoint.name[:])
	protocol := endpoint.tcp ? "TCP" : "UDP"
	arrived, left := endpoint.arrived_data, endpoint.left_data
	// The unit of the payload, a segment or a datagram, is a case of the
	// sentence: each protocol is a fact type.
	if endpoint.tcp {
		system.log_fact(.Info, Tcp_Passes_Measured{receive_passes = hundredths(arrived), received_bytes = u64(arrived.payload_bytes), received_units = u64(arrived.units), send_passes = hundredths(left), sent_bytes = u64(left.payload_bytes), sent_units = u64(left.units), data_bytes_read = u64(left.data_bytes_read), owner = value_kinds.module_name_field(name)})
	} else {
		system.log_fact(.Info, Udp_Passes_Measured{receive_passes = hundredths(arrived), received_bytes = u64(arrived.payload_bytes), received_units = u64(arrived.units), send_passes = hundredths(left), sent_bytes = u64(left.payload_bytes), sent_units = u64(left.units), data_bytes_read = u64(left.data_bytes_read), owner = value_kinds.module_name_field(name)})
	}
	right := arrived.bytes_passed == arrived.payload_bytes && left.bytes_passed == left.units * SEND_HEADER_COPIED && left.data_bytes_read == 0
	// The verdict is a case of the sentence: each one is a fact type.
	if right {
		system.log_fact(.Info, Payload_Passes_Checked{header_bytes = value_kinds.Size_In_Bytes(SEND_HEADER_COPIED), data_bytes_read = value_kinds.Size_In_Bytes(left.data_bytes_read), owner = value_kinds.module_name_field(name), protocol = value_kinds.text_field(protocol, PROTOCOL_FIELD_BYTES)})
	} else {
		system.log_fact(.Info, Payload_Passes_Wrong{header_bytes = value_kinds.Size_In_Bytes(SEND_HEADER_COPIED), data_bytes_read = value_kinds.Size_In_Bytes(left.data_bytes_read), owner = value_kinds.module_name_field(name), protocol = value_kinds.text_field(protocol, PROTOCOL_FIELD_BYTES)})
	}
}

// frame_service_stopped_fail writes the line of a frame service that
// stopped, and stops this service: no frame moves, and the root service
// then refuses each process that needs an endpoint.
frame_service_stopped_fail :: proc "contextless" () -> ! {
	fail("the frame service stopped: the network device moves no frame, and this service stops")
}

// call sends one command to the frame service and waits for its completion.
// Only at the start: no other request is in flight. The wait ends at the
// stop of the frame service, or at system.ANSWER_BOUND_MILLISECONDS, and
// this service then stops with its line.
call :: proc "contextless" (command: frame.Command, tag: u32, values: [7]u64 = {}) -> ring.Record {
	frame_command(command, tag, values)
	system.wake_reader(&frames.commands)
	deadline := system.answer_deadline(system.time())
	for {
		wait := system.wait_begin() // The stop of the frame service is an event.
		if record, ok := system.receive(&frames.completions); ok && record.tag == tag {
			return record
		}
		state, _, _ := system.process_state(frame_service)
		switch system.answer_wait_of(system.time(), deadline, state) {
		case .Waits:
		case .Stopped:
			frame_service_stopped_fail()
		case .Silent:
			system.log_fact(.Error, Frame_Service_Silent{bound = answer_bound_field(), command = command_field(frame.command_name(i64(command)))})
			system.stop(.Failed)
		}
		system.wait_records(&wait, &frames.completions)
		system.wait_end(&wait, deadline)
	}
}

// frame_service_check stops this service when the frame service stopped.
// It reads the state only after an event of this process: the stop of a
// process that it holds is one, so no stop is missed and a pass with no
// event makes no kernel call. The word is read before the state: a stop
// after the read changes it again.
frame_service_check :: proc "contextless" () {
	events := intrinsics.volatile_load(system.events())
	if frame_service_state_read && events == frame_service_events {
		return
	}
	frame_service_events = events
	frame_service_state_read = true
	if state, _, _ := system.process_state(frame_service); system.answer_wait_of(system.time(), system.WAIT_FOREVER, state) == .Stopped {
		frame_service_stopped_fail()
	}
}

// The entry of the network service: it attaches to the frame service of the
// device, then moves frames and datagrams for the life of the machine.
//
// The entry, in order:
//
// 1. opens the frame ring and the control ring of the root service; with
//    no ring, it stops (`fail`);
// 2. creates the frame region, contiguous because the device reads and
//    writes it, and gives it to the frame service with `Attach`;
// 3. reads the hardware address and the state of the link, and posts the
//    places for the frames that arrive;
// 4. writes "network: ok, the address 10.0.2.15/24 ...", then measures the
//    headers of IPv4 and Ethernet of one frame 20000 times and writes the
//    cost of one.
//
// Then one loop runs for ever. Each pass takes the frames that arrived and
// the frames that left, the new endpoints of the control ring, and the
// commands of each endpoint while its completion queue has room. A command
// that has no room waits in the endpoint, so a process that reads no
// completion slows only itself. The loop then wakes the rings that changed,
// and waits for a record or for the deadline of the oldest request that
// waits for an answer (an ARP request, an echo).
//
// **The stop of the frame service.** This service holds the frame service
// with the right Read, so its stop is an event. At the start, at that stop
// or when the frame service does not answer a command in
// system.ANSWER_BOUND_MILLISECONDS, and in the loop at that stop, it writes
// "network: the frame service stopped: ..." (or the command that had no
// answer) and stops with `Failed`. The root service then refuses each
// process that needs an endpoint (src/md/features/missing_hardware.md).
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	frames_memory = ctx.handles[frame.GRANT_RING]
	control_memory = ctx.handles[datagram.SERVICE_CONTROL]
	status: system.Status
	if frames, status = system.ring_open(frames_memory); status != .Ok {
		fail("no frame ring")
	}
	frame_service = ctx.handles[frame.GRANT_SERVICE]
	if kind, rights, _ := system.handle_state(frame_service); kind != .Process || .Read not_in rights {
		fail("no handle of the frame service with the right Read: a wait for the device would have no end")
	}
	if control, status = system.ring_open(control_memory, receive_handles = true); status != .Ok {
		fail("no control ring")
	}
	// The frame region: the device reads and writes it, so it is contiguous.
	memory, memory_status := system.memory_create(REGION_PAGES, 0, {.Contiguous})
	address, map_status := system.memory_map(memory, {.Write})
	if memory_status != .Ok || map_status != .Ok {
		fail("no frame region")
	}
	region = ([^]u8)(address)[:REGION_PAGES * system.PAGE_SIZE]
	// The frame service maps the ring when it starts: until then, the
	// kernel does not know the other side.
	given: system.Handle
	give_status := system.Status.Bad_Handle
	for attempt := 0; attempt < 2000 && give_status != .Ok; attempt += 1 {
		if given, give_status = system.give(frames_memory, memory, {.Read, .Write}); give_status != .Ok {
			if state, _, _ := system.process_state(frame_service); system.answer_wait_of(system.time(), system.WAIT_FOREVER, state) == .Stopped {
				frame_service_stopped_fail()
			}
			system.sleep(system.time() + 1)
		}
	}
	if give_status != .Ok {
		fail("the frame service does not map the frame ring")
	}
	if attached := call(.Attach, TAG_ATTACH, {0 = u64(given)}); frame.Status(attached.kind) != .Ok {
		fail("the frame service refused the frame region")
	}
	info := call(.Info, TAG_INFO)
	hardware = frame.hardware(info.values[0])
	link_up = info.values[1] != 0
	for place in RECEIVE_PLACES ..< PLACE_COUNT {
		send_place_free(place)
	}
	for place in 0 ..< min(RECEIVE_PLACES, int(info.values[3])) {
		frame_receive(place)
	}
	text: [64]u8
	writer := system.Writer{buffer = text[:]}
	network.address_write(&writer, LOCAL_ADDRESS)
	system.write_bytes(&writer, {'/', '2', '4', ' '})
	network.hardware_write(&writer, hardware)
	// The state of the link is a case of the sentence: each one is a fact
	// type.
	if link_up {
		system.log_fact(.Info, Ready_Link_Up{receive_places = u64(min(RECEIVE_PLACES, int(info.values[3]))), interface_address = value_kinds.text_field(system.written(&writer), INTERFACE_ADDRESS_FIELD_BYTES)})
	} else {
		system.log_fact(.Info, Ready_Link_Down{receive_places = u64(min(RECEIVE_PLACES, int(info.values[3]))), interface_address = value_kinds.text_field(system.written(&writer), INTERFACE_ADDRESS_FIELD_BYTES)})
	}
	// The cost of what this process writes for each datagram or segment that leaves:
	// the headers of IPv4 and Ethernet, with the checksum of the IPv4
	// header. No byte of the payload is read: its checksum is the work of
	// the process that sends it.
	{
		ROUNDS :: 20_000
		PAYLOAD :: network.MTU - network.IPV4_HEADER
		place, _ := send_place_take()
		start := system.time()
		for round in 0 ..< ROUNDS {
			network.ipv4_frame(place_bytes(place), hardware, hardware, LOCAL_ADDRESS, GATEWAY_ADDRESS, network.PROTOCOL_UDP, PAYLOAD, u16(round))
		}
		took := system.time() - start
		send_place_free(place)
		system.log_fact(.Info, Headers_Measured{payload_size = value_kinds.Size_In_Bytes(PAYLOAD), header_time = value_kinds.Time_In_Nanoseconds(took * 1_000_000 / ROUNDS)})
	}

	for {
		wait := system.wait_begin()
		// After wait_begin: a stop after this check ends the wait of this
		// pass, and the next pass finds it.
		frame_service_check()
		now := system.time()
		// The frame service: frames that arrived, frames sent, statistics.
		for record in system.receive(&frames.completions) {
			tag := int(record.tag)
			switch {
			case tag < RECEIVE_PLACES:
				if frame.Status(record.kind) == .Ok {
					arrived(tag, int(record.values[0]), now)
				}
				frame_receive(tag)
			case tag < PLACE_COUNT:
				// The device read the frame: the Send of a process completes
				// now, and the process can write its place again.
				owner := send_owners[tag - RECEIVE_PLACES]
				send_owners[tag - RECEIVE_PLACES] = {}
				send_place_free(tag)
				if owner.busy {
					// The frame service writes the word: it is compared, and
					// a refusal carries the word as it came.
					if record.kind == u32(frame.Status.Ok) {
						complete_taken(&endpoints[owner.endpoint], owner.tag, .Ok)
					} else {
						complete_taken(&endpoints[owner.endpoint], owner.tag, .No_Region, errors.ring_fail(u32(datagram.Command.Send), .Refused, .Region, 1, 0, 0, i64(record.kind)))
					}
				}
			case tag >= TAG_READ_REGION_ADD && tag < TAG_READ_REGION_ADD + ENDPOINT_CAPACITY:
				// A refusal leaves the endpoint with no read region: the frame
				// service refuses each of its sends, which complete with
				// No_Region.
				if frame.Status(record.kind) != .Ok {
					endpoint := &endpoints[tag - TAG_READ_REGION_ADD]
					system.log_fact(.Error, Read_Region_Refused{status_word = u64(record.kind), owner = owner_field(endpoint.name)})
				}
			case tag >= TAG_READ_REGION_REMOVE && tag < TAG_READ_REGION_REMOVE + ENDPOINT_CAPACITY:
			case tag == TAG_STATISTICS:
				for &item in pending {
					if item.kind == .Statistics {
						endpoint := &endpoints[item.endpoint]
						values := [7]u64{0 = endpoint.sent, 1 = endpoint.received, 4 = endpoint.problems.count, 6 = endpoint.dropped}
						if endpoint.grant.inspect {
							values[2], values[3], values[5] = system.kernel_entries(), record.values[2], answered
							values[4] += machine_problems.count
						}
						complete_taken(endpoint, item.tag, .Ok, values)
						item = {}
					}
				}
			}
		}
		for record in system.receive(&control.commands) {
			controlled(record)
		}
		for &endpoint, index in endpoints {
			if endpoint.ring_memory == 0 {
				continue
			}
			for ring.count(&endpoint.datagram_ring.completions) + endpoint.in_flight + 1 < ring.capacity(&endpoint.datagram_ring.completions) {
				record: ring.Record
				if endpoint.has_held {
					record, endpoint.has_held = endpoint.held, false
				} else {
					ok: bool
					if record, ok = system.receive(&endpoint.datagram_ring.commands); !ok {
						break
					}
				}
				if !command(&endpoint, index, record, now) {
					endpoint.held, endpoint.has_held = record, true
					break
				}
			}
		}
		deadline := expire(now)
		if frames_changed {
			frames_changed = false
			system.wake_reader(&frames.commands)
		}
		for &endpoint in endpoints {
			if endpoint.changed {
				endpoint.changed = false
				system.wake_reader(&endpoint.datagram_ring.completions)
			}
		}
		if !ring.empty(&frames.completions) {
			continue
		}
		system.wait_records(&wait, &frames.completions)
		system.wait_records(&wait, &control.commands)
		for &endpoint in endpoints {
			if endpoint.ring_memory != 0 && !endpoint.has_held && ring.count(&endpoint.datagram_ring.completions) + endpoint.in_flight + 1 < ring.capacity(&endpoint.datagram_ring.completions) {
				system.wait_records(&wait, &endpoint.datagram_ring.commands)
			}
		}
		system.wait_end(&wait, deadline)
	}
}

#assert(REGION_PAGES * system.PAGE_SIZE == PLACE_COUNT * frame.PLACE_SIZE)
#assert(PLACE_COUNT <= frame.RING_CAPACITY)
#assert(TAG_ATTACH >= PLACE_COUNT)
#assert(TAG_READ_REGION_ADD > TAG_STATISTICS && TAG_READ_REGION_ADD + ENDPOINT_CAPACITY <= TAG_READ_REGION_REMOVE)
#assert(ENDPOINT_CAPACITY <= frame.READ_REGION_CAPACITY) // The place of an endpoint is the place of its read region.
#assert(SEND_HEADER_COPIED <= datagram.DATAGRAM_LEAST && SEND_HEADER_COPIED <= datagram.SEGMENT_LEAST)
