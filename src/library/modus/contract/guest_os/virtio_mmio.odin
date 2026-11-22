package guest_os

import "modus:contract/byte_order"
import "modus:contract/enum_word"

// Devices of the guest in the form of the virtio specification, version
// 1.2: the transport "virtio over MMIO", version 2, and split virtqueues.
// The process that runs the guest is the device: it reads the rings and
// the buffers of the driver in the memory of the guest, and each value
// there comes from the guest. Each read is checked against the memory, each
// chain of descriptors is bounded by the size of its queue, and a request
// that breaks a rule of the specification ends the device: it sets
// DEVICE_NEEDS_RESET and serves nothing more until the driver resets it.
// No network device exists: a build has no network.

VIRTIO_MAGIC :: u32(0x7472_6976) // "virt"
VIRTIO_TRANSPORT_VERSION :: u32(2)
VIRTIO_VENDOR :: u32(0x5355_444D) // "MDUS"
VIRTIO_QUEUE_SIZE_MOST :: 256
VIRTIO_QUEUES_MOST :: 2
VIRTIO_WINDOW_BYTES :: u64(0x1000) // The guest physical addresses of one device.
VIRTIO_CONFIG_OFFSET :: u64(0x100)
VIRTIO_SECTOR_BYTES :: u64(512)
VIRTIO_CONSOLE_CAPTURE_BYTES :: 4096
VIRTIO_BLOCK_IDENTIFIER_BYTES :: 20

// The registers of the transport (virtio 1.2, 4.2.2).
Virtio_Register :: enum u64 {
	Magic                 = 0x000,
	Version               = 0x004,
	Device_Identifier     = 0x008,
	Vendor_Identifier     = 0x00C,
	Device_Features       = 0x010,
	Device_Features_Select = 0x014,
	Driver_Features       = 0x020,
	Driver_Features_Select = 0x024,
	Queue_Select          = 0x030,
	Queue_Size_Most       = 0x034,
	Queue_Size            = 0x038,
	Queue_Ready           = 0x044,
	Queue_Notify          = 0x050,
	Interrupt_Status      = 0x060,
	Interrupt_Acknowledge = 0x064,
	Status                = 0x070,
	Queue_Descriptor_Low  = 0x080,
	Queue_Descriptor_High = 0x084,
	Queue_Driver_Low      = 0x090,
	Queue_Driver_High     = 0x094,
	Queue_Device_Low      = 0x0A0,
	Queue_Device_High     = 0x0A4,
	Configuration_Generation = 0x0FC,
}

// The kind of a device: its device identifier in the specification.
Virtio_Device_Kind :: enum u32 {
	Block   = 2,
	Console = 3,
}

// The bits of the status register (virtio 1.2, 2.1).
VIRTIO_STATUS_ACKNOWLEDGE :: u32(1)
VIRTIO_STATUS_DRIVER :: u32(2)
VIRTIO_STATUS_DRIVER_OK :: u32(4)
VIRTIO_STATUS_FEATURES_OK :: u32(8)
VIRTIO_STATUS_NEEDS_RESET :: u32(64)
VIRTIO_STATUS_FAILED :: u32(128)

// The feature bits that the devices offer.
VIRTIO_FEATURE_VERSION_1 :: u64(1) << 32
VIRTIO_BLOCK_FEATURE_READ_ONLY :: u64(1) << 5
VIRTIO_BLOCK_FEATURE_FLUSH :: u64(1) << 9

// The interrupt status bits.
VIRTIO_INTERRUPT_USED_BUFFER :: u32(1)
VIRTIO_INTERRUPT_CONFIGURATION :: u32(2)

// The flags of a descriptor.
VIRTIO_DESCRIPTOR_NEXT :: u16(1)
VIRTIO_DESCRIPTOR_WRITE :: u16(2)
VIRTIO_DESCRIPTOR_INDIRECT :: u16(4)

