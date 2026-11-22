// Pure freestanding desktop shell primitives: positionable taskbar
// (Top/Bottom/Left/Right), window decoration mode (Server vs Client CSD),
// grouped taskbar entries for multi-window modules, and system tray icons
// (src/md/features/desktop_to_browser.md, "A. The desktop foundations").
package desktop_shell

import "modus:contract/enum_word"

MAX_TASKBAR_GROUPS :: 24
MAX_TRAY_ICONS :: 8
BAR_THICKNESS_HORIZONTAL :: i32(32)
BAR_THICKNESS_VERTICAL :: i32(48)

Bar_Position :: enum u8 {
	Top    = 1,
	Bottom = 2,
	Left   = 3,
	Right  = 4,
}

bar_position_of_word :: proc "contextless" (word: u64) -> (pos: Bar_Position, ok: bool) {
	return enum_word.member_of_word(Bar_Position, word)
}

Window_Decoration :: enum u8 {
	Server = 0, // Default compositor title bar, minimize/maximize/close buttons, and borders.
	Client = 1, // Borderless client-side decorations: client paints its whole surface.
}

window_decoration_of_word :: proc "contextless" (word: u64) -> (dec: Window_Decoration, ok: bool) {
	return enum_word.member_of_word(Window_Decoration, word)
}

Tray_Icon_Kind :: enum u8 {
	Network    = 1,
	Sound      = 2,
	Locale     = 3,
	Capture    = 4,
	Wide_Grant = 5,
}

tray_icon_kind_of_word :: proc "contextless" (word: u64) -> (kind: Tray_Icon_Kind, ok: bool) {
	return enum_word.member_of_word(Tray_Icon_Kind, word)
}

Shell_Rect :: struct {
	x:      i32,
	y:      i32,
	width:  i32,
	height: i32,
}

// bar_and_work_rects computes the exact bar rectangle and remaining desktop
// work area for any Bar_Position (Top, Bottom, Left, Right).
bar_and_work_rects :: proc "contextless" (screen_w, screen_h: i32, pos: Bar_Position) -> (bar_rect, work_rect: Shell_Rect, ok: bool) {
	if screen_w <= BAR_THICKNESS_VERTICAL || screen_h <= BAR_THICKNESS_HORIZONTAL {
		return {}, {}, false
	}
	switch pos {
	case .Top:
		return {0, 0, screen_w, BAR_THICKNESS_HORIZONTAL},
			{0, BAR_THICKNESS_HORIZONTAL, screen_w, screen_h - BAR_THICKNESS_HORIZONTAL}, true
	case .Bottom:
		return {0, screen_h - BAR_THICKNESS_HORIZONTAL, screen_w, BAR_THICKNESS_HORIZONTAL},
			{0, 0, screen_w, screen_h - BAR_THICKNESS_HORIZONTAL}, true
	case .Left:
		return {0, 0, BAR_THICKNESS_VERTICAL, screen_h},
			{BAR_THICKNESS_VERTICAL, 0, screen_w - BAR_THICKNESS_VERTICAL, screen_h}, true
	case .Right:
		return {screen_w - BAR_THICKNESS_VERTICAL, 0, BAR_THICKNESS_VERTICAL, screen_h},
			{0, 0, screen_w - BAR_THICKNESS_VERTICAL, screen_h}, true
	}
	return {}, {}, false
}

// ============================================================================
// Taskbar Window Grouping (aggregates multiple windows of the same module)
// ============================================================================

Window_Entry :: struct {
	window_id:  u64,
	module_key: u64, // Hash of the module/type name for grouping
	focused:    bool,
	minimized:  bool,
}

Taskbar_Group :: struct {
	module_key:      u64,
	first_window_id: u64,
	total_count:     u16,
	minimized_count: u16,
	has_focus:       bool,
}

taskbar_group_windows :: proc "contextless" (windows: []Window_Entry, out_groups: []Taskbar_Group) -> int {
	count := 0
	for w in windows {
		if w.window_id == 0 {
			continue
		}
		found := -1
		for i in 0 ..< count {
			if out_groups[i].module_key == w.module_key {
				found = i
				break
			}
		}
		if found >= 0 {
			g := &out_groups[found]
			g.total_count += 1
			if w.minimized {
				g.minimized_count += 1
			}
			if w.focused {
				g.has_focus = true
			}
		} else if count < len(out_groups) {
			out_groups[count] = {
				module_key      = w.module_key,
				first_window_id = w.window_id,
				total_count     = 1,
				minimized_count = w.minimized ? 1 : 0,
				has_focus       = w.focused,
			}
			count += 1
		}
	}
	return count
}

// ============================================================================
// System Tray Icons
// ============================================================================

Tray_Entry :: struct {
	active: bool,
	kind:   Tray_Icon_Kind,
	alert:  bool,
	label:  [8]u8,
	len:    u8,
}

Tray_State :: struct {
	entries: [MAX_TRAY_ICONS]Tray_Entry,
}

tray_set :: proc "contextless" (t: ^Tray_State, kind: Tray_Icon_Kind, active, alert: bool, label: string) {
	if t == nil {
		return
	}
	free_idx := -1
	for &e, i in t.entries {
		if e.kind == kind && e.active {
			if !active {
				e = {}
				return
			}
			e.alert = alert
			n := min(len(label), len(e.label))
			e.len = u8(n)
			copy(e.label[:n], label[:n])
			return
		}
		if !e.active && free_idx < 0 {
			free_idx = i
		}
	}
	if !active || free_idx < 0 {
		return
	}
	e := &t.entries[free_idx]
	n := min(len(label), len(e.label))
	e^ = {active = true, kind = kind, alert = alert, len = u8(n)}
	copy(e.label[:n], label[:n])
}
