package root

import "modus:contract/root_ring"
import "modus:contract/call_outcome"
import "modus:contract/enum_word"
import "modus:contract/ring"
import "modus:contract/settings"
import "modus:display"
import "modus:principals"
import "modus:system"

// The text settings of the system (docs/FONTS.md): this service creates the
// settings page and maps the page (or each window's presentation page) into
// each process with a surface, each terminal, and the compositor. Processes
// map font outlines and script fonts read-only through storage.map_object
// under their granted "fonts" tree. The process `settings` receives the
// settings page with Write. The boot display that this service draws reads no
// font file: its text is Spleen at the size of its scale
// (src/md/features/boot_display_scale.md).
//
// At the end of the boot this service starts `settings` for its boot pass:
// it reads the settings kept in its private store and writes the page; the
// compositor sees the change and each window draws again.

settings_memory: system.Handle
// The pass of the next start of `settings`: start() gives it in the value
// VALUE_PASS. Window for each start that opens its window.
settings_pass: settings.Pass
// The process of the last pass that this service started, by its kernel
// (slot, serial) pair: a serial starts at 1 for each fresh slot, so both
// slot and serial are required to name one process uniquely. 0: none.
settings_pass_process_slot: u64
settings_pass_process_serial: u64
settings_pass_running_pass: settings.Pass

// text_settings_create makes the settings page and reads the default script
// font hash from the boot image. It writes the initial defaults before any
// process starts and immediately unmaps its writable mapping so `settings` is
// the sole writer of the settings page.
text_settings_create :: proc "contextless" () {
	status: call_outcome.Call_Outcome
	settings_memory, status = system.memory_create(1)
	address: rawptr
	if status == .Succeeded {
		address, status = system.memory_map(settings_memory)
	}
	if status != .Succeeded {
		fail("cannot create the settings page", status)
	}
	// The defaults before any process maps the page: the word 0 names no
	// scale, so an all-zero page would be refused by each reader until the
	// boot pass of `settings` writes it. Unmap right away so this service
	// never writes the page again.
	settings.page_defaults_write((^settings.Page)(address))
	system.memory_unmap(address)
	script_fonts_name_read()
}

// Where the text settings of a process come from.
Text_Settings_Page :: enum u8 {
	Presentation, // A page of its own, that its display library writes from the presentation record (presentation_pages.odin): each window.
	Machine, // The settings page of the machine, read-only: `settings`, the date service and the holder of the display.
}

// text_settings_give adds the page of the text settings to the mappings of a
// process that has a surface or a terminal, and sets the bit of its range in
// its values. A window gets its own presentation page (item is its place); a
// holder that applies the settings of the machine gets the settings page,
// read-only.
text_settings_give :: proc "contextless" (mappings: []system.Mapping, count: ^int, values: ^system.Context_Values, page: Text_Settings_Page, item: ^Started = nil) {
	if settings_memory == 0 {
		return
	}
	if count^ + 1 > len(mappings) {
		mapping_dropped_log("the settings page", len(mappings))
		return
	}
	switch page {
	case .Presentation:
		if item != nil {
			presentation_page_give(item, mappings, count, values)
		}
	case .Machine:
		mappings[count^] = {memory = settings_memory, address = settings.PAGE_ADDRESS, first = 0, page_count = 1}
		count^ += 1
		system.range_mapped_put(values, .Settings_Page)
	}
}

settings_boot_pass_started: bool

// settings_boot_pass_start starts the holder of the role Settings for its
// boot pass: `settings` reads the settings kept in its private store,
// writes the page, and stops. The storage service starts first, with the
// block service of the data disk. A machine with no data disk keeps the
// defaults. A start policy asks for it, as the row settings of its list,
// and gets the outcome, with the record of a refusal in values. The row
// names the role, so it reaches the holder that the plan of principal 0
// gave, as each other row of a role does.
settings_boot_pass_start :: proc "contextless" (values: ^[7]u64) -> call_outcome.Call_Outcome {
	settings_boot_pass_started = true
	decision, outcome := settings_pass_start(.Boot, principals.MACHINE, values)
	switch decision {
	case .Start:
		if outcome != .Succeeded {
			system.log_fact(.Warning, Settings_Boot_Pass_Failed{outcome = outcome})
		}
		return outcome
	case .Raised, .Waits, .Refused:
		// Another process settings runs and writes the page: its fact said
		// so, and the start policy gets a refusal of the moment.
	}
	return root_ring.refuse(values, .Callee_Busy, u32(root_ring.Root_Command.Start), .Busy, .Processes, 1, 1, 1)
}

