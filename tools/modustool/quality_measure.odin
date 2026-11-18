// The lines of the three measures of the standard of quality and of the
// quality profile, which the compositor writes
// (src/md/features/desktop_to_browser.md, "The three measures on the path of the system").
// The scenario of the measure run waits for each line; after the machine,
// the tool checks their form. A time is a measure, never a condition: the
// check reads no bound of a time.
package modustool

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// The lines, as the compositor writes them
// (src/modules/system/compositor/quality_measures.odin). The tool checks
// the form of the last line of each kind.
QUALITY_PROFILE_LINE :: "compositor: the quality profile is the processor profile: the system drives no GPU device"
QUALITY_FRAME :: "compositor: measure: the time of a frame, from the first record that the compositor reads to the flip"
QUALITY_KEY :: "compositor: measure: the time of a key to the screen, from its record in the input service to the flip that shows it"
QUALITY_WINDOW_START :: "compositor: measure: the start of the window "
QUALITY_WINDOW_START_TAIL :: ", from Process_Start to its first frame: "
// The window whose start the measure record keeps: locks draws its first
// frame before its measures, in the measure run.
QUALITY_WINDOW_START_LOCKS :: QUALITY_WINDOW_START + "locks" + QUALITY_WINDOW_START_TAIL
QUALITY_LEAST :: ": least "
QUALITY_MEDIAN :: " us, median "
QUALITY_OVER :: " us, over "
QUALITY_MICROSECONDS :: " us"

// quality_time_tenths reads a time as the compositor writes it: digits, a
// point and one digit. It gives tenths of a microsecond.
@(private = "file")
quality_time_tenths :: proc(text: string) -> (tenths: u64, ok: bool) {
	point := strings.index_byte(text, '.')
	if point < 1 || point != len(text) - 2 {
		return 0, false
	}
	whole := quality_count(text[:point]) or_return
	tenth := quality_count(text[point + 1:]) or_return
	return whole * 10 + tenth, true
}

