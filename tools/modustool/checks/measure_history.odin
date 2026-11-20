// The measure history: the measure record of each release, one file for
// each release in docs/measures/releases/, and a chart of each measure over
// the releases on the page of the measured numbers
// (src/md/features/measure_history.md; docs/SITE.md, "The measure history").
//
//   modustool changelog release <number>   copies the measure record to <number>.txt
//   modustool measure-history              gives each release tag that holds a measure record its copy
package checks

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modustool:foundation"
import module "modus:contract/module"
import "modustool:build"

MEASURE_HISTORY_FOLDER :: MEASURE_RECORD_FOLDER + "/releases"
MEASURE_HISTORY_FILE_EXTENSION :: ".txt"

// The SVG of one chart, in the units of its view box. The SVG scales with
// its card, so these are proportions, not pixels.
MEASURE_HISTORY_CHART_WIDTH :: 600
MEASURE_HISTORY_CHART_HEIGHT :: 120
// Room around the places of the points, so that a square at the edge or at
// the top is whole.
MEASURE_HISTORY_CHART_MARGIN :: 6
MEASURE_HISTORY_POINT_SIZE :: 6
// A chart compares: a measure with fewer points has no chart.
MEASURE_HISTORY_LEAST_POINTS :: 2

// One release of the history: its file, and the record that it holds.
Measure_History_Release :: struct {
	release: Release_Number, // From the name of the file, not from the line "release" of the record.
	path:    string,
	text:    string,
	record:  Measure_Record,
}

// Which way of a number is the faster system.
Measure_Faster :: enum {
	Higher,
	Lower,
}

// The one number of a line of a log that the chart of a measure follows.
Measure_History_Series :: struct {
	sentence: string, // The sentence of measure_entries: the identity of the measure.
	title:    string,
	before:   string, // The words of the line just before the number.
	after:    string, // The words just after it: its unit as the log writes it.
	unit:     string, // The unit in words.
	faster:   Measure_Faster,
}