// A request of virtio-blk (virtio 1.2, 5.2.6): its type, in the header.
Virtio_Block_Request :: enum u32 {
	In       = 0,
	Out      = 1,
	Flush    = 4,
	Identify = 8,
}

// The status byte of a request of virtio-blk.
Virtio_Block_Status :: enum u8 {
	Ok          = 0,
	Io_Error    = 1,
	Unsupported = 2,
}

VIRTIO_BLOCK_HEADER_BYTES :: u64(16)

// One split virtqueue, as the driver set it up.
Virtio_Queue :: struct {
	size:           u32,
	ready:          bool,
	descriptors:    u64,
	driver_ring:    u64, // The available ring.
	device_ring:    u64, // The used ring.
	last_available: u16,
	used_index:     u16,
}

// One buffer of a chain: its guest physical range, and whether the device
// writes it.
Chain_Buffer :: struct {
	address:  u64,
	length:   u32,
	writable: bool,
}

// One device: its transport, its queues and what its kind holds.
Virtio_Device :: struct {
	kind:                    Virtio_Device_Kind,
	status:                  u32,
	device_features_select:  u32,
	driver_features_select:  u32,
	driver_features:         u64,
	queue_select:            u32,
	queues:                  [VIRTIO_QUEUES_MOST]Virtio_Queue,
	interrupt_status:        u32,
	// A block device: its disk, and whether the guest may write it.
	disk:                    []u8,
	read_only:               bool,
	identifier:              [VIRTIO_BLOCK_IDENTIFIER_BYTES]u8,
	// A console: what the guest wrote, up to the capture, and the bytes past it.
	console:                 [VIRTIO_CONSOLE_CAPTURE_BYTES]u8,
	console_length:          u32,
	console_dropped:         u64,
	// The counts that the process reads: requests served, writes that a
	// read-only disk refused, requests refused, and chains that broke the
	// rules of the specification.
	requests:                u64,
	writes_refused:          u64,
	requests_refused:        u64,
	malformed_chains:        u64,
	registers_refused:       u64,
	// The chain that is read now: no buffer of it on the stack of the thread.
	chain:                   [VIRTIO_QUEUE_SIZE_MOST]Chain_Buffer,
}

// virtio_block_device makes a block device on a disk. A read-only disk
// offers VIRTIO_BLK_F_RO and refuses each write; a writable disk offers
// VIRTIO_BLK_F_FLUSH. The capacity is the whole sectors of the disk.
virtio_block_device :: proc "contextless" (disk: []u8, read_only: bool, identifier: string) -> (device: Virtio_Device) {
	device.kind = .Block
	device.disk = disk
	device.read_only = read_only
	copy(device.identifier[:], identifier)
	return
}

virtio_console_device :: proc "contextless" () -> (device: Virtio_Device) {
	device.kind = .Console
	return
}

virtio_queue_count :: proc "contextless" (device: ^Virtio_Device) -> u32 {
	switch device.kind {
	case .Block:
		return 1
	case .Console:
		return 2 // The receive queue and the transmit queue of port 0.
	}
	return 0
}

virtio_device_features :: proc "contextless" (device: ^Virtio_Device) -> u64 {
	switch device.kind {
	case .Block:
		return VIRTIO_FEATURE_VERSION_1 | (device.read_only ? VIRTIO_BLOCK_FEATURE_READ_ONLY : VIRTIO_BLOCK_FEATURE_FLUSH)
	case .Console:
		return VIRTIO_FEATURE_VERSION_1
	}
	return 0
}

// virtio_block_capacity gives the capacity of a block device in sectors.
virtio_block_capacity :: proc "contextless" (device: ^Virtio_Device) -> u64 {
	return u64(len(device.disk)) / VIRTIO_SECTOR_BYTES
}

// virtio_reset brings a device to its state after a write of 0 to Status.
virtio_reset :: proc "contextless" (device: ^Virtio_Device) {
	device.status = 0
	device.device_features_select = 0
	device.driver_features_select = 0
	device.driver_features = 0
	device.queue_select = 0
	device.queues = {}
	device.interrupt_status = 0
}

