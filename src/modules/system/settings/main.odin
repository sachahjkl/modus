// The settings of the system (docs/FONTS.md, "The setting"): the font of
// the system, the order of the color stripes of the screen, the pointer
// theme, the grid fit of the vector font, the layout of the keyboard, the
// appearance of the desktop, the time zone and the languages that the
// principal reads. The window shows the settings in four sections, each
// setting with a line that says what it does and its values as buttons
// (src/md/features/settings_window.md); the export set() and a getter
// for each setting make the same changes and give the same values from the
// console and from `modustool call`.
//
// The language list (src/md/features/interface_language.md, "1. The
// identity of a language") is the languages that the principal reads, the first first, as
// records of language_tag.Locale: set_languages() takes a table of them,
// and the list of the languages of the window adds a common language,
// moves a language up, or removes it. An empty list is English.
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
// (the context value VALUE_PASS, the pass Boot): it reads the record of its
// store, writes the page, and stops. The tile Appearance of the Control
// Center starts it for the pass Appearance_Next.
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
// **What a reader sees**: the cards Display, Pointer, Keyboard, and Region
// and language, in one column or two by the width of the window, which the
// principal resizes; a scroll bar when they do not fit. The log has
// "settings: the boot pass: ..." at boot, "settings: ok, font vector, ..."
// when the window opens, and one line for each change, with "kept in the
// store" or "NOT kept: the store refused". At the boot pass and at each
// change of the appearance it writes why the appearance in force is what it
// is: "settings: the appearance in force is dark: auto, light from 07:00 to
// 19:00 of the local time; the local time is 01:04 with a zone of 0 s, at
// 1794791040 s since 1970".
package settings_process

import "base:intrinsics"
import "modus:contract/accessibility"
import "modus:contract/chosen_values"
import "modus:contract/date"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/language_tag"
import "modus:contract/module"
import "modus:contract/plan_values"
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

// The size of the window at its start, its least size and its largest
// size, in logical pixels (src/md/features/settings_window.md). Each place
// in it comes from its layout tree (settings_layout), from the size that
// the window has now. Literals, so that the tool reads the window of the
// Opens at 784x624 (multiples of 8 for exact pixel scaling at every eighth) so
// the sidebar + content split shows at once.
WIDTH :: 784
HEIGHT :: 624
LEAST_WIDTH :: 400
LEAST_HEIGHT :: 320
LARGEST_WIDTH :: 1024
LARGEST_HEIGHT :: 800
// The tool counts the module, the thread stacks and the window at its
// largest size and largest scale; working_pages covers the transient peak
// (measured 7515 pages) when opening at 784x624 at scale 2 and clamping to
// 784x482 before Window_Ready releases the initial surface.
MODULE_BUDGET :: system.Stated_Budget{threads = 2, window_width = LARGEST_WIDTH, window_height = LARGEST_HEIGHT, working_memory_pages = 1024}
// The window that sets the scale back fits the least work area that each
// holder of the display leaves at each scale, with its title.
#assert(LEAST_HEIGHT + 40 <= scale_factor.WORK_AREA_LEAST_HEIGHT)

// Plan value: layout metrics for the settings sidebar, narrow tab bar,
// segmented controls, and slim bottom status footer.
SIDEBAR_MIN_WIDTH :: 580 // Below this width, navigation collapses to a compact top tab bar.
SIDEBAR_WIDTH :: 176
SIDEBAR_SEARCH_HEIGHT :: 26
SIDEBAR_ROW_HEIGHT :: 28
COMPACT_NAV_HEIGHT :: 30
STATUS_FOOTER_HEIGHT :: 24
STATUS_RIGHT_CLEARANCE :: 22 // 11 px resize grip + 2 px border + 9 px margin.
SEGMENTED_HEIGHT :: 28

// Closed set of navigation categories in the settings sidebar / compact tab bar.
Nav_Category :: enum u8 {
	All,
	Display,
	Pointer,
	Keyboard,
	Region_And_Language,
	Modules,
}

@(rodata)
nav_categories := [len(Nav_Category)]Nav_Category{.All, .Display, .Pointer, .Keyboard, .Region_And_Language, .Modules}

@(rodata)
nav_category_labels := [Nav_Category]string {
	.All                 = "All",
	.Display             = "Display",
	.Pointer             = "Pointer",
	.Keyboard            = "Keyboard",
	.Region_And_Language = "Region",
	.Modules             = "Modules",
}

@(rodata)
nav_sidebar_labels := [Nav_Category]string {
	.All                 = "All settings",
	.Display             = "Display",
	.Pointer             = "Pointer",
	.Keyboard            = "Keyboard",
	.Region_And_Language = "Region & language",
	.Modules             = "Modules",
}

// Closed set of actions in the settings right-click menu and Ctrl+K palette.
Settings_Menu_Action :: enum u32 {
	None             = 0,
	Cat_All          = 1,
	Cat_Display      = 2,
	Cat_Pointer      = 3,
	Cat_Keyboard     = 4,
	Cat_Region       = 5,
	Cat_Modules      = 6,
	Clear_Search     = 7,
	Appearance_Auto  = 8,
	Appearance_Dark  = 9,
	Appearance_Light = 10,
	Font_Vector      = 11,
	Font_Spleen      = 12,
	Scale_100        = 13,
	Scale_125        = 14,
	Scale_150        = 15,
	Scale_200        = 16,
	Open_Palette     = 17,
}

nav_category: Nav_Category = .All
search_buf: [32]u8 // Plan value: covers multi-word setting filter queries.
search_len: int
settings_ctx_menu: interface.Context_Menu_State
settings_palette: interface.Command_Palette_State
palette_pill_area: interface.Area

// The display texts of the members whose name is not the word that a
// principal reads (src/md/features/enum_parameters.md, "The display text of
// a member"). The palette shows them on the buttons of the rows of `set`,
// and the completion beside each name; a line still types the name. No code
// reads these tables: the build writes them into the module file.
@(rodata, member_texts = "en")
scale_texts := [scale_factor.Scale]string {
	.Eight_Eighths    = "1",
	.Nine_Eighths     = "1.125",
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
	.Of_The_Owner  = "Owner",
	.Of_The_System = "System",
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

// The draw tables of the window: the four sections, the scroll bar and the
// action bar take about 400 records at the largest size. A full table
// drops the records past it, and the window writes one line.
window_memory: interface.Window_Memory(2048, 32768)
table_full_logged: bool
drawn_change: u32 = 1 // The change count of the last frame; odd: none yet.

// with_value gives a choice with one setting at the value of a button or of
// a name: its place in the names of the values of the setting, whose word
// the description gives. ok false: the border refuses that word, and
// scale_problem says why for the scale (a count that names no member).
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

// The kept record of this run (src/md/features/module_settings.md, "The
// precedence"): the record of chosen values as the store holds it, the
// language list when the principal chose one, and the settings that they
// give with the defaults. A record that this release cannot read is never
// written over, but by a change of the principal, which starts a new one.
// A record that the store did not give (a refused read) is another case:
// its choices are not known, so no change is written over it until a read
// gives it (kept_record_unread), as modus:kept_choices does.
kept_record_bytes: [system.PAGE_SIZE]u8
kept_record_length: int
kept_record_readable: bool = true
kept_record_unread: bool
kept_languages_bytes: [size_of(settings.Language_List)]u8
kept_languages_found: bool
kept_choice: settings.Choice
kept_zone_offset_minutes: i32
kept_layers: settings.Kept_Layers

// The plan values of this owner: its defaults and its locks, from the page
// of its start (src/md/features/module_settings.md, "Plan records").
kept_plan: plan_values.Owner_Values
// The copy of the plan values page that kept_plan points into.
kept_plan_copy: system.Plan_Values_Copy

// What a keep attempt did with a change.
Keep_Result :: enum u8 {
	Kept_In_Store,   // Written to the private store and updated in memory.
	Kept_In_Session, // No private store: updated in memory for the running session only.
	Refused,         // The private store refused the read or write.
}

// What the read of the kept record found.
Kept_Load :: enum u8 {
	Nothing_Kept, // No record: the principal chose nothing.
	Kept, // A record of chosen values.
	Unreadable, // A record that this release cannot read: the defaults hold, and the record stays.
	Read_Refused, // The store gave no record.
	No_Store, // The process has no private store.
}

// kept_load reads the kept record and the language list once, at the start
// of each pass: a change goes on the record that the store holds, so it
// never loses a choice that this process does not know.
kept_load :: proc "contextless" () -> Kept_Load {
	// With no store the defaults of the plan hold, overlaid with any
	// session choices already written to the live settings page.
	kept_choice, kept_zone_offset_minutes, kept_layers = settings.choice_of_kept({}, nil, false, kept_plan)
	if !has_store {
		kept_record_readable = true
		if page != nil && intrinsics.atomic_load_explicit(&page.change_count, .Acquire) > 0 {
			if current, ok := settings.read(page); ok {
				changes := settings.kept_changes_of(kept_choice, kept_zone_offset_minutes, current, current.zone_offset_minutes, {})
				_ = kept_write(changes.changes[:changes.count], changes.languages_changed, current.languages)
			}
		}
		return .No_Store
	}
	error: errors.Error_Record
	bytes, found, status := storage.read(&store, storage.ROOT, settings.KEPT_OBJECT_NAME, kept_record_bytes[:], &error)
	if status != .Ok {
		kept_record_unread = true
		return .Read_Refused
	}
	kept_record_unread = false
	kept_record_readable = true
	load := Kept_Load.Nothing_Kept
	record: chosen_values.Record
	if found {
		problem: chosen_values.Record_Problem
		if record, problem = chosen_values.read_record(bytes); problem != .None {
			kept_record_readable = false
			record = {}
			load = .Unreadable
		} else {
			kept_record_length = len(bytes)
			load = .Kept
		}
	}
	languages, languages_found, languages_status := storage.read(&store, storage.ROOT, settings.KEPT_LANGUAGES_OBJECT_NAME, kept_languages_bytes[:], &error)
	kept_languages_found = languages_status == .Ok && languages_found && len(languages) == len(kept_languages_bytes)
	if kept_languages_found && load == .Nothing_Kept {
		load = .Kept
	}
	kept_choice, kept_zone_offset_minutes, kept_layers = settings.choice_of_kept(record, kept_languages_bytes[:], kept_languages_found, kept_plan)
	return load
}

// keep writes what changed from the kept settings to the private store when
// present, or updates the in-memory session record when the machine has no
// data disk. A value that changed, or that the act names, becomes a choice.
// When an open store refuses, it gives .Refused with a log line and the kept
// settings stay as they were.
keep :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32, given: settings.Given) -> Keep_Result {
	if !has_store {
		changes := settings.kept_changes_of(kept_choice, kept_zone_offset_minutes, choice, zone_offset_minutes, given)
		if !kept_write(changes.changes[:changes.count], changes.languages_changed, choice.languages) {
			return .Refused
		}
		return .Kept_In_Session
	}
	// The store did not give the record at the last read: it is read again,
	// and while the store does not give it, a write would replace choices
	// that this process does not know.
	if kept_record_unread && kept_load() == .Read_Refused {
		system.log_fact(.Warning, Kept_Record_Unread{})
		return .Refused
	}
	changes := settings.kept_changes_of(kept_choice, kept_zone_offset_minutes, choice, zone_offset_minutes, given)
	return kept_write(changes.changes[:changes.count], changes.languages_changed, choice.languages) ? .Kept_In_Store : .Refused
}

