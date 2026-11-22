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
import "modus:layout"
import "modus:storage"
import "modus:system"
import "modus:text_rendering"

// The size of the window at its start: one row of 32 for each setting and
// for the time zone, the three rows of the languages, and the card of the
// text of the system. Each place in it comes from its layout tree
// (settings_layout), from the size that the window has now.
WIDTH :: 560
HEIGHT :: 688
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

// The buttons of the row of the time zone, from the left. The value of the
// zone is between the two halves. A press stops at -12:00 and at +14:00.
@(rodata)
zone_steps := [4]Zone_Step{{"-1 h", -60}, {"-15 min", -settings.ZONE_OFFSET_MINUTES_STEP}, {"+15 min", settings.ZONE_OFFSET_MINUTES_STEP}, {"+1 h", 60}}

// The common languages of the first build, which the third row of the
// languages adds. The languages whose pack the machine holds take their
// place when the packs come.
@(rodata)
common_languages := [7]string{"en", "fr", "fr-CA", "de", "es", "ja", "ar"}

// The lines of the text of the system that the second card shows at the
// size of the body text.
@(rodata)
sample_lines := [3]string {
	"> print(monitor.processes())   31 processes",
	"compositor   12.4 ms   2 418 pages   runs",
	"{fill} [rings] gi Rb 0O 1lI  ok: 0x4F3A",
}
SAMPLE_HEADING :: "EEVDF fair"
SAMPLE_NUMBER :: "12 345"
SAMPLE_CAPTION :: "wakes in one second"

// A row of the card SETTINGS: a button of BUTTON_HEIGHT and the gap under it.
ROW :: 32
BUTTON_HEIGHT :: 24
// A button of a value of a setting is this wide, or as wide as its label
// and its padding when the label is wider; it gives room down to its label
// when the row is too narrow.
VALUE_BUTTON_WIDTH :: 96
// The room on each side of the label of a button.
BUTTON_LABEL_PADDING :: 8
// The column of the title of a row, with the gap after it: the first button
// of each row starts at the same place.
TITLE_COLUMN :: 144
// The room of the word "add" before the languages to add, with its gap.
ADD_COLUMN :: 40
// The title of a row sits this far under the top of the row, on the line of
// the labels of its buttons.
TITLE_DROP :: 4

// The texts of a frame that the layout measures and the draw shows: the
// draw reads the same texts that gave the widths.
Frame_Texts :: struct {
	zone_buffer:    [settings.ZONE_TEXT_SIZE]u8,
	zone:           string, // The zone in force: "+08:00".
	tag_buffers:    [settings.LANGUAGE_LIST_CAPACITY][language_tag.LOCALE_TEXT_CAPACITY]u8,
	tags:           [settings.LANGUAGE_LIST_CAPACITY]string, // The canonical tag of each language of the list.
	list_count:     int, // The languages of the list.
	tags_shown:     int, // The languages of the list whose tag was written: the row stops at the first that was not.
	added:          [len(common_languages)]settings.Language_List, // The list with each common language at its end.
	can_add:        [len(common_languages)]bool, // The list does not hold the common language, and is not full.
}

// frame_texts_of gives the texts of a frame of the window.
frame_texts_of :: proc "contextless" (texts: ^Frame_Texts, choice: settings.Choice) {
	texts.zone = settings.zone_text(texts.zone_buffer[:], choice.zone_offset_minutes)
	list := choice.languages
	texts.list_count = int(min(list.count, settings.LANGUAGE_LIST_CAPACITY))
	texts.tags_shown = 0
	for index in 0 ..< texts.list_count {
		tag, tag_ok := language_tag.tag_write(list.locales[index], texts.tag_buffers[index][:])
		if !tag_ok {
			break
		}
		texts.tags[index] = tag
		texts.tags_shown += 1
	}
	for tag, index in common_languages {
		texts.can_add[index] = false
		locale, problem, _ := language_tag.tag_read(tag)
		if problem != .None {
			continue
		}
		added, add_problem := settings.language_list_add(list, locale)
		// A problem: the list holds the language, or is full.
		texts.added[index] = added
		texts.can_add[index] = add_problem == .None
	}
}

