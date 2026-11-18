// The lines that processor_frame writes as it measures a frame at
// 1920 x 1080 on the processor in three parts
// (src/md/features/desktop_to_browser.md, "The first measure: a frame at 1920 × 1080 on the processor").
// The scenario of the measure run waits for each line; after the machine,
// the tool checks their form. A time is a measure, never a condition: the
// check reads no bound of a time.
package modustool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "modustool:foundation"

// The start of each line, in the order of the log. The process writes them
// (src/modules/demonstrations/processor_frame/main.odin, measure_log).
PROCESSOR_FRAME_CLEAR_AND_PRESENT :: "processor_frame: measure: a clear and a present of 1920x1080"
PROCESSOR_FRAME_FULL_FRAME :: "processor_frame: measure: a full frame of the compositor at 1920x1080 with 4 windows"
PROCESSOR_FRAME_FRAME_IN_ITS_DAMAGE :: "processor_frame: measure: a frame of the compositor at 1920x1080 with 4 windows in its damage"
PROCESSOR_FRAME_DRAW_TABLE :: "processor_frame: measure: the execution of a draw table of 1920x1080 with "
// The last line: each part drew its pixels.
PROCESSOR_FRAME_DONE :: "processor_frame: ok, each part drew its pixels"
PROCESSOR_FRAME_WRONG :: "processor_frame: wrong: "

@(rodata)
processor_frame_parts := [?]string {
	PROCESSOR_FRAME_CLEAR_AND_PRESENT,
	PROCESSOR_FRAME_FULL_FRAME,
	PROCESSOR_FRAME_FRAME_IN_ITS_DAMAGE,
	PROCESSOR_FRAME_DRAW_TABLE,
}

// The words of the times of a line, after the name of its part.
PROCESSOR_FRAME_LEAST :: ": least "
PROCESSOR_FRAME_MEDIAN :: " us, median "
PROCESSOR_FRAME_FRAMES :: " us, "
PROCESSOR_FRAME_ROUNDS :: " frames in one second at the median, over "
PROCESSOR_FRAME_END :: " frames"

// processor_frame_text_before gives the text before a separator and the
// text after it.
@(private = "file")
processor_frame_text_before :: proc(text, separator: string) -> (before, after: string, found: bool) {
	at := strings.index(text, separator)
	if at < 0 {
		return "", text, false
	}
	return text[:at], text[at + len(separator):], true
}

// processor_frame_decimal reads a time as the process writes it: digits, a
// point and one digit. It gives tenths of a microsecond.
@(private = "file")
processor_frame_decimal :: proc(text: string) -> (tenths: u64, ok: bool) {
	point := strings.index_byte(text, '.')
	if point < 1 || point != len(text) - 2 {
		return 0, false
	}
	whole := processor_frame_count(text[:point]) or_return
	tenth := processor_frame_count(text[point + 1:]) or_return
	return whole * 10 + tenth, true
}

// processor_frame_count reads a count: digits only, no sign.
@(private = "file")
processor_frame_count :: proc(text: string) -> (count: u64, ok: bool) {
	if len(text) == 0 {
		return 0, false
	}
	for character in text {
		if character < '0' || character > '9' {
			return 0, false
		}
	}
	value, parsed := strconv.parse_int(text, 10)
	if !parsed || value < 0 {
		return 0, false
	}
	return u64(value), true
}