// kept_write writes changes of the record of chosen values, and the
// language list when write_languages. When has_store is false, it updates the
// in-memory record without calling storage. A record that this release cannot
// read gives way to a new one: the principal acted.
kept_write :: proc "contextless" (changes: []chosen_values.Change, write_languages: bool, languages: settings.Language_List) -> bool {
	error: errors.Error_Record
	if len(changes) > 0 {
		record: chosen_values.Record
		if kept_record_readable {
			record, _ = chosen_values.read_record(kept_record_bytes[:kept_record_length])
		}
		written_bytes: [system.PAGE_SIZE]u8
		written, problem := chosen_values.write_record(record, changes, written_bytes[:])
		if problem != .None {
			system.log_fact(.Warning, Kept_Record_Refused{problem = value_kinds.text_field(chosen_values.RECORD_PROBLEM_NAMES[problem], PROBLEM_FIELD_BYTES)})
			return false
		}
		if has_store {
			if _, status := storage.write(&store, storage.ROOT, settings.KEPT_OBJECT_NAME, written_bytes[:written], &error); status != .Ok {
				system.log_fact(.Warning, Store_Refused(errors.error_record_fact_fields(error)))
				return false
			}
		}
		copy(kept_record_bytes[:], written_bytes[:written])
		kept_record_length = written
		kept_record_readable = true
	}
	if write_languages {
		list := languages
		list_bytes := transmute([size_of(settings.Language_List)]u8)list
		if has_store {
			if _, status := storage.write(&store, storage.ROOT, settings.KEPT_LANGUAGES_OBJECT_NAME, list_bytes[:], &error); status != .Ok {
				system.log_fact(.Warning, Store_Refused(errors.error_record_fact_fields(error)))
				return false
			}
		}
		kept_languages_bytes = list_bytes
		kept_languages_found = true
	}
	record, _ := chosen_values.read_record(kept_record_bytes[:kept_record_length])
	kept_choice, kept_zone_offset_minutes, kept_layers = settings.choice_of_kept(record, kept_languages_bytes[:], kept_languages_found, kept_plan)
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
	return appearance.in_force_of(choice.appearance, moment), moment
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
	if choice.appearance != .Auto || !moment.known {
		return system.WAIT_FOREVER
	}
	wait_milliseconds := u64(appearance.next_edge(moment) - moment.milliseconds)
	if wait_milliseconds > system.WAIT_FOREVER - now {
		return system.WAIT_FOREVER
	}
	return now + wait_milliseconds
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

// The step of a change after the keep (change_decision): the page takes a
// change only when the private store kept it.
Change_Decision :: struct {
	write_page: bool, // The page takes the change, and the compositor and `date` wake.
	kept:       bool, // The change holds: the caller reports success.
}

// change_decision decides a change from what it changes and from the keep
// result: a change that changes nothing writes nothing and holds; a change
// kept in the store or in the running session goes to the page; a change that
// an open store refused leaves the page as it was and fails
// (src/md/features/settings_window.md, "One writer, the store first when present").
change_decision :: proc "contextless" (changes_nothing: bool, result: Keep_Result) -> Change_Decision {
	if changes_nothing {
		return {write_page = false, kept = true}
	}
	switch result {
	case .Kept_In_Store, .Kept_In_Session:
		return {write_page = true, kept = true}
	case .Refused:
		return {write_page = false, kept = false}
	}
	return {write_page = false, kept = false}
}

// change keeps the values, the zone and the language list in the private
// store when present (or in memory for the running session without a store),
// then writes them on the page and wakes the compositor and the process
// `date`. A change that an open store refuses changes nothing on the page: it
// writes its fact, and gives false (change_decision). A change that a lock of
// the plan holds changes nothing, and gives false too.
change :: proc "contextless" (choice: settings.Choice, zone_offset_minutes: i32, given: settings.Given = {}) -> bool {
	current, current_ok := page_choice()
	zone := settings.zone_offset_minutes_valid(zone_offset_minutes)
	values_same := current_ok && settings.values_of(current) == settings.values_of(choice)
	languages_same := current_ok && current.languages == choice.languages
	// An act that names a default keeps a choice, with no change of a value.
	changes_nothing := values_same && languages_same && current.zone_offset_minutes == zone && !settings.given_not_chosen(given, kept_layers)
	if changes_nothing {
		return change_decision(true, .Kept_In_Store).kept
	}
	// A lock of the plan holds over every door: a call, a press in the
	// window, the next appearance. A change that meets one changes nothing.
	if locked_setting, zone_locked, locked := settings.change_locked(kept_plan, current, current.zone_offset_minutes, choice, zone, given); locked {
		name := zone_locked ? settings.TIME_ZONE_NAME : settings.descriptions[locked_setting].name
		system.log_fact(.Warning, Change_Locked{setting = value_kinds.text_field(name, LOCKED_NAME_FIELD_BYTES)})
		return false
	}
	keep_result := keep(choice, zone, given)
	decision := change_decision(false, keep_result)
	if !decision.write_page {
		system.log_fact(.Warning, Change_Not_Kept{})
		return decision.kept
	}
	if !values_same {
		system.log_fact(.Info, Values_Changed{font = value_field(choice, .Font), subpixel_order = value_field(choice, .Subpixel_Order), pointer_theme = value_field(choice, .Pointer_Theme), grid_fit = value_field(choice, .Grid_Fit), keyboard_layout = value_field(choice, .Keyboard_Layout), appearance = value_field(choice, .Appearance), scale = value_field(choice, .Scale), store = store_field(keep_result)})
	}
	if current.zone_offset_minutes != zone {
		zone_buffer: [settings.ZONE_TEXT_SIZE]u8
		system.log_fact(.Info, Zone_Changed{zone = value_kinds.text_field(settings.zone_text(zone_buffer[:], zone), ZONE_FIELD_BYTES), store = store_field(keep_result)})
	}
	if !languages_same {
		languages_buffer: [LANGUAGES_FIELD_BYTES]u8
		system.log_fact(.Info, Languages_Changed{languages = value_kinds.text_field(languages_text(choice.languages, languages_buffer[:LANGUAGES_FIELD_BYTES - 1]), LANGUAGES_FIELD_BYTES), store = store_field(keep_result)})
	}
	page_write(choice, zone)
	return decision.kept
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
// The scale factor of the desktop is a count of eighths, from `.eight_eighths`, 1, to `.sixteen_eighths`, 2;
// `.ten_eighths`, 1.25, is the default. Each window lets its surface go, makes a surface of its size at the scale
// that the compositor names from its own budget, and draws again. A window whose budget does not pay that surface
// declines the scale and shows its frame only, until another scale; the window of settings says how many did.
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
// - **scale**: a count of eighths, `.eight_eighths` to `.sixteen_eighths`.
//
// The caller must act for the principal (**Acts_For_Principal**): the console and the host have it. The result is
// 1, or a failure with its call outcome and an error record:
//
// - `No_Grant`: the caller does not act for the principal.
// - `Absent`: the call gives no setting.
// - `Bad_Value`: a value that names no member of the enum of its setting; the record names the argument and
//   holds the value. No setting changes.
// - `No_Grant`, unit `Plan_Lock`: a lock of the plan of principal 0 holds a setting that the call gives; the
//   record names its argument. No setting changes, and the choice before stays kept.
// - `Refused`: the store did not keep the values. The page keeps the values before: a change is kept in the
//   store first, so no window shows a value that the next start of the machine loses.
//
// Example: `settings.set(font = .spleen)`, then `settings.font()` gives `.spleen`.
@(export, link_name = "set", enum_getters = "font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance, scale = scale")
set :: proc "c" (
	font_presence: module.Presence,
	font: settings.Font,
	subpixel_order_presence: module.Presence,
	subpixel_order: settings.Subpixel_Order,
	pointer_theme_presence: module.Presence,
	pointer_theme: settings.Pointer_Theme,
	grid_fit_presence: module.Presence,
	grid_fit: settings.Grid_Fit,
	keyboard_layout_presence: module.Presence,
	keyboard_layout: settings.Keyboard_Layout,
	appearance_presence: module.Presence,
	appearance: settings.Appearance,
	scale_presence: module.Presence,
	scale: scale_factor.Scale,
	error: ^errors.Error_Record,
) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	current, _ := settings.read(page)
	arguments := settings.Set_Arguments{font_presence, font, subpixel_order_presence, subpixel_order, pointer_theme_presence, pointer_theme, grid_fit_presence, grid_fit, keyboard_layout_presence, keyboard_layout, appearance_presence, appearance, scale_presence, scale}
	changed, refused, problem := settings.choice_of_arguments(current, arguments)
	// The argument of a setting is its place in the parameters, from 1: the
	// parameters are in the order of the settings.
	argument := i64(refused) + 1
	words := settings.values_of({font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance, scale = scale})
	presences := [settings.Setting]module.Presence{.Font = font_presence, .Subpixel_Order = subpixel_order_presence, .Pointer_Theme = pointer_theme_presence, .Grid_Fit = grid_fit_presence, .Keyboard_Layout = keyboard_layout_presence, .Appearance = appearance_presence, .Scale = scale_presence}
	switch problem {
	case .None:
	case .Nothing_Given:
		return call_outcome.fail(error, .Argument_Refused, .Absent, .None, 0)
	case .Bad_Value:
		// A Presence word past Given is the value that the record holds;
		// otherwise the word that names no member.
		if _, presence_ok := module.presence_of_word(u64(presences[refused])); !presence_ok {
			return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, i64(presences[refused]))
		}
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, i64(words[refused]))
	}
	// A lock of the plan holds over the choice: a call that names a locked
	// setting changes none (src/md/features/module_settings.md, "The lock").
	if locked, found := settings.first_locked(kept_plan, presences); found {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, i64(locked) + 1)
	}
	given: settings.Given
	for setting in settings.Setting {
		given.values[setting] = presences[setting] == .Given
	}
	if !change(changed, current.zone_offset_minutes, given) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0)
	}
	return .Succeeded, 1
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

// plan_only describes the value of the plan that the time zone takes: a number of minutes from UTC, which the plan of principal 0 gives as a default or a lock (src/md/features/module_settings.md, "Plan records"). The console and the plans service type a plan by this description. Each call is refused.
//
// - **time_zone**: the offset in minutes, -720 to 840; the zone takes a whole quarter of an hour, and the border of the zone refuses another number at the start of this service.
//
// Each call fails with the outcome Grant_Or_Right_Missing and the error record No_Grant, unit Plan_Lock: a principal changes the zone with set_time_zone.
//
// ```
// plans.apply("zone", plan { values = { settings = { time_zone = 480 } } }, {})
// ```
@(export, link_name = "plan_only", parameter_ranges = "time_zone = -720..840")
plan_only_export :: proc "c" (time_zone_presence: module.Presence, time_zone: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 0)
}

// The range of the description is the range of the border of the zone.
#assert(settings.ZONE_OFFSET_MINUTES_LEAST == -720 && settings.ZONE_OFFSET_MINUTES_MOST == 840)

