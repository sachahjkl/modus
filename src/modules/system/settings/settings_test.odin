#+build !freestanding
package settings_process

import "base:intrinsics"
import "core:sync"
import "core:testing"
import "modus:contract/chosen_values"
import "modus:contract/isolated"
import "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:contract/scale_factor"
import "modus:contract/settings"
import "modus:graphics"
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
// The layout of the window is one tree of the process (layout_tree): the
// process lays out on one thread. The test runner runs the tests on several
// threads, so each test that lays out holds this lock; two tests that built
// the tree at once saw a layout of the other and failed one run in a few.
@(private = "file")
layout_tree_lock: sync.Mutex

@(private = "file")
@(deferred_none = layout_tree_end)
layout_tree_begin :: proc() {
	sync.mutex_lock(&layout_tree_lock)
}

@(private = "file")
layout_tree_end :: proc() {
	sync.mutex_unlock(&layout_tree_lock)
}

@(test)
settings_layout_refuses_each_size_out_of_range :: proc(t: ^testing.T) {
	layout_tree_begin()
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
	layout_tree_begin()
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
				footer := area_of(tree, boxes.footer)
				testing.expectf(t, footer == interface.Area{0, height - STATUS_FOOTER_HEIGHT, width, STATUS_FOOTER_HEIGHT}, "at %dx%d the footer is %v", width, height, footer)
				testing.expect(t, boxes.has_sidebar == (width >= SIDEBAR_MIN_WIDTH))
				if boxes.has_sidebar {
					sb := area_of(tree, boxes.sidebar)
					testing.expectf(t, sb.x == 0 && sb.width == SIDEBAR_WIDTH, "at %dx%d sidebar is %v", width, height, sb)
				} else {
					nav := area_of(tree, boxes.compact_nav)
					testing.expectf(t, nav.x == 0 && nav.y == 0 && nav.width == width && nav.height == COMPACT_NAV_HEIGHT, "at %dx%d compact nav is %v", width, height, nav)
				}
				view := area_of(tree, boxes.view)
				if boxes.content_height > view.height {
					testing.expectf(t, boxes.scroll_bar != layout.NO_BOX, "at %dx%d the content of %d lines has no scroll bar in a view of %d", width, height, boxes.content_height, view.height)
				}
				controls: [64]interface.Area
				control_count := 0
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
						index := boxes.setting_boxes[setting].control
						if setting == .Scale {
							testing.expect(t, index == layout.NO_BOX)
							continue
						}
						area := area_of(tree, index)
						testing.expectf(t, area_inside(area, content), "at %dx%d the control %v %v is out of the card %v", width, height, setting, area, content)
						controls[control_count] = area
						control_count += 1
					}
				}
				for index in 0 ..< len(common_languages) {
					if texts.can_add[index] {
						area := area_of(tree, boxes.add_buttons[index])
						testing.expectf(t, area_inside(area, card_content(area_of(tree, boxes.cards[.Region_And_Language]))), "at %dx%d the language %s is out of its card", width, height, common_languages[index].name)
						controls[control_count] = area
						control_count += 1
					}
				}
				track := area_of(tree, boxes.scale_track)
				testing.expectf(t, scale_stop_width(track.width) >= 8, "at %dx%d the stops of the scale are thinner than 8 pixels", width, height)
				// Each stop holds its short label whole, or the scale in force
				// has its own box beside the track.
				if boxes.scale_value == layout.NO_BOX {
					for label in SCALE_STOP_LABELS {
						testing.expectf(t, scale_stop_width(track.width) >= interface.text_measured_width(&table, interface.FONT_INTERFACE, label) + 2 * SCALE_STOP_LABEL_PADDING, "at %dx%d the label %s is cut in its stop", width, height, label)
					}
				}
				for first in 0 ..< control_count {
					for second in first + 1 ..< control_count {
						testing.expectf(t, areas_apart(controls[first], controls[second]), "at %dx%d two controls overlap: %v and %v", width, height, controls[first], controls[second])
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
	layout_tree_begin()
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
// The notice of the windows that declined the scale: none for 0 and for a
// count under 0; one window and many; the largest count is written whole,
// with the end of its sentence. In the layout it lies inside the card
// Display, under the track, at the least and at the largest width.
// A change is kept in the store first: a refused keep leaves the page as
// it was and fails; a kept one goes to the page; a change of nothing
// writes nothing and holds, kept or not.
// The short labels of the stops: one for each member of the scale, each
// the percent of its member rounded half up, and no two alike.
@(test)
settings_stop_labels_are_the_percents :: proc(t: ^testing.T) {
	for member, place in scale_factor.Scale {
		// Tenths of a percent: 8 eighths are 1000.
		percent := (int(member) * 1000 / scale_factor.EIGHTHS_OF_ONE + 5) / 10
		digits: [3]u8 = {u8('0' + percent / 100), u8('0' + percent / 10 % 10), u8('0' + percent % 10)}
		testing.expectf(t, SCALE_STOP_LABELS[place] == string(digits[:]), "the stop %v says %s, not %d", member, SCALE_STOP_LABELS[place], percent)
		for other in SCALE_STOP_LABELS[place + 1:] {
			testing.expect(t, other != SCALE_STOP_LABELS[place])
		}
	}
}

@(test)
settings_change_goes_to_the_page_only_when_kept :: proc(t: ^testing.T) {
	testing.expect_value(t, change_decision(false, .Refused), Change_Decision{write_page = false, kept = false})
	testing.expect_value(t, change_decision(false, .Kept_In_Store), Change_Decision{write_page = true, kept = true})
	testing.expect_value(t, change_decision(false, .Kept_In_Session), Change_Decision{write_page = true, kept = true})
	testing.expect_value(t, change_decision(true, .Refused), Change_Decision{write_page = false, kept = true})
	testing.expect_value(t, change_decision(true, .Kept_In_Store), Change_Decision{write_page = false, kept = true})
	testing.expect_value(t, change_decision(true, .Kept_In_Session), Change_Decision{write_page = false, kept = true})
}

@(test)
settings_keep_without_store_updates_session_state :: proc(t: ^testing.T) {
	has_store = false
	page = nil
	kept_plan = {}
	kept_record_length = 0
	kept_record_readable = false
	kept_languages_found = false
	testing.expect_value(t, kept_load(), Kept_Load.No_Store)
	next := kept_choice
	next.appearance = .Light
	next.scale = .Twelve_Eighths
	given: settings.Given
	given.values[.Appearance] = true
	given.values[.Scale] = true
	testing.expect_value(t, keep(next, 60, given), Keep_Result.Kept_In_Session)
	testing.expect_value(t, kept_choice.appearance, settings.Appearance.Light)
	testing.expect_value(t, kept_choice.scale, scale_factor.Scale.Twelve_Eighths)
	testing.expect_value(t, kept_zone_offset_minutes, i32(60))
}

@(test)
settings_declined_notice :: proc(t: ^testing.T) {
	layout_tree_begin()
	buffer: [DECLINED_NOTICE_BYTES]u8
	testing.expect_value(t, declined_notice_write(buffer[:], 0), "")
	testing.expect_value(t, declined_notice_write(buffer[:], -1), "")
	testing.expect_value(t, declined_notice_write(buffer[:], min(int)), "")
	one := declined_notice_write(buffer[:], 1)
	testing.expectf(t, len(one) > 2 && one[:2] == "1 " && one[len(one) - 9:] == "it again.", "the notice of one window: %s", one)
	ENDING :: "shows it again."
	for count in ([?]int{2, 64, max(int)}) {
		notice := declined_notice_write(buffer[:], count)
		testing.expectf(t, len(notice) >= len(ENDING) && notice[len(notice) - len(ENDING):] == ENDING, "the notice of %d windows is cut: %s", count, notice)
	}
	tokens, _ := layout.tokens_for(.Dark, .Standard)
	table: interface.Draw_Table
	for width in ([?]int{LEAST_WIDTH, LARGEST_WIDTH}) {
		texts: Frame_Texts
		frame_texts_of(&texts, settings.choice_default(), 3)
		boxes, ok := settings_layout(&table, &texts, width, LARGEST_HEIGHT, 0, tokens)
		testing.expect(t, ok)
		testing.expect(t, boxes.scale_declined != layout.NO_BOX)
		notice := area_of(&layout_tree, boxes.scale_declined)
		card := area_of(&layout_tree, boxes.cards[.Display])
		track := area_of(&layout_tree, boxes.scale_track)
		testing.expectf(t, notice.y >= track.y + track.height && notice.x >= card.x && notice.x + notice.width <= card.x + card.width && notice.y + notice.height <= card.y + card.height, "at %d the notice %v is not under the track %v in its card %v", width, notice, track, card)
		testing.expect(t, notice.height > 0)
		quiet: Frame_Texts
		frame_texts_of(&quiet, settings.choice_default(), 0)
		quiet_boxes, _ := settings_layout(&table, &quiet, width, LARGEST_HEIGHT, 0, tokens)
		testing.expect(t, quiet_boxes.scale_declined == layout.NO_BOX)
	}
}

// Builds a validated synthetic module binary with an optional `set` export
// combining an instance parameter (`instances_export`), an Enum parameter, a
// ranged Integer parameter (`range`), an open-choices Integer parameter
// (`choices_export`), a bounded Text parameter, plus `settings_state`.
@(private = "file")
synthetic_settings_module :: proc(t: ^testing.T) -> []u8 {
	code := [1]u8{0xC3}
	segments := [1]module_file_writer.Segment_Part{{memory_offset = 0, memory_size = module.PAGE_SIZE, flags = {.Read, .Execute}, data = code[:]}}
	choice_fields := [2]module_file_writer.Field_Description{
		{name = "id", offset = 0, type = .Integer, detail = 8},
		{name = "name", offset = 8, type = .Text, detail = 16},
	}
	state_fields := [2]module_file_writer.Field_Description{
		{name = "layer", offset = 0, type = .Integer, detail = 8},
		{name = "value", offset = 8, type = .Integer, detail = 8},
	}
	records := [2]module_file_writer.Record_Description{
		{name = "Choice", size = 24, fields = choice_fields[:]},
		{name = "Setting_State", size = 16, fields = state_fields[:]},
	}
	enum_members := [2]module_file_writer.Member_Description{
		{name = "off", value = 0},
		{name = "on", value = 1},
	}
	enums := [1]module_file_writer.Enum_Description{
		{name = "Toggle", size = 8, members = enum_members[:]},
	}
	set_types := [5]module.Type{.Integer, .Enum, .Integer, .Integer, .Text}
	set_names := [5]string{"screen", "mode", "delay_ms", "profile", "home"}
	enum_detail, enum_ok := module.enum_detail_make(1, 0)
	testing.expect(t, enum_ok)
	set_details := [5]u32{0, enum_detail, 0, 0, 0}
	set_needs := [5]module.Parameter_Need{.Required, .Optional, .Optional, .Optional, .Optional}
	exports := [4]module_file_writer.Export_Part{
		{
			name              = "set",
			parameters        = set_types[:],
			parameter_names   = set_names[:],
			parameter_details = set_details[:],
			parameter_needs   = set_needs[:],
			result            = .Integer,
		},
		{name = "screens", result = .Table, result_detail = 1},
		{name = "profiles", result = .Table, result_detail = 1},
		{name = "settings_state", result = .Table, result_detail = 2},
	}
	param_settings := [4]module.Parameter_Setting{
		{export_index = 1, parameter = 0, instances_export = 2},
		{export_index = 1, parameter = 2, has_range = module.PARAMETER_RANGE_GIVEN, least = 250, most = 5000},
		{export_index = 1, parameter = 3, choices_export = 3},
		{export_index = 1, parameter = 4, has_range = module.PARAMETER_RANGE_GIVEN, least = 1, most = 1024},
	}
	parts := module_file_writer.Module_Parts{
		segments           = segments[:],
		exports            = exports[:],
		records            = records[:],
		enums              = enums[:],
		parameter_settings = param_settings[:],
	}
	needed, size_refusal := module_file_writer.file_size_needed(parts)
	testing.expect_value(t, size_refusal.refusal, module_file_writer.Refusal.None)
	buf := make([]u8, int(needed), context.temp_allocator)
	written, write_refusal := module_file_writer.write(parts, buf)
	testing.expect_value(t, write_refusal.refusal, module_file_writer.Refusal.None)
	return buf[:written]
}

// Dynamic discovery from module.Parameter_Setting handles invalid binaries,
// Enum members, range stops, choices_export, instances_export, bounded Text,
// settings_state (including locked layer and invalid layer refusal), setter
// argument encoding, and non-overlapping layout across window sizes.
@(test)
discovered_module_settings_and_layout :: proc(t: ^testing.T) {
	layout_tree_begin()
	mod: Discovered_Module
	// Refusal cases: empty, invalid binary, non-optional set export.
	testing.expect(t, !module_settings_discover_file("", nil, &mod))
	bad := [16]u8{0 = 1, 1 = 2, 2 = 3, 3 = 4}
	testing.expect(t, !module_settings_discover_file("broken", bad[:], &mod))
	testing.expect_value(t, mod.param_count, 0)

	file := synthetic_settings_module(t)
	testing.expect(t, module_settings_discover_file("sample_mod", file, &mod))
	testing.expect_value(t, discovered_module_name(&mod), "sample_mod")
	testing.expect_value(t, discovered_module_title(&mod), "SAMPLE MOD")
	testing.expect_value(t, mod.param_count, 5)
	testing.expect(t, mod.has_instances && mod.instance_param_index == 0)
	testing.expect_value(t, mod.params[0].kind, Discovered_Param_Kind.Instances)
	testing.expect_value(t, mod.params[1].kind, Discovered_Param_Kind.Enum)
	testing.expect_value(t, mod.params[1].value_count, 2)
	testing.expect_value(t, mod.params[2].kind, Discovered_Param_Kind.Range)
	testing.expect(t, mod.params[2].value_count >= 2 && mod.params[2].values[0] == 250 && mod.params[2].values[mod.params[2].value_count - 1] == 5000)
	testing.expect_value(t, mod.params[3].kind, Discovered_Param_Kind.Choices)
	testing.expect_value(t, mod.params[4].kind, Discovered_Param_Kind.Text)

	// Decode instances_export and choices_export table rows.
	Choice_Row :: struct #packed {
		id:   i64,
		name: [16]u8,
	}
	inst_rows := [2]Choice_Row{{id = 10}, {id = 20}}
	copy(inst_rows[0].name[:], "Screen A")
	copy(inst_rows[1].name[:], "Screen B")
	inst_count := discovered_table_choices_decode(file, mod.params[0].instances_export, ([^]u8)(&inst_rows[0])[:size_of(inst_rows)], 2, &mod.params[0])
	testing.expect_value(t, inst_count, 2)
	testing.expect_value(t, discovered_value_label(&mod.params[0], 1), "Screen B")

	choice_rows := [2]Choice_Row{{id = 101}, {id = 202}}
	copy(choice_rows[0].name[:], "Warm")
	copy(choice_rows[1].name[:], "Cool")
	choice_count := discovered_table_choices_decode(file, mod.params[3].choices_export, ([^]u8)(&choice_rows[0])[:size_of(choice_rows)], 2, &mod.params[3])
	testing.expect_value(t, choice_count, 2)
	testing.expect_value(t, discovered_value_label(&mod.params[3], 0), "Warm")

	// Apply settings_state: refuse unknown layer word first, then apply valid rows.
	State_Row :: struct #packed {
		layer: i64,
		value: i64,
	}
	bad_state := [1]State_Row{{layer = 99, value = 1}}
	testing.expect(t, !discovered_state_apply(&mod, ([^]u8)(&bad_state[0])[:size_of(bad_state)], 1))
	good_state := [3]State_Row{
		{layer = i64(chosen_values.Layer.Chosen), value = 1},
		{layer = i64(chosen_values.Layer.Locked), value = 5000},
		{layer = i64(chosen_values.Layer.Plan_Default), value = 202},
	}
	testing.expect(t, discovered_state_apply(&mod, ([^]u8)(&good_state[0])[:size_of(good_state)], 3))
	testing.expect(t, mod.state_loaded)
	testing.expect_value(t, mod.params[1].layer, chosen_values.Layer.Chosen)
	testing.expect_value(t, mod.params[2].layer, chosen_values.Layer.Locked)
	testing.expect_value(t, mod.params[2].current_value, i64(5000))
	testing.expect_value(t, mod.params[3].current_value, i64(202))

	// Build setter arguments with selected instance 1 (id = 20) and delay_ms = 5000.
	mod.selected_instance_index = 1
	args: [module.PARAMETER_CAPACITY]isolated.Argument
	arg_count, args_ok := discovered_set_arguments_build(&mod, mod.params[2].param_index, 5000, args[:])
	testing.expect(t, args_ok && arg_count == 5)
	testing.expect(t, args[0].presence == .Given && args[0].integer == 20)
	testing.expect(t, args[1].presence == .Absent)
	testing.expect(t, args[2].presence == .Given && args[2].integer == 5000)
	testing.expect(t, args[3].presence == .Absent && args[4].presence == .Absent)

	// Layout with discovered cards has zero overlap and every button inside its card.
	set: Discovered_Set
	set.modules[0] = mod
	set.module_count = 1
	table: interface.Draw_Table
	texts: Frame_Texts
	frame_texts_of(&texts, settings.choice_default())
	for app in ([?]graphics.Appearance{.Dark, .Light}) {
		tokens, _ := layout.tokens_for(app, .Standard)
		for width in ([?]int{LEAST_WIDTH, WIDTH, TWO_COLUMNS_WIDTH, LARGEST_WIDTH}) {
			boxes, ok := settings_layout(&table, &texts, width, HEIGHT, 0, tokens, &set)
			testing.expectf(t, ok, "settings_layout failed with discovered module at width %d", width)
			tree := &layout_tree
			card := area_of(tree, boxes.discovered_cards[0].card)
			content := card_content(card)
			for section in Section {
				testing.expectf(t, areas_apart(card, area_of(tree, boxes.cards[section])), "discovered card overlaps %v at width %d", section, width)
			}
			for p in 0 ..< mod.param_count {
				for v in 0 ..< mod.params[p].value_count {
					btn := area_of(tree, boxes.discovered_cards[0].params[p].values[v])
					testing.expectf(t, area_inside(btn, content), "button %d.%d %v outside card %v at width %d", p, v, btn, content, width)
				}
			}
		}
	}
}

