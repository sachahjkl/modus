package compositor

import "modus:contract/chosen_values"
import "modus:contract/desktop_shell"
import "modus:contract/display_choices"
import "modus:contract/plan_values"
import "modus:contract/errors"
import "modus:contract/value_kinds"
import "modus:kept_choices"
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

// The keeper of the kept record, on its worker (modus:kept_choices).
display_kept: kept_choices.Kept
display_choices_in_force: display_choices.Choices = display_choices.CONTRACT_DEFAULTS
// The plan values of the role: its defaults and its locks, from the page of
// the start of this holder (src/md/features/module_settings.md, "Plan
// records").
display_plan: plan_values.Owner_Values
// The copy of the plan values page that display_plan points into.
display_plan_copy: system.Plan_Values_Copy

// display_choices_open opens the role store from the context and starts
// the worker, with no call to the storage service: the read waits for the
// first frame.
display_choices_open :: proc "contextless" (ctx: ^system.Context) {
	// The defaults of the plan hold from the first frame, before the read
	// of the store.
	display_plan, _ = system.plan_values_of_process(&ctx.values, &display_plan_copy)
	role_store, role_store_open := storage.open_of_handles(ctx.handles[system.GRANT_STORAGE_RING], ctx.handles[system.GRANT_STORAGE_REGION], ctx.handles[system.GRANT_STORAGE_SERVICE], ctx.values[VALUE_STORAGE_FILE_SIZE])
	if !kept_choices.kept_open(&display_kept, role_store, role_store_open, display_choices.KEPT_OBJECT_NAME) {
		system.log_fact(.Warning, Display_Choices_No_Store{})
	}
	display_choices_apply(display_choices.choices_of_record({}, display_plan))
}

// display_choices_load asks the worker for the kept record, once, after the
// first frame.
display_choices_load :: proc "contextless" () {
	kept_choices.kept_load(&display_kept)
}

// display_choices_wait adds the end of a job of the worker to the wait of
// the loop. true: a job ended already, and the loop must not sleep.
display_choices_wait :: proc "contextless" (wait: ^system.Wait) -> bool {
	return kept_choices.kept_wait(&display_kept, wait)
}

// display_choices_step takes the end of a job of the store. The loop calls
// it at each turn.
display_choices_step :: proc "contextless" () {
	step := kept_choices.kept_step(&display_kept)
	switch step.fault {
	case .None:
	case .Not_Read:
		system.log_fact(.Warning, Display_Choices_Not_Read(errors.error_record_fact_fields(step.error)))
	case .Unreadable:
		system.log_fact(.Warning, Display_Choices_Unreadable{problem = value_kinds.text_field(chosen_values.RECORD_PROBLEM_NAMES[step.problem], PROBLEM_NAME_FIELD_BYTES)})
	case .Not_Kept:
		system.log_fact(.Warning, Display_Choices_Not_Kept(errors.error_record_fact_fields(step.error)))
	}
	if step.changed {
		display_choices_apply(display_choices.choices_of_record(kept_choices.kept_record(&display_kept), display_plan))
	}
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

// display_choices_change makes changes hold at once, after the border of
// each value, and has the worker keep them.
display_choices_change :: proc "contextless" (changes: []chosen_values.Change) -> kept_choices.Change_Result {
	for change in changes {
		setting, known := display_setting_of_name(change.name)
		if !known || (change.kind == .Choose && !display_choices.word_valid(setting, change.value)) {
			return .No_Room
		}
	}
	result := kept_choices.kept_change(&display_kept, changes)
	if result == .Taken {
		display_choices_apply(display_choices.choices_of_record(kept_choices.kept_record(&display_kept), display_plan))
	}
	return result
}

// display_choice_choose keeps one choice of a press of the principal on the
// desktop (a menu of the bar, a tile). With no role store, the press still
// holds for this run: the line of the start says that no choice is kept.
display_choice_choose :: proc "contextless" (setting: display_choices.Setting, word: u64) {
	// A lock of the plan holds over a press too.
	if !display_choices.word_valid(setting, word) || display_choices.setting_locked(display_plan, setting) {
		return
	}
	changes := [1]chosen_values.Change{{name = display_choices.SETTING_NAMES[setting], kind = .Choose, value = word}}
	if kept_choices.kept_change_for_this_run(&display_kept, changes[:]) == .Taken {
		display_choices_apply(display_choices.choices_of_record(kept_choices.kept_record(&display_kept), display_plan))
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
choice_change_fail :: proc "contextless" (result: kept_choices.Change_Result, error: ^errors.Error_Record, argument: i64, value: i64) -> i64 {
	switch result {
	case .Taken:
		return 1
	case .No_Room:
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