// set_time_zone changes the time zone of the system, and keeps it in the store: set_time_zone("+08:00").
//
// The time zone is a fixed offset from UTC, with no summer time: a sign, the hours and the minutes, from "-12:00"
// to "+14:00", by quarters of an hour; "+00:00", UTC, is the default. The bar then shows the local time, and the
// rule of the appearance `.auto` counts its hours in it. A zone is a number of minutes, not a member of a closed
// set: so it is a Text, and not an argument of `set`.
//
// - **zone**: the zone, 32 bytes at most.
//
// The caller must act for the principal (**Acts_For_Principal**). The result is 1, or a failure with its call outcome and an error record:
//
// - `No_Grant`: the caller does not act for the principal.
// - `No_Grant`, unit `Plan_Lock`: a lock of the plan of principal 0 holds the zone.
// - `Empty`: the zone is empty.
// - `Too_Small`: the zone has fewer than 6 bytes ("+8:00", "UTC").
// - `Too_Long`: the zone has more than 6 bytes.
// - `Bad_Byte`: a byte of the zone is not '+', '-', ':', or a digit.
// - `Bad_Value`: the minutes part is 60 or more, or the offset is outside -12:00 to +14:00 ("+15:00").
// - `Not_Multiple`: the offset is not a multiple of 15 minutes ("+08:10").
// - `Refused`: the store did not keep the zone. The page keeps the zone before.
//
// Example: `settings.set_time_zone("+08:00")`, then `settings.time_zone()` gives "+08:00".
@(export, link_name = "set_time_zone")
set_time_zone :: proc "c" (zone: ^string, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	zone_buffer: [32]u8
	given, zone_ok := copied(zone^, zone_buffer[:])
	if !zone_ok {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, i64(len(zone^)), settings.ZONE_TEXT_SIZE)
	}
	minutes, problem, detail_value, detail_found := settings.zone_parse_checked(given)
	switch problem {
	case .None:
	case .Empty:
		return call_outcome.fail(error, .Argument_Refused, .Empty, .Bytes, 1, 0, settings.ZONE_TEXT_SIZE)
	case .Too_Short:
		return call_outcome.fail(error, .Argument_Refused, .Too_Small, .Bytes, 1, detail_value, settings.ZONE_TEXT_SIZE)
	case .Too_Long:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Bytes, 1, detail_value, settings.ZONE_TEXT_SIZE)
	case .Bad_Byte:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Byte, .Bytes, 1, detail_value, 0, detail_found)
	case .Minutes_Over:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, detail_value, 59, detail_found)
	case .Out_Of_Range:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, detail_value, i64(settings.ZONE_OFFSET_MINUTES_MOST))
	case .Not_Quarter:
		return call_outcome.fail(error, .Argument_Refused, .Not_Multiple, .None, 1, detail_value, i64(settings.ZONE_OFFSET_MINUTES_STEP), detail_found)
	}
	if settings.time_zone_locked(kept_plan) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 1)
	}
	current, _ := settings.read(page)
	if !change(current, minutes, {time_zone = true}) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 1)
	}
	return .Succeeded, 1
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
// The caller must act for the principal (**Acts_For_Principal**). The result is 1, or a failure with its call outcome and an error record; on each refusal no language changes:
//
// - `No_Grant`: the caller does not act for the principal.
// - `Too_Long`: more than 8 records; value: their count; limit: 8.
// - `Out_Of_Range`: the count of the table is past its capacity; value: the count; limit: the capacity.
// - `Bad_Value`: a record that names no locale in its canonical form, or the root locale `und`; value: the
//   word of its `language_tag.Locale_Problem`, 0 for the root locale; found: the record, from 1.
// - `Bad_Value`: also a duplicate language that the table holds in an earlier record; found: the record, from 1.
// - `Refused`: the store did not keep the list. The page keeps the list before.
//
// Example: `settings.set_languages([language("fr"), language("en")])`, then `settings.languages()` gives fr, then en.
@(export, link_name = "set_languages")
set_languages :: proc "c" (languages: ^system.Table_To_Read(language_tag.Locale), error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if languages.count > settings.LANGUAGE_LIST_CAPACITY {
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 1, i64(min(languages.count, u64(max(i64)))), settings.LANGUAGE_LIST_CAPACITY)
	}
	if languages.count > languages.capacity {
		return call_outcome.fail(error, .Argument_Refused, .Out_Of_Range, .Records, 1, i64(languages.count), i64(min(languages.capacity, u64(max(i64)))))
	}
	// A copy: the caller can change its records during the call.
	given: [settings.LANGUAGE_LIST_CAPACITY]language_tag.Locale
	count := copy(given[:], system.table_records(languages))
	list, problem, place, locale_problem := settings.language_list_of_locales(given[:count])
	record := i64(place) + 1
	switch problem {
	case .None:
	case .Too_Many:
		return call_outcome.fail(error, .Argument_Refused, .Too_Long, .Records, 1, i64(count), settings.LANGUAGE_LIST_CAPACITY)
	case .Bad_Locale:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 1, i64(locale_problem), 0, record)
	case .No_Language, .Record_Past_Count:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 1, 0, 0, record)
	case .Duplicate:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .Records, 1, 0, 0, record)
	}
	current, _ := settings.read(page)
	current.languages = list
	if !change(current, current.zone_offset_minutes) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 1)
	}
	return .Succeeded, 1
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

// reset_and_write makes chosen values absent, then writes the settings that
// the defaults give on the page: the store first when present, or in memory
// for the running session without a store.
reset_and_write :: proc "contextless" (changes: []chosen_values.Change, languages: bool) -> bool {
	// As keep: a record that the store did not give is read again, and no
	// reset is written over choices that this process does not know.
	if has_store && kept_record_unread && kept_load() == .Read_Refused {
		system.log_fact(.Warning, Kept_Record_Unread{})
		return false
	}
	if len(changes) > 0 && !kept_write(changes, false, {}) {
		return false
	}
	if languages {
		if has_store {
			error: errors.Error_Record
			// No object is no choice already: the reset holds.
			if _, status := storage.remove(&store, storage.ROOT, settings.KEPT_LANGUAGES_OBJECT_NAME, &error); status != .Ok && status != .Absent {
				system.log_fact(.Warning, Store_Refused(errors.error_record_fact_fields(error)))
				return false
			}
		}
		kept_languages_found = false
		record, _ := chosen_values.read_record(kept_record_bytes[:kept_record_length])
		kept_choice, kept_zone_offset_minutes, kept_layers = settings.choice_of_kept(record, nil, false, kept_plan)
	}
	choice := kept_choice
	current, _ := page_choice()
	choice.change_count = current.change_count
	page_write(choice, kept_zone_offset_minutes)
	return true
}

// reset makes the choice of one setting absent: its default holds again. The
// result is 1, or an error record: `No_Grant` (-1) for a caller that does
// not act for the principal or (unit `Plan_Lock`) for a setting that a lock
// of the plan holds, `Bad_Value` (-3) for a word that names no setting,
// `Refused` (-4) when the store did not keep the change.
//
// ```
// settings.reset(.font)
// ```
@(export, link_name = "reset")
reset :: proc "c" (setting: settings.Setting, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	member, ok := enum_word.member_of_word(settings.Setting, u64(setting))
	if !ok {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, i64(setting))
	}
	if settings.setting_locked(kept_plan, member) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 1)
	}
	changes := [1]chosen_values.Change{{name = settings.descriptions[member].name, kind = .Reset}}
	if !reset_and_write(changes[:], false) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 1)
	}
	return .Succeeded, 1
}

// reset_time_zone makes the choice of the time zone absent: UTC holds again.
// The result is 1, or an error record as for reset.
@(export, link_name = "reset_time_zone")
reset_time_zone :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if settings.time_zone_locked(kept_plan) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 0)
	}
	changes := [1]chosen_values.Change{{name = settings.TIME_ZONE_NAME, kind = .Reset}}
	if !reset_and_write(changes[:], false) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0)
	}
	return .Succeeded, 1
}

// reset_languages makes the choice of the language list absent: English
// holds again. The result is 1, or an error record as for reset.
@(export, link_name = "reset_languages")
reset_languages :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if !reset_and_write(nil, true) {
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 0)
	}
	return .Succeeded, 1
}

// The state of one setting: the setting (its number in settings.Setting,
// then 7 for the time zone and 8 for the language list), the layer that
// gives its value (0 the default of the contract, 1 a default of the plan,
// 2 a choice of the principal, 3 a lock of the plan), and the word of its value (the count of the languages for the
// language list).
Setting_State :: struct {
	setting: i64,
	layer:   i64,
	value:   i64,
}

// settings_state gives one row for each setting: which layer gives its
// value, and the value. A reader sees that a choice hides a default. The
// result is the count of the rows, 9, or an error record.
@(export, link_name = "settings_state")
settings_state :: proc "c" (result: ^[]Setting_State, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	values := settings.values_of(kept_choice)
	rows: [len(settings.Setting) + 2]Setting_State
	for setting in settings.Setting {
		rows[int(setting)] = {setting = i64(setting), layer = i64(kept_layers.values[setting]), value = i64(values[setting])}
	}
	rows[len(settings.Setting)] = {setting = i64(len(settings.Setting)), layer = i64(kept_layers.time_zone), value = i64(kept_zone_offset_minutes)}
	rows[len(settings.Setting) + 1] = {setting = i64(len(settings.Setting) + 1), layer = i64(kept_layers.languages), value = i64(kept_choice.languages.count)}
	copy(result^, rows[:])
	return .Succeeded, i64(len(rows))
}

// repeat keeps count records in the store, one commit each, with the font and the subpixel order of each record from its number: the case of the loss of power of the machine test (a loss in the middle gives the record before or the record in flight, never a mix).
//
// It is a test export, not a setting that a reader changes. The machine test calls it, then cuts the power of the
// machine during the commits; at the next start, the boot pass must read one whole record. The font of record n
// is n mod 2, its subpixel order n mod 3, so a mix of two records shows. The page takes the last record.
//
// - **count**: the number of records, from 1 to 1000.
//
// The result is the count of records kept, or an outcome with an error record:
//
// - `Grant_Or_Right_Missing`, `No_Grant`: the caller does not act for the principal.
// - `Argument_Refused`, `Bad_Value`: a count outside 1 to 1000.
// - `Callee_Unavailable`, `Refused`: the store refused the first record.
// - `Stopped_After_A_Partial_Change`, `Refused`: the store refused a later record; the records before it are kept,
//   the page did not change, and the record of the error holds the number of the refused one.
@(export, link_name = "repeat")
repeat :: proc "c" (count: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if count < 1 || count > 1000 {
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, count, 1000)
	}
	choice, _ := settings.read(page)
	// The font of the record n is the value n mod 2, its order of the
	// stripes the value n mod 3: the members in the order of their values.
	fonts := [2]settings.Font{.Vector, .Spleen}
	orders := [3]settings.Subpixel_Order{.Red_Green_Blue, .Blue_Green_Red, .None}
	for number in 0 ..< count {
		choice.font = fonts[number % 2]
		choice.subpixel_order = orders[number % 3]
		if keep(choice, choice.zone_offset_minutes, {}) != .Kept_In_Store {
			// The store kept the records before this one; the page did
			// not change.
			if number > 0 {
				return call_outcome.fail(error, .Stopped_After_A_Partial_Change, .Refused, .None, 1, number)
			}
			return call_outcome.fail(error, .Callee_Unavailable, .Refused, .None, 1, number)
		}
	}
	page_write(choice, choice.zone_offset_minutes)
	system.log_fact(.Info, Records_Repeated{records = u64(count)})
	return .Succeeded, count
}

// appearance_next_pass is the pass of the tile of the Control Center: the
// appearance after the one of the page, kept in the store and written on
// the page, as a press on its button in the window does. The root service
// starts it only while no other process settings runs
// (settings.start_answer), so this process is the one writer of the page.
// A refused page stops the pass with Failed: the defaults of the reader
// would take the place of the kept record of each other setting.
appearance_next_pass :: proc "contextless" () -> ! {
	choice, read_ok := settings.read(page)
	if !read_ok {
		system.log_fact(.Warning, Appearance_Next_Page_Refused{})
		system.stop(.Failed)
	}
	before := choice.appearance
	choice.appearance = settings.appearance_next(before)
	given: settings.Given
	given.values[.Appearance] = true
	kept := change(choice, choice.zone_offset_minutes, given)
	result := kept ? (has_store ? Keep_Result.Kept_In_Store : .Kept_In_Session) : .Refused
	system.log_fact(.Info, Appearance_Next_Kept{before = value_kinds.text_field(settings.value_name_of(.Appearance, u32(before)), VALUE_NAME_FIELD_BYTES), after = value_field(choice, .Appearance), store = store_field(result)})
	system.stop(kept ? .Done : .Failed)
}

