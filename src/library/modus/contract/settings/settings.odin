// The settings of the owner (docs/FONTS.md, "The setting"): one page that
// the root service creates. The process `settings` is the one writer of the
// values; each process with a surface or a terminal, and the compositor,
// map it with the right Read only, at PAGE_ADDRESS. The bit of the range Settings_Page in
// the context value op.CONTEXT_VALUE_FIXED_RANGES_MAPPED says that it is
// mapped (clear: the process has no page, and its text is Spleen).
//
// Each setting is one value of the page and one row of `descriptions`: its
// name, the names of its values and the word of its first value. The word
// of a value is its place in the names plus the first word: the place for
// each setting but the scale, whose word is its count of eighths
// (modus:contract/scale_factor). The first value of each setting is its
// default: the vector font with the grid fit, red green blue, the pointer
// theme of the owner when the boot image has it, the scale 1.25. The word
// 0 names no scale, so the root service writes the defaults into the page
// that it creates (page_defaults_write), and an all-zero page is refused.
//
// The page holds the choices only. The font outlines, from which each
// process draws its glyphs, are not on the page: the root service maps
// that resource of the boot image read-only in the same processes, after
// it checked its hash and its format, at its fixed range of
// modus:contract/fixed_addresses, and sets the bit of the range in the
// context of each process (modus:contract/font_outlines). The process
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
import op "modus:contract/operation"
import "modus:contract/scale_factor"

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
	Scale           = 6, // The scale factor of the desktop, in eighths: `scale_factor.Scale`.
}

// The values of each setting. 0 is the default.
Font :: enum u32 {
	Vector = 0, // The vector fonts of the font outlines, through their faces.
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
	Off = 1, // The shapes of the design: the face of the cells with no grid fit.
}

// The layout of the keyboard: the character that the input service gives
// for each key, as a code point (src/library/internal/input/keyboard_layout).
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
VALUE_NAME_CAPACITY :: 8 // The most values of one setting.

// Description: the name of a setting, the names of its values and the word
// of the first one, for the window of `settings`. The exports take the
// enums themselves, and the module file names their members for the
// console and the palette (src/md/features/enum_parameters.md).
Description :: struct {
	name:        string, // The name in the exports and in the console: "subpixel_order".
	title:       string, // For the window.
	value_names: [VALUE_NAME_CAPACITY]string, // The name of each value, by its place.
	value_count: u32, // The values of the setting.
	first_word:  u32, // The word of the value at the place 0: the word of a value is its place plus this.
}

// The description of each setting. The scale names each count of eighths
// of its range; the border refuses the ones past the window bound
// (scale_factor.scale_of_word), and the window of `settings` shows only the
// others.
descriptions := [Setting]Description {
	.Font            = {"font", "font", {"vector", "spleen", "", "", "", "", "", ""}, len(Font), 0},
	.Subpixel_Order  = {"subpixel_order", "subpixel order", {"rgb", "bgr", "none", "", "", "", "", ""}, len(Subpixel_Order), 0},
	.Pointer_Theme   = {"pointer_theme", "pointer theme", {"owner", "system", "", "", "", "", "", ""}, len(Pointer_Theme), 0},
	.Grid_Fit        = {"grid_fit", "grid fit", {"on", "off", "", "", "", "", "", ""}, len(Grid_Fit), 0},
	.Keyboard_Layout = {"keyboard_layout", "keyboard layout", {"us", "french", "", "", "", "", "", ""}, len(Keyboard_Layout), 0},
	.Appearance      = {"appearance", "appearance", {"auto", "dark", "light", "", "", "", "", ""}, len(Appearance), 0},
	.Scale           = {"scale", "scale", {"1.25", "1.375", "1.5", "1.625", "1.75", "1.875", "2", ""}, len(scale_factor.Scale), u32(scale_factor.Scale.Ten_Eighths)},
}

// word_of_value gives the word of the value at a place of a setting. A
// place past the values of the setting gives a word that its border
// refuses: the first word plus the place.
word_of_value :: proc "contextless" (setting: Setting, place: int) -> u32 {
	return first_word_of(setting) + u32(max(place, 0))
}

// value_place_of_word gives the place of the value of a word, or ok false
// for a word under the first word or past the values of the setting.
value_place_of_word :: proc "contextless" (setting: Setting, word: u32) -> (place: int, ok: bool) {
	first := first_word_of(setting)
	if word < first || word - first >= value_counts(setting) {
		return 0, false
	}
	return int(word - first), true
}

