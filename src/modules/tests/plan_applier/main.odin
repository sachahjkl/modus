// The applier of the machine test of the plan of principal 0 across a
// restart (src/md/features/declarations.md, "The plan of principal 0 at
// the start"). It applies plans of principal 0 through `plans.apply` and
// reads the decision of the principal with `plans.apply_poll`; the tool
// answers each dialog of the trusted display with the keys of a principal.
// The refusals come first, each with its call outcome and its error record,
// and each leaves generation 0 current:
//
// 1. a Plan_Expected that names a current plan that does not exist:
//    refused at once, with no dialog;
// 2. a plan that the principal refuses: Enter while the focus is on
//    Refuse;
// 3. a holder of Settings whose hash names no module of the boot image,
//    which the principal accepts: the root service refuses its roles, so
//    nothing commits;
// 4. a holder that is a module of the image and does not fill the
//    contract of Settings (generic_source): the same.
//
// The last case is the plan that commits: settings_stand_in as the holder
// of Settings and the value storage.keep_all_minutes = 90, accepted,
// generation 1. Storage runs before plans, so the value reaches it at the
// apply, and at the next start of the machine when plans gives the values
// of the generation in force.
//
// The display takes a decision only powerbox.CONSENT_ARM_MILLISECONDS after it
// showed the difference: this process writes one line for each dialog when
// that time passed after the answer of `apply`, which came after the
// dialog showed, so a key that the tool presses after that line counts.
// The host tests of the dialog (internal:compositor/bar) prove that a key
// before that time is no act; a machine test cannot place a key before it
// with no bound on the speed of the host.
//
// **Start**: `start("plan_applier")` in the console of principal 0. **What
// a reader sees**: no window; one line for each case, then "plan_applier:
// the principal accepted the plan: generation 1, ..." or a line
// "plan_applier: WRONG: ...". It stops itself with Done, or Failed after a
// WRONG line.
package plan_applier

import "modus:contract/blake3"
import "modus:contract/call_outcome"
import "modus:contract/chosen_values"
import "modus:contract/errors"
import "modus:contract/isolated"
import "modus:contract/module"
import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/role_contract"
import "modus:contract/value_kinds"
import "modus:system"

// Page tables for mapping the boot image plus the plans call connection.
BOOT_IMAGE_AND_CONNECTION_PAGES :: 32
// Boot image page tables and plans call connection mapped before exit.
MODULE_START_OBJECTS :: [?]system.Start_Object{BOOT_IMAGE_AND_CONNECTION_PAGES}

// The module that the plan that commits names as the holder of Settings,
// and the module of the image that does not fill that contract.
HOLDER_MODULE :: "settings_stand_in"
NOT_FILLING_MODULE :: "generic_source"

// The names of the plans of the cases, which the dialog shows: the tool
// tells the dialogs apart by them.
PLAN_REFUSED_BY_PRINCIPAL :: "refused by the principal"
PLAN_NOT_IN_IMAGE :: "a holder not in the image"
PLAN_CONTRACT_NOT_FILLED :: "a holder that does not fill"
PLAN_COMMITTED :: "settings stand-in"

// The time between two reads of the decision. The decision is in the
// trusted display, which wakes no caller of plans, and plans serves
// exports only, with no ring that a caller waits on: apply_poll, called
// again, is the one way to read it.
POLL_MILLISECONDS :: 100

Plans_Connection :: struct {
	connection:         system.Call_Connection,
	file:               []u8,
	apply_export:       u32,
	poll_export:        u32,
	generation_export:  u32,
}

plans: Plans_Connection

@(private = "file")
wrong :: proc "contextless" (text: string, value: u64) -> ! {
	system.log_fact(.Error, Wrong{value = value}, text)
	system.stop(.Failed)
}