// boot_pass reads the record of the store and writes the page: the pass of
// the boot, with no window.
boot_pass :: proc "contextless" () -> ! {
	start := system.nanoseconds()
	// The kept record holds the choices of the principal only: the defaults
	// are never written, so a later default holds where the principal chose
	// none. A record that this release cannot read stays as it is.
	load := kept_load()
	choice, zone_offset_minutes := kept_choice, kept_zone_offset_minutes
	source: Boot_Pass_Source
	store_refused := false
	switch load {
	case .Nothing_Kept:
		source = .Nothing_Kept
	case .Kept:
		source = .Kept
	case .Unreadable:
		source = .Record_Unreadable
	case .Read_Refused:
		source = .Read_Refused
		store_refused = true
	case .No_Store:
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
	case .Record_Unreadable:
		system.log_fact(.Info, Boot_Pass_Record_Unreadable{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	case .No_Store:
		system.log_fact(.Info, Boot_Pass_No_Store{elapsed = elapsed, font = font, subpixel_order = subpixel_order, pointer_theme = pointer_theme, grid_fit = grid_fit, keyboard_layout = keyboard_layout, appearance = appearance_value, scale = scale_value})
	}
	if store_refused {
		system.stop(.Failed)
	}
	system.stop(.Done)
}

// The window (src/md/features/settings_window.md): four sections, each a
// card; each setting is its name, one line that says what it does, and its
// values. The value in force is the marked button.

// The texts of the window for one setting: its name, one line that says
// what it does, and the word of each value on its button. The exports keep
// the names of the enums (settings.descriptions); these words are for a
// reader. Two buttons of the window never have one label: a machine test
// presses a value by its label.
Setting_Text :: struct {
	title:        string,
	explanation:  string,
	value_labels: [settings.VALUE_NAME_CAPACITY]string,
}

@(rodata)
setting_texts := [settings.Setting]Setting_Text {
	.Font            = {"Font", "The font of the text of every window.", {"Vector", "Spleen 8x16", "", "", "", "", "", "", ""}},
	.Subpixel_Order  = {"Color stripes", "The order of the color stripes of the screen: text is sharper when it matches.", {"RGB", "BGR", "None (gray)", "", "", "", "", "", ""}},
	.Pointer_Theme   = {"Pointer theme", "Posy when the boot image holds it; without it, both are the theme of the system.", {"Posy", "System", "", "", "", "", "", "", ""}},
	.Grid_Fit        = {"Grid fit", "Puts the stems of the glyphs on whole pixels: sharper, and a little less exact.", {"On", "Off", "", "", "", "", "", "", ""}},
	.Keyboard_Layout = {"Layout", "The characters of the keys. A change holds from the next key.", {"US (QWERTY)", "French (AZERTY)", "", "", "", "", "", "", ""}},
	.Appearance      = {"Appearance", "Auto is light from 07:00 to 19:00 of the local time, and dark at night.", {"Auto", "Dark", "Light", "", "", "", "", "", ""}},
	.Scale           = {"Scale", "The size of each thing on the screen, from 100 % to 200 %. The whole desktop draws again at once.", {"100 %", "112.5 %", "125 %", "137.5 %", "150 %", "162.5 %", "175 %", "187.5 %", "200 %"}},
}

// The sections of the window, in the order of use.
Section :: enum u8 {
	Display,
	Pointer,
	Keyboard,
	Region_And_Language,
}

@(rodata)
section_titles := [Section]string {
	.Display             = "DISPLAY",
	.Pointer             = "POINTER",
	.Keyboard            = "KEYBOARD",
	.Region_And_Language = "REGION AND LANGUAGE",
}

// The settings of each section that are rows of values, in the order of
// the window: the scale first, the setting that a principal changes first
// on a new screen. The time zone and the languages are the section Region
// and language.
@(rodata)
display_settings := [?]settings.Setting{.Scale, .Appearance, .Font, .Subpixel_Order, .Grid_Fit}
@(rodata)
pointer_settings := [?]settings.Setting{.Pointer_Theme}
@(rodata)
keyboard_settings := [?]settings.Setting{.Keyboard_Layout}

// settings_of_section gives the settings of a section that are rows of
// values.
settings_of_section :: proc "contextless" (section: Section) -> []settings.Setting {
	switch section {
	case .Display:
		return display_settings[:]
	case .Pointer:
		return pointer_settings[:]
	case .Keyboard:
		return keyboard_settings[:]
	case .Region_And_Language:
		return nil
	}
	return nil
}

// An offset of the time zone that the earth uses, with places that keep it
// as their standard time. The contract holds the offset alone
// (src/md/features/time_zone.md): the places help a reader find it.
Zone_Place :: struct {
	minutes: i32,
	places:  string,
}

@(rodata)
zone_places := [?]Zone_Place {
	{-720, "Baker Island"},
	{-660, "American Samoa, Niue"},
	{-600, "Hawaii, Tahiti"},
	{-570, "Marquesas Islands"},
	{-540, "Alaska"},
	{-480, "Los Angeles, Vancouver"},
	{-420, "Denver, Phoenix"},
	{-360, "Chicago, Mexico City"},
	{-300, "New York, Toronto, Bogota"},
	{-240, "Halifax, La Paz, Caracas"},
	{-210, "Newfoundland"},
	{-180, "Sao Paulo, Buenos Aires"},
	{-120, "South Georgia"},
	{-60, "Azores, Cape Verde"},
	{0, "London, Lisbon, Accra"},
	{60, "Paris, Berlin, Lagos"},
	{120, "Athens, Cairo, Johannesburg"},
	{180, "Moscow, Istanbul, Nairobi"},
	{210, "Tehran"},
	{240, "Dubai, Baku"},
	{270, "Kabul"},
	{300, "Karachi, Tashkent"},
	{330, "India, Sri Lanka"},
	{345, "Nepal"},
	{360, "Dhaka, Bishkek"},
	{390, "Yangon"},
	{420, "Bangkok, Jakarta"},
	{480, "Beijing, Singapore, Perth"},
	{525, "Eucla"},
	{540, "Tokyo, Seoul"},
	{570, "Adelaide, Darwin"},
	{600, "Sydney, Brisbane"},
	{630, "Lord Howe Island"},
	{660, "Noumea, Solomon Islands"},
	{720, "Auckland, Fiji"},
	{765, "Chatham Islands"},
	{780, "Tonga, Samoa"},
	{840, "Kiritimati"},
}

// The common languages that the section offers to add, with the name that
// the window shows. The languages whose pack the machine holds take their
// place when the packs come.
Language_Name :: struct {
	tag:  string,
	name: string,
}

@(rodata)
common_languages := [7]Language_Name{{"en", "English"}, {"fr", "French"}, {"fr-CA", "French (Canada)"}, {"de", "German"}, {"es", "Spanish"}, {"ja", "Japanese"}, {"ar", "Arabic"}}

// language_name_of gives the name of a canonical tag, or the tag for a
// language that the window has no name for (a list that the console set).
language_name_of :: proc "contextless" (tag: string) -> string {
	for language in common_languages {
		if language.tag == tag {
			return language.name
		}
	}
	return tag
}

// The heights and widths of the window, in logical pixels. A button of a
// value is VALUE_BUTTON_WIDTH wide, or as wide as its label and its padding.
BUTTON_HEIGHT :: 24
VALUE_BUTTON_WIDTH :: 96
BUTTON_LABEL_PADDING :: 8
// The room between two settings of a card, and between the parts of one.
SETTING_GAP :: 16
SETTING_PART_GAP :: 4
// From this width of the window, the sections take two columns.
TWO_COLUMNS_WIDTH :: 720
// The lines of the list of the zones that show at once.
ZONE_LIST_LINES :: 6
// The room between two stops of the track of the scale.
SCALE_STOP_GAP :: 4
// The widest label of the scale, whose measure gives the room of the
// label of the scale in force beside its track.
SCALE_LABEL_SAMPLE :: "187.5 %"
// The label of each stop of the track: its percent, rounded half up. A stop
// of a narrow window has room for three digits where it has none for
// "187.5 %", so each stop says its value at each width that the window
// takes; the name of the element keeps the whole value.
SCALE_STOP_LABELS := [?]string{"100", "113", "125", "138", "150", "163", "175", "188", "200"}
#assert(len(SCALE_STOP_LABELS) == len(scale_factor.Scale))
// The widest label of a stop, with the room on each side of it.
SCALE_STOP_SAMPLE :: "188"
SCALE_STOP_LABEL_PADDING :: 4
// The bytes of one line of the list of the zones: "UTC+05:30  India, Sri Lanka".
ZONE_LINE_BYTES :: 64
// The bytes of one line of the list of the languages: "8  French (Canada)".
LANGUAGE_LINE_BYTES :: language_tag.LOCALE_TEXT_CAPACITY + 8

// The texts of a frame that the layout measures and the draw shows: the
// draw reads the same texts that gave the widths.
Frame_Texts :: struct {
	zone_line_buffers: [len(zone_places) + 1][ZONE_LINE_BYTES]u8,
	zone_lines:        [len(zone_places) + 1]string, // The lines of the list of the zones: a zone that the table does not hold is the first line.
	zone_line_count:   int,
	zone_chosen:       int, // The line of the zone in force.
	zone_first_extra:  bool, // The first line is the zone in force, which the table does not hold.
	tag_buffers:       [settings.LANGUAGE_LIST_CAPACITY][language_tag.LOCALE_TEXT_CAPACITY]u8,
	line_buffers:      [settings.LANGUAGE_LIST_CAPACITY][LANGUAGE_LINE_BYTES]u8,
	language_lines:    [settings.LANGUAGE_LIST_CAPACITY]string, // "1  French (Canada)".
	list_count:        int, // The languages of the list.
	lines_shown:       int, // The languages of the list whose tag was written: the list stops at the first that was not.
	added:             [len(common_languages)]settings.Language_List, // The list with each common language at its end.
	can_add:           [len(common_languages)]bool, // The list does not hold the common language, and is not full.
	declined_buffer:   [DECLINED_NOTICE_BYTES]u8,
	declined_notice:   string, // "2 windows show only their frame: ...", or "" when no window declined the scale.
}

// The parts of the notice of the windows that declined the scale, and its
// bytes: the 19 digits of the largest count and the longer form.
DECLINED_ONE :: " window shows only its frame"
DECLINED_MANY :: " windows show only their frame"
DECLINED_REASON :: ": its budget does not pay a surface at this scale. A smaller scale, or a new start of the window, shows it again."
DECLINED_NOTICE_BYTES :: 19 + len(DECLINED_MANY) + len(DECLINED_REASON)
#assert(len(DECLINED_MANY) >= len(DECLINED_ONE))

// declined_notice_write writes the notice of the windows whose budget does
// not pay a surface at the scale in force, or "" for none.
declined_notice_write :: proc "contextless" (buffer: []u8, windows: int) -> string {
	if windows <= 0 {
		return ""
	}
	digits: [20]u8
	place := len(digits)
	for value := windows; value > 0 || place == len(digits); value /= 10 {
		place -= 1
		digits[place] = u8('0' + value % 10)
	}
	count := copy(buffer, digits[place:])
	count += copy(buffer[count:], windows == 1 ? DECLINED_ONE : DECLINED_MANY)
	count += copy(buffer[count:], DECLINED_REASON)
	return string(buffer[:count])
}

// zone_line_write writes the line of a zone in the list: "UTC+05:30" and
// its places.
zone_line_write :: proc "contextless" (buffer: []u8, minutes: i32, places: string) -> string {
	zone_buffer: [settings.ZONE_TEXT_SIZE]u8
	count := copy(buffer, "UTC")
	count += copy(buffer[count:], settings.zone_text(zone_buffer[:], minutes))
	if places != "" {
		count += copy(buffer[count:], "  ")
		count += copy(buffer[count:], places)
	}
	return string(buffer[:count])
}

// frame_texts_of gives the texts of a frame of the window.
frame_texts_of :: proc "contextless" (texts: ^Frame_Texts, choice: settings.Choice, windows_declined := 0) {
	texts.declined_notice = declined_notice_write(texts.declined_buffer[:], windows_declined)
	zone := choice.zone_offset_minutes
	texts.zone_line_count = 0
	texts.zone_chosen = -1
	texts.zone_first_extra = true
	for place in zone_places {
		if place.minutes == zone {
			texts.zone_first_extra = false
		}
	}
	if texts.zone_first_extra {
		texts.zone_lines[0] = zone_line_write(texts.zone_line_buffers[0][:], zone, "")
		texts.zone_chosen = 0
		texts.zone_line_count = 1
	}
	for place in zone_places {
		line := texts.zone_line_count
		texts.zone_lines[line] = zone_line_write(texts.zone_line_buffers[line][:], place.minutes, place.places)
		if place.minutes == zone {
			texts.zone_chosen = line
		}
		texts.zone_line_count += 1
	}
	list := choice.languages
	texts.list_count = int(min(list.count, settings.LANGUAGE_LIST_CAPACITY))
	texts.lines_shown = 0
	for index in 0 ..< texts.list_count {
		tag, tag_ok := language_tag.tag_write(list.locales[index], texts.tag_buffers[index][:])
		if !tag_ok {
			break
		}
		buffer := texts.line_buffers[index][:]
		buffer[0] = u8('1' + index)
		count := 1
		count += copy(buffer[count:], "  ")
		count += copy(buffer[count:], language_name_of(tag))
		texts.language_lines[index] = string(buffer[:count])
		texts.lines_shown += 1
	}
	for language, index in common_languages {
		texts.can_add[index] = false
		locale, problem, _ := language_tag.tag_read(language.tag)
		if problem != .None {
			continue
		}
		added, add_problem := settings.language_list_add(list, locale)
		// A problem: the list holds the language, or is full.
		texts.added[index] = added
		texts.can_add[index] = add_problem == .None
	}
}

// The number of each line of the list of the languages is one digit.
#assert(settings.LANGUAGE_LIST_CAPACITY <= 9)

// The boxes of one setting that is a segmented control or track.
Setting_Boxes :: struct {
	title:       layout.Box_Index,
	explanation: layout.Box_Index,
	control:     layout.Box_Index, // Segmented control box (NO_BOX for .Scale, which uses scale_track).
}

// The boxes of a line of the list of the languages.
Language_Boxes :: struct {
	text:   layout.Box_Index,
	up:     layout.Box_Index, // NO_BOX: the first language.
	remove: layout.Box_Index,
}

// The boxes of the window that the draw reads after the solve. NO_BOX: the
// frame has no such element.
Settings_Boxes :: struct {
	has_sidebar:           bool,
	sidebar:               layout.Box_Index, // Left navigation sidebar when width >= SIDEBAR_MIN_WIDTH.
	compact_nav:           layout.Box_Index, // Top tab bar when width < SIDEBAR_MIN_WIDTH.
	view:                  layout.Box_Index, // The part of the window that scrolls.
	scroll_bar:            layout.Box_Index, // NO_BOX: the content fits the view.
	store_note:            layout.Box_Index, // NO_BOX: the store keeps the choices.
	cards:                 [Section]layout.Box_Index,
	setting_boxes:         [settings.Setting]Setting_Boxes,
	scale_value:           layout.Box_Index, // NO_BOX: each stop of the track holds its percentage.
	scale_track:           layout.Box_Index,
	scale_declined:        layout.Box_Index, // NO_BOX: each window pays its surface at the scale in force.
	zone_title:            layout.Box_Index,
	zone_explanation:      layout.Box_Index,
	zone_list:             layout.Box_Index,
	languages_title:       layout.Box_Index,
	languages_explanation: layout.Box_Index,
	languages_none:        layout.Box_Index,
	language_lines:        [settings.LANGUAGE_LIST_CAPACITY]Language_Boxes,
	add_title:             layout.Box_Index,
	add_buttons:           [len(common_languages)]layout.Box_Index,
	discovered_cards:      [DISCOVERED_MODULE_CAPACITY]Discovered_Card_Boxes,
	footer:                layout.Box_Index,
	content_height:        int, // The height of the content of the view, which the scroll bar moves.
	scroll:                int, // The first line of the content in the view, which the solver clamped.
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

// A box of a fixed width and height.
fixed_box :: proc "contextless" (width, height: int) -> layout.Box_Description {
	return {size = {.X = layout.px(i32(width)), .Y = layout.px(i32(height))}}
}

// A box across the whole width, of a height.
line_box :: proc "contextless" (height: int) -> layout.Box_Description {
	return {size = {.X = layout.fill(), .Y = layout.px(i32(height))}}
}

// The width of a button whose label is drawn whole in the font that draws
// it, at least least_width.
button_width :: proc "contextless" (table: ^interface.Draw_Table, label: string, least_width := 0) -> int {
	return max(interface.text_measured_width(table, interface.FONT_INTERFACE, label) + 2 * BUTTON_LABEL_PADDING, least_width)
}

// Row_Flow places boxes of known widths in lines of BUTTON_HEIGHT across a
// width: a box that does not fit in the rest of its line starts the next
// line. A box wider than a whole line keeps the width of the line.
Row_Flow :: struct {
	builder: ^Layout_Builder,
	width:   int, // The width of a line.
	used:    int, // The width that the open line holds, with its gaps.
	open:    bool, // A line is open.
	gap:     int,
}

flow_begin :: proc "contextless" (builder: ^Layout_Builder, width, gap: int) -> Row_Flow {
	builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, gap = i32(gap)})
	return {builder = builder, width = width, gap = gap}
}

flow_add :: proc "contextless" (flow: ^Row_Flow, width: int) -> layout.Box_Index {
	shown := min(width, flow.width)
	if flow.open && flow.used + flow.gap + shown > flow.width {
		builder_close(flow.builder)
		flow.open = false
	}
	if !flow.open {
		builder_open(flow.builder, {size = {.X = layout.fill(), .Y = layout.px(BUTTON_HEIGHT)}, child_axis = .X, gap = i32(flow.gap)})
		flow.open = true
		flow.used = 0
	} else {
		flow.used += flow.gap
	}
	flow.used += shown
	return builder_add(flow.builder, fixed_box(shown, BUTTON_HEIGHT))
}

flow_end :: proc "contextless" (flow: ^Row_Flow) {
	if flow.open {
		builder_close(flow.builder)
	}
	builder_close(flow.builder)
}

// setting_header_add adds the name of a setting and the line of what it
// does, which wraps in the width of the card.
setting_header_add :: proc "contextless" (builder: ^Layout_Builder, table: ^interface.Draw_Table, explanation: string, room: int) -> (title, explanation_box: layout.Box_Index) {
	title = builder_add(builder, line_box(interface.line_height(interface.FONT_INTERFACE_BOLD)))
	explanation_box = builder_add(builder, line_box(interface.caption_height(table, explanation, room)))
	return
}

ZONE_TITLE :: "Time zone"
// After the name of a setting that a lock of the plan of principal 0 holds.
LOCKED_MARK :: "locked by the plan"
ZONE_EXPLANATION :: "A fixed offset from UTC: it does not follow summer time."
LANGUAGES_TITLE :: "Languages"
LANGUAGES_EXPLANATION :: "The languages that you read, the first first. Each text is in the first one that has it, else in English."
LANGUAGES_NONE :: "No language chosen."
LANGUAGE_UP :: "Up"
LANGUAGE_REMOVE :: "Remove"
LANGUAGE_ADD :: "Add"
STORE_NOTE :: "Not kept: no store. The choices last until the next start."

// section_matches_filter reports whether a core section should be shown for the
// active navigation category and live search query.
section_matches_filter :: proc "contextless" (section: Section, cat: Nav_Category, query: string) -> bool {
	if query == "" {
		switch cat {
		case .All:
			return true
		case .Display:
			return section == .Display
		case .Pointer:
			return section == .Pointer
		case .Keyboard:
			return section == .Keyboard
		case .Region_And_Language:
			return section == .Region_And_Language
		case .Modules:
			return false
		}
	}
	if interface.find_without_case(section_titles[section], query) >= 0 {
		return true
	}
	for setting in settings_of_section(section) {
		if interface.find_without_case(setting_texts[setting].title, query) >= 0 || interface.find_without_case(setting_texts[setting].explanation, query) >= 0 {
			return true
		}
		for place in 0 ..< int(settings.descriptions[setting].value_count) {
			if interface.find_without_case(setting_texts[setting].value_labels[place], query) >= 0 {
				return true
			}
		}
	}
	if section == .Region_And_Language {
		if interface.find_without_case(ZONE_TITLE, query) >= 0 || interface.find_without_case(LANGUAGES_TITLE, query) >= 0 {
			return true
		}
	}
	return false
}

// section_add adds the card of a section: the room of its title, then
// each setting, then the room under the last one.
section_add :: proc "contextless" (builder: ^Layout_Builder, boxes: ^Settings_Boxes, table: ^interface.Draw_Table, texts: ^Frame_Texts, section: Section, room: int, tokens: layout.Element_Tokens) {
	gap := int(tokens.gap)
	boxes.cards[section] = builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, padding = {.X = tokens.margin, .Y = 0}, gap = SETTING_GAP})
	builder_add(builder, line_box(int(tokens.title) - SETTING_GAP))
	for setting in settings_of_section(section) {
		builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, gap = SETTING_PART_GAP})
		setting_boxes := &boxes.setting_boxes[setting]
		setting_boxes.title, setting_boxes.explanation = setting_header_add(builder, table, setting_texts[setting].explanation, room)
		if setting == .Scale {
			// The track of the stops, each with its percent; a stop too
			// narrow for three digits leaves the scale in force beside a
			// track of bare stops.
			builder_open(builder, {size = {.X = layout.fill(), .Y = layout.px(SEGMENTED_HEIGHT)}, child_axis = .X, gap = i32(gap)})
			if scale_stop_width(room) < interface.text_measured_width(table, interface.FONT_INTERFACE, SCALE_STOP_SAMPLE) + 2 * SCALE_STOP_LABEL_PADDING {
				boxes.scale_value = builder_add(builder, fixed_box(interface.text_measured_width(table, interface.FONT_INTERFACE_BOLD, SCALE_LABEL_SAMPLE), SEGMENTED_HEIGHT))
			}
			boxes.scale_track = builder_add(builder, line_box(SEGMENTED_HEIGHT))
			builder_close(builder)
			if texts.declined_notice != "" {
				boxes.scale_declined = builder_add(builder, line_box(interface.caption_height(table, texts.declined_notice, room)))
			}
		} else {
			setting_boxes.control = builder_add(builder, line_box(SEGMENTED_HEIGHT))
		}
		builder_close(builder)
	}
	if section == .Region_And_Language {
		// The time zone: its name, its line, the list of the offsets.
		builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, gap = SETTING_PART_GAP})
		boxes.zone_title, boxes.zone_explanation = setting_header_add(builder, table, ZONE_EXPLANATION, room)
		boxes.zone_list = builder_add(builder, line_box(ZONE_LIST_LINES * interface.TABLE_LINE))
		builder_close(builder)
		// The languages: their name, their line, the list in its order,
		// then the common languages to add.
		builder_open(builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, gap = SETTING_PART_GAP})
		boxes.languages_title, boxes.languages_explanation = setting_header_add(builder, table, LANGUAGES_EXPLANATION, room)
		if texts.list_count == 0 {
			boxes.languages_none = builder_add(builder, line_box(BUTTON_HEIGHT))
		}
		for index in 0 ..< texts.lines_shown {
			line := &boxes.language_lines[index]
			builder_open(builder, {size = {.X = layout.fill(), .Y = layout.px(BUTTON_HEIGHT)}, child_axis = .X, gap = i32(gap)})
			line.text = builder_add(builder, line_box(BUTTON_HEIGHT))
			if index > 0 {
				line.up = builder_add(builder, fixed_box(button_width(table, LANGUAGE_UP), BUTTON_HEIGHT))
			}
			line.remove = builder_add(builder, fixed_box(button_width(table, LANGUAGE_REMOVE), BUTTON_HEIGHT))
			builder_close(builder)
		}
		flow := flow_begin(builder, room, gap)
		boxes.add_title = flow_add(&flow, interface.text_measured_width(table, {}, LANGUAGE_ADD))
		for language, index in common_languages {
			if texts.can_add[index] {
				boxes.add_buttons[index] = flow_add(&flow, button_width(table, language.name))
			}
		}
		flow_end(&flow)
		builder_close(builder)
	}
	builder_add(builder, line_box(0))
	builder_close(builder)
}

