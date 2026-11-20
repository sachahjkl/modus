// The measure record: the file of the repository that holds the measured
// numbers of the last full check, and the facts of its run. A build of the
// site on a clean checkout runs no machine, so it reads the numbers here
// (docs/SITE.md, "The measure record"). `modustool screenshots` writes
// the file; `modustool site` reads it.
package checks

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "modustool:foundation"
import "modus:contract/reference_screen"
import "modus:support/graphics"
import "modustool:build"

MEASURE_RECORD_FOLDER :: "docs/measures"
MEASURE_RECORD_FILE :: MEASURE_RECORD_FOLDER + "/measures.txt"
// The first line names the form: a reader refuses another form.
MEASURE_RECORD_FIRST_LINE :: "measure record 1"
// The last line: a file with no such line was not written whole.
MEASURE_RECORD_LAST_LINE :: "end"
// The count of the first digits of a commit that a page shows.
MEASURE_COMMIT_SHORT_LENGTH :: 7
// A user name or a host name that is shorter is not replaced in a text: it
// matches parts of common words.
MEASURE_PRIVATE_NAME_LEAST_LENGTH :: 3

// Whether the work tree had changes that were not committed when the run
// started.
Measure_Tree_State :: enum {
	Unknown,
	Clean,
	Changed,
}

@(rodata)
measure_tree_state_names := [Measure_Tree_State]string {
	.Unknown = "unknown",
	.Clean   = "clean",
	.Changed = "changed",
}

// What the pass reads before it changes the tree.
Measure_Run_Facts :: struct {
	started: time.Time,
	commit:  string, // 40 hexadecimal digits, or "" when the tool cannot read it.
	tree:    Measure_Tree_State,
}

// One number of `measure_entries` in the record: the whole line of the log
// that holds it, or why the run did not give it.
Measure_Record_Number :: struct {
	sentence:       string, // The sentence of the table: the key of the number.
	found:          bool,
	log:            string, // The path of the log, relative to the repository.
	line_number:    int,
	matching_lines: int,
	machine:        string, // The machine that wrote the log.
	line:           string, // The whole line, with its label "[process] ".
	absent:         string, // Why the run did not give the number.
}

Measure_Record :: struct {
	time:          string, // When the record was written, "2026-11-12 02:09 UTC".
	release:       string, // The newest release of the changelog in the tree of the run.
	commit:        string, // The commit of the tree of the run, or "".
	tree:          Measure_Tree_State,
	host:          string, // The processor of the host and the accelerator of QEMU.
	checks_passed: int,
	numbers:       []Measure_Record_Number,
	boot_lines:    []string, // The lines "kernel: boot: ..." of the main machine.
}

// The texts of the host that no line of the record may hold.
Measure_Private_Names :: struct {
	repository_folder: string, // The absolute path of the repository.
	home_folder:       string,
	user_name:         string,
	host_name:         string,
}

// measure_time_text gives a time as the pages show it.
measure_time_text :: proc(moment: time.Time) -> string {
	year, month, day := time.date(moment)
	hour, minute, _ := time.clock(moment)
	return fmt.tprintf("%04d-%02d-%02d %02d:%02d UTC", year, int(month), day, hour, minute)
}

// measure_run_facts_read reads the commit and the state of the tree. The
// pass calls it first: it writes pictures and the record into the tree.
measure_run_facts_read :: proc() -> Measure_Run_Facts {
	// The commit is kept in memory of its own: the pass frees the temporary
	// memory many times before it writes the record.
	facts := Measure_Run_Facts{started = time.now(), commit = strings.clone(foundation.git_commit_read())}
	command := [?]string{"git", "status", "--porcelain"}
	state, standard_output, _, error := os.process_exec({command = command[:]}, context.temp_allocator)
	if error == nil && state.exited && state.success {
		if len(strings.trim_space(string(standard_output))) == 0 {
			facts.tree = .Clean
		} else {
			facts.tree = .Changed
		}
	}
	return facts
}

