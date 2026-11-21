// Pure shared-writer input-point gate for Layer 2 of process record and replay
// (src/md/features/record_and_replay.md, "The hard cases, and the choices").
//
// When a recorded process shares writable memory (a ring, call region, or
// surface) with another process, that peer is a shared writer. The gate
// enforces four invariants without taking locks or reading hardware state:
//
// 1. A shared writer may run ONLY while every recorded thread of the recorded
//    process is at an input point (inside a kernel entry or held at a fault).
// 2. A recorded thread may not leave an input point while any shared writer is
//    still running on a processor.
// 3. If a recorded thread stays outside an input point for one whole stint
//    while a shared writer waits, the gate ends the input history cleanly with
//    Stint_Bound_Reached and releases every waiting shared writer.
// 4. A revocation ends the input history immediately with Revocation and
//    releases every shared writer at once, regardless of thread state or time.
package replay_filter

import "modus:contract/input_history"

// Maximum shared-writer processes tracked concurrently for one recorded process.
SHARED_WRITER_CAPACITY :: 32
// Maximum recorded threads tracked concurrently by one shared-writer gate.
RECORDED_THREAD_CAPACITY :: 16

// Explicit lifecycle state of one shared-writer input-point gate.
Shared_Writer_Gate_State :: enum u8 {
	Inactive          = 0, // No recording active; all processes run freely.
	Active            = 1, // Recording active; shared writers gated on input points.
	Ended_Stint_Bound = 2, // Ended cleanly because a waiting shared writer reached the one-stint bound.
	Ended_Revocation  = 3, // Ended immediately by a revocation override.
	Ended_Normal      = 4, // Ended normally when recording finished or the process stopped.
}

// Outcome when a recorded thread requests to leave an input point and resume
// user instructions.
Leave_Input_Point_Result :: enum u8 {
	Left              = 0, // Thread left the input point; user execution may resume.
	Must_Wait_Writers = 1, // One or more shared writers still execute on a processor; wait first.
	Refused           = 2, // Invalid thread, thread not at an input point, or gate not active.
}

// Scheduling decision for a candidate process checked against a gate.
Writer_Schedule_Decision :: enum u8 {
	Run_Freely         = 0, // Process is not a tracked shared writer, or the gate is inactive/ended.
	Run_At_Input_Point = 1, // Shared writer may run because every recorded thread is at an input point.
	Wait_Input_Point   = 2, // Shared writer must wait because a recorded thread is between input points.
}

// One tracked process that maps writable shared memory with the recorded process.
Shared_Writer_Entry :: struct {
	process_slot:   u32,  // Kernel process slot (> 0); 0 means free slot.
	process_serial: u32,  // Kernel process serial (> 0) to guard against slot reuse.
	active_cpus:    u32,  // Count of processors currently running a thread of this shared writer.
	waiting:        bool, // True while deferred by the scheduler awaiting an input point.
}

// One tracked thread belonging to the recorded process.
Recorded_Thread_Entry :: struct {
	thread_id:      u32,  // Non-zero thread identifier; 0 means free slot.
	at_input_point: bool, // True while inside a kernel entry or held at a fault.
}

// Pure kernel-part state machine gating shared writers on the input points of
// one recorded process.
Shared_Writer_Gate :: struct {
	state:                   Shared_Writer_Gate_State,
	recorded_process_slot:   u32,
	recorded_process_serial: u32,
	stint_bound_ticks:       u64, // Strict one-stint wait limit (> 0).
	threads:                 [RECORDED_THREAD_CAPACITY]Recorded_Thread_Entry,
	thread_count:            u32,
	threads_at_input_point:  u32,
	writers:                 [SHARED_WRITER_CAPACITY]Shared_Writer_Entry,
	writer_count:            u32,
	active_writer_cpus:      u32, // Sum of active_cpus across all tracked shared writers.
	waiting_writer_count:    u32, // Count of tracked shared writers currently waiting.
	wait_started_tick:       u64, // Tick when the first shared writer began waiting outside an input point.
	wait_timer_armed:        bool,
	history_end_reason:      input_history.History_End_Reason,
}

