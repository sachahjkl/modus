package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "modustool:foundation"

// The tool built once (src/md/infrastructure/repository_layout.md, "The
// tool built once"). The command `modustool` of the development shell
// runs the binary TOOL_BINARY. Before a command, that binary compares the
// build key of its own sources with the key of its build record, as the
// incremental build does for a module (incremental_build.odin): the list
// of the files that its compiler read, every other file of the folder of
// each of them, the command of the compiler and the program `odin`. When
// the key differs, it compiles the tool again, then runs the new binary
// with the same arguments and ends with its status. A time of a file is
// not the identity of a source, so the key, and not a time, decides.
//
// The check of the flake builds the tool as a derivation of its own,
// with TOOL_BUILDS_ITSELF false: Nix builds it again for each change of
// its sources, and the binary of the store never compiles itself.

// The binary of the development shell, and the files of its build, from
// the root of the repository. The command of the flake makes the first
// binary when TOOL_BINARY is absent: the command modustool of flake.nix.
TOOL_BUILD_FOLDER :: foundation.BUILD_FOLDER + "/tool"
TOOL_BINARY :: TOOL_BUILD_FOLDER + "/modustool"
TOOL_BUILD_RECORD :: TOOL_BINARY + BUILD_RECORD_SUFFIX

// The compile of the tool, with no output. flake.nix writes the same
// words for its first binary and for the derivation of the check; a host
// test reads them there.
TOOL_COMPILE_COMMAND :: [?]string{"odin", "build", foundation.TOOL_SOURCE_FOLDER, "-vet", foundation.SOURCE_LIBRARY_FLAG, foundation.KERNEL_LIBRARY_FLAG, foundation.TOOL_LIBRARY_FLAG, foundation.LOG_FACT_ATTRIBUTE_FLAG}

// False in the binary of the store, whose sources are the inputs of its
// derivation, and in the instrumented child of the fuzzing, a build of
// the sources of its parent at another place (fuzz_instrumented_build.odin).
TOOL_BUILDS_ITSELF :: #config(TOOL_BUILDS_ITSELF, true)
TOOL_NEVER_BUILDS_ITSELF_FLAG :: "-define:TOOL_BUILDS_ITSELF=false"

// Set by the first process of a command, after its check: each process
// that it starts (a module step, a boot volume, a fuzz child, the binary
// that it compiled) inherits it and does not hash the sources again.
TOOL_SOURCES_CHECKED_VARIABLE :: "MODUSTOOL_SOURCES_CHECKED"

// tool_root_of_binary gives the root of the repository from the path of
// the binary of the development shell: the path with TOOL_BINARY at its
// end. A binary at another place has no root, and so no sources.
tool_root_of_binary :: proc(executable: string) -> (root: string, found: bool) {
	suffix :: "/" + TOOL_BINARY
	if !strings.has_suffix(executable, suffix) || len(executable) == len(suffix) {
		return "", false
	}
	return executable[:len(executable) - len(suffix)], true
}

// tool_compile_command_of gives the command that compiles the tool to
// output, with the list of the files that the compiler reads in
// dependency_file. Each process has its own two files: two commands that
// start at once never write one file.
tool_compile_command_of :: proc(output, dependency_file: string) -> []string {
	base := TOOL_COMPILE_COMMAND
	command := make([dynamic]string, context.temp_allocator)
	append(&command, ..base[:])
	append(&command, foundation.join("-out:", output), "-export-dependencies:json", foundation.join("-export-dependencies-file:", dependency_file))
	return command[:]
}

// tool_build_key_inputs gives the inputs of the build key of the tool,
// without the list of the compiler. The output paths of the command are
// not inputs: they hold the number of the process.
tool_build_key_inputs :: proc() -> Build_Key_Inputs {
	base := TOOL_COMPILE_COMMAND
	settings := make([dynamic]string, context.temp_allocator)
	append(&settings, host_program_identity("odin"), "the compiler")
	append(&settings, ..base[:])
	return {subject = "the tool", settings = settings[:]}
}

// tool_binary_is_current says if the binary at binary is the build of the
// sources as they are now: its record has the build key of now, and the
// binary has its recorded hash. reason says why it is not.
tool_binary_is_current :: proc(record_path, binary: string, inputs: Build_Key_Inputs, table: ^Input_File_Table) -> (current: bool, reason: string) {
	return recorded_build_is_kept(record_path, inputs, table, []string{binary})
}

// tool_build_record_write writes the build record of a binary that the
// compiler made from the files of its list. It writes none, and removes
// an old one, when a file of the list cannot be read or changed after the
// table hashed it: the record would join the key of some bytes to the
// binary of other bytes.
tool_build_record_write :: proc(record_path, binary: string, inputs: Build_Key_Inputs, table: ^Input_File_Table, source_files, load_files: []string) -> bool {
	inputs_of_the_build := inputs
	inputs_of_the_build.source_files = source_files
	inputs_of_the_build.load_files = load_files
	key, complete := build_key(inputs_of_the_build, table, true)
	if !complete || len(source_files) == 0 {
		_ = os.remove(record_path)
		return false
	}
	return build_record_write(record_path, key, []string{binary}, source_files, load_files)
}

