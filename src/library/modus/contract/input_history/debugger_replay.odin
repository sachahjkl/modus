// Pure reverse-execution checkpoint ring and replay planners for Layer 3 of
// process record and replay (src/md/features/record_and_replay.md, "The
// debugger: step back, and a watch back").
//
// Reverse execution in a deterministic replay uses saved checkpoints (copied
// memory objects and thread states) instead of fork:
//
// - step_back_plan selects the nearest checkpoint at or before the target
//   execution position and computes the exact forward replay range (input
//   points to advance, then single-step instructions after that point).
// - watch_back_plan walks backwards across checkpoint intervals to locate the
//   last write overlapping a hardware data watchpoint strictly before the
//   current execution position, then computes the exact forward replay plan
//   to stop at that write.
package input_history

import op "modus:contract/operation"

// Maximum checkpoints retained simultaneously in one Checkpoint_Ring.
CHECKPOINT_RING_CAPACITY :: 32

// Exact execution position in a deterministic replay: monotonic input point
// number plus instructions retired since that input point.
Replay_Position :: struct {
	point_number:      u64, // 0 at process entry before the first input point.
	instruction_count: u64, // Instructions retired after point_number.
}

// One saved checkpoint of a replayed process kept by the debugger service.
Replay_Checkpoint :: struct {
	id:                  u64,             // Monotonic non-zero identifier; 0 means empty slot.
	position:            Replay_Position, // Execution position captured by this checkpoint.
	history_byte_offset: u64,             // Byte offset in the input history stream at capture.
	instruction_address: u64,             // Instruction pointer at capture (< op.USER_END).
	stack_pointer:       u64,             // Stack pointer at capture (< op.USER_END).
	memory_object_count: u32,             // Count of copied memory objects in this checkpoint.
	thread_count:        u32,             // Count of saved thread states in this checkpoint.
}

// Fixed-capacity chronological ring of replay checkpoints. When full, pushing
// a newer checkpoint evicts the oldest retained checkpoint.
Checkpoint_Ring :: struct {
	entries:  [CHECKPOINT_RING_CAPACITY]Replay_Checkpoint,
	head:     u32, // Index of the oldest retained checkpoint in entries.
	count:    u32, // Number of checkpoints currently held (0 ..= capacity).
	capacity: u32, // Active ring capacity (1 ..= CHECKPOINT_RING_CAPACITY); 0 means uninitialized.
	last_id:  u64, // Highest checkpoint id pushed so far.
}

// Outcome of planning a reverse step.
Step_Back_Status :: enum u8 {
	Ok                  = 0, // Valid prior checkpoint selected with exact forward replay range.
	At_Start            = 1, // Target steps past the beginning of the replay (0, 0).
	No_Prior_Checkpoint = 2, // No retained checkpoint exists at or before the target position.
	Invalid_Request     = 3, // Invalid ring or request parameters (nil ring, steps_back == 0, etc.).
}

// Exact forward replay plan from a checkpoint to a reverse-step target.
Step_Back_Plan :: struct {
	status:                   Step_Back_Status,
	checkpoint:               Replay_Checkpoint,
	start_position:           Replay_Position,
	target_position:          Replay_Position,
	replay_points_to_advance: u64,
	single_steps_after_point: u64,
	history_start_offset:     u64,
}

// Outcome of planning a reverse data watchpoint search.
Watch_Back_Status :: enum u8 {
	Scan_Window         = 0, // Replay forward over [range_start, range_end) with watchpoint armed.
	Replay_To_Hit       = 1, // Matching prior write found; replay forward from checkpoint to range_end.
	Not_Found           = 2, // Searched back to replay entry (0, 0) with no matching write.
	No_Prior_Checkpoint = 3, // No retained checkpoint exists strictly before search_end.
	Invalid_Watchpoint  = 4, // Watch address or length violates x86-64 debug watchpoint rules.
	Invalid_Request     = 5, // Nil or uninitialized checkpoint ring.
}

// One hardware data watchpoint hit observed during a forward window scan.
Watch_Hit :: struct {
	position:            Replay_Position, // Execution position of the write instruction.
	write_address:       u64,             // Starting virtual address written by the instruction.
	write_length:        u32,             // Byte length of the write (> 0).
	instruction_address: u64,             // Instruction pointer that performed the write.
}

// Exact plan for one step of reverse watchpoint execution.
Watch_Back_Plan :: struct {
	status:                   Watch_Back_Status,
	checkpoint:               Replay_Checkpoint,
	range_start:              Replay_Position,
	range_end:                Replay_Position,
	next_search_end:          Replay_Position,
	replay_points_to_advance: u64,
	single_steps_after_point: u64,
	history_start_offset:     u64,
	watch_address:            u64,
	watch_length:             u32,
	hit:                      Watch_Hit,
}

