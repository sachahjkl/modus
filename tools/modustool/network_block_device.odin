package modustool

import format "modus:contract/store"
import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:sync"
import "core:thread"

// A disk that the modus tool serves to QEMU with the Network Block Device
// protocol (NBD, "fixed newstyle" handshake, simple replies), so that the
// tool sees each write and each flush of the machine, in order.
//
// The disk keeps two images:
//   current   what the machine reads: each write is there.
//   durable   what a disk keeps through a loss of power: each write that a
//             flush that came after it made durable.
// and the writes after the last flush (pending), in order. At a loss of
// power (the tool ends QEMU with no warning), a real disk can hold the
// durable image plus any subset of the pending writes, each one whole or
// torn: power_loss.odin builds these images and checks each one.
//
// The disk can also drop one write: it answers Ok and keeps nothing, as a
// disk with a fault that reports none; and hide one: it answers Ok, gives
// the bytes at a read, and never makes them durable (dropped_write.odin).
//
// The protocol: https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md
// All numbers on the wire are big-endian.

NBD_MAGIC :: u64(0x4e42444d41474943) // "NBDMAGIC"
NBD_OPTION_MAGIC :: u64(0x49484156454F5054) // "IHAVEOPT"
NBD_REPLY_MAGIC :: u64(0x0003e889045565a9) // The reply to an option.
NBD_REQUEST_MAGIC :: u32(0x25609513)
NBD_SIMPLE_REPLY_MAGIC :: u32(0x67446698)

NBD_FLAG_FIXED_NEWSTYLE :: u16(1)
NBD_FLAG_NO_ZEROES :: u16(2)
NBD_FLAG_HAS_FLAGS :: u16(1) // Transmission flags.
NBD_FLAG_SEND_FLUSH :: u16(4)
NBD_FLAG_SEND_FUA :: u16(8)

NBD_OPTION_EXPORT_NAME :: u32(1)
NBD_OPTION_ABORT :: u32(2)
NBD_OPTION_INFO :: u32(6)
NBD_OPTION_GO :: u32(7)
NBD_REPLY_ACK :: u32(1)
NBD_REPLY_INFO :: u32(3)
NBD_REPLY_ERROR_UNSUPPORTED :: u32(1 << 31 | 1)
NBD_INFO_EXPORT :: u16(0)

NBD_COMMAND_READ :: u16(0)
NBD_COMMAND_WRITE :: u16(1)
NBD_COMMAND_DISCONNECT :: u16(2)
NBD_COMMAND_FLUSH :: u16(3)
NBD_COMMAND_FLAG_FUA :: u16(1) // This write is durable when its reply comes.
NBD_ERROR_INVALID :: u32(22) // EINVAL

// One write after the last flush.
Pending_Write :: struct {
	offset: u64,
	bytes:  []u8,
}

Network_Block_Device :: struct {
	socket:   net.TCP_Socket,
	client:   net.TCP_Socket,
	port:     int,
	thread:   ^thread.Thread,
	stop:     bool,
	lock:     sync.Mutex, // current, durable, pending and the counts.
	current:  []u8,
	durable:  []u8,
	pending:  [dynamic]Pending_Write,
	writes:   int, // The writes and the flushes since the start: the test reads them.
	flushes:  int,
	reads:    int,
	failure:  string, // A request that the protocol does not permit.
	// The loss of power: at the first write of a root (blocks 0 and 1 of
	// the data disk, src/library/contract/store) from the write with this number (from
	// 1) on, the disk answers nothing more, as a disk whose power went off
	// during that write. The write of a root is the hardest moment: the
	// blocks of the commit are durable, its root is not. 0: never.
	power_off_after_write: int,
	powered_off:           bool,
	// The dropped write (dropped_write.odin): not empty, the disk answers Ok
	// to the first write that holds a block whose bytes start with this
	// marker, and keeps nothing of that block: a read gives its bytes from
	// before. It keeps the other blocks of the request, and each later
	// write.
	drop_marker:       string,
	dropped:           bool,
	dropped_block:     u64, // The block that the disk did not keep.
	// The dropped root: not empty, the disk keeps the first write of a
	// block whose bytes start with this marker, then answers Ok to the next
	// write of a root and keeps nothing of it.
	root_drop_marker:  string,
	root_drop_state:   Root_Drop_State,
	// The hidden dropped write: not empty, the disk answers Ok to the first
	// write that holds a block whose bytes start with this marker, gives
	// those bytes at each read, and never makes them durable: a cache that
	// a loss of power empties, and that hides the loss from a read back.
	hide_marker:       string,
	hide_state:        Hide_State,
	hidden_block:      u64, // The block that a loss of power loses.
	// A copy of the durable image when the first root after the hidden
	// write became durable: the image that a loss of power at that moment
	// leaves.
	durable_at_hidden_root: []u8,
}

