#+build !freestanding
package plans_core

import "core:strings"
import "core:testing"
import "modus:contract/blake3"
import pr "modus:contract/plans_recipes"
import "modus:contract/start_grant"

// plans_test_state_init starts state with a memory store that the test frees.
plans_test_state_init :: proc(state: ^Plans_State, display_slot: u32) -> ^pr.Memory_Private_Store {
	store := new(pr.Memory_Private_Store)
	state_init(state, display_slot, pr.memory_private_store_port(store))
	return store
}

// A trusted display that a test drives: it gives serials from 1, keeps the
// texts of the last dialog, and answers each poll with the decision that the
// test set for the serial.
@(private = "file")
Test_Display :: struct {
	next_serial:   u64,
	asks:          int,
	polls:         int,
	refuse_to_ask: bool,
	poll_fails:    bool,
	plan_name:     string,
	added:         string,
	removed:       string,
	decisions:     [16]pr.Plan_Display_Decision,
}

@(private = "file")
test_display_ask :: proc "contextless" (user: rawptr, plan_name: string, added: string, removed: string) -> (serial: u64, ok: bool) {
	display := (^Test_Display)(user)
	display.asks += 1
	if display.refuse_to_ask {
		return 0, false
	}
	display.next_serial += 1
	display.plan_name, display.added, display.removed = plan_name, added, removed
	return display.next_serial, true
}

@(private = "file")
test_display_poll :: proc "contextless" (user: rawptr, serial: u64) -> (decision: pr.Plan_Display_Decision, ok: bool) {
	display := (^Test_Display)(user)
	display.polls += 1
	if display.poll_fails {
		return .Unknown, false
	}
	if serial == 0 || serial >= len(display.decisions) {
		return .Unknown, true
	}
	return display.decisions[serial], true
}

@(private = "file")
test_display_port :: proc(display: ^Test_Display) -> Trusted_Display_Port {
	return {user = display, ask = test_display_ask, poll = test_display_poll}
}

@(private = "file")
trusted_test_hash :: proc(tag: u8) -> blake3.Hash {
	data := [4]u8{'t', 'r', 'u', tag}
	return blake3.hash(data[:])
}

@(private = "file")
module_plan :: proc(principal: u64, tag: u8, grants: u64) -> pr.Plan_Spec {
	plan := pr.Plan_Spec{principal = principal, entry_count = 1}
	plan.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", trusted_test_hash(tag), grants)
	return plan
}

// accepted_apply asks for plan and accepts it, and gives the committed record.
@(private = "file")
accepted_apply :: proc(t: ^testing.T, state: ^Plans_State, display: ^Test_Display, plan: ^pr.Plan_Spec, expected: blake3.Hash, now_ms: u64) -> pr.Applied_Plan_Record {
	port := test_display_port(display)
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists
	ticket, refusal := apply_request(state, &port, "home", plan, expected, &difference, &lists)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	display.decisions[ticket] = .Accepted
	record, finished, poll_refusal := apply_poll(state, &port, plan.principal, ticket, now_ms, &difference)
	testing.expect(t, finished)
	testing.expect_value(t, poll_refusal, pr.Plan_Refusal.None)
	return record
}

