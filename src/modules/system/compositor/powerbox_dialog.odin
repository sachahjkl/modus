// Unforgeable trusted-display Powerbox grant dialog, trusted Store Picker,
// and Wide-Grant active bar mark inside the compositor
// (src/md/features/powerbox.md) and (src/md/features/wide_grants.md).
//
// Drawn directly by the Display role holder above every client window so no
// process can spoof, cover, or click-jack a grant approval, and while a wide
// agent grant is active an unforgeable mark stays visible in the bar and
// revokes immediately on Ctrl+Shift+Escape.
package compositor

import "base:intrinsics"
import "internal:compositor/bar"
import "modus:contract/enum_word"
import op "modus:contract/operation"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/value_kinds"
import "modus:display"
import "modus:graphics"
import "modus:interface"
import "modus:system"

POWERBOX_DIALOG_WIDTH :: 440
POWERBOX_DIALOG_HEIGHT :: 160
POWERBOX_TEXT_LIMIT :: 96
POWERBOX_PICKER_SLOTS :: 4 // The rows of the list that show at once: the list scrolls past them.
POWERBOX_TITLE_HEIGHT :: 30 // The title plate, inside the two lines of the frame.
POWERBOX_MARGIN :: 16 // From the frame to the texts, the list and the buttons.
POWERBOX_PICKER_LINE :: 24
POWERBOX_PICKER_ROOM :: POWERBOX_PICKER_SLOTS * POWERBOX_PICKER_LINE + 12 // The list and the room around it.
POWERBOX_BUTTON_HEIGHT :: 26
POWERBOX_BUTTON_PADDING :: 12 // On each side of the text of a button.
POWERBOX_BUTTON_GAP :: 8 // Between two buttons, and between the act and its key in one button.

Powerbox_Prompt_State :: struct {
	open:            bool,
	request_id:      u64,
	kind:            powerbox.Request_Item_Kind,
	process_name:    [POWERBOX_TEXT_LIMIT]u8,
	process_len:     int,
	resource_text:   [POWERBOX_TEXT_LIMIT]u8,
	resource_len:    int,
	// The place of the chosen store in the whole list of the principal,
	// and the first row that shows: the list follows the chosen row. The
	// names come from the powerbox by pages (powerbox_picker.odin).
	picker_selected: int,
	picker_first:    int,
	last_decision:   powerbox.Item_Decision,
	shown_milliseconds: u64, // When the dialog showed: a grant counts only after the arm time of the principal.
}


powerbox_prompt: Powerbox_Prompt_State
powerbox_next_id: u64 = 1
// The requested grants that the principal kept and that hold: the menu of
// the windows lists them under the window of their process.
window_grants: bar.Window_Grant_Table
plan_difference_dialog: bar.Plan_Difference_Dialog

// trusted_dialog_open reports whether a dialog of the trusted display
// shows: one at a time, so a key or a press acts on the one that the
// principal sees.
trusted_dialog_open :: proc "contextless" () -> bool {
	return powerbox_prompt.open || plan_difference_dialog.open || wide_grant_trusted_surface_open()
}

powerbox_prompt_open :: proc "contextless" (kind: powerbox.Request_Item_Kind, process_name, resource_text: string, principal: u64 = 0) -> u64 {
	if len(process_name) == 0 || len(resource_text) == 0 {
		return 0
	}
	// The dialog takes the keys: the card of the switcher closes.
	window_switcher_cancel() // window_switcher.odin
	id := powerbox_next_id
	powerbox_next_id += 1
	powerbox_prompt = {
		open          = true,
		request_id    = id,
		kind          = kind,
		process_len   = min(len(process_name), POWERBOX_TEXT_LIMIT),
		resource_len  = min(len(resource_text), POWERBOX_TEXT_LIMIT),
		last_decision = .None,
		shown_milliseconds = system.time(),
	}
	if kind == .Store_Share {
		// The stores of the principal, from the powerbox, shown only to the
		// principal on the trusted display: the requesting process never
		// sees the list.
		powerbox_picker_open(principal)
	}
	copy(powerbox_prompt.process_name[:powerbox_prompt.process_len], process_name[:powerbox_prompt.process_len])
	copy(powerbox_prompt.resource_text[:powerbox_prompt.resource_len], resource_text[:powerbox_prompt.resource_len])
	damage_whole_screen()
	return id
}

powerbox_prompt_decide :: proc "contextless" (allow: bool) -> bool {
	if !powerbox_prompt.open {
		return false
	}
	// The arm time of the principal holds for this door as for the
	// difference of a plan: a grant before it is no act, and the dialog takes
	// the key. A refusal counts at once: it gives nothing.
	if allow && !powerbox.consent_armed(powerbox_prompt.shown_milliseconds, system.time(), display_choices_in_force.consent_arm_milliseconds) {
		return true
	}
	if powerbox_prompt.kind == .Store_Share {
		// A share needs a store that the powerbox checks: the prompt waits
		// for its answer (powerbox_prompt_picked). With no store to pick,
		// Allow does nothing.
		if allow {
			powerbox_picker_pick(powerbox_prompt.picker_selected)
			return true
		}
		powerbox_picker_close()
	}
	powerbox_prompt.open = false
	powerbox_prompt.last_decision = allow ? .Granted : .Refused
	if allow {
		window_grant_add(string(powerbox_prompt.process_name[:powerbox_prompt.process_len]), string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len]), "")
	}
	damage_whole_screen()
	return true
}

