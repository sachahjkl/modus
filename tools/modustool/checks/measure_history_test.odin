package checks

import "core:strings"
import "core:testing"

// Each series names a measure of the table, and reads its number from the
// line that the measure record holds today.
@(test)
measure_history_series_read_the_lines_of_the_record :: proc(t: ^testing.T) {
	lines := [len(measure_history_series)]string {
		"[locks] locks: kernel entries in one second, each locker on its own objects: 1 locker 7616000, 2 lockers 13041706, 4 lockers 25399040",
		"[clock] clock: the time page: 1106119202 reads in one second, 0 kernel entries for one million reads",
		"[scheduler] scheduler: EEVDF: two threads that wake each other, a spinner on each processor: 200581 wakes in one second (80106 turns ended on the processor of the waker, 85 by an interrupt, 430 moves)",
		"[vector_glyphs] vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 3887 ns, scale 2 8568 ns, scale 3 16922 ns; from the glyph cache: 201 ns; Spleen 8x16: 22 ns",
		"[compositor] " + COMPOSITOR_FULL_FRAME + "with 17 windows in 2272 us",
		"[disk] disk: read, 1 block in each request, 32 in flight: 429355 blocks in one second, kernel entries for 100 requests: 10 of this process, 18 of the block service, 0 errors",
		"[notes] notes: count 1000, stopped: 1000 commits in 8215 ms",
		"[net] net: the header and the checksum of a datagram of 1472 bytes: 331 ns, in this process (no offload)",
		"[net] net: the round trip of one datagram of 64 bytes: 48 us at least, 66 us in the middle, over 1000",
		"[net] net: a burst with 64 datagrams in flight: 89509 datagrams in one second, sent and answered, 0 lost",
		"[fetch] fetch: GET /large: 1048576 bytes, fnv1a64 e7867887f2822325 as expected, 112.4 MB/s",
		"[fetch] fetch: POST /sink, 1 MiB: the remote got the same hash, 20.5 MB/s",
		"[cryptography_vectors] cryptography_vectors: seal ChaCha20-Poly1305: 2823 ns for 1200 bytes, 425 MB/s",
		"[processor_frame] processor_frame: measure: a clear and a present of 1920x1080: least 2310.4 us, median 2401.7 us, 416 frames in one second at the median, over 21 frames",
		"[processor_frame] processor_frame: measure: a full frame of the compositor at 1920x1080 with 4 windows: least 9120.0 us, median 9300.5 us, 107 frames in one second at the median, over 21 frames",
		"[processor_frame] processor_frame: measure: a frame of the compositor at 1920x1080 with 4 windows in its damage of 2 rectangles, 122432 pixels: least 310.2 us, median 322.9 us, 3096 frames in one second at the median, over 21 frames",
		"[processor_frame] processor_frame: measure: the execution of a draw table of 1920x1080 with 339 records: 38 opaque rectangles and gradients, 120 texts in the font of the cells, 144 in the interface font, 12 opaque pictures, 25 rectangles and pictures with alpha: least 14800.3 us, median 15022.0 us, 66 frames in one second at the median, over 21 frames",
		"[compositor] " + QUALITY_FRAME + ": least 812.4 us, median 9031.0 us, over 64 frames",
		"[compositor] " + QUALITY_KEY + ": least 1203.7 us, median 14000.2 us, over 16 keys",
		"[compositor] " + QUALITY_WINDOW_START_LOCKS + "51234.5 us",
		"modustool: measure: the records of the log of build/test_output.txt: 412 up to \"kernel: ok\", 2210 up to \"the machine is usable\"",
		"modustool: measure: the module files: root 1179648 bytes, 393216 bytes of code; compositor 2097152 bytes, 786432 bytes of code",
	}
	expected := [len(measure_history_series)]string{"25399040", "1106119202", "200581", "3887", "2272", "429355", "8215", "331", "66", "89509", "112.4", "20.5", "2823", "2310.4", "9120.0", "310.2", "14800.3", "812.4", "1203.7", "51234.5", "2210", "1179648"}
	sentences := make(map[string]bool, context.temp_allocator)
	for series, index in measure_history_series {
		in_table := false
		for measure in measure_entries {
			if measure.sentence == series.sentence {
				in_table = true
			}
		}
		testing.expectf(t, in_table, "the series %q names no measure of measure_entries", series.title)
		testing.expectf(t, series.sentence not_in sentences, "two series follow the measure %q", series.sentence)
		sentences[series.sentence] = true
		text, value, ok := measure_history_value(series, lines[index])
		testing.expectf(t, ok && text == expected[index] && value > 0, "the series %q reads %q from its line", series.title, text)
	}
	_, decimal, _ := measure_history_value(measure_history_series[10], lines[10])
	testing.expect(t, decimal > 112.3 && decimal < 112.5)

	// Another unit, or words that changed: no number, never a wrong one.
	other_unit, _ := strings.replace_all(lines[3], "3887 ns", "3887 us", context.temp_allocator)
	_, _, other_unit_ok := measure_history_value(measure_history_series[3], other_unit)
	testing.expect(t, !other_unit_ok, "a series took a number of another unit")
	_, _, other_words_ok := measure_history_value(measure_history_series[0], "[locks] locks: 4 processes 25399040")
	testing.expect(t, !other_words_ok, "a series took a line with other words")
	// A point after the number ends a sentence: it is not a decimal point.
	sentence_end := Measure_History_Series{before = "count ", after = "."}
	end_text, _, end_ok := measure_history_value(sentence_end, "a count 12.")
	testing.expect(t, end_ok)
	testing.expect_value(t, end_text, "12")
}