// replay_position_compare orders two Replay_Positions lexicographically:
// -1 if a < b, 0 if a == b, +1 if a > b.
replay_position_compare :: proc "contextless" (a, b: Replay_Position) -> int {
	if a.point_number < b.point_number {
		return -1
	}
	if a.point_number > b.point_number {
		return 1
	}
	if a.instruction_count < b.instruction_count {
		return -1
	}
	if a.instruction_count > b.instruction_count {
		return 1
	}
	return 0
}

// forward_range_steps computes the exact input points to replay and trailing
// single steps required to advance from start to target (requires start <= target).
@(private = "file")
forward_range_steps :: proc "contextless" (start, target: Replay_Position) -> (points: u64, single_steps: u64) {
	points = target.point_number - start.point_number
	if points == 0 {
		single_steps = target.instruction_count - start.instruction_count
	} else {
		single_steps = target.instruction_count
	}
	return points, single_steps
}

// checkpoint_ring_init initializes a Checkpoint_Ring with capacity in
// 1 ..= CHECKPOINT_RING_CAPACITY. Refuses nil or out-of-range capacity.
checkpoint_ring_init :: proc "contextless" (checkpoints: ^Checkpoint_Ring, capacity: u32 = CHECKPOINT_RING_CAPACITY) -> bool {
	if checkpoints == nil || capacity == 0 || capacity > CHECKPOINT_RING_CAPACITY {
		return false
	}
	checkpoints^ = Checkpoint_Ring{capacity = capacity}
	return true
}

// checkpoint_ring_get returns the checkpoint at chronological_index
// (0 = oldest retained, count - 1 = newest retained).
checkpoint_ring_get :: proc "contextless" (checkpoints: ^Checkpoint_Ring, chronological_index: u32) -> (checkpoint: Replay_Checkpoint, ok: bool) {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY {
		return {}, false
	}
	if checkpoints.head >= checkpoints.capacity || checkpoints.count > checkpoints.capacity {
		return {}, false
	}
	if chronological_index >= checkpoints.count {
		return {}, false
	}
	slot := u32((u64(checkpoints.head) + u64(chronological_index)) % u64(checkpoints.capacity))
	return checkpoints.entries[slot], true
}

// checkpoint_ring_push appends one checkpoint in strictly increasing id and
// Replay_Position order, with non-decreasing history_byte_offset and user-space
// addresses. When full, the oldest checkpoint is evicted. On refusal, the ring
// is untouched.
checkpoint_ring_push :: proc "contextless" (checkpoints: ^Checkpoint_Ring, checkpoint: Replay_Checkpoint) -> bool {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY {
		return false
	}
	if checkpoints.head >= checkpoints.capacity || checkpoints.count > checkpoints.capacity {
		return false
	}
	if checkpoint.id == 0 || checkpoint.id <= checkpoints.last_id {
		return false
	}
	if checkpoint.instruction_address >= op.USER_END || checkpoint.stack_pointer >= op.USER_END {
		return false
	}
	if checkpoints.count > 0 {
		latest, latest_ok := checkpoint_ring_get(checkpoints, checkpoints.count - 1)
		if !latest_ok {
			return false
		}
		if replay_position_compare(checkpoint.position, latest.position) <= 0 {
			return false
		}
		if checkpoint.history_byte_offset < latest.history_byte_offset {
			return false
		}
	}
	if checkpoints.count < checkpoints.capacity {
		slot := u32((u64(checkpoints.head) + u64(checkpoints.count)) % u64(checkpoints.capacity))
		checkpoints.entries[slot] = checkpoint
		checkpoints.count += 1
	} else {
		// Evict oldest slot at head and advance head.
		checkpoints.entries[checkpoints.head] = checkpoint
		checkpoints.head = u32((u64(checkpoints.head) + 1) % u64(checkpoints.capacity))
	}
	checkpoints.last_id = checkpoint.id
	return true
}

// checkpoint_ring_nearest_at_or_before selects the newest retained checkpoint
// whose position is <= target.
checkpoint_ring_nearest_at_or_before :: proc "contextless" (checkpoints: ^Checkpoint_Ring, target: Replay_Position) -> (checkpoint: Replay_Checkpoint, found: bool) {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY || checkpoints.count == 0 {
		return {}, false
	}
	for reverse := checkpoints.count; reverse > 0; reverse -= 1 {
		candidate, ok := checkpoint_ring_get(checkpoints, reverse - 1)
		if ok && replay_position_compare(candidate.position, target) <= 0 {
			return candidate, true
		}
	}
	return {}, false
}

