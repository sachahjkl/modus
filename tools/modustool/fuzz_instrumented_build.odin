package modustool

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// The instrumented child (src/md/infrastructure/fuzzing.md, "Edge counters
// from the LLVM of the build"). The build of a module already passes
// through LLVM IR and llc (src/md/infrastructure/llvm_of_the_build.md); the
// child is built the same way:
//
// 1. `odin build tools/modustool -print-linker-flags -keep-temp-files`
//    writes one IR file for each package (a large package can give one for
//    each file), and prints the commands of nasm and of the link, with no
//    link.
// 2. `opt -passes=sancov-module` instruments the IR of the packages under
//    test only: one 8-bit counter for each edge, the table of the
//    addresses of the edges, the trace of each comparison.
// 3. llc makes each object, nasm each assembly file, and clang links them
//    with the flags that the compiler printed.
//
// The tool and the runtime of Odin are not instrumented: the counters say
// which code of the system an input reached.

FUZZ_INSTRUMENTED_FOLDER :: FUZZING_BUILD_FOLDER + "/instrumented"
FUZZ_INSTRUMENTED_NAME :: "modustool_instrumented"
FUZZ_INSTRUMENTED_BINARY :: FUZZ_INSTRUMENTED_FOLDER + "/" + FUZZ_INSTRUMENTED_NAME

// The options of the pass, as `-fsanitize=fuzzer-no-link` of clang gives
// them: each block and each critical edge, an 8-bit counter with no call,
// the table of the addresses, and the comparisons.
FUZZ_COVERAGE_PASS_OPTIONS :: [?]string {
	"-passes=sancov-module",
	"-sanitizer-coverage-level=3",
	"-sanitizer-coverage-inline-8bit-counters",
	"-sanitizer-coverage-pc-table",
	"-sanitizer-coverage-trace-compares",
}

// fuzz_command_tokens splits a command that the compiler printed into its
// arguments: spaces separate them, and double quotes hold a path with no
// change.
fuzz_command_tokens :: proc(line: string) -> []string {
	tokens := make([dynamic]string, context.temp_allocator)
	current := strings.builder_make(context.temp_allocator)
	quoted := false
	has_token := false
	for character in line {
		switch {
		case character == '"':
			quoted = !quoted
			has_token = true
		case (character == ' ' || character == '\t') && !quoted:
			if has_token {
				append(&tokens, strings.clone(strings.to_string(current), context.temp_allocator))
				strings.builder_reset(&current)
				has_token = false
			}
		case:
			strings.write_rune(&current, character)
			has_token = true
		}
	}
	if has_token {
		append(&tokens, strings.clone(strings.to_string(current), context.temp_allocator))
	}
	return tokens[:]
}

// fuzz_package_is_instrumented says if an IR file of the compiler belongs
// to one of the packages under test, by the names that their sources
// declare: the name of the file is the name of the output, "-", the name of
// the package, then ".ll", "-" and the name of a file of the package, or
// "$" and a number.
fuzz_package_is_instrumented :: proc(file_name: string, package_names: []string) -> bool {
	_, found := fuzz_package_of_file(file_name, package_names)
	return found
}

// fuzz_package_of_file gives the index of the package of package_names
// that an IR file belongs to.
fuzz_package_of_file :: proc(file_name: string, package_names: []string) -> (index: int, found: bool) {
	prefix := FUZZ_INSTRUMENTED_NAME + "-"
	if !strings.has_prefix(file_name, prefix) || !strings.has_suffix(file_name, ".ll") {
		return 0, false
	}
	stem := file_name[len(prefix):len(file_name) - len(".ll")]
	for name, number in package_names {
		if stem == name || strings.has_prefix(stem, strings.concatenate({name, "-"}, context.temp_allocator)) || strings.has_prefix(stem, strings.concatenate({name, "$"}, context.temp_allocator)) {
			return number, true
		}
	}
	return 0, false
}

// fuzz_package_name_of_line gives the name of a line `package <name>`: the
// name ends at the first space, tab or "/", so a comment after it is no
// part of it.
fuzz_package_name_of_line :: proc(line: string) -> (name: string, found: bool) {
	if !strings.has_prefix(line, "package ") {
		return "", false
	}
	name = strings.trim_left_space(line[len("package "):])
	if end := strings.index_any(name, " \t\r/"); end >= 0 {
		name = name[:end]
	}
	return name, len(name) > 0
}