// virtio_fail ends a device after a request that broke a rule: it serves no
// queue until the driver resets it, and the driver learns it by an
// interrupt of configuration change.
virtio_fail :: proc "contextless" (device: ^Virtio_Device) {
	device.malformed_chains += 1
	device.status |= VIRTIO_STATUS_NEEDS_RESET
	device.interrupt_status |= VIRTIO_INTERRUPT_CONFIGURATION
}

// virtio_read gives the value of a read of the window of a device. A read
// of a register of the transport takes 4 bytes; a read of the
// configuration takes 1, 2 or 4 bytes. Each other read is refused: ok is
// false, and the value is all ones, as a read where no device answers.
virtio_read :: proc "contextless" (device: ^Virtio_Device, offset: u64, size: u8) -> (value: u32, ok: bool) {
	if offset >= VIRTIO_CONFIG_OFFSET {
		return virtio_configuration_read(device, offset - VIRTIO_CONFIG_OFFSET, size)
	}
	if size != 4 || offset & 3 != 0 {
		device.registers_refused += 1
		return max(u32), false
	}
	register, known := enum_word.member_of_word(Virtio_Register, offset)
	if !known {
		device.registers_refused += 1
		return 0, true // A reserved register reads as 0.
	}
	queue := virtio_selected_queue(device)
	switch register {
	case .Magic:
		return VIRTIO_MAGIC, true
	case .Version:
		return VIRTIO_TRANSPORT_VERSION, true
	case .Device_Identifier:
		return u32(device.kind), true
	case .Vendor_Identifier:
		return VIRTIO_VENDOR, true
	case .Device_Features:
		features := virtio_device_features(device)
		switch device.device_features_select {
		case 0:
			return u32(features), true
		case 1:
			return u32(features >> 32), true
		}
		return 0, true
	case .Queue_Size_Most:
		return queue == nil ? 0 : VIRTIO_QUEUE_SIZE_MOST, true
	case .Queue_Ready:
		return queue != nil && queue.ready ? 1 : 0, true
	case .Interrupt_Status:
		return device.interrupt_status, true
	case .Status:
		return device.status, true
	case .Configuration_Generation:
		return 0, true // The configuration never changes.
	case .Device_Features_Select, .Driver_Features, .Driver_Features_Select, .Queue_Select, .Queue_Size, .Queue_Notify, .Interrupt_Acknowledge, .Queue_Descriptor_Low, .Queue_Descriptor_High, .Queue_Driver_Low, .Queue_Driver_High, .Queue_Device_Low, .Queue_Device_High:
		return 0, true // The registers that the driver only writes read as 0.
	}
	return 0, true
}