@(test)
test_plans_refusal_on_the_trusted_display_changes_nothing :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)
	display: Test_Display
	port := test_display_port(&display)
	store_bit := u64(1) << u64(start_grant.Grant.Store)

	plan := module_plan(0, 1, store_bit)
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists
	ticket, refusal := apply_request(state, &port, "home", &plan, {}, &difference, &lists)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, ticket, u64(1))
	testing.expect_value(t, display.plan_name, "home")
	testing.expect_value(t, display.added, "disk calc")
	testing.expect_value(t, display.removed, "")
	testing.expect_value(t, pending_ticket(state, 0), ticket)

	// While the dialog shows, a poll finishes nothing and commits nothing.
	_, finished, pending_refusal := apply_poll(state, &port, 0, ticket, 100, &difference)
	testing.expect(t, !finished)
	testing.expect_value(t, pending_refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, highest_generation(state, 0), u64(0))

	// A poll of another ticket, of ticket 0, and of another principal finds
	// no pending apply, and the pending apply stays.
	for bad_ticket in ([?]u64{0, ticket + 1, max(u64)}) {
		_, bad_finished, bad_refusal := apply_poll(state, &port, 0, bad_ticket, 100, &difference)
		testing.expect(t, bad_finished)
		testing.expect_value(t, bad_refusal, pr.Plan_Refusal.No_Pending_Apply)
	}
	_, _, other_principal := apply_poll(state, &port, 1, ticket, 100, &difference)
	testing.expect_value(t, other_principal, pr.Plan_Refusal.No_Pending_Apply)
	testing.expect_value(t, pending_ticket(state, 0), ticket)

	// The principal refuses: no generation, no write in the store, and the
	// pending apply ends.
	display.decisions[ticket] = .Refused
	record, refused_finished, refused := apply_poll(state, &port, 0, ticket, 200, &difference)
	testing.expect(t, refused_finished)
	testing.expect_value(t, refused, pr.Plan_Refusal.Refused_By_Principal)
	testing.expect_value(t, record, pr.Applied_Plan_Record{})
	testing.expect_value(t, highest_generation(state, 0), u64(0))
	testing.expect_value(t, store.writes, 0)
	testing.expect_value(t, pending_ticket(state, 0), u64(0))
	_, _, again := apply_poll(state, &port, 0, ticket, 300, &difference)
	testing.expect_value(t, again, pr.Plan_Refusal.No_Pending_Apply)
	_, _, found := current_plan(state, 0)
	testing.expect(t, !found, "a refused plan is never current")
}

@(test)
test_plans_accept_commits_and_rollback_restores_the_exact_prior_state :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)
	display: Test_Display
	network_bit := u64(1) << u64(start_grant.Grant.Network)

	first_plan := module_plan(3, 1, 0)
	first := accepted_apply(t, state, &display, &first_plan, {}, 100)
	testing.expect_value(t, first.generation, u64(1))
	second_plan := module_plan(3, 2, network_bit)
	second := accepted_apply(t, state, &display, &second_plan, first.plan_hash, 200)
	testing.expect_value(t, second.generation, u64(2))
	testing.expect_value(t, second.previous_plan_hash, first.plan_hash)
	testing.expect_value(t, display.added, "disk calc changed")

	// Each generation and the current object are in the store.
	for name in ([?]string{"plan_3_1", "plan_3_2", "plan_3_current"}) {
		testing.expectf(t, pr.memory_private_store_find(store, name) != nil, "the store holds %s", name)
	}

	// The rollback selects generation 1, and the service that starts again
	// reads the same state from the store: the plan of generation 1 whole.
	selected, refusal := rollback(state, 3)
	testing.expect_value(t, refusal, pr.Plan_Refusal.None)
	testing.expect_value(t, selected, first)
	forget(state)
	plan, record, found := current_plan(state, 3)
	testing.expect(t, found)
	testing.expect_value(t, record, first)
	reread_hash, _ := pr.plan_hash(plan)
	testing.expect(t, reread_hash == first.plan_hash && plan.entry_count == first_plan.entry_count && plan.entries[0] == first_plan.entries[0], "the store gives back the plan of generation 1")
	testing.expect_value(t, highest_generation(state, 3), u64(2))

	// A second rollback has no generation before the first: it is refused,
	// and the store and the current generation do not change.
	writes := store.writes
	current_object := pr.memory_private_store_find(store, "plan_3_current")
	current_before := string(current_object.bytes[:current_object.length])
	_, double := rollback(state, 3)
	testing.expect_value(t, double, pr.Plan_Refusal.Empty_History)
	testing.expect_value(t, store.writes, writes)
	testing.expect_value(t, string(current_object.bytes[:current_object.length]), current_before)
	_, record, _ = current_plan(state, 3)
	testing.expect_value(t, record.generation, u64(1))

	// The next apply writes generation 3 and never overwrites generation 2.
	generation_object := pr.memory_private_store_find(store, "plan_3_2")
	generation_two := string(generation_object.bytes[:generation_object.length])
	third_plan := module_plan(3, 3, 0)
	third := accepted_apply(t, state, &display, &third_plan, first.plan_hash, 300)
	testing.expect_value(t, third.generation, u64(3))
	testing.expect_value(t, string(generation_object.bytes[:generation_object.length]), generation_two)
}

