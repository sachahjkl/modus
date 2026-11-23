#+build !freestanding
package plans_core

import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/plan_values"
import pr "modus:contract/plans_recipes"
import rd "modus:contract/root_delegation"

// The set of the values of a plan: the entries of each owner in its
// records, a lock apart from a default, the other kinds left out; the set
// passes the check of the core. A plan with no value is a set of no owner.
@(test)
the_values_of_a_plan_become_one_set :: proc(t: ^testing.T) {
	plan: pr.Plan_Spec
	add :: proc(plan: ^pr.Plan_Spec, owner, field: string, word: u64, layer: chosen_values.Layer) {
		entry, _ := pr.plan_entry_make_value(owner, field, word, layer)
		plan.entries[plan.entry_count] = entry
		plan.entry_count += 1
	}
	add(&plan, "display", "bar_edge", 2, .Plan_Default)
	add(&plan, "storage", "keep_all_minutes", 30, .Locked)
	add(&plan, "display", "consent_arm_milliseconds", 1000, .Locked)
	store, _ := pr.plan_entry_make_store("notes", .Read_Only)
	plan.entries[plan.entry_count] = store
	plan.entry_count += 1
	out: [plan_values.SET_SIZE]u8
	written, ok := plan_values_set_of(&plan, 4, out[:])
	testing.expect(t, ok && written > 0)
	head, problem := plan_values.set_check(out[:])
	testing.expect(t, problem == .None && head.owner_count == 2 && head.generation == 4)
	display, found := plan_values.owner_values_of(out[:], "display")
	testing.expect(t, found && display.defaults.count == 1 && display.locks.count == 1 && plan_values.locked(display, "consent_arm_milliseconds", any_word))
	storage, storage_found := plan_values.owner_values_of(out[:], "storage")
	testing.expect(t, storage_found && plan_values.locked(storage, "keep_all_minutes", any_word))
	_, notes := plan_values.owner_values_of(out[:], "notes")
	testing.expect(t, !notes)
	none: [plan_values.SET_SIZE]u8
	none_written, none_ok := plan_values_set_of(nil, 0, none[:])
	testing.expect(t, none_ok && none_written == plan_values.SET_HEADER_SIZE)
	// A damaged entry that passed no border is refused, not sent.
	damaged := plan
	damaged.entries[0].value_layer_word = 2
	_, damaged_ok := plan_values_set_of(&damaged, 4, out[:])
	testing.expect(t, !damaged_ok)
}

// With no port, a plan of principal 0 with a value is refused and one with
// none passes; a plan of another principal sends nothing. A refusal of the
// core is a refusal of the apply.
@(test)
values_with_no_port_or_a_refusal_are_refused :: proc(t: ^testing.T) {
	state: Plans_State
	plan: pr.Plan_Spec
	entry, _ := pr.plan_entry_make_value("display", "bar_edge", 2, .Plan_Default)
	plan.entries[0], plan.entry_count = entry, 1
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, &plan, 1, .Apply), pr.Plan_Refusal.Values_Refused)
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, nil, 1, .Apply), pr.Plan_Refusal.None)
	testing.expect_value(t, values_give(&state, 7, &plan, 1, .Apply), pr.Plan_Refusal.None)
	refuse :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		return .Bad_Record, true
	}
	silent :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		return .None, false
	}
	state.values = {replace = refuse}
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, &plan, 1, .Apply), pr.Plan_Refusal.Values_Refused)
	testing.expect_value(t, state.values_problem, plan_values.Set_Problem.Bad_Record)
	state.values = {replace = silent}
	testing.expect_value(t, values_give(&state, MACHINE_PRINCIPAL, &plan, 1, .Apply), pr.Plan_Refusal.Values_Refused)
}

// A send again of the values: one that the core takes marks nothing; one
// that the core refuses for its content is sent once and marks the state
// with its generation and the problem; one with no answer is sent
// VALUES_SEND_TRIES times, with a pause between, and marks No_Answer; a
// plan of another principal sends nothing.
@(test)
a_refused_send_again_of_the_values_marks_the_state :: proc(t: ^testing.T) {
	@(static) sends: int
	@(static) pauses: int
	state := new(Plans_State, context.temp_allocator)
	plan: pr.Plan_Spec
	entry, _ := pr.plan_entry_make_value("display", "bar_edge", 2, .Plan_Default)
	plan.entries[0], plan.entry_count = entry, 1
	take :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		sends += 1
		return .None, true
	}
	refuse_rollback :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		sends += 1
		return step == .Rollback ? .Bad_Record : .None, true
	}
	silent :: proc "contextless" (user: rawptr, set: []u8, step: rd.Plan_Roles_Step) -> (problem: plan_values.Set_Problem, answered: bool) {
		sends += 1
		return .None, false
	}
	pause :: proc "contextless" (user: rawptr) {pauses += 1}
	state.roles.pause = pause
	state.values = {replace = take}
	sends = 0
	testing.expect(t, values_resend(state, MACHINE_PRINCIPAL, &plan, 3))
	testing.expect(t, !state.values_unreconciled && sends == 1)
	state.values = {replace = refuse_rollback}
	sends = 0
	testing.expect(t, values_resend(state, 7, &plan, 3))
	testing.expect(t, !state.values_unreconciled && sends == 0)
	testing.expect(t, !values_resend(state, MACHINE_PRINCIPAL, &plan, max(u64)))
	testing.expect(t, state.values_unreconciled && state.values_unreconciled_generation == max(u64) && sends == 1)
	testing.expect_value(t, state.values_cause, Values_Cause.Refused)
	testing.expect_value(t, state.values_problem, plan_values.Set_Problem.Bad_Record)
	state.values_unreconciled = false
	state.values = {replace = silent}
	sends, pauses = 0, 0
	testing.expect(t, !values_resend(state, MACHINE_PRINCIPAL, &plan, 0))
	testing.expect(t, state.values_unreconciled && state.values_unreconciled_generation == 0)
	testing.expect_value(t, state.values_cause, Values_Cause.No_Answer)
	testing.expect_value(t, sends, VALUES_SEND_TRIES)
	testing.expect_value(t, pauses, VALUES_SEND_TRIES - 1)
}

