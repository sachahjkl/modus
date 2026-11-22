#+build !freestanding
package firmware_memory_map

import info "modus:contract/boot_info"
import "core:testing"

// The size of a buffer: the refusals first, each with no pages. A map of 0
// bytes, a step of 1 byte and one byte below the minimum, a map one byte
// past the limit, the largest map and the largest step, and a sum of the
// map and its margin one byte past the limit.
@(test)
a_size_that_has_no_buffer_is_refused :: proc(t: ^testing.T) {
	limit := u64(BUFFER_PAGE_LIMIT) * info.PAGE_SIZE
	Refusal :: struct {
		needed_bytes:    u64,
		descriptor_size: u64,
		problem:         Size_Problem,
	}
	refusals := [?]Refusal {
		{0, DESCRIPTOR_SIZE_MINIMUM, .Map_Empty},
		{0, 0, .Map_Empty},
		{DESCRIPTOR_SIZE_MINIMUM, 1, .Descriptor_Too_Small},
		{DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM - 1, .Descriptor_Too_Small},
		{limit + 1, DESCRIPTOR_SIZE_MINIMUM, .Too_Large},
		{max(u64), DESCRIPTOR_SIZE_MINIMUM, .Too_Large},
		{DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MAXIMUM + 1, .Descriptor_Too_Large},
		{DESCRIPTOR_SIZE_MINIMUM, max(u64), .Descriptor_Too_Large},
		{limit - DESCRIPTOR_SIZE_MAXIMUM * MARGIN_DESCRIPTORS + 1, DESCRIPTOR_SIZE_MAXIMUM, .Too_Large},
		{limit - DESCRIPTOR_SIZE_MINIMUM * MARGIN_DESCRIPTORS + 1, DESCRIPTOR_SIZE_MINIMUM, .Too_Large},
		{limit, DESCRIPTOR_SIZE_MINIMUM, .Too_Large},
	}
	for refusal in refusals {
		pages, problem := buffer_pages(refusal.needed_bytes, refusal.descriptor_size)
		testing.expectf(t, problem == refusal.problem && pages == 0, "a map of %d bytes with a step of %d gives %d pages and %v, not %v", refusal.needed_bytes, refusal.descriptor_size, pages, problem, refusal.problem)
	}
}

// The size of a buffer holds the map and its margin, on whole pages: one
// byte, one descriptor, a map that fills one page with its margin and one
// byte more, a step that the firmware did not give, and the limit exactly.
@(test)
a_buffer_holds_the_map_and_its_margin :: proc(t: ^testing.T) {
	limit := u64(BUFFER_PAGE_LIMIT) * info.PAGE_SIZE
	margin := u64(DESCRIPTOR_SIZE_MINIMUM * MARGIN_DESCRIPTORS)
	Case :: struct {
		needed_bytes:    u64,
		descriptor_size: u64,
		pages:           u64,
	}
	cases := [?]Case {
		{1, DESCRIPTOR_SIZE_MINIMUM, 1},
		{DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM, 1},
		{info.PAGE_SIZE - margin, DESCRIPTOR_SIZE_MINIMUM, 1},
		{info.PAGE_SIZE - margin + 1, DESCRIPTOR_SIZE_MINIMUM, 2},
		// With no step from the firmware, the margin counts descriptors of
		// the minimum size.
		{info.PAGE_SIZE - margin, 0, 1},
		{info.PAGE_SIZE - margin + 1, 0, 2},
		// A larger step gives a larger margin.
		{info.PAGE_SIZE - margin, DESCRIPTOR_SIZE_MINIMUM + 8, 2},
		{limit - margin, DESCRIPTOR_SIZE_MINIMUM, BUFFER_PAGE_LIMIT},
		// The largest step: its margin is 8 pages.
		{info.PAGE_SIZE, DESCRIPTOR_SIZE_MAXIMUM, 1 + MARGIN_DESCRIPTORS * DESCRIPTOR_SIZE_MAXIMUM / info.PAGE_SIZE},
	}
	for one in cases {
		pages, problem := buffer_pages(one.needed_bytes, one.descriptor_size)
		testing.expectf(t, problem == .None && pages == one.pages, "a map of %d bytes with a step of %d gives %d pages and %v, not %d pages", one.needed_bytes, one.descriptor_size, pages, problem, one.pages)
		step := one.descriptor_size == 0 ? u64(DESCRIPTOR_SIZE_MINIMUM) : one.descriptor_size
		testing.expectf(t, pages * info.PAGE_SIZE >= one.needed_bytes + step * MARGIN_DESCRIPTORS, "%d pages hold the map of %d bytes and its margin", pages, one.needed_bytes)
	}
}

