#+build !freestanding
#+build !modus
package guest_os

import "core:testing"
import "modus:contract/blake3"
import "modus:contract/byte_order"

// The layout of the queues of a test driver: queue n at 0x1_0000 + n *
// 0x1_0000; its descriptors, then its available ring at +0x1000 and its
// used ring at +0x2000. Buffers start at 0x8_0000.
TEST_VIRTIO_MEMORY :: 1024 * 1024
TEST_QUEUE_SIZE :: 8
TEST_BUFFERS :: u64(0x8_0000)

test_queue_base :: proc(queue: u32) -> u64 {
	return 0x1_0000 + u64(queue) * 0x1_0000
}

test_register :: proc(device: ^Virtio_Device, memory: Guest_Memory, register: Virtio_Register, value: u32) -> bool {
	return virtio_write(device, memory, u64(register), 4, value)
}

// test_driver_start brings a device to DRIVER_OK with its features and its
// queues, as the driver of Linux does.
test_driver_start :: proc(device: ^Virtio_Device, memory: Guest_Memory) {
	test_register(device, memory, .Status, 0)
	test_register(device, memory, .Status, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER)
	features := virtio_device_features(device)
	test_register(device, memory, .Driver_Features_Select, 0)
	test_register(device, memory, .Driver_Features, u32(features))
	test_register(device, memory, .Driver_Features_Select, 1)
	test_register(device, memory, .Driver_Features, u32(features >> 32))
	test_register(device, memory, .Status, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK)
	for queue in 0 ..< virtio_queue_count(device) {
		base := test_queue_base(queue)
		test_register(device, memory, .Queue_Select, queue)
		test_register(device, memory, .Queue_Size, TEST_QUEUE_SIZE)
		test_register(device, memory, .Queue_Descriptor_Low, u32(base))
		test_register(device, memory, .Queue_Driver_Low, u32(base + 0x1000))
		test_register(device, memory, .Queue_Device_Low, u32(base + 0x2000))
		test_register(device, memory, .Queue_Ready, 1)
	}
	test_register(device, memory, .Status, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)
}

Test_Descriptor :: struct {
	address: u64,
	length:  u32,
	flags:   u16,
	next:    u16,
}

// test_submit writes descriptors from index 0, makes the chain at head
// available, and notifies.
test_submit :: proc(device: ^Virtio_Device, memory: Guest_Memory, queue: u32, descriptors: []Test_Descriptor, head: u16 = 0, notify: bool = true) {
	base := test_queue_base(queue)
	for descriptor, index in descriptors {
		at := base + u64(index) * 16
		guest_memory_write_u64(memory, at, descriptor.address)
		guest_memory_write_u32(memory, at + 8, descriptor.length)
		guest_memory_write_u16(memory, at + 12, descriptor.flags)
		guest_memory_write_u16(memory, at + 14, descriptor.next)
	}
	available, _ := guest_memory_read_u16(memory, base + 0x1000 + 2)
	guest_memory_write_u16(memory, base + 0x1000 + 4 + 2 * (u64(available) % TEST_QUEUE_SIZE), head)
	guest_memory_write_u16(memory, base + 0x1000 + 2, available + 1)
	if notify {
		test_register(device, memory, .Queue_Notify, queue)
	}
}

test_used_index :: proc(memory: Guest_Memory, queue: u32) -> u16 {
	value, _ := guest_memory_read_u16(memory, test_queue_base(queue) + 0x2000 + 2)
	return value
}

