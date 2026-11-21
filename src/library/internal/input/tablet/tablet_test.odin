#+build !freestanding
package tablet

import "core:testing"
import "modus:contract/virtio_input"

@(private = "file")
QEMU_RANGE :: virtio_input.Axis_Range{virtio_input.ABSOLUTE_AXIS_DEFAULT_MINIMUM, virtio_input.ABSOLUTE_AXIS_DEFAULT_MAXIMUM}

@(private = "file")
raw_abs :: proc(axis: virtio_input.Abs_Axis, value: i32) -> virtio_input.Raw_Event {
	return {type_word = u16(virtio_input.Event_Type.Abs), code_word = u16(axis), value = value}
}

@(private = "file")
raw_button :: proc(button: virtio_input.Button_Code, pressed: i32) -> virtio_input.Raw_Event {
	return {type_word = u16(virtio_input.Event_Type.Key), code_word = u16(button), value = pressed}
}

@(private = "file")
raw_wheel :: proc(notches: i32) -> virtio_input.Raw_Event {
	return {type_word = u16(virtio_input.Event_Type.Rel), code_word = u16(virtio_input.Rel_Axis.Wheel), value = notches}
}

@(private = "file")
raw_syn :: proc() -> virtio_input.Raw_Event {
	return {type_word = u16(virtio_input.Event_Type.Syn), code_word = u16(virtio_input.Syn_Code.Report), value = 0}
}

// Initialization refuses invalid axis ranges (min >= max) and zero screen
// width or height, leaving a zero uninitialized state.
@(test)
tablet_state_init_refuses_bad_ranges_and_zero_screen :: proc(t: ^testing.T) {
	bad_cases := [?]struct {
		x_range: virtio_input.Axis_Range,
		y_range: virtio_input.Axis_Range,
		width:   u32,
		height:  u32,
		problem: virtio_input.Scale_Problem,
	}{
		{{0, 0}, QEMU_RANGE, 1280, 800, .Bad_Axis_Range},
		{{10, 5}, QEMU_RANGE, 1280, 800, .Bad_Axis_Range},
		{QEMU_RANGE, {32767, 32767}, 1280, 800, .Bad_Axis_Range},
		{QEMU_RANGE, {100, -100}, 1280, 800, .Bad_Axis_Range},
		{QEMU_RANGE, QEMU_RANGE, 0, 800, .Zero_Screen_Extent},
		{QEMU_RANGE, QEMU_RANGE, 1280, 0, .Zero_Screen_Extent},
		{QEMU_RANGE, QEMU_RANGE, 0, 0, .Zero_Screen_Extent},
	}
	for c in bad_cases {
		state, problem := tablet_state_init(c.x_range, c.y_range, c.width, c.height)
		testing.expectf(t, problem == c.problem && !state.initialized, "case %v gave %v", c, problem)
	}
	// Feeding an uninitialized state refuses safely.
	uninit: Tablet_State
	ev, ready, decode_problem := tablet_state_feed(&uninit, raw_syn())
	testing.expect(t, !ready && decode_problem != .None && ev == (Tablet_Event{}))
}

// EV_SYN batching never emits a partial X-only move before SYN_REPORT,
// commits X, Y, buttons, and wheel atomically on SYN_REPORT, and ignores
// empty SYN_REPORT frames.
@(test)
tablet_state_batches_until_syn_report :: proc(t: ^testing.T) {
	state, init_problem := tablet_state_init(QEMU_RANGE, QEMU_RANGE, 1280, 800)
	testing.expect_value(t, init_problem, virtio_input.Scale_Problem.None)

	// Empty SYN_REPORT emits nothing.
	_, ready, problem := tablet_state_feed(&state, raw_syn())
	testing.expect(t, !ready && problem == .None)

	// Partial ABS_X alone emits nothing.
	_, ready, problem = tablet_state_feed(&state, raw_abs(.X, 16384))
	testing.expect(t, !ready && problem == .None)
	testing.expect_value(t, state.committed_x, u32(0))

	// ABS_Y + button press + wheel before SYN_REPORT still emits nothing.
	_, ready, problem = tablet_state_feed(&state, raw_abs(.Y, 32767))
	testing.expect(t, !ready && problem == .None)
	_, ready, problem = tablet_state_feed(&state, raw_button(.Left, 1))
	testing.expect(t, !ready && problem == .None)
	_, ready, problem = tablet_state_feed(&state, raw_wheel(-2))
	testing.expect(t, !ready && problem == .None)

	// SYN_REPORT commits everything atomically as one event.
	ev, syn_ready, syn_problem := tablet_state_feed(&state, raw_syn())
	testing.expect(t, syn_ready && syn_problem == .None)
	testing.expect_value(t, ev, Tablet_Event{x = 640, y = 799, buttons = BUTTON_LEFT, wheel = -2})

	// A second SYN_REPORT with no new updates emits nothing.
	_, ready, problem = tablet_state_feed(&state, raw_syn())
	testing.expect(t, !ready && problem == .None)

	// An X-only update in the next frame preserves the previous Y coordinate
	// and zeroes the wheel.
	_, ready, problem = tablet_state_feed(&state, raw_abs(.X, 0))
	testing.expect(t, !ready && problem == .None)
	_, ready, problem = tablet_state_feed(&state, raw_button(.Left, 0))
	testing.expect(t, !ready && problem == .None)
	ev, syn_ready, syn_problem = tablet_state_feed(&state, raw_syn())
	testing.expect(t, syn_ready && syn_problem == .None)
	testing.expect_value(t, ev, Tablet_Event{x = 0, y = 799, buttons = 0, wheel = 0})
}

