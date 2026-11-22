#+build !freestanding
package bar

import "core:strings"
import "core:testing"

@(test)
window_grant_record_refuses_each_bad_input_and_changes_nothing :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	long_process := strings.repeat("p", WINDOW_GRANT_PROCESS_BYTES + 1, context.temp_allocator)
	long_resource := strings.repeat("r", WINDOW_GRANT_RESOURCE_BYTES + 1, context.temp_allocator)
	cases := [?]struct {
		process, resource: string,
		refusal:           Window_Grant_Refusal,
	} {
		{"", "10.0.2.100 port 80, TCP", .Empty_Process},
		{"notes", "", .Empty_Resource},
		{long_process, "documents", .Process_Too_Long},
		{"notes", long_resource, .Resource_Too_Long},
	}
	for test_case in cases {
		grant_id, refusal := window_grant_record(&table, test_case.process, test_case.resource)
		testing.expect_value(t, grant_id, 0)
		testing.expect_value(t, refusal, test_case.refusal)
		testing.expect_value(t, table.count, 0)
		testing.expect_value(t, table.last_grant_id, 0)
	}
	// The bounds themselves fit whole.
	edge_process := strings.repeat("p", WINDOW_GRANT_PROCESS_BYTES, context.temp_allocator)
	edge_resource := strings.repeat("r", WINDOW_GRANT_RESOURCE_BYTES, context.temp_allocator)
	grant_id, refusal := window_grant_record(&table, edge_process, edge_resource)
	testing.expect_value(t, refusal, Window_Grant_Refusal.None)
	testing.expect_value(t, grant_id, 1)
	testing.expect_value(t, window_grant_process(&table.grants[0]), edge_process)
	testing.expect_value(t, window_grant_resource(&table.grants[0]), edge_resource)
}

@(test)
window_grant_table_full_refuses_the_next_grant :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	for index in 0 ..< WINDOW_GRANT_CAPACITY {
		grant_id, refusal := window_grant_record(&table, "notes", "documents")
		testing.expect_value(t, refusal, Window_Grant_Refusal.None)
		testing.expect_value(t, grant_id, u64(index + 1))
	}
	grant_id, refusal := window_grant_record(&table, "notes", "documents")
	testing.expect_value(t, grant_id, 0)
	testing.expect_value(t, refusal, Window_Grant_Refusal.Full)
	testing.expect_value(t, table.count, WINDOW_GRANT_CAPACITY)
	// A revoke frees a place, and the next number is still new.
	_, ok := window_grant_revoke(&table, 5)
	testing.expect(t, ok)
	grant_id, refusal = window_grant_record(&table, "notes", "projects")
	testing.expect_value(t, refusal, Window_Grant_Refusal.None)
	testing.expect_value(t, grant_id, u64(WINDOW_GRANT_CAPACITY + 1))
}

@(test)
window_grant_revoke_refuses_a_number_that_holds_no_grant :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	first, _ := window_grant_record(&table, "notes", "documents")
	second, _ := window_grant_record(&table, "paint", "10.0.2.100 port 80, TCP")
	third, _ := window_grant_record(&table, "notes", "projects")
	for missing in ([?]u64{0, 4, max(u64)}) {
		_, ok := window_grant_revoke(&table, missing)
		testing.expectf(t, !ok, "the number %v holds no grant", missing)
		testing.expect_value(t, table.count, 3)
	}
	revoked, ok := window_grant_revoke(&table, second)
	testing.expect(t, ok)
	testing.expect_value(t, window_grant_process(&revoked), "paint")
	testing.expect_value(t, table.count, 2)
	// A second revoke of the same number is refused.
	_, ok = window_grant_revoke(&table, second)
	testing.expect(t, !ok)
	// The others keep the order of their record.
	testing.expect_value(t, table.grants[0].grant_id, first)
	testing.expect_value(t, table.grants[1].grant_id, third)
	testing.expect_value(t, table.grants[2].grant_id, 0)
}

@(test)
window_grants_end_with_their_process_only :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	window_grant_record(&table, "notes", "documents")
	window_grant_record(&table, "paint", "pictures")
	window_grant_record(&table, "notes", "projects")
	testing.expect_value(t, window_grants_end_of_process(&table, "absent"), 0)
	testing.expect_value(t, window_grants_end_of_process(&table, "note"), 0) // A prefix is another process.
	testing.expect_value(t, window_grants_end_of_process(&table, "notes"), 2)
	testing.expect_value(t, table.count, 1)
	testing.expect_value(t, window_grant_process(&table.grants[0]), "paint")
	testing.expect_value(t, table.grants[1].grant_id, 0)
}