// A step that the boot program walks. Refused first: 0, 1 and one below
// the minimum; one past the maximum and the largest u64; a step larger than
// the map, by one byte, and a map of 0 bytes. Then the minimum, the
// maximum, and a step equal to the map are taken.
@(test)
a_step_that_is_not_one_descriptor_is_refused :: proc(t: ^testing.T) {
	MAP :: 64 * DESCRIPTOR_SIZE_MAXIMUM
	for size in ([]u64{0, 1, DESCRIPTOR_SIZE_MINIMUM - 1, DESCRIPTOR_SIZE_MAXIMUM + 1, max(u64)}) {
		testing.expectf(t, !descriptor_size_valid(size, MAP), "a step of %d bytes is taken", size)
	}
	testing.expect(t, !descriptor_size_valid(DESCRIPTOR_SIZE_MINIMUM + 1, DESCRIPTOR_SIZE_MINIMUM), "a step one byte larger than the map is taken")
	testing.expect(t, !descriptor_size_valid(DESCRIPTOR_SIZE_MINIMUM, 0), "a step in a map of 0 bytes is taken")
	for size in ([]u64{DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM + 8, DESCRIPTOR_SIZE_MAXIMUM}) {
		testing.expectf(t, descriptor_size_valid(size, MAP), "a step of %d bytes is refused", size)
	}
	testing.expect(t, descriptor_size_valid(DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM), "a map of one descriptor is refused")
}

// The walk by index never leaves the map: each descriptor that it reads
// ends inside it. A step of 0 gives none; a map shorter than one step gives
// none; a map with a cut descriptor at its end leaves that one out.
@(test)
the_walk_of_the_map_stays_inside_it :: proc(t: ^testing.T) {
	testing.expect_value(t, descriptor_count(DESCRIPTOR_SIZE_MAXIMUM, 0), 0)
	testing.expect_value(t, descriptor_count(DESCRIPTOR_SIZE_MINIMUM - 1, DESCRIPTOR_SIZE_MINIMUM), 0)
	testing.expect_value(t, descriptor_count(0, DESCRIPTOR_SIZE_MINIMUM), 0)
	testing.expect_value(t, descriptor_count(3 * DESCRIPTOR_SIZE_MINIMUM - 1, DESCRIPTOR_SIZE_MINIMUM), 2)
	testing.expect_value(t, descriptor_count(3 * DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM), 3)
	for map_bytes in ([]u64{DESCRIPTOR_SIZE_MAXIMUM, 5 * DESCRIPTOR_SIZE_MAXIMUM - 1, u64(BUFFER_PAGE_LIMIT) * info.PAGE_SIZE}) {
		for step in ([]u64{DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM + 8, DESCRIPTOR_SIZE_MAXIMUM}) {
			count := descriptor_count(map_bytes, step)
			testing.expectf(t, count * step <= map_bytes && (count + 1) * step > map_bytes, "a map of %d bytes with a step of %d gives %d descriptors", map_bytes, step, count)
		}
	}
}

// The size of a read that succeeded: one byte past the buffer and the
// largest u64 are refused; a map that fills the buffer, and a smaller one,
// are taken.
@(test)
a_map_larger_than_its_buffer_is_refused :: proc(t: ^testing.T) {
	BUFFER :: 4 * info.PAGE_SIZE
	testing.expect(t, !map_size_valid(BUFFER + 1, BUFFER), "a map one byte past its buffer is taken")
	testing.expect(t, !map_size_valid(max(u64), BUFFER), "the largest size is taken")
	testing.expect(t, !map_size_valid(1, 0), "a map in no buffer is taken")
	testing.expect(t, map_size_valid(BUFFER, BUFFER), "a map that fills its buffer is refused")
	testing.expect(t, map_size_valid(DESCRIPTOR_SIZE_MINIMUM, BUFFER), "a map smaller than its buffer is refused")
}

