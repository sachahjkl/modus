// Pure state and layout model for the remote display viewer list popover
// opened from the viewer mark in the bar (src/md/features/remote_display.md,
// "The authority"). Holds no kernel handle and allocates no memory so host
// tests exercise every state transition, hit-test edge, and refusal.
package bar

// Maximum viewers shown in the bar popover; asserted equal to
// display.CAPTURE_VIEWER_CAPACITY in the compositor.
VIEWER_CAPACITY :: 8

// Geometry of the compact viewer list card under the bar mark.
VIEWER_POPOVER_WIDTH :: 272
VIEWER_DISCONNECT_LABEL :: "disconnect"
VIEWER_DISCONNECT_WIDTH :: 84
VIEWER_DISCONNECT_HEIGHT :: 20
VIEWER_DISCONNECT_Y_OFFSET :: (LINE_HEIGHT - VIEWER_DISCONNECT_HEIGHT) / 2
VIEWER_LABEL_CAPACITY :: 24

// One connected remote display viewer listed in the bar popover.
Viewer_Entry :: struct {
	key_head:  u64, // First 8 bytes of the viewer's Ed25519 public key (Capture_Viewers).
	has_input: bool, // True when the viewer holds the Input grant.
}

// State of the viewer list popover owned by the compositor.
Viewer_Popover :: struct {
	open:          bool,
	hovered_index: int, // Index in 0..<count whose disconnect button is hovered, or -1.
	count:         int,
	viewers:       [VIEWER_CAPACITY]Viewer_Entry,
}

// Closed set of outcomes from a user action on the viewer mark or popover.
Viewer_Popover_Action_Kind :: enum u8 {
	None       = 0, // No state change or command emitted.
	Opened     = 1, // Mark click opened the popover.
	Closed     = 2, // Mark click, Escape, outside click, or loss of viewers closed the popover.
	Disconnect = 3, // Principal clicked disconnect for viewer_index / key_head.
}

// Outcome returned by popover interactions.
Viewer_Popover_Action :: struct {
	kind:         Viewer_Popover_Action_Kind,
	viewer_index: int,
	key_head:     u64,
}

// viewer_popover_init resets a popover to closed with no viewers and no hover.
viewer_popover_init :: proc "contextless" (popover: ^Viewer_Popover) {
	popover^ = {hovered_index = -1}
}

// viewer_popover_has_viewers reports whether at least one viewer is listed and
// the viewer mark can open the popover.
viewer_popover_has_viewers :: proc "contextless" (popover: ^Viewer_Popover) -> bool {
	return popover.count > 0
}

// viewer_popover_sync updates the viewer list from Capture_Viewers or capture
// face open/close events. Closes the popover automatically when capture closes
// or 0 viewers remain. Returns true when any visible state changed.
viewer_popover_sync :: proc "contextless" (popover: ^Viewer_Popover, capture_open: bool, count: int, keys: []u64, input_mask: u64) -> (changed: bool) {
	old_open := popover.open
	old_count := popover.count
	old_hovered := popover.hovered_index
	old_viewers := popover.viewers

	if !capture_open || count <= 0 || len(keys) == 0 {
		popover.open = false
		popover.hovered_index = -1
		popover.count = 0
		popover.viewers = {}
		return old_open != popover.open || old_count != popover.count || old_hovered != popover.hovered_index
	}

	next_count := clamp(count, 0, min(VIEWER_CAPACITY, len(keys)))
	popover.count = next_count
	popover.viewers = {}
	for index in 0 ..< next_count {
		popover.viewers[index] = {
			key_head  = keys[index],
			has_input = (input_mask >> u64(index)) & 1 != 0,
		}
	}
	if popover.hovered_index < 0 || popover.hovered_index >= next_count {
		popover.hovered_index = -1
	}
	if old_open != popover.open || old_count != popover.count || old_hovered != popover.hovered_index {
		return true
	}
	for index in 0 ..< next_count {
		if old_viewers[index] != popover.viewers[index] {
			return true
		}
	}
	return false
}

// viewer_popover_rect gives the rectangle of the viewer list card directly
// beneath the bar mark, right-aligned to the mark and clamped inside the
// screen width.
viewer_popover_rect :: proc "contextless" (mark_x, mark_width, screen_width, count: int) -> (x, y, width, height: int) {
	width = VIEWER_POPOVER_WIDTH
	rows := clamp(count, 1, VIEWER_CAPACITY)
	height = TITLE + rows * LINE_HEIGHT + 2 * BORDER
	y = HEIGHT
	max_x := max(PADDING, screen_width - width - PADDING)
	desired_x := mark_x + mark_width - width
	x = clamp(desired_x, PADDING, max_x)
	return
}

// viewer_popover_row_rect gives the rectangle of viewer row index inside the
// popover card. Returns ok = false for an out-of-range index or empty count.
viewer_popover_row_rect :: proc "contextless" (mark_x, mark_width, screen_width, count, index: int) -> (x, y, width, height: int, ok: bool) {
	clamped := clamp(count, 0, VIEWER_CAPACITY)
	if index < 0 || index >= clamped {
		return 0, 0, 0, 0, false
	}
	left, top, card_width, _ := viewer_popover_rect(mark_x, mark_width, screen_width, clamped)
	return left + BORDER, top + BORDER + TITLE + index * LINE_HEIGHT, card_width - 2 * BORDER, LINE_HEIGHT, true
}