// shared_writer_gate_init initializes an active gate for one recorded process
// with a strict positive one-stint bound. Refuses nil gate, zero slot, zero
// serial, or zero stint bound without modifying state on nil.
shared_writer_gate_init :: proc "contextless" (gate: ^Shared_Writer_Gate, recorded_process_slot: u32, recorded_process_serial: u32, stint_bound_ticks: u64) -> bool {
	if gate == nil || recorded_process_slot == 0 || recorded_process_serial == 0 || stint_bound_ticks == 0 {
		return false
	}
	gate^ = Shared_Writer_Gate {
		state                   = .Active,
		recorded_process_slot   = recorded_process_slot,
		recorded_process_serial = recorded_process_serial,
		stint_bound_ticks       = stint_bound_ticks,
	}
	return true
}

// all_recorded_threads_at_input_point reports whether every registered thread
// of the recorded process is currently at an input point.
@(private = "file")
all_recorded_threads_at_input_point :: proc "contextless" (gate: ^Shared_Writer_Gate) -> bool {
	return gate.threads_at_input_point == gate.thread_count
}

// clear_waiting_writers clears waiting flags and disarms the one-stint wait
// timer when shared writers become runnable or the gate ends.
@(private = "file")
clear_waiting_writers :: proc "contextless" (gate: ^Shared_Writer_Gate) {
	for &entry in gate.writers {
		entry.waiting = false
	}
	gate.waiting_writer_count = 0
	gate.wait_timer_armed = false
	gate.wait_started_tick = 0
}

// register_recorded_thread adds a non-zero thread of the recorded process.
// Refuses nil gate, inactive/ended gate, zero thread_id, duplicates, or full table.
register_recorded_thread :: proc "contextless" (gate: ^Shared_Writer_Gate, thread_id: u32, starts_at_input_point := true) -> bool {
	if gate == nil || gate.state != .Active || thread_id == 0 {
		return false
	}
	free_index := -1
	for entry, idx in gate.threads {
		if entry.thread_id == thread_id {
			return false
		}
		if entry.thread_id == 0 && free_index < 0 {
			free_index = idx
		}
	}
	if free_index < 0 {
		return false
	}
	// A new thread starting outside an input point cannot be registered while
	// a shared writer is actively executing on a processor.
	if !starts_at_input_point && gate.active_writer_cpus > 0 {
		return false
	}
	gate.threads[free_index] = Recorded_Thread_Entry {
		thread_id      = thread_id,
		at_input_point = starts_at_input_point,
	}
	gate.thread_count += 1
	if starts_at_input_point {
		gate.threads_at_input_point += 1
	}
	return true
}

// unregister_recorded_thread removes a finished recorded thread from the gate.
// If removing an outside-input-point thread leaves all remaining threads at an
// input point, waiting shared writers are released immediately.
unregister_recorded_thread :: proc "contextless" (gate: ^Shared_Writer_Gate, thread_id: u32) -> bool {
	if gate == nil || gate.state != .Active || thread_id == 0 {
		return false
	}
	for &entry in gate.threads {
		if entry.thread_id == thread_id {
			if entry.at_input_point && gate.threads_at_input_point > 0 {
				gate.threads_at_input_point -= 1
			}
			entry = {}
			if gate.thread_count > 0 {
				gate.thread_count -= 1
			}
			if all_recorded_threads_at_input_point(gate) {
				clear_waiting_writers(gate)
			}
			return true
		}
	}
	return false
}

// add_shared_writer registers a peer process that shares writable memory with
// the recorded process. Refuses nil gate, inactive/ended gate, zero slot or
// serial, the recorded process itself, duplicates, or a full writer table.
add_shared_writer :: proc "contextless" (gate: ^Shared_Writer_Gate, process_slot: u32, process_serial: u32) -> bool {
	if gate == nil || gate.state != .Active || process_slot == 0 || process_serial == 0 {
		return false
	}
	if process_slot == gate.recorded_process_slot && process_serial == gate.recorded_process_serial {
		return false
	}
	free_index := -1
	for entry, idx in gate.writers {
		if entry.process_slot == process_slot && entry.process_serial == process_serial {
			return false
		}
		if entry.process_slot == 0 && free_index < 0 {
			free_index = idx
		}
	}
	if free_index < 0 {
		return false
	}
	gate.writers[free_index] = Shared_Writer_Entry {
		process_slot   = process_slot,
		process_serial = process_serial,
	}
	gate.writer_count += 1
	return true
}

