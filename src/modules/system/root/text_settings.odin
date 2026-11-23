package root

import "modus:contract/font_outlines"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:display"
import "modus:principals"
import "modus:system"

// The text of the system and the settings of the system (docs/FONTS.md):
// this service creates the settings page, checks the hash and the format
// of the font outlines of the boot image once, and maps the page and the
// outlines read-only into each process with a surface, into each terminal
// and into the compositor. Each process draws each glyph of its text from
// the outlines, into its private glyph cache. The process `settings`
// receives the page with Write. The boot display that this service draws
// reads no font file: its text is Spleen at the size of its scale
// (src/md/features/boot_display_scale.md).
//
// At the end of the boot this service starts `settings` for its boot pass:
// it reads the settings kept in its private store and writes the page; the
// compositor sees the change and each window draws again.

settings_memory: system.Handle
// The font outlines of the boot image: page_count 0 when the image has
// none, or none that font_outlines.validate accepts.
font_outlines_mapping: system.Mapping
// The pass of the next start of `settings`: start() gives it in the value
// VALUE_PASS. Window for each start that opens its window.
settings_pass: settings.Pass
// The process of the last pass that this service started, by its serial:
// a slot of the table is used again, a serial is not. 0: none.
settings_pass_process_serial: u64
settings_pass_running_pass: settings.Pass

// text_settings_create makes the settings page and finds the font
// outlines. It writes the initial defaults before any process starts and
// immediately unmaps its writable mapping so `settings` is the sole writer
// of the settings page. Font outlines are given only when their format is
// valid; their hash was checked with the whole image (trust_check): a resource shorter
// than its header, or whose header states another size than the resource,
// is not given, so a process that reads the size in the header reads only
// mapped bytes. With no outlines, each process draws with Spleen 8x16, and
// the log says why.
text_settings_create :: proc "contextless" () {
	status: system.Status
	settings_memory, status = system.memory_create(1)
	address: rawptr
	if status == .Ok {
		address, status = system.memory_map(settings_memory)
	}
	if status != .Ok {
		fail("cannot create the settings page", status)
	}
	// The defaults before any process maps the page: the word 0 names no
	// scale, so an all-zero page would be refused by each reader until the
	// boot pass of `settings` writes it. Unmap right away so this service
	// never writes the page again.
	settings.page_defaults_write((^settings.Page)(address))
	system.memory_unmap(address)
	if mapping, _, given := resource_mapping(font_outlines.RESOURCE_NAME, font_outlines.ADDRESS, "each process with a surface"); given {
		entry := system.image_resource_find(image, font_outlines.RESOURCE_NAME)
		if _, problem := font_outlines.validate(image[entry.offset:][:entry.size]); problem.kind == .None {
			font_outlines_mapping = mapping
		} else {
			system.log_fact(.Warning, Font_Outlines_Refused{problem_value = problem.value, problem = text_field(font_outlines.problem_sentences[problem.kind], 80)})
		}
	}
	if font_outlines_mapping.page_count == 0 {
		system.log_fact(.Warning, Font_Outlines_Absent{})
	}
}

// text_settings_give adds the settings page and the font outlines,
// read-only, to the mappings of a process that has a surface or a
// terminal, and sets the bit of each range in its values. The mapping of
// the outlines has no flag: the right Read only, for every process, the
// process `settings` included. Its pages come from the boot image, whose
// one handle (of this service) has no right Write.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values) {
	if settings_memory == 0 {
		return
	}
	// The page and the outlines.
	if count^ + 2 > len(mappings) {
		mapping_dropped_log("the settings page and the font outlines", len(mappings))
		return
	}
	mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
	count^ += 1
	system.range_mapped_put(values, .Settings_Page)
	if font_outlines_mapping.page_count != 0 {
		mappings[count^] = font_outlines_mapping
		mappings[count^].flags = {}
		count^ += 1
		system.range_mapped_put(values, .Font_Outlines)
	}
}

