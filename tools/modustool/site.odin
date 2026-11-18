// The data of the site and the helpers that its pages share (docs/SITE.md):
// the measured numbers and the logs that they come from, and the escape of
// every text of a file. The pages are in site_frame.odin and
// site_pages.odin; the pictures of the screen are in site_gallery.odin.
package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modus:support/graphics"
import "modustool:foundation"
import "modustool:build"

SITE_FOLDER :: foundation.BUILD_FOLDER + "/site"
SITE_PAGE :: "index.html"
SITE_STYLE_SHEET :: "style.css"
// The address of the repository: the one place that names it, because its
// name can change with the name of the system.
SITE_REPOSITORY_ADDRESS :: "https://github.com/sachahjkl/modus"
SITE_SYSTEM_NAME :: "modus"
SITE_RELEASE_COUNT :: 5
SITE_NOT_MEASURED :: "Not measured."

// Which line a number takes when the log has several lines with its text.
Site_Line_Choice :: enum {
	First,
	Last,
}

// The section of the page that shows a number.
Site_Measure_Place :: enum {
	Numbers,
	Build,
}

// One measured number: its sentence for the reader, the logs where a
// process printed it, and a part of the text of that line. The first log
// that has the line gives it. The page quotes the whole line: the line
// gives its own conditions (the count, the size, the unit).
// A required number is a line that a scenario of `modustool test` waits
// for, a line that a measure run of `modustool screenshots` waits for
// (measure_runs.odin), or the line of the second build: a run of
// `modustool screenshots` that passed holds it, so the measure record
// must hold it. A rate over a duration comes from a measure run only: the
// test checks by count and measures no rate.
Site_Measure :: struct {
	sentence: string,
	files:    [2]string, // "" for no second log.
	pattern:  string,
	choice:   Site_Line_Choice,
	accent:   graphics.Color, // The color of the concept that the number measures.
	place:    Site_Measure_Place,
	required: bool,
	// How to read the number: what the process does to measure it, and what
	// the number does not say. Markdown.
	reading: string,
}

