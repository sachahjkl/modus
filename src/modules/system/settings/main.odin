// The settings of the system (docs/FONTS.md, "The setting"): the font of
// the system, the order of the color stripes of the screen, the pointer
// theme, the grid fit of the vector font, the layout of the keyboard, the
// appearance of the desktop, the time zone and the languages that the
// principal reads. The window shows each setting as a row of buttons and
// the text of the system at its three sizes; the export set() and a getter
// for each setting make the same changes and give the same values from the
// console and from `modustool call`.
//
// The language list (src/md/features/interface_language.md, "1. The
// identity of a language") is the languages that the principal reads, the first first, as
// records of language_tag.Locale: set_languages() takes a table of them,
// and the row "languages" of the window adds a common language, moves the
// chosen language up, or removes it. An empty list is English.
//
// The time zone (src/md/features/time_zone.md) is a fixed offset from UTC,
// "+08:00". This process writes it on the settings page; the process `date`
// copies it into the date page and wakes waiters on the date page. This
// process wakes on the date page and moves the appearance in force when the
// new local time asks for it. So this process computes the appearance in
// force with the zone of the date page, never with the zone that it writes.
//
// This process is the sole writer of the settings page
// (modus:contract/settings). A change is written first to its private
// store, as one record in one object (one commit), then to the page, with
// the appearance in force that the setting `appearance` gives now
// (src/md/features/appearance.md); the page wakes the compositor, which
// gives the new font, pointer theme and appearance to each window: every
// process draws again, with no code of its own for it. With the setting
// `auto`, this process waits for the next 07:00 or 19:00 local-time edge
// and for date-page changes, and updates the appearance in force itself.
//
// At boot the root service starts this process for one pass with no window
// (the context value VALUE_BOOT_PASS): it reads the record of its store,
// writes the page, and stops.
//
// **What it is for.** It shows that a choice of the principal is state like
// any other: kept in a private store with no save action, and seen by every
// process at once through one page that each reads and only one writes. No
// process reads a configuration file, and no process needs code to follow a
// change.
//
// **Start**: `start("settings")` in the console, or the bar of the desktop.
// Keys: Tab moves between the buttons, Enter presses one; a click works
// too. From the console, with no window: `connect("settings")`, then
// `settings.set(font = .spleen)`.
//
// **Grants**, as the root service gives them:
//
// - **Settings**: the settings page with the right Write. No other process
//   can write it.
// - **Store**: its private store, which keeps the record of the settings
//   across a stop of the machine.
// - **Serve**: the exports `set`, `set_time_zone`, `set_languages`,
//   `repeat`, and a getter for each setting, for the time zone and for the
//   languages.
//
// **What a reader sees**: a card with one row of buttons for each setting,
// and a card with the text of the system at its three sizes. The log has
// "settings: the boot pass: ..." at boot, "settings: ok, font vector, ..."
// when the window opens, and one line for each change, with "kept in the
// store" or "NOT kept: the store refused". At the boot pass and at each
// change of the appearance it writes why the appearance in force is what it
// is: "settings: the appearance in force is dark: auto, light from 07:00 to
// 19:00 of the local time; the local time is 01:04 with a zone of 0 s, at
// 1794791040 s since 1970".
package settings_process

import "base:intrinsics"
import "internal:settings/appearance_rule"
import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/language_tag"
import op "modus:contract/operation"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "internal:settings/appearance"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:storage"
import "modus:system"
import "modus:text_rendering"

// One row of 32 for each setting and for the time zone, and the three
// rows of the languages.
WIDTH :: 560
HEIGHT :: 688
LANGUAGE_ROWS :: 3 // The list, the buttons that change it, the languages to add.
// The least budget of 2048 pages, in which it ran before it stated its
// window, less that window at the scale 1 (648 pages): its module, its
// stack, its tables and its glyph memory. The tool counts the window at
// the window bound (docs/MODULE_CONTRACT.md, "The budget that a module
// asks for").
MODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 1400, window_width = WIDTH, window_height = HEIGHT}

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"): the keys of the focus of the interface package.
// A procedure, not a global array: an item is made by a call, and a
// freestanding process runs no call before its entry.
bar_items :: proc "contextless" () -> [3]interface.Action_Bar_Item {
	return {
		interface.action_bar_item("next button", 3, "Tab"),
		interface.action_bar_item("button before", 2, "Shift", "Tab"),
		interface.action_bar_item("choose the value", 3, "Enter"),
	}
}
bar: interface.Action_Bar_State

// The display texts of the members whose name is not the word that a
// principal reads (src/md/features/enum_parameters.md, "The display text of
// a member"). The palette shows them on the buttons of the rows of `set`,
// and the completion beside each name; a line still types the name. No code
// reads these tables: the build writes them into the module file.
@(rodata, member_texts = "en")
scale_texts := [scale_factor.Scale]string {
	.Ten_Eighths      = "1.25",
	.Eleven_Eighths   = "1.375",
	.Twelve_Eighths   = "1.5",
	.Thirteen_Eighths = "1.625",
	.Fourteen_Eighths = "1.75",
	.Fifteen_Eighths  = "1.875",
	.Sixteen_Eighths  = "2",
}
@(rodata, member_texts = "en")
subpixel_order_texts := #partial [settings.Subpixel_Order]string {
	.Red_Green_Blue = "RGB",
	.Blue_Green_Red = "BGR",
}
@(rodata, member_texts = "en")
pointer_theme_texts := [settings.Pointer_Theme]string {
	.Of_The_Owner  = "owner",
	.Of_The_System = "system",
}
@(rodata, member_texts = "en")
keyboard_layout_texts := #partial [settings.Keyboard_Layout]string {
	.United_States = "US",
}