// virtio_write applies a write of the window of a device. A write that is
// not of 4 bytes, or to the configuration, is refused and changes nothing.
virtio_write :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, offset: u64, size: u8, value: u32) -> (ok: bool) {
	if size != 4 || offset & 3 != 0 || offset >= VIRTIO_CONFIG_OFFSET {
		device.registers_refused += 1
		return false
	}
	register, known := enum_word.member_of_word(Virtio_Register, offset)
	if !known {
		device.registers_refused += 1
		return false
	}
	queue := virtio_selected_queue(device)
	switch register {
	case .Device_Features_Select:
		device.device_features_select = value
	case .Driver_Features_Select:
		device.driver_features_select = value
	case .Driver_Features:
		// Features change only before FEATURES_OK.
		if device.status & VIRTIO_STATUS_FEATURES_OK != 0 {
			device.registers_refused += 1
			return false
		}
		switch device.driver_features_select {
		case 0:
			device.driver_features = device.driver_features & 0xFFFF_FFFF_0000_0000 | u64(value)
		case 1:
			device.driver_features = device.driver_features & 0xFFFF_FFFF | u64(value) << 32
		case:
			if value != 0 {
				device.registers_refused += 1
				return false
			}
		}
	case .Queue_Select:
		device.queue_select = value
	case .Queue_Size:
		if queue == nil || queue.ready {
			device.registers_refused += 1
			return false
		}
		queue.size = value
	case .Queue_Descriptor_Low, .Queue_Descriptor_High, .Queue_Driver_Low, .Queue_Driver_High, .Queue_Device_Low, .Queue_Device_High:
		if queue == nil || queue.ready {
			device.registers_refused += 1
			return false
		}
		target := &queue.device_ring
		if register == .Queue_Descriptor_Low || register == .Queue_Descriptor_High {
			target = &queue.descriptors
		} else if register == .Queue_Driver_Low || register == .Queue_Driver_High {
			target = &queue.driver_ring
		}
		if offset & 4 == 0 {
			target^ = target^ & 0xFFFF_FFFF_0000_0000 | u64(value)
		} else {
			target^ = target^ & 0xFFFF_FFFF | u64(value) << 32
		}
	case .Queue_Ready:
		if queue == nil {
			device.registers_refused += 1
			return false
		}
		if value == 0 {
			queue.ready = false
			return true
		}
		if !virtio_queue_valid(queue^, memory) {
			virtio_fail(device)
			return false
		}
		queue.ready = true
	case .Queue_Notify:
		virtio_notify(device, memory, value)
	case .Interrupt_Acknowledge:
		device.interrupt_status &~= value
	case .Status:
		if value == 0 {
			virtio_reset(device)
			return true
		}
		// FEATURES_OK holds only for features that the device offers, with
		// VERSION_1, which the transport of version 2 needs.
		if value & VIRTIO_STATUS_FEATURES_OK != 0 && device.status & VIRTIO_STATUS_FEATURES_OK == 0 {
			offered := virtio_device_features(device)
			if device.driver_features &~ offered != 0 || device.driver_features & VIRTIO_FEATURE_VERSION_1 == 0 {
				device.status = value &~ VIRTIO_STATUS_FEATURES_OK | device.status & VIRTIO_STATUS_NEEDS_RESET
				return true
			}
		}
		device.status = value | device.status & VIRTIO_STATUS_NEEDS_RESET
	case .Magic, .Version, .Device_Identifier, .Vendor_Identifier, .Device_Features, .Queue_Size_Most, .Interrupt_Status, .Configuration_Generation:
		device.registers_refused += 1 // A register that the driver only reads.
		return false
	}
	return true
}

virtio_selected_queue :: proc "contextless" (device: ^Virtio_Device) -> ^Virtio_Queue {
	if device.queue_select >= virtio_queue_count(device) {
		return nil
	}
	return &device.queues[device.queue_select]
}

// virtio_queue_valid checks a queue before it is ready: a size that is a
// power of two up to the most, rings aligned as the specification says,
// and each ring inside the memory of the guest.
virtio_queue_valid :: proc "contextless" (queue: Virtio_Queue, memory: Guest_Memory) -> bool {
	size := u64(queue.size)
	if size == 0 || size > VIRTIO_QUEUE_SIZE_MOST || size & (size - 1) != 0 {
		return false
	}
	if queue.descriptors & 15 != 0 || queue.driver_ring & 1 != 0 || queue.device_ring & 3 != 0 {
		return false
	}
	_, descriptors_inside := guest_memory_range(memory, queue.descriptors, 16 * size)
	_, driver_inside := guest_memory_range(memory, queue.driver_ring, 6 + 2 * size)
	_, device_inside := guest_memory_range(memory, queue.device_ring, 6 + 8 * size)
	return descriptors_inside && driver_inside && device_inside
}

// virtio_configuration_read reads the configuration of a device: for a
// block device, its capacity in sectors in the first 8 bytes; each other
// byte is 0.
virtio_configuration_read :: proc "contextless" (device: ^Virtio_Device, offset: u64, size: u8) -> (value: u32, ok: bool) {
	if size != 1 && size != 2 && size != 4 || offset & u64(size - 1) != 0 || offset + u64(size) > VIRTIO_WINDOW_BYTES - VIRTIO_CONFIG_OFFSET {
		device.registers_refused += 1
		return max(u32), false
	}
	configuration: [16]u8
	if device.kind == .Block {
		byte_order.write_u64_little_endian(configuration[:], 0, virtio_block_capacity(device))
	}
	for index in 0 ..< u64(size) {
		if offset + index < len(configuration) {
			value |= u32(configuration[offset + index]) << (index * 8)
		}
	}
	return value, true
}

