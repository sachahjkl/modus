#+build !freestanding
package replay_filter

import "core:testing"
import "modus:contract/input_history"

// Refusals at initialization, registration, and writer addition edges: nil, 0,
// self-writer, duplicate writer, duplicate thread, and one past capacity.
@(test)
shared_writer_gate_refuses_invalid_inputs_and_bounds :: proc(t: ^testing.T) {
	testing.expect(t, !shared_writer_gate_init(nil, 2, 1, 10))
	gate: Shared_Writer_Gate
	testing.expect(t, !shared_writer_gate_init(&gate, 0, 1, 10))
	testing.expect(t, !shared_writer_gate_init(&gate, 2, 0, 10))
	testing.expect(t, !shared_writer_gate_init(&gate, 2, 1, 0))
	testing.expect_value(t, gate.state, Shared_Writer_Gate_State.Inactive)

	// Operations on an inactive gate refuse mutations and let processes run freely.
	testing.expect(t, !add_shared_writer(&gate, 3, 1))
	testing.expect(t, !register_recorded_thread(&gate, 1))
	testing.expect(t, !recorded_thread_enter_input_point(&gate, 1))
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 1), Leave_Input_Point_Result.Refused)
	may_inactive, dec_inactive := shared_writer_may_run(&gate, 3, 1, 100)
	testing.expect(t, may_inactive)
	testing.expect_value(t, dec_inactive, Writer_Schedule_Decision.Run_Freely)

	testing.expect(t, shared_writer_gate_init(&gate, 5, 99, 100))

	// Refused thread registrations: 0, duplicate, and one past capacity.
	testing.expect(t, !register_recorded_thread(&gate, 0))
	for id in u32(1) ..= u32(RECORDED_THREAD_CAPACITY) {
		testing.expect(t, register_recorded_thread(&gate, id))
	}
	testing.expect(t, !register_recorded_thread(&gate, 1), "duplicate thread_id must be refused")
	testing.expect(t, !register_recorded_thread(&gate, RECORDED_THREAD_CAPACITY + 1), "thread past capacity must be refused")
	testing.expect_value(t, gate.thread_count, u32(RECORDED_THREAD_CAPACITY))

	// Refused shared writers: zero slot, zero serial, recorded process itself,
	// duplicate, and one past SHARED_WRITER_CAPACITY.
	testing.expect(t, !add_shared_writer(&gate, 0, 1))
	testing.expect(t, !add_shared_writer(&gate, 3, 0))
	testing.expect(t, !add_shared_writer(&gate, 5, 99), "recorded process cannot be its own shared writer")
	for slot in u32(10) ..< u32(10 + SHARED_WRITER_CAPACITY) {
		testing.expect(t, add_shared_writer(&gate, slot, 1))
	}
	testing.expect(t, !add_shared_writer(&gate, 10, 1), "duplicate shared writer must be refused")
	testing.expect(t, !add_shared_writer(&gate, 10 + SHARED_WRITER_CAPACITY, 1), "writer past capacity must be refused")
	testing.expect_value(t, gate.writer_count, u32(SHARED_WRITER_CAPACITY))
}

