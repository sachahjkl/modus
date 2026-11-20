#+build !freestanding
package settings

import "core:testing"
import "modus:contract/scale_factor"

// A writer that stops in a change (an odd count) does not stop a reader:
// after READ_TRIES reads it gives the defaults, and refuses the page.
@(test)
a_page_left_in_a_change :: proc(t: ^testing.T) {
	page: Page
	written := Choice{font = .Spleen, subpixel_order = .None, pointer_theme = .Of_The_System, grid_fit = .Off, keyboard_layout = .French, appearance = .Light, scale = .Eleven_Eighths}
	write(&page, written, 330, .Light)
	choice, ok := read(&page)
	testing.expect(t, ok)
	testing.expect_value(t, choice.font, Font.Spleen)
	testing.expect_value(t, choice.appearance, Appearance.Light)
	testing.expect_value(t, choice.scale, scale_factor.Scale.Eleven_Eighths)
	testing.expect_value(t, choice.appearance_in_force, Appearance_In_Force.Light)
	testing.expect_value(t, choice.zone_offset_minutes, 330)
	testing.expect_value(t, choice.change_count, 2)
	testing.expect_value(t, values_of(choice), values_of(written))
	page.change_count = 3
	stopped, stopped_ok := read(&page)
	testing.expect(t, !stopped_ok)
	testing.expect_value(t, values_of(stopped), values_of(choice_default()))
	testing.expect_value(t, stopped.zone_offset_minutes, 0)
	testing.expect_value(t, stopped.change_count, 3)
}

// The text of a zone and back: each quarter of an hour from -12:00 to
// +14:00 gives its text and reads back as itself.
@(test)
the_text_of_a_zone :: proc(t: ^testing.T) {
	buffer: [ZONE_TEXT_SIZE]u8
	testing.expect_value(t, zone_text(buffer[:], 0), "+00:00")
	testing.expect_value(t, zone_text(buffer[:], 480), "+08:00")
	testing.expect_value(t, zone_text(buffer[:], -210), "-03:30")
	testing.expect_value(t, zone_text(buffer[:], 345), "+05:45")
	testing.expect_value(t, zone_text(buffer[:], ZONE_OFFSET_MINUTES_LEAST), "-12:00")
	testing.expect_value(t, zone_text(buffer[:], ZONE_OFFSET_MINUTES_MOST), "+14:00")
	// A zone that is not valid is written as UTC, and a short buffer gives
	// no text.
	testing.expect_value(t, zone_text(buffer[:], ZONE_OFFSET_MINUTES_MOST + ZONE_OFFSET_MINUTES_STEP), "+00:00")
	testing.expect_value(t, zone_text(buffer[:], 7), "+00:00")
	testing.expect_value(t, zone_text(buffer[:ZONE_TEXT_SIZE - 1], 60), "")
	count := 0
	for minutes := ZONE_OFFSET_MINUTES_LEAST; minutes <= ZONE_OFFSET_MINUTES_MOST; minutes += ZONE_OFFSET_MINUTES_STEP {
		read_back, ok := zone_parse(zone_text(buffer[:], minutes))
		testing.expectf(t, ok && read_back == minutes, "the zone %d minutes reads back as %d", minutes, read_back)
		count += 1
	}
	testing.expect_value(t, count, 105)
}

// A text that is not a zone is refused: the form, the range and the
// quarters of an hour.
@(test)
a_text_that_is_not_a_zone :: proc(t: ^testing.T) {
	refused := [?]string{"", "+8:00", "+08", "08:00", "UTC", "+08:10", "+15:00", "-12:15", "+08:60", "+0a:00", "+08-00", "+08:000", " +08:00"}
	for text in refused {
		_, ok := zone_parse(text)
		testing.expectf(t, !ok, "the text %q is refused", text)
	}
	minutes, ok := zone_parse("-00:00")
	testing.expect(t, ok && minutes == 0)
}

