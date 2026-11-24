package machine

import "core:os"
import "core:strings"
import "core:testing"
import "modustool:build"

// The whole test and each part are accepted.
@(test)
test_accepts_each_known_part :: proc(t: ^testing.T) {
	testing.expect_value(t, test_arguments_problem(nil), "")
	for part in test_parts {
		testing.expectf(t, test_arguments_problem([]string{part.name}) == "", "the part %s is accepted", part.name)
	}
}

// A word that is not a part is refused, and the refusal lists the parts:
// the whole test in its place would pass and say nothing of the mistake.
// The machines of the TPM run in their part: a second word is refused. A
// name with a letter more or less, or in capitals, is no part.
@(test)
test_refuses_an_unknown_part :: proc(t: ^testing.T) {
	refused := [][]string{{"netwrok"}, {""}, {"main", "network"}, {"trusted_boot", "tpm"}, {"principals", "tpm"}, {"tcp", "tpm"}, {"Main"}, {"mai"}, {"mainn"}, {"main "}}
	for arguments in refused {
		problem := test_arguments_problem(arguments)
		testing.expectf(t, problem != "", "%v is refused", arguments)
		for part in test_parts {
			testing.expectf(t, strings.contains(problem, part.name), "the refusal of %v names the part %s", arguments, part.name)
		}
	}
	testing.expect(t, strings.has_prefix(test_arguments_problem([]string{"netwrok"}), "test does not know the part `netwrok`; the parts: main, tcp, "))
	_, found := test_part_find("netwrok")
	testing.expect(t, !found, "a name that is no part finds no row")
}

// `test --fast <part>` is accepted for each known part (with or without a
// step range); bare `test --fast`, duplicate `--fast`, `--fast` after the part
// name, `--fast` with `from`, and unknown parts after `--fast` are refused.
@(test)
test_accepts_and_refuses_fast_flag :: proc(t: ^testing.T) {
	mode, rest := test_arguments_optimization(nil)
	testing.expect_value(t, mode, build.Optimization_Mode.Speed)
	testing.expect_value(t, len(rest), 0)

	mode, rest = test_arguments_optimization([]string{"main"})
	testing.expect_value(t, mode, build.Optimization_Mode.Speed)
	testing.expect_value(t, len(rest), 1)
	testing.expect_value(t, rest[0], "main")

	mode, rest = test_arguments_optimization([]string{TEST_FAST_FLAG, "main"})
	testing.expect_value(t, mode, build.Optimization_Mode.None)
	testing.expect_value(t, len(rest), 1)
	testing.expect_value(t, rest[0], "main")

	for part in test_parts {
		testing.expectf(t, test_arguments_problem([]string{TEST_FAST_FLAG, part.name}) == "", "`test --fast %s` is accepted", part.name)
	}
	testing.expect_value(t, test_arguments_problem([]string{TEST_FAST_FLAG, "main", "steps", "1", "to", "2"}), "")
	range, has_range := test_arguments_give_step_range([]string{TEST_FAST_FLAG, "main", "steps", "3", "to", "4"}, context.temp_allocator)
	testing.expect(t, has_range, "`test --fast <part> steps` parses the step range")
	testing.expect_value(t, range.span.first, 3)
	testing.expect_value(t, range.span.last, 4)
	_, has_inputs := test_arguments_give_inputs([]string{TEST_FAST_FLAG, "main", "from", "folder"})
	testing.expect(t, !has_inputs, "`test --fast <part> from` gives no input folder")

	refused := [][]string {
		{TEST_FAST_FLAG},
		{TEST_FAST_FLAG, TEST_FAST_FLAG, "main"},
		{TEST_FAST_FLAG, ""},
		{TEST_FAST_FLAG, "netwrok"},
		{TEST_FAST_FLAG, "Main"},
		{"main", TEST_FAST_FLAG},
		{TEST_FAST_FLAG, "main", "network"},
		{TEST_FAST_FLAG, "main", "from", "folder"},
		{"--slow", "main"},
	}
	for arguments in refused {
		problem := test_arguments_problem(arguments)
		testing.expectf(t, problem != "", "%v is refused", arguments)
	}
}

// No part is in the table two times, each part has its sentence and its
// procedure, and its name is a word that a command line and a file name
// take as it is.
@(test)
test_parts_are_distinct_and_whole :: proc(t: ^testing.T) {
	for part, index in test_parts {
		for other in test_parts[index + 1:] {
			testing.expectf(t, part.name != other.name, "the part %s is in the table one time", part.name)
		}
		testing.expectf(t, part.does != "", "the part %s says what it checks", part.name)
		testing.expectf(t, part.run != nil, "the part %s has its procedure", part.name)
		testing.expectf(t, len(part.procedures) > 0, "the part %s names its procedures", part.name)
		for character in transmute([]u8)part.name {
			testing.expectf(t, (character >= 'a' && character <= 'z') || character == '_' || character == '-', "the name of the part %s has the character %c", part.name, character)
		}
		// The cell of the guide is one line of a table.
		testing.expectf(t, !strings.contains(part.does, "|") && !strings.contains(part.does, "\n"), "the sentence of the part %s holds no | and no new line", part.name)
	}
}