// The number that each chart follows: the one that the sentence of the
// measure names first. The second build gives a fact, not a number: it has
// no chart.
measure_history_series := [?]Measure_History_Series {
	{sentence = "Kernel entries in one second, with 1, 2 and 4 processes that each take the locks of their own objects", title = "Kernel entries in one second, 4 processes", before = "4 lockers ", after = "", unit = "kernel entries in one second", faster = .Higher},
	{sentence = "Reads of the time in one second from the time page, with no kernel entry", title = "Reads of the time page in one second", before = "the time page: ", after = " reads in one second", unit = "reads in one second", faster = .Higher},
	{sentence = "Wakes in one second of two threads that wake each other on a busy machine, under the strategy EEVDF", title = "Wakes in one second, EEVDF on a busy machine", before = "a spinner on each processor: ", after = " wakes in one second", unit = "wakes in one second", faster = .Higher},
	{sentence = "One glyph of the vector font, from its outline and from the glyph cache", title = "One glyph from its outline, scale 1", before = "scale 1 ", after = " ns", unit = "nanoseconds", faster = .Lower},
	{sentence = COMPOSITOR_FULL_FRAME_SENTENCE, title = "A full frame of the compositor at 1920 x 1080", before = " windows in ", after = " us", unit = "microseconds", faster = .Lower},
	{sentence = "Blocks read in one second from a virtio disk, through the block service in user space", title = "Blocks read in one second, 32 in flight", before = "32 in flight: ", after = " blocks in one second", unit = "blocks in one second", faster = .Higher},
	{sentence = "1000 commits of a process to its private store, one commit for each step", title = "1000 commits to a private store", before = "1000 commits in ", after = " ms", unit = "milliseconds", faster = .Lower},
	{sentence = "The header and the checksum of one UDP datagram, in the process that sends it", title = "The header and the checksum of one UDP datagram", before = "1472 bytes: ", after = " ns", unit = "nanoseconds", faster = .Lower},
	{sentence = "The round trip of one UDP datagram", title = "The round trip of one UDP datagram, the middle of 1000", before = "at least, ", after = " us in the middle", unit = "microseconds", faster = .Lower},
	{sentence = "UDP datagrams in one second, with 64 in flight", title = "UDP datagrams in one second, 64 in flight", before = "64 datagrams in flight: ", after = " datagrams in one second", unit = "datagrams in one second", faster = .Higher},
	{sentence = "TCP: 1 MiB that the process `fetch` receives from a server of the host", title = "TCP: 1 MiB received", before = "as expected, ", after = " MB/s", unit = "megabytes in one second", faster = .Higher},
	{sentence = "TCP: 1 MiB that the process `fetch` sends to a server of the host", title = "TCP: 1 MiB sent", before = "the same hash, ", after = " MB/s", unit = "megabytes in one second", faster = .Higher},
	{sentence = "ChaCha20-Poly1305: the seal of one QUIC datagram of 1200 bytes, through the module `cryptography`", title = "The seal of one QUIC datagram of 1200 bytes", before = "ChaCha20-Poly1305: ", after = " ns for 1200 bytes", unit = "nanoseconds", faster = .Lower},
	{sentence = "A clear and a present of a frame of 1920 x 1080 on the processor", title = "A clear and a present at 1920 x 1080, the least of 21", before = PROCESSOR_FRAME_LEAST, after = PROCESSOR_FRAME_MEDIAN, unit = "microseconds", faster = .Lower},
	{sentence = "A full frame of the compositor at 1920 x 1080 with 4 windows, on the processor", title = "A full frame of the compositor at 1920 x 1080, the least of 21", before = PROCESSOR_FRAME_LEAST, after = PROCESSOR_FRAME_MEDIAN, unit = "microseconds", faster = .Lower},
	{sentence = "A frame of the compositor at 1920 x 1080 in its damage, on the processor", title = "A frame of the compositor in its damage at 1920 x 1080, the least of 21", before = PROCESSOR_FRAME_LEAST, after = PROCESSOR_FRAME_MEDIAN, unit = "microseconds", faster = .Lower},
	{sentence = "The execution of a draw table of a desktop at 1920 x 1080, on the processor", title = "A draw table of a desktop at 1920 x 1080, the least of 21", before = PROCESSOR_FRAME_LEAST, after = PROCESSOR_FRAME_MEDIAN, unit = "microseconds", faster = .Lower},
	{sentence = "The time of a frame of the compositor, from the first record that it reads to the flip", title = "The time of a frame, from its first record to the flip, the least", before = QUALITY_LEAST, after = QUALITY_MEDIAN, unit = "microseconds", faster = .Lower},
	{sentence = "The time of a key to the screen, through the console", title = "A key to the screen through the console, the least", before = QUALITY_LEAST, after = QUALITY_MEDIAN, unit = "microseconds", faster = .Lower},
	{sentence = "The start of a window, from Process_Start to its first frame", title = "The start of the window of locks", before = QUALITY_WINDOW_START_TAIL, after = QUALITY_MICROSECONDS, unit = "microseconds", faster = .Lower},
	{sentence = LOG_RECORDS_OF_THE_START_SENTENCE, title = "The log records up to a usable machine", before = "up to \"kernel: ok\", ", after = " up to \"root: the machine is usable\"", unit = "log records", faster = .Lower},
	{sentence = LOG_MODULE_FILES_SENTENCE, title = "The module file of the root service", before = "module files: root ", after = " bytes, ", unit = "bytes", faster = .Lower},
}

// What the release command or the history command does with a record.
Measure_History_Copy_Decision :: enum {
	Write,
	Same_Run, // The newest earlier copy holds the same run: no copy.
	Refused, // The record does not have the form of a measure record.
}

// The copy that the release command writes after the other files.
Measure_History_Copy :: struct {
	write: bool,
	path:  string,
	text:  string,
}

// One place of a chart: a release of the history, with or without a number.
Measure_History_Point :: struct {
	release:    string,
	present:    bool,
	value:      f64,
	value_text: string, // The number as the log writes it.
	commit:     string,
	time:       string,
	host:       string,
	missing:    string, // Why the release has no number.
}

measure_history_file_path :: proc(number: Release_Number) -> string {
	return strings.concatenate({MEASURE_HISTORY_FOLDER, "/", release_number_text(number), MEASURE_HISTORY_FILE_EXTENSION}, context.temp_allocator)
}

