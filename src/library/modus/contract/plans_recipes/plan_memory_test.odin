#+build !freestanding
#+build !modus
package plans_recipes

// The memory of the plans of the tests: a plan of count entries with room
// for capacity, and a difference with room for each item of two plans.

TEST_PLAN_CAPACITY :: 64

test_plan :: proc(principal: u64, count: u32, capacity := TEST_PLAN_CAPACITY) -> Plan_Spec {
	bytes, _ := plan_bytes_for(max(int(count), capacity))
	plan := plan_of_memory(principal, make([]u8, bytes, context.temp_allocator))
	plan.entry_count = count
	return plan
}

// test_plan_copy gives a plan with the entries of plan in memory of its own:
// a change of the copy leaves plan as it was.
test_plan_copy :: proc(plan: ^Plan_Spec) -> Plan_Spec {
	copied := test_plan(plan.principal, 0, max(len(plan.entries), 1))
	plan_copy(&copied, plan)
	return copied
}

test_difference :: proc(capacity := 2 * TEST_PLAN_CAPACITY) -> Plan_Difference {
	return {changes = make([]Plan_Diff_Item, capacity, context.temp_allocator)}
}