// A zone on the page that is not valid reads as UTC, and a change of the
// zone alone makes two choices differ.
@(test)
the_zone_on_the_page :: proc(t: ^testing.T) {
	page: Page
	page_defaults_write(&page)
	page.zone_offset_minutes = ZONE_OFFSET_MINUTES_MOST + 60
	choice, _ := read(&page)
	testing.expect_value(t, choice.zone_offset_minutes, 0)
	page.zone_offset_minutes = 100
	choice, _ = read(&page)
	testing.expect_value(t, choice.zone_offset_minutes, 0)
	page.zone_offset_minutes = -720
	first, ok := read(&page)
	testing.expect(t, ok)
	testing.expect_value(t, first.zone_offset_minutes, -720)
	changed := first
	changed.zone_offset_minutes = 60
	testing.expect(t, values_differ(first, changed))
}

// The kept record: a word that names no value of its setting refuses the
// whole record, at each edge, and nothing of it is read; a record of the
// version before and a short record are refused; a zone that is not valid
// reads as UTC. A scale word past the window bound refuses the record as a
// word that names no scale. A record of the six settings before the scale
// keeps them and reads the scale 1.25. The record of a choice reads back
// as that choice.
@(test)
the_kept_record :: proc(t: ^testing.T) {
	written := Choice{font = .Spleen, appearance = .Light, scale = .Eleven_Eighths}
	kept := kept_of(written, -210)
	testing.expect_value(t, kept.zero, 0)
	testing.expect_value(t, kept.count, u32(len(Setting)))
	bytes := ([^]u8)(&kept)[:size_of(kept)]
	refused_words := [?]u32{len(Font), len(Font) + 1, 0x100, max(u32)}
	for word in refused_words {
		kept.values[Setting.Font] = word
		read_choice, zone, ok := kept_read(bytes)
		testing.expectf(t, !ok, "the font word %d names no font, and the record is taken", word)
		testing.expect_value(t, values_of(read_choice), values_of(choice_default()))
		testing.expect_value(t, zone, 0)
	}
	kept.values[Setting.Font] = u32(Font.Spleen)
	refused_scales := [?]u32{0, scale_factor.EIGHTHS_OF_ONE, u32(scale_factor.Scale.Ten_Eighths) - 1, u32(scale_factor.WINDOW_BOUND) + 1, u32(scale_factor.Scale.Sixteen_Eighths), u32(scale_factor.Scale.Sixteen_Eighths) + 1, max(u32)}
	for word in refused_scales {
		kept.values[Setting.Scale] = word
		read_choice, _, ok := kept_read(bytes)
		testing.expectf(t, !ok, "the scale word %d is taken in a record", word)
		testing.expect_value(t, read_choice.scale, scale_factor.DEFAULT)
	}
	kept.values[Setting.Scale] = u32(scale_factor.Scale.Eleven_Eighths)
	kept.values[Setting.Appearance] = len(Appearance)
	_, _, ok := kept_read(bytes)
	testing.expect(t, !ok)
	kept.values[Setting.Appearance] = u32(Appearance.Light)
	kept.version = KEPT_VERSION - 1
	_, _, ok = kept_read(bytes)
	testing.expect(t, !ok)
	kept.version = KEPT_VERSION
	_, _, ok = kept_read(bytes[:size_of(kept) - 8])
	testing.expect(t, !ok)
	kept.zone_offset_minutes = 7
	_, zone, zone_ok := kept_read(bytes)
	testing.expect(t, zone_ok)
	testing.expect_value(t, zone, 0)
	kept.zone_offset_minutes = -210
	// A record written before the scale existed: the word past its count
	// is no value of the record, so it is not read, and the scale has its
	// default, not the word 0. Here the word past the count names nothing.
	kept.count = u32(Setting.Scale)
	kept.values[Setting.Scale] = max(u32)
	before_scale, _, before_scale_ok := kept_read(bytes)
	testing.expect(t, before_scale_ok)
	testing.expect_value(t, before_scale.scale, scale_factor.DEFAULT)
	testing.expect_value(t, before_scale.font, Font.Spleen)
	testing.expect_value(t, before_scale.appearance, Appearance.Light)
	// A record of fewer settings still: each past its count has its default.
	kept.count = u32(Setting.Appearance)
	older, _, older_ok := kept_read(bytes)
	testing.expect(t, older_ok)
	testing.expect_value(t, older.appearance, Appearance.Auto)
	testing.expect_value(t, older.font, Font.Spleen)
	kept.count = len(Setting)
	kept.values[Setting.Scale] = u32(scale_factor.Scale.Eleven_Eighths)
	read_choice, read_zone, read_ok := kept_read(bytes)
	testing.expect(t, read_ok)
	testing.expect_value(t, values_of(read_choice), values_of(written))
	testing.expect_value(t, read_zone, -210)
}