// measure_history_file_release gives the release that a file of the
// history names: "0.92.0.txt" is the release 0.92.0. A name in another
// form, "0.092.0.txt" too, names none.
measure_history_file_release :: proc(name: string) -> (number: Release_Number, ok: bool) {
	if !strings.has_suffix(name, MEASURE_HISTORY_FILE_EXTENSION) {
		return {}, false
	}
	stem := name[:len(name) - len(MEASURE_HISTORY_FILE_EXTENSION)]
	number = release_number_parse(stem) or_return
	return number, release_number_text(number) == stem
}

// measure_history_same_run says whether two records are one run of the full
// check. Two runs of one commit, at two times, are two runs.
measure_history_same_run :: proc(a, b: Measure_Record) -> bool {
	return a.time == b.time && a.commit == b.commit
}

// measure_history_newest_before gives the copy of the highest release that
// comes before a release, in any order of the list.
measure_history_newest_before :: proc(releases: []Measure_History_Release, number: Release_Number) -> (newest: Measure_History_Release, found: bool) {
	for candidate in releases {
		if !release_number_less(candidate.release, number) {
			continue
		}
		if !found || release_number_less(newest.release, candidate.release) {
			newest, found = candidate, true
		}
	}
	return
}

// measure_history_copy_decide decides whether a release gets a copy of a
// record: not when the record does not read, and not when the copy of the
// release before holds the same run, since no full check ran between them.
measure_history_copy_decide :: proc(record_text: string, earlier: []Measure_History_Release, number: Release_Number) -> (decision: Measure_History_Copy_Decision, same_run_release: Release_Number, problem: string) {
	record, parse_problem := measure_record_parse(record_text)
	if parse_problem != "" {
		return .Refused, {}, parse_problem
	}
	if newest, found := measure_history_newest_before(earlier, number); found && measure_history_same_run(newest.record, record) {
		return .Same_Run, newest.release, ""
	}
	return .Write, {}, ""
}

// measure_history_read reads each copy of the folder, oldest release
// first. An absent folder is an empty history. A file with another name or
// another form stops the reader: it is a file of the repository that a
// developer can change.
measure_history_read :: proc(folder: string) -> (releases: []Measure_History_Release, problem: string) {
	if !os.exists(folder) {
		return nil, ""
	}
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		return nil, fmt.tprintf("%s: cannot list the folder: %v", folder, list_error)
	}
	found := make([dynamic]Measure_History_Release, context.temp_allocator)
	for entry in entries {
		number, name_ok := measure_history_file_release(entry.name)
		if !name_ok || entry.type == .Directory {
			return nil, fmt.tprintf("%s/%s: each file of the measure history is named <release number>%s", folder, entry.name, MEASURE_HISTORY_FILE_EXTENSION)
		}
		path := strings.concatenate({folder, "/", entry.name}, context.temp_allocator)
		data, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			return nil, fmt.tprintf("%s: cannot read: %v", path, read_error)
		}
		record, parse_problem := measure_record_parse(string(data))
		if parse_problem != "" {
			return nil, fmt.tprintf("%s: %s", path, parse_problem)
		}
		append(&found, Measure_History_Release{release = number, path = path, text = string(data), record = record})
	}
	slice.sort_by(found[:], proc(a, b: Measure_History_Release) -> bool {
		return release_number_less(a.release, b.release)
	})
	return found[:], ""
}

// measure_history_copy_prepare reads the measure record and the history
// before the release command writes any file, and gives the copy of the
// release. A record that does not read stops the release.
measure_history_copy_prepare :: proc(number: Release_Number) -> (copy: Measure_History_Copy, ok: bool) {
	number_text := release_number_text(number)
	record_text, has_record := foundation.read_text_file_quiet(MEASURE_RECORD_FILE)
	if !has_record {
		fmt.printfln("modustool: %s is absent: the release %s has no copy in %s", MEASURE_RECORD_FILE, number_text, MEASURE_HISTORY_FOLDER)
		return {}, true
	}
	earlier, read_problem := measure_history_read(MEASURE_HISTORY_FOLDER)
	if read_problem != "" {
		fmt.eprintfln("modustool: %s", read_problem)
		return {}, false
	}
	decision, same_run_release, problem := measure_history_copy_decide(record_text, earlier, number)
	if decision == .Refused {
		fmt.eprintfln("modustool: %s: %s; the release is not written", MEASURE_RECORD_FILE, problem)
		return {}, false
	}
	if decision == .Same_Run {
		fmt.printfln("modustool: %s holds the run of the release %s: the release %s has no measures of its own, and no copy", MEASURE_RECORD_FILE, release_number_text(same_run_release), number_text)
		return {}, true
	}
	return Measure_History_Copy{write = true, path = measure_history_file_path(number), text = record_text}, true
}