// The full frame of the compositor at another size of the screen is another
// measure: a log of a screen of 1024 x 768, or of a size that starts as the
// reference screen does, gives the measure no line, and a log with both
// sizes gives the line of the reference screen only. The series of the
// releases at 1024 x 768 had another sentence, so no chart joins the two.
@(test)
measure_full_frame_takes_the_reference_screen_only :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(COMPOSITOR_FULL_FRAME, "1920x1080"))
	OLD_SIZE :: "[compositor] compositor: a full frame of 1024x768 with 17 windows in 2272 us\n"
	LONGER_HEIGHT :: "[compositor] compositor: a full frame of 1920x10800 with 17 windows in 2272 us\n"
	OTHER_HEIGHT :: "[compositor] compositor: a full frame of 1920x1200 with 17 windows in 2272 us\n"
	REFERENCE_LINE :: "[compositor] " + COMPOSITOR_FULL_FRAME + "with 17 windows in 3305 us"
	for log_text in ([]string{"", OLD_SIZE, LONGER_HEIGHT, OTHER_HEIGHT, OLD_SIZE + LONGER_HEIGHT + OTHER_HEIGHT}) {
		found, found_number, found_count := log_line_choose(log_text, COMPOSITOR_FULL_FRAME, .Last)
		testing.expectf(t, found == "" && found_number == 0 && found_count == 0, "the log %q gave the full frame the line %q", log_text, found)
	}
	line, line_number, matching_lines := log_line_choose(OLD_SIZE + REFERENCE_LINE + "\n" + OTHER_HEIGHT, COMPOSITOR_FULL_FRAME, .Last)
	testing.expect_value(t, line_number, 2)
	testing.expect_value(t, matching_lines, 1)
	testing.expect_value(t, line, REFERENCE_LINE)
	held := false
	for series in measure_history_series {
		testing.expectf(t, series.sentence != "A full frame of the compositor", "a series still follows the measure of a screen of 1024 x 768")
		held = held || series.sentence == COMPOSITOR_FULL_FRAME_SENTENCE
	}
	testing.expect(t, held, "no series follows the full frame of the reference screen")
}

