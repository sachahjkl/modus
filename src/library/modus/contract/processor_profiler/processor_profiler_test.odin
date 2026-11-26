#+build !freestanding
#+build !modus
package processor_profiler

import "core:testing"

@(test)
profiler_computes_deltas_ipc_and_refuses_backwards_counters :: proc(t: ^testing.T) {
	p: Profiler_Session
	profiler_init(&p)

	_, r0 := profiler_record_sample(&p, {thread_id = 0})
	testing.expect_value(t, r0, Profiler_Refusal.Invalid_Thread)

	// First sample establishes baseline.
	_, r1 := profiler_record_sample(&p, {thread_id = 7, cycles = 1000, instructions = 500, cache_misses = 10, branch_misses = 2})
	testing.expect_value(t, r1, Profiler_Refusal.None)

	// Backwards sample refused without mutation.
	_, rb := profiler_record_sample(&p, {thread_id = 7, cycles = 999, instructions = 600, cache_misses = 10, branch_misses = 2})
	testing.expect_value(t, rb, Profiler_Refusal.Counter_Backwards)

	// Second sample computes exact IPC (2000 inst / 1000 cycles = 2000 milli-IPC) and miss rate.
	d, r2 := profiler_record_sample(&p, {thread_id = 7, cycles = 2000, instructions = 2500, cache_misses = 30, branch_misses = 5})
	testing.expect_value(t, r2, Profiler_Refusal.None)
	testing.expect_value(t, d.cycles, u64(1000))
	testing.expect_value(t, d.instructions, u64(2000))
	testing.expect_value(t, d.ipc_milli, u64(2000))
	testing.expect_value(t, d.cache_miss_per_k_inst, u64(10))
}

@(test)
external_pager_enforces_wx_bounds_and_maps_pages :: proc(t: ^testing.T) {
	_, bad := pager_action_of_word(99)
	testing.expect(t, !bad)

	pg: External_Pager
	pager_init(&pg)

	// W^X violation refused.
	testing.expect(t, !pager_add_region(&pg, 0x1000_0000, 4, writable = true, executable = true, backed = false))
	// Valid RW anonymous heap and RX backed code regions.
	testing.expect(t, pager_add_region(&pg, 0x1000_0000, 4, writable = true, executable = false, backed = false))
	testing.expect(t, pager_add_region(&pg, 0x2000_0000, 2, writable = false, executable = true, backed = true))

	act1, p1 := pager_handle_fault(&pg, 0x1000_1234, is_write = true, is_exec = false)
	testing.expect_value(t, act1, Pager_Action.Map_Zero_Page)
	testing.expect_value(t, p1, u64(0x1000_1000))

	// Exec on RW region refused.
	act_bad, _ := pager_handle_fault(&pg, 0x1000_1234, is_write = false, is_exec = true)
	testing.expect_value(t, act_bad, Pager_Action.Refuse_Stop)

	// Exec on RX backed region maps backing page; write on RX refused.
	act2, p2 := pager_handle_fault(&pg, 0x2000_0500, is_write = false, is_exec = true)
	testing.expect_value(t, act2, Pager_Action.Map_Back_Page)
	testing.expect_value(t, p2, u64(0x2000_0000))
	act_ro, _ := pager_handle_fault(&pg, 0x2000_0500, is_write = true, is_exec = false)
	testing.expect_value(t, act_ro, Pager_Action.Refuse_Stop)
}
