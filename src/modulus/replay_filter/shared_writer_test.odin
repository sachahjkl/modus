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