page: ^settings.Page
date_page: ^date.Page // The date of the rule of the day of the setting `appearance`, or nil.
service: system.Service
store: storage.Client
has_store: bool

window_memory: interface.Window_Memory(384, 8192)
drawn_change: u32 = 1 // The change count of the last frame; odd: none yet.

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_NAME :: -2
ERROR_VALUE :: -3
ERROR_STORE :: -4

// with_value gives a choice with one setting at the value of a button or of
// a name: its place in the names of the values of the setting, whose word
// the description gives. ok false: the border refuses that word, and
// scale_problem says why for the scale (a count past the window bound).
with_value :: proc "contextless" (choice: settings.Choice, setting: settings.Setting, place: int) -> (changed: settings.Choice, ok: bool, scale_problem: scale_factor.Scale_Problem) {
	values := settings.values_of(choice)
	values[setting] = settings.word_of_value(setting, place)
	if setting == .Scale {
		_, scale_problem = scale_factor.scale_of_word(u64(values[setting]))
	}
	changed, _, ok = settings.choice_of_values(values)
	if !ok {
		return choice, false, scale_problem
	}
	changed.appearance_in_force = choice.appearance_in_force
	changed.zone_offset_minutes = choice.zone_offset_minutes
	changed.change_count = choice.change_count
	changed.languages = choice.languages
	return changed, true, .None
}

// keep writes the record of the values and the zone to the private store:
// one object, one commit. It gives false, with a log line, when the store
// refuses.
keep :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32) -> bool {
	if !has_store {
		return false
	}
	kept := settings.kept_of(choice, zone_offset_minutes)
	error: errors.Error_Record
	_, status := storage.write(&store, storage.ROOT, settings.KEPT_OBJECT_NAME, ([^]u8)(&kept)[:size_of(kept)], &error)
	if status != .Ok {
		system.log_fact(.Warning, Store_Refused(errors.error_record_fact_fields(error)))
		return false
	}
	return true
}

// in_force_at gives the appearance in force of the values at system time now:
// the setting `appearance`, with `auto` by the rule of the day over the
// date page (src/md/features/appearance.md), and the moment that the rule
// read, for the fact of the appearance. The zone is the one of the date
// page: this process wakes on the date page after `date` copies a new zone,
// so the page never holds the appearance of a zone that the date page does
// not have yet.
in_force_at :: proc "contextless" (choice: settings.Choice, now: u64) -> (settings.Appearance_In_Force, appearance.Moment) {
	moment := appearance.moment_of(date_page, now)
	hour, minute, second: i32
	time_known := false
	if moment.known {
		refusal: appearance_rule.Appearance_Time_Refusal
		hour, minute, second, _, refusal = appearance_rule.local_hms_of_utc(moment.milliseconds, moment.zone_offset_seconds)
		time_known = refusal == .None
	}
	in_force, _ := appearance_rule.appearance_for_time(choice.appearance, hour, minute, second, time_known)
	return in_force, moment
}

// in_force_now evaluates the appearance in force at the current system time.
in_force_now :: proc "contextless" (choice: settings.Choice) -> (settings.Appearance_In_Force, appearance.Moment) {
	return in_force_at(choice, system.time())
}

// page_write writes the values and their appearance in force on the page in
// one change, and wakes the compositor and the process `date`. Before the
// write, it writes the sentence of the appearance in force on the log when
// the setting or the appearance changes, or when `always`: the log then
// has it before the line of the compositor that the write causes.
page_write :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32, always := false) {
	before, before_ok := settings.read(page)
	in_force, moment := in_force_now(choice)
	if always || !before_ok || before.appearance != choice.appearance || before.appearance_in_force != in_force {
		appearance_log(choice.appearance, in_force, moment)
	}
	settings.write(page, choice, zone_offset_minutes, in_force)
	system.word_wake(&page.change_count, 64)
}

// appearance_edge_step arms the wait on the date page, updates the appearance
// in force as the sole writer of the settings page whenever the local time or
// zone crossed a rule edge, and returns the system-time deadline of the next
// 07:00 or 19:00 local transition.
appearance_edge_step :: proc "contextless" (wait: ^system.Wait) -> u64 {
	if date_page != nil {
		system.wait_word(wait, &date_page.change_count, intrinsics.atomic_load_explicit(&date_page.change_count, .Acquire))
	}
	choice, ok := settings.read(page)
	if !ok {
		return system.WAIT_FOREVER
	}
	now := system.time()
	in_force, moment := in_force_at(choice, now)
	if in_force != choice.appearance_in_force {
		appearance_log(choice.appearance, in_force, moment)
		settings.write(page, choice, choice.zone_offset_minutes, in_force)
		system.word_wake(&page.change_count, 64)
	}
	wait_ms, has_edge, refusal := appearance_rule.next_edge_milliseconds(choice.appearance, moment.milliseconds, moment.zone_offset_seconds, moment.known)
	if refusal != .None || !has_edge || wait_ms > system.WAIT_FOREVER - now {
		return system.WAIT_FOREVER
	}
	return now + wait_ms
}

// page_choice reads the page that this process writes. A refused page (a
// word that names no value: no write of this process makes one) is said on
// the log, and gives the defaults, which the next change writes over it.
page_choice :: proc "contextless" () -> (choice: settings.Choice, ok: bool) {
	choice, ok = settings.read(page)
	if !ok && choice.change_count & 1 == 0 {
		system.log_fact(.Warning, Page_Refused{})
	}
	return choice, ok
}