// The states of the dropped root, in their order.
Root_Drop_State :: enum {
	Armed, // No block with the marker was written yet.
	Marker_Written, // The block with the marker was kept: the next root is dropped.
	Root_Dropped, // A write of a root was answered and not kept.
}

// The states of the hidden dropped write, in their order.
Hide_State :: enum {
	Armed, // No write was hidden yet.
	Hidden, // The block with the marker is in the current image only.
	Root_Written, // A root was written after it.
	Root_Durable, // A flush made that root durable, and the disk copied its durable image.
}

// The two places of the root block (docs/STORAGE.md, "3.1 The blocks"):
// a write below them is the write of a root.
ROOT_BLOCK_PLACES :: 2

// marker_block gives the place in `bytes` of the first block whose bytes
// start with `marker`, or -1. QEMU can join the writes of several blocks
// into one request: each block of it is compared, and the disk changes
// only the block with the marker, so the storage service finds one block.
@(private = "file")
marker_block :: proc(offset: u64, bytes: []u8, marker: string) -> int {
	if marker == "" || offset < ROOT_BLOCK_PLACES * format.BLOCK_SIZE {
		return -1
	}
	for start := 0; start + len(marker) <= len(bytes); start += format.BLOCK_SIZE {
		if string(bytes[start:][:len(marker)]) == marker {
			return start
		}
	}
	return -1
}

// drop_decide moves the dropped writes to their next state for one write.
// It gives the place in `bytes` of the block that the disk does not keep
// at all, and of the block that it does not make durable; -1 for none. The
// caller holds the lock.
drop_decide :: proc(server: ^Network_Block_Device, offset: u64, bytes: []u8) -> (dropped_start: int, hidden_start: int) {
	dropped_start, hidden_start = -1, -1
	switch server.root_drop_state {
	case .Armed:
		if marker_block(offset, bytes, server.root_drop_marker) >= 0 {
			server.root_drop_state = .Marker_Written
		}
	case .Marker_Written:
		if offset < ROOT_BLOCK_PLACES * format.BLOCK_SIZE {
			// A root is written alone: the whole write is the root.
			server.root_drop_state = .Root_Dropped
			return 0, -1
		}
	case .Root_Dropped:
	}
	if !server.dropped {
		dropped_start = marker_block(offset, bytes, server.drop_marker)
		if dropped_start >= 0 {
			server.dropped = true
			server.dropped_block = (offset + u64(dropped_start)) / format.BLOCK_SIZE
		}
	}
	switch server.hide_state {
	case .Armed:
		hidden_start = marker_block(offset, bytes, server.hide_marker)
		if hidden_start >= 0 {
			server.hide_state = .Hidden
			server.hidden_block = (offset + u64(hidden_start)) / format.BLOCK_SIZE
		}
	case .Hidden:
		if offset < ROOT_BLOCK_PLACES * format.BLOCK_SIZE {
			server.hide_state = .Root_Written
		}
	case .Root_Written, .Root_Durable:
	}
	return dropped_start, hidden_start
}

// disk_server_start serves an image: `image` is the disk at the start, and
// it is durable.
disk_server_start :: proc(server: ^Network_Block_Device, image: []u8) -> bool {
	socket, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		fmt.eprintfln("modustool: the disk server has no TCP socket: %v", err)
		return false
	}
	bound, bound_err := net.bound_endpoint(socket)
	if bound_err != nil {
		net.close(socket)
		return false
	}
	server^ = {socket = socket, port = bound.port}
	server.current = make([]u8, len(image))
	server.durable = make([]u8, len(image))
	copy(server.current, image)
	copy(server.durable, image)
	server.pending = make([dynamic]Pending_Write)
	server.thread = thread.create_and_start_with_poly_data(server, disk_server_run)
	return true
}

// disk_server_stop ends the server. The images and the pending writes stay:
// call disk_server_free after the use of them.
disk_server_stop :: proc(server: ^Network_Block_Device) {
	if server.thread == nil {
		return
	}
	sync.atomic_store(&server.stop, true)
	if client := net.TCP_Socket(sync.atomic_load((^int)(&server.client))); client != 0 {
		_ = net.shutdown(client, .Both)
	}
	_ = net.shutdown(server.socket, .Both)
	net.close(server.socket)
	thread.join(server.thread)
	thread.destroy(server.thread)
	server.thread = nil
}

