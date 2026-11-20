// The data of the site and the helpers that its pages share (docs/SITE.md):
// the measured numbers and the logs that they come from, and the escape of
// every text of a file. The pages are in site_frame.odin and
// site_pages.odin; the pictures of the screen are in site_gallery.odin.
package site

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modus:support/graphics"
import "modustool:foundation"
import "modustool:checks"

SITE_FOLDER :: foundation.BUILD_FOLDER + "/site"
SITE_PAGE :: "index.html"
SITE_STYLE_SHEET :: "style.css"
SITE_SYSTEM_NAME :: "modus"
SITE_RELEASE_COUNT :: 5
SITE_NOT_MEASURED :: "Not measured."

// Where a number or the stages of the start that a page shows come from:
// a log in build/ that is newer than the measure record, or the measure
// record.
Site_Measure_Source :: enum {
	None,
	Build,
	Record,
}

// One number as the page shows it.
Site_Measured :: struct {
	measure:        checks.Measure_Entry,
	found:          bool,
	source:         Site_Measure_Source,
	path:           string,
	conditions:     string,
	line_number:    int,
	matching_lines: int,
	text:           string, // The line, with no "[process] " label.
	written:        string, // The time of the log, or of the measure record, in UTC.
	log_time:       time.Time, // The time of the log in build/ that has the line.
	missing:        string, // Why the number is absent.
}

// The measure record as the site reads it from the work tree.
Site_Measure_Record :: struct {
	present: bool,
	record:  checks.Measure_Record,
	written: time.Time, // The time of the file in the work tree.
}

Site_Accent :: struct {
	class_name: string,
	color:      graphics.Color,
	// The shade of the accent, in percent, that fills a form on the light
	// page: a segment of the line of time of the start, a bar of a chart.
	// The accent itself is too near white there for a form that carries a
	// fact. On the dark page the form takes the accent.
	light_graphic_percent: u32,
}

site_accents := [?]Site_Accent {
	{"accent-kernel", graphics.DARK_KERNEL, 73},
	{"accent-process", graphics.DARK_PROCESS, 58},
	{"accent-memory", graphics.DARK_MEMORY, 65},
	{"accent-machine", graphics.DARK_MACHINE, 78},
	{"accent-boot", graphics.DARK_BOOT_PROGRAM, 65},
	{"accent-firmware", graphics.DARK_FIRMWARE, 83},
}

// site_accent_graphic_color gives the color of a form in an accent, in one
// form of the page.
site_accent_graphic_color :: proc(accent: Site_Accent, light: bool) -> graphics.Color {
	return light ? graphics.shade(accent.color, accent.light_graphic_percent) : accent.color
}

// site_without_process_label takes the label "[process] " or
// "[process] " of the log off a line.
site_without_process_label :: proc(line: string) -> string {
	if strings.has_prefix(line, "[") {
		if end := strings.index(line, "] "); end > 0 {
			return line[end + 2:]
		}
	}
	return line
}

// site_line_choose gives the line of log_line_choose with no label.
site_line_choose :: proc(content, pattern: string, choice: checks.Measure_Line_Choice) -> (text: string, line_number, matching_lines: int) {
	line: string
	line, line_number, matching_lines = checks.log_line_choose(content, pattern, choice)
	return site_without_process_label(line), line_number, matching_lines
}

// site_file_time gives the time of the last change of a file, in UTC.
site_file_time :: proc(path: string) -> string {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return checks.measure_time_text(info.modification_time)
}

site_measure_read :: proc(measure: checks.Measure_Entry) -> (measured: Site_Measured) {
	measured.measure = measure
	reasons := make([dynamic]string, context.temp_allocator)
	for path in measure.files {
		if path == "" {
			continue
		}
		if !os.exists(path) {
			append(&reasons, fmt.tprintf("%s: no file", path))
			continue
		}
		data, read_problem := checks.measure_log_read(path)
		if read_problem != "" {
			append(&reasons, fmt.tprintf("%s: %s", path, read_problem))
			continue
		}
		text, line_number, matching_lines := site_line_choose(data, measure.pattern, measure.choice)
		if matching_lines == 0 {
			append(&reasons, fmt.tprintf("%s: no line with \"%s\"", path, measure.pattern))
			continue
		}
		measured.found = true
		measured.source = .Build
		measured.path = path
		measured.conditions = checks.measure_output_conditions(path)
		measured.line_number = line_number
		measured.matching_lines = matching_lines
		measured.text = text
		measured.written = site_file_time(path)
		if file_information, stat_error := os.stat(path, context.temp_allocator); stat_error == nil {
			measured.log_time = file_information.modification_time
		}
		return
	}
	measured.missing = strings.join(reasons[:], "; ", context.temp_allocator)
	return
}

