#+build !freestanding
package bar

import "core:testing"
import "modus:calendar"
import "modus:interface"

@(private = "file")
SCREEN_WIDTHS_OF_TEST := [?]int{1920, 1280, 1024}
@(private = "file")
SCREEN_HEIGHT_OF_TEST :: 1080
@(private = "file")
TRAY_WIDGETS_WITH_CARD := [?]Tray_Widget{.Control_Center, .Notifications, .Calendar}

@(private = "file")
Box :: struct {
	x, y, width, height: int,
}

@(private = "file")
box_of :: proc(x, y, width, height: int) -> Box {
	return {x, y, width, height}
}

@(private = "file")
boxes_meet :: proc(first, second: Box) -> bool {
	return first.x < second.x + second.width && second.x < first.x + first.width && first.y < second.y + second.height && second.y < first.y + first.height
}

@(private = "file")
box_holds :: proc(outer, inner: Box) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

// A word that names no widget is refused at the border; each member comes
// back from its own word.
@(test)
a_word_that_names_no_tray_widget_is_refused :: proc(t: ^testing.T) {
	for word in ([?]u64{4, 5, 255, 256, 1 << 32, max(u64) - 1, max(u64)}) {
		widget, ok := tray_widget_of_word(word)
		testing.expectf(t, !ok && widget == .None, "the word %v is refused", word)
	}
	for widget in Tray_Widget {
		back, ok := tray_widget_of_word(u64(widget))
		testing.expectf(t, ok && back == widget, "the word of %v gives it back", widget)
	}
	testing.expect_value(t, u64(Tray_Widget.None), 0)
	testing.expect_value(t, u64(Tray_Widget.Control_Center), 1)
	testing.expect_value(t, u64(Tray_Widget.Notifications), 2)
	testing.expect_value(t, u64(Tray_Widget.Calendar), 3)
}

// The two buttons and the clock stay in the band of the pills at each
// edge, never meet, keep room for the outline of the focus between them,
// leave the hairline of the clock alone, and the clock plate holds the
// whole text of the clock.
@(test)
the_tray_buttons_keep_apart_and_in_the_bar :: proc(t: ^testing.T) {
	testing.expect(t, TRAY_BUTTON_GAP >= interface.FOCUS_RING_WIDTH)
	for edge in Edge {
		for screen_width in SCREEN_WIDTHS_OF_TEST {
			layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
			bar_top := top(layout)
			hairline := tray_right(screen_width) + TRAY_CLOCK_GAP / 2
			boxes: [3]Box
			for widget, index in TRAY_WIDGETS_WITH_CARD {
				boxes[index] = box_of(tray_widget_button(layout, screen_width, widget))
				box := boxes[index]
				testing.expectf(t, box.y == bar_top + TRAY_Y && box.height == TRAY_HEIGHT, "%v %v at %v: %v leaves the band of the pills", edge, screen_width, widget, box)
				testing.expectf(t, box.x + box.width < screen_width, "%v: %v leaves the screen", widget, box)
				ring := interface.focus_ring_area({box.x, box.y, box.width, box.height})
				testing.expectf(t, ring.y >= bar_top && ring.y + ring.height <= bar_top + HEIGHT, "%v: the outline of the focus leaves the bar", widget)
				// The hairline is outside each button.
				testing.expectf(t, hairline < box.x || hairline >= box.x + box.width, "%v covers the hairline", widget)
			}
			testing.expect(t, !boxes_meet(boxes[0], boxes[1]) && !boxes_meet(boxes[1], boxes[2]) && !boxes_meet(boxes[0], boxes[2]))
			// The outline of the focus of one button never covers the next.
			testing.expect(t, boxes[0].x + boxes[0].width + interface.FOCUS_RING_WIDTH <= boxes[1].x)
			// The order from the left: the control center, the bell, the clock.
			testing.expect(t, boxes[0].x < boxes[1].x && boxes[1].x < hairline && hairline < boxes[2].x)
			clock := boxes[2]
			testing.expect(t, clock.x <= clock_x(screen_width) && clock.x + clock.width >= clock_x(screen_width) + CLOCK_WIDTH)
			testing.expect_value(t, tray_buttons_left(screen_width), boxes[0].x)
			// None has no place.
			_, _, none_width, _ := tray_widget_button(layout, screen_width, .None)
			testing.expect_value(t, none_width, 0)
		}
	}
	// The clock keeps its place: 16 pixels from the right edge.
	testing.expect_value(t, clock_x(1920), 1920 - 152 - 16)
}

