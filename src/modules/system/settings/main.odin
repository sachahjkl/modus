// The settings of the system (docs/FONTS.md, "The setting"): the font of
// the system, the order of the color stripes of the screen, the pointer
// theme, the grid fit of the vector font, the layout of the keyboard, the
// appearance of the desktop and the time zone. The window shows each
// setting as a row of buttons and the text of the system at its three
// sizes; the exports set() and get() make the same changes from the console
// and from `modustool call`.
//
// The time zone (src/md/features/time_zone.md) is a fixed offset from UTC,
// "+08:00". This process writes it on the settings page; the process `date`
// copies it into the date page, and the root service then moves the
// appearance in force when the new local time asks for it. So this process
// computes the appearance in force with the zone of the date page, never
// with the zone that it writes.
//
// This process is the one writer of the values of the settings page
// (modus:contract/settings). A change is written first to its private
// store, as one record in one object (one commit), then to the page, with
// the appearance in force that the setting `appearance` gives now
// (src/md/features/appearance.md); the page wakes the compositor, which
// gives the new font, pointer theme and appearance to each window: every
// process draws again, with no code of its own for it. With the setting
// `auto`, the root service changes the appearance in force at 07:00 and at
// 19:00: this process runs only while its window is open.
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
// `settings.set("font", "spleen")`.
//
// **Grants**, as the root service gives them:
//
// - **Settings**: the settings page with the right Write. No other process
//   can write it.
// - **Store**: its private store, which keeps the record of the settings
//   across a stop of the machine.
// - **Serve**: the exports `set`, `get` and `repeat`.
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

import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/isolated"
import op "modus:contract/operation"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "modus:support/appearance"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/storage"
import "modus:support/system"
import "modus:support/text_rendering"

