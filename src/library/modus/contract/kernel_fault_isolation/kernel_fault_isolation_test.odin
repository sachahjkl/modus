#+build !freestanding
package kernel_fault_isolation

import "core:testing"

@(test)
mce_isolation_branch_irq_and_fuzz_coverage_ring :: proc(t: ^testing.T) {
	_, bad := fault_action_of_word(99)
	testing.expect(t, !bad)

	// Recoverable uncorrected user memory poison stops ONLY that user process.
	user_poison := MC_STATUS_VAL | MC_STATUS_UC | MC_STATUS_S | MC_STATUS_AR
	testing.expect_value(t, classify_machine_check(user_poison, in_user_ring = true, rip_valid = true, addr_valid = true), Fault_Action.Kill_User_Process)
	// Same fault inside kernel ring halts machine.
	testing.expect_value(t, classify_machine_check(user_poison, in_user_ring = false, rip_valid = true, addr_valid = true), Fault_Action.Halt_Machine)
	// PCC=1 (corrupted processor context) always halts machine even in user ring.
	testing.expect_value(t, classify_machine_check(user_poison | MC_STATUS_PCC, in_user_ring = true, rip_valid = true, addr_valid = true), Fault_Action.Halt_Machine)
	// Corrected error ignored.
	testing.expect_value(t, classify_machine_check(MC_STATUS_VAL, in_user_ring = true, rip_valid = true, addr_valid = true), Fault_Action.Ignore_Corrected)

	// Branch-count interrupt placement.
	pt := Branch_Interrupt_Point{retired_branches = 42_000, instruction_ptr = 0x401234, vector = 32}
	testing.expect(t, branch_interrupt_matches(pt, 42_000, 0x401234))
	testing.expect(t, !branch_interrupt_matches(pt, 41_999, 0x401234))

	// Counter ring & per-procedure coverage.
	ring: Counter_Ring
	counter_ring_init(&ring)
	testing.expect(t, procedure_coverage_mark(&ring, 7))
	testing.expect(t, !procedure_coverage_mark(&ring, 7))
	testing.expect(t, procedure_coverage_mark(&ring, 200))
	testing.expect_value(t, procedure_coverage_count(&ring), 2)
	testing.expect(t, counter_ring_push(&ring, {sequence = 1, edges_hit = 120, new_edges = 5, smp_interleave = 0b1010}))
	testing.expect_value(t, ring.write_idx, u64(1))
}