// The boxes of the window that the draw reads after the solve. NO_BOX: the
// frame has no such element.
Settings_Boxes :: struct {
	settings_card:   layout.Box_Index,
	setting_titles:  [settings.Setting]layout.Box_Index,
	value_buttons:   [settings.Setting][settings.VALUE_NAME_CAPACITY]layout.Box_Index, // NO_BOX: a value that the border refuses has no button.
	zone_title:      layout.Box_Index,
	zone_value:      layout.Box_Index,
	zone_buttons:    [len(zone_steps)]layout.Box_Index,
	languages_title: layout.Box_Index,
	languages_none:  layout.Box_Index,
	language_list:   [settings.LANGUAGE_LIST_CAPACITY]layout.Box_Index,
	move_up:         layout.Box_Index,
	remove:          layout.Box_Index,
	add_title:       layout.Box_Index,
	add_buttons:     [len(common_languages)]layout.Box_Index,
	rows:            layout.Box_Index, // The rows of the card SETTINGS: a language button past its right edge is not drawn.
	console_hint:    layout.Box_Index,
	sample_card:     layout.Box_Index,
	sample_lines:    [len(sample_lines)]layout.Box_Index,
	heading:         layout.Box_Index,
	number:          layout.Box_Index,
	caption:         layout.Box_Index,
	facts:           layout.Box_Index,
	action_bar:      layout.Box_Index,
}

// The layout tree of a frame. A global: the tree is too large for the stack.
layout_tree: layout.Box_Tree

// Layout_Builder adds boxes to a tree and keeps the first refusal, so that
// one check after the last box says whether the whole tree was built.
Layout_Builder :: struct {
	tree:   ^layout.Box_Tree,
	status: layout.Box_Status,
}

builder_open :: proc "contextless" (builder: ^Layout_Builder, description: layout.Box_Description) -> layout.Box_Index {
	index, status := layout.box_open(builder.tree, description)
	if builder.status == .Done {
		builder.status = status
	}
	return index
}

builder_add :: proc "contextless" (builder: ^Layout_Builder, description: layout.Box_Description) -> layout.Box_Index {
	index, status := layout.box_add(builder.tree, description)
	if builder.status == .Done {
		builder.status = status
	}
	return index
}

builder_close :: proc "contextless" (builder: ^Layout_Builder) {
	status := layout.box_close(builder.tree)
	if builder.status == .Done {
		builder.status = status
	}
}

// area_of gives the area of the interface package of a box that the
// solver placed.
area_of :: proc "contextless" (tree: ^layout.Box_Tree, index: layout.Box_Index) -> interface.Area {
	box := layout.box_of(tree, index)
	if box == nil {
		return {}
	}
	return {int(box.rect.x), int(box.rect.y), int(box.rect.width), int(box.rect.height)}
}

// The boxes that the layout of settings repeats.

// A space of a height across the whole width: the parts of a card that its
// frame draws, over and under its content.
spacer :: proc "contextless" (height: i32) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.px(height)}}
}

// A card: its content between the margins, under the room of its title.
card_box :: proc "contextless" (height: layout.Size, tokens: layout.Element_Tokens) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = height}, child_axis = .Y, padding = {.X = tokens.margin, .Y = 0}}
}

// A row of the card SETTINGS: its title, then its buttons, with the gap between each two.
row_box :: proc "contextless" (tokens: layout.Element_Tokens) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.px(ROW)}, child_axis = .X, gap = tokens.gap}
}

title_box :: proc "contextless" (tokens: layout.Element_Tokens) -> layout.Box_Description {
	return {size = {.X = layout.px(TITLE_COLUMN - tokens.gap), .Y = layout.px(BUTTON_HEIGHT)}}
}

// A button as wide as its label in the font that draws it, so no label is cut.
label_button_box :: proc "contextless" (table: ^interface.Draw_Table, label: string) -> layout.Box_Description {
	width := i32(interface.text_measured_width(table, interface.FONT_INTERFACE, label)) + 2 * BUTTON_LABEL_PADDING
	return {size = {.X = layout.px(width), .Y = layout.px(BUTTON_HEIGHT)}}
}

// A text of the body font as a box: its measured width.
text_box :: proc "contextless" (table: ^interface.Draw_Table, text: string) -> layout.Box_Description {
	return {size = {.X = layout.px(i32(interface.text_measured_width(table, {}, text))), .Y = layout.px(BUTTON_HEIGHT)}}
}

