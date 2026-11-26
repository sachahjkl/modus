#+build !freestanding
package device_stop

import "core:testing"
import "modus:contract/call_outcome"

// Sound_Device start decision: busy refuses first even if absence is reported,
// absent device starts without sound handles, present idle device starts the
// driver, and only Nothing_Has_That_Name permits a silent start after driver_start.
@(test)
sound_device_start_decision_handles_busy_absent_and_present :: proc(t: ^testing.T) {
	testing.expect_value(t, sound_device_start_decide(true, true), Sound_Device_Start_Action.Refuse_Busy)
	testing.expect_value(t, sound_device_start_decide(true, false), Sound_Device_Start_Action.Refuse_Busy)
	testing.expect_value(t, sound_device_start_decide(false, false), Sound_Device_Start_Action.Start_Without_Sound)
	testing.expect_value(t, sound_device_start_decide(false, true), Sound_Device_Start_Action.Start_Driver)

	for outcome in call_outcome.Call_Outcome {
		testing.expect_value(t, sound_device_driver_status_allows_silent(outcome), outcome == .Nothing_Has_That_Name)
	}
}

// Stopping a slot with no live process does nothing and leaves state untouched.
@(test)
stop_without_process_does_nothing :: proc(t: ^testing.T) {
	active := true
	actions := stop_decide(false, true, &active)
	testing.expect_value(t, actions, Stop_Actions{})
	testing.expect(t, active)

	actions_nil := stop_decide(false, true, nil)
	testing.expect_value(t, actions_nil, Stop_Actions{})
}

// A non-driver process stops without touching PCI Bus Master, and reap_decide
// schedules no device cleanup for it.
@(test)
non_driver_never_touches_bus_master :: proc(t: ^testing.T) {
	active := true
	stop := stop_decide(true, false, &active)
	testing.expect_value(t, stop, Stop_Actions{disable_bus_master_before_stop = false, stop_process = true})
	testing.expect(t, active)

	reap := reap_decide(false, &active)
	testing.expect_value(t, reap, Reap_Actions{})
	testing.expect(t, active)
}

// Stopping a live device service turns off Bus Master before Process_Stop,
// and neither a repeated stop nor the later reap turns it off a second time.
@(test)
device_service_turns_bus_master_off_before_stop :: proc(t: ^testing.T) {
	active := true
	first := stop_decide(true, true, &active)
	testing.expect_value(t, first, Stop_Actions{disable_bus_master_before_stop = true, stop_process = true})
	testing.expect(t, !active)

	second := stop_decide(true, true, &active)
	testing.expect_value(t, second, Stop_Actions{disable_bus_master_before_stop = false, stop_process = true})
	testing.expect(t, !active)

	reap := reap_decide(true, &active)
	testing.expect_value(t, reap, Reap_Actions{disable_bus_master = false, close_queues = true})
	testing.expect(t, !active)
}

// A device service that stopped on its own still gets Bus Master turned off
// during reap before its queue memory closes, and only once.
@(test)
self_stopped_device_service_turns_bus_master_off_at_reap :: proc(t: ^testing.T) {
	active := true
	first := reap_decide(true, &active)
	testing.expect_value(t, first, Reap_Actions{disable_bus_master = true, close_queues = true})
	testing.expect(t, !active)

	second := reap_decide(true, &active)
	testing.expect_value(t, second, Reap_Actions{disable_bus_master = false, close_queues = true})
}

// A nil state pointer is refused cleanly without crashing.
@(test)
nil_bus_master_pointer_is_safe :: proc(t: ^testing.T) {
	testing.expect_value(t, stop_decide(true, true, nil), Stop_Actions{disable_bus_master_before_stop = false, stop_process = true})
	testing.expect_value(t, reap_decide(true, nil), Reap_Actions{disable_bus_master = false, close_queues = true})
}
