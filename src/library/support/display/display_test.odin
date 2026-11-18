#+build !freestanding
package display

import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/key_path"
import "core:testing"

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
// A refused record gives the zero event, so nothing of it reaches a program.
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
// refused: the program never makes a surface of that size. The words that
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

	settings_changed := ring.Record{kind = u32(Event_Kind.Settings_Changed)}
	event, ok = event_of_record(settings_changed)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Settings_Changed})

	go_to := ring.Record{kind = u32(Event_Kind.Go_To)}
	go_to.values[0] = act_name_hash("settings.set:font")
	event, ok = event_of_record(go_to)
	testing.expect(t, ok)
	testing.expect_value(t, event, Event{kind = .Go_To, act = act_name_hash("settings.set:font")})
}