// checkpoint_ring_nearest_before selects the newest retained checkpoint whose
// position is strictly < limit.
checkpoint_ring_nearest_before :: proc "contextless" (checkpoints: ^Checkpoint_Ring, limit: Replay_Position) -> (checkpoint: Replay_Checkpoint, found: bool) {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY || checkpoints.count == 0 {
		return {}, false
	}
	for reverse := checkpoints.count; reverse > 0; reverse -= 1 {
		candidate, ok := checkpoint_ring_get(checkpoints, reverse - 1)
		if ok && replay_position_compare(candidate.position, limit) < 0 {
			return candidate, true
		}
	}
	return {}, false
}

// step_back_to_position_plan selects the nearest checkpoint at or before target
// and computes the exact forward replay range to reach target.
step_back_to_position_plan :: proc "contextless" (checkpoints: ^Checkpoint_Ring, target: Replay_Position) -> Step_Back_Plan {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY {
		return {status = .Invalid_Request}
	}
	chosen, found := checkpoint_ring_nearest_at_or_before(checkpoints, target)
	if !found {
		return {status = .No_Prior_Checkpoint, target_position = target}
	}
	points, steps := forward_range_steps(chosen.position, target)
	return Step_Back_Plan {
		status                   = .Ok,
		checkpoint               = chosen,
		start_position           = chosen.position,
		target_position          = target,
		replay_points_to_advance = points,
		single_steps_after_point = steps,
		history_start_offset     = chosen.history_byte_offset,
	}
}

// step_back_plan computes the reverse-step target and forward replay range to
// move steps_back instructions earlier than current.
//
// When current.instruction_count >= steps_back, the target remains within
// current.point_number. When stepping across the boundary of
// current.point_number into current.point_number - 1,
// prior_point_instruction_count gives the instruction count reached at the end
// of current.point_number - 1 (0 when the boundary itself is the target for a
// 1-instruction step back from (P, 0)).
step_back_plan :: proc "contextless" (checkpoints: ^Checkpoint_Ring, current: Replay_Position, steps_back: u64 = 1, prior_point_instruction_count: u64 = 0) -> Step_Back_Plan {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY || steps_back == 0 {
		return {status = .Invalid_Request}
	}
	if current.point_number == 0 && current.instruction_count == 0 {
		return {status = .At_Start}
	}
	target: Replay_Position
	if current.instruction_count >= steps_back {
		target = Replay_Position {
			point_number      = current.point_number,
			instruction_count = current.instruction_count - steps_back,
		}
	} else {
		if current.point_number == 0 {
			return {status = .At_Start}
		}
		remaining := steps_back - current.instruction_count
		if prior_point_instruction_count == 0 {
			if remaining > 1 {
				return {status = .Invalid_Request}
			}
			target = Replay_Position {
				point_number      = current.point_number - 1,
				instruction_count = 0,
			}
		} else {
			if remaining > prior_point_instruction_count {
				return {status = .Invalid_Request}
			}
			target = Replay_Position {
				point_number      = current.point_number - 1,
				instruction_count = prior_point_instruction_count - remaining,
			}
		}
	}
	return step_back_to_position_plan(checkpoints, target)
}

// watch_range_valid validates an x86-64 hardware data watchpoint: length must
// be 1, 2, 4, or 8 bytes, address must be non-zero, aligned to length, and the
// entire range must lie strictly below op.USER_END.
watch_range_valid :: proc "contextless" (address: u64, length: u32) -> bool {
	if length != 1 && length != 2 && length != 4 && length != 8 {
		return false
	}
	if address == 0 || address >= op.USER_END {
		return false
	}
	if address % u64(length) != 0 {
		return false
	}
	if u64(length) > op.USER_END - address {
		return false
	}
	return true
}

// ranges_overlap reports whether [a_start, a_start + a_len) and
// [b_start, b_start + b_len) share at least one byte without overflow.
@(private = "file")
ranges_overlap :: proc "contextless" (a_start: u64, a_len: u32, b_start: u64, b_len: u32) -> bool {
	if a_len == 0 || b_len == 0 || a_start >= op.USER_END || b_start >= op.USER_END {
		return false
	}
	if u64(a_len) > op.USER_END - a_start || u64(b_len) > op.USER_END - b_start {
		return false
	}
	a_end := a_start + u64(a_len)
	b_end := b_start + u64(b_len)
	return a_start < b_end && b_start < a_end
}