// The count of the parts that run at once by processors: one for each
// MACHINE_PROCESSOR_COUNT processors, at least one, and never more than
// the parts. The memory is ample here, so it bounds nothing.
@(test)
test_parts_at_once_follows_the_processors :: proc(t: ^testing.T) {
	ample := max(u64)
	part := u64(MACHINE_MEMORY_MIB)
	testing.expect_value(t, test_parts_at_once(0, 64, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(1, 64, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, 0, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, 1, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, -1, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, min(int), ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT - 1, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT * 2 - 1, ample, part), 1)
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT * 2, ample, part), 2)
	testing.expect_value(t, test_parts_at_once(3, MACHINE_PROCESSOR_COUNT * 16, ample, part), 3)
	testing.expect_value(t, test_parts_at_once(len(test_parts), max(int), ample, part), len(test_parts))
}

// The bound by memory: the available memory less HOST_MEMORY_MARGIN_MIB,
// divided by the largest part, and the smaller of the two bounds. A part
// larger than the memory, and a memory of 0, still run one part.
@(test)
test_parts_at_once_follows_the_memory :: proc(t: ^testing.T) {
	part := u64(MACHINE_MEMORY_MIB)
	many_processors := MACHINE_PROCESSOR_COUNT * 64
	// A memory of 0, and a memory at or below the margin.
	testing.expect_value(t, test_parts_at_once(30, many_processors, 0, part), 1)
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB - 1, part), 1)
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB, part), 1)
	// A part larger than the memory past the margin.
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB + part - 1, part), 1)
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB + 1, max(u64)), 1)
	// The edges of one part, then two.
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB + part, part), 1)
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB + 2 * part - 1, part), 1)
	testing.expect_value(t, test_parts_at_once(30, many_processors, HOST_MEMORY_MARGIN_MIB + 2 * part, part), 2)
	// One part: the memory never gives more than the parts.
	testing.expect_value(t, test_parts_at_once(1, many_processors, max(u64), part), 1)
	testing.expect_value(t, test_parts_at_once(1, many_processors, 0, part), 1)
	// The host of the failure that this bound answers: 16 processors give
	// 4 parts, and 6 GiB of available memory gives 2.
	testing.expect_value(t, test_parts_at_once(30, 16, HOST_MEMORY_MARGIN_MIB + 2048, part), 2)
	// The processor bound smaller than the memory bound: the processors
	// decide.
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT * 3, HOST_MEMORY_MARGIN_MIB + 10 * part, part), 3)
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT * 3, max(u64), part), 3)
	// Parts that start no machine have no bound by memory.
	testing.expect_value(t, test_parts_at_once(30, MACHINE_PROCESSOR_COUNT * 3, 0, 0), 3)
}

// The memory of a part is the -m of its machines, or none for a part that
// starts no QEMU; each row that says "No machine" in the guide declares
// it, and no other row does.
@(test)
test_parts_declare_their_memory :: proc(t: ^testing.T) {
	for part in test_parts {
		says_no_machine := strings.has_prefix(part.does, "No machine")
		testing.expectf(t, part.starts_no_machine == says_no_machine, "the part %s starts no machine in its row only when its sentence says so", part.name)
		testing.expect_value(t, test_part_memory_mib(part), says_no_machine ? 0 : u64(MACHINE_MEMORY_MIB))
	}
	testing.expect_value(t, test_parts_largest_memory_mib(nil), 0)
	testing.expect_value(t, test_parts_largest_memory_mib(test_parts[:]), u64(MACHINE_MEMORY_MIB))
}

// The parts that run at once share no data disk, and a run keeps the
// values of its own machines only.
@(test)
test_part_runs_share_no_disk_and_no_value :: proc(t: ^testing.T) {
	first := test_part_run_make("main")
	second := test_part_run_make("tcp")
	defer test_part_run_free(&first)
	defer test_part_run_free(&second)
	testing.expect(t, first.data_disk != second.data_disk, "two parts have two data disks")
	for part in test_parts {
		for other in test_parts {
			if part.name == other.name {
				continue
			}
			first_run := test_part_run_make(part.name)
			other_run := test_part_run_make(other.name)
			testing.expectf(t, first_run.data_disk != other_run.data_disk, "the parts %s and %s have two data disks", part.name, other.name)
			test_part_run_free(&first_run)
			test_part_run_free(&other_run)
		}
	}
	append(&first.remembered_values, strings.clone("a drawn value"))
	testing.expect_value(t, len(second.remembered_values), 0)
	remembered_values_forget(&first)
	testing.expect_value(t, len(first.remembered_values), 0)
}

// The guide has the table of the parts, one line for each part in the
// order of test_parts, as test_part_guide_row writes it: the guide follows
// the table of the tool. The test runs from the root of the repository.
@(test)
the_guide_has_the_table_of_the_test_parts :: proc(t: ^testing.T) {
	bytes, error := os.read_entire_file("docs/TOOLS.md", context.temp_allocator)
	testing.expect(t, error == nil, "docs/TOOLS.md can be read from the root of the repository")
	if error != nil {
		return
	}
	guide := string(bytes)
	section_start := strings.index(guide, "\n### The parts of the machine test\n")
	testing.expect(t, section_start >= 0, "the guide has the section of the parts")
	if section_start < 0 {
		return
	}
	section := guide[section_start + 1:]
	if next := strings.index(section[1:], "\n### "); next >= 0 {
		section = section[:next + 1]
	}
	rows := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(section, context.temp_allocator) {
		if strings.has_prefix(line, "| `") {
			append(&rows, line)
		}
	}
	testing.expectf(t, len(rows) == len(test_parts), "the table of the guide has %d parts, and the tool %d", len(rows), len(test_parts))
	for part, place in test_parts {
		expected := test_part_guide_row(part)
		found := place < len(rows) ? rows[place] : ""
		testing.expectf(t, found == expected, "the line %d of the table of the parts in docs/TOOLS.md must be:\n%s\nand it is:\n%s", place + 1, expected, found)
	}
}
