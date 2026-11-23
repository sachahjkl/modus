package settings_process

import "modus:contract/errors"
import op "modus:contract/operation"
import "modus:contract/settings"
import "modus:contract/value_kinds"
import "internal:settings/appearance"
import "modus:system"

// The log facts of settings (src/md/features/log_facts.md, "The
// migration"): each line, as a record of fields. Each fact template is the
// sentence that the line wrote before it was a fact, so a wait of a machine
// test on that sentence reads it as before; a status and an error record
// are written by the names of their members.

// The store refused the record of the settings: its error record.
@(log_fact = "settings: the store did not keep the settings: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Store_Refused :: distinct errors.Error_Record_Fact_Fields

// The page of the settings holds a value that its setting does not have,
// or a change count that never stayed even: the defaults take its place.
@(log_fact = "settings: the settings page holds a value that its setting does not have, or was never stable: the defaults")
Page_Refused :: struct {}

// The sentence of the appearance in force, by its three cases: the setting
// dark or light; the setting auto with no date; the setting auto by the
// rule of the day, with the local time that the rule read. The hours of
// the rule are in the template: the assert below fails the build when they
// change.
#assert(appearance.LIGHT_FROM_SECOND == 7 * 3_600 && appearance.DARK_FROM_SECOND == 19 * 3_600, "the template of Appearance_By_Rule names 07:00 and 19:00")

// The appearance in force is the value of the setting.
@(log_fact = "settings: the appearance in force is {in_force}: the setting {setting_value}")
Appearance_By_Setting :: struct {
	in_force:      [8]u8,
	setting_value: [8]u8,
}

// The setting is auto, and the system has no date: the appearance in force
// is the dark one.
@(log_fact = "settings: the appearance in force is {in_force}: auto, and the system has no date")
Appearance_Without_Date :: struct {
	in_force: [8]u8,
}

// The setting is auto: the rule of the day, at the local time that it read.
@(log_fact = "settings: the appearance in force is {in_force}: auto, light from 07:00 to 19:00 of the local time; the local time is {local_time} with a zone of {zone_offset}, at {date} since 1970")
Appearance_By_Rule :: struct {
	zone_offset: value_kinds.Time_In_Seconds,
	date:        value_kinds.Time_In_Seconds,
	in_force:    [8]u8,
	local_time:  [8]u8,
}

// The bytes of the Text field of an appearance in force, "dark" or
// "light", and of the local time "HH:MM", with a zero byte.
IN_FORCE_FIELD_BYTES :: 8
LOCAL_TIME_FIELD_BYTES :: 8

// appearance_log writes the fact of the appearance in force of a setting
// at a moment, in the case that the moment gives.
appearance_log :: proc "contextless" (setting: settings.Appearance, in_force_value: settings.Appearance_In_Force, moment: appearance.Moment) {
	in_force := value_kinds.text_field(settings.appearance_in_force_names[in_force_value], IN_FORCE_FIELD_BYTES)
	if setting != .Auto {
		system.log_fact(.Info, Appearance_By_Setting{in_force = in_force, setting_value = value_kinds.text_field(settings.descriptions[.Appearance].value_names[u32(setting)], VALUE_NAME_FIELD_BYTES)})
		return
	}
	if !moment.known {
		system.log_fact(.Info, Appearance_Without_Date{in_force = in_force})
		return
	}
	// The local time in two digits for the hour and two for the minute,
	// as the bar draws it.
	second := appearance.local_second_of_day(moment)
	local_time: [LOCAL_TIME_FIELD_BYTES]u8
	digits := [4]i64{second / 3_600 / 10, second / 3_600 % 10, second / 60 % 60 / 10, second / 60 % 10}
	local_time[0], local_time[1], local_time[2], local_time[3], local_time[4] = u8('0' + digits[0]), u8('0' + digits[1]), ':', u8('0' + digits[2]), u8('0' + digits[3])
	system.log_fact(.Info, Appearance_By_Rule{zone_offset = value_kinds.Time_In_Seconds(moment.zone_offset_seconds), date = value_kinds.Time_In_Seconds((moment.milliseconds - moment.milliseconds %% 1000) / 1000), in_force = in_force, local_time = local_time})
}

// What the boot pass read: each case is a fact type of its own, because
// its words pass the values of one record with the values of the choice.
Boot_Pass_Source :: enum {
	Nothing_Kept,
	Read_Refused,
	Kept,
	Record_Unreadable,
	No_Store,
}

// The boot pass found no record in the store: the defaults.
@(log_fact = "settings: the boot pass: no settings kept: the defaults: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; in {elapsed}")
Boot_Pass_Nothing_Kept :: struct {
	elapsed:         value_kinds.Time_In_Microseconds,
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// The store gave no record: the defaults, and the pass fails.
@(log_fact = "settings: the boot pass: the store gives no record (status not Ok): the defaults: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; in {elapsed}")
Boot_Pass_Read_Refused :: struct {
	elapsed:         value_kinds.Time_In_Microseconds,
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// The boot pass read the settings that the store kept.
@(log_fact = "settings: the boot pass: the settings kept in the store: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; in {elapsed}")
Boot_Pass_Kept :: struct {
	elapsed:         value_kinds.Time_In_Microseconds,
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// The record of the store is one that this release cannot read: the
// defaults hold, and the record stays as it is until the principal changes
// a setting.
@(log_fact = "settings: the boot pass: the record of the store is one that this release cannot read: the defaults, and the record stays: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; in {elapsed}")
Boot_Pass_Record_Unreadable :: struct {
	elapsed:         value_kinds.Time_In_Microseconds,
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// A change does not fit the kept record, or names a setting that is not
// valid: nothing changed.
@(log_fact = "settings: the kept record refused a change ({problem}): nothing changed")
Kept_Record_Refused :: struct {
	problem: [24]u8, // N written out: the tool reads the size of a Text field from the source.
}

PROBLEM_FIELD_BYTES :: size_of(Kept_Record_Refused{}.problem)

// The process has no private store: the defaults.
@(log_fact = "settings: the boot pass: no private store: the defaults: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; in {elapsed}")
Boot_Pass_No_Store :: struct {
	elapsed:         value_kinds.Time_In_Microseconds,
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// The lines of the values of the settings. A line of the values of a choice names each setting by its title, as
// the window shows it, and holds the name of its value in a Text field of
// its own: a reader filters on one setting, as where(font = "spleen"). The
// templates name the seven settings in the order of settings.Setting: a new
// setting fails the assert below until each template names it.

#assert(len(settings.Setting) == 7, "each template of a line of the values names the seven settings")

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
@(log_fact = "settings: font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}; {store}")
Values_Changed :: struct {
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
	store:           [32]u8,
}

// A change of the time zone, and what the store did with it.
@(log_fact = "settings: time zone {zone}; {store}")
Zone_Changed :: struct {
	zone:  [8]u8,
	store: [32]u8,
}

// The bytes of the Text field of a language list: the canonical tags in
// their order, joined by ", ", and a zero byte. A fact holds at most
// op.LOG_FACT_VALUE_CAPACITY bytes, so a longer list gives the tags that
// fit whole.
LANGUAGES_FIELD_BYTES :: 112

// A change of the language list, and what the store did with it.
@(log_fact = "settings: languages {languages}; {store}")
Languages_Changed :: struct {
	languages: [112]u8,
	store:     [32]u8,
}
#assert(size_of(Languages_Changed{}.languages) == LANGUAGES_FIELD_BYTES)

// The test export repeat kept its records, one commit each.
@(log_fact = "settings: kept {records} records, one commit each")
Records_Repeated :: struct {
	records: u64,
}

// The element with the focus was past an edge of the view: the view moves
// to show it, so Tab reaches each control of a window that does not fit
// the work area (src/md/features/window_scroll.md).
@(log_fact = "settings: the focus moves the view to the line {first}")
View_Follows_Focus :: struct {
	first: u64,
}

// The window drew a new choice: its values.
@(log_fact = "settings: drawn with font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}")
Values_Drawn :: struct {
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// The context names no private store that this process can open: the
// root service gave none, or the storage service is not a valid module.
// Each change is then refused: a change is kept in the store first.
@(log_fact = "settings: no private store: each change is refused")
No_Store :: struct {}

// A change that the private store did not keep: the page keeps the values
// before, and the call fails (change_decision). Store_Refused or No_Store
// says why.
@(log_fact = "settings: a change that the store did not keep: the page keeps the values before")
Change_Not_Kept :: struct {}

// The store did not give the kept record at the last read: a change is not
// written over choices that this process does not know, until a read gives
// the record.
@(log_fact = "settings: the store did not give the kept record: no change is written over it until the next read gives it")
Kept_Record_Unread :: struct {}

// The context names no settings page that this process can map: the
// status of the map, which a reader writes by the name of its member.
@(log_fact = "settings: no settings page: status {status}")
No_Settings_Page :: struct {
	status: op.Status_Word,
}

// The window is open: the values of the page.
@(log_fact = "settings: ok, font {font}, subpixel order {subpixel_order}, pointer theme {pointer_theme}, grid fit {grid_fit}, keyboard layout {keyboard_layout}, appearance {appearance}, scale {scale}")
Window_Ready :: struct {
	font:            [8]u8,
	subpixel_order:  [8]u8,
	pointer_theme:   [8]u8,
	grid_fit:        [8]u8,
	keyboard_layout: [8]u8,
	appearance:      [8]u8,
	scale:           [8]u8,
}

// The context names a pass that is no member of settings.Pass: the process
// writes nothing and stops.
@(log_fact = "settings: the context names the pass {word}, which is no pass: nothing is written")
Pass_Refused :: struct {
	word: u64,
}

// The tile of the Control Center: the appearance after the one of the page.
@(log_fact = "settings: the next appearance of the Control Center: {before} to {after}; {store}")
Appearance_Next_Kept :: struct {
	before: [8]u8,
	after:  [8]u8,
	store:  [32]u8,
}
#assert(size_of(Appearance_Next_Kept{}.before) == VALUE_NAME_FIELD_BYTES && size_of(Appearance_Next_Kept{}.store) == STORE_WORDS_FIELD_BYTES)

// The tile of the Control Center, with a page that the reader refused: the
// pass keeps nothing, since the defaults would take the place of the kept
// record of each other setting.
@(log_fact = "settings: the next appearance of the Control Center keeps nothing: the settings page holds a value that its setting does not have, or was never stable")
Appearance_Next_Page_Refused :: struct {}

// The window cannot be resized: the limits that this process gave were
// refused, or the command ring of the window was full.
@(log_fact = "settings: the window stays fixed: {cause}")
Window_Stays_Fixed :: struct {
	cause: [64]u8,
}
STAYS_FIXED_CAUSE_FIELD_BYTES :: 64
#assert(size_of(Window_Stays_Fixed{}.cause) == STAYS_FIXED_CAUSE_FIELD_BYTES)

// A frame of the window held more records or more text than its draw
// table: the records past it are not drawn. A window writes it one time.
@(log_fact = "settings: a frame is past its draw table of {records} records and {text_bytes} bytes of text; its last records are not drawn")
Frame_Table_Full :: struct {
	records:    u64,
	text_bytes: u64,
}

// value_field gives the Text field of the name of the value of one setting
// of a choice.
value_field :: proc "contextless" (choice: settings.Choice, setting: settings.Setting) -> [VALUE_NAME_FIELD_BYTES]u8 {
	values := settings.values_of(choice)
	return value_kinds.text_field(settings.value_name_of(setting, values[setting]), VALUE_NAME_FIELD_BYTES)
}

// store_field gives the Text field of what the store did with a change.
store_field :: proc "contextless" (kept: bool) -> [STORE_WORDS_FIELD_BYTES]u8 {
	return value_kinds.text_field(kept ? STORE_KEPT_WORDS : STORE_REFUSED_WORDS, STORE_WORDS_FIELD_BYTES)
}
