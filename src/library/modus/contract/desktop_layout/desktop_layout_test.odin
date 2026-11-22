#+build !freestanding
package desktop_layout

import "core:testing"

@(test)
notifications_never_steal_focus_and_enforce_quotas :: proc(t: ^testing.T) {
	q: Notification_Queue
	notification_queue_init(&q, 42)

	// Refusal edges: nil, sender 0, empty title, control byte, bad TTL, backwards time.
	_, r := notification_post(nil, 1, "hi", "body", 5_000, 100)
	testing.expect_value(t, r, Notification_Refusal.Nil_State)
	_, r = notification_post(&q, 0, "hi", "body", 5_000, 100)
	testing.expect_value(t, r, Notification_Refusal.Invalid_Sender)
	_, r = notification_post(&q, 1, "", "body", 5_000, 100)
	testing.expect_value(t, r, Notification_Refusal.Empty_Title)
	_, r = notification_post(&q, 1, "bad\ntitle", "body", 5_000, 100)
	testing.expect_value(t, r, Notification_Refusal.Control_Byte_In_Text)
	_, r = notification_post(&q, 1, "ok", "body", NOTIFICATION_MIN_TTL_MS - 1, 100)
	testing.expect_value(t, r, Notification_Refusal.Invalid_Ttl)
	_, r = notification_post(&q, 1, "ok", "body", NOTIFICATION_MAX_TTL_MS + 1, 100)
	testing.expect_value(t, r, Notification_Refusal.Invalid_Ttl)
	testing.expect_value(t, q.focused_window_id, u64(42))

	// Post up to per-sender quota (4), 5th refused; focus remains 42.
	ids: [MAX_NOTIFICATIONS_PER_SENDER]u64
	for i in 0 ..< MAX_NOTIFICATIONS_PER_SENDER {
		id, post_r := notification_post(&q, 7, "build", "done", 5_000, 1_000)
		testing.expect_value(t, post_r, Notification_Refusal.None)
		testing.expect(t, id != 0)
		ids[i] = id
	}
	_, r = notification_post(&q, 7, "build", "spam", 5_000, 1_000)
	testing.expect_value(t, r, Notification_Refusal.Sender_Quota_Full)
	testing.expect_value(t, q.focused_window_id, u64(42))

	// Backwards time refused without mutating queue.
	_, r = notification_expire(&q, 999)
	testing.expect_value(t, r, Notification_Refusal.Backwards_Time)
	testing.expect_value(t, q.active_count, MAX_NOTIFICATIONS_PER_SENDER)

	// Explicit dismiss frees a slot without changing focus.
	testing.expect_value(t, notification_dismiss(&q, ids[0]), Notification_Refusal.None)
	testing.expect_value(t, notification_dismiss(&q, ids[0]), Notification_Refusal.Not_Found)
	testing.expect_value(t, q.active_count, MAX_NOTIFICATIONS_PER_SENDER - 1)
	testing.expect_value(t, q.focused_window_id, u64(42))

	// Expiry at exact expires_at_ms clears remaining notifications.
	expired, exp_r := notification_expire(&q, 6_000)
	testing.expect_value(t, exp_r, Notification_Refusal.None)
	testing.expect_value(t, expired, MAX_NOTIFICATIONS_PER_SENDER - 1)
	testing.expect_value(t, q.active_count, 0)
	testing.expect_value(t, q.focused_window_id, u64(42))

	// Corner placement stays below top bar and inside screen bounds.
	area := Work_Area{screen_width = 1920, screen_height = 1080, bar_height = 32}
	card0, ok0 := notification_corner_rect(area, 0)
	testing.expect(t, ok0)
	testing.expect(t, card0.y == 44 && card0.x + card0.width == 1920 - NOTIFICATION_CARD_MARGIN)
	_, bad_ok := notification_corner_rect(area, -1)
	testing.expect(t, !bad_ok)
}