@(test)
test_plans_apply_request_refuses_each_bad_input_and_asks_nothing :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)
	display: Test_Display
	port := test_display_port(&display)
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists
	plan := module_plan(0, 1, 0)

	long_name := strings.repeat("n", pr.PLAN_DISPLAY_NAME_BYTES + 1, context.temp_allocator)
	_, empty_name := apply_request(state, &port, "", &plan, {}, &difference, &lists)
	testing.expect_value(t, empty_name, pr.Plan_Refusal.Invalid_Name)
	_, long := apply_request(state, &port, long_name, &plan, {}, &difference, &lists)
	testing.expect_value(t, long, pr.Plan_Refusal.Invalid_Name)
	_, no_plan := apply_request(state, &port, "home", nil, {}, &difference, &lists)
	testing.expect_value(t, no_plan, pr.Plan_Refusal.Empty_Plan)
	_, no_buffer := apply_request(state, &port, "home", &plan, {}, nil, &lists)
	testing.expect_value(t, no_buffer, pr.Plan_Refusal.Buffer_Too_Small)
	_, stale := apply_request(state, &port, "home", &plan, trusted_test_hash(9), &difference, &lists)
	testing.expect_value(t, stale, pr.Plan_Refusal.Stale_Current_Plan)
	_, no_display := apply_request(state, nil, "home", &plan, {}, &difference, &lists)
	testing.expect_value(t, no_display, pr.Plan_Refusal.Consent_Required)

	// A plan whose additions do not fit the dialog: nine entries.
	nine := pr.Plan_Spec{principal = 0, entry_count = 9}
	names := [9]string{"a", "b", "c", "d", "e", "f", "g", "h", "i"}
	for name, index in names {
		nine.entries[index], _ = pr.plan_entry_make_module(.Disk_Module, name, trusted_test_hash(u8(index + 1)), 0)
	}
	_, too_many := apply_request(state, &port, "home", &nine, {}, &difference, &lists)
	testing.expect_value(t, too_many, pr.Plan_Refusal.Display_Refused)
	// An item past the bytes of an item: a name of 48 bytes after "disk ".
	long_entry := pr.Plan_Spec{principal = 0, entry_count = 1}
	long_entry.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, strings.repeat("m", 44, context.temp_allocator), trusted_test_hash(1), 0)
	_, item_too_long := apply_request(state, &port, "home", &long_entry, {}, &difference, &lists)
	testing.expect_value(t, item_too_long, pr.Plan_Refusal.Display_Refused)
	// The last byte that fits: "disk " and 43 bytes.
	edge_entry := pr.Plan_Spec{principal = 0, entry_count = 1}
	edge_entry.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, strings.repeat("m", 43, context.temp_allocator), trusted_test_hash(1), 0)

	// The display that does not show the dialog: nothing is pending.
	display.refuse_to_ask = true
	_, not_shown := apply_request(state, &port, "home", &edge_entry, {}, &difference, &lists)
	testing.expect_value(t, not_shown, pr.Plan_Refusal.Display_Refused)
	testing.expect_value(t, display.asks, 1)
	testing.expect_value(t, pending_ticket(state, 0), u64(0))
	testing.expect_value(t, store.writes, 0)
	display.refuse_to_ask = false

	ticket, shown := apply_request(state, &port, "home", &edge_entry, {}, &difference, &lists)
	testing.expect_value(t, shown, pr.Plan_Refusal.None)
	testing.expect_value(t, len(display.added), pr.PLAN_DISPLAY_ITEM_BYTES)

	// A second apply while the dialog of the first shows is refused, and the
	// first stays pending.
	_, busy := apply_request(state, &port, "home", &plan, {}, &difference, &lists)
	testing.expect_value(t, busy, pr.Plan_Refusal.Apply_Pending)
	testing.expect_value(t, pending_ticket(state, 0), ticket)

	// The dialog closed with no poll of plans: the next request drops the
	// pending apply uncommitted and asks for its own.
	display.decisions[ticket] = .Accepted
	next, replaced := apply_request(state, &port, "home", &plan, {}, &difference, &lists)
	testing.expect_value(t, replaced, pr.Plan_Refusal.None)
	testing.expect(t, next != ticket)
	testing.expect_value(t, highest_generation(state, 0), u64(0))
	_, _, old_ticket := apply_poll(state, &port, 0, ticket, 100, &difference)
	testing.expect_value(t, old_ticket, pr.Plan_Refusal.No_Pending_Apply)

	// A display that no longer answers drops the pending apply.
	display.poll_fails = true
	_, _, gone := apply_poll(state, &port, 0, next, 100, &difference)
	testing.expect_value(t, gone, pr.Plan_Refusal.Display_Refused)
	testing.expect_value(t, pending_ticket(state, 0), u64(0))
	display.poll_fails = false

	// A decision that the display no longer knows commits nothing.
	unknown_ticket, _ := apply_request(state, &port, "home", &plan, {}, &difference, &lists)
	display.decisions[unknown_ticket] = .Unknown
	_, _, unknown := apply_poll(state, &port, 0, unknown_ticket, 100, &difference)
	testing.expect_value(t, unknown, pr.Plan_Refusal.Display_Refused)
	testing.expect_value(t, store.writes, 0)

	// The current plan again is no change: the dialog has nothing to show.
	committed := accepted_apply(t, state, &display, &plan, {}, 100)
	_, same := apply_request(state, &port, "home", &plan, committed.plan_hash, &difference, &lists)
	testing.expect_value(t, same, pr.Plan_Refusal.No_Change)
}

