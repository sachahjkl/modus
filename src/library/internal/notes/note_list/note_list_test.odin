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
	none: Change_Wait
	testing.expect(t, !change_wait_due(&none, max(u64)), "no change waits: nothing is due")
	_, has_deadline := change_wait_deadline(&none)
	testing.expect(t, !has_deadline)
	wait: Change_Wait
	change_wait_mark(&wait, 100)
	testing.expect(t, !change_wait_due(&wait, 100))
	testing.expect(t, !change_wait_due(&wait, 100 + PAUSE_MILLISECONDS - 1))
	testing.expect(t, change_wait_due(&wait, 100 + PAUSE_MILLISECONDS))
	testing.expect(t, !change_wait_due(&wait, 10), "a clock that went back")
	testing.expect(t, change_wait_due(&wait, max(u64)))
	deadline, has := change_wait_deadline(&wait)
	testing.expect(t, has)
	testing.expect_value(t, deadline, u64(100 + PAUSE_MILLISECONDS))
	late: Change_Wait
	change_wait_mark(&late, max(u64) - 1)
	deadline, _ = change_wait_deadline(&late)
	testing.expect_value(t, deadline, max(u64))
}

// Keys less than a second apart do not hold the commit back: it is due 5
// seconds after the first change that waits. A refused commit starts the
// wait again from the refusal.
@(test)
a_change_is_due_at_most_5_seconds_after_the_first_change :: proc(t: ^testing.T) {
	wait: Change_Wait
	now := u64(1000)
	change_wait_mark(&wait, now)
	for now < 1000 + LONGEST_WAIT_MILLISECONDS - 500 {
		now += 500
		change_wait_mark(&wait, now)
		testing.expectf(t, !change_wait_due(&wait, now), "at %d: no pause, and under 5 s", now)
	}
	testing.expect_value(t, wait.first_change, u64(1000))
	testing.expect(t, !change_wait_due(&wait, 1000 + LONGEST_WAIT_MILLISECONDS - 1))
	testing.expect(t, change_wait_due(&wait, 1000 + LONGEST_WAIT_MILLISECONDS))
	deadline, _ := change_wait_deadline(&wait)
	testing.expect_value(t, deadline, u64(1000 + LONGEST_WAIT_MILLISECONDS))
	change_wait_again(&wait, 7000)
	testing.expect(t, !change_wait_due(&wait, 7000), "a refusal is not due at once")
	deadline, _ = change_wait_deadline(&wait)
	testing.expect_value(t, deadline, u64(7000 + PAUSE_MILLISECONDS))
	wait.waiting = false
	change_wait_mark(&wait, 20_000)
	testing.expect_value(t, wait.first_change, u64(20_000))
}

// A refused write marks only the note whose write failed: other notes stay
// kept, and a successful write of another note does not clear the first.
@(test)
write_refused_is_tracked_per_note :: proc(t: ^testing.T) {
	list := new(Note_List)
	defer free(list)
	list_reset(list)
	// Edges: empty list, empty name, unknown name, out-of-range indices.
	for bad in ([?]int{-1, 0, 1, NOTE_CAPACITY, max(int), min(int)}) {
		testing.expect(t, !note_is_write_refused(list, bad))
	}
	index, found := note_write_done(list, "", false, 0)
	testing.expect(t, !found && index == -1)
	index, found = note_write_done(list, "note_000001", false, 0)
	testing.expect(t, !found && index == -1)

	first, _ := list_add_stored(list, "note_000001", transmute([]u8)string("one"), 10)
	second, _ := list_add_stored(list, "note_000002", transmute([]u8)string("two"), 20)
	testing.expect(t, !note_is_write_refused(list, first))
	testing.expect(t, !note_is_write_refused(list, second))

	// Refusing a write on the first note leaves the second note kept.
	index, found = note_write_done(list, "note_000001", false, 99)
	testing.expect(t, found && index == first)
	testing.expect(t, note_is_write_refused(list, first))
	testing.expect(t, !note_is_write_refused(list, second))
	testing.expect_value(t, list.notes[first].generation, i64(10))

	// A write that succeeds on the second note updates only the second note.
	index, found = note_write_done(list, "note_000002", true, 25)
	testing.expect(t, found && index == second)
	testing.expect(t, note_is_write_refused(list, first))
	testing.expect(t, !note_is_write_refused(list, second))
	testing.expect_value(t, list.notes[second].generation, i64(25))

	// A write of an unknown name changes nothing.
	index, found = note_write_done(list, "note_000099", true, 30)
	testing.expect(t, !found && index == -1)
	testing.expect(t, note_is_write_refused(list, first))

	// A write that succeeds on the first note clears its refusal and updates
	// its generation.
	index, found = note_write_done(list, "note_000001", true, 31)
	testing.expect(t, found && index == first)
	testing.expect(t, !note_is_write_refused(list, first))
	testing.expect_value(t, list.notes[first].generation, i64(31))

	// Removing a refused note shifts the remaining notes without leaking its flag.
	_, _ = note_write_done(list, "note_000001", false, 0)
	testing.expect(t, note_is_write_refused(list, first))
	shown, _ := list_remove(list, first)
	testing.expect_value(t, shown, 0)
	testing.expect_value(t, note_name(&list.notes[0]), "note_000002")
	testing.expect(t, !note_is_write_refused(list, 0))
}