// test_block_request makes one request of three descriptors: the header,
// the data and the status byte, and gives the status.
test_block_request :: proc(device: ^Virtio_Device, memory: Guest_Memory, type: u32, sector: u64, data_bytes: u32) -> (status: u8) {
	header := TEST_BUFFERS
	data := TEST_BUFFERS + 0x1000
	status_address := TEST_BUFFERS + 0x2_0000
	guest_memory_write_u32(memory, header, type)
	guest_memory_write_u32(memory, header + 4, 0)
	guest_memory_write_u64(memory, header + 8, sector)
	guest_memory_range(memory, status_address, 1)
	memory.bytes[status_address] = 0xAA
	data_flags := type == u32(Virtio_Block_Request.Out) ? VIRTIO_DESCRIPTOR_NEXT : VIRTIO_DESCRIPTOR_NEXT | VIRTIO_DESCRIPTOR_WRITE
	test_submit(device, memory, 0, {{header, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {data, data_bytes, data_flags, 2}, {status_address, 1, VIRTIO_DESCRIPTOR_WRITE, 0}})
	return memory.bytes[status_address]
}

// The transport: the identity of each device, the features that each
// offers, and each access that the specification forbids, refused with no
// change.
@(test)
virtio_transport_refusals :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	disk: [4096]u8
	input := virtio_block_device(disk[:], true, "in")
	output := virtio_block_device(disk[:], false, "out")
	console := virtio_console_device()
	value, ok := virtio_read(&input, u64(Virtio_Register.Magic), 4)
	testing.expect(t, ok && value == VIRTIO_MAGIC)
	value, _ = virtio_read(&input, u64(Virtio_Register.Version), 4)
	testing.expect_value(t, value, u32(2))
	value, _ = virtio_read(&console, u64(Virtio_Register.Device_Identifier), 4)
	testing.expect_value(t, value, u32(3))
	testing.expect_value(t, virtio_device_features(&input), VIRTIO_FEATURE_VERSION_1 | VIRTIO_BLOCK_FEATURE_READ_ONLY)
	testing.expect_value(t, virtio_device_features(&output), VIRTIO_FEATURE_VERSION_1 | VIRTIO_BLOCK_FEATURE_FLUSH)
	value, _ = virtio_configuration_read(&input, 0, 4)
	testing.expect_value(t, value, u32(8)) // 4096 bytes: 8 sectors.
	// Accesses of the wrong size or alignment.
	value, ok = virtio_read(&input, u64(Virtio_Register.Magic), 2)
	testing.expect(t, !ok && value == max(u32))
	_, ok = virtio_read(&input, 2, 4)
	testing.expect(t, !ok)
	_, ok = virtio_configuration_read(&input, 1, 2)
	testing.expect(t, !ok)
	_, ok = virtio_configuration_read(&input, 0, 8)
	testing.expect(t, !ok)
	_, ok = virtio_configuration_read(&input, VIRTIO_WINDOW_BYTES, 4)
	testing.expect(t, !ok)
	testing.expect(t, !virtio_write(&input, memory, u64(Virtio_Register.Status), 1, 1))
	testing.expect(t, !virtio_write(&input, memory, VIRTIO_CONFIG_OFFSET, 4, 0))
	testing.expect(t, !test_register(&input, memory, .Magic, 0))
	testing.expect(t, !virtio_write(&input, memory, 0x0FC + 4, 4, 0)) // In the reserved gap... the configuration.
	testing.expect_value(t, input.status, u32(0))
	// FEATURES_OK holds only for offered features with VERSION_1.
	for features in ([?]u64{0, VIRTIO_BLOCK_FEATURE_READ_ONLY, VIRTIO_FEATURE_VERSION_1 | VIRTIO_BLOCK_FEATURE_FLUSH, VIRTIO_FEATURE_VERSION_1 | 1 << 40}) {
		virtio_reset(&input)
		test_register(&input, memory, .Driver_Features_Select, 0)
		test_register(&input, memory, .Driver_Features, u32(features))
		test_register(&input, memory, .Driver_Features_Select, 1)
		test_register(&input, memory, .Driver_Features, u32(features >> 32))
		test_register(&input, memory, .Status, VIRTIO_STATUS_FEATURES_OK)
		status, _ := virtio_read(&input, u64(Virtio_Register.Status), 4)
		testing.expectf(t, status & VIRTIO_STATUS_FEATURES_OK == 0, "features %x are refused", features)
	}
	// A queue past the count of the device has no size and takes nothing.
	test_register(&input, memory, .Queue_Select, 1)
	value, _ = virtio_read(&input, u64(Virtio_Register.Queue_Size_Most), 4)
	testing.expect_value(t, value, u32(0))
	testing.expect(t, !test_register(&input, memory, .Queue_Size, 8))
	// Each queue that breaks a rule is refused when it becomes ready.
	bad_queues := [?]Virtio_Queue {
		{size = 0, descriptors = 0x1_0000, driver_ring = 0x1_1000, device_ring = 0x1_2000},
		{size = 6, descriptors = 0x1_0000, driver_ring = 0x1_1000, device_ring = 0x1_2000},
		{size = 512, descriptors = 0x1_0000, driver_ring = 0x1_1000, device_ring = 0x1_2000},
		{size = 8, descriptors = 0x1_0008, driver_ring = 0x1_1000, device_ring = 0x1_2000},
		{size = 8, descriptors = 0x1_0000, driver_ring = 0x1_1001, device_ring = 0x1_2000},
		{size = 8, descriptors = 0x1_0000, driver_ring = 0x1_1000, device_ring = 0x1_2002},
		{size = 8, descriptors = TEST_VIRTIO_MEMORY - 64, driver_ring = 0x1_1000, device_ring = 0x1_2000},
		{size = 8, descriptors = 0x1_0000, driver_ring = 0x1_1000, device_ring = 0xFFFF_FFFF_FFFF_FFFC},
	}
	for queue in bad_queues {
		testing.expectf(t, !virtio_queue_valid(queue, memory), "queue %v is refused", queue)
	}
	virtio_reset(&input)
	test_register(&input, memory, .Queue_Size, 6)
	test_register(&input, memory, .Queue_Descriptor_Low, 0x1_0000)
	test_register(&input, memory, .Queue_Driver_Low, 0x1_1000)
	test_register(&input, memory, .Queue_Device_Low, 0x1_2000)
	testing.expect(t, !test_register(&input, memory, .Queue_Ready, 1))
	testing.expect(t, input.status & VIRTIO_STATUS_NEEDS_RESET != 0)
	testing.expect(t, !input.queues[0].ready)
	// The successful case last: a reset clears the failure.
	test_driver_start(&input, memory)
	testing.expect(t, input.status & VIRTIO_STATUS_NEEDS_RESET == 0)
	testing.expect(t, input.queues[0].ready)
	// A ready queue keeps its size and its rings.
	testing.expect(t, !test_register(&input, memory, .Queue_Size, 4))
	testing.expect(t, !test_register(&input, memory, .Queue_Descriptor_Low, 0))
}

