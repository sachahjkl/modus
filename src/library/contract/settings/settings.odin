// The settings of the owner (docs/FONTS.md, "The setting"): one page that
// the root service creates. The process `settings` is the one writer of the
// values; each process with a surface or a terminal, and the compositor,
// map it with the right Read only, at PAGE_ADDRESS. The bit of the range Settings_Page in
// the context value op.CONTEXT_VALUE_FIXED_RANGES_MAPPED says that it is
// mapped (clear: the process has no page, and its text is Spleen).
//
// Each setting is one value of the page and one row of `descriptions`: its
// name and the names of its values. Value 0 of each setting is its default
// (ZII): an all-zero page is the vector font with the grid fit, red green
// blue, the pointer theme of the owner when the boot image has it.
//
// The page holds the choices only. The glyph caches (the three of the font
// of the cells, the two of the interface font) are not on the page: the
// root service maps these resources of the boot image read-only in the
// same processes, after it checked their hashes and their format, at the
// fixed ranges of modus:contract/fixed_addresses, and sets the bit of each range
// in the context of each process (glyph_cache_open). The process
// `settings` writes the page, so a field of the page can only change a
// look: no process reads an address or a size from it.
//
// A change: the writer makes change_count odd, writes the values and the
// appearance in force, makes it even again, and wakes the threads that
// wait on it (the compositor, the root service). The compositor then sends
// the display event Settings_Changed to each window, and each process draws
// again. A reader copies the values while change_count stays even and the
// same (read).
//
// The appearance in force (src/md/features/appearance.md) has a second
// writer: with the setting `auto`, the root service writes the one word
// appearance_in_force at each edge of the rule of the day, with one atomic
// store outside the change count (appearance_in_force_write), and wakes the
// same waiters. A reader loads that word inside its loop of reads.
//
// The time zone (src/md/features/time_zone.md) is one more choice of the
// page, zone_offset_minutes, outside the enumeration Setting: a zone is a
// number of minutes, not one of a list of names. The process `settings`
// writes it with the values; the process `date` copies it into the date
// page, where each reader of the local time reads it.
//
// The process `settings` keeps the values in its private store, as one
// record (Kept_Settings) in one object: one write is one commit, so a loss
// of power gives the old record or the new one, never a mix. At boot the
// root service starts `settings` for one pass with no window: it reads the
// record and writes the page.
package settings

import "base:intrinsics"
import "modus:contract/enum_word"
import "modus:contract/fixed_addresses"
import "modus:contract/glyph_cache"
import op "modus:contract/operation"

PAGE_ADDRESS :: fixed_addresses.SETTINGS_PAGE_ADDRESS // Where a process maps the settings page.
GRANT_PAGE :: 12 // The handle of the context of the process `settings`: the page, with Read and Write.
VALUE_BOOT_PASS :: op.CONTEXT_VALUE_SETTINGS_BOOT_PASS // The process `settings`: 1 for the pass at boot (read the kept record, write the page, stop).
KEPT_OBJECT_NAME :: "settings" // The object of the private store of `settings` that holds Kept_Settings.

// The settings, in the order of the page and of the window.
Setting :: enum u32 {
	Font           = 0, // Which font draws the text of the system: `Font`.
	Subpixel_Order = 1, // The order of the color stripes of the screen: `Subpixel_Order`.
	Pointer_Theme  = 2, // Which pointer theme the compositor draws: `Pointer_Theme`.
	Grid_Fit       = 3, // Whether the glyphs sit on whole pixels: `Grid_Fit`.
	Keyboard_Layout = 4, // Which character each key of the keyboard gives: `Keyboard_Layout`.
	Appearance      = 5, // Which appearance the desktop has, or the rule of the day: `Appearance`.
}

// The values of each setting. 0 is the default.
Font :: enum u32 {
	Vector = 0, // The vector font of the glyph cache.
	Spleen = 1, // The bitmap font Spleen 8x16: the fallback, and a choice of the owner.
}