// measure_private_names_read reads the texts of the host that the record
// must not hold.
measure_private_names_read :: proc() -> Measure_Private_Names {
	names: Measure_Private_Names
	names.repository_folder, _ = os.get_working_directory(context.temp_allocator)
	names.home_folder = os.get_env("HOME", context.temp_allocator)
	names.user_name = os.get_env("USER", context.temp_allocator)
	if data, error := os.read_entire_file("/proc/sys/kernel/hostname", context.temp_allocator); error == nil {
		names.host_name = strings.trim_space(string(data))
	}
	return names
}

// measure_text_without_private cuts the texts of the host out of a text:
// a path in the repository becomes relative to it, the home folder becomes
// "~", the user name "<user>" and the host name "<host>". The repository
// is in the home folder, so it goes first.
measure_text_without_private :: proc(text: string, names: Measure_Private_Names) -> string {
	result := text
	if len(names.repository_folder) > 1 {
		result, _ = strings.replace_all(result, strings.concatenate({names.repository_folder, "/"}, context.temp_allocator), "", context.temp_allocator)
		result, _ = strings.replace_all(result, names.repository_folder, ".", context.temp_allocator)
	}
	if len(names.home_folder) > 1 {
		result, _ = strings.replace_all(result, names.home_folder, "~", context.temp_allocator)
	}
	if len(names.user_name) >= MEASURE_PRIVATE_NAME_LEAST_LENGTH {
		result, _ = strings.replace_all(result, names.user_name, "<user>", context.temp_allocator)
	}
	if len(names.host_name) >= MEASURE_PRIVATE_NAME_LEAST_LENGTH {
		result, _ = strings.replace_all(result, names.host_name, "<host>", context.temp_allocator)
	}
	return result
}

// measure_host_text gives the host as the record states it: the model of
// the processor, the count of logical processors, and how QEMU runs the
// machine. It names no host, no user and no folder.
measure_host_text :: proc(processor_information: string, has_kvm: bool) -> string {
	model := "a processor whose model the tool cannot read"
	count := 0
	for line in foundation.lines_of_text(processor_information) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		key := strings.trim_space(line[:colon])
		if key == "processor" {
			count += 1
		}
		if key == "model name" && count <= 1 {
			model = strings.trim_space(line[colon + 1:])
		}
	}
	accelerator: string = has_kvm ? "QEMU with KVM" : "QEMU with TCG, with no KVM"
	return fmt.tprintf("%s, %d logical processors; %s", model, count, accelerator)
}

// measure_record_number_from_log takes the line of a number from the
// content of one log. It gives false when the log has no such line.
measure_record_number_from_log :: proc(number: ^Measure_Record_Number, measure: Measure_Entry, path, content: string, names: Measure_Private_Names) -> bool {
	line, line_number, matching_lines := log_line_choose(content, measure.pattern, measure.choice)
	if matching_lines == 0 {
		return false
	}
	number.found = true
	number.log = measure_text_without_private(path, names)
	number.line_number = line_number
	number.matching_lines = matching_lines
	number.machine = measure_output_conditions(path)
	number.line = measure_text_without_private(line, names)
	number.absent = ""
	return true
}

// measure_log_rendered gives the text of a log with the line of each fact
// rendered by the module files of the build. QEMU writes the raw line of a
// fact, and a measured line that became a fact keeps its sentence as the
// identity of its measure (src/md/features/log_facts.md, "The machine
// tests"): the record keeps the sentence, which the history reads as
// before. A log with no fact line stays as it is, and reads no module file.
// Each reader of a measured log calls it: the measure record, the page of
// the measured numbers, the checks of the lines of a measure run, the lines
// that a measure run prints and the frame of the test of the sound. The
// catalog of the module files is the one that the run of the tool keeps
// (build.fact_lines_render_of_build), so the logs of one measure record
// read each module file once.
measure_log_rendered :: proc(content: string) -> (rendered: string, problem: string) {
	return build.fact_lines_render_of_build(content)
}

