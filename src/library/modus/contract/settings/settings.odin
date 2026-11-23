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
// (modus:contract/scale_factor). The first value of each setting but the
// scale is its default: the vector font with the grid fit, red green blue,
// the pointer theme of the owner when the boot image has it; the default
// scale is 1.25 (scale_factor.DEFAULT), the third of its range. The word
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
// A change: the sole writer (`settings`) makes change_count odd, writes the
// values, the time zone, and the appearance in force, makes it even again,
// and wakes the threads that wait on it (the compositor and `date`). The
// compositor then sends the display event Presentation to each window,
// and each process draws again. A reader copies the values while
// change_count stays even and the same (read).
//
// With the setting `auto`, `settings` wakes at each 07:00 or 19:00 local
// edge and on each change of the date page, and updates appearance_in_force
// through the same single-writer write().
//
// The language list (src/md/features/interface_language.md, "1. The
// identity of a language") is one more choice of the page: the languages that the principal
// reads, in its order, as at most LANGUAGE_LIST_CAPACITY records of
// language_tag.Locale and their count. An empty list is the source
// language of each text, English, so a page of zeros holds it. The page
// and the kept record hold records, never the text of a tag: no reader
// parses a tag that another wrote.
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
import "modus:contract/chosen_values"
import "modus:contract/enum_word"
import "modus:contract/fixed_addresses"
import "modus:contract/language_tag"
import "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/scale_factor"

PAGE_ADDRESS :: fixed_addresses.SETTINGS_PAGE_ADDRESS // Where a process maps the settings page.
// Where a process with a surface maps a page of its own, in the format of
// the settings page, that its display library writes from the presentation
// record of the holder of the display (src/md/features/module_settings.md,
// "The presentation record").
PRESENTATION_PAGE_ADDRESS :: fixed_addresses.PRESENTATION_PAGE_ADDRESS
GRANT_PAGE :: 12 // The handle of the context of the process `settings`: the page, with Read and Write.
VALUE_PASS :: op.CONTEXT_VALUE_SETTINGS_PASS // The process `settings`: the word of its Pass.

// The pass that the process `settings` runs, as its starter names it in
// the context value VALUE_PASS. The values cross the context, so they are
// stated; pass_of_word is their one border.
Pass :: enum u64 {
	Window          = 0, // No pass: the window and the service.
	Boot            = 1, // At boot: read the kept record, write the page, stop.
	Appearance_Next = 2, // The tile of the Control Center: the next appearance (appearance_next), kept and written, then stop.
}

// pass_of_word is the border of the context value VALUE_PASS: a word that
// names no Pass is refused, never read as the window.
pass_of_word :: proc "contextless" (word: u64) -> (pass: Pass, ok: bool) {
	return enum_word.member_of_word(Pass, word)
}

// The answer of the root service to an ask that starts `settings`. The
// process `settings` is the one writer of the page, so two never run: an
// ask while one runs raises its window, waits for its pass, or is refused.
Start_Answer :: enum u8 {
	Start                      = 0, // No process `settings` runs: start.
	Raise_Window               = 1, // A window runs and the ask is a window: the compositor raises it, the focus where it was.
	Raise_Window_At_Appearance = 2, // A window runs and the ask is the next appearance: the compositor raises it at the appearance.
	Wait_For_Pass              = 3, // A pass runs and the ask is a window: the start waits until the pass stops.
	Refuse                     = 4, // Another process `settings` runs and the ask is a pass: refused; the one that runs writes the page.
}

// start_answer decides an ask of the pass `asked` for `settings`, with
// `running` true when a process `settings` runs, in the pass `running_pass`.
start_answer :: proc "contextless" (asked: Pass, running: bool, running_pass: Pass) -> Start_Answer {
	if !running {
		return .Start
	}
	switch running_pass {
	case .Boot, .Appearance_Next:
		switch asked {
		case .Window:
			return .Wait_For_Pass
		case .Boot, .Appearance_Next:
			return .Refuse
		}
	case .Window:
		switch asked {
		case .Window:
			return .Raise_Window
		case .Appearance_Next:
			return .Raise_Window_At_Appearance
		case .Boot:
			return .Refuse
		}
	}
	return .Refuse
}