// The order of the color stripes of the pixels of the screen, from the left.
Subpixel_Order :: enum u32 {
	Red_Green_Blue = 0, // Red at the left: most screens.
	Blue_Green_Red = 1, // Blue at the left.
	None           = 2, // Grayscale: a screen with no stripes in rows, or a screenshot to read.
}

// The pointer theme that the compositor draws (docs/POINTERS.md).
Pointer_Theme :: enum u32 {
	Of_The_Owner  = 0, // The first theme of pointer_pictures.RESOURCE_PREFERENCE that the boot image has.
	Of_The_System = 1, // The theme of the system (resources/pointers/system.manifest).
}

// Whether the text of the system is fitted to the grid of pixels.
Grid_Fit :: enum u32 {
	On  = 0, // The baseline, the x-height and the cap height on whole pixels (docs/FONTS.md, "Grid fit").
	Off = 1, // The shapes of the design: the glyph cache with no grid fit.
}

// The layout of the keyboard: the character that the input service gives
// for each key, as a code point (src/library/private/input/keyboard_layout).
Keyboard_Layout :: enum u32 {
	United_States = 0, // The layout of the United States: QWERTY.
	French        = 1, // The layout of France: AZERTY.
}

// The appearance of the desktop that the principal chose
// (src/md/features/appearance.md).
Appearance :: enum u32 {
	Auto  = 0, // The rule of the day: light from 07:00 to 19:00 of the local time, dark at night.
	Dark  = 1, // The dark appearance at each hour.
	Light = 2, // The light appearance at each hour.
}

// The appearance that each process draws now: the word appearance_in_force
// of the page. With the setting Dark or Light it is that value; with Auto,
// the value of the rule at this moment.
Appearance_In_Force :: enum u32 {
	Dark  = 0, // The default: an all-zero page is dark.
	Light = 1,
}

SETTING_CAPACITY :: 8 // The page and the kept record have room for 8 values.
VALUE_NAME_CAPACITY :: 4 // The most values of one setting.

// Description: the name of a setting and the names of its values, for the
// exports and the window of `settings`.
Description :: struct {
	name:        string, // The name in the exports and in the console: "subpixel_order".
	title:       string, // For the window.
	value_names: [VALUE_NAME_CAPACITY]string, // The name of each value, by its number.
	value_count: u32, // The values of the setting.
}

// The description of each setting.
descriptions := [Setting]Description {
	.Font           = {"font", "font", {"vector", "spleen", "", ""}, len(Font)},
	.Subpixel_Order = {"subpixel_order", "subpixel order", {"rgb", "bgr", "none", ""}, len(Subpixel_Order)},
	.Pointer_Theme  = {"pointer_theme", "pointer theme", {"owner", "system", "", ""}, len(Pointer_Theme)},
	.Grid_Fit       = {"grid_fit", "grid fit", {"on", "off", "", ""}, len(Grid_Fit)},
	.Keyboard_Layout = {"keyboard_layout", "keyboard layout", {"us", "french", "", ""}, len(Keyboard_Layout)},
	.Appearance      = {"appearance", "appearance", {"auto", "dark", "light", ""}, len(Appearance)},
}

// The time zone: a fixed offset from UTC, in minutes, with no summer time
// (src/md/features/time_zone.md). Its name in the exports and its title in
// the window.
TIME_ZONE_NAME :: "time_zone"
TIME_ZONE_TITLE :: "time zone"
ZONE_OFFSET_MINUTES_LEAST :: i32(-12 * 60) // -12:00, the zone of the earth furthest west.
ZONE_OFFSET_MINUTES_MOST :: i32(14 * 60) // +14:00, the zone of the earth furthest east.
ZONE_OFFSET_MINUTES_STEP :: i32(15) // Each offset in use is a whole quarter of an hour: +05:45, +12:45.
ZONE_TEXT_SIZE :: 6 // "+08:00": a sign, two digits of hours, a colon, two digits of minutes.

