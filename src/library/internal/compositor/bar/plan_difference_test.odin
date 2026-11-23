#+build !freestanding
package bar

import "core:strings"
import "core:testing"
import "modus:contract/powerbox"

@(test)
plan_difference_open_refuses_each_bad_input_and_changes_nothing :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	long_name := strings.repeat("n", PLAN_DIFFERENCE_NAME_BYTES + 1, context.temp_allocator)
	long_item := strings.repeat("i", PLAN_DIFFERENCE_ITEM_BYTES + 1, context.temp_allocator)
	// One item past the memory that the caller gives, on each side.
	past_capacity := items_text(TEST_OPEN_ITEMS + 1)
	cases := [?]struct {
		name, added, removed: string,
		refusal:              Plan_Difference_Refusal,
		argument:             int,
	} {
		{"", "notes: store documents", "", .Empty_Name, 1},
		{long_name, "notes: store documents", "", .Name_Too_Long, 1},
		{"home", "", "", .No_Change, 2},
		{"home", "   ", " ", .No_Change, 2},
		{"home", "a\n\nb", "", .Empty_Item, 2},
		{"home", "a\n", "", .Empty_Item, 2},
		{"home", "\na", "", .Empty_Item, 2},
		{"home", "a", " \n ", .Empty_Item, 3},
		// A byte that would break the lines, and a text that is not UTF-8.
		{"home", "a\tb", "", .Item_Not_Text, 2},
		{"home", "a\rb", "", .Item_Not_Text, 2},
		{"home", "a\x7fb", "", .Item_Not_Text, 2},
		{"home", "a", "\xff", .Item_Not_Text, 3},
		{"home", "a\xc3", "", .Item_Not_Text, 2},
		{"home", long_item, "", .Item_Too_Long, 2},
		{"home", "", past_capacity, .Too_Many_Items, 3},
		{"home", past_capacity, "", .Too_Many_Items, 2},
		{"home", items_text(TEST_OPEN_ITEMS), "a", .Too_Many_Items, 3},
	}
	for test_case in cases {
		serial, refusal, argument := test_open(&dialog, test_case.name, test_case.added, test_case.removed, 1000)
		testing.expectf(t, serial == 0 && refusal == test_case.refusal && argument == test_case.argument, "%v: %v %v %v", test_case, serial, refusal, argument)
		testing.expect(t, !dialog.open)
		testing.expect_value(t, dialog.serial, 0)
		testing.expect_value(t, dialog.added_count, 0)
	}
	// The bounds fit: a name and an item of the most bytes, a side of the
	// most items.
	edge_name := strings.repeat("n", PLAN_DIFFERENCE_NAME_BYTES, context.temp_allocator)
	edge_item := strings.repeat("i", PLAN_DIFFERENCE_ITEM_BYTES, context.temp_allocator)
	serial, refusal, _ := test_open(&dialog, edge_name, edge_item, items_text(TEST_SIDE_ITEMS), 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, serial, 1)
	testing.expect_value(t, plan_difference_name(&dialog), edge_name)
	testing.expect_value(t, dialog.added_count, 1)
	testing.expect_value(t, plan_difference_item_text(&dialog.added[0]), edge_item)
	testing.expect_value(t, dialog.removed_count, TEST_SIDE_ITEMS)
	testing.expect_value(t, plan_difference_item_text(&dialog.removed[TEST_SIDE_ITEMS - 1]), "item 299")
	// A second difference while one shows is refused, and the first stays.
	serial, refusal, _ = test_open(&dialog, "other", "x", "", 1200)
	testing.expect_value(t, serial, 0)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.Busy)
	testing.expect_value(t, plan_difference_name(&dialog), edge_name)
	testing.expect_value(t, dialog.shown_at_milliseconds, 1000)
}