// fuzz_package_name_of_folder gives the name that the sources of a folder
// of the source library declare. The compiler names an IR file by it, and
// it can differ from the name of the folder: the folder support/terminal
// holds the package terminal_records. A folder whose sources cannot be read
// gives the name of the folder, and the build then fails, naming each
// folder that no IR file belongs to.
fuzz_package_name_of_folder :: proc(package_folder: string) -> string {
	folder_name := package_folder[strings.last_index_byte(package_folder, '/') + 1:]
	folder := strings.concatenate({SOURCE_FOLDER_LIBRARY, "/", package_folder}, context.temp_allocator)
	entries, error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if error != nil {
		return folder_name
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for entry in entries {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") || strings.has_suffix(entry.name, "_test.odin") {
			continue
		}
		bytes, read_error := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if read_error != nil {
			continue
		}
		for line in strings.split_lines(string(bytes), context.temp_allocator) {
			if name, found := fuzz_package_name_of_line(line); found {
				return name
			}
		}
	}
	return folder_name
}

// fuzz_package_names gives the declared name of the package of each folder.
fuzz_package_names :: proc(packages: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for package_folder in packages {
		append(&names, fuzz_package_name_of_folder(package_folder))
	}
	return names[:]
}

// The commands that the compiler printed: the assembly of each file of
// nasm, and the link.
Fuzz_Printed_Commands :: struct {
	assembly: [dynamic][]string,
	link:     []string,
}

fuzz_printed_commands :: proc(output: string) -> (commands: Fuzz_Printed_Commands, ok: bool) {
	commands.assembly = make([dynamic][]string, context.temp_allocator)
	for line in strings.split_lines(output, context.temp_allocator) {
		tokens := fuzz_command_tokens(line)
		if len(tokens) == 0 {
			continue
		}
		switch tokens[0] {
		case "nasm":
			append(&commands.assembly, tokens)
		case "clang":
			commands.link = tokens
		}
	}
	return commands, commands.link != nil
}