// A press finds the button that the eye sees: the middle of each, and
// nothing in the gap, on the hairline, over or under the band, or one
// pixel past an edge.
@(test)
a_press_finds_the_tray_button_under_it :: proc(t: ^testing.T) {
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		for widget in TRAY_WIDGETS_WITH_CARD {
			x, y, width, height := tray_widget_button(layout, 1920, widget)
			testing.expect_value(t, tray_widget_button_at(layout, 1920, x + width / 2, y + height / 2), widget)
			testing.expect_value(t, tray_widget_button_at(layout, 1920, x, y), widget)
			testing.expect_value(t, tray_widget_button_at(layout, 1920, x + width - 1, y + height - 1), widget)
			testing.expect_value(t, tray_widget_button_at(layout, 1920, x + width / 2, y - 1), Tray_Widget.None)
			testing.expect_value(t, tray_widget_button_at(layout, 1920, x + width / 2, y + height), Tray_Widget.None)
		}
		control_x, control_y, control_width, _ := tray_widget_button(layout, 1920, .Control_Center)
		testing.expect_value(t, tray_widget_button_at(layout, 1920, control_x + control_width, control_y + 4), Tray_Widget.None) // The gap.
		testing.expect_value(t, tray_widget_button_at(layout, 1920, control_x - 1, control_y + 4), Tray_Widget.None)
		testing.expect_value(t, tray_widget_button_at(layout, 1920, tray_right(1920) + TRAY_CLOCK_GAP / 2, control_y + 4), Tray_Widget.None) // The hairline.
		testing.expect_value(t, tray_widget_button_at(layout, 1920, -1, -1), Tray_Widget.None)
		testing.expect_value(t, tray_widget_button_at(layout, 1920, max(int) / 2, control_y + 4), Tray_Widget.None)
	}
}

// The marks of the assistive holders, the mark of a viewer and the pills
// (the EN of the locale) are laid out from the left of the buttons: none
// of them meets a button, and a reference screen keeps room for them after
// the first window plate.
@(test)
the_marks_of_the_tray_end_before_the_tray_buttons :: proc(t: ^testing.T) {
	BADGE_GAP :: 4 // The gap of the compositor between two parts of the tray.
	right := tray_buttons_left(1920) - BADGE_GAP
	registry: Assistive_Registry
	_, refusal := assistive_attach(&registry, "orca", .Screen_Reader)
	testing.expect_value(t, refusal, Assistive_Attach_Refusal.None)
	_, refusal = assistive_attach(&registry, "zoom", .Magnifier)
	testing.expect_value(t, refusal, Assistive_Attach_Refusal.None)
	widths: [ASSISTIVE_HOLDER_LIMIT]int
	for &width in widths {
		width = 120
	}
	marks := assistive_marks_place(&registry, widths, right, PLATES_X + PLATE_WIDTH + 16)
	testing.expect_value(t, marks.count, 2)
	for mark in marks.marks[:marks.count] {
		testing.expectf(t, mark.x + mark.width <= right && !mark.square, "a mark %v reaches the buttons", mark)
	}
	// A mark of a viewer of the widest text and the pill EN still fit after
	// the first plate of a reference screen.
	testing.expect(t, right - 2 * 120 - 2 * PADDING > PLATES_X + PLATE_WIDTH + 16)
}

