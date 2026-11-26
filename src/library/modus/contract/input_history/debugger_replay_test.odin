#+build !freestanding
#+build !modus
package input_history

import "core:testing"
import op "modus:contract/operation"

// Adversarial edge tests for Checkpoint_Ring initialization, ordering,
// user-space bounds, and ring eviction.
@(test)
checkpoint_ring_refuses_bad_inputs_and_evicts_oldest :: proc(t: ^testing.T) {
	// Invalid init capacities: nil, 0, bound + 1, max(u32).
	testing.expect(t, !checkpoint_ring_init(nil, 4))
	ring: Checkpoint_Ring
	testing.expect(t, !checkpoint_ring_init(&ring, 0))
	testing.expect(t, !checkpoint_ring_init(&ring, CHECKPOINT_RING_CAPACITY + 1))
	testing.expect(t, !checkpoint_ring_init(&ring, max(u32)))

	// Push on uninitialized ring is refused.
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 1, position = {0, 0}}))

	// Valid init with small capacity 3 to test eviction cleanly.
	testing.expect(t, checkpoint_ring_init(&ring, 3))

	// Zero id, kernel RIP, and kernel RSP are refused without mutating ring.
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 0, position = {0, 0}}))
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 1, position = {0, 0}, instruction_address = op.USER_END}))
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 1, position = {0, 0}, stack_pointer = op.USER_END}))
	testing.expect_value(t, ring.count, u32(0))

	// Push 3 valid checkpoints.
	c1 := Replay_Checkpoint{id = 1, position = {0, 0}, history_byte_offset = 0, instruction_address = 0x40_0000, stack_pointer = 0x70_0000}
	c2 := Replay_Checkpoint{id = 2, position = {10, 5}, history_byte_offset = 1024, instruction_address = 0x40_0100, stack_pointer = 0x70_0000}
	c3 := Replay_Checkpoint{id = 3, position = {20, 0}, history_byte_offset = 2048, instruction_address = 0x40_0200, stack_pointer = 0x70_0000}
	testing.expect(t, checkpoint_ring_push(&ring, c1))
	testing.expect(t, checkpoint_ring_push(&ring, c2))
	testing.expect(t, checkpoint_ring_push(&ring, c3))
	testing.expect_value(t, ring.count, u32(3))

	// Duplicate id, non-increasing id, equal position, earlier position, and
	// decreasing history_byte_offset are all refused.
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 3, position = {30, 0}, history_byte_offset = 3000}))
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 2, position = {30, 0}, history_byte_offset = 3000}))
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 4, position = {20, 0}, history_byte_offset = 3000}))
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 4, position = {19, 999}, history_byte_offset = 3000}))
	testing.expect(t, !checkpoint_ring_push(&ring, Replay_Checkpoint{id = 4, position = {30, 0}, history_byte_offset = 2047}))
	testing.expect_value(t, ring.count, u32(3))

	// Pushing a 4th checkpoint evicts c1 and retains [c2, c3, c4] in order.
	c4 := Replay_Checkpoint{id = 4, position = {30, 12}, history_byte_offset = 4096}
	testing.expect(t, checkpoint_ring_push(&ring, c4))
	testing.expect_value(t, ring.count, u32(3))

	got0, ok0 := checkpoint_ring_get(&ring, 0)
	got1, ok1 := checkpoint_ring_get(&ring, 1)
	got2, ok2 := checkpoint_ring_get(&ring, 2)
	_, ok3 := checkpoint_ring_get(&ring, 3)
	testing.expect(t, ok0 && ok1 && ok2 && !ok3)
	testing.expect_value(t, got0.id, u64(2))
	testing.expect_value(t, got1.id, u64(3))
	testing.expect_value(t, got2.id, u64(4))
}