// measure_history_copy_write writes the copy that the release command
// prepared.
measure_history_copy_write :: proc(copy: Measure_History_Copy) -> bool {
	if !copy.write {
		return true
	}
	foundation.make_folder(MEASURE_HISTORY_FOLDER) or_return
	if error := os.write_entire_file(copy.path, transmute([]u8)copy.text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", copy.path, error)
		return false
	}
	fmt.printfln("modustool: copied %s to %s", MEASURE_RECORD_FILE, copy.path)
	return true
}

// measure_history_release_tags gives the release numbers of the release
// tags of the output of ship_tag_list_command, oldest first.
measure_history_release_tags :: proc(output: string) -> []Release_Number {
	numbers := make([dynamic]Release_Number, context.temp_allocator)
	for line in strings.split_lines(output, context.temp_allocator) {
		name := strings.trim_space(line)
		if !strings.has_prefix(name, RELEASE_TAG_PREFIX) {
			continue
		}
		if number, ok := release_number_parse(name[len(RELEASE_TAG_PREFIX):]); ok {
			append(&numbers, number)
		}
	}
	slice.sort_by(numbers[:], release_number_less)
	return numbers[:]
}

// The command that prints the measure record in the tree of a release tag.
// It fails when the tree of the tag has no such file.
measure_history_tag_record_command :: proc(number: Release_Number) -> []string {
	return command_words("git", "show", fmt.tprintf("%s:%s", release_tag_name(number), MEASURE_RECORD_FILE))
}

// run_measure_history gives each release tag whose tree holds a measure
// record its copy in the history. It changes no file that exists.
run_measure_history :: proc(args: []string) -> int {
	if len(args) != 0 {
		fmt.eprintln("modustool measure-history takes no argument")
		return foundation.EXIT_USAGE
	}
	tag_list, list_ok := command_output(ship_tag_list_command())
	if !list_ok {
		fmt.eprintln("modustool: measure-history: git cannot list the release tags")
		return foundation.EXIT_FAILURE
	}
	tags := measure_history_release_tags(tag_list)
	kept, read_problem := measure_history_read(MEASURE_HISTORY_FOLDER)
	if read_problem != "" {
		fmt.eprintfln("modustool: measure-history: %s", read_problem)
		return foundation.EXIT_FAILURE
	}
	releases := make([dynamic]Measure_History_Release, context.temp_allocator)
	append(&releases, ..kept)
	with_record, written, same_run, present := 0, 0, 0, 0
	for number in tags {
		record_text, has_record := command_output(measure_history_tag_record_command(number))
		if !has_record {
			continue
		}
		with_record += 1
		path := measure_history_file_path(number)
		if existing, exists := foundation.read_text_file_quiet(path); exists {
			present += 1
			if existing != record_text {
				fmt.printfln("modustool: measure-history: %s differs from %s in the tag %s; the file is kept", path, MEASURE_RECORD_FILE, release_tag_name(number))
			}
			continue
		}
		decision, same_run_release, problem := measure_history_copy_decide(record_text, releases[:], number)
		if decision == .Refused {
			fmt.printfln("modustool: measure-history: %s in the tag %s does not read: %s; no copy", MEASURE_RECORD_FILE, release_tag_name(number), problem)
			continue
		}
		if decision == .Same_Run {
			same_run += 1
			fmt.printfln("modustool: measure-history: the tag %s holds the run of the release %s; no copy", release_tag_name(number), release_number_text(same_run_release))
			continue
		}
		if !measure_history_copy_write(Measure_History_Copy{write = true, path = path, text = record_text}) {
			return foundation.EXIT_FAILURE
		}
		record, _ := measure_record_parse(record_text)
		append(&releases, Measure_History_Release{release = number, path = path, text = record_text, record = record})
		written += 1
	}
	fmt.printfln("modustool: measure-history: %d release tags, %d hold %s; %d copies written, %d already in %s, %d with the run of an earlier release", len(tags), with_record, MEASURE_RECORD_FILE, written, present, MEASURE_HISTORY_FOLDER, same_run)
	return 0
}

