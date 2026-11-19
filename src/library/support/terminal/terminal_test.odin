#+build !freestanding
package terminal_records

import op "modus:contract/operation"
import "modus:contract/ring"
import "modus:support/system"
import "core:testing"

// The context of a terminal, as the root service starts it. A slot and a
// value that the caller wrote already are refused first, and the handles
// of the terminal stay out of them; then the whole layout: each slot with
// its handle and its rights, the text region with Read only, the name and
// the size of the window, and no refusal.
@(test)
the_context_of_a_terminal_takes_each_place_once :: proc(t: ^testing.T) {
	handles := Terminal_Handles{display = 11, ring = 12, text = 13, writer = 14, log = {handle = 15, rights = {.Write}}}
	name := system.name_pack("flood")
	taken_grants: system.Context_Grants
	taken_values: system.Context_Values
	system.grant_put(&taken_grants, GRANT_TEXT, {handle = 99, rights = {.Read, .Write}})
	system.value_put(&taken_values, VALUE_ROWS, 7)
	context_of(&taken_grants, &taken_values, handles, name, COLUMNS_LIMIT, ROWS_LIMIT, true)
	testing.expect_value(t, taken_grants.refusal, system.Context_Refusal{refused = true, place = GRANT_TEXT})
	testing.expect_value(t, taken_grants.grants[GRANT_TEXT].handle, system.Handle(99))
	testing.expect_value(t, taken_values.refusal, system.Context_Refusal{refused = true, place = VALUE_ROWS})
	testing.expect_value(t, taken_values.values[VALUE_ROWS], u64(7))
	grants: system.Context_Grants
	values: system.Context_Values
	context_of(&grants, &values, handles, name, COLUMNS_LIMIT, ROWS_LIMIT, true)
	_, _, refused := system.context_refusal_of(&grants, &values)
	testing.expect(t, !refused)
	testing.expect_value(t, grants.grants[system.GRANT_DISPLAY], system.Grant{handle = 11, rights = {.Read, .Write}})
	testing.expect_value(t, grants.grants[GRANT_RING], system.Grant{handle = 12, rights = {.Read, .Write}})
	testing.expect_value(t, grants.grants[GRANT_TEXT], system.Grant{handle = 13, rights = {.Read}})
	testing.expect_value(t, grants.grants[GRANT_PROCESS], system.Grant{handle = 14, rights = {.Read}})
	testing.expect_value(t, grants.grants[op.CONTEXT_LOG], handles.log)
	testing.expect_value(t, grants.taken, bit_set[0 ..< op.CONTEXT_HANDLES; u32]{system.GRANT_DISPLAY, GRANT_RING, GRANT_TEXT, GRANT_PROCESS, op.CONTEXT_LOG})
	for word, index in name {
		testing.expect_value(t, values.values[VALUE_NAME + index], word)
	}
	testing.expect_value(t, values.values[VALUE_COLUMNS], u64(COLUMNS_LIMIT))
	testing.expect_value(t, values.values[VALUE_ROWS], u64(ROWS_LIMIT))
	testing.expect_value(t, values.values[VALUE_MEASURE], u64(1))
}

// The process of a terminal writes the kind of each record of the terminal
// ring: None, one past the last kind and the largest word are refused, and
// give None. Then each kind but None comes back from its word.
@(test)
kind_of_ring_word_refuses_a_word_that_names_no_record :: proc(t: ^testing.T) {
	refused := [?]u32{u32(Kind.None), u32(max(Kind)) + 1, max(u32)}
	for word in refused {
		read, ok := kind_of_ring_word(word)
		testing.expectf(t, !ok, "the word %d names no record, and it is taken", word)
		testing.expect_value(t, read, Kind.None)
	}
	for member in Kind {
		if member != .None {
			read, ok := kind_of_ring_word(u32(member))
			testing.expect(t, ok)
			testing.expect_value(t, read, member)
		}
	}
}

