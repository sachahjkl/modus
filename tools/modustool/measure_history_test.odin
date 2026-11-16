package modustool

import "core:strings"
import "core:testing"

// One release of the history whose record holds the lock measure with a
// line, or with no line when the line is "".
@(private = "file")
history_test_release :: proc(release: Release_Number, time_text, commit, locks_line: string) -> Measure_History_Release {
	numbers := make([]Measure_Record_Number, 1, context.temp_allocator)
	if locks_line != "" {
		numbers[0] = {sentence = measure_history_series[0].sentence, found = true, log = TEST_OUTPUT_MEASURE, line_number = 99, matching_lines = 1, machine = "The machine of `modustool measure`", line = locks_line}
	} else {
		numbers[0] = {sentence = measure_history_series[0].sentence, absent = "build/test_output_measure.txt: no file"}
	}
	record := Measure_Record {
		time          = time_text,
		release       = "0.91.0",
		commit        = commit,
		tree          = .Clean,
		host          = "AMD Ryzen 7 5800X 8-Core Processor, 16 logical processors; QEMU with KVM",
		checks_passed = 1858,
		numbers       = numbers,
	}
	return Measure_History_Release{release = release, path = measure_history_file_path(release), text = measure_record_format(record), record = record}
}

@(private = "file")
history_test_locks_line :: proc(four_lockers: string) -> string {
	return strings.concatenate({"[locks] locks: kernel entries in one second, each locker on its own objects: 1 locker 7616000, 2 lockers 13041706, 4 lockers ", four_lockers}, context.temp_allocator)
}