// The read-only disk of inputs: every write is refused with Io_Error, at
// every place, and no byte of the disk changes; reads and flushes serve.
@(test)
virtio_read_only_disk_refuses_every_write :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	disk: [8 * 512]u8
	for &value, index in disk {
		value = u8(index * 13)
	}
	original := disk
	device := virtio_block_device(disk[:], true, "modus-inputs")
	test_driver_start(&device, memory)
	for &value in bytes[TEST_BUFFERS + 0x1000:][:4096] {
		value = 0x5A
	}
	writes := [?]struct {
		sector: u64,
		bytes:  u32,
	}{{0, 512}, {3, 1024}, {7, 512}, {8, 512}, {0, 4096}, {0, 100}, {max(u64), 512}, {max(u64) / 512, 512}}
	for write, index in writes {
		status := test_block_request(&device, memory, u32(Virtio_Block_Request.Out), write.sector, write.bytes)
		testing.expectf(t, status == u8(Virtio_Block_Status.Io_Error), "write %v gives %v", write, status)
		testing.expect_value(t, device.writes_refused, u64(index + 1))
	}
	testing.expect(t, disk == original)
	testing.expect_value(t, test_used_index(memory, 0), u16(len(writes)))
	testing.expect(t, device.status & VIRTIO_STATUS_NEEDS_RESET == 0)
	// A flush serves, and the successful read last.
	testing.expect_value(t, test_block_request(&device, memory, u32(Virtio_Block_Request.Flush), 0, 512), u8(Virtio_Block_Status.Ok))
	testing.expect_value(t, test_block_request(&device, memory, u32(Virtio_Block_Request.In), 2, 1024), u8(Virtio_Block_Status.Ok))
	testing.expect(t, string(bytes[TEST_BUFFERS + 0x1000:][:1024]) == string(original[1024:2048]))
	written, _ := guest_memory_read_u32(memory, test_queue_base(0) + 0x2000 + 4 + 8 * (u64(test_used_index(memory, 0) - 1) % TEST_QUEUE_SIZE) + 4)
	testing.expect_value(t, written, u32(1025))
	testing.expect(t, disk == original)
}

