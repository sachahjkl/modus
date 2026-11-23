#+build !freestanding
package display

import "modus:contract/errors"
import "modus:contract/memory_screen"
import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:contract/scale_factor"
import "modus:contract/text_encoding"
import "modus:key_path"
import "core:testing"

// A part of Capture_Viewers is refused with a count past the capacity, a
// place that is not a multiple of a part or that is past the count, and a
// bit of the input past the count; then the parts of 0, 1, 4, 5 and 8
// viewers go through the border and give each key at its place, the last
// part marked.
@(test)
capture_viewers_parts_round_trip_and_refuse_each_edge :: proc(t: ^testing.T) {
	refused := [?][7]u64{
		{0 = CAPTURE_VIEWER_CAPACITY + 1},
		{0 = max(u64)},
		{0 = 8, 2 = 1},
		{0 = 8, 2 = 3},
		{0 = 4, 2 = 4},
		{0 = 8, 2 = 8},
		{0 = 0, 1 = 1},
		{0 = 3, 1 = 0b1000},
		{0 = 8, 1 = 1 << 8},
	}
	for values in refused {
		_, _, _, _, ok := capture_viewers_part_check(values)
		testing.expectf(t, !ok, "the part %v was taken", values)
	}
	keys: [CAPTURE_VIEWER_CAPACITY]u64
	for &key, index in keys {
		key = u64(0x1000 + index)
	}
	for count in ([?]int{0, 1, CAPTURE_VIEWER_KEYS_OF_A_PART, CAPTURE_VIEWER_KEYS_OF_A_PART + 1, CAPTURE_VIEWER_CAPACITY}) {
		parts: [CAPTURE_VIEWER_CAPACITY / CAPTURE_VIEWER_KEYS_OF_A_PART]ring.Record
		part_count := capture_viewers_parts(keys[:count], max(u64), &parts)
		testing.expect_value(t, part_count, max(1, (count + CAPTURE_VIEWER_KEYS_OF_A_PART - 1) / CAPTURE_VIEWER_KEYS_OF_A_PART))
		seen: [CAPTURE_VIEWER_CAPACITY]u64
		lasts := 0
		for part in parts[:part_count] {
			taken_count, input, place, last, ok := capture_viewers_part_check(part.values)
			testing.expectf(t, ok && taken_count == count, "a part of %d viewers was refused: %v", count, part.values)
			testing.expect_value(t, input, count == 0 ? 0 : (u64(1) << u64(count)) - 1)
			for index in place ..< min(place + CAPTURE_VIEWER_KEYS_OF_A_PART, count) {
				seen[index] = part.values[3 + index - place]
			}
			if last {
				lasts += 1
			}
		}
		testing.expect_value(t, lasts, 1)
		for index in 0 ..< count {
			testing.expect_value(t, seen[index], keys[index])
		}
	}
}

// The second word of Settings_Raise: one past the last member, a word of
// 32 bits and the largest word are refused first; then each member.
@(test)
the_focus_of_a_settings_raise_refuses_a_word_that_names_no_member :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(max(Settings_Raise_Focus)) + 1, u64(max(u32)), max(u64)}) {
		_, ok := settings_raise_focus_of_word(word)
		testing.expectf(t, !ok, "the word %d names a focus", word)
	}
	for member in Settings_Raise_Focus {
		read, ok := settings_raise_focus_of_word(u64(member))
		testing.expect(t, ok && read == member)
	}
}

// The layout of a window from its view: a fixed window keeps the size that
// it opened with, at each view, the smallest too; a resizable window takes
// its least size under a view below it, on each axis alone, and the view
// at and above the least size.
@(test)
the_layout_of_a_window_keeps_its_least_size :: proc(t: ^testing.T) {
	limits := Size_Limits{least_width = 400, least_height = 320, largest_width = 1024, largest_height = 800}
	for view in ([?][2]int{{1, 1}, {560, 482}, {560, 688}}) {
		width, height := layout_size_of(view[0], view[1], false, limits, 560, 688)
		testing.expectf(t, width == 560 && height == 688, "a fixed window in %v lays out at %dx%d", view, width, height)
	}
	Case :: struct {
		view, layout: [2]int,
	}
	cases := [?]Case{{{1, 1}, {400, 320}}, {{399, 482}, {400, 482}}, {{560, 319}, {560, 320}}, {{400, 320}, {400, 320}}, {{560, 482}, {560, 482}}, {{1024, 800}, {1024, 800}}}
	for each in cases {
		width, height := layout_size_of(each.view[0], each.view[1], true, limits, 560, 688)
		testing.expectf(t, width == each.layout[0] && height == each.layout[1], "a resizable window in %v lays out at %dx%d", each.view, width, height)
	}
}