// The card of each widget opens away from the bar edge, ends on the right
// edge of its button, and stays inside the screen with its margin, also on
// a screen narrower than the card.
@(test)
the_cards_open_away_from_the_bar_edge :: proc(t: ^testing.T) {
	for edge in Edge {
		for screen_width in SCREEN_WIDTHS_OF_TEST {
			layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
			for widget in TRAY_WIDGETS_WITH_CARD {
				for count in ([?]int{0, 1, NOTIFICATION_HISTORY_CAPACITY}) {
					x, y, width, height := tray_card(layout, screen_width, widget, count)
					switch edge {
					case .Top:
						testing.expectf(t, y == HEIGHT, "%v under a bar at the top starts at %d", widget, y)
					case .Bottom:
						testing.expectf(t, y + height == top(layout), "%v over a bar at the bottom ends at %d", widget, y + height)
					}
					testing.expect(t, x >= TRAY_CARD_MARGIN && x + width <= screen_width - TRAY_CARD_MARGIN)
					button_x, _, button_width, _ := tray_widget_button(layout, screen_width, widget)
					testing.expectf(t, x + width == button_x + button_width || x == TRAY_CARD_MARGIN || x + width == screen_width - TRAY_CARD_MARGIN, "%v is not on its button", widget)
				}
			}
		}
	}
	// A screen narrower than the card keeps its left edge on the margin.
	x, _, _, _ := tray_card({}, 200, .Control_Center, 0)
	testing.expect_value(t, x, TRAY_CARD_MARGIN)
	// None has no card.
	_, _, width, _ := tray_card({}, 1920, .None, 0)
	testing.expect_value(t, width, 0)
	testing.expect(t, !tray_card_inside({}, 1920, .None, 0, 1000, 100))
}

// The card of the notifications grows with the history, up to its
// capacity; a negative count is the empty card.
@(test)
the_notification_card_grows_with_the_history :: proc(t: ^testing.T) {
	_, empty := tray_card_size(.Notifications, 0)
	_, negative := tray_card_size(.Notifications, -3)
	_, one := tray_card_size(.Notifications, 1)
	_, full := tray_card_size(.Notifications, NOTIFICATION_HISTORY_CAPACITY)
	_, past := tray_card_size(.Notifications, NOTIFICATION_HISTORY_CAPACITY + 1)
	_, largest := tray_card_size(.Notifications, max(int))
	testing.expect_value(t, negative, empty)
	testing.expect_value(t, one, 2 * BORDER + NOTIFICATION_HEAD_HEIGHT + NOTIFICATION_ROW_HEIGHT)
	testing.expect_value(t, past, full)
	testing.expect_value(t, largest, full)
	testing.expect(t, empty < one && one < full)
	// Each row is inside the card, under the head, and the rows never meet.
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		card := box_of(tray_card(layout, 1920, .Notifications, 3))
		for index in 0 ..< 3 {
			x, y, width, height, ok := notification_row(layout, 1920, 3, index)
			testing.expect(t, ok && box_holds(card, {x, y, width, height}))
			testing.expect(t, y >= card.y + BORDER + NOTIFICATION_HEAD_HEIGHT)
		}
		for index in ([?]int{-1, 3, NOTIFICATION_HISTORY_CAPACITY, max(int)}) {
			_, _, _, _, ok := notification_row(layout, 1920, 3, index)
			testing.expectf(t, !ok, "the row %d of a history of 3 has no place", index)
		}
		_, _, _, _, ok := notification_row(layout, 1920, 0, 0)
		testing.expect(t, !ok)
	}
}

