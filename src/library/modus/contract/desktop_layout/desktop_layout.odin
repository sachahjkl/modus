// Pure freestanding desktop layout state machines for system notifications,
// floating window edge snapping, and workspaces
// (src/md/features/desktop_to_browser.md).
//
// Zero dynamic allocations, zero kernel operations, strict closed-enum borders,
// and zero state mutation on any refusal.
package desktop_layout

import "modus:contract/enum_word"

// Geometry rectangle in logical desktop pixels.
Rect :: struct {
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
}

// Logical screen work area excluding the reserved top system bar.
Work_Area :: struct {
	screen_width:  i32,
	screen_height: i32,
	bar_height:    i32,
}

// ============================================================================
// 1. System Notifications (non-focus-stealing, unforgeable reserved corner)
// ============================================================================

MAX_NOTIFICATIONS :: 16
MAX_NOTIFICATIONS_PER_SENDER :: 4
MAX_NOTIFICATION_TITLE_BYTES :: 64
MAX_NOTIFICATION_BODY_BYTES :: 192
NOTIFICATION_MIN_TTL_MS :: u64(1_000)
NOTIFICATION_MAX_TTL_MS :: u64(60_000)
NOTIFICATION_CARD_WIDTH :: i32(340)
NOTIFICATION_CARD_HEIGHT :: i32(72)
NOTIFICATION_CARD_GAP :: i32(8)
NOTIFICATION_CARD_MARGIN :: i32(12)

Notification_Refusal :: enum u8 {
	None                 = 0,
	Nil_State            = 1,
	Invalid_Sender       = 2,
	Empty_Title          = 3,
	Title_Too_Long       = 4,
	Body_Too_Long        = 5,
	Control_Byte_In_Text = 6,
	Invalid_Ttl          = 7,
	Backwards_Time       = 8,
	Sender_Quota_Full    = 9,
	Queue_Full           = 10,
	Not_Found            = 11,
}

Notification_Entry :: struct {
	active:        bool,
	id:            u64,
	sender_id:     u64,
	created_at_ms: u64,
	expires_at_ms: u64,
	title:         [MAX_NOTIFICATION_TITLE_BYTES]u8,
	title_len:     u16,
	body:          [MAX_NOTIFICATION_BODY_BYTES]u8,
	body_len:      u16,
}

Notification_Queue :: struct {
	entries:           [MAX_NOTIFICATIONS]Notification_Entry,
	active_count:      int,
	next_id:           u64,
	has_time:          bool,
	last_time_ms:      u64,
	focused_window_id: u64, // Preserved verbatim across every notification operation.
}

@(private = "file")
text_has_control_byte :: proc "contextless" (text: string) -> bool {
	bytes := transmute([]u8)text
	for b in bytes {
		if b < 0x20 || b == 0x7F {
			return true
		}
	}
	return false
}

notification_queue_init :: proc "contextless" (q: ^Notification_Queue, focused_window_id: u64) {
	if q == nil {
		return
	}
	q^ = {
		next_id           = 1,
		focused_window_id = focused_window_id,
	}
}

// notification_expire removes all notifications whose expires_at_ms <= now_ms.
// Never changes focused_window_id. Refuses backwards timestamps without mutation.
notification_expire :: proc "contextless" (q: ^Notification_Queue, now_ms: u64) -> (expired: int, refusal: Notification_Refusal) {
	if q == nil {
		return 0, .Nil_State
	}
	if q.has_time && now_ms < q.last_time_ms {
		return 0, .Backwards_Time
	}
	q.has_time = true
	q.last_time_ms = now_ms
	for &e in q.entries {
		if e.active && now_ms >= e.expires_at_ms {
			e = {}
			q.active_count -= 1
			expired += 1
		}
	}
	return expired, .None
}