// tool_build_current makes this process the build of the sources as they
// are now. With a current binary, or in a process that a checked command
// started, it returns. If not, it compiles the tool again, runs the new
// binary with the arguments of this process, and ends with its status:
// it then does not return.
tool_build_current :: proc() {
	if os.get_env(TOOL_SOURCES_CHECKED_VARIABLE, context.temp_allocator) != "" {
		return
	}
	executable, path_error := os.get_executable_path(context.temp_allocator)
	if path_error != nil {
		fmt.eprintfln("modustool: cannot find the file of the tool: %v", path_error)
		os.exit(foundation.EXIT_FAILURE)
	}
	root, found := tool_root_of_binary(executable)
	if !found {
		fmt.eprintfln("modustool: the tool is %s, and not %s in the folder of a repository: it cannot find its sources", executable, TOOL_BINARY)
		os.exit(foundation.EXIT_FAILURE)
	}
	_ = os.set_env(TOOL_SOURCES_CHECKED_VARIABLE, "yes")
	// The table holds the time of the start: a source that changes during
	// the compile then gives no record, and the next command compiles again.
	table := input_file_table_make(root, nil)
	inputs := tool_build_key_inputs()
	binary := foundation.join(root, "/", TOOL_BINARY)
	record_path := foundation.join(root, "/", TOOL_BUILD_RECORD)
	current, reason := tool_binary_is_current(record_path, binary, inputs, table)
	if current {
		input_file_table_destroy(table)
		return
	}
	// The lines of the compile go to the standard error: the standard
	// output of a command is its own, and a caller can read it.
	fmt.eprintfln("modustool: the tool is compiled again (%s)", reason)
	built := tool_build(root, binary, record_path, inputs, table)
	input_file_table_destroy(table)
	if !built {
		os.exit(foundation.EXIT_FAILURE)
	}
	os.exit(tool_run_again(binary))
}

// tool_build compiles the tool into a file of this process, then puts it
// at binary, and writes its build record. The record of the binary before
// is removed first: it must not stay beside a new binary.
tool_build :: proc(root, binary, record_path: string, inputs: Build_Key_Inputs, table: ^Input_File_Table) -> bool {
	foundation.make_folder(foundation.join(root, "/", TOOL_BUILD_FOLDER)) or_return
	_ = os.remove(record_path)
	host_process_number := os.get_pid()
	output := fmt.tprintf("%s.%d.next", TOOL_BINARY, host_process_number)
	dependency_file := fmt.tprintf("%s.%d.%s", TOOL_BINARY, host_process_number, DEPENDENCY_FILE_NAME)
	output_path := foundation.join(root, "/", output)
	dependency_path := foundation.join(root, "/", dependency_file)
	defer {
		_ = os.remove(dependency_path)
	}
	command := tool_compile_command_of(output, dependency_file)
	started := time.tick_now()
	host_process, start_error := os.process_start({command = command, working_dir = root, stdin = os.stdin, stdout = os.stderr, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], start_error)
		return false
	}
	state, wait_error := os.process_wait(host_process)
	// The compile time of the tool is a measure: nothing reads it.
	fmt.eprintfln("modustool: measure: the compile of the tool: %.1f s", time.duration_seconds(time.tick_since(started)))
	if wait_error != nil || !state.success {
		_ = os.remove(output_path)
		fmt.eprintln("modustool: the compile of the tool failed: the command did not run")
		return false
	}
	if rename_error := os.rename(output_path, binary); rename_error != nil {
		fmt.eprintfln("modustool: cannot put the tool at %s: %v", binary, rename_error)
		return false
	}
	source_files, load_files, listed := dependency_list_read(dependency_path)
	if !listed || !tool_build_record_write(record_path, binary, inputs, table, source_files, load_files) {
		fmt.eprintln("modustool: no build record for the tool: the compiler gave no list of its files, or a source changed during its compile; the next command compiles it again")
	}
	return true
}

// tool_run_again runs the new binary with the arguments of this process,
// on the terminal of this process, and gives its status.
tool_run_again :: proc(binary: string) -> int {
	command := make([dynamic]string, context.temp_allocator)
	append(&command, binary)
	append(&command, ..os.args[1:])
	host_process, start_error := os.process_start({command = command[:], stdin = os.stdin, stdout = os.stdout, stderr = os.stderr})
	if start_error != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", binary, start_error)
		return foundation.EXIT_FAILURE
	}
	state, wait_error := os.process_wait(host_process)
	if wait_error != nil || !state.exited {
		return foundation.EXIT_FAILURE
	}
	return state.exit_code
}
