package checks

import "core:fmt"
import "core:os"
import "core:strings"
import "modustool:foundation"

// A time in a machine test has one role: to end a test that hangs. Each
// step has HANG_BOUND, and a step with a bound of its own names it with a
// constant whose comment gives the reason (docs/TOOLS.md, "The bounds of the
// tests"): no step carries a number tuned to the speed of some host.
TEST_BOUND_FOLDER :: "tools/modustool"
TEST_BOUND_FIELD :: "seconds = "

test_bound_check :: proc() -> bool {
	files := make([dynamic]string, context.temp_allocator)
	foundation.source_files_of_a_folder(TEST_BOUND_FOLDER, &files) or_return
	texts := make([]string, len(files), context.temp_allocator)
	for path, index in files {
		bytes, read_error := os.read_entire_file(path, context.temp_allocator)
		if read_error != nil {
			fmt.eprintfln("modustool: test failed: cannot read %s: %v", path, read_error)
			return false
		}
		texts[index] = string(bytes)
	}
	found, bounds := 0, 0
	for text, index in texts {
		rest := text
		line_number := 0
		for line in strings.split_lines_iterator(&rest) {
			line_number += 1
			// A literal of a Step names its kind.
			if !strings.contains(line, "kind = .") {
				continue
			}
			for at := 0; at < len(line); {
				offset := strings.index(line[at:], TEST_BOUND_FIELD)
				if offset < 0 {
					break
				}
				start := at + offset
				at = start + len(TEST_BOUND_FIELD)
				// The field, not a longer name that ends with it (milliseconds).
				if start > 0 && byte_of_a_name(line[start - 1]) {
					continue
				}
				end := at
				for end < len(line) && byte_of_a_name(line[end]) {
					end += 1
				}
				value := line[at:end]
				bounds += 1
				switch {
				case value == "" || value[0] >= '0' && value[0] <= '9':
					fmt.eprintfln("modustool: test failed: %s:%d: the bound of a step is the number %s: name it with a constant whose comment gives its reason", files[index], line_number, value)
					found += 1
				case !test_bound_constant_has_reason(texts, value):
					fmt.eprintfln("modustool: test failed: %s:%d: the bound %s of a step is not a constant of %s with a comment on the line above it", files[index], line_number, value, TEST_BOUND_FOLDER)
					found += 1
				}
			}
		}
	}
	sleeps := 0
	for text, index in texts {
		rest := text
		line_number := 0
		for line in strings.split_lines_iterator(&rest) {
			line_number += 1
			period, has_sleep := sleep_period_of_a_line(line)
			if !has_sleep {
				continue
			}
			sleeps += 1
			if sleep_period_has_a_number(period) {
				fmt.eprintfln("modustool: test failed: %s:%d: a time.sleep of the tool has the number %s: a poll uses CONDITION_POLL_PERIOD, and any other period is a constant whose comment gives its reason", files[index], line_number, period)
				found += 1
			}
		}
	}
	if found > 0 {
		return false
	}
	foundation.test_passed_print("each of the %d steps with a bound of its own names a constant with its reason, and each of the %d time.sleep of the tool names its period (%d files read)", bounds, sleeps, len(files))
	return true
}

// sleep_period_has_a_number says if the argument of a time.sleep is no
// named period: empty, or with a digit anywhere outside a name, as in
// `20 * time.Millisecond`, `time.Millisecond * 20`,
// `time.Duration(20) * time.Millisecond` or `CONDITION_POLL_PERIOD * 20`.
// A digit inside a name (`TPM2_PERIOD`) is a part of the name.
sleep_period_has_a_number :: proc(period: string) -> bool {
	if strings.trim_space(strings.trim_suffix(strings.trim_space(period), ")")) == "" {
		return true
	}
	for index in 0 ..< len(period) {
		character := period[index]
		if character < '0' || character > '9' {
			continue
		}
		// The start of the name that holds the digit, if one does.
		start := index
		for start > 0 && byte_of_a_name(period[start - 1]) {
			start -= 1
		}
		first := period[start]
		if first >= '0' && first <= '9' {
			return true
		}
	}
	return false
}

// sleep_period_of_a_line gives the argument of a call of time.sleep in a
// line of source, before any comment: a wait of a fixed time with a number
// in place of a named period is a time tuned to the speed of some host.
sleep_period_of_a_line :: proc(line: string) -> (period: string, has_sleep: bool) {
	SLEEP_CALL :: "time.sleep("
	code := line
	if comment := strings.index(code, "//"); comment >= 0 {
		code = code[:comment]
	}
	at := strings.index(code, SLEEP_CALL)
	if at < 0 {
		return "", false
	}
	// The call, not a longer name that ends with it.
	if at > 0 && byte_of_a_name(code[at - 1]) {
		return "", false
	}
	return strings.trim_space(code[at + len(SLEEP_CALL):]), true
}

// test_bound_constant_has_reason says if a file declares the constant name
// at the start of a line, with a line of comment just above it.
@(private = "file")
test_bound_constant_has_reason :: proc(texts: []string, name: string) -> bool {
	declaration := strings.concatenate({name, " ::"}, context.temp_allocator)
	for text in texts {
		previous := ""
		rest := text
		for line in strings.split_lines_iterator(&rest) {
			if strings.has_prefix(line, declaration) {
				return strings.has_prefix(strings.trim_space(previous), "//")
			}
			previous = line
		}
	}
	return false
}

// byte_of_a_name says if a byte can be a part of a name of Odin.
@(private = "file")
byte_of_a_name :: proc(byte: u8) -> bool {
	return byte == '_' || byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' || byte >= '0' && byte <= '9'
}
