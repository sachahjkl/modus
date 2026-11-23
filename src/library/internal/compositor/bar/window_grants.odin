// The requested grants that the menu of the windows lists under the window
// of their process, and the rows of that menu: one row for each window,
// then one row for each grant of its process. The compositor keeps the
// table and draws the rows; the places and the acts are here, so a host
// test reads the same layout as the screen
// (src/md/features/powerbox.md, "The grant").
package bar

// A process holds at most 32 requested grants, and the windows of all the
// processes share this table: past it, a new grant is refused, never cut.
WINDOW_GRANT_CAPACITY :: 32
// The name of the process of a grant: the title of its window, which is a
// system.Name of 31 bytes at most.
WINDOW_GRANT_PROCESS_BYTES :: 31
// The object of a grant, as the dialog showed it: with a zero byte after
// it, it fills a field of 96 bytes of a row or a fact.
WINDOW_GRANT_RESOURCE_BYTES :: 95

// The windows of the desktop at one time: the clients of the compositor.
WINDOW_CAPACITY :: 128

// The rows of the menu of the windows: each window and each grant.
WINDOWS_MENU_ROW_CAPACITY :: WINDOW_CAPACITY + WINDOW_GRANT_CAPACITY

// A grant row: the key icon after the place of the icon of the window, so
// the row reads as a part of the window above it; then the object; then
// the button that revokes it, at the right end of the row.
WINDOWS_GRANT_ICON_X :: WINDOWS_TITLE_X
WINDOWS_GRANT_TEXT_X :: WINDOWS_GRANT_ICON_X + ICON_SIZE + ICON_GAP
WINDOWS_REVOKE_WIDTH :: 64
WINDOWS_REVOKE_INSET :: 3 // From the top and the foot of the row to the button.

// A requested grant that the principal kept, and that holds.
Window_Grant :: struct {
	grant_id:        u64, // The number of the grant: never 0, never given twice in one run.
	process_name:    [WINDOW_GRANT_PROCESS_BYTES]u8,
	process_length:  int,
	resource_name:   [WINDOW_GRANT_RESOURCE_BYTES]u8,
	resource_length: int,
}

// The grants that hold, in the order of their record: a revoked grant
// leaves the table, so the rows of a window keep that order.
Window_Grant_Table :: struct {
	grants:        [WINDOW_GRANT_CAPACITY]Window_Grant,
	count:         int,
	last_grant_id: u64, // The number of the last grant recorded; 0 before the first.
}

// Why a grant is not recorded.
Window_Grant_Refusal :: enum u8 {
	None,
	Empty_Process, // The process has no name.
	Empty_Resource, // The grant names no object.
	Process_Too_Long, // Past WINDOW_GRANT_PROCESS_BYTES.
	Resource_Too_Long, // Past WINDOW_GRANT_RESOURCE_BYTES.
	Full, // WINDOW_GRANT_CAPACITY grants hold.
}

// window_grant_record records a grant of a process to an object, and
// gives its number, or 0 with the refusal. A name that does not fit is
// refused whole: a cut name could name another process or another object.
window_grant_record :: proc "contextless" (table: ^Window_Grant_Table, process_name, resource_name: string) -> (grant_id: u64, refusal: Window_Grant_Refusal) {
	switch {
	case len(process_name) == 0:
		return 0, .Empty_Process
	case len(resource_name) == 0:
		return 0, .Empty_Resource
	case len(process_name) > WINDOW_GRANT_PROCESS_BYTES:
		return 0, .Process_Too_Long
	case len(resource_name) > WINDOW_GRANT_RESOURCE_BYTES:
		return 0, .Resource_Too_Long
	case table.count >= WINDOW_GRANT_CAPACITY:
		return 0, .Full
	}
	table.last_grant_id += 1
	grant := &table.grants[table.count]
	grant^ = {grant_id = table.last_grant_id, process_length = len(process_name), resource_length = len(resource_name)}
	copy(grant.process_name[:], process_name)
	copy(grant.resource_name[:], resource_name)
	table.count += 1
	return grant.grant_id, .None
}

// window_grant_process gives the name of the process of a grant.
window_grant_process :: proc "contextless" (grant: ^Window_Grant) -> string {
	return string(grant.process_name[:grant.process_length])
}

// window_grant_resource gives the object of a grant.
window_grant_resource :: proc "contextless" (grant: ^Window_Grant) -> string {
	return string(grant.resource_name[:grant.resource_length])
}

// window_grant_find gives the slot of the grant of a number, or -1.
window_grant_find :: proc "contextless" (table: ^Window_Grant_Table, grant_id: u64) -> int {
	if grant_id == 0 {
		return -1
	}
	for slot in 0 ..< table.count {
		if table.grants[slot].grant_id == grant_id {
			return slot
		}
	}
	return -1
}

