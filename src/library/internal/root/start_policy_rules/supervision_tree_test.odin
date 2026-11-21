#+build !freestanding
package start_policy_rules

import "core:testing"
import "modus:contract/start_list"
import "modus:contract/supervision"

@(test)
supervision_tree_refuses_invalid_init_and_registration :: proc(t: ^testing.T) {
	// Null and uninitialized tree refused everywhere.
	testing.expect_value(t, supervision_tree_init(nil, .One_For_One), Supervision_Refusal.Null_Tree)
	uninit: Supervision_Tree
	testing.expect_value(t, supervision_tree_init(&uninit, .None), Supervision_Refusal.Invalid_Strategy)
	testing.expect_value(t, supervision_tree_init(&uninit, supervision.Restart_Strategy(99)), Supervision_Refusal.Invalid_Strategy)
	testing.expect_value(t, uninit, Supervision_Tree{})

	testing.expect_value(t, supervision_tree_add_child(&uninit, {child_id = 1, child_strategy = .One_For_One}), Supervision_Refusal.Tree_Not_Initialized)
	testing.expect_value(t, supervision_tree_add_dependency(&uninit, 1, 2), Supervision_Refusal.Tree_Not_Initialized)
	testing.expect_value(t, supervision_tree_record_stop(&uninit, 1, .Fault, .None, 0).refusal, Supervision_Refusal.Tree_Not_Initialized)

	// Valid init.
	tree: Supervision_Tree
	testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)

	// Bad child configs leave tree unchanged.
	before := tree
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 0, child_strategy = .One_For_One}), Supervision_Refusal.Zero_Child_Id)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .None}), Supervision_Refusal.Invalid_Strategy)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = supervision.Restart_Strategy(77)}), Supervision_Refusal.Invalid_Strategy)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, max_restarts = start_list.RESTART_LIMIT + 1}), Supervision_Refusal.Restart_Limit_Exceeded)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, max_restarts = max(u32)}), Supervision_Refusal.Restart_Limit_Exceeded)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, parent_id = 1, child_strategy = .One_For_One}), Supervision_Refusal.Dependency_Cycle)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, parent_id = 99, child_strategy = .One_For_One}), Supervision_Refusal.Unknown_Parent)
	testing.expect_value(t, tree, before)

	// Duplicate child refused.
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, max_restarts = start_list.RESTART_LIMIT}), Supervision_Refusal.None)
	after_one := tree
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One}), Supervision_Refusal.Duplicate_Child)
	testing.expect_value(t, tree, after_one)

	// Fill tree to SUPERVISION_NODE_CAPACITY; one more is refused cleanly.
	for id in u32(2) ..= u32(SUPERVISION_NODE_CAPACITY) {
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = id, child_strategy = .One_For_One}), Supervision_Refusal.None)
	}
	full_before := tree
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = SUPERVISION_NODE_CAPACITY + 1, child_strategy = .One_For_One}), Supervision_Refusal.Tree_Full)
	testing.expect_value(t, tree, full_before)
}