// measure_history_value reads the number that a series follows from a line
// of a log: the digits just after its words before, with at most one
// decimal point, then its words after. A line whose words changed gives no
// number: a chart then has a gap, never a wrong point.
measure_history_value :: proc(series: Measure_History_Series, line: string) -> (text: string, value: f64, ok: bool) {
	place := strings.index(line, series.before)
	if place < 0 || series.before == "" {
		return "", 0, false
	}
	rest := line[place + len(series.before):]
	length := 0
	has_point := false
	for length < len(rest) {
		character := rest[length]
		if character >= '0' && character <= '9' {
			length += 1
			continue
		}
		// A point between two digits is a decimal point; a point after the
		// number ends a sentence.
		if character == '.' && !has_point && length > 0 && length + 1 < len(rest) && rest[length + 1] >= '0' && rest[length + 1] <= '9' {
			has_point = true
			length += 1
			continue
		}
		break
	}
	if length == 0 || !strings.has_prefix(rest[length:], series.after) {
		return "", 0, false
	}
	parsed, parsed_ok := strconv.parse_f64(rest[:length])
	if !parsed_ok {
		return "", 0, false
	}
	return rest[:length], parsed, true
}

// measure_history_points gives one place for each release of the history,
// in its order, with the number of the series where the release has it.
measure_history_points :: proc(series: Measure_History_Series, releases: []Measure_History_Release) -> (points: []Measure_History_Point, present_count: int) {
	points = make([]Measure_History_Point, len(releases), context.temp_allocator)
	for history_release, index in releases {
		point := Measure_History_Point {
			release = release_number_text(history_release.release),
			commit  = history_release.record.commit,
			time    = history_release.record.time,
			host    = history_release.record.host,
			missing = "the record has no line of this measure",
		}
		for number in history_release.record.numbers {
			if number.sentence != series.sentence || !number.found {
				continue
			}
			text, value, ok := measure_history_value(series, number.line)
			if ok {
				point.present = true
				point.value = value
				point.value_text = text
				point.missing = ""
				present_count += 1
			} else {
				point.missing = "the line has no number in the words of this chart"
			}
			break
		}
		points[index] = point
	}
	return
}

// measure_history_point_x gives the place of a release on the horizontal
// axis: the releases at equal steps, a release alone in the middle.
measure_history_point_x :: proc(index, count: int) -> int {
	left :: MEASURE_HISTORY_CHART_MARGIN
	right :: MEASURE_HISTORY_CHART_WIDTH - MEASURE_HISTORY_CHART_MARGIN
	if count <= 1 {
		return MEASURE_HISTORY_CHART_WIDTH / 2
	}
	return left + index * (right - left) / (count - 1)
}

// measure_history_point_y gives the height of a number on a scale from
// zero, at the bottom, to the largest number, at the top. SVG counts down.
measure_history_point_y :: proc(value, most: f64) -> int {
	top :: MEASURE_HISTORY_CHART_MARGIN
	bottom :: MEASURE_HISTORY_CHART_HEIGHT - MEASURE_HISTORY_CHART_MARGIN
	if most <= 0 || value <= 0 {
		return bottom
	}
	return bottom - int(value / most * f64(bottom - top) + 0.5)
}