// site_measure_record_read reads the measure record of the work tree. An
// absent file is no problem: the site then has the logs of build/ only. A
// file that does not have its form stops the site.
site_measure_record_read :: proc(path: string) -> (found: Site_Measure_Record, problem: string) {
	file_information, stat_error := os.stat(path, context.temp_allocator)
	if stat_error != nil {
		return {}, ""
	}
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		return {}, fmt.tprintf("%s: cannot read: %v", path, read_error)
	}
	record, parse_problem := checks.measure_record_parse(string(data))
	if parse_problem != "" {
		return {}, fmt.tprintf("%s: %s", path, parse_problem)
	}
	return Site_Measure_Record{present = true, record = record, written = file_information.modification_time}, ""
}

// site_measure_source_choose chooses where a fact of the page comes from.
// A log of build/ that is newer than the measure record wins: a developer who
// just ran the tests sees their numbers. Else the record, when it holds
// the fact. A checkout writes the record at the time of the checkout, so
// the logs of an older run lose.
site_measure_source_choose :: proc(build_found: bool, build_time: time.Time, record: Site_Measure_Record, record_holds: bool) -> Site_Measure_Source {
	if build_found && (!record.present || time.diff(record.written, build_time) > 0) {
		return .Build
	}
	if record.present && record_holds {
		return .Record
	}
	return .None
}

// site_measure_record_number finds a number of the table in the record, by
// its sentence.
site_measure_record_number :: proc(record: checks.Measure_Record, sentence: string) -> (number: checks.Measure_Record_Number, held: bool) {
	for candidate in record.numbers {
		if candidate.sentence == sentence {
			return candidate, true
		}
	}
	return {}, false
}

// site_measure_resolve gives a number as the page shows it, from what the
// logs of build/ gave and from the measure record.
site_measure_resolve :: proc(from_build: Site_Measured, record: Site_Measure_Record) -> Site_Measured {
	measured := from_build
	record_number, held := site_measure_record_number(record.record, from_build.measure.sentence)
	measured.source = site_measure_source_choose(from_build.found, from_build.log_time, record, held && record_number.found)
	switch measured.source {
	case .Build:
		return measured
	case .Record:
		measured.found = true
		measured.path = record_number.log
		measured.conditions = record_number.machine
		measured.line_number = record_number.line_number
		measured.matching_lines = record_number.matching_lines
		measured.text = site_without_process_label(record_number.line)
		measured.written = record.record.time
		measured.missing = ""
		return measured
	case .None:
	}
	measured.found = false
	reasons := make([dynamic]string, context.temp_allocator)
	if from_build.found {
		append(&reasons, fmt.tprintf("%s is older than %s", from_build.path, checks.MEASURE_RECORD_FILE))
	} else if from_build.missing != "" {
		append(&reasons, from_build.missing)
	}
	if !record.present {
		append(&reasons, fmt.tprintf("%s: no file", checks.MEASURE_RECORD_FILE))
	} else if !held {
		append(&reasons, fmt.tprintf("the full check of %s does not have this number", record.record.time))
	} else {
		append(&reasons, fmt.tprintf("the full check of %s did not print it: %s", record.record.time, record_number.absent))
	}
	measured.missing = strings.join(reasons[:], "; ", context.temp_allocator)
	return measured
}