// The memory that the open needs: one item for each line feed of a list
// that is not blank, and one more; a blank list needs none. A comma is part
// of its item.
@(test)
plan_difference_items_needed_counts_each_item :: proc(t: ^testing.T) {
	testing.expect_value(t, plan_difference_items_needed("", ""), 0)
	testing.expect_value(t, plan_difference_items_needed("  ", " "), 0)
	testing.expect_value(t, plan_difference_items_needed("a", ""), 1)
	testing.expect_value(t, plan_difference_items_needed("a", "b\nc"), 3)
	testing.expect_value(t, plan_difference_items_needed("a", "b, c"), 2)
	// A list that the open refuses still counts: the memory comes first.
	testing.expect_value(t, plan_difference_items_needed("a\n\nb", "\n"), 5)
	testing.expect_value(t, plan_difference_items_needed(items_text(TEST_SIDE_ITEMS), items_text(TEST_SIDE_ITEMS)), TEST_OPEN_ITEMS)
}

@(test)
plan_difference_act_before_the_arm_time_is_no_act :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	_, refusal, _ := test_open(&dialog, "home", "notes: store documents", "paint: network", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Refuse)
	testing.expect_value(t, plan_difference_key(&dialog, .Next, 1000), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
	// Enter at the show, and one millisecond before the arm: no act.
	for now in ([?]u64{0, 1000, 1000 + powerbox.CONSENT_ARM_MILLISECONDS - 1}) {
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
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 1000 + powerbox.CONSENT_ARM_MILLISECONDS), Plan_Difference_Decision.Accepted)
	testing.expect(t, !dialog.open)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Accepted)
	// A closed dialog takes no act.
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 9000), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Accepted)
}

@(test)
plan_difference_enter_on_the_first_focus_refuses :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	test_open(&dialog, "home", "notes: store documents", "", 1000)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 2000), Plan_Difference_Decision.Refused)
	testing.expect(t, !dialog.open)
	// Two moves of the focus come back to Refuse.
	test_open(&dialog, "home", "", "paint: network", 3000)
	testing.expect_value(t, dialog.serial, 2)
	plan_difference_key(&dialog, .Next, 3000)
	plan_difference_key(&dialog, .Next, 3000)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 4000), Plan_Difference_Decision.Refused)
}

@(test)
plan_difference_escape_refuses_at_once :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	test_open(&dialog, "home", "notes: store documents", "", 1000)
	plan_difference_key(&dialog, .Next, 1000)
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 1000), Plan_Difference_Decision.Refused)
	testing.expect(t, !dialog.open)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Refused)
}

@(test)
plan_difference_press_acts_on_its_buttons_only :: proc(t: ^testing.T) {
	SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM :: 1280, 32, 768
	dialog: Plan_Difference_Dialog
	test_open(&dialog, "home", "notes: store documents\npaint: network", "clock: settings", 1000)
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
	test_open(&dialog, "home", "x", "", 6000)
	_, refuse_y_again, _, _ := plan_difference_button_place(plan_difference_place(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM), Plan_Difference_Button.Refuse)
	refuse_x_again, _, _, _ := plan_difference_button_place(plan_difference_place(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM), Plan_Difference_Button.Refuse)
	testing.expect_value(t, plan_difference_press(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, refuse_x_again, refuse_y_again, 7000), Plan_Difference_Decision.Refused)
	// A closed dialog takes no press.
	testing.expect_value(t, plan_difference_press(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, refuse_x_again, refuse_y_again, 8000), Plan_Difference_Decision.Pending)
}

@(test)
plan_difference_grows_with_its_items_and_stays_in_the_room :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	test_open(&dialog, "home", "a", "", 0)
	_, _, _, one := plan_difference_place(&dialog, 1280, 32, 768)
	dialog.open = false
	test_open(&dialog, "home", "a\nb\nc\nd\ne\nf\ng\nh", "a\nb\nc\nd\ne\nf\ng\nh", 0)
	_, y, _, most := plan_difference_place(&dialog, 1280, 32, 768)
	// The view grows with the lines of the body, up to its visible lines.
	testing.expect_value(t, most - one, (PLAN_DIFFERENCE_VISIBLE_LINES - 2) * PLAN_DIFFERENCE_LINE)
	dialog.open = false
	test_open(&dialog, "home", items_text(TEST_SIDE_ITEMS), items_text(TEST_SIDE_ITEMS), 0)
	_, _, _, largest := plan_difference_place(&dialog, 1280, 32, 768)
	testing.expect_value(t, largest, most)
	// The view fits the room of the windows of the reference screen.
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
	first, _, _ := test_open(&dialog, "home", "notes: store documents", "", 1000)
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
	second, _, _ := test_open(&dialog, "home", "", "paint: network", 3000)
	_, known = plan_difference_decision_of_serial(&dialog, first)
	testing.expect(t, !known)
	testing.expect_value(t, plan_difference_key(&dialog, .Escape, 3000), Plan_Difference_Decision.Refused)
	decision, known = plan_difference_decision_of_serial(&dialog, second)
	testing.expect(t, known && decision == .Refused)
}