// The blank disk of outputs: writes inside the disk change exactly their
// sectors; each range past the disk, each size that is not whole sectors,
// and each overflow of the sector are refused with no change; the hash of
// the disk is the hash of the bytes that the guest wrote.
@(test)
virtio_output_disk_bounds_and_hash :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	disk: [8 * 512]u8
	device := virtio_block_device(disk[:], false, "modus-outputs")
	test_driver_start(&device, memory)
	expected: [8 * 512]u8
	refused := [?]struct {
		sector: u64,
		bytes:  u32,
	}{{8, 512}, {7, 1024}, {0, 4608}, {0, 511}, {1, 513}, {max(u64), 512}, {max(u64) / 512 + 1, 512}, {9, 512}}
	for &value in bytes[TEST_BUFFERS + 0x1000:][:8192] {
		value = 0x77
	}
	for write in refused {
		status := test_block_request(&device, memory, u32(Virtio_Block_Request.Out), write.sector, write.bytes)
		testing.expectf(t, status == u8(Virtio_Block_Status.Io_Error), "write %v gives %v", write, status)
		read_status := test_block_request(&device, memory, u32(Virtio_Block_Request.In), write.sector, write.bytes)
		testing.expectf(t, read_status == u8(Virtio_Block_Status.Io_Error), "read %v gives %v", write, read_status)
	}
	testing.expect(t, disk == expected)
	testing.expect_value(t, device.writes_refused, u64(0))
	testing.expect_value(t, device.requests_refused, u64(2 * len(refused)))
	testing.expect_value(t, test_block_request(&device, memory, 99, 0, 512), u8(Virtio_Block_Status.Unsupported))
	// The successful writes last: the first sector, two in the middle, the last.
	for write in ([?]struct {
			sector: u64,
			bytes:  u32,
			fill:   u8,
		}{{0, 512, 1}, {3, 1024, 2}, {7, 512, 3}}) {
		for &value in bytes[TEST_BUFFERS + 0x1000:][:write.bytes] {
			value = write.fill
		}
		for &value in expected[write.sector * 512:][:write.bytes] {
			value = write.fill
		}
		testing.expect_value(t, test_block_request(&device, memory, u32(Virtio_Block_Request.Out), write.sector, write.bytes), u8(Virtio_Block_Status.Ok))
	}
	testing.expect(t, disk == expected)
	testing.expect_value(t, blake3.hash(disk[:]), blake3.hash(expected[:]))
	testing.expect_value(t, test_block_request(&device, memory, u32(Virtio_Block_Request.Flush), 0, 512), u8(Virtio_Block_Status.Ok))
	testing.expect_value(t, test_block_request(&device, memory, u32(Virtio_Block_Request.Identify), 0, 20), u8(Virtio_Block_Status.Ok))
	testing.expect_value(t, string(bytes[TEST_BUFFERS + 0x1000:][:13]), "modus-outputs")
	testing.expect(t, device.interrupt_status & VIRTIO_INTERRUPT_USED_BUFFER != 0)
}