// virtio_notify serves the queue that a driver names. A device that
// failed, a driver that is not ready, or a queue that is not ready gets
// nothing: the specification forbids the notify then.
virtio_notify :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, queue_index: u32) {
	if device.status & VIRTIO_STATUS_NEEDS_RESET != 0 || device.status & VIRTIO_STATUS_DRIVER_OK == 0 || queue_index >= virtio_queue_count(device) {
		return
	}
	queue := &device.queues[queue_index]
	if !queue.ready {
		return
	}
	switch device.kind {
	case .Block:
		virtio_queue_serve(device, memory, queue)
	case .Console:
		if queue_index == 1 {
			virtio_queue_serve(device, memory, queue)
		}
		// The receive queue waits for input: virtio_console_receive fills it.
	}
}

// virtio_chain_read reads the chain of descriptors that starts at head
// into device.chain. The readable buffers come first, then the writable
// ones; a chain longer than its queue (a loop), an index past the queue, an
// indirect descriptor (not offered), a buffer of length 0 or a buffer
// outside the memory is refused.
virtio_chain_read :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, queue: ^Virtio_Queue, head: u16) -> (count: int, readable_bytes: u64, writable_bytes: u64, ok: bool) {
	index := u64(head)
	writable_seen := false
	for {
		if index >= u64(queue.size) || count >= int(queue.size) {
			return 0, 0, 0, false
		}
		descriptor := queue.descriptors + index * 16
		address := guest_memory_read_u64(memory, descriptor) or_return
		length := guest_memory_read_u32(memory, descriptor + 8) or_return
		flags := guest_memory_read_u16(memory, descriptor + 12) or_return
		next := guest_memory_read_u16(memory, descriptor + 14) or_return
		if flags & VIRTIO_DESCRIPTOR_INDIRECT != 0 || length == 0 {
			return 0, 0, 0, false
		}
		if _, inside := guest_memory_range(memory, address, u64(length)); !inside {
			return 0, 0, 0, false
		}
		writable := flags & VIRTIO_DESCRIPTOR_WRITE != 0
		if writable {
			writable_seen = true
			writable_bytes += u64(length)
		} else {
			if writable_seen {
				return 0, 0, 0, false
			}
			readable_bytes += u64(length)
		}
		device.chain[count] = {address = address, length = length, writable = writable}
		count += 1
		if flags & VIRTIO_DESCRIPTOR_NEXT == 0 {
			return count, readable_bytes, writable_bytes, true
		}
		index = u64(next)
	}
}

// chain_copy_out copies bytes from the readable buffers of a chain, from
// the offset in their concatenation, into out.
chain_copy_out :: proc "contextless" (memory: Guest_Memory, chain: []Chain_Buffer, offset: u64, out: []u8) {
	skip := offset
	done := 0
	for buffer in chain {
		if buffer.writable || done >= len(out) {
			break
		}
		length := u64(buffer.length)
		if skip >= length {
			skip -= length
			continue
		}
		bytes, _ := guest_memory_range(memory, buffer.address + skip, length - skip)
		done += copy(out[done:], bytes)
		skip = 0
	}
}

// chain_copy_in copies bytes into the writable buffers of a chain, at the
// offset in their concatenation.
chain_copy_in :: proc "contextless" (memory: Guest_Memory, chain: []Chain_Buffer, offset: u64, bytes: []u8) {
	skip := offset
	done := 0
	for buffer in chain {
		if !buffer.writable {
			continue
		}
		if done >= len(bytes) {
			break
		}
		length := u64(buffer.length)
		if skip >= length {
			skip -= length
			continue
		}
		target, _ := guest_memory_range(memory, buffer.address + skip, length - skip)
		done += copy(target, bytes[done:])
		skip = 0
	}
}

