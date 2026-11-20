package settings_process

import "modus:contract/settings"
import "modus:contract/value_kinds"

// The log facts of settings (src/md/features/log_facts.md, "The
// migration"): each line that has a value, as a record of fields. Each fact
// template is the sentence that the line wrote before it was a fact, so a
// wait of a machine test on that sentence reads it as before.
//
// A line of the values of a choice names each setting by its title, as
// values_text writes it, and holds the name of its value in a Text field of
// its own: a reader filters on one setting, as where(font = "spleen"). The
// templates name the six settings in the order of settings.Setting: a new
// setting fails the assert below until each template names it.

#assert(len(settings.Setting) == 6, "each template of a line of the values names the six settings")

// The bytes of the Text field of the name of a value: the longest name,
// "french" or "system", and a zero byte.
VALUE_NAME_FIELD_BYTES :: 8
// The bytes of the Text field of what the store did with a change: the
// longest words, "NOT kept: the store refused", and a zero byte.
STORE_WORDS_FIELD_BYTES :: 32
// The bytes of the Text field of a time zone: settings.ZONE_TEXT_SIZE and a
// zero byte.
ZONE_FIELD_BYTES :: 8
#assert(ZONE_FIELD_BYTES > settings.ZONE_TEXT_SIZE)

// The words of what the store did with a change.
STORE_KEPT_WORDS :: "kept in the store"
STORE_REFUSED_WORDS :: "NOT kept: the store refused"
#assert(len(STORE_REFUSED_WORDS) < STORE_WORDS_FIELD_BYTES && len(STORE_KEPT_WORDS) < STORE_WORDS_FIELD_BYTES)

// A change of the values of a setting, and what the store did with it.
@(log_fact = "settings: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}; {store}")
Values_Changed :: struct {
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	store:           [32]u8,
}

// A change of the time zone, and what the store did with it.
@(log_fact = "settings: time zone {zone}; {store}")
Zone_Changed :: struct {
	zone:  [8]u8,
	store: [32]u8,
}

// The test export repeat kept its records, one commit each.
@(log_fact = "settings: kept {records} records, one commit each")
Records_Repeated :: struct {
	records: u64,
}

// The window drew a new choice: its values.
@(log_fact = "settings: drawn with font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}")
Values_Drawn :: struct {
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
}

// The context names no settings page that this process can map: the
// status of the map, written as its number, as the line wrote it.
@(log_fact = "settings: no settings page: status {status_word}")
No_Settings_Page :: struct {
	status_word: u64,
}

// The window is open: the values of the page.
@(log_fact = "settings: ok, font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}")
Window_Ready :: struct {
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
}

// value_field gives the Text field of the name of the value of one setting
// of a choice.
value_field :: proc "contextless" (choice: settings.Choice, setting: settings.Setting) -> [VALUE_NAME_FIELD_BYTES]u8 {
	values := settings.values_of(choice)
	return value_kinds.text_field(settings.descriptions[setting].value_names[values[setting]], VALUE_NAME_FIELD_BYTES)
}

// store_field gives the Text field of what the store did with a change.
store_field :: proc "contextless" (kept: bool) -> [STORE_WORDS_FIELD_BYTES]u8 {
	return value_kinds.text_field(kept ? STORE_KEPT_WORDS : STORE_REFUSED_WORDS, STORE_WORDS_FIELD_BYTES)
}