@(private = "file")
wrong_call :: proc "contextless" (text: string, outcome: call_outcome.Call_Outcome, error: errors.Error_Record) -> ! {
	system.log_fact(.Error, Wrong_Call{outcome = call_outcome.Call_Outcome_Word(outcome), error_kind = u64(error.kind), error_unit = u64(error.unit), error_argument = error.argument, error_value = error.value, error_found = error.found}, text)
	system.stop(.Failed)
}

@(private = "file")
bytes_of :: proc "contextless" (value: ^$T) -> []u8 {
	return ([^]u8)(value)[:size_of(T)]
}

// holder_row gives the one row of a plan: hash as the holder of Settings.
@(private = "file")
holder_row :: proc "contextless" (hash: blake3.Hash, name: string) -> (row: pr.Plan_Entry_Row) {
	row.kind_word = i64(pr.Plan_Entry_Kind.Role_Holder)
	row.role_word = i64(role_contract.Role.Settings)
	row.module_hash = value_kinds.Hash_Field(hash)
	copy(row.name[:], name)
	return row
}

// The value of the plan that the committed plan gives storage: each
// version kept 90 minutes, which the tool reads in the line of the rule of
// storage, 5400000 ms.
KEEP_ALL_MINUTES :: 90

// keep_all_row gives the row of the value storage.keep_all_minutes.
@(private = "file")
keep_all_row :: proc "contextless" () -> (row: pr.Plan_Entry_Row) {
	row.kind_word = i64(pr.Plan_Entry_Kind.Value)
	copy(row.name[:], "storage.keep_all_minutes")
	row.value_kind_word = i64(chosen_values.Entry_Kind.Word)
	row.value_word = KEEP_ALL_MINUTES
	row.value_layer_word = i64(chosen_values.Layer.Plan_Default)
	return row
}

// apply calls plans.apply with one row.
@(private = "file")
apply :: proc "contextless" (plan_name: string, row: ^pr.Plan_Entry_Row, expected: ^pr.Plan_Expected, error: ^errors.Error_Record) -> (ticket: i64, outcome: call_outcome.Call_Outcome) {
	return apply_rows(plan_name, ([^]pr.Plan_Entry_Row)(row)[:1], expected, error)
}

// apply_rows calls plans.apply with a table of rows.
@(private = "file")
apply_rows :: proc "contextless" (plan_name: string, rows: []pr.Plan_Entry_Row, expected: ^pr.Plan_Expected, error: ^errors.Error_Record) -> (ticket: i64, outcome: call_outcome.Call_Outcome) {
	name := plan_name
	arguments := [3]isolated.Argument{{text = transmute([]u8)name}, {table = {records = ([^]u8)(raw_data(rows))[:len(rows) * size_of(pr.Plan_Entry_Row)], count = u64(len(rows))}}, {record = bytes_of(expected)}}
	error^ = {}
	return system.call_isolated(&plans.connection, plans.file, plans.apply_export, arguments[:], error)
}

// decision_wait reads the decision on ticket until the principal took one,
// and writes the line of the arm time once.
@(private = "file")
decision_wait :: proc "contextless" (plan_name: string, ticket: i64, asked_at: u64, generation_row: ^pr.Plan_Generation_Row, error: ^errors.Error_Record) -> (generation: i64, outcome: call_outcome.Call_Outcome) {
	armed := false
	deadline := asked_at + powerbox.CONSENT_ARM_MILLISECONDS + system.TEST_HANG_BOUND_MILLISECONDS
	for {
		rows: [1]pr.Plan_Generation_Row
		arguments := [1]isolated.Argument{{integer = u64(ticket)}}
		error^ = {}
		generation, outcome = system.call_isolated(&plans.connection, plans.file, plans.poll_export, arguments[:], error, false, bytes_of(&rows))
		if outcome != .Succeeded || generation != 0 {
			generation_row^ = rows[0]
			return generation, outcome
		}
		now := system.time()
		if !armed && now >= asked_at + powerbox.CONSENT_ARM_MILLISECONDS {
			armed = true
			system.log_fact(.Info, Dialog_Armed{ticket = u64(ticket)}, plan_name)
		}
		if now >= deadline {
			wrong("no decision of the principal came within the hang bound, in milliseconds:", system.TEST_HANG_BOUND_MILLISECONDS)
		}
		wait := system.wait_begin()
		system.wait_end(&wait, now + POLL_MILLISECONDS)
	}
}

