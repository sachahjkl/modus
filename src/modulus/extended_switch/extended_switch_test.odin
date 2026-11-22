#+build !freestanding
package extended_switch

import "core:testing"

// Zero-initialized records and boundary arguments always require a restore,
// including on processor 0 where raw index 0 must never alias NO_PROCESSOR.
@(test)
edges_and_zero_state_always_restore :: proc(t: ^testing.T) {
	cache: Processor_Cache
	thread: Thread_State

	testing.expect_value(t, restore_decision(cache, thread, 0, 0, 0), Restore_Decision.Restore)
	testing.expect_value(t, restore_decision(cache, thread, 0, 1, 1), Restore_Decision.Restore)
	testing.expect_value(t, restore_decision(cache, thread, 0, 0, 1), Restore_Decision.Restore)
	testing.expect_value(t, restore_decision(cache, thread, 0, 1, 0), Restore_Decision.Restore)

	// Attempting to save with invalid index, invalid serial, or max(u32) CPU
	// invalidates the cache and never produces a skip.
	thread_initialize(&thread)
	record_save(&cache, &thread, 0, 0, 1)
	testing.expect_value(t, cache.last_extended_thread_index, NO_THREAD)
	testing.expect_value(t, thread.last_extended_cpu, NO_PROCESSOR)
	testing.expect_value(t, restore_decision(cache, thread, 0, 0, 1), Restore_Decision.Restore)

	record_save(&cache, &thread, 0, 1, 0)
	testing.expect_value(t, cache.last_extended_thread_index, NO_THREAD)
	testing.expect_value(t, thread.last_extended_cpu, NO_PROCESSOR)
	testing.expect_value(t, restore_decision(cache, thread, 0, 1, 0), Restore_Decision.Restore)

	record_save(&cache, &thread, max(u32), 1, 1)
	testing.expect_value(t, cache.last_extended_thread_index, NO_THREAD)
	testing.expect_value(t, thread.last_extended_cpu, NO_PROCESSOR)
	testing.expect_value(t, restore_decision(cache, thread, max(u32), 1, 1), Restore_Decision.Restore)
}

// Saving a thread on a processor and picking the same thread again on the same
// processor skips the restore, including at processor 0 and max(u32) - 1.
@(test)
same_cpu_and_same_thread_skips_restore :: proc(t: ^testing.T) {
	for cpu_index in ([]u32{0, 1, 63, max(u32) - 1}) {
		cache: Processor_Cache
		thread: Thread_State
		thread_initialize(&thread)

		// First pick on a fresh processor must restore.
		testing.expect_value(t, restore_decision(cache, thread, cpu_index, 7, 42), Restore_Decision.Restore)
		record_restore(&cache, &thread)

		// After the thread leaves and saves on this processor, re-picking it skips restore.
		record_save(&cache, &thread, cpu_index, 7, 42)
		testing.expect_value(t, restore_decision(cache, thread, cpu_index, 7, 42), Restore_Decision.Skip)

		// Repeating save and re-pick on the same processor continues to skip.
		record_save(&cache, &thread, cpu_index, 7, 42)
		testing.expect_value(t, restore_decision(cache, thread, cpu_index, 7, 42), Restore_Decision.Skip)
	}
}

// Switching to a different thread on the same processor must restore, and
// returning to the first thread afterwards must also restore.
@(test)
different_thread_on_same_cpu_restores :: proc(t: ^testing.T) {
	cache: Processor_Cache
	thread_a, thread_b: Thread_State
	thread_initialize(&thread_a)
	thread_initialize(&thread_b)

	record_save(&cache, &thread_a, 0, 3, 10)
	testing.expect_value(t, restore_decision(cache, thread_b, 0, 4, 11), Restore_Decision.Restore)
	record_restore(&cache, &thread_b)

	// Even before thread_b saves, thread_a is no longer in CPU 0's registers.
	testing.expect_value(t, restore_decision(cache, thread_a, 0, 3, 10), Restore_Decision.Restore)

	record_save(&cache, &thread_b, 0, 4, 11)
	testing.expect_value(t, restore_decision(cache, thread_b, 0, 4, 11), Restore_Decision.Skip)
	testing.expect_value(t, restore_decision(cache, thread_a, 0, 3, 10), Restore_Decision.Restore)
}