// fuzz_run_parallel runs commands, as many at once as the processor has
// cores, and fails when one fails.
fuzz_run_parallel :: proc(commands: [][]string) -> bool {
	limit := max(os.get_processor_core_count(), 1)
	running := make([dynamic]os.Process, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	all_passed := true
	for command in commands {
		if len(running) >= limit && !fuzz_wait_oldest(&running, &names) {
			all_passed = false
		}
		process, error := os.process_start({command = command, stdout = os.stdout, stderr = os.stderr})
		if error != nil {
			fmt.eprintfln("modustool: cannot start %s: %v", command[0], error)
			all_passed = false
			continue
		}
		append(&running, process)
		append(&names, strings.join(command[:min(len(command), 3)], " ", context.temp_allocator))
	}
	for len(running) > 0 {
		if !fuzz_wait_oldest(&running, &names) {
			all_passed = false
		}
	}
	return all_passed
}

// fuzz_wait_oldest waits for the oldest process of a list, and removes it.
fuzz_wait_oldest :: proc(processes: ^[dynamic]os.Process, process_names: ^[dynamic]string) -> bool {
	state, error := os.process_wait(processes^[0])
	name := process_names^[0]
	ordered_remove(processes, 0)
	ordered_remove(process_names, 0)
	if error != nil || !state.success {
		fmt.eprintfln("modustool: %s failed (code %d)", name, state.exit_code)
		return false
	}
	return true
}

// fuzz_instrumented_build builds the instrumented child, with the edge
// counters in the packages of `packages` (folders under the source
// library). Each build is whole: it keeps nothing of an earlier one.
fuzz_instrumented_build :: proc(packages: []string) -> bool {
	if !reset_folder(FUZZ_INSTRUMENTED_FOLDER) || !make_folder(FUZZ_INSTRUMENTED_FOLDER + "/objects") {
		return false
	}
	compile := []string{"odin", "build", TOOL_SOURCE_FOLDER, "-vet", SOURCE_LIBRARY_FLAG, "-print-linker-flags", "-keep-temp-files", "-out:" + FUZZ_INSTRUMENTED_BINARY}
	state, standard_output, standard_error, error := os.process_exec({command = compile}, context.temp_allocator)
	if error != nil || !state.success {
		fmt.eprintfln("modustool: the compile of the instrumented child failed: %v\n%s", error, string(standard_error))
		return false
	}
	commands, has_link := fuzz_printed_commands(string(standard_output))
	if !has_link {
		fmt.eprintln("modustool: the compiler printed no link command for the instrumented child")
		return false
	}
	entries, list_error := os.read_all_directory_by_path(FUZZ_INSTRUMENTED_FOLDER, context.temp_allocator)
	if list_error != nil {
		fmt.eprintfln("modustool: cannot list %s: %v", FUZZ_INSTRUMENTED_FOLDER, list_error)
		return false
	}
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	instrument := make([dynamic][]string, context.temp_allocator)
	objects_commands := make([dynamic][]string, context.temp_allocator)
	objects := make([dynamic]string, context.temp_allocator)
	instrumented_count := 0
	package_names := fuzz_package_names(packages)
	// The IR files of each package: a package with none would run with no
	// edge counted, and no message would say so.
	files_of_package := make([]int, len(package_names), context.temp_allocator)
	for entry in entries {
		if !strings.has_suffix(entry.name, ".ll") {
			continue
		}
		ir := strings.concatenate({FUZZ_INSTRUMENTED_FOLDER, "/", entry.name}, context.temp_allocator)
		object := strings.concatenate({FUZZ_INSTRUMENTED_FOLDER, "/objects/", entry.name[:len(entry.name) - len(".ll")], ".o"}, context.temp_allocator)
		if package_index, found := fuzz_package_of_file(entry.name, package_names); found {
			// Two folders of one declared name share their IR files.
			for name, index in package_names {
				if name == package_names[package_index] {
					files_of_package[index] += 1
				}
			}
			command := make([dynamic]string, context.temp_allocator)
			append(&command, "opt")
			options := FUZZ_COVERAGE_PASS_OPTIONS
			append(&command, ..options[:])
			append(&command, ir, "-o", ir)
			append(&instrument, command[:])
			instrumented_count += 1
		}
		// A clone: the literal lives on the stack of this turn of the loop.
		append(&objects_commands, slice.clone([]string{"llc", "-O1", "-relocation-model=pic", "-filetype=obj", "-o", object, ir}, context.temp_allocator))
		append(&objects, object)
	}
	all_found := instrumented_count > 0
	if len(packages) == 0 {
		fmt.eprintln("modustool: the instrumented child names no package under test")
	}
	for count, index in files_of_package {
		if count == 0 {
			fmt.eprintfln("modustool: no IR file of the compiler belongs to the package %s of the folder %s: its edges would not be counted", package_names[index], packages[index])
			all_found = false
		}
	}
	if !all_found {
		return false
	}
	// The objects of the assembly files: the command that the compiler
	// printed, with an output in the folder of this build.
	assembly_objects := make(map[string]string, context.temp_allocator)
	for command, index in commands.assembly {
		changed := slice.clone(command, context.temp_allocator)
		for token, place in changed {
			if token == "-o" && place + 1 < len(changed) {
				object := fmt.tprintf("%s/objects/assembly_%d.o", FUZZ_INSTRUMENTED_FOLDER, index)
				assembly_objects[changed[place + 1]] = object
				changed[place + 1] = object
			}
		}
		append(&objects_commands, changed)
	}
	if !fuzz_run_parallel(instrument[:]) || !fuzz_run_parallel(objects_commands[:]) {
		return false
	}
	// The link: each object of an IR file that the compiler named is
	// replaced by the objects of this build; an object of an assembly file
	// by its object here.
	link := make([dynamic]string, context.temp_allocator)
	for token in commands.link {
		if strings.has_suffix(token, ".o") {
			if object, found := assembly_objects[token]; found {
				append(&link, object)
			}
			continue
		}
		append(&link, token)
	}
	append(&link, ..objects[:])
	if !run(link[:]) {
		return false
	}
	fmt.printfln("modustool: the instrumented child %s: %d IR files with edge counters, of %d", FUZZ_INSTRUMENTED_BINARY, instrumented_count, len(objects))
	return true
}