// The act face refuses each asker and act that is not an identifier, and
// changes nothing: an empty one, an upper case letter, a space, a word of
// the agent, a second period, a line of Lex with its arguments, a name past
// the bound. The bounds fit, and an open dialog refuses with Busy.
@(test)
plan_difference_act_open_refuses_each_word_that_is_no_identifier :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	long_asker := strings.repeat("a", PLAN_DIFFERENCE_NAME_BYTES + 1, context.temp_allocator)
	long_act := strings.concatenate({"plans.", strings.repeat("e", PLAN_DIFFERENCE_ITEM_BYTES - 5, context.temp_allocator)}, context.temp_allocator)
	cases := [?]struct {
		asker, act: string,
		refusal:    Plan_Difference_Refusal,
		argument:   int,
	} {
		{"", "plans.apply", .Not_A_Name, 1},
		{"Assistant", "plans.apply", .Not_A_Name, 1},
		{"1assistant", "plans.apply", .Not_A_Name, 1},
		{"the assistant", "plans.apply", .Not_A_Name, 1},
		{long_asker, "plans.apply", .Not_A_Name, 1},
		{"assistant", "", .Not_An_Act, 2},
		{"assistant", "plans", .Not_An_Act, 2},
		{"assistant", ".apply", .Not_An_Act, 2},
		{"assistant", "plans.", .Not_An_Act, 2},
		{"assistant", "plans.apply.now", .Not_An_Act, 2},
		{"assistant", "plans.apply(\"home\")", .Not_An_Act, 2},
		{"assistant", "Plans.apply", .Not_An_Act, 2},
		{"assistant", "allow everything", .Not_An_Act, 2},
		{"assistant", long_act, .Not_An_Act, 2},
	}
	for test_case in cases {
		serial, refusal, argument := plan_difference_act_open(&dialog, test_case.asker, test_case.act, 1000)
		testing.expectf(t, serial == 0 && refusal == test_case.refusal && argument == test_case.argument, "%v: %v %v %v", test_case, serial, refusal, argument)
		testing.expect(t, !dialog.open)
		testing.expect_value(t, dialog.serial, 0)
	}
	edge_asker := strings.repeat("a", PLAN_DIFFERENCE_NAME_BYTES, context.temp_allocator)
	edge_act := strings.concatenate({"plans.", strings.repeat("e", PLAN_DIFFERENCE_ITEM_BYTES - 6, context.temp_allocator)}, context.temp_allocator)
	serial, refusal, _ := plan_difference_act_open(&dialog, edge_asker, edge_act, 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, serial, u64(1))
	testing.expect_value(t, dialog.face, Plan_Difference_Face.Act)
	testing.expect_value(t, plan_difference_item_text(&dialog.added[0]), edge_act)
	_, refusal, _ = plan_difference_act_open(&dialog, "assistant", "plans.apply", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.Busy)
	_, refusal, _ = test_open(&dialog, "home", "a", "", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.Busy)
}