// The root service, the input service and each window write the kind of a
// record that the compositor reads: None, one past the last member and the
// largest word are refused, and give None. Then each member but None comes
// back from its word.
@(test)
ring_words_of_the_compositor_refuse_a_word_that_names_no_member :: proc(t: ^testing.T) {
	controls_refused := [?]u32{u32(Control.None), u32(max(Control)) + 1, max(u32)}
	for word in controls_refused {
		read, ok := control_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no control, and it is taken", word)
		testing.expect_value(t, read, Control.None)
	}
	inputs_refused := [?]u32{u32(Input.None), u32(max(Input)) + 1, max(u32)}
	for word in inputs_refused {
		read, ok := input_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no input, and it is taken", word)
		testing.expect_value(t, read, Input.None)
	}
	commands_refused := [?]u32{u32(Command.None), u32(max(Command)) + 1, max(u32)}
	for word in commands_refused {
		read, ok := command_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no command, and it is taken", word)
		testing.expect_value(t, read, Command.None)
	}
	for member in Control {
		if member != .None {
			read, ok := control_of_ring_word(u32(member))
			testing.expect(t, ok && read == member)
		}
	}
	for member in Input {
		if member != .None {
			read, ok := input_of_ring_word(u32(member))
			testing.expect(t, ok && read == member)
		}
	}
	for member in Command {
		if member != .None {
			read, ok := command_of_ring_word(u32(member))
			testing.expect(t, ok && read == member)
		}
	}
}

// The compositor writes the kind of each input record. A kind that names no
// event is refused first: None, one past the last member, the largest kind.
// A refused record gives the zero event, so nothing of it reaches a process.
@(test)
event_of_record_refuses_a_kind_that_names_no_event :: proc(t: ^testing.T) {
	refused_kinds := [?]u32{u32(Event_Kind.None), u32(max(Event_Kind)) + 1, 1 << 31, max(u32)}
	for kind in refused_kinds {
		record := ring.Record{kind = kind}
		for &value in record.values {
			value = max(u64)
		}
		event, ok := event_of_record(record)
		testing.expectf(t, !ok, "the kind %d names no event, and it is taken", kind)
		testing.expect_value(t, event, Event{})
	}
}

// The records of the capture face go to the service of the remote display,
// which reads them itself: a window refuses them, whatever their values.
@(test)
event_of_record_refuses_the_records_of_the_capture_face :: proc(t: ^testing.T) {
	for kind in ([3]Event_Kind{.Capture_Size, .Capture_Frame, .Capture_Disconnect}) {
		for value in ([3]u64{0, 1, max(u64)}) {
			record := ring.Record{kind = u32(kind)}
			for &word in record.values {
				word = value
			}
			event, ok := event_of_record(record)
			testing.expectf(t, !ok, "a window takes the record %v", kind)
			testing.expect_value(t, event, Event{})
		}
	}
	// The header of the two pictures fits its page, and the memory of the
	// largest screen holds both pictures after it.
	testing.expect(t, size_of(Capture_Header) <= CAPTURE_HEADER_PAGES * 4096)
	testing.expect_value(t, capture_pages(1, 1), u64(CAPTURE_HEADER_PAGES + 1))
	testing.expect(t, capture_pages(1920, 1080) * 4096 >= CAPTURE_HEADER_PAGES * 4096 + PICTURE_COUNT * 1920 * 1080 * 4)
}

// The serial of a key reaches its event, the largest word too: it is a
// number of the compositor that the process only names back. key_shown
// keeps the newest serial: 0 and an older serial change nothing.
@(test)
key_serial_reaches_the_event_and_key_shown_keeps_the_newest :: proc(t: ^testing.T) {
	key := ring.Record{kind = u32(Event_Kind.Key)}
	key.values = {KEY_TAB, 'a', 1, 0, 0, 0, 0}
	key.values[KEY_EVENT_SERIAL] = max(u64)
	event, ok := event_of_record(key)
	testing.expect(t, ok)
	testing.expect_value(t, event.key_serial, max(u64))

	window: Window
	key_shown(&window, 0)
	testing.expect_value(t, window.key_shown_serial, 0)
	key_shown(&window, 5)
	key_shown(&window, 3)
	key_shown(&window, 0)
	testing.expect_value(t, window.key_shown_serial, 5)
	key_shown(&window, 6)
	testing.expect_value(t, window.key_shown_serial, 6)
}

// The notches of the wheel are cut at the limit, on both sides: the edges
// are the limit, one past it and the largest counts of the word.
@(test)
event_of_record_cuts_the_notches_at_the_limit :: proc(t: ^testing.T) {
	LIMIT :: key_path.WHEEL_NOTCHES_LIMIT
	cases := [?]struct {
		written: i64,
		read:    int,
	}{
		{LIMIT, LIMIT},
		{LIMIT + 1, LIMIT},
		{max(i64), LIMIT},
		{-LIMIT, -LIMIT},
		{-LIMIT - 1, -LIMIT},
		{min(i64), -LIMIT},
		{0, 0},
	}
	for each in cases {
		record := ring.Record{kind = u32(Event_Kind.Pointer)}
		record.values[key_path.POINTER_RECORD_WHEEL] = u64(each.written)
		event, ok := event_of_record(record)
		testing.expect(t, ok)
		testing.expect_value(t, event.wheel, each.read)
	}
}