// refusal_check checks a refusal whole: the call failed with the outcome
// that the case waits for, its error record has the kind, the unit, the argument and the refusal that the case
// waits for, and generation 0 is still current.
@(private = "file")
refusal_check :: proc "contextless" (what: string, result: i64, outcome: call_outcome.Call_Outcome, error: errors.Error_Record, wanted_outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit, argument: i64, refusal: pr.Plan_Refusal) {
	if outcome != wanted_outcome || result != 0 || error.kind != i64(kind) || error.unit != i64(unit) || error.argument != argument || error.found != i64(refusal) {
		system.log_fact(.Error, Wrong_Refusal{result = result, outcome = call_outcome.Call_Outcome_Word(outcome), error_kind = error.kind, error_unit = error.unit, error_argument = error.argument, error_found = error.found, wanted_kind = i64(kind), wanted_unit = i64(unit), wanted_argument = argument, wanted_found = i64(refusal)}, what)
		system.stop(.Failed)
	}
	current_check(what)
	system.log_fact(.Info, Refused_As_It_Must{refusal_code = u64(refusal)}, what)
}

// current_check checks that no plan of principal 0 is current.
@(private = "file")
current_check :: proc "contextless" (what: string) {
	error: errors.Error_Record
	generation, outcome := system.call_isolated(&plans.connection, plans.file, plans.generation_export, nil, &error)
	if outcome != .Succeeded || generation != 0 {
		system.log_fact(.Error, Wrong_Generation{generation = generation, outcome = call_outcome.Call_Outcome_Word(outcome)}, what)
		system.stop(.Failed)
	}
}

// refused_after_dialog applies a plan of one row, lets the tool answer its
// dialog, and checks the refusal of apply_poll.
@(private = "file")
refused_after_dialog :: proc "contextless" (plan_name: string, row: ^pr.Plan_Entry_Row, refusal: pr.Plan_Refusal, wanted_outcome: call_outcome.Call_Outcome, kind: errors.Kind, unit: errors.Unit, argument: i64) {
	expected: pr.Plan_Expected
	error: errors.Error_Record
	ticket, applied := apply(plan_name, row, &expected, &error)
	if applied != .Succeeded || ticket <= 0 {
		wrong_call("plans.apply refused a plan before its dialog", applied, error)
	}
	system.log_fact(.Info, Difference_Shown{ticket = u64(ticket)}, plan_name)
	generation_row: pr.Plan_Generation_Row
	result, outcome := decision_wait(plan_name, ticket, system.time(), &generation_row, &error)
	refusal_check(plan_name, result, outcome, error, wanted_outcome, kind, unit, argument, refusal)
}

