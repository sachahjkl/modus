#+build !freestanding
package bar

import "core:strings"
import "core:testing"

@(test)
plan_difference_open_refuses_each_bad_input_and_changes_nothing :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	long_name := strings.repeat("n", PLAN_DIFFERENCE_NAME_BYTES + 1, context.temp_allocator)
	long_item := strings.repeat("i", PLAN_DIFFERENCE_ITEM_BYTES + 1, context.temp_allocator)
	nine := "a, b, c, d, e, f, g, h, i"
	cases := [?]struct {
		name, added, removed: string,
		refusal:              Plan_Difference_Refusal,
		argument:             int,
	} {
		{"", "notes: store documents", "", .Empty_Name, 1},
		{long_name, "notes: store documents", "", .Name_Too_Long, 1},
		{"home", "", "", .No_Change, 2},
		{"home", "   ", " ", .No_Change, 2},
		{"home", "a,,b", "", .Empty_Item, 2},
		{"home", "a,", "", .Empty_Item, 2},
		{"home", ",a", "", .Empty_Item, 2},
		{"home", "a", " , ", .Empty_Item, 3},
		{"home", long_item, "", .Item_Too_Long, 2},
		{"home", "", nine, .Too_Many_Items, 3},
	}
	for test_case in cases {
		serial, refusal, argument := plan_difference_open(&dialog, test_case.name, test_case.added, test_case.removed, 1000)
		testing.expectf(t, serial == 0 && refusal == test_case.refusal && argument == test_case.argument, "%v: %v %v %v", test_case, serial, refusal, argument)
		testing.expect(t, !dialog.open)
		testing.expect_value(t, dialog.serial, 0)
		testing.expect_value(t, dialog.added_count, 0)
	}
	// The bounds fit: a name and an item of the most bytes, a side of the
	// most items.
	edge_name := strings.repeat("n", PLAN_DIFFERENCE_NAME_BYTES, context.temp_allocator)
	edge_item := strings.repeat("i", PLAN_DIFFERENCE_ITEM_BYTES, context.temp_allocator)
	serial, refusal, _ := plan_difference_open(&dialog, edge_name, edge_item, "a, b, c, d, e, f, g, h", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, serial, 1)
	testing.expect_value(t, plan_difference_name(&dialog), edge_name)
	testing.expect_value(t, dialog.added_count, 1)
	testing.expect_value(t, plan_difference_item_text(&dialog.added[0]), edge_item)
	testing.expect_value(t, dialog.removed_count, PLAN_DIFFERENCE_ITEM_CAPACITY)
	testing.expect_value(t, plan_difference_item_text(&dialog.removed[7]), "h")
	// A second difference while one shows is refused, and the first stays.
	serial, refusal, _ = plan_difference_open(&dialog, "other", "x", "", 1200)
	testing.expect_value(t, serial, 0)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.Busy)
	testing.expect_value(t, plan_difference_name(&dialog), edge_name)
	testing.expect_value(t, dialog.shown_at_milliseconds, 1000)
}

@(test)
plan_difference_act_before_the_arm_time_is_no_act :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	_, refusal, _ := plan_difference_open(&dialog, "home", "notes: store documents", "paint: network", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Refuse)
	testing.expect_value(t, plan_difference_key(&dialog, .Next, 1000), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
	// Enter at the show, and one millisecond before the arm: no act.
	for now in ([?]u64{0, 1000, 1000 + PLAN_DIFFERENCE_ARM_MILLISECONDS - 1}) {
		testing.expect_value(t, plan_difference_key(&dialog, .Act, now), Plan_Difference_Decision.Pending)
		testing.expect(t, dialog.open)
	}
	// A press on Accept before the arm: no act either.
	x, y, width, height := plan_difference_place(&dialog, 1280, 32, 768)
	accept_x, accept_y, _, _ := plan_difference_button_place(x, y, width, height, .Accept)
	testing.expect_value(t, plan_difference_press(&dialog, 1280, 32, 768, accept_x + 1, accept_y + 1, 1499), Plan_Difference_Decision.Pending)
	testing.expect(t, dialog.open)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Pending)
	// Other keys change nothing.
	testing.expect_value(t, plan_difference_key(&dialog, .Other, 9000), Plan_Difference_Decision.Pending)
	testing.expect(t, dialog.open)
	// At the arm time, Enter on Accept accepts.
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 1000 + PLAN_DIFFERENCE_ARM_MILLISECONDS), Plan_Difference_Decision.Accepted)
	testing.expect(t, !dialog.open)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Accepted)
	// A closed dialog takes no act.
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 9000), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Accepted)
}

@(test)
plan_difference_enter_on_the_first_focus_refuses :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	plan_difference_open(&dialog, "home", "notes: store documents", "", 1000)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 2000), Plan_Difference_Decision.Refused)
	testing.expect(t, !dialog.open)
	// Two moves of the focus come back to Refuse.
	plan_difference_open(&dialog, "home", "", "paint: network", 3000)
	testing.expect_value(t, dialog.serial, 2)
	plan_difference_key(&dialog, .Next, 3000)
	plan_difference_key(&dialog, .Next, 3000)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 4000), Plan_Difference_Decision.Refused)
}

