#+build !freestanding
package note_list

import "core:strings"
import "core:testing"

@(test)
a_title_is_the_first_line_cut_after_a_whole_character :: proc(t: ^testing.T) {
	title, count := title_of(transmute([]u8)string("first line\nsecond"))
	testing.expect_value(t, string(title[:count]), "first line")
	_, count = title_of(nil)
	testing.expect_value(t, count, 0)
	_, count = title_of(transmute([]u8)string("\nsecond"))
	testing.expect_value(t, count, 0)
	title, count = title_of(transmute([]u8)string("a\tb"))
	testing.expect_value(t, string(title[:count]), "a b")
	// TITLE_BYTES - 1 bytes, then a character of two bytes: it does not
	// fit, and the title ends before it.
	long := strings.concatenate({strings.repeat("x", TITLE_BYTES - 1, context.temp_allocator), "é"}, context.temp_allocator)
	title, count = title_of(transmute([]u8)long)
	testing.expect_value(t, count, TITLE_BYTES - 1)
	exact := strings.repeat("y", TITLE_BYTES + 5, context.temp_allocator)
	_, count = title_of(transmute([]u8)exact)
	testing.expect_value(t, count, TITLE_BYTES)
	// The first bytes of an object can end inside a character, or hold a
	// byte that is not text: the title stops before it.
	cut := [?]u8{'a', 'b', 0xC3}
	title, count = title_of(cut[:])
	testing.expect_value(t, string(title[:count]), "ab")
	control := [?]u8{'a', 0x01, 'b'}
	title, count = title_of(control[:])
	testing.expect_value(t, string(title[:count]), "a")
	invalid := [?]u8{0xFF, 'a'}
	_, count = title_of(invalid[:])
	testing.expect_value(t, count, 0)
}

@(test)
only_a_name_of_the_prefix_and_six_digits_has_a_serial :: proc(t: ^testing.T) {
	serial, ok := serial_of_name("note_000042")
	testing.expect(t, ok)
	testing.expect_value(t, serial, u64(42))
	serial, ok = serial_of_name("note_999999")
	testing.expect(t, ok)
	testing.expect_value(t, serial, u64(SERIAL_LIMIT))
	refused := [?]string{"", "note_", "note_000000", "note_00001", "note_0000001", "note_00000a", "Note_000001", "copy", "note_-00001", "note_ 00001"}
	for name in refused {
		_, ok = serial_of_name(name)
		testing.expectf(t, !ok, "the name %q has no serial", name)
	}
}

@(test)
a_serial_past_its_limit_or_zero_has_no_name :: proc(t: ^testing.T) {
	buffer: [NAME_BYTES]u8
	count, ok := name_of_serial(1, &buffer)
	testing.expect(t, ok)
	testing.expect_value(t, string(buffer[:count]), "note_000001")
	count, ok = name_of_serial(SERIAL_LIMIT, &buffer)
	testing.expect(t, ok)
	testing.expect_value(t, string(buffer[:count]), "note_999999")
	for serial in ([?]u64{0, SERIAL_LIMIT + 1, max(u64)}) {
		_, ok = name_of_serial(serial, &buffer)
		testing.expectf(t, !ok, "the serial %d has no name", serial)
	}
}

@(test)
the_list_refuses_a_bad_name_a_full_list_and_a_place_out_of_it :: proc(t: ^testing.T) {
	list := new(Note_List)
	defer free(list)
	list_reset(list)
	_, problem := list_add_stored(list, "", nil, 1)
	testing.expect_value(t, problem, List_Problem.Name_Invalid)
	_, problem = list_add_stored(list, strings.repeat("n", NAME_BYTES + 1, context.temp_allocator), nil, 1)
	testing.expect_value(t, problem, List_Problem.Name_Invalid)
	testing.expect_value(t, list.count, 0)
	// A name of NAME_BYTES bytes is taken.
	_, problem = list_add_stored(list, strings.repeat("n", NAME_BYTES, context.temp_allocator), nil, 1)
	testing.expect_value(t, problem, List_Problem.None)
	for list.count < NOTE_CAPACITY {
		_, problem = list_add_new(list)
		testing.expect_value(t, problem, List_Problem.None)
	}
	_, problem = list_add_new(list)
	testing.expect_value(t, problem, List_Problem.Full)
	_, problem = list_add_stored(list, "copy", nil, 2)
	testing.expect_value(t, problem, List_Problem.Full)
	testing.expect_value(t, list.count, NOTE_CAPACITY)
	for index in ([?]int{-1, NOTE_CAPACITY, max(int), min(int)}) {
		_, problem = list_remove(list, index)
		testing.expect_value(t, problem, List_Problem.No_Place)
		testing.expect_value(t, note_name_take(list, index), List_Problem.No_Place)
	}
	testing.expect_value(t, list.count, NOTE_CAPACITY)
}