@(test)
supervision_restart_bounds_cover_zero_one_exact_window_and_expiry :: proc(t: ^testing.T) {
	// Case 1: 0 restarts allowed (optional stops permanently; needed escalates immediately).
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, needed = false, max_restarts = 0, window_milliseconds = 0}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 2, child_strategy = .One_For_One, needed = true, max_restarts = 0, window_milliseconds = 60_000}), Supervision_Refusal.None)

		dec_opt := supervision_tree_record_stop(&tree, 1, .Fault, .None, 100)
		testing.expect_value(t, dec_opt.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec_opt.action, supervision.Escalation_Action.Stop_Permanently)
		testing.expect_value(t, dec_opt.restart_count, 0)

		dec_need := supervision_tree_record_stop(&tree, 2, .Fault, .None, 100)
		testing.expect_value(t, dec_need.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec_need.action, supervision.Escalation_Action.Escalate_To_Parent)
		testing.expect_value(t, dec_need.escalated_to_id, u32(0))
		testing.expect_value(t, dec_need.restart_count, 0)
	}

	// Case 2: 1 restart allowed.
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, needed = true, max_restarts = 1, window_milliseconds = 0}), Supervision_Refusal.None)

		dec1 := supervision_tree_record_stop(&tree, 1, .Itself, .Failed, 0)
		testing.expect_value(t, dec1.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec1.action, supervision.Escalation_Action.Restart_Child)
		testing.expect_value(t, dec1.restarts_in_window, u64(1))

		dec2 := supervision_tree_record_stop(&tree, 1, .Itself, .Failed, 999_999_999)
		testing.expect_value(t, dec2.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec2.action, supervision.Escalation_Action.Escalate_To_Parent)
		testing.expect_value(t, dec2.escalated_to_id, u32(0))
	}

	// Case 3: Exact bound 5 restarts in 60s -> 6th within 60s escalates.
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 10, child_strategy = .One_For_One, needed = true, max_restarts = 5, window_milliseconds = 60_000}), Supervision_Refusal.None)

		for idx in u64(1) ..= 5 {
			dec := supervision_tree_record_stop(&tree, 10, .Fault, .None, idx * 1_000)
			testing.expect_value(t, dec.refusal, Supervision_Refusal.None)
			testing.expect_value(t, dec.action, supervision.Escalation_Action.Restart_Child)
			testing.expect_value(t, dec.restarts_in_window, idx)
		}
		// Exactly 60_000 ms after the 1st restart (t = 1_000 -> t = 61_000) is still within 60s -> escalates!
		dec6 := supervision_tree_record_stop(&tree, 10, .Fault, .None, 61_000)
		testing.expect_value(t, dec6.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec6.action, supervision.Escalation_Action.Escalate_To_Parent)
		testing.expect_value(t, dec6.escalated_to_id, u32(0))
		testing.expect_value(t, dec6.restarts_in_window, u64(5))
	}

	// Case 4: Exact bound 5 restarts in 60s -> 6th after 60s + 1ms succeeds!
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 10, child_strategy = .One_For_One, needed = true, max_restarts = 5, window_milliseconds = 60_000}), Supervision_Refusal.None)

		for idx in u64(1) ..= 5 {
			dec := supervision_tree_record_stop(&tree, 10, .Fault, .None, idx * 1_000)
			testing.expect_value(t, dec.action, supervision.Escalation_Action.Restart_Child)
		}
		// 60s + 1ms after 1st restart (t = 61_001) prunes t = 1_000 -> succeeds!
		dec6 := supervision_tree_record_stop(&tree, 10, .Fault, .None, 61_001)
		testing.expect_value(t, dec6.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec6.action, supervision.Escalation_Action.Restart_Child)
		testing.expect_value(t, dec6.restarts_in_window, u64(5))

		// Immediate 7th at t = 61_001 (2_000 is only 59_001ms old) escalates!
		dec7 := supervision_tree_record_stop(&tree, 10, .Fault, .None, 61_001)
		testing.expect_value(t, dec7.action, supervision.Escalation_Action.Escalate_To_Parent)
	}

	// Case 5: Ring wrap-around past RESTART_WINDOW_RING_CAPACITY and u64 near max(u64).
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, needed = true, max_restarts = start_list.RESTART_LIMIT, window_milliseconds = 1_000}), Supervision_Refusal.None)

		// 40 restarts spaced 100ms apart: at most 11 in any 1000ms window, wraps ring > 2 times.
		base := max(u64) - 10_000
		for i in u64(0) ..< 40 {
			dec := supervision_tree_record_stop(&tree, 1, .Fault, .None, base + i * 100)
			testing.expect_value(t, dec.refusal, Supervision_Refusal.None)
			testing.expect_value(t, dec.action, supervision.Escalation_Action.Restart_Child)
		}
	}
}