// The act face keeps the act of the plan dialog: the focus starts on
// Refuse, an act before the arm time is no act, Enter then refuses, and a
// later plan dialog takes the face Plan again.
@(test)
plan_difference_act_face_refuses_on_the_first_enter :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	serial, _, _ := plan_difference_act_open(&dialog, "assistant", "plans.apply", 1000)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 1000 + powerbox.CONSENT_ARM_MILLISECONDS - 1), Plan_Difference_Decision.Pending)
	testing.expect(t, dialog.open)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 1000 + powerbox.CONSENT_ARM_MILLISECONDS), Plan_Difference_Decision.Refused)
	decision, known := plan_difference_decision_of_serial(&dialog, serial)
	testing.expect(t, known && decision == .Refused)
	plan_serial, _, _ := test_open(&dialog, "home", "a", "", 5000)
	testing.expect_value(t, dialog.face, Plan_Difference_Face.Plan)
	_, known = plan_difference_decision_of_serial(&dialog, serial)
	testing.expect(t, !known)
	testing.expect_value(t, plan_serial, serial + 1)
}

// The act face moves the focus only after the arm time, and each move
// starts the arm time again: Tab then Enter at once, before or after the
// first arm time, never allows; Enter after the arm time of the move does.
@(test)
plan_difference_act_face_arms_again_after_each_move_of_the_focus :: proc(t: ^testing.T) {
	ARM :: powerbox.CONSENT_ARM_MILLISECONDS
	dialog: Plan_Difference_Dialog
	plan_difference_act_open(&dialog, "assistant", "plans.apply", 1000)
	// Tab before the arm time: no move, and Enter then refuses.
	for now in ([?]u64{1000, 1000 + ARM - 1}) {
		testing.expect_value(t, plan_difference_key(&dialog, .Next, now), Plan_Difference_Decision.Pending)
		testing.expect_value(t, dialog.focus, Plan_Difference_Button.Refuse)
	}
	// Tab at the arm time moves; Enter at once, and one millisecond before
	// the new arm time, does nothing.
	moved := u64(1000 + ARM)
	testing.expect_value(t, plan_difference_key(&dialog, .Next, moved), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
	for now in ([?]u64{moved, moved + ARM - 1}) {
		testing.expect_value(t, plan_difference_key(&dialog, .Act, now), Plan_Difference_Decision.Pending)
		testing.expect(t, dialog.open)
	}
	// A second Tab within the new arm time does not move back.
	plan_difference_key(&dialog, .Next, moved + 1)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
	// After the arm time of the move, Enter allows.
	testing.expect_value(t, plan_difference_key(&dialog, .Act, moved + ARM), Plan_Difference_Decision.Accepted)
	// On the next dialog, Tab then Enter long after the show and at the
	// same time: no allow.
	plan_difference_act_open(&dialog, "assistant", "plans.apply", 10_000)
	testing.expect_value(t, plan_difference_key(&dialog, .Next, 20_000), Plan_Difference_Decision.Pending)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 20_000), Plan_Difference_Decision.Pending)
	testing.expect(t, dialog.open)
	// The plan face keeps its moves at any time.
	dialog.open = false
	test_open(&dialog, "home", "a", "", 30_000)
	plan_difference_key(&dialog, .Next, 30_000)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
}

// On the act face a press on the button with no focus moves the focus
// only, under the same arm rule; a second press after the arm time acts.
@(test)
plan_difference_act_face_press_on_the_other_button_moves_the_focus_only :: proc(t: ^testing.T) {
	ARM :: powerbox.CONSENT_ARM_MILLISECONDS
	SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM :: 1280, 32, 768
	dialog: Plan_Difference_Dialog
	plan_difference_act_open(&dialog, "assistant", "plans.apply", 1000)
	x, y, width, height := plan_difference_place(&dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM)
	accept_x, accept_y, _, _ := plan_difference_button_place(x, y, width, height, .Accept)
	press :: proc(dialog: ^Plan_Difference_Dialog, point_x, point_y: int, now: u64) -> Plan_Difference_Decision {
		return plan_difference_press(dialog, SCREEN_WIDTH, WORK_TOP, WORK_BOTTOM, point_x, point_y, now)
	}
	testing.expect_value(t, press(&dialog, accept_x + 1, accept_y + 1, 1000 + ARM - 1), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Refuse)
	testing.expect_value(t, press(&dialog, accept_x + 1, accept_y + 1, 1000 + ARM), Plan_Difference_Decision.Pending)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
	testing.expect(t, dialog.open)
	testing.expect_value(t, press(&dialog, accept_x + 1, accept_y + 1, 1000 + 2 * ARM - 1), Plan_Difference_Decision.Pending)
	testing.expect_value(t, press(&dialog, accept_x + 1, accept_y + 1, 1000 + 2 * ARM), Plan_Difference_Decision.Accepted)
}

