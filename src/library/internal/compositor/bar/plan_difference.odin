// The difference of a plan on the trusted display: the state of its dialog,
// its places and its acts. The compositor draws it and gives it the keys
// and the presses; the rules of the act are here, so a host test checks
// them (src/md/features/powerbox.md, "The relation to the other paths").
// A plan is applied whole: the dialog has no tick, only accept and refuse.
package bar

// The arm time: an act counts only this long after the dialog showed, so a
// key or a press meant for a window does not accept the plan.
PLAN_DIFFERENCE_ARM_MILLISECONDS :: 500
PLAN_DIFFERENCE_NAME_BYTES :: 48
PLAN_DIFFERENCE_ITEM_BYTES :: 48
// The items of one side: each fits on the reference screen with no scroll,
// so the principal never accepts a line that it did not see.
PLAN_DIFFERENCE_ITEM_CAPACITY :: 8

// The places of the dialog, in pixels.
PLAN_DIFFERENCE_WIDTH :: 480
PLAN_DIFFERENCE_TITLE_HEIGHT :: 30
PLAN_DIFFERENCE_MARGIN :: 16
PLAN_DIFFERENCE_LINE :: 20 // One item, one heading, the name of the plan.
PLAN_DIFFERENCE_GAP :: 8 // Between two parts of the body.
PLAN_DIFFERENCE_BUTTON_WIDTH :: 156
PLAN_DIFFERENCE_BUTTON_HEIGHT :: 26
PLAN_DIFFERENCE_BUTTON_GAP :: 8

// The decision of the principal.
Plan_Difference_Decision :: enum u8 {
	Pending, // The dialog shows, or none was asked.
	Accepted,
	Refused,
}

// The button that has the focus. The focus starts on Refuse: Enter at once
// refuses, and to accept the principal moves the focus first.
Plan_Difference_Button :: enum u8 {
	Refuse,
	Accept,
}

// A key that the dialog reads. The compositor gives Tab and the arrows as
// Next, Enter and Space as Act.
Plan_Difference_Key :: enum u8 {
	Other, // The dialog takes it and does nothing.
	Next, // The focus moves to the other button.
	Act, // The button that has the focus acts, after the arm time.
	Escape, // Refuses at any time: a refusal gives nothing.
}

// Why a difference is not shown.
Plan_Difference_Refusal :: enum u8 {
	None,
	Busy, // A dialog of a plan shows already.
	Empty_Name, // The plan has no name.
	Name_Too_Long, // Past PLAN_DIFFERENCE_NAME_BYTES.
	Empty_Item, // A list holds an item with no byte: two commas, or a comma at an end.
	Item_Too_Long, // An item past PLAN_DIFFERENCE_ITEM_BYTES.
	Too_Many_Items, // A side past PLAN_DIFFERENCE_ITEM_CAPACITY.
	No_Change, // Nothing added and nothing removed: nothing to accept.
}

Plan_Difference_Item :: struct {
	text:   [PLAN_DIFFERENCE_ITEM_BYTES]u8,
	length: int,
}

