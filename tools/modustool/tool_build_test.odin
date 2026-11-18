package modustool

import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// The binary of the development shell finds its sources only from its own
// place: a binary at another place, at the place of the older command, or
// a file of a build that runs, has no root.
@(test)
tool_root_only_from_the_place_of_the_binary :: proc(t: ^testing.T) {
	for executable in ([]string{"", "modustool", TOOL_BINARY, "/" + TOOL_BINARY, "/home/someone/modus/" + foundation.BUILD_FOLDER + "/modustool", "/home/someone/modus/" + TOOL_BINARY + ".7.next", "/home/someone/modus/" + TOOL_BINARY + "/other", "/nix/store/x-modustool/bin/modustool"}) {
		_, found := tool_root_of_binary(executable)
		testing.expectf(t, !found, "%q has no root", executable)
	}
	root, found := tool_root_of_binary("/home/someone/modus/" + TOOL_BINARY)
	testing.expect(t, found)
	testing.expect_value(t, root, "/home/someone/modus")
}

// The compile of the tool writes its binary and the list of its compiler
// into files of the process, never at the place of the binary.
@(test)
tool_compile_command_writes_files_of_the_host_process :: proc(t: ^testing.T) {
	command := tool_compile_command_of(TOOL_BINARY + ".7.next", TOOL_BINARY + ".7." + DEPENDENCY_FILE_NAME)
	base := TOOL_COMPILE_COMMAND
	testing.expect(t, len(command) > len(base))
	for word, place in base {
		testing.expect_value(t, command[place], word)
	}
	words := strings.join(command, " ", context.temp_allocator)
	testing.expect(t, strings.contains(words, "-out:" + TOOL_BINARY + ".7.next"), "the binary goes to the file of the process")
	testing.expect(t, !strings.contains(words, "-out:" + TOOL_BINARY + " "), "the binary never goes to the place of the binary that runs")
	testing.expect(t, strings.contains(words, "-export-dependencies-file:" + TOOL_BINARY + ".7." + DEPENDENCY_FILE_NAME), "the list goes to the file of the process")
	// The output paths hold the number of the process: they are not
	// inputs of the key.
	inputs := tool_build_key_inputs()
	for setting in inputs.settings {
		testing.expectf(t, !strings.has_prefix(setting, "-out:") && !strings.has_prefix(setting, "-export-dependencies-file:"), "%s is not an input of the key", setting)
	}
}

// The command of the flake compiles the tool with the words of the tool:
// its first binary in the development shell, and the derivation of the
// check, whose binary never compiles itself.
@(test)
tool_compile_words_of_the_flake :: proc(t: ^testing.T) {
	bytes, error := os.read_entire_file(foundation.ROOT_MARK, context.temp_allocator)
	testing.expect(t, error == nil, "the test runs from the root of the repository")
	flake := string(bytes)
	base := TOOL_COMPILE_COMMAND
	words := strings.join(base[:], " ", context.temp_allocator)
	testing.expect_value(t, strings.count(flake, words), 2)
	testing.expect(t, strings.contains(flake, strings.concatenate({words, " -out:", TOOL_BINARY}, context.temp_allocator)), "the first binary of the shell is at the place of the binary")
	testing.expect(t, strings.contains(flake, strings.concatenate({words, " ", TOOL_NEVER_BUILDS_ITSELF_FLAG}, context.temp_allocator)), "the binary of the check never compiles itself")
}

// A record that a file changed after the table hashed it is never
// written, and an old record does not stay.
@(test)
tool_build_record_refused_after_a_change_during_the_compile :: proc(t: ^testing.T) {
	root, source, binary, record_path := tool_build_tree(t, "test_tool_build_changed")
	table := input_file_table_make(root, nil)
	defer input_file_table_destroy(table)
	_ = input_file(table, source)
	testing.expect(t, os.write_entire_file(source, "package a\n\nchanged := 1\n") == nil)
	testing.expect(t, os.write_entire_file(record_path, "an old record\n") == nil)
	inputs := Build_Key_Inputs{subject = "the tool", settings = []string{"odin", "build"}}
	testing.expect(t, !tool_build_record_write(record_path, binary, inputs, table, []string{source}, nil), "a source that changed after its hash gives no record")
	testing.expect(t, !os.exists(record_path), "the old record is removed")
	testing.expect(t, !tool_build_record_write(record_path, binary, inputs, table, nil, nil), "a compiler that read no file gives no record")
	testing.expect(t, !os.exists(record_path))
}