// The reads of the map are bounded. The refusals first: a read number of
// 0, a negative one, one past the bound and the largest one stop, whatever
// the firmware answered; a status that is neither success nor "too small"
// stops; "too small" at the last read stops. Then a read that allocates a
// buffer is followed by one more, and a success is read.
@(test)
the_reads_of_the_map_are_bounded :: proc(t: ^testing.T) {
	for read in ([]int{0, -1, READ_TRY_LIMIT + 1, max(int), min(int)}) {
		for status in ([]u64{EFI_SUCCESS, EFI_BUFFER_TOO_SMALL}) {
			testing.expectf(t, read_outcome(read, status) == .Still_Growing, "read %d with status %X does not stop", read, status)
		}
	}
	for status in ([]u64{1, EFI_BUFFER_TOO_SMALL + 1, EFI_BUFFER_TOO_SMALL - 1, u64(1) << 63, 5, max(u64)}) {
		for read in 1 ..= READ_TRY_LIMIT {
			testing.expectf(t, read_outcome(read, status) == .Refused, "read %d with status %X is not refused", read, status)
		}
	}
	testing.expect_value(t, read_outcome(READ_TRY_LIMIT, EFI_BUFFER_TOO_SMALL), Read_Outcome.Still_Growing)
	testing.expect(t, READ_TRY_LIMIT >= 2, "a read that allocates a buffer is followed by one more")
	for read in 1 ..< READ_TRY_LIMIT {
		testing.expect_value(t, read_outcome(read, EFI_BUFFER_TOO_SMALL), Read_Outcome.Larger_Buffer)
	}
	for read in 1 ..= READ_TRY_LIMIT {
		testing.expect_value(t, read_outcome(read, EFI_SUCCESS), Read_Outcome.Read)
	}
}

// added says if list_add gave the status Added.
@(private = "file")
added :: proc(list: ^Range_List, start: u64, page_count: u64, kind: info.Memory_Kind) -> bool {
	return list_add(list, start, page_count, kind) == .Added
}

// The usable ranges that pass the room are refused before any range is
// added: one more than the room, a negative count. Each refused list is
// empty.
@(test)
a_map_whose_usable_ranges_pass_the_room_is_refused :: proc(t: ^testing.T) {
	room: [4]info.Memory_Range
	for usable in ([]int{len(room) + 1, -1, max(int)}) {
		list, fits := list_begin(room[:], usable)
		testing.expectf(t, !fits && list.ranges == nil && list.count == 0, "a map with %d usable ranges in a room of %d is taken", usable, len(room))
	}
	empty: []info.Memory_Range
	_, fits := list_begin(empty, 1)
	testing.expect(t, !fits, "one usable range in no room is taken")
}

// A usable range past the count that list_begin got finds no room: the
// list refuses it, and the ranges that it kept do not change.
@(test)
a_usable_range_past_its_count_is_refused :: proc(t: ^testing.T) {
	room: [2]info.Memory_Range
	list, fits := list_begin(room[:], 2)
	testing.expect(t, fits)
	testing.expect(t, added(&list, 0, 1, .Free))
	testing.expect(t, added(&list, 8 * info.PAGE_SIZE, 1, .Boot))
	before := room
	testing.expect_value(t, list_add(&list, 16 * info.PAGE_SIZE, 1, .Free), Add_Status.No_Room)
	testing.expect_value(t, list.count, 2)
	for range, index in room {
		testing.expectf(t, range == before[index], "a refused range changed the kept range %d", index)
	}
	testing.expect_value(t, list.dropped_count, 0)
}