@(test)
supervision_whole_uptime_never_forgets_and_backwards_clock_is_refused :: proc(t: ^testing.T) {
	tree: Supervision_Tree
	testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
	// Child 1: window_milliseconds == 0 (whole uptime, never reads clock).
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, needed = true, max_restarts = 2, window_milliseconds = 0}), Supervision_Refusal.None)
	// Child 2: window_milliseconds == 60_000 (timed window, enforces monotonic clock).
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 2, child_strategy = .One_For_One, needed = false, max_restarts = 3, window_milliseconds = 60_000}), Supervision_Refusal.None)

	// Child 1 restarts twice; clock values are never inspected (even going backwards or jumping hours later).
	testing.expect_value(t, supervision_tree_record_stop(&tree, 1, .Fault, .None, 5_000).action, supervision.Escalation_Action.Restart_Child)
	testing.expect_value(t, supervision_tree_record_stop(&tree, 1, .Fault, .None, 100).action, supervision.Escalation_Action.Restart_Child)
	testing.expect(t, !tree.nodes[0].history.has_last_timestamp, "window == 0 must never record a clock timestamp")
	// Even 10 hours later (36_000_000 ms), whole-uptime window never forgets!
	dec3 := supervision_tree_record_stop(&tree, 1, .Fault, .None, 36_000_000)
	testing.expect_value(t, dec3.action, supervision.Escalation_Action.Escalate_To_Parent)
	testing.expect_value(t, dec3.restarts_in_window, u64(2))

	// Child 2 records stop at t = 10_000; backwards timestamps (9_999, 0) are refused with tree unchanged!
	testing.expect_value(t, supervision_tree_record_stop(&tree, 2, .Fault, .None, 10_000).action, supervision.Escalation_Action.Restart_Child)
	before_backwards := tree
	testing.expect_value(t, supervision_tree_record_stop(&tree, 2, .Fault, .None, 9_999).refusal, Supervision_Refusal.Clock_Moved_Backwards)
	testing.expect_value(t, supervision_tree_record_stop(&tree, 2, .Fault, .None, 0).refusal, Supervision_Refusal.Clock_Moved_Backwards)
	testing.expect_value(t, tree, before_backwards)

	// Invalid stop words refused with tree unchanged.
	testing.expect_value(t, supervision_tree_record_stop(&tree, 2, .None, .None, 10_000).refusal, Supervision_Refusal.Invalid_Stop_Words)
	testing.expect_value(t, supervision_tree_record_stop(&tree, 2, .Fault, .Failed, 10_000).refusal, Supervision_Refusal.Invalid_Stop_Words)
	testing.expect_value(t, supervision_tree_record_stop(&tree, 2, .Itself, .None, 10_000).refusal, Supervision_Refusal.Invalid_Stop_Words)
	testing.expect_value(t, tree, before_backwards)

	// Clean Done and Refused stops never restart and do not consume a restart slot.
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 3, child_strategy = .One_For_One, needed = true, max_restarts = 5}), Supervision_Refusal.None)
	dec_done := supervision_tree_record_stop(&tree, 3, .Itself, .Done, 10_000)
	testing.expect_value(t, dec_done.refusal, Supervision_Refusal.None)
	testing.expect_value(t, dec_done.action, supervision.Escalation_Action.Stop_Permanently)
	testing.expect_value(t, dec_done.restarts_in_window, u64(0))

	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 4, child_strategy = .One_For_One, needed = true, max_restarts = 5}), Supervision_Refusal.None)
	dec_refused := supervision_tree_record_stop(&tree, 4, .Itself, .Refused, 10_000)
	testing.expect_value(t, dec_refused.refusal, Supervision_Refusal.None)
	testing.expect_value(t, dec_refused.action, supervision.Escalation_Action.Stop_Permanently)
	testing.expect_value(t, dec_refused.restarts_in_window, u64(0))
}

