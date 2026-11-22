#+build !freestanding
package settings_process

import "base:intrinsics"
import "core:testing"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:interface"
import "modus:layout"

// The test runs on the host: the module links src/library/modus/system,
// whose call of an export is an entry of the machine that the host does
// not have. No test here calls an export; a call stops the test.
@(export, link_name = "export_call")
host_export_call :: proc "c" (address: uintptr, integers, floats, results: rawptr) {intrinsics.trap()}

@(private = "file")
area_inside :: proc(inner, outer: interface.Area) -> bool {
	return inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
}

@(private = "file")
areas_apart :: proc(first, second: interface.Area) -> bool {
	return first.x + first.width <= second.x || second.x + second.width <= first.x || first.y + first.height <= second.y || second.y + second.height <= first.y
}

// The content of a card: inside its margins, under its title.
@(private = "file")
card_content :: proc(card: interface.Area) -> interface.Area {
	return {card.x + MARGIN, card.y, card.width - 2 * MARGIN, card.height}
}
@(private = "file")
MARGIN :: 16

// The layout refuses each size that no tree takes, and gives no place.
@(test)
settings_layout_refuses_each_size_out_of_range :: proc(t: ^testing.T) {
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	table: interface.Draw_Table
	texts: Frame_Texts
	frame_texts_of(&texts, settings.choice_default())
	for size in ([][2]int{{0, HEIGHT}, {WIDTH, 0}, {-1, HEIGHT}, {WIDTH, -1}, {layout.LENGTH_LIMIT + 1, HEIGHT}, {WIDTH, layout.LENGTH_LIMIT + 1}, {min(int), min(int)}, {max(int), max(int)}}) {
		boxes, ok := settings_layout(&table, &texts, size[0], size[1], 0, tokens)
		testing.expectf(t, !ok, "the size %v was taken", size)
		testing.expect(t, boxes == {}, "a refusal gave places")
	}
}

// At each width from the least to the largest, and at the least and the
// largest height: each value button lies inside the content of its card,
// as wide as its label with its padding, apart from each other button;
// the cards are apart; the action bar spans the foot of the window; a
// content taller than the view has the scroll bar. A language list with
// the most languages makes the section Region and language its tallest.
@(test)
settings_layout_fits_each_size :: proc(t: ^testing.T) {
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	table: interface.Draw_Table
	testing.expect_value(t, int(tokens.margin), MARGIN)
	full := settings.choice_default()
	for language in common_languages[:settings.LANGUAGE_LIST_CAPACITY - 1] {
		texts: Frame_Texts
		frame_texts_of(&texts, full)
		for added, index in texts.added {
			if common_languages[index].tag == language.tag && texts.can_add[index] {
				full.languages = added
			}
		}
	}
	testing.expect_value(t, int(full.languages.count), len(common_languages))
	choices := [?]settings.Choice{settings.choice_default(), full}
	heights := [?]int{LEAST_HEIGHT, HEIGHT, LARGEST_HEIGHT}
	for choice in choices {
		texts: Frame_Texts
		frame_texts_of(&texts, choice)
		for width := LEAST_WIDTH; width <= LARGEST_WIDTH; width += 1 {
			for height in heights {
				boxes, ok := settings_layout(&table, &texts, width, height, 0, tokens)
				if !ok {
					testing.expectf(t, false, "the size %dx%d gave no layout", width, height)
					return
				}
				tree := &layout_tree
				bar := area_of(tree, boxes.action_bar)
				testing.expectf(t, bar == interface.Area{0, height - interface.ACTION_BAR_ROW_HEIGHT, width, interface.ACTION_BAR_ROW_HEIGHT}, "at %dx%d the action bar is %v", width, height, bar)
				view := area_of(tree, boxes.view)
				if boxes.content_height > view.height {
					testing.expectf(t, boxes.scroll_bar != layout.NO_BOX, "at %dx%d the content of %d lines has no scroll bar in a view of %d", width, height, boxes.content_height, view.height)
				}
				buttons: [64]interface.Area
				button_count := 0
				for section in Section {
					card := area_of(tree, boxes.cards[section])
					testing.expectf(t, card.x >= view.x && card.x + card.width <= view.x + view.width, "at %dx%d the card %v is out of the view", width, height, section)
					for other in Section {
						if other != section {
							testing.expectf(t, areas_apart(card, area_of(tree, boxes.cards[other])), "at %dx%d the cards %v and %v overlap", width, height, section, other)
						}
					}
					content := card_content(card)
					for setting in settings_of_section(section) {
						for place in 0 ..< int(settings.descriptions[setting].value_count) {
							index := boxes.setting_boxes[setting].values[place]
							if setting == .Scale {
								testing.expect(t, index == layout.NO_BOX)
								continue
							}
							area := area_of(tree, index)
							label := setting_texts[setting].value_labels[place]
							testing.expectf(t, area_inside(area, content), "at %dx%d the button %s %v is out of the card %v", width, height, label, area, content)
							testing.expectf(t, area.width >= button_width(&table, label), "at %dx%d the button %s is cut", width, height, label)
							buttons[button_count] = area
							button_count += 1
						}
					}
				}
				for index in 0 ..< len(common_languages) {
					if texts.can_add[index] {
						area := area_of(tree, boxes.add_buttons[index])
						testing.expectf(t, area_inside(area, card_content(area_of(tree, boxes.cards[.Region_And_Language]))), "at %dx%d the language %s is out of its card", width, height, common_languages[index].name)
						buttons[button_count] = area
						button_count += 1
					}
				}
				track := area_of(tree, boxes.scale_track)
				testing.expectf(t, scale_stop_width(track.width) >= 8, "at %dx%d the stops of the scale are thinner than 8 pixels", width, height)
				// Each stop holds its percentage whole, or the scale in force
				// has its own box beside the track.
				if boxes.scale_value == layout.NO_BOX {
					for label in setting_texts[.Scale].value_labels[:len(scale_factor.Scale)] {
						testing.expectf(t, scale_stop_width(track.width) >= button_width(&table, label), "at %dx%d the label %s is cut in its stop", width, height, label)
					}
				}
				for first in 0 ..< button_count {
					for second in first + 1 ..< button_count {
						testing.expectf(t, areas_apart(buttons[first], buttons[second]), "at %dx%d two buttons overlap: %v and %v", width, height, buttons[first], buttons[second])
					}
				}
				if t.error_count > 0 {
					return
				}
			}
		}
	}
}