// refused_words_of gives the words that the border of a setting must
// refuse: one past its last value, the next one, a word past 255 and the
// largest word; for the scale also 0, 1, the scale 1, one under its first
// word and each count past the window bound.
@(private = "file")
refused_words_of :: proc(setting: Setting, words: ^[16]u32) -> int {
	count := 0
	add :: proc(words: ^[16]u32, count: ^int, word: u32) {
		words[count^] = word
		count^ += 1
	}
	if setting == .Scale {
		for word in ([?]u32{0, 1, scale_factor.EIGHTHS_OF_ONE, u32(scale_factor.Scale.Ten_Eighths) - 1}) {
			add(words, &count, word)
		}
		for word in u32(scale_factor.WINDOW_BOUND) + 1 ..= u32(scale_factor.Scale.Sixteen_Eighths) + 1 {
			add(words, &count, word)
		}
	} else {
		last := word_of_value(setting, int(descriptions[setting].value_count))
		add(words, &count, last)
		add(words, &count, last + 1)
	}
	add(words, &count, 0x100)
	add(words, &count, max(u32))
	return count
}

// A word that a setting does not have refuses the page: one past the last
// value of each setting, a word past 255, the largest word, and for the
// scale each count outside 10 to the window bound. The choice is the
// defaults, so no reader acts on the word. The appearance in force past its
// last member refuses the page too. Each value of each setting then reads
// back as its member.
@(test)
a_value_out_of_its_setting :: proc(t: ^testing.T) {
	for setting in Setting {
		words: [16]u32
		count := refused_words_of(setting, &words)
		for word in words[:count] {
			testing.expectf(t, !value_valid(setting, word), "the word %d names no value of %v, and it is taken", word, setting)
			values := values_of(choice_default())
			values[setting] = word
			_, refused, ok := choice_of_values(values)
			testing.expectf(t, !ok && refused == setting, "the word %d of %v: refused %v, ok %v", word, setting, refused, ok)
			page: Page
			page_defaults_write(&page)
			page.values[setting] = word
			choice, page_ok := read(&page)
			testing.expectf(t, !page_ok, "a page with the word %d for %v is taken", word, setting)
			testing.expect_value(t, values_of(choice), values_of(choice_default()))
		}
	}
	page: Page
	page_defaults_write(&page)
	page.appearance_in_force = u32(max(Appearance_In_Force)) + 1
	_, in_force_ok := read(&page)
	testing.expect(t, !in_force_ok)
	page.appearance_in_force = max(u32)
	_, in_force_ok = read(&page)
	testing.expect(t, !in_force_ok)
	// The success case last: each value that the border takes.
	for setting in Setting {
		for place in 0 ..< int(descriptions[setting].value_count) {
			word := word_of_value(setting, place)
			if setting == .Scale && word > u32(scale_factor.WINDOW_BOUND) {
				continue
			}
			testing.expectf(t, value_valid(setting, word), "the word %d of %v is refused", word, setting)
			values := values_of(choice_default())
			values[setting] = word
			choice, _, ok := choice_of_values(values)
			testing.expect(t, ok)
			testing.expect_value(t, values_of(choice), values)
			testing.expect_value(t, value_name_of(setting, word), descriptions[setting].value_names[place])
		}
	}
}