// quality_count reads a count: digits only, no sign.
@(private = "file")
quality_count :: proc(text: string) -> (count: u64, ok: bool) {
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

// quality_spread_problem gives why the times of a line of the frames or of
// the keys are not in their form, or "": "least <t> us, median <t> us,
// over <n> <unit>", the least not above the median, a count that is not 0.
quality_spread_problem :: proc(line, unit: string) -> string {
	least_at := strings.index(line, QUALITY_LEAST)
	if least_at < 0 {
		return fmt.tprintf("it has no \"%s\"", QUALITY_LEAST)
	}
	rest := line[least_at + len(QUALITY_LEAST):]
	median_at := strings.index(rest, QUALITY_MEDIAN)
	if median_at < 0 {
		return fmt.tprintf("it has no \"%s\"", QUALITY_MEDIAN)
	}
	least_text := rest[:median_at]
	rest = rest[median_at + len(QUALITY_MEDIAN):]
	over_at := strings.index(rest, QUALITY_OVER)
	ending := strings.concatenate({" ", unit}, context.temp_allocator)
	if over_at < 0 || !strings.has_suffix(rest, ending) {
		return fmt.tprintf("its times are not in the words \"least <t> us, median <t> us, over <n> %s\"", unit)
	}
	median_text := rest[:over_at]
	count_start := over_at + len(QUALITY_OVER)
	if count_start > len(rest) - len(ending) {
		return "it has no count"
	}
	count_text := rest[count_start:len(rest) - len(ending)]
	least, least_ok := quality_time_tenths(least_text)
	median, median_ok := quality_time_tenths(median_text)
	count, count_ok := quality_count(count_text)
	switch {
	case !least_ok:
		return fmt.tprintf("the least \"%s\" is not a time with one decimal", least_text)
	case !median_ok:
		return fmt.tprintf("the median \"%s\" is not a time with one decimal", median_text)
	case !count_ok:
		return fmt.tprintf("the count \"%s\" is not a count", count_text)
	case count == 0:
		return fmt.tprintf("the line measures 0 %s", unit)
	case least > median:
		return fmt.tprintf("the least %d.%d us is above the median %d.%d us", least / 10, least % 10, median / 10, median % 10)
	}
	return ""
}

// quality_start_problem gives why a line of the start of a window is not in
// its form, or "": a name with no space, then the time with one decimal.
quality_start_problem :: proc(line: string) -> string {
	start_at := strings.index(line, QUALITY_WINDOW_START)
	if start_at < 0 {
		return fmt.tprintf("it has no \"%s\"", QUALITY_WINDOW_START)
	}
	rest := line[start_at + len(QUALITY_WINDOW_START):]
	tail_at := strings.index(rest, QUALITY_WINDOW_START_TAIL)
	if tail_at < 0 {
		return fmt.tprintf("it has no \"%s\"", QUALITY_WINDOW_START_TAIL)
	}
	name := rest[:tail_at]
	if len(name) == 0 || strings.contains_rune(name, ' ') {
		return fmt.tprintf("the window \"%s\" is not a name", name)
	}
	time_text := rest[tail_at + len(QUALITY_WINDOW_START_TAIL):]
	if !strings.has_suffix(time_text, QUALITY_MICROSECONDS) {
		return fmt.tprintf("the time \"%s\" does not end with \"%s\"", time_text, QUALITY_MICROSECONDS)
	}
	time_text = time_text[:len(time_text) - len(QUALITY_MICROSECONDS)]
	if _, ok := quality_time_tenths(time_text); !ok {
		return fmt.tprintf("the time \"%s\" is not a time with one decimal", time_text)
	}
	return ""
}

// quality_lines_problems gives the problems of the lines of the quality
// measures in a log: the line of the profile, at least one line of the
// frames, of the keys and of the start of locks, and each such line in its
// form.
quality_lines_problems :: proc(log: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	profile, frames, keys, locks := 0, 0, 0, 0
	for raw in strings.split_lines(log, context.temp_allocator) {
		line := strings.trim_right(raw, "\r")
		problem := ""
		switch {
		case strings.contains(line, QUALITY_PROFILE_LINE):
			profile += 1
		case strings.contains(line, QUALITY_FRAME):
			frames += 1
			problem = quality_spread_problem(line, "frames")
		case strings.contains(line, QUALITY_KEY):
			keys += 1
			problem = quality_spread_problem(line, "keys")
		case strings.contains(line, QUALITY_WINDOW_START):
			if strings.contains(line, QUALITY_WINDOW_START_LOCKS) {
				locks += 1
			}
			problem = quality_start_problem(line)
		}
		if problem != "" {
			append(&problems, fmt.tprintf("the line \"%s\": %s", line, problem))
		}
	}
	if profile != 1 {
		append(&problems, fmt.tprintf("the log has %d lines \"%s\", not 1: the compositor chooses its profile once", profile, QUALITY_PROFILE_LINE))
	}
	if frames == 0 {
		append(&problems, fmt.tprintf("the log has no line \"%s...\"", QUALITY_FRAME))
	}
	if keys == 0 {
		append(&problems, fmt.tprintf("the log has no line \"%s...\"", QUALITY_KEY))
	}
	if locks == 0 {
		append(&problems, fmt.tprintf("the log has no line \"%s...\"", QUALITY_WINDOW_START_LOCKS))
	}
	return problems[:]
}

// quality_lines_check reads the log of a measure run and checks the lines
// of the quality measures. It prints the lines when they pass.
quality_lines_check :: proc(path: string) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read %s: %v", path, read_error)
		return false
	}
	log := string(data)
	problems := quality_lines_problems(log)
	for problem in problems {
		fmt.eprintfln("modustool: test failed: %s: %s", path, problem)
	}
	if len(problems) > 0 {
		return false
	}
	test_passed_print("the lines of the quality profile and of the three measures of the standard of quality in %s are in their form", path)
	for line in strings.split_lines(log, context.temp_allocator) {
		if strings.contains(line, QUALITY_PROFILE_LINE) || strings.contains(line, QUALITY_WINDOW_START_LOCKS) {
			fmt.println(strings.trim_right(line, "\r"))
		}
	}
	return true
}
