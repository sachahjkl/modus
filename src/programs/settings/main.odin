// The settings of the system (docs/FONTS.md, "The setting"): the font of
// the system, the order of the color stripes of the screen, the pointer
// theme, the grid fit of the vector font, the layout of the keyboard and
// the appearance of the desktop. The window shows each setting as a row of
// buttons and the text of the system at its three sizes; the exports set()
// and get() make the same changes from the console and from `modustool
// call`.
//
// This program is the one writer of the values of the settings page
// (modus:contract/settings). A change is written first to its private
// store, as one record in one object (one commit), then to the page, with
// the appearance in force that the setting `appearance` gives now
// (src/md/features/appearance.md); the page wakes the compositor, which
// gives the new font, pointer theme and appearance to each window: every
// program draws again, with no code of its own for it. With the setting
// `auto`, the root service changes the appearance in force at 07:00 and at
// 19:00: this program runs only while its window is open.
//
// At boot the root service starts this program for one pass with no window
// (the context value VALUE_BOOT_PASS): it reads the record of its store,
// writes the page, and stops.
//
// **What it is for.** It shows that a choice of the principal is state like
// any other: kept in a private store with no save action, and seen by every
// program at once through one page that each reads and only one writes. No
// program reads a configuration file, and no program needs code to follow a
// change.
//
// **Start**: `start("settings")` in the console, or the bar of the desktop.
// Keys: Tab moves between the buttons, Enter presses one; a click works
// too. From the console, with no window: `connect("settings")`, then
// `settings.set("font", "spleen")`.
//
// **Grants**, as the root service gives them:
//
// - **Settings**: the settings page with the right Write. No other program
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
package settings_program

import "modus:contract/date"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/settings"
import "modus:support/appearance"
import "modus:support/display"
import "modus:support/graphics"
import "modus:support/interface"
import "modus:support/storage"
import "modus:support/system"

WIDTH :: 560
HEIGHT :: 528

// The keys of the window, in its action bar (docs/INTERFACE.md, "4.4 The
// action bar"): the keys of the focus of the interface package.
bar_items := [?]interface.Action_Bar_Item {
	{faces = {"Tab"}, name = "next button", priority = 3},
	{faces = {"Shift", "Tab"}, name = "button before", priority = 2},
	{faces = {"Enter"}, name = "choose the value", priority = 3},
}
bar: interface.Action_Bar_State

page: ^settings.Page
date_page: ^date.Page // The date of the rule of the day of the setting `appearance`, or nil.
service: system.Service
store: storage.Client
has_store: bool

records_now, records_before: [384]interface.Draw_Record
text_now, text_before: [8192]u8
drawing: interface.Window_Drawing
drawn_change: u32 = 1 // The change count of the last frame; odd: none yet.

ERROR_ACTS_FOR_PRINCIPAL :: -1
ERROR_NAME :: -2
ERROR_VALUE :: -3
ERROR_STORE :: -4

// values_text writes the values of a choice: "font vector, subpixel order
// rgb, pointer theme owner, grid fit on".
values_text :: proc "contextless" (writer: ^system.Writer, values: [settings.Setting]u32) -> string {
	for setting in settings.Setting {
		description := settings.descriptions[setting]
		system.write_part(writer, setting == .Font ? "" : ", ")
		system.write_part(writer, description.title)
		system.write_part(writer, " ")
		system.write_part(writer, description.value_names[settings.valid(setting, values[setting])])
	}
	return system.written(writer)
}

// keep writes the record of the values to the private store: one object,
// one commit. It gives false, with a log line, when the store refuses.
keep :: proc "contextless" (values: [settings.Setting]u32) -> bool {
	if !has_store {
		return false
	}
	kept := settings.kept_of(values)
	error: errors.Error_Record
	_, status := storage.write(&store, storage.ROOT, settings.KEPT_OBJECT_NAME, ([^]u8)(&kept)[:size_of(kept)], &error)
	if status != .Ok {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		storage.error_text(&writer, &store, &error)
		system.log_in("programs", .Warning, "settings: the store did not keep the settings: ", system.written(&writer))
		return false
	}
	return true
}