// site_boot_log_choose gives the lines of the start that the home shows,
// from the log of the main machine or from the measure record, by the same
// rule as the numbers.
site_boot_log_choose :: proc(record: Site_Measure_Record) -> (log: string, source: Site_Measure_Source) {
	build_time: time.Time
	file_information, stat_error := os.stat(checks.TEST_OUTPUT, context.temp_allocator)
	build_found := stat_error == nil
	if build_found {
		build_time = file_information.modification_time
	}
	switch site_measure_source_choose(build_found, build_time, record, len(record.record.boot_lines) > 0) {
	case .Build:
		content, _ := foundation.read_text_file_quiet(checks.TEST_OUTPUT)
		return content, .Build
	case .Record:
		return strings.join(record.record.boot_lines, "\n", context.temp_allocator), .Record
	case .None:
	}
	return "", .None
}

// site_short_commit gives the first digits of a commit, as the pages show
// it.
site_short_commit :: proc(commit: string) -> string {
	if commit == "" {
		return "a commit that the tool could not read"
	}
	return commit[:min(checks.MEASURE_COMMIT_SHORT_LENGTH, len(commit))]
}

// site_tree_words says whether the tree of a run had changes.
site_tree_words :: proc(state: checks.Measure_Tree_State) -> string {
	switch state {
	case .Clean:
		return "with no change that was not committed"
	case .Changed:
		return "with changes that were not committed"
	case .Unknown:
	}
	return "whose changes the tool could not read"
}

// site_origin_words says where a number or the stages of the start come
// from, as a line of Markdown.
site_origin_words :: proc(source: Site_Measure_Source, record: Site_Measure_Record) -> string {
	switch source {
	case .Record:
		day := record.record.time[:min(10, len(record.record.time))]
		return fmt.tprintf("Measured in the full check of %s, on the tree of `%s`, %s", day, site_short_commit(record.record.commit), site_tree_words(record.record.tree))
	case .Build:
		return "Measured in this work tree: the log in `" + foundation.BUILD_FOLDER + "/` is newer than `" + checks.MEASURE_RECORD_FILE + "`"
	case .None:
	}
	return ""
}

// site_inline writes a line of Markdown as HTML: `code`, **bold**, and the
// text of a link [text](address) with no link, because the address names a
// file of the repository that the site does not have. Every other character
// is escaped.
site_inline :: proc(builder: ^strings.Builder, text: string) {
	bold_open := false
	index := 0
	for index < len(text) {
		character := text[index]
		if character == '`' {
			end := strings.index_byte(text[index + 1:], '`')
			if end >= 0 {
				strings.write_string(builder, "<code>")
				foundation.html_escape(builder, text[index + 1:index + 1 + end])
				strings.write_string(builder, "</code>")
				index += end + 2
				continue
			}
		}
		if character == '*' && index + 1 < len(text) && text[index + 1] == '*' {
			strings.write_string(builder, bold_open ? "</strong>" : "<strong>")
			bold_open = !bold_open
			index += 2
			continue
		}
		if character == '[' {
			closing := strings.index_byte(text[index + 1:], ']')
			if closing >= 0 {
				after := index + 1 + closing + 1
				if after < len(text) && text[after] == '(' {
					end := strings.index_byte(text[after + 1:], ')')
					if end >= 0 {
						site_inline(builder, text[index + 1:index + 1 + closing])
						index = after + 1 + end + 1
						continue
					}
				}
			}
		}
		foundation.html_escape(builder, text[index:index + 1])
		index += 1
	}
	if bold_open {
		strings.write_string(builder, "</strong>")
	}
}

// site_inline_text gives the HTML of a line of Markdown.
site_inline_text :: proc(text: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	site_inline(&builder, text)
	return strings.to_string(builder)
}

// site_plain writes a line of Markdown as escaped plain text, for an
// attribute: the marks of code and bold go away.
site_plain :: proc(builder: ^strings.Builder, text: string) {
	without_code, _ := strings.remove_all(text, "`", context.temp_allocator)
	without_bold, _ := strings.remove_all(without_code, "**", context.temp_allocator)
	foundation.html_escape(builder, without_bold)
}

site_accent_class :: proc(color: graphics.Color) -> string {
	for accent in site_accents {
		if accent.color == color {
			return accent.class_name
		}
	}
	return site_accents[0].class_name
}