disk_server_free :: proc(server: ^Network_Block_Device) {
	for write in server.pending {
		delete(write.bytes)
	}
	delete(server.pending)
	delete(server.current)
	delete(server.durable)
	delete(server.durable_at_hidden_root)
	server.current, server.durable, server.durable_at_hidden_root = nil, nil, nil
}

disk_server_run :: proc(server: ^Network_Block_Device) {
	for !sync.atomic_load(&server.stop) {
		client, _, err := net.accept_tcp(server.socket)
		if err != nil {
			return
		}
		sync.atomic_store((^int)(&server.client), int(client))
		if disk_server_handshake(server, client) {
			disk_server_serve(server, client)
		}
		sync.atomic_store((^int)(&server.client), 0)
		net.close(client)
	}
}

// receive_all receives exactly len(bytes) bytes.
receive_all :: proc(socket: net.TCP_Socket, bytes: []u8) -> bool {
	for received := 0; received < len(bytes); {
		count, err := net.recv_tcp(socket, bytes[received:])
		if err != nil || count <= 0 {
			return false
		}
		received += count
	}
	return true
}

@(private = "file")
put_u16 :: proc(bytes: []u8, value: u16) {
	endian.put_u16(bytes, .Big, value)
}

@(private = "file")
put_u32 :: proc(bytes: []u8, value: u32) {
	endian.put_u32(bytes, .Big, value)
}

@(private = "file")
put_u64 :: proc(bytes: []u8, value: u64) {
	endian.put_u64(bytes, .Big, value)
}

@(private = "file")
option_reply :: proc(client: net.TCP_Socket, option: u32, kind: u32, data: []u8) -> bool {
	header: [20]u8
	put_u64(header[0:], NBD_REPLY_MAGIC)
	put_u32(header[8:], option)
	put_u32(header[12:], kind)
	put_u32(header[16:], u32(len(data)))
	return send_all(client, header[:]) && send_all(client, data)
}

// disk_server_handshake makes the fixed newstyle handshake. It gives true
// when the transmission starts (NBD_OPT_GO or NBD_OPT_EXPORT_NAME).
disk_server_handshake :: proc(server: ^Network_Block_Device, client: net.TCP_Socket) -> bool {
	greeting: [18]u8
	put_u64(greeting[0:], NBD_MAGIC)
	put_u64(greeting[8:], NBD_OPTION_MAGIC)
	put_u16(greeting[16:], NBD_FLAG_FIXED_NEWSTYLE | NBD_FLAG_NO_ZEROES)
	if !send_all(client, greeting[:]) {
		return false
	}
	client_flags: [4]u8
	if !receive_all(client, client_flags[:]) {
		return false
	}
	no_zeroes := endian.unchecked_get_u32be(client_flags[:]) & u32(NBD_FLAG_NO_ZEROES) != 0
	transmission := NBD_FLAG_HAS_FLAGS | NBD_FLAG_SEND_FLUSH | NBD_FLAG_SEND_FUA
	size := u64(len(server.current))
	for {
		header: [16]u8
		if !receive_all(client, header[:]) || endian.unchecked_get_u64be(header[0:]) != NBD_OPTION_MAGIC {
			return false
		}
		option := endian.unchecked_get_u32be(header[8:])
		length := endian.unchecked_get_u32be(header[12:])
		if length > 4096 {
			return false
		}
		data: [4096]u8
		if !receive_all(client, data[:length]) {
			return false
		}
		switch option {
		case NBD_OPTION_EXPORT_NAME:
			reply: [10 + 124]u8
			put_u64(reply[0:], size)
			put_u16(reply[8:], transmission)
			return send_all(client, reply[:no_zeroes ? 10 : len(reply)])
		case NBD_OPTION_GO, NBD_OPTION_INFO:
			info: [12]u8
			put_u16(info[0:], NBD_INFO_EXPORT)
			put_u64(info[2:], size)
			put_u16(info[10:], transmission)
			if !option_reply(client, option, NBD_REPLY_INFO, info[:]) || !option_reply(client, option, NBD_REPLY_ACK, nil) {
				return false
			}
			if option == NBD_OPTION_GO {
				return true
			}
		case NBD_OPTION_ABORT:
			option_reply(client, option, NBD_REPLY_ACK, nil)
			return false
		case:
			// Structured replies, meta contexts, the list of exports: a client
			// goes on without them.
			if !option_reply(client, option, NBD_REPLY_ERROR_UNSUPPORTED, nil) {
				return false
			}
		}
	}
}

