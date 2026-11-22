// Pure decision state for skipping redundant extended-state restores on
// thread switches. A processor that takes again the thread whose x87/SSE/AVX
// registers it last saved skips xrstor/fxrstor when the thread neither ran on
// another processor nor had its saved state modified in the meantime.
//
// This package allocates no memory, holds no global state, and calls no
// hardware instruction or kernel operation.
package extended_switch

// Zero marks no thread in a processor cache and no processor in a thread
// state, so zero-initialized records always require a restore.
NO_THREAD :: u32(0)
NO_PROCESSOR :: u32(0)

// Processor_Cache records the thread whose extended state still lives in
// one processor's hardware registers. Only that processor reads and writes it.
Processor_Cache :: struct {
	last_extended_thread_index:  u32,
	last_extended_thread_serial: u64,
	last_extended_generation:    u64,
}

// Thread_State records a thread's extended-state generation and the processor
// that last saved its extended state (1 + processor_index, or 0 for none).
Thread_State :: struct {
	extended_generation: u64,
	last_extended_cpu:   u32,
}

// Restore_Decision states whether a processor picking a thread must restore
// the thread's saved extended state from memory or can keep its live registers.
Restore_Decision :: enum u8 {
	Restore = 0,
	Skip    = 1,
}

// processor_tag encodes a processor index as 1 + index so that 0 always means
// no processor. max(u32) cannot be encoded without wrapping and maps to none.
processor_tag :: #force_inline proc "contextless" (processor_index: u32) -> u32 {
	if processor_index == max(u32) {
		return NO_PROCESSOR
	}
	return processor_index + 1
}

// thread_initialize prepares a newly created or reused thread slot so no
// processor can match stale register state against it.
thread_initialize :: #force_inline proc "contextless" (thread: ^Thread_State) {
	thread.extended_generation += 1
	thread.last_extended_cpu = NO_PROCESSOR
}

// thread_mark_modified invalidates any processor's cached extended state for a
// thread whose saved state changed out of band (for example Thread_Control
// writes or thread teardown).
thread_mark_modified :: #force_inline proc "contextless" (thread: ^Thread_State) {
	thread.extended_generation += 1
	thread.last_extended_cpu = NO_PROCESSOR
}

// processor_invalidate forgets whichever thread's extended state lived in a
// processor's registers (for example after Guest_Run, thread stop, or restore).
processor_invalidate :: #force_inline proc "contextless" (cache: ^Processor_Cache) {
	cache^ = {}
}

// record_save records that processor_index just saved thread's extended state
// to memory while leaving that exact state live in its hardware registers.
record_save :: #force_inline proc "contextless" (
	cache: ^Processor_Cache,
	thread: ^Thread_State,
	processor_index: u32,
	thread_index: u32,
	thread_serial: u64,
) {
	tag := processor_tag(processor_index)
	if thread_index == NO_THREAD || thread_serial == 0 || tag == NO_PROCESSOR {
		processor_invalidate(cache)
		thread.last_extended_cpu = NO_PROCESSOR
		return
	}
	cache.last_extended_thread_index = thread_index
	cache.last_extended_thread_serial = thread_serial
	cache.last_extended_generation = thread.extended_generation
	thread.last_extended_cpu = tag
}

// restore_decision returns .Skip only when processor_index still holds the
// exact live extended state of (thread_index, thread_serial, generation) and
// the thread has not run on another processor or been modified since that save.
restore_decision :: #force_inline proc "contextless" (
	cache: Processor_Cache,
	thread: Thread_State,
	processor_index: u32,
	thread_index: u32,
	thread_serial: u64,
) -> Restore_Decision {
	tag := processor_tag(processor_index)
	if thread_index == NO_THREAD || thread_serial == 0 || tag == NO_PROCESSOR {
		return .Restore
	}
	if cache.last_extended_thread_index != thread_index {
		return .Restore
	}
	if cache.last_extended_thread_serial != thread_serial {
		return .Restore
	}
	if cache.last_extended_generation != thread.extended_generation {
		return .Restore
	}
	if thread.last_extended_cpu != tag {
		return .Restore
	}
	return .Skip
}

// record_restore records that a processor restored thread's extended state from
// memory: the processor's previous cached thread is overwritten, and the thread
// will now diverge from any state cached on another processor.
record_restore :: #force_inline proc "contextless" (cache: ^Processor_Cache, thread: ^Thread_State) {
	processor_invalidate(cache)
	thread.last_extended_cpu = NO_PROCESSOR
}