// zone_offset_minutes_valid gives the zone, or the default 0 (UTC) for a
// number outside the range or not a whole quarter of an hour.
zone_offset_minutes_valid :: proc "contextless" (minutes: i32) -> i32 {
	if minutes < ZONE_OFFSET_MINUTES_LEAST || minutes > ZONE_OFFSET_MINUTES_MOST || minutes % ZONE_OFFSET_MINUTES_STEP != 0 {
		return 0
	}
	return minutes
}

// zone_text writes the text of a zone in the form of ISO 8601, "+08:00" or
// "-03:30", in a buffer of ZONE_TEXT_SIZE bytes or more. Zero is "+00:00".
// A zone that is not valid is written as 0. A shorter buffer gives "".
zone_text :: proc "contextless" (buffer: []u8, minutes: i32) -> string {
	if len(buffer) < ZONE_TEXT_SIZE {
		return ""
	}
	value := zone_offset_minutes_valid(minutes)
	buffer[0] = value < 0 ? '-' : '+'
	size := value < 0 ? -value : value
	hours, rest := size / 60, size % 60
	buffer[1] = u8('0' + hours / 10)
	buffer[2] = u8('0' + hours % 10)
	buffer[3] = ':'
	buffer[4] = u8('0' + rest / 10)
	buffer[5] = u8('0' + rest % 10)
	return string(buffer[:ZONE_TEXT_SIZE])
}

// zone_parse reads the text of a zone: a sign, two digits of hours, a
// colon and two digits of minutes, from "-12:00" to "+14:00", by quarters
// of an hour. ok is false for any other text: "+8:00", "+08", "UTC",
// "+08:10", "+15:00".
zone_parse :: proc "contextless" (text: string) -> (minutes: i32, ok: bool) {
	if len(text) != ZONE_TEXT_SIZE || text[0] != '+' && text[0] != '-' || text[3] != ':' {
		return 0, false
	}
	digit_places := [4]int{1, 2, 4, 5}
	for place in digit_places {
		if text[place] < '0' || text[place] > '9' {
			return 0, false
		}
	}
	hours := i32(text[1] - '0') * 10 + i32(text[2] - '0')
	rest := i32(text[4] - '0') * 10 + i32(text[5] - '0')
	if rest >= 60 {
		return 0, false
	}
	minutes = hours * 60 + rest
	if text[0] == '-' {
		minutes = -minutes
	}
	if zone_offset_minutes_valid(minutes) != minutes {
		return 0, false
	}
	return minutes, true
}

// The names of the appearance in force, by its number, for the log.
appearance_in_force_names := [Appearance_In_Force]string {
	.Dark  = "dark",
	.Light = "light",
}

// The settings page: what the process `settings` writes and each process
// with a surface reads, at PAGE_ADDRESS. A reader copies it while
// change_count stays even and the same.
Page :: struct {
	change_count:        u32, // Even when the page is stable. Each change adds 2.
	appearance_in_force: u32, // The word of an Appearance_In_Force. The process `settings` and the root service write it.
	values:              [SETTING_CAPACITY]u32, // By Setting. A reader takes them through choice_of_values, which refuses a word that names no value.
	zone_offset_minutes: i32, // The time zone. A reader keeps it through zone_offset_minutes_valid.
}
#assert(size_of(Page) <= 4096)

// The glyph caches that a process with a surface or a terminal can
// receive: the three of the font of the cells, and the two of the
// interface font (docs/FONTS.md, section 12).
Glyph_Cache :: enum u8 {
	With_Grid_Fit, // The font of the cells, with grid fit.
	Without_Grid_Fit, // The font of the cells, with no grid fit.
	Bold, // Scale 1 only: the titles of the cards. Absent: the titles are the regular weight.
	Interface, // B612 Regular: three positions at scale 1, one at the scales 2 and 3.
	Interface_Bold, // B612 Bold: scale 1 only, three positions.
}