// appearance_next gives the appearance after one press on the tile of the
// Control Center: auto, then dark, then light, then auto again.
appearance_next :: proc "contextless" (appearance: Appearance) -> Appearance {
	switch appearance {
	case .Auto:
		return .Dark
	case .Dark:
		return .Light
	case .Light:
		return .Auto
	}
	return .Auto
}
KEPT_OBJECT_NAME :: "settings" // The object of the private store of `settings` that holds the record of the chosen values.

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
VALUE_NAME_CAPACITY :: 9 // The most values of one setting: the scale has 9, from 1 to 2 by eighths.

// Description: the name of a setting, the names of its values and the word
// of the first one, for the window of `settings`. The exports take the
// enums themselves, and the module file names their members for the
// console and the palette (src/md/features/enum_parameters.md).
Description :: struct {
	name:        string, // The name in the exports and in the console: "subpixel_order".
	title:       string, // For the window.
	value_names: [VALUE_NAME_CAPACITY]string, // The name of each value, by its place; "" past the values.
	value_count: u32, // The values of the setting.
	first_word:  u32, // The word of the value at the place 0: the word of a value is its place plus this.
}

// The description of each setting. The scale names each count of eighths
// of its range, from 1 to 2; the border takes each of them
// (scale_factor.scale_of_word).
descriptions := [Setting]Description {
	.Font            = {"font", "font", {"vector", "spleen", "", "", "", "", "", "", ""}, len(Font), 0},
	.Subpixel_Order  = {"subpixel_order", "subpixel order", {"rgb", "bgr", "none", "", "", "", "", "", ""}, len(Subpixel_Order), 0},
	.Pointer_Theme   = {"pointer_theme", "pointer theme", {"owner", "system", "", "", "", "", "", "", ""}, len(Pointer_Theme), 0},
	.Grid_Fit        = {"grid_fit", "grid fit", {"on", "off", "", "", "", "", "", "", ""}, len(Grid_Fit), 0},
	.Keyboard_Layout = {"keyboard_layout", "keyboard layout", {"us", "french", "", "", "", "", "", "", ""}, len(Keyboard_Layout), 0},
	.Appearance      = {"appearance", "appearance", {"auto", "dark", "light", "", "", "", "", "", ""}, len(Appearance), 0},
	.Scale           = {"scale", "scale", {"1", "1.125", "1.25", "1.375", "1.5", "1.625", "1.75", "1.875", "2"}, len(scale_factor.Scale), u32(min(scale_factor.Scale))},
}
#assert(len(scale_factor.Scale) <= VALUE_NAME_CAPACITY)

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
		return u32(min(scale_factor.Scale))
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

LANGUAGE_LIST_CAPACITY :: 8 // The languages of the list at most: each more is 48 more bytes of the page and of the kept record.

// Language_List: the languages that the principal reads, the first first.
// The records past the count are zero.
Language_List :: struct {
	locales: [LANGUAGE_LIST_CAPACITY]language_tag.Locale,
	count:   u32,
}

// Why a language list is refused.
Language_List_Problem :: enum u8 {
	None              = 0, // The list holds count distinct languages.
	Too_Many          = 1, // More than LANGUAGE_LIST_CAPACITY languages.
	Bad_Locale        = 2, // A record that language_tag.locale_valid refuses: the locale problem says why.
	No_Language       = 3, // A record of the root locale, `und`: it names no language to read.
	Duplicate         = 4, // A language that the list holds before.
	Record_Past_Count = 5, // A record past the count that is not zero.
}

// language_list_valid is the border of a list that another process wrote:
// a page or a kept record. place is the record at fault, from 0, and
// locale_problem says why a Bad_Locale record is refused.
language_list_valid :: proc "contextless" (list: Language_List) -> (problem: Language_List_Problem, place: int, locale_problem: language_tag.Locale_Problem) {
	if list.count > LANGUAGE_LIST_CAPACITY {
		return .Too_Many, LANGUAGE_LIST_CAPACITY, .None
	}
	for index in 0 ..< int(list.count) {
		locale := list.locales[index]
		if found := language_tag.locale_valid(locale); found != .None {
			return .Bad_Locale, index, found
		}
		if locale.language == {} {
			return .No_Language, index, .None
		}
		for earlier in 0 ..< index {
			if list.locales[earlier] == locale {
				return .Duplicate, index, .None
			}
		}
	}
	for index in int(list.count) ..< LANGUAGE_LIST_CAPACITY {
		if list.locales[index] != {} {
			return .Record_Past_Count, index, .None
		}
	}
	return .None, 0, .None
}