@(test)
measure_history_file_names_and_tags :: proc(t: ^testing.T) {
	number, ok := measure_history_file_release("0.92.0.txt")
	testing.expect(t, ok)
	testing.expect_value(t, number, Release_Number{0, 92, 0})
	for name in ([]string{"0.092.0.txt", "measures.txt", "0.92.0.md", "0.92.txt"}) {
		_, refused_ok := measure_history_file_release(name)
		testing.expectf(t, !refused_ok, "%q names a release", name)
	}
	testing.expect_value(t, measure_history_file_path({0, 93, 0}), MEASURE_HISTORY_FOLDER + "/0.93.0" + MEASURE_HISTORY_FILE_EXTENSION)

	tags := measure_history_release_tags("v0.10.0\nv0.9.0\nnot-a-release\nv0.92.0\nvnothing\n")
	testing.expect_value(t, len(tags), 3)
	if len(tags) == 3 {
		testing.expect_value(t, tags[0], Release_Number{0, 9, 0})
		testing.expect_value(t, tags[1], Release_Number{0, 10, 0})
		testing.expect_value(t, tags[2], Release_Number{0, 92, 0})
	}
	testing.expect_value(t, strings.join(measure_history_tag_record_command({0, 92, 0}), " ", context.temp_allocator), "git show v0.92.0:" + MEASURE_RECORD_FILE)
}

// A release gets a copy unless the copy of the release before holds the
// same run; a record that does not read gets none.
@(test)
measure_history_copy_of_a_release :: proc(t: ^testing.T) {
	earlier := make([]Measure_History_Release, 1, context.temp_allocator)
	earlier[0] = measure_history_release_example({0, 92, 0}, "2026-11-14 11:46 UTC", "41701e59b2febf6b9033e8891567f6bca6f56c55", measure_history_locks_line_example("25399040"))
	same_run := earlier[0].text
	decision, same_release, problem := measure_history_copy_decide(same_run, earlier, {0, 93, 0})
	testing.expect_value(t, decision, Measure_History_Copy_Decision.Same_Run)
	testing.expect_value(t, same_release, Release_Number{0, 92, 0})
	testing.expect_value(t, problem, "")

	// The same commit at another time is another run.
	later_run := measure_history_release_example({0, 93, 0}, "2026-11-16 06:05 UTC", "41701e59b2febf6b9033e8891567f6bca6f56c55", measure_history_locks_line_example("25000000"))
	decision, _, _ = measure_history_copy_decide(later_run.text, earlier, {0, 93, 0})
	testing.expect_value(t, decision, Measure_History_Copy_Decision.Write)
	// No history yet.
	decision, _, _ = measure_history_copy_decide(same_run, nil, {0, 93, 0})
	testing.expect_value(t, decision, Measure_History_Copy_Decision.Write)
	// A copy of a later release is not the release before.
	decision, _, _ = measure_history_copy_decide(same_run, earlier, {0, 91, 0})
	testing.expect_value(t, decision, Measure_History_Copy_Decision.Write)
	// A file that is not a measure record.
	decision, _, problem = measure_history_copy_decide("measure record 2\nend\n", earlier, {0, 93, 0})
	testing.expect_value(t, decision, Measure_History_Copy_Decision.Refused)
	testing.expect(t, problem != "")

	// The newest copy before a release, in any order of the list.
	unordered := make([]Measure_History_Release, 3, context.temp_allocator)
	unordered[0] = measure_history_release_example({0, 95, 0}, "2026-11-20 10:00 UTC", "", measure_history_locks_line_example("1"))
	unordered[1] = measure_history_release_example({0, 93, 0}, "2026-11-18 10:00 UTC", "", measure_history_locks_line_example("2"))
	unordered[2] = measure_history_release_example({0, 92, 0}, "2026-11-14 11:46 UTC", "", measure_history_locks_line_example("3"))
	newest, found := measure_history_newest_before(unordered, {0, 94, 0})
	testing.expect(t, found)
	testing.expect_value(t, newest.release, Release_Number{0, 93, 0})
	_, found = measure_history_newest_before(unordered, {0, 92, 0})
	testing.expect(t, !found)
}