// The tiles and the launch buttons lie inside the control center, never
// meet, and the launch buttons are under its groove. A press finds a part
// that acts; a tile that says a state takes none; a part of another card is
// never found.
@(test)
the_parts_of_the_control_center_are_where_the_eye_sees_them :: proc(t: ^testing.T) {
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		card := box_of(tray_card(layout, 1920, .Control_Center, 0))
		groove := control_center_hairline_y(card.y)
		parts: [dynamic]Box
		defer delete(parts)
		for part in Tray_Part {
			if tray_part_widget(part) != .Control_Center {
				continue
			}
			x, y, width, height, ok := tray_part_place(layout, 1920, part, 0)
			box := Box{x, y, width, height}
			testing.expectf(t, ok && box_holds(card, box), "%v leaves the card: %v in %v", part, box, card)
			for other in parts {
				testing.expectf(t, !boxes_meet(box, other), "%v meets another part", part)
			}
			append(&parts, box)
			switch part {
			case .Launch_Settings, .Launch_Monitor, .Launch_Browser, .Launch_Edit:
				testing.expect(t, y > groove + 1)
			case .Appearance_Tile, .Bar_Edge_Tile, .Magnifier_Tile, .Display_Tile:
				testing.expect(t, y + height < groove)
			case .None, .Clear_All:
			}
			found := tray_part_at(layout, 1920, .Control_Center, 0, x + width / 2, y + height / 2)
			testing.expect_value(t, found, tray_part_takes_press(part) ? part : Tray_Part.None)
			// The same point with the card of another widget finds nothing.
			testing.expect_value(t, tray_part_at(layout, 1920, .Calendar, 0, x + width / 2, y + height / 2), Tray_Part.None)
			testing.expect_value(t, tray_part_at(layout, 1920, .None, 0, x + width / 2, y + height / 2), Tray_Part.None)
		}
		testing.expect_value(t, len(parts), 8)
		// The gap between two tiles is no part.
		x, y, width, _, _ := tray_part_place(layout, 1920, .Appearance_Tile, 0)
		testing.expect_value(t, tray_part_at(layout, 1920, .Control_Center, 0, x + width, y + 4), Tray_Part.None)
	}
	_, _, _, _, ok := tray_part_place({}, 1920, .None, 0)
	testing.expect(t, !ok)
	for part in Tray_Part {
		module, label := tray_part_module(part)
		launches := part == .Launch_Settings || part == .Launch_Monitor || part == .Launch_Browser || part == .Launch_Edit
		testing.expectf(t, (module != "") == launches && (label != "") == launches, "%v and its module", part)
		testing.expectf(t, tray_part_closes_card(part) == launches, "%v and the close of its card", part)
	}
	testing.expect(t, !tray_part_takes_press(.Appearance_Tile) && !tray_part_takes_press(.Display_Tile) && !tray_part_takes_press(.None))
}

// The button Clear all has a place only with a history, in the head of
// the card.
@(test)
clear_all_is_in_the_head_of_a_history_only :: proc(t: ^testing.T) {
	for count in ([?]int{0, -1, min(int)}) {
		_, _, _, _, ok := tray_part_place({}, 1920, .Clear_All, count)
		testing.expectf(t, !ok, "Clear all with %d notifications", count)
	}
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		card := box_of(tray_card(layout, 1920, .Notifications, 2))
		x, y, width, height, ok := tray_part_place(layout, 1920, .Clear_All, 2)
		testing.expect(t, ok && box_holds(card, {x, y, width, height}))
		testing.expect(t, y + height <= card.y + BORDER + NOTIFICATION_HEAD_HEIGHT)
		testing.expect_value(t, tray_part_at(layout, 1920, .Notifications, 2, x + 1, y + 1), Tray_Part.Clear_All)
		testing.expect_value(t, tray_part_at(layout, 1920, .Notifications, 0, x + 1, y + 1), Tray_Part.None)
	}
}

