// The difference of a plan on the trusted display: the state of its dialog,
// its places and its acts. The compositor draws it and gives it the keys
// and the presses; the rules of the act are here, so a host test checks
// them (src/md/features/powerbox.md, "The relation to the other paths").
// A plan is applied whole: the dialog has no tick, only accept and refuse.
package bar

import pr "modus:contract/plans_recipes"
import "modus:contract/powerbox"
import "modus:contract/text_encoding"

// The bounds of the contract of a plan: one fact in one place.
PLAN_DIFFERENCE_NAME_BYTES :: pr.PLAN_DISPLAY_NAME_BYTES
PLAN_DIFFERENCE_ITEM_BYTES :: pr.PLAN_DISPLAY_ITEM_BYTES
// The items of one side. An item is cut into lines of
// PLAN_DIFFERENCE_LINE_CHARACTERS characters, never cut short, and the
// dialog grows with its lines.
PLAN_DIFFERENCE_ITEM_CAPACITY :: pr.PLAN_DISPLAY_ITEM_CAPACITY
PLAN_DIFFERENCE_LINE_CHARACTERS :: pr.PLAN_DISPLAY_LINE_CHARACTERS

// Merge note, work/limits_paging_and_sync. That branch rewrote this dialog:
// any count of items in memory that the caller of plan_difference_open
// gives, a body that scrolls past PLAN_DIFFERENCE_VISIBLE_LINES, an accept
// that counts only once seen_through, and the two sides read on the worker
// of the compositor from a memory object (plan_difference_read, its
// Plan_Difference_Source and Plan_Difference_Memory). Its item is one line
// of 48 bytes, and its lists split at a comma. At the merge, keep that
// paging and that worker, and keep the item of this branch:
//
// 1. The item: PLAN_DIFFERENCE_ITEM_BYTES is pr.PLAN_DISPLAY_ITEM_BYTES,
//    384 bytes. plan_difference_items splits at the line feed
//    (pr.PLAN_DISPLAY_ITEM_SEPARATOR), not at a comma, and refuses an item
//    that text_encoding.text_valid refuses with Item_Not_Text, one item at
//    a time: plan_difference_read reads the sides through it, so a
//    difference from a memory object keeps the same border.
// 2. The lines: plan_difference_body_lines counts each item as
//    pr.plan_display_item_lines of its text, not as 1, and
//    plan_difference_line gives the item and the line inside it
//    (a field item_line, from 0) of a line of the body; the draw writes
//    plan_difference_item_line(item, item_line) in the font of the cells.
//    seen_through, the scroll bounds and the height of the view then count
//    the wrapped lines, so an accept counts only once the last line of the
//    last item showed. plan_difference_side_lines and the height of
//    plan_difference_place of this branch leave: the view of that branch
//    gives the height.
// 3. The memory: an item takes size_of(Plan_Difference_Item), 392 bytes, so
//    the arena of the difference that the worker takes from is sized by
//    plan_difference_items_needed times that size.
// 4. The list of plans_core (display_lists_of_difference of that branch,
//    with its DISPLAY_LIST_ITEM_MOST) joins its items with
//    pr.PLAN_DISPLAY_ITEM_SEPARATOR, writes a text value in quotes, and
//    DISPLAY_LIST_ITEM_MOST becomes pr.PLAN_DISPLAY_ITEM_BYTES +
//    len(pr.PLAN_DISPLAY_ITEM_SEPARATOR). No bound of lines is kept: the
//    count of the items is the bound of that branch.

// The places of the dialog, in pixels.
PLAN_DIFFERENCE_WIDTH :: 480
PLAN_DIFFERENCE_TITLE_HEIGHT :: 30
PLAN_DIFFERENCE_MARGIN :: 16
PLAN_DIFFERENCE_LINE :: 20 // One item, one heading, the name of the plan.
PLAN_DIFFERENCE_GAP :: 8 // Between two parts of the body.
PLAN_DIFFERENCE_BUTTON_WIDTH :: 156
PLAN_DIFFERENCE_BUTTON_HEIGHT :: 26
PLAN_DIFFERENCE_BUTTON_GAP :: 8

