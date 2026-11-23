#+build !freestanding
package virtio

import "core:testing"
import "modus:pci"

// A device whose status is 0 finished its reset.
@(test)
reset_is_done_when_the_status_is_zero :: proc(t: ^testing.T) {
	registers: [64]u8
	device := Device{common = uintptr(&registers[0])}
	testing.expect(t, reset_done(&device))
}

// A device that keeps a status never finishes its reset: the wait ends
// after its count of reads, and start gives the error with no other write.
@(test)
reset_wait_ends_on_a_device_that_keeps_its_status :: proc(t: ^testing.T) {
	registers: [64]u8
	registers[COMMON_STATUS] = STATUS_ACKNOWLEDGE
	device := Device{common = uintptr(&registers[0])}
	testing.expect(t, !reset_done(&device))
	testing.expect_value(t, registers[COMMON_STATUS], u8(STATUS_ACKNOWLEDGE))
}

// start on registers of plain memory: the write of 0 reads back as 0, so
// the reset is done, and the registers have no virtio 1 bit.
@(test)
start_goes_past_a_reset_that_is_done :: proc(t: ^testing.T) {
	registers: [64]u8
	registers[COMMON_STATUS] = STATUS_DRIVER_OK
	device := Device{common = uintptr(&registers[0])}
	_, start_error := start(&device, 0)
	testing.expect_value(t, start_error, Start_Error.No_Version_1)
	testing.expect_value(t, registers[COMMON_STATUS], u8(STATUS_ACKNOWLEDGE | STATUS_DRIVER))
}

// A configuration with one capability at 0x40: its kind, its BAR, its
// place and its length.
@(private = "file")
configuration_with_capability :: proc(kind, bar: u8, place, length: u32) -> (configuration: [pci.CONFIGURATION_SIZE]u8) {
	configuration[pci.OFFSET_CAPABILITIES] = 0x40
	configuration[0x40] = CAPABILITY_VIRTIO
	configuration[0x41] = 0 // No next capability.
	configuration[0x43] = kind
	configuration[0x44] = bar
	(^u32)(&configuration[0x48])^ = place
	(^u32)(&configuration[0x4C])^ = length
	return
}

// The common configuration is found only in a capability of its kind, at
// a BAR of the device, with the length of its registers; a short copy of
// the configuration, a list that starts before 0x40 and a list that loops
// give none.
@(test)
the_common_configuration_is_found_only_where_it_fits :: proc(t: ^testing.T) {
	found_configuration := configuration_with_capability(CAPABILITY_COMMON, 4, 0x3000, COMMON_CONFIG_SIZE)
	bar, place, found := common_place(found_configuration[:])
	testing.expect(t, found && bar == 4 && place == 0x3000)
	refused := [?][pci.CONFIGURATION_SIZE]u8{
		configuration_with_capability(CAPABILITY_NOTIFY, 4, 0x3000, COMMON_CONFIG_SIZE),
		configuration_with_capability(CAPABILITY_COMMON, pci.BAR_COUNT, 0x3000, COMMON_CONFIG_SIZE), // One past the last BAR.
		configuration_with_capability(CAPABILITY_COMMON, 255, 0x3000, COMMON_CONFIG_SIZE),
		configuration_with_capability(CAPABILITY_COMMON, 4, 0x3000, COMMON_CONFIG_SIZE - 1), // One byte short.
		configuration_with_capability(CAPABILITY_COMMON, 4, 0x3000, 0),
	}
	for &configuration in refused {
		_, _, refused_found := common_place(configuration[:])
		testing.expect(t, !refused_found)
	}
	short := found_configuration
	_, _, short_found := common_place(short[:pci.CONFIGURATION_SIZE - 1])
	testing.expect(t, !short_found)
	before := found_configuration
	before[pci.OFFSET_CAPABILITIES] = 0x3C
	_, _, before_found := common_place(before[:])
	testing.expect(t, !before_found)
	// A capability of another kind that names itself as the next one: the
	// walk ends at its bound.
	looping := configuration_with_capability(CAPABILITY_NOTIFY, 4, 0x3000, COMMON_CONFIG_SIZE)
	looping[0x41] = 0x40
	_, _, looping_found := common_place(looping[:])
	testing.expect(t, !looping_found)
}