site_measures := [?]Site_Measure {
	{sentence = "Kernel entries in one second, with 1, 2 and 4 processes that each take the locks of their own objects", files = {TEST_OUTPUT_MEASURE, ""}, pattern = "locks: kernel entries in one second", choice = .First, accent = graphics.DARK_KERNEL, place = .Numbers, required = true, reading = "Each locker is a process that enters the kernel again and again and takes only the locks of its own objects, so no two lockers wait for one lock. A count that grows with the lockers shows that the kernel serves several processors at once. It does not say what happens when processes share one object."},
	{sentence = "Reads of the time in one second from the time page, with no kernel entry", files = {TEST_OUTPUT_MEASURE_CLOCK, ""}, pattern = "clock: the time page:", choice = .First, accent = graphics.DARK_KERNEL, place = .Numbers, required = true, reading = "A process reads the time from a page that the kernel keeps up to date. The part that matters is the second one: **0 kernel entries for one million reads**, so the time costs a read of memory. The count of reads follows the speed of the host processor."},
	{sentence = "Wakes in one second of two threads that wake each other on a busy machine, under the strategy EEVDF", files = {TEST_OUTPUT_MEASURE_SCHEDULER, ""}, pattern = "scheduler: EEVDF: two threads that wake each other", choice = .First, accent = graphics.DARK_KERNEL, place = .Numbers, required = true, reading = "Two threads wake each other while a spinner keeps each processor busy: the count is their wakes in one second. The same line gives how late a thread that sleeps 2 ms wakes among spinners, and the share of the processor of each spinner of one weight. It shows the scheduler under load; it compares no other strategy."},
	{sentence = "One glyph of the vector font, from its outline and from the glyph cache", files = {TEST_OUTPUT, ""}, pattern = "vector_glyphs: one glyph from its outline", choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "The time to draw one glyph of the vector font from its outline at three scales, the time to copy it from the glyph cache, and the time of one glyph of the bitmap font. The difference is the work that the glyph cache saves each process."},
	{sentence = "A full frame of the compositor", files = {TEST_OUTPUT, ""}, pattern = "compositor: a full frame of", choice = .Last, accent = graphics.DARK_PROCESS, place = .Numbers, required = false, reading = "The time to draw the whole screen with its windows, on the processor: the system has no graphics device. The compositor prints it only when a frame redraws the whole screen, so the number is not required. Most frames redraw their damage rectangles only, and cost less."},
	{sentence = "A clear and a present of a frame of 1920 x 1080 on the processor", files = {TEST_OUTPUT_MEASURE, ""}, pattern = PROCESSOR_FRAME_CLEAR_AND_PRESENT, choice = .First, accent = graphics.DARK_MEMORY, place = .Numbers, required = true, reading = "The process `processor_frame` fills a canvas of 1920 x 1080 with one color, then copies it into a second canvas, as the compositor copies its frame into a screen page: 8.3 MB written, then 8.3 MB read and written. It is the bound of the memory bandwidth for a frame of the reference screen with no GPU. The least and the median of 21 frames; the frames in one second come from the median."},
	{sentence = "A full frame of the compositor at 1920 x 1080 with 4 windows, on the processor", files = {TEST_OUTPUT_MEASURE, ""}, pattern = PROCESSOR_FRAME_FULL_FRAME, choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "The phases of a frame of the compositor at the reference screen, in memory: the background, one call of the drawing module for each of 4 windows and one for the bar, then the copy into a screen page. The test machine shows 1024 x 768, so `processor_frame` draws the frame in canvases of its own, with the records of each window in the form of the compositor. The pointer and the page flip are not in it."},
	{sentence = "A frame of the compositor at 1920 x 1080 in its damage, on the processor", files = {TEST_OUTPUT_MEASURE, ""}, pattern = PROCESSOR_FRAME_FRAME_IN_ITS_DAMAGE, choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "The same frame in its damage only: a rectangle of 400 x 300 of the front window, which one Present changed, and the clock of the bar. Most frames of a desktop are of this kind."},
	{sentence = "The execution of a draw table of a desktop at 1920 x 1080, on the processor", files = {TEST_OUTPUT_MEASURE, ""}, pattern = PROCESSOR_FRAME_DRAW_TABLE, choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "One call of the drawing module draws a table that fills the screen: twelve cards with gradients, texts in the font of the cells and in the interface font, opaque pictures, pictures and rectangles with alpha. The line gives the count of each kind. The table is built once; the time is its execution."},
	{sentence = "The time of a frame of the compositor, from the first record that it reads to the flip", files = {TEST_OUTPUT_MEASURE, ""}, pattern = QUALITY_FRAME, choice = .Last, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "A measure of the standard of quality, on the path of the system: from the read of the first record of the root service, of the input service or of a window in the turn that draws the frame (or the start of the draw when that turn read none) to its page flip. The compositor draws at most one frame each 16 ms; that wait is not in the time, so it compares with the 8.3 ms of a frame at 120 Hz. The least and the median of the last 64 frames, at the last line of the run."},
	{sentence = "The time of a key to the screen, through the console", files = {TEST_OUTPUT_MEASURE, ""}, pattern = QUALITY_KEY, choice = .Last, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "A measure of the standard of quality: from the read of the key by the input service to the page flip of the frame that shows its character in the line of the console. The console names the key with its line, its terminal names it with the picture, and the compositor ties the two. The least and the median of 16 keys that the machine test typed, at the last line of the run."},
	{sentence = "The start of a window, from Process_Start to its first frame", files = {TEST_OUTPUT_MEASURE, ""}, pattern = QUALITY_WINDOW_START_LOCKS, choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "A measure of the standard of quality: from the call of the start by the root service (the load of the module, its hash and Process_Start) to the page flip of the first frame of the window of `locks`, which draws its window before its measures."},
	{sentence = "Blocks read in one second from a virtio disk, through the block service in user space", files = {TEST_OUTPUT_MEASURE_DISK, ""}, pattern = "disk: read, 1 block in each request, 32 in flight", choice = .First, accent = graphics.DARK_MEMORY, place = .Numbers, required = true, reading = "One block in each request, 32 requests in flight, through the block service, which is a process. The kernel entries for 100 requests show that the blocks do not pass through the kernel. The disk is a file of the host under virtio: the number is not the speed of a real disk."},
	{sentence = "1000 commits of a process to its private store, one commit for each step", files = {foundation.BUILD_FOLDER + "/test_output_persist_1.txt", ""}, pattern = "notes: count 1000, stopped", choice = .First, accent = graphics.DARK_MEMORY, place = .Numbers, required = true, reading = "The process `notes` commits 1000 times in a row to its private store; each commit is durable on the data disk before the next one starts. The time of one commit is the total divided by 1000. The disk is a file of the host: the number is not the speed of a real disk."},
	{sentence = "The header and the checksum of one UDP datagram, in the process that sends it", files = {TEST_OUTPUT_NETWORK, ""}, pattern = "net: the header and the checksum of a datagram", choice = .First, accent = graphics.DARK_MACHINE, place = .Numbers, required = true, reading = "The time that the process `net` takes to write the UDP header of one datagram of 1472 bytes and to compute its checksum, with no help of the device. The process that sends a datagram does this work: the network service copies the datagram and computes no checksum of it."},
	{sentence = "The round trip of one UDP datagram", files = {TEST_OUTPUT_NETWORK, ""}, pattern = "net: the round trip of one datagram", choice = .First, accent = graphics.DARK_MACHINE, place = .Numbers, required = true, reading = "A datagram of 64 bytes goes to the peer of the tool and back, over the loopback of the host: the least and the middle of 1000 trips. Each trip passes the frame service, the network service and QEMU."},
	{sentence = "UDP datagrams in one second, with 64 in flight", files = {TEST_OUTPUT_NETWORK, ""}, pattern = "net: a burst with 64 datagrams in flight", choice = .First, accent = graphics.DARK_MACHINE, place = .Numbers, required = true, reading = "The process keeps 64 datagrams in flight, and the peer answers each one: the count of answered datagrams in one second, and the count lost."},
	{sentence = "TCP: 1 MiB that the process `fetch` receives from a server of the host", files = {TEST_OUTPUT_TCP_REAL, ""}, pattern = "fetch: GET /large:", choice = .First, accent = graphics.DARK_MACHINE, place = .Numbers, required = true, reading = "The process `fetch` receives 1 MiB over TCP from a server of the host, through the user networking of QEMU (libslirp); a hash checks each byte. The rate includes libslirp, which is not a part of the system."},
	{sentence = "TCP: 1 MiB that the process `fetch` sends to a server of the host", files = {TEST_OUTPUT_TCP_REAL, ""}, pattern = "fetch: POST /sink, 1 MiB", choice = .First, accent = graphics.DARK_MACHINE, place = .Numbers, required = true, reading = "The process `fetch` sends 1 MiB over TCP to a server of the host, which checks the hash. The rate includes the user networking of QEMU, which is not a part of the system."},
	{sentence = "ChaCha20-Poly1305: the seal of one QUIC datagram of 1200 bytes, through the module `cryptography`", files = {TEST_OUTPUT_CRYPTOGRAPHY, ""}, pattern = "cryptography_vectors: seal ChaCha20-Poly1305", choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "The time of the seal of one datagram of 1200 bytes, the size of a QUIC datagram, by the module `cryptography`, and its rate."},
	{sentence = "The same bytes after a second build", files = {build.REPRODUCIBLE_BUILD_RECORD, ""}, pattern = "the same bytes after a second build", choice = .Last, accent = graphics.DARK_KERNEL, place = .Build, required = true, reading = "Not a time: a fact. A second build gives each module, its LLVM IR, its object, the pointer theme files and the boot program, byte for byte. It holds for the compiler of the flake, on the host of the run."},
}