// Unknown event types, unknown codes, and invalid button values are refused
// without corrupting pending coordinates or buttons, and out-of-range
// coordinates clamp cleanly to [0..width-1, 0..height-1].
@(test)
tablet_state_refuses_unknown_events_and_clamps_out_of_range :: proc(t: ^testing.T) {
	state, init_problem := tablet_state_init(QEMU_RANGE, QEMU_RANGE, 1920, 1080)
	testing.expect_value(t, init_problem, virtio_input.Scale_Problem.None)

	// Queue a valid out-of-range X (below min) and Y (above max).
	_, ready, problem := tablet_state_feed(&state, raw_abs(.X, -500))
	testing.expect(t, !ready && problem == .None)
	_, ready, problem = tablet_state_feed(&state, raw_abs(.Y, 99999))
	testing.expect(t, !ready && problem == .None)

	// Inject hostile unknown events mid-frame.
	before_pending_x, before_pending_y := state.pending_x, state.pending_y
	hostile := [?]struct {
		raw:     virtio_input.Raw_Event,
		problem: virtio_input.Decode_Problem,
	}{
		{{type_word = 0x99, code_word = 0, value = 1}, .Unknown_Event_Type},
		{{type_word = u16(virtio_input.Event_Type.Abs), code_word = 99, value = 123}, .Unknown_Event_Code},
		{{type_word = u16(virtio_input.Event_Type.Key), code_word = 0x1E, value = 1}, .Unknown_Event_Code},
		{{type_word = u16(virtio_input.Event_Type.Key), code_word = u16(virtio_input.Button_Code.Right), value = 2}, .Bad_Button_Value},
		{{type_word = u16(virtio_input.Event_Type.Syn), code_word = 1, value = 0}, .Unknown_Event_Code},
	}
	for h in hostile {
		ev, ev_ready, ev_problem := tablet_state_feed(&state, h.raw)
		testing.expect(t, !ev_ready && ev_problem == h.problem && ev == (Tablet_Event{}))
	}
	testing.expect_value(t, state.unknown_events_ignored, u64(len(hostile)))
	testing.expect(t, state.pending_x == before_pending_x && state.pending_y == before_pending_y)

	// SYN_REPORT still commits the valid pending updates clamped to screen edges.
	ev, syn_ready, syn_problem := tablet_state_feed(&state, raw_syn())
	testing.expect(t, syn_ready && syn_problem == .None)
	testing.expect_value(t, ev, Tablet_Event{x = 0, y = 1079, buttons = 0, wheel = 0})
}

// The tablet backlog coalesces moves with equal buttons and preserves button
// transitions up to its stated capacity.
@(test)
tablet_backlog_coalesces_moves_and_keeps_button_transitions :: proc(t: ^testing.T) {
	backlog: Tablet_Backlog
	_, has := tablet_backlog_first(&backlog)
	testing.expect(t, !has)

	testing.expect(t, tablet_backlog_add(&backlog, {x = 10, y = 20, buttons = 0, wheel = 1}))
	testing.expect(t, tablet_backlog_add(&backlog, {x = 50, y = 60, buttons = 0, wheel = 2}))
	testing.expect_value(t, backlog.count, 1)
	testing.expect_value(t, backlog.merged, u64(1))
	first, ok := tablet_backlog_first(&backlog)
	testing.expect(t, ok && first == Tablet_Event{x = 50, y = 60, buttons = 0, wheel = 3})

	// Fill remaining slots with alternating button transitions.
	for i in 1 ..< TABLET_BACKLOG_CAPACITY {
		buttons := u32(i & 1)
		testing.expect(t, tablet_backlog_add(&backlog, {x = u32(i), y = u32(i), buttons = buttons}))
	}
	testing.expect_value(t, backlog.count, TABLET_BACKLOG_CAPACITY)
	// Next distinct button transition is refused; same-button move still coalesces.
	last_buttons := backlog.events[TABLET_BACKLOG_CAPACITY - 1].buttons
	testing.expect(t, !tablet_backlog_add(&backlog, {x = 1, y = 2, buttons = last_buttons ~ BUTTON_LEFT}))
	testing.expect(t, tablet_backlog_add(&backlog, {x = 99, y = 88, buttons = last_buttons}))
	testing.expect_value(t, backlog.events[TABLET_BACKLOG_CAPACITY - 1].x, u32(99))

	tablet_backlog_remove_first(&backlog)
	testing.expect_value(t, backlog.count, TABLET_BACKLOG_CAPACITY - 1)
}