// act_ask refuses a caller with no grant, and Busy while the grant dialog
// or a dialog of a plan shows; each refusal changes nothing.
@(test)
plan_difference_act_ask_refuses_a_caller_without_the_grant_and_a_busy_display :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	serial, refusal, _ := plan_difference_act_ask(&dialog, {}, false, "assistant", "plans.apply", 1000)
	testing.expect(t, serial == 0 && refusal == .No_Grant && !dialog.open)
	serial, refusal, _ = plan_difference_act_ask(&dialog, {allowed = true}, true, "assistant", "plans.apply", 1000)
	testing.expect(t, serial == 0 && refusal == .Busy && !dialog.open)
	test_open(&dialog, "home", "a", "", 1000)
	serial, refusal, _ = plan_difference_act_ask(&dialog, {allowed = true}, false, "assistant", "plans.apply", 1000)
	testing.expect(t, serial == 0 && refusal == .Busy && dialog.face == .Plan)
	testing.expect_value(t, dialog.serial, 1)
	dialog.open = false
	serial, refusal, _ = plan_difference_act_ask(&dialog, {allowed = true}, false, "assistant", "plans.apply", 1000)
	testing.expect(t, serial == 2 && refusal == .None && dialog.face == .Act)
}

// A poll refuses a caller with no grant and a serial under 1; a serial of
// the other face, the largest serial, and a caller that is not the asker
// of an act read unknown. The asker reads its decision last.
@(test)
plan_difference_poll_gives_a_decision_to_its_face_and_its_asker_only :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	asker := Plan_Difference_Caller{allowed = true, is_asker = true}
	other := Plan_Difference_Caller{allowed = true}
	plan_serial, _, _ := test_open(&dialog, "home", "a", "", 1000)
	_, known, refusal := plan_difference_poll(&dialog, .Act, asker, i64(plan_serial))
	testing.expect(t, !known && refusal == .None)
	plan_difference_key(&dialog, .Escape, 1000)
	act_serial, _, _ := plan_difference_act_open(&dialog, "assistant", "plans.apply", 2000)
	_, known, refusal = plan_difference_poll(&dialog, .Plan, asker, i64(act_serial))
	testing.expect(t, !known && refusal == .None)
	for serial in ([?]i64{0, -1, min(i64)}) {
		_, known, refusal = plan_difference_poll(&dialog, .Act, asker, serial)
		testing.expectf(t, !known && refusal == .Bad_Serial, "serial %d", serial)
	}
	_, known, refusal = plan_difference_poll(&dialog, .Act, asker, max(i64))
	testing.expect(t, !known && refusal == .None)
	_, known, refusal = plan_difference_poll(&dialog, .Act, {}, i64(act_serial))
	testing.expect(t, !known && refusal == .No_Grant)
	_, known, refusal = plan_difference_poll(&dialog, .Act, {is_asker = true}, i64(act_serial))
	testing.expect(t, !known && refusal == .No_Grant)
	_, known, refusal = plan_difference_poll(&dialog, .Act, other, i64(act_serial))
	testing.expect(t, !known && refusal == .None)
	decision: Plan_Difference_Decision
	decision, known, refusal = plan_difference_poll(&dialog, .Act, asker, i64(act_serial))
	testing.expect(t, known && decision == .Pending && refusal == .None)
	plan_difference_key(&dialog, .Escape, 2000)
	decision, known, _ = plan_difference_poll(&dialog, .Act, asker, i64(act_serial))
	testing.expect(t, known && decision == .Refused)
}

