#+build !freestanding
package driver_domain

import "core:testing"

@(test)
class_ring_keeper_restarts_bounded_and_preserves_client_ring :: proc(t: ^testing.T) {
	_, bad_st := keeper_state_of_word(99)
	testing.expect(t, !bad_st)

	k: Class_Ring_Keeper
	keeper_init(&k)
	testing.expect_value(t, k.state, Keeper_State.Ready)
	testing.expect_value(t, k.generation, u64(1))

	// Five crashes inside one 60s window restart cleanly, incrementing generation.
	for i in u64(0) ..< u64(MAX_RESTARTS_IN_WINDOW) {
		restart, ok := keeper_on_driver_stopped(&k, 1_000 + i * 1_000)
		testing.expect(t, ok && restart)
		testing.expect_value(t, k.state, Keeper_State.Restarting)
		testing.expect(t, keeper_on_driver_restarted(&k))
		testing.expect_value(t, k.state, Keeper_State.Ready)
	}
	testing.expect_value(t, k.generation, u64(1 + MAX_RESTARTS_IN_WINDOW))

	// 6th crash within the same 60s window trips .Failed cleanly.
	restart6, ok6 := keeper_on_driver_stopped(&k, 10_000)
	testing.expect(t, ok6 && !restart6)
	testing.expect_value(t, k.state, Keeper_State.Failed)
	// Backwards time refused.
	_, ok_back := keeper_on_driver_stopped(&k, 5_000)
	testing.expect(t, !ok_back)

	// Proxy frame border check.
	payload: [64]u8
	testing.expect(t, proxy_frame_validate({class_word = u8(Proxy_Device_Class.Wifi_Network), direction = 1, length = 64, sequence = 1}, payload[:]))
	testing.expect(t, !proxy_frame_validate({class_word = 99, direction = 1, length = 64, sequence = 1}, payload[:]))
	testing.expect(t, !proxy_frame_validate({class_word = 1, direction = 3, length = 64, sequence = 1}, payload[:]))
	testing.expect(t, !proxy_frame_validate({class_word = 1, direction = 1, length = 65, sequence = 1}, payload[:]))
}