// measure_record_number_read reads one number from the logs of the run. A
// log that is older than the start of the run is of another run: it is not
// read.
measure_record_number_read :: proc(measure: Measure_Entry, started: time.Time, names: Measure_Private_Names) -> Measure_Record_Number {
	number := Measure_Record_Number{sentence = measure.sentence}
	reasons := make([dynamic]string, context.temp_allocator)
	for path in measure.files {
		if path == "" {
			continue
		}
		file_information, stat_error := os.stat(path, context.temp_allocator)
		if stat_error != nil {
			append(&reasons, fmt.tprintf("%s: no file", path))
			continue
		}
		if time.diff(started, file_information.modification_time) < 0 {
			append(&reasons, fmt.tprintf("%s: written before the start of the run", path))
			continue
		}
		content, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			append(&reasons, fmt.tprintf("%s: cannot read: %v", path, read_error))
			continue
		}
		data, render_problem := measure_log_rendered(string(content))
		if render_problem != "" {
			append(&reasons, fmt.tprintf("%s: the facts cannot be rendered: %s", path, render_problem))
			continue
		}
		if measure_record_number_from_log(&number, measure, path, data, names) {
			return number
		}
		append(&reasons, fmt.tprintf("%s: no line with \"%s\"", path, measure.pattern))
	}
	number.absent = measure_text_without_private(strings.join(reasons[:], "; ", context.temp_allocator), names)
	return number
}

// measure_boot_lines gives the lines of the stages of the start of a log of
// the main machine, with the texts of the host cut out.
measure_boot_lines :: proc(content: string, names: Measure_Private_Names) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	for line in foundation.lines_of_text(content) {
		if strings.has_prefix(line, BOOT_STAGE_PREFIX) {
			append(&lines, measure_text_without_private(line, names))
		}
	}
	return lines[:]
}

// measure_value gives a text that fits on one line of the record.
measure_value :: proc(text: string) -> string {
	one_line, _ := strings.replace_all(text, "\n", " ", context.temp_allocator)
	one_line, _ = strings.replace_all(one_line, "\r", " ", context.temp_allocator)
	return one_line
}

// measure_record_format writes the record in its form: the first line,
// the facts of the run, one block for each number in the order of the
// table, the lines of the start in the order of the log, and the last
// line. Each line is a key, one space and a value.
measure_record_format :: proc(record: Measure_Record) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n", MEASURE_RECORD_FIRST_LINE)
	fmt.sbprintf(&b, "time %s\n", measure_value(record.time))
	fmt.sbprintf(&b, "release %s\n", measure_value(record.release))
	commit: string = record.commit != "" ? record.commit : "unknown"
	fmt.sbprintf(&b, "commit %s\n", measure_value(commit))
	fmt.sbprintf(&b, "tree %s\n", measure_tree_state_names[record.tree])
	fmt.sbprintf(&b, "host %s\n", measure_value(record.host))
	fmt.sbprintf(&b, "checks %d\n", record.checks_passed)
	for number in record.numbers {
		fmt.sbprintf(&b, "number %s\n", measure_value(number.sentence))
		if number.found {
			fmt.sbprintf(&b, "log %s\n", measure_value(number.log))
			fmt.sbprintf(&b, "line %d\n", number.line_number)
			fmt.sbprintf(&b, "matching %d\n", number.matching_lines)
			fmt.sbprintf(&b, "machine %s\n", measure_value(number.machine))
			fmt.sbprintf(&b, "text %s\n", measure_value(number.line))
		} else {
			fmt.sbprintf(&b, "absent %s\n", measure_value(number.absent))
		}
	}
	for line in record.boot_lines {
		fmt.sbprintf(&b, "boot %s\n", measure_value(line))
	}
	fmt.sbprintf(&b, "%s\n", MEASURE_RECORD_LAST_LINE)
	return strings.to_string(b)
}