WIDTH :: 560
HEIGHT :: 560

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
// a name: its index in the names of the values of the setting. ok false: the
// setting has no value of that index.
with_value :: proc "contextless" (choice: settings.Choice, setting: settings.Setting, index: int) -> (changed: settings.Choice, ok: bool) {
	values := settings.values_of(choice)
	values[setting] = u32(index)
	changed, _, ok = settings.choice_of_values(values)
	if !ok {
		return choice, false
	}
	changed.appearance_in_force = choice.appearance_in_force
	changed.zone_offset_minutes = choice.zone_offset_minutes
	changed.change_count = choice.change_count
	return changed, true
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

// in_force_now gives the appearance in force of the values at this moment:
// the setting `appearance`, with `auto` by the rule of the day over the
// date page (src/md/features/appearance.md), and the moment that the rule
// read, for the fact of the appearance. The zone is the one of the date
// page: the root service writes the appearance of a new zone after the
// process `date` copies it, so the page never holds the appearance of a
// zone that the date page does not have yet.
in_force_now :: proc "contextless" (choice: settings.Choice) -> (settings.Appearance_In_Force, appearance.Moment) {
	moment := appearance.moment_of(date_page, system.time())
	return appearance.in_force_of(choice.appearance, moment), moment
}

// page_write writes the values and their appearance in force on the page in
// one change, and wakes the compositor and the root service. Before the
// write, it writes the sentence of the appearance in force on the log when
// the setting or the appearance changes, or when `always`: the log then
// has it before the line of the compositor that the write causes.
page_write :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32, always := false) {
	before, before_ok := settings.read(page)
	in_force, moment := in_force_now(choice)
	if always || !before_ok || before.appearance != choice.appearance || before.appearance_in_force != in_force {
		appearance_log(choice.appearance, moment)
	}
	settings.write(page, choice, zone_offset_minutes, in_force)
	system.word_wake(&page.change_count, 64)
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

// change keeps the values and the zone, then writes them on the page and
// wakes the compositor and the process `date`.
change :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32) -> bool {
	current, current_ok := page_choice()
	zone := settings.zone_offset_minutes_valid(zone_offset_minutes)
	values_same := current_ok && settings.values_of(current) == settings.values_of(choice)
	if values_same && current.zone_offset_minutes == zone {
		return true
	}
	kept := keep(choice, zone)
	if !values_same {
		system.log_fact(.Info, Values_Changed{font = value_field(choice, .Font), subpixel_order = value_field(choice, .Subpixel_Order), pointer_theme = value_field(choice, .Pointer_Theme), grid_fit = value_field(choice, .Grid_Fit), keyboard_layout = value_field(choice, .Keyboard_Layout), appearance = value_field(choice, .Appearance), store = store_field(kept)})
	}
	if current.zone_offset_minutes != zone {
		zone_buffer: [settings.ZONE_TEXT_SIZE]u8
		system.log_fact(.Info, Zone_Changed{zone = value_kinds.text_field(settings.zone_text(zone_buffer[:], zone), ZONE_FIELD_BYTES), store = store_field(kept)})
	}
	page_write(choice, zone)
	return kept
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

// setting_of finds a setting by its name.
@(private = "file")
setting_of :: proc "contextless" (name: string) -> (setting: settings.Setting, found: bool) {
	for description, each in settings.descriptions {
		if description.name == name {
			return each, true
		}
	}
	return {}, false
}

// set changes a setting of the system, and keeps it in the store: set("font", "vector" or "spleen"); set("subpixel_order", "rgb", "bgr" or "none"); set("pointer_theme", "owner" or "system"); set("grid_fit", "on" or "off"); set("keyboard_layout", "us" or "french"); set("appearance", "auto", "dark" or "light"); set("time_zone", "+08:00").
//
// Every window draws again: the settings page wakes the compositor, which gives the new font, pointer theme and
// appearance to each window. The order is the store first, then the page, so a stop of the machine between the two
// keeps the new value. A value equal to the value of the page changes nothing and returns 1. The setting
// `appearance` `auto` gives the light appearance from 07:00 to 19:00 of the local time and the dark one at night:
// the page holds the appearance in force, which the log says with the time that the rule read.
//
// The time zone is a fixed offset from UTC, with no summer time: a sign, the hours and the minutes, from "-12:00"
// to "+14:00", by quarters of an hour; "+00:00", UTC, is the default. The bar then shows the local time, and the
// rule of `auto` counts its hours in it.
//
// - **name**: the name of a setting: `font`, `subpixel_order`, `pointer_theme`, `grid_fit`, `keyboard_layout`,
//   `appearance` or `time_zone`; 32 bytes at most.
// - **value**: one of the values of that setting, as above; 32 bytes at most.
//
// The caller must act for the principal (**Acts_For_Principal**): the console and the host have it. The result is
// 1, or a negative number with an error record:
//
// - `No_Grant` (-1): the caller does not act for the principal.
// - `Absent` (-2): no setting has this name.
// - `Too_Long` (-3): the name or the value has more than 32 bytes; the record names the argument.
// - `Bad_Value` (-3): the setting has no such value.
// - `Refused` (-4): the store did not keep the value. The page changed all the same, so the windows show the new
//   value until the next start of the machine.
//
// Example: `settings.set("font", "spleen")`, then `settings.get("font")` gives "spleen".
@(export, link_name = "set")
set :: proc "c" (name: ^string, value: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	name_buffer, value_buffer: [32]u8
	wanted, name_ok := copied(name^, name_buffer[:])
	given, value_ok := copied(value^, value_buffer[:])
	if !name_ok || !value_ok {
		return errors.fail(error, ERROR_VALUE, .Too_Long, .Bytes, name_ok ? 2 : 1, i64(max(len(name^), len(value^))), 32)
	}
	if wanted == settings.TIME_ZONE_NAME {
		zone, zone_ok := settings.zone_parse(given)
		if !zone_ok {
			return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 2)
		}
		current, _ := settings.read(page)
		if !change(current, zone) {
			return errors.fail(error, ERROR_STORE, .Refused, .None, 2)
		}
		return 1
	}
	setting, found := setting_of(wanted)
	if !found {
		return errors.fail(error, ERROR_NAME, .Absent, .None, 1)
	}
	description := &settings.descriptions[setting]
	for value_name, index in description.value_names[:description.value_count] {
		if value_name == given {
			current, _ := settings.read(page)
			changed, changed_ok := with_value(current, setting, index)
			if !changed_ok {
				return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 2)
			}
			if !change(changed, current.zone_offset_minutes) {
				return errors.fail(error, ERROR_STORE, .Refused, .None, 2)
			}
			return 1
		}
	}
	return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 2)
}