// powerbox_prompt_picked takes the answer of the powerbox to a pick: the
// grant holds only when the powerbox found the store at its place in its
// copy of the list. A refusal closes the prompt with nothing granted: the
// list changed, and the principal asks again.
powerbox_prompt_picked :: proc "contextless" (accepted: bool, store: string) {
	if !powerbox_prompt.open || powerbox_prompt.kind != .Store_Share {
		return
	}
	powerbox_prompt.open = false
	powerbox_prompt.last_decision = accepted ? .Granted : .Refused
	if accepted {
		window_grant_add(string(powerbox_prompt.process_name[:powerbox_prompt.process_len]), string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len]), store)
	}
	damage_whole_screen()
}

// window_grant_add records a grant that the principal kept, so the menu
// of the windows lists it. A store names the store that the principal
// picked, then the mode that the process asked for.
window_grant_add :: proc "contextless" (process_name, resource_text, chosen_store: string) {
	resource_bytes: [bar.WINDOW_GRANT_RESOURCE_BYTES + 1]u8 // One more byte: a name past the bound is refused, not cut.
	resource := resource_text
	if len(chosen_store) > 0 {
		length := copy(resource_bytes[:], chosen_store)
		length += copy(resource_bytes[length:], ", ")
		length += copy(resource_bytes[length:], resource_text)
		resource = string(resource_bytes[:length])
	}
	grant_id, refusal := bar.window_grant_record(&window_grants, process_name, resource)
	if refusal != .None {
		system.log_fact(.Warning, Window_Grant_Not_Listed{window = value_kinds.module_name_field(process_name)})
		return
	}
	system.log_fact(.Info, Window_Grant_Recorded{grant = grant_id, resource = value_kinds.text_field(resource, GRANT_RESOURCE_FIELD_BYTES), window = value_kinds.module_name_field(process_name)})
	windows_menu_rows_build() // start_menu.odin
}

// window_grant_revoke ends a requested grant that the menu of the windows
// lists, and gives false when no grant of that number holds. A revocation
// only takes authority away: the trusted display does it at once.
window_grant_revoke :: proc "contextless" (grant_id: u64) -> bool {
	revoked, ok := bar.window_grant_revoke(&window_grants, grant_id)
	if !ok {
		return false
	}
	system.log_fact(.Info, Window_Grant_Revoked{grant = revoked.grant_id, resource = value_kinds.text_field(bar.window_grant_resource(&revoked), GRANT_RESOURCE_FIELD_BYTES), window = value_kinds.module_name_field(bar.window_grant_process(&revoked))})
	windows_menu_rows_build() // start_menu.odin
	return true
}

// window_grants_window_closed ends the grants of the process of a window
// that closed: a grant for this run ends with its process, and a later
// process of the same name must not find them in the menu.
window_grants_window_closed :: proc "contextless" (process_name: string) {
	if ended := bar.window_grants_end_of_process(&window_grants, process_name); ended > 0 {
		system.log_fact(.Info, Window_Grants_Ended{grants = u64(ended), window = value_kinds.module_name_field(process_name)})
	}
}

// The memory of the difference that shows: a copy of the two sides that
// the asker gave, and the items of the dialog. A difference has any count
// of items, so the arena reserves the pages of the budget of the
// compositor and commits them as a difference needs them; the next
// difference starts it again.
plan_difference_arena: system.Arena

// The pages of the budget of the compositor that a difference never takes:
// the windows, the palette and the frames keep their room whatever the
// size of a difference.
PLAN_DIFFERENCE_KEPT_PAGES :: 2048

// plan_difference_push takes bytes of the arena when the budget keeps its
// margin after the exact pages of the push.
@(private = "file")
plan_difference_push :: proc "contextless" (bytes, alignment: u64) -> (address: rawptr, ok: bool) {
	pages, fits := system.arena_push_commit_pages(&plan_difference_arena, bytes, alignment)
	amounts, status := system.budget_read()
	if !fits || status != .Ok || amounts.pages < PLAN_DIFFERENCE_KEPT_PAGES || pages > amounts.pages - PLAN_DIFFERENCE_KEPT_PAGES {
		return nil, false
	}
	pushed, push_status := system.arena_push(&plan_difference_arena, bytes, alignment)
	return pushed, push_status == .Ok
}

// plan_difference_memory_step gives the pages of a difference back to the
// budget once its dialog closed: a large difference holds its pages only
// while the principal reads it.
plan_difference_memory_step :: proc "contextless" () {
	plan_difference_reading_step()
	if !plan_difference_dialog.open && plan_reading_stage() == .Idle && plan_difference_arena.used_bytes > 0 {
		system.arena_trim(&plan_difference_arena, 0)
	}
}

// The reading of a difference on the worker of the compositor. stage is
// the one word that the two threads share: the interface thread writes
// Requested with each field of the job, the worker reads the object and
// writes Published with its reading, and the interface thread adopts it
// and writes Idle. The arena of the difference belongs to the worker
// while the stage is Requested, and to the interface thread else.
Plan_Reading_Stage :: enum u32 {
	Idle      = 0,
	Requested = 1,
	Published = 2,
}

