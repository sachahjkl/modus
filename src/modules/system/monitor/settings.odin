package monitor

// The settings of the monitor (src/md/features/module_settings.md, "Module
// settings"): the monitor owns them, keeps the choices of the principal in
// its private store, and reads the plan values of the owner `monitor`.
// The store is read after the first picture, on the worker of the keeper:
// until then the period of the plan or of the contract holds.

import "modus:contract/call_outcome"
import "modus:contract/chosen_values"
import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/plan_values"
import "modus:contract/value_kinds"
import "modus:kept_choices"
import "modus:storage"
import "modus:system"

// The object of the kept record, at the root of the private store.
KEPT_OBJECT_NAME :: "settings"
// The name of the sample period in the kept record and in the plan.
SAMPLE_INTERVAL_NAME :: "sample_interval"
// The sample period, in milliseconds: one sample and one picture each
// period. At the default, the sample history of a graph holds the last
// minute. Under the least, the samples cost more than they show; past the
// most, a graph moves too slowly to follow.
SAMPLE_INTERVAL_LEAST :: 250
SAMPLE_INTERVAL_MOST :: 5000
SAMPLE_INTERVAL_DEFAULT :: 500

monitor_kept: kept_choices.Kept
monitor_plan: plan_values.Owner_Values
// The copy of the plan values page that monitor_plan points into.
monitor_plan_copy: system.Plan_Values_Copy
sample_interval_in_force: u64 = SAMPLE_INTERVAL_DEFAULT
sample_interval_layer: chosen_values.Layer = .Contract_Default

// sample_interval_border is the one border of a word of the period.
sample_interval_border :: proc "contextless" (word: u64) -> bool {
	return word >= SAMPLE_INTERVAL_LEAST && word <= SAMPLE_INTERVAL_MOST
}

// sample_interval_of_record gives the period in force and its layer: a lock
// of the plan, a choice of the principal, a default of the plan, the
// default of the contract.
sample_interval_of_record :: proc "contextless" (record: chosen_values.Record, plan: plan_values.Owner_Values) -> (milliseconds: u64, layer: chosen_values.Layer) {
	word, word_layer, found := plan_values.value_in_force(SAMPLE_INTERVAL_NAME, record, plan, sample_interval_border)
	if !found {
		return SAMPLE_INTERVAL_DEFAULT, .Contract_Default
	}
	return word, word_layer
}

// Why a call of set is refused before it reads the plan and the store.
Set_Refusal :: enum u8 {
	None                = 0,
	Presence_Not_Member = 1, // The Presence word is neither Absent nor Given.
	Absent              = 2, // The call gives no setting.
	Out_Of_Range        = 3, // The period is out of SAMPLE_INTERVAL_LEAST to SAMPLE_INTERVAL_MOST.
}

// sample_interval_of_arguments is the border of the arguments of set: the
// Presence word, then the period.
sample_interval_of_arguments :: proc "contextless" (presence: module.Presence, value: i64) -> (interval: u64, refusal: Set_Refusal) {
	integer, given, presence_ok := module.optional_integer_of_arguments(presence, value)
	switch {
	case !presence_ok:
		return 0, .Presence_Not_Member
	case !given:
		return 0, .Absent
	case integer < 0 || !sample_interval_border(u64(integer)):
		return 0, .Out_Of_Range
	}
	return u64(integer), .None
}

// settings_open reads the plan values and opens the store, with no call to
// the storage service.
settings_open :: proc "contextless" (ctx: ^system.Context) {
	monitor_plan, _ = system.plan_values_of_process(&ctx.values, &monitor_plan_copy)
	store, store_open := storage.open(ctx)
	if !kept_choices.kept_open(&monitor_kept, store, store_open, KEPT_OBJECT_NAME) {
		system.log_fact(.Info, Settings_Not_Kept{})
	}
	sample_interval_in_force, sample_interval_layer = sample_interval_of_record({}, monitor_plan)
}

// settings_step takes the end of a job of the store.
settings_step :: proc "contextless" () {
	step := kept_choices.kept_step(&monitor_kept)
	switch step.fault {
	case .None:
	case .Not_Read:
		system.log_fact(.Warning, Settings_Not_Read(errors.error_record_fact_fields(step.error)))
	case .Unreadable:
		system.log_fact(.Warning, Settings_Unreadable{problem = value_kinds.text_field(chosen_values.RECORD_PROBLEM_NAMES[step.problem], SETTINGS_PROBLEM_FIELD_BYTES)})
	case .Not_Kept:
		system.log_fact(.Warning, Settings_Write_Refused(errors.error_record_fact_fields(step.error)))
	}
	if step.changed {
		sample_interval_in_force, sample_interval_layer = sample_interval_of_record(kept_choices.kept_record(&monitor_kept), monitor_plan)
	}
}