// viewer_popover_disconnect_rect gives the explicit disconnect button rectangle
// inside viewer row index. Returns ok = false for an out-of-range index.
viewer_popover_disconnect_rect :: proc "contextless" (mark_x, mark_width, screen_width, count, index: int) -> (x, y, width, height: int, ok: bool) {
	row_x, row_y, row_width, _, row_ok := viewer_popover_row_rect(mark_x, mark_width, screen_width, count, index)
	if !row_ok {
		return 0, 0, 0, 0, false
	}
	btn_x := row_x + row_width - PADDING - VIEWER_DISCONNECT_WIDTH
	return btn_x, row_y + VIEWER_DISCONNECT_Y_OFFSET, VIEWER_DISCONNECT_WIDTH, VIEWER_DISCONNECT_HEIGHT, true
}

// viewer_popover_point_inside reports whether (point_x, point_y) lies within
// the popover card for count viewers.
viewer_popover_point_inside :: proc "contextless" (mark_x, mark_width, screen_width, count, point_x, point_y: int) -> bool {
	if count <= 0 {
		return false
	}
	x, y, width, height := viewer_popover_rect(mark_x, mark_width, screen_width, count)
	return point_x >= x && point_x < x + width && point_y >= y && point_y < y + height
}

// viewer_popover_disconnect_at returns the viewer index whose disconnect button
// contains (point_x, point_y), or -1 when none does.
viewer_popover_disconnect_at :: proc "contextless" (mark_x, mark_width, screen_width, count, point_x, point_y: int) -> int {
	clamped := clamp(count, 0, VIEWER_CAPACITY)
	for index in 0 ..< clamped {
		x, y, width, height, ok := viewer_popover_disconnect_rect(mark_x, mark_width, screen_width, clamped, index)
		if ok && point_x >= x && point_x < x + width && point_y >= y && point_y < y + height {
			return index
		}
	}
	return -1
}

// viewer_popover_mark_click handles a press on the bar viewer mark.
// With 0 viewers, does nothing and stays closed. With viewers present, toggles
// the popover open or closed.
viewer_popover_mark_click :: proc "contextless" (popover: ^Viewer_Popover) -> Viewer_Popover_Action {
	if popover.count <= 0 {
		popover.open = false
		popover.hovered_index = -1
		return {}
	}
	if popover.open {
		popover.open = false
		popover.hovered_index = -1
		return {kind = .Closed, viewer_index = -1}
	}
	popover.open = true
	popover.hovered_index = -1
	return {kind = .Opened, viewer_index = -1}
}

// viewer_popover_escape closes an open popover on Escape. No-op when closed.
viewer_popover_escape :: proc "contextless" (popover: ^Viewer_Popover) -> Viewer_Popover_Action {
	if !popover.open {
		return {}
	}
	popover.open = false
	popover.hovered_index = -1
	return {kind = .Closed, viewer_index = -1}
}

// viewer_popover_pointer_move updates hovered_index while the popover is open.
// Returns true when hover state changed.
viewer_popover_pointer_move :: proc "contextless" (popover: ^Viewer_Popover, mark_x, mark_width, screen_width, point_x, point_y: int) -> (changed: bool) {
	if !popover.open || popover.count <= 0 {
		if popover.hovered_index != -1 {
			popover.hovered_index = -1
			return true
		}
		return false
	}
	next := viewer_popover_disconnect_at(mark_x, mark_width, screen_width, popover.count, point_x, point_y)
	if next == popover.hovered_index {
		return false
	}
	popover.hovered_index = next
	return true
}

// viewer_popover_disconnect_index validates index and emits a Disconnect action
// for the chosen viewer, closing the popover. Refuses closed popovers,
// negative or out-of-range indexes, and zero key heads without mutating state.
viewer_popover_disconnect_index :: proc "contextless" (popover: ^Viewer_Popover, index: int) -> Viewer_Popover_Action {
	if !popover.open || index < 0 || index >= popover.count || index >= VIEWER_CAPACITY {
		return {}
	}
	key_head := popover.viewers[index].key_head
	if key_head == 0 {
		return {}
	}
	popover.open = false
	popover.hovered_index = -1
	return {
		kind         = .Disconnect,
		viewer_index = index,
		key_head     = key_head,
	}
}

// viewer_popover_click handles a left-button press while the popover is open:
// - on a viewer's disconnect button -> emits Disconnect and closes;
// - outside the popover card -> closes;
// - inside the popover card away from disconnect buttons -> keeps open (.None).
viewer_popover_click :: proc "contextless" (popover: ^Viewer_Popover, mark_x, mark_width, screen_width, point_x, point_y: int) -> Viewer_Popover_Action {
	if !popover.open || popover.count <= 0 {
		return {}
	}
	if idx := viewer_popover_disconnect_at(mark_x, mark_width, screen_width, popover.count, point_x, point_y); idx >= 0 {
		return viewer_popover_disconnect_index(popover, idx)
	}
	if !viewer_popover_point_inside(mark_x, mark_width, screen_width, popover.count, point_x, point_y) {
		popover.open = false
		popover.hovered_index = -1
		return {kind = .Closed, viewer_index = -1}
	}
	return {}
}

// viewer_key_label formats a viewer's 8-hex-digit key prefix and grant role
// (" (input)" or " (view)") into out without dynamic allocation.
viewer_key_label :: proc "contextless" (key_head: u64, has_input: bool, out: []u8) -> string {
	hex := "0123456789abcdef"
	suffix := has_input ? " (input)" : " (view)"
	needed := 8 + len(suffix)
	if len(out) < needed {
		return ""
	}
	bytes := transmute([8]u8)key_head
	for i in 0 ..< 4 {
		out[i * 2] = hex[bytes[i] >> 4]
		out[i * 2 + 1] = hex[bytes[i] & 0x0F]
	}
	copy(out[8:], suffix)
	return string(out[:needed])
}