// settings_layout builds and solves the layout tree of the window at a
// size: the card SETTINGS as high as its rows, the card of the text of the
// system in the height left, and the action bar at the bottom. The heading
// and the caption of the second card wrap in its width, so the tree is
// solved once for that width, then again with their heights. ok false: the
// tree refused a box, and the frame draws no card.
settings_layout :: proc "contextless" (table: ^interface.Draw_Table, choice: settings.Choice, texts: ^Frame_Texts, width, height: int, tokens: layout.Element_Tokens) -> (boxes: Settings_Boxes, ok: bool) {
	tree := &layout_tree
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y}) != .Done {
		return {}, false
	}
	builder := Layout_Builder{tree = tree}
	gap := tokens.gap
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, padding = {.X = gap, .Y = gap}, gap = gap})

	boxes.settings_card = builder_open(&builder, card_box(layout.children_sum(), tokens))
	builder_add(&builder, spacer(tokens.title))
	boxes.rows = builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y})
	for &description, setting in settings.descriptions {
		builder_open(&builder, row_box(tokens))
		boxes.setting_titles[setting] = builder_add(&builder, title_box(tokens))
		for value_name, place in description.value_names[:description.value_count] {
			// A value that the border refuses has no button: the scales past
			// the window bound, which no window fits yet.
			if !settings.value_valid(setting, settings.word_of_value(setting, place)) {
				continue
			}
			label := label_button_box(table, value_name)
			label_width := label.size[.X].value
			button := layout.Box_Description{size = {.X = {kind = .Pixels, value = VALUE_BUTTON_WIDTH, strictness = 0, least = label_width}, .Y = layout.px(BUTTON_HEIGHT)}}
			boxes.value_buttons[setting][place] = builder_add(&builder, button)
		}
		builder_close(&builder)
	}
	builder_open(&builder, row_box(tokens))
	boxes.zone_title = builder_add(&builder, title_box(tokens))
	for step, index in zone_steps {
		if index == len(zone_steps) / 2 {
			boxes.zone_value = builder_add(&builder, text_box(table, texts.zone))
		}
		boxes.zone_buttons[index] = builder_add(&builder, label_button_box(table, step.label))
	}
	builder_close(&builder)
	// The languages: the list, each language a button that chooses it.
	builder_open(&builder, row_box(tokens))
	boxes.languages_title = builder_add(&builder, title_box(tokens))
	if texts.list_count == 0 {
		boxes.languages_none = builder_add(&builder, text_box(table, "none: English"))
	}
	for index in 0 ..< texts.tags_shown {
		boxes.language_list[index] = builder_add(&builder, label_button_box(table, texts.tags[index]))
	}
	builder_close(&builder)
	// The buttons that move the chosen language up and remove it.
	builder_open(&builder, row_box(tokens))
	builder_add(&builder, title_box(tokens))
	if texts.list_count > 0 {
		boxes.move_up = builder_add(&builder, label_button_box(table, "move up"))
		boxes.remove = builder_add(&builder, label_button_box(table, "remove"))
	}
	builder_close(&builder)
	// The common languages that the list does not hold, to add at its end.
	builder_open(&builder, row_box(tokens))
	builder_add(&builder, title_box(tokens))
	boxes.add_title = builder_add(&builder, {size = {.X = layout.px(ADD_COLUMN - gap), .Y = layout.px(BUTTON_HEIGHT)}})
	for tag, index in common_languages {
		if texts.can_add[index] {
			boxes.add_buttons[index] = builder_add(&builder, label_button_box(table, tag))
		}
	}
	builder_close(&builder)
	builder_close(&builder)
	builder_add(&builder, spacer(gap))
	boxes.console_hint = builder_add(&builder, spacer(graphics.LINE_HEIGHT))
	builder_add(&builder, spacer(gap))
	builder_close(&builder)

	// The text of the system at each text size token that the desktop
	// uses, one under the other; the line of the facts at the bottom.
	boxes.sample_card = builder_open(&builder, card_box(layout.fill(), tokens))
	builder_add(&builder, spacer(tokens.title))
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y})
	for _, index in sample_lines {
		boxes.sample_lines[index] = builder_add(&builder, spacer(graphics.LINE_HEIGHT))
	}
	builder_add(&builder, spacer(gap))
	boxes.heading = builder_add(&builder, spacer(i32(interface.line_height(interface.FONT_HEADING))))
	builder_add(&builder, spacer(gap))
	boxes.number = builder_add(&builder, spacer(i32(interface.line_height(interface.FONT_LARGE))))
	boxes.caption = builder_add(&builder, spacer(i32(interface.line_height(interface.FONT_CAPTION))))
	builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}})
	boxes.facts = builder_add(&builder, spacer(graphics.LINE_HEIGHT))
	builder_close(&builder)
	builder_add(&builder, spacer(gap))
	builder_close(&builder)
	builder_close(&builder)
	boxes.action_bar = builder_add(&builder, {size = {.X = layout.fill(), .Y = layout.px(interface.ACTION_BAR_ROW_HEIGHT)}})
	if builder.status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	// The heading and the caption take the lines that they need in the
	// width that the first solve gave them.
	room := int(tree.boxes[boxes.heading].rect.width)
	tree.boxes[boxes.heading].size[.Y] = layout.px(i32(interface.heading_height(table, SAMPLE_HEADING, room)))
	tree.boxes[boxes.caption].size[.Y] = layout.px(i32(interface.caption_height(table, SAMPLE_CAPTION, room)))
	if layout.solve(tree) != .Done {
		return {}, false
	}
	return boxes, true
}