// The fixed range of each glyph cache.
glyph_cache_ranges := [Glyph_Cache]fixed_addresses.Fixed_Range {
	.With_Grid_Fit    = .Glyph_Cache,
	.Without_Grid_Fit = .Glyph_Cache_Without_Grid_Fit,
	.Bold             = .Glyph_Cache_Bold,
	.Interface        = .Interface_Glyph_Cache,
	.Interface_Bold   = .Interface_Glyph_Cache_Bold,
}

// glyph_cache_open validates a glyph cache of this process at its fixed
// range. With the bit of the range clear in the context (the starter did
// not map it), nothing is read and the problem is Not_Mapped. Else the
// size comes from the header of the cache, bounded by the span of the
// range (glyph_cache.validate_at). The bytes there are pages of the boot
// image, mapped read-only, that no process can write (docs/FONTS.md,
// section 5, "Who can write a cache").
glyph_cache_open :: proc "contextless" (values: ^[op.CONTEXT_VALUES]u64, cache: Glyph_Cache) -> (glyph_cache.Cache, glyph_cache.Problem) {
	range := glyph_cache_ranges[cache]
	if range not_in fixed_addresses.ranges_mapped(values) {
		return {}, {kind = .Not_Mapped, index = u32(range)}
	}
	place := fixed_addresses.range_of(range)
	return glyph_cache.validate_at(uintptr(place.address), place.span)
}

// Choice: the values of a page, as one copy. Each value is the member of
// its setting: the border of the page (choice_of_values) refused each word
// that names no value, so no reader casts a word.
Choice :: struct {
	font:                Font,
	subpixel_order:      Subpixel_Order,
	pointer_theme:       Pointer_Theme,
	grid_fit:            Grid_Fit,
	keyboard_layout:     Keyboard_Layout,
	appearance:          Appearance, // The setting of the appearance: Auto, Dark or Light.
	appearance_in_force: Appearance_In_Force, // The appearance that each process draws now.
	zone_offset_minutes: i32, // The time zone that the principal chose, kept valid.
	change_count:        u32, // The change count of the page at the copy.
}

// value_valid says if a word names a value of a setting: the word of a
// member of the enumeration of the setting.
value_valid :: proc "contextless" (setting: Setting, word: u32) -> bool {
	switch setting {
	case .Font:
		_, ok := enum_word.member_of_word(Font, u64(word))
		return ok
	case .Subpixel_Order:
		_, ok := enum_word.member_of_word(Subpixel_Order, u64(word))
		return ok
	case .Pointer_Theme:
		_, ok := enum_word.member_of_word(Pointer_Theme, u64(word))
		return ok
	case .Grid_Fit:
		_, ok := enum_word.member_of_word(Grid_Fit, u64(word))
		return ok
	case .Keyboard_Layout:
		_, ok := enum_word.member_of_word(Keyboard_Layout, u64(word))
		return ok
	case .Appearance:
		_, ok := enum_word.member_of_word(Appearance, u64(word))
		return ok
	}
	return false
}

// choice_of_values is the border of the words of the settings: the choice
// of the members, or ok false with the first setting whose word names no
// value of it (a page or a record that a broken writer wrote). The word is
// refused, never read as the default: the caller keeps what it had, or
// refuses the whole page or record. The time zone, the appearance in force
// and the count are not set.
//
// The members come from the enumerations, and not from `descriptions`:
// that table holds names, so it has addresses that a loader writes, and a
// module that only reads a choice (the drawing module) must have no such
// data (docs/MODULE_CONTRACT.md, "A library as a module").
choice_of_values :: proc "contextless" (values: [Setting]u32) -> (choice: Choice, refused: Setting, ok: bool) {
	font_ok, order_ok, theme_ok, grid_ok, layout_ok, appearance_ok: bool
	choice.font, font_ok = enum_word.member_of_word(Font, u64(values[.Font]))
	choice.subpixel_order, order_ok = enum_word.member_of_word(Subpixel_Order, u64(values[.Subpixel_Order]))
	choice.pointer_theme, theme_ok = enum_word.member_of_word(Pointer_Theme, u64(values[.Pointer_Theme]))
	choice.grid_fit, grid_ok = enum_word.member_of_word(Grid_Fit, u64(values[.Grid_Fit]))
	choice.keyboard_layout, layout_ok = enum_word.member_of_word(Keyboard_Layout, u64(values[.Keyboard_Layout]))
	choice.appearance, appearance_ok = enum_word.member_of_word(Appearance, u64(values[.Appearance]))
	member_ok := [Setting]bool {
		.Font            = font_ok,
		.Subpixel_Order  = order_ok,
		.Pointer_Theme   = theme_ok,
		.Grid_Fit        = grid_ok,
		.Keyboard_Layout = layout_ok,
		.Appearance      = appearance_ok,
	}
	for setting in Setting {
		if !member_ok[setting] {
			return {}, setting, false
		}
	}
	return choice, {}, true
}