// The keys walk the parts that act, around the ends; a card with none,
// and the calendar, give None.
@(test)
the_keys_walk_the_parts_of_a_card :: proc(t: ^testing.T) {
	testing.expect_value(t, tray_part_step(.None, 0, .None, true), Tray_Part.None)
	testing.expect_value(t, tray_part_step(.Calendar, 3, .None, true), Tray_Part.None)
	testing.expect_value(t, tray_part_step(.Notifications, 0, .None, true), Tray_Part.None)
	testing.expect_value(t, tray_part_step(.Notifications, -1, .Clear_All, false), Tray_Part.None)
	testing.expect_value(t, tray_part_step(.Notifications, 1, .None, true), Tray_Part.Clear_All)
	testing.expect_value(t, tray_part_step(.Notifications, 1, .Clear_All, false), Tray_Part.Clear_All)
	testing.expect_value(t, tray_part_step(.Control_Center, 0, .None, true), Tray_Part.Bar_Edge_Tile)
	testing.expect_value(t, tray_part_step(.Control_Center, 0, .None, false), Tray_Part.Launch_Edit)
	testing.expect_value(t, tray_part_step(.Control_Center, 0, .Launch_Edit, true), Tray_Part.Bar_Edge_Tile)
	testing.expect_value(t, tray_part_step(.Control_Center, 0, .Bar_Edge_Tile, false), Tray_Part.Launch_Edit)
	// A part that takes no press, or of another card, starts at an end.
	testing.expect_value(t, tray_part_step(.Control_Center, 0, .Appearance_Tile, true), Tray_Part.Bar_Edge_Tile)
	testing.expect_value(t, tray_part_step(.Control_Center, 0, .Clear_All, false), Tray_Part.Launch_Edit)
	// A whole round reaches each part that acts once.
	part := Tray_Part.None
	seen: [Tray_Part]int
	for _ in 0 ..< len(CONTROL_CENTER_PARTS_IN_ORDER) {
		part = tray_part_step(.Control_Center, 0, part, true)
		testing.expect(t, tray_part_takes_press(part) && tray_part_widget(part) == .Control_Center)
		seen[part] += 1
	}
	for count, seen_part in seen {
		testing.expectf(t, count == (tray_part_takes_press(seen_part) && tray_part_widget(seen_part) == .Control_Center ? 1 : 0), "%v seen %d times", seen_part, count)
	}
}

// The press: a button opens its card and closes another; the same button
// closes it; a press outside closes it and is taken; a press on the card
// away from its parts keeps it; a tile keeps it, a launch closes it; with
// no card, a press elsewhere is not taken.
@(test)
a_press_opens_and_closes_one_card_at_a_time :: proc(t: ^testing.T) {
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		center :: proc(layout: Layout, widget: Tray_Widget) -> (int, int) {
			x, y, width, height := tray_widget_button(layout, 1920, widget)
			return x + width / 2, y + height / 2
		}
		state: Tray_State
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, 500, 500), Tray_Press{})
		testing.expect_value(t, state.open, Tray_Widget.None)
		x, y := center(layout, .Control_Center)
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, x, y), Tray_Press{kind = .Opened, widget = .Control_Center})
		testing.expect_value(t, state.open, Tray_Widget.Control_Center)
		x, y = center(layout, .Calendar)
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, x, y), Tray_Press{kind = .Opened, widget = .Calendar})
		testing.expect_value(t, state.open, Tray_Widget.Calendar)
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, x, y), Tray_Press{kind = .Closed, widget = .Calendar})
		testing.expect_value(t, state.open, Tray_Widget.None)
		// A press on the card away from its parts keeps it.
		x, y = center(layout, .Control_Center)
		tray_press(&state, layout, 1920, 0, x, y)
		card_x, card_y, _, _ := tray_card(layout, 1920, .Control_Center, 0)
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, card_x + 1, card_y + 1), Tray_Press{kind = .Kept_Open, widget = .Control_Center})
		// A tile keeps the card open; a launch button closes it.
		tile_x, tile_y, _, _, _ := tray_part_place(layout, 1920, .Magnifier_Tile, 0)
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, tile_x + 2, tile_y + 2), Tray_Press{kind = .Part_Pressed, widget = .Control_Center, part = .Magnifier_Tile})
		testing.expect_value(t, state.open, Tray_Widget.Control_Center)
		launch_x, launch_y, _, _, _ := tray_part_place(layout, 1920, .Launch_Browser, 0)
		testing.expect_value(t, tray_press(&state, layout, 1920, 0, launch_x + 2, launch_y + 2), Tray_Press{kind = .Part_Pressed, widget = .Control_Center, part = .Launch_Browser})
		testing.expect_value(t, state.open, Tray_Widget.None)
		// A press outside an open card closes it, and is taken.
		x, y = center(layout, .Notifications)
		tray_press(&state, layout, 1920, 2, x, y)
		testing.expect_value(t, tray_press(&state, layout, 1920, 2, 10, 500), Tray_Press{kind = .Closed, widget = .Notifications})
		testing.expect_value(t, state, Tray_State{})
	}
}