// The terminal writes the kind of each input record. A kind that names no
// input is refused first: None, one past the last kind, the largest kind.
// A refused record gives the zero record. Then each input comes back with
// its values, the first row of the list cut to the largest i32.
@(test)
input_of_record_refuses_a_kind_that_names_no_input :: proc(t: ^testing.T) {
	refused_kinds := [?]u32{u32(Input.None), u32(max(Input)) + 1, 1 << 31, max(u32)}
	for kind in refused_kinds {
		record := ring.Record{kind = kind, tag = max(u32)}
		for &value in record.values {
			value = max(u64)
		}
		given, ok := input_of_record(record)
		testing.expectf(t, !ok, "the kind %d names no input, and it is taken", kind)
		testing.expect_value(t, given, Input_Record{})
	}
	key_record := ring.Record{kind = u32(Input.Key), tag = 0x1C}
	key_record.values[0] = 0x11_0000 // Past the last code point: no character.
	key_record.values[1] = 2
	given, ok := input_of_record(key_record)
	testing.expect(t, ok)
	testing.expect_value(t, given, Input_Record{kind = .Key, key = {code = 0x1C, character = 0, modifiers = 2}})
	// The serial of the compositor comes back as it is, the largest too.
	key_record.values[2] = max(u64)
	given, ok = input_of_record(key_record)
	testing.expect(t, ok)
	testing.expect_value(t, given.key.serial, max(u64))
	list_record := ring.Record{kind = u32(Input.List_First)}
	list_record.values[0] = max(u64)
	given, ok = input_of_record(list_record)
	testing.expect(t, ok)
	testing.expect_value(t, given, Input_Record{kind = .List_First, list_first = int(max(i32))})
	list_record.values[0] = 3
	given, ok = input_of_record(list_record)
	testing.expect(t, ok)
	testing.expect_value(t, given, Input_Record{kind = .List_First, list_first = 3})
}

// The key serial of an Edit record is kept only up to the newest serial
// that the terminal forwarded: the largest word and one past it are
// refused and change nothing; an older serial keeps the newer one; 0 is
// taken and changes nothing.
@(test)
edit_key_serial_take_refuses_a_serial_that_was_not_forwarded :: proc(t: ^testing.T) {
	kept: u64
	testing.expect(t, edit_key_serial_take(&kept, max(u64), 10))
	testing.expect_value(t, kept, 0)
	testing.expect(t, edit_key_serial_take(&kept, 11, 10))
	testing.expect_value(t, kept, 0)
	testing.expect(t, edit_key_serial_take(&kept, 1, 0), "a serial with no key forwarded was taken")
	testing.expect(t, !edit_key_serial_take(&kept, 0, 10))
	testing.expect_value(t, kept, 0)
	testing.expect(t, !edit_key_serial_take(&kept, 10, 10))
	testing.expect_value(t, kept, 10)
	testing.expect(t, !edit_key_serial_take(&kept, 4, 10))
	testing.expect_value(t, kept, 10)
}

// The form of a hint line for a width: the long form when it fits, the
// short form when the long one does not, each cut to the width.
@(test)
hint_form_for_each_width :: proc(t: ^testing.T) {
	Case :: struct {
		long_count, short_count, columns: int,
		form:                             Hint_Form,
		shown:                            int,
	}
	cases := [?]Case {
		{60, 30, 104, .Long, 60}, // The long form fits.
		{104, 30, 104, .Long, 104}, // It fits exactly.
		{105, 30, 104, .Short, 30}, // One cell too long: the short form.
		{120, 50, 40, .Short, 40}, // Both too long: the short form, cut.
		{120, 0, 40, .Long, 40}, // No short form: the long form, cut.
		{0, 0, 40, .Long, 0}, // No hint.
		{50, 20, -3, .Short, 0}, // A width under zero shows nothing.
	}
	for item, index in cases {
		form, shown := hint_form_choose(item.long_count, item.short_count, item.columns)
		testing.expectf(t, form == item.form && shown == item.shown, "case %d: %v %d cells, not %v %d cells", index, form, shown, item.form, item.shown)
	}
}

// A record takes the start of a text that ends after a whole character:
// "é" is two bytes, and a cut between them moves before it.
@(test)
a_record_cuts_after_a_whole_character :: proc(t: ^testing.T) {
	testing.expect_value(t, record_part("café", 10), 5)
	testing.expect_value(t, record_part("café", 4), 3)
	testing.expect_value(t, record_part("café", 5), 5)
	testing.expect_value(t, record_part("é", 1), 0)
	testing.expect_value(t, record_part("abc", 0), 0)
	// A long text of "é": each record of RUN_LIMIT bytes takes whole characters.
	// "a", then 128 times "é": the byte RUN_LIMIT - 1 is the first byte of
	// the last "é".
	long: [RUN_LIMIT + 1]u8
	long[0] = 'a'
	for index := 1; index + 1 < len(long); index += 2 {
		long[index], long[index + 1] = 0xC3, 0xA9
	}
	testing.expect_value(t, record_part(string(long[:]), RUN_LIMIT), RUN_LIMIT - 1)
}