// value_name_of gives the name of the value of a word of a setting, or ""
// for a word that names no value of it.
value_name_of :: proc "contextless" (setting: Setting, word: u32) -> string {
	place, ok := value_place_of_word(setting, word)
	if !ok {
		return ""
	}
	return descriptions[setting].value_names[place]
}

// first_word_of and value_counts give the first word and the count of the
// values of a setting from the enumerations, not from `descriptions`, so
// the two never disagree with the members.
@(private)
first_word_of :: proc "contextless" (setting: Setting) -> u32 {
	switch setting {
	case .Font, .Subpixel_Order, .Pointer_Theme, .Grid_Fit, .Keyboard_Layout, .Appearance:
		return 0
	case .Scale:
		return u32(scale_factor.Scale.Ten_Eighths)
	}
	return 0
}

@(private)
value_counts :: proc "contextless" (setting: Setting) -> u32 {
	switch setting {
	case .Font:
		return len(Font)
	case .Subpixel_Order:
		return len(Subpixel_Order)
	case .Pointer_Theme:
		return len(Pointer_Theme)
	case .Grid_Fit:
		return len(Grid_Fit)
	case .Keyboard_Layout:
		return len(Keyboard_Layout)
	case .Appearance:
		return len(Appearance)
	case .Scale:
		return len(scale_factor.Scale)
	}
	return 0
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
	scale:               scale_factor.Scale, // The scale factor of the desktop, up to scale_factor.WINDOW_BOUND.
	appearance_in_force: Appearance_In_Force, // The appearance that each process draws now.
	zone_offset_minutes: i32, // The time zone that the principal chose, kept valid.
	change_count:        u32, // The change count of the page at the copy.
}

// choice_default gives the choice of a principal who set nothing: the
// first value of each setting, and the scale 1.25. A Choice of all zero is
// not it: the zero of the scale names no member.
choice_default :: proc "contextless" () -> Choice {
	return {scale = scale_factor.DEFAULT}
}

// page_defaults_write writes the defaults into a page that the root
// service created, before any reader maps it: the word 0 of the scale names
// no scale, so an all-zero page is refused.
page_defaults_write :: proc "contextless" (page: ^Page) {
	write(page, choice_default(), 0, .Dark)
}

// value_valid says if a word names a value of a setting: the word of a
// member of the enumeration of the setting, and for the scale a member
// that scale_factor.scale_of_word takes.
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
	case .Scale:
		_, problem := scale_factor.scale_of_word(u64(word))
		return problem == .None
	}
	return false
}

// choice_of_values is the border of the words of the settings: the choice
// of the members, or ok false with the first setting whose word names no
// value of it (a page or a record that a broken writer wrote). The word is
// refused, never read as the default: the caller keeps what it had, or
// refuses the whole page or record. The choice of a refusal is the
// defaults. The time zone, the appearance in force and the count are not
// set. A scale word past the window bound is refused as a word that names
// no scale: scale_factor.scale_of_word on the word says which.
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
	scale_problem: scale_factor.Scale_Problem
	choice.scale, scale_problem = scale_factor.scale_of_word(u64(values[.Scale]))
	member_ok := [Setting]bool {
		.Font            = font_ok,
		.Subpixel_Order  = order_ok,
		.Pointer_Theme   = theme_ok,
		.Grid_Fit        = grid_ok,
		.Keyboard_Layout = layout_ok,
		.Appearance      = appearance_ok,
		.Scale           = scale_problem == .None,
	}
	for setting in Setting {
		if !member_ok[setting] {
			return choice_default(), setting, false
		}
	}
	return choice, {}, true
}

// The arguments of the export `set` of the process `settings`, each of the
// enum of its setting, as its caller wrote them in the registers
// (src/md/features/enum_parameters.md). A setting that the call leaves out
// holds the absent word: each bit of its size set.
Set_Arguments :: struct {
	font:            Font,
	subpixel_order:  Subpixel_Order,
	pointer_theme:   Pointer_Theme,
	grid_fit:        Grid_Fit,
	keyboard_layout: Keyboard_Layout,
	appearance:      Appearance,
	scale:           scale_factor.Scale,
}