// Multi-thread input-point gate: a shared writer runs ONLY when EVERY recorded
// thread is at an input point, and a recorded thread cannot leave an input
// point while a shared writer is still active on a processor.
@(test)
shared_writer_requires_all_recorded_threads_at_input_point :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 4, 10, 50))
	testing.expect(t, register_recorded_thread(&gate, 101, starts_at_input_point = true))
	testing.expect(t, register_recorded_thread(&gate, 102, starts_at_input_point = true))
	testing.expect(t, add_shared_writer(&gate, 7, 20))

	// Untracked process always runs freely, regardless of recorded thread state.
	may_other, dec_other := shared_writer_may_run(&gate, 8, 20, 10)
	testing.expect(t, may_other)
	testing.expect_value(t, dec_other, Writer_Schedule_Decision.Run_Freely)

	// Both threads at input point -> shared writer may run and begin executing.
	may_run, decision := shared_writer_may_run(&gate, 7, 20, 10)
	testing.expect(t, may_run)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Run_At_Input_Point)
	testing.expect(t, shared_writer_begin_run(&gate, 7, 20))

	// While shared writer is active on a CPU, recorded thread cannot leave input point.
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 101), Leave_Input_Point_Result.Must_Wait_Writers)
	testing.expect_value(t, gate.threads_at_input_point, u32(2))

	// Once shared writer finishes its CPU slice, recorded thread 101 leaves input point.
	testing.expect(t, shared_writer_end_run(&gate, 7, 20))
	testing.expect(t, !shared_writer_end_run(&gate, 7, 20), "underflow must be refused")
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 101), Leave_Input_Point_Result.Left)
	// Leaving twice is refused.
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 101), Leave_Input_Point_Result.Refused)

	// One thread (102) at input point, one (101) outside -> shared writer must wait.
	may_run, decision = shared_writer_may_run(&gate, 7, 20, 100)
	testing.expect(t, !may_run)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Wait_Input_Point)
	testing.expect(t, !shared_writer_begin_run(&gate, 7, 20), "begin_run refused while thread outside input point")
	testing.expect(t, gate.wait_timer_armed)
	testing.expect_value(t, gate.wait_started_tick, u64(100))

	// Thread 102 also leaves; still blocked.
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 102), Leave_Input_Point_Result.Left)
	may_run, decision = shared_writer_may_run(&gate, 7, 20, 120)
	testing.expect(t, !may_run)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Wait_Input_Point)
	// First wait timestamp must NOT reset when checked again.
	testing.expect_value(t, gate.wait_started_tick, u64(100))

	// Thread 101 enters input point; 102 still outside -> still blocked.
	testing.expect(t, recorded_thread_enter_input_point(&gate, 101))
	testing.expect(t, !recorded_thread_enter_input_point(&gate, 101), "double enter must be refused")
	may_run, decision = shared_writer_may_run(&gate, 7, 20, 130)
	testing.expect(t, !may_run)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Wait_Input_Point)

	// Thread 102 enters input point -> all at input point, writer may run,
	// and timer stays armed until shared_writer_begin_run actually dispatches it!
	testing.expect(t, recorded_thread_enter_input_point(&gate, 102))
	testing.expect(t, gate.wait_timer_armed)
	testing.expect_value(t, gate.waiting_writer_count, u32(1))
	may_run, decision = shared_writer_may_run(&gate, 7, 20, 140)
	testing.expect(t, may_run)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Run_At_Input_Point)

	// Rapid enter/leave before writer runs must NOT reset wait_started_tick.
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 102), Leave_Input_Point_Result.Left)
	testing.expect(t, gate.wait_timer_armed)
	testing.expect_value(t, gate.wait_started_tick, u64(100))
	testing.expect(t, recorded_thread_enter_input_point(&gate, 102))

	// Once the waiting writer begins running, the wait timer disarms cleanly.
	testing.expect(t, shared_writer_begin_run(&gate, 7, 20))
	testing.expect(t, !gate.wait_timer_armed)
	testing.expect_value(t, gate.waiting_writer_count, u32(0))
	testing.expect(t, shared_writer_end_run(&gate, 7, 20))
}