// act_cancel refuses a caller with no grant and a serial under 1, closes
// nothing for another caller, another serial or a dialog of a plan, and
// closes the act dialog of its asker with a refusal.
@(test)
plan_difference_act_cancel_closes_the_dialog_of_its_asker_only :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	asker := Plan_Difference_Caller{allowed = true, is_asker = true}
	plan_serial, _, _ := test_open(&dialog, "home", "a", "", 1000)
	closed, refusal := plan_difference_act_cancel(&dialog, asker, i64(plan_serial))
	testing.expect(t, !closed && refusal == .None && dialog.open)
	dialog.open = false
	serial, _, _ := plan_difference_act_open(&dialog, "assistant", "plans.apply", 2000)
	closed, refusal = plan_difference_act_cancel(&dialog, {}, i64(serial))
	testing.expect(t, !closed && refusal == .No_Grant && dialog.open)
	for bad in ([?]i64{0, -1, min(i64)}) {
		closed, refusal = plan_difference_act_cancel(&dialog, asker, bad)
		testing.expect(t, !closed && refusal == .Bad_Serial && dialog.open)
	}
	for wrong in ([?]i64{i64(serial) + 1, max(i64)}) {
		closed, refusal = plan_difference_act_cancel(&dialog, asker, wrong)
		testing.expect(t, !closed && refusal == .None && dialog.open)
	}
	closed, refusal = plan_difference_act_cancel(&dialog, {allowed = true}, i64(serial))
	testing.expect(t, !closed && refusal == .None && dialog.open)
	closed, refusal = plan_difference_act_cancel(&dialog, asker, i64(serial))
	testing.expect(t, closed && refusal == .None && !dialog.open)
	testing.expect_value(t, dialog.decision, Plan_Difference_Decision.Refused)
	closed, _ = plan_difference_act_cancel(&dialog, asker, i64(serial))
	testing.expect(t, !closed)
}

// The items of a side in the tests: past the 64 of a dialog of a fixed
// size. test_open gives the memory of two such sides.
TEST_SIDE_ITEMS :: 300
TEST_OPEN_ITEMS :: 2 * TEST_SIDE_ITEMS

test_open :: proc(dialog: ^Plan_Difference_Dialog, plan_name, added, removed: string, now_milliseconds: u64) -> (serial: u64, refusal: Plan_Difference_Refusal, argument: int) {
	items := make([]Plan_Difference_Item, TEST_OPEN_ITEMS, context.temp_allocator)
	return plan_difference_open(dialog, plan_name, added, removed, now_milliseconds, items)
}

// items_text gives a list of count distinct items that line feeds
// separate.
items_text :: proc(count: int) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< count {
		if index > 0 {
			strings.write_string(&builder, "\n")
		}
		strings.write_string(&builder, "item ")
		strings.write_int(&builder, index)
	}
	return strings.to_string(builder)
}

