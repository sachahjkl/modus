// Two-processor multi-thread operation sequence planner and ahead-of-time
// counter-ring prefetch window planner for kernel fuzzing
// (src/md/infrastructure/kernel_fuzzing.md).
package fuzz

// Plan value: two-processor fuzzing target exercising cross-CPU lock order
// and cross-CPU wakes.
MULTI_CPU_COUNT :: 2

// Format property: matches operation_sequence.STEPS_MOST per sequence.
MULTI_CPU_STEPS_MAX :: 64

// Inline capacity: maximum ahead-of-time sequences kept in flight across
// separate counted-kernel counter sets.
COUNTER_RING_SLOTS_MAX :: 16

// Closed border refusal set for two-CPU sequence planning and counter-ring windows.
Multi_Cpu_Refusal :: enum u8 {
	None,
	Invalid_Cpu,
	Empty_Sequence,
	Step_Capacity_Exceeded,
	Unpaired_Barrier,
	Invalid_Barrier_Id,
	Self_Wake_Refused,
	Invalid_Window_Size,
	Window_Full,
	Window_Empty,
	Slot_Mismatch,
}

// Closed operation step kinds in a two-CPU fuzzing sequence.
Multi_Cpu_Step_Kind :: enum u8 {
	Kernel_Operation = 1,
	Barrier_Sync     = 2,
	Cross_Cpu_Wake   = 3,
	Lock_Order_Probe = 4,
}

// One scheduled step assigned to CPU 0 or CPU 1.
Multi_Cpu_Step :: struct {
	step_index:     int,
	cpu_id:         u8,
	thread_id:      u8,
	kind:           Multi_Cpu_Step_Kind,
	operation_word: u32,
	barrier_id:     u16,
	target_cpu:     u8,
}

// Bounded two-processor multi-thread operation sequence.
Multi_Cpu_Sequence :: struct {
	step_count:    int,
	barrier_count: int,
	wake_count:    int,
	steps:         [MULTI_CPU_STEPS_MAX]Multi_Cpu_Step,
}

// One in-flight operation sequence assigned to its own counted-kernel counter set.
Counter_Ring_Slot :: struct {
	sequence_id:       u64,
	counter_set_index: int,
	in_flight:         bool,
}

// Bounded FIFO prefetch window writing operation sequences ahead across
// disjoint counted-kernel counter sets.
Counter_Ring_Window :: struct {
	capacity:         int,
	head:             int,
	count:            int,
	next_sequence_id: u64,
	completed_total:  u64,
	slots:            [COUNTER_RING_SLOTS_MAX]Counter_Ring_Slot,
}

// multi_cpu_sequence_init resets seq to an empty two-CPU sequence.
multi_cpu_sequence_init :: proc(seq: ^Multi_Cpu_Sequence) {
	seq^ = {}
}

// multi_cpu_sequence_add validates CPU assignment, barrier ID, cross-CPU wake
// target, and capacity before appending step to seq.
multi_cpu_sequence_add :: proc(seq: ^Multi_Cpu_Sequence, step: Multi_Cpu_Step) -> Multi_Cpu_Refusal {
	if seq == nil {
		return .Empty_Sequence
	}
	if int(step.cpu_id) >= MULTI_CPU_COUNT {
		return .Invalid_Cpu
	}
	if seq.step_count >= MULTI_CPU_STEPS_MAX {
		return .Step_Capacity_Exceeded
	}
	switch step.kind {
	case .Kernel_Operation, .Lock_Order_Probe:
	case .Barrier_Sync:
		if step.barrier_id == 0 {
			return .Invalid_Barrier_Id
		}
	case .Cross_Cpu_Wake:
		if int(step.target_cpu) >= MULTI_CPU_COUNT {
			return .Invalid_Cpu
		}
		if step.target_cpu == step.cpu_id {
			return .Self_Wake_Refused
		}
	}
	added := step
	added.step_index = seq.step_count
	seq.steps[seq.step_count] = added
	seq.step_count += 1
	if step.kind == .Barrier_Sync {
		seq.barrier_count += 1
	} else if step.kind == .Cross_Cpu_Wake {
		seq.wake_count += 1
	}
	return .None
}