@(test)
a_new_note_takes_the_serial_after_the_largest_of_the_store :: proc(t: ^testing.T) {
	list := new(Note_List)
	defer free(list)
	list_reset(list)
	list_add_stored(list, "copy", transmute([]u8)string("a copy"), 7)
	list_add_stored(list, "note_000009", transmute([]u8)string("nine"), 9)
	list_add_stored(list, "note_000003", transmute([]u8)string("three"), 3)
	index, _ := list_add_new(list)
	testing.expect_value(t, note_name_take(list, index), List_Problem.None)
	testing.expect_value(t, note_name(&list.notes[index]), "note_000010")
	// A second take keeps the name.
	testing.expect_value(t, note_name_take(list, index), List_Problem.None)
	testing.expect_value(t, note_name(&list.notes[index]), "note_000010")
	testing.expect_value(t, list_newest(list), 1)
	testing.expect_value(t, note_title(&list.notes[0]), "a copy")
}

@(test)
the_last_serial_ends_the_new_names :: proc(t: ^testing.T) {
	list := new(Note_List)
	defer free(list)
	list_reset(list)
	list_add_stored(list, "note_999999", nil, 1)
	testing.expect_value(t, list.next_serial, u64(0))
	index, _ := list_add_new(list)
	testing.expect_value(t, note_name_take(list, index), List_Problem.No_Serial)
	testing.expect_value(t, list.notes[index].name_count, 0)
	// A smaller serial after it does not give the names back.
	list_add_stored(list, "note_000001", nil, 2)
	testing.expect_value(t, list.next_serial, u64(0))
}

@(test)
a_removal_shows_the_next_note_or_the_one_before_the_last :: proc(t: ^testing.T) {
	list := new(Note_List)
	defer free(list)
	list_reset(list)
	list_add_stored(list, "note_000001", transmute([]u8)string("one"), 1)
	list_add_stored(list, "note_000002", transmute([]u8)string("two"), 2)
	list_add_stored(list, "note_000003", transmute([]u8)string("three"), 3)
	shown, problem := list_remove(list, 1)
	testing.expect_value(t, problem, List_Problem.None)
	testing.expect_value(t, shown, 1)
	testing.expect_value(t, note_title(&list.notes[1]), "three")
	shown, _ = list_remove(list, 1)
	testing.expect_value(t, shown, 0)
	shown, _ = list_remove(list, 0)
	testing.expect_value(t, shown, -1)
	testing.expect_value(t, list.count, 0)
	testing.expect_value(t, list_newest(list), -1)
}

@(test)
a_pause_ends_only_after_its_time_and_never_on_a_clock_that_went_back :: proc(t: ^testing.T) {
	testing.expect(t, !pause_ended(false, 0, max(u64)))
	testing.expect(t, !pause_ended(true, 100, 100))
	testing.expect(t, !pause_ended(true, 100, 100 + PAUSE_MILLISECONDS - 1))
	testing.expect(t, pause_ended(true, 100, 100 + PAUSE_MILLISECONDS))
	testing.expect(t, !pause_ended(true, 5000, 10))
	testing.expect(t, pause_ended(true, 0, max(u64)))
	_, has_deadline := pause_deadline(false, 10)
	testing.expect(t, !has_deadline)
	deadline, has := pause_deadline(true, 10)
	testing.expect(t, has)
	testing.expect_value(t, deadline, u64(10 + PAUSE_MILLISECONDS))
	deadline, _ = pause_deadline(true, max(u64) - 1)
	testing.expect_value(t, deadline, max(u64))
}