// processor_frame_line_problem gives why the times of one line are not in
// the form of the process, or "": the least and the median in tenths of a
// microsecond, the least not above the median, a median that is not 0, the
// frames in one second that the median gives, and a count of frames that
// is not 0.
processor_frame_line_problem :: proc(line: string) -> string {
	_, times, has_least := processor_frame_text_before(line, PROCESSOR_FRAME_LEAST)
	if !has_least {
		return fmt.tprintf("it has no \"%s\"", PROCESSOR_FRAME_LEAST)
	}
	least_text, after_least, has_median := processor_frame_text_before(times, PROCESSOR_FRAME_MEDIAN)
	median_text, after_median, has_frames := processor_frame_text_before(after_least, PROCESSOR_FRAME_FRAMES)
	frames_text, after_frames, has_rounds := processor_frame_text_before(after_median, PROCESSOR_FRAME_ROUNDS)
	if !has_median || !has_frames || !has_rounds || !strings.has_suffix(after_frames, PROCESSOR_FRAME_END) {
		return "its times are not in the words \"least <t> us, median <t> us, <n> frames in one second at the median, over <n> frames\""
	}
	rounds_text := after_frames[:len(after_frames) - len(PROCESSOR_FRAME_END)]
	least, least_ok := processor_frame_decimal(least_text)
	median, median_ok := processor_frame_decimal(median_text)
	frames, frames_ok := processor_frame_count(frames_text)
	rounds, rounds_ok := processor_frame_count(rounds_text)
	switch {
	case !least_ok:
		return fmt.tprintf("the least \"%s\" is not a time with one decimal", least_text)
	case !median_ok:
		return fmt.tprintf("the median \"%s\" is not a time with one decimal", median_text)
	case !frames_ok:
		return fmt.tprintf("the frames in one second \"%s\" are not a count", frames_text)
	case !rounds_ok:
		return fmt.tprintf("the count of frames \"%s\" is not a count", rounds_text)
	case rounds == 0:
		return "the part ran 0 frames"
	case median == 0:
		return "the median is 0.0 us: the part drew nothing that the clock sees"
	case least > median:
		return fmt.tprintf("the least %d.%d us is above the median %d.%d us", least / 10, least % 10, median / 10, median % 10)
	}
	// The process computes the frames from the median in nanoseconds, and
	// writes the median cut to a tenth of a microsecond: the frames lie
	// between the counts of the median written and of one tenth more.
	most := 10_000_000 / median
	fewest := 10_000_000 / (median + 1)
	if frames > most || frames + 1 < fewest {
		return fmt.tprintf("%d frames in one second do not follow from the median %d.%d us: between %d and %d", frames, median / 10, median % 10, fewest, most)
	}
	return ""
}

// processor_frame_lines_problems gives the problems of the lines of
// processor_frame in a log: each part has exactly one line, in the form of
// the process, and the last line of the process is there.
processor_frame_lines_problems :: proc(log: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	lines := strings.split_lines(log, context.temp_allocator)
	for part in processor_frame_parts {
		found := 0
		for line in lines {
			if !strings.contains(line, part) {
				continue
			}
			found += 1
			if problem := processor_frame_line_problem(strings.trim_right(line, "\r")); problem != "" {
				append(&problems, fmt.tprintf("the line \"%s...\": %s", part, problem))
			}
		}
		if found != 1 {
			append(&problems, fmt.tprintf("the log has %d lines \"%s...\", not 1: each part runs once", found, part))
		}
	}
	done := false
	for line in lines {
		done ||= strings.contains(line, PROCESSOR_FRAME_DONE)
	}
	if !done {
		append(&problems, fmt.tprintf("the log has no line \"%s\"", PROCESSOR_FRAME_DONE))
	}
	return problems[:]
}

// processor_frame_lines_check reads the log of a measure run and checks
// the lines of processor_frame. It prints the lines when they pass.
processor_frame_lines_check :: proc(path: string) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", path, read_error)
		return false
	}
	log := string(data)
	problems := processor_frame_lines_problems(log)
	for problem in problems {
		fmt.eprintfln("modustool: test failed: %s: %s", path, problem)
	}
	if len(problems) > 0 {
		return false
	}
	foundation.test_passed_print("the %d measure lines of processor_frame in %s are in their form, and each part drew its pixels", len(processor_frame_parts), path)
	for line in measure_process_lines(log, "processor_frame") {
		if strings.contains(line, "processor_frame: measure: ") {
			fmt.println(line)
		}
	}
	return true
}