@(test)
plan_difference_escape_refuses_at_once :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	plan_difference_open(&dialog, "home", "notes: store documents", "", 1000)
	plan_difference_key(&dialog, .Next, 1000)
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 1000), Plan_Difference_Decision.Refused)
	testing.expect(t, !dialog.open)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Refused)
}

@(test)
plan_difference_press_acts_on_its_buttons_only :: proc(t: ^testing.T) {
	SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM :: 1280, 32, 768
	dialog: Plan_Difference_Dialog
	plan_difference_open(&dialog, "home", "notes: store documents, paint: network", "clock: settings", 1000)
	x, y, width, height := plan_difference_place(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM)
	testing.expect(t, y >= WORK_TOP && y + height <= WORK_BOTTOM)
	accept_x, accept_y, accept_width, accept_height := plan_difference_button_place(x, y, width, height, .Accept)
	refuse_x, refuse_y, refuse_width, _ := plan_difference_button_place(x, y, width, height, .Refuse)
	testing.expect(t, accept_x + accept_width < refuse_x && accept_y == refuse_y)
	testing.expect(t, refuse_x + refuse_width <= x + width && accept_x >= x)
	// Presses in the dialog away from the buttons, outside it, and one
	// pixel past each edge of Accept: no decision.
	misses := [?][2]int{{x + 4, y + 4}, {0, 0}, {accept_x - 1, accept_y}, {accept_x + accept_width, accept_y}, {accept_x, accept_y - 1}, {accept_x, accept_y + accept_height}}
	for point in misses {
		testing.expectf(t, plan_difference_press(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, point.x, point.y, 5000) == .Pending, "%v is on no button", point)
		testing.expect(t, dialog.open)
	}
	// The last pixel of Accept accepts.
	testing.expect_value(t, plan_difference_press(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, accept_x + accept_width - 1, accept_y + accept_height - 1, 5000), Plan_Difference_Decision.Accepted)
	// Refuse, by a press, on the next dialog.
	plan_difference_open(&dialog, "home", "x", "", 6000)
	_, refuse_y_again, _, _ := plan_difference_button_place(plan_difference_place(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM), Plan_Difference_Button.Refuse)
	refuse_x_again, _, _, _ := plan_difference_button_place(plan_difference_place(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM), Plan_Difference_Button.Refuse)
	testing.expect_value(t, plan_difference_press(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, refuse_x_again, refuse_y_again, 7000), Plan_Difference_Decision.Refused)
	// A closed dialog takes no press.
	testing.expect_value(t, plan_difference_press(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, refuse_x_again, refuse_y_again, 8000), Plan_Difference_Decision.Pending)
}

@(test)
plan_difference_grows_with_its_items_and_stays_in_the_room :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	plan_difference_open(&dialog, "home", "a", "", 0)
	_, _, _, one := plan_difference_place(&dialog, 1280, 32, 768)
	dialog.open = false
	plan_difference_open(&dialog, "home", "a, b, c, d, e, f, g, h", "a, b, c, d, e, f, g, h", 0)
	_, y, _, most := plan_difference_place(&dialog, 1280, 32, 768)
	testing.expect_value(t, most - one, 7 * PLAN_DIFFERENCE_LINE + PLAN_DIFFERENCE_GAP + 9 * PLAN_DIFFERENCE_LINE)
	// The most items fit the room of the windows of the reference screen.
	testing.expect(t, y >= 32 && y + most <= 768)
	// A bar at the bottom: the room starts at 0.
	_, bottom_y, _, _ := plan_difference_place(&dialog, 1280, 0, 736)
	testing.expect(t, bottom_y >= PLAN_DIFFERENCE_MARGIN)
}

@(test)
plan_difference_decision_of_serial_names_only_the_last_dialog :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	// Before any dialog: serial 0, 1 and the largest serial name nothing.
	for serial in ([?]u64{0, 1, max(u64)}) {
		decision, known := plan_difference_decision_of_serial(&dialog, serial)
		testing.expectf(t, !known && decision == .Pending, "serial %v: %v %v", serial, decision, known)
	}
	first, _, _ := plan_difference_open(&dialog, "home", "notes: store documents", "", 1000)
	decision, known := plan_difference_decision_of_serial(&dialog, first)
	testing.expect(t, known && decision == .Pending)
	// A serial one past the one shown names nothing.
	_, known = plan_difference_decision_of_serial(&dialog, first + 1)
	testing.expect(t, !known)
	plan_difference_key(&dialog, .Next, 1000)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 2000), Plan_Difference_Decision.Accepted)
	decision, known = plan_difference_decision_of_serial(&dialog, first)
	testing.expect(t, known && decision == .Accepted)
	// A later dialog replaces the decision: the first serial is unknown, so a
	// caller never reads the decision of another dialog as its own.
	second, _, _ := plan_difference_open(&dialog, "home", "", "paint: network", 3000)
	_, known = plan_difference_decision_of_serial(&dialog, first)
	testing.expect(t, !known)
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 3000), Plan_Difference_Decision.Refused)
	decision, known = plan_difference_decision_of_serial(&dialog, second)
	testing.expect(t, known && decision == .Refused)
}
