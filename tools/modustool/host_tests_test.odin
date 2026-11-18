package modustool

import "core:strings"
import "core:testing"

// The pool of processes that the host tests share with the build. Its
// outputs are memory of the worker threads, outside the memory that the
// test runner follows: the tests do not free them.

// A command that cannot start, and a command that ends with a failure,
// are failures; after a failure the pool starts no new process. With one
// process at once the order is fixed: the second and the third commands
// never start.
@(test)
host_test_pool_stops_after_a_failure :: proc(t: ^testing.T) {
	missing := []string{"/a program that is not there"}
	outcomes := build_processes_run([][]string{missing, []string{"true"}, []string{"true"}}, 1, context.temp_allocator)
	testing.expect_value(t, len(outcomes), 3)
	testing.expect(t, outcomes[0].started && !outcomes[0].success, "a command that cannot start is a failure")
	testing.expect(t, len(outcomes[0].output) > 0, "a command that cannot start says why")
	testing.expect(t, !outcomes[1].started && !outcomes[2].started, "no process starts after a failure")
	// A program that runs and ends with a status that is not 0: its
	// output is kept, and the next command does not start.
	absent := "/a folder that is not there/of a host test"
	outcomes = build_processes_run([][]string{[]string{"ls", absent}, []string{"true"}}, 1, context.temp_allocator)
	testing.expect(t, outcomes[0].started && !outcomes[0].success, "a status that is not 0 is a failure")
	testing.expect(t, strings.contains(string(outcomes[0].output), absent), "the output of a failure is kept: it names the folder")
	testing.expect(t, !outcomes[1].started, "no process starts after a failure")
}

// No count of processes starts no process: the caller then counts each
// command as not started, never as passed. host_tests_run asks for one
// at the least.
@(test)
host_test_pool_with_no_process_starts_none :: proc(t: ^testing.T) {
	for processes in ([]int{0, -1}) {
		outcomes := build_processes_run([][]string{[]string{"true"}}, processes, context.temp_allocator)
		testing.expect_value(t, len(outcomes), 1)
		testing.expectf(t, !outcomes[0].started && !outcomes[0].success, "%d processes at once start no command", processes)
	}
}

// The outcomes have the order of the commands, not the order of their
// ends, and each keeps its own output. The successful case is the last.
@(test)
host_test_pool_keeps_the_order_of_the_commands :: proc(t: ^testing.T) {
	outcomes := build_processes_run([][]string{[]string{"echo", "first"}, []string{"echo", "second"}, []string{"echo", "third"}}, 3, context.temp_allocator)
	testing.expect_value(t, len(outcomes), 3)
	for text, place in ([]string{"first\n", "second\n", "third\n"}) {
		testing.expectf(t, outcomes[place].started && outcomes[place].success, "the command %d passed", place)
		testing.expect_value(t, string(outcomes[place].output), text)
	}
}

// The count at once: at least one, at most one for each processor and
// one for each folder. The edges first: no processor, a negative count,
// no folder.
@(test)
host_tests_at_once_is_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, host_tests_at_once(77, 0), 1)
	testing.expect_value(t, host_tests_at_once(77, -4), 1)
	testing.expect_value(t, host_tests_at_once(0, 16), 1)
	testing.expect_value(t, host_tests_at_once(1, 16), 1)
	testing.expect_value(t, host_tests_at_once(3, 16), 3)
	testing.expect_value(t, host_tests_at_once(77, 1), 1)
	testing.expect_value(t, host_tests_at_once(77, 16), 16)
	testing.expect_value(t, host_tests_at_once(16, 16), 16)
	testing.expect_value(t, host_tests_at_once(17, 16), 16)
	// The bound of the sandbox: NIX_BUILD_CORES bounds the processors.
	testing.expect_value(t, host_tests_at_once(77, test_processors_of(32, "4")), 4)
	testing.expect_value(t, host_tests_at_once(77, test_processors_of(32, "")), 32)
}

