// The arithmetic of the memory map that the boot program reads from the
// firmware (src/md/features/missing_hardware.md, "The stop of the boot
// program"): the size of the buffer that holds the map, and the list of the
// ranges that the kernel receives. It calls no firmware service, so the host
// tests run it.
//
// ```odin
// pages, problem := firmware_memory_map.buffer_pages(needed_bytes, descriptor_size)
// list, fits := firmware_memory_map.list_begin(ranges[:], usable_count)
// kept := firmware_memory_map.list_add(&list, start, page_count, kind)
// ```
package firmware_memory_map

import info "modus:contract/boot_info"

// The descriptor of the UEFI specification is 40 bytes. A firmware can
// state a larger step between two descriptors, never a smaller one: a
// smaller step would read one descriptor over the next.
DESCRIPTOR_SIZE_MINIMUM :: 40
// The descriptors of room past the size that the firmware asks. The
// allocation of the buffer itself splits a free range in two or three, and
// the free of an older buffer can split another: 8 covers both with room.
MARGIN_DESCRIPTORS :: 8
// The reads of the map before the boot program stops: each read that finds
// its buffer too small allocates a larger one, which changes the map again.
// A map that still grows after this count grows with each allocation.
READ_TRY_LIMIT :: 4
// The largest buffer: 4 MiB, about 100 000 descriptors of 40 bytes. A
// firmware that asks more gives a size that no machine has.
BUFFER_PAGE_LIMIT :: 1024
// The room of the list that the kernel receives (Boot_Info.memory_ranges).
RANGE_CAPACITY :: 1024

// The two answers of GetMemoryMap that the boot program reads: the map is
// in the buffer, or the buffer is too small and the size is the one that the
// firmware needs (UEFI specification, "EFI_BOOT_SERVICES.GetMemoryMap()").
EFI_SUCCESS :: u64(0)
EFI_BUFFER_TOO_SMALL :: u64(1) << 63 | 5

// What the boot program does after one read of the map.
Read_Outcome :: enum {
	Read, // The buffer holds the map.
	Larger_Buffer, // The buffer is too small: allocate the size that the firmware asks, then read again.
	Refused, // The firmware refused the read: the boot program stops.
	Still_Growing, // The buffer was too small at READ_TRY_LIMIT reads: the boot program stops.
}

// read_outcome decides after read number `read` (1 for the first) that
// answered `status`. A number of read below 1 or past READ_TRY_LIMIT is
// past the bound: the boot program stops.
read_outcome :: proc "contextless" (read: int, status: u64) -> Read_Outcome {
	if read < 1 || read > READ_TRY_LIMIT {
		return .Still_Growing
	}
	switch status {
	case EFI_SUCCESS:
		return .Read
	case EFI_BUFFER_TOO_SMALL:
		return read < READ_TRY_LIMIT ? .Larger_Buffer : .Still_Growing
	}
	return .Refused
}

// Why a size that the firmware gives has no buffer.
Size_Problem :: enum {
	None,
	Map_Empty, // The firmware asks a buffer of 0 bytes: a map holds one range at least.
	Descriptor_Too_Small, // The step between two descriptors is below DESCRIPTOR_SIZE_MINIMUM.
	Too_Large, // The buffer would pass BUFFER_PAGE_LIMIT.
}