// measure_record_parse reads a record in its form. The file is a file of
// the repository that a developer can change: each line is checked.
measure_record_parse :: proc(text: string) -> (record: Measure_Record, problem: string) {
	lines := foundation.lines_of_text(text)
	for len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	if len(lines) == 0 || lines[0] != MEASURE_RECORD_FIRST_LINE {
		return {}, fmt.tprintf("the first line is not \"%s\"", MEASURE_RECORD_FIRST_LINE)
	}
	if len(lines) < 2 || lines[len(lines) - 1] != MEASURE_RECORD_LAST_LINE {
		return {}, fmt.tprintf("the last line is not \"%s\": the file is not whole", MEASURE_RECORD_LAST_LINE)
	}
	numbers := make([dynamic]Measure_Record_Number, context.temp_allocator)
	boot_lines := make([dynamic]string, context.temp_allocator)
	for line, index in lines[1:len(lines) - 1] {
		line_number := index + 2
		key, value := line, ""
		if space := strings.index_byte(line, ' '); space >= 0 {
			key = line[:space]
			value = line[space + 1:]
		}
		current: ^Measure_Record_Number
		if len(numbers) > 0 {
			current = &numbers[len(numbers) - 1]
		}
		switch key {
		case "time":
			record.time = value
		case "release":
			record.release = value
		case "commit":
			record.commit = value == "unknown" ? "" : value
		case "tree":
			known := false
			for name, state in measure_tree_state_names {
				if name == value {
					record.tree = state
					known = true
				}
			}
			if !known {
				return {}, fmt.tprintf("line %d: the tree \"%s\" is not clean, changed or unknown", line_number, value)
			}
		case "host":
			record.host = value
		case "checks":
			checks, checks_ok := strconv.parse_int(value, 10)
			if !checks_ok || checks < 0 {
				return {}, fmt.tprintf("line %d: the count of checks \"%s\" is not a count", line_number, value)
			}
			record.checks_passed = checks
		case "number":
			append(&numbers, Measure_Record_Number{sentence = value})
		case "boot":
			append(&boot_lines, value)
		case "log", "line", "matching", "machine", "text", "absent":
			if current == nil {
				return {}, fmt.tprintf("line %d: \"%s\" before the first line \"number\"", line_number, key)
			}
			switch key {
			case "log":
				current.log = value
				current.found = true
			case "line", "matching":
				count, count_ok := strconv.parse_int(value, 10)
				if !count_ok || count < 1 {
					return {}, fmt.tprintf("line %d: \"%s\" is not a count of at least 1", line_number, value)
				}
				if key == "line" {
					current.line_number = count
				} else {
					current.matching_lines = count
				}
			case "machine":
				current.machine = value
			case "text":
				current.line = value
			case "absent":
				current.absent = value
			}
		case:
			return {}, fmt.tprintf("line %d: the key \"%s\" is not a key of the form", line_number, key)
		}
	}
	if record.time == "" || record.release == "" {
		return {}, "the line \"time\" or the line \"release\" is absent"
	}
	for number in numbers {
		if number.found == (number.absent != "") {
			return {}, fmt.tprintf("the number \"%s\" needs a line \"log\" or a line \"absent\", not both", number.sentence)
		}
		if number.found && (number.line_number == 0 || number.matching_lines == 0 || number.line == "") {
			return {}, fmt.tprintf("the number \"%s\" has a log but no line, count or text", number.sentence)
		}
	}
	record.numbers = numbers[:]
	record.boot_lines = boot_lines[:]
	return record, ""
}