// Adversarial edge tests and exact forward-range calculations for step_back_plan.
@(test)
step_back_plan_selects_nearest_checkpoint_and_exact_range :: proc(t: ^testing.T) {
	ring: Checkpoint_Ring
	// Uninitialized ring -> Invalid_Request.
	testing.expect_value(t, step_back_plan(&ring, {5, 1}, 1).status, Step_Back_Status.Invalid_Request)
	testing.expect_value(t, step_back_plan(nil, {5, 1}, 1).status, Step_Back_Status.Invalid_Request)

	testing.expect(t, checkpoint_ring_init(&ring, 4))
	// steps_back == 0 -> Invalid_Request.
	testing.expect_value(t, step_back_plan(&ring, {5, 1}, 0).status, Step_Back_Status.Invalid_Request)
	// Stepping back from (0, 0) or past point 0 -> At_Start.
	testing.expect_value(t, step_back_plan(&ring, {0, 0}, 1).status, Step_Back_Status.At_Start)
	testing.expect_value(t, step_back_plan(&ring, {0, 3}, 4).status, Step_Back_Status.At_Start)
	// Empty ring -> No_Prior_Checkpoint.
	testing.expect_value(t, step_back_plan(&ring, {5, 10}, 1).status, Step_Back_Status.No_Prior_Checkpoint)

	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 1, position = {0, 0}, history_byte_offset = 0}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 2, position = {10, 4}, history_byte_offset = 512}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 3, position = {10, 20}, history_byte_offset = 512}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 4, position = {25, 0}, history_byte_offset = 4096}))

	// Same point as checkpoint 2: (10, 15) stepping back 1 -> target (10, 14).
	// Must select checkpoint 2 (10, 4), NOT checkpoint 3 (10, 20)!
	p1 := step_back_plan(&ring, {10, 15}, 1)
	testing.expect_value(t, p1.status, Step_Back_Status.Ok)
	testing.expect_value(t, p1.checkpoint.id, u64(2))
	testing.expect_value(t, p1.target_position, Replay_Position{10, 14})
	testing.expect_value(t, p1.replay_points_to_advance, u64(0))
	testing.expect_value(t, p1.single_steps_after_point, u64(10))
	testing.expect_value(t, p1.history_start_offset, u64(512))

	// Exact hit on a checkpoint: (10, 21) stepping back 1 -> target (10, 20) == checkpoint 3.
	p2 := step_back_plan(&ring, {10, 21}, 1)
	testing.expect_value(t, p2.status, Step_Back_Status.Ok)
	testing.expect_value(t, p2.checkpoint.id, u64(3))
	testing.expect_value(t, p2.replay_points_to_advance, u64(0))
	testing.expect_value(t, p2.single_steps_after_point, u64(0))

	// Multi-point forward range: (28, 7) stepping back 2 -> target (28, 5), checkpoint 4 at (25, 0).
	p3 := step_back_plan(&ring, {28, 7}, 2)
	testing.expect_value(t, p3.status, Step_Back_Status.Ok)
	testing.expect_value(t, p3.checkpoint.id, u64(4))
	testing.expect_value(t, p3.target_position, Replay_Position{28, 5})
	testing.expect_value(t, p3.replay_points_to_advance, u64(3))
	testing.expect_value(t, p3.single_steps_after_point, u64(5))
	testing.expect_value(t, p3.history_start_offset, u64(4096))

	// Crossing an input-point boundary: at (25, 0), stepping back 1 with prior point
	// ending at 12 instructions -> target (24, 11), selects checkpoint 3 at (10, 20),
	// advancing 14 points then 11 single steps!
	p4 := step_back_plan(&ring, {25, 0}, 1, prior_point_instruction_count = 12)
	testing.expect_value(t, p4.status, Step_Back_Status.Ok)
	testing.expect_value(t, p4.checkpoint.id, u64(3))
	testing.expect_value(t, p4.target_position, Replay_Position{24, 11})
	testing.expect_value(t, p4.replay_points_to_advance, u64(14))
	testing.expect_value(t, p4.single_steps_after_point, u64(11))

	// Evicting checkpoint 1 makes targets before (10, 4) return No_Prior_Checkpoint.
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 5, position = {40, 0}, history_byte_offset = 8192}))
	p5 := step_back_plan(&ring, {5, 1}, 1)
	testing.expect_value(t, p5.status, Step_Back_Status.No_Prior_Checkpoint)
}