// change keeps the values, the zone and the language list, then writes
// them on the page and wakes the compositor and the process `date`.
change :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32) -> bool {
	current, current_ok := page_choice()
	zone := settings.zone_offset_minutes_valid(zone_offset_minutes)
	values_same := current_ok && settings.values_of(current) == settings.values_of(choice)
	languages_same := current_ok && current.languages == choice.languages
	if values_same && languages_same && current.zone_offset_minutes == zone {
		return true
	}
	kept := keep(choice, zone)
	if !values_same {
		system.log_fact(.Info, Values_Changed{font = value_field(choice, .Font), subpixel_order = value_field(choice, .Subpixel_Order), pointer_theme = value_field(choice, .Pointer_Theme), grid_fit = value_field(choice, .Grid_Fit), keyboard_layout = value_field(choice, .Keyboard_Layout), appearance = value_field(choice, .Appearance), scale = value_field(choice, .Scale), store = store_field(kept)})
	}
	if current.zone_offset_minutes != zone {
		zone_buffer: [settings.ZONE_TEXT_SIZE]u8
		system.log_fact(.Info, Zone_Changed{zone = value_kinds.text_field(settings.zone_text(zone_buffer[:], zone), ZONE_FIELD_BYTES), store = store_field(kept)})
	}
	if !languages_same {
		languages_buffer: [LANGUAGES_FIELD_BYTES]u8
		system.log_fact(.Info, Languages_Changed{languages = value_kinds.text_field(languages_text(choice.languages, languages_buffer[:LANGUAGES_FIELD_BYTES - 1]), LANGUAGES_FIELD_BYTES), store = store_field(kept)})
	}
	page_write(choice, zone)
	return kept
}

// languages_text writes the canonical tags of a list in its order, joined
// by ", ", or "none" for the empty list. A buffer too short for the list
// holds the tags that fit whole.
languages_text :: proc "contextless" (list: settings.Language_List, buffer: []u8) -> string {
	if list.count == 0 {
		return "none"
	}
	count := 0
	for index in 0 ..< int(min(list.count, settings.LANGUAGE_LIST_CAPACITY)) {
		tag_buffer: [language_tag.LOCALE_TEXT_CAPACITY]u8
		tag, ok := language_tag.tag_write(list.locales[index], tag_buffer[:])
		separator := index == 0 ? "" : ", "
		if !ok || len(separator) + len(tag) > len(buffer) - count {
			break
		}
		count += copy(buffer[count:], separator)
		count += copy(buffer[count:], tag)
	}
	return string(buffer[:count])
}

@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// copied copies a text argument: the caller can change the call region
// during the call.
@(private = "file")
copied :: proc "contextless" (text: string, buffer: []u8) -> (string, bool) {
	if len(text) > len(buffer) {
		return "", false
	}
	count := copy(buffer, text)
	return string(buffer[:count]), true
}

// set changes one setting of the system or more, and keeps them in the store: set(font = .spleen), set(keyboard_layout = .french, appearance = .light).
//
// Each setting is one optional argument of the enum of its values: a line names the parameter and a member, and
// the console completes both and refuses a member that the enum does not have before the call. A setting that the
// call leaves out keeps its value. Every window draws again: the settings page wakes the compositor, which gives
// the new font, pointer theme and appearance to each window. The order is the store first, then the page, so a
// stop of the machine between the two keeps the new values. Values equal to the values of the page change nothing
// and return 1. The setting `appearance` `.auto` gives the light appearance from 07:00 to 19:00 of the local time
// and the dark one at night: the page holds the appearance in force, which the log says with the time that the
// rule read.
//
// The scale factor of the desktop is a count of eighths: `.ten_eighths`, 1.25, is the default. Each window lets
// its surface go, makes a surface of its size at the scale that the compositor names from its own budget, and
// draws again. The scales from `.twelve_eighths`, 1.5, to `.sixteen_eighths`, 2, are members, and are refused
// until each window fits their logical screen.
//
// Each parameter names its getter: the export of the same name gives the value in use, and the palette marks its
// button with it.
//
// - **font**: `.vector` or `.spleen`.
// - **subpixel_order**: `.red_green_blue`, `.blue_green_red` or `.none`.
// - **pointer_theme**: `.of_the_owner` or `.of_the_system`.
// - **grid_fit**: `.on` or `.off`.
// - **keyboard_layout**: `.united_states` or `.french`.
// - **appearance**: `.auto`, `.dark` or `.light`.
// - **scale**: `.ten_eighths` and the other counts of eighths up to `.sixteen_eighths`.
//
// The caller must act for the principal (**Acts_For_Principal**): the console and the host have it. The result is
// 1, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Absent` (-2): the call gives no setting.
// - `Bad_Value` (-3): a value that names no member of the enum of its setting; the record names the argument and
//   holds the value. No setting changes.
// - `Out_Of_Range` (-3): a scale from `.twelve_eighths` to `.sixteen_eighths`, past the largest scale whose
//   logical screen each window fits; the record holds the count of eighths and the largest count, 11. No setting
//   changes.
// - `Refused` (-4): the store did not keep the values. The page changed all the same, so the windows show the new
//   values until the next start of the machine.
//
// Example: `settings.set(font = .spleen)`, then `settings.font()` gives `.spleen`.
@(export, link_name = "set", enum_getters = "font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance, scale = scale", optional_parameters = "font, subpixel_order, pointer_theme, grid_fit, keyboard_layout, appearance, scale")
set :: proc "c" (font: settings.Font, subpixel_order: settings.Subpixel_Order, pointer_theme: settings.Pointer_Theme, grid_fit: settings.Grid_Fit, keyboard_layout: settings.Keyboard_Layout, appearance: settings.Appearance, scale: scale_factor.Scale, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	current, _ := settings.read(page)
	arguments := settings.Set_Arguments{font, subpixel_order, pointer_theme, grid_fit, keyboard_layout, appearance, scale}
	changed, refused, problem := settings.choice_of_arguments(current, arguments)
	// The argument of a setting is its place in the parameters, from 1: the
	// parameters are in the order of the settings.
	argument := i64(refused) + 1
	words := settings.values_of({font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance, scale = scale})
	switch problem {
	case .None:
	case .Nothing_Given:
		return errors.fail(error, ERROR_NAME, .Absent, .None, 0)
	case .Bad_Value:
		return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, argument, i64(words[refused]))
	case .Past_Window_Bound:
		return errors.fail(error, ERROR_VALUE, .Out_Of_Range, .None, argument, i64(scale), i64(scale_factor.WINDOW_BOUND))
	}
	if !change(changed, current.zone_offset_minutes) {
		return errors.fail(error, ERROR_STORE, .Refused, .None, 0)
	}
	return 1
}