// A region that the device places fits only inside the memory, and a sum
// that passes the largest value is no fit.
@(test)
a_region_of_the_device_fits_only_inside_the_memory :: proc(t: ^testing.T) {
	testing.expect(t, region_fits(0, 4096, 4096))
	testing.expect(t, region_fits(4094, 2, 4096))
	testing.expect(t, region_fits(4096, 0, 4096))
	testing.expect(t, !region_fits(4095, 2, 4096))
	testing.expect(t, !region_fits(4097, 0, 4096))
	testing.expect(t, !region_fits(8, max(u64) - 4, 4096))
	testing.expect(t, !region_fits(max(u64), 2, 4096))
}

// The size of a queue is the largest power of two that the device offers,
// at most QUEUE_SIZE_LIMIT.
@(test)
the_size_of_a_queue_is_a_power_of_two :: proc(t: ^testing.T) {
	Case :: struct {
		offered, chosen: u32,
	}
	cases := []Case{{0, 0}, {1, 1}, {2, 2}, {3, 2}, {12, 8}, {255, 128}, {QUEUE_SIZE_LIMIT, QUEUE_SIZE_LIMIT}, {QUEUE_SIZE_LIMIT + 1, QUEUE_SIZE_LIMIT}, {u32(max(u16)), QUEUE_SIZE_LIMIT}}
	for item in cases {
		testing.expectf(t, queue_size_choose(item.offered) == item.chosen, "offered %d", item.offered)
	}
}

// queue_start on registers of plain memory: the queue takes the power of
// two under the size that the device offers, and refuses a notify register
// outside the notify registers of the capability.
@(test)
a_queue_refuses_a_notify_register_outside_the_capability :: proc(t: ^testing.T) {
	registers: [64]u8
	notify: [16]u8
	(^u16)(&registers[COMMON_QUEUE_SIZE])^ = 12
	(^u16)(&registers[COMMON_QUEUE_NOTIFY_OFF])^ = 5
	device := Device{common = uintptr(&registers[0]), notify_base = uintptr(&notify[0]), notify_length = size_of(notify), multiplier = 4}
	// 5 * 4 + 2 bytes pass the 16 bytes of the capability.
	_, error := queue_start(&device, 0, 0, 0, 1, 0)
	testing.expect_value(t, error, Queue_Error.Bad_Notify)
	// 3 * 4 + 2 bytes fit.
	(^u16)(&registers[COMMON_QUEUE_NOTIFY_OFF])^ = 3
	queue: Queue
	queue, error = queue_start(&device, 0, 0, 0, 1, 0)
	testing.expect_value(t, error, Queue_Error.None)
	testing.expect_value(t, queue.size, 8)
	testing.expect_value(t, (^u16)(&registers[COMMON_QUEUE_SIZE])^, 8)
	testing.expect_value(t, queue.notify, uintptr(&notify[12]))
	// The largest place that a device can give is no fit either.
	device.multiplier = max(u32)
	(^u16)(&registers[COMMON_QUEUE_NOTIFY_OFF])^ = max(u16)
	_, error = queue_start(&device, 0, 0, 0, 1, 0)
	testing.expect_value(t, error, Queue_Error.Bad_Notify)
}

// A capability of the list of a test configuration: its place, and the
// bytes from its kind on.
@(private = "file")
Extent_Capability :: struct {
	place: u32,
	bytes: []u8,
}

// configuration_with_list links the capabilities in their order, from the
// first place, and ends the list.
@(private = "file")
configuration_with_list :: proc(capabilities: []Extent_Capability) -> (configuration: [pci.CONFIGURATION_SIZE]u8) {
	if len(capabilities) > 0 {
		configuration[pci.OFFSET_CAPABILITIES] = u8(capabilities[0].place)
	}
	for capability, index in capabilities {
		copy(configuration[capability.place:], capability.bytes)
		next := u8(0)
		if index + 1 < len(capabilities) {
			next = u8(capabilities[index + 1].place)
		}
		configuration[capability.place + 1] = next
	}
	return
}

// A virtio capability: kind 9, its type, its BAR, its place and its length.
@(private = "file")
virtio_capability :: proc(kind, bar: u8, place, length: u32) -> []u8 {
	bytes := make([]u8, 16, context.temp_allocator)
	bytes[0], bytes[2], bytes[3], bytes[4] = CAPABILITY_VIRTIO, 16, kind, bar
	(^u32)(&bytes[8])^ = place
	(^u32)(&bytes[12])^ = length
	return bytes
}