// measure_record_write writes the record of the run that just passed: each
// number of `measure_entries`, the lines of the start, and the facts of the
// run. A number that the table marks as required and that the logs of the
// run do not hold is a fault of the run: the record is not written.
measure_record_write :: proc(facts: Measure_Run_Facts) -> bool {
	names := measure_private_names_read()
	record := Measure_Record {
		time          = measure_time_text(time.now()),
		commit        = facts.commit,
		tree          = facts.tree,
		checks_passed = sync.atomic_load(&foundation.test_passed_count),
	}
	processor_information, _ := foundation.read_text_file_quiet("/proc/cpuinfo")
	record.host = measure_text_without_private(measure_host_text(processor_information, os.exists("/dev/kvm")), names)
	changelog_problems := make([dynamic]string, context.temp_allocator)
	changelog, changelog_ok := changelog_read(&changelog_problems)
	if !changelog_ok || len(changelog_problems) > 0 || len(changelog.releases) == 0 {
		problems_print(changelog_problems[:])
		fmt.eprintfln("modustool: %s is not written: the release of %s cannot be read", MEASURE_RECORD_FILE, CHANGELOG_FILE)
		return false
	}
	record.release = release_number_text(changelog.releases[0].number)

	numbers := make([dynamic]Measure_Record_Number, context.temp_allocator)
	holes := make([dynamic]string, context.temp_allocator)
	for measure in measure_entries {
		number := measure_record_number_read(measure, facts.started, names)
		if !number.found {
			fmt.printfln("modustool: the run did not give the number \"%s\": %s", measure.sentence, number.absent)
			if measure.required {
				append(&holes, measure.sentence)
			}
		}
		append(&numbers, number)
	}
	if len(holes) > 0 {
		for hole in holes {
			fmt.eprintfln("modustool: test failed: the required number \"%s\" is not in the logs of the run", hole)
		}
		fmt.eprintfln("modustool: %s is not written: %d required numbers are absent", MEASURE_RECORD_FILE, len(holes))
		return false
	}
	record.numbers = numbers[:]

	// The lines of the start, from the log of the main machine of this run.
	main_log_information, main_log_error := os.stat(TEST_OUTPUT, context.temp_allocator)
	if main_log_error == nil && time.diff(facts.started, main_log_information.modification_time) >= 0 {
		if main_log, has_main_log := foundation.read_text_file_quiet(TEST_OUTPUT); has_main_log {
			record.boot_lines = measure_boot_lines(main_log, names)
		}
	}
	if len(record.boot_lines) == 0 {
		fmt.printfln("modustool: %s of this run has no line \"%s...\": the record has no stage of the start", TEST_OUTPUT, BOOT_STAGE_PREFIX)
	}

	text := measure_record_format(record)
	// The site reads the record: it must read back as it was written.
	if _, problem := measure_record_parse(text); problem != "" {
		fmt.eprintfln("modustool: %s is not written: it does not read back: %s", MEASURE_RECORD_FILE, problem)
		return false
	}
	foundation.make_folder(MEASURE_RECORD_FOLDER) or_return
	if error := os.write_entire_file(MEASURE_RECORD_FILE, transmute([]u8)text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", MEASURE_RECORD_FILE, error)
		return false
	}
	found := 0
	for number in record.numbers {
		found += number.found ? 1 : 0
	}
	commit_text: string = record.commit != "" ? record.commit[:min(MEASURE_COMMIT_SHORT_LENGTH, len(record.commit))] : "unknown"
	fmt.printfln("modustool: wrote %s: %d of %d numbers, %d stages of the start, %d checks passed, the tree of %s (%s), the release %s", MEASURE_RECORD_FILE, found, len(record.numbers), len(record.boot_lines), record.checks_passed, commit_text, measure_tree_state_names[record.tree], record.release)
	return true
}

TEST_OUTPUT_CRYPTOGRAPHY :: foundation.BUILD_FOLDER + "/test_output_cryptography.txt"

// The log of the machine of the network, whose measures the table of the
// measures reads.
TEST_OUTPUT_NETWORK :: foundation.BUILD_FOLDER + "/test_output_network.txt"

TEST_OUTPUT :: foundation.BUILD_FOLDER + "/test_output.txt"

TEST_OUTPUT_MEASURE :: foundation.BUILD_FOLDER + "/test_output_measure.txt"

// The logs of the measure runs whose lines the measure record holds.
TEST_OUTPUT_MEASURE_CLOCK :: foundation.BUILD_FOLDER + "/test_output_measure_clock.txt"

TEST_OUTPUT_MEASURE_DISK :: foundation.BUILD_FOLDER + "/test_output_measure_disk.txt"

TEST_OUTPUT_MEASURE_SCHEDULER :: foundation.BUILD_FOLDER + "/test_output_scheduler_1.txt"

// measure_process_lines gives the lines of a log that a process wrote: the
// lines that hold "name: ".
measure_process_lines :: proc(log: string, name: string) -> []string {
	mark := strings.concatenate({name, ": "}, context.temp_allocator)
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(log, context.temp_allocator) {
		if strings.contains(line, mark) {
			append(&lines, strings.trim_right(line, "\r"))
		}
	}
	return lines[:]
}