// Why choice_of_arguments refuses the arguments of a call.
Set_Problem :: enum u8 {
	None              = 0, // The choice holds each given value.
	Nothing_Given     = 1, // The call gives no setting.
	Bad_Value         = 2, // A value that names no member of its enum: `refused` says which setting.
	Past_Window_Bound = 3, // A scale past scale_factor.WINDOW_BOUND, which no window fits yet.
}

// choice_of_arguments is the border of the export `set`: the choice of now
// with each setting that the call gives, or a refusal, which changes no
// value. Each argument comes in a register, so a value can name no member:
// enum_word.member_of_argument refuses it, as each word that crosses a
// border. A setting left out keeps its value. The appearance in force, the
// time zone and the count are those of current.
choice_of_arguments :: proc "contextless" (current: Choice, arguments: Set_Arguments) -> (changed: Choice, refused: Setting, problem: Set_Problem) {
	changed = current
	given_count := 0
	given_ok: bool
	take :: proc "contextless" (argument: $Enum, member: ^Enum, given_count: ^int) -> (ok: bool) {
		value, given, valid := enum_word.member_of_argument(argument)
		if !valid {
			return false
		}
		if given {
			member^ = value
			given_count^ += 1
		}
		return true
	}
	if given_ok = take(arguments.font, &changed.font, &given_count); !given_ok {
		return current, .Font, .Bad_Value
	}
	if given_ok = take(arguments.subpixel_order, &changed.subpixel_order, &given_count); !given_ok {
		return current, .Subpixel_Order, .Bad_Value
	}
	if given_ok = take(arguments.pointer_theme, &changed.pointer_theme, &given_count); !given_ok {
		return current, .Pointer_Theme, .Bad_Value
	}
	if given_ok = take(arguments.grid_fit, &changed.grid_fit, &given_count); !given_ok {
		return current, .Grid_Fit, .Bad_Value
	}
	if given_ok = take(arguments.keyboard_layout, &changed.keyboard_layout, &given_count); !given_ok {
		return current, .Keyboard_Layout, .Bad_Value
	}
	if given_ok = take(arguments.appearance, &changed.appearance, &given_count); !given_ok {
		return current, .Appearance, .Bad_Value
	}
	if given_ok = take(arguments.scale, &changed.scale, &given_count); !given_ok {
		return current, .Scale, .Bad_Value
	}
	if given_count == 0 {
		return current, {}, .Nothing_Given
	}
	// A member of the scale that no window fits yet: the border of the
	// page refuses it, so the export refuses it before any write.
	if _, scale_problem := scale_factor.scale_of_word(u64(changed.scale)); scale_problem != .None {
		return current, .Scale, .Past_Window_Bound
	}
	return changed, {}, .None
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
	values[.Scale] = u32(choice.scale)
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
			return refused_read(before), false
		}
		choice.zone_offset_minutes = zone_offset_minutes_valid(zone_word)
		choice.change_count = before
		return choice, true
	}
	return refused_read(before), false
}

// refused_read gives the choice of a page that read refused: the defaults,
// with the count that the read saw.
@(private)
refused_read :: proc "contextless" (change_count: u32) -> Choice {
	choice := choice_default()
	choice.change_count = change_count
	return choice
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
// setting past the count of the record has its default, the word of its
// first value: the record did not hold it. A record of the six settings
// before the scale then reads with the scale 1.25, and keeps the other
// settings of the principal. A zone that is not valid is UTC. The choice
// holds no appearance in force and no count; a refusal gives the defaults.
kept_read :: proc "contextless" (bytes: []u8) -> (choice: Choice, zone_offset_minutes: i32, ok: bool) {
	if len(bytes) != size_of(Kept_Settings) {
		return choice_default(), 0, false
	}
	kept: Kept_Settings // A copy: the bytes can be at any alignment.
	intrinsics.mem_copy_non_overlapping(&kept, raw_data(bytes), size_of(kept))
	if kept.magic != KEPT_MAGIC || kept.version != KEPT_VERSION || kept.count > SETTING_CAPACITY {
		return choice_default(), 0, false
	}
	values := values_of(choice_default())
	for setting in Setting {
		if u32(setting) < kept.count {
			values[setting] = kept.values[setting]
		}
	}
	values_ok: bool
	choice, _, values_ok = choice_of_values(values)
	if !values_ok {
		return choice_default(), 0, false
	}
	return choice, zone_offset_minutes_valid(kept.zone_offset_minutes), true
}
