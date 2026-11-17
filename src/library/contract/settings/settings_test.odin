#+build !freestanding
package settings

import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import op "modus:contract/operation"
import "core:testing"

// A writer that stops in a change (an odd count) does not stop a reader:
// after READ_TRIES reads it gives the defaults, and refuses the page.
@(test)
a_page_left_in_a_change :: proc(t: ^testing.T) {
	page: Page
	written := Choice{font = .Spleen, subpixel_order = .None, pointer_theme = .Of_The_System, grid_fit = .Off, keyboard_layout = .French, appearance = .Light}
	write(&page, written, 330, .Light)
	choice, ok := read(&page)
	testing.expect(t, ok)
	testing.expect_value(t, choice.font, Font.Spleen)
	testing.expect_value(t, choice.appearance, Appearance.Light)
	testing.expect_value(t, choice.appearance_in_force, Appearance_In_Force.Light)
	testing.expect_value(t, choice.zone_offset_minutes, 330)
	testing.expect_value(t, choice.change_count, 2)
	testing.expect_value(t, values_of(choice), values_of(written))
	page.change_count = 3
	stopped, stopped_ok := read(&page)
	testing.expect(t, !stopped_ok)
	testing.expect_value(t, values_of(stopped), [Setting]u32{})
	testing.expect_value(t, stopped.zone_offset_minutes, 0)
	testing.expect_value(t, stopped.change_count, 3)
}

// The text of a zone and back: each quarter of an hour from -12:00 to
// +14:00 gives its text and reads back as itself.
@(test)
the_text_of_a_zone :: proc(t: ^testing.T) {
	buffer: [ZONE_TEXT_SIZE]u8
	testing.expect_value(t, zone_text(buffer[:], 0), "+00:00")
	testing.expect_value(t, zone_text(buffer[:], 480), "+08:00")
	testing.expect_value(t, zone_text(buffer[:], -210), "-03:30")
	testing.expect_value(t, zone_text(buffer[:], 345), "+05:45")
	testing.expect_value(t, zone_text(buffer[:], ZONE_OFFSET_MINUTES_LEAST), "-12:00")
	testing.expect_value(t, zone_text(buffer[:], ZONE_OFFSET_MINUTES_MOST), "+14:00")
	// A zone that is not valid is written as UTC, and a short buffer gives
	// no text.
	testing.expect_value(t, zone_text(buffer[:], ZONE_OFFSET_MINUTES_MOST + ZONE_OFFSET_MINUTES_STEP), "+00:00")
	testing.expect_value(t, zone_text(buffer[:], 7), "+00:00")
	testing.expect_value(t, zone_text(buffer[:ZONE_TEXT_SIZE - 1], 60), "")
	count := 0
	for minutes := ZONE_OFFSET_MINUTES_LEAST; minutes <= ZONE_OFFSET_MINUTES_MOST; minutes += ZONE_OFFSET_MINUTES_STEP {
		read_back, ok := zone_parse(zone_text(buffer[:], minutes))
		testing.expectf(t, ok && read_back == minutes, "the zone %d minutes reads back as %d", minutes, read_back)
		count += 1
	}
	testing.expect_value(t, count, 105)
}

// A text that is not a zone is refused: the form, the range and the
// quarters of an hour.
@(test)
a_text_that_is_not_a_zone :: proc(t: ^testing.T) {
	refused := [?]string{"", "+8:00", "+08", "08:00", "UTC", "+08:10", "+15:00", "-12:15", "+08:60", "+0a:00", "+08-00", "+08:000", " +08:00"}
	for text in refused {
		_, ok := zone_parse(text)
		testing.expectf(t, !ok, "the text %q is refused", text)
	}
	minutes, ok := zone_parse("-00:00")
	testing.expect(t, ok && minutes == 0)
}

// A zone on the page that is not valid reads as UTC, and a change of the
// zone alone makes two choices differ.
@(test)
the_zone_on_the_page :: proc(t: ^testing.T) {
	page: Page
	page.zone_offset_minutes = ZONE_OFFSET_MINUTES_MOST + 60
	choice, _ := read(&page)
	testing.expect_value(t, choice.zone_offset_minutes, 0)
	page.zone_offset_minutes = 100
	choice, _ = read(&page)
	testing.expect_value(t, choice.zone_offset_minutes, 0)
	page.zone_offset_minutes = -720
	first, ok := read(&page)
	testing.expect(t, ok)
	testing.expect_value(t, first.zone_offset_minutes, -720)
	changed := first
	changed.zone_offset_minutes = 60
	testing.expect(t, values_differ(first, changed))
}