// Migrating a thread to another processor and back to the original idle
// processor must restore, because the thread modified its state elsewhere.
@(test)
cross_cpu_migration_forces_restore :: proc(t: ^testing.T) {
	cpu0, cpu1: Processor_Cache
	thread: Thread_State
	thread_initialize(&thread)

	// Thread runs and saves on CPU 0.
	record_save(&cpu0, &thread, 0, 5, 99)
	testing.expect_value(t, restore_decision(cpu0, thread, 0, 5, 99), Restore_Decision.Skip)

	// Thread migrates to CPU 1: CPU 1 must restore.
	testing.expect_value(t, restore_decision(cpu1, thread, 1, 5, 99), Restore_Decision.Restore)
	record_restore(&cpu1, &thread)

	// Even before CPU 1 saves, CPU 0's cache must no longer skip for this thread.
	testing.expect_value(t, restore_decision(cpu0, thread, 0, 5, 99), Restore_Decision.Restore)

	// Thread saves on CPU 1 while CPU 0 stayed idle with its old cache untouched.
	record_save(&cpu1, &thread, 1, 5, 99)
	testing.expect_value(t, restore_decision(cpu1, thread, 1, 5, 99), Restore_Decision.Skip)

	// Thread migrates back to CPU 0: CPU 0 must restore because last_extended_cpu is CPU 1.
	testing.expect_value(t, restore_decision(cpu0, thread, 0, 5, 99), Restore_Decision.Restore)
}

// Thread_Control writes (Write_Registers / Write_Extended_State) bump the
// generation and force a restore on the same CPU, including across u64 wrap.
@(test)
generation_bump_forces_restore :: proc(t: ^testing.T) {
	cache: Processor_Cache
	thread: Thread_State
	thread_initialize(&thread)

	record_save(&cache, &thread, 2, 9, 77)
	testing.expect_value(t, restore_decision(cache, thread, 2, 9, 77), Restore_Decision.Skip)

	thread_mark_modified(&thread)
	testing.expect_value(t, restore_decision(cache, thread, 2, 9, 77), Restore_Decision.Restore)

	// Edge: generation at max(u64) wraps to 0 on modification and still forces restore.
	thread.extended_generation = max(u64)
	record_save(&cache, &thread, 2, 9, 77)
	testing.expect_value(t, restore_decision(cache, thread, 2, 9, 77), Restore_Decision.Skip)
	thread_mark_modified(&thread)
	testing.expect_value(t, thread.extended_generation, u64(0))
	testing.expect_value(t, restore_decision(cache, thread, 2, 9, 77), Restore_Decision.Restore)
}

// Guest_Run or any kernel operation that clobbers registers invalidates the
// processor cache and forces a restore for the same thread.
@(test)
processor_invalidation_forces_restore :: proc(t: ^testing.T) {
	cache: Processor_Cache
	thread: Thread_State
	thread_initialize(&thread)

	record_save(&cache, &thread, 1, 12, 500)
	testing.expect_value(t, restore_decision(cache, thread, 1, 12, 500), Restore_Decision.Skip)

	processor_invalidate(&cache)
	testing.expect_value(t, cache.last_extended_thread_index, NO_THREAD)
	testing.expect_value(t, restore_decision(cache, thread, 1, 12, 500), Restore_Decision.Restore)
}

// Reusing a thread slot with a new serial must restore, even on the same CPU
// and even if the generation value happens to match.
@(test)
reused_thread_slot_with_new_serial_restores :: proc(t: ^testing.T) {
	cache: Processor_Cache
	thread: Thread_State
	thread_initialize(&thread)

	record_save(&cache, &thread, 0, 6, 1)
	testing.expect_value(t, restore_decision(cache, thread, 0, 6, 1), Restore_Decision.Skip)

	// Even with identical generation and last_extended_cpu, a new serial forces restore.
	testing.expect_value(t, restore_decision(cache, thread, 0, 6, 2), Restore_Decision.Restore)

	// Full slot reuse via zeroing + thread_initialize also forces restore.
	thread = {}
	thread_initialize(&thread)
	testing.expect_value(t, restore_decision(cache, thread, 0, 6, 2), Restore_Decision.Restore)
	testing.expect_value(t, restore_decision(cache, thread, 0, 6, 1), Restore_Decision.Restore)
}