// language_list_of_locales makes the list of records in their order, or
// a refusal with the empty list. No record is changed: a record that is not
// canonical is refused, not made canonical.
language_list_of_locales :: proc "contextless" (locales: []language_tag.Locale) -> (list: Language_List, problem: Language_List_Problem, place: int, locale_problem: language_tag.Locale_Problem) {
	if len(locales) > LANGUAGE_LIST_CAPACITY {
		return {}, .Too_Many, LANGUAGE_LIST_CAPACITY, .None
	}
	for locale, index in locales {
		list.locales[index] = locale
	}
	list.count = u32(len(locales))
	problem, place, locale_problem = language_list_valid(list)
	if problem != .None {
		return {}, problem, place, locale_problem
	}
	return list, .None, 0, .None
}

// language_list_add gives the list with one more language at its end, or
// the problem that refuses it, with the list unchanged.
language_list_add :: proc "contextless" (list: Language_List, locale: language_tag.Locale) -> (changed: Language_List, problem: Language_List_Problem) {
	if list.count >= LANGUAGE_LIST_CAPACITY {
		return list, .Too_Many
	}
	changed = list
	changed.locales[changed.count] = locale
	changed.count += 1
	if problem, _, _ = language_list_valid(changed); problem != .None {
		return list, problem
	}
	return changed, .None
}

// language_list_move_up gives the list with the language at place before
// the one before it. The first language, and a place past the count, give
// the list unchanged.
language_list_move_up :: proc "contextless" (list: Language_List, place: int) -> Language_List {
	changed := list
	if place >= 1 && place < int(min(list.count, LANGUAGE_LIST_CAPACITY)) {
		changed.locales[place - 1], changed.locales[place] = list.locales[place], list.locales[place - 1]
	}
	return changed
}

// language_list_remove gives the list with no language at place, the
// languages after it one place up. A place past the count gives the list
// unchanged.
language_list_remove :: proc "contextless" (list: Language_List, place: int) -> Language_List {
	count := int(min(list.count, LANGUAGE_LIST_CAPACITY))
	if place < 0 || place >= count {
		return list
	}
	changed := list
	for index in place ..< count - 1 {
		changed.locales[index] = list.locales[index + 1]
	}
	changed.locales[count - 1] = {}
	changed.count = u32(count - 1)
	return changed
}