@(test)
windows_menu_rows_put_each_grant_under_its_window :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	window_grant_record(&table, "notes", "documents")
	window_grant_record(&table, "absent", "pictures") // A process with no window has no row.
	window_grant_record(&table, "paint", "10.0.2.100 port 80, TCP")
	window_grant_record(&table, "notes", "projects")
	names := [?]string{"console", "notes", "paint"}
	rows: [WINDOWS_MENU_ROW_CAPACITY]Windows_Menu_Row
	count := windows_menu_rows(&table, names[:], rows[:])
	testing.expect_value(t, count, 6)
	expected := [?]Windows_Menu_Row {
		{kind = .Window, window = 0, grant = -1},
		{kind = .Window, window = 1, grant = -1},
		{kind = .Grant, window = 1, grant = 0},
		{kind = .Grant, window = 1, grant = 3},
		{kind = .Window, window = 2, grant = -1},
		{kind = .Grant, window = 2, grant = 2},
	}
	for row, index in expected {
		testing.expectf(t, rows[index] == row, "row %v: %v, not %v", index, rows[index], row)
	}
	// With no room, no row; with less room, the rows that fit.
	testing.expect_value(t, windows_menu_rows(&table, names[:], rows[:0]), 0)
	testing.expect_value(t, windows_menu_rows(&table, names[:], rows[:3]), 3)
	testing.expect(t, rows[2] == expected[2])
	// No window: no row, whatever the grants.
	testing.expect_value(t, windows_menu_rows(&table, nil, rows[:]), 0)
}

@(test)
windows_menu_press_revokes_on_the_button_only :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	window_grant_record(&table, "notes", "documents")
	names := [?]string{"console", "notes"}
	rows: [WINDOWS_MENU_ROW_CAPACITY]Windows_Menu_Row
	count := windows_menu_rows(&table, names[:], rows[:])
	testing.expect_value(t, count, 3)
	for edge in Edge {
		layout := placed(layout_of(.None), edge, 768)
		// The button of the grant row: its middle, its corners, and one
		// pixel past each edge.
		x, y, width, height := windows_revoke_button(layout, 2)
		line_x, line_y, line_width, line_height := windows_line(layout, 2)
		testing.expectf(t, x > line_x && x + width < line_x + line_width && y > line_y && y + height < line_y + line_height, "%v: the button is inside its row", edge)
		for point in ([?][2]int{{x + width / 2, y + height / 2}, {x, y}, {x + width - 1, y + height - 1}}) {
			row, on_revoke := windows_menu_point(layout, rows[:count], point.x, point.y)
			testing.expectf(t, row == 2 && on_revoke, "%v: %v is on the button", edge, point)
			testing.expect_value(t, windows_menu_act(rows[:count], row, on_revoke), Windows_Menu_Act.Revoke_Grant)
		}
		for point in ([?][2]int{{x - 1, y}, {x + width, y}, {x, y - 1}, {x, y + height}}) {
			row, on_revoke := windows_menu_point(layout, rows[:count], point.x, point.y)
			testing.expectf(t, !on_revoke, "%v: %v is past the button", edge, point)
			if row == 2 {
				testing.expect_value(t, windows_menu_act(rows[:count], row, on_revoke), Windows_Menu_Act.Stay_Open)
			}
		}
		// A window row has no button, even at the place of the button of
		// the row under it.
		window_x, window_y, _, _ := windows_revoke_button(layout, 1)
		row, on_revoke := windows_menu_point(layout, rows[:count], window_x + 1, window_y + 1)
		testing.expect_value(t, row, 1)
		testing.expect(t, !on_revoke)
		testing.expect_value(t, windows_menu_act(rows[:count], row, true), Windows_Menu_Act.Raise_Window)
		// A point past the last row is on no row.
		center_x, center_y := windows_line_center(layout, count)
		row, on_revoke = windows_menu_point(layout, rows[:count], center_x, center_y)
		testing.expect_value(t, row, -1)
		testing.expect(t, !on_revoke)
	}
}

@(test)
windows_menu_keys_step_over_grant_rows_and_revoke :: proc(t: ^testing.T) {
	table: Window_Grant_Table
	window_grant_record(&table, "notes", "documents")
	window_grant_record(&table, "notes", "projects")
	names := [?]string{"notes", "paint"}
	rows: [WINDOWS_MENU_ROW_CAPACITY]Windows_Menu_Row
	count := windows_menu_rows(&table, names[:], rows[:])
	testing.expect_value(t, count, 4)
	// Down walks each row, the grant rows too, and goes around.
	line := -1
	for expected in ([?]int{0, 1, 2, 3, 0}) {
		line = windows_menu_step(line, count, true)
		testing.expect_value(t, line, expected)
	}
	// Enter or Space on a grant row revokes it; on a window row it raises.
	testing.expect_value(t, windows_menu_act(rows[:count], 1, true), Windows_Menu_Act.Revoke_Grant)
	testing.expect_value(t, windows_menu_act(rows[:count], 0, true), Windows_Menu_Act.Raise_Window)
	// No row chosen, or a row past the count: nothing but the close.
	for row in ([?]int{-1, count, max(int)}) {
		testing.expect_value(t, windows_menu_act(rows[:count], row, true), Windows_Menu_Act.Close)
	}
	// The revoke of the last grant row keeps the choice on the menu.
	grant_id := table.grants[rows[2].grant].grant_id
	_, ok := window_grant_revoke(&table, grant_id)
	testing.expect(t, ok)
	count = windows_menu_rows(&table, names[:], rows[:])
	testing.expect_value(t, count, 3)
	testing.expect_value(t, windows_menu_row_after_change(3, count), 2)
	testing.expect_value(t, windows_menu_row_after_change(1, count), 1)
	testing.expect_value(t, windows_menu_row_after_change(-1, count), -1)
	testing.expect_value(t, windows_menu_row_after_change(2, 0), -1)
}