// settings_boot_pass_start starts `settings` for its boot pass: it reads
// the settings kept in its private store, writes the page, and stops. The
// storage service starts first, with the block service of the data disk.
// A machine with no data disk keeps the defaults. A start policy asks for
// it, as the row settings of its list, and gets the status.
settings_boot_pass_start :: proc "contextless" () -> system.Status {
	status := settings_pass_start(.Boot, principals.MACHINE)
	if status != .Ok {
		system.log_fact(.Warning, Settings_Boot_Pass_Failed{status = status})
	}
	return status
}
// settings_pass_start starts `settings` for a pass and keeps the serial
// of its process, so that settings_running finds the pass that runs.
settings_pass_start :: proc "contextless" (pass: settings.Pass, principal: u64) -> system.Status {
	place: ^Started
	settings_pass = pass
	status := start("settings", principal, place = &place)
	settings_pass = .Window
	if status == .Ok && place != nil {
		settings_pass_process_serial = place.process_serial
		settings_pass_running_pass = pass
	}
	return status
}

// settings_running finds the process `settings` that runs, a terminal
// apart (it has the name of its process), and the pass that it runs.
settings_running :: proc "contextless" () -> (item: ^Started, pass: settings.Pass) {
	for &candidate in started {
		if candidate.process == 0 || candidate.is_terminal || system.name_of(candidate.name[:]) != "settings" {
			continue
		}
		if settings_pass_process_serial != 0 && candidate.process_serial == settings_pass_process_serial {
			return &candidate, settings_pass_running_pass
		}
		item, pass = &candidate, .Window
	}
	return
}

// A start of the window of `settings` that came while a pass ran: it goes
// when the pass stops (settings_start_due_step), in the session that asked.
settings_start_due: bool
settings_start_due_principal: u64

// settings_start_allowed is the one-writer check of start() for each start
// of `settings`, whoever asks (settings.start_answer): the pass asked is
// settings_pass. It gives true when the start goes on. Otherwise it did
// the answer, so that two processes `settings` never run: it asked the
// compositor to raise the window that runs, or kept the start of a window
// due until the pass stops, or refused a pass; each with its fact.
settings_start_allowed :: proc "contextless" (principal: u64) -> bool {
	item, pass := settings_running()
	switch settings.start_answer(settings_pass, item != nil, pass) {
	case .Start:
		return true
	case .Raise_Window:
		if settings_raise_ask(item, .Keep) {
			system.log_fact(.Info, Settings_Start_Raises_Window{})
		}
	case .Raise_Window_At_Appearance:
		if settings_raise_ask(item, .Appearance) {
			system.log_fact(.Info, Appearance_Next_Raises_Settings{})
		}
	case .Wait_For_Pass:
		settings_start_due, settings_start_due_principal = true, principal
		system.log_fact(.Info, Settings_Start_Waits_For_Pass{})
	case .Refuse:
		system.log_fact(.Info, Settings_Pass_Refused_Settings_Runs{})
	}
	return false
}

// settings_raise_ask asks the compositor to raise the window of the process
// `settings` that runs, with the focus where the ask needs it. A full ring
// raises nothing, with its fact: the next ask asks again.
settings_raise_ask :: proc "contextless" (item: ^Started, focus: display.Settings_Raise_Focus) -> (sent: bool) {
	if !system.send(&control.commands, ring.Record{kind = u32(display.Control.Settings_Raise), values = {0 = u64(item.client), 1 = u64(focus)}}) {
		system.log_fact(.Warning, Settings_Raise_Ring_Full{})
		return false
	}
	return true
}

// settings_start_due_step starts the window of `settings` that waited for
// a pass, once no process `settings` runs. The loop calls it after reap.
settings_start_due_step :: proc "contextless" () {
	if !settings_start_due {
		return
	}
	if item, _ := settings_running(); item != nil {
		return
	}
	settings_start_due = false
	if status := start("settings", settings_start_due_principal); status != .Ok {
		system.log_fact(.Warning, Settings_Due_Start_Failed{status = status})
	}
}

// settings_appearance_next_start takes the press on the tile Appearance
// of the Control Center: start() decides (settings_start_allowed). It
// starts `settings` for the next appearance in the session of the
// desktop, or asks the compositor to raise the window of `settings` that
// runs, the one writer of the page, or refuses while a pass runs.
settings_appearance_next_start :: proc "contextless" () {
	if status := settings_pass_start(.Appearance_Next, desktop_principal()); status != .Ok && status != .Bad_State {
		system.log_fact(.Warning, Appearance_Next_Not_Started{status = status})
	}
}
