package bar

// The acts of the desktop by keys alone (src/md/features/accessibility.md,
// "3. Keyboard access to everything"): the move and the resize of the
// window in front, and the walk over the items of the bar and the lines of
// its menus. The compositor holds the state; these procedures hold none, so
// a host test gives them each edge.

// The step of an arrow key: a spacing token of the design. With Shift, one
// logical pixel, so each place and each size stays reachable.
KEYBOARD_STEP :: 16
KEYBOARD_FINE_STEP :: 1

// What the arrow keys do to the window in front. None: they go to its
// process.
Keyboard_Window_Mode :: enum u8 {
	None,
	Move, // The arrows move the window; Enter keeps the place, Escape gives the old one back.
	Resize, // The arrows move its right and bottom edges; Enter asks the one Resized, Escape gives the old size back.
}

// An arrow key.
Arrow :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

// arrow_step gives the move of an arrow key, in logical pixels.
arrow_step :: proc "contextless" (arrow: Arrow, fine: bool) -> (step_x, step_y: int) {
	step := fine ? KEYBOARD_FINE_STEP : KEYBOARD_STEP
	switch arrow {
	case .Left:
		return -step, 0
	case .Right:
		return step, 0
	case .Up:
		return 0, -step
	case .Down:
		return 0, step
	}
	return 0, 0
}

// keyboard_move_place gives the place of a window after one arrow key in
// the mode Move: one step from its place, then kept on the screen by the
// rule of a drag (window_place_kept), so a part of its title always stays
// where the pointer and the keys can take it again.
keyboard_move_place :: proc "contextless" (x, y: int, arrow: Arrow, fine: bool, frame: Window_Frame, screen_width, screen_height: int) -> (moved_x, moved_y: int) {
	step_x, step_y := arrow_step(arrow, fine)
	return window_place_kept(x + step_x, y + step_y, frame, screen_width, screen_height)
}

// keyboard_resize_size gives the size of the surface of a window after one
// arrow key in the mode Resize: Right and Down grow it, Left and Up shrink
// it. The keys hold the right and the bottom edges, as a drag of the
// corner at the bottom right: the top left corner stays, and the rule of a
// drag (resize_drag) keeps the size inside sizes and the frame on the
// screen. The size given is the size of now, which sizes must hold.
keyboard_resize_size :: proc "contextless" (x, y, width, height: int, arrow: Arrow, fine: bool, sizes: Size_Range, frame_width, frame_height, screen_width, screen_height: int) -> (resized_width, resized_height: int) {
	step_x, step_y := arrow_step(arrow, fine)
	start := Resize_Start{edges = {.Right, .Bottom}, x = x, y = y, width = width, height = height}
	_, _, resized_width, resized_height = resize_drag(start, step_x, step_y, sizes, frame_width, frame_height, screen_width, screen_height)
	return
}

// What an item of the bar is, in the order of the keys. None: the bar has
// not the focus of the keys.
Bar_Item_Kind :: enum u8 {
	None,
	Start, // The heron button: Enter opens the start menu.
	Windows, // The button of the windows: Enter opens the menu of the windows.
	Plate, // The plate of a group of windows: Enter brings the group to the front.
	Viewer_Mark, // The mark of the viewers of the remote display: Enter opens the list of the viewers.
	Control_Center, // The button of the control center: Enter opens its card.
	Notifications, // The button of the notifications: Enter opens the history.
	Clock, // The clock: Enter opens the calendar.
}

// The tray buttons that the keys reach, after the viewer mark: the control
// center, the notifications, the clock.
TRAY_ITEM_COUNT :: 3

// bar_item_tray_widget gives the widget that an item opens, or None for an
// item that opens no tray widget.
bar_item_tray_widget :: proc "contextless" (kind: Bar_Item_Kind) -> Tray_Widget {
	switch kind {
	case .None, .Start, .Windows, .Plate, .Viewer_Mark:
		return .None
	case .Control_Center:
		return .Control_Center
	case .Notifications:
		return .Notifications
	case .Clock:
		return .Calendar
	}
	return .None
}

// One item of the bar that the keys reach. plate: the slot of a Plate, 0
// for each other kind.
Bar_Item :: struct {
	kind:  Bar_Item_Kind,
	plate: int,
}

// bar_item_of_tray_widget gives the item of the bar that opens a widget, or
// None for None.
bar_item_of_tray_widget :: proc "contextless" (widget: Tray_Widget) -> Bar_Item_Kind {
	switch widget {
	case .None:
		return .None
	case .Control_Center:
		return .Control_Center
	case .Notifications:
		return .Notifications
	case .Calendar:
		return .Clock
	}
	return .None
}