// Ranges that do not follow each other, of 0 ranges, exactly the room,
// and one more than the room: the Reserved range past the room is dropped
// and counted with its pages; no usable range is dropped.
@(test)
the_reserved_ranges_past_the_room_are_counted :: proc(t: ^testing.T) {
	ROOM :: RANGE_CAPACITY
	room := new([ROOM]info.Memory_Range)
	defer free(room)
	// One more usable range than the room: refused before any range.
	_, fits_past := list_begin(room^[:], ROOM + 1)
	testing.expect(t, !fits_past, "a map of 1025 usable ranges in a room of 1024 is taken")
	// 0 ranges.
	list, fits := list_begin(room^[:], 0)
	testing.expect(t, fits)
	testing.expect_value(t, list.count, 0)
	testing.expect_value(t, list.dropped_count, 0)
	// Exactly the room of usable ranges is taken.
	_, fits_whole := list_begin(room^[:], ROOM)
	testing.expect(t, fits_whole, "a map of 1024 usable ranges in a room of 1024 is refused")
	// Each range is 1 page, with a gap of 1 page after it, so none joins.
	add_reserved :: proc(list: ^Range_List, index: u64, pages: u64) -> bool {
		return added(list, index * 2 * info.PAGE_SIZE + 0x1000_0000, pages, .Reserved)
	}
	// Exactly the room: one usable range, then ROOM - 1 Reserved ones.
	list, fits = list_begin(room^[:], 1)
	testing.expect(t, fits)
	testing.expect(t, added(&list, 0, 1, .Free))
	for index in 0 ..< u64(ROOM - 1) {
		testing.expect(t, add_reserved(&list, index, 1))
	}
	testing.expect_value(t, list.count, ROOM)
	testing.expect_value(t, list.dropped_count, 0)
	testing.expect_value(t, list.dropped_pages, 0)
	// One more than the room: the Reserved range is dropped with its pages.
	testing.expect(t, add_reserved(&list, ROOM, 3))
	testing.expect_value(t, list.count, ROOM)
	testing.expect_value(t, list.dropped_count, 1)
	testing.expect_value(t, list.dropped_pages, 3)
	// The largest count of pages: the sum stays at the largest u64.
	testing.expect(t, add_reserved(&list, ROOM + 1, max(u64)))
	testing.expect(t, add_reserved(&list, ROOM + 2, max(u64)))
	testing.expect_value(t, list.dropped_count, 3)
	testing.expect_value(t, list.dropped_pages, max(u64))
	testing.expect_value(t, list.count, ROOM)
	testing.expect_value(t, room^[0], info.Memory_Range{start = 0, page_count = 1, kind = u32(info.Memory_Kind.Free)})
}

// The usable ranges keep their room: a map whose Reserved ranges come
// first still gives each usable range, and drops the Reserved ones that
// take the room of a usable one.
@(test)
the_reserved_ranges_never_take_the_room_of_a_usable_one :: proc(t: ^testing.T) {
	room: [3]info.Memory_Range
	list, fits := list_begin(room[:], 2)
	testing.expect(t, fits)
	testing.expect(t, added(&list, 0, 1, .Reserved))
	testing.expect(t, added(&list, 2 * info.PAGE_SIZE, 1, .Reserved))
	testing.expect(t, added(&list, 4 * info.PAGE_SIZE, 1, .Free))
	testing.expect(t, added(&list, 6 * info.PAGE_SIZE, 1, .Boot))
	testing.expect_value(t, list.count, 3)
	testing.expect_value(t, list.dropped_count, 1)
	testing.expect_value(t, room[1].kind, u32(info.Memory_Kind.Free))
	testing.expect_value(t, room[2].kind, u32(info.Memory_Kind.Boot))
}

