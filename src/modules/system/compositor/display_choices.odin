package compositor

import "modus:contract/chosen_values"
import "modus:contract/desktop_shell"
import "modus:contract/display_choices"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/storage_status"
import "modus:contract/value_kinds"
import "modus:interface"
import "modus:storage"
import "modus:system"

// The settings of the role Display (src/md/features/module_settings.md,
// "The role store"): the compositor owns them. It
// keeps the values that the principal chose in the store of the role, which
// the root service gives the holder of the display: a restart of the
// compositor, and a module that the plan puts in its place, get them back.
//
// The loop of the compositor never waits for the store: a worker thread
// reads the kept record after the first frame and writes it after each
// change. Until the read ends, the screen draws with the defaults of the
// contract. A change holds at once; the worker keeps it, and a later change
// that comes while a write runs is written after it.

// The size of the file of the storage service, at a value of the context
// that is not a value of the screen (the root service, display_role_store_give).
VALUE_STORAGE_FILE_SIZE :: 8

// The room of the kept record: one page holds about a hundred names, past
// the five of the contract. A record past it is read as one that this
// release cannot read, and stays as it is.
KEPT_RECORD_BYTES :: system.PAGE_SIZE

// What the worker does now.
Choices_Job :: enum u8 {
	None  = 0,
	Read  = 1, // Read the kept record, once.
	Write = 2, // Write the record of the choices in force.
}

role_store: storage.Client
role_store_open: bool
choices_work: interface.Background_Work
choices_job: Choices_Job
// The bytes of the job: the record that the worker read or writes. The
// loop touches them only while the work is idle.
choices_job_bytes: [KEPT_RECORD_BYTES]u8
choices_job_length: int
choices_job_found: bool
choices_job_status: storage_status.Status
choices_job_error: errors.Error_Record
// The kept record of this run: what the store holds, with the changes of
// this run. It is readable once the read ended with a record of this
// format, or with none.
kept_record_bytes: [KEPT_RECORD_BYTES]u8
kept_record_length: int
kept_record_read: bool
kept_record_readable: bool
// The changes that came before the read ended: each one goes on the record
// that the store gave, so the read never loses a choice of an earlier run.
pending_changes: [display_choices.Setting]chosen_values.Change
pending_given: [display_choices.Setting]bool
kept_record_dirty: bool // The record of this run holds a change that the store does not hold yet.
display_choices_in_force: display_choices.Choices = display_choices.CONTRACT_DEFAULTS

// display_choices_open opens the role store from the context and starts
// the worker, with no call to the storage service: the read waits for the
// first frame.
display_choices_open :: proc "contextless" (ctx: ^system.Context) {
	role_store, role_store_open = storage.open_of_handles(ctx.handles[system.GRANT_STORAGE_RING], ctx.handles[system.GRANT_STORAGE_REGION], ctx.handles[system.GRANT_STORAGE_SERVICE], ctx.values[VALUE_STORAGE_FILE_SIZE])
	if role_store_open && interface.background_work_start(&choices_work) != .Ok {
		role_store_open = false
	}
	if !role_store_open {
		system.log_fact(.Warning, Display_Choices_No_Store{})
	}
}

// display_choices_load asks the worker for the kept record, once, after the
// first frame.
display_choices_load :: proc "contextless" () {
	if !role_store_open || choices_job != .None || kept_record_read {
		return
	}
	choices_job = .Read
	_ = interface.background_work_ask(&choices_work, choices_job_run, nil)
}

// choices_job_run runs on the worker: one call of the store.
@(private = "file")
choices_job_run :: proc "contextless" (parameter: rawptr) {
	switch choices_job {
	case .Read:
		bytes: []u8
		bytes, choices_job_found, choices_job_status = storage.read(&role_store, storage.ROOT, display_choices.KEPT_OBJECT_NAME, choices_job_bytes[:], &choices_job_error)
		choices_job_length = len(bytes)
	case .Write:
		_, choices_job_status = storage.write(&role_store, storage.ROOT, display_choices.KEPT_OBJECT_NAME, choices_job_bytes[:choices_job_length], &choices_job_error)
	case .None:
	}
}

// display_choices_wait adds the end of a job of the worker to the wait of
// the loop. true: a job ended already, and the loop must not sleep.
display_choices_wait :: proc "contextless" (wait: ^system.Wait) -> bool {
	if !role_store_open {
		return false
	}
	return interface.background_work_wait(wait, &choices_work)
}