// Two folders whose files have one name are refused before any process
// starts: "a/b_c" and "a_b/c" both give "a_b_c". The folders of the
// check have distinct names.
@(test)
host_test_folders_with_one_name_are_refused :: proc(t: ^testing.T) {
	testing.expect(t, host_test_names_first_repeat([]string{"a/b_c", "a_b/c"}) != "", "two paths that give one name are refused")
	testing.expect(t, host_test_names_first_repeat([]string{"a/b", "x", "a/b"}) != "", "one folder two times is refused")
	testing.expect_value(t, host_test_names_first_repeat(nil), "")
	testing.expect_value(t, host_test_names_first_repeat([]string{"a/b", "a/c"}), "")
	folders := HOST_TEST_FOLDERS
	testing.expect_value(t, host_test_names_first_repeat(folders[:]), "")
}

// The flag of the kernel parts goes to the host tests of src/kernel/* and
// of the tool only, as in the compile of each; each command has its own
// temporary folder and its own test program.
@(test)
host_test_commands_take_the_kernel_parts_where_they_compile :: proc(t: ^testing.T) {
	folders := HOST_TEST_FOLDERS
	programs := make(map[string]bool, context.temp_allocator)
	for folder in folders {
		command := host_test_command(folder, "/temporary")
		testing.expect_value(t, command[0], "env")
		testing.expect_value(t, command[1], "TMPDIR=/temporary")
		kernel_flag_count := 0
		for word in command {
			if word == KERNEL_LIBRARY_FLAG {
				kernel_flag_count += 1
			}
		}
		testing.expectf(t, kernel_flag_count == (source_folder_takes_kernel_library(folder) ? 1 : 0), "%s: the flag of the kernel parts %d times", folder, kernel_flag_count)
		program := command[len(command) - 1]
		testing.expectf(t, strings.has_prefix(program, "-out:" + BUILD_FOLDER + "/test_"), "%s: the last word is the test program, not %s", folder, program)
		testing.expectf(t, !programs[program], "%s: the test program %s is the program of another folder", folder, program)
		programs[program] = true
	}
	tool := host_test_command(TOOL_SOURCE_FOLDER, "/temporary")
	testing.expect(t, strings.contains(strings.join(tool, " ", context.temp_allocator), KERNEL_LIBRARY_FLAG), "the tool takes the kernel parts")
	library := host_test_command(SOURCE_FOLDER_CONTRACT + "/ring", "/temporary")
	testing.expect(t, !strings.contains(strings.join(library, " ", context.temp_allocator), KERNEL_LIBRARY_FLAG), "a folder of the library does not take the kernel parts")
	// With no temporary folder of its own, a folder keeps the temporary
	// folder of the check: its command sets no variable.
	inherited := host_test_command(SOURCE_FOLDER_CONTRACT + "/ring", "")
	testing.expect_value(t, inherited[0], "odin")
	testing.expect(t, !strings.contains(strings.join(inherited, " ", context.temp_allocator), "TMPDIR="), "no temporary folder is set")
}

// The end of a log: no line for a count of 0 or less, the whole text when
// it has fewer lines, and the last lines with their ends of line.
@(test)
text_last_lines_of_a_log :: proc(t: ^testing.T) {
	testing.expect_value(t, text_last_lines("a\nb\n", 0), "")
	testing.expect_value(t, text_last_lines("a\nb\n", -1), "")
	testing.expect_value(t, text_last_lines("", 1), "")
	testing.expect_value(t, text_last_lines("\n", 1), "\n")
	testing.expect_value(t, text_last_lines("a\nb\nc\n", 1), "c\n")
	testing.expect_value(t, text_last_lines("a\nb\nc\n", 2), "b\nc\n")
	testing.expect_value(t, text_last_lines("a\nb\nc\n", 3), "a\nb\nc\n")
	testing.expect_value(t, text_last_lines("a\nb\nc\n", 4), "a\nb\nc\n")
	testing.expect_value(t, text_last_lines("a\nb\nc", 1), "c")
	testing.expect_value(t, text_last_lines("a\n\nc\n", 2), "\nc\n")
	testing.expect_value(t, text_last_lines("only", 1), "only")
}