// A List with no rows of its own shows empty rows, not the rows of the list
// before; the rows of a list are forgotten when the process stops; each
// value of the process is brought inside its array.
@(test)
list_rows_go_to_one_list :: proc(t: ^testing.T) {
	keeping: List_Keeping
	name := "monitor.count"
	list_keep_row(&keeping, {0 = 0, 1 = 7, 2 = 1}, transmute([]u8)name, nil)
	list_keep_show(&keeping, {0 = 1, 1 = 0, 3 = 1})
	testing.expect_value(t, keeping.shown.row_count, 1)
	testing.expect_value(t, string(keeping.shown.rows[0].text[:keeping.shown.rows[0].length]), "monitor.count")
	testing.expect_value(t, keeping.shown.rows[0].name_length, 7)
	testing.expect_value(t, keeping.shown.chosen, 0)

	// A List of 8 rows with no List_Row before it.
	list_keep_show(&keeping, {0 = 8, 1 = NO_CHOICE})
	testing.expect_value(t, keeping.shown.row_count, LIST_ROWS)
	for row, index in keeping.shown.rows {
		testing.expectf(t, row.length == 0, "row %d of the second list is empty, not a row of the list before", index)
	}
	testing.expect_value(t, keeping.shown.chosen, -1)
}

// A number that names no icon refuses its row: the row is not kept, and
// the refusal is counted. A row keeps the icon that its process names; a
// row with no icon after a row with one has none.
@(test)
list_row_keeps_the_icon_of_its_kind :: proc(t: ^testing.T) {
	keeping: List_Keeping
	name := "monitor"
	list_keep_row(&keeping, {0 = 1, 1 = 7, 4 = u64(max(List_Icon)) + 1}, transmute([]u8)name, nil)
	list_keep_row(&keeping, {0 = 2, 1 = 7, 4 = 1 << 32}, transmute([]u8)name, nil)
	list_keep_row(&keeping, {0 = 3, 1 = 7, 4 = max(u64)}, transmute([]u8)name, nil)
	testing.expect_value(t, keeping.rows_refused, 3)
	for row in keeping.next {
		testing.expect_value(t, row.length, 0)
	}
	list_keep_row(&keeping, {0 = 0, 1 = 7, 4 = u64(List_Icon.Module)}, transmute([]u8)name, nil)
	list_keep_row(&keeping, {0 = 1, 1 = 7, 4 = u64(max(List_Icon))}, transmute([]u8)name, nil)
	list_keep_show(&keeping, {0 = 2, 1 = NO_CHOICE})
	testing.expect_value(t, keeping.rows_refused, 3)
	testing.expect_value(t, keeping.shown.rows[0].icon, List_Icon.Module)
	testing.expect_value(t, keeping.shown.rows[1].icon, max(List_Icon))
	list_keep_row(&keeping, {0 = 0, 1 = 7}, transmute([]u8)name, nil)
	list_keep_show(&keeping, {0 = 1, 1 = NO_CHOICE})
	testing.expect_value(t, keeping.shown.rows[0].icon, List_Icon.None)
}

@(test)
list_values_of_a_hostile_process :: proc(t: ^testing.T) {
	keeping: List_Keeping
	long: [RUN_LIMIT + 50]u8
	list_keep_row(&keeping, {0 = LIST_ROWS}, long[:], nil) // A row past the rows: not kept.
	list_keep_row(&keeping, {0 = 2, 1 = 1_000_000}, long[:10], long[:20])
	testing.expect_value(t, keeping.next[2].length, 30)
	testing.expect_value(t, keeping.next[2].name_length, 30)
	list_keep_show(&keeping, {0 = 1_000, 1 = 1_000, 2 = max(u64), 3 = 5, 4 = max(u64)})
	testing.expect_value(t, keeping.shown.row_count, LIST_ROWS)
	testing.expect_value(t, keeping.shown.chosen, -1)
	testing.expect_value(t, keeping.shown.total, LIST_ROWS)
	testing.expect_value(t, keeping.shown.first, 0)
	testing.expect_value(t, keeping.shown.anchor, RUN_LIMIT)
	list_keep_forget(&keeping)
	testing.expect_value(t, keeping.shown.row_count, 0)
	testing.expect_value(t, keeping.shown.rows[2].length, 0)
}

// A line longer than a record ends with the cut mark; a line that fits is
// the same text.
@(test)
record_text_of_a_long_line :: proc(t: ^testing.T) {
	buffer: [RUN_LIMIT]u8
	testing.expect_value(t, record_text("a short line", &buffer), "a short line")
	long: [RUN_LIMIT + 44]u8
	for &b in long {
		b = 'x'
	}
	text := record_text(string(long[:]), &buffer)
	testing.expect_value(t, len(text), RUN_LIMIT)
	// 44 dropped, 21 bytes of mark: 235 bytes stay, 65 are missing.
	testing.expect_value(t, text[235:], "... and 65 bytes more")
}