// Strict one-stint bound: before stint_bound_ticks (bound - 1) and on clock
// rollback nothing expires; at exactly stint_bound_ticks the history ends
// cleanly with Stint_Bound_Reached and the shared writer runs freely.
@(test)
shared_writer_stint_bound_ends_history_cleanly :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	STINT :: u64(25)
	testing.expect(t, shared_writer_gate_init(&gate, 2, 1, STINT))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect(t, add_shared_writer(&gate, 9, 3))

	// Before any writer waits, stint cannot expire.
	exp0, reason0 := shared_writer_stint_expired(&gate, 1000)
	testing.expect(t, !exp0)
	testing.expect_value(t, reason0, input_history.History_End_Reason.None)

	// Writer attempts to run at tick 500 -> waits, arming the stint timer.
	may, dec := shared_writer_may_run(&gate, 9, 3, 500)
	testing.expect(t, !may)
	testing.expect_value(t, dec, Writer_Schedule_Decision.Wait_Input_Point)

	// Clock rollback (now < wait_started_tick) must not underflow or expire.
	exp_back, reason_back := shared_writer_stint_expired(&gate, 499)
	testing.expect(t, !exp_back)
	testing.expect_value(t, reason_back, input_history.History_End_Reason.None)

	// At bound - 1 (500 + 24 = 524), still active and waiting.
	exp_edge, reason_edge := shared_writer_stint_expired(&gate, 500 + STINT - 1)
	testing.expect(t, !exp_edge)
	testing.expect_value(t, reason_edge, input_history.History_End_Reason.None)
	testing.expect_value(t, gate.state, Shared_Writer_Gate_State.Active)

	// At exact bound (500 + 25 = 525), history ends cleanly with Stint_Bound_Reached.
	exp_hit, reason_hit := shared_writer_stint_expired(&gate, 500 + STINT)
	testing.expect(t, exp_hit)
	testing.expect_value(t, reason_hit, input_history.History_End_Reason.Stint_Bound_Reached)
	testing.expect_value(t, gate.state, Shared_Writer_Gate_State.Ended_Stint_Bound)
	testing.expect_value(t, gate.waiting_writer_count, u32(0))

	// Shared writer runs freely immediately after stint expiration.
	may_after, dec_after := shared_writer_may_run(&gate, 9, 3, 526)
	testing.expect(t, may_after)
	testing.expect_value(t, dec_after, Writer_Schedule_Decision.Run_Freely)

	// Subsequent expiration checks report false with the kept end reason.
	exp_again, reason_again := shared_writer_stint_expired(&gate, 999)
	testing.expect(t, !exp_again)
	testing.expect_value(t, reason_again, input_history.History_End_Reason.Stint_Bound_Reached)
}

// Immediate revocation override: revocation ends the history at once with
// Revocation (even at tick 0 with recorded thread outside input point) and
// releases every waiting shared writer immediately.
@(test)
shared_writer_revocation_overrides_immediately :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 3, 7, max(u64)))
	testing.expect(t, register_recorded_thread(&gate, 11, starts_at_input_point = false))
	testing.expect(t, add_shared_writer(&gate, 12, 4))
	testing.expect(t, add_shared_writer(&gate, 13, 5))

	// Both shared writers are blocked.
	m1, d1 := shared_writer_may_run(&gate, 12, 4, 0)
	m2, d2 := shared_writer_may_run(&gate, 13, 5, 0)
	testing.expect(t, !m1 && d1 == .Wait_Input_Point)
	testing.expect(t, !m2 && d2 == .Wait_Input_Point)
	testing.expect_value(t, gate.waiting_writer_count, u32(2))

	// Revocation ends the gate immediately without waiting for input point or stint.
	ended, reason := shared_writer_revoke_immediately(&gate)
	testing.expect(t, ended)
	testing.expect_value(t, reason, input_history.History_End_Reason.Revocation)
	testing.expect_value(t, gate.state, Shared_Writer_Gate_State.Ended_Revocation)
	testing.expect_value(t, gate.waiting_writer_count, u32(0))
	testing.expect(t, !gate.wait_timer_armed)

	// Both shared writers immediately run freely.
	m1_after, d1_after := shared_writer_may_run(&gate, 12, 4, 0)
	m2_after, d2_after := shared_writer_may_run(&gate, 13, 5, 0)
	testing.expect(t, m1_after && d1_after == .Run_Freely)
	testing.expect(t, m2_after && d2_after == .Run_Freely)

	// Second revocation call is idempotent and returns false with kept reason.
	ended2, reason2 := shared_writer_revoke_immediately(&gate)
	testing.expect(t, !ended2)
	testing.expect_value(t, reason2, input_history.History_End_Reason.Revocation)
}