// A character past the last code point is no character: the key keeps its
// code and gives 0.
@(test)
event_of_record_refuses_a_character_past_the_last_code_point :: proc(t: ^testing.T) {
	record := ring.Record{kind = u32(Event_Kind.Key)}
	record.values[0] = KEY_ENTER
	record.values[1] = 0x11_0000
	event, ok := event_of_record(record)
	testing.expect(t, ok)
	testing.expect_value(t, event.code, u32(KEY_ENTER))
	testing.expect_value(t, event.character, rune(0))
	record.values[1] = max(u64)
	event, ok = event_of_record(record)
	testing.expect(t, ok)
	testing.expect_value(t, event.character, rune(0))
}

// A Resized whose size is 0, one past the limit, or the largest word, is
// refused: the process never makes a surface of that size. The words that
// read as negative numbers are refused as the large words that they are.
@(test)
event_of_record_refuses_a_resize_out_of_its_range :: proc(t: ^testing.T) {
	refused := [?][2]u64{
		{0, 100},
		{100, 0},
		{0, 0},
		{SURFACE_LIMIT + 1, 100},
		{100, SURFACE_LIMIT + 1},
		{max(u64), 100},
		{100, max(u64)},
		{1 << 63, 1 << 63},
	}
	for size in refused {
		record := ring.Record{kind = u32(Event_Kind.Resized)}
		record.values[0], record.values[1] = size[0], size[1]
		event, ok := event_of_record(record)
		testing.expectf(t, !ok, "a resize to %d x %d is taken", size[0], size[1])
		testing.expect_value(t, event, Event{})
	}
	// The edges that are taken: 1, and the limit.
	taken := [?][2]u64{{1, 1}, {SURFACE_LIMIT, SURFACE_LIMIT}, {976, 400}}
	for size in taken {
		record := ring.Record{kind = u32(Event_Kind.Resized)}
		record.values[0], record.values[1] = size[0], size[1]
		event, ok := event_of_record(record)
		testing.expect(t, ok)
		testing.expect_value(t, event, Event{kind = .Resized, width = int(size[0]), height = int(size[1])})
	}
}

// The border of the record Resizable refuses each rule that the words
// break, from the edges: a least size of 0 and one below the floor, a
// largest size one past the limit and the largest word, a least size past
// its largest one, and a surface outside the limits. A refusal gives the
// zero limits. The limits that hold come last.
@(test)
size_limits_of_words_refuses_each_broken_rule :: proc(t: ^testing.T) {
	WIDTH :: 816
	HEIGHT :: 336
	cases := [?]struct {
		words:   [4]u64,
		problem: Size_Limits_Problem,
	}{
		{{0, 0, 0, 0}, .Least_Below_Floor},
		{{0, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT}, .Least_Below_Floor},
		{{RESIZABLE_LEAST_WIDTH - 1, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT}, .Least_Below_Floor},
		{{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT - 1, SURFACE_LIMIT, SURFACE_LIMIT}, .Least_Below_Floor},
		{{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT + 1, SURFACE_LIMIT}, .Largest_Past_Limit},
		{{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT + 1}, .Largest_Past_Limit},
		{{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, max(u64), max(u64)}, .Largest_Past_Limit},
		// A word that reads as a negative int: refused as a large word.
		{{1 << 63, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT}, .Least_Past_Largest},
		{{WIDTH + 1, HEIGHT, WIDTH, SURFACE_LIMIT}, .Least_Past_Largest},
		{{WIDTH, HEIGHT + 1, SURFACE_LIMIT, HEIGHT}, .Least_Past_Largest},
		{{WIDTH + 8, HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT}, .Size_Outside},
		{{WIDTH, HEIGHT, WIDTH - 8, SURFACE_LIMIT}, .Least_Past_Largest},
		{{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, WIDTH - 1, SURFACE_LIMIT}, .Size_Outside},
		{{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, HEIGHT - 1}, .Size_Outside},
	}
	for each in cases {
		limits, problem := size_limits_of_words(each.words, WIDTH, HEIGHT)
		testing.expectf(t, problem == each.problem, "the words %v give %v, not %v", each.words, problem, each.problem)
		testing.expect_value(t, limits, Size_Limits{})
	}
	// The edges that hold: the floor, the limit, and the size of the
	// surface as both bounds.
	limits, problem := size_limits_of_words({RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT}, WIDTH, HEIGHT)
	testing.expect_value(t, problem, Size_Limits_Problem.None)
	testing.expect_value(t, limits, Size_Limits{RESIZABLE_LEAST_WIDTH, RESIZABLE_LEAST_HEIGHT, SURFACE_LIMIT, SURFACE_LIMIT})
	limits, problem = size_limits_of_words({WIDTH, HEIGHT, WIDTH, HEIGHT}, WIDTH, HEIGHT)
	testing.expect_value(t, problem, Size_Limits_Problem.None)
	testing.expect_value(t, limits, Size_Limits{WIDTH, HEIGHT, WIDTH, HEIGHT})
}