// virtio_queue_serve serves each chain that the driver made available
// since the last notify, and puts each in the used ring.
virtio_queue_serve :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, queue: ^Virtio_Queue) {
	available, readable := guest_memory_read_u16(memory, queue.driver_ring + 2)
	if !readable {
		virtio_fail(device)
		return
	}
	pending := available - queue.last_available
	if u32(pending) > queue.size {
		virtio_fail(device) // The driver says that more chains wait than the ring holds.
		return
	}
	served := false
	for _ in 0 ..< pending {
		slot := u64(queue.last_available) % u64(queue.size)
		head, head_read := guest_memory_read_u16(memory, queue.driver_ring + 4 + 2 * slot)
		if !head_read {
			virtio_fail(device)
			break
		}
		count, readable_bytes, writable_bytes, chain_ok := virtio_chain_read(device, memory, queue, head)
		if !chain_ok {
			virtio_fail(device)
			break
		}
		written: u64
		served_ok: bool
		switch device.kind {
		case .Block:
			written, served_ok = virtio_block_serve(device, memory, device.chain[:count], readable_bytes, writable_bytes)
		case .Console:
			written, served_ok = virtio_console_transmit(device, memory, device.chain[:count], writable_bytes)
		}
		if !served_ok {
			virtio_fail(device)
			break
		}
		virtio_used_put(memory, queue, head, u32(written))
		queue.last_available += 1
		served = true
	}
	if served {
		device.interrupt_status |= VIRTIO_INTERRUPT_USED_BUFFER
	}
}

// virtio_used_put adds one element to the used ring: the head of the chain
// and the bytes that the device wrote. The ring was checked inside the
// memory when the queue became ready.
virtio_used_put :: proc "contextless" (memory: Guest_Memory, queue: ^Virtio_Queue, head: u16, written: u32) {
	slot := u64(queue.used_index) % u64(queue.size)
	_ = guest_memory_write_u32(memory, queue.device_ring + 4 + 8 * slot, u32(head))
	_ = guest_memory_write_u32(memory, queue.device_ring + 8 + 8 * slot, written)
	queue.used_index += 1
	_ = guest_memory_write_u16(memory, queue.device_ring + 2, queue.used_index)
}

// virtio_block_serve serves one request of virtio-blk. A request with no
// status byte cannot be answered: it breaks the rules (false). Each other
// request gets its status in its last writable byte: a write to a
// read-only disk, a range past the disk, or data that is not whole sectors
// gets Io_Error and changes no byte of the disk; an unknown type gets
// Unsupported.
virtio_block_serve :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, chain: []Chain_Buffer, readable_bytes: u64, writable_bytes: u64) -> (written: u64, ok: bool) {
	if writable_bytes == 0 {
		return 0, false
	}
	device.requests += 1
	status_offset := writable_bytes - 1
	status := Virtio_Block_Status.Io_Error
	written = 1
	if readable_bytes < VIRTIO_BLOCK_HEADER_BYTES {
		device.requests_refused += 1
	} else {
		header: [VIRTIO_BLOCK_HEADER_BYTES]u8
		chain_copy_out(memory, chain, 0, header[:])
		type_word := byte_order.read_u32_little_endian(header[:], 0)
		sector := byte_order.read_u64_little_endian(header[:], 8)
		capacity := virtio_block_capacity(device)
		request, known := enum_word.member_of_word(Virtio_Block_Request, u64(type_word))
		if !known {
			status = .Unsupported
			device.requests_refused += 1
		} else {
			switch request {
			case .In:
				data := status_offset
				if virtio_sectors_inside(sector, data, capacity) && readable_bytes == VIRTIO_BLOCK_HEADER_BYTES {
					chain_copy_in(memory, chain, 0, device.disk[sector * VIRTIO_SECTOR_BYTES:][:data])
					written += data
					status = .Ok
				} else {
					device.requests_refused += 1
				}
			case .Out:
				data := readable_bytes - VIRTIO_BLOCK_HEADER_BYTES
				if device.read_only {
					device.writes_refused += 1
				} else if virtio_sectors_inside(sector, data, capacity) && writable_bytes == 1 {
					chain_copy_out(memory, chain, VIRTIO_BLOCK_HEADER_BYTES, device.disk[sector * VIRTIO_SECTOR_BYTES:][:data])
					status = .Ok
				} else {
					device.requests_refused += 1
				}
			case .Flush:
				status = .Ok
			case .Identify:
				count := min(status_offset, VIRTIO_BLOCK_IDENTIFIER_BYTES)
				chain_copy_in(memory, chain, 0, device.identifier[:count])
				written += count
				status = .Ok
			}
		}
	}
	status_byte := [1]u8{u8(status)}
	chain_copy_in(memory, chain, status_offset, status_byte[:])
	return written, true
}