// get gives the value of a setting of the system as a text: get("font"), get("subpixel_order"), get("pointer_theme"), get("grid_fit"), get("keyboard_layout"), get("appearance"), get("time_zone").
//
// It reads the settings page, which each process can read too: so it needs no grant, and each caller gets the
// value.
//
// - **name**: the name of a setting, 32 bytes at most.
//
// The result is the length of the value name, and the text holds the value name: "+08:00" for the time zone. A
// text shorter than the value gets its first bytes; the result still counts them all. The result is a negative
// number with an error record when the call fails:
//
// - `Absent` (-2): no setting has this name.
// - `Too_Long` (-3): the name has more than 32 bytes.
@(export, link_name = "get")
get :: proc "c" (name: ^string, result: ^[]u8, error: ^errors.Error_Record) -> i64 {
	name_buffer: [32]u8
	wanted, ok := copied(name^, name_buffer[:])
	if !ok {
		return errors.fail(error, ERROR_VALUE, .Too_Long, .Bytes, 1, i64(len(name^)), len(name_buffer))
	}
	if wanted == settings.TIME_ZONE_NAME {
		zone_buffer: [settings.ZONE_TEXT_SIZE]u8
		current, _ := settings.read(page)
		zone_name := settings.zone_text(zone_buffer[:], current.zone_offset_minutes)
		copy(result^, zone_name)
		return i64(len(zone_name))
	}
	setting, found := setting_of(wanted)
	if !found {
		return errors.fail(error, ERROR_NAME, .Absent, .None, 1)
	}
	// A refused page gives the defaults, which each process draws with.
	current, _ := settings.read(page)
	values := settings.values_of(current)
	// The count of the whole text: a caller with a smaller buffer sees that
	// it does not fit.
	value_name := settings.descriptions[setting].value_names[values[setting]]
	copy(result^, value_name)
	return i64(len(value_name))
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
	buffer: [64]u8
	choice: settings.Choice
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
	switch source {
	case .Nothing_Kept:
		system.log_fact(.Info, Boot_Pass_Nothing_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value})
	case .Read_Refused:
		system.log_fact(.Info, Boot_Pass_Read_Refused{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value})
	case .Kept:
		system.log_fact(.Info, Boot_Pass_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value})
	case .Record_Refused_Defaults_Kept:
		system.log_fact(.Info, Boot_Pass_Record_Refused_Defaults_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value})
	case .Record_Refused_Defaults_Not_Kept:
		system.log_fact(.Info, Boot_Pass_Record_Refused_Defaults_Not_Kept{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value})
	case .No_Store:
		system.log_fact(.Info, Boot_Pass_No_Store{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value})
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

// draw builds the window: a row of buttons for each setting and for the
// time zone, then the text of the system at the text size tokens, then the
// hash of the font of the cells.
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
	// is under the caption of its large number: 7 rows of 32, the settings
	// and the time zone, leave it 168 in the window.
	ROW :: 32
	rows_height := (len(settings.Setting) + 1) * ROW
	content := interface.card(&frame, {8, 8, WIDTH - 16, 40 + rows_height + 32}, "SETTINGS", has_store ? "kept in the store of settings" : "NOT kept: no store", graphics.colors.kernel, interface.text_of(&count))
	for &description, setting in settings.descriptions {
		y := content.y + int(setting) * ROW
		interface.draw_text(frame.table, content.x, y + 4, description.title, graphics.colors.dim)
		for value_name, index in description.value_names[:description.value_count] {
			area := interface.Area{content.x + 144 + index * 104, y, 96, 24}
			builder: interface.Text_Builder
			interface.text_put(&builder, description.name)
			interface.text_put(&builder, value_name)
			element := interface.identity(interface.text_of(&builder))
			in_use := values[setting] == u32(index)
			if interface.button(&frame, area, element, value_name, in_use).activated {
				if changed, changed_ok := with_value(choice, setting, index); changed_ok {
					change(changed, choice.zone_offset_minutes)
				}
			}
			if in_use {
				// The palette sets this setting with the export set, and
				// its entry has the same act name: "settings.set:" and the
				// name of the setting (src/modules/system/console/palette_provider.odin).
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
	interface.draw_text(frame.table, content.x, content.y + rows_height + 8, "the console: settings.set(\"font\", \"spleen\")", graphics.colors.dim)

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
		system.log_fact(.Info, Values_Drawn{font = value_field(choice, .Font), subpixel_order = value_field(choice, .Subpixel_Order), pointer_theme = value_field(choice, .Pointer_Theme), grid_fit = value_field(choice, .Grid_Fit), keyboard_layout = value_field(choice, .Keyboard_Layout), appearance = value_field(choice, .Appearance)})
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
	system.log_fact(.Info, Window_Ready{font = value_field(started, .Font), subpixel_order = value_field(started, .Subpixel_Order), pointer_theme = value_field(started, .Pointer_Theme), grid_fit = value_field(started, .Grid_Fit), keyboard_layout = value_field(started, .Keyboard_Layout), appearance = value_field(started, .Appearance)})
	for {
		wait := system.wait_begin()
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		if interface.window_events(&window_memory.drawing, &window) {
			draw_with_bar(&window)
		}
	}
}