// font gives the font of the text of the system: `.vector` or `.spleen`.
//
// Each getter reads the settings page, which each process can read too: so it needs no grant, and each caller
// gets the value. A refused page gives the defaults, which each process draws with.
@(export, link_name = "font")
font_get :: proc "c" () -> settings.Font {
	current, _ := settings.read(page)
	return current.font
}

// subpixel_order gives the order of the color stripes of the screen: `.red_green_blue`, `.blue_green_red` or `.none`.
@(export, link_name = "subpixel_order")
subpixel_order_get :: proc "c" () -> settings.Subpixel_Order {
	current, _ := settings.read(page)
	return current.subpixel_order
}

// pointer_theme gives the pointer theme that the compositor draws: `.of_the_owner` or `.of_the_system`.
@(export, link_name = "pointer_theme")
pointer_theme_get :: proc "c" () -> settings.Pointer_Theme {
	current, _ := settings.read(page)
	return current.pointer_theme
}

// grid_fit gives whether the glyphs sit on whole pixels: `.on` or `.off`.
@(export, link_name = "grid_fit")
grid_fit_get :: proc "c" () -> settings.Grid_Fit {
	current, _ := settings.read(page)
	return current.grid_fit
}

// keyboard_layout gives the layout of the keyboard: `.united_states` or `.french`.
@(export, link_name = "keyboard_layout")
keyboard_layout_get :: proc "c" () -> settings.Keyboard_Layout {
	current, _ := settings.read(page)
	return current.keyboard_layout
}

// appearance gives the appearance that the principal chose: `.auto`, `.dark` or `.light`.
@(export, link_name = "appearance")
appearance_get :: proc "c" () -> settings.Appearance {
	current, _ := settings.read(page)
	return current.appearance
}

// scale gives the scale factor of the desktop, in eighths: `.ten_eighths` is 1.25.
@(export, link_name = "scale")
scale_get :: proc "c" () -> scale_factor.Scale {
	current, _ := settings.read(page)
	return current.scale
}

// set_time_zone changes the time zone of the system, and keeps it in the store: set_time_zone("+08:00").
//
// The time zone is a fixed offset from UTC, with no summer time: a sign, the hours and the minutes, from "-12:00"
// to "+14:00", by quarters of an hour; "+00:00", UTC, is the default. The bar then shows the local time, and the
// rule of the appearance `.auto` counts its hours in it. A zone is a number of minutes, not a member of a closed
// set: so it is a Text, and not an argument of `set`.
//
// - **zone**: the zone, 32 bytes at most.
//
// The caller must act for the principal (**Acts_For_Principal**). The result is 1, or a negative number with an
// error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Too_Long` (-3): the zone has more than 32 bytes.
// - `Bad_Value` (-3): the text is no zone: "+8:00", "+08:10", "+15:00", "UTC".
// - `Refused` (-4): the store did not keep the zone. The page changed all the same.
//
// Example: `settings.set_time_zone("+08:00")`, then `settings.time_zone()` gives "+08:00".
@(export, link_name = "set_time_zone")
set_time_zone :: proc "c" (zone: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	zone_buffer: [32]u8
	given, zone_ok := copied(zone^, zone_buffer[:])
	if !zone_ok {
		return errors.fail(error, ERROR_VALUE, .Too_Long, .Bytes, 1, i64(len(zone^)), len(zone_buffer))
	}
	minutes, parsed := settings.zone_parse(given)
	if !parsed {
		return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 1)
	}
	current, _ := settings.read(page)
	if !change(current, minutes) {
		return errors.fail(error, ERROR_STORE, .Refused, .None, 1)
	}
	return 1
}

// time_zone gives the time zone of the system as a text: "+08:00".
//
// The result is the length of the text, 6. A buffer shorter than the text gets its first bytes; the result still
// counts them all.
@(export, link_name = "time_zone")
time_zone_get :: proc "c" (result: ^[]u8) -> i64 {
	zone_buffer: [settings.ZONE_TEXT_SIZE]u8
	current, _ := settings.read(page)
	zone_name := settings.zone_text(zone_buffer[:], current.zone_offset_minutes)
	copy(result^, zone_name)
	return i64(len(zone_name))
}

// Language_Row: one language of the list, as the getter languages gives it.
// The sizes of the text fields are numbers: the tool reads a Text field as
// [N]u8 with a number N.
Language_Row :: struct {
	tag:      [128]u8, // The canonical tag: "fr-CA", "ar-EG-u-nu-latn".
	language: [8]u8, // The language subtag: "fr".
	script:   [4]u8, // The script subtag, "Latn", or "".
	region:   [4]u8, // The region, "CA" or "419", or "".
}
#assert(size_of(Language_Row{}.tag) == language_tag.LOCALE_TEXT_CAPACITY && size_of(Language_Row{}.language) == language_tag.LANGUAGE_BYTES)
#assert(size_of(Language_Row{}.script) == language_tag.SCRIPT_BYTES && size_of(Language_Row{}.region) == language_tag.REGION_BYTES)