// A difference with more lines than the view: accept is no act until the
// view reached the last line, whatever the time; the view stays inside the
// body; each line of the body is a heading or an item, in order.
@(test)
plan_difference_accept_counts_only_after_the_last_line_showed :: proc(t: ^testing.T) {
	ARM :: powerbox.CONSENT_ARM_MILLISECONDS
	dialog: Plan_Difference_Dialog
	// A body of exactly the visible lines needs no scroll.
	test_open(&dialog, "home", items_text(PLAN_DIFFERENCE_VISIBLE_LINES - 1), "", 0)
	testing.expect(t, dialog.seen_through)
	testing.expect(t, !plan_difference_scroll(&dialog, 1))
	plan_difference_key(&dialog, .Escape, 0)

	// One line more needs one line of scroll.
	test_open(&dialog, "home", items_text(PLAN_DIFFERENCE_VISIBLE_LINES), "", 0)
	testing.expect(t, !dialog.seen_through)
	plan_difference_key(&dialog, .Next, 0)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, ARM), Plan_Difference_Decision.Pending)
	testing.expect(t, dialog.open)
	testing.expect_value(t, plan_difference_key(&dialog, .Line_Next, ARM), Plan_Difference_Decision.Pending)
	testing.expect(t, dialog.seen_through)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, ARM), Plan_Difference_Decision.Accepted)

	// The largest difference: 64 additions and 64 removals.
	test_open(&dialog, "home", items_text(TEST_SIDE_ITEMS), items_text(TEST_SIDE_ITEMS), 1000)
	body := plan_difference_body_lines(&dialog)
	testing.expect_value(t, body, 2 + 2 * TEST_SIDE_ITEMS)
	testing.expect_value(t, plan_difference_visible_lines(&dialog), PLAN_DIFFERENCE_VISIBLE_LINES)
	// The lines: the heading of the additions, the 64 items, the heading of
	// the removals, its 64 items, then no line.
	first, _ := plan_difference_line(&dialog, 0)
	testing.expect(t, first.heading && first.added)
	last_added, _ := plan_difference_line(&dialog, TEST_SIDE_ITEMS)
	testing.expect_value(t, plan_difference_item_text(last_added.item), "item 299")
	removals, _ := plan_difference_line(&dialog, TEST_SIDE_ITEMS + 1)
	testing.expect(t, removals.heading && !removals.added)
	last, last_ok := plan_difference_line(&dialog, body - 1)
	testing.expect(t, last_ok && !last.added)
	testing.expect_value(t, plan_difference_item_text(last.item), "item 299")
	_, past := plan_difference_line(&dialog, body)
	testing.expect(t, !past)

	// The view never leaves the body: up from the top, down past the end.
	testing.expect(t, !plan_difference_scroll(&dialog, -1))
	testing.expect_value(t, dialog.first_line, 0)
	plan_difference_key(&dialog, .Next, 1000)
	testing.expect_value(t, dialog.focus, Plan_Difference_Button.Accept)
	// Each page short of the end: accept is no act.
	for dialog.first_line + PLAN_DIFFERENCE_VISIBLE_LINES < body - (PLAN_DIFFERENCE_VISIBLE_LINES - 1) {
		plan_difference_key(&dialog, .Page_Next, 1000)
		testing.expect_value(t, plan_difference_key(&dialog, .Act, 1000 + ARM), Plan_Difference_Decision.Pending)
		testing.expect(t, dialog.open)
	}
	testing.expect(t, plan_difference_scroll(&dialog, max(int) / 2))
	testing.expect_value(t, dialog.first_line, body - PLAN_DIFFERENCE_VISIBLE_LINES)
	testing.expect(t, dialog.seen_through)
	// Back up: what was seen stays seen.
	plan_difference_key(&dialog, .Page_Previous, 1000)
	testing.expect(t, dialog.seen_through)
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 1000 + ARM), Plan_Difference_Decision.Accepted)
// A longer arm time of the principal delays the act; a shorter one, 0 and
// the largest value of the type change nothing below the one of the
// contract, and a time past the most of a principal holds as the most: one
// rule for each door (powerbox.consent_arm_milliseconds), with no sum that
// wraps.
@(test)
plan_difference_arm_time_of_the_principal_is_never_shorter :: proc(t: ^testing.T) {
	ARM :: powerbox.CONSENT_ARM_MILLISECONDS
	for shorter in ([?]u64{0, 1, ARM - 1}) {
		dialog: Plan_Difference_Dialog
		dialog.arm_milliseconds_of_the_principal = shorter
		_, refusal, _ := plan_difference_act_open(&dialog, "assistant", "notes.open", 1000)
		testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
		testing.expect_value(t, plan_difference_arm_milliseconds(&dialog), ARM)
		testing.expect(t, !plan_difference_armed(&dialog, 1000 + ARM - 1))
		testing.expect(t, plan_difference_armed(&dialog, 1000 + ARM))
	}
	dialog: Plan_Difference_Dialog
	dialog.arm_milliseconds_of_the_principal = 2_000
	_, refusal, _ := plan_difference_act_open(&dialog, "assistant", "notes.open", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect(t, !plan_difference_armed(&dialog, 1000 + ARM))
	testing.expect(t, !plan_difference_armed(&dialog, 2999))
	testing.expect(t, plan_difference_armed(&dialog, 3000))
	testing.expect_value(t, plan_difference_key(&dialog, .Act, 2999), Plan_Difference_Decision.Pending)
	// The largest word: the most of a principal, ten seconds, and no act
	// one millisecond before it.
	MOST :: powerbox.CONSENT_ARM_MILLISECONDS_MOST
	largest: Plan_Difference_Dialog
	largest.arm_milliseconds_of_the_principal = max(u64)
	_, refusal, _ = plan_difference_act_open(&largest, "assistant", "notes.open", 1000)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, plan_difference_arm_milliseconds(&largest), MOST)
	testing.expect(t, !plan_difference_armed(&largest, 1000 + ARM))
	testing.expect(t, !plan_difference_armed(&largest, 1000 + MOST - 1))
	testing.expect(t, plan_difference_armed(&largest, 1000 + MOST))
	testing.expect(t, plan_difference_armed(&largest, max(u64)))
	// A clock before the show is no act.
	testing.expect(t, !plan_difference_armed(&dialog, 999))
}