// Each series names a measure of the table, and reads its number from the
// line that the measure record holds today.
@(test)
measure_history_series_read_the_lines_of_the_record :: proc(t: ^testing.T) {
	lines := [len(measure_history_series)]string {
		"[locks] locks: kernel entries in one second, each locker on its own objects: 1 locker 7616000, 2 lockers 13041706, 4 lockers 25399040",
		"[clock] clock: the time page: 1106119202 reads in one second, 0 kernel entries for one million reads",
		"[scheduler] scheduler: EEVDF: two threads that wake each other, a spinner on each processor: 200581 wakes in one second (80106 turns ended on the processor of the waker, 85 by an interrupt, 430 moves)",
		"[vector_glyphs] vector_glyphs: one glyph from its outline, in fixed point, with the stripes (the least of batches): scale 1 3887 ns, scale 2 8568 ns, scale 3 16922 ns; from the glyph cache: 201 ns; Spleen 8x16: 22 ns",
		"[compositor:surfaces] compositor: a full frame of 1024x768 with 17 windows in 2272 us",
		"[disk] disk: read, 1 block in each request, 32 in flight: 429355 blocks in one second, kernel entries for 100 requests: 10 of this program, 18 of the block service, 0 errors",
		"[notes] notes: count 1000, stopped: 1000 commits in 8215 ms",
		"[net] net: the header and the checksum of a datagram of 1472 bytes: 331 ns, in this program (no offload)",
		"[net] net: the round trip of one datagram of 64 bytes: 48 us at least, 66 us in the middle, over 1000",
		"[net] net: a burst with 64 datagrams in flight: 89509 datagrams in one second, sent and answered, 0 lost",
		"[fetch] fetch: GET /large: 1048576 bytes, fnv1a64 e7867887f2822325 as expected, 112.4 MB/s",
		"[fetch] fetch: POST /sink, 1 MiB: the remote got the same hash, 20.5 MB/s",
		"[cryptography_vectors] cryptography_vectors: seal ChaCha20-Poly1305: 2823 ns for 1200 bytes, 425 MB/s",
	}
	expected := [len(measure_history_series)]string{"25399040", "1106119202", "200581", "3887", "2272", "429355", "8215", "331", "66", "89509", "112.4", "20.5", "2823"}
	sentences := make(map[string]bool, context.temp_allocator)
	for series, index in measure_history_series {
		in_table := false
		for measure in site_measures {
			if measure.sentence == series.sentence {
				in_table = true
			}
		}
		testing.expectf(t, in_table, "the series %q names no measure of site_measures", series.title)
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
	_, _, other_words_ok := measure_history_value(measure_history_series[0], "[locks] locks: 4 programs 25399040")
	testing.expect(t, !other_words_ok, "a series took a line with other words")
	// A point after the number ends a sentence: it is not a decimal point.
	sentence_end := Measure_History_Series{before = "count ", after = "."}
	end_text, _, end_ok := measure_history_value(sentence_end, "a count 12.")
	testing.expect(t, end_ok)
	testing.expect_value(t, end_text, "12")
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
	earlier[0] = history_test_release({0, 92, 0}, "2026-11-14 11:46 UTC", "41701e59b2febf6b9033e8891567f6bca6f56c55", history_test_locks_line("25399040"))
	same_run := earlier[0].text
	decision, same_release, problem := measure_history_copy_decide(same_run, earlier, {0, 93, 0})
	testing.expect_value(t, decision, Measure_History_Copy_Decision.Same_Run)
	testing.expect_value(t, same_release, Release_Number{0, 92, 0})
	testing.expect_value(t, problem, "")

	// The same commit at another time is another run.
	later_run := history_test_release({0, 93, 0}, "2026-11-16 06:05 UTC", "41701e59b2febf6b9033e8891567f6bca6f56c55", history_test_locks_line("25000000"))
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
	unordered[0] = history_test_release({0, 95, 0}, "2026-11-20 10:00 UTC", "", history_test_locks_line("1"))
	unordered[1] = history_test_release({0, 93, 0}, "2026-11-18 10:00 UTC", "", history_test_locks_line("2"))
	unordered[2] = history_test_release({0, 92, 0}, "2026-11-14 11:46 UTC", "", history_test_locks_line("3"))
	newest, found := measure_history_newest_before(unordered, {0, 94, 0})
	testing.expect(t, found)
	testing.expect_value(t, newest.release, Release_Number{0, 93, 0})
	_, found = measure_history_newest_before(unordered, {0, 92, 0})
	testing.expect(t, !found)
}

// The chart of one measure over four releases, one with no number: the
// golden SVG.
@(test)
measure_history_chart_golden :: proc(t: ^testing.T) {
	releases := make([]Measure_History_Release, 4, context.temp_allocator)
	releases[0] = history_test_release({0, 92, 0}, "2026-11-14 11:46 UTC", "41701e59b2febf6b9033e8891567f6bca6f56c55", history_test_locks_line("100"))
	releases[1] = history_test_release({0, 93, 0}, "2026-11-16 06:05 UTC", "b7dedc5e85cd3b40c462f9562b0dc389aac1d792", history_test_locks_line("200"))
	releases[2] = history_test_release({0, 94, 0}, "2026-11-17 06:05 UTC", "", "")
	releases[3] = history_test_release({0, 95, 0}, "2026-11-18 06:05 UTC", "", history_test_locks_line("50"))
	points, present_count := measure_history_points(measure_history_series[0], releases)
	testing.expect_value(t, present_count, 3)
	testing.expect_value(t, len(points), 4)
	testing.expect(t, !points[2].present)
	testing.expect_value(t, points[2].missing, "the record has no line of this measure")
	golden := `<svg class="measure-history-chart" viewBox="0 0 600 120" role="img" aria-label="Kernel entries in one second, 4 programs">
<line class="measure-history-scale" x1="0" y1="6" x2="600" y2="6"/>
<line class="measure-history-scale" x1="0" y1="114" x2="600" y2="114"/>
<polyline class="measure-history-line" points="6,60 202,6"/>
<rect class="measure-history-point" x="3" y="57" width="6" height="6"><title>0.92.0: 100</title></rect>
<rect class="measure-history-point" x="199" y="3" width="6" height="6"><title>0.93.0: 200</title></rect>
<rect class="measure-history-point" x="591" y="84" width="6" height="6"><title>0.95.0: 50</title></rect>
</svg>
`
	testing.expect_value(t, measure_history_chart_svg(points, measure_history_series[0].title), golden)

	// The places: equal steps, a release alone in the middle; the heights
	// from zero at the bottom.
	testing.expect_value(t, measure_history_point_x(0, 1), MEASURE_HISTORY_CHART_WIDTH / 2)
	testing.expect_value(t, measure_history_point_y(0, 200), MEASURE_HISTORY_CHART_HEIGHT - MEASURE_HISTORY_CHART_MARGIN)
	testing.expect_value(t, measure_history_point_y(200, 200), MEASURE_HISTORY_CHART_MARGIN)

	// The section of the page: one card, for the one measure with points.
	site: Site
	site.measure_history = releases
	b := strings.builder_make(context.temp_allocator)
	site_measure_history_write(&site, &b)
	html := strings.to_string(b)
	testing.expect_value(t, strings.count(html, "<article class=\"card measure-chart "), 1)
	for part in ([]string {
		"<h2 id=\"history\">Each measure over the releases</h2>",
		"holds the measure record of 4 releases, from 0.92.0 to 0.95.0",
		"Two runs of the same build differ",
		"id=\"history-kernel-entries-in-one-second",
		"<p class=\"measure-unit\">From 0 to <code class=\"value value-number\">200</code> kernel entries in one second. A higher number is faster.</p>",
		"<p class=\"measure-history-releases\"><span>0.92.0</span><span>0.95.0</span></p>",
		"<li>0.93.0: <code class=\"value value-number\">200</code>, the run of <code>b7dedc5</code> at 2026-11-16 06:05 UTC</li>",
		"<li>0.94.0: no number: the record has no line of this measure</li>",
		"<li>0.95.0: <code class=\"value value-number\">50</code>, the run of an unknown commit at 2026-11-18 06:05 UTC</li>",
		"<a href=\"#reading-kernel-entries-in-one-second",
	}) {
		testing.expectf(t, strings.contains(html, part), "the section has no %q:\n%s", part, html)
	}
	// One host: the list does not repeat it.
	testing.expect(t, !strings.contains(html, ", on AMD"))
	testing.expect(t, !strings.contains(html, "hosts measured these releases"))

	// One release: no chart, and the section says why.
	site.measure_history = releases[:1]
	one := strings.builder_make(context.temp_allocator)
	site_measure_history_write(&site, &one)
	testing.expect(t, strings.contains(strings.to_string(one), "holds the measure record of one release, 0.92.0"))
	testing.expect(t, strings.contains(strings.to_string(one), "No measure has a number in 2 releases yet"))
	testing.expect(t, !strings.contains(strings.to_string(one), "<svg"))
	// No history.
	site.measure_history = nil
	none := strings.builder_make(context.temp_allocator)
	site_measure_history_write(&site, &none)
	testing.expect(t, strings.contains(strings.to_string(none), "holds no measure record of a release"))
}