// size_inside at each edge of the limits: one before and one past each
// bound is outside, each bound is inside.
@(test)
size_inside_at_each_edge :: proc(t: ^testing.T) {
	limits := Size_Limits{least_width = 200, least_height = 100, largest_width = 400, largest_height = 300}
	outside := [?][2]int{{199, 150}, {401, 150}, {300, 99}, {300, 301}, {0, 0}, {-1, 150}, {300, -1}, {max(int), 150}, {min(int), 150}}
	for size in outside {
		testing.expectf(t, !size_inside(limits, size[0], size[1]), "%v is inside", size)
	}
	inside := [?][2]int{{200, 100}, {400, 300}, {300, 150}}
	for size in inside {
		testing.expectf(t, size_inside(limits, size[0], size[1]), "%v is outside", size)
	}
}

// A window of 816 x 336 whose limits go to 1216 x 640, with a ring in plain
// memory: the refusals of surface_resize come before any kernel operation,
// so a host test runs them.
@(private = "file")
resizable_window_of_test :: proc(ring_memory: []u8) -> Window {
	window: Window
	opened, ok := ring.open(raw_data(ring_memory), ring.PAGE_COUNT)
	assert(ok)
	window.ring = opened
	window.pictures[0] = {width = 816, height = 336, stride = 816}
	window.pictures[1] = window.pictures[0]
	window.canvas = window.pictures[0]
	window.resizable = true
	window.size_limits = {least_width = 816, least_height = 336, largest_width = 1216, largest_height = 640}
	window.resize_asked = true
	window.resize_asked_width, window.resize_asked_height = 880, 384
	return window
}

// surface_resize refuses, with no change of the window: a fixed window; no
// Resized to answer; another size than the asked one, by one pixel, 0 and
// a negative size; a size outside the limits that a Resizable narrowed
// after the request; and a full command ring, with No_Slot. No_Budget comes
// from the kernel, which a host test does not have: the machine test of a
// window whose budget refuses is not written.
@(test)
surface_resize_refuses_before_any_kernel_operation :: proc(t: ^testing.T) {
	ring_memory := make([]u8, ring.PAGE_COUNT * ring.PAGE_SIZE)
	defer delete(ring_memory)
	Case :: struct {
		width, height: int,
		change:        proc(window: ^Window),
		status:        op.Status,
	}
	cases := [?]Case{
		{880, 384, proc(window: ^Window) {window.resizable = false}, .Bad_Operation},
		{880, 384, proc(window: ^Window) {window.resize_asked = false}, .Bad_Operation},
		{881, 384, nil, .Bad_Operation},
		{880, 383, nil, .Bad_Operation},
		{0, 0, nil, .Bad_Operation},
		{-880, -384, nil, .Bad_Operation},
		{880, 384, proc(window: ^Window) {window.size_limits.largest_width = 872}, .Bad_Operation},
		{880, 384, proc(window: ^Window) {
			for ring.push(&window.ring.commands, ring.Record{kind = u32(Command.Picture_Due)}) {}
		}, .No_Slot},
	}
	for each, index in cases {
		for &value in ring_memory {
			value = 0
		}
		window := resizable_window_of_test(ring_memory)
		if each.change != nil {
			each.change(&window)
		}
		before := window
		status := surface_resize(&window, each.width, each.height)
		testing.expectf(t, status == each.status, "case %d gives %v, not %v", index, status, each.status)
		testing.expectf(t, window == before, "case %d changed the window", index)
	}
}

// The error record of a size past the largest limit of a resizable window
// names the axis that passes it: the argument 2 for the width, also a
// width of 0, and 3 for the height. A size below the least size is a clamp
// of the compositor, which the window takes: no error names it.
@(test)
surface_resize_names_the_axis_past_the_largest_limit :: proc(t: ^testing.T) {
	ring_memory := make([]u8, ring.PAGE_COUNT * ring.PAGE_SIZE)
	defer delete(ring_memory)
	cases := [?]struct {
		width, height, argument: int,
	}{{1217, 384, 2}, {0, 384, 2}, {880, 641, 3}}
	for each in cases {
		for &value in ring_memory {
			value = 0
		}
		window := resizable_window_of_test(ring_memory)
		window.resize_asked_width, window.resize_asked_height = each.width, each.height
		error: errors.Error_Record
		status := surface_resize(&window, each.width, each.height, &error)
		testing.expectf(t, status == .Bad_Operation && error.argument == i64(each.argument), "%dx%d gives %v with the argument %d", each.width, each.height, status, error.argument)
	}
}