Plan_Difference_Dialog :: struct {
	open:                 bool,
	serial:               u64, // The number of the last dialog shown; 0 before the first.
	plan_name:            [PLAN_DIFFERENCE_NAME_BYTES]u8,
	plan_name_length:     int,
	added:                [PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item,
	added_count:          int,
	removed:              [PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item,
	removed_count:        int,
	shown_at_milliseconds: u64, // The clock of the system when the dialog showed.
	focus:                Plan_Difference_Button,
	decision:             Plan_Difference_Decision, // Of the last dialog.
}

// plan_difference_open shows the difference of a plan: its name, and the
// grants and roles that it adds and removes, each a list of names that
// commas separate, with the spaces around a name dropped. It gives the
// serial of the dialog, or 0 with the refusal and the argument that it
// names, from 1: the name, the added list, the removed list; 0 for Busy. A
// refusal changes nothing.
plan_difference_open :: proc "contextless" (dialog: ^Plan_Difference_Dialog, plan_name, added, removed: string, now_milliseconds: u64) -> (serial: u64, refusal: Plan_Difference_Refusal, argument: int) {
	if dialog.open {
		return 0, .Busy, 0
	}
	if len(plan_name) == 0 {
		return 0, .Empty_Name, 1
	}
	if len(plan_name) > PLAN_DIFFERENCE_NAME_BYTES {
		return 0, .Name_Too_Long, 1
	}
	added_items, removed_items: [PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item
	added_count, removed_count: int
	if added_count, refusal = plan_difference_items(added, &added_items); refusal != .None {
		return 0, refusal, 2
	}
	if removed_count, refusal = plan_difference_items(removed, &removed_items); refusal != .None {
		return 0, refusal, 3
	}
	if added_count == 0 && removed_count == 0 {
		return 0, .No_Change, 2
	}
	dialog.serial += 1
	dialog.open = true
	copy(dialog.plan_name[:], plan_name)
	dialog.plan_name_length = len(plan_name)
	dialog.added, dialog.added_count = added_items, added_count
	dialog.removed, dialog.removed_count = removed_items, removed_count
	dialog.shown_at_milliseconds = now_milliseconds
	dialog.focus = .Refuse
	dialog.decision = .Pending
	return dialog.serial, .None, 0
}

// plan_difference_items splits a list of names. An empty list has no item.
@(private = "file")
plan_difference_items :: proc "contextless" (list: string, items: ^[PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item) -> (count: int, refusal: Plan_Difference_Refusal) {
	if len(plan_difference_trim(list)) == 0 {
		return 0, .None
	}
	start := 0
	for index in 0 ..= len(list) {
		if index < len(list) && list[index] != ',' {
			continue
		}
		item := plan_difference_trim(list[start:index])
		start = index + 1
		switch {
		case len(item) == 0:
			return 0, .Empty_Item
		case len(item) > PLAN_DIFFERENCE_ITEM_BYTES:
			return 0, .Item_Too_Long
		case count >= PLAN_DIFFERENCE_ITEM_CAPACITY:
			return 0, .Too_Many_Items
		}
		copy(items[count].text[:], item)
		items[count].length = len(item)
		count += 1
	}
	return count, .None
}

@(private = "file")
plan_difference_trim :: proc "contextless" (text: string) -> string {
	first, last := 0, len(text)
	for first < last && text[first] == ' ' {
		first += 1
	}
	for last > first && text[last - 1] == ' ' {
		last -= 1
	}
	return text[first:last]
}

// plan_difference_name gives the name of the plan of the dialog.
plan_difference_name :: proc "contextless" (dialog: ^Plan_Difference_Dialog) -> string {
	return string(dialog.plan_name[:dialog.plan_name_length])
}

// plan_difference_item_text gives the text of an item.
plan_difference_item_text :: proc "contextless" (item: ^Plan_Difference_Item) -> string {
	return string(item.text[:item.length])
}

// plan_difference_armed reports whether an act counts at a time.
plan_difference_armed :: proc "contextless" (dialog: ^Plan_Difference_Dialog, now_milliseconds: u64) -> bool {
	return dialog.open && now_milliseconds >= dialog.shown_at_milliseconds + PLAN_DIFFERENCE_ARM_MILLISECONDS
}

// plan_difference_decide closes the dialog with a decision.
@(private = "file")
plan_difference_decide :: proc "contextless" (dialog: ^Plan_Difference_Dialog, decision: Plan_Difference_Decision) -> Plan_Difference_Decision {
	dialog.open = false
	dialog.decision = decision
	return decision
}

// plan_difference_key gives a key to the dialog, and gives the decision
// that it made, or Pending.
plan_difference_key :: proc "contextless" (dialog: ^Plan_Difference_Dialog, key: Plan_Difference_Key, now_milliseconds: u64) -> Plan_Difference_Decision {
	if !dialog.open {
		return .Pending
	}
	switch key {
	case .Other:
	case .Next:
		dialog.focus = dialog.focus == .Refuse ? .Accept : .Refuse
	case .Escape:
		return plan_difference_decide(dialog, .Refused)
	case .Act:
		if !plan_difference_armed(dialog, now_milliseconds) {
			return .Pending
		}
		switch dialog.focus {
		case .Refuse:
			return plan_difference_decide(dialog, .Refused)
		case .Accept:
			return plan_difference_decide(dialog, .Accepted)
		}
	}
	return .Pending
}

// plan_difference_place gives the place of the dialog: in the middle of
// the width of the screen, and between the top and the foot of the room
// of the windows, so it never covers the bar.
plan_difference_place :: proc "contextless" (dialog: ^Plan_Difference_Dialog, screen_width, work_top, work_bottom: int) -> (x, y, width, height: int) {
	width = PLAN_DIFFERENCE_WIDTH
	// The title plate, the name of the plan, each side with its heading,
	// then the buttons.
	height = 2 + PLAN_DIFFERENCE_TITLE_HEIGHT + 1 + PLAN_DIFFERENCE_MARGIN + PLAN_DIFFERENCE_LINE
	if dialog.added_count > 0 {
		height += PLAN_DIFFERENCE_GAP + (1 + dialog.added_count) * PLAN_DIFFERENCE_LINE
	}
	if dialog.removed_count > 0 {
		height += PLAN_DIFFERENCE_GAP + (1 + dialog.removed_count) * PLAN_DIFFERENCE_LINE
	}
	height += PLAN_DIFFERENCE_MARGIN + PLAN_DIFFERENCE_BUTTON_HEIGHT + PLAN_DIFFERENCE_MARGIN
	x = max(0, (screen_width - width) / 2)
	y = max(work_top + PLAN_DIFFERENCE_MARGIN, work_top + (work_bottom - work_top - height) / 2)
	return x, y, width, height
}

// plan_difference_button_place gives the place of a button of a dialog at
// (x, y, width, height): both at the foot, at the right, Refuse last.
plan_difference_button_place :: proc "contextless" (x, y, width, height: int, button: Plan_Difference_Button) -> (button_x, button_y, button_width, button_height: int) {
	button_y = y + height - PLAN_DIFFERENCE_MARGIN - PLAN_DIFFERENCE_BUTTON_HEIGHT
	refuse_x := x + width - PLAN_DIFFERENCE_MARGIN - PLAN_DIFFERENCE_BUTTON_WIDTH
	switch button {
	case .Refuse:
		button_x = refuse_x
	case .Accept:
		button_x = refuse_x - PLAN_DIFFERENCE_BUTTON_GAP - PLAN_DIFFERENCE_BUTTON_WIDTH
	}
	return button_x, button_y, PLAN_DIFFERENCE_BUTTON_WIDTH, PLAN_DIFFERENCE_BUTTON_HEIGHT
}

// plan_difference_press gives a press of the pointer to the dialog, and
// gives the decision that it made, or Pending. The dialog takes each press
// while it shows: a press outside it reaches no window. A press on a
// button gives it the focus, and acts after the arm time.
plan_difference_press :: proc "contextless" (dialog: ^Plan_Difference_Dialog, screen_width, work_top, work_bottom, point_x, point_y: int, now_milliseconds: u64) -> Plan_Difference_Decision {
	if !dialog.open {
		return .Pending
	}
	x, y, width, height := plan_difference_place(dialog, screen_width, work_top, work_bottom)
	for button in Plan_Difference_Button {
		button_x, button_y, button_width, button_height := plan_difference_button_place(x, y, width, height, button)
		if !inside(point_x, point_y, button_x, button_y, button_width, button_height) {
			continue
		}
		dialog.focus = button
		return plan_difference_key(dialog, .Act, now_milliseconds)
	}
	return .Pending
}