Plan_Reading_Job :: struct {
	stage:         u32,
	serial:        u64,
	memory:        system.Handle, // The object of the two sides, which this process holds with Read until the reading ends.
	added_bytes:   int,
	removed_bytes: int,
	read:          bar.Plan_Difference_Read,
}

plan_reading: Plan_Reading_Job
plan_difference_worker_running: bool

// plan_difference_worker_start starts the thread that reads each
// difference. With none, a difference is refused with Busy.
plan_difference_worker_start :: proc "contextless" () {
	if _, status := system.thread_start(plan_difference_worker, nil); status == .Ok {
		plan_difference_worker_running = true
	}
}

@(private = "file")
plan_reading_stage :: proc "contextless" () -> Plan_Reading_Stage {
	word := intrinsics.atomic_load_explicit(&plan_reading.stage, .Acquire)
	stage, ok := enum_word.member_of_word(Plan_Reading_Stage, u64(word))
	return ok ? stage : .Idle
}

@(private = "file")
plan_reading_stage_set :: proc "contextless" (stage: Plan_Reading_Stage) {
	intrinsics.atomic_store_explicit(&plan_reading.stage, u32(stage), .Release)
	system.word_wake(&plan_reading.stage)
}

@(private = "file")
plan_reading_take :: proc "contextless" (_: rawptr, bytes, alignment: int) -> rawptr {
	address, ok := plan_difference_push(u64(bytes), u64(alignment))
	return ok ? address : nil
}

// plan_reading_copy copies the object of the job through the kernel
// (system.memory_read), never through a mapping: the caller made the
// object, and a page with no frame or a revocation during the read is
// then a status, where a read through a mapping would fault and stop the
// trusted display.
@(private = "file")
plan_reading_copy :: proc "contextless" (_: rawptr, into: []u8) -> bool {
	_, status := system.memory_read(plan_reading.memory, 0, into)
	return status == .Ok
}

// plan_difference_worker is the entry of the thread of the readings: it
// copies the object into the arena of the difference and parses it there
// (bar.plan_difference_read), and publishes the reading. Its work is in
// proportion to the difference, so it never runs on the interface thread.
plan_difference_worker :: proc "c" (_: rawptr) -> ! {
	for {
		system.word_wait(&plan_reading.stage, u32(Plan_Reading_Stage.Idle))
		if plan_reading_stage() != .Requested {
			// Published waits for the interface thread.
			system.word_wait(&plan_reading.stage, u32(Plan_Reading_Stage.Published))
			continue
		}
		read := bar.Plan_Difference_Read{refusal = .Too_Many_Items, argument = 2}
		if plan_difference_arena.base == nil {
			if amounts, budget_status := system.budget_read(); budget_status == .Ok {
				if arena, arena_status := system.arena_create(system.arena_reservation_pages(amounts.pages)); arena_status == .Ok {
					arena.exact_commits = true
					plan_difference_arena = arena
				}
			}
		}
		if plan_difference_arena.base != nil {
			system.arena_reset(&plan_difference_arena)
			source := bar.Plan_Difference_Source{bytes = plan_reading.added_bytes + plan_reading.removed_bytes, copy = plan_reading_copy}
			read = bar.plan_difference_read(source, plan_reading.added_bytes, plan_reading.removed_bytes, {take = plan_reading_take})
		}
		plan_reading.read = read
		plan_reading_stage_set(.Published)
	}
}

// plan_difference_show checks the object of a difference at its border
// and opens its dialog in its reading state; the worker reads it. It gives
// the serial, or 0 with the refusal and its argument, from 1: the name,
// the object. memory is the handle as this process names it, which the
// caller gave through the call ring of its connection: each refusal
// closes it, and the end of the reading too.
plan_difference_show :: proc "contextless" (plan_name: string, memory: system.Handle, added_bytes, removed_bytes: i64) -> (serial: u64, refusal: bar.Plan_Difference_Refusal, argument: int) {
	caller := system.service_caller()
	kind := op.Object_Kind.None
	rights: system.Rights
	through := false
	if caller != nil && memory != 0 {
		kind, rights, through = system.handle_state(memory, caller.ring_memory)
	}
	// Only a handle that came through the ring of this caller is this
	// process's to close: a number of another handle is no handle of it.
	defer if refusal != .None && through {
		system.close(memory)
	}
	pages: u64
	flags: op.Memory_Flags
	if through && kind == .Memory {
		pages, flags, _ = system.memory_size_and_flags(memory)
	}
	if refusal = bar.plan_difference_object_check(kind, rights, through, pages, flags, added_bytes, removed_bytes); refusal != .None {
		return 0, refusal, 2
	}
	// One trusted dialog at a time: the screen of a wide grant, and a
	// screen that waits for its turn, go first.
	if powerbox_prompt.open || wide_grant_trusted_surface_open() || wide_grant_screen_waits || !plan_difference_worker_running || plan_reading_stage() != .Idle {
		return 0, .Busy, 0
	}
	serial, refusal, argument = bar.plan_difference_reading_open(&plan_difference_dialog, plan_name, system.time())
	if refusal != .None {
		return
	}
	// The fields of the job, then the stage: the worker reads them after it.
	plan_reading.serial, plan_reading.memory = serial, memory
	plan_reading.added_bytes, plan_reading.removed_bytes = int(added_bytes), int(removed_bytes)
	plan_reading.read = {}
	plan_reading_stage_set(.Requested)
	window_switcher_cancel() // window_switcher.odin: the dialog takes the keys.
	dialog_asker_bind(caller)
	damage_whole_screen()
	return
}