// The border of a text of the clipboard, refusals first: no byte, one byte
// past the limit, one byte past the room of a field, a byte that starts no
// sequence, a cut sequence, a surrogate, CR, NUL, Escape, DEL, C1 controls
// are refused in both forms. LF and Tab are refused in Single_Line (so a
// paste never runs a line of the console) and taken in Multi_Line. Then
// the texts that hold: one byte, the limit, multi-line UTF-8 with LF, Tab,
// and multi-byte characters.
@(test)
clipboard_text_problem_refuses_each_text_that_is_not_text :: proc(t: ^testing.T) {
	// A long text of a page and one byte; the limit of 1 GiB is tried with
	// a slice of that length that the check refuses before it reads a byte.
	LONG :: 4096
	limit_and_one: [LONG + 1]u8
	for &value in limit_and_one {
		value = 'a'
	}
	past_the_limit := ([^]u8)(&limit_and_one[0])[:CLIPBOARD_TEXT_LIMIT + 1]
	refused_always := [?]struct {
		text:    []u8,
		room:    int,
		problem: Clipboard_Problem,
	}{
		{nil, CLIPBOARD_TEXT_LIMIT, .Empty},
		{past_the_limit, CLIPBOARD_TEXT_LIMIT + 1, .Too_Large},
		{past_the_limit, max(int), .Too_Large},
		{limit_and_one[:], LONG, .Too_Large},
		{limit_and_one[:8], 7, .Too_Large},
		{limit_and_one[:1], 0, .Too_Large},
		{{0xFF}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0xC3}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0xED, 0xA0, 0x80}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{'l', 's', '\r'}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{'a', '\r', '\n', 'b'}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0x01}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0x08}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0x0B}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0x0C}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0x1B, '['}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0x7F}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0xC2, 0x80}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0xC2, 0x85}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0xC2, 0x9F}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{0}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{'a', '\n', 0, 'b'}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
		{{'a', '\n', 0xFF}, CLIPBOARD_TEXT_LIMIT, .Not_Text},
	}
	for form in Clipboard_Text_Form {
		for each, index in refused_always {
			problem := clipboard_text_problem(each.text, each.room, form)
			testing.expectf(t, problem == each.problem, "form %v case %d gives %v, not %v", form, index, problem, each.problem)
		}
	}
	// LF and Tab are refused in Single_Line, accepted in Multi_Line.
	multiline_cases := [?][]u8{
		{'\n'},
		{'\t'},
		{'l', 's', '\n'},
		{'a', '\n', '\t', 'b'},
		{'f', 'i', 'r', 's', 't', '\n', 0xC3, 0xA9, 't', 0xC3, 0xA9, '\n', 0xE2, 0x82, 0xAC},
	}
	for text, index in multiline_cases {
		testing.expectf(t, clipboard_text_problem(text, CLIPBOARD_TEXT_LIMIT, .Single_Line) == .Not_Text, "Single_Line case %d accepted multiline text", index)
		testing.expectf(t, !clipboard_text_valid(text, .Single_Line), "clipboard_text_valid Single_Line case %d accepted multiline text", index)
		testing.expectf(t, clipboard_text_problem(text, CLIPBOARD_TEXT_LIMIT, .Multi_Line) == .None, "Multi_Line case %d refused multiline text", index)
		testing.expectf(t, clipboard_text_valid(text, .Multi_Line), "clipboard_text_valid Multi_Line case %d refused multiline text", index)
	}
	testing.expect_value(t, clipboard_text_problem(limit_and_one[:1], 1, .Single_Line), Clipboard_Problem.None)
	testing.expect_value(t, clipboard_text_problem(limit_and_one[:1], 1, .Multi_Line), Clipboard_Problem.None)
	// A text past the old limit of one page holds: the room bounds it.
	testing.expect_value(t, clipboard_text_problem(limit_and_one[:], LONG + 1, .Single_Line), Clipboard_Problem.None)
	testing.expect_value(t, clipboard_text_problem(limit_and_one[:], LONG + 1, .Multi_Line), Clipboard_Problem.None)
	// Multi-line text at exact room and one past the room.
	multiline_bound := limit_and_one
	multiline_bound[0] = '\n'
	multiline_bound[LONG - 1] = '\n'
	testing.expect_value(t, clipboard_text_problem(multiline_bound[:LONG], LONG, .Multi_Line), Clipboard_Problem.None)
	testing.expect_value(t, clipboard_text_problem(multiline_bound[:LONG + 1], LONG, .Multi_Line), Clipboard_Problem.Too_Large)
	euro := [?]u8{0xE2, 0x82, 0xAC, 'h', 0xC3, 0xA9}
	testing.expect_value(t, clipboard_text_problem(euro[:], len(euro), .Single_Line), Clipboard_Problem.None)
	testing.expect_value(t, clipboard_text_problem(euro[:], len(euro), .Multi_Line), Clipboard_Problem.None)
}