// window_grant_revoke ends the grant of a number, and gives a copy of it.
// ok is false when no grant of that number holds: a number that was
// revoked, never given, or 0.
window_grant_revoke :: proc "contextless" (table: ^Window_Grant_Table, grant_id: u64) -> (revoked: Window_Grant, ok: bool) {
	slot := window_grant_find(table, grant_id)
	if slot < 0 {
		return {}, false
	}
	revoked = table.grants[slot]
	copy(table.grants[slot:table.count - 1], table.grants[slot + 1:table.count])
	table.count -= 1
	table.grants[table.count] = {}
	return revoked, true
}

// window_grants_end_of_process ends each grant of a process, and gives
// their count: a grant for this run ends with its process.
window_grants_end_of_process :: proc "contextless" (table: ^Window_Grant_Table, process_name: string) -> int {
	kept, ended := 0, 0
	for slot in 0 ..< table.count {
		if window_grant_process(&table.grants[slot]) == process_name {
			ended += 1
			continue
		}
		table.grants[kept] = table.grants[slot]
		kept += 1
	}
	for slot in kept ..< table.count {
		table.grants[slot] = {}
	}
	table.count = kept
	return ended
}

// The kind of a row of the menu of the windows.
Windows_Menu_Row_Kind :: enum u8 {
	Window, // A window: a press brings it to the front.
	Grant, // A grant of the process of the window above: its button revokes it.
}

// A row of the menu of the windows.
Windows_Menu_Row :: struct {
	kind:   Windows_Menu_Row_Kind,
	window: int, // The line of the window in the list of the windows; a grant row has the line of its window.
	grant:  int, // The slot of the grant in the table; -1 on a window row.
}

// windows_menu_rows writes the rows of the menu of the windows: each
// window of window_names, in their order, and under it each grant of its
// process. It gives the count of the rows; a window or a grant past the
// room of rows has no row.
windows_menu_rows :: proc "contextless" (table: ^Window_Grant_Table, window_names: []string, rows: []Windows_Menu_Row) -> int {
	count := 0
	for name, window in window_names {
		if count >= len(rows) {
			break
		}
		rows[count] = {kind = .Window, window = window, grant = -1}
		count += 1
		for slot in 0 ..< table.count {
			if count >= len(rows) {
				break
			}
			if window_grant_process(&table.grants[slot]) == name {
				rows[count] = {kind = .Grant, window = window, grant = slot}
				count += 1
			}
		}
	}
	return count
}

// windows_revoke_button gives the place of the button that revokes the
// grant of a row of the menu of the windows: at the right end of the row.
windows_revoke_button :: proc "contextless" (layout: Layout, row: int) -> (x, y, width, height: int) {
	line_x, line_y, line_width, line_height := windows_line(layout, row)
	return line_x + line_width - PADDING - WINDOWS_REVOKE_WIDTH, line_y + WINDOWS_REVOKE_INSET, WINDOWS_REVOKE_WIDTH, line_height - 2 * WINDOWS_REVOKE_INSET
}

// windows_menu_point gives the row of the menu of the windows at a point,
// or -1, and whether the point is on the button that revokes the grant of
// that row. A window row has no such button.
windows_menu_point :: proc "contextless" (layout: Layout, rows: []Windows_Menu_Row, point_x, point_y: int) -> (row: int, on_revoke: bool) {
	row = windows_line_at(layout, len(rows), point_x, point_y)
	if row < 0 || rows[row].kind != .Grant {
		return row, false
	}
	x, y, width, height := windows_revoke_button(layout, row)
	return row, inside(point_x, point_y, x, y, width, height)
}

// What a press or a key does on the menu of the windows.
Windows_Menu_Act :: enum u8 {
	Close, // On no row: the menu closes and does nothing.
	Raise_Window, // On a window row: the window comes to the front, and the menu closes.
	Revoke_Grant, // On the button of a grant row, or a key on a grant row: the grant ends, and the menu stays open.
	Stay_Open, // A press on a grant row away from its button: nothing, and the menu stays open.
}

// windows_menu_act gives the act of a row. revoke_asked is true for a
// press on the button of the row, and for Enter or Space on the row: a
// grant row has no other act, so a key there means its button.
windows_menu_act :: proc "contextless" (rows: []Windows_Menu_Row, row: int, revoke_asked: bool) -> Windows_Menu_Act {
	if row < 0 || row >= len(rows) {
		return .Close
	}
	switch rows[row].kind {
	case .Window:
		return .Raise_Window
	case .Grant:
		return revoke_asked ? .Revoke_Grant : .Stay_Open
	}
	return .Close
}

// windows_menu_row_after_change gives the chosen row after the rows
// changed: the same place, or the last row when the menu is shorter, or
// -1 with no row.
windows_menu_row_after_change :: proc "contextless" (row, count: int) -> int {
	if row < 0 || count <= 0 {
		return -1
	}
	return min(row, count - 1)
}