// plan_difference_reading_step adopts a reading that the worker published,
// in constant time, for the dialog that still shows it, and closes its
// object: a dialog that ended while the worker read takes no line.
plan_difference_reading_step :: proc "contextless" () {
	if plan_reading_stage() != .Published {
		return
	}
	adopted := bar.plan_difference_adopt(&plan_difference_dialog, plan_reading.serial, &plan_reading.read, system.time())
	system.close(plan_reading.memory)
	plan_reading.serial, plan_reading.memory, plan_reading.read = 0, 0, {}
	plan_reading_stage_set(.Idle)
	if adopted && plan_difference_dialog.open {
		system.log_fact(.Info, Plan_Difference_Shown{added = u64(plan_difference_dialog.added_count), removed = u64(plan_difference_dialog.removed_count), plan = value_kinds.text_field(bar.plan_difference_name(&plan_difference_dialog), PLAN_NAME_FIELD_BYTES)})
	}
	damage_whole_screen()
}

// plan_difference_reading_wait adds the stage of the reading to the wait of
// the interface thread, so a publication wakes it.
plan_difference_reading_wait :: proc "contextless" (wait: ^system.Wait) {
	if plan_reading_stage() == .Requested {
		system.wait_word(wait, &plan_reading.stage, u32(Plan_Reading_Stage.Requested))
	}
}

// act_dialog_show shows one act of an agent on the trusted display: the
// asker, the name of the calling process, and the act, service.export. It
// gives the serial, or 0 with the refusal and the argument that it names.
// caller says what the connection of the asker may do; a call from no
// connection is no asker.
act_dialog_show :: proc "contextless" (asker: ^system.Connection, caller: bar.Plan_Difference_Caller, act: string) -> (serial: u64, refusal: bar.Plan_Difference_Refusal, argument: int) {
	asker_name := asker != nil ? system.name_of(asker.caller[:]) : ""
	serial, refusal, argument = bar.plan_difference_act_ask(&plan_difference_dialog, caller, powerbox_prompt.open, asker_name, act, system.time())
	if refusal != .None {
		return
	}
	system.log_fact(.Info, Act_Shown{asker = value_kinds.text_field(asker_name, PLAN_NAME_FIELD_BYTES), act = value_kinds.text_field(act, PLAN_NAME_FIELD_BYTES)})
	window_switcher_cancel() // window_switcher.odin: the dialog takes the keys.
	dialog_asker_bind(asker)
	damage_whole_screen()
	return
}

// act_dialog_cancelled records that the asker withdrew the act that
// showed: the dialog closed with a refusal.
act_dialog_cancelled :: proc "contextless" () {
	dialog := &plan_difference_dialog
	system.log_fact(.Info, Act_Cancelled{asker = value_kinds.text_field(bar.plan_difference_name(dialog), PLAN_NAME_FIELD_BYTES), act = value_kinds.text_field(bar.plan_difference_item_text(&dialog.added[0]), PLAN_NAME_FIELD_BYTES)})
	damage_whole_screen()
}

// The connection that asked for the dialog that shows, or for the last
// one: connection nil when the compositor itself asked, or when the
// connection ended. The ring handle and the name tell a later caller in
// the same place of the connection table from the asker.
Dialog_Asker :: struct {
	connection: ^system.Connection,
	ring:       system.Handle,
	name:       system.Name,
}

dialog_asker: Dialog_Asker

dialog_asker_bind :: proc "contextless" (connection: ^system.Connection) {
	dialog_asker = {}
	if connection != nil {
		dialog_asker = {connection = connection, ring = connection.ring_memory, name = connection.caller}
	}
}

// dialog_asker_is says if a connection is the one that asked for the
// last dialog: a decision goes to its asker only.
dialog_asker_is :: proc "contextless" (connection: ^system.Connection) -> bool {
	return connection != nil && dialog_asker.connection == connection && dialog_asker.ring == connection.ring_memory && dialog_asker.name == connection.caller
}

// dialog_asker_allowed says if the asker may still ask for the dialog of
// the face that shows: a plan for the holder of Plans or a caller that
// acts for its principal, an act for an act asker or such a caller.
@(private = "file")
dialog_asker_allowed :: proc "contextless" (grant: u64) -> bool {
	switch plan_difference_dialog.face {
	case .Plan:
		return pr.plan_display_caller_allowed(grant)
	case .Act:
		return pr.act_display_caller_allowed(grant)
	}
	return false
}