// The pointer lights one button and one part, and says what changed.
@(test)
the_pointer_lights_the_button_and_the_part_under_it :: proc(t: ^testing.T) {
	state: Tray_State
	x, y, _, _ := tray_widget_button({}, 1920, .Notifications)
	button_changed, part_changed := tray_pointer_move(&state, {}, 1920, 0, x + 1, y + 1)
	testing.expect(t, button_changed && !part_changed && state.hovered == .Notifications)
	button_changed, part_changed = tray_pointer_move(&state, {}, 1920, 0, x + 2, y + 2)
	testing.expect(t, !button_changed && !part_changed)
	testing.expect(t, tray_open(&state, .Control_Center))
	testing.expect(t, !tray_open(&state, .Control_Center))
	tile_x, tile_y, _, _, _ := tray_part_place({}, 1920, .Bar_Edge_Tile, 0)
	button_changed, part_changed = tray_pointer_move(&state, {}, 1920, 0, tile_x + 1, tile_y + 1)
	testing.expect(t, button_changed && part_changed && state.hovered == .None && state.chosen == .Bar_Edge_Tile)
	// A tile that says a state is never lit.
	tile_x, tile_y, _, _, _ = tray_part_place({}, 1920, .Display_Tile, 0)
	_, part_changed = tray_pointer_move(&state, {}, 1920, 0, tile_x + 1, tile_y + 1)
	testing.expect(t, part_changed && state.chosen == .None)
	testing.expect(t, tray_open(&state, .None) && state.open == .None)
}

// The history keeps the newest first, drops the oldest past its capacity,
// refuses an empty title with no change, and cuts a long text on a
// character.
@(test)
the_history_of_the_notifications_keeps_the_newest :: proc(t: ^testing.T) {
	history: Notification_History
	testing.expect(t, !notification_history_add(&history, "", "a body", 10, true))
	testing.expect_value(t, history.count, 0)
	testing.expect(t, !notification_history_clear(&history))
	titles := [?]string{"one", "two", "three", "four", "five", "six", "seven"}
	for title, index in titles {
		testing.expect(t, notification_history_add(&history, title, "", i64(index), true))
	}
	testing.expect_value(t, history.count, NOTIFICATION_HISTORY_CAPACITY)
	testing.expect_value(t, notification_title(&history.records[0]), "seven")
	testing.expect_value(t, notification_title(&history.records[NOTIFICATION_HISTORY_CAPACITY - 1]), "two")
	// An empty title on a full history changes nothing.
	testing.expect(t, !notification_history_add(&history, "", "", 0, true))
	testing.expect_value(t, notification_title(&history.records[0]), "seven")
	testing.expect(t, notification_history_clear(&history))
	testing.expect_value(t, history.count, 0)
	// The bound, one past it, and a two-byte character across it.
	exact := "123456789012345678901234567890123456789012345678"
	testing.expect_value(t, len(exact), NOTIFICATION_TITLE_BYTES)
	notification_history_add(&history, exact, "", 0, true)
	testing.expect_value(t, notification_title(&history.records[0]), exact)
	notification_history_add(&history, "123456789012345678901234567890123456789012345678X", "", 0, true)
	testing.expect_value(t, notification_title(&history.records[0]), exact)
	across := "12345678901234567890123456789012345678901234567\u00E9"
	testing.expect_value(t, len(across), NOTIFICATION_TITLE_BYTES + 1)
	notification_history_add(&history, across, "", 0, true)
	testing.expect_value(t, notification_title(&history.records[0]), "12345678901234567890123456789012345678901234567")
	long_body: [NOTIFICATION_BODY_BYTES + 20]u8
	for &byte in long_body {
		byte = 'b'
	}
	notification_history_add(&history, "title", string(long_body[:]), 0, true)
	testing.expect_value(t, len(notification_body(&history.records[0])), NOTIFICATION_BODY_BYTES)
	testing.expect_value(t, notification_body(&history.records[1]), "")
}