// virtio_sectors_inside says if bytes of data from a sector are whole
// sectors inside the capacity, with no overflow.
virtio_sectors_inside :: proc "contextless" (sector: u64, data_bytes: u64, capacity: u64) -> bool {
	if data_bytes == 0 || data_bytes % VIRTIO_SECTOR_BYTES != 0 {
		return false
	}
	sectors := data_bytes / VIRTIO_SECTOR_BYTES
	return sector <= capacity && sectors <= capacity - sector
}

// virtio_console_transmit takes the bytes of one chain of the transmit
// queue. A writable buffer there breaks the rules.
virtio_console_transmit :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, chain: []Chain_Buffer, writable_bytes: u64) -> (written: u64, ok: bool) {
	if writable_bytes != 0 {
		return 0, false
	}
	device.requests += 1
	for buffer in chain {
		bytes, _ := guest_memory_range(memory, buffer.address, u64(buffer.length))
		room := VIRTIO_CONSOLE_CAPTURE_BYTES - int(device.console_length)
		taken := min(room, len(bytes))
		copy(device.console[device.console_length:], bytes[:taken])
		device.console_length += u32(taken)
		device.console_dropped += u64(len(bytes) - taken)
	}
	return 0, true
}

// virtio_console_receive gives input bytes to the guest through the
// receive queue, one chain at a time, and gives the count that the guest
// had room for. A readable buffer in a chain of the receive queue breaks
// the rules.
virtio_console_receive :: proc "contextless" (device: ^Virtio_Device, memory: Guest_Memory, input: []u8) -> (taken: int) {
	if device.kind != .Console || device.status & VIRTIO_STATUS_NEEDS_RESET != 0 || device.status & VIRTIO_STATUS_DRIVER_OK == 0 {
		return 0
	}
	queue := &device.queues[0]
	if !queue.ready {
		return 0
	}
	for taken < len(input) {
		available, readable := guest_memory_read_u16(memory, queue.driver_ring + 2)
		if !readable || available == queue.last_available {
			break
		}
		if u32(available - queue.last_available) > queue.size {
			virtio_fail(device)
			break
		}
		slot := u64(queue.last_available) % u64(queue.size)
		head, head_read := guest_memory_read_u16(memory, queue.driver_ring + 4 + 2 * slot)
		if !head_read {
			virtio_fail(device)
			break
		}
		count, readable_bytes, writable_bytes, chain_ok := virtio_chain_read(device, memory, queue, head)
		if !chain_ok || readable_bytes != 0 {
			virtio_fail(device)
			break
		}
		part := input[taken:][:min(u64(len(input) - taken), writable_bytes)]
		chain_copy_in(memory, device.chain[:count], 0, part)
		virtio_used_put(memory, queue, head, u32(len(part)))
		queue.last_available += 1
		taken += len(part)
		device.interrupt_status |= VIRTIO_INTERRUPT_USED_BUFFER
	}
	return taken
}