// plan_difference_asker_check closes the dialog that shows when the grant
// of its asker no longer lets it ask: the root service wrote the grant
// again after a change of the roles, and the module that asked lost the
// role Plans, or its connection ended (its process exited). The principal
// never answers a dialog for a module that cannot receive the answer. It
// runs after each pass of the service, which applies each Grant before the
// next call. A connection that ended also loses the decision of a closed
// dialog, so a later caller in its place never reads it.
plan_difference_asker_check :: proc "contextless" () {
	asker := dialog_asker.connection
	if asker == nil {
		return
	}
	ended := asker.calls.head == nil || asker.ring_memory != dialog_asker.ring || asker.caller != dialog_asker.name
	if ended {
		dialog_asker.connection = nil
	}
	if !plan_difference_dialog.open || (!ended && dialog_asker_allowed(asker.grant)) {
		return
	}
	dialog_asker.connection = nil
	switch plan_difference_dialog.face {
	case .Plan:
		system.log_fact(.Warning, Plan_Difference_Asker_Lost{plan = value_kinds.text_field(bar.plan_difference_name(&plan_difference_dialog), PLAN_NAME_FIELD_BYTES)})
	case .Act:
		system.log_fact(.Warning, Act_Asker_Lost{asker = value_kinds.text_field(bar.plan_difference_name(&plan_difference_dialog), PLAN_NAME_FIELD_BYTES)})
	}
	plan_difference_answer(bar.plan_difference_key(&plan_difference_dialog, .Escape, system.time()))
}

// plan_difference_answer records the decision of the principal, if the
// last key or press made one, with the fact of the face of the dialog.
plan_difference_answer :: proc "contextless" (decision: bar.Plan_Difference_Decision) {
	dialog := &plan_difference_dialog
	name := value_kinds.text_field(bar.plan_difference_name(dialog), PLAN_NAME_FIELD_BYTES)
	act := value_kinds.text_field(dialog.added_count > 0 ? bar.plan_difference_item_text(&dialog.added[0]) : "", PLAN_NAME_FIELD_BYTES)
	switch decision {
	case .Pending:
		return
	case .Accepted:
		switch dialog.face {
		case .Plan:
			system.log_fact(.Info, Plan_Difference_Accepted{plan = name})
		case .Act:
			system.log_fact(.Info, Act_Allowed{asker = name, act = act})
		}
	case .Refused:
		switch dialog.face {
		case .Plan:
			system.log_fact(.Info, Plan_Difference_Refused{plan = name})
		case .Act:
			system.log_fact(.Info, Act_Refused{asker = name, act = act})
		}
	}
	damage_whole_screen()
}

// plan_difference_pointer gives a press to the dialog of a plan, and
// reports whether the dialog took the pointer: while it shows, no menu and
// no window receives a press or a move.
plan_difference_pointer :: proc "contextless" (pressed: bool) -> bool {
	if !plan_difference_dialog.open {
		return false
	}
	if pressed {
		focus := plan_difference_dialog.focus
		plan_difference_answer(bar.plan_difference_press(&plan_difference_dialog, desktop_width, desktop_work_top(), desktop_work_bottom(), pointer_x, pointer_y, system.time()))
		if plan_difference_dialog.open && plan_difference_dialog.focus != focus {
			damage_whole_screen()
		}
	}
	return true
}

// powerbox_picker_follow_choice moves the view of the list so that it holds
// the chosen store.
powerbox_picker_follow_choice :: proc "contextless" () {
	prompt := &powerbox_prompt
	if prompt.picker_selected < prompt.picker_first {
		prompt.picker_first = prompt.picker_selected
	}
	if prompt.picker_selected >= prompt.picker_first + POWERBOX_PICKER_SLOTS {
		prompt.picker_first = prompt.picker_selected - POWERBOX_PICKER_SLOTS + 1
	}
	prompt.picker_first = clamp(prompt.picker_first, 0, max(powerbox_picker_total() - POWERBOX_PICKER_SLOTS, 0))
	powerbox_picker_show(prompt.picker_first, POWERBOX_PICKER_SLOTS)
}

powerbox_and_wide_grant_key :: proc "contextless" (code: u32, pressed: bool, modifiers: u32) -> bool {
	if !pressed {
		return false
	}
	ctrl_shift := u32(display.MODIFIER_CONTROL | display.MODIFIER_SHIFT)
	if wide_grant_display.active && code == display.KEY_ESCAPE && (modifiers & ctrl_shift) == ctrl_shift {
		return wide_grant_revoke_press() // wide_grant_screen.odin
	}
	if wide_grant_screen_key(code, pressed) {
		return true
	}
	if plan_difference_dialog.open {
		key: bar.Plan_Difference_Key
		switch code {
		case display.KEY_TAB, display.KEY_LEFT, display.KEY_RIGHT:
			key = .Next
		case display.KEY_UP:
			key = .Line_Previous
		case display.KEY_DOWN:
			key = .Line_Next
		case display.KEY_PAGE_UP:
			key = .Page_Previous
		case display.KEY_PAGE_DOWN:
			key = .Page_Next
		case display.KEY_ENTER:
			key = .Act
		case display.KEY_ESCAPE:
			key = .Escape
		case:
			key = .Other
		}
		focus := plan_difference_dialog.focus
		first_line := plan_difference_dialog.first_line
		plan_difference_answer(bar.plan_difference_key(&plan_difference_dialog, key, system.time()))
		if plan_difference_dialog.open && (plan_difference_dialog.focus != focus || plan_difference_dialog.first_line != first_line) {
			damage_whole_screen()
		}
		return true
	}
	if !powerbox_prompt.open {
		return false
	}
	switch code {
	case display.KEY_UP:
		if total := powerbox_picker_total(); powerbox_prompt.kind == .Store_Share && total > 0 {
			powerbox_prompt.picker_selected = (powerbox_prompt.picker_selected + total - 1) % total
			powerbox_picker_follow_choice()
			damage_whole_screen()
		}
		return true
	case display.KEY_DOWN:
		if total := powerbox_picker_total(); powerbox_prompt.kind == .Store_Share && total > 0 {
			powerbox_prompt.picker_selected = (powerbox_prompt.picker_selected + 1) % total
			powerbox_picker_follow_choice()
			damage_whole_screen()
		}
		return true
	case display.KEY_ENTER:
		return powerbox_prompt_decide(true)
	case display.KEY_ESCAPE:
		return powerbox_prompt_decide(false)
	}
	return true
}

