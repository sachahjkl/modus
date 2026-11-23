package browser

// The settings of the browser (src/md/features/module_settings.md, "Module
// settings"): the browser owns them, keeps the choices of the principal in
// its private store, and reads the plan values of the owner `browser`.
// The store is read after the first frame, on the worker of the keeper:
// the first page is the home of the plan or of the contract, and the home
// that the principal chose replaces it if no other page was loaded.

import "modus:contract/chosen_values"
import "modus:contract/errors"
import "modus:contract/isolated"
import module "modus:contract/module"
import "modus:contract/plan_values"
import "modus:contract/text_encoding"
import "modus:contract/value_kinds"
import "modus:kept_choices"
import "modus:storage"
import "modus:system"

// The object of the kept record, at the root of the private store.
KEPT_OBJECT_NAME :: "settings"
// The name of the home in the kept record and in the plan.
HOME_NAME :: "home"
// The default of the contract.
HOME_DEFAULT :: "modus://welcome"
// The bound of the bytes of the home: the bytes of the address field. The
// export states it (parameter_ranges), the console checks it before the
// call, and home_problem_of checks it again.
HOME_BYTES_LEAST :: 1
HOME_BYTES_MOST :: ADDRESS_CAPACITY
#assert(HOME_BYTES_MOST <= chosen_values.TEXT_BYTES_MOST)

ERROR_ACTS_FOR_PRINCIPAL :: -1

browser_kept: kept_choices.Kept
browser_plan: plan_values.Owner_Values
// The home in force, in the canonical form of its address, and its layer.
home_bytes: [HOME_BYTES_MOST]u8
home_length: int
home_layer: chosen_values.Layer = .Contract_Default
// The principal loaded a page after the start: a later read of the store
// does not replace the page shown.
page_chosen_after_start: bool

// Why a text is no home.
Home_Problem :: enum u8 {
	None             = 0,
	Too_Short        = 1, // Fewer bytes than HOME_BYTES_LEAST: the empty text.
	Too_Long         = 2, // More bytes than HOME_BYTES_MOST.
	Not_Utf8         = 3,
	Address_Refused  = 4, // The border of an address of the browser refuses it: address_parse names why.
	Canonical_Too_Long = 5, // The canonical form of the address is longer than HOME_BYTES_MOST.
}

// home_problem_of is the one border of a home: its bound of bytes, its
// UTF-8, then the border of an address of the browser. canonical is the
// address as the browser writes it, in the bytes of out.
home_problem_of :: proc "contextless" (text: string, out: []u8) -> (canonical: string, problem: Home_Problem, address_problem: Address_Problem) {
	switch {
	case len(text) < HOME_BYTES_LEAST:
		return "", .Too_Short, .None
	case len(text) > HOME_BYTES_MOST:
		return "", .Too_Long, .None
	case !text_encoding.text_valid(transmute([]u8)text):
		return "", .Not_Utf8, .None
	}
	address, parsed := address_parse(text)
	if parsed != .None {
		return "", .Address_Refused, parsed
	}
	writer := Source_Writer{bytes = out}
	address_write(&writer, &address)
	if writer.full || writer.count > HOME_BYTES_MOST {
		return "", .Canonical_Too_Long, .None
	}
	return writer_text(&writer), .None, .None
}

// home_border is the border of a home of the record or of the plan: a text
// that home_problem_of takes.
home_border :: proc "contextless" (text: string) -> bool {
	room: [ADDRESS_CAPACITY + 8]u8
	_, problem, _ := home_problem_of(text, room[:])
	return problem == .None
}

// home_of_record gives the home in force, in the bytes of out, and its
// layer: a lock of the plan, a choice of the principal, a default of the
// plan, the default of the contract.
home_of_record :: proc "contextless" (record: chosen_values.Record, plan: plan_values.Owner_Values, out: []u8) -> (home: string, layer: chosen_values.Layer) {
	text, text_layer, found := plan_values.text_in_force(HOME_NAME, record, plan, home_border)
	if !found {
		return HOME_DEFAULT, .Contract_Default
	}
	canonical, _, _ := home_problem_of(text, out)
	return canonical, text_layer
}

