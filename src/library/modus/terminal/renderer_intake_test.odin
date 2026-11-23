#+build !freestanding
package terminal_records

import "core:testing"

// A text region of the test: small, so a record crosses its end.
@(private = "file")
TEST_REGION_SIZE :: 16

// A word that names no record, None, one past the last kind and the
// largest word, is refused and counted; it reads no text and changes
// nothing that a renderer shows.
@(test)
renderer_intake_refuses_a_word_that_names_no_record :: proc(t: ^testing.T) {
	region: [TEST_REGION_SIZE]u8
	intake := renderer_intake_make(region[:])
	for word in ([?]u32{u32(Kind.None), u32(max(Kind)) + 1, max(u32)}) {
		event := renderer_intake_take(&intake, {kind = word, tag = 8})
		testing.expect_value(t, event.step, Renderer_Step.None)
	}
	testing.expect_value(t, intake.records_refused, u64(3))
	testing.expect_value(t, intake.read, u64(0))
	testing.expect_value(t, intake.list.shown.chosen, -1)
}

// The text of a record that crosses the end of the region comes back in
// order from its two parts; a count past RUN_LIMIT is cut to it; a region
// of zero bytes gives empty texts and still counts what was read, so the
// next record does not read the text of the one before.
@(test)
renderer_intake_reads_text_across_the_end_of_the_region :: proc(t: ^testing.T) {
	region: [TEST_REGION_SIZE]u8
	copy(region[:], "LMNOPQRSTUVWXYZ!")
	intake := renderer_intake_make(region[:])
	intake.read = TEST_REGION_SIZE - 2
	event := renderer_intake_take(&intake, {kind = u32(Kind.Text), tag = 5, values = {0 = transmute(u64)Style{tone = u8(Tone.Good), flags = {.End_Line}}}})
	testing.expect_value(t, event.step, Renderer_Step.Text)
	testing.expect_value(t, string(intake.text[:intake.text_length]), "Z!LMN")
	testing.expect_value(t, event.style.tone, u8(Tone.Good))
	testing.expect(t, .End_Line in event.style.flags)

	first, second := renderer_take(&intake, max(u32))
	testing.expect_value(t, len(first) + len(second), TEST_REGION_SIZE)
	testing.expect_value(t, intake.read, u64(TEST_REGION_SIZE + 3 + RUN_LIMIT))

	empty := renderer_intake_make(nil)
	event = renderer_intake_take(&empty, {kind = u32(Kind.Text), tag = 7})
	testing.expect_value(t, event.step, Renderer_Step.Text)
	testing.expect_value(t, empty.text_length, 0)
	testing.expect_value(t, empty.read, u64(7))
}

// Status and Hint keep their text and their values, and the next record
// reads its own text after theirs.
@(test)
renderer_intake_keeps_status_and_hint :: proc(t: ^testing.T) {
	region: [TEST_REGION_SIZE]u8
	copy(region[:], "statushintTEXT")
	intake := renderer_intake_make(region[:])
	event := renderer_intake_take(&intake, {kind = u32(Kind.Status), tag = 6, values = {0 = transmute(u64)Style{tone = u8(Tone.Good)}, 1 = 3, 2 = 10}})
	testing.expect_value(t, event.step, Renderer_Step.Status)
	testing.expect_value(t, string(intake.status.text[:intake.status.length]), "status")
	testing.expect_value(t, intake.status.value, u64(3))
	testing.expect_value(t, intake.status.total, u64(10))
	testing.expect_value(t, intake.status.style.tone, u8(Tone.Good))
	event = renderer_intake_take(&intake, {kind = u32(Kind.Hint), tag = 4, values = {1 = 1, 2 = 2, 3 = 3, 4 = 0, 5 = 1}})
	testing.expect_value(t, event.step, Renderer_Step.Hint)
	hint := &intake.hint
	testing.expect_value(t, string(hint.text[:hint.length]), "hint")
	testing.expect_value(t, hint.long_bytes, 3)
	testing.expect_value(t, hint.mark_start, 1)
	testing.expect_value(t, hint.mark_length, 2)
	testing.expect_value(t, hint.short_mark_start, 0)
	testing.expect_value(t, hint.short_mark_length, 1)
	testing.expect_value(t, renderer_intake_take(&intake, {kind = u32(Kind.Text), tag = 4}).step, Renderer_Step.Text)
	testing.expect_value(t, string(intake.text[:intake.text_length]), "TEXT")
}