// settings_tree_build builds the tree of the window at a size: the left
// sidebar (or compact top tab bar on narrow windows), the scrollable view of
// cards, the scroll bar when needed, and the slim status footer.
settings_tree_build :: proc "contextless" (table: ^interface.Draw_Table, texts: ^Frame_Texts, width, height, scroll: int, with_scroll_bar: bool, tokens: layout.Element_Tokens, discovered: ^Discovered_Set = nil, cat: Nav_Category = .All, query := "") -> (boxes: Settings_Boxes, ok: bool) {
	tree := &layout_tree
	if layout.tree_begin(tree, i32(width), i32(height), {child_axis = .Y}) != .Done {
		return {}, false
	}
	builder := Layout_Builder{tree = tree}
	gap := int(tokens.gap)
	boxes.has_sidebar = width >= SIDEBAR_MIN_WIDTH
	if !boxes.has_sidebar {
		boxes.compact_nav = builder_add(&builder, line_box(COMPACT_NAV_HEIGHT))
	}
	content_total_w := width - (boxes.has_sidebar ? SIDEBAR_WIDTH : 0)
	view_width := content_total_w - (with_scroll_bar ? interface.SCROLL_BAR_THICKNESS : 0)
	// Two columns when showing All sections with plenty of room past the sidebar.
	columns := (cat == .All && query == "" && content_total_w >= TWO_COLUMNS_WIDTH) ? 2 : 1
	column_width := max((view_width - 2 * gap - (columns - 1) * gap) / columns, 1)
	room := max(column_width - 2 * int(tokens.margin), 1)
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .X})
	if boxes.has_sidebar {
		boxes.sidebar = builder_add(&builder, {size = {.X = layout.px(SIDEBAR_WIDTH), .Y = layout.fill()}})
	}
	boxes.view = builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.fill()}, child_axis = .Y, overflow = {.X = .Clip, .Y = .Scroll}, scroll = {.X = 0, .Y = i32(clamp(scroll, 0, layout.LENGTH_LIMIT))}})
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .Y, padding = {.X = i32(gap), .Y = i32(gap)}, gap = i32(gap)})
	if !has_store {
		boxes.store_note = builder_add(&builder, line_box(interface.caption_height(table, STORE_NOTE, max(view_width - 2 * gap, 1))))
	}
	builder_open(&builder, {size = {.X = layout.fill(), .Y = layout.children_sum()}, child_axis = .X, gap = i32(gap)})
	show_modules := (cat == .All || cat == .Modules)
	for column in 0 ..< columns {
		builder_open(&builder, {size = {.X = layout.px(i32(column_width)), .Y = layout.children_sum()}, child_axis = .Y, gap = i32(gap)})
		for section in Section {
			if !section_matches_filter(section, cat, query) {
				continue
			}
			// One column holds each section; two hold Display at the left and the others at the right.
			if columns == 1 || (section == .Display) == (column == 0) {
				section_add(&builder, &boxes, table, texts, section, room, tokens)
			}
		}
		if discovered != nil && (show_modules || query != "") {
			for mod_idx in 0 ..< min(discovered.module_count, DISCOVERED_MODULE_CAPACITY) {
				if query != "" && interface.find_without_case(discovered_module_title(&discovered.modules[mod_idx]), query) < 0 {
					continue
				}
				if columns == 1 || (mod_idx % 2 == 0) == (column == 0) {
					discovered_section_add(&builder, &boxes.discovered_cards[mod_idx], table, &discovered.modules[mod_idx], room, tokens)
				}
			}
		}
		builder_close(&builder)
	}
	builder_close(&builder)
	builder_close(&builder)
	builder_close(&builder)
	if with_scroll_bar {
		boxes.scroll_bar = builder_add(&builder, {size = {.X = layout.px(interface.SCROLL_BAR_THICKNESS), .Y = layout.fill()}})
	}
	builder_close(&builder)
	boxes.footer = builder_add(&builder, line_box(STATUS_FOOTER_HEIGHT))
	if builder.status != .Done || layout.solve(tree) != .Done {
		return {}, false
	}
	view := layout.box_of(tree, boxes.view)
	boxes.content_height = int(view.content_size[.Y])
	boxes.scroll = int(view.scroll[.Y])
	return boxes, true
}