// Each chain that breaks a rule of the specification ends the device: it
// is not put in the used ring, the device sets DEVICE_NEEDS_RESET, and it
// serves nothing more until a reset.
@(test)
virtio_malformed_chains_refused :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	disk: [8 * 512]u8
	header, data, status := TEST_BUFFERS, TEST_BUFFERS + 0x1000, TEST_BUFFERS + 0x2_0000
	chains := [?][]Test_Descriptor {
		{{header, 16, VIRTIO_DESCRIPTOR_NEXT, 0}}, // A loop on itself.
		{{header, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {data, 512, VIRTIO_DESCRIPTOR_NEXT | VIRTIO_DESCRIPTOR_WRITE, 0}}, // A loop of two.
		{{header, 16, VIRTIO_DESCRIPTOR_NEXT, TEST_QUEUE_SIZE}}, // An index past the queue.
		{{header, 16, VIRTIO_DESCRIPTOR_NEXT | VIRTIO_DESCRIPTOR_INDIRECT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}},
		{{header, 0, VIRTIO_DESCRIPTOR_NEXT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}}, // A buffer of length 0.
		{{TEST_VIRTIO_MEMORY - 8, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}}, // Past the memory.
		{{max(u64) - 4, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}}, // An overflow.
		{{status, 1, VIRTIO_DESCRIPTOR_NEXT | VIRTIO_DESCRIPTOR_WRITE, 1}, {header, 16, 0, 0}}, // Readable after writable.
		{{header, 16, 0, 0}}, // No status byte.
	}
	for chain, index in chains {
		device := virtio_block_device(disk[:], false, "out")
		for &value in bytes[:0x8_0000] {
			value = 0
		}
		test_driver_start(&device, memory)
		guest_memory_write_u32(memory, header, u32(Virtio_Block_Request.Out))
		test_submit(&device, memory, 0, chain)
		testing.expectf(t, device.status & VIRTIO_STATUS_NEEDS_RESET != 0, "chain %v ends the device", index)
		testing.expectf(t, test_used_index(memory, 0) == 0, "chain %v is not used", index)
		testing.expect(t, device.interrupt_status & VIRTIO_INTERRUPT_CONFIGURATION != 0)
		// Nothing is served after it, even a good chain.
		test_submit(&device, memory, 0, {{header, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}})
		testing.expect_value(t, test_used_index(memory, 0), u16(0))
	}
	// The driver says that more chains wait than the ring holds.
	device := virtio_block_device(disk[:], false, "out")
	for &value in bytes[:0x8_0000] {
		value = 0
	}
	test_driver_start(&device, memory)
	guest_memory_write_u16(memory, test_queue_base(0) + 0x1000 + 2, TEST_QUEUE_SIZE + 1)
	test_register(&device, memory, .Queue_Notify, 0)
	testing.expect(t, device.status & VIRTIO_STATUS_NEEDS_RESET != 0)
	testing.expect(t, disk == [8 * 512]u8{})
	// A notify before DRIVER_OK serves nothing.
	other := virtio_block_device(disk[:], false, "out")
	for &value in bytes[:0x8_0000] {
		value = 0
	}
	test_driver_start(&other, memory)
	test_register(&other, memory, .Status, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK)
	guest_memory_write_u32(memory, header, u32(Virtio_Block_Request.Flush))
	test_submit(&other, memory, 0, {{header, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}})
	testing.expect_value(t, test_used_index(memory, 0), u16(0))
	// The successful case last: after a reset, and new rings as a driver
	// makes them, the same device serves.
	for &value in bytes[:0x8_0000] {
		value = 0
	}
	test_driver_start(&device, memory)
	guest_memory_write_u32(memory, header, u32(Virtio_Block_Request.Flush))
	test_submit(&device, memory, 0, {{header, 16, VIRTIO_DESCRIPTOR_NEXT, 1}, {status, 1, VIRTIO_DESCRIPTOR_WRITE, 0}})
	testing.expect_value(t, test_used_index(memory, 0), u16(1))
	testing.expect_value(t, bytes[status], u8(Virtio_Block_Status.Ok))
}

