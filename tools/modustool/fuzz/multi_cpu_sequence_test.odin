// Host unit tests for two-processor fuzzing sequences and counter-ring
// prefetch windows (multi_cpu_sequence.odin).
package fuzz

import "core:testing"

@(test)
multi_cpu_sequence_refuses_invalid_cpus_self_wakes_and_unpaired_barriers :: proc(t: ^testing.T) {
	seq: Multi_Cpu_Sequence
	multi_cpu_sequence_init(&seq)

	// Empty sequence is refused.
	testing.expect_value(t, multi_cpu_sequence_validate(&seq), Multi_Cpu_Refusal.Empty_Sequence)

	// Out-of-range CPU, zero barrier ID, and self-wake are refused.
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 2, kind = .Kernel_Operation}), Multi_Cpu_Refusal.Invalid_Cpu)
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 0, kind = .Barrier_Sync, barrier_id = 0}), Multi_Cpu_Refusal.Invalid_Barrier_Id)
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 1, kind = .Cross_Cpu_Wake, target_cpu = 1}), Multi_Cpu_Refusal.Self_Wake_Refused)
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 0, kind = .Cross_Cpu_Wake, target_cpu = 2}), Multi_Cpu_Refusal.Invalid_Cpu)

	// Unpaired barrier on CPU 0 alone is refused by validate.
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 0, kind = .Barrier_Sync, barrier_id = 7}), Multi_Cpu_Refusal.None)
	testing.expect_value(t, multi_cpu_sequence_validate(&seq), Multi_Cpu_Refusal.Unpaired_Barrier)

	// Pairing barrier 7 on CPU 1 resolves validation cleanly.
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 1, kind = .Barrier_Sync, barrier_id = 7}), Multi_Cpu_Refusal.None)
	testing.expect_value(t, multi_cpu_sequence_validate(&seq), Multi_Cpu_Refusal.None)

	// Filling to capacity then adding one more fails cleanly with Step_Capacity_Exceeded.
	for seq.step_count < MULTI_CPU_STEPS_MAX {
		testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 0, kind = .Kernel_Operation, operation_word = 1}), Multi_Cpu_Refusal.None)
	}
	testing.expect_value(t, multi_cpu_sequence_add(&seq, {cpu_id = 1, kind = .Kernel_Operation, operation_word = 2}), Multi_Cpu_Refusal.Step_Capacity_Exceeded)
}

@(test)
multi_cpu_lock_wake_and_counter_ring_window_round_trip :: proc(t: ^testing.T) {
	// Deterministic two-CPU lock-order + cross-CPU wake sequence passes validation.
	seq := multi_cpu_sequence_plan_lock_wake(11, 22)
	testing.expect_value(t, multi_cpu_sequence_validate(&seq), Multi_Cpu_Refusal.None)
	testing.expect_value(t, seq.step_count, 5)
	testing.expect_value(t, seq.barrier_count, 2)
	testing.expect_value(t, seq.wake_count, 1)

	// Counter-ring prefetch window refuses bad sizes.
	w: Counter_Ring_Window
	testing.expect_value(t, counter_ring_window_init(&w, 0), Multi_Cpu_Refusal.Invalid_Window_Size)
	testing.expect_value(t, counter_ring_window_init(&w, COUNTER_RING_SLOTS_MAX + 1), Multi_Cpu_Refusal.Invalid_Window_Size)

	testing.expect_value(t, counter_ring_window_init(&w, 3), Multi_Cpu_Refusal.None)
	testing.expect_value(t, counter_ring_window_complete(&w, 1), Multi_Cpu_Refusal.Window_Empty)

	s1, r1 := counter_ring_window_enqueue(&w)
	s2, r2 := counter_ring_window_enqueue(&w)
	s3, r3 := counter_ring_window_enqueue(&w)
	testing.expect_value(t, r1, Multi_Cpu_Refusal.None)
	testing.expect_value(t, r2, Multi_Cpu_Refusal.None)
	testing.expect_value(t, r3, Multi_Cpu_Refusal.None)
	testing.expect_value(t, s1.counter_set_index, 0)
	testing.expect_value(t, s2.counter_set_index, 1)
	testing.expect_value(t, s3.counter_set_index, 2)

	// Fourth enqueue on 3-slot window is refused.
	_, r4 := counter_ring_window_enqueue(&w)
	testing.expect_value(t, r4, Multi_Cpu_Refusal.Window_Full)

	// Out-of-order completion is refused; FIFO completion frees slot and wraps cleanly.
	testing.expect_value(t, counter_ring_window_complete(&w, s2.sequence_id), Multi_Cpu_Refusal.Slot_Mismatch)
	testing.expect_value(t, counter_ring_window_complete(&w, s1.sequence_id), Multi_Cpu_Refusal.None)
	s4, r4_ok := counter_ring_window_enqueue(&w)
	testing.expect_value(t, r4_ok, Multi_Cpu_Refusal.None)
	testing.expect_value(t, s4.sequence_id, u64(4))
	testing.expect_value(t, s4.counter_set_index, 0)
	testing.expect_value(t, w.completed_total, u64(1))
}