// disk_server_serve answers the requests of the transmission until its end.
disk_server_serve :: proc(server: ^Network_Block_Device, client: net.TCP_Socket) {
	data := make([]u8, 32 << 20)
	defer delete(data)
	for !sync.atomic_load(&server.stop) {
		request: [28]u8
		if !receive_all(client, request[:]) {
			return
		}
		flags := endian.unchecked_get_u16be(request[4:])
		kind := endian.unchecked_get_u16be(request[6:])
		cookie := endian.unchecked_get_u64be(request[8:])
		offset := endian.unchecked_get_u64be(request[16:])
		length := u64(endian.unchecked_get_u32be(request[24:]))
		if endian.unchecked_get_u32be(request[0:]) != NBD_REQUEST_MAGIC {
			server.failure = "a request with a wrong magic"
			return
		}
		reply: [16]u8
		put_u32(reply[0:], NBD_SIMPLE_REPLY_MAGIC)
		put_u64(reply[8:], cookie)
		size := u64(len(server.current))
		in_range := offset <= size && length <= size - offset && length <= u64(len(data))
		switch kind {
		case NBD_COMMAND_READ:
			if !in_range {
				put_u32(reply[4:], NBD_ERROR_INVALID)
				send_all(client, reply[:])
				continue
			}
			sync.mutex_lock(&server.lock)
			copy(data[:length], server.current[offset:][:length])
			server.reads += 1
			sync.mutex_unlock(&server.lock)
			if !send_all(client, reply[:]) || !send_all(client, data[:length]) {
				return
			}
		case NBD_COMMAND_WRITE:
			if length > u64(len(data)) || !receive_all(client, data[:length]) {
				return
			}
			if !in_range {
				put_u32(reply[4:], NBD_ERROR_INVALID)
			} else {
				sync.mutex_lock(&server.lock)
				dropped_start, hidden_start := drop_decide(server, offset, data[:length])
				if dropped_start >= 0 {
					// The block that the disk does not keep: the write puts back
					// the bytes that the disk holds there.
					dropped_length := min(format.BLOCK_SIZE, int(length) - dropped_start)
					copy(data[dropped_start:][:dropped_length], server.current[offset + u64(dropped_start):][:dropped_length])
				}
				copy(server.current[offset:][:length], data[:length])
				if hidden_start >= 0 {
					// The block that a read sees and that never becomes durable:
					// the durable part of the write keeps the durable bytes there.
					hidden_length := min(format.BLOCK_SIZE, int(length) - hidden_start)
					copy(data[hidden_start:][:hidden_length], server.durable[offset + u64(hidden_start):][:hidden_length])
				}
				if flags & NBD_COMMAND_FLAG_FUA != 0 {
					// Durable at its reply: the disk keeps it through a loss of
					// power, with no flush.
					copy(server.durable[offset:][:length], data[:length])
				} else {
					append(&server.pending, Pending_Write{offset = offset, bytes = clone_bytes(data[:length])})
				}
				server.writes += 1
				off := server.power_off_after_write != 0 && server.writes >= server.power_off_after_write && offset < ROOT_BLOCK_PLACES * format.BLOCK_SIZE && flags & NBD_COMMAND_FLAG_FUA == 0
				sync.mutex_unlock(&server.lock)
				if off {
					sync.atomic_store(&server.powered_off, true)
					return // No reply: the machine waits for a disk that has no power.
				}
			}
			if !send_all(client, reply[:]) {
				return
			}
		case NBD_COMMAND_FLUSH:
			// Each write that has its reply is durable now.
			sync.mutex_lock(&server.lock)
			for write in server.pending {
				copy(server.durable[write.offset:][:len(write.bytes)], write.bytes)
				delete(write.bytes)
			}
			clear(&server.pending)
			server.flushes += 1
			if server.hide_state == .Root_Written {
				server.hide_state = .Root_Durable
				server.durable_at_hidden_root = clone_bytes(server.durable)
			}
			sync.mutex_unlock(&server.lock)
			if !send_all(client, reply[:]) {
				return
			}
		case NBD_COMMAND_DISCONNECT:
			return
		case:
			put_u32(reply[4:], NBD_ERROR_INVALID)
			if !send_all(client, reply[:]) {
				return
			}
		}
	}
}

clone_bytes :: proc(bytes: []u8) -> []u8 {
	copy_of := make([]u8, len(bytes))
	copy(copy_of, bytes)
	return copy_of
}