// multi_cpu_sequence_validate verifies that seq is non-empty and that every
// Barrier_Sync ID appears on both CPU 0 and CPU 1 so no thread deadlocks.
multi_cpu_sequence_validate :: proc(seq: ^Multi_Cpu_Sequence) -> Multi_Cpu_Refusal {
	if seq == nil || seq.step_count <= 0 {
		return .Empty_Sequence
	}
	for i in 0 ..< seq.step_count {
		step := seq.steps[i]
		if step.kind != .Barrier_Sync {
			continue
		}
		cpu0_seen := false
		cpu1_seen := false
		for j in 0 ..< seq.step_count {
			other := seq.steps[j]
			if other.kind == .Barrier_Sync && other.barrier_id == step.barrier_id {
				if other.cpu_id == 0 {
					cpu0_seen = true
				} else if other.cpu_id == 1 {
					cpu1_seen = true
				}
			}
		}
		if !cpu0_seen || !cpu1_seen {
			return .Unpaired_Barrier
		}
	}
	return .None
}

// multi_cpu_sequence_plan_lock_wake builds a deterministic two-CPU sequence
// exercising concurrent lock-order probes synchronized at barrier 1 followed
// by a cross-CPU wake from CPU 0 to CPU 1.
multi_cpu_sequence_plan_lock_wake :: proc(op_cpu0, op_cpu1: u32) -> (seq: Multi_Cpu_Sequence) {
	multi_cpu_sequence_init(&seq)
	_ = multi_cpu_sequence_add(&seq, {cpu_id = 0, thread_id = 0, kind = .Barrier_Sync, barrier_id = 1})
	_ = multi_cpu_sequence_add(&seq, {cpu_id = 1, thread_id = 1, kind = .Barrier_Sync, barrier_id = 1})
	_ = multi_cpu_sequence_add(&seq, {cpu_id = 0, thread_id = 0, kind = .Lock_Order_Probe, operation_word = op_cpu0})
	_ = multi_cpu_sequence_add(&seq, {cpu_id = 1, thread_id = 1, kind = .Lock_Order_Probe, operation_word = op_cpu1})
	_ = multi_cpu_sequence_add(&seq, {cpu_id = 0, thread_id = 0, kind = .Cross_Cpu_Wake, target_cpu = 1})
	return seq
}

// counter_ring_window_init initializes a prefetch counter-ring window with
// capacity disjoint counter sets (1..COUNTER_RING_SLOTS_MAX).
counter_ring_window_init :: proc(w: ^Counter_Ring_Window, capacity: int) -> Multi_Cpu_Refusal {
	if w == nil || capacity < 1 || capacity > COUNTER_RING_SLOTS_MAX {
		return .Invalid_Window_Size
	}
	w^ = {}
	w.capacity = capacity
	w.next_sequence_id = 1
	return .None
}

// counter_ring_window_enqueue reserves the next free counter set in FIFO order.
counter_ring_window_enqueue :: proc(w: ^Counter_Ring_Window) -> (slot: Counter_Ring_Slot, refusal: Multi_Cpu_Refusal) {
	if w == nil || w.capacity < 1 || w.capacity > COUNTER_RING_SLOTS_MAX {
		return {}, .Invalid_Window_Size
	}
	if w.count >= w.capacity {
		return {}, .Window_Full
	}
	idx := (w.head + w.count) % w.capacity
	slot = Counter_Ring_Slot {
		sequence_id       = w.next_sequence_id,
		counter_set_index = idx,
		in_flight         = true,
	}
	w.slots[idx] = slot
	w.count += 1
	w.next_sequence_id += 1
	return slot, .None
}

// counter_ring_window_complete retires the oldest in-flight sequence after
// verifying exact FIFO sequence_id agreement.
counter_ring_window_complete :: proc(w: ^Counter_Ring_Window, sequence_id: u64) -> Multi_Cpu_Refusal {
	if w == nil || w.capacity < 1 || w.capacity > COUNTER_RING_SLOTS_MAX {
		return .Invalid_Window_Size
	}
	if w.count == 0 {
		return .Window_Empty
	}
	head_slot := &w.slots[w.head]
	if !head_slot.in_flight || head_slot.sequence_id != sequence_id {
		return .Slot_Mismatch
	}
	head_slot^ = {}
	w.head = (w.head + 1) % w.capacity
	w.count -= 1
	w.completed_total += 1
	return .None
}