// Which line a number takes when the log has several lines with its text.
Measure_Line_Choice :: enum {
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
Measure_Entry :: struct {
	sentence: string,
	files:    [2]string, // "" for no second log.
	pattern:  string,
	choice:   Measure_Line_Choice,
	accent:   graphics.Color, // The color of the concept that the number measures.
	place:    Site_Measure_Place,
	required: bool,
	// How to read the number: what the process does to measure it, and what
	// the number does not say. Markdown.
	reading: string,
}

// The full frame of the compositor on the main machine. Its line names the
// size of the screen, and the sentence names it too: a measure at another
// size is another measure, with a series of its own
// (src/md/features/desktop_to_browser.md, "The reference screen").
COMPOSITOR_FULL_FRAME_SENTENCE :: "A full frame of the compositor at 1920 x 1080, with the windows of the main test"
COMPOSITOR_FULL_FRAME :: "compositor: a full frame of 1920x1080 "
#assert(reference_screen.WIDTH == 1920 && reference_screen.HEIGHT == 1080, "the sentence and the line of the full frame name 1920 x 1080")

measure_entries := [?]Measure_Entry {
	{sentence = "Kernel entries in one second, with 1, 2 and 4 processes that each take the locks of their own objects", files = {TEST_OUTPUT_MEASURE, ""}, pattern = "locks: kernel entries in one second", choice = .First, accent = graphics.DARK_KERNEL, place = .Numbers, required = true, reading = "Each locker is a process that enters the kernel again and again and takes only the locks of its own objects, so no two lockers wait for one lock. A count that grows with the lockers shows that the kernel serves several processors at once. It does not say what happens when processes share one object."},
	{sentence = "Reads of the time in one second from the time page, with no kernel entry", files = {TEST_OUTPUT_MEASURE_CLOCK, ""}, pattern = "clock: the time page:", choice = .First, accent = graphics.DARK_KERNEL, place = .Numbers, required = true, reading = "A process reads the time from a page that the kernel keeps up to date. The part that matters is the second one: **0 kernel entries for one million reads**, so the time costs a read of memory. The count of reads follows the speed of the host processor."},
	{sentence = "Wakes in one second of two threads that wake each other on a busy machine, under the strategy EEVDF", files = {TEST_OUTPUT_MEASURE_SCHEDULER, ""}, pattern = "scheduler: EEVDF: two threads that wake each other", choice = .First, accent = graphics.DARK_KERNEL, place = .Numbers, required = true, reading = "Two threads wake each other while a spinner keeps each processor busy: the count is their wakes in one second. The same line gives how late a thread that sleeps 2 ms wakes among spinners; the next line gives the share of the processor of each spinner of one weight. It shows the scheduler under load; it compares no other strategy."},
	{sentence = "One glyph of the vector font, from its outline and from the glyph cache", files = {TEST_OUTPUT, ""}, pattern = "vector_glyphs: one glyph from its outline", choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "The time to draw one glyph of the vector font from its outline at three scales, the time to copy it from the private glyph cache of the process, and the time of one glyph of the bitmap font. A process draws each glyph from its outline once, then copies it at each frame."},
	{sentence = COMPOSITOR_FULL_FRAME_SENTENCE, files = {TEST_OUTPUT, ""}, pattern = COMPOSITOR_FULL_FRAME, choice = .Last, accent = graphics.DARK_PROCESS, place = .Numbers, required = false, reading = "The time to draw the whole reference screen with its windows, on the processor: the system has no graphics device. The compositor prints it only when a frame redraws the whole screen, so the number is not required. Most frames redraw their damage rectangles only, and cost less. The sentence names the size of the screen: a frame of another size is another measure, with a series of its own."},
	{sentence = "A clear and a present of a frame of 1920 x 1080 on the processor", files = {TEST_OUTPUT_MEASURE, ""}, pattern = PROCESSOR_FRAME_CLEAR_AND_PRESENT, choice = .First, accent = graphics.DARK_MEMORY, place = .Numbers, required = true, reading = "The process `processor_frame` fills a canvas of 1920 x 1080 with one color, then copies it into a second canvas, as the compositor copies its frame into a screen page: 8.3 MB written, then 8.3 MB read and written. It is the bound of the memory bandwidth for a frame of the reference screen with no GPU. The least and the median of 21 frames; the frames in one second come from the median."},
	{sentence = "A full frame of the compositor at 1920 x 1080 with 4 windows, on the processor", files = {TEST_OUTPUT_MEASURE, ""}, pattern = PROCESSOR_FRAME_FULL_FRAME, choice = .First, accent = graphics.DARK_PROCESS, place = .Numbers, required = true, reading = "The phases of a frame of the compositor at the reference screen, in memory: the background, one call of the drawing module for each of 4 windows and one for the bar, then the copy into a screen page. `processor_frame` draws the frame in canvases of its own, with the records of each window in the form of the compositor, so the parts stay apart. The pointer and the page flip are not in it; the full frame of the compositor itself, on the main machine, holds them."},
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
	{sentence = LOG_RECORDS_OF_THE_START_SENTENCE, files = {build.LOG_MEASURES_RECORD, ""}, pattern = "measure: the records of the log of", choice = .First, accent = graphics.DARK_KERNEL, place = .Build, required = true, reading = "Not a time: a count. The log records that the main machine wrote up to the line \"kernel: ok\" and up to the line of the root service that the machine is usable, as the tool counts them on the serial log: one record for each fact, and one for each 168 bytes of a text. Each second of a budget holds a count of records, so a line that takes more records takes more of it. `modustool measure-compare` reads the count of two records."},
	{sentence = LOG_MODULE_FILES_SENTENCE, files = {build.LOG_MEASURES_RECORD, ""}, pattern = "measure: the module files:", choice = .First, accent = graphics.DARK_PROCESS, place = .Build, required = true, reading = "Not a time: a size. The bytes of the module files of the root service and of the compositor, and the bytes of their segments of code. A log fact writes no text at its call, so a module that writes facts holds less code that formats; its fact templates are in the file. `modustool measure-compare` reads the sizes of two records."},
}

// The sentences of the measures of the log of the main machine, which the
// table and its series both name.
LOG_RECORDS_OF_THE_START_SENTENCE :: "The log records of the main machine up to the end of its start"
LOG_MODULE_FILES_SENTENCE :: "The module files of the root service and of the compositor"

// What each log is: the machine that wrote it and what else ran.
Measure_Output_File :: struct {
	path:       string,
	conditions: string,
}

measure_output_files := [?]Measure_Output_File {
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
	{build.LOG_MEASURES_RECORD, "Written by `modustool test`, after the main machine, from its serial log and the module files of the build"},
}

// log_line_choose finds the lines of a log that contain the pattern, and
// gives the first or the last one whole, with its label.
log_line_choose :: proc(content, pattern: string, choice: Measure_Line_Choice) -> (line: string, line_number, matching_lines: int) {
	for candidate, index in foundation.lines_of_text(content) {
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

measure_output_conditions :: proc(path: string) -> string {
	for output in measure_output_files {
		if output.path == path {
			return output.conditions
		}
	}
	return ""
}

BOOT_STAGE_PREFIX :: "kernel: boot: "

TEST_OUTPUT_TCP_REAL :: foundation.BUILD_FOLDER + "/test_output_tcp_real.txt"

// measure_record_example gives a record with each kind of field: a number
// that a log holds, a number that is absent with its reason, and the lines
// of the start. The tests of the record and of its page on the site read it.
measure_record_example :: proc() -> Measure_Record {
	numbers := make([]Measure_Record_Number, 2, context.temp_allocator)
	numbers[0] = {sentence = "Reads of the time", found = true, log = "build/test_output.txt", line_number = 812, matching_lines = 2, machine = "The main machine of `modustool test`", line = "[clock] clock: the time page: 1000 reads"}
	numbers[1] = {sentence = "A full frame of the compositor", absent = "build/test_output.txt: no line with \"compositor: a full frame of\""}
	boot_lines := make([]string, 2, context.temp_allocator)
	boot_lines[0] = "kernel: boot: firmware: 1031293 us"
	boot_lines[1] = "kernel: boot: kernel: root service: 2096 us"
	return Measure_Record {
		time = "2026-11-12 02:09 UTC",
		release = "0.91.0",
		commit = "264fa303aaaabbbbccccddddeeeeffff00001111",
		tree = .Changed,
		host = "AMD Ryzen 7 5800X 8-Core Processor, 16 logical processors; QEMU with KVM",
		checks_passed = 1234,
		numbers = numbers,
		boot_lines = boot_lines,
	}
}