// remove_shared_writer removes a tracked shared writer (for example when it
// unmaps the shared object or stops). Disarms the wait timer if no waiting
// writers remain.
remove_shared_writer :: proc "contextless" (gate: ^Shared_Writer_Gate, process_slot: u32, process_serial: u32) -> bool {
	if gate == nil || process_slot == 0 || process_serial == 0 {
		return false
	}
	for &entry in gate.writers {
		if entry.process_slot == process_slot && entry.process_serial == process_serial {
			if entry.active_cpus <= gate.active_writer_cpus {
				gate.active_writer_cpus -= entry.active_cpus
			} else {
				gate.active_writer_cpus = 0
			}
			if entry.waiting && gate.waiting_writer_count > 0 {
				gate.waiting_writer_count -= 1
				if gate.waiting_writer_count == 0 {
					gate.wait_timer_armed = false
					gate.wait_started_tick = 0
				}
			}
			entry = {}
			if gate.writer_count > 0 {
				gate.writer_count -= 1
			}
			return true
		}
	}
	return false
}

// recorded_thread_enter_input_point marks a recorded thread as having entered
// an input point (kernel entry or fault). Refuses unknown threads, threads
// already at an input point, or an inactive/ended gate. Once every recorded
// thread is at an input point, waiting shared writers are unblocked and the
// one-stint wait timer is disarmed.
recorded_thread_enter_input_point :: proc "contextless" (gate: ^Shared_Writer_Gate, thread_id: u32) -> bool {
	if gate == nil || gate.state != .Active || thread_id == 0 {
		return false
	}
	for &entry in gate.threads {
		if entry.thread_id == thread_id {
			if entry.at_input_point {
				return false
			}
			entry.at_input_point = true
			gate.threads_at_input_point += 1
			// Keep waiting writers and the one-stint wait timer armed until a
			// waiting writer actually runs (shared_writer_begin_run), so rapid
			// enter/leave cycles cannot reset the timer and starve writers.
			return true
		}
	}
	return false
}

// recorded_thread_leave_input_point attempts to transition a recorded thread
// out of an input point back to user instructions. If any tracked shared
// writer is currently executing on a processor, returns Must_Wait_Writers and
// keeps the thread at the input point so recorded code never observes mid-write
// shared pages.
recorded_thread_leave_input_point :: proc "contextless" (gate: ^Shared_Writer_Gate, thread_id: u32) -> Leave_Input_Point_Result {
	if gate == nil || gate.state != .Active || thread_id == 0 {
		return .Refused
	}
	for &entry in gate.threads {
		if entry.thread_id == thread_id {
			if !entry.at_input_point {
				return .Refused
			}
			if gate.active_writer_cpus > 0 {
				return .Must_Wait_Writers
			}
			entry.at_input_point = false
			if gate.threads_at_input_point > 0 {
				gate.threads_at_input_point -= 1
			}
			return .Left
		}
	}
	return .Refused
}

// shared_writer_may_run decides whether a candidate process may be scheduled
// right now. Untracked processes and inactive/ended gates always run freely.
// A tracked shared writer may run ONLY while every recorded thread is at an
// input point; otherwise it is marked waiting and the one-stint timer is armed
// from now_tick if not already armed.
shared_writer_may_run :: proc "contextless" (gate: ^Shared_Writer_Gate, process_slot: u32, process_serial: u32, now_tick: u64 = 0) -> (may_run: bool, decision: Writer_Schedule_Decision) {
	if gate == nil || gate.state != .Active || process_slot == 0 || process_serial == 0 {
		return true, .Run_Freely
	}
	for &entry in gate.writers {
		if entry.process_slot != process_slot || entry.process_serial != process_serial {
			continue
		}
		if all_recorded_threads_at_input_point(gate) {
			// Wait state clears only when shared_writer_begin_run actually
			// dispatches this writer, not on a schedule probe.
			return true, .Run_At_Input_Point
		}
		if !entry.waiting {
			entry.waiting = true
			gate.waiting_writer_count += 1
		}
		if !gate.wait_timer_armed {
			gate.wait_timer_armed = true
			gate.wait_started_tick = now_tick
		}
		return false, .Wait_Input_Point
	}
	return true, .Run_Freely
}