// settings_layout builds and solves the layout tree of the window at a
// size, with the first line of the content that the view shows. A content
// taller than the view gets the scroll bar: the tree is built again with
// the bar, whose width can wrap more lines.
settings_layout :: proc "contextless" (table: ^interface.Draw_Table, texts: ^Frame_Texts, width, height, scroll: int, tokens: layout.Element_Tokens, discovered: ^Discovered_Set = nil, cat: Nav_Category = .All, query := "") -> (boxes: Settings_Boxes, ok: bool) {
	if width <= 0 || height <= 0 || width > layout.LENGTH_LIMIT || height > layout.LENGTH_LIMIT {
		return {}, false
	}
	boxes, ok = settings_tree_build(table, texts, width, height, 0, false, tokens, discovered, cat, query)
	if !ok {
		return {}, false
	}
	if boxes.content_height > int(area_of(&layout_tree, boxes.view).height) {
		boxes, ok = settings_tree_build(table, texts, width, height, scroll, true, tokens, discovered, cat, query)
	}
	return boxes, ok
}

// The first line of the content in the view: the scroll bar and the wheel
// move it, and the focus brings the element that has it into the view.
view_scroll: int

// setting_segmented draws an enum setting as a connected segmented control
// while keeping its act name so the Super palette can focus it directly.
setting_segmented :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, setting: settings.Setting, values: [settings.Setting]u32, locked: bool) -> (result: interface.Element_Result, chosen_place: int) {
	count := int(settings.descriptions[setting].value_count)
	current_place := 0
	for place in 0 ..< count {
		if values[setting] == settings.word_of_value(setting, place) {
			current_place = place
			break
		}
	}
	chosen_place = current_place
	builder: interface.Text_Builder
	interface.text_put(&builder, "setting ")
	interface.text_put(&builder, settings.descriptions[setting].name)
	element := interface.identity(interface.text_of(&builder))
	result = interface.segmented_control(frame, area, element, setting_texts[setting].value_labels[:count], &chosen_place, locked)
	act: interface.Text_Builder
	interface.text_put(&act, "settings.set:")
	interface.text_put(&act, settings.descriptions[setting].name)
	interface.element_act_name(frame, element, interface.text_of(&act))
	return
}

// scale_stop_width gives the width of one stop of a track of a width.
scale_stop_width :: proc "contextless" (track_width: int) -> int {
	stops := len(scale_factor.Scale)
	return (track_width - (stops - 1) * SCALE_STOP_GAP) / stops
}

// scale_track_draw draws the machined track of the scale: one stop for each
// member of the enum, from 100 % to 200 %, with hover and active gradient fills.
scale_track_draw :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, choice: settings.Choice, labels_inside: bool, focus_area: ^interface.Area) {
	stop_width := scale_stop_width(area.width)
	for member, place in scale_factor.Scale {
		stop := interface.Area{area.x + place * (stop_width + SCALE_STOP_GAP), area.y, stop_width, area.height}
		label := setting_texts[.Scale].value_labels[place]
		label_y := stop.y + (stop.height - interface.LINE) / 2
		element := interface.identity_with(interface.identity("scale stop"), place)
		result := interface.element_interact(frame, element, stop, .Button)
		interface.element_name(frame, stop, label)
		in_use := member == choice.scale
		states := accessibility.Element_States{.Focusable}
		if result.focused {
			states += {.Focused}
		}
		interface.draw_element_push(frame.table, stop, u32(element), .Button, {toggle = in_use ? .True : .False, states = states, actions = {.Press, .Focus}, name = label})
		if in_use {
			interface.draw_vertical_gradient(frame.table, stop.x, stop.y, stop.width, stop.height, graphics.shade(graphics.colors.chosen, 112), graphics.shade(graphics.colors.chosen, 88), u32(element))
			if stop.width > 2 {
				interface.draw_rectangle(frame.table, stop.x + 1, stop.y + 1, stop.width - 2, 1, graphics.shade(graphics.colors.chosen, 140), u32(element))
			}
		} else if result.under_pointer {
			interface.draw_rectangle(frame.table, stop.x, stop.y, stop.width, stop.height, graphics.shade(graphics.colors.title, 62), u32(element))
			interface.draw_outline(frame.table, stop.x, stop.y, stop.width, stop.height, 1, graphics.colors.title, u32(element))
		} else {
			interface.draw_vertical_gradient(frame.table, stop.x, stop.y, stop.width, stop.height, graphics.shade(graphics.colors.track, 108), graphics.shade(graphics.colors.track, 92), u32(element))
			interface.draw_outline(frame.table, stop.x, stop.y, stop.width, stop.height, 1, graphics.colors.not_usable, u32(element))
		}
		if labels_inside {
			short := SCALE_STOP_LABELS[place]
			font := in_use ? interface.FONT_INTERFACE_BOLD : interface.FONT_INTERFACE
			label_x := stop.x + max((stop.width - interface.text_measured_width(frame.table, font, short)) / 2, 0)
			col := (in_use || result.under_pointer) ? graphics.COLOR_WHITE : graphics.colors.text
			interface.draw_text(frame.table, label_x, label_y, short, col, font, u32(element))
		}
		if result.focused {
			interface.draw_focus_ring(frame.table, stop, u32(element))
			focus_area^ = stop
		}
		interface.draw_element_pop(frame.table)
		if in_use {
			interface.element_act_name(frame, element, "settings.set:scale")
		}
		if result.activated && !in_use {
			if changed, changed_ok, _ := with_value(choice, .Scale, place); changed_ok {
				given: settings.Given
				given.values[.Scale] = true
				change(changed, choice.zone_offset_minutes, given)
			}
		}
	}
}

// setting_header_draw draws the name of a setting and the line of what it
// does.
setting_header_draw :: proc "contextless" (frame: ^interface.Frame, title, explanation: interface.Area, title_text, explanation_text: string, tokens: layout.Element_Tokens, locked := false) {
	interface.draw_text(frame.table, title.x, title.y, title_text, tokens.text, interface.FONT_INTERFACE_BOLD)
	// A setting that a lock of the plan holds says so after its name: its
	// buttons take no press.
	if locked {
		after := title.x + interface.text_measured_width(frame.table, interface.FONT_INTERFACE_BOLD, title_text) + int(tokens.gap)
		interface.draw_text(frame.table, after, title.y, LOCKED_MARK, tokens.text_dim, interface.FONT_INTERFACE)
	}
	interface.draw_caption(frame, explanation.x, explanation.y, explanation.width, explanation_text)
}

// A text on the line of the labels of the buttons beside it.
text_on_button_line :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, text: string, color: graphics.Color, font: interface.Font = {}) {
	interface.draw_text(frame.table, area.x, area.y + (BUTTON_HEIGHT - interface.LINE) / 2, text, color, font)
}

// region_draw draws the section Region and language: the list of the
// zones, then the list of the languages with Up and Remove, then the
// languages to add.
region_draw :: proc "contextless" (frame: ^interface.Frame, boxes: ^Settings_Boxes, choice: settings.Choice, texts: ^Frame_Texts, tokens: layout.Element_Tokens, focus_area: ^interface.Area) {
	tree := &layout_tree
	setting_header_draw(frame, area_of(tree, boxes.zone_title), area_of(tree, boxes.zone_explanation), ZONE_TITLE, ZONE_EXPLANATION, tokens, settings.time_zone_locked(kept_plan))
	zone_area := area_of(tree, boxes.zone_list)
	chosen := max(texts.zone_chosen, 0)
	zone_result := interface.list_with_choice(frame, zone_area, interface.identity("time zone list"), texts.zone_lines[:texts.zone_line_count], &chosen, {name = "time zone"})
	if zone_result.focused {
		focus_area^ = zone_area
	}
	if zone_result.changed && chosen != texts.zone_chosen {
		place := chosen - (texts.zone_first_extra ? 1 : 0)
		if place >= 0 && place < len(zone_places) {
			change(choice, zone_places[place].minutes, {time_zone = true})
		}
	}

	setting_header_draw(frame, area_of(tree, boxes.languages_title), area_of(tree, boxes.languages_explanation), LANGUAGES_TITLE, LANGUAGES_EXPLANATION, tokens)
	list := choice.languages
	if texts.list_count == 0 {
		text_on_button_line(frame, area_of(tree, boxes.languages_none), LANGUAGES_NONE, tokens.text)
	}
	for index in 0 ..< texts.lines_shown {
		line := &boxes.language_lines[index]
		text_on_button_line(frame, area_of(tree, line.text), texts.language_lines[index], tokens.text)
		if line.up != layout.NO_BOX {
			area := area_of(tree, line.up)
			result := interface.button(frame, area, interface.identity_with(interface.identity("language up"), index), LANGUAGE_UP)
			if result.focused {
				focus_area^ = area
			}
			if result.activated {
				changed := choice
				changed.languages = settings.language_list_move_up(list, index)
				change(changed, choice.zone_offset_minutes)
			}
		}
		area := area_of(tree, line.remove)
		result := interface.button(frame, area, interface.identity_with(interface.identity("language remove"), index), LANGUAGE_REMOVE)
		if result.focused {
			focus_area^ = area
		}
		if result.activated {
			changed := choice
			changed.languages = settings.language_list_remove(list, index)
			change(changed, choice.zone_offset_minutes)
		}
	}
	text_on_button_line(frame, area_of(tree, boxes.add_title), LANGUAGE_ADD, tokens.text_dim)
	for language, index in common_languages {
		if !texts.can_add[index] {
			continue
		}
		area := area_of(tree, boxes.add_buttons[index])
		result := interface.button(frame, area, interface.identity_with(interface.identity("language add"), index), language.name)
		if result.focused {
			focus_area^ = area
		}
		if result.activated {
			changed := choice
			changed.languages = texts.added[index]
			change(changed, choice.zone_offset_minutes)
		}
	}
}