@(test)
supervision_strategies_compute_exact_stop_and_restart_orders :: proc(t: ^testing.T) {
	// One_For_All: stopping B restarts [A, B, C] and stops [C, B, A].
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_All), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 10, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 20, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 30, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)

		dec := supervision_tree_record_stop(&tree, 20, .Fault, .None, 100)
		testing.expect_value(t, dec.refusal, Supervision_Refusal.None)
		testing.expect_value(t, dec.action, supervision.Escalation_Action.Restart_Group)
		testing.expect_value(t, dec.restart_count, 3)
		testing.expect_value(t, dec.restart_order[0], u32(10))
		testing.expect_value(t, dec.restart_order[1], u32(20))
		testing.expect_value(t, dec.restart_order[2], u32(30))
		testing.expect_value(t, dec.stop_count, 3)
		testing.expect_value(t, dec.stop_order[0], u32(30))
		testing.expect_value(t, dec.stop_order[1], u32(20))
		testing.expect_value(t, dec.stop_order[2], u32(10))
	}

	// Rest_For_One: stopping B restarts [B, C]; stopping C restarts [C]; stopping A restarts [A, B, C].
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .Rest_For_One), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 10, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 20, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 30, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)

		dec_b := supervision_tree_record_stop(&tree, 20, .Fault, .None, 100)
		testing.expect_value(t, dec_b.action, supervision.Escalation_Action.Restart_Group)
		testing.expect_value(t, dec_b.restart_count, 2)
		testing.expect_value(t, dec_b.restart_order[0], u32(20))
		testing.expect_value(t, dec_b.restart_order[1], u32(30))
		testing.expect_value(t, dec_b.stop_order[0], u32(30))
		testing.expect_value(t, dec_b.stop_order[1], u32(20))

		dec_c := supervision_tree_record_stop(&tree, 30, .Fault, .None, 200)
		testing.expect_value(t, dec_c.action, supervision.Escalation_Action.Restart_Child)
		testing.expect_value(t, dec_c.restart_count, 1)
		testing.expect_value(t, dec_c.restart_order[0], u32(30))

		dec_a := supervision_tree_record_stop(&tree, 10, .Fault, .None, 300)
		testing.expect_value(t, dec_a.action, supervision.Escalation_Action.Restart_Group)
		testing.expect_value(t, dec_a.restart_count, 3)
		testing.expect_value(t, dec_a.restart_order[0], u32(10))
		testing.expect_value(t, dec_a.restart_order[1], u32(20))
		testing.expect_value(t, dec_a.restart_order[2], u32(30))
	}

	// Explicit dependency group under One_For_One: storage depends on block,
	// console is independent. Stopping block restarts [block, storage] only.
	{
		tree: Supervision_Tree
		testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
		// Add storage (100) before block (200) to verify topological sort puts provider first!
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 100, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 200, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 300, child_strategy = .One_For_One, max_restarts = 4}), Supervision_Refusal.None)
		testing.expect_value(t, supervision_tree_add_dependency(&tree, 100, 200), Supervision_Refusal.None)

		dec := supervision_tree_record_stop(&tree, 200, .Fault, .None, 100)
		testing.expect_value(t, dec.action, supervision.Escalation_Action.Restart_Group)
		testing.expect_value(t, dec.restart_count, 2)
		testing.expect_value(t, dec.restart_order[0], u32(200)) // Provider starts first!
		testing.expect_value(t, dec.restart_order[1], u32(100)) // Dependent starts second!
		testing.expect_value(t, dec.stop_order[0], u32(100))    // Dependent stops first!
		testing.expect_value(t, dec.stop_order[1], u32(200))    // Provider stops second!
	}
}

@(test)
supervision_tree_refuses_dependency_cycles :: proc(t: ^testing.T) {
	tree: Supervision_Tree
	testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 1, child_strategy = .One_For_One, max_restarts = 2}), Supervision_Refusal.None)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 2, child_strategy = .One_For_One, max_restarts = 2}), Supervision_Refusal.None)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 3, child_strategy = .One_For_One, max_restarts = 2}), Supervision_Refusal.None)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 4, parent_id = 1, child_strategy = .One_For_One, max_restarts = 2}), Supervision_Refusal.None)

	// Self-cycle refused.
	before := tree
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 1, 1), Supervision_Refusal.Dependency_Cycle)
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 0, 1), Supervision_Refusal.Zero_Child_Id)
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 1, 0), Supervision_Refusal.Unknown_Dependency)
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 99, 1), Supervision_Refusal.Unknown_Child)
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 1, 99), Supervision_Refusal.Unknown_Dependency)
	testing.expect_value(t, tree, before)

	// Direct 2-node cycle: 1 -> 2, then 2 -> 1 refused.
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 1, 2), Supervision_Refusal.None)
	after_12 := tree
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 1, 2), Supervision_Refusal.Duplicate_Dependency)
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 2, 1), Supervision_Refusal.Dependency_Cycle)
	testing.expect_value(t, tree, after_12)

	// Indirect 3-node cycle: 2 -> 3, then 3 -> 1 refused!
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 2, 3), Supervision_Refusal.None)
	after_23 := tree
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 3, 1), Supervision_Refusal.Dependency_Cycle)
	testing.expect_value(t, tree, after_23)

	// Mixed parent-dependency cycle: 4 has parent 1, so 1 -> 4 or 3 -> 4 (since 1 -> 2 -> 3 and 4 -> 1) refused!
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 1, 4), Supervision_Refusal.Dependency_Cycle)
	testing.expect_value(t, supervision_tree_add_dependency(&tree, 3, 4), Supervision_Refusal.Dependency_Cycle)
	testing.expect_value(t, tree, after_23)
}