// The time of a record: the local time of day with a date, the time since
// the boot without, a time before 1970, and the largest values.
@(test)
the_time_of_a_notification_is_its_time_of_day :: proc(t: ^testing.T) {
	buffer: [8]u8
	record := Notification_Record{seconds = calendar.days_from_civil(2026, 11, 22) * calendar.SECONDS_IN_A_DAY + 16 * 3600 + 30 * 60 + 59, dated = true}
	testing.expect_value(t, notification_time_text(&record, &buffer), "16:30")
	record = {seconds = 0, dated = true}
	testing.expect_value(t, notification_time_text(&record, &buffer), "00:00")
	record = {seconds = -60, dated = true} // 1969-12-31 23:59.
	testing.expect_value(t, notification_time_text(&record, &buffer), "23:59")
	record = {seconds = max(i64), dated = true}
	text := notification_time_text(&record, &buffer)
	testing.expect(t, len(text) == 5 && text[2] == ':' && text[0] <= '2')
	record = {seconds = 3 * 3600 + 7 * 60, dated = false}
	testing.expect_value(t, notification_time_text(&record, &buffer), "03:07")
	record = {seconds = 500 * 3600, dated = false}
	testing.expect_value(t, notification_time_text(&record, &buffer), "99:00")
	record = {seconds = -5, dated = false}
	testing.expect_value(t, notification_time_text(&record, &buffer), "00:00")
}

@(private = "file")
noon_of :: proc(year: i64, month, day: int) -> i64 {
	return calendar.days_from_civil(year, month, day) * calendar.SECONDS_IN_A_DAY + 12 * 3600
}

// The months of each length, a leap February and the years that are not
// leap by the rule of 100, and the column of the first day.
@(test)
the_month_has_its_length_and_its_first_weekday :: proc(t: ^testing.T) {
	cases := [?]struct {
		year:         i64,
		month, day:   int,
		days, column: int,
	}{
		{2026, 11, 22, 30, 6}, // 2026-11-01 was a Sunday.
		{2026, 1, 1, 31, 3}, // A Thursday.
		{2026, 2, 28, 28, 6}, // A Sunday.
		{2024, 2, 29, 29, 3}, // A leap year: a Thursday.
		{2023, 2, 1, 28, 2}, // A Wednesday.
		{2000, 2, 15, 29, 1}, // Leap by the rule of 400: a Tuesday.
		{2100, 2, 15, 28, 0}, // Not leap by the rule of 100: a Monday.
		{1970, 1, 1, 31, 3}, // Day 0, a Thursday.
		{2026, 3, 31, 31, 6}, // 31 days from a Sunday: the sixth row.
	}
	for item in cases {
		month := calendar_month_of(noon_of(item.year, item.month, item.day))
		testing.expectf(t, month.year == item.year && month.month == item.month && month.today == item.day, "%v-%v-%v: %v", item.year, item.month, item.day, month)
		testing.expectf(t, month.days == item.days, "%v-%v has %d days, not %d", item.year, item.month, item.days, month.days)
		testing.expectf(t, month.first_column == item.column, "%v-%v starts in the column %d, not %d", item.year, item.month, item.column, month.first_column)
		// Each day of the month is in the grid once, in order.
		next := 1
		for row in 0 ..< CALENDAR_ROWS {
			for column in 0 ..< CALENDAR_COLUMNS {
				day, in_month := calendar_cell(month, row, column)
				testing.expect(t, day >= 1 && day <= 31)
				if in_month {
					testing.expectf(t, day == next, "%v-%v: the cell %d,%d has %d, not %d", item.year, item.month, row, column, day, next)
					next += 1
				}
			}
		}
		testing.expectf(t, next == month.days + 1, "%v-%v shows %d days", item.year, item.month, next - 1)
		row, column := calendar_today_cell(month)
		day, in_month := calendar_cell(month, row, column)
		testing.expect(t, in_month && day == item.day)
	}
	// One second before 1970: the last day of December 1969, a Wednesday.
	month := calendar_month_of(-1)
	testing.expect(t, month.year == 1969 && month.month == 12 && month.today == 31 && month.first_column == 0)
}