// settings_ctx_menu_open opens the compact right-click menu for settings.
settings_ctx_menu_open :: proc "contextless" (x, y, w, h: int, has_modules: bool) {
	interface.command_palette_close(&settings_palette)
	items: [8]interface.Context_Menu_Item
	n := 0
	items[n] = {id = u32(Settings_Menu_Action.Cat_All), label = "All settings", disabled = nav_category == .All && search_len == 0}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Display), label = "Display", disabled = nav_category == .Display}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Pointer), label = "Pointer", disabled = nav_category == .Pointer}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Keyboard), label = "Keyboard", disabled = nav_category == .Keyboard}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Region), label = "Region & language", disabled = nav_category == .Region_And_Language}; n += 1
	if has_modules {
		items[n] = {id = u32(Settings_Menu_Action.Cat_Modules), label = "Modules", disabled = nav_category == .Modules}; n += 1
	}
	if search_len > 0 {
		items[n] = {id = u32(Settings_Menu_Action.Clear_Search), label = "Clear search", separator_before = true}; n += 1
	}
	items[n] = {id = u32(Settings_Menu_Action.Open_Palette), label = "Command palette", shortcut = "Ctrl+K", separator_before = true}; n += 1
	interface.context_menu_open_compact(&settings_ctx_menu, x, y, w, h, items[:n])
}

// settings_palette_open opens the Ctrl+K fuzzy command palette for settings.
settings_palette_open :: proc "contextless" (h: int, has_modules: bool) {
	interface.context_menu_close(&settings_ctx_menu)
	items: [16]interface.Command_Palette_Item
	n := 0
	items[n] = {id = u32(Settings_Menu_Action.Cat_All), label = "Show all sections", category = "Navigate"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Display), label = "Display", category = "Navigate"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Pointer), label = "Pointer", category = "Navigate"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Keyboard), label = "Keyboard", category = "Navigate"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Cat_Region), label = "Region & language", category = "Navigate"}; n += 1
	if has_modules {
		items[n] = {id = u32(Settings_Menu_Action.Cat_Modules), label = "Modules", category = "Navigate"}; n += 1
	}
	items[n] = {id = u32(Settings_Menu_Action.Appearance_Auto), label = "Appearance: Auto", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Appearance_Dark), label = "Appearance: Dark", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Appearance_Light), label = "Appearance: Light", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Font_Vector), label = "Font: Vector", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Font_Spleen), label = "Font: Spleen 8x16", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Scale_100), label = "Scale: 100 %", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Scale_125), label = "Scale: 125 %", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Scale_150), label = "Scale: 150 %", category = "Display"}; n += 1
	items[n] = {id = u32(Settings_Menu_Action.Scale_200), label = "Scale: 200 %", category = "Display"}; n += 1
	if search_len > 0 {
		items[n] = {id = u32(Settings_Menu_Action.Clear_Search), label = "Clear search filter", category = "Search"}; n += 1
	}
	interface.command_palette_open(&settings_palette, "Settings commands", items[:n], h)
}

settings_apply_quick_value :: proc "contextless" (choice: settings.Choice, setting: settings.Setting, place: int) {
	if changed, ok, _ := with_value(choice, setting, place); ok {
		given: settings.Given
		given.values[setting] = true
		change(changed, choice.zone_offset_minutes, given)
	}
}

settings_menu_action_run :: proc "contextless" (action_word: u32, choice: settings.Choice, h: int, has_modules: bool) -> bool {
	action, ok := enum_word.member_of_word(Settings_Menu_Action, u64(action_word))
	if !ok {
		return false
	}
	switch action {
	case .None:
		return false
	case .Cat_All:
		nav_category = .All
		search_len = 0
		view_scroll = 0
		return true
	case .Cat_Display:
		nav_category = .Display
		view_scroll = 0
		return true
	case .Cat_Pointer:
		nav_category = .Pointer
		view_scroll = 0
		return true
	case .Cat_Keyboard:
		nav_category = .Keyboard
		view_scroll = 0
		return true
	case .Cat_Region:
		nav_category = .Region_And_Language
		view_scroll = 0
		return true
	case .Cat_Modules:
		nav_category = .Modules
		view_scroll = 0
		return true
	case .Clear_Search:
		search_len = 0
		view_scroll = 0
		return true
	case .Appearance_Auto:
		settings_apply_quick_value(choice, .Appearance, 0)
		return true
	case .Appearance_Dark:
		settings_apply_quick_value(choice, .Appearance, 1)
		return true
	case .Appearance_Light:
		settings_apply_quick_value(choice, .Appearance, 2)
		return true
	case .Font_Vector:
		settings_apply_quick_value(choice, .Font, 0)
		return true
	case .Font_Spleen:
		settings_apply_quick_value(choice, .Font, 1)
		return true
	case .Scale_100:
		settings_apply_quick_value(choice, .Scale, 0)
		return true
	case .Scale_125:
		settings_apply_quick_value(choice, .Scale, 2)
		return true
	case .Scale_150:
		settings_apply_quick_value(choice, .Scale, 4)
		return true
	case .Scale_200:
		settings_apply_quick_value(choice, .Scale, 8)
		return true
	case .Open_Palette:
		settings_palette_open(h, has_modules)
		return true
	}
	return false
}

// sidebar_draw renders the left navigation rail: title, live search box,
// and single-tab-stop WAI-ARIA category list.
sidebar_draw :: proc "contextless" (frame: ^interface.Frame, area: interface.Area, has_modules: bool) -> bool {
	table := frame.table
	interface.draw_rectangle(table, area.x, area.y, area.width, area.height, graphics.colors.card_bottom)
	interface.draw_rectangle(table, area.x + area.width - 1, area.y, 1, area.height, graphics.colors.track)
	pad := 10
	inner_w := max(area.width - 2 * pad - 1, 1)
	y := area.y + 12
	interface.draw_text(table, area.x + pad, y, "SETTINGS", graphics.colors.kernel, interface.FONT_INTERFACE_BOLD)
	y += interface.LINE + 10
	search_area := interface.Area{area.x + pad, y, inner_w, SIDEBAR_SEARCH_HEIGHT}
	sr := interface.text_input(frame, search_area, interface.identity("settings search"), search_buf[:], &search_len, "Search...", name = "Search settings")
	changed := sr.changed
	if sr.changed {
		view_scroll = 0
	}
	y += SIDEBAR_SEARCH_HEIGHT + 12

	cat_count := has_modules ? len(Nav_Category) : len(Nav_Category) - 1
	nav_area := interface.Area{area.x + 6, y, max(area.width - 13, 1), cat_count * (SIDEBAR_ROW_HEIGHT + 2)}
	nav_id := interface.identity("settings nav")
	nav_res := interface.element_interact(frame, nav_id, nav_area, .List)
	if nav_res.focused {
		for &key in frame.input.keys[:frame.input.key_count] {
			if key.taken {
				continue
			}
			switch key.code {
			case display.KEY_UP:
				idx := (int(nav_category) + cat_count - 1) % cat_count
				nav_category = nav_categories[idx]
				view_scroll = 0
				changed = true
				key.taken = true
			case display.KEY_DOWN:
				idx := (int(nav_category) + 1) % cat_count
				nav_category = nav_categories[idx]
				view_scroll = 0
				changed = true
				key.taken = true
			}
		}
	}
	for i in 0 ..< cat_count {
		cat := nav_categories[i]
		row_area := interface.Area{nav_area.x, y + i * (SIDEBAR_ROW_HEIGHT + 2), nav_area.width, SIDEBAR_ROW_HEIGHT}
		interface.element_name(frame, row_area, nav_sidebar_labels[cat])
		hovered := frame.input.pointer_known && interface.area_contains(row_area, frame.input.pointer_x, frame.input.pointer_y)
		if hovered && frame.input.pressed {
			nav_category = cat
			view_scroll = 0
			changed = true
		}
		is_active := nav_category == cat
		if is_active {
			interface.draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, graphics.colors.track)
			interface.draw_rectangle(table, row_area.x, row_area.y + 4, 3, row_area.height - 8, graphics.colors.title)
		} else if hovered {
			interface.draw_rectangle(table, row_area.x, row_area.y, row_area.width, row_area.height, graphics.colors.card_top)
		}
		font := is_active ? interface.FONT_INTERFACE_BOLD : interface.FONT_INTERFACE
		shown := interface.text_fit(table, font, nav_sidebar_labels[cat], max(row_area.width - 18, 0))
		col := is_active ? graphics.colors.text_strong : (hovered ? graphics.colors.text : graphics.colors.dim)
		interface.draw_text(table, row_area.x + 12, row_area.y + (row_area.height - interface.LINE) / 2, shown, col, font)
	}
	if nav_res.focused {
		interface.draw_focus_ring(table, nav_area, u32(nav_id))
	}
	return changed
}

// Draw_Outcome says what a frame asks of the next one.
Draw_Outcome :: struct {
	draw_again: bool, // The view or navigation moved and needs an immediate redraw.
}