// in_force_now gives the appearance in force of the values at this moment:
// the setting `appearance`, with `auto` by the rule of the day over the
// date page (src/md/features/appearance.md). It writes the sentence of the
// rule in buffer.
in_force_now :: proc "contextless" (values: [settings.Setting]u32, buffer: []u8) -> (settings.Appearance_In_Force, string) {
	setting := settings.Appearance(settings.valid(.Appearance, values[.Appearance]))
	moment := appearance.moment_of(date_page, system.time())
	return appearance.in_force_of(setting, moment), appearance.sentence_write(buffer, setting, moment)
}

// page_write writes the values and their appearance in force on the page in
// one change, and wakes the compositor and the root service. Before the
// write, it writes the sentence of the appearance in force on the log when
// the setting or the appearance changes, or when `always`: the log then
// has it before the line of the compositor that the write causes.
page_write :: proc "contextless" (values: [settings.Setting]u32, always := false) {
	before := settings.read(page)
	sentence_buffer: [192]u8
	in_force, sentence := in_force_now(values, sentence_buffer[:])
	if always || before.values[.Appearance] != values[.Appearance] || before.appearance_in_force != in_force {
		system.log("settings: ", sentence)
	}
	settings.write(page, values, in_force)
	system.word_wake(&page.change_count, 64)
}

// change keeps the values, then writes them on the page and wakes the
// compositor.
change :: proc "contextless" (values: [settings.Setting]u32) -> bool {
	choice := settings.read(page)
	if choice.values == values {
		return true
	}
	kept := keep(values)
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	system.log("settings: ", values_text(&writer, values), kept ? "; kept in the store" : "; NOT kept: the store refused")
	page_write(values)
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

// set changes a setting of the system, and keeps it in the store: set("font", "vector" or "spleen"); set("subpixel_order", "rgb", "bgr" or "none"); set("pointer_theme", "owner" or "system"); set("grid_fit", "on" or "off"); set("keyboard_layout", "us" or "french"); set("appearance", "auto", "dark" or "light").
//
// Every window draws again: the settings page wakes the compositor, which gives the new font, pointer theme and
// appearance to each window. The order is the store first, then the page, so a stop of the machine between the two
// keeps the new value. A value equal to the value of the page changes nothing and returns 1. The setting
// `appearance` `auto` gives the light appearance from 07:00 to 19:00 of the local time and the dark one at night:
// the page holds the appearance in force, which the log says with the time that the rule read.
//
// - **name**: the name of a setting: `font`, `subpixel_order`, `pointer_theme`, `grid_fit`, `keyboard_layout` or
//   `appearance`; 32 bytes at most.
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
	setting, found := setting_of(wanted)
	if !found {
		return errors.fail(error, ERROR_NAME, .Absent, .None, 1)
	}
	description := &settings.descriptions[setting]
	for value_name, index in description.value_names[:description.value_count] {
		if value_name == given {
			values := settings.read(page).values
			values[setting] = u32(index)
			if !change(values) {
				return errors.fail(error, ERROR_STORE, .Refused, .None, 2)
			}
			return 1
		}
	}
	return errors.fail(error, ERROR_VALUE, .Bad_Value, .None, 2)
}

// get gives the value of a setting of the system as a text: get("font"), get("subpixel_order"), get("pointer_theme"), get("grid_fit"), get("keyboard_layout"), get("appearance").
//
// It reads the settings page, which each program can read too: so it needs no grant, and each caller gets the
// value.
//
// - **name**: the name of a setting, 32 bytes at most.
//
// The result is the length of the value name, and the text holds the value name. A text shorter than the value
// gets its first bytes; the result still counts them all. The result is a negative number with an error record
// when the call fails:
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
	setting, found := setting_of(wanted)
	if !found {
		return errors.fail(error, ERROR_NAME, .Absent, .None, 1)
	}
	values := settings.read(page).values
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
	values := settings.read(page).values
	for number in 0 ..< count {
		values[.Font] = u32(number % 2)
		values[.Subpixel_Order] = u32(number % 3)
		if !keep(values) {
			return errors.fail(error, ERROR_STORE, .Refused, .None, 1, number)
		}
	}
	page_write(values)
	system.log("settings: kept ", u64(count), " records, one commit each")
	return count
}