@(test)
test_plans_accept_after_the_current_plan_changed_is_stale :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)
	display: Test_Display
	port := test_display_port(&display)
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists

	first_plan := module_plan(0, 1, 0)
	first := accepted_apply(t, state, &display, &first_plan, {}, 100)
	second_plan := module_plan(0, 2, 0)
	ticket, _ := apply_request(state, &port, "home", &second_plan, first.plan_hash, &difference, &lists)
	// Another way changes the current plan while the dialog shows.
	third_plan := module_plan(0, 3, 0)
	third, third_refusal := apply_plan(state, &third_plan, first.plan_hash, nil, nil, 150, &difference)
	testing.expect_value(t, third_refusal, pr.Plan_Refusal.None)
	writes := store.writes
	display.decisions[ticket] = .Accepted
	_, finished, refusal := apply_poll(state, &port, 0, ticket, 200, &difference)
	testing.expect(t, finished)
	testing.expect_value(t, refusal, pr.Plan_Refusal.Stale_Current_Plan)
	testing.expect_value(t, store.writes, writes)
	_, record, _ := current_plan(state, 0)
	testing.expect_value(t, record, third)
}

@(test)
test_plans_store_failure_commits_nothing :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)
	display: Test_Display
	port := test_display_port(&display)
	difference: pr.Plan_Difference
	lists: Plan_Display_Lists
	plan := module_plan(0, 1, 0)

	// No write passes, then only the generation object: each accept is
	// refused, and the tables do not change.
	for allowed in ([?]int{0, 1}) {
		store.writes_allowed = store.writes + allowed
		ticket, _ := apply_request(state, &port, "home", &plan, {}, &difference, &lists)
		display.decisions[ticket] = .Accepted
		_, _, refusal := apply_poll(state, &port, 0, ticket, 100, &difference)
		testing.expect_value(t, refusal, pr.Plan_Refusal.Store_Failed)
		testing.expect_value(t, highest_generation(state, 0), u64(0))
		testing.expect_value(t, pending_ticket(state, 0), u64(0))
	}
	// The generation object that no current object names is not history: a
	// service that starts again has no plan, and the next apply writes
	// generation 1 again.
	testing.expect(t, pr.memory_private_store_find(store, "plan_0_1") != nil)
	testing.expect(t, pr.memory_private_store_find(store, "plan_0_current") == nil)
	forget(state)
	testing.expect_value(t, highest_generation(state, 0), u64(0))
	store.writes_allowed = -1
	record := accepted_apply(t, state, &display, &plan, {}, 200)
	testing.expect_value(t, record.generation, u64(1))

	// A rollback whose write fails does not move the current generation.
	second_plan := module_plan(0, 2, 0)
	second := accepted_apply(t, state, &display, &second_plan, record.plan_hash, 300)
	store.writes_allowed = store.writes
	_, refused := rollback(state, 0)
	testing.expect_value(t, refused, pr.Plan_Refusal.Store_Failed)
	_, current, _ := current_plan(state, 0)
	testing.expect_value(t, current, second)
	forget(state)
	_, current, _ = current_plan(state, 0)
	testing.expect_value(t, current, second)
}