// Titles reach the full 255-byte STORAGE7 format limit, and the list crosses
// its 256-note inline capacity into its caller-supplied overflow tier cleanly.
@(test)
note_list_255_byte_titles_and_overflow_tier :: proc(t: ^testing.T) {
	testing.expect_value(t, TITLE_BYTES, 255)
	long_255 := strings.repeat("a", 255, context.temp_allocator)
	title, count := title_of(transmute([]u8)long_255)
	testing.expect_value(t, count, 255)
	testing.expect_value(t, string(title[:count]), long_255)

	Grow_Ctx :: struct {
		backing: [dynamic]Note,
		limit:   int,
	}
	grow_notes :: proc "contextless" (user_data: rawptr, current: []Note, minimum_notes: int) -> (grown: []Note, ok: bool) {
		ctx := (^Grow_Ctx)(user_data)
		if minimum_notes > ctx.limit {
			return nil, false
		}
		target := min(ctx.limit, max(minimum_notes, max(len(current) * 2, NOTE_CAPACITY + 128)))
		return ctx.backing[:target], true
	}

	list := new(Note_List)
	defer free(list)
	list_reset(list)
	ctx := Grow_Ctx{limit = 600}
	resize(&ctx.backing, 600)
	defer delete(ctx.backing)
	list_init_overflow(list, nil, grow_notes, &ctx)

	// Fill inline tier: zero overflow moves.
	for i in 0 ..< NOTE_CAPACITY {
		_, prob := list_add_new(list)
		testing.expect_value(t, prob, List_Problem.None)
		testing.expect_value(t, note_name_take(list, i), List_Problem.None)
	}
	testing.expect(t, !list_on_overflow(list))
	testing.expect_value(t, list.overflow_moves, u64(0))

	// Crossing 256 -> 257 moves to overflow tier with 255-byte title intact.
	idx_257, prob_257 := list_add_stored(list, "note_000900", transmute([]u8)long_255, 900)
	testing.expect_value(t, prob_257, List_Problem.None)
	testing.expect_value(t, idx_257, NOTE_CAPACITY)
	testing.expect(t, list_on_overflow(list))
	testing.expect_value(t, list.overflow_moves, u64(1))
	testing.expect_value(t, note_title(note_at(list, idx_257)), long_255)
	testing.expect_value(t, note_find(list, "note_000900"), idx_257)
	testing.expect_value(t, list_newest(list), idx_257)

	// Grow to 600 notes (second overflow growth) and refuse 601 cleanly.
	for list.count < 600 {
		_, p := list_add_new(list)
		testing.expect_value(t, p, List_Problem.None)
	}
	testing.expect(t, list.overflow_moves >= 2)
	_, full_prob := list_add_new(list)
	testing.expect_value(t, full_prob, List_Problem.Full)
	testing.expect_value(t, list.count, 600)

	// Copy into a separate list with its own backing: neither aliases the other.
	dst := new(Note_List)
	defer free(dst)
	dst_ctx := Grow_Ctx{limit = 600}
	resize(&dst_ctx.backing, 600)
	defer delete(dst_ctx.backing)
	list_init_overflow(dst, nil, grow_notes, &dst_ctx)
	testing.expect_value(t, list_copy_from(dst, list), List_Problem.None)
	testing.expect_value(t, dst.count, 600)
	testing.expect_value(t, note_title(note_at(dst, idx_257)), long_255)

	// Copy into an unbacked list refuses with Full without changing dst.
	unbacked := new(Note_List)
	defer free(unbacked)
	list_reset(unbacked)
	_, _ = list_add_stored(unbacked, "keep", transmute([]u8)string("kept"), 1)
	testing.expect_value(t, list_copy_from(unbacked, list), List_Problem.Full)
	testing.expect_value(t, unbacked.count, 1)
	testing.expect_value(t, note_name(note_at(unbacked, 0)), "keep")
}