// notification_post appends one system notification without changing focus.
notification_post :: proc "contextless" (
	q: ^Notification_Queue,
	sender_id: u64,
	title: string,
	body: string,
	ttl_ms: u64,
	now_ms: u64,
) -> (id: u64, refusal: Notification_Refusal) {
	if q == nil {
		return 0, .Nil_State
	}
	if sender_id == 0 {
		return 0, .Invalid_Sender
	}
	if len(title) == 0 {
		return 0, .Empty_Title
	}
	if len(title) > MAX_NOTIFICATION_TITLE_BYTES {
		return 0, .Title_Too_Long
	}
	if len(body) > MAX_NOTIFICATION_BODY_BYTES {
		return 0, .Body_Too_Long
	}
	if text_has_control_byte(title) || text_has_control_byte(body) {
		return 0, .Control_Byte_In_Text
	}
	if ttl_ms < NOTIFICATION_MIN_TTL_MS || ttl_ms > NOTIFICATION_MAX_TTL_MS {
		return 0, .Invalid_Ttl
	}
	if q.has_time && now_ms < q.last_time_ms {
		return 0, .Backwards_Time
	}
	if now_ms > max(u64) - ttl_ms {
		return 0, .Invalid_Ttl
	}

	// Expire stale notifications before checking quotas.
	_, _ = notification_expire(q, now_ms)

	sender_count := 0
	free_idx := -1
	for &e, i in q.entries {
		if !e.active {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if e.sender_id == sender_id {
			sender_count += 1
		}
	}
	if sender_count >= MAX_NOTIFICATIONS_PER_SENDER {
		return 0, .Sender_Quota_Full
	}
	if free_idx < 0 {
		return 0, .Queue_Full
	}

	assigned := q.next_id
	if assigned == 0 {
		assigned = 1
	}
	q.next_id = assigned == max(u64) ? 1 : assigned + 1

	entry := &q.entries[free_idx]
	entry^ = {
		active        = true,
		id            = assigned,
		sender_id     = sender_id,
		created_at_ms = now_ms,
		expires_at_ms = now_ms + ttl_ms,
		title_len     = u16(len(title)),
		body_len      = u16(len(body)),
	}
	copy(entry.title[:], transmute([]u8)title)
	copy(entry.body[:], transmute([]u8)body)
	q.active_count += 1
	return assigned, .None
}

// notification_dismiss explicitly removes one notification by id without changing focus.
notification_dismiss :: proc "contextless" (q: ^Notification_Queue, id: u64) -> Notification_Refusal {
	if q == nil {
		return .Nil_State
	}
	if id == 0 {
		return .Not_Found
	}
	for &e in q.entries {
		if e.active && e.id == id {
			e = {}
			q.active_count -= 1
			return .None
		}
	}
	return .Not_Found
}

// notification_corner_rect computes the reserved top-right card rect for slot_rank (0-based).
notification_corner_rect :: proc "contextless" (area: Work_Area, slot_rank: int) -> (rect: Rect, ok: bool) {
	if !work_area_valid(area) || slot_rank < 0 || slot_rank >= MAX_NOTIFICATIONS {
		return {}, false
	}
	avail_w := area.screen_width - 2 * NOTIFICATION_CARD_MARGIN
	if avail_w <= 0 {
		return {}, false
	}
	w := min(NOTIFICATION_CARD_WIDTH, avail_w)
	x := area.screen_width - NOTIFICATION_CARD_MARGIN - w
	y := area.bar_height + NOTIFICATION_CARD_MARGIN + i32(slot_rank) * (NOTIFICATION_CARD_HEIGHT + NOTIFICATION_CARD_GAP)
	if y + NOTIFICATION_CARD_HEIGHT > area.screen_height {
		return {}, false
	}
	return Rect{x = x, y = y, width = w, height = NOTIFICATION_CARD_HEIGHT}, true
}

// ============================================================================
// 2. Floating Window Edge Snapping
// ============================================================================

Snap_Zone :: enum u8 {
	Floating    = 0,
	Left_Half   = 1,
	Right_Half  = 2,
	Top_Half    = 3,
	Bottom_Half = 4,
	Maximized   = 5,
	Minimized   = 6,
}

snap_zone_of_word :: proc "contextless" (word: u64) -> (zone: Snap_Zone, ok: bool) {
	return enum_word.member_of_word(Snap_Zone, word)
}

Window_Snap_State :: struct {
	zone:          Snap_Zone,
	current_rect:  Rect,
	floating_rect: Rect, // Preserved across snap/maximize/minimize transitions.
	has_floating:  bool,
}

work_area_valid :: proc "contextless" (area: Work_Area) -> bool {
	if area.screen_width <= 0 || area.screen_height <= 0 || area.bar_height < 0 {
		return false
	}
	return area.bar_height < area.screen_height
}

rect_valid :: proc "contextless" (r: Rect) -> bool {
	return r.width > 0 && r.height > 0
}

// snap_zone_rect computes the exact target rectangle for zone within area.
// Returns ok = false for .Floating, .Minimized, or invalid work areas.
snap_zone_rect :: proc "contextless" (area: Work_Area, zone: Snap_Zone) -> (rect: Rect, ok: bool) {
	if !work_area_valid(area) {
		return {}, false
	}
	usable_y := area.bar_height
	usable_h := area.screen_height - area.bar_height
	half_w := area.screen_width / 2
	half_h := usable_h / 2
	if half_w <= 0 || half_h <= 0 {
		return {}, false
	}
	switch zone {
	case .Floating, .Minimized:
		return {}, false
	case .Left_Half:
		return Rect{x = 0, y = usable_y, width = half_w, height = usable_h}, true
	case .Right_Half:
		return Rect{x = half_w, y = usable_y, width = area.screen_width - half_w, height = usable_h}, true
	case .Top_Half:
		return Rect{x = 0, y = usable_y, width = area.screen_width, height = half_h}, true
	case .Bottom_Half:
		return Rect{x = 0, y = usable_y + half_h, width = area.screen_width, height = usable_h - half_h}, true
	case .Maximized:
		return Rect{x = 0, y = usable_y, width = area.screen_width, height = usable_h}, true
	}
	return {}, false
}

// window_snap_init initializes a floating window with its initial rectangle.
window_snap_init :: proc "contextless" (state: ^Window_Snap_State, initial: Rect) -> bool {
	if state == nil || !rect_valid(initial) {
		return false
	}
	state^ = {
		zone          = .Floating,
		current_rect  = initial,
		floating_rect = initial,
		has_floating  = true,
	}
	return true
}

// window_snap_apply transitions a window to target_zone, saving floating_rect
// when leaving .Floating and restoring floating_rect identically on unsnap.
// Refuses invalid inputs without mutating state.
window_snap_apply :: proc "contextless" (state: ^Window_Snap_State, area: Work_Area, target_zone: Snap_Zone) -> bool {
	if state == nil || !state.has_floating || !work_area_valid(area) {
		return false
	}
	switch target_zone {
	case .Floating:
		state.zone = .Floating
		state.current_rect = state.floating_rect
		return true
	case .Minimized:
		if state.zone == .Floating {
			state.floating_rect = state.current_rect
		}
		state.zone = .Minimized
		return true
	case .Left_Half, .Right_Half, .Top_Half, .Bottom_Half, .Maximized:
		target_rect, ok := snap_zone_rect(area, target_zone)
		if !ok {
			return false
		}
		if state.zone == .Floating {
			state.floating_rect = state.current_rect
		}
		state.zone = target_zone
		state.current_rect = target_rect
		return true
	}
	return false
}

// ============================================================================
// 3. Workspaces (isolated window groups with per-workspace focus memory)
// ============================================================================

MAX_WORKSPACES :: 9
MAX_WORKSPACE_WINDOWS :: 64

Workspace_Refusal :: enum u8 {
	None                 = 0,
	Nil_State            = 1,
	Invalid_Workspace    = 2,
	Invalid_Window       = 3,
	Window_Already_Open  = 4,
	Window_Not_Found     = 5,
	Window_Table_Full    = 6,
}

Workspace_Window :: struct {
	active:          bool,
	window_id:       u64,
	workspace_index: u8,
}

Workspace_Manager :: struct {
	workspace_count: u8,
	active_index:    u8,
	focused_window:  [MAX_WORKSPACES]u64,
	windows:         [MAX_WORKSPACE_WINDOWS]Workspace_Window,
	window_count:    int,
}

workspace_manager_init :: proc "contextless" (m: ^Workspace_Manager, count: u8 = MAX_WORKSPACES) -> Workspace_Refusal {
	if m == nil {
		return .Nil_State
	}
	if count == 0 || count > MAX_WORKSPACES {
		return .Invalid_Workspace
	}
	m^ = {
		workspace_count = count,
		active_index    = 0,
	}
	return .None
}

@(private = "file")
workspace_fallback_focus :: proc "contextless" (m: ^Workspace_Manager, ws: u8) -> u64 {
	for &w in m.windows {
		if w.active && w.workspace_index == ws {
			return w.window_id
		}
	}
	return 0
}

workspace_add_window :: proc "contextless" (m: ^Workspace_Manager, window_id: u64, ws_index: u8) -> Workspace_Refusal {
	if m == nil {
		return .Nil_State
	}
	if window_id == 0 {
		return .Invalid_Window
	}
	if ws_index >= m.workspace_count {
		return .Invalid_Workspace
	}
	free_idx := -1
	for &w, i in m.windows {
		if !w.active {
			if free_idx < 0 {
				free_idx = i
			}
			continue
		}
		if w.window_id == window_id {
			return .Window_Already_Open
		}
	}
	if free_idx < 0 {
		return .Window_Table_Full
	}
	m.windows[free_idx] = {
		active          = true,
		window_id       = window_id,
		workspace_index = ws_index,
	}
	m.window_count += 1
	m.focused_window[ws_index] = window_id
	return .None
}

workspace_switch :: proc "contextless" (m: ^Workspace_Manager, target_ws: u8) -> (focused: u64, refusal: Workspace_Refusal) {
	if m == nil {
		return 0, .Nil_State
	}
	if target_ws >= m.workspace_count {
		return 0, .Invalid_Workspace
	}
	m.active_index = target_ws
	return m.focused_window[target_ws], .None
}

workspace_move_window :: proc "contextless" (m: ^Workspace_Manager, window_id: u64, target_ws: u8) -> Workspace_Refusal {
	if m == nil {
		return .Nil_State
	}
	if window_id == 0 {
		return .Invalid_Window
	}
	if target_ws >= m.workspace_count {
		return .Invalid_Workspace
	}
	for &w in m.windows {
		if w.active && w.window_id == window_id {
			old_ws := w.workspace_index
			if old_ws == target_ws {
				return .None
			}
			w.workspace_index = target_ws
			if m.focused_window[old_ws] == window_id {
				m.focused_window[old_ws] = workspace_fallback_focus(m, old_ws)
			}
			m.focused_window[target_ws] = window_id
			return .None
		}
	}
	return .Window_Not_Found
}

workspace_remove_window :: proc "contextless" (m: ^Workspace_Manager, window_id: u64) -> Workspace_Refusal {
	if m == nil {
		return .Nil_State
	}
	if window_id == 0 {
		return .Invalid_Window
	}
	for &w in m.windows {
		if w.active && w.window_id == window_id {
			ws := w.workspace_index
			w = {}
			m.window_count -= 1
			if m.focused_window[ws] == window_id {
				m.focused_window[ws] = workspace_fallback_focus(m, ws)
			}
			return .None
		}
	}
	return .Window_Not_Found
}

workspace_window_visible :: proc "contextless" (m: ^Workspace_Manager, window_id: u64) -> bool {
	if m == nil || window_id == 0 {
		return false
	}
	for &w in m.windows {
		if w.active && w.window_id == window_id {
			return w.workspace_index == m.active_index
		}
	}
	return false
}
