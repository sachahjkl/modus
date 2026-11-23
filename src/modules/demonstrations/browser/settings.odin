package browser

// The settings of the browser (src/md/features/module_settings.md, "Module
// settings"): the browser owns them, keeps the choices of the principal in
// its private store, and reads the plan values of the owner `browser`.
// The store is read after the first frame, on the worker of the keeper:
// the first page is the home of the plan or of the contract, and the home
// that the principal chose replaces it if no other page was loaded.

import "modus:contract/chosen_values"
import "modus:contract/enum_word"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/plan_values"
import "modus:contract/value_kinds"
import "modus:kept_choices"
import "modus:storage"
import "modus:system"

// The object of the kept record, at the root of the private store.
KEPT_OBJECT_NAME :: "settings"
// The name of the home in the kept record and in the plan.
HOME_NAME :: "home"
// The default of the contract.
HOME_DEFAULT :: Built_In_Page.Welcome

ERROR_ACTS_FOR_PRINCIPAL :: -1

browser_kept: kept_choices.Kept
browser_plan: plan_values.Owner_Values
home_in_force: Built_In_Page = HOME_DEFAULT
home_layer: chosen_values.Layer = .Contract_Default
// The principal loaded a page after the start: a later read of the store
// does not replace the page shown.
page_chosen_after_start: bool

// home_border is the one border of a word of the home.
home_border :: proc "contextless" (word: u64) -> bool {
	_, known := enum_word.member_of_word(Built_In_Page, word)
	return known
}

// home_of_record gives the home in force, and its layer: a lock of the
// plan, a choice of the principal, a default of the plan, the default of
// the contract.
home_of_record :: proc "contextless" (record: chosen_values.Record, plan: plan_values.Owner_Values) -> (home: Built_In_Page, layer: chosen_values.Layer) {
	word, word_layer, found := plan_values.value_in_force(HOME_NAME, record, plan, home_border)
	if !found {
		return HOME_DEFAULT, .Contract_Default
	}
	home, _ = enum_word.member_of_word(Built_In_Page, word)
	return home, word_layer
}

// settings_open reads the plan values and opens the store. It makes no call
// to the storage service: the read waits for the first frame.
settings_open :: proc "contextless" (ctx: ^system.Context) {
	browser_plan, _ = system.plan_values_of_process(&ctx.values)
	store, store_open := storage.open(ctx)
	if !kept_choices.kept_open(&browser_kept, store, store_open, KEPT_OBJECT_NAME) {
		system.log_fact(.Info, Settings_Not_Kept{})
	}
	home_in_force, home_layer = home_of_record({}, browser_plan)
}

// settings_step takes the end of a job of the store, and makes a new home
// hold.
settings_step :: proc "contextless" () {
	step := kept_choices.kept_step(&browser_kept)
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
		settings_take()
	}
}

// settings_take computes the home from the record of the keeper; the page
// of the start follows it while the principal loaded no other.
@(private = "file")
settings_take :: proc "contextless" () {
	before := home_in_force
	home_in_force, home_layer = home_of_record(kept_choices.kept_record(&browser_kept), browser_plan)
	if home_in_force != before && !page_chosen_after_start {
		// The page of the start is the one entry of the history: the home
		// takes its place.
		history_count, history_place = 0, 0
		_ = page_load(BOOKMARK_ADDRESSES[home_in_force], true)
	}
}

@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// set changes the settings of the browser, each optional: home, the page
// built in that the browser opens at its start. The browser keeps it in its
// private store, so the next start opens it. The result is 1, or -1 with
// an error record: No_Grant for a caller that does not act for the
// principal, Absent for a call that gives no setting, Bad_Value for a word
// that names no page (argument 1), Refused when the browser has no store,
// No_Grant with the unit Plan_Lock when a lock of the plan holds the home.
// A refused call changes nothing.
//
// **Grant**: the caller must **act for the principal**.
//
// ```
// connect("browser")
// browser.set(home = .guide)
// ```
@(export, link_name = "set", enum_getters = "home = home")
set_export :: proc "c" (home_presence: module.Presence, home: Built_In_Page, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if home_presence == .Absent {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Absent, .None, 0)
	}
	if !home_border(u64(home)) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 1, i64(home))
	}
	if plan_values.locked(browser_plan, HOME_NAME) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Plan_Lock, 1)
	}
	changes := [1]chosen_values.Change{{name = HOME_NAME, kind = .Choose, value = u64(home)}}
	return settings_change(changes[:], error, 1, i64(home))
}

// home gives the page built in that the browser opens at its start.
@(export, link_name = "home")
home_get :: proc "c" () -> Built_In_Page {
	return home_in_force
}

// reset makes the choice of the home absent: the default of the plan, else
// the welcome page, holds again. The result is 1, or -1 with an error
// record: No_Grant (unit Plan_Lock: a lock of the plan holds the home),
// Refused when the browser has no store.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "reset")
reset_export :: proc "c" (error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if plan_values.locked(browser_plan, HOME_NAME) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Plan_Lock, 0)
	}
	changes := [1]chosen_values.Change{{name = HOME_NAME, kind = .Reset}}
	return settings_change(changes[:], error, 0, 0)
}

// The state of one setting: the layer that gives its value (0 the contract
// default, 1 a default of the plan, 2 a choice of the principal, 3 a lock
// of the plan), and the word of its value.
Setting_State :: struct {
	layer: i64,
	value: i64,
}

// settings_state gives one row for each setting of the browser: its layer
// and its value. The result is the count of the settings, or -1 with an
// error record.
//
// **Grant**: the caller must **act for the principal**.
@(export, link_name = "settings_state")
settings_state_export :: proc "c" (result: ^[]Setting_State, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	if len(result^) > 0 {
		result[0] = {layer = i64(home_layer), value = i64(home_in_force)}
	}
	return 1
}

@(private = "file")
settings_change :: proc "contextless" (changes: []chosen_values.Change, error: ^errors.Error_Record, argument: i64, value: i64) -> i64 {
	switch kept_choices.kept_change(&browser_kept, changes) {
	case .Taken:
		settings_take()
		return 1
	case .No_Room:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, argument, value)
	case .No_Store:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused, .Store, argument, value)
	}
	return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Refused, .None)
}