// Adversarial edge tests and full backward-interval search for watch_back_plan.
@(test)
watch_back_plan_validates_watchpoints_and_finds_last_prior_write :: proc(t: ^testing.T) {
	ring: Checkpoint_Ring
	testing.expect_value(t, watch_back_plan(&ring, 0x2000, 8, {10, 0}).status, Watch_Back_Status.Invalid_Request)
	testing.expect(t, checkpoint_ring_init(&ring, 4))

	// Invalid watchpoints: zero address, invalid sizes (0, 3, 5, 16), unaligned
	// addresses, and kernel/overflowing addresses.
	testing.expect_value(t, watch_back_plan(&ring, 0, 8, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, 0x2000, 0, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, 0x2000, 3, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, 0x2000, 16, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, 0x2001, 2, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, 0x2002, 4, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, 0x2004, 8, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, op.USER_END, 8, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)
	testing.expect_value(t, watch_back_plan(&ring, max(u64) - 7, 8, {10, 0}).status, Watch_Back_Status.Invalid_Watchpoint)

	// Search at (0, 0) -> Not_Found.
	testing.expect_value(t, watch_back_plan(&ring, 0x2000, 8, {0, 0}).status, Watch_Back_Status.Not_Found)

	// Populate checkpoints: (0, 0), (10, 0), (20, 0).
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 1, position = {0, 0}, history_byte_offset = 0}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 2, position = {10, 0}, history_byte_offset = 1000}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 3, position = {20, 0}, history_byte_offset = 2000}))

	// Step 1: initial scan from (25, 9) selects checkpoint 3 at (20, 0).
	scan1 := watch_back_plan(&ring, 0x2000, 8, {25, 9})
	testing.expect_value(t, scan1.status, Watch_Back_Status.Scan_Window)
	testing.expect_value(t, scan1.checkpoint.id, u64(3))
	testing.expect_value(t, scan1.range_start, Replay_Position{20, 0})
	testing.expect_value(t, scan1.range_end, Replay_Position{25, 9})
	testing.expect_value(t, scan1.next_search_end, Replay_Position{20, 0})
	testing.expect_value(t, scan1.replay_points_to_advance, u64(5))
	testing.expect_value(t, scan1.single_steps_after_point, u64(9))

	// Step 2: observed hits in [20..25) include hits to ignore (different address,
	// hit AT search_end, hit before window) AND two overlapping hits; must pick
	// the LATEST overlapping write strictly before (25, 9).
	hits := [?]Watch_Hit {
		{position = {19, 99}, write_address = 0x2000, write_length = 8, instruction_address = 0x40_0010}, // before window
		{position = {21, 3}, write_address = 0x2000, write_length = 4, instruction_address = 0x40_0020},  // overlap low half
		{position = {23, 7}, write_address = 0x2007, write_length = 1, instruction_address = 0x40_0030},  // overlap last byte -> winner!
		{position = {24, 5}, write_address = 0x2008, write_length = 8, instruction_address = 0x40_0040},  // adjacent, no overlap
		{position = {25, 9}, write_address = 0x2000, write_length = 8, instruction_address = 0x40_0050},  // AT search_end (not strictly before)
	}
	found_plan := watch_back_plan(&ring, 0x2000, 8, {25, 9}, hits[:])
	testing.expect_value(t, found_plan.status, Watch_Back_Status.Replay_To_Hit)
	testing.expect_value(t, found_plan.checkpoint.id, u64(3))
	testing.expect_value(t, found_plan.range_end, Replay_Position{23, 7})
	testing.expect_value(t, found_plan.replay_points_to_advance, u64(3))
	testing.expect_value(t, found_plan.single_steps_after_point, u64(7))
	testing.expect_value(t, found_plan.hit.instruction_address, u64(0x40_0030))

	// Step 3: if no hit matched in [20, 25), passing a truly empty slice
	// with has_observed_hits = true steps back to [10, 20), then [0, 10), then Not_Found!
	scan2 := watch_back_plan(&ring, 0x2000, 8, {25, 9}, []Watch_Hit{}, has_observed_hits = true)
	testing.expect_value(t, scan2.status, Watch_Back_Status.Scan_Window)
	testing.expect_value(t, scan2.checkpoint.id, u64(2))
	testing.expect_value(t, scan2.range_start, Replay_Position{10, 0})
	testing.expect_value(t, scan2.range_end, Replay_Position{20, 0})

	scan3 := watch_back_plan(&ring, 0x2000, 8, {20, 0}, []Watch_Hit{}, has_observed_hits = true)
	testing.expect_value(t, scan3.status, Watch_Back_Status.Scan_Window)
	testing.expect_value(t, scan3.checkpoint.id, u64(1))
	testing.expect_value(t, scan3.range_start, Replay_Position{0, 0})
	testing.expect_value(t, scan3.range_end, Replay_Position{10, 0})

	exhausted := watch_back_plan(&ring, 0x2000, 8, {10, 0}, []Watch_Hit{}, has_observed_hits = true)
	testing.expect_value(t, exhausted.status, Watch_Back_Status.Not_Found)

	// Evict checkpoint 1 (0, 0) so oldest retained is (10, 0): scanning past
	// (10, 0) must distinguish No_Prior_Checkpoint from Not_Found!
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 4, position = {30, 0}, history_byte_offset = 3000}))
	testing.expect(t, checkpoint_ring_push(&ring, Replay_Checkpoint{id = 5, position = {40, 0}, history_byte_offset = 4000}))
	no_prior := watch_back_plan(&ring, 0x2000, 8, {20, 0}, []Watch_Hit{}, has_observed_hits = true)
	testing.expect_value(t, no_prior.status, Watch_Back_Status.No_Prior_Checkpoint)

	// Corrupt head/count on Checkpoint_Ring is refused without out-of-bounds access.
	corrupt := ring
	corrupt.head = corrupt.capacity
	_, corrupt_ok := checkpoint_ring_get(&corrupt, 0)
	testing.expect(t, !corrupt_ok)
	testing.expect(t, !checkpoint_ring_push(&corrupt, Replay_Checkpoint{id = 6, position = {50, 0}, history_byte_offset = 5000}))
	testing.expect_value(t, watch_back_plan(&corrupt, 0x2000, 8, {40, 0}).status, Watch_Back_Status.Invalid_Request)
}