// buffer_pages gives the pages of a buffer for a map of needed_bytes, with
// room for MARGIN_DESCRIPTORS more descriptors of descriptor_size bytes.
// A descriptor_size of 0 is a size that the firmware did not give with its
// answer "too small": the margin then counts descriptors of the minimum
// size. A map that the boot program reads has its own check of the step
// (descriptor_size_valid).
buffer_pages :: proc "contextless" (needed_bytes: u64, descriptor_size: u64) -> (pages: u64, problem: Size_Problem) {
	if needed_bytes == 0 {
		return 0, .Map_Empty
	}
	step := descriptor_size
	if step == 0 {
		step = DESCRIPTOR_SIZE_MINIMUM
	}
	if step < DESCRIPTOR_SIZE_MINIMUM {
		return 0, .Descriptor_Too_Small
	}
	limit := u64(BUFFER_PAGE_LIMIT) * info.PAGE_SIZE
	// Each term is bounded before the sum: no sum wraps.
	if needed_bytes > limit || step > limit / MARGIN_DESCRIPTORS {
		return 0, .Too_Large
	}
	whole := needed_bytes + step * MARGIN_DESCRIPTORS
	if whole > limit {
		return 0, .Too_Large
	}
	return (whole + info.PAGE_SIZE - 1) / info.PAGE_SIZE, .None
}

// descriptor_size_valid says if the step that the firmware gave with a map
// can be walked: at least one descriptor of the specification.
descriptor_size_valid :: proc "contextless" (descriptor_size: u64) -> bool {
	return descriptor_size >= DESCRIPTOR_SIZE_MINIMUM
}

// The list of the ranges that the kernel receives, while the boot program
// fills it.
//
// The kernel reads an address that no range lists as an address that a
// device can hold (device_range in src/kernel/memory.odin): a range of
// memory left out could then be given to a device service. So the list
// keeps each usable range, `Free` and `Boot`, and drops only `Reserved`
// ranges, which the kernel reads as it reads an address of no range.
Range_List :: struct {
	ranges:          []info.Memory_Range, // The room.
	count:           int, // The ranges kept.
	reserved_room:   int, // The Reserved ranges that the room still takes.
	dropped_count:   u64, // The Reserved ranges dropped.
	dropped_pages:   u64, // Their pages; the largest u64 when the sum passes it.
}

// list_begin starts a list in ranges for a map with usable_count ranges
// of the kinds `Free` and `Boot`. The rest of the room goes to Reserved
// ranges. fits is false when the usable ranges alone pass the room, or
// when usable_count is negative: such a map cannot be given whole, and the
// boot program stops.
list_begin :: proc "contextless" (ranges: []info.Memory_Range, usable_count: int) -> (list: Range_List, fits: bool) {
	if usable_count < 0 || usable_count > len(ranges) {
		return {}, false
	}
	return {ranges = ranges, reserved_room = len(ranges) - usable_count}, true
}

// list_add adds one range of the map, in the order of the map. A range
// that follows the last kept one, with the same kind, joins it. A range of
// no page holds no memory: it is left out and not counted. A Reserved range
// past its room is dropped and counted. kept is false for a usable range
// that finds no room: the count given to list_begin was below the usable
// ranges of the map, and the list is not the map.
list_add :: proc "contextless" (list: ^Range_List, start: u64, page_count: u64, kind: info.Memory_Kind) -> (kept: bool) {
	if page_count == 0 {
		return true
	}
	if list.count > 0 {
		last := &list.ranges[list.count - 1]
		// A join whose end would pass the last address is refused: the
		// range then stays a range of its own.
		last_end_fits := last.page_count <= (max(u64) - last.start) / info.PAGE_SIZE
		if last_end_fits && last.kind == kind && last.start + last.page_count * info.PAGE_SIZE == start && page_count <= (max(u64) - last.start) / info.PAGE_SIZE - last.page_count {
			last.page_count += page_count
			return true
		}
	}
	switch kind {
	case .Reserved:
		if list.reserved_room == 0 || list.count == len(list.ranges) {
			list.dropped_count += 1
			list.dropped_pages = page_count > max(u64) - list.dropped_pages ? max(u64) : list.dropped_pages + page_count
			return true
		}
		list.reserved_room -= 1
	case .Free, .Boot:
		if list.count == len(list.ranges) {
			return false
		}
	}
	list.ranges[list.count] = {start = start, page_count = page_count, kind = kind}
	list.count += 1
	return true
}