// shared_writer_begin_run records that a processor has started executing a
// tracked shared writer. Refused while any recorded thread is outside an input
// point on an active gate so mutual exclusion is never violated.
shared_writer_begin_run :: proc "contextless" (gate: ^Shared_Writer_Gate, process_slot: u32, process_serial: u32) -> bool {
	if gate == nil || gate.state != .Active || process_slot == 0 || process_serial == 0 {
		return false
	}
	if !all_recorded_threads_at_input_point(gate) {
		return false
	}
	for &entry in gate.writers {
		if entry.process_slot == process_slot && entry.process_serial == process_serial {
			if entry.active_cpus == max(u32) || gate.active_writer_cpus == max(u32) {
				return false
			}
			if entry.waiting {
				entry.waiting = false
				if gate.waiting_writer_count > 0 {
					gate.waiting_writer_count -= 1
				}
				if gate.waiting_writer_count == 0 {
					gate.wait_timer_armed = false
					gate.wait_started_tick = 0
				}
			}
			entry.active_cpus += 1
			gate.active_writer_cpus += 1
			return true
		}
	}
	return false
}

// shared_writer_end_run records that a processor has stopped executing a
// tracked shared writer, allowing recorded threads to leave their input point
// once active_writer_cpus reaches zero.
shared_writer_end_run :: proc "contextless" (gate: ^Shared_Writer_Gate, process_slot: u32, process_serial: u32) -> bool {
	if gate == nil || process_slot == 0 || process_serial == 0 {
		return false
	}
	for &entry in gate.writers {
		if entry.process_slot == process_slot && entry.process_serial == process_serial {
			if entry.active_cpus == 0 || gate.active_writer_cpus == 0 {
				return false
			}
			entry.active_cpus -= 1
			gate.active_writer_cpus -= 1
			return true
		}
	}
	return false
}

// shared_writer_stint_expired enforces the strict one-stint wait bound: if at
// least one shared writer is waiting while a recorded thread stays outside an
// input point for stint_bound_ticks or longer, the gate ends the history
// cleanly with Stint_Bound_Reached and releases all shared writers.
shared_writer_stint_expired :: proc "contextless" (gate: ^Shared_Writer_Gate, now_tick: u64) -> (expired: bool, end_reason: input_history.History_End_Reason) {
	if gate == nil {
		return false, .None
	}
	if gate.state != .Active {
		return false, gate.history_end_reason
	}
	if !gate.wait_timer_armed || gate.waiting_writer_count == 0 || all_recorded_threads_at_input_point(gate) {
		return false, .None
	}
	if now_tick < gate.wait_started_tick {
		return false, .None
	}
	elapsed := now_tick - gate.wait_started_tick
	if elapsed < gate.stint_bound_ticks {
		return false, .None
	}
	gate.state = .Ended_Stint_Bound
	gate.history_end_reason = .Stint_Bound_Reached
	clear_waiting_writers(gate)
	return true, .Stint_Bound_Reached
}

// shared_writer_revoke_immediately applies the immediate revocation override:
// a revocation never waits for an input point or stint bound, ends the history
// at once with Revocation, and lets every shared writer run freely.
shared_writer_revoke_immediately :: proc "contextless" (gate: ^Shared_Writer_Gate) -> (ended: bool, end_reason: input_history.History_End_Reason) {
	if gate == nil {
		return false, .None
	}
	if gate.state != .Active {
		return false, gate.history_end_reason
	}
	gate.state = .Ended_Revocation
	gate.history_end_reason = .Revocation
	clear_waiting_writers(gate)
	return true, .Revocation
}

// shared_writer_end_normal ends an active gate cleanly when recording stops.
shared_writer_end_normal :: proc "contextless" (gate: ^Shared_Writer_Gate) -> bool {
	if gate == nil || gate.state != .Active {
		return false
	}
	gate.state = .Ended_Normal
	gate.history_end_reason = .Normal_Stop
	clear_waiting_writers(gate)
	return true
}