// zone_row_draw draws the row of the time zone: its title, then the
// buttons that move the zone by an hour or by a quarter of an hour, with
// the value between them.
zone_row_draw :: proc "contextless" (frame: ^interface.Frame, boxes: ^Settings_Boxes, choice: settings.Choice, texts: ^Frame_Texts, tokens: layout.Element_Tokens) {
	tree := &layout_tree
	title := area_of(tree, boxes.zone_title)
	interface.draw_text(frame.table, title.x, title.y + TITLE_DROP, settings.TIME_ZONE_TITLE, tokens.text_dim)
	value := area_of(tree, boxes.zone_value)
	interface.draw_text(frame.table, value.x, value.y + TITLE_DROP, texts.zone, tokens.text)
	for step, index in zone_steps {
		builder: interface.Text_Builder
		interface.text_put(&builder, settings.TIME_ZONE_NAME)
		interface.text_put(&builder, step.label)
		element := interface.identity(interface.text_of(&builder))
		if interface.button(frame, area_of(tree, boxes.zone_buttons[index]), element, step.label).activated {
			moved := clamp(choice.zone_offset_minutes + step.minutes, settings.ZONE_OFFSET_MINUTES_LEAST, settings.ZONE_OFFSET_MINUTES_MOST)
			change(choice, moved)
		}
	}
}

// The language of the list that the buttons "move up" and "remove" act on:
// its place, from 0. A press on a language of the list chooses it.
chosen_language: int

// language_button draws one button of the rows of the languages, with an
// element named by the row and the label, and gives whether it was
// pressed. A button past the right edge of the card is not drawn: drawn
// says so, and no button after it in its row is drawn either.
language_button :: proc "contextless" (frame: ^interface.Frame, index: layout.Box_Index, right: int, row_name, label: string, in_use := false) -> (pressed: bool, drawn: bool) {
	area := area_of(&layout_tree, index)
	if area.x + area.width > right {
		return false, false
	}
	builder: interface.Text_Builder
	interface.text_put(&builder, "languages ")
	interface.text_put(&builder, row_name)
	interface.text_put(&builder, label)
	element := interface.identity(interface.text_of(&builder))
	return interface.button(frame, area, element, label, in_use).activated, true
}

// languages_rows_draw draws the three rows of the languages: the list in
// its order, each language a button that chooses it; the buttons that move
// the chosen language up and remove it; the common languages that the list
// does not hold, to add at its end.
languages_rows_draw :: proc "contextless" (frame: ^interface.Frame, boxes: ^Settings_Boxes, choice: settings.Choice, texts: ^Frame_Texts, tokens: layout.Element_Tokens) {
	tree := &layout_tree
	list := choice.languages
	count := texts.list_count
	rows := area_of(tree, boxes.rows)
	right := rows.x + rows.width
	chosen_language = clamp(chosen_language, 0, max(count - 1, 0))
	title := area_of(tree, boxes.languages_title)
	interface.draw_text(frame.table, title.x, title.y + TITLE_DROP, "languages", tokens.text_dim)
	if count == 0 {
		none := area_of(tree, boxes.languages_none)
		interface.draw_text(frame.table, none.x, none.y + TITLE_DROP, "none: English", tokens.text)
	}
	for index in 0 ..< texts.tags_shown {
		pressed, drawn := language_button(frame, boxes.language_list[index], right, "list ", texts.tags[index], index == chosen_language)
		if !drawn {
			break
		}
		if pressed {
			chosen_language = index
		}
	}
	if count > 0 {
		if pressed, _ := language_button(frame, boxes.move_up, right, "", "move up"); pressed && chosen_language >= 1 {
			changed := choice
			changed.languages = settings.language_list_move_up(list, chosen_language)
			if change(changed, choice.zone_offset_minutes) {
				chosen_language -= 1
			}
		}
		if pressed, _ := language_button(frame, boxes.remove, right, "", "remove"); pressed {
			changed := choice
			changed.languages = settings.language_list_remove(list, chosen_language)
			change(changed, choice.zone_offset_minutes)
		}
	}
	add := area_of(tree, boxes.add_title)
	interface.draw_text(frame.table, add.x, add.y + TITLE_DROP, "add", tokens.text_dim)
	for tag, index in common_languages {
		if !texts.can_add[index] {
			continue
		}
		pressed, drawn := language_button(frame, boxes.add_buttons[index], right, "add ", tag)
		if !drawn {
			break
		}
		if pressed {
			changed := choice
			changed.languages = texts.added[index]
			change(changed, choice.zone_offset_minutes)
		}
	}
}