@(test)
discovered_queue_sync_and_instance_clamp :: proc(t: ^testing.T) {
	// Reset queue state cleanly.
	discovered_req_head = 0
	discovered_req_count = 0
	discovered_req_dropped = 0
	discovered_set = {}
	discovered_ui_snapshot = {}
	discovered_dirty = 1
	discovered_ui_seen = max(u32)

	// Bounded FIFO queue preserves all DISCOVERED_REQUEST_QUEUE_CAPACITY rapid clicks
	// in order and counts overflow without overwriting queued items.
	for i in 0 ..< DISCOVERED_REQUEST_QUEUE_CAPACITY {
		testing.expect(t, discovered_queue_push(0, i, i64(i * 100)))
	}
	testing.expect(t, !discovered_queue_push(0, 99, 999))
	testing.expect_value(t, discovered_req_dropped, u64(1))
	for i in 0 ..< DISCOVERED_REQUEST_QUEUE_CAPACITY {
		req, ok := discovered_dequeue()
		testing.expect(t, ok)
		testing.expect_value(t, req.param_idx, i)
		testing.expect_value(t, req.value, i64(i * 100))
	}
	_, empty_ok := discovered_dequeue()
	testing.expect(t, !empty_ok)

	// discovered_ui_sync copies only when discovered_dirty changes.
	discovered_set.module_count = 1
	snap1 := discovered_ui_sync()
	testing.expect_value(t, snap1.module_count, 1)
	discovered_set.module_count = 2
	// Dirty unchanged -> UI snapshot stays at 1 without recopying.
	snap2 := discovered_ui_sync()
	testing.expect_value(t, snap2.module_count, 1)
	discovered_dirty += 1
	snap3 := discovered_ui_sync()
	testing.expect_value(t, snap3.module_count, 2)

	// Instance index clamping when instances shrink or empty.
	mod: Discovered_Module
	mod.has_instances = true
	mod.instance_param_index = 0
	mod.param_count = 1
	mod.params[0].kind = .Instances
	mod.params[0].value_count = 2
	mod.selected_instance_index = 5
	discovered_instance_index_clamp(&mod)
	testing.expect_value(t, mod.selected_instance_index, 1)
	mod.params[0].value_count = 0
	discovered_instance_index_clamp(&mod)
	testing.expect_value(t, mod.selected_instance_index, 0)
}