// Each character that a reader does not see, or that changes the order of
// a text, is refused: each range at its first and its last code point, and
// each single one, in both Single_Line and Multi_Line forms. The code
// points just outside each range are taken.
@(test)
clipboard_text_problem_refuses_each_hidden_character :: proc(t: ^testing.T) {
	hidden := [?]rune{0x200B, 0x200F, 0x202A, 0x202E, 0x2066, 0x2069, 0x2028, 0x2029, 0xFEFF}
	for character in hidden {
		text: [8]u8
		text[0] = 'a'
		length := 1 + text_encoding.character_encode(character, text[1:])
		for form in Clipboard_Text_Form {
			problem := clipboard_text_problem(text[:length], CLIPBOARD_TEXT_LIMIT, form)
			testing.expectf(t, problem == .Hidden_Character, "form %v U+%X gives %v", form, character, problem)
		}
		multiline: [10]u8
		multiline[0], multiline[1] = 'a', '\n'
		multiline_length := 2 + text_encoding.character_encode(character, multiline[2:])
		testing.expectf(t, clipboard_text_problem(multiline[:multiline_length], CLIPBOARD_TEXT_LIMIT, .Multi_Line) == .Hidden_Character, "Multi_Line after LF U+%X not refused", character)
		testing.expectf(t, text_encoding.character_hidden(character), "U+%X is not hidden", character)
	}
	shown := [?]rune{0x200A, 0x2010, 0x2027, 0x202F, 0x2065, 0x206A, 0xFEFE, 0xFF00}
	for character in shown {
		text: [8]u8
		length := text_encoding.character_encode(character, text[:])
		for form in Clipboard_Text_Form {
			problem := clipboard_text_problem(text[:length], CLIPBOARD_TEXT_LIMIT, form)
			testing.expectf(t, problem == .None, "form %v U+%X gives %v", form, character, problem)
		}
	}
}

// A Pasted whose words are out of their range is refused, and gives the
// zero event: a handle of 0 and past 32 bits, a kind of None, past the last
// member and the largest word, a count of 0, one past the limit and the
// largest word, a serial of 0. A Copy_Asked with the serial 0 too. Then a
// paste and a copy that hold.
@(test)
event_of_record_refuses_a_paste_out_of_its_range :: proc(t: ^testing.T) {
	TEXT :: u64(Clipboard_Kind.Text)
	refused := [?][4]u64{
		{0, TEXT, 5, 1},
		{u64(max(u32)) + 1, TEXT, 5, 1},
		{max(u64), TEXT, 5, 1},
		{7, u64(Clipboard_Kind.None), 5, 1},
		{7, u64(max(Clipboard_Kind)) + 1, 5, 1},
		{7, max(u64), 5, 1},
		{7, TEXT, 0, 1},
		{7, TEXT, CLIPBOARD_TEXT_LIMIT + 1, 1},
		{7, TEXT, max(u64), 1},
		{7, TEXT, 5, 0},
	}
	for words in refused {
		record := ring.Record{kind = u32(Event_Kind.Pasted)}
		record.values[0], record.values[1], record.values[2], record.values[3] = words[0], words[1], words[2], words[3]
		event, ok := event_of_record(record)
		testing.expectf(t, !ok, "the paste %v is taken", words)
		testing.expect_value(t, event, Event{})
	}
	event, ok := event_of_record(ring.Record{kind = u32(Event_Kind.Copy_Asked)})
	testing.expect(t, !ok)
	testing.expect_value(t, event, Event{})
	record := ring.Record{kind = u32(Event_Kind.Pasted)}
	record.values[0], record.values[1], record.values[2], record.values[3] = u64(max(u32)), TEXT, CLIPBOARD_TEXT_LIMIT, max(u64)
	event, ok = event_of_record(record)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Pasted, paste_handle = op.Handle(max(u32)), clipboard_kind = .Text, byte_count = CLIPBOARD_TEXT_LIMIT, clipboard_serial = max(u64)})
	asked := ring.Record{kind = u32(Event_Kind.Copy_Asked)}
	asked.values[0] = 1
	event, ok = event_of_record(asked)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Copy_Asked, clipboard_serial = 1, copy_action = .Copy})
	asked.values[1] = u64(Copy_Action.Cut)
	event, ok = event_of_record(asked)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Copy_Asked, clipboard_serial = 1, copy_action = .Cut})
	for bad_action in ([?]u64{u64(max(Copy_Action)) + 1, max(u64)}) {
		asked.values[1] = bad_action
		event, ok = event_of_record(asked)
		testing.expectf(t, !ok, "Copy_Asked with action %d is taken", bad_action)
		testing.expect_value(t, event, Event{})
	}
}

// The facts of a paste that holds: 5 bytes of text in one page that the
// compositor gave, for a field of 16 bytes of room.
@(private = "file")
paste_of_test :: proc() -> Paste_Facts {
	return {event = {kind = .Pasted, paste_handle = 7, clipboard_kind = .Text, byte_count = 5, clipboard_serial = 1}, is_memory = true, readable = true, through = true, memory_bytes = 4096, room = 16}
}