// set changes the settings of the monitor, each optional: sample_interval,
// the time between two samples and two pictures, in milliseconds, 250 to
// 5000. The monitor keeps it in its private store, so its next start uses
// it. The result is 1, or -1 with an error record: No_Grant for a caller
// that does not act for the principal, Absent for a call that gives no
// setting, Bad_Value for a Presence word that is neither Absent nor Given
// or a number out of its range (argument 1), Refused
// when the monitor has no store, No_Grant with the unit Plan_Lock when a
// lock of the plan holds the period. A refused call changes nothing.
//
// **Grant**: the caller must **act for the principal**.
//
// ```
// connect("monitor")
// monitor.set(sample_interval = 1000)
// ```
@(export, link_name = "set", parameter_ranges = "sample_interval = 250..5000")
set_export :: proc "c" (sample_interval_presence: module.Presence, sample_interval: i64, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	interval, refusal := sample_interval_of_arguments(sample_interval_presence, sample_interval)
	switch refusal {
	case .None:
	case .Presence_Not_Member:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, i64(min(u64(sample_interval_presence), u64(max(i64)))), i64(module.Presence.Given))
	case .Absent:
		return call_outcome.fail(error, .Argument_Refused, .Absent, .None, 0)
	case .Out_Of_Range:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, 1, sample_interval, SAMPLE_INTERVAL_MOST)
	}
	if plan_values.locked(monitor_plan, SAMPLE_INTERVAL_NAME, sample_interval_border) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 1)
	}
	changes := [1]chosen_values.Change{{name = SAMPLE_INTERVAL_NAME, kind = .Choose, value = interval}}
	return settings_change(changes[:], error, 1, sample_interval)
}

// sample_interval gives the time between two samples, in milliseconds.
@(export, link_name = "sample_interval")
sample_interval_get :: proc "c" () -> i64 {
	return i64(sample_interval_in_force)
}

// reset makes the choice of the sample period absent: the default of the
// plan, else 500 ms, holds again. The result is 1, or -1 with an error
// record: No_Grant (unit Plan_Lock: a lock of the plan holds the period),
// Refused when the monitor has no store.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "reset")
reset_export :: proc "c" (error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if plan_values.locked(monitor_plan, SAMPLE_INTERVAL_NAME, sample_interval_border) {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Plan_Lock, 0)
	}
	changes := [1]chosen_values.Change{{name = SAMPLE_INTERVAL_NAME, kind = .Reset}}
	return settings_change(changes[:], error, 0, 0)
}

// The state of one setting: the layer that gives its value (0 the contract
// default, 1 a default of the plan, 2 a choice of the principal, 3 a lock
// of the plan), and its value.
Setting_State :: struct {
	layer: i64,
	value: i64,
}

// settings_state gives one row for each setting of the monitor: its layer
// and its value. The result is the count of the settings, or -1 with an
// error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "settings_state")
settings_state_export :: proc "c" (result: ^[]Setting_State, error: ^errors.Error_Record) -> (outcome: call_outcome.Call_Outcome, value: i64) {
	if !acts_for_principal() {
		return call_outcome.fail(error, .Grant_Or_Right_Missing, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {layer = i64(sample_interval_layer), value = i64(sample_interval_in_force)}
	}
	return .Succeeded, 1
}

@(private = "file")
settings_change :: proc "contextless" (changes: []chosen_values.Change, error: ^errors.Error_Record, argument: i64, value: i64) -> (outcome: call_outcome.Call_Outcome, changed: i64) {
	switch kept_choices.kept_change(&monitor_kept, changes) {
	case .Taken:
		sample_interval_in_force, sample_interval_layer = sample_interval_of_record(kept_choices.kept_record(&monitor_kept), monitor_plan)
		return .Succeeded, 1
	case .No_Room:
		return call_outcome.fail(error, .Argument_Refused, .Bad_Value, .None, argument, value)
	case .No_Store:
		return call_outcome.fail(error, .Callee_Unavailable, .Refused, .Store, argument, value)
	}
	return call_outcome.fail(error, .Argument_Refused, .Refused, .None)
}
