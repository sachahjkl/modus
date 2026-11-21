#+build !freestanding
package text_model

import "core:testing"

@(private = "file")
make_text :: proc(bytes: string) -> ^Text {
	text := new(Text)
	if len(bytes) > 0 {
		problem := text_insert(text, transmute([]u8)bytes)
		assert(problem == .None)
	}
	return text
}

@(private = "file")
as_string :: proc(text: ^Text) -> string {
	return string(text_bytes(text))
}

@(test)
copy_and_cut_refuse_empty_selection_and_short_target_without_changing_text :: proc(t: ^testing.T) {
	text := make_text("hello\nworld")
	defer free(text)
	buffer: [64]u8
	// Nothing selected: copy and cut are no-ops with Empty.
	count, problem := selection_copy(text, buffer[:])
	testing.expect_value(t, problem, Edit_Problem.Empty)
	testing.expect_value(t, count, 0)
	count, problem = selection_cut(text, buffer[:])
	testing.expect_value(t, problem, Edit_Problem.Empty)
	testing.expect_value(t, count, 0)
	testing.expect(t, !selection_delete(text))
	testing.expect_value(t, as_string(text), "hello\nworld")

	// Selection larger than target buffer (0 bytes and one byte short):
	// refused whole, text and selection stay intact.
	selection_set(text, 0, 11)
	count, problem = selection_copy(text, nil)
	testing.expect_value(t, problem, Edit_Problem.Too_Long)
	testing.expect_value(t, count, 0)
	count, problem = selection_copy(text, buffer[:10])
	testing.expect_value(t, problem, Edit_Problem.Too_Long)
	testing.expect_value(t, count, 0)
	count, problem = selection_cut(text, buffer[:10])
	testing.expect_value(t, problem, Edit_Problem.Too_Long)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, text.anchor, 0)
	testing.expect_value(t, text.caret, 11)
	testing.expect_value(t, as_string(text), "hello\nworld")

	// Exact target size succeeds.
	count, problem = selection_copy(text, buffer[:11])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, count, 11)
	testing.expect_value(t, string(buffer[:count]), "hello\nworld")
}