// settings_pass_start decides a start of `settings` for a pass, then
// starts it when the decision is Start, and keeps the serial of its
// process, so that settings_running finds the pass that runs. status is
// the outcome of the start, Succeeded with any other decision; a refusal
// writes its record in refusal, when the caller gives one.
settings_pass_start :: proc "contextless" (pass: settings.Pass, principal: u64, refusal: ^[7]u64 = nil) -> (decision: Settings_Start_Decision, outcome: call_outcome.Call_Outcome) {
	settings_pass = pass
	defer settings_pass = .Window
	if decision = settings_start_decide(principal, .Other); decision != .Start {
		return decision, .Succeeded
	}
	place: ^Started
	outcome = start(role_holder_name(.Settings), principal, place = &place, refusal = refusal)
	if outcome == .Succeeded && place != nil {
		settings_pass_process_slot = place.process_slot
		settings_pass_process_serial = place.process_serial
		settings_pass_running_pass = pass
	}
	return .Start, outcome
}

// settings_window_start takes Control.Start of `settings` from the desktop:
// the one start of the window that waits for a pass that runs, so that a
// press of the principal is not lost.
settings_window_start :: proc "contextless" (principal: u64, budget_unbounded := false) {
	if settings_start_decide(principal, .Desktop, budget_unbounded) == .Start {
		start(role_holder_name(.Settings), principal, budget_unbounded = budget_unbounded)
	}
}

