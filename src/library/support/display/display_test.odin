#+build !freestanding
package display

import "modus:contract/ring"
import "modus:support/key_path"
import "core:testing"

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