// draw builds the window from its layout tree at the size of the window
// now: a row of buttons for each setting and for the time zone, the rows
// of the languages, then the text of the system at the text size tokens,
// then the hash of the font of the cells, and the action bar.
draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	// A refused page shows the defaults: a press writes a whole page again.
	choice, _ := settings.read(page)
	values := settings.values_of(choice)
	frame := interface.window_frame_start(&window_memory)
	// graphics holds only members of the appearance: the tokens of the
	// standard contrast are the colors that the window drew with before.
	tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
	width, height := window.width, window.height
	interface.background(&frame, {0, 0, width, height})
	interface.action_bar_input_take(&frame, &bar)
	texts: Frame_Texts
	frame_texts_of(&texts, choice)
	boxes, laid_out := settings_layout(frame.table, choice, &texts, width, height, tokens)
	tree := &layout_tree
	bar_area := interface.Area{0, height - interface.ACTION_BAR_ROW_HEIGHT, width, interface.ACTION_BAR_ROW_HEIGHT}
	if laid_out {
		bar_area = area_of(tree, boxes.action_bar)
		count: interface.Text_Builder
		interface.text_put(&count, "change ")
		interface.text_put_number(&count, u64(choice.change_count / 2))
		interface.card(&frame, area_of(tree, boxes.settings_card), "SETTINGS", has_store ? "kept in the store of settings" : "NOT kept: no store", graphics.colors.kernel, interface.text_of(&count))
		for &description, setting in settings.descriptions {
			title := area_of(tree, boxes.setting_titles[setting])
			interface.draw_text(frame.table, title.x, title.y + TITLE_DROP, description.title, tokens.text_dim)
			for value_name, place in description.value_names[:description.value_count] {
				if boxes.value_buttons[setting][place] == layout.NO_BOX {
					continue
				}
				word := settings.word_of_value(setting, place)
				builder: interface.Text_Builder
				interface.text_put(&builder, description.name)
				interface.text_put(&builder, value_name)
				element := interface.identity(interface.text_of(&builder))
				in_use := values[setting] == word
				if interface.button(&frame, area_of(tree, boxes.value_buttons[setting][place]), element, value_name, in_use).activated {
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
		zone_row_draw(&frame, &boxes, choice, &texts, tokens)
		languages_rows_draw(&frame, &boxes, choice, &texts, tokens)
		hint := area_of(tree, boxes.console_hint)
		interface.draw_text(frame.table, hint.x, hint.y, "the console: settings.set(font = .spleen)", tokens.text_dim)

		vector := choice.font == .Vector && graphics.text_vector_drawn()
		interface.card(&frame, area_of(tree, boxes.sample_card), "THE TEXT OF THE SYSTEM", vector ? "the vector font, drawn by this process" : "Spleen 8x16, the fallback", graphics.colors.machine)
		for line, index in sample_lines {
			place := area_of(tree, boxes.sample_lines[index])
			interface.draw_text(frame.table, place.x, place.y, line, tokens.text)
		}
		// The heading, then the large number with its caption under it: each
		// text size token that the desktop uses, one under the other.
		heading := area_of(tree, boxes.heading)
		interface.draw_heading(&frame, heading.x, heading.y, heading.width, SAMPLE_HEADING, graphics.colors.process)
		number := area_of(tree, boxes.number)
		interface.large_number(&frame, number.x, number.y, SAMPLE_NUMBER, tokens.text)
		caption := area_of(tree, boxes.caption)
		interface.draw_caption(&frame, caption.x, caption.y, caption.width, SAMPLE_CAPTION)
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
		facts_place := area_of(tree, boxes.facts)
		interface.draw_text(frame.table, facts_place.x, facts_place.y, interface.text_of(&facts), tokens.text_dim)
	}
	items := bar_items()
	bar_result := interface.action_bar(&frame, bar_area, items[:], &bar)
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