// Each refusal of a paste before any byte is read, from the edges: an event
// that is no paste, a kind that is not text, a handle that is no memory,
// with no Read, or that the compositor did not give through the ring, a
// count of 0, a negative count, one byte past the room of the field, past
// the limit, memory one byte too small and of 0 bytes. The pastes that hold
// come last: a count that fills the room, and the memory just large enough.
@(test)
paste_problem_refuses_each_broken_rule :: proc(t: ^testing.T) {
	Case :: struct {
		facts:   Paste_Facts,
		problem: Clipboard_Problem,
	}
	cases: [12]Case
	for &each in cases {
		each.facts = paste_of_test()
	}
	cases[0].facts.event.kind, cases[0].problem = .Key, .Unknown_Kind
	cases[1].facts.event.clipboard_kind, cases[1].problem = .None, .Unknown_Kind
	cases[2].facts.is_memory, cases[2].problem = false, .Not_Given
	cases[3].facts.readable, cases[3].problem = false, .Not_Given
	cases[4].facts.through, cases[4].problem = false, .Not_Given
	cases[5].facts.event.byte_count, cases[5].problem = 0, .Empty
	cases[6].facts.event.byte_count, cases[6].problem = -1, .Empty
	cases[7].facts.event.byte_count, cases[7].problem = 17, .Too_Large
	cases[8].facts.event.byte_count, cases[8].facts.room, cases[8].problem = CLIPBOARD_TEXT_LIMIT + 1, CLIPBOARD_TEXT_LIMIT * 2, .Too_Large
	cases[9].facts.memory_bytes, cases[9].problem = 4, .Too_Small
	cases[10].facts.memory_bytes, cases[10].problem = 0, .Too_Small
	cases[11].facts.room, cases[11].problem = 0, .Too_Large
	for each, index in cases {
		problem := paste_problem(each.facts)
		testing.expectf(t, problem == each.problem, "case %d gives %v, not %v", index, problem, each.problem)
	}
	facts := paste_of_test()
	facts.event.byte_count = 16
	testing.expect_value(t, paste_problem(facts), Clipboard_Problem.None)
	facts.memory_bytes = 16
	testing.expect_value(t, paste_problem(facts), Clipboard_Problem.None)
}

// The kind of a content refuses None, one past the last member and the
// largest word; Text comes back.
@(test)
clipboard_kind_of_word_refuses_a_word_that_names_no_kind :: proc(t: ^testing.T) {
	for word in ([?]u64{u64(Clipboard_Kind.None), u64(max(Clipboard_Kind)) + 1, max(u64)}) {
		kind, ok := clipboard_kind_of_word(word)
		testing.expectf(t, !ok, "the word %d is taken", word)
		testing.expect_value(t, kind, Clipboard_Kind.None)
	}
	kind, ok := clipboard_kind_of_word(u64(Clipboard_Kind.Text))
	testing.expect(t, ok && kind == .Text)
}

// copy_send refuses with no request, and changes nothing: a copy that no
// key of the principal asked for makes no memory and sends no record.
@(test)
copy_send_refuses_a_copy_that_no_key_asked_for :: proc(t: ^testing.T) {
	window: Window
	text := [?]u8{'h', 'i'}
	problem, status := copy_send(&window, text[:])
	testing.expect_value(t, problem, Clipboard_Problem.Not_Asked)
	testing.expect_value(t, status, op.Status.Ok)
	testing.expect_value(t, window, Window{})
	testing.expect(t, !copy_decline(&window))
}

// Each member that is an event comes back from its own kind, with its
// values, last.
@(test)
event_of_record_reads_each_event :: proc(t: ^testing.T) {
	key := ring.Record{kind = u32(Event_Kind.Key)}
	key.values = {KEY_TAB, 'a', 1, MODIFIER_SHIFT, 0, 0, 0}
	event, ok := event_of_record(key)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Key, code = KEY_TAB, character = 'a', pressed = true, modifiers = MODIFIER_SHIFT})

	pointer := ring.Record{kind = u32(Event_Kind.Pointer)}
	left_of_the_surface: i64 = -3
	pointer.values[key_path.POINTER_RECORD_X] = u64(left_of_the_surface)
	pointer.values[key_path.POINTER_RECORD_Y] = 7
	pointer.values[key_path.POINTER_RECORD_BUTTONS] = BUTTON_LEFT
	pointer.values[key_path.POINTER_RECORD_WHEEL] = WHEEL_TOWARD_THE_END
	event, ok = event_of_record(pointer)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Pointer, x = -3, y = 7, buttons = BUTTON_LEFT, wheel = WHEEL_TOWARD_THE_END})

	// Settings_Changed names the scale of the compositor: a word that names
	// no scale refuses the record: 0, 7 under the scale 1, 17 past 2, and the
	// largest word.
	settings_changed := ring.Record{kind = u32(Event_Kind.Settings_Changed)}
	for word in ([?]u64{0, scale_factor.EIGHTHS_OF_ONE - 1, u64(scale_factor.Scale.Sixteen_Eighths) + 1, max(u64)}) {
		settings_changed.values[1] = word
		_, scale_ok := event_of_record(settings_changed)
		testing.expectf(t, !scale_ok, "a Settings_Changed with the scale word %d is taken", word)
	}
	// The count of the windows that declined the scale: one past its limit
	// and the largest word are refused; the limit is taken.
	settings_changed.values[1] = u64(scale_factor.Scale.Eleven_Eighths)
	for word in ([?]u64{WINDOWS_DECLINED_LIMIT + 1, max(u64)}) {
		settings_changed.values[2] = word
		_, declined_ok := event_of_record(settings_changed)
		testing.expectf(t, !declined_ok, "a Settings_Changed that counts %d windows is taken", word)
	}
	settings_changed.values[2] = WINDOWS_DECLINED_LIMIT
	limit_event, limit_ok := event_of_record(settings_changed)
	testing.expect(t, limit_ok && limit_event.windows_declined == WINDOWS_DECLINED_LIMIT)
	settings_changed.values[2] = 0
	event, ok = event_of_record(settings_changed)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Settings_Changed, scale = .Eleven_Eighths})

	// Surface_Answer: a word of no answer and the serial 0 are refused.
	answer := ring.Record{kind = u32(Event_Kind.Surface_Answer)}
	for words in ([?][2]u64{{0, 1}, {u64(max(Surface_Answer_Kind)) + 1, 1}, {max(u64), 1}, {u64(Surface_Answer_Kind.Released), 0}}) {
		answer.values[0], answer.values[1] = words[0], words[1]
		_, answer_ok := event_of_record(answer)
		testing.expectf(t, !answer_ok, "the answer %v is taken", words)
	}
	answer.values[0], answer.values[1] = u64(Surface_Answer_Kind.Rescale_Taken), 3
	event, ok = event_of_record(answer)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Surface_Answer, surface_answer = .Rescale_Taken, surface_serial = 3})

	// A hash is 32 bits: the first word past them and the largest word
	// name no act name.
	go_to := ring.Record{kind = u32(Event_Kind.Go_To)}
	for word in ([?]u64{u64(max(u32)) + 1, max(u64)}) {
		go_to.values[0] = word
		_, go_to_ok := event_of_record(go_to)
		testing.expectf(t, !go_to_ok, "the act %x is taken", word)
	}
	go_to.values[0] = u64(max(u32))
	event, ok = event_of_record(go_to)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Go_To, act = max(u32)})
	go_to.values[0] = u64(act_name_hash("settings.set:font"))
	event, ok = event_of_record(go_to)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Go_To, act = act_name_hash("settings.set:font")})
}