// bar_item_count gives the items that the keys reach: the two buttons, the
// plates that the bar shows, the viewer mark when it is shown, and the
// tray buttons with the clock. A pill
// of the tray that does nothing is no item: the focus never stops on a
// thing that no key acts on.
bar_item_count :: proc "contextless" (plate_count: int, viewer_mark: bool) -> int {
	return 2 + max(plate_count, 0) + (viewer_mark ? 1 : 0) + TRAY_ITEM_COUNT
}

// bar_item_place gives the place of an item in the order of the keys, or
// -1 for None and for an item that the bar does not show.
bar_item_place :: proc "contextless" (item: Bar_Item, plate_count: int, viewer_mark: bool) -> int {
	switch item.kind {
	case .None:
		return -1
	case .Start:
		return 0
	case .Windows:
		return 1
	case .Plate:
		if item.plate < 0 || item.plate >= plate_count {
			return -1
		}
		return 2 + item.plate
	case .Viewer_Mark:
		if !viewer_mark {
			return -1
		}
		return 2 + max(plate_count, 0)
	case .Control_Center:
		return 2 + max(plate_count, 0) + (viewer_mark ? 1 : 0)
	case .Notifications:
		return 3 + max(plate_count, 0) + (viewer_mark ? 1 : 0)
	case .Clock:
		return 4 + max(plate_count, 0) + (viewer_mark ? 1 : 0)
	}
	return -1
}

// bar_item_at gives the item at a place in the order of the keys. A place
// outside the order gives None.
bar_item_at :: proc "contextless" (place, plate_count: int, viewer_mark: bool) -> Bar_Item {
	count := bar_item_count(plate_count, viewer_mark)
	switch {
	case place < 0 || place >= count:
		return {}
	case place == 0:
		return {kind = .Start}
	case place == 1:
		return {kind = .Windows}
	case place < 2 + max(plate_count, 0):
		return {kind = .Plate, plate = place - 2}
	case viewer_mark && place == 2 + max(plate_count, 0):
		return {kind = .Viewer_Mark}
	}
	switch place - (count - TRAY_ITEM_COUNT) {
	case 0:
		return {kind = .Control_Center}
	case 1:
		return {kind = .Notifications}
	}
	return {kind = .Clock}
}

// bar_item_step gives the next item (Right, forward) or the item before
// (Left), around the ends. An item that left the bar (a plate whose group
// closed, a viewer mark that went) counts as the last item that is still
// there: Left gives that item, Right the first. A bar with no focus starts
// at the heron button.
bar_item_step :: proc "contextless" (item: Bar_Item, plate_count: int, viewer_mark: bool, forward: bool) -> Bar_Item {
	if item.kind == .None {
		return {kind = .Start}
	}
	count := bar_item_count(plate_count, viewer_mark)
	place := bar_item_place(item, plate_count, viewer_mark)
	if place < 0 {
		return bar_item_at(forward ? 0 : count - 1, plate_count, viewer_mark)
	}
	step := forward ? 1 : count - 1
	return bar_item_at((place + step) % count, plate_count, viewer_mark)
}

// The most lines of the start menu in the order of the keys: each name,
// then each quick action, with the demonstrations open.
START_MENU_KEY_LINES :: len(names) + ACTION_COUNT

// The quick actions in the order of their lines, from the top.
@(rodata)
start_actions_in_order := [ACTION_COUNT]Start_Action{.Demonstrations, .Bar_Edge, .Magnifier}

// start_menu_step gives the chosen line or quick action of the start menu
// after Down (forward) or Up, around the ends: line is a name, or -1 with
// action a quick action. Only the lines that the menu shows are steps: the
// names of the layout (shown_count), then the quick actions. With nothing
// chosen, Down chooses the first name and Up the last quick action; a line
// that the menu does not show counts as nothing chosen.
start_menu_step :: proc "contextless" (layout: Layout, line: int, action: Start_Action, forward: bool) -> (next_line: int, next_action: Start_Action) {
	shown := shown_count(layout)
	lines := shown + ACTION_COUNT
	place := -1
	if line >= 0 && line < shown {
		place = line
	}
	for ordered, index in start_actions_in_order {
		if action != .None && ordered == action {
			place = shown + index
		}
	}
	if place < 0 {
		place = forward ? 0 : lines - 1
	} else {
		place = (place + (forward ? 1 : lines - 1)) % lines
	}
	if place < shown {
		return place, .None
	}
	return -1, start_actions_in_order[place - shown]
}

// windows_menu_step gives the chosen line of the menu of count windows
// after Down (forward) or Up, around the ends; -1 with no window. With no
// line chosen, or a line past the count, Down chooses the first line and
// Up the last.
windows_menu_step :: proc "contextless" (line, count: int, forward: bool) -> int {
	if count <= 0 {
		return -1
	}
	if line < 0 || line >= count {
		return forward ? 0 : count - 1
	}
	return (line + (forward ? 1 : count - 1)) % count
}
