// Live desktop workspace switching, edge-snapping, notification queue, and
// viewport magnifier state integrated directly into the compositor service.
package compositor

import "modus:contract/desktop_layout"
import "modus:contract/notifications"
import "modus:contract/screen_reader"

desktop_workspaces: desktop_layout.Workspace_Manager
desktop_work_area: desktop_layout.Work_Area
desktop_notifications: notifications.Notification_Queue
desktop_magnifier: screen_reader.Magnifier_State
desktop_features_ready: bool

desktop_features_init :: proc "contextless" (screen_w, screen_h, bar_h: i32) {
	desktop_work_area = desktop_layout.Work_Area{
		screen_width  = screen_w,
		screen_height = screen_h,
		bar_height    = bar_h,
	}
	_ = desktop_layout.workspace_manager_init(&desktop_workspaces)
	notifications.queue_init(&desktop_notifications, min_interval_ms = 500)
	_ = screen_reader.magnifier_init(&desktop_magnifier, screen_w, screen_h, 16)
	desktop_magnifier.enabled = false
	desktop_features_ready = true
}

desktop_workspace_select :: proc "contextless" (index: u8) -> bool {
	if !desktop_features_ready {
		return false
	}
	_, refusal := desktop_layout.workspace_switch(&desktop_workspaces, index)
	return refusal == .None
}

desktop_magnifier_toggle :: proc "contextless" (tx, ty: i32) {
	if !desktop_features_ready {
		return
	}
	desktop_magnifier.enabled = !desktop_magnifier.enabled
	if desktop_magnifier.enabled {
		screen_reader.magnifier_focus_on(&desktop_magnifier, tx, ty)
	}
}

desktop_magnifier_track :: proc "contextless" (tx, ty: i32) {
	if !desktop_features_ready || !desktop_magnifier.enabled {
		return
	}
	screen_reader.magnifier_focus_on(&desktop_magnifier, tx, ty)
}

desktop_notification_post :: proc "contextless" (source_id: u64, urgency: notifications.Urgency, now_ms: u64, title, body: []u8) -> u64 {
	if !desktop_features_ready {
		return 0
	}
	id, refusal := notifications.queue_post(&desktop_notifications, source_id, urgency, now_ms, 8_000, title, body)
	return refusal == .None ? id : 0
}