// The structures of a GPU as QEMU places them for virtio-vga: the virtio
// structures in the BAR 2, the MSI-X table and its pending bits in the BAR
// 4, a region of shared memory of 64 bits in the BAR 3, and the BAR 0 of
// the video memory with no structure. The extent of a BAR is the end of its
// last structure; a BAR with none has 0.
@(test)
register_extents_are_the_end_of_the_last_structure_of_each_bar :: proc(t: ^testing.T) {
	msi_x := make([]u8, 12, context.temp_allocator)
	msi_x[0] = pci.CAPABILITY_MSI_X
	(^u16)(&msi_x[2])^ = 2 // Three entries.
	(^u32)(&msi_x[4])^ = 0x0000 | 4
	(^u32)(&msi_x[8])^ = 0x0800 | 4
	shared := make([]u8, 24, context.temp_allocator)
	shared[0], shared[2], shared[3], shared[4] = CAPABILITY_VIRTIO, 24, CAPABILITY_SHARED_MEMORY, 3
	(^u32)(&shared[8])^ = 0
	(^u32)(&shared[12])^ = 0
	(^u32)(&shared[16])^ = 0 // Offset 0.
	(^u32)(&shared[20])^ = 1 // Length 1 << 32.
	configuration := configuration_with_list({
		{0x40, msi_x},
		{0x50, virtio_capability(CAPABILITY_COMMON, 2, 0x1000, 0x800)},
		{0x60, virtio_capability(CAPABILITY_ISR, 2, 0x1800, 0x800)},
		{0x70, virtio_capability(CAPABILITY_DEVICE, 2, 0x2000, 0x1000)},
		{0x80, virtio_capability(CAPABILITY_NOTIFY, 2, 0x3000, 0x1000)},
		{0x90, shared},
	})
	extents := register_extents(configuration[:])
	testing.expect_value(t, extents[0], u64(0))
	testing.expect_value(t, extents[1], u64(0))
	testing.expect_value(t, extents[2], u64(0x4000))
	testing.expect_value(t, extents[3], u64(1) << 32)
	testing.expect_value(t, extents[4], u64(0x0800 + 8))
	testing.expect_value(t, extents[5], u64(0))
}

// What places no structure: a BAR past the last one, a length of 0, the
// capability of the access to the configuration (type 5), a region of
// shared memory whose capability is too short for its 64-bit fields, a
// short copy of the configuration, a list that starts before 0x40, and a
// list that loops (the walk ends). An end past 64 bits stays at the
// largest value.
@(test)
register_extents_refuse_what_places_no_structure :: proc(t: ^testing.T) {
	short_shared := virtio_capability(CAPABILITY_SHARED_MEMORY, 1, 0x100, 0x100)
	refused := configuration_with_list({
		{0x40, virtio_capability(CAPABILITY_COMMON, pci.BAR_COUNT, 0x1000, 0x800)},
		{0x50, virtio_capability(CAPABILITY_COMMON, 255, 0x1000, 0x800)},
		{0x60, virtio_capability(CAPABILITY_DEVICE, 1, 0x1000, 0)},
		{0x70, virtio_capability(5, 1, 0x1000, 0x800)},
		{0x80, short_shared},
	})
	testing.expect_value(t, register_extents(refused[:]), [pci.BAR_COUNT]u64{})
	whole := configuration_with_list({{0x40, virtio_capability(CAPABILITY_COMMON, 2, 0x1000, 0x800)}})
	testing.expect_value(t, register_extents(whole[:pci.CONFIGURATION_SIZE - 1]), [pci.BAR_COUNT]u64{})
	before := whole
	before[pci.OFFSET_CAPABILITIES] = 0x3C
	testing.expect_value(t, register_extents(before[:]), [pci.BAR_COUNT]u64{})
	looping := whole
	looping[0x41] = 0x40
	testing.expect_value(t, register_extents(looping[:])[2], u64(0x1800))
	past := configuration_with_list({{0x40, virtio_capability(CAPABILITY_COMMON, 2, max(u32), max(u32))}})
	testing.expect_value(t, register_extents(past[:])[2], u64(max(u32)) + u64(max(u32)))
}