// A usable range that the kernel cannot hold is refused, and the list does
// not change: a start inside a page, a start one byte below the limit, a
// range that ends one page past the limit, a start past it, the largest
// start, and a count of pages whose end wraps. The edges that are taken: a
// range that ends at the limit exactly, and a Reserved range past it,
// which the kernel never gives.
@(test)
a_usable_range_past_the_addresses_is_refused :: proc(t: ^testing.T) {
	room: [4]info.Memory_Range
	list, fits := list_begin(room[:], 3)
	testing.expect(t, fits)
	last_page := ADDRESS_LIMIT - info.PAGE_SIZE
	top := max(u64) - (max(u64) % info.PAGE_SIZE)
	Refusal :: struct {
		start:      u64,
		page_count: u64,
		status:     Add_Status,
	}
	refusals := [?]Refusal {
		{1, 1, .Not_On_Page},
		{info.PAGE_SIZE + 1, 1, .Not_On_Page},
		{ADDRESS_LIMIT - 1, 1, .Not_On_Page},
		{last_page, 2, .Past_Address_Limit},
		{ADDRESS_LIMIT, 1, .Past_Address_Limit},
		{top, 1, .Past_Address_Limit},
		{info.PAGE_SIZE, max(u64), .Past_Address_Limit},
		{0, ADDRESS_LIMIT / info.PAGE_SIZE + 1, .Past_Address_Limit},
	}
	for kind in ([]info.Memory_Kind{.Free, .Boot}) {
		for refusal in refusals {
			status := list_add(&list, refusal.start, refusal.page_count, kind)
			testing.expectf(t, status == refusal.status, "a %v range at %X of %d pages gives %v, not %v", kind, refusal.start, refusal.page_count, status, refusal.status)
			testing.expect_value(t, list.count, 0)
		}
	}
	testing.expect(t, added(&list, last_page, 1, .Free), "a range that ends at the limit is refused")
	testing.expect(t, added(&list, 0, ADDRESS_LIMIT / info.PAGE_SIZE - 1, .Boot), "a range of every page below the last page is refused")
	testing.expect(t, added(&list, top, 1, .Reserved), "a Reserved range at the top is refused")
	testing.expect_value(t, list.count, 3)
	testing.expect_value(t, room[0], info.Memory_Range{start = last_page, page_count = 1, kind = u32(info.Memory_Kind.Free)})
}

// A range that follows the last one with the same kind joins it; one of
// another kind, one after a gap, a Reserved join that would wrap, and a
// range of no page do not. A range of no page is not counted.
@(test)
a_range_that_follows_with_its_kind_joins_the_last :: proc(t: ^testing.T) {
	room: [6]info.Memory_Range
	list, fits := list_begin(room[:], 4)
	testing.expect(t, fits)
	testing.expect(t, added(&list, info.PAGE_SIZE, 2, .Free))
	testing.expect(t, added(&list, 3 * info.PAGE_SIZE, 1, .Free)) // Follows: joins.
	testing.expect_value(t, list.count, 1)
	testing.expect_value(t, room[0].page_count, 3)
	testing.expect(t, added(&list, 4 * info.PAGE_SIZE, 1, .Boot)) // Follows, of another kind.
	testing.expect(t, added(&list, 6 * info.PAGE_SIZE, 1, .Boot)) // The same kind, after a gap.
	testing.expect_value(t, list.count, 3)
	testing.expect(t, added(&list, 7 * info.PAGE_SIZE, 0, .Free)) // No page.
	testing.expect_value(t, list.count, 3)
	testing.expect_value(t, list.dropped_count, 0)
	// A usable range that ends at the limit, then one that follows it:
	// the join would pass the limit, so the second is refused alone.
	last_page := ADDRESS_LIMIT - info.PAGE_SIZE
	testing.expect(t, added(&list, last_page, 1, .Free))
	testing.expect_value(t, list_add(&list, ADDRESS_LIMIT, 1, .Free), Add_Status.Past_Address_Limit)
	testing.expect_value(t, list.count, 4)
	testing.expect_value(t, room[3].page_count, 1)
	// A Reserved range at the top of the addresses, then one whose join
	// would wrap to 0: it stays a range of its own.
	top := max(u64) - (max(u64) % info.PAGE_SIZE)
	testing.expect(t, added(&list, top, 1, .Reserved))
	testing.expect(t, added(&list, 0, 1, .Reserved))
	testing.expect_value(t, list.count, 6)
	testing.expect_value(t, room[4].page_count, 1)
	testing.expect_value(t, room[5].start, 0)
}