// The place of a word and its name: a word under the first word of a
// setting and a word past its values name no value, and give no name.
@(test)
the_place_of_a_word :: proc(t: ^testing.T) {
	_, under_ok := value_place_of_word(.Scale, u32(scale_factor.Scale.Ten_Eighths) - 1)
	testing.expect(t, !under_ok)
	_, zero_ok := value_place_of_word(.Scale, 0)
	testing.expect(t, !zero_ok)
	_, past_ok := value_place_of_word(.Font, len(Font))
	testing.expect(t, !past_ok)
	_, largest_ok := value_place_of_word(.Scale, max(u32))
	testing.expect(t, !largest_ok)
	testing.expect_value(t, value_name_of(.Scale, max(u32)), "")
	testing.expect_value(t, value_name_of(.Font, len(Font)), "")
	place, ok := value_place_of_word(.Scale, u32(scale_factor.Scale.Eleven_Eighths))
	testing.expect(t, ok)
	testing.expect_value(t, place, 1)
	testing.expect_value(t, value_name_of(.Scale, u32(scale_factor.Scale.Eleven_Eighths)), "1.375")
	testing.expect_value(t, value_name_of(.Font, u32(Font.Spleen)), "spleen")
}

// Two choices with the same values and other counts do not differ; one
// value changed makes them differ, for each setting.
@(test)
values_differ_compares_the_values_only :: proc(t: ^testing.T) {
	first := Choice{font = .Spleen, subpixel_order = .None, grid_fit = .Off, keyboard_layout = .French, appearance = .Auto, scale = .Ten_Eighths, change_count = 2}
	second := first
	second.change_count = 1_000_002
	testing.expect(t, !values_differ(first, second))
	testing.expect(t, !values_differ(first, first))
	other := Choice{font = .Vector, subpixel_order = .Red_Green_Blue, pointer_theme = .Of_The_System, grid_fit = .On, keyboard_layout = .United_States, appearance = .Dark, scale = .Eleven_Eighths}
	other_values := values_of(other)
	for setting in Setting {
		values := values_of(first)
		values[setting] = other_values[setting]
		changed, _, ok := choice_of_values(values)
		testing.expect(t, ok)
		changed.change_count = first.change_count
		testing.expectf(t, values_differ(first, changed), "a change of %v", setting)
		testing.expectf(t, values_differ(changed, first), "a change of %v, in the other order", setting)
	}
	// The appearance in force alone, as the root service changes it at an
	// edge of the day: the compositor must tell the windows.
	changed := first
	changed.appearance_in_force = .Light
	testing.expect(t, values_differ(first, changed))
}

// The root service changes the appearance in force alone: the values and
// the change count stay, and a reader sees the new word.
@(test)
the_appearance_in_force_alone :: proc(t: ^testing.T) {
	page: Page
	write(&page, choice_default(), 0, .Dark)
	before, before_ok := read(&page)
	appearance_in_force_write(&page, .Light)
	after, after_ok := read(&page)
	testing.expect(t, before_ok && after_ok)
	testing.expect_value(t, after.appearance_in_force, Appearance_In_Force.Light)
	testing.expect_value(t, after.change_count, before.change_count)
	testing.expect_value(t, values_of(after), values_of(before))
}

// An all-zero page holds the word 0 for the scale, which names no scale:
// it is refused, and its choice is the defaults with the scale 1.25. The
// page that the root service creates is written with the defaults first:
// the setting auto, dark in force, the scale 1.25.
@(test)
an_all_zero_page_is_refused :: proc(t: ^testing.T) {
	empty: Page
	empty_choice, empty_ok := read(&empty)
	testing.expect(t, !empty_ok)
	testing.expect_value(t, empty_choice.scale, scale_factor.DEFAULT)
	created: Page
	page_defaults_write(&created)
	choice, ok := read(&created)
	testing.expect(t, ok)
	testing.expect_value(t, choice.appearance, Appearance.Auto)
	testing.expect_value(t, choice.appearance_in_force, Appearance_In_Force.Dark)
	testing.expect_value(t, choice.scale, scale_factor.DEFAULT)
	testing.expect_value(t, created.values[Setting.Scale], u32(scale_factor.DEFAULT))
}