// gate_counts_match checks that the counters of the gate equal what its
// tables hold: a refusal must leave both unchanged.
@(private = "file")
gate_counts_match :: proc(t: ^testing.T, gate: ^Shared_Writer_Gate, loc := #caller_location) {
	threads, at_point, writers, active, waiting: u32
	for entry in gate.threads {
		if entry.thread_id != 0 {
			threads += 1
			if entry.at_input_point {
				at_point += 1
			}
		}
	}
	for entry in gate.writers {
		if entry.process_slot != 0 {
			writers += 1
			active += entry.active_cpus
			if entry.waiting {
				waiting += 1
			}
		}
	}
	testing.expect_value(t, gate.thread_count, threads, loc = loc)
	testing.expect_value(t, gate.threads_at_input_point, at_point, loc = loc)
	testing.expect_value(t, gate.writer_count, writers, loc = loc)
	testing.expect_value(t, gate.active_writer_cpus, active, loc = loc)
	testing.expect_value(t, gate.waiting_writer_count, waiting, loc = loc)
}

// Three recorded threads and one writer on two processors: the writer waits
// until the last thread enters, no thread leaves while either processor runs
// the writer, and a refused leave changes nothing.
@(test)
shared_writer_gate_holds_every_thread_while_any_processor_writes :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, 1000))
	for id in u32(1) ..= 3 {
		testing.expect(t, register_recorded_thread(&gate, id, starts_at_input_point = false))
	}
	testing.expect(t, add_shared_writer(&gate, 2, 1))

	for id in u32(1) ..= 3 {
		may, decision := shared_writer_may_run(&gate, 2, 1, u64(id))
		testing.expect(t, !may)
		testing.expect_value(t, decision, Writer_Schedule_Decision.Wait_Input_Point)
		testing.expect(t, !shared_writer_begin_run(&gate, 2, 1))
		testing.expect(t, recorded_thread_enter_input_point(&gate, id))
	}
	// The first wait armed the timer; later probes keep its start.
	testing.expect_value(t, gate.wait_started_tick, u64(1))
	gate_counts_match(t, &gate)

	may, decision := shared_writer_may_run(&gate, 2, 1, 4)
	testing.expect(t, may)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Run_At_Input_Point)
	testing.expect(t, shared_writer_begin_run(&gate, 2, 1))
	testing.expect(t, shared_writer_begin_run(&gate, 2, 1), "a second processor runs the same writer")
	testing.expect_value(t, gate.active_writer_cpus, u32(2))

	for id in u32(1) ..= 3 {
		testing.expect_value(t, recorded_thread_leave_input_point(&gate, id), Leave_Input_Point_Result.Must_Wait_Writers)
	}
	testing.expect_value(t, gate.threads_at_input_point, u32(3))
	gate_counts_match(t, &gate)

	// One processor left the writer: the other still holds every thread.
	testing.expect(t, shared_writer_end_run(&gate, 2, 1))
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 2), Leave_Input_Point_Result.Must_Wait_Writers)
	testing.expect(t, shared_writer_end_run(&gate, 2, 1))
	testing.expect(t, !shared_writer_end_run(&gate, 2, 1), "a third end of two runs must be refused")
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 2), Leave_Input_Point_Result.Left)
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 2), Leave_Input_Point_Result.Refused)
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 99), Leave_Input_Point_Result.Refused)
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 0), Leave_Input_Point_Result.Refused)
	testing.expect(t, !recorded_thread_enter_input_point(&gate, 0))
	testing.expect(t, !recorded_thread_enter_input_point(&gate, 99))
	gate_counts_match(t, &gate)
}