// set_languages sets the languages that the principal reads, the first first, and keeps them in the store: set_languages([language("fr-CA"), language("en")]).
//
// A text of the system is written in the first language of the list that has it, else in its source language,
// English. An empty table sets the empty list: each text is in English. Each window draws again: the settings page
// wakes the compositor. The order is the store first, then the page. A list equal to the list of the page changes
// nothing and returns 1.
//
// - **languages**: a table of 0 to 8 records of `language_tag.Locale`, each a language in its canonical form;
//   `language("fr-CA")` in the console reads a tag into its record.
//
// The caller must act for the principal (**Acts_For_Principal**). The result is 1, or a negative number with an
// error record; on each refusal no language changes:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Too_Long` (-3): more than 8 records; value: their count; limit: 8.
// - `Out_Of_Range` (-3): the count of the table is past its capacity; value: the count; limit: the capacity.
// - `Bad_Value` (-3): a record that names no locale in its canonical form, or the root locale `und`; value: the
//   word of its `language_tag.Locale_Problem`, 0 for the root locale; found: the record, from 1.
// - `Exists` (-3): a language that the table holds in an earlier record; found: the record, from 1.
// - `Refused` (-4): the store did not keep the list. The page changed all the same, so the windows use the new list
//   until the next start of the machine.
//
// Example: `settings.set_languages([language("fr"), language("en")])`, then `settings.languages()` gives fr, then en.
@(export, link_name = "set_languages")
set_languages :: proc "c" (languages: ^system.Table_To_Read(language_tag.Locale), error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if languages.count > settings.LANGUAGE_LIST_CAPACITY {
		return errors.fail(error, ERROR_VALUE, .Too_Long, .Records, 1, i64(min(languages.count, u64(max(i64)))), settings.LANGUAGE_LIST_CAPACITY)
	}
	if languages.count > languages.capacity {
		return errors.fail(error, ERROR_VALUE, .Out_Of_Range, .Records, 1, i64(languages.count), i64(min(languages.capacity, u64(max(i64)))))
	}
	// A copy: the caller can change its records during the call.
	given: [settings.LANGUAGE_LIST_CAPACITY]language_tag.Locale
	count := copy(given[:], system.table_records(languages))
	list, problem, place, locale_problem := settings.language_list_of_locales(given[:count])
	record := i64(place) + 1
	switch problem {
	case .None:
	case .Too_Many:
		return errors.fail(error, ERROR_VALUE, .Too_Long, .Records, 1, i64(count), settings.LANGUAGE_LIST_CAPACITY)
	case .Bad_Locale:
		return errors.fail(error, ERROR_VALUE, .Bad_Value, .Records, 1, i64(locale_problem), 0, record)
	case .No_Language, .Record_Past_Count:
		return errors.fail(error, ERROR_VALUE, .Bad_Value, .Records, 1, 0, 0, record)
	case .Duplicate:
		return errors.fail(error, ERROR_VALUE, .Exists, .Records, 1, 0, 0, record)
	}
	current, _ := settings.read(page)
	current.languages = list
	if !change(current, current.zone_offset_minutes) {
		return errors.fail(error, ERROR_STORE, .Refused, .None, 1)
	}
	return 1
}

// languages gives the languages that the principal reads, the first first: the canonical tag of each, its language, its script and its region.
//
// An empty table: each text of the system is in English. The getter reads the settings page, which each process
// can read too: so it needs no grant. A refused page gives the empty list. The result is the count of languages; a
// table shorter than the list gets its first rows.
//
// Example: `settings.languages()` gives a row "fr-CA", "fr", "", "CA", then a row "en", "en", "", "".
@(export, link_name = "languages")
languages_get :: proc "c" (result: ^[]Language_Row) -> i64 {
	current, _ := settings.read(page)
	count := int(min(current.languages.count, settings.LANGUAGE_LIST_CAPACITY))
	for index in 0 ..< min(count, len(result^)) {
		locale := current.languages.locales[index]
		row: Language_Row
		_, _ = language_tag.tag_write(locale, row.tag[:])
		row.language = locale.language
		row.script = locale.script
		row.region = locale.region
		result[index] = row
	}
	return i64(count)
}

// repeat keeps count records in the store, one commit each, with the font and the subpixel order of each record from its number: the case of the loss of power of the machine test (a loss in the middle gives the record before or the record in flight, never a mix).
//
// It is a test export, not a setting that a reader changes. The machine test calls it, then cuts the power of the
// machine during the commits; at the next start, the boot pass must read one whole record. The font of record n
// is n mod 2, its subpixel order n mod 3, so a mix of two records shows. The page takes the last record.
//
// - **count**: the number of records, from 1 to 1000.
//
// The result is the count of records kept, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Bad_Value` (-3): a count outside 1 to 1000.
// - `Refused` (-4): the store refused a record; the record of the error holds its number.
@(export, link_name = "repeat")
repeat :: proc "c" (count: i64, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if count < 1 || count > 1000 {
		return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 1, count, 1000)
	}
	choice, _ := settings.read(page)
	// The font of the record n is the value n mod 2, its order of the
	// stripes the value n mod 3: the members in the order of their values.
	fonts := [2]settings.Font{.Vector, .Spleen}
	orders := [3]settings.Subpixel_Order{.Red_Green_Blue, .Blue_Green_Red, .None}
	for number in 0 ..< count {
		choice.font = fonts[number % 2]
		choice.subpixel_order = orders[number % 3]
		if !keep(choice, choice.zone_offset_minutes) {
			return errors.fail(error, ERROR_STORE, .Refused, .None, 1, number)
		}
	}
	page_write(choice, choice.zone_offset_minutes)
	system.log_fact(.Info, Records_Repeated{records = u64(count)})
	return count
}

