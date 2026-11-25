package checks

import "core:fmt"
import "core:strconv"
import "core:strings"

// The sub-modes of `modustool check` (src/md/infrastructure/full_check.md,
// "The derivations of the check").
Check_Mode :: enum u8 {
	All,
	Without_Machines,
	Static,
	Host_Tests,
	Fuzz,
	Reproducible,
}

// Which folders of HOST_TEST_FOLDERS `modustool check host_tests` runs.
Host_Tests_Scope :: enum u8 {
	All,
	System,
	Tool,
}

// Parsed arguments of `modustool check`.
Check_Arguments :: struct {
	mode:             Check_Mode,
	host_tests_scope: Host_Tests_Scope,
	fuzz_shard:       int,
	fuzz_total:       int,
}

CHECK_USAGE_TEXT :: "check [without_machines | static | host_tests [system | tool] | fuzz <shard> <total> | reproducible]"

// parse_positive_decimal reads a positive base-10 integer containing only
// ASCII digits (no sign, space, or underscore) and returns >= 1.
@(private = "file")
parse_positive_decimal :: proc(text: string) -> (value: int, ok: bool) {
	if len(text) == 0 || strings.contains_any(text, " \t\n\r+-_") {
		return 0, false
	}
	for b in transmute([]u8)text {
		if b < '0' || b > '9' {
			return 0, false
		}
	}
	parsed, parsed_ok := strconv.parse_int(text, 10)
	if !parsed_ok || parsed < 1 {
		return 0, false
	}
	return parsed, true
}

// check_arguments_parse validates the arguments of `modustool check`.
// Refuses unknown modes, extra arguments, and out-of-range shard bounds.
check_arguments_parse :: proc(args: []string) -> (parsed: Check_Arguments, problem: string) {
	if len(args) == 0 {
		return {mode = .All}, ""
	}
	switch args[0] {
	case "without_machines":
		if len(args) != 1 {
			return {}, CHECK_USAGE_TEXT
		}
		return {mode = .Without_Machines}, ""
	case "static":
		if len(args) != 1 {
			return {}, CHECK_USAGE_TEXT
		}
		return {mode = .Static}, ""
	case "reproducible":
		if len(args) != 1 {
			return {}, CHECK_USAGE_TEXT
		}
		return {mode = .Reproducible}, ""
	case "host_tests":
		if len(args) == 1 {
			return {mode = .Host_Tests, host_tests_scope = .All}, ""
		}
		if len(args) == 2 {
			switch args[1] {
			case "system":
				return {mode = .Host_Tests, host_tests_scope = .System}, ""
			case "tool":
				return {mode = .Host_Tests, host_tests_scope = .Tool}, ""
			}
		}
		return {}, CHECK_USAGE_TEXT
	case "fuzz":
		if len(args) != 3 {
			return {}, CHECK_USAGE_TEXT
		}
		shard, shard_ok := parse_positive_decimal(args[1])
		total, total_ok := parse_positive_decimal(args[2])
		if !shard_ok || !total_ok {
			return {}, fmt.tprintf("check fuzz <shard> <total>: shard and total must be positive integers (%s)", CHECK_USAGE_TEXT)
		}
		if shard > total {
			return {}, fmt.tprintf("check fuzz %d %d: shard must be in 1..%d", shard, total, total)
		}
		return {mode = .Fuzz, fuzz_shard = shard, fuzz_total = total}, ""
	}
	return {}, CHECK_USAGE_TEXT
}