powerbox_dialog_records :: proc "contextless" (table: ^interface.Draw_Table) {
	wide_grant_records(table) // wide_grant_screen.odin
	plan_difference_records(table)
	if !powerbox_prompt.open {
		return
	}
	is_picker := powerbox_prompt.kind == .Store_Share
	width := POWERBOX_DIALOG_WIDTH
	height := is_picker ? POWERBOX_DIALOG_HEIGHT + POWERBOX_PICKER_ROOM : POWERBOX_DIALOG_HEIGHT
	// In the middle of the desktop, and never on the bar at either edge.
	x := max(0, (desktop_width - width) / 2)
	y := max(desktop_work_top() + 16, min((desktop_height - height) / 2, desktop_work_bottom() - height - 16))

	trusted_card_records(table, x, y, width, height, is_picker ? "TRUSTED STORE PICKER" : "TRUSTED GRANT REQUEST")

	// The asker and what it asks for.
	text_room := width - 2 * POWERBOX_MARGIN
	body_y := y + 2 + POWERBOX_TITLE_HEIGHT + 1 + 12
	proc_str := string(powerbox_prompt.process_name[:powerbox_prompt.process_len])
	res_str := string(powerbox_prompt.resource_text[:powerbox_prompt.resource_len])
	interface.draw_text(table, x + POWERBOX_MARGIN, body_y, interface.text_fit(table, interface.FONT_INTERFACE, proc_str, text_room), graphics.colors.text_strong, interface.FONT_INTERFACE)
	interface.draw_text(table, x + POWERBOX_MARGIN, body_y + 22, interface.text_fit(table, interface.FONT_INTERFACE, res_str, text_room), graphics.colors.dim, interface.FONT_INTERFACE)

	button_y := y + height - POWERBOX_MARGIN - POWERBOX_BUTTON_HEIGHT
	if is_picker {
		// The stores, in a recessed list with a hairline border; the chosen
		// store is a plate in the gradient of the chosen blue.
		list_x, list_y := x + POWERBOX_MARGIN, body_y + 48
		list_width, list_height := text_room, POWERBOX_PICKER_SLOTS * POWERBOX_PICKER_LINE + 2
		interface.draw_rectangle(table, list_x, list_y, list_width, list_height, graphics.colors.recess)
		interface.draw_outline(table, list_x, list_y, list_width, list_height, 1, graphics.colors.track)
		// Only the rows of the view: the list has any count of stores.
		visible_end := min(powerbox_prompt.picker_first + POWERBOX_PICKER_SLOTS, powerbox_picker_total())
		switch {
		case picker.stage == .Opening:
			interface.draw_text(table, list_x + 12, list_y + 5, "Reading the stores", graphics.colors.dim, interface.FONT_INTERFACE)
		case picker.stage == .No_List:
			interface.draw_text(table, list_x + 12, list_y + 5, interface.text_fit(table, interface.FONT_INTERFACE, "The stores did not come. Refuse, then ask again.", list_width - 24), graphics.colors.dim, interface.FONT_INTERFACE)
		case powerbox_picker_total() == 0:
			interface.draw_text(table, list_x + 12, list_y + 5, "No store", graphics.colors.dim, interface.FONT_INTERFACE)
		}
		for i in powerbox_prompt.picker_first ..< visible_end {
			name, shown := powerbox_picker_name(i)
			if !shown {
				continue // Its page comes.
			}
			ry := list_y + 1 + (i - powerbox_prompt.picker_first) * POWERBOX_PICKER_LINE
			sel := i == powerbox_prompt.picker_selected
			if sel {
				interface.draw_vertical_gradient(table, list_x + 1, ry, list_width - 2, POWERBOX_PICKER_LINE, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
				interface.draw_rectangle(table, list_x + 2, ry, list_width - 4, 1, graphics.shade(graphics.colors.chosen, 140))
			}
			interface.draw_text(table, list_x + 12, ry + 4, interface.text_fit(table, interface.FONT_INTERFACE, name, list_width - 24), sel ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
		}
		interface.draw_text(table, x + POWERBOX_MARGIN, button_y + (POWERBOX_BUTTON_HEIGHT - graphics.CELL_HEIGHT) / 2, "Up/Down: choose", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	// The two acts at the right, the refusal last: each button says its key.
	right := x + width - POWERBOX_MARGIN
	right = powerbox_button_records(table, right, button_y, "Refuse", "Esc", false)
	_ = powerbox_button_records(table, right - POWERBOX_BUTTON_GAP, button_y, is_picker ? "Share" : "Allow", "Enter", true)
}

// trusted_card_records draws the frame of a dialog of the trusted display,
// in the look of a window: a sharp shadow, the outer line of the edge, a
// line of the blue of the title inside it, the cards gradient, and the
// title plate in the gradient of a focused window with its line of light.
// The shadow and the edge are tokens: a shade of the background is near
// black in the light appearance too, a black box there.
trusted_card_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, header: string) {
	interface.draw_rectangle(table, x + 4, y + 4, width, height, graphics.colors.shadow)
	interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.card_top, graphics.colors.card_bottom)
	interface.draw_outline(table, x, y, width, height, 1, graphics.colors.edge)
	interface.draw_outline(table, x + 1, y + 1, width - 2, height - 2, 1, graphics.colors.title)
	interface.draw_horizontal_gradient(table, x + 2, y + 2, width - 4, 1, graphics.shade(graphics.colors.title, 125), graphics.shade(graphics.colors.title_end, 125))
	interface.draw_horizontal_gradient(table, x + 2, y + 3, width - 4, POWERBOX_TITLE_HEIGHT - 1, graphics.colors.title, graphics.colors.title_end)
	interface.draw_rectangle(table, x + 2, y + 2 + POWERBOX_TITLE_HEIGHT, width - 4, 1, graphics.colors.edge)
	interface.draw_text(table, x + POWERBOX_MARGIN - 4, y + 2 + (POWERBOX_TITLE_HEIGHT - graphics.CELL_HEIGHT) / 2, header, graphics.COLOR_WHITE, interface.FONT_INTERFACE_BOLD)
}

// plan_difference_records draws the difference of a plan: its name, what
// it adds in the color of an expected answer, what it removes in the coral
// of a failure, each with its sign so the two read apart with no color,
// and the two buttons. The places come from the bar package, as the
// presses that it hit-tests.
@(private = "file")
plan_difference_records :: proc "contextless" (table: ^interface.Draw_Table) {
	dialog := &plan_difference_dialog
	if !dialog.open {
		return
	}
	#assert(bar.PLAN_DIFFERENCE_TITLE_HEIGHT == POWERBOX_TITLE_HEIGHT)
	x, y, width, height := bar.plan_difference_place(dialog, desktop_width, desktop_work_top(), desktop_work_bottom())
	// The words of the face: a plan, or one act of an agent that asked.
	element, header, name_label, accept := "plan difference", "TRUSTED PLAN DIFFERENCE", "plan", "Accept plan"
	add_heading := "adds"
	// Each item is in the font of the cells, as a reader compares it
	// character by character (docs/FONTS.md, section 12.6): an act,
	// service.export, and an item of a plan, whose value can be a text. A
	// cell has one width, so the lines of an item are known before the
	// draw (bar.plan_difference_item_line).
	item_font := interface.Font{}
	switch dialog.face {
	case .Plan:
	case .Act:
		element, header, name_label, accept = "act", "TRUSTED ACT", "asker", "Allow once"
		add_heading = "runs"
	}
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity(element)), .Alert_Dialog, {name = element})
	defer interface.draw_element_pop(table)
	trusted_card_records(table, x, y, width, height, header)
	text_x := x + bar.PLAN_DIFFERENCE_MARGIN
	text_room := width - 2 * bar.PLAN_DIFFERENCE_MARGIN
	line_y := y + 2 + bar.PLAN_DIFFERENCE_TITLE_HEIGHT + 1 + bar.PLAN_DIFFERENCE_MARGIN
	text_offset := (bar.PLAN_DIFFERENCE_LINE - graphics.CELL_HEIGHT) / 2
	name_x := interface.draw_text(table, text_x, line_y + text_offset, name_label, graphics.colors.dim, interface.FONT_INTERFACE) + bar.PLAN_DIFFERENCE_GAP
	interface.draw_text(table, name_x, line_y + text_offset, interface.text_fit(table, interface.FONT_INTERFACE_BOLD, bar.plan_difference_name(dialog), x + width - bar.PLAN_DIFFERENCE_MARGIN - name_x), graphics.colors.text_strong, interface.FONT_INTERFACE_BOLD)
	line_y += bar.PLAN_DIFFERENCE_LINE + bar.PLAN_DIFFERENCE_GAP
	// The lines of the view only: the body scrolls over each change of the
	// difference.
	visible := bar.plan_difference_visible_lines(dialog)
	if dialog.reading {
		interface.draw_text(table, text_x, line_y + text_offset, "Reading the difference", graphics.colors.dim, interface.FONT_INTERFACE)
	}
	for index in dialog.first_line ..< dialog.first_line + visible {
		line, ok := bar.plan_difference_line(dialog, index)
		if !ok {
			break
		}
		color := line.added ? graphics.colors.process : graphics.colors.failed
		if line.heading {
			interface.draw_text(table, text_x, line_y + text_offset, line.added ? add_heading : "removes", graphics.colors.dim, interface.FONT_CAPTION)
		} else {
			item_x := interface.draw_text(table, text_x + 8, line_y + text_offset, line.added ? "+" : "-", color, interface.FONT_INTERFACE_BOLD) + bar.PLAN_DIFFERENCE_GAP
			// text_fit cuts nothing here: a line of an item fits its room; it
			// stays as the guard of the box of the dialog.
			#assert(bar.PLAN_DIFFERENCE_LINE_CHARACTERS * graphics.CELL_WIDTH <= bar.PLAN_DIFFERENCE_WIDTH - 2 * bar.PLAN_DIFFERENCE_MARGIN - 24)
			shown := interface.text_fit(table, item_font, bar.plan_difference_item_line(line.item, line.item_line), text_x + text_room - item_x)
			interface.draw_text(table, item_x, line_y + text_offset, shown, color, item_font)
		}
		line_y += bar.PLAN_DIFFERENCE_LINE
	}
	accept_x, button_y, button_width, button_height := bar.plan_difference_button_place(x, y, width, height, .Accept)
	refuse_x, _, _, _ := bar.plan_difference_button_place(x, y, width, height, .Refuse)
	// Until the view showed the last line, the hint says how to reach it:
	// the accept counts only after.
	hint := dialog.seen_through ? "Tab: move" : "Down: read all"
	interface.draw_text(table, text_x, button_y + (button_height - graphics.CELL_HEIGHT) / 2, hint, graphics.colors.dim, interface.FONT_INTERFACE)
	plan_difference_button_records(table, accept_x, button_y, button_width, button_height, accept, "Enter", true, dialog.focus == .Accept)
	plan_difference_button_records(table, refuse_x, button_y, button_width, button_height, "Refuse", "Esc", false, dialog.focus == .Refuse)
}

