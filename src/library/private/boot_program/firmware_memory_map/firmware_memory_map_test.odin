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
		{DESCRIPTOR_SIZE_MINIMUM, max(u64), .Too_Large},
		{DESCRIPTOR_SIZE_MINIMUM, limit / MARGIN_DESCRIPTORS + 1, .Too_Large},
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
	}
	for one in cases {
		pages, problem := buffer_pages(one.needed_bytes, one.descriptor_size)
		testing.expectf(t, problem == .None && pages == one.pages, "a map of %d bytes with a step of %d gives %d pages and %v, not %d pages", one.needed_bytes, one.descriptor_size, pages, problem, one.pages)
		step := one.descriptor_size == 0 ? u64(DESCRIPTOR_SIZE_MINIMUM) : one.descriptor_size
		testing.expectf(t, pages * info.PAGE_SIZE >= one.needed_bytes + step * MARGIN_DESCRIPTORS, "%d pages hold the map of %d bytes and its margin", pages, one.needed_bytes)
	}
}

// A step that the boot program walks: 0, 1 and one below the minimum are
// refused; the minimum and a larger step are taken.
@(test)
a_step_below_one_descriptor_is_refused :: proc(t: ^testing.T) {
	for size in ([]u64{0, 1, DESCRIPTOR_SIZE_MINIMUM - 1}) {
		testing.expectf(t, !descriptor_size_valid(size), "a step of %d bytes is taken", size)
	}
	for size in ([]u64{DESCRIPTOR_SIZE_MINIMUM, DESCRIPTOR_SIZE_MINIMUM + 8, max(u64)}) {
		testing.expectf(t, descriptor_size_valid(size), "a step of %d bytes is refused", size)
	}
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
	testing.expect(t, list_add(&list, 0, 1, .Free))
	testing.expect(t, list_add(&list, 8 * info.PAGE_SIZE, 1, .Boot))
	before := room
	testing.expect(t, !list_add(&list, 16 * info.PAGE_SIZE, 1, .Free), "a usable range with no room is taken")
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
		return list_add(list, index * 2 * info.PAGE_SIZE + 0x1000_0000, pages, .Reserved)
	}
	// Exactly the room: one usable range, then ROOM - 1 Reserved ones.
	list, fits = list_begin(room^[:], 1)
	testing.expect(t, fits)
	testing.expect(t, list_add(&list, 0, 1, .Free))
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
	testing.expect_value(t, room^[0], info.Memory_Range{start = 0, page_count = 1, kind = .Free})
}

// The usable ranges keep their room: a map whose Reserved ranges come
// first still gives each usable range, and drops the Reserved ones that
// take the room of a usable one.
@(test)
the_reserved_ranges_never_take_the_room_of_a_usable_one :: proc(t: ^testing.T) {
	room: [3]info.Memory_Range
	list, fits := list_begin(room[:], 2)
	testing.expect(t, fits)
	testing.expect(t, list_add(&list, 0, 1, .Reserved))
	testing.expect(t, list_add(&list, 2 * info.PAGE_SIZE, 1, .Reserved))
	testing.expect(t, list_add(&list, 4 * info.PAGE_SIZE, 1, .Free))
	testing.expect(t, list_add(&list, 6 * info.PAGE_SIZE, 1, .Boot))
	testing.expect_value(t, list.count, 3)
	testing.expect_value(t, list.dropped_count, 1)
	testing.expect_value(t, room[1].kind, info.Memory_Kind.Free)
	testing.expect_value(t, room[2].kind, info.Memory_Kind.Boot)
}

// A range that follows the last one with the same kind joins it; one of
// another kind, one after a gap, a join that would pass the last address,
// and a range of no page do not. A range of no page is not counted.
@(test)
a_range_that_follows_with_its_kind_joins_the_last :: proc(t: ^testing.T) {
	room: [6]info.Memory_Range
	list, fits := list_begin(room[:], 5)
	testing.expect(t, fits)
	testing.expect(t, list_add(&list, info.PAGE_SIZE, 2, .Free))
	testing.expect(t, list_add(&list, 3 * info.PAGE_SIZE, 1, .Free)) // Follows: joins.
	testing.expect_value(t, list.count, 1)
	testing.expect_value(t, room[0].page_count, 3)
	testing.expect(t, list_add(&list, 4 * info.PAGE_SIZE, 1, .Boot)) // Follows, of another kind.
	testing.expect(t, list_add(&list, 6 * info.PAGE_SIZE, 1, .Boot)) // The same kind, after a gap.
	testing.expect_value(t, list.count, 3)
	testing.expect(t, list_add(&list, 7 * info.PAGE_SIZE, 0, .Free)) // No page.
	testing.expect_value(t, list.count, 3)
	testing.expect_value(t, list.dropped_count, 0)
	// A range at the top of the addresses, then one whose join would wrap.
	top := max(u64) - (max(u64) % info.PAGE_SIZE)
	testing.expect(t, list_add(&list, top, 1, .Free))
	testing.expect(t, list_add(&list, 0, max(u64) / info.PAGE_SIZE, .Free))
	testing.expect_value(t, list.count, 5)
	testing.expect_value(t, room[3].page_count, 1)
	// The same start again does not follow.
	testing.expect(t, list_add(&list, 0, 1, .Reserved))
	testing.expect_value(t, list.count, 6)
}