// The binary is compiled again for each change of what the key holds: no
// record, a damaged record, a source, a new file beside a source, the
// binary, the command or the compiler. The case of a current binary is
// the last.
@(test)
tool_binary_is_compiled_again_for_each_change :: proc(t: ^testing.T) {
	root, source, binary, record_path := tool_build_tree(t, "test_tool_build_changes")
	inputs := Build_Key_Inputs{subject = "the tool", settings = []string{"odin", "build"}}
	decide :: proc(root, record_path, binary: string, inputs: Build_Key_Inputs) -> (bool, string) {
		table := input_file_table_make(root, nil)
		defer input_file_table_destroy(table)
		return tool_binary_is_current(record_path, binary, inputs, table)
	}
	current, reason := decide(root, record_path, binary, inputs)
	testing.expect(t, !current, "no record")
	testing.expect_value(t, reason, "no build record")
	testing.expect(t, os.write_entire_file(record_path, "not a record\n") == nil)
	current, _ = decide(root, record_path, binary, inputs)
	testing.expect(t, !current, "a damaged record")
	// A record of the tree as it is: its key, with no rule on the times of
	// the files, which a test cannot hold.
	{
		table := input_file_table_make(root, nil)
		defer input_file_table_destroy(table)
		with_list := inputs
		with_list.source_files = []string{source}
		key, complete := build_key(with_list, table)
		testing.expect(t, complete)
		testing.expect(t, build_record_write(record_path, key, []string{binary}, []string{source}, nil))
	}
	testing.expect(t, os.write_entire_file(source, "package a\n\nchanged := 1\n") == nil)
	current, reason = decide(root, record_path, binary, inputs)
	testing.expect(t, !current, "a source changed")
	testing.expect_value(t, reason, "an input changed")
	testing.expect(t, os.write_entire_file(source, TOOL_BUILD_TREE_SOURCE) == nil)
	beside := foundation.join(root, "/tools/b.odin")
	testing.expect(t, os.write_entire_file(beside, "package a\n") == nil)
	current, reason = decide(root, record_path, binary, inputs)
	testing.expect(t, !current, "a new file beside a source")
	testing.expect_value(t, reason, "an input changed")
	testing.expect(t, os.remove(beside) == nil)
	testing.expect(t, os.write_entire_file(binary, "another binary") == nil)
	current, reason = decide(root, record_path, binary, inputs)
	testing.expect(t, !current, "a binary with other bytes")
	testing.expect_value(t, reason, OUTPUT_CHANGED_REASON)
	testing.expect(t, os.write_entire_file(binary, TOOL_BUILD_TREE_BINARY) == nil)
	other_command := inputs
	other_command.settings = []string{"odin", "build", "-vet"}
	current, reason = decide(root, record_path, binary, other_command)
	testing.expect(t, !current, "another command")
	testing.expect_value(t, reason, "an input changed")
	current, reason = decide(root, record_path, binary, inputs)
	testing.expect(t, current, "the same sources, the same command and the same binary")
	testing.expect_value(t, reason, "")
}

TOOL_BUILD_TREE_SOURCE :: "package a\n"
TOOL_BUILD_TREE_BINARY :: "the binary"

// tool_build_tree writes a small tree in a folder of the build: one
// source, and a binary at the place of the binary of the shell.
@(private = "file")
tool_build_tree :: proc(t: ^testing.T, name: string) -> (root, source, binary, record_path: string) {
	working, error := os.get_working_directory(context.temp_allocator)
	testing.expect(t, error == nil)
	root = foundation.join(working, "/", foundation.BUILD_FOLDER, "/", name)
	testing.expect(t, foundation.reset_folder(root))
	testing.expect(t, foundation.make_folder(foundation.join(root, "/tools")))
	testing.expect(t, foundation.make_folder(foundation.join(root, "/", TOOL_BUILD_FOLDER)))
	source = foundation.join(root, "/tools/a.odin")
	binary = foundation.join(root, "/", TOOL_BINARY)
	record_path = foundation.join(root, "/", TOOL_BUILD_RECORD)
	testing.expect(t, os.write_entire_file(source, TOOL_BUILD_TREE_SOURCE) == nil)
	testing.expect(t, os.write_entire_file(binary, TOOL_BUILD_TREE_BINARY) == nil)
	return
}