// The values of a hint come from another process: a long form past the
// text is cut to the text, a mark that starts past its form gives no mark,
// a mark that passes the end of its form is cut there, and the largest
// word changes nothing of this. A new status replaces the one before
// whole.
@(test)
renderer_intake_brings_the_marks_of_a_hint_inside_their_form :: proc(t: ^testing.T) {
	region: [TEST_REGION_SIZE]u8
	copy(region[:], "abcdefgh")
	intake := renderer_intake_make(region[:])
	renderer_intake_take(&intake, {kind = u32(Kind.Hint), tag = 8, values = {1 = 6, 2 = max(u64), 3 = max(u64), 4 = 0, 5 = 4}})
	hint := &intake.hint
	testing.expect_value(t, hint.long_bytes, 8)
	testing.expect_value(t, hint.mark_start, 6)
	testing.expect_value(t, hint.mark_length, 2)
	testing.expect_value(t, hint.short_mark_start, 0)
	testing.expect_value(t, hint.short_mark_length, 0)
	intake.read = 0
	renderer_intake_take(&intake, {kind = u32(Kind.Hint), tag = 8, values = {1 = 5, 2 = 9, 3 = 5, 4 = max(u64), 5 = 1}})
	testing.expect_value(t, hint.long_bytes, 5)
	testing.expect_value(t, hint.mark_start, 0)
	testing.expect_value(t, hint.mark_length, 0)
	testing.expect_value(t, hint.short_mark_start, 0)
	testing.expect_value(t, hint.short_mark_length, 0)
	intake.read = 0
	renderer_intake_take(&intake, {kind = u32(Kind.Hint), tag = 8, values = {1 = 2, 2 = 1, 3 = 5, 4 = 2, 5 = max(u64)}})
	testing.expect_value(t, hint.mark_start, 2)
	testing.expect_value(t, hint.mark_length, 1)
	testing.expect_value(t, hint.short_mark_start, 2)
	testing.expect_value(t, hint.short_mark_length, 1)
	intake.read = 0
	renderer_intake_take(&intake, {kind = u32(Kind.Status), tag = 8, values = {1 = 1, 2 = 2}})
	renderer_intake_take(&intake, {kind = u32(Kind.Status), tag = 0})
	testing.expect_value(t, intake.status.length, 0)
	testing.expect_value(t, intake.status.total, u64(0))
	testing.expect_value(t, intake.status.value, u64(0))
}