// What each log is: the machine that wrote it and what else ran.
Site_Output_File :: struct {
	path:       string,
	conditions: string,
}

site_output_files := [?]Site_Output_File {
	{TEST_OUTPUT_MEASURE, "The machine of `modustool measure`: a measure run, only the desktop and the process that measures run"},
	{TEST_OUTPUT_MEASURE_CLOCK, "The machine of `modustool measure clock`: a measure run, only the desktop and the process `clock` run"},
	{TEST_OUTPUT_MEASURE_DISK, "The machine of `modustool measure disk`: a measure run, only the desktop and the process `disk` run"},
	{TEST_OUTPUT_MEASURE_SCHEDULER, "The machine of `modustool measure scheduler`: a measure run, only the desktop and the process `scheduler` run"},
	{TEST_OUTPUT, "The main machine of `modustool test`, while the other processes of the test run"},
	{TEST_OUTPUT_NETWORK, "The network machine of `modustool test`: the remote is the peer of the tool, on the loopback of the host"},
	{TEST_OUTPUT_TCP_REAL, "The machine of `modustool test` with QEMU user networking: the remote is the TCP of the host, through libslirp"},
	{TEST_OUTPUT_CRYPTOGRAPHY, "The machine of `modustool test crypto`"},
	{foundation.BUILD_FOLDER + "/test_output_persist_1.txt", "The first machine of the test of persistence of `modustool test`, on a new data disk"},
	{build.REPRODUCIBLE_BUILD_RECORD, "Written by `modustool check`, after it built every module and the boot program a second time and compared the bytes"},
}

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
	measure:        Site_Measure,
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
	record:  Measure_Record,
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
// "[process:channel] " of the log off a line.
site_without_process_label :: proc(line: string) -> string {
	if strings.has_prefix(line, "[") {
		if end := strings.index(line, "] "); end > 0 {
			return line[end + 2:]
		}
	}
	return line
}