// An item takes a line for each 53 characters, cut at a whole character:
// a comma stays in its item, a character of two bytes is never split, and
// the lines of an item give back the item. The dialog grows with its
// lines, with no bound of lines: 32 lines are shown whole.
@(test)
plan_difference_wraps_an_item_and_counts_its_lines :: proc(t: ^testing.T) {
	dialog: Plan_Difference_Dialog
	// 53 characters of two bytes, then one: 2 lines.
	item := strings.concatenate({strings.repeat("é", PLAN_DIFFERENCE_LINE_CHARACTERS, context.temp_allocator), ",z"}, context.temp_allocator)
	_, refusal, _ := test_open(&dialog, "home", item, "", 0)
	testing.expect_value(t, refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, dialog.added_count, 1)
	testing.expect_value(t, plan_difference_side_lines(dialog.added[:1]), 2)
	first, second, third := plan_difference_item_line(&dialog.added[0], 0), plan_difference_item_line(&dialog.added[0], 1), plan_difference_item_line(&dialog.added[0], 2)
	testing.expect(t, first == strings.repeat("é", PLAN_DIFFERENCE_LINE_CHARACTERS, context.temp_allocator) && second == ",z" && third == "")
	testing.expect_value(t, strings.concatenate({first, second}, context.temp_allocator), item)
	// An item of exactly one line, and the empty line past it.
	dialog.open = false
	exact := strings.repeat("q", PLAN_DIFFERENCE_LINE_CHARACTERS, context.temp_allocator)
	test_open(&dialog, "home", exact, "", 0)
	testing.expect(t, plan_difference_side_lines(dialog.added[:1]) == 1 && plan_difference_item_line(&dialog.added[0], 0) == exact && plan_difference_item_line(&dialog.added[0], 1) == "")
	// 32 lines: 8 items of 4 lines on one side, each item whole.
	dialog.open = false
	four := strings.repeat("w", 3 * PLAN_DIFFERENCE_LINE_CHARACTERS + 1, context.temp_allocator)
	side := strings.join({four, four, four, four, four, four, four, four}, "\n", context.temp_allocator)
	_, many_refusal, _ := test_open(&dialog, "home", side, "", 0)
	testing.expect_value(t, many_refusal, Plan_Difference_Refusal.None)
	testing.expect_value(t, plan_difference_side_lines(dialog.added[:dialog.added_count]), 32)
	// The body counts each line of each item: the heading and 32 lines, of
	// which the view shows PLAN_DIFFERENCE_VISIBLE_LINES; a line of the body
	// names its item and its line inside it.
	testing.expect_value(t, plan_difference_body_lines(&dialog), 1 + 32)
	testing.expect_value(t, plan_difference_visible_lines(&dialog), PLAN_DIFFERENCE_VISIBLE_LINES)
	for at in ([?][3]int{{1, 0, 0}, {4, 0, 3}, {5, 1, 0}, {32, 7, 3}}) {
		line, line_ok := plan_difference_line(&dialog, at[0])
		testing.expect(t, line_ok && line.added && line.item == &dialog.added[at[1]] && line.item_line == at[2])
	}
	_, past_ok := plan_difference_line(&dialog, 33)
	testing.expect(t, !past_ok)
	testing.expect(t, !dialog.seen_through, "a body past the view is not seen through at the open")
}
}