// watch_back_plan plans reverse watchpoint execution ("who wrote these bytes
// last strictly before search_end?"):
//
// - With observed_hits == nil: selects the nearest checkpoint strictly before
//   search_end and returns Scan_Window over [checkpoint.position, search_end)
//   with next_search_end = checkpoint.position.
// - With observed_hits != nil: selects the latest hit within
//   [checkpoint.position, search_end) whose written byte range overlaps
//   [watch_address, watch_address + watch_length), returning Replay_To_Hit
//   with the exact forward replay range to that write. If no hit matched in
//   this window, automatically steps back to the next earlier checkpoint
//   interval (Scan_Window), or returns Not_Found / No_Prior_Checkpoint when
//   no earlier interval remains.
watch_back_plan :: proc "contextless" (
	checkpoints: ^Checkpoint_Ring,
	watch_address: u64,
	watch_length: u32,
	search_end: Replay_Position,
	observed_hits: []Watch_Hit = nil,
	has_observed_hits: bool = false,
) -> Watch_Back_Plan {
	if checkpoints == nil || checkpoints.capacity == 0 || checkpoints.capacity > CHECKPOINT_RING_CAPACITY {
		return {status = .Invalid_Request}
	}
	if checkpoints.head >= checkpoints.capacity || checkpoints.count > checkpoints.capacity {
		return {status = .Invalid_Request}
	}
	if !watch_range_valid(watch_address, watch_length) {
		return {status = .Invalid_Watchpoint, watch_address = watch_address, watch_length = watch_length}
	}
	if search_end.point_number == 0 && search_end.instruction_count == 0 {
		return {status = .Not_Found, watch_address = watch_address, watch_length = watch_length}
	}
	chosen, found := checkpoint_ring_nearest_before(checkpoints, search_end)
	if !found {
		return {
			status        = .No_Prior_Checkpoint,
			range_end     = search_end,
			watch_address = watch_address,
			watch_length  = watch_length,
		}
	}

	if !has_observed_hits && observed_hits == nil {
		points, steps := forward_range_steps(chosen.position, search_end)
		return Watch_Back_Plan {
			status                   = .Scan_Window,
			checkpoint               = chosen,
			range_start              = chosen.position,
			range_end                = search_end,
			next_search_end          = chosen.position,
			replay_points_to_advance = points,
			single_steps_after_point = steps,
			history_start_offset     = chosen.history_byte_offset,
			watch_address            = watch_address,
			watch_length             = watch_length,
		}
	}

	// Select the latest matching write strictly inside [chosen.position, search_end).
	best_hit: Watch_Hit
	has_best := false
	for candidate in observed_hits {
		if candidate.write_length == 0 || candidate.write_address >= op.USER_END {
			continue
		}
		if replay_position_compare(candidate.position, chosen.position) < 0 {
			continue
		}
		if replay_position_compare(candidate.position, search_end) >= 0 {
			continue
		}
		if !ranges_overlap(watch_address, watch_length, candidate.write_address, candidate.write_length) {
			continue
		}
		if !has_best || replay_position_compare(candidate.position, best_hit.position) > 0 {
			best_hit = candidate
			has_best = true
		}
	}

	if has_best {
		points, steps := forward_range_steps(chosen.position, best_hit.position)
		return Watch_Back_Plan {
			status                   = .Replay_To_Hit,
			checkpoint               = chosen,
			range_start              = chosen.position,
			range_end                = best_hit.position,
			next_search_end          = chosen.position,
			replay_points_to_advance = points,
			single_steps_after_point = steps,
			history_start_offset     = chosen.history_byte_offset,
			watch_address            = watch_address,
			watch_length             = watch_length,
			hit                      = best_hit,
		}
	}

	// No hit matched in [chosen.position, search_end); step back to the prior interval.
	if chosen.position.point_number == 0 && chosen.position.instruction_count == 0 {
		return {status = .Not_Found, watch_address = watch_address, watch_length = watch_length}
	}
	prior, prior_found := checkpoint_ring_nearest_before(checkpoints, chosen.position)
	if !prior_found {
		return {
			status        = .No_Prior_Checkpoint,
			range_end     = chosen.position,
			watch_address = watch_address,
			watch_length  = watch_length,
		}
	}
	points, steps := forward_range_steps(prior.position, chosen.position)
	return Watch_Back_Plan {
		status                   = .Scan_Window,
		checkpoint               = prior,
		range_start              = prior.position,
		range_end                = chosen.position,
		next_search_end          = prior.position,
		replay_points_to_advance = points,
		single_steps_after_point = steps,
		history_start_offset     = prior.history_byte_offset,
		watch_address            = watch_address,
		watch_length             = watch_length,
	}
}