// values_of gives the word of each value of a choice: the form of the page,
// of the kept record and of the window of `settings`, which treats each
// setting as a row of buttons.
values_of :: proc "contextless" (choice: Choice) -> (values: [Setting]u32) {
	values[.Font] = u32(choice.font)
	values[.Subpixel_Order] = u32(choice.subpixel_order)
	values[.Pointer_Theme] = u32(choice.pointer_theme)
	values[.Grid_Fit] = u32(choice.grid_fit)
	values[.Keyboard_Layout] = u32(choice.keyboard_layout)
	values[.Appearance] = u32(choice.appearance)
	return values
}

// values_differ tells whether two choices have different values, a
// different time zone, or a different appearance in force. The count of
// changes is not compared: the
// process `settings` can change the count with no end and leave the values
// as they were, and a reader that acts on each new count then does work for
// nothing (the compositor tells every window, and a window ring that is
// full loses the keys of the input).
values_differ :: proc "contextless" (first, second: Choice) -> bool {
	return values_of(first) != values_of(second) || first.zone_offset_minutes != second.zone_offset_minutes || first.appearance_in_force != second.appearance_in_force
}

// READ_TRIES: the most reads of a page that changes, or that its writer
// left in the middle of a change (change_count odd). A reader does not wait
// for the writer.
READ_TRIES :: 64

// read copies the choice of a page that another process writes. It reads
// again while the page changes, at most READ_TRIES times. ok is false when
// no copy was whole (a writer that stops in a change, or changes the page
// with no end), and when a whole copy holds a word that names no value of
// its setting, or no appearance in force: the page is refused, not read as
// the defaults for that word. The choice is then the defaults with the
// count that the read saw, so a broken writer changes the look of the other
// processes and never stops them, and a reader that acts on the page (the
// root service, the process `date`) acts on nothing.
read :: proc "contextless" (page: ^Page) -> (choice: Choice, ok: bool) {
	before: u32
	for _ in 0 ..< READ_TRIES {
		before = intrinsics.atomic_load_explicit(&page.change_count, .Acquire)
		if before & 1 != 0 {
			continue
		}
		values: [Setting]u32
		for setting in Setting {
			values[setting] = intrinsics.atomic_load_explicit(&page.values[setting], .Relaxed)
		}
		zone_word := intrinsics.atomic_load_explicit(&page.zone_offset_minutes, .Relaxed)
		// One word, which the root service also stores alone: the copy is
		// the old or the new appearance, never a mix.
		in_force_word := intrinsics.atomic_load_explicit(&page.appearance_in_force, .Relaxed)
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&page.change_count, .Relaxed) != before {
			continue
		}
		values_ok, in_force_ok: bool
		choice, _, values_ok = choice_of_values(values)
		choice.appearance_in_force, in_force_ok = enum_word.member_of_word(Appearance_In_Force, u64(in_force_word))
		if !values_ok || !in_force_ok {
			return {change_count = before}, false
		}
		choice.zone_offset_minutes = zone_offset_minutes_valid(zone_word)
		choice.change_count = before
		return choice, true
	}
	return {change_count = before}, false
}