// A writer that waits is never starved: rapid enter and leave of a thread,
// a thread that exits, and a new thread that starts outside an input point
// all keep the first wait start, and the bound ends the history at exactly
// that start plus the stint.
@(test)
shared_writer_gate_bound_survives_churn_of_the_recorded_threads :: proc(t: ^testing.T) {
	STINT :: u64(100)
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, STINT))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect(t, register_recorded_thread(&gate, 2, starts_at_input_point = true))
	testing.expect(t, add_shared_writer(&gate, 5, 5))
	may, _ := shared_writer_may_run(&gate, 5, 5, 10)
	testing.expect(t, !may)

	for round in u64(0) ..< 40 {
		testing.expect(t, recorded_thread_enter_input_point(&gate, 1))
		testing.expect_value(t, recorded_thread_leave_input_point(&gate, 1), Leave_Input_Point_Result.Left)
		probe, _ := shared_writer_may_run(&gate, 5, 5, 10 + round)
		testing.expect(t, !probe)
	}
	testing.expect_value(t, gate.wait_started_tick, u64(10))

	// The thread outside exits: every thread left is at an input point, the
	// writer may run, and the bound does not end the history then.
	testing.expect(t, unregister_recorded_thread(&gate, 1))
	testing.expect(t, !unregister_recorded_thread(&gate, 1), "a second exit of one thread must be refused")
	testing.expect(t, gate.wait_timer_armed)
	testing.expect_value(t, gate.waiting_writer_count, u32(1))
	may, _ = shared_writer_may_run(&gate, 5, 5, 50)
	testing.expect(t, may)
	expired, reason := shared_writer_stint_expired(&gate, 10 + STINT * 4)
	testing.expect(t, !expired, "the bound never ends a history while every thread is at an input point")
	testing.expect_value(t, reason, input_history.History_End_Reason.None)

	// A new thread starts outside an input point before the writer ran: the
	// wait keeps its first start.
	testing.expect(t, register_recorded_thread(&gate, 3, starts_at_input_point = false))
	may, _ = shared_writer_may_run(&gate, 5, 5, 60)
	testing.expect(t, !may)
	testing.expect_value(t, gate.wait_started_tick, u64(10))

	expired, reason = shared_writer_stint_expired(&gate, 10 + STINT - 1)
	testing.expect(t, !expired)
	expired, reason = shared_writer_stint_expired(&gate, 10 + STINT)
	testing.expect(t, expired)
	testing.expect_value(t, reason, input_history.History_End_Reason.Stint_Bound_Reached)

	// After the end, the gate refuses every change and lets the writer run.
	testing.expect(t, !register_recorded_thread(&gate, 4))
	testing.expect(t, !unregister_recorded_thread(&gate, 2))
	testing.expect(t, !add_shared_writer(&gate, 6, 6))
	testing.expect(t, !shared_writer_begin_run(&gate, 5, 5))
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 2), Leave_Input_Point_Result.Refused)
	testing.expect(t, !shared_writer_end_normal(&gate))
	ended, kept := shared_writer_revoke_immediately(&gate)
	testing.expect(t, !ended)
	testing.expect_value(t, kept, input_history.History_End_Reason.Stint_Bound_Reached)
	free, decision := shared_writer_may_run(&gate, 5, 5, 0)
	testing.expect(t, free)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Run_Freely)
}