// display_choices_step takes the end of a job, then asks for the write of a
// record that the store does not hold yet. The loop calls it at each turn.
display_choices_step :: proc "contextless" () {
	if !role_store_open || !interface.background_work_take(&choices_work) {
		return
	}
	job := choices_job
	choices_job = .None
	switch job {
	case .None:
	case .Read:
		choices_read_end()
	case .Write:
		if choices_job_status != .Ok {
			system.log_fact(.Warning, Display_Choices_Not_Kept(errors.error_record_fact_fields(choices_job_error)))
		}
	}
	if kept_record_read && kept_record_dirty {
		kept_record_dirty = false
		copy(choices_job_bytes[:], kept_record_bytes[:kept_record_length])
		choices_job_length = kept_record_length
		choices_job = .Write
		_ = interface.background_work_ask(&choices_work, choices_job_run, nil)
	}
}

// choices_read_end takes the record that the worker read, puts on it the
// changes that came before, and makes its choices hold.
@(private = "file")
choices_read_end :: proc "contextless" () {
	kept_record_read = true
	kept_record_readable = true
	if choices_job_status != .Ok {
		// A record that the store did not give is never written over in
		// this run: the next start reads it again, and the choices of this
		// run hold for this run only.
		role_store_open = false
		system.log_fact(.Warning, Display_Choices_Not_Read(errors.error_record_fact_fields(choices_job_error)))
		return
	}
	if choices_job_found {
		if _, problem := chosen_values.read_record(choices_job_bytes[:choices_job_length]); problem != .None {
			kept_record_readable = false
			system.log_fact(.Warning, Display_Choices_Unreadable{problem = value_kinds.text_field(chosen_values.RECORD_PROBLEM_NAMES[problem], PROBLEM_NAME_FIELD_BYTES)})
		} else {
			copy(kept_record_bytes[:], choices_job_bytes[:choices_job_length])
			kept_record_length = choices_job_length
		}
	}
	changes: [len(display_choices.Setting)]chosen_values.Change
	count := 0
	for setting in display_choices.Setting {
		if pending_given[setting] {
			changes[count] = pending_changes[setting]
			count += 1
			pending_given[setting] = false
		}
	}
	if count > 0 {
		// A change of the principal starts a new record over one that this
		// release cannot read: the principal acted.
		kept_record_readable = true
		if !kept_record_readable_after_changes(changes[:count]) {
			return
		}
		kept_record_dirty = true
	}
	record, _ := chosen_values.read_record(kept_record_bytes[:kept_record_length])
	display_choices_apply(display_choices.choices_of_record(record))
}

// kept_record_readable_after_changes writes changes on the record of this
// run. false: the record has no room for them, and nothing changed.
@(private = "file")
kept_record_readable_after_changes :: proc "contextless" (changes: []chosen_values.Change) -> bool {
	record, _ := chosen_values.read_record(kept_record_bytes[:kept_record_length])
	written_bytes: [KEPT_RECORD_BYTES]u8
	written, problem := chosen_values.write_record(record, changes, written_bytes[:])
	if problem != .None {
		system.log_fact(.Warning, Display_Choices_Unreadable{problem = value_kinds.text_field(chosen_values.RECORD_PROBLEM_NAMES[problem], PROBLEM_NAME_FIELD_BYTES)})
		return false
	}
	copy(kept_record_bytes[:], written_bytes[:written])
	kept_record_length = written
	return true
}

// display_choices_apply makes a set of choices the one in force: it moves
// the bar, sets "do not disturb", the time of a card, the factor of the
// magnifier and the arm time of the dialogs of the trusted display.
display_choices_apply :: proc "contextless" (choices: display_choices.Choices) {
	display_choices_in_force = choices
	if desktop_features_ready {
		if desktop_bar_position != choices.bar_edge {
			desktop_bar_position_set(choices.bar_edge)
		}
		desktop_notifications.do_not_disturb = choices.do_not_disturb == .On
		if !desktop_magnifier.enabled {
			desktop_magnifier.zoom_eighths = u16(choices.magnifier_eighths)
		}
	}
	plan_difference_dialog.arm_milliseconds_of_the_principal = choices.consent_arm_milliseconds
}

// The result of a change of the choices.
Choice_Change_Result :: enum u8 {
	Taken    = 0, // The choice holds, and the worker keeps it.
	Refused  = 1, // A value that its border refuses, or a record with no room for it: nothing changed.
	No_Store = 2, // The holder has no role store: nothing changed.
}