// settings_running finds the process `settings` that runs, a terminal
// apart (it has the name of its process), and the pass that it runs.
settings_running :: proc "contextless" () -> (item: ^Started, pass: settings.Pass) {
	for &candidate in started {
		if candidate.process == 0 || candidate.is_terminal || !is_role_holder(system.name_of(candidate.name[:]), .Settings) {
			continue
		}
		if settings_pass_process_slot != 0 && settings_pass_process_serial != 0 &&
		   candidate.process_slot == settings_pass_process_slot && candidate.process_serial == settings_pass_process_serial {
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
settings_start_due_budget_unbounded: bool
// A keyboard layout hint from the display holder (for example the browser
// machine host) waiting for the boot pass or another settings pass to finish.
settings_keyboard_layout_due: bool
settings_keyboard_layout_due_pass: settings.Pass

// Who asks a start of `settings`: the desktop, whose start of the window
// waits for a pass that runs, or another caller (a connection to the
// service, a start policy, the debugger, a pass), which is refused then.
Settings_Asker :: enum u8 {
	Other,
	Desktop,
}

// What a decision on a start of `settings` did. Only Start starts a
// process; each other one answered with its fact, and starts none.
Settings_Start_Decision :: enum u8 {
	Start, // No process settings runs: the start goes on.
	Raised, // A window runs: the compositor raises it.
	Waits, // A pass runs, and the desktop asked the window: it starts when the pass stops.
	Refused, // Another process settings runs, and the ask cannot wait.
}

// settings_start_decide is the one-writer check for each start of
// `settings` (settings.start_answer): the pass asked is settings_pass.
// So that two processes `settings` never run, an answer other than Start
// asks the compositor to raise the window that runs, keeps the start of
// the window of the desktop due until the pass stops, or refuses; each with
// its fact. start() calls it for each caller; a caller that decides first
// gets Start again from start(), since Start does nothing.
settings_start_decide :: proc "contextless" (principal: u64, asker: Settings_Asker, budget_unbounded := false) -> Settings_Start_Decision {
	item, pass := settings_running()
	switch settings.start_answer(settings_pass, item != nil, pass) {
	case .Start:
		return .Start
	case .Raise_Window:
		if settings_raise_ask(item, .Keep) {
			system.log_fact(.Info, Settings_Start_Raises_Window{})
		}
		return .Raised
	case .Raise_Window_At_Appearance:
		if settings_raise_ask(item, .Appearance) {
			system.log_fact(.Info, Appearance_Next_Raises_Settings{})
		}
		return .Raised
	case .Wait_For_Pass:
		switch asker {
		case .Desktop:
			settings_start_due = true
			settings_start_due_principal = principal
			settings_start_due_budget_unbounded = budget_unbounded
			system.log_fact(.Info, Settings_Start_Waits_For_Pass{})
			return .Waits
		case .Other:
			system.log_fact(.Info, Settings_Start_Refused_Pass_Runs{})
			return .Refused
		}
	case .Refuse:
		system.log_fact(.Info, Settings_Pass_Refused_Settings_Runs{})
		return .Refused
	}
	return .Refused
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

// settings_start_due_step starts a pending keyboard layout pass or the window
// of `settings` that waited for a pass, once no process `settings` runs.
// The loop calls it after reap.
settings_start_due_step :: proc "contextless" () {
	if item, _ := settings_running(); item != nil {
		return
	}
	if settings_keyboard_layout_due && (settings_boot_pass_started || start_policy_running() == nil) {
		pass := settings_keyboard_layout_due_pass
		settings_keyboard_layout_due = false
		decision, outcome := settings_pass_start(pass, desktop_principal())
		if decision == .Start && outcome != .Succeeded {
			system.log_fact(.Warning, Keyboard_Layout_Hint_Not_Started{outcome = outcome})
		}
		return
	}
	if !settings_start_due {
		return
	}
	settings_start_due = false
	due_unbounded := settings_start_due_budget_unbounded
	settings_start_due_budget_unbounded = false
	if outcome := start(role_holder_name(.Settings), settings_start_due_principal, budget_unbounded = due_unbounded); outcome != .Succeeded {
		system.log_fact(.Warning, Settings_Due_Start_Failed{outcome = outcome})
	}
}

// settings_keyboard_layout_from_control validates a Keyboard_Layout_Set control
// record from the display holder and starts or queues the one-shot settings
// pass after the boot pass so settings remains the single writer of the page.
settings_keyboard_layout_from_control :: proc "contextless" (values: [7]u64) -> bool {
	for index in 1 ..< len(values) {
		if values[index] != 0 {
			return false
		}
	}
	layout, ok := enum_word.member_of_word(settings.Keyboard_Layout, values[0])
	if !ok {
		return false
	}
	pass: settings.Pass
	switch layout {
	case .United_States:
		pass = .Keyboard_Layout_US
	case .French:
		pass = .Keyboard_Layout_French
	}
	if (!settings_boot_pass_started && start_policy_running() != nil) {
		settings_keyboard_layout_due = true
		settings_keyboard_layout_due_pass = pass
		return true
	}
	if item, running_pass := settings_running(); item != nil {
		if running_pass != .Window {
			settings_keyboard_layout_due = true
			settings_keyboard_layout_due_pass = pass
		}
		return true
	}
	decision, outcome := settings_pass_start(pass, desktop_principal())
	if decision == .Start && outcome != .Succeeded {
		system.log_fact(.Warning, Keyboard_Layout_Hint_Not_Started{outcome = outcome})
	}
	return true
}

// settings_appearance_next_start takes the press on the tile Appearance
// of the Control Center (settings_start_decide): it starts `settings` for
// the next appearance in the session of the desktop, or asks the
// compositor to raise the window of `settings` that runs, the one writer of
// the page, or refuses while a pass runs.
settings_appearance_next_start :: proc "contextless" () {
	decision, outcome := settings_pass_start(.Appearance_Next, desktop_principal())
	if decision == .Start && outcome != .Succeeded {
		system.log_fact(.Warning, Appearance_Next_Not_Started{outcome = outcome})
	}
}