// The edges of the bound: one tick, and the largest bound with a wait that
// starts at 0, which only the largest tick reaches.
@(test)
shared_writer_gate_bound_edges :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, 1))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect(t, add_shared_writer(&gate, 2, 2))
	shared_writer_may_run(&gate, 2, 2, 7)
	expired, _ := shared_writer_stint_expired(&gate, 7)
	testing.expect(t, !expired)
	expired, _ = shared_writer_stint_expired(&gate, 8)
	testing.expect(t, expired)

	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, max(u64)))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect(t, add_shared_writer(&gate, 2, 2))
	shared_writer_may_run(&gate, 2, 2, 0)
	expired, _ = shared_writer_stint_expired(&gate, max(u64) - 1)
	testing.expect(t, !expired)
	expired, _ = shared_writer_stint_expired(&gate, max(u64))
	testing.expect(t, expired)

	// Nil gates are refused everywhere, and a nil gate never holds a writer.
	testing.expect(t, !register_recorded_thread(nil, 1))
	testing.expect(t, !unregister_recorded_thread(nil, 1))
	testing.expect(t, !add_shared_writer(nil, 1, 1))
	testing.expect(t, !remove_shared_writer(nil, 1, 1))
	testing.expect(t, !recorded_thread_enter_input_point(nil, 1))
	testing.expect_value(t, recorded_thread_leave_input_point(nil, 1), Leave_Input_Point_Result.Refused)
	testing.expect(t, !shared_writer_begin_run(nil, 1, 1))
	testing.expect(t, !shared_writer_end_run(nil, 1, 1))
	testing.expect(t, !shared_writer_end_normal(nil))
	nil_expired, nil_reason := shared_writer_stint_expired(nil, 1)
	testing.expect(t, !nil_expired)
	testing.expect_value(t, nil_reason, input_history.History_End_Reason.None)
	nil_ended, _ := shared_writer_revoke_immediately(nil)
	testing.expect(t, !nil_ended)
	nil_may, nil_decision := shared_writer_may_run(nil, 1, 1)
	testing.expect(t, nil_may)
	testing.expect_value(t, nil_decision, Writer_Schedule_Decision.Run_Freely)
}

// A slot that another process took again has another serial: it is not the
// writer, so it runs freely and cannot start or end a run of the writer.
@(test)
shared_writer_gate_refuses_a_reused_slot :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, 10))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect(t, add_shared_writer(&gate, 4, 7))
	may, decision := shared_writer_may_run(&gate, 4, 8, 0)
	testing.expect(t, may)
	testing.expect_value(t, decision, Writer_Schedule_Decision.Run_Freely)
	testing.expect_value(t, gate.waiting_writer_count, u32(0))
	testing.expect(t, !gate.wait_timer_armed)
	testing.expect(t, recorded_thread_enter_input_point(&gate, 1))
	testing.expect(t, !shared_writer_begin_run(&gate, 4, 8))
	testing.expect(t, !shared_writer_end_run(&gate, 4, 8))
	testing.expect(t, !remove_shared_writer(&gate, 4, 8))
	testing.expect(t, !remove_shared_writer(&gate, 0, 7))
	testing.expect(t, !remove_shared_writer(&gate, 4, 0))
	testing.expect(t, !shared_writer_begin_run(&gate, 0, 7))
	testing.expect(t, !shared_writer_end_run(&gate, 4, 0))
	gate_counts_match(t, &gate)
}

// The counters of processors stop at their largest value: a begin that would
// wrap is refused and changes nothing.
@(test)
shared_writer_gate_refuses_a_processor_count_that_wraps :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, 10))
	testing.expect(t, add_shared_writer(&gate, 2, 2))
	gate.writers[0].active_cpus = max(u32)
	gate.active_writer_cpus = max(u32)
	testing.expect(t, !shared_writer_begin_run(&gate, 2, 2))
	testing.expect_value(t, gate.writers[0].active_cpus, max(u32))
	testing.expect_value(t, gate.active_writer_cpus, max(u32))
	// A thread that starts outside an input point is refused while a writer runs.
	testing.expect(t, !register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect_value(t, gate.thread_count, u32(0))
}