@(export, link_name = "entry")
entry :: proc "c" (ctx: ^system.Context) -> ! {
	image_handle := ctx.handles[system.GRANT_IMAGE]
	address, map_status := system.memory_map(image_handle, {})
	if image_handle == 0 || map_status != .Succeeded {
		wrong("the boot image does not map; the status word", u64(map_status))
	}
	image := ([^]u8)(address)[:ctx.values[system.GRANT_VALUE_IMAGE_SIZE]]
	holder_file := system.image_find(image, HOLDER_MODULE)
	not_filling_file := system.image_find(image, NOT_FILLING_MODULE)
	if len(holder_file) == 0 || len(not_filling_file) == 0 {
		wrong("the boot image lacks settings_stand_in or generic_source; the size of the first", u64(len(holder_file)))
	}
	plans.file = system.image_find(image, "plans")
	plans.apply_export = module.export_find(plans.file, "apply")
	plans.poll_export = module.export_find(plans.file, "apply_poll")
	plans.generation_export = module.export_find(plans.file, "current_generation")
	if plans.apply_export == 0 || plans.poll_export == 0 || plans.generation_export == 0 {
		wrong("the module plans lacks apply, apply_poll or current_generation; the size of its file", u64(len(plans.file)))
	}
	requests, ring_status := system.ring_open(ctx.handles[system.GRANT_ROOT], receive_handles = true)
	if ring_status != .Succeeded {
		wrong("no root ring; the status word", u64(ring_status))
	}
	// The role name reaches the holder of Plans in force.
	connected: call_outcome.Call_Outcome
	plans.connection, connected = system.service_connection(&requests, 1, role_contract.role_properties(.Plans).name)
	if connected != .Succeeded {
		wrong("the root service gave no connection to the holder of Plans; the outcome word", u64(connected))
	}
	if blake3.Hash(plans.connection.module_hash) != blake3.hash(plans.file) {
		wrong("the holder of Plans is not the module plans of the boot image; the size of its file", u64(len(plans.file)))
	}
	current_check("the start")

	holder_hash := blake3.hash(holder_file)
	holder := holder_row(holder_hash, HOLDER_MODULE)

	// 1. A current plan that does not exist: no dialog.
	{
		expected := pr.Plan_Expected{current_plan_hash = value_kinds.Hash_Field(blake3.hash(transmute([]u8)string("no plan was applied")))}
		error: errors.Error_Record
		result, outcome := apply(PLAN_COMMITTED, &holder, &expected, &error)
		refusal_check("a Plan_Expected of a plan that is not current", result, outcome, error, .Another_Change_Came_First, .State, .Versions, 2, .Stale_Current_Plan)
	}
	// 2. The principal refuses the difference.
	refused_after_dialog(PLAN_REFUSED_BY_PRINCIPAL, &holder, .Refused_By_Principal, .Grant_Or_Right_Missing, .Refused, .Display, 0)
	// 3. A hash of no module of the image.
	{
		absent := holder_row(blake3.hash(transmute([]u8)string("no module has these bytes")), HOLDER_MODULE)
		refused_after_dialog(PLAN_NOT_IN_IMAGE, &absent, .Roles_Refused, .Argument_Refused, .Refused, .Grants, 1)
	}
	// 4. A module of the image that does not fill the contract of Settings.
	{
		not_filling := holder_row(blake3.hash(not_filling_file), NOT_FILLING_MODULE)
		refused_after_dialog(PLAN_CONTRACT_NOT_FILLED, &not_filling, .Roles_Refused, .Argument_Refused, .Refused, .Grants, 1)
	}

	// The plan that commits, last: the holder of Settings, and a value of
	// the plan for storage, which started before plans and gets it at the
	// apply and at each later start of the machine.
	rows := [2]pr.Plan_Entry_Row{0 = holder, 1 = keep_all_row()}
	expected: pr.Plan_Expected
	error: errors.Error_Record
	ticket, applied := apply_rows(PLAN_COMMITTED, rows[:], &expected, &error)
	if applied != .Succeeded || ticket <= 0 {
		wrong_call("plans.apply refused the plan", applied, error)
	}
	system.log_fact(.Info, Difference_Shown{ticket = u64(ticket)}, PLAN_COMMITTED)
	generation_row: pr.Plan_Generation_Row
	generation, polled := decision_wait(PLAN_COMMITTED, ticket, system.time(), &generation_row, &error)
	if polled != .Succeeded || generation <= 0 {
		wrong_call("plans.apply_poll did not commit the accepted plan", polled, error)
	}
	if generation_row.generation != generation || generation_row.standing != .Current {
		wrong("the row of the applied generation does not name it as the current one; its generation", u64(generation_row.generation))
	}
	system.log_fact(.Info, Plan_Accepted{generation = u64(generation)})
	system.call_connection_end(&plans.connection)
	system.stop(.Done)
}