@(test)
select_all_and_multiline_copy_cut_paste_work_across_gap_and_positions :: proc(t: ^testing.T) {
	// Empty text: select_all stays at 0..0.
	empty := make_text("")
	defer free(empty)
	text_select_all(empty)
	testing.expect_value(t, empty.anchor, 0)
	testing.expect_value(t, empty.caret, 0)

	// Place gap in the middle of a multi-line UTF-8 text, then copy
	// before gap, after gap, and spanning the gap.
	text := make_text("first\n\tsécond\nthird")
	defer free(text)
	selection_set(text, 6, 6)
	testing.expect_value(t, text_insert_character(text, 'X'), Edit_Problem.None) // Gap now at 7 ("first\nX\tsécond\nthird").
	testing.expect_value(t, text.before_count, 7)

	clip: [64]u8
	// Copy spanning the gap across two lines and a tab + UTF-8 char.
	selection_set(text, 3, 15) // "st\nX\tsécond" (12 bytes)
	count, problem := selection_copy(text, clip[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, string(clip[:count]), "st\nX\tsécond")

	// Copy strictly before the gap.
	selection_set(text, 0, 5)
	count, problem = selection_copy(text, clip[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, string(clip[:count]), "first")

	// Copy strictly after the gap (reversed selection anchor > caret).
	selection_set(text, text_length(text), 15)
	count, problem = selection_copy(text, clip[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, string(clip[:count]), "\nthird")

	// Cut multi-line selection across lines.
	selection_set(text, 5, 15) // "\nX\tsécond"
	count, problem = selection_cut(text, clip[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, string(clip[:count]), "\nX\tsécond")
	testing.expect_value(t, as_string(text), "first\nthird")
	testing.expect_value(t, text.caret, 5)
	testing.expect_value(t, text.anchor, 5)

	// Paste at start, middle, and end.
	selection_set(text, 0, 0)
	testing.expect_value(t, text_insert(text, transmute([]u8)string("A\n")), Edit_Problem.None)
	testing.expect_value(t, as_string(text), "A\nfirst\nthird")

	selection_set(text, 7, 7) // After "A\nfirst"
	testing.expect_value(t, text_insert(text, clip[:count]), Edit_Problem.None)
	testing.expect_value(t, as_string(text), "A\nfirst\nX\tsécond\nthird")

	selection_set(text, text_length(text), text_length(text))
	testing.expect_value(t, text_insert(text, transmute([]u8)string("\nZ")), Edit_Problem.None)
	testing.expect_value(t, as_string(text), "A\nfirst\nX\tsécond\nthird\nZ")

	// Select all and replace with a single paste.
	text_select_all(text)
	testing.expect_value(t, selection_count(text), text_length(text))
	testing.expect_value(t, text_insert(text, transmute([]u8)string("line1\nline2")), Edit_Problem.None)
	testing.expect_value(t, as_string(text), "line1\nline2")
}

@(test)
paste_exceeding_capacity_is_refused_with_buffer_and_selection_unchanged :: proc(t: ^testing.T) {
	text := new(Text)
	defer free(text)
	chunk := make([]u8, TEXT_CAPACITY - 4)
	defer delete(chunk)
	for &value in chunk {
		value = 'a'
	}
	testing.expect_value(t, text_insert(text, chunk), Edit_Problem.None)
	// 4 bytes free; pasting 5 bytes is refused whole.
	selection_set(text, 10, 10)
	testing.expect_value(t, text_insert(text, transmute([]u8)string("12\n45")), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY - 4)
	testing.expect_value(t, text.caret, 10)
	// Selection of 2 bytes frees 6 bytes total: pasting 7 bytes still refused and keeps selection!
	selection_set(text, 10, 12)
	testing.expect_value(t, text_insert(text, transmute([]u8)string("123\n567")), Edit_Problem.Too_Long)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY - 4)
	testing.expect_value(t, text.anchor, 10)
	testing.expect_value(t, text.caret, 12)
	// Pasting exactly 6 bytes fits at exact TEXT_CAPACITY bound.
	testing.expect_value(t, text_insert(text, transmute([]u8)string("123\n56")), Edit_Problem.None)
	testing.expect_value(t, text_length(text), TEXT_CAPACITY)
}

@(test)
undo_walk_stays_coherent_across_cut_and_paste_commits :: proc(t: ^testing.T) {
	text := make_text("alpha\nbeta\ngamma")
	defer free(text)
	walk: Version_Walk
	// Generation 1: "alpha\nbeta\ngamma". Cut "\nbeta" -> generation 2: "alpha\ngamma".
	clip: [32]u8
	selection_set(text, 5, 10)
	count, problem := selection_cut(text, clip[:])
	testing.expect_value(t, problem, Edit_Problem.None)
	testing.expect_value(t, string(clip[:count]), "\nbeta")
	walk_changed(&walk)
	// Undo from gen 2 -> gen 1.
	step, walk_problem := walk_back(&walk, {1, 2})
	testing.expect_value(t, walk_problem, Walk_Problem.None)
	testing.expect_value(t, step, Walk_Step{from = 2, to = 1})
	testing.expect_value(t, text_replace_whole(text, transmute([]u8)string("alpha\nbeta\ngamma")), Edit_Problem.None)
	walk_went_back(&walk, step)
	testing.expect_value(t, as_string(text), "alpha\nbeta\ngamma")
	// Paste at end -> new commit invalidates redo stack.
	selection_set(text, text_length(text), text_length(text))
	testing.expect_value(t, text_insert(text, clip[:count]), Edit_Problem.None)
	walk_changed(&walk)
	_, walk_problem = walk_forward(&walk)
	testing.expect_value(t, walk_problem, Walk_Problem.No_Newer_Version)
	testing.expect_value(t, as_string(text), "alpha\nbeta\ngamma\nbeta")
}

@(test)
search_refuses_invalid_and_oversized_queries_and_handles_empty_and_not_found :: proc(t: ^testing.T) {
	text := make_text("hello world")
	defer free(text)
	search := new(Search)
	defer free(search)
	search_open(search, text)
	testing.expect(t, search.active)
	testing.expect_value(t, search.match_count, 0)
	testing.expect_value(t, search.active_match, -1)
	testing.expect(t, !search_next(search, text))
	testing.expect(t, !search_previous(search, text))

	// Invalid queries are refused and change nothing.
	refused := [?]string{"\n", "\t", "\r", "\x00", "\x1b", "\xff", "a\n"}
	for bad in refused {
		testing.expect_value(t, search_query_insert(search, text, transmute([]u8)bad), Edit_Problem.Not_Text)
		testing.expect_value(t, search.query_count, 0)
	}
	testing.expect_value(t, search_query_insert(search, text, nil), Edit_Problem.Empty)
	testing.expect_value(t, search_query_insert_character(search, text, '\n'), Edit_Problem.Not_Text)
	testing.expect_value(t, search_query_insert_character(search, text, '\t'), Edit_Problem.Not_Text)

	// Query longer than buffer: valid query, 0 matches, caret stays put.
	caret_before := text.caret
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("hello world and much longer")), Edit_Problem.None)
	testing.expect_value(t, search.match_count, 0)
	testing.expect_value(t, search.active_match, -1)
	testing.expect_value(t, text.caret, caret_before)
	testing.expect(t, !search_next(search, text))
	testing.expect(t, !search_previous(search, text))

	// Query not found.
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("xyz")), Edit_Problem.None)
	testing.expect_value(t, search.match_count, 0)
	testing.expect_value(t, search.active_match, -1)

	// Exact SEARCH_QUERY_CAPACITY and one past bound.
	exact: [SEARCH_QUERY_CAPACITY + 1]u8
	for &value in exact {
		value = 'q'
	}
	testing.expect_value(t, search_query_set(search, text, exact[:SEARCH_QUERY_CAPACITY]), Edit_Problem.None)
	testing.expect_value(t, search.query_count, SEARCH_QUERY_CAPACITY)
	testing.expect_value(t, search_query_insert_character(search, text, 'z'), Edit_Problem.Too_Long)
	testing.expect_value(t, search.query_count, SEARCH_QUERY_CAPACITY)
	testing.expect_value(t, search_query_set(search, text, exact[:]), Edit_Problem.Too_Long)
	testing.expect_value(t, search.query_count, SEARCH_QUERY_CAPACITY)
}

