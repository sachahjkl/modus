// The virtio tablet event batcher: accumulates EV_ABS, EV_KEY, and EV_REL
// records from a virtio-tablet-pci event queue and commits one atomic
// absolute pointer event on EV_SYN/SYN_REPORT, preventing X-then-Y
// stair-stepping.
//
// Pure internal package of the input service, with host tests and no
// kernel operation calls.
package tablet

import "modus:contract/virtio_input"

// Button bit masks produced in Tablet_Event.buttons.
BUTTON_LEFT :: u32(1 << 0)
BUTTON_RIGHT :: u32(1 << 1)
BUTTON_MIDDLE :: u32(1 << 2)

// Maximum wheel notches accumulated within one EV_SYN frame.
WHEEL_NOTCHES_LIMIT :: i32(1 << 16)

// Maximum pending committed tablet events held while the input ring is full.
TABLET_BACKLOG_CAPACITY :: 8

// One committed atomic absolute pointer event emitted on SYN_REPORT.
Tablet_Event :: struct {
	x:       u32,
	y:       u32,
	buttons: u32,
	wheel:   i32,
}

// Per-device state that batches raw virtio input events until SYN_REPORT.
Tablet_State :: struct {
	x_range:                virtio_input.Axis_Range,
	y_range:                virtio_input.Axis_Range,
	screen_width:           u32,
	screen_height:          u32,
	initialized:            bool,
	pending_x:              i32,
	pending_y:              i32,
	has_pending_x:          bool,
	has_pending_y:          bool,
	pending_buttons:        u32,
	pending_wheel:          i32,
	has_pending_changes:    bool,
	committed_x:            u32,
	committed_y:            u32,
	committed_buttons:      u32,
	unknown_events_ignored: u64,
}

// Bounded backlog of committed tablet events waiting for room in the input
// ring. Consecutive moves with identical buttons coalesce to the newest
// coordinates while accumulating wheel notches, preserving every button
// transition in order.
Tablet_Backlog :: struct {
	events: [TABLET_BACKLOG_CAPACITY]Tablet_Event,
	count:  int,
	merged: u64,
}

// tablet_state_init validates axis ranges and screen dimensions and returns
// a ready Tablet_State. Invalid ranges (min >= max) or zero screen
// dimensions are refused with the zero Tablet_State.
tablet_state_init :: proc "contextless" (x_range, y_range: virtio_input.Axis_Range, screen_width, screen_height: u32) -> (state: Tablet_State, problem: virtio_input.Scale_Problem) {
	if !virtio_input.axis_range_valid(x_range) || !virtio_input.axis_range_valid(y_range) {
		return {}, .Bad_Axis_Range
	}
	if screen_width == 0 || screen_height == 0 {
		return {}, .Zero_Screen_Extent
	}
	return {
		x_range = x_range,
		y_range = y_range,
		screen_width = screen_width,
		screen_height = screen_height,
		initialized = true,
	}, .None
}

