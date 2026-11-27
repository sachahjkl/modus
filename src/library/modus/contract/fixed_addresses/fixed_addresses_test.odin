#+build !freestanding
#+build !modus
package fixed_addresses

import op "modus:contract/operation"
import "core:testing"

// Each pair of ranges: no two overlap, and each is inside the band on a
// page. Each named address is the address of its member.
@(test)
no_two_ranges_overlap :: proc(t: ^testing.T) {
	for first_name in Fixed_Range {
		first := range_of(first_name)
		testing.expectf(t, first.address >= BAND_START && first.address + first.span <= BAND_END, "%v is inside the band", first_name)
		testing.expectf(t, first.address % 4096 == 0 && first.span > 0, "%v starts on a page and is not empty", first_name)
		for second_name in Fixed_Range {
			if first_name == second_name {
				continue
			}
			second := range_of(second_name)
			apart := first.address + first.span <= second.address || second.address + second.span <= first.address
			testing.expectf(t, apart, "%v and %v do not overlap", first_name, second_name)
		}
	}
	// A list, not an array indexed by the enumeration: the free slots have
	// no member, so the enumeration is sparse.
	Named_Address :: struct {
		range:   Fixed_Range,
		address: u64,
	}
	named := [?]Named_Address {
		{.Module_Files, MODULE_FILES_ADDRESS},
		{.Settings_Page, SETTINGS_PAGE_ADDRESS},
		{.Presentation_Page, PRESENTATION_PAGE_ADDRESS},
		{.Plan_Values_Page, PLAN_VALUES_PAGE_ADDRESS},
		{.Date_Page, DATE_PAGE_ADDRESS},
		{.Storage_File, STORAGE_FILE_ADDRESS},
		{.Module_Tables, MODULE_TABLES_ADDRESS},
		{.Debug_Image, DEBUG_IMAGE_ADDRESS},
		{.Disk_Process_Page, DISK_PROCESS_PAGE_ADDRESS},
		{.Fresh_Bytes_Page, FRESH_BYTES_PAGE_ADDRESS},
		{.Start_Policy_Pages, START_POLICY_PAGES_ADDRESS},
		{.Edit_Target_Page, EDIT_TARGET_PAGE_ADDRESS},
	}
	for each in named {
		testing.expectf(t, each.address == range_of(each.range).address, "%v: the named address is the address of its member", each.range)
	}
}

// The set of the mapped ranges: each member is its own bit, a starter adds
// each one, and a bit past the members names no range.
@(test)
the_set_of_the_mapped_ranges :: proc(t: ^testing.T) {
	values: [op.CONTEXT_VALUES]u64
	testing.expect_value(t, ranges_mapped(&values), Fixed_Ranges{})
	for range in Fixed_Range {
		range_mapped_add(&values, range)
		testing.expectf(t, range in ranges_mapped(&values), "%v is in the set after its add", range)
		testing.expectf(t, values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] & (u64(1) << uint(range)) != 0, "%v is the bit %v", range, int(range))
	}
	all := ranges_mapped(&values)
	for range in Fixed_Range {
		testing.expect(t, range in all)
	}
	// Every value from 0 to the last member but the free slots.
	testing.expect_value(t, values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED], ((u64(1) << uint(int(max(Fixed_Range)) + 1)) - 1) & ~free_slot_bits())
	// One bit alone: the other ranges are not mapped.
	values = {}
	range_mapped_add(&values, .Date_Page)
	testing.expect_value(t, ranges_mapped(&values), Fixed_Ranges{.Date_Page})
	// A bit that names no member beside a valid one: no member is in the set.
	for slot in free_slots {
		for word in ([?]u64{u64(1) << slot, u64(1) << 63}) {
			values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] = word | u64(1) << uint(Fixed_Range.Date_Page)
			for range in Fixed_Range {
				testing.expectf(t, range not_in ranges_mapped(&values), "the word %x gives %v", word, range)
			}
		}
	}
}

// The slots of the ranges that left: no member has their values. Slot 1 held
// pointer themes, slots 5, 9, 10, and 13 held boot-image glyph caches, and
// slot 14 held font outlines (slot 18 past Edit_Target_Page held script fonts).
free_slots := [6]uint{1, 5, 9, 10, 13, 14}

// free_slot_bits gives the bits of the free slots.
free_slot_bits :: proc() -> (bits: u64) {
	for slot in free_slots {
		bits |= u64(1) << slot
	}
	return bits
}

// The values of the members are the values of the contract: a module of an
// earlier build reads each range at its old bit.
@(test)
the_members_keep_their_values :: proc(t: ^testing.T) {
	expected := [?]struct {
		range: Fixed_Range,
		value: int,
	} {
		{.Module_Files, 0},
		{.Settings_Page, 2},
		{.Presentation_Page, 3},
		{.Plan_Values_Page, 4},
		{.Date_Page, 6},
		{.Storage_File, 7},
		{.Module_Tables, 8},
		{.Debug_Image, 11},
		{.Disk_Process_Page, 12},
		{.Fresh_Bytes_Page, 15},
		{.Start_Policy_Pages, 16},
		{.Edit_Target_Page, 17},
	}
	count := 0
	for range in Fixed_Range {
		testing.expectf(t, free_slot_bits() & (u64(1) << uint(range)) == 0, "%v takes a free slot", range)
		count += 1
	}
	testing.expect_value(t, count, len(expected))
	for each in expected {
		testing.expectf(t, int(each.range) == each.value, "%v is %v, not %v", each.range, int(each.range), each.value)
	}
	testing.expect_value(t, int(max(Fixed_Range)), SLOT_COUNT - 1)
}

// The border of the value of the fixed ranges: the edges first. 0 is the
// empty set; each word with a bit that names no member is refused (each
// free slot alone and beside a member, the slot past the last member, the
// last bit, every bit); the set of every member is accepted, last.
@(test)
the_border_of_the_fixed_ranges :: proc(t: ^testing.T) {
	ranges, ok := fixed_ranges_of_word(0)
	testing.expect(t, ok && ranges == {})
	refused := [?]u64{u64(1) << SLOT_COUNT, u64(1) << 63, max(u64), free_slot_bits()}
	for word in refused {
		ranges, ok = fixed_ranges_of_word(word)
		testing.expectf(t, !ok && ranges == {}, "the word %x is refused", word)
	}
	for slot in free_slots {
		for word in ([?]u64{u64(1) << slot, u64(1) << slot | u64(1) << uint(Fixed_Range.Date_Page)}) {
			ranges, ok = fixed_ranges_of_word(word)
			testing.expectf(t, !ok && ranges == {}, "the word %x is refused", word)
		}
	}
	for range in Fixed_Range {
		ranges, ok = fixed_ranges_of_word(u64(1) << uint(range))
		testing.expectf(t, ok && ranges == {range}, "the bit of %v gives %v", range, ranges)
	}
	every: u64
	for range in Fixed_Range {
		every |= u64(1) << uint(range)
	}
	ranges, ok = fixed_ranges_of_word(every)
	testing.expect(t, ok)
	for range in Fixed_Range {
		testing.expect(t, range in ranges)
	}
}