// The record of a set of act names: two hashes of 32 bits in each value
// after the count. The border refuses each value that no window layer
// writes, and gives back each set that one writes, up to the capacity.
@(test)
the_record_of_the_act_names :: proc(t: ^testing.T) {
	hashes: [ACT_NAME_SET_CAPACITY + 1]u32
	for &hash, index in hashes {
		hash = act_name_hash(string([]u8{u8('a' + index)}))
	}
	// Each count from 0 to the capacity comes back whole and in order.
	for count in 0 ..= ACT_NAME_SET_CAPACITY {
		values := act_names_values(hashes[:count])
		back, back_count, ok := act_names_of_values(values)
		testing.expectf(t, ok && back_count == count, "the set of %d hashes gave %d, ok %v", count, back_count, ok)
		for index in 0 ..< count {
			testing.expectf(t, back[index] == hashes[index], "the set of %d hashes changed the hash %d", count, index)
		}
	}
	// One past the capacity: the record keeps the first ones.
	values := act_names_values(hashes[:])
	testing.expect_value(t, values[0], u64(ACT_NAME_SET_CAPACITY))
	// A count past the capacity, the largest word as a count.
	for count in ([?]u64{ACT_NAME_SET_CAPACITY + 1, max(u64)}) {
		refused := act_names_values(hashes[:ACT_NAME_SET_CAPACITY])
		refused[0] = count
		_, _, ok := act_names_of_values(refused)
		testing.expectf(t, !ok, "the count %d is taken", count)
	}
	// A hash of 0 in the count: in the low half and in the high half.
	for place in 0 ..< 2 {
		refused := act_names_values(hashes[:2])
		refused[1] &= place == 0 ? 0xFFFF_FFFF_0000_0000 : 0x0000_0000_FFFF_FFFF
		_, _, ok := act_names_of_values(refused)
		testing.expectf(t, !ok, "a hash of 0 at the place %d is taken", place)
	}
	// A hash after the count: the high half of the last value in use, and
	// the last value of the record.
	odd := act_names_values(hashes[:1])
	odd[1] |= u64(hashes[1]) << 32
	_, _, odd_ok := act_names_of_values(odd)
	testing.expect(t, !odd_ok)
	last := act_names_values(hashes[:1])
	last[6] = 1
	_, _, last_ok := act_names_of_values(last)
	testing.expect(t, !last_ok)
}

// The pages of the copies of the service of the remote display, as the root
// service counts them for a growth (memory_screen.service_copies_pages), are
// the pages that the service makes: the capture face and the copy of the
// screen, at each bound and at the screens between.
@(test)
the_pages_of_the_copies_agree_with_the_screen_of_memory :: proc(t: ^testing.T) {
	for size in ([?][2]int{{320, 240}, {1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}, {7680, 4320}, {321, 241}}) {
		mirror := (u64(size[0] * size[1] * 4) + 4095) / 4096
		testing.expectf(t, capture_pages(size[0], size[1]) + mirror == memory_screen.service_copies_pages(u64(size[0]), u64(size[1])), "%v", size)
	}
}