// display_choices_change makes changes hold at once, after the border of
// each value, and has the worker keep them. Before the read of the kept
// record ends, the changes wait to go on the record that the store gives.
display_choices_change :: proc "contextless" (changes: []chosen_values.Change) -> Choice_Change_Result {
	for change in changes {
		setting, known := display_setting_of_name(change.name)
		if !known || (change.kind == .Choose && !display_choices.word_valid(setting, change.value)) {
			return .Refused
		}
	}
	if !role_store_open {
		return .No_Store
	}
	if !kept_record_read {
		choices := display_choices_in_force
		for change in changes {
			setting, _ := display_setting_of_name(change.name)
			pending_changes[setting] = change
			pending_given[setting] = true
			choices_word_set(&choices, setting, change.kind == .Choose ? change.value : display_choices.word_of(display_choices.CONTRACT_DEFAULTS, setting), change.kind == .Choose ? .Chosen : .Contract_Default)
		}
		display_choices_apply(choices)
		return .Taken
	}
	kept_record_readable = true
	if !kept_record_readable_after_changes(changes) {
		return .Refused
	}
	kept_record_dirty = true
	record, _ := chosen_values.read_record(kept_record_bytes[:kept_record_length])
	display_choices_apply(display_choices.choices_of_record(record))
	display_choices_step_ask()
	return .Taken
}

// display_choices_step_ask asks for the write at once when the worker is
// idle, so a change does not wait for the next turn of the loop.
@(private = "file")
display_choices_step_ask :: proc "contextless" () {
	if choices_job != .None || !kept_record_dirty {
		return
	}
	kept_record_dirty = false
	copy(choices_job_bytes[:], kept_record_bytes[:kept_record_length])
	choices_job_length = kept_record_length
	choices_job = .Write
	if !interface.background_work_ask(&choices_work, choices_job_run, nil) {
		choices_job = .None
		kept_record_dirty = true
	}
}

// choices_word_set sets the word of one setting in a set of choices, with
// the layer that gives it. The word passed its border.
@(private = "file")
choices_word_set :: proc "contextless" (choices: ^display_choices.Choices, setting: display_choices.Setting, word: u64, layer: chosen_values.Layer) {
	switch setting {
	case .Bar_Edge:
		choices.bar_edge, _ = desktop_shell.bar_position_of_word(word)
	case .Do_Not_Disturb:
		choices.do_not_disturb, _ = enum_word.member_of_word(display_choices.Do_Not_Disturb, word)
	case .Notification_Show_Time:
		choices.notification_show_milliseconds = word
	case .Magnifier_Factor:
		choices.magnifier_eighths = word
	case .Consent_Arm_Time:
		choices.consent_arm_milliseconds = word
	}
	choices.layers[setting] = layer
}

// display_choice_choose keeps one choice of a press of the principal on the
// desktop (a menu of the bar, a tile). With no role store, the press still
// holds for this run: the line of the start says that no choice is kept.
display_choice_choose :: proc "contextless" (setting: display_choices.Setting, word: u64) {
	changes := [1]chosen_values.Change{{name = display_choices.SETTING_NAMES[setting], kind = .Choose, value = word}}
	switch display_choices_change(changes[:]) {
	case .Taken, .Refused:
	case .No_Store:
		choices := display_choices_in_force
		choices_word_set(&choices, setting, word, .Chosen)
		display_choices_apply(choices)
	}
}

// display_bar_edge_choose keeps the edge of the bar that a press chose.
display_bar_edge_choose :: proc "contextless" (edge: desktop_shell.Bar_Position) {
	display_choice_choose(.Bar_Edge, u64(edge))
}

// display_setting_of_name gives the setting of a name of the kept record.
display_setting_of_name :: proc "contextless" (name: string) -> (display_choices.Setting, bool) {
	for setting in display_choices.Setting {
		if display_choices.SETTING_NAMES[setting] == name {
			return setting, true
		}
	}
	return .Bar_Edge, false
}

// choice_change_fail answers a change, in the words of the setters: 1 when
// it holds, Bad_Value for a refused value, Refused with no role store.
choice_change_fail :: proc "contextless" (result: Choice_Change_Result, error: ^errors.Error_Record, argument: i64, value: i64) -> i64 {
	switch result {
	case .Taken:
		return 1
	case .Refused:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, argument, value)
	case .No_Store:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused, .Store, argument, value)
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused, .None)
}

// The log facts of the choices of the role.

@(log_fact = "compositor: no role store: the choices of the role Display hold for this run only")
Display_Choices_No_Store :: struct {}

@(log_fact = "compositor: the role store did not give the kept choices, so the defaults hold and the record stays as it is: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Display_Choices_Not_Read :: distinct errors.Error_Record_Fact_Fields

@(log_fact = "compositor: the kept choices are a record that this release cannot read ({problem}): the defaults hold, and the record stays as it is until the principal changes a choice")
Display_Choices_Unreadable :: struct {
	problem: [24]u8, // N written out: the tool reads the size of a Text field from the source.
}

@(log_fact = "compositor: the role store did not keep a choice, which holds for this run only: kind {kind}, unit {unit}, operation {operation}, argument {argument}, value {value}, limit {limit}, found {found}")
Display_Choices_Not_Kept :: distinct errors.Error_Record_Fact_Fields

PROBLEM_NAME_FIELD_BYTES :: size_of(Display_Choices_Unreadable{}.problem)