// The view scrolls to the foot of the content and no further, and a
// scroll before the top is refused by the tree builder: it clamps to 0.
@(test)
settings_layout_scrolls_inside_the_content :: proc(t: ^testing.T) {
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	table: interface.Draw_Table
	texts: Frame_Texts
	frame_texts_of(&texts, settings.choice_default())
	boxes, ok := settings_layout(&table, &texts, LEAST_WIDTH, LEAST_HEIGHT, 0, tokens)
	testing.expect(t, ok)
	view := area_of(&layout_tree, boxes.view)
	testing.expect(t, boxes.scroll_bar != layout.NO_BOX && boxes.content_height > view.height)
	for scroll in ([?]int{-1, min(int), boxes.content_height, boxes.content_height + 1, layout.LENGTH_LIMIT + 1, max(int)}) {
		scrolled, scrolled_ok := settings_layout(&table, &texts, LEAST_WIDTH, LEAST_HEIGHT, scroll, tokens)
		testing.expect(t, scrolled_ok)
		testing.expectf(t, scrolled.scroll >= 0 && scrolled.scroll <= boxes.content_height - view.height, "the scroll %d gave the first line %d", scroll, scrolled.scroll)
	}
}

// Each value of each setting has a label, and no two buttons or stops of
// the window have one label: a machine test presses an element by it.
@(test)
settings_labels_are_whole_and_distinct :: proc(t: ^testing.T) {
	labels: [96]string
	count := 0
	for setting in settings.Setting {
		for place in 0 ..< int(settings.descriptions[setting].value_count) {
			label := setting_texts[setting].value_labels[place]
			testing.expectf(t, label != "", "the value %d of %v has no label", place, setting)
			labels[count] = label
			count += 1
		}
		testing.expectf(t, setting_texts[setting].title != "" && setting_texts[setting].explanation != "", "the setting %v has no title or no line", setting)
	}
	testing.expect_value(t, int(settings.descriptions[.Scale].value_count), len(scale_factor.Scale))
	for language in common_languages {
		labels[count] = language.name
		count += 1
	}
	for label in ([?]string{LANGUAGE_UP, LANGUAGE_REMOVE}) {
		labels[count] = label
		count += 1
	}
	for first in 0 ..< count {
		for second in first + 1 ..< count {
			testing.expectf(t, labels[first] != labels[second], "two elements have the label %s", labels[first])
		}
	}
}

// The zones of the list are the offsets that the contract takes, in their
// order, each one time. The zone in force is the chosen line; a zone that
// the table does not hold is the first line, and is chosen.
@(test)
settings_zone_list :: proc(t: ^testing.T) {
	for place, index in zone_places {
		testing.expectf(t, settings.zone_offset_minutes_valid(place.minutes) == place.minutes, "the zone %d is not one that the contract takes", place.minutes)
		testing.expectf(t, index == 0 || zone_places[index - 1].minutes < place.minutes, "the zone %d is out of order", place.minutes)
	}
	testing.expect_value(t, zone_places[0].minutes, settings.ZONE_OFFSET_MINUTES_LEAST)
	testing.expect_value(t, zone_places[len(zone_places) - 1].minutes, settings.ZONE_OFFSET_MINUTES_MOST)
	choice := settings.choice_default()
	for zone in ([?]i32{settings.ZONE_OFFSET_MINUTES_LEAST, 0, 330, settings.ZONE_OFFSET_MINUTES_MOST}) {
		choice.zone_offset_minutes = zone
		texts: Frame_Texts
		frame_texts_of(&texts, choice)
		testing.expect(t, !texts.zone_first_extra)
		testing.expect_value(t, texts.zone_line_count, len(zone_places))
		testing.expect_value(t, zone_places[texts.zone_chosen].minutes, zone)
	}
	// +08:15 is a zone that the contract takes and the earth does not use.
	choice.zone_offset_minutes = 495
	texts: Frame_Texts
	frame_texts_of(&texts, choice)
	testing.expect(t, texts.zone_first_extra)
	testing.expect_value(t, texts.zone_chosen, 0)
	testing.expect_value(t, texts.zone_lines[0], "UTC+08:15")
	testing.expect_value(t, texts.zone_line_count, len(zone_places) + 1)
	testing.expect_value(t, texts.zone_lines[1], "UTC-12:00  Baker Island")
}