// boot_pass reads the record of the store and writes the page: the pass of
// the boot, with no window.
boot_pass :: proc "contextless" () -> ! {
	start := system.nanoseconds()
	buffer: [64]u8
	values: [settings.Setting]u32
	what := "no settings kept: the defaults"
	if has_store {
		bytes, found, status := storage.read(&store, storage.ROOT, settings.KEPT_OBJECT_NAME, buffer[:])
		switch {
		case status != .Ok:
			what = "the store gives no record (status not Ok): the defaults"
		case !found:
		case:
			read, valid := settings.kept_read(bytes)
			if valid {
				values = read
				what = "the settings kept in the store"
			} else {
				what = "the record of the store is not a record of this version: the defaults"
			}
		}
	} else {
		what = "no private store: the defaults"
	}
	page_write(values, always = true)
	text: [256]u8
	writer := system.Writer{buffer = text[:]}
	system.log("settings: the boot pass: ", what, ": ", values_text(&writer, values), "; in ", (system.nanoseconds() - start) / 1000, " us")
	system.stop(0)
}

// draw builds the window: a row of buttons for each setting, then the text
// of the system at its three sizes, then the facts of the glyph caches.
draw :: proc "contextless" (window: ^display.Window) -> interface.Action_Bar_Result {
	choice := settings.read(page)
	frame := interface.window_frame_begin(&drawing)
	interface.background(&frame, {0, 0, WIDTH, HEIGHT})
	interface.action_bar_input_take(&frame, &bar)
	count: interface.Text_Builder
	interface.text_put(&count, "change ")
	interface.text_put_number(&count, u64(choice.change_count / 2))
	// A row: a button of 24 pixels and a gap of 8. The card of the text
	// under the rows needs 152 pixels of content, so that its line of facts
	// is under its large number: 6 rows of 32 leave it 168 in the window.
	ROW :: 32
	rows_height := len(settings.Setting) * ROW
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
			in_use := choice.values[setting] == u32(index)
			if interface.button(&frame, area, element, value_name, in_use).activated {
				values := choice.values
				values[setting] = u32(index)
				change(values)
			}
			if in_use {
				// The palette sets this setting with the export set, and
				// its entry has the same act name: "settings.set:" and the
				// name of the setting (src/programs/console/palette_provider.odin).
				// The button of the value in use is where go to puts the
				// focus.
				act: interface.Text_Builder
				interface.text_put(&act, "settings.set:")
				interface.text_put(&act, description.name)
				interface.element_act_name(&frame, element, interface.text_of(&act))
			}
		}
	}
	interface.draw_text(frame.table, content.x, content.y + rows_height + 8, "the console: settings.set(\"font\", \"spleen\")", graphics.colors.dim)

	top := 8 + 40 + rows_height + 32 + 8
	vector := settings.font_of(choice) == .Vector && graphics.text_vector_drawn()
	sample := interface.card(&frame, {8, top, WIDTH - 16, HEIGHT - top - 8 - interface.ACTION_BAR_ROW_HEIGHT}, "THE TEXT OF THE SYSTEM", vector ? "the vector font, from the glyph cache" : "Spleen 8x16, the fallback", graphics.colors.machine)
	lines := [?]string {
		"> print(monitor.programs())   31 programs",
		"compositor   12.4 ms   2 418 pages   runs",
		"{fill} [rings] gi Rb 0O 1lI  ok: 0x4F3A",
	}
	for line, index in lines {
		interface.draw_text(frame.table, sample.x, sample.y + index * 16, line, graphics.colors.text)
	}
	interface.draw_text(frame.table, sample.x, sample.y + 56, "EEVDF fair", graphics.colors.program, interface.FONT_MEDIUM)
	after := interface.large_number(&frame, sample.x, sample.y + 88, "12 345", graphics.colors.text)
	interface.draw_text(frame.table, after + 16, sample.y + 112, "wakes in one second", graphics.colors.dim)
	// The sizes of the caches are in their headers; the hash is that of the
	// font file, in the header of the cache that this program validated.
	facts: interface.Text_Builder
	with_grid_fit_size := display.glyph_cache_valid[.On] ? display.glyph_caches[.On].header.file_size : 0
	without_grid_fit_size := display.glyph_cache_valid[.Off] ? display.glyph_caches[.Off].header.file_size : 0
	if with_grid_fit_size == 0 || !graphics.text_state.has_cache {
		interface.text_put(&facts, "no glyph cache: the text is Spleen 8x16")
	} else {
		interface.text_put(&facts, "glyph caches ")
		interface.text_put_number(&facts, with_grid_fit_size)
		interface.text_put(&facts, " and ")
		interface.text_put_number(&facts, without_grid_fit_size)
		interface.text_put(&facts, " bytes, font hash ")
		hex := "0123456789abcdef"
		for byte in graphics.text_state.cache.header.font_hash[:4] {
			interface.text_put(&facts, hex[byte >> 4:][:1])
			interface.text_put(&facts, hex[byte & 15:][:1])
		}
	}
	interface.draw_text(frame.table, sample.x, sample.y + sample.height - 16, interface.text_of(&facts), graphics.colors.dim)
	bar_result := interface.action_bar(&frame, {0, HEIGHT - interface.ACTION_BAR_ROW_HEIGHT, WIDTH, interface.ACTION_BAR_ROW_HEIGHT}, bar_items[:], &bar)
	interface.window_frame_end(&drawing, &frame, window)
	if choice.change_count != drawn_change && drawn_change != 1 {
		buffer: [256]u8
		writer := system.Writer{buffer = buffer[:]}
		system.log("settings: drawn with ", values_text(&writer, choice.values))
	}
	drawn_change = choice.change_count
	return bar_result
}