// plan_difference_button_records draws a button of the dialog of a plan in
// its fixed place, in the look of the buttons of the grant dialog, with
// the ring of the focus on the button that Enter acts on.
@(private = "file")
plan_difference_button_records :: proc "contextless" (table: ^interface.Draw_Table, x, y, width, height: int, act, key: string, grants, focused: bool) {
	interface.draw_element_push(table, {x, y, width, height}, u32(interface.identity(act)), .Button, {name = act})
	defer interface.draw_element_pop(table)
	if grants {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
		interface.draw_outline(table, x, y, width, height, 1, graphics.shade(graphics.colors.chosen, 70))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.chosen, 140))
	} else {
		interface.draw_vertical_gradient(table, x, y, width, height, graphics.colors.track, graphics.shade(graphics.colors.track, 88))
		interface.draw_outline(table, x, y, width, height, 1, graphics.shade(graphics.colors.track, 150))
		interface.draw_rectangle(table, x + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.track, 130))
	}
	text_y := y + (height - graphics.CELL_HEIGHT) / 2
	interface.draw_text(table, x + POWERBOX_BUTTON_PADDING, text_y, act, grants ? graphics.COLOR_WHITE : graphics.colors.text_strong, interface.FONT_INTERFACE)
	interface.draw_text_right(table, x + width - POWERBOX_BUTTON_PADDING, text_y, key, grants ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
	if focused {
		interface.draw_focus_ring(table, {x, y, width, height})
	}
}