@(test)
search_finds_single_and_multiple_matches_wraps_and_handles_utf8 :: proc(t: ^testing.T) {
	text := make_text("été foo\nbar foo €\nfoo été")
	defer free(text)
	// Place gap in the middle so search traverses across gap.
	selection_set(text, 10, 10)
	testing.expect_value(t, text_insert_character(text, ' '), Edit_Problem.None)
	testing.expect(t, text_delete_before(text))

	search := new(Search)
	defer free(search)
	selection_set(text, 0, 0)
	search_open(search, text)

	// Single match with UTF-8 euro sign.
	testing.expect_value(t, search_query_insert_character(search, text, '€'), Edit_Problem.None)
	testing.expect_value(t, search.match_count, 1)
	testing.expect_value(t, search.active_match, 0)
	euro_pos := int(search.matches[0])
	testing.expect_value(t, text.caret, euro_pos)
	testing.expect(t, search_next(search, text))
	testing.expect_value(t, search.active_match, 0)
	testing.expect(t, search_previous(search, text))
	testing.expect_value(t, search.active_match, 0)

	// Multi-byte UTF-8 query ("été") across lines: 2 matches.
	// With origin at euro_pos (> 0), search_query_set starts at match 1 (byte 26).
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("été")), Edit_Problem.None)
	testing.expect_value(t, search.match_count, 2)
	testing.expect_value(t, search.active_match, 1)
	testing.expect_value(t, int(search.matches[0]), 0)
	testing.expect_value(t, text.caret, int(search.matches[1]))
	// Wrap forward from last match (1) to first (0).
	testing.expect(t, search_next(search, text))
	testing.expect_value(t, search.active_match, 0)
	testing.expect_value(t, text.caret, 0)
	// Next goes to 1.
	testing.expect(t, search_next(search, text))
	testing.expect_value(t, search.active_match, 1)
	testing.expect_value(t, text.caret, int(search.matches[1]))
	// Previous goes back to 0, then wraps backward to 1.
	testing.expect(t, search_previous(search, text))
	testing.expect_value(t, search.active_match, 0)
	testing.expect(t, search_previous(search, text))
	testing.expect_value(t, search.active_match, 1)
	testing.expect_value(t, text.caret, int(search.matches[1]))

	// Multiple matches across 3 lines ("foo"): incremental typing from origin=6.
	selection_set(text, 6, 6)
	search_open(search, text)
	testing.expect_value(t, search_query_insert_character(search, text, 'f'), Edit_Problem.None)
	testing.expect_value(t, search.match_count, 3)
	// "été " is 5 bytes ("é"=2, "t"=1, "é"=2, " "=1 -> 6), so first "foo" is at byte 6!
	testing.expect_value(t, int(search.matches[0]), 6)
	testing.expect_value(t, search.active_match, 0)
	testing.expect_value(t, text.caret, 6)
	testing.expect_value(t, search_query_insert_character(search, text, 'o'), Edit_Problem.None)
	testing.expect_value(t, search.active_match, 0)
	testing.expect_value(t, text.caret, 6)
	testing.expect_value(t, search_query_insert_character(search, text, 'o'), Edit_Problem.None)
	testing.expect_value(t, search.match_count, 3)
	testing.expect_value(t, search.active_match, 0)
	// Next -> 1 -> 2 -> wrap to 0.
	testing.expect(t, search_next(search, text))
	testing.expect_value(t, search.active_match, 1)
	testing.expect(t, search_next(search, text))
	testing.expect_value(t, search.active_match, 2)
	testing.expect(t, search_next(search, text))
	testing.expect_value(t, search.active_match, 0)
	// Previous -> wrap to 2 -> 1.
	testing.expect(t, search_previous(search, text))
	testing.expect_value(t, search.active_match, 2)
	testing.expect(t, search_previous(search, text))
	testing.expect_value(t, search.active_match, 1)

	// Binary search helper search_first_match_overlapping.
	first_pos := int(search.matches[0])
	second_pos := int(search.matches[1])
	third_pos := int(search.matches[2])
	testing.expect_value(t, search_first_match_overlapping(search, 0), 0)
	testing.expect_value(t, search_first_match_overlapping(search, first_pos + 2), 0)
	testing.expect_value(t, search_first_match_overlapping(search, first_pos + 3), 1)
	testing.expect_value(t, search_first_match_overlapping(search, second_pos), 1)
	testing.expect_value(t, search_first_match_overlapping(search, third_pos + 3), 3)

	// Close search, edit at found caret, then search again.
	search_close(search)
	testing.expect(t, !search.active)
	testing.expect_value(t, text.caret, second_pos)
	testing.expect_value(t, text_insert(text, transmute([]u8)string("Z")), Edit_Problem.None)
	search_recompute(search, text, 0, false)
	// "Zfoo" still contains "foo" shifted by 1 byte -> 3 matches still!
	testing.expect_value(t, search.match_count, 3)
	testing.expect_value(t, int(search.matches[1]), second_pos + 1)

	// Query caret movement and Backspace / Delete on UTF-8 query.
	search_open(search, text)
	testing.expect_value(t, search_query_set(search, text, transmute([]u8)string("aé€")), Edit_Problem.None)
	testing.expect_value(t, search.query_caret, 6)
	search_query_move(search, .Left)
	testing.expect_value(t, search.query_caret, 3) // Before '€'.
	testing.expect(t, search_query_delete_after(search, text))
	testing.expect_value(t, string(search_query_bytes(search)), "aé")
	testing.expect(t, search_query_delete_before(search, text))
	testing.expect_value(t, string(search_query_bytes(search)), "a")
	search_query_move(search, .Start)
	testing.expect_value(t, search.query_caret, 0)
	testing.expect(t, !search_query_delete_before(search, text))
	search_query_move(search, .End)
	testing.expect_value(t, search.query_caret, 1)
	testing.expect(t, !search_query_delete_after(search, text))
}
