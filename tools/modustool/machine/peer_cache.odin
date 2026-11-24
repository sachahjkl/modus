// Peer UDP forwarder for the local QUIC object cache server (10.0.2.100:5010).
//
// The recipes service inside QEMU holds a scoped UDP endpoint to 10.0.2.100
// port 5010 (src/modules/system/root/network.odin). QEMU user networking with
// restrict=on drops UDP, so machines that talk to a local host cache-serve run
// on the tool's dgram peer. This file answers ARP for 10.0.2.100 and forwards
// UDP datagrams bidirectionally between 10.0.2.15:<ephemeral> <-> 10.0.2.100:5010
// and the host loopback cache-serve QUIC socket (127.0.0.1:<bound_port>).
package machine

import "core:fmt"
import "core:net"
import "core:sync"
import "modus:contract/object_cache"

@(rodata)
PEER_CACHE_HARDWARE := [6]u8{0x52, 0x55, 0x0A, 0x00, 0x02, 0x64}
@(rodata)
PEER_CACHE_ADDRESS := [4]u8{10, 0, 2, 100}
PEER_CACHE_PORT :: u16(object_cache.DEFAULT_QUIC_PORT)
PEER_CACHE_DATA_LIMIT :: RELAY_DATA_LIMIT
PEER_CACHE_PER_TICK :: RELAY_PER_TICK

Peer_Cache :: struct {
	active:       bool,
	target:       net.Endpoint,
	socket:       net.UDP_Socket,
	machine_port: u16,
	to_cache:     int,
	to_machine:   int,
	too_long:     int,
	wrong_sender: int,
}

// peer_cache_start binds a non-blocking loopback UDP socket for forwarding
// 10.0.2.100:5010 traffic to target. A zero target.port leaves forwarding off.
peer_cache_start :: proc(cache: ^Peer_Cache, target: net.Endpoint) -> bool {
	cache^ = {}
	if target.port == 0 {
		return true
	}
	socket, err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	if err != nil {
		fmt.eprintfln("modustool: the cache forwarder of the peer has no UDP socket: %v", err)
		return false
	}
	_ = net.set_blocking(socket, false)
	cache^ = {
		active = true,
		target = target,
		socket = socket,
	}
	return true
}

peer_cache_stop :: proc(cache: ^Peer_Cache) {
	if !cache.active {
		return
	}
	net.close(cache.socket)
	cache.active = false
}

// peer_cache_arp_reply builds a 60-byte Ethernet ARP reply claiming
// PEER_CACHE_ADDRESS at PEER_CACHE_HARDWARE for an incoming ARP request.
peer_cache_arp_reply :: proc(frame: []u8, arp: []u8) -> (reply: [60]u8) {
	copy(reply[0:6], frame[6:12])
	copy(reply[6:12], PEER_CACHE_HARDWARE[:])
	put16(reply[:], 12, 0x0806)
	copy(reply[14:22], arp[0:8])
	put16(reply[:], 20, 2)
	copy(reply[22:28], PEER_CACHE_HARDWARE[:])
	copy(reply[28:32], PEER_CACHE_ADDRESS[:])
	copy(reply[32:38], arp[8:14])
	copy(reply[38:42], arp[14:18])
	return reply
}

// peer_cache_udp_frame builds an Ethernet + IPv4 + UDP frame from
// PEER_CACHE_ADDRESS:PEER_CACHE_PORT to MACHINE_ADDRESS:machine_port.
peer_cache_udp_frame :: proc(destination_hardware: [6]u8, machine_port: u16, data: []u8, allocator := context.temp_allocator) -> []u8 {
	udp_length := 8 + len(data)
	frame := make([]u8, max(42 + len(data), 60), allocator)
	dst_hw := destination_hardware
	copy(frame[0:6], dst_hw[:])
	copy(frame[6:12], PEER_CACHE_HARDWARE[:])
	put16(frame, 12, 0x0800)
	ip := frame[14:34]
	ip[0] = 0x45
	put16(ip, 2, 20 + udp_length)
	put16(ip, 6, 0x4000)
	ip[8] = 64
	ip[9] = 17
	copy(ip[12:16], PEER_CACHE_ADDRESS[:])
	copy(ip[16:20], MACHINE_ADDRESS[:])
	put16(ip, 10, 0)
	put16(ip, 10, internet_sum(0, ip))

	put16(frame, 34, int(PEER_CACHE_PORT))
	put16(frame, 36, int(machine_port))
	put16(frame, 38, udp_length)
	copy(frame[42:], data)
	put16(frame, 40, 0)
	value := internet_sum(pseudo_sum(PEER_CACHE_ADDRESS[:], MACHINE_ADDRESS[:], udp_length), frame[34:42 + len(data)])
	put16(frame, 40, value == 0 ? 0xFFFF : value)
	return frame
}

// peer_cache_datagram forwards one UDP datagram sent by the machine to
// 10.0.2.100:5010 toward the host cache-serve QUIC socket.
peer_cache_datagram :: proc(peer: ^Peer, machine_port: u16, data: []u8) {
	cache := &peer.cache
	if !cache.active {
		return
	}
	if len(data) > PEER_CACHE_DATA_LIMIT {
		cache.too_long += 1
		return
	}
	cache.machine_port = machine_port
	sent, err := net.send_udp(cache.socket, data, cache.target)
	if err == nil && sent == len(data) {
		cache.to_cache += 1
	}
}

@(private = "file")
peer_cache_same_endpoint :: proc(first, second: net.Endpoint) -> bool {
	a, a_ok := first.address.(net.IP4_Address)
	b, b_ok := second.address.(net.IP4_Address)
	return first.port == second.port && a_ok && b_ok && a == b
}

// peer_cache_tick drains pending UDP replies from the host cache-serve QUIC
// socket and sends them back to the machine as Ethernet frames from 10.0.2.100:5010.
// Datagrams from any endpoint other than cache.target are dropped and counted.
peer_cache_tick :: proc(peer: ^Peer) {
	cache := &peer.cache
	if !cache.active || cache.machine_port == 0 {
		return
	}
	buffer: [65536]u8
	for _ in 0 ..< PEER_CACHE_PER_TICK {
		count, from, err := net.recv_udp(cache.socket, buffer[:])
		if err != nil || count <= 0 {
			return
		}
		if !peer_cache_same_endpoint(from, cache.target) {
			cache.wrong_sender += 1
			continue
		}
		if count > PEER_CACHE_DATA_LIMIT {
			cache.too_long += 1
			continue
		}
		sync.mutex_lock(&peer.lock)
		hardware := peer.hardware
		sync.mutex_unlock(&peer.lock)
		frame := peer_cache_udp_frame(hardware, cache.machine_port, buffer[:count])
		peer_send(peer, frame)
		cache.to_machine += 1
	}
}