// The console: each chain of the transmit queue is captured in order, the
// capture keeps its bound and counts what it drops, a writable buffer
// there is refused; the receive queue takes input into writable buffers
// only.
@(test)
virtio_console_rings :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	console := virtio_console_device()
	test_driver_start(&console, memory)
	copy(bytes[TEST_BUFFERS:], "hello, ")
	copy(bytes[TEST_BUFFERS + 0x100:], "guest")
	test_submit(&console, memory, 1, {{TEST_BUFFERS, 7, VIRTIO_DESCRIPTOR_NEXT, 1}, {TEST_BUFFERS + 0x100, 5, 0, 0}})
	copy(bytes[TEST_BUFFERS + 0x200:], "\n")
	test_submit(&console, memory, 1, {{TEST_BUFFERS + 0x200, 1, 0, 0}})
	testing.expect_value(t, string(console.console[:console.console_length]), "hello, guest\n")
	testing.expect_value(t, test_used_index(memory, 1), u16(2))
	testing.expect(t, console.interrupt_status & VIRTIO_INTERRUPT_USED_BUFFER != 0)
	virtio_write(&console, memory, u64(Virtio_Register.Interrupt_Acknowledge), 4, VIRTIO_INTERRUPT_USED_BUFFER)
	testing.expect_value(t, console.interrupt_status, u32(0))
	// The capture keeps its bound.
	for _ in 0 ..< 5 {
		test_submit(&console, memory, 1, {{TEST_BUFFERS, 1000, 0, 0}})
	}
	testing.expect_value(t, console.console_length, u32(VIRTIO_CONSOLE_CAPTURE_BYTES))
	testing.expect_value(t, console.console_dropped, u64(13 + 5000 - VIRTIO_CONSOLE_CAPTURE_BYTES))
	// The receive queue: input into a writable buffer.
	test_submit(&console, memory, 0, {{TEST_BUFFERS + 0x1000, 4, VIRTIO_DESCRIPTOR_WRITE, 0}})
	taken := virtio_console_receive(&console, memory, transmute([]u8)string("input"))
	testing.expect_value(t, taken, 4)
	testing.expect_value(t, string(bytes[TEST_BUFFERS + 0x1000:][:4]), "inpu")
	testing.expect_value(t, virtio_console_receive(&console, memory, transmute([]u8)string("t")), 0) // No buffer left.
	// A readable buffer in the receive queue ends the device.
	test_submit(&console, memory, 0, {{TEST_BUFFERS + 0x1000, 4, 0, 0}})
	testing.expect_value(t, virtio_console_receive(&console, memory, transmute([]u8)string("x")), 0)
	testing.expect(t, console.status & VIRTIO_STATUS_NEEDS_RESET != 0)
	// A writable buffer in the transmit queue ends the device too.
	other := virtio_console_device()
	for &value in bytes[:0x8_0000] {
		value = 0
	}
	test_driver_start(&other, memory)
	test_submit(&other, memory, 1, {{TEST_BUFFERS, 4, VIRTIO_DESCRIPTOR_WRITE, 0}})
	testing.expect(t, other.status & VIRTIO_STATUS_NEEDS_RESET != 0)
	testing.expect_value(t, other.console_length, u32(0))
	testing.expect_value(t, test_used_index(memory, 1), u16(0))
	_ = byte_order.read_u16_little_endian
}
// A resize of the console: a size of 0 and a device that is no console are
// refused with nothing changed; a new size changes the configuration and
// its generation, and raises the configuration interrupt only for a driver
// that took VIRTIO_CONSOLE_F_SIZE; the same size again changes nothing.
@(test)
virtio_console_resize_refusals_and_change :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	disk: [512]u8
	block := virtio_block_device(disk[:], true, "test")
	testing.expect(t, !virtio_console_resize(&block, 80, 24))
	testing.expect(t, !virtio_console_resize(nil, 80, 24))

	console := virtio_console_device()
	for size in ([?][2]u16{{0, 24}, {80, 0}, {0, 0}}) {
		testing.expect(t, !virtio_console_resize(&console, size[0], size[1]))
	}
	testing.expect_value(t, console.configuration_generation, u32(0))
	testing.expect_value(t, console.console_cols, VIRTIO_CONSOLE_DEFAULT_COLUMNS)

	// No driver yet: the size changes, and no interrupt rises.
	testing.expect(t, virtio_console_resize(&console, 100, 30))
	testing.expect_value(t, console.interrupt_status, u32(0))
	testing.expect_value(t, console.configuration_generation, u32(1))

	test_driver_start(&console, memory)
	testing.expect(t, virtio_console_resize(&console, max(u16), 1))
	testing.expect(t, console.interrupt_status & VIRTIO_INTERRUPT_CONFIGURATION != 0)
	columns, columns_ok := virtio_read(&console, VIRTIO_CONFIG_OFFSET, 2)
	rows, rows_ok := virtio_read(&console, VIRTIO_CONFIG_OFFSET + 2, 2)
	testing.expect(t, columns_ok && rows_ok)
	testing.expect_value(t, columns, u32(max(u16)))
	testing.expect_value(t, rows, u32(1))
	generation, _ := virtio_read(&console, u64(Virtio_Register.Configuration_Generation), 4)
	testing.expect_value(t, generation, u32(2))

	// The same size again: no new generation and no new interrupt.
	test_register(&console, memory, .Interrupt_Acknowledge, VIRTIO_INTERRUPT_CONFIGURATION)
	testing.expect(t, virtio_console_resize(&console, max(u16), 1))
	testing.expect_value(t, console.configuration_generation, u32(2))
	testing.expect_value(t, console.interrupt_status & VIRTIO_INTERRUPT_CONFIGURATION, u32(0))

	// A driver that did not take the feature gets the size but no interrupt.
	plain := virtio_console_device()
	test_register(&plain, memory, .Status, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER)
	test_register(&plain, memory, .Status, VIRTIO_STATUS_ACKNOWLEDGE | VIRTIO_STATUS_DRIVER | VIRTIO_STATUS_FEATURES_OK | VIRTIO_STATUS_DRIVER_OK)
	testing.expect(t, virtio_console_resize(&plain, 132, 43))
	testing.expect_value(t, plain.interrupt_status & VIRTIO_INTERRUPT_CONFIGURATION, u32(0))
	testing.expect_value(t, plain.console_rows, u16(43))
}
// The capture of the console drains in order: a taker of 0 bytes takes
// nothing, a short taker takes the oldest bytes and leaves the rest, and a
// device that is no console gives nothing. A capture that the taker
// empties takes a burst again.
@(test)
virtio_console_output_drains_in_order :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	console := virtio_console_device()
	test_driver_start(&console, memory)
	copy(bytes[TEST_BUFFERS:], "abcdef")
	test_submit(&console, memory, 1, {{TEST_BUFFERS, 6, 0, 0}})
	out: [4]u8
	testing.expect_value(t, virtio_console_output_take(&console, out[:0]), 0)
	testing.expect_value(t, virtio_console_output_take(nil, out[:]), 0)
	disk: [512]u8
	block := virtio_block_device(disk[:], true, "test")
	testing.expect_value(t, virtio_console_output_take(&block, out[:]), 0)
	testing.expect_value(t, virtio_console_output_take(&console, out[:]), 4)
	testing.expect_value(t, string(out[:]), "abcd")
	testing.expect_value(t, virtio_console_output_take(&console, out[:]), 2)
	testing.expect_value(t, string(out[:2]), "ef")
	testing.expect_value(t, virtio_console_output_take(&console, out[:]), 0)
	for _ in 0 ..< 4 {
		test_submit(&console, memory, 1, {{TEST_BUFFERS, 1024, 0, 0}})
	}
	testing.expect_value(t, console.console_length, u32(VIRTIO_CONSOLE_CAPTURE_BYTES))
	testing.expect_value(t, console.console_dropped, u64(0))
}