// draw_with_bar draws a frame and, when a press on an item of the action
// bar ran its key, a second frame that takes the key, as a typed key: the
// focus moves, or the button with the focus is pressed.
draw_with_bar :: proc "contextless" (window: ^display.Window) {
	if result := draw(window); result.ran && interface.input_key_add(&drawing.input, result.run) {
		draw(window)
	}
}

// The entry of settings: the boot pass, or the window and the service.
//
// The entry maps the settings page; with no page it writes "settings: no
// settings page" and stops with the code 1. It opens its private store; a
// program with no store still runs, and says "NOT kept: no store".
//
// - **The boot pass** (the context value `VALUE_BOOT_PASS` is not 0): it
//   reads the record of its store, writes the page, wakes the compositor,
//   writes "settings: the boot pass: ..." with its time, and stops with the
//   code 0. A missing or unreadable record gives the defaults.
// - **Otherwise**: it opens its window (with none, it stops with the code
//   1) and its service, draws, and writes "settings: ok, ...". Then one loop
//   waits on the events of the window and on the service ring, runs the
//   calls, and draws after an event. It never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	page_handle := ctx.handles[settings.GRANT_PAGE]
	address, status := system.memory_map(page_handle)
	if status != .Ok {
		system.log("settings: no settings page: status ", u64(status))
		system.stop(1)
	}
	page = (^settings.Page)(address)
	date_page = date.page_of(ctx)
	store, has_store = storage.open(ctx)
	if ctx.values[settings.VALUE_BOOT_PASS] != 0 {
		boot_pass()
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "settings")
	if !ok {
		system.stop(1)
	}
	service, _ = system.service_open(ctx)
	drawing = interface.window_drawing_of(records_now[:], records_before[:], text_now[:], text_before[:])
	draw_with_bar(&window)
	buffer: [256]u8
	writer := system.Writer{buffer = buffer[:]}
	system.log("settings: ok, ", values_text(&writer, settings.read(page).values))
	for {
		wait := system.wait_begin()
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_end(&wait)
		system.service_run(&service)
		if interface.window_events(&drawing, &window) {
			draw_with_bar(&window)
		}
	}
}