// The cells before the first day have the last days of the month before,
// over the end of a year; the cells after the last day start the next
// month at 1; a cell outside the grid has no day.
@(test)
the_cells_around_a_month_belong_to_its_neighbours :: proc(t: ^testing.T) {
	november := calendar_month_of(noon_of(2026, 11, 22))
	day, in_month := calendar_cell(november, 0, 0)
	testing.expect(t, day == 26 && !in_month) // 2026-10-26.
	day, in_month = calendar_cell(november, 0, 6)
	testing.expect(t, day == 1 && in_month)
	day, in_month = calendar_cell(november, 5, 0)
	testing.expect(t, day == 30 && in_month)
	day, in_month = calendar_cell(november, 5, 1)
	testing.expect(t, day == 1 && !in_month)
	day, in_month = calendar_cell(november, 5, 6)
	testing.expect(t, day == 6 && !in_month)
	january := calendar_month_of(noon_of(2026, 1, 10))
	day, in_month = calendar_cell(january, 0, 0)
	testing.expect(t, day == 29 && !in_month) // 2025-12-29.
	march := calendar_month_of(noon_of(2024, 3, 1)) // After a leap February.
	day, in_month = calendar_cell(march, 0, 0)
	testing.expect(t, day == 26 && !in_month)
	for cell in ([?][2]int{{-1, 0}, {0, -1}, {CALENDAR_ROWS, 0}, {0, CALENDAR_COLUMNS}, {max(int), max(int)}, {min(int), 0}}) {
		day, in_month = calendar_cell(november, cell[0], cell[1])
		testing.expectf(t, day == 0 && !in_month, "the cell %v is outside the grid", cell)
		_, _, _, _, ok := calendar_cell_place({}, 1920, cell[0], cell[1])
		testing.expect(t, !ok)
	}
	today_row, today_column := calendar_today_cell(november)
	testing.expect(t, today_row == 3 && today_column == 6)
}

// The title names the month and the year.
@(test)
the_calendar_title_names_the_month :: proc(t: ^testing.T) {
	buffer: [32]u8
	testing.expect_value(t, calendar_title(calendar_month_of(noon_of(2026, 11, 22)), &buffer), "November 2026")
	testing.expect_value(t, calendar_title(calendar_month_of(noon_of(2024, 2, 29)), &buffer), "February 2024")
	testing.expect_value(t, calendar_title(calendar_month_of(0), &buffer), "January 1970")
	testing.expect_value(t, calendar_title({year = -44, month = 3}, &buffer), "March -44")
	testing.expect_value(t, calendar_title({year = 0, month = 99}, &buffer), "December 0")
	longest := calendar_title({year = min(i64) + 1, month = 9}, &buffer)
	testing.expect(t, len(longest) <= len(buffer) && longest[:10] == "September ")
}

// The grid lies inside the card under its head, each cell inside the grid,
// and the foot inside the card, at each edge.
@(test)
the_calendar_grid_fits_its_card :: proc(t: ^testing.T) {
	for edge in Edge {
		layout := placed({}, edge, SCREEN_HEIGHT_OF_TEST)
		card := box_of(tray_card(layout, 1920, .Calendar, 0))
		grid := box_of(calendar_grid(layout, 1920))
		testing.expect(t, box_holds(card, grid))
		testing.expect(t, grid.y >= card.y + BORDER + CALENDAR_PADDING + CALENDAR_HEAD_HEIGHT + CALENDAR_WEEKDAY_HEIGHT)
		testing.expect_value(t, card.y + card.height - BORDER, grid.y + grid.height + CALENDAR_FOOT_HEIGHT)
		for row in 0 ..< CALENDAR_ROWS {
			for column in 0 ..< CALENDAR_COLUMNS {
				x, y, width, height, ok := calendar_cell_place(layout, 1920, row, column)
				testing.expect(t, ok && box_holds(grid, {x, y, width, height}))
			}
		}
	}
}
