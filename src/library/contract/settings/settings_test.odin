#+build !freestanding
package settings

import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import op "modus:contract/operation"
import "core:testing"

// A writer that stops in a change (an odd count) does not stop a reader:
// after READ_TRIES reads it gives the defaults.
@(test)
a_page_left_in_a_change :: proc(t: ^testing.T) {
	page: Page
	write(&page, {.Font = 1, .Subpixel_Order = 2, .Pointer_Theme = 1, .Grid_Fit = 1, .Keyboard_Layout = 1, .Appearance = u32(Appearance.Light)}, .Light)
	choice := read(&page)
	testing.expect_value(t, choice.values[.Font], 1)
	testing.expect_value(t, appearance_of(choice), Appearance.Light)
	testing.expect_value(t, choice.appearance_in_force, Appearance_In_Force.Light)
	testing.expect_value(t, choice.change_count, 2)
	page.change_count = 3
	stopped := read(&page)
	testing.expect_value(t, stopped.values, [Setting]u32{})
	testing.expect_value(t, stopped.change_count, 3)
}

// A value that a setting does not have reads as its default.
@(test)
a_value_out_of_its_setting :: proc(t: ^testing.T) {
	page: Page
	page.values[Setting.Subpixel_Order] = 0xFFFF_FFFF
	page.values[Setting.Font] = 1
	choice := read(&page)
	testing.expect_value(t, choice.values[.Subpixel_Order], 0)
	testing.expect_value(t, choice.values[.Font], 1)
}

// A glyph cache whose range the starter did not state as mapped is not
// read: each cache gives Not_Mapped with no bit, even with the bits of the
// other ranges set. A set bit makes the program read the fixed address,
// which is not mapped in a host test: that path is tested on the machine.
@(test)
a_glyph_cache_that_is_not_mapped :: proc(t: ^testing.T) {
	values: [op.CONTEXT_VALUES]u64
	for cache in Glyph_Cache {
		_, problem := glyph_cache_open(&values, cache)
		testing.expect_value(t, problem.kind, glyph_cache.Problem_Kind.Not_Mapped)
	}
	fixed_addresses.range_mapped_add(&values, .Settings_Page)
	fixed_addresses.range_mapped_add(&values, .Date_Page)
	for cache in Glyph_Cache {
		_, problem := glyph_cache_open(&values, cache)
		testing.expect_value(t, problem.kind, glyph_cache.Problem_Kind.Not_Mapped)
	}
}

// Two choices with the same values and other counts do not differ; one
// value changed makes them differ, for each setting.
@(test)
values_differ_compares_the_values_only :: proc(t: ^testing.T) {
	first := Choice{values = {.Font = 1, .Subpixel_Order = 2, .Pointer_Theme = 0, .Grid_Fit = 1, .Keyboard_Layout = 1, .Appearance = u32(Appearance.Auto)}, change_count = 2}
	second := first
	second.change_count = 1_000_002
	testing.expect(t, !values_differ(first, second))
	testing.expect(t, !values_differ(first, first))
	for setting in Setting {
		changed := first
		changed.values[setting] += 1
		testing.expectf(t, values_differ(first, changed), "a change of %v", setting)
		testing.expectf(t, values_differ(changed, first), "a change of %v, in the other order", setting)
	}
	// The appearance in force alone, as the root service changes it at an
	// edge of the day: the compositor must tell the windows.
	changed := first
	changed.appearance_in_force = .Light
	testing.expect(t, values_differ(first, changed))
}

// The root service changes the appearance in force alone: the values and
// the change count stay, and a reader sees the new word. A word that the
// enumeration does not have reads as dark.
@(test)
the_appearance_in_force_alone :: proc(t: ^testing.T) {
	page: Page
	values: [Setting]u32
	values[.Appearance] = u32(Appearance.Auto)
	write(&page, values, .Dark)
	before := read(&page)
	appearance_in_force_write(&page, .Light)
	after := read(&page)
	testing.expect_value(t, after.appearance_in_force, Appearance_In_Force.Light)
	testing.expect_value(t, after.change_count, before.change_count)
	testing.expect_value(t, after.values, before.values)
	page.appearance_in_force = 7
	testing.expect_value(t, read(&page).appearance_in_force, Appearance_In_Force.Dark)
	// An all-zero page: the setting auto, dark in force.
	empty: Page
	testing.expect_value(t, appearance_of(read(&empty)), Appearance.Auto)
	testing.expect_value(t, read(&empty).appearance_in_force, Appearance_In_Force.Dark)
}