@(test)
supervision_escalation_walks_tree_and_terminates_without_looping :: proc(t: ^testing.T) {
	tree: Supervision_Tree
	testing.expect_value(t, supervision_tree_init(&tree, .One_For_One), Supervision_Refusal.None)

	// Parent supervisor (10) with 1 restart in 60s, needed = true.
	testing.expect_value(t, supervision_tree_add_child(&tree, {
		child_id            = 10,
		parent_id           = 0,
		child_strategy      = .One_For_One,
		needed              = true,
		max_restarts        = 1,
		window_milliseconds = 60_000,
	}), Supervision_Refusal.None)
	// Worker child (11) under Parent (10) with 1 restart in 60s, needed = true.
	testing.expect_value(t, supervision_tree_add_child(&tree, {
		child_id            = 11,
		parent_id           = 10,
		child_strategy      = .One_For_One,
		needed              = true,
		max_restarts        = 1,
		window_milliseconds = 60_000,
	}), Supervision_Refusal.None)

	// Stop 1 of worker 11 at t = 1_000 -> restarts worker 11.
	dec1 := supervision_tree_record_stop(&tree, 11, .Fault, .None, 1_000)
	testing.expect_value(t, dec1.refusal, Supervision_Refusal.None)
	testing.expect_value(t, dec1.action, supervision.Escalation_Action.Restart_Child)
	testing.expect_value(t, dec1.restart_count, 1)
	testing.expect_value(t, dec1.restart_order[0], u32(11))

	// Stop 2 of worker 11 at t = 2_000 -> worker bound exhausted -> escalates to parent 10!
	dec2 := supervision_tree_record_stop(&tree, 11, .Fault, .None, 2_000)
	testing.expect_value(t, dec2.refusal, Supervision_Refusal.None)
	testing.expect_value(t, dec2.action, supervision.Escalation_Action.Escalate_To_Parent)
	testing.expect_value(t, dec2.escalated_to_id, u32(10))
	testing.expect_value(t, dec2.restart_count, 2)
	testing.expect_value(t, dec2.restart_order[0], u32(10))
	testing.expect_value(t, dec2.restart_order[1], u32(11))
	testing.expect_value(t, dec2.stop_order[0], u32(11))
	testing.expect_value(t, dec2.stop_order[1], u32(10))

	// Backwards clock on worker 11 after parent restart is still refused!
	before_back := tree
	testing.expect_value(t, supervision_tree_record_stop(&tree, 11, .Fault, .None, 1_999).refusal, Supervision_Refusal.Clock_Moved_Backwards)
	testing.expect_value(t, tree, before_back)

	// Stop 3 of worker 11 at t = 3_000 -> restarts worker 11 under new parent instance.
	dec3 := supervision_tree_record_stop(&tree, 11, .Fault, .None, 3_000)
	testing.expect_value(t, dec3.action, supervision.Escalation_Action.Restart_Child)

	// Stop 4 of worker 11 at t = 4_000 -> worker exhausted -> parent 10 ALSO exhausted -> escalates to root (0)!
	dec4 := supervision_tree_record_stop(&tree, 11, .Fault, .None, 4_000)
	testing.expect_value(t, dec4.refusal, Supervision_Refusal.None)
	testing.expect_value(t, dec4.action, supervision.Escalation_Action.Escalate_To_Parent)
	testing.expect_value(t, dec4.escalated_to_id, u32(0))
	testing.expect_value(t, dec4.restart_count, 0)

	// Stop 5 of worker 11 or parent 10 -> permanently stopped, never loops!
	testing.expect_value(t, supervision_tree_record_stop(&tree, 11, .Fault, .None, 5_000).refusal, Supervision_Refusal.Child_Permanently_Stopped)
	testing.expect_value(t, supervision_tree_record_stop(&tree, 10, .Fault, .None, 5_000).refusal, Supervision_Refusal.Child_Permanently_Stopped)

	// Optional parent (20, needed = false) with needed child (21): once parent exhausts restarts, stops permanently instead of escalating to root.
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 20, parent_id = 0, child_strategy = .One_For_One, needed = false, max_restarts = 0}), Supervision_Refusal.None)
	testing.expect_value(t, supervision_tree_add_child(&tree, {child_id = 21, parent_id = 20, child_strategy = .One_For_One, needed = true, max_restarts = 0}), Supervision_Refusal.None)
	dec_opt_parent := supervision_tree_record_stop(&tree, 21, .Fault, .None, 6_000)
	testing.expect_value(t, dec_opt_parent.refusal, Supervision_Refusal.None)
	testing.expect_value(t, dec_opt_parent.action, supervision.Escalation_Action.Stop_Permanently)
}