// What the dialog asks the principal to decide. The same state, keys and
// arm time serve both, so the act dialog keeps each rule of the plan
// dialog (src/md/features/assistant.md, "The act dialog").
Plan_Difference_Face :: enum u8 {
	Plan, // The difference of a plan: its name, what it adds and removes.
	Act, // One act of an agent: the asker, and the act as service.export.
}

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
	Item_Not_Text, // An item that is not UTF-8, or holds a control byte: the lines of the dialog would not be the item.
	No_Change, // Nothing added and nothing removed: nothing to accept.
	Not_A_Name, // The asker of an act is not an identifier: a name of a process.
	Not_An_Act, // The act is not two identifiers with a period between them.
	No_Grant, // The caller may not ask for a dialog of this face: no connection, or a grant that names no asker.
	Bad_Serial, // A serial under 1: no dialog has it.
}

// The facts of the connection of a call that the compositor reads, for a
// dialog of one face.
Plan_Difference_Caller :: struct {
	allowed:  bool, // The grant of the connection lets it ask for the dialog of the face; false with no connection where the face needs one.
	is_asker: bool, // It is the connection that asked for the last dialog, and it lasts.
}

Plan_Difference_Item :: struct {
	text:   [PLAN_DIFFERENCE_ITEM_BYTES]u8,
	length: int,
}