// A write past the bound of a writable disk is counted in
// writes_past_bound and changes no byte; a write inside it serves.
@(test)
virtio_output_disk_write_past_bound :: proc(t: ^testing.T) {
	bytes := make([]u8, TEST_VIRTIO_MEMORY)
	defer delete(bytes)
	memory := Guest_Memory{bytes}
	disk: [4 * VIRTIO_SECTOR_BYTES]u8
	output := virtio_block_device(disk[:], false, "out")
	test_driver_start(&output, memory)
	for &value in bytes[TEST_BUFFERS + 0x1000:][:2 * VIRTIO_SECTOR_BYTES] {
		value = 0xEE
	}
	// The last sector and one past it: past the bound.
	status := test_block_request(&output, memory, u32(Virtio_Block_Request.Out), 3, u32(2 * VIRTIO_SECTOR_BYTES))
	testing.expect_value(t, status, u8(Virtio_Block_Status.Io_Error))
	testing.expect(t, output.writes_past_bound > 0, "the write past the bound is counted")
	for value in disk {
		testing.expect_value(t, value, u8(0))
	}
	// The last sector alone: inside the bound.
	past := output.writes_past_bound
	status = test_block_request(&output, memory, u32(Virtio_Block_Request.Out), 3, u32(VIRTIO_SECTOR_BYTES))
	testing.expect_value(t, status, u8(Virtio_Block_Status.Ok))
	testing.expect_value(t, output.writes_past_bound, past)
	testing.expect_value(t, disk[3 * VIRTIO_SECTOR_BYTES], u8(0xEE))
}
