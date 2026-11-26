#+build !freestanding
#+build !modus
package kernel_fault_isolation

import "core:testing"

@(test)
mce_sdm_vol3b_classification_and_bounded_counter_ring :: proc(t: ^testing.T) {
	_, bad := fault_action_of_word(99)
	testing.expect(t, !bad)

	user_ar := MC_STATUS_VAL | MC_STATUS_UC | MC_STATUS_EN | MC_STATUS_S | MC_STATUS_AR
	// Requires MCG_SER_P (software_error_recovery_supported): without it, MUST halt!
	testing.expect_value(t, classify_machine_check(user_ar, false, true, true, true), Fault_Action.Halt_Machine)
	// With MCG_SER_P + EN + S + AR in user ring: isolates to user process.
	testing.expect_value(t, classify_machine_check(user_ar, true, true, true, true), Fault_Action.Kill_User_Process)
	// OVER bit set with UC MUST halt!
	testing.expect_value(t, classify_machine_check(user_ar | MC_STATUS_OVER, true, true, true, true), Fault_Action.Halt_Machine)
	// Action Optional (S=1, AR=0): no process kill needed.
	user_ao := MC_STATUS_VAL | MC_STATUS_UC | MC_STATUS_EN | MC_STATUS_S
	testing.expect_value(t, classify_machine_check(user_ao, true, true, true, true), Fault_Action.Ignore_Corrected)
	// Kernel ring always halts.
	testing.expect_value(t, classify_machine_check(user_ar, true, false, true, true), Fault_Action.Halt_Machine)

	// Counter ring bounds & dropped counter accounting.
	ring: Counter_Ring
	counter_ring_init(&ring)
	for i in u64(0) ..< COUNTER_RING_SLOTS {
		testing.expect(t, counter_ring_push(&ring, {sequence = i + 1}))
	}
	testing.expect(t, !counter_ring_push(&ring, {sequence = 99}))
	testing.expect_value(t, ring.dropped, u64(1))
}