// The kept record: a word that names no value of its setting refuses the
// whole record, at each edge, and nothing of it is read; a record of the
// version before and a short record are refused; a zone that is not valid
// reads as UTC. The record of a choice reads back as that choice.
@(test)
the_kept_record :: proc(t: ^testing.T) {
	written := Choice{font = .Spleen, appearance = .Light}
	kept := kept_of(written, -210)
	testing.expect_value(t, kept.zero, 0)
	bytes := ([^]u8)(&kept)[:size_of(kept)]
	refused_words := [?]u32{len(Font), len(Font) + 1, 0x100, max(u32)}
	for word in refused_words {
		kept.values[Setting.Font] = word
		read_choice, zone, ok := kept_read(bytes)
		testing.expectf(t, !ok, "the font word %d names no font, and the record is taken", word)
		testing.expect_value(t, values_of(read_choice), [Setting]u32{})
		testing.expect_value(t, zone, 0)
	}
	kept.values[Setting.Font] = u32(Font.Spleen)
	kept.values[Setting.Appearance] = len(Appearance)
	_, _, ok := kept_read(bytes)
	testing.expect(t, !ok)
	kept.values[Setting.Appearance] = u32(Appearance.Light)
	kept.version = KEPT_VERSION - 1
	_, _, ok = kept_read(bytes)
	testing.expect(t, !ok)
	kept.version = KEPT_VERSION
	_, _, ok = kept_read(bytes[:size_of(kept) - 8])
	testing.expect(t, !ok)
	kept.zone_offset_minutes = 7
	_, zone, zone_ok := kept_read(bytes)
	testing.expect(t, zone_ok)
	testing.expect_value(t, zone, 0)
	kept.zone_offset_minutes = -210
	// A record written before the last settings existed: a word past its
	// count is no value of the record, so it is not read, and the setting
	// has its default. Here the word past the count names nothing.
	kept.count = u32(Setting.Appearance)
	kept.values[Setting.Appearance] = max(u32)
	older, _, older_ok := kept_read(bytes)
	testing.expect(t, older_ok)
	testing.expect_value(t, older.appearance, Appearance.Auto)
	testing.expect_value(t, older.font, Font.Spleen)
	kept.count = len(Setting)
	kept.values[Setting.Appearance] = u32(Appearance.Light)
	read_choice, read_zone, read_ok := kept_read(bytes)
	testing.expect(t, read_ok)
	testing.expect_value(t, values_of(read_choice), values_of(written))
	testing.expect_value(t, read_zone, -210)
}

// A word that a setting does not have refuses the page: one past the last
// value of each setting, a word past 255, and the largest word. The choice
// is the defaults, so no reader acts on the word. The appearance in force
// past its last member refuses the page too. Each value of each setting
// then reads back as its member.
@(test)
a_value_out_of_its_setting :: proc(t: ^testing.T) {
	counts := [Setting]u32 {
		.Font            = len(Font),
		.Subpixel_Order  = len(Subpixel_Order),
		.Pointer_Theme   = len(Pointer_Theme),
		.Grid_Fit        = len(Grid_Fit),
		.Keyboard_Layout = len(Keyboard_Layout),
		.Appearance      = len(Appearance),
	}
	for setting in Setting {
		refused_words := [?]u32{counts[setting], counts[setting] + 1, 0x100, max(u32)}
		for word in refused_words {
			testing.expectf(t, !value_valid(setting, word), "the word %d names no value of %v, and it is taken", word, setting)
			values: [Setting]u32
			values[setting] = word
			_, refused, ok := choice_of_values(values)
			testing.expectf(t, !ok && refused == setting, "the word %d of %v: refused %v, ok %v", word, setting, refused, ok)
			page: Page
			page.values[setting] = word
			page.values[Setting.Font] = setting == .Font ? word : u32(Font.Spleen)
			choice, page_ok := read(&page)
			testing.expectf(t, !page_ok, "a page with the word %d for %v is taken", word, setting)
			testing.expect_value(t, values_of(choice), [Setting]u32{})
		}
	}
	page: Page
	page.appearance_in_force = u32(max(Appearance_In_Force)) + 1
	_, in_force_ok := read(&page)
	testing.expect(t, !in_force_ok)
	page.appearance_in_force = max(u32)
	_, in_force_ok = read(&page)
	testing.expect(t, !in_force_ok)
	for setting in Setting {
		for word in 0 ..< counts[setting] {
			testing.expect(t, value_valid(setting, word))
			values: [Setting]u32
			values[setting] = word
			choice, _, ok := choice_of_values(values)
			testing.expect(t, ok)
			testing.expect_value(t, values_of(choice), values)
		}
	}
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
	first := Choice{font = .Spleen, subpixel_order = .None, grid_fit = .Off, keyboard_layout = .French, appearance = .Auto, change_count = 2}
	second := first
	second.change_count = 1_000_002
	testing.expect(t, !values_differ(first, second))
	testing.expect(t, !values_differ(first, first))
	other := Choice{font = .Vector, subpixel_order = .Red_Green_Blue, pointer_theme = .Of_The_System, grid_fit = .On, keyboard_layout = .United_States, appearance = .Dark}
	other_values := values_of(other)
	for setting in Setting {
		values := values_of(first)
		values[setting] = other_values[setting]
		changed, _, ok := choice_of_values(values)
		testing.expect(t, ok)
		changed.change_count = first.change_count
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
// the change count stay, and a reader sees the new word.
@(test)
the_appearance_in_force_alone :: proc(t: ^testing.T) {
	page: Page
	write(&page, Choice{appearance = .Auto}, 0, .Dark)
	before, before_ok := read(&page)
	appearance_in_force_write(&page, .Light)
	after, after_ok := read(&page)
	testing.expect(t, before_ok && after_ok)
	testing.expect_value(t, after.appearance_in_force, Appearance_In_Force.Light)
	testing.expect_value(t, after.change_count, before.change_count)
	testing.expect_value(t, values_of(after), values_of(before))
	// An all-zero page: the setting auto, dark in force.
	empty: Page
	empty_choice, empty_ok := read(&empty)
	testing.expect(t, empty_ok)
	testing.expect_value(t, empty_choice.appearance, Appearance.Auto)
	testing.expect_value(t, empty_choice.appearance_in_force, Appearance_In_Force.Dark)
}