// A revocation while a writer runs on a processor ends the history at once;
// the processor still ends its run, which the cleanup counts, and the
// recorded threads are no longer held by the gate.
@(test)
shared_writer_gate_revocation_while_a_writer_runs :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, 10))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = true))
	testing.expect(t, add_shared_writer(&gate, 2, 2))
	testing.expect(t, add_shared_writer(&gate, 3, 3))
	testing.expect(t, shared_writer_begin_run(&gate, 2, 2))
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 1), Leave_Input_Point_Result.Must_Wait_Writers)

	ended, reason := shared_writer_revoke_immediately(&gate)
	testing.expect(t, ended)
	testing.expect_value(t, reason, input_history.History_End_Reason.Revocation)
	testing.expect_value(t, gate.state, Shared_Writer_Gate_State.Ended_Revocation)
	for writer in ([2]u32{2, 3}) {
		may, decision := shared_writer_may_run(&gate, writer, writer, 0)
		testing.expect(t, may)
		testing.expect_value(t, decision, Writer_Schedule_Decision.Run_Freely)
	}
	// The run that began before the revocation ends; its counter falls to 0.
	testing.expect(t, shared_writer_end_run(&gate, 2, 2))
	testing.expect(t, !shared_writer_end_run(&gate, 2, 2))
	testing.expect(t, !shared_writer_end_run(&gate, 3, 3))
	testing.expect_value(t, gate.active_writer_cpus, u32(0))
	// The writers leave the ended gate.
	testing.expect(t, remove_shared_writer(&gate, 2, 2))
	testing.expect(t, remove_shared_writer(&gate, 3, 3))
	testing.expect(t, !remove_shared_writer(&gate, 3, 3))
	testing.expect_value(t, gate.writer_count, u32(0))
	expired, kept := shared_writer_stint_expired(&gate, max(u64))
	testing.expect(t, !expired)
	testing.expect_value(t, kept, input_history.History_End_Reason.Revocation)
}

// The removal of writers: a waiting writer that goes disarms the bound when it
// was the last one that waited, and a running writer that goes no longer
// holds the recorded threads.
@(test)
shared_writer_gate_removal_releases_waits_and_runs :: proc(t: ^testing.T) {
	gate: Shared_Writer_Gate
	testing.expect(t, shared_writer_gate_init(&gate, 1, 1, 10))
	testing.expect(t, register_recorded_thread(&gate, 1, starts_at_input_point = false))
	testing.expect(t, add_shared_writer(&gate, 2, 2))
	testing.expect(t, add_shared_writer(&gate, 3, 3))
	shared_writer_may_run(&gate, 2, 2, 5)
	shared_writer_may_run(&gate, 3, 3, 6)
	testing.expect_value(t, gate.waiting_writer_count, u32(2))

	testing.expect(t, remove_shared_writer(&gate, 2, 2))
	testing.expect(t, gate.wait_timer_armed, "another writer still waits")
	testing.expect_value(t, gate.wait_started_tick, u64(5))
	testing.expect(t, remove_shared_writer(&gate, 3, 3))
	testing.expect(t, !gate.wait_timer_armed)
	expired, _ := shared_writer_stint_expired(&gate, 1000)
	testing.expect(t, !expired, "no writer waits: the bound has nothing to end")
	gate_counts_match(t, &gate)

	// A writer that runs and goes after the shoot-down of its mapping.
	testing.expect(t, add_shared_writer(&gate, 4, 4))
	testing.expect(t, recorded_thread_enter_input_point(&gate, 1))
	testing.expect(t, shared_writer_begin_run(&gate, 4, 4))
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 1), Leave_Input_Point_Result.Must_Wait_Writers)
	testing.expect(t, remove_shared_writer(&gate, 4, 4))
	testing.expect_value(t, gate.active_writer_cpus, u32(0))
	testing.expect(t, !shared_writer_end_run(&gate, 4, 4), "the end of a run of a removed writer must be refused")
	testing.expect_value(t, recorded_thread_leave_input_point(&gate, 1), Leave_Input_Point_Result.Left)
	gate_counts_match(t, &gate)

	// The free places are taken again: the table holds its capacity once more.
	for slot in u32(10) ..< u32(10 + SHARED_WRITER_CAPACITY) {
		testing.expect(t, add_shared_writer(&gate, slot, 1))
	}
	testing.expect(t, !add_shared_writer(&gate, 9, 1))
	testing.expect(t, shared_writer_end_normal(&gate))
	testing.expect_value(t, gate.history_end_reason, input_history.History_End_Reason.Normal_Stop)
	testing.expect(t, !shared_writer_end_normal(&gate))
}