// draw builds the window from its layout tree at the size of the window
// now: sidebar/tab navigation, sections, scroll bar, slim status footer,
// right-click context menu, and Ctrl+K command palette.
draw :: proc "contextless" (window: ^display.Window) -> Draw_Outcome {
	// A refused page shows the defaults: a press writes a whole page again.
	choice, _ := settings.read(page)
	values := settings.values_of(choice)
	focus_before := window_memory.drawing.state.focus
	frame := interface.window_frame_start(&window_memory, window)
	tokens, _ := layout.tokens_for(graphics.appearance, .Standard)
	width, height := window.width, window.height
	discovered_snapshot := discovered_ui_sync()
	has_modules := discovered_snapshot.module_count > 0
	if !has_modules && nav_category == .Modules {
		nav_category = .All
	}
	outcome: Draw_Outcome

	// Handle Ctrl+K / Ctrl+Shift+P toggle and open overlay keys before widgets.
	for &key in frame.input.keys[:frame.input.key_count] {
		if key.taken {
			continue
		}
		if interface.is_command_palette_shortcut(key.code, key.character, key.modifiers) {
			key.taken = true
			if settings_palette.open {
				interface.command_palette_close(&settings_palette)
			} else {
				settings_palette_open(height, has_modules)
			}
			continue
		}
		if settings_palette.open {
			consumed, act := interface.command_palette_handle_key(&settings_palette, key.code, key.character, true, key.modifiers, height)
			if consumed {
				key.taken = true
			}
			if act != 0 && settings_menu_action_run(act, choice, height, has_modules) {
				outcome.draw_again = true
			}
			continue
		}
		if settings_ctx_menu.open {
			consumed, act := interface.context_menu_handle_key(&settings_ctx_menu, key.code, key.character, true, key.modifiers)
			if consumed {
				key.taken = true
			}
			if act != 0 && settings_menu_action_run(act, choice, height, has_modules) {
				outcome.draw_again = true
			}
		}
	}

	// Right-click opens compact settings context menu; open overlays take pointer first.
	if frame.input.right_pressed {
		frame.input.right_pressed = false
		settings_ctx_menu_open(frame.input.right_press_x, frame.input.right_press_y, width, height, has_modules)
	}
	if settings_palette.open {
		res := interface.command_palette_pointer(&settings_palette, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed, frame.input.wheel, width, height)
		if res.triggered && settings_menu_action_run(res.triggered_id, choice, height, has_modules) {
			outcome.draw_again = true
		}
		frame.input.pressed = false
		frame.input.released = false
		frame.input.wheel = 0
	} else if settings_ctx_menu.open {
		res := interface.context_menu_pointer(&settings_ctx_menu, frame.input.pointer_x, frame.input.pointer_y, frame.input.pressed)
		if res.triggered && settings_menu_action_run(res.triggered_id, choice, height, has_modules) {
			outcome.draw_again = true
		}
		frame.input.pressed = false
		frame.input.released = false
		frame.input.wheel = 0
	}

	interface.background(&frame, {0, 0, width, height})
	texts: Frame_Texts
	frame_texts_of(&texts, choice, display.windows_that_declined_the_scale())
	query := string(search_buf[:search_len])
	boxes, laid_out := settings_layout(frame.table, &texts, width, height, view_scroll, tokens, discovered_snapshot, nav_category, query)
	tree := &layout_tree
	footer_area := interface.Area{0, height - STATUS_FOOTER_HEIGHT, width, STATUS_FOOTER_HEIGHT}
	if laid_out {
		footer_area = area_of(tree, boxes.footer)
		if boxes.has_sidebar {
			if sidebar_draw(&frame, area_of(tree, boxes.sidebar), has_modules) {
				outcome.draw_again = true
			}
		} else {
			cat_count := has_modules ? len(Nav_Category) : len(Nav_Category) - 1
			tab_labels: [len(Nav_Category)]string
			for i in 0 ..< cat_count {
				tab_labels[i] = nav_category_labels[nav_categories[i]]
			}
			active_idx := int(nav_category)
			tab_res := interface.tab_bar(&frame, area_of(tree, boxes.compact_nav), interface.identity("settings tabs"), tab_labels[:cat_count], &active_idx)
			if tab_res.changed {
				nav_category = nav_categories[clamp(active_idx, 0, cat_count - 1)]
				view_scroll = 0
				outcome.draw_again = true
			}
		}

		view := area_of(tree, boxes.view)
		focus_area: interface.Area
		interface.draw_clip_push(frame.table, view.x, view.y, view.width, view.height)
		if boxes.store_note != layout.NO_BOX {
			note := area_of(tree, boxes.store_note)
			interface.draw_caption(&frame, note.x, note.y, note.width, STORE_NOTE)
		}
		for section in Section {
			if boxes.cards[section] == layout.NO_BOX {
				continue
			}
			interface.card(&frame, area_of(tree, boxes.cards[section]), section_titles[section], "", graphics.colors.kernel)
			for setting in settings_of_section(section) {
				setting_boxes := &boxes.setting_boxes[setting]
				locked := settings.setting_locked(kept_plan, setting)
				setting_header_draw(&frame, area_of(tree, setting_boxes.title), area_of(tree, setting_boxes.explanation), setting_texts[setting].title, setting_texts[setting].explanation, tokens, locked)
				if setting == .Scale {
					if boxes.scale_value != layout.NO_BOX {
						in_force := int(choice.scale) - int(min(scale_factor.Scale))
						text_on_button_line(&frame, area_of(tree, boxes.scale_value), setting_texts[.Scale].value_labels[clamp(in_force, 0, len(scale_factor.Scale) - 1)], tokens.text, interface.FONT_INTERFACE_BOLD)
					}
					scale_track_draw(&frame, area_of(tree, boxes.scale_track), choice, boxes.scale_value == layout.NO_BOX, &focus_area)
					if boxes.scale_declined != layout.NO_BOX {
						notice := area_of(tree, boxes.scale_declined)
						interface.draw_caption(&frame, notice.x, notice.y, notice.width, texts.declined_notice)
					}
					continue
				}
				if setting_boxes.control != layout.NO_BOX {
					ctrl_area := area_of(tree, setting_boxes.control)
					seg_res, chosen_place := setting_segmented(&frame, ctrl_area, setting, values, locked)
					if seg_res.focused {
						focus_area = ctrl_area
					}
					if seg_res.changed {
						if changed, changed_ok, _ := with_value(choice, setting, chosen_place); changed_ok {
							given: settings.Given
							given.values[setting] = true
							change(changed, choice.zone_offset_minutes, given)
						}
					}
				}
			}
			if section == .Region_And_Language {
				region_draw(&frame, &boxes, choice, &texts, tokens, &focus_area)
			}
		}
		for mod_idx in 0 ..< min(discovered_snapshot.module_count, DISCOVERED_MODULE_CAPACITY) {
			if boxes.discovered_cards[mod_idx].card != layout.NO_BOX {
				discovered_card_draw(&frame, mod_idx, &discovered_snapshot.modules[mod_idx], &boxes.discovered_cards[mod_idx], tokens, &focus_area)
			}
		}
		interface.draw_clip_pop(frame.table)
		view_scroll = 0
		if boxes.scroll_bar != layout.NO_BOX {
			scrolled := interface.scroll_bar(&frame, area_of(tree, boxes.scroll_bar), interface.identity("settings scroll bar"), .Vertical, {total = boxes.content_height, visible = view.height, first = boxes.scroll}, {line = interface.TABLE_LINE}, "settings", view)
			view_scroll = scrolled.first
			if scrolled.changed {
				outcome.draw_again = true
			}
			// Bring the focused element into view only when keyboard focus
			// actually moved, never fighting pointer or wheel scrolling.
			focus_moved := window_memory.drawing.state.focus != focus_before
			if focus_moved && focus_area.height > 0 && focus_area.y < view.y {
				view_scroll = max(view_scroll - (view.y - focus_area.y) - int(tokens.gap), 0)
				outcome.draw_again = true
				system.log_fact(.Info, View_Follows_Focus{first = u64(view_scroll)})
			} else if focus_moved && focus_area.height > 0 && focus_area.y + focus_area.height > view.y + view.height {
				view_scroll += focus_area.y + focus_area.height - view.y - view.height + int(tokens.gap)
				outcome.draw_again = true
				system.log_fact(.Info, View_Follows_Focus{first = u64(view_scroll)})
			}
		}
	}

	// Slim bottom status footer: store persistence badge on left, interactive Ctrl+K pill on right.
	interface.draw_rectangle(frame.table, footer_area.x, footer_area.y, footer_area.width, footer_area.height, graphics.colors.card_bottom)
	interface.draw_rectangle(frame.table, footer_area.x, footer_area.y, footer_area.width, 1, graphics.colors.track)
	badge_text := has_store ? "Kept in private store" : "Session only"
	badge_accent := has_store ? graphics.colors.process : graphics.colors.warning
	badge_w := min(interface.text_measured_width(frame.table, interface.FONT_CAPTION, badge_text) + 16, max(footer_area.width - 100, 0))
	if badge_w > 24 {
		interface.badge(&frame, {footer_area.x + 8, footer_area.y + 3, badge_w, 18}, badge_text, badge_accent)
	}
	pill_label := "Ctrl+K"
	pill_w := interface.text_measured_width(frame.table, interface.FONT_CAPTION, pill_label) + 14
	palette_pill_area = {footer_area.x + footer_area.width - STATUS_RIGHT_CLEARANCE - pill_w, footer_area.y + 3, pill_w, 18}
	if palette_pill_area.x > footer_area.x + badge_w + 16 {
		hot := !settings_ctx_menu.open && !settings_palette.open && frame.input.pointer_known && interface.area_contains(palette_pill_area, frame.input.pointer_x, frame.input.pointer_y)
		if hot && frame.input.pressed {
			settings_palette_open(height, has_modules)
			outcome.draw_again = true
		}
		interface.draw_rectangle(frame.table, palette_pill_area.x, palette_pill_area.y, palette_pill_area.width, palette_pill_area.height, hot ? graphics.shade(graphics.colors.track, 128) : graphics.colors.track)
		interface.draw_outline(frame.table, palette_pill_area.x, palette_pill_area.y, palette_pill_area.width, palette_pill_area.height, 1, hot ? graphics.colors.title : graphics.colors.not_usable)
		cap_y := palette_pill_area.y + (palette_pill_area.height - interface.line_height(interface.FONT_CAPTION)) / 2
		interface.draw_text(frame.table, palette_pill_area.x + 7, cap_y, pill_label, hot ? graphics.colors.text_strong : graphics.colors.dim, interface.FONT_CAPTION)
	}

	// Draw floating overlays last above all content.
	if settings_ctx_menu.open {
		interface.context_menu_draw(frame.table, &settings_ctx_menu)
	}
	if settings_palette.open {
		interface.command_palette_draw(frame.table, &settings_palette, width, height)
	}

	interface.window_frame_end(&window_memory.drawing, &frame, window)
	if frame.table.full && !table_full_logged {
		table_full_logged = true
		system.log_fact(.Warning, Frame_Table_Full{records = u64(len(window_memory.records_now)), text_bytes = u64(len(window_memory.text_now))})
	}
	if choice.change_count != drawn_change && drawn_change != 1 {
		system.log_fact(.Info, Values_Drawn{font = value_field(choice, .Font), subpixel_order = value_field(choice, .Subpixel_Order), pointer_theme = value_field(choice, .Pointer_Theme), grid_fit = value_field(choice, .Grid_Fit), keyboard_layout = value_field(choice, .Keyboard_Layout), appearance = value_field(choice, .Appearance), scale = value_field(choice, .Scale)})
	}
	drawn_change = choice.change_count
	return outcome
}

// DRAWS_AGAIN_MOST bounds the frames that one event draws: a frame whose
// view moved draws the next one at once, and the next one moves it no
// more unless the focus is past the view again.
DRAWS_AGAIN_MOST :: 3

// draw_with_bar draws a frame and redraws immediately when navigation,
// scrolling, or focus-following moved the view.
draw_with_bar :: proc "contextless" (window: ^display.Window) {
	outcome := draw(window)
	for _ in 0 ..< DRAWS_AGAIN_MOST {
		if !outcome.draw_again {
			break
		}
		outcome = draw(window)
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
// - **The boot pass** (the context value `VALUE_PASS` is `Boot`): it
//   reads the record of its store, writes the page, wakes the compositor,
//   writes "settings: the boot pass: ..." with its time, and stops with
//   `Done`. A missing or unreadable record gives the defaults. A record of
//   another version gives the defaults, which the pass keeps in its place.
//   A store that fails the read or refuses that write gives the defaults
//   too, and the pass stops with `Failed`.
// - **The next appearance** (`VALUE_PASS` is `Appearance_Next`): the tile
//   of the Control Center. It keeps and writes the appearance after the one
//   of the page (settings.appearance_next), and stops with `Done`, or with
//   `Failed` when the store did not keep it.
// - **A word that names no pass**: it writes its fact and stops with
//   `Refused`, with no write.
// - **Otherwise**: it opens its window (with none, it stops with `Failed`)
//   and its service, draws, and writes "settings: ok, ...". Then one loop
//   waits on the events of the window and on the service ring, runs the
//   calls, and draws after an event. It never stops by itself.
@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	page_handle := ctx.handles[settings.GRANT_PAGE]
	address, status := system.memory_map(page_handle)
	if status != .Succeeded {
		system.log_fact(.Info, No_Settings_Page{status = call_outcome.Call_Outcome_Word(status)})
		system.stop(system.stop_outcome_of_grant(page_handle, status))
	}
	page = (^settings.Page)(address)
	date_page = date.page_of(ctx)
	store, has_store = storage.open(ctx)
	if !has_store {
		system.log_fact(.Warning, No_Store{})
	}
	kept_plan, _ = system.plan_values_of_process(&ctx.values, &kept_plan_copy)
	pass, pass_ok := settings.pass_of_word(ctx.values[settings.VALUE_PASS])
	if !pass_ok {
		system.log_fact(.Warning, Pass_Refused{word = ctx.values[settings.VALUE_PASS]})
		system.stop(.Refused)
	}
	switch pass {
	case .Window:
		_ = kept_load()
	case .Boot:
		boot_pass()
	case .Appearance_Next:
		_ = kept_load()
		appearance_next_pass()
	}
	window, ok := display.open(ctx, WIDTH, HEIGHT, "settings")
	if !ok {
		system.stop(.Failed)
	}
	// The limits are constants of this process: a refusal is a fault of
	// this source, and a full ring a fault of the compositor; the line says
	// which, and the window keeps its size.
	if problem, sent := display.resizable_set(&window, {least_width = LEAST_WIDTH, least_height = LEAST_HEIGHT, largest_width = LARGEST_WIDTH, largest_height = LARGEST_HEIGHT}); problem != .None {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field(display.SIZE_LIMITS_PROBLEM_SENTENCES[problem], STAYS_FIXED_CAUSE_FIELD_BYTES)})
	} else if !sent {
		system.log_fact(.Info, Window_Stays_Fixed{cause = value_kinds.text_field("the command ring of the window is full", STAYS_FIXED_CAUSE_FIELD_BYTES)})
	}
	service, _ = system.service_open(ctx)
	discovered_start(ctx)
	draw_with_bar(&window)
	started, _ := settings.read(page)
	system.log_fact(.Info, Window_Ready{font = value_field(started, .Font), subpixel_order = value_field(started, .Subpixel_Order), pointer_theme = value_field(started, .Pointer_Theme), grid_fit = value_field(started, .Grid_Fit), keyboard_layout = value_field(started, .Keyboard_Layout), appearance = value_field(started, .Appearance), scale = value_field(started, .Scale)})
	discovered_seen := intrinsics.atomic_load_explicit(&discovered_dirty, .Acquire)
	for {
		wait := system.wait_begin()
		display.wait_events(&wait, &window)
		system.service_wait(&wait, &service)
		system.wait_word(&wait, &discovered_dirty, discovered_seen)
		deadline := appearance_edge_step(&wait)
		system.wait_end(&wait, deadline)
		system.service_run(&service)
		dirty_now := intrinsics.atomic_load_explicit(&discovered_dirty, .Acquire)
		discovered_changed := dirty_now != discovered_seen
		discovered_seen = dirty_now
		if interface.window_events(&window_memory.drawing, &window) || discovered_changed {
			draw_with_bar(&window)
		}
	}
}