// The arguments of a call that leaves out each setting: the absent word,
// each bit of the size of the enum set, as the console writes it.
@(private = "file")
nothing_given :: proc() -> Set_Arguments {
	return {
		font            = Font(max(u32)),
		subpixel_order  = Subpixel_Order(max(u32)),
		pointer_theme   = Pointer_Theme(max(u32)),
		grid_fit        = Grid_Fit(max(u32)),
		keyboard_layout = Keyboard_Layout(max(u32)),
		appearance      = Appearance(max(u32)),
		scale           = scale_factor.Scale(max(u8)),
	}
}

// The border of the export set refuses a value past each enum, and
// changes nothing then: one past the last member, the absent word less
// one, a word of the scale under its first member, and a member of
// another enum written into this one. A call that gives nothing is
// refused, and so is a scale that no window fits.
@(test)
the_arguments_of_set_refuse_a_value_past_the_enum :: proc(t: ^testing.T) {
	current := choice_default()
	current.zone_offset_minutes, current.change_count = 60, 8
	Case :: struct {
		arguments: Set_Arguments,
		refused:   Setting,
		problem:   Set_Problem,
	}
	past := make([dynamic]Case, context.temp_allocator)
	for word in ([?]u32{u32(max(Font)) + 1, max(u32) - 1, 1 << 16}) {
		arguments := nothing_given()
		arguments.font = Font(word)
		append(&past, Case{arguments, .Font, .Bad_Value})
	}
	for word in ([?]u32{u32(max(Keyboard_Layout)) + 1, max(u32) - 1}) {
		arguments := nothing_given()
		arguments.keyboard_layout = Keyboard_Layout(word)
		append(&past, Case{arguments, .Keyboard_Layout, .Bad_Value})
	}
	for word in ([?]u8{0, 9, u8(max(scale_factor.Scale)) + 1, max(u8) - 1}) {
		arguments := nothing_given()
		arguments.scale = scale_factor.Scale(word)
		append(&past, Case{arguments, .Scale, .Bad_Value})
	}
	// The member None of the subpixel order, 2, written as a layout of the
	// keyboard, which has two members: a member of another enum is no
	// member of this one.
	another := nothing_given()
	another.keyboard_layout = Keyboard_Layout(Subpixel_Order.None)
	append(&past, Case{another, .Keyboard_Layout, .Bad_Value})
	// A good value before a bad one changes nothing either.
	mixed := nothing_given()
	mixed.font, mixed.appearance = .Spleen, Appearance(3)
	append(&past, Case{mixed, .Appearance, .Bad_Value})
	append(&past, Case{nothing_given(), {}, .Nothing_Given})
	beyond := nothing_given()
	beyond.scale = .Twelve_Eighths
	append(&past, Case{beyond, .Scale, .Past_Window_Bound})
	largest := nothing_given()
	largest.scale = max(scale_factor.Scale)
	append(&past, Case{largest, .Scale, .Past_Window_Bound})
	for item in past {
		changed, refused, problem := choice_of_arguments(current, item.arguments)
		testing.expectf(t, problem == item.problem && refused == item.refused, "%v gives %v of %v, not %v of %v", item.arguments, problem, refused, item.problem, item.refused)
		testing.expectf(t, changed == current, "a refused call changed the choice: %v", changed)
	}
	// The successes come last: one setting, the others kept, and the count,
	// the zone and the appearance in force kept.
	layout := nothing_given()
	layout.keyboard_layout = .French
	changed, _, problem := choice_of_arguments(current, layout)
	testing.expect_value(t, problem, Set_Problem.None)
	expected := current
	expected.keyboard_layout = .French
	testing.expect_value(t, changed, expected)
	each := Set_Arguments{font = .Spleen, subpixel_order = .None, pointer_theme = .Of_The_System, grid_fit = .Off, keyboard_layout = .French, appearance = .Light, scale = .Eleven_Eighths}
	changed, _, problem = choice_of_arguments(current, each)
	testing.expect_value(t, problem, Set_Problem.None)
	testing.expect(t, changed.font == .Spleen && changed.subpixel_order == .None && changed.scale == .Eleven_Eighths && changed.zone_offset_minutes == 60 && changed.change_count == 8)
}