// measure_history_chart_svg writes the chart of one series: a line at zero
// and a line at the largest number, a line through each run of releases
// that have a number, and a square at each number with its release in its
// title. It holds no other text: the SVG scales with its card, so a text in
// it has no width that the tool can compute.
measure_history_chart_svg :: proc(points: []Measure_History_Point, label: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	top :: MEASURE_HISTORY_CHART_MARGIN
	bottom :: MEASURE_HISTORY_CHART_HEIGHT - MEASURE_HISTORY_CHART_MARGIN
	half :: MEASURE_HISTORY_POINT_SIZE / 2
	most := 0.0
	for point in points {
		if point.present {
			most = max(most, point.value)
		}
	}
	fmt.sbprintf(&b, "<svg class=\"measure-history-chart\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"", MEASURE_HISTORY_CHART_WIDTH, MEASURE_HISTORY_CHART_HEIGHT)
	foundation.html_escape(&b, label)
	strings.write_string(&b, "\">\n")
	fmt.sbprintf(&b, "<line class=\"measure-history-scale\" x1=\"0\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", top, MEASURE_HISTORY_CHART_WIDTH, top)
	fmt.sbprintf(&b, "<line class=\"measure-history-scale\" x1=\"0\" y1=\"%d\" x2=\"%d\" y2=\"%d\"/>\n", bottom, MEASURE_HISTORY_CHART_WIDTH, bottom)
	// The places of the points of consecutive releases with a number: one
	// line; a release with no number ends it.
	line_places := make([dynamic]string, context.temp_allocator)
	line_write :: proc(b: ^strings.Builder, places: ^[dynamic]string) {
		if len(places^) >= 2 {
			strings.write_string(b, "<polyline class=\"measure-history-line\" points=\"")
			strings.write_string(b, strings.join(places^[:], " ", context.temp_allocator))
			strings.write_string(b, "\"/>\n")
		}
		clear(places)
	}
	for point, index in points {
		if !point.present {
			line_write(&b, &line_places)
			continue
		}
		append(&line_places, fmt.tprintf("%d,%d", measure_history_point_x(index, len(points)), measure_history_point_y(point.value, most)))
	}
	line_write(&b, &line_places)
	for point, index in points {
		if !point.present {
			continue
		}
		fmt.sbprintf(&b, "<rect class=\"measure-history-point\" x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"><title>", measure_history_point_x(index, len(points)) - half, measure_history_point_y(point.value, most) - half, MEASURE_HISTORY_POINT_SIZE, MEASURE_HISTORY_POINT_SIZE)
		foundation.html_escape(&b, point.release)
		strings.write_string(&b, ": ")
		foundation.html_escape(&b, point.value_text)
		strings.write_string(&b, "</title></rect>\n")
	}
	strings.write_string(&b, "</svg>\n")
	return strings.to_string(b)
}

// The rules of the charts of the history. The cards and their grid are the
// rules of the charts of the home (.measure-charts, .card.measure-chart).
// The width of a line does not scale with the SVG.
SITE_MEASURE_HISTORY_RULES :: `
/* The charts of the measure history: a line and its points over the
   releases, from zero, in the accent of the measure. */
.measure-history-chart { display: block; width: 100%; height: auto; margin: 0 0 4px; background: var(--track); }
.measure-history-scale { stroke: var(--dim); stroke-width: 1px; vector-effect: non-scaling-stroke; }
.measure-history-line { fill: none; stroke: var(--accent-graphic); stroke-width: 2px; vector-effect: non-scaling-stroke; }
.measure-history-point { fill: var(--accent-graphic); }
.measure-history-releases { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 0 16px; margin: 0 0 8px; color: var(--dim); font-family: var(--mono); font-size: 12px; line-height: 16px; }
.measure-history-numbers { margin: 0 0 8px; font-size: 14px; line-height: 20px; }
.measure-history-numbers ul { list-style: none; margin: 4px 0 0; padding: 0; }
.measure-history-numbers li { margin: 0; padding: 2px 0; overflow-wrap: anywhere; }
`

// record_text gives a record as Name{field = value, field = "text"}.
record_text :: proc(file: []u8, described: module.Record, record: []u8) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, module.string_at(file, described.name_offset, described.name_count))
	strings.write_byte(&builder, '{')
	for number in 0 ..< described.field_count {
		item, _ := module.field(file, described, number)
		if number > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, module.string_at(file, item.name_offset, item.name_count))
		strings.write_string(&builder, " = ")
		value := build.field_value(record, item)
		if item.type == u8(module.Type.Text) {
			strings.write_quoted_string(&builder, value)
		} else {
			strings.write_string(&builder, value)
		}
	}
	strings.write_byte(&builder, '}')
	return strings.to_string(builder)
}

// measure_history_release_example gives one release of the history whose
// record holds the lock measure with a line, or with no line when the line
// is "": the example that the tests of the history and of its chart on the
// site read.
measure_history_release_example :: proc(release: Release_Number, time_text, commit, locks_line: string) -> Measure_History_Release {
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

// measure_history_locks_line_example gives a line of the lock measure with
// the count of four lockers, for the examples of the history.
measure_history_locks_line_example :: proc(four_lockers: string) -> string {
	return strings.concatenate({"[locks] locks: kernel entries in one second, each locker on its own objects: 1 locker 7616000, 2 lockers 13041706, 4 lockers ", four_lockers}, context.temp_allocator)
}