// boot_pass reads the record of the store and writes the page: the pass of
// the boot, with no window.
boot_pass :: proc "contextless" () -> ! {
	start := system.nanoseconds()
	buffer: [size_of(settings.Kept_Settings) + 64]u8
	choice := settings.choice_default()
	zone_offset_minutes: i32
	source := Boot_Pass_Source.Nothing_Kept
	// A store that fails a read or refuses the write of the defaults: the
	// page still holds the defaults, and the stop says that the pass failed.
	store_refused := false
	if has_store {
		bytes, found, status := storage.read(&store, storage.ROOT, settings.KEPT_OBJECT_NAME, buffer[:])
		switch {
		case status != .Ok:
			source = .Read_Refused
			store_refused = true
		case !found:
		case:
			read, read_zone, valid := settings.kept_read(bytes)
			if valid {
				choice = read
				zone_offset_minutes = read_zone
				source = .Kept
			} else {
				// A record of another version (a disk of an older system),
				// or a record with a value that its setting does not have:
				// the defaults take its place in the store, so the next boot
				// reads a valid record and the defaults hold once, not at
				// each boot until the next change of a setting.
				if keep(choice, zone_offset_minutes) {
					source = .Record_Refused_Defaults_Kept
				} else {
					source = .Record_Refused_Defaults_Not_Kept
					store_refused = true
				}
			}
		}
	} else {
		source = .No_Store
	}
	page_write(choice, zone_offset_minutes, always = true)
	elapsed := value_kinds.Time_In_Microseconds((system.nanoseconds() - start) / 1000)
	font, subpixel_order, pointer_theme := value_field(choice, .Font), value_field(choice, .Subpixel_Order), value_field(choice, .Pointer_Theme)
	grid_fit, keyboard_layout, appearance_value := value_field(choice, .Grid_Fit), value_field(choice, .Keyboard_Layout), value_field(choice, .Appearance)
	scale_value := value_field(choice, .Scale)
	switch source {
	case .Nothing_Kept:
		system.log_fact(.Info, Boot_Pass_Nothing_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	case .Read_Refused:
		system.log_fact(.Info, Boot_Pass_Read_Refused{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	case .Kept:
		system.log_fact(.Info, Boot_Pass_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	case .Record_Refused_Defaults_Kept:
		system.log_fact(.Info, Boot_Pass_Record_Refused_Defaults_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	case .Record_Refused_Defaults_Not_Kept:
		system.log_fact(.Info, Boot_Pass_Record_Refused_Defaults_Not_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	case .No_Store:
		system.log_fact(.Info, Boot_Pass_No_Store{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	}
	if store_refused {
		system.stop(.Failed)
	}
	system.stop(.Done)
}

// A button of the row of the time zone: its label and how far it moves the
// zone.
Zone_Step :: struct {
	label:   string,
	minutes: i32,
}

// zone_row draws the row of the time zone at (x, y): its title, then the
// buttons that move the zone by an hour or by a quarter of an hour, with
// the value between them. A press stops at -12:00 and at +14:00. Each
// button is as wide as its label in the font that draws it, so no label is
// cut.
zone_row :: proc "contextless" (frame: ^interface.Frame, x, y: int, choice: settings.Choice) {
	interface.draw_text(frame.table, x, y + 4, settings.TIME_ZONE_TITLE, graphics.colors.dim)
	steps := [4]Zone_Step{{"-1 h", -60}, {"-15 min", -settings.ZONE_OFFSET_MINUTES_STEP}, {"+15 min", settings.ZONE_OFFSET_MINUTES_STEP}, {"+1 h", 60}}
	zone_buffer: [settings.ZONE_TEXT_SIZE]u8
	shown := settings.zone_text(zone_buffer[:], choice.zone_offset_minutes)
	left := x + 144
	for step, index in steps {
		if index == len(steps) / 2 {
			left = interface.draw_text(frame.table, left, y + 4, shown, graphics.colors.text) + 8
		}
		width := interface.text_measured_width(frame.table, interface.FONT_INTERFACE, step.label) + 16
		builder: interface.Text_Builder
		interface.text_put(&builder, settings.TIME_ZONE_NAME)
		interface.text_put(&builder, step.label)
		element := interface.identity(interface.text_of(&builder))
		if interface.button(frame, {left, y, width, 24}, element, step.label).activated {
			moved := clamp(choice.zone_offset_minutes + step.minutes, settings.ZONE_OFFSET_MINUTES_LEAST, settings.ZONE_OFFSET_MINUTES_MOST)
			change(choice, moved)
		}
		left += width + 8
	}
}

// The language of the list that the buttons "move up" and "remove" act on:
// its place, from 0. A press on a language of the list chooses it.
chosen_language: int

// language_button draws one button of the rows of the languages, as wide
// as its label, with an element named by the row and the label, and gives
// whether it was pressed and where the next button starts.
language_button :: proc "contextless" (frame: ^interface.Frame, left, y: int, row_name, label: string, in_use := false) -> (pressed: bool, next_left: int) {
	width := interface.text_measured_width(frame.table, interface.FONT_INTERFACE, label) + 16
	builder: interface.Text_Builder
	interface.text_put(&builder, "languages ")
	interface.text_put(&builder, row_name)
	interface.text_put(&builder, label)
	element := interface.identity(interface.text_of(&builder))
	pressed = interface.button(frame, {left, y, width, 24}, element, label, in_use).activated
	return pressed, left + width + 8
}

// languages_rows draws the three rows of the languages at (x, y): the list
// in its order, each language a button that chooses it; the buttons that
// move the chosen language up and remove it; the common languages that
// the list does not hold, to add at its end. A button past the right edge
// of the card is not drawn.
languages_rows :: proc "contextless" (frame: ^interface.Frame, x, y, right: int, choice: settings.Choice) {
	ROW :: 32
	list := choice.languages
	count := int(min(list.count, settings.LANGUAGE_LIST_CAPACITY))
	chosen_language = clamp(chosen_language, 0, max(count - 1, 0))
	interface.draw_text(frame.table, x, y + 4, "languages", graphics.colors.dim)
	left := x + 144
	if count == 0 {
		interface.draw_text(frame.table, left, y + 4, "none: English", graphics.colors.text)
	}
	for index in 0 ..< count {
		tag_buffer: [language_tag.LOCALE_TEXT_CAPACITY]u8
		tag, tag_ok := language_tag.tag_write(list.locales[index], tag_buffer[:])
		width := interface.text_measured_width(frame.table, interface.FONT_INTERFACE, tag) + 16
		if !tag_ok || left + width > right {
			break
		}
		pressed: bool
		if pressed, left = language_button(frame, left, y, "list ", tag, index == chosen_language); pressed {
			chosen_language = index
		}
	}
	left = x + 144
	if count > 0 {
		pressed: bool
		if pressed, left = language_button(frame, left, y + ROW, "", "move up"); pressed && chosen_language >= 1 {
			changed := choice
			changed.languages = settings.language_list_move_up(list, chosen_language)
			if change(changed, choice.zone_offset_minutes) {
				chosen_language -= 1
			}
		}
		if pressed, left = language_button(frame, left, y + ROW, "", "remove"); pressed {
			changed := choice
			changed.languages = settings.language_list_remove(list, chosen_language)
			change(changed, choice.zone_offset_minutes)
		}
	}
	// The common languages of the first build. The languages whose pack the
	// machine holds take their place when the packs come.
	common := [?]string{"en", "fr", "fr-CA", "de", "es", "ja", "ar"}
	interface.draw_text(frame.table, x + 144, y + 2 * ROW + 4, "add", graphics.colors.dim)
	left = x + 144 + 40
	for tag in common {
		locale, problem, _ := language_tag.tag_read(tag)
		if problem != .None {
			continue
		}
		added, add_problem := settings.language_list_add(list, locale)
		if add_problem != .None {
			// The list holds it, or is full.
			continue
		}
		width := interface.text_measured_width(frame.table, interface.FONT_INTERFACE, tag) + 16
		if left + width > right {
			break
		}
		pressed: bool
		if pressed, left = language_button(frame, left, y + 2 * ROW, "add ", tag); pressed {
			changed := choice
			changed.languages = added
			change(changed, choice.zone_offset_minutes)
		}
	}
}

// draw builds the window: a row of buttons for each setting and for the
// time zone, the rows of the languages, then the text of the system at the
// text size tokens, then the hash of the font of the cells.
draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	// A refused page shows the defaults: a press writes a whole page again.
	choice, _ := settings.read(page)
	values := settings.values_of(choice)
	frame := interface.window_frame_start(&window_memory)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	interface.action_bar_input_take(&frame, &bar)
	count: interface.Text_Builder
	interface.text_put(&count, "change ")
	interface.text_put_number(&count, u64(choice.change_count / 2))
	// A row: a button of 24 pixels and a gap of 8. The card of the text
	// under the rows needs 150 pixels of content, so that its line of facts
	// is under the caption of its large number: 11 rows of 32, the
	// settings, the time zone and the languages, leave it 168 in the window.
	ROW :: 32
	rows_height := (len(settings.Setting) + 1 + LANGUAGE_ROWS) * ROW
	content := interface.card(&frame, {8, 8, WIDTH - 16, 40 + rows_height + 32}, "SETTINGS", has_store ? "kept in the store of settings" : "NOT kept: no store", graphics.colors.kernel, interface.text_of(&count))
	for &description, setting in settings.descriptions {
		y := content.y + int(setting) * ROW
		interface.draw_text(frame.table, content.x, y + 4, description.title, graphics.colors.dim)
		for value_name, place in description.value_names[:description.value_count] {
			// A value that the border refuses has no button: the scales past
			// the window bound, which no window fits yet.
			word := settings.word_of_value(setting, place)
			if !settings.value_valid(setting, word) {
				continue
			}
			area := interface.Area{content.x + 144 + place * 104, y, 96, 24}
			builder: interface.Text_Builder
			interface.text_put(&builder, description.name)
			interface.text_put(&builder, value_name)
			element := interface.identity(interface.text_of(&builder))
			in_use := values[setting] == word
			if interface.button(&frame, area, element, value_name, in_use).activated {
				if changed, changed_ok, _ := with_value(choice, setting, place); changed_ok {
					change(changed, choice.zone_offset_minutes)
				}
			}
			if in_use {
				// The palette sets this setting with the parameter of the
				// same name of the export set, and its row has the same act
				// name: "settings.set:" and the name of the parameter
				// (src/modules/system/console/palette_provider.odin).
				// The button of the value in use is where go to puts the
				// focus.
				act: interface.Text_Builder
				interface.text_put(&act, "settings.set:")
				interface.text_put(&act, description.name)
				interface.element_act_name(&frame, element, interface.text_of(&act))
			}
		}
	}
	zone_row(&frame, content.x, content.y + len(settings.Setting) * ROW, choice)
	languages_rows(&frame, content.x, content.y + (len(settings.Setting) + 1) * ROW, content.x + content.width, choice)
	interface.draw_text(frame.table, content.x, content.y + rows_height + 8, "the console: settings.set(font = .spleen)", graphics.colors.dim)

	top := 8 + 40 + rows_height + 32 + 8
	vector := choice.font == .Vector && graphics.text_vector_drawn()
	sample := interface.card(&frame, {8, top, WIDTH - 16, HEIGHT - top - 8 - interface.ACTION_BAR_ROW_HEIGHT}, "THE TEXT OF THE SYSTEM", vector ? "the vector font, drawn by this process" : "Spleen 8x16, the fallback", graphics.colors.machine)
	lines := [?]string {
		"> print(monitor.processes())   31 processes",
		"compositor   12.4 ms   2 418 pages   runs",
		"{fill} [rings] gi Rb 0O 1lI  ok: 0x4F3A",
	}
	for line, index in lines {
		interface.draw_text(frame.table, sample.x, sample.y + index * 16, line, graphics.colors.text)
	}
	// The heading, then the large number with its caption under it: each
	// text size token that the desktop uses, one under the other.
	heading_top := sample.y + 3 * graphics.LINE_HEIGHT + graphics.GAP
	number_top := heading_top + interface.draw_heading(&frame, sample.x, heading_top, sample.width, "EEVDF fair", graphics.colors.process) + graphics.GAP
	interface.large_number(&frame, sample.x, number_top, "12 345", graphics.colors.text)
	interface.draw_caption(&frame, sample.x, number_top + interface.line_height(interface.FONT_LARGE), sample.width, "wakes in one second")
	// The hash of the font file of the cells, which the record of the font
	// outlines names and this process opened.
	facts: interface.Text_Builder
	cells_font := &text_rendering.state.fonts[.Paper_Mono]
	if !cells_font.opened {
		interface.text_put(&facts, "no font outlines: the text is Spleen 8x16")
	} else {
		interface.text_put(&facts, "the font of the cells: hash ")
		hex := "0123456789abcdef"
		for byte in cells_font.hash[:4] {
			interface.text_put(&facts, hex[byte >> 4:][:1])
			interface.text_put(&facts, hex[byte & 15:][:1])
		}
	}
	interface.draw_text(frame.table, sample.x, sample.y + sample.height - 16, interface.text_of(&facts), graphics.colors.dim)
	items := bar_items()
	bar_result := interface.action_bar(&frame, {0, HEIGHT - interface.ACTION_BAR_ROW_HEIGHT, WIDTH, interface.ACTION_BAR_ROW_HEIGHT}, items[:], &bar)
	interface.window_frame_end(&window_memory.drawing, &frame, window)
	if choice.change_count != drawn_change && drawn_change != 1 {
		system.log_fact(.Info, Values_Drawn{font = value_field(choice, .Font), subpixel_order = value_field(choice, .Subpixel_Order), pointer_theme = value_field(choice, .Pointer_Theme), grid_fit = value_field(choice, .Grid_Fit), keyboard_layout = value_field(choice, .Keyboard_Layout), appearance = value_field(choice, .Appearance), scale = value_field(choice, .Scale)})
	}
	drawn_change = choice.change_count
	return bar_result
}

// draw_with_bar draws a frame and, when a press on an item of the action
// bar ran its key, a second frame that takes the key, as a typed key: the
// focus moves, or the button with the focus is pressed.
draw_with_bar :: proc "contextless" (window: ^display.Window) {
	if result := draw(window); result.ran && interface.input_key_add(&window_memory.drawing.input, result.run) {
		draw(window)
	}
}

// The entry of settings: the boot pass, or the window and the service.
//
// The entry maps the settings page; with no page it writes "settings: no
// settings page" and stops with `Refused` when the context names no page or
// a handle that it cannot map, and with `Failed` for any other status. It
// opens its private store; a process with no store still runs, and says
// "NOT kept: no store".
//
// - **The boot pass** (the context value `VALUE_BOOT_PASS` is not 0): it
//   reads the record of its store, writes the page, wakes the compositor,
//   writes "settings: the boot pass: ..." with its time, and stops with
//   `Done`. A missing or unreadable record gives the defaults. A record of
//   another version gives the defaults, which the pass keeps in its place.
//   A store that fails the read or refuses that write gives the defaults
//   too, and the pass stops with `Failed`.
// - **Otherwise**: it opens its window (with none, it stops with `Failed`)
//   and its service, draws, and writes "settings: ok, ...". Then one loop
//   waits on the events of the window and on the service ring, runs the
//   calls, and draws after an event. It never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	page_handle := ctx.handles[settings.GRANT_PAGE]
	address, status := system.memory_map(page_handle)
	if status != .Ok {
		system.log_fact(.Info, No_Settings_Page{status = op.Status_Word(status)})
		system.stop(system.stop_outcome_of_grant(page_handle, status))
	}
	page = (^settings.Page)(address)
	date_page = date.page_of(ctx)
	store, has_store = storage.open(ctx)
	if ctx.values[settings.VALUE_BOOT_PASS] != 0 {
		boot_pass()
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "settings")
	if !ok {
		system.stop(.Failed)
	}
	service, _ = system.service_open(ctx)
	draw_with_bar(&window)
	started, _ := settings.read(page)
	system.log_fact(.Info, Window_Ready{font = value_field(started, .Font), subpixel_order = value_field(started, .Subpixel_Order), pointer_theme = value_field(started, .Pointer_Theme), grid_fit = value_field(started, .Grid_Fit), keyboard_layout = value_field(started, .Keyboard_Layout), appearance = value_field(started, .Appearance), scale = value_field(started, .Scale)})
	for {
		wait := system.wait_begin()
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		deadline := appearance_edge_step(&wait)
		system.wait_end(&wait, deadline)
		system.service_run(&service)
		if interface.window_events(&window_memory.drawing, &window) {
			draw_with_bar(&window)
		}
	}
}