// write changes the values of the page, the time zone and the appearance in
// force, in one change. The one writer of the values is the process
// `settings`; it wakes the waiters after (it owns the kernel calls, this
// package has none). The choice holds members only, so the page never holds
// a word that names no value.
write :: proc "contextless" (page: ^Page, choice: Choice, zone_offset_minutes: i32, appearance_in_force: Appearance_In_Force) {
	values := values_of(choice)
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	for setting in Setting {
		intrinsics.atomic_store_explicit(&page.values[setting], values[setting], .Relaxed)
	}
	intrinsics.atomic_store_explicit(&page.zone_offset_minutes, zone_offset_minutes_valid(zone_offset_minutes), .Relaxed)
	intrinsics.atomic_store_explicit(&page.appearance_in_force, u32(appearance_in_force), .Relaxed)
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
}

// appearance_in_force_write changes the appearance in force alone, with one
// store and no change of the count: the write of the root service at an
// edge of the rule of the day. A reader copies the old or the new word. The
// caller wakes the waiters of change_count after.
appearance_in_force_write :: proc "contextless" (page: ^Page, appearance_in_force: Appearance_In_Force) {
	intrinsics.atomic_store_explicit(&page.appearance_in_force, u32(appearance_in_force), .Release)
}

// Kept_Settings: the record of the private store of `settings`, 56 bytes,
// little-endian. A record with another magic or version is not used: the
// defaults hold. Version 2 added the time zone. The boot pass of `settings`
// writes the defaults in place of a record of another version, so they
// hold once.
KEPT_MAGIC :: u64(0x53474E4954544553) // The bytes "SETTINGS".
KEPT_VERSION :: 2

Kept_Settings :: struct {
	magic:               u64,
	version:             u32,
	count:               u32, // The values that follow: the count of Setting when it was written.
	values:              [SETTING_CAPACITY]u32,
	zone_offset_minutes: i32, // The time zone.
	zero:                u32, // 0: the record has no padding byte of unknown value.
}
#assert(size_of(Kept_Settings) == 56)

// kept_of makes the record of a choice.
kept_of :: proc "contextless" (choice: Choice, zone_offset_minutes: i32) -> (kept: Kept_Settings) {
	kept.magic, kept.version, kept.count = KEPT_MAGIC, KEPT_VERSION, len(Setting)
	values := values_of(choice)
	for setting in Setting {
		kept.values[setting] = values[setting]
	}
	kept.zone_offset_minutes = zone_offset_minutes_valid(zone_offset_minutes)
	return kept
}

// kept_read reads a record from its bytes: ok is false for bytes that are
// not a record of this version, and for a record with a word that names no
// value of its setting: such a record is refused whole, as a record of
// another version is, and never read as the default of that one setting. A
// setting past the count of the record has its default: the record did not
// hold it. A zone that is not valid is UTC. The choice holds no appearance
// in force and no count.
kept_read :: proc "contextless" (bytes: []u8) -> (choice: Choice, zone_offset_minutes: i32, ok: bool) {
	if len(bytes) != size_of(Kept_Settings) {
		return {}, 0, false
	}
	kept: Kept_Settings // A copy: the bytes can be at any alignment.
	intrinsics.mem_copy_non_overlapping(&kept, raw_data(bytes), size_of(kept))
	if kept.magic != KEPT_MAGIC || kept.version != KEPT_VERSION || kept.count > SETTING_CAPACITY {
		return {}, 0, false
	}
	values: [Setting]u32
	for setting in Setting {
		if u32(setting) < kept.count {
			values[setting] = kept.values[setting]
		}
	}
	values_ok: bool
	choice, _, values_ok = choice_of_values(values)
	if !values_ok {
		return {}, 0, false
	}
	return choice, zone_offset_minutes_valid(kept.zone_offset_minutes), true
}
