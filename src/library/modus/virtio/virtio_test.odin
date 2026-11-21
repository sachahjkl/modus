#+build !freestanding
package virtio

import "core:testing"

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