// home_text gives the home in force.
home_text :: proc "contextless" () -> string {
	return string(home_bytes[:home_length])
}

@(private = "file")
home_take :: proc "contextless" (record: chosen_values.Record) {
	room: [ADDRESS_CAPACITY + 8]u8
	home, layer := home_of_record(record, browser_plan, room[:])
	home_length = copy(home_bytes[:], home)
	home_layer = layer
}

// settings_open reads the plan values and opens the store. It makes no call
// to the storage service: the read waits for the first frame.
settings_open :: proc "contextless" (ctx: ^system.Context) {
	browser_plan, _ = system.plan_values_of_process(&ctx.values)
	store, store_open := storage.open(ctx)
	if !kept_choices.kept_open(&browser_kept, store, store_open, KEPT_OBJECT_NAME) {
		system.log_fact(.Info, Settings_Not_Kept{})
	}
	home_take({})
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
	before: [HOME_BYTES_MOST]u8
	before_length := copy(before[:], home_text())
	home_take(kept_choices.kept_record(&browser_kept))
	if home_text() != string(before[:before_length]) && !page_chosen_after_start {
		// The page of the start is the one entry of the history: the home
		// takes its place.
		history_count, history_place = 0, 0
		_ = page_load(home_text(), true)
	}
}

@(private = "file")
acts_for_principal :: proc "contextless" () -> bool {
	caller := system.service_caller()
	return caller == nil || caller.grant & isolated.CALLER_ACTS_FOR_PRINCIPAL != 0
}

// set changes the settings of the browser, each optional: home, the
// address that the browser opens at its start: a page built in
// (modus://welcome, modus://guide) or an address of HTTP or HTTPS, 1 to 160
// bytes. The browser keeps it in its private store, in the form that its
// address field writes, so the next start opens it. The result is 1, or -1
// with an error record: No_Grant for a caller that does not act for the
// principal, or with the unit Plan_Lock when a lock of the plan holds the
// home; Absent for a call that gives no setting; Too_Long (unit Bytes) for
// a home past 160 bytes; Bad_Value (argument 1) for an empty home, a home
// that is not UTF-8, or an address that the browser refuses (found: the
// problem of the address, from 1); Refused when the browser has no store. A
// refused call changes nothing.
//
// **Grant**: the caller must **act for the principal**.
//
// ```
// connect("browser")
// browser.set(home = "modus://guide")
// ```
@(export, link_name = "set", parameter_ranges = "home = 1..160")
set_export :: proc "c" (home_presence: module.Presence, home: ^string, error: ^errors.Error_Record) -> i64 {
	if !acts_for_principal() {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Acts_For_Principal)
	}
	text, given, ok := module.optional_text_of_arguments(home_presence, home)
	if !ok {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 1, i64(home_presence))
	}
	if !given {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Absent, .None, 0)
	}
	room: [ADDRESS_CAPACITY + 8]u8
	canonical, problem, address_problem := home_problem_of(text, room[:])
	switch problem {
	case .None:
	case .Too_Long, .Canonical_Too_Long:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Too_Long, .Bytes, 1, i64(len(text)), HOME_BYTES_MOST)
	case .Too_Short, .Not_Utf8:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 1, i64(len(text)))
	case .Address_Refused:
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .Bad_Value, .None, 1, i64(len(text)), 0, i64(address_problem))
	}
	if plan_values.locked(browser_plan, HOME_NAME) {
		return errors.fail(error, ERROR_ACTS_FOR_PRINCIPAL, .No_Grant, .Plan_Lock, 1)
	}
	changes := [1]chosen_values.Change{{name = HOME_NAME, kind = .Choose_Text, text = canonical}}
	return settings_change(changes[:], error, 1, i64(len(text)))
}

// home gives the address that the browser opens at its start. The result
// is the length of the text; a buffer shorter than the text gets its first
// bytes, and the result still counts them all.
@(export, link_name = "home")
home_get :: proc "c" (result: ^[]u8) -> i64 {
	copy(result^, home_text())
	return i64(home_length)
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
// of the plan), and its value: for a text, the count of its bytes, which
// its getter gives.
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
		result[0] = {layer = i64(home_layer), value = i64(home_length)}
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
