package site

import "core:strings"
import "core:testing"
import "core:time"
import "modustool:checks"

// The choice between a log of build/ and the measure record, by their
// times.
@(test)
measure_record_or_build_by_time :: proc(t: ^testing.T) {
	older := time.unix(1_000, 0)
	newer := time.unix(2_000, 0)
	record := Site_Measure_Record{present = true, written = newer}
	testing.expect_value(t, site_measure_source_choose(true, time.unix(3_000, 0), record, true), Site_Measure_Source.Build)
	testing.expect_value(t, site_measure_source_choose(true, older, record, true), Site_Measure_Source.Record)
	testing.expect_value(t, site_measure_source_choose(false, {}, record, true), Site_Measure_Source.Record)
	testing.expect_value(t, site_measure_source_choose(true, older, record, false), Site_Measure_Source.None)
	testing.expect_value(t, site_measure_source_choose(false, {}, record, false), Site_Measure_Source.None)
	no_record := Site_Measure_Record{}
	testing.expect_value(t, site_measure_source_choose(true, older, no_record, false), Site_Measure_Source.Build)
	testing.expect_value(t, site_measure_source_choose(false, {}, no_record, false), Site_Measure_Source.None)

	// A number that build/ does not have and that the record holds: its
	// line, its log and the time of the record, and no "no file".
	present := Site_Measure_Record{present = true, record = checks.measure_record_example(), written = newer}
	from_build := Site_Measured {
		measure = checks.Site_Measure{sentence = "Reads of the time"},
		missing = "build/test_output.txt: no file",
	}
	resolved := site_measure_resolve(from_build, present)
	testing.expect(t, resolved.found)
	testing.expect_value(t, resolved.source, Site_Measure_Source.Record)
	testing.expect_value(t, resolved.text, "clock: the time page: 1000 reads")
	testing.expect_value(t, resolved.path, "build/test_output.txt")
	testing.expect_value(t, resolved.line_number, 812)
	testing.expect_value(t, resolved.written, "2026-11-12 02:09 UTC")
	testing.expect_value(t, resolved.missing, "")
	// A number that the run did not give: absent, with the reason of the run.
	absent := site_measure_resolve(Site_Measured{measure = checks.Site_Measure{sentence = "A full frame of the compositor"}, missing = "build/test_output.txt: no file"}, present)
	testing.expect(t, !absent.found)
	testing.expect(t, strings.contains(absent.missing, "the full check of 2026-11-12 02:09 UTC did not print it"))
	// A log of build/ that is newer wins.
	newest := Site_Measured {
		measure  = checks.Site_Measure{sentence = "Reads of the time"},
		found    = true,
		source   = .Build,
		path     = checks.TEST_OUTPUT,
		text     = "clock: the time page: 2000 reads",
		log_time = time.unix(3_000, 0),
	}
	testing.expect_value(t, site_measure_resolve(newest, present).text, "clock: the time page: 2000 reads")
}

// The page of the numbers: the run first, then a row from the record, a
// row from build/ and a row that is absent; a record of an older release.
@(test)
measure_record_page_text :: proc(t: ^testing.T) {
	site := test_site()
	site.release = "0.91.0"
	site.measure_record = Site_Measure_Record{present = true, record = checks.measure_record_example(), written = time.unix(2_000, 0)}
	measured := make([]Site_Measured, 3, context.temp_allocator)
	measured[0] = site_measure_resolve(Site_Measured{measure = checks.Site_Measure{sentence = "Reads of the time"}, missing = "build/test_output.txt: no file"}, site.measure_record)
	measured[1] = Site_Measured {
		measure     = checks.Site_Measure{sentence = "Blocks read"},
		found       = true,
		source      = .Build,
		path        = checks.TEST_OUTPUT,
		line_number = 5,
		text        = "disk: read, 1 block",
		written     = "2026-11-13 08:00 UTC",
		log_time    = time.unix(3_000, 0),
	}
	measured[2] = site_measure_resolve(Site_Measured{measure = checks.Site_Measure{sentence = "A full frame of the compositor"}, missing = "build/test_output.txt: no file"}, site.measure_record)
	site.measured = measured
	body := site_numbers_body(&site)
	first_paragraph := body[strings.index(body, "<p>"):]
	first_paragraph = first_paragraph[:strings.index(first_paragraph, "</p>")]
	for part in ([]string{"<time datetime=\"2026-11-12T02:09Z\">2026-11-12 02:09 UTC</time>", "<code>264fa30</code>", "with changes that were not committed", "the release 0.91.0", "AMD Ryzen 7 5800X 8-Core Processor, 16 logical processors; QEMU with KVM", "1234 checks passed"}) {
		testing.expectf(t, strings.contains(first_paragraph, part), "the first paragraph has no %q:\n%s", part, first_paragraph)
	}
	expect := [?]string {
		"<code>clock: the time page: 1000 reads</code>",
		"line 812 (the first of 2 lines with this text)",
		"Measured in the full check of 2026-11-12, on the tree of <code>264fa30</code>, with changes that were not committed.",
		"Measured in this work tree: the log in <code>build/</code> is newer than <code>docs/measures/measures.txt</code>.",
		"1 numbers come from the logs in <code>build/</code>",
		"<td data-label=\"The line of the log\" class=\"column-line missing\">Not measured.</td>",
		"2 of 3 numbers are measured.",
	}
	for part in expect {
		testing.expectf(t, strings.contains(body, part), "the page has no %q:\n%s", part, body)
	}
	testing.expect(t, !strings.contains(body, "the numbers were measured before this release"))
	// The row from the record does not say "no file".
	row_start := strings.index(body, "clock: the time page")
	row := body[row_start:]
	row = row[:strings.index(row, "</tr>")]
	testing.expect(t, !strings.contains(row, "no file"))

	// A record of an older release.
	site.release = "0.92.0"
	older_body := site_numbers_body(&site)
	testing.expect(t, strings.contains(older_body, "The measure record is of the release 0.91.0. This site shows the release 0.92.0: the numbers were measured before this release."))

	// No record.
	site.measure_record = {}
	testing.expect(t, strings.contains(site_numbers_body(&site), "The repository holds no measure record"))
}