Plan_Difference_Dialog :: struct {
	open:                 bool,
	face:                 Plan_Difference_Face, // Of the dialog that shows, or of the last one.
	serial:               u64, // The number of the last dialog shown; 0 before the first.
	plan_name:            [PLAN_DIFFERENCE_NAME_BYTES]u8,
	plan_name_length:     int,
	added:                [PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item,
	added_count:          int,
	removed:              [PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item,
	removed_count:        int,
	shown_at_milliseconds: u64, // The clock of the system when the dialog showed.
	armed_from_milliseconds: u64, // An act counts from this time on: the show, plus the arm time; on the act face, the last move of the focus too.
	arm_milliseconds_of_the_principal: u64, // A longer arm time that the principal chose; under the one of the contract it changes nothing.
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
	dialog.face = .Plan
	copy(dialog.plan_name[:], plan_name)
	dialog.plan_name_length = len(plan_name)
	dialog.added, dialog.added_count = added_items, added_count
	dialog.removed, dialog.removed_count = removed_items, removed_count
	dialog.shown_at_milliseconds = now_milliseconds
	dialog.armed_from_milliseconds = now_milliseconds
	dialog.focus = .Refuse
	dialog.decision = .Pending
	return dialog.serial, .None, 0
}

// plan_difference_act_open shows one act of an agent: the asker, the name
// of the calling process, which the compositor reads from the connection,
// and the act, `service.export`. Both are identifiers that the dialog
// checks: no word of the agent reaches the trusted display. It gives the
// serial, or 0 with the refusal and the argument that it names, from 1:
// the asker, the act; 0 for Busy. A refusal changes nothing.
plan_difference_act_open :: proc "contextless" (dialog: ^Plan_Difference_Dialog, asker, act: string, now_milliseconds: u64) -> (serial: u64, refusal: Plan_Difference_Refusal, argument: int) {
	if dialog.open {
		return 0, .Busy, 0
	}
	if len(asker) > PLAN_DIFFERENCE_NAME_BYTES || !identifier_valid(asker) {
		return 0, .Not_A_Name, 1
	}
	period := -1
	for character, index in transmute([]u8)act {
		if character == '.' {
			period = index
			break
		}
	}
	if len(act) > PLAN_DIFFERENCE_ITEM_BYTES || period < 0 || !identifier_valid(act[:period]) || !identifier_valid(act[period + 1:]) {
		return 0, .Not_An_Act, 2
	}
	dialog.serial += 1
	dialog.open = true
	dialog.face = .Act
	copy(dialog.plan_name[:], asker)
	dialog.plan_name_length = len(asker)
	dialog.added = {}
	copy(dialog.added[0].text[:], act)
	dialog.added[0].length = len(act)
	dialog.added_count = 1
	dialog.removed_count = 0
	dialog.shown_at_milliseconds = now_milliseconds
	dialog.armed_from_milliseconds = now_milliseconds
	dialog.focus = .Refuse
	dialog.decision = .Pending
	return dialog.serial, .None, 0
}

// identifier_valid says if a text is an identifier of the system: 1 or more
// bytes, a lowercase letter first, then lowercase letters, digits and `_`.
@(private = "file")
identifier_valid :: proc "contextless" (text: string) -> bool {
	if len(text) == 0 || text[0] < 'a' || text[0] > 'z' {
		return false
	}
	for character in transmute([]u8)text {
		letter := character >= 'a' && character <= 'z'
		digit := character >= '0' && character <= '9'
		if !letter && !digit && character != '_' {
			return false
		}
	}
	return true
}

// plan_difference_items splits a list of items, which a line feed separates
// (pr.PLAN_DISPLAY_ITEM_SEPARATOR): an item can hold a comma. An empty list
// has no item. An item is text with no control byte.
@(private = "file")
plan_difference_items :: proc "contextless" (list: string, items: ^[PLAN_DIFFERENCE_ITEM_CAPACITY]Plan_Difference_Item) -> (count: int, refusal: Plan_Difference_Refusal) {
	if len(plan_difference_trim(list)) == 0 {
		return 0, .None
	}
	start := 0
	for index in 0 ..= len(list) {
		if index < len(list) && list[index] != '\n' {
			continue
		}
		// text_valid refuses a control character and a sequence that is not
		// UTF-8: the line feeds are between the items, never in one.
		if !text_encoding.text_valid(transmute([]u8)list[start:index]) {
			return 0, .Item_Not_Text
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

// plan_difference_side_lines gives the lines of the items of one side.
plan_difference_side_lines :: proc "contextless" (items: []Plan_Difference_Item) -> int {
	lines := 0
	for &item in items {
		lines += pr.plan_display_item_lines(plan_difference_item_text(&item))
	}
	return lines
}

// plan_difference_item_line gives the line of an item from 0: at most
// PLAN_DIFFERENCE_LINE_CHARACTERS whole characters. The dialog draws each
// line of each item, so no item is cut short.
plan_difference_item_line :: proc "contextless" (item: ^Plan_Difference_Item, line: int) -> string {
	text := plan_difference_item_text(item)
	start, characters := 0, 0
	for index in 0 ..< len(text) {
		if text[index] & 0xC0 == 0x80 {
			continue
		}
		if characters == line * PLAN_DIFFERENCE_LINE_CHARACTERS {
			start = index
		}
		if characters == (line + 1) * PLAN_DIFFERENCE_LINE_CHARACTERS {
			return text[start:index]
		}
		characters += 1
	}
	if characters <= line * PLAN_DIFFERENCE_LINE_CHARACTERS {
		return ""
	}
	return text[start:]
}

// plan_difference_item_text gives the text of an item.
plan_difference_item_text :: proc "contextless" (item: ^Plan_Difference_Item) -> string {
	return string(item.text[:item.length])
}

// plan_difference_armed reports whether an act counts at a time: the arm
// time after the show, and on the act face after the last move of the
// focus too.
plan_difference_armed :: proc "contextless" (dialog: ^Plan_Difference_Dialog, now_milliseconds: u64) -> bool {
	// A difference, not a sum: a large arm time never wraps to an early act.
	return dialog.open && now_milliseconds >= dialog.armed_from_milliseconds && now_milliseconds - dialog.armed_from_milliseconds >= plan_difference_arm_milliseconds(dialog)
}

// plan_difference_arm_milliseconds gives the arm time of the dialog: the
// longer one that the principal chose, never one shorter than the one of the
// contract, whatever the field holds.
plan_difference_arm_milliseconds :: proc "contextless" (dialog: ^Plan_Difference_Dialog) -> u64 {
	return max(dialog.arm_milliseconds_of_the_principal, powerbox.CONSENT_ARM_MILLISECONDS)
}

// plan_difference_focus_move gives the focus to a button. On the act face
// a move counts only after the arm time, and starts the arm time again: a
// Tab and an Enter typed for a window at once never allow an act, so the
// principal sees the focus on Allow for the whole arm time before Enter
// counts. The plan face moves at any time, as the grant dialog.
@(private = "file")
plan_difference_focus_move :: proc "contextless" (dialog: ^Plan_Difference_Dialog, button: Plan_Difference_Button, now_milliseconds: u64) {
	if dialog.focus == button {
		return
	}
	switch dialog.face {
	case .Plan:
		dialog.focus = button
	case .Act:
		if !plan_difference_armed(dialog, now_milliseconds) {
			return
		}
		dialog.focus = button
		dialog.armed_from_milliseconds = now_milliseconds
	}
}

// plan_difference_decide closes the dialog with a decision.
@(private = "file")
plan_difference_decide :: proc "contextless" (dialog: ^Plan_Difference_Dialog, decision: Plan_Difference_Decision) -> Plan_Difference_Decision {
	dialog.open = false
	dialog.decision = decision
	return decision
}

// plan_difference_decision_of_serial gives the decision of the dialog that
// showed with serial: Pending while it shows. known is false for a serial
// that is not the last one shown, as the dialog keeps the decision of the
// last dialog only: a later dialog replaced it, or no dialog had it.
plan_difference_decision_of_serial :: proc "contextless" (dialog: ^Plan_Difference_Dialog, serial: u64) -> (decision: Plan_Difference_Decision, known: bool) {
	if serial == 0 || serial != dialog.serial {
		return .Pending, false
	}
	if dialog.open {
		return .Pending, true
	}
	return dialog.decision, true
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
		plan_difference_focus_move(dialog, dialog.focus == .Refuse ? .Accept : .Refuse, now_milliseconds)
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
		height += PLAN_DIFFERENCE_GAP + (1 + plan_difference_side_lines(dialog.added[:dialog.added_count])) * PLAN_DIFFERENCE_LINE
	}
	if dialog.removed_count > 0 {
		height += PLAN_DIFFERENCE_GAP + (1 + plan_difference_side_lines(dialog.removed[:dialog.removed_count])) * PLAN_DIFFERENCE_LINE
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
// button gives it the focus, and acts after the arm time. On the act face
// a press on the button that has no focus moves the focus only
// (plan_difference_focus_move): a second press after the arm time acts.
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
		switch dialog.face {
		case .Plan:
			dialog.focus = button
		case .Act:
			if dialog.focus != button {
				plan_difference_focus_move(dialog, button, now_milliseconds)
				return .Pending
			}
		}
		return plan_difference_key(dialog, .Act, now_milliseconds)
	}
	return .Pending
}

// plan_difference_act_ask shows one act of an agent for a caller: it
// refuses a caller that may not ask (No_Grant), and Busy while the grant
// dialog shows (grant_dialog_open) or a dialog of this state shows. Each
// other refusal is the one of plan_difference_act_open.
plan_difference_act_ask :: proc "contextless" (dialog: ^Plan_Difference_Dialog, caller: Plan_Difference_Caller, grant_dialog_open: bool, asker, act: string, now_milliseconds: u64) -> (serial: u64, refusal: Plan_Difference_Refusal, argument: int) {
	if !caller.allowed {
		return 0, .No_Grant, 0
	}
	if grant_dialog_open {
		return 0, .Busy, 0
	}
	return plan_difference_act_open(dialog, asker, act, now_milliseconds)
}

// plan_difference_poll gives the decision of the dialog of a face with a
// serial, for a caller: Pending while it shows. known is false for a
// serial that is not the last dialog, for the last dialog when it has the
// other face, and on the act face for a caller that is not its asker: a
// decision on an act goes to the one that asked. A caller that may not
// ask is refused with No_Grant, a serial under 1 with Bad_Serial.
plan_difference_poll :: proc "contextless" (dialog: ^Plan_Difference_Dialog, face: Plan_Difference_Face, caller: Plan_Difference_Caller, serial: i64) -> (decision: Plan_Difference_Decision, known: bool, refusal: Plan_Difference_Refusal) {
	if !caller.allowed {
		return .Pending, false, .No_Grant
	}
	if serial < 1 {
		return .Pending, false, .Bad_Serial
	}
	decision, known = plan_difference_decision_of_serial(dialog, u64(serial))
	if !known || dialog.face != face {
		return .Pending, false, .None
	}
	switch face {
	case .Plan:
	case .Act:
		if !caller.is_asker {
			return .Pending, false, .None
		}
	}
	return decision, true, .None
}

// plan_difference_act_cancel closes the act dialog with a serial with a
// refusal, for its asker only: the agent withdrew the act, and the
// principal never decides an act that its asker no longer shows. closed is
// false, with no refusal, when no act dialog of the caller with that serial
// shows.
plan_difference_act_cancel :: proc "contextless" (dialog: ^Plan_Difference_Dialog, caller: Plan_Difference_Caller, serial: i64) -> (closed: bool, refusal: Plan_Difference_Refusal) {
	if !caller.allowed {
		return false, .No_Grant
	}
	if serial < 1 {
		return false, .Bad_Serial
	}
	if !dialog.open || dialog.face != .Act || u64(serial) != dialog.serial || !caller.is_asker {
		return false, .None
	}
	plan_difference_decide(dialog, .Refused)
	return true, .None
}