// Runs of the edit line that are not a whole count of runs, that pass the
// end of the line, or whose target names no record or takes no runs, are
// refused and counted; the line is then plain. A cursor past the text is
// cut to its end, and NO_CURSOR gives no cursor. Runs that fit color the
// line, and the next line with no runs before it is plain.
@(test)
renderer_intake_checks_the_runs_of_the_edit_line :: proc(t: ^testing.T) {
	region: [256]u8
	intake := renderer_intake_make(region[:])
	put :: proc(intake: ^Renderer_Intake, bytes: []u8) {
		place := int(intake.read % u64(len(intake.text_region)))
		copy(intake.text_region[place:], bytes)
	}
	// Three bytes: not a whole run.
	put(&intake, {0, 2, u8(Code_Kind.Function)})
	renderer_intake_take(&intake, {kind = u32(Kind.Code_Runs), tag = 3, values = {0 = u64(Kind.Edit)}})
	testing.expect_value(t, intake.runs_refused, u64(1))
	// A target that names no record, and a target that takes no runs.
	renderer_intake_take(&intake, {kind = u32(Kind.Code_Runs), tag = 0, values = {0 = u64(max(Kind)) + 1}})
	renderer_intake_take(&intake, {kind = u32(Kind.Code_Runs), tag = 0, values = {0 = u64(Kind.Text)}})
	testing.expect_value(t, intake.runs_refused, u64(3))
	// A run past the end of a line of 4 bytes: the start in two bytes,
	// little end first, then the length and the kind.
	put(&intake, {0, 0, 9, u8(Code_Kind.Function)})
	renderer_intake_take(&intake, {kind = u32(Kind.Code_Runs), tag = 4, values = {0 = u64(Kind.Edit)}})
	put(&intake, transmute([]u8)string("help"))
	event := renderer_intake_take(&intake, {kind = u32(Kind.Edit), tag = 4, values = {1 = 1 << 63}})
	testing.expect_value(t, event.step, Renderer_Step.Edit)
	testing.expect_value(t, intake.runs_refused, u64(4))
	testing.expect_value(t, intake.edit.code.count, 0)
	testing.expect(t, intake.edit.has_cursor)
	testing.expect_value(t, intake.edit.cursor, 4)
	// Runs that fit.
	put(&intake, {0, 0, 4, u8(Code_Kind.Function)})
	renderer_intake_take(&intake, {kind = u32(Kind.Code_Runs), tag = 4, values = {0 = u64(Kind.Edit)}})
	put(&intake, transmute([]u8)string("help"))
	renderer_intake_take(&intake, {kind = u32(Kind.Edit), tag = 4, values = {1 = NO_CURSOR}})
	testing.expect_value(t, intake.runs_refused, u64(4))
	testing.expect_value(t, intake.edit.code.count, 1)
	testing.expect(t, !intake.edit.has_cursor)
	put(&intake, transmute([]u8)string("help"))
	renderer_intake_take(&intake, {kind = u32(Kind.Edit), tag = 4, values = {1 = 0}})
	testing.expect_value(t, intake.edit.code.count, 0)
}

// A row past the rows of a list, and a row whose icon names no List_Icon,
// are not kept; a chosen row past the shown rows is no choice; a count of
// rows past LIST_ROWS is cut to it. A kept row reaches the list at List.
@(test)
renderer_intake_keeps_the_completion_list :: proc(t: ^testing.T) {
	region: [256]u8
	copy(region[:], "startbegin a module")
	intake := renderer_intake_make(region[:])
	testing.expect_value(t, renderer_intake_take(&intake, {kind = u32(Kind.List_Row), tag = 5, values = {0 = LIST_ROWS, 1 = 5}}).step, Renderer_Step.None)
	renderer_intake_take(&intake, {kind = u32(Kind.List_Row), tag = 0, values = {0 = 0, 4 = u64(max(List_Icon)) + 1}})
	testing.expect_value(t, intake.list.rows_refused, u64(1))
	intake.read = 0
	renderer_intake_take(&intake, {kind = u32(Kind.List_Row), tag = 19, values = {0 = 0, 1 = max(u64)}})
	event := renderer_intake_take(&intake, {kind = u32(Kind.List), values = {0 = max(u64), 1 = 5, 4 = max(u64)}})
	testing.expect_value(t, event.step, Renderer_Step.List)
	shown := &intake.list.shown
	testing.expect_value(t, shown.row_count, LIST_ROWS)
	testing.expect_value(t, shown.chosen, 5)
	testing.expect_value(t, shown.anchor, RUN_LIMIT)
	testing.expect_value(t, shown.rows[0].name_length, 19)
	testing.expect_value(t, string(shown.rows[0].text[:shown.rows[0].length]), "startbegin a module")
	event = renderer_intake_take(&intake, {kind = u32(Kind.List), values = {0 = 2, 1 = 2}})
	testing.expect_value(t, shown.row_count, 2)
	testing.expect_value(t, shown.chosen, -1)
	event = renderer_intake_take(&intake, {kind = u32(Kind.List), values = {0 = 0, 1 = NO_CHOICE}})
	testing.expect_value(t, shown.row_count, 0)
}
