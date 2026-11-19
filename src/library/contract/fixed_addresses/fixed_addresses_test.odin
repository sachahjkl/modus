#+build !freestanding
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
	// The two interface glyph caches have no named address: their readers
	// take range_of (modus:contract/settings).
	// A list, not an array indexed by the enumeration: the free slot has no
	// member, so the enumeration is sparse.
	Named_Address :: struct {
		range:   Fixed_Range,
		address: u64,
	}
	named := [?]Named_Address {
		{.Module_Files, MODULE_FILES_ADDRESS},
		{.Pointer_Themes, POINTER_THEMES_ADDRESS},
		{.Settings_Page, SETTINGS_PAGE_ADDRESS},
		{.Glyph_Cache, GLYPH_CACHE_ADDRESS},
		{.Glyph_Cache_Without_Grid_Fit, GLYPH_CACHE_WITHOUT_GRID_FIT_ADDRESS},
		{.Glyph_Cache_Bold, GLYPH_CACHE_BOLD_ADDRESS},
		{.Date_Page, DATE_PAGE_ADDRESS},
		{.Storage_File, STORAGE_FILE_ADDRESS},
		{.Module_Tables, MODULE_TABLES_ADDRESS},
		{.Debug_Image, DEBUG_IMAGE_ADDRESS},
		{.Disk_Process_Page, DISK_PROCESS_PAGE_ADDRESS},
		{.Font_Outlines, FONT_OUTLINES_ADDRESS},
		{.Fresh_Bytes_Page, FRESH_BYTES_PAGE_ADDRESS},
		{.Start_Policy_Pages, START_POLICY_PAGES_ADDRESS},
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
	// Every value from 0 to the last member but the free slot.
	testing.expect_value(t, values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED], ((u64(1) << uint(int(max(Fixed_Range)) + 1)) - 1) & ~(u64(1) << FREE_SLOT))
	// One bit alone: the other ranges are not mapped.
	values = {}
	range_mapped_add(&values, .Date_Page)
	testing.expect_value(t, ranges_mapped(&values), Fixed_Ranges{.Date_Page})
	// A bit that names no member beside a valid one: no member is in the set.
	for word in ([?]u64{u64(1) << FREE_SLOT, u64(1) << 63}) {
		values[op.CONTEXT_VALUE_FIXED_RANGES_MAPPED] = word | u64(1) << uint(Fixed_Range.Date_Page)
		for range in Fixed_Range {
			testing.expectf(t, range not_in ranges_mapped(&values), "the word %x gives %v", word, range)
		}
	}
}

// The slot of the range that left: no member has its value.
FREE_SLOT :: 13

// The values of the members are the values of the contract: a module of an
// earlier build reads each range at its old bit.
@(test)
the_members_keep_their_values :: proc(t: ^testing.T) {
	expected := [?]struct {
		range: Fixed_Range,
		value: int,
	} {
		{.Module_Files, 0},
		{.Pointer_Themes, 1},
		{.Settings_Page, 2},
		{.Glyph_Cache, 3},
		{.Glyph_Cache_Without_Grid_Fit, 4},
		{.Glyph_Cache_Bold, 5},
		{.Date_Page, 6},
		{.Storage_File, 7},
		{.Module_Tables, 8},
		{.Interface_Glyph_Cache, 9},
		{.Interface_Glyph_Cache_Bold, 10},
		{.Debug_Image, 11},
		{.Disk_Process_Page, 12},
		{.Font_Outlines, 14},
		{.Fresh_Bytes_Page, 15},
		{.Start_Policy_Pages, 16},
	}
	count := 0
	for range in Fixed_Range {
		testing.expectf(t, int(range) != FREE_SLOT, "%v takes the free slot", range)
		count += 1
	}
	testing.expect_value(t, count, len(expected))
	for each in expected {
		testing.expectf(t, int(each.range) == each.value, "%v is %v, not %v", each.range, int(each.range), each.value)
	}
	testing.expect_value(t, int(max(Fixed_Range)), SLOT_COUNT - 1)
}

// The border of the value of the fixed ranges: the edges first. 0 is the
// empty set; each word with a bit that names no member is refused (the
// free slot, the slot past the last member, the last bit, every bit); the
// set of every member is accepted, last.
@(test)
the_border_of_the_fixed_ranges :: proc(t: ^testing.T) {
	ranges, ok := fixed_ranges_of_word(0)
	testing.expect(t, ok && ranges == {})
	refused := [?]u64{u64(1) << FREE_SLOT, u64(1) << SLOT_COUNT, u64(1) << 63, max(u64), u64(1) << FREE_SLOT | u64(1) << uint(Fixed_Range.Font_Outlines)}
	for word in refused {
		ranges, ok = fixed_ranges_of_word(word)
		testing.expectf(t, !ok && ranges == {}, "the word %x is refused", word)
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