@(test)
window_snapping_saves_and_restores_floating_geometry :: proc(t: ^testing.T) {
	_, bad_zone := snap_zone_of_word(99)
	testing.expect(t, !bad_zone)
	z, ok_zone := snap_zone_of_word(u64(Snap_Zone.Left_Half))
	testing.expect(t, ok_zone && z == .Left_Half)

	area := Work_Area{screen_width = 1920, screen_height = 1080, bar_height = 32}
	initial := Rect{x = 120, y = 80, width = 800, height = 600}
	s: Window_Snap_State
	testing.expect(t, !window_snap_init(&s, Rect{0, 0, 0, 100}))
	testing.expect(t, window_snap_init(&s, initial))

	// Left half, right half, top half, bottom half, maximize, minimize, then restore.
	testing.expect(t, window_snap_apply(&s, area, .Left_Half))
	testing.expect_value(t, s.current_rect, Rect{0, 32, 960, 1048})
	testing.expect(t, window_snap_apply(&s, area, .Right_Half))
	testing.expect_value(t, s.current_rect, Rect{960, 32, 960, 1048})
	testing.expect(t, window_snap_apply(&s, area, .Top_Half))
	testing.expect_value(t, s.current_rect, Rect{0, 32, 1920, 524})
	testing.expect(t, window_snap_apply(&s, area, .Bottom_Half))
	testing.expect_value(t, s.current_rect, Rect{0, 556, 1920, 524})
	testing.expect(t, window_snap_apply(&s, area, .Maximized))
	testing.expect_value(t, s.current_rect, Rect{0, 32, 1920, 1048})
	testing.expect(t, window_snap_apply(&s, area, .Minimized))
	testing.expect_value(t, s.zone, Snap_Zone.Minimized)
	testing.expect(t, window_snap_apply(&s, area, .Floating))
	testing.expect_value(t, s.current_rect, initial)

	// Invalid work area refused without mutation.
	testing.expect(t, !window_snap_apply(&s, Work_Area{0, 1080, 32}, .Maximized))
	testing.expect_value(t, s.zone, Snap_Zone.Floating)
}

@(test)
workspaces_isolate_windows_and_remember_focus :: proc(t: ^testing.T) {
	m: Workspace_Manager
	testing.expect_value(t, workspace_manager_init(&m, 0), Workspace_Refusal.Invalid_Workspace)
	testing.expect_value(t, workspace_manager_init(&m, MAX_WORKSPACES + 1), Workspace_Refusal.Invalid_Workspace)
	testing.expect_value(t, workspace_manager_init(&m, 4), Workspace_Refusal.None)

	testing.expect_value(t, workspace_add_window(&m, 0, 0), Workspace_Refusal.Invalid_Window)
	testing.expect_value(t, workspace_add_window(&m, 10, 4), Workspace_Refusal.Invalid_Workspace)
	testing.expect_value(t, workspace_add_window(&m, 10, 0), Workspace_Refusal.None)
	testing.expect_value(t, workspace_add_window(&m, 10, 1), Workspace_Refusal.Window_Already_Open)
	testing.expect_value(t, workspace_add_window(&m, 20, 1), Workspace_Refusal.None)

	testing.expect(t, workspace_window_visible(&m, 10))
	testing.expect(t, !workspace_window_visible(&m, 20))

	// Switching workspace restores remembered focus and visibility.
	f1, r1 := workspace_switch(&m, 1)
	testing.expect_value(t, r1, Workspace_Refusal.None)
	testing.expect_value(t, f1, u64(20))
	testing.expect(t, workspace_window_visible(&m, 20))
	testing.expect(t, !workspace_window_visible(&m, 10))

	// Move window 20 from workspace 1 -> 2 clears workspace 1's focus cleanly.
	testing.expect_value(t, workspace_move_window(&m, 20, 2), Workspace_Refusal.None)
	testing.expect_value(t, m.focused_window[1], u64(0))
	testing.expect_value(t, m.focused_window[2], u64(20))

	// Removing window leaves zero dangling focus.
	testing.expect_value(t, workspace_remove_window(&m, 20), Workspace_Refusal.None)
	testing.expect_value(t, m.focused_window[2], u64(0))
	testing.expect_value(t, workspace_remove_window(&m, 20), Workspace_Refusal.Window_Not_Found)
}