// The settings page: what the process `settings` writes and each process
// with a surface reads, at PAGE_ADDRESS. A reader copies it while
// change_count stays even and the same.
Page :: struct {
	change_count:        u32, // Even when the page is stable. Each change adds 2.
	appearance_in_force: u32, // The word of an Appearance_In_Force. Written only by `settings`.
	values:              [SETTING_CAPACITY]u32, // By Setting. A reader takes them through choice_of_values, which refuses a word that names no value.
	zone_offset_minutes: i32, // The time zone. A reader keeps it through zone_offset_minutes_valid.
	language_count:      u32, // The languages of the list. A reader takes the list through language_list_valid.
	languages:           [LANGUAGE_LIST_CAPACITY]language_tag.Locale, // The language list, then zeros.
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
	scale:               scale_factor.Scale, // The scale factor of the desktop, from 1 to 2.
	appearance_in_force: Appearance_In_Force, // The appearance that each process draws now.
	zone_offset_minutes: i32, // The time zone that the principal chose, kept valid.
	change_count:        u32, // The change count of the page at the copy.
	languages:           Language_List, // The languages that the principal reads, which language_list_valid took.
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
// set. A scale word outside 8 to 16 is refused as a word that names no
// scale: scale_factor.scale_of_word on the word says which.
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

// The arguments of the export `set` of the process `settings`, as its
// caller wrote them in the registers: each setting is optional, a Presence
// word then the enum of its setting (src/md/features/module_settings.md,
// "The description of a parameter"). A caller that passes zeros passes
// absence.
Set_Arguments :: struct {
	font_presence:            module.Presence,
	font:                     Font,
	subpixel_order_presence:  module.Presence,
	subpixel_order:           Subpixel_Order,
	pointer_theme_presence:   module.Presence,
	pointer_theme:            Pointer_Theme,
	grid_fit_presence:        module.Presence,
	grid_fit:                 Grid_Fit,
	keyboard_layout_presence: module.Presence,
	keyboard_layout:          Keyboard_Layout,
	appearance_presence:      module.Presence,
	appearance:               Appearance,
	scale_presence:           module.Presence,
	scale:                    scale_factor.Scale,
}

// Why choice_of_arguments refuses the arguments of a call.
Set_Problem :: enum u8 {
	None              = 0, // The choice holds each given value.
	Nothing_Given     = 1, // The call gives no setting.
	Bad_Value         = 2, // A value that names no member of its enum: `refused` says which setting.
}

// choice_of_arguments is the border of the export `set`: the choice of now
// with each setting that the call gives, or a refusal, which changes no
// value. Each argument comes in a register, so a Presence word or a value
// can name no member: module.optional_member_of_arguments refuses it, as
// each word that crosses a border. A setting left out keeps its value. The appearance in force, the
// time zone and the count are those of current.
choice_of_arguments :: proc "contextless" (current: Choice, arguments: Set_Arguments) -> (changed: Choice, refused: Setting, problem: Set_Problem) {
	changed = current
	given_count := 0
	given_ok: bool
	take :: proc "contextless" (presence: module.Presence, argument: $Enum, member: ^Enum, given_count: ^int) -> (ok: bool) {
		value, given, valid := module.optional_member_of_arguments(presence, argument)
		if !valid {
			return false
		}
		if given {
			member^ = value
			given_count^ += 1
		}
		return true
	}
	if given_ok = take(arguments.font_presence, arguments.font, &changed.font, &given_count); !given_ok {
		return current, .Font, .Bad_Value
	}
	if given_ok = take(arguments.subpixel_order_presence, arguments.subpixel_order, &changed.subpixel_order, &given_count); !given_ok {
		return current, .Subpixel_Order, .Bad_Value
	}
	if given_ok = take(arguments.pointer_theme_presence, arguments.pointer_theme, &changed.pointer_theme, &given_count); !given_ok {
		return current, .Pointer_Theme, .Bad_Value
	}
	if given_ok = take(arguments.grid_fit_presence, arguments.grid_fit, &changed.grid_fit, &given_count); !given_ok {
		return current, .Grid_Fit, .Bad_Value
	}
	if given_ok = take(arguments.keyboard_layout_presence, arguments.keyboard_layout, &changed.keyboard_layout, &given_count); !given_ok {
		return current, .Keyboard_Layout, .Bad_Value
	}
	if given_ok = take(arguments.appearance_presence, arguments.appearance, &changed.appearance, &given_count); !given_ok {
		return current, .Appearance, .Bad_Value
	}
	if given_ok = take(arguments.scale_presence, arguments.scale, &changed.scale, &given_count); !given_ok {
		return current, .Scale, .Bad_Value
	}
	if given_count == 0 {
		return current, {}, .Nothing_Given
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
// different time zone, a different language list, or a different
// appearance in force. The count of
// changes is not compared: the
// process `settings` can change the count with no end and leave the values
// as they were, and a reader that acts on each new count then does work for
// nothing (the compositor tells every window, and a window ring that is
// full loses the keys of the input).
values_differ :: proc "contextless" (first, second: Choice) -> bool {
	return values_of(first) != values_of(second) || first.zone_offset_minutes != second.zone_offset_minutes || first.appearance_in_force != second.appearance_in_force || first.languages != second.languages
}

// READ_TRIES: the most reads of a page that changes, or that its writer
// left in the middle of a change (change_count odd). A reader does not wait
// for the writer.
READ_TRIES :: 64

// read copies the choice of a page that another process writes. It reads
// again while the page changes, at most READ_TRIES times. ok is false when
// no copy was whole (a writer that stops in a change, or changes the page
// with no end), and when a whole copy holds a word that names no value of
// its setting, no appearance in force, or a language list that
// language_list_valid refuses (a count past the capacity, a damaged
// record): the page is refused, not read as
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
		// The records can be torn by a change: the change count after the
		// copy says so, and the copy is read again.
		languages: Language_List
		languages.count = intrinsics.atomic_load_explicit(&page.language_count, .Relaxed)
		intrinsics.mem_copy_non_overlapping(&languages.locales, &page.languages, size_of(languages.locales))
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&page.change_count, .Relaxed) != before {
			continue
		}
		values_ok, in_force_ok: bool
		choice, _, values_ok = choice_of_values(values)
		choice.appearance_in_force, in_force_ok = enum_word.member_of_word(Appearance_In_Force, u64(in_force_word))
		languages_problem, _, _ := language_list_valid(languages)
		if !values_ok || !in_force_ok || languages_problem != .None {
			return refused_read(before), false
		}
		choice.zone_offset_minutes = zone_offset_minutes_valid(zone_word)
		choice.change_count = before
		choice.languages = languages
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
// a word that names no value; a language list that language_list_valid
// refuses is written as the empty list, so the page never holds a list
// that its readers refuse.
write :: proc "contextless" (page: ^Page, choice: Choice, zone_offset_minutes: i32, appearance_in_force: Appearance_In_Force) {
	values := values_of(choice)
	languages := choice.languages
	if problem, _, _ := language_list_valid(languages); problem != .None {
		languages = {}
	}
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
	intrinsics.atomic_thread_fence(.Release)
	for setting in Setting {
		intrinsics.atomic_store_explicit(&page.values[setting], values[setting], .Relaxed)
	}
	intrinsics.atomic_store_explicit(&page.zone_offset_minutes, zone_offset_minutes_valid(zone_offset_minutes), .Relaxed)
	intrinsics.atomic_store_explicit(&page.appearance_in_force, u32(appearance_in_force), .Relaxed)
	intrinsics.atomic_store_explicit(&page.language_count, languages.count, .Relaxed)
	intrinsics.mem_copy_non_overlapping(&page.languages, &languages.locales, size_of(languages.locales))
	intrinsics.atomic_store_explicit(&page.change_count, page.change_count + 1, .Release)
}

// The kept record of `settings` (src/md/features/module_settings.md, "The
// precedence"): the values that the principal chose, and only them, as a
// record of chosen values (modus:contract/chosen_values) in the object
// KEPT_OBJECT_NAME. The key of each value is the name of its setting in
// descriptions, and TIME_ZONE_NAME for the zone. The language list is its
// own object, KEPT_LANGUAGES_OBJECT_NAME: it is no word. A setting that
// the principal did not set has no entry, and its default holds.
KEPT_LANGUAGES_OBJECT_NAME :: "languages"

// The layer of each value of the settings in force.
Kept_Layers :: struct {
	values:    [Setting]chosen_values.Layer,
	time_zone: chosen_values.Layer,
	languages: chosen_values.Layer,
}

// zone_offset_minutes_allowed says if a word is a zone of the contract: a
// signed count of minutes from -12:00 to +14:00, by quarters of an hour.
zone_offset_minutes_allowed :: proc "contextless" (word: u64) -> bool {
	minutes := cast(i64)word
	return minutes >= i64(ZONE_OFFSET_MINUTES_LEAST) && minutes <= i64(ZONE_OFFSET_MINUTES_MOST) && minutes % i64(ZONE_OFFSET_MINUTES_STEP) == 0
}

// choice_of_kept gives the settings in force from a checked kept record and
// the bytes of the language list, when the store holds them: each chosen
// word that the border of its setting takes, and the default for each other
// one. A word that its border refuses holds as no choice, and stays kept as
// it was: a later release may know it. The choice holds no appearance in
// force and no count.
choice_of_kept :: proc "contextless" (record: chosen_values.Record, languages_bytes: []u8, languages_found: bool) -> (choice: Choice, zone_offset_minutes: i32, layers: Kept_Layers) {
	choice = choice_default()
	values := values_of(choice)
	for setting in Setting {
		word, found := chosen_values.find(record, descriptions[setting].name)
		if !found || word > u64(max(u32)) {
			continue
		}
		if _, ok := value_place_of_word(setting, u32(word)); !ok {
			continue
		}
		values[setting] = u32(word)
		layers.values[setting] = .Chosen
	}
	choice, _, _ = choice_of_values(values)
	if word, found := chosen_values.find(record, TIME_ZONE_NAME); found && zone_offset_minutes_allowed(word) {
		zone_offset_minutes = i32(cast(i64)word)
		layers.time_zone = .Chosen
	}
	if languages_found && len(languages_bytes) == size_of(Language_List) {
		list: Language_List // A copy: the bytes can be at any alignment.
		intrinsics.mem_copy_non_overlapping(&list, raw_data(languages_bytes), size_of(list))
		if problem, _, _ := language_list_valid(list); problem == .None {
			choice.languages = list
			layers.languages = .Chosen
		}
	}
	return choice, zone_offset_minutes, layers
}

// kept_read reads the bytes of the object KEPT_OBJECT_NAME: ok is false for
// bytes that are no record of chosen values, and the defaults hold. The
// language list is its own object: the choice holds none.
kept_read :: proc "contextless" (bytes: []u8) -> (choice: Choice, zone_offset_minutes: i32, layers: Kept_Layers, ok: bool) {
	record, problem := chosen_values.read_record(bytes)
	if problem != .None {
		return choice_default(), 0, {}, false
	}
	choice, zone_offset_minutes, layers = choice_of_kept(record, nil, false)
	return choice, zone_offset_minutes, layers, true
}

// The words of a presentation record after the count, the scale and the
// windows that declined it, in the window event Presentation: the font,
// the order of the stripes, the grid fit and the appearance in force, one
// byte each; the time zone; the language, then the script and the region,
// of the first language of the principal.
PRESENTATION_WORDS :: 4

// presentation_words_of gives the words of the presentation record of a
// choice: what a window draws with, and nothing more. The pointer theme,
// the layout of the keyboard and the rest of the language list stay with
// the holders that use them.
presentation_words_of :: proc "contextless" (choice: Choice) -> (words: [PRESENTATION_WORDS]u64) {
	values := values_of(choice)
	words[0] = u64(values[.Font]) | u64(values[.Subpixel_Order]) << 8 | u64(values[.Grid_Fit]) << 16 | u64(choice.appearance_in_force) << 24
	words[1] = cast(u64)i64(choice.zone_offset_minutes)
	if choice.languages.count > 0 {
		locale := choice.languages.locales[0]
		words[2] = transmute(u64)locale.language
		script_and_region := [8]u8{}
		copy(script_and_region[:4], locale.script[:])
		copy(script_and_region[4:], locale.region[:])
		words[3] = transmute(u64)script_and_region
	}
	return words
}

// presentation_of_words is the border of the words of a presentation
// record, as a window reads them from its ring: the choice that the window
// writes on its own page, with the scale that the record names and the
// defaults for what the record does not carry. A word that names no value
// of its setting, bits past the four bytes, a zone out of its range, a
// locale that is not one canonical language, or a script or a region with
// no language, refuses the whole record.
presentation_of_words :: proc "contextless" (words: [PRESENTATION_WORDS]u64, scale: scale_factor.Scale) -> (choice: Choice, ok: bool) {
	if words[0] >> 32 != 0 {
		return choice_default(), false
	}
	values := values_of(choice_default())
	values[.Font] = u32(words[0] & 0xFF)
	values[.Subpixel_Order] = u32(words[0] >> 8 & 0xFF)
	values[.Grid_Fit] = u32(words[0] >> 16 & 0xFF)
	values[.Scale] = u32(scale)
	in_force, in_force_ok := enum_word.member_of_word(Appearance_In_Force, words[0] >> 24 & 0xFF)
	choice, _, ok = choice_of_values(values)
	if !ok || !in_force_ok || !zone_offset_minutes_allowed(words[1]) {
		return choice_default(), false
	}
	choice.appearance_in_force = in_force
	choice.zone_offset_minutes = i32(cast(i64)words[1])
	if words[2] == 0 {
		if words[3] != 0 {
			return choice_default(), false
		}
		return choice, true
	}
	locale: language_tag.Locale
	locale.language = transmute([8]u8)words[2]
	script_and_region := transmute([8]u8)words[3]
	copy(locale.script[:], script_and_region[:4])
	copy(locale.region[:], script_and_region[4:])
	list := Language_List{count = 1}
	list.locales[0] = locale
	if problem, _, _ := language_list_valid(list); problem != .None {
		return choice_default(), false
	}
	choice.languages = list
	return choice, true
}

// Kept_Changes: the changes of the kept record that one change of the
// settings makes: a word for each setting whose value changed, and the
// zone when it changed.
Kept_Changes :: struct {
	changes: [len(Setting) + 1]chosen_values.Change,
	count:   int,
	languages_changed: bool,
}

// kept_changes_of gives the changes from the settings in force before to
// the settings after: only what changed becomes a chosen value, so a choice
// of the value in force records nothing and leaves a default a default.
kept_changes_of :: proc "contextless" (before: Choice, before_zone: i32, after: Choice, after_zone: i32) -> (kept: Kept_Changes) {
	before_values, after_values := values_of(before), values_of(after)
	for setting in Setting {
		if before_values[setting] != after_values[setting] {
			kept.changes[kept.count] = {name = descriptions[setting].name, kind = .Choose, value = u64(after_values[setting])}
			kept.count += 1
		}
	}
	if before_zone != after_zone {
		kept.changes[kept.count] = {name = TIME_ZONE_NAME, kind = .Choose, value = cast(u64)i64(after_zone)}
		kept.count += 1
	}
	kept.languages_changed = before.languages != after.languages
	return kept
}