// tablet_state_feed consumes one raw wire event from the virtio event queue.
// Unknown event types, unknown codes, and invalid button values are refused
// without mutating pending or committed state, and unknown_events_ignored is
// incremented. Partial ABS_X, ABS_Y, button, and wheel updates are buffered
// and only committed atomically on SYN_REPORT.
tablet_state_feed :: proc "contextless" (state: ^Tablet_State, raw: virtio_input.Raw_Event) -> (event: Tablet_Event, ready: bool, problem: virtio_input.Decode_Problem) {
	if !state.initialized {
		return {}, false, .Unknown_Event_Type
	}
	decoded, decode_problem := virtio_input.event_decode(raw)
	if decode_problem != .None {
		state.unknown_events_ignored += 1
		return {}, false, decode_problem
	}
	switch decoded.event_type {
	case .Abs:
		switch decoded.abs_axis {
		case .X:
			state.pending_x = decoded.value
			state.has_pending_x = true
			state.has_pending_changes = true
		case .Y:
			state.pending_y = decoded.value
			state.has_pending_y = true
			state.has_pending_changes = true
		}
		return {}, false, .None
	case .Key:
		bit: u32
		switch decoded.button_code {
		case .Left:
			bit = BUTTON_LEFT
		case .Right:
			bit = BUTTON_RIGHT
		case .Middle:
			bit = BUTTON_MIDDLE
		}
		if decoded.value == 1 {
			state.pending_buttons |= bit
		} else {
			state.pending_buttons &~= bit
		}
		state.has_pending_changes = true
		return {}, false, .None
	case .Rel:
		switch decoded.rel_axis {
		case .Wheel:
			sum := clamp(i64(state.pending_wheel) + i64(decoded.value), -i64(WHEEL_NOTCHES_LIMIT), i64(WHEEL_NOTCHES_LIMIT))
			state.pending_wheel = i32(sum)
			state.has_pending_changes = true
		}
		return {}, false, .None
	case .Syn:
		switch decoded.syn_code {
		case .Report:
			if !state.has_pending_changes {
				return {}, false, .None
			}
			if state.has_pending_x {
				scaled_x, x_problem := virtio_input.scale_axis_coordinate(state.pending_x, state.x_range, state.screen_width)
				if x_problem == .None {
					state.committed_x = scaled_x
				}
				state.has_pending_x = false
			}
			if state.has_pending_y {
				scaled_y, y_problem := virtio_input.scale_axis_coordinate(state.pending_y, state.y_range, state.screen_height)
				if y_problem == .None {
					state.committed_y = scaled_y
				}
				state.has_pending_y = false
			}
			state.committed_buttons = state.pending_buttons
			wheel := state.pending_wheel
			state.pending_wheel = 0
			state.has_pending_changes = false
			return Tablet_Event{
				x = state.committed_x,
				y = state.committed_y,
				buttons = state.committed_buttons,
				wheel = wheel,
			}, true, .None
		}
	}
	return {}, false, .None
}

// tablet_backlog_add appends a committed event to the backlog, coalescing
// moves whose button mask matches the last queued event. Returns false only
// when the backlog is full and a button transition cannot be merged.
tablet_backlog_add :: proc "contextless" (backlog: ^Tablet_Backlog, event: Tablet_Event) -> bool {
	if backlog.count > 0 && backlog.events[backlog.count - 1].buttons == event.buttons {
		last := &backlog.events[backlog.count - 1]
		last.x = event.x
		last.y = event.y
		sum := clamp(i64(last.wheel) + i64(event.wheel), -i64(WHEEL_NOTCHES_LIMIT), i64(WHEEL_NOTCHES_LIMIT))
		last.wheel = i32(sum)
		backlog.merged += 1
		return true
	}
	if backlog.count >= TABLET_BACKLOG_CAPACITY {
		return false
	}
	backlog.events[backlog.count] = event
	backlog.count += 1
	return true
}

// tablet_backlog_first returns the oldest queued tablet event.
tablet_backlog_first :: proc "contextless" (backlog: ^Tablet_Backlog) -> (event: Tablet_Event, ok: bool) {
	if backlog.count == 0 {
		return {}, false
	}
	return backlog.events[0], true
}

// tablet_backlog_drain sends the queued events, the oldest first, while the
// sender takes them, and removes each event only once it is sent: an event
// that the sender refuses, a change of a button among them, stays first in
// the backlog for the next drain.
tablet_backlog_drain :: proc "contextless" (backlog: ^Tablet_Backlog, sender: rawptr, send: proc "contextless" (sender: rawptr, event: Tablet_Event) -> bool) -> (sent: int) {
	for {
		waiting := tablet_backlog_first(backlog) or_break
		if !send(sender, waiting) {
			break
		}
		tablet_backlog_remove_first(backlog)
		sent += 1
	}
	return sent
}

// tablet_backlog_remove_first drops the oldest queued tablet event.
tablet_backlog_remove_first :: proc "contextless" (backlog: ^Tablet_Backlog) {
	if backlog.count == 0 {
		return
	}
	for index in 0 ..< backlog.count - 1 {
		backlog.events[index] = backlog.events[index + 1]
	}
	backlog.events[backlog.count - 1] = {}
	backlog.count -= 1
}