// The commit of a generation: one that the core takes at the second send
// marks nothing; one that it never takes is sent VALUES_SEND_TRIES times
// and marks Not_Committed; a plan of another principal and a port with no
// commit send nothing.
@(test)
a_commit_that_the_core_does_not_take_marks_the_state :: proc(t: ^testing.T) {
	@(static) commits: int
	@(static) take_at: int
	state := new(Plans_State, context.temp_allocator)
	commit :: proc "contextless" (user: rawptr, generation: u64) -> (taken: bool, answered: bool) {
		commits += 1
		return commits == take_at, true
	}
	values_commit(state, MACHINE_PRINCIPAL, 4)
	testing.expect(t, !state.values_unreconciled)
	state.values.commit = commit
	commits, take_at = 0, 2
	values_commit(state, 7, 4)
	testing.expect(t, commits == 0 && !state.values_unreconciled)
	values_commit(state, MACHINE_PRINCIPAL, 4)
	testing.expect(t, commits == 2 && !state.values_unreconciled)
	commits, take_at = 0, -1
	values_commit(state, MACHINE_PRINCIPAL, 5)
	testing.expect(t, commits == VALUES_SEND_TRIES && state.values_unreconciled && state.values_unreconciled_generation == 5)
	testing.expect_value(t, state.values_cause, Values_Cause.Not_Committed)
}

@(private = "file")
any_word :: proc "contextless" (word: u64) -> bool {return true}

// A text of the plan reaches its owner: the set keeps it as a text entry,
// the page of the owner gives it back, and text_in_force reads it by the
// precedence; a word of the same set stays a word. The largest plan of
// texts, 32 of 256 bytes for one owner, fits the set.
@(test)
a_text_of_the_plan_reaches_its_owner :: proc(t: ^testing.T) {
	plan: pr.Plan_Spec
	home, _ := pr.plan_entry_make_text_value("browser", "home", "http://example.org/a,b", .Plan_Default)
	interval, _ := pr.plan_entry_make_value("monitor", "sample_interval", 1000, .Locked)
	plan.entries[0], plan.entries[1], plan.entry_count = home, interval, 2
	out: [plan_values.SET_SIZE]u8
	written, ok := plan_values_set_of(&plan, 2, out[:])
	testing.expect(t, ok && written > 0)
	browser, found := plan_values.owner_values_of(out[:], "browser")
	testing.expect(t, found)
	page: [plan_values.OWNER_PAGE_SIZE]u8
	testing.expect(t, plan_values.owner_page_write(page[:], browser))
	read, read_ok := plan_values.owner_page_read(page[:])
	testing.expect(t, read_ok)
	any_text :: proc "contextless" (text: string) -> bool {return true}
	text, layer, text_found := plan_values.text_in_force("home", {}, read, any_text)
	testing.expect(t, text_found && text == "http://example.org/a,b" && layer == .Plan_Default)
	_, word_found := chosen_values.find(read.defaults, "home")
	testing.expect(t, !word_found)
	monitor, _ := plan_values.owner_values_of(out[:], "monitor")
	word, word_ok := chosen_values.find(monitor.locks, "sample_interval")
	testing.expect(t, word_ok && word == 1000)
	// 32 texts of 256 bytes for one owner.
	TEXTS :: 32
	full := test_plan(0, 0, TEXTS)
	long: [pr.PLAN_VALUE_TEXT_BYTES]u8
	for &byte in long {
		byte = 'a'
	}
	field: [3]u8 = {'f', 'a', 'a'}
	for index in 0 ..< TEXTS {
		field[1], field[2] = 'a' + u8(index / 26), 'a' + u8(index % 26)
		full.entries[index], _ = pr.plan_entry_make_text_value("browser", string(field[:]), string(long[:]), .Plan_Default)
	}
	// 32 texts of 256 bytes do not fit the page of one owner: the border of
	// the plan refuses them at the entry that passes the page, and the core
	// would refuse the set; the entries that fit pass.
	full.entry_count = TEXTS
	refusal, bad := pr.plan_validate(&full)
	testing.expect_value(t, refusal, pr.Plan_Refusal.Values_Too_Large)
	per_entry := chosen_values.ENTRY_SIZE + pr.PLAN_VALUE_TEXT_BYTES
	testing.expect_value(t, int(bad), plan_values.OWNER_BYTES_MOST / per_entry)
	full.entry_count = bad
	fitting, _ := pr.plan_validate(&full)
	testing.expect_value(t, fitting, pr.Plan_Refusal.None)
	fitting_written, fitting_ok := plan_values_set_of(&full, 3, out[:])
	testing.expect(t, fitting_ok && fitting_written > 0)
	fitting_values, _ := plan_values.owner_values_of(out[:], "browser")
	testing.expect(t, plan_values.owner_fits_page(fitting_values))
}