@(test)
test_plans_damaged_store_is_refused_whole :: proc(t: ^testing.T) {
	state := new(Plans_State)
	defer free(state)
	store := plans_test_state_init(state, 5)
	defer free(store)
	display: Test_Display
	first_plan := module_plan(0, 1, 0)
	first := accepted_apply(t, state, &display, &first_plan, {}, 100)
	second_plan := module_plan(0, 2, 0)
	_ = accepted_apply(t, state, &display, &second_plan, first.plan_hash, 200)

	generation := pr.memory_private_store_find(store, "plan_0_1")
	current := pr.memory_private_store_find(store, "plan_0_current")
	saved_generation, saved_current := new_clone(generation^), new_clone(current^)
	defer free(saved_generation)
	defer free(saved_current)
	damages := [?]struct {
		object: ^pr.Memory_Private_Object,
		offset: int,
		length: int,
	} {
		{generation, 0, -1}, // The magic.
		{generation, pr.PLAN_GENERATION_HEAD_SIZE + 40, -1}, // A byte of the module hash of the row.
		{generation, pr.PLAN_GENERATION_HEAD_SIZE + 128 + 10, -1}, // A byte after the name of the row.
		{generation, 8 + 80, -1}, // The generation of the record.
		{generation, -1, saved_generation.length - 1}, // One byte short.
		{generation, -1, saved_generation.length + 1}, // One byte more.
		{current, 0, -1},
		{current, 16, -1}, // The current generation.
		{current, 33, -1}, // The hash of the current plan.
		{current, -1, pr.PLAN_CURRENT_WIRE_SIZE - 1},
	}
	for damage, index in damages {
		generation^, current^ = saved_generation^, saved_current^
		if damage.offset >= 0 {
			damage.object.bytes[damage.offset] ~= 0x5a
		} else {
			damage.object.length = damage.length
		}
		forget(state)
		_, refusal := principal_entry(state, 0)
		testing.expectf(t, refusal == .Store_Damaged, "damage %d: %v", index, refusal)
		_, rollback_refusal := rollback(state, 0)
		testing.expectf(t, rollback_refusal == .Store_Damaged, "damage %d: rollback %v", index, rollback_refusal)
		_, _, found := current_plan(state, 0)
		testing.expect(t, !found)
		testing.expect(t, find_principal_for_test(state, 0) == nil)
	}
	// A current object that names a generation past the highest one.
	generation^, current^ = saved_generation^, saved_current^
	current.bytes[16] = 3
	forget(state)
	_, past := principal_entry(state, 0)
	testing.expect_value(t, past, pr.Plan_Refusal.Store_Damaged)
	// The store whole again: the history reads.
	current^ = saved_current^
	forget(state)
	_, whole := principal_entry(state, 0)
	testing.expect_value(t, whole, pr.Plan_Refusal.None)
}

@(private = "file")
find_principal_for_test :: proc(state: ^Plans_State, principal: u64) -> ^Principal_Plans_State {
	for &entry in state.principals {
		if entry.active && entry.principal == principal {
			return &entry
		}
	}
	return nil
}

@(test)
test_plans_display_lists_name_each_side :: proc(t: ^testing.T) {
	store_bit := u64(1) << u64(start_grant.Grant.Store)
	current := pr.Plan_Spec{principal = 0, entry_count = 3}
	current.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", trusted_test_hash(1), store_bit)
	current.entries[1], _ = pr.plan_entry_make_store("notes", .Read_Write)
	current.entries[2], _ = pr.plan_entry_make_module(.Start_Module, "clock", trusted_test_hash(2), 0)
	proposed := pr.Plan_Spec{principal = 0, entry_count = 3}
	proposed.entries[0], _ = pr.plan_entry_make_module(.Disk_Module, "calc", trusted_test_hash(1), 0)
	proposed.entries[1], _ = pr.plan_entry_make_store("notes", .Read_Only)
	proposed.entries[2], _ = pr.plan_entry_make_store("documents", .Read_Write)
	difference: pr.Plan_Difference
	testing.expect_value(t, pr.plan_diff_compute(&current, &proposed, &difference), pr.Plan_Refusal.None)
	lists: Plan_Display_Lists
	testing.expect_value(t, display_lists_of_difference(&difference, &lists), pr.Plan_Refusal.None)
	testing.expect_value(t, string(lists.added[:lists.added_length]), "store documents read write")
	testing.expect_value(t, string(lists.removed[:lists.removed_length]), "disk calc narrowed, store notes read, start clock")
}