// powerbox_button_records draws a button of the dialog that ends at right:
// its act, then its key in a dim text. The act that grants is a plate of
// the chosen blue with a line of light; the refusal is a plate of the track
// with a hairline border. It gives the x of its left edge.
powerbox_button_records :: proc "contextless" (table: ^interface.Draw_Table, right, y: int, act, key: string, grants: bool) -> int {
	act_width := interface.text_measured_width(table, interface.FONT_INTERFACE, act)
	key_width := interface.text_measured_width(table, interface.FONT_INTERFACE, key)
	width := act_width + POWERBOX_BUTTON_GAP + key_width + 2 * POWERBOX_BUTTON_PADDING
	left := right - width
	if grants {
		interface.draw_vertical_gradient(table, left, y, width, POWERBOX_BUTTON_HEIGHT, graphics.colors.chosen, graphics.shade(graphics.colors.chosen, 86))
		interface.draw_outline(table, left, y, width, POWERBOX_BUTTON_HEIGHT, 1, graphics.shade(graphics.colors.chosen, 70))
		interface.draw_rectangle(table, left + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.chosen, 140))
	} else {
		interface.draw_vertical_gradient(table, left, y, width, POWERBOX_BUTTON_HEIGHT, graphics.colors.track, graphics.shade(graphics.colors.track, 88))
		interface.draw_outline(table, left, y, width, POWERBOX_BUTTON_HEIGHT, 1, graphics.shade(graphics.colors.track, 150))
		interface.draw_rectangle(table, left + 1, y + 1, width - 2, 1, graphics.shade(graphics.colors.track, 130))
	}
	text_y := y + (POWERBOX_BUTTON_HEIGHT - graphics.CELL_HEIGHT) / 2
	// The act: white on the chosen blue; on the track, the strong text, so
	// the refusal reads on the light track too.
	key_x := interface.draw_text(table, left + POWERBOX_BUTTON_PADDING, text_y, act, grants ? graphics.COLOR_WHITE : graphics.colors.text_strong, interface.FONT_INTERFACE) + POWERBOX_BUTTON_GAP
	// The key in the text color on the track: the dim color has the
	// contrast of a large text only there.
	interface.draw_text(table, key_x, text_y, key, grants ? graphics.COLOR_WHITE : graphics.colors.text, interface.FONT_INTERFACE)
	return left
}