// log_line_choose finds the lines of a log that contain the pattern, and
// gives the first or the last one whole, with its label.
log_line_choose :: proc(content, pattern: string, choice: Site_Line_Choice) -> (line: string, line_number, matching_lines: int) {
	for candidate, index in foundation.site_lines(content) {
		if !strings.contains(candidate, pattern) {
			continue
		}
		matching_lines += 1
		if matching_lines == 1 || choice == .Last {
			line = candidate
			line_number = index + 1
		}
	}
	return
}

// site_line_choose gives the line of log_line_choose with no label.
site_line_choose :: proc(content, pattern: string, choice: Site_Line_Choice) -> (text: string, line_number, matching_lines: int) {
	line: string
	line, line_number, matching_lines = log_line_choose(content, pattern, choice)
	return site_without_process_label(line), line_number, matching_lines
}

// site_file_time gives the time of the last change of a file, in UTC.
site_file_time :: proc(path: string) -> string {
	info, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return measure_time_text(info.modification_time)
}

site_output_conditions :: proc(path: string) -> string {
	for output in site_output_files {
		if output.path == path {
			return output.conditions
		}
	}
	return ""
}

site_measure_read :: proc(measure: Site_Measure) -> (measured: Site_Measured) {
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
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			append(&reasons, fmt.tprintf("%s: cannot read: %v", path, err))
			continue
		}
		text, line_number, matching_lines := site_line_choose(string(data), measure.pattern, measure.choice)
		if matching_lines == 0 {
			append(&reasons, fmt.tprintf("%s: no line with \"%s\"", path, measure.pattern))
			continue
		}
		measured.found = true
		measured.source = .Build
		measured.path = path
		measured.conditions = site_output_conditions(path)
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
	record, parse_problem := measure_record_parse(string(data))
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
site_measure_record_number :: proc(record: Measure_Record, sentence: string) -> (number: Measure_Record_Number, held: bool) {
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
		append(&reasons, fmt.tprintf("%s is older than %s", from_build.path, MEASURE_RECORD_FILE))
	} else if from_build.missing != "" {
		append(&reasons, from_build.missing)
	}
	if !record.present {
		append(&reasons, fmt.tprintf("%s: no file", MEASURE_RECORD_FILE))
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
	file_information, stat_error := os.stat(TEST_OUTPUT, context.temp_allocator)
	build_found := stat_error == nil
	if build_found {
		build_time = file_information.modification_time
	}
	switch site_measure_source_choose(build_found, build_time, record, len(record.record.boot_lines) > 0) {
	case .Build:
		content, _ := foundation.site_read_quiet(TEST_OUTPUT)
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
	return commit[:min(MEASURE_COMMIT_SHORT_LENGTH, len(commit))]
}

// site_tree_words says whether the tree of a run had changes.
site_tree_words :: proc(state: Measure_Tree_State) -> string {
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
		return "Measured in this work tree: the log in `" + foundation.BUILD_FOLDER + "/` is newer than `" + MEASURE_RECORD_FILE + "`"
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
				foundation.site_escape(builder, text[index + 1:index + 1 + end])
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
		foundation.site_escape(builder, text[index:index + 1])
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
	foundation.site_escape(builder, without_bold)
}

site_accent_class :: proc(color: graphics.Color) -> string {
	for accent in site_accents {
		if accent.color == color {
			return accent.class_name
		}
	}
	return site_accents[0].class_name
}
