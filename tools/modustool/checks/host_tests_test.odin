package checks

import "core:strings"
import "core:testing"
import "modustool:foundation"

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
	testing.expect_value(t, host_tests_at_once(77, foundation.test_processors_of(32, "4")), 4)
	testing.expect_value(t, host_tests_at_once(77, foundation.test_processors_of(32, "")), 32)
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
	test_programs := make(map[string]bool, context.temp_allocator)
	for folder in folders {
		command := host_test_command(folder, "/temporary")
		testing.expect_value(t, command[0], "env")
		testing.expect_value(t, command[1], "TMPDIR=/temporary")
		kernel_flag_count := 0
		for word in command {
			if word == foundation.KERNEL_LIBRARY_FLAG {
				kernel_flag_count += 1
			}
		}
		testing.expectf(t, kernel_flag_count == (foundation.source_folder_takes_kernel_library(folder) ? 1 : 0), "%s: the flag of the kernel parts %d times", folder, kernel_flag_count)
		tool_flag_count := 0
		for word in command {
			if word == foundation.TOOL_LIBRARY_FLAG {
				tool_flag_count += 1
			}
		}
		testing.expectf(t, tool_flag_count == (foundation.source_folder_is_of_the_tool(folder) ? 1 : 0), "%s: the flag of the source library of the tool %d times", folder, tool_flag_count)
		test_program := command[len(command) - 1]
		testing.expectf(t, strings.has_prefix(test_program, "-out:" + foundation.BUILD_FOLDER + "/test_"), "%s: the last word is the test program, not %s", folder, test_program)
		testing.expectf(t, !test_programs[test_program], "%s: the test program %s is the test program of another folder", folder, test_program)
		test_programs[test_program] = true
	}
	tool := host_test_command(foundation.TOOL_SOURCE_FOLDER, "/temporary")
	testing.expect(t, strings.contains(strings.join(tool, " ", context.temp_allocator), foundation.KERNEL_LIBRARY_FLAG), "the tool takes the kernel parts")
	library := host_test_command(foundation.SOURCE_FOLDER_CONTRACT + "/ring", "/temporary")
	testing.expect(t, !strings.contains(strings.join(library, " ", context.temp_allocator), foundation.KERNEL_LIBRARY_FLAG), "a folder of the library does not take the kernel parts")
	testing.expect(t, !strings.contains(strings.join(library, " ", context.temp_allocator), foundation.TOOL_LIBRARY_FLAG), "a folder of the library does not take the source library of the tool")
	// A package of the tool takes both: it imports another package of the
	// tool, which can import a kernel part.
	package_of_the_tool := strings.join(host_test_command(foundation.TOOL_SOURCE_FOLDER + "/foundation", "/temporary"), " ", context.temp_allocator)
	testing.expect(t, strings.contains(package_of_the_tool, foundation.KERNEL_LIBRARY_FLAG) && strings.contains(package_of_the_tool, foundation.TOOL_LIBRARY_FLAG), "a package of the tool takes the kernel parts and the source library of the tool")
	for package_folder in ([]string{foundation.TOOL_SOURCE_FOLDER + "/foundation", foundation.TOOL_SOURCE_FOLDER + "/resources", foundation.TOOL_SOURCE_FOLDER + "/build", foundation.TOOL_SOURCE_FOLDER + "/checks", foundation.TOOL_SOURCE_FOLDER + "/fuzz", foundation.TOOL_SOURCE_FOLDER + "/similarity"}) {
		listed := false
		for folder in folders {
			listed = listed || folder == package_folder
		}
		testing.expectf(t, listed, "the host tests of the package %s run in the check", package_folder)
	}
	// With no temporary folder of its own, a folder keeps the temporary
	// folder of the check: its command sets no variable.
	inherited := host_test_command(foundation.SOURCE_FOLDER_CONTRACT + "/ring", "")
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
