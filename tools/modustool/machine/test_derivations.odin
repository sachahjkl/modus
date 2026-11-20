package machine

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "modustool:build"
import "modustool:foundation"

// The derivations of the full check (src/md/infrastructure/full_check.md,
// "The derivations of the check"): the test inputs that a whole build
// gives, a test part on a given build, the join of the outputs of the parts,
// the count of the parts that Nix takes from the store, and the proof that a
// change of a document runs no part again.

// The folder of the test inputs and the file of the names of the test parts,
// in the output of the derivation of the whole build (flake.nix, systemBuild).
TEST_INPUTS_FOLDER_NAME :: "test_inputs"
TEST_PARTS_FILE_NAME :: "test_parts.json"

// The count of the checks that passed in one process. A part derivation
// writes it after its part; `check` writes it at its end; the join adds up
// the counts of its outputs.
CHECKS_PASSED_FILE_NAME :: "checks_passed.txt"
CHECKS_PASSED_FILE :: foundation.BUILD_FOLDER + "/" + CHECKS_PASSED_FILE_NAME

// The folders of an output of a part derivation and of the join.
JOINED_LOG_FOLDER_NAME :: "logs"
JOINED_PICTURE_FOLDER_NAME :: "screenshots"

// The suffixes of the files of a build that are no test inputs. The LLVM IR,
// the objects and the linked files name the compiler in the store, and a
// fixed-output derivation must hold no path of the store. The build records,
// the lists of the compiler and the logs hold the sources and the times of
// one build, so they would make the hash new at each build.
TEST_INPUT_REFUSED_SUFFIXES :: [?]string{".build_record", ".json", ".ll", ".bc", ".o", ".obj", ".lib", ".elf", ".txt", ".log"}

// The folders of a build that hold no test input: the parts of the build of
// a module that name the compiler, and the folders of the other commands.
TEST_INPUT_REFUSED_FOLDERS :: [?]string{"llvm_ir", "objects", "tool", "screenshots", "host_tests", "fuzzing", "different_builds", "modules_without_debug_information", "flake_check", "site", "films", "similarity", "part_cache"}

// The kinds of the files of a build, one of each module, that a test part
// can read past its boot volumes. A kind is a test input when the test
// inputs keep its files; the others name the compiler in the store or the
// time of one build, so only a build or a check that runs where the build
// is reads them.
Build_File_Kind :: enum {
	Module_File,
	Debug_Object,
	Module_Source_List, // The sources of the repository that the compiler read.
	Reached_Fact_List, // The fact keys that the compile step found in the code.
	Linked_File, // The output of the link, with the debug information that names the compiler in the store.
	Dependency_List, // The list of the compiler, with the paths of its libraries in the store.
	Build_Record,
}

Build_File_Kinds :: bit_set[Build_File_Kind]

// What the engine of a machine reads in every part: the module files (the
// catalog of the log facts, the measures of the log) and the debug objects
// (the stack traces, the state of a processor at a fault).
MACHINE_ENGINE_READS :: Build_File_Kinds{.Module_File, .Debug_Object}

// The texts of a source of the tool that name a file of each kind: a
// procedure that holds one reads that kind. A host test reads the sources
// with them, and refuses a part whose procedures read a kind that it does
// not declare, or that the test inputs do not keep.
build_file_kind_markers := [Build_File_Kind][]string {
	.Module_File        = {"module_path("},
	.Debug_Object       = {"debug_object_path(", "module_debug_object_file("},
	.Module_Source_List = {"module_source_list_file(", "module_source_list_read("},
	.Reached_Fact_List  = {"module_reached_facts_file("},
	.Linked_File        = {"module_linked_file(", "linked.elf"},
	.Dependency_List    = {"module_dependency_file(", "dependency_list_read(", "boot_volume_dependency_file(", "DEPENDENCY_FILE_NAME"},
	.Build_Record       = {"BUILD_RECORD_SUFFIX", "_record_path(", "TOOL_BUILD_RECORD"},
}

// build_file_of_module gives the file of one kind of a module, by its path
// relative to the build folder.
build_file_of_module :: proc(kind: Build_File_Kind, name: string) -> string {
	path: string
	switch kind {
	case .Module_File:
		path = foundation.module_path(name)
	case .Debug_Object:
		path = build.debug_object_path(name)
	case .Module_Source_List:
		path = build.module_source_list_file(name)
	case .Reached_Fact_List:
		path = build.module_reached_facts_file(name)
	case .Linked_File:
		path = build.module_linked_file(name)
	case .Dependency_List:
		path = build.module_dependency_file(name)
	case .Build_Record:
		path = foundation.join(foundation.module_build_folder, "/", name, build.COMPILE_RECORD_SUFFIX)
	}
	relative, _ := build_relative_path(path)
	return relative
}

// build_file_kind_is_test_input says if the test inputs keep the files of
// a kind: the rule of test_input_kept, on the file of the kernel.
build_file_kind_is_test_input :: proc(kind: Build_File_Kind) -> bool {
	return test_input_kept(build_file_of_module(kind, "kernel"))
}

// test_part_reads gives the kinds of the files of the build that a part
// reads: those that it declares, and those of the engine of a machine.
test_part_reads :: proc(part: Test_Part) -> Build_File_Kinds {
	return part.reads + MACHINE_ENGINE_READS
}

// test_part_reads_problem refuses a part that reads a kind of file that the
// test inputs do not keep: its part derivation would fail at the first
// read, after machines ran.
test_part_reads_problem :: proc(part: Test_Part) -> string {
	for kind in test_part_reads(part) {
		if !build_file_kind_is_test_input(kind) {
			return fmt.tprintf("the test part %s reads the %v of each module (%s), which the test inputs do not keep: it names the compiler in the store or the time of one build", part.name, kind, build_file_of_module(kind, "kernel"))
		}
	}
	return ""
}

// test_part_build_files_problem refuses a part that reads a kind of file
// that the test inputs do not keep, or whose file of a module of the table
// the inputs lack. held names the files of the inputs by their paths
// relative to the folder of the inputs.
test_part_build_files_problem :: proc(part: Test_Part, held: map[string]bool) -> string {
	if problem := test_part_reads_problem(part); problem != "" {
		return problem
	}
	for kind in test_part_reads(part) {
		for module_build in foundation.module_builds {
			path := build_file_of_module(kind, module_build.name)
			if !held[path] {
				return fmt.tprintf("the test part %s reads %s, which the test inputs lack", part.name, path)
			}
		}
	}
	return ""
}

// test_input_kept says if a file of the build folder, by its path relative
// to that folder, is a test input. A path that leaves the folder, or that
// names no file, is refused.
test_input_kept :: proc(relative_path: string) -> bool {
	if relative_path == "" || strings.has_prefix(relative_path, "/") {
		return false
	}
	parts := strings.split(relative_path, "/", context.temp_allocator)
	for part in parts {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	refused_folders := TEST_INPUT_REFUSED_FOLDERS
	for folder in parts[:len(parts) - 1] {
		if slice.contains(refused_folders[:], folder) {
			return false
		}
	}
	refused_suffixes := TEST_INPUT_REFUSED_SUFFIXES
	for suffix in refused_suffixes {
		if strings.has_suffix(relative_path, suffix) {
			return false
		}
	}
	return true
}

// test_input_is_linked says if a test input is a boot volume of a part or a
// boot image: 64 MiB or about 11 MB, which QEMU and the release image only
// read. A part links it in place of a copy. Another disk of the build is a
// copy: a part can write it. volume_paths are the relative paths of the
// boot volumes of the parts.
test_input_is_linked :: proc(relative_path: string, volume_paths: []string) -> bool {
	return strings.has_suffix(relative_path, ".image") || slice.contains(volume_paths, relative_path)
}

// test_parts_volume_paths gives the paths of the boot volumes of every part,
// relative to the build folder, in the temporary memory.
test_parts_volume_paths :: proc() -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	for part in test_parts {
		for volume in test_part_volumes_of(part) {
			if relative, inside := build_relative_path(volume); inside && !slice.contains(paths[:], relative) {
				append(&paths, relative)
			}
		}
	}
	return paths[:]
}

// relative_files_collect appends the paths of the files under a folder,
// relative to root, with each folder below it. Its texts are of the
// temporary memory.
@(private = "file")
relative_files_collect :: proc(root, relative: string, paths: ^[dynamic]string) -> bool {
	folder := relative == "" ? root : foundation.join(root, "/", relative)
	entries, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
	if list_error != nil {
		fmt.eprintfln("modustool: cannot list %s: %v", folder, list_error)
		return false
	}
	for entry in entries {
		path := relative == "" ? strings.clone(entry.name, context.temp_allocator) : foundation.join(relative, "/", entry.name)
		#partial switch entry.type {
		case .Directory:
			relative_files_collect(root, path, paths) or_return
		case .Regular, .Symlink:
			append(paths, path)
		}
	}
	return true
}

@(private = "file")
folder_of_path :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	return slash < 0 ? "." : path[:slash]
}

// The path of a boot volume relative to the build folder: a volume is named
// by its path in the build folder ("build/boot_volume.img").
@(private = "file")
build_relative_path :: proc(path: string) -> (relative: string, ok: bool) {
	prefix :: foundation.BUILD_FOLDER + "/"
	if !strings.has_prefix(path, prefix) {
		return "", false
	}
	return path[len(prefix):], true
}

// test_parts_names_text gives the names of the test parts, in the order of
// the table, as a JSON array: the flake makes one part derivation for each.
test_parts_names_text :: proc(parts: []Test_Part) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	for part, place in parts {
		if place > 0 {
			strings.write_byte(&b, ',')
		}
		foundation.json_string_write(&b, part.name)
	}
	strings.write_string(&b, "]\n")
	return strings.to_string(b)
}

// test_inputs_write copies the test inputs of the build folder into
// <target>/test_inputs, a new folder, and writes the names of the test
// parts into <target>/test_parts.json. It refuses a build that lacks a boot
// volume of a part: the inputs of every part come from one whole build.
test_inputs_write :: proc(target: string) -> bool {
	inputs_folder := foundation.join(target, "/", TEST_INPUTS_FOLDER_NAME)
	if os.exists(inputs_folder) {
		fmt.eprintfln("modustool: %s exists: the test inputs go to a new folder", inputs_folder)
		return false
	}
	paths := make([dynamic]string, context.temp_allocator)
	relative_files_collect(foundation.BUILD_FOLDER, "", &paths) or_return
	slice.sort(paths[:])
	kept := make(map[string]bool, allocator = context.temp_allocator)
	copied := 0
	copied_bytes: i64 = 0
	for path in paths {
		if !test_input_kept(path) {
			continue
		}
		source := foundation.join(foundation.BUILD_FOLDER, "/", path)
		copy_target := foundation.join(inputs_folder, "/", path)
		foundation.make_folder(folder_of_path(copy_target)) or_return
		if copy_error := os.copy_file(copy_target, source); copy_error != nil {
			fmt.eprintfln("modustool: cannot copy %s to %s: %v", source, copy_target, copy_error)
			return false
		}
		if information, stat_error := os.stat(copy_target, context.temp_allocator); stat_error == nil {
			copied_bytes += information.size
		}
		kept[path] = true
		copied += 1
	}
	// Each part finds in the inputs what it reads: this refusal comes in the
	// whole build, before any machine of any part starts.
	for part in test_parts {
		for volume in test_part_volumes_of(part) {
			relative, inside := build_relative_path(volume)
			if !inside || !kept[relative] {
				fmt.eprintfln("modustool: the build folder has no boot volume %s of the test part %s: the test inputs come from a whole build (`modustool build whole`)", volume, part.name)
				return false
			}
		}
		if problem := test_part_build_files_problem(part, kept); problem != "" {
			fmt.eprintfln("modustool: %s", problem)
			return false
		}
	}
	names_path := foundation.join(target, "/", TEST_PARTS_FILE_NAME)
	if write_error := os.write_entire_file(names_path, test_parts_names_text(test_parts[:])); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", names_path, write_error)
		return false
	}
	fmt.printfln("modustool: wrote %d test inputs to %s, and the names of %d test parts to %s", copied, inputs_folder, len(test_parts), names_path)
	fmt.printfln("modustool: measure: the test inputs: %d files, %d bytes", copied, copied_bytes)
	return true
}

// test_inputs_take makes the build folder of one part from a folder of
// test inputs: each boot volume and boot image is a link to the file of the
// folder, every other file is a copy that the part can write over. Then it
// notes the volumes of the part as ready, so a machine starts only from a
// volume that the folder holds. It refuses a build folder that exists, a
// volume of the part that the folder lacks and a file that is no test
// input, before it writes anything.
test_inputs_take :: proc(folder: string, part: Test_Part) -> bool {
	if os.exists(foundation.BUILD_FOLDER) {
		fmt.eprintfln("modustool: %s exists: a part on given test inputs starts from no build of its own", foundation.BUILD_FOLDER)
		return false
	}
	// A link names its target from the folder of the link: the path of the
	// folder of the inputs must not depend on where the link is.
	absolute_folder := folder
	if !strings.has_prefix(folder, "/") {
		working_folder, folder_error := os.get_working_directory(context.temp_allocator)
		if folder_error != nil {
			fmt.eprintfln("modustool: cannot read the working folder: %v", folder_error)
			return false
		}
		absolute_folder = foundation.join(working_folder, "/", folder)
	}
	volumes := test_part_volumes_of(part)
	for volume in volumes {
		relative, inside := build_relative_path(volume)
		if !inside || !os.exists(foundation.join(absolute_folder, "/", relative)) {
			fmt.eprintfln("modustool: %s has no boot volume %s of the test part %s", folder, volume, part.name)
			return false
		}
	}
	paths := make([dynamic]string, context.temp_allocator)
	relative_files_collect(absolute_folder, "", &paths) or_return
	volume_paths := test_parts_volume_paths()
	held := make(map[string]bool, allocator = context.temp_allocator)
	for path in paths {
		if !test_input_kept(path) {
			fmt.eprintfln("modustool: %s holds %s, which is no test input", folder, path)
			return false
		}
		held[path] = true
	}
	if problem := test_part_build_files_problem(part, held); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	for path in paths {
		source := foundation.join(absolute_folder, "/", path)
		target := foundation.join(foundation.BUILD_FOLDER, "/", path)
		foundation.make_folder(folder_of_path(target)) or_return
		if test_input_is_linked(path, volume_paths) {
			if link_error := os.symlink(source, target); link_error != nil {
				fmt.eprintfln("modustool: cannot link %s to %s: %v", target, source, link_error)
				return false
			}
			continue
		}
		if copy_error := os.copy_file(target, source); copy_error != nil {
			fmt.eprintfln("modustool: cannot copy %s to %s: %v", source, target, copy_error)
			return false
		}
		// A file of the store is read-only, and a copy keeps its mode.
		if mode_error := os.change_mode(target, os.perm(0o644)); mode_error != nil {
			fmt.eprintfln("modustool: cannot make %s writable: %v", target, mode_error)
			return false
		}
	}
	for volume in volumes {
		build.boot_volume_ready_note(volume)
	}
	fmt.printfln("modustool: the test part %s runs on the test inputs of %s: %d files, %d boot volumes of the part, no build", part.name, folder, len(paths), len(volumes))
	return true
}

// checks_passed_write writes the count of the checks that passed in this
// process.
checks_passed_write :: proc(count: int) -> bool {
	if write_error := os.write_entire_file(CHECKS_PASSED_FILE, fmt.tprintf("%d\n", count)); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CHECKS_PASSED_FILE, write_error)
		return false
	}
	return true
}

// checks_passed_of_text reads the count of a file of the checks that passed:
// one number of 0 or more, then the end of the line. The reader of a
// number takes a sign and `_` between digits: neither is a count.
checks_passed_of_text :: proc(text: string) -> (count: int, ok: bool) {
	trimmed := strings.trim_right(text, "\n")
	if trimmed == "" || strings.contains_any(trimmed, " \t\n+-_") {
		return 0, false
	}
	value, is_number := strconv.parse_int(trimmed, 10)
	if !is_number || value < 0 {
		return 0, false
	}
	return value, true
}

// One output that the join takes: the output of a part derivation, or of
// the host checks, whose part name is "".
Joined_Output :: struct {
	part:   string,
	folder: string,
}

// test_join_argument_read reads one argument `<part>=<folder>` of the join.
test_join_argument_read :: proc(argument: string) -> (joined: Joined_Output, problem: string) {
	equals := strings.index_byte(argument, '=')
	if equals <= 0 || equals == len(argument) - 1 {
		return {}, fmt.tprintf("`%s` is not <part>=<folder>", argument)
	}
	name := argument[:equals]
	if _, found := test_part_find(name); !found {
		return {}, fmt.tprintf("`%s` names no test part; the parts: %s", name, test_part_names())
	}
	return {part = name, folder = argument[equals + 1:]}, ""
}

// test_join_parts_problem gives the refusal of the outputs of a join, or
// "": each part of the list once, and no other part. The whole test is the
// list of the parts, so a join that lacks one would prove less than the
// whole test.
test_join_parts_problem :: proc(joined: []Joined_Output, part_names: []string) -> string {
	for name in part_names {
		count := 0
		for output in joined {
			if output.part == name {
				count += 1
			}
		}
		switch {
		case count == 0:
			return fmt.tprintf("the join has no output of the test part %s", name)
		case count > 1:
			return fmt.tprintf("the join has the test part %s %d times", name, count)
		}
	}
	for output in joined {
		if !slice.contains(part_names, output.part) {
			return fmt.tprintf("the join has the output of %s, which is no test part", output.part)
		}
	}
	return ""
}

// joined_file_name gives the name of a log of an output in the join: the
// file of the times of a part takes the name of its part, since each part
// writes one. The other names stay.
joined_file_name :: proc(part, name: string) -> string {
	times_file: string = TEST_TIMES_FILE
	times_name := times_file[strings.last_index_byte(times_file, '/') + 1:]
	if part != "" && name == times_name {
		return fmt.tprintf("test_times_%s.txt", part)
	}
	return name
}

// joined_file_copy copies one file into the join, and refuses a name that
// an earlier output of the join wrote: two parts that write one name would
// leave the file of whichever came last.
@(private = "file")
joined_file_copy :: proc(target, source, owner: string) -> bool {
	if os.exists(target) {
		fmt.eprintfln("modustool: %s writes %s, which an earlier output of the join wrote", owner, target)
		return false
	}
	bytes, read_error := os.read_entire_file(source, context.allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: cannot read %s: %v", source, read_error)
		return false
	}
	defer delete(bytes)
	if write_error := os.write_entire_file(target, bytes); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", target, write_error)
		return false
	}
	return true
}

// Counts of a join, for its line.
Join_Counts :: struct {
	pictures:      int,
	logs:          int,
	checks_passed: int,
}

// outputs_join joins the outputs into target, a new folder: the logs of each
// output in logs/ and the pictures in screenshots/, with the count of the
// checks of all in logs/checks_passed.txt. It refuses an output with no
// count of its checks and a file name that two outputs write. The caller
// checks the list of the parts first (test_join_parts_problem).
outputs_join :: proc(target: string, outputs: []Joined_Output) -> (counts: Join_Counts, ok: bool) {
	if os.exists(target) {
		fmt.eprintfln("modustool: %s exists: the join goes to a new folder", target)
		return {}, false
	}
	log_folder := foundation.join(target, "/", JOINED_LOG_FOLDER_NAME)
	picture_folder := foundation.join(target, "/", JOINED_PICTURE_FOLDER_NAME)
	foundation.make_folder(log_folder) or_return
	foundation.make_folder(picture_folder) or_return
	for output in outputs {
		owner := output.part == "" ? fmt.tprintf("the host checks (%s)", output.folder) : fmt.tprintf("the test part %s (%s)", output.part, output.folder)
		output_logs := foundation.join(output.folder, "/", JOINED_LOG_FOLDER_NAME)
		count_text, count_read := foundation.read_text_file_quiet(foundation.join(output_logs, "/", CHECKS_PASSED_FILE_NAME))
		count, count_ok := checks_passed_of_text(count_text)
		if !count_read || !count_ok {
			fmt.eprintfln("modustool: %s gives no count of its checks in %s/%s", owner, output_logs, CHECKS_PASSED_FILE_NAME)
			return {}, false
		}
		counts.checks_passed += count
		logs := foundation.files_with_suffix(output_logs, ".txt") or_return
		for log in logs {
			name := log[strings.last_index_byte(log, '/') + 1:]
			if name == CHECKS_PASSED_FILE_NAME {
				continue
			}
			joined_file_copy(foundation.join(log_folder, "/", joined_file_name(output.part, name)), log, owner) or_return
			counts.logs += 1
		}
		output_pictures := foundation.join(output.folder, "/", JOINED_PICTURE_FOLDER_NAME)
		if !os.exists(output_pictures) {
			continue
		}
		pictures := foundation.files_with_suffix(output_pictures, ".png") or_return
		for picture in pictures {
			name := picture[strings.last_index_byte(picture, '/') + 1:]
			joined_file_copy(foundation.join(picture_folder, "/", name), picture, owner) or_return
			counts.pictures += 1
		}
	}
	count_path := foundation.join(log_folder, "/", CHECKS_PASSED_FILE_NAME)
	if write_error := os.write_entire_file(count_path, fmt.tprintf("%d\n", counts.checks_passed)); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", count_path, write_error)
		return {}, false
	}
	return counts, true
}

// test_join is the command `test_join <target> <host checks> <part>=<folder>...`:
// the output of the check of the flake, from the output of the host checks
// and of each part derivation.
test_join :: proc(args: []string) -> bool {
	if len(args) < 2 {
		fmt.eprintln("modustool: test_join <target folder> <host checks folder> <part>=<folder> ...")
		return false
	}
	outputs := make([dynamic]Joined_Output, context.temp_allocator)
	append(&outputs, Joined_Output{part = "", folder = args[1]})
	for argument in args[2:] {
		output, problem := test_join_argument_read(argument)
		if problem != "" {
			fmt.eprintfln("modustool: %s", problem)
			return false
		}
		append(&outputs, output)
	}
	names := make([]string, len(test_parts), context.temp_allocator)
	for part, place in test_parts {
		names[place] = part.name
	}
	if problem := test_join_parts_problem(outputs[1:], names); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return false
	}
	counts := outputs_join(args[0], outputs[:]) or_return
	fmt.printfln("modustool: joined the host checks and %d test parts into %s: %d pictures, %d logs, %d checks passed", len(outputs) - 1, args[0], counts.pictures, counts.logs, counts.checks_passed)
	return true
}

// host_command_output runs a host process (Nix, git) and gives its standard
// output. Its standard error is printed only when the command fails.
@(private = "file")
host_command_output :: proc(command: []string) -> (output: string, ok: bool) {
	state, standard_output, standard_error, exec_error := os.process_exec({command = command}, context.temp_allocator)
	if exec_error != nil {
		fmt.eprintfln("modustool: cannot start %s: %v", command[0], exec_error)
		return "", false
	}
	if !state.exited || !state.success {
		fmt.eprintfln("modustool: %s failed:\n%s", strings.join(command, " ", context.temp_allocator), string(standard_error))
		return "", false
	}
	return string(standard_output), true
}

// text_map_of_json reads a JSON object whose values are texts, as Nix
// prints an attribute set of paths. Its memory is of the temporary
// allocator.
text_map_of_json :: proc(text: string) -> (texts: map[string]string, ok: bool) {
	value, parse_error := json.parse_string(text, allocator = context.temp_allocator)
	if parse_error != .None {
		return nil, false
	}
	object, is_object := value.(json.Object)
	if !is_object {
		return nil, false
	}
	texts = make(map[string]string, allocator = context.temp_allocator)
	for key, entry in object {
		entry_text, is_text := entry.(json.String)
		if !is_text {
			return nil, false
		}
		texts[key] = entry_text
	}
	return texts, true
}

// test_parts_in_store_count counts the part derivations of the check of the
// flake whose output is in the store of this host already, and those that
// the build of the check runs. The evaluation builds the test inputs first.
// A measure: a failure gives no count, and fails no command.
test_parts_in_store_count :: proc(flake_check_attribute: string) -> (in_store, to_run: int, ok: bool) {
	output := host_command_output({"nix", "eval", "--json", foundation.join(flake_check_attribute, ".partOutputs")}) or_return
	paths := text_map_of_json(output) or_return
	for _, path in paths {
		state, _, _, exec_error := os.process_exec({command = {"nix", "path-info", path}}, context.temp_allocator)
		if exec_error == nil && state.exited && state.success {
			in_store += 1
		} else {
			to_run += 1
		}
	}
	return in_store, to_run, true
}

// The changes of the proof of the cache: a line more in an intent file, and
// a line more in a host test of the tool. Neither is read by a machine.
PART_CACHE_FOLDER :: foundation.BUILD_FOLDER + "/part_cache"
PART_CACHE_DOCUMENT :: "src/md/infrastructure/full_check.md"
PART_CACHE_HOST_TEST :: "tools/modustool/machine/test_derivations_test.odin"

// One tree of the proof of the cache: its folder name, the file that it
// changes ("" for the tree with no change) and the line that it adds.
Part_Cache_Tree :: struct {
	name:  string,
	file:  string,
	line:  string,
	what:  string, // What the change is, for the lines of the check.
}

PART_CACHE_TREES :: [?]Part_Cache_Tree {
	{name = "unchanged"},
	{name = "document", file = PART_CACHE_DOCUMENT, line = "\nA line that the proof of the cache adds.\n", what = "a line more in an intent file"},
	{name = "host_test", file = PART_CACHE_HOST_TEST, line = "\n// A line that the proof of the cache adds.\n", what = "a line more in a host test of the tool"},
}

// part_derivations_compare gives the problems of a change that must leave
// the derivation of each part the same: a part that a tree lacks, a part
// that is not in the list, a part whose derivation differs, and a change
// that did not reach the whole build, which would prove nothing.
part_derivations_compare :: proc(unchanged, changed: map[string]string, part_names: []string, unchanged_build, changed_build, what: string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	if unchanged_build == "" || unchanged_build == changed_build {
		append(&problems, fmt.tprintf("after %s the whole build has the same derivation: the change did not reach the check, so it proves nothing", what))
	}
	for name in part_names {
		before, before_found := unchanged[name]
		after, after_found := changed[name]
		switch {
		case !before_found || !after_found:
			append(&problems, fmt.tprintf("the tree before or after %s has no derivation of the test part %s", what, name))
		case before == "" || before != after:
			append(&problems, fmt.tprintf("after %s the test part %s has another derivation: %s, then %s", what, name, before, after))
		}
	}
	for tree in ([2]map[string]string{unchanged, changed}) {
		for name in tree {
			if !slice.contains(part_names, name) {
				append(&problems, fmt.tprintf("a tree has the derivation of %s, which is no test part", name))
			}
		}
	}
	return problems[:]
}

// part_cache_tree_write copies the tracked files into a folder of the
// proof, then adds the line of its change.
@(private = "file")
part_cache_tree_write :: proc(tree: Part_Cache_Tree, tracked: []string) -> (folder: string, ok: bool) {
	folder = foundation.join(PART_CACHE_FOLDER, "/", tree.name)
	for path in tracked {
		target := foundation.join(folder, "/", path)
		foundation.make_folder(folder_of_path(target)) or_return
		if copy_error := os.copy_file(target, path); copy_error != nil {
			fmt.eprintfln("modustool: cannot copy %s to %s: %v (a tracked file that the work tree lacks?)", path, target, copy_error)
			return "", false
		}
	}
	if tree.file == "" {
		return folder, true
	}
	changed := foundation.join(folder, "/", tree.file)
	text := foundation.read_text_file(changed) or_return
	if write_error := os.write_entire_file(changed, foundation.join(text, tree.line)); write_error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", changed, write_error)
		return "", false
	}
	return folder, true
}

// part_cache_check is the command `part_cache`: three copies of the tracked
// files, one with no change, one with a line more in an intent file and one
// with a line more in a host test of the tool. Each test part must have the
// same derivation in the three, and the whole build another one in each
// changed tree. It compares derivation paths, never a time. Each evaluation
// builds the test inputs of its tree: two whole builds in all.
part_cache_check :: proc(flake_check_attribute: string) -> bool {
	listing := host_command_output({"git", "ls-files", "-z"}) or_return
	tracked := make([dynamic]string, context.temp_allocator)
	for path in strings.split(listing, "\x00", context.temp_allocator) {
		if path != "" {
			append(&tracked, path)
		}
	}
	if len(tracked) == 0 {
		fmt.eprintln("modustool: git lists no tracked file")
		return false
	}
	foundation.reset_folder(PART_CACHE_FOLDER) or_return
	working_folder, folder_error := os.get_working_directory(context.temp_allocator)
	if folder_error != nil {
		fmt.eprintfln("modustool: cannot read the working folder: %v", folder_error)
		return false
	}
	// The attribute without the flake: ".#checks..." gives "checks...".
	attribute := flake_check_attribute[strings.index_byte(flake_check_attribute, '#') + 1:]
	part_names := make([]string, len(test_parts), context.temp_allocator)
	for part, place in test_parts {
		part_names[place] = part.name
	}
	trees := PART_CACHE_TREES
	derivations: [len(PART_CACHE_TREES)]map[string]string
	builds: [len(PART_CACHE_TREES)]string
	for tree, place in trees {
		folder := part_cache_tree_write(tree, tracked[:]) or_return
		flake := foundation.join("path:", working_folder, "/", folder)
		fmt.printfln("modustool: the derivations of the tree %s (the evaluation builds its test inputs)", tree.name)
		output := host_command_output({"nix", "eval", "--json", foundation.join(flake, "#", attribute, ".partDerivations")}) or_return
		map_ok: bool
		derivations[place], map_ok = text_map_of_json(output)
		if !map_ok {
			fmt.eprintfln("modustool: the derivations of the parts of the tree %s are no object of texts: %s", tree.name, output)
			return false
		}
		build_derivation := host_command_output({"nix", "eval", "--raw", foundation.join(flake, "#", attribute, ".systemBuildDerivation")}) or_return
		builds[place] = strings.trim_space(build_derivation)
	}
	passed := true
	for tree, place in trees[1:] {
		problems := part_derivations_compare(derivations[0], derivations[place + 1], part_names, builds[0], builds[place + 1], tree.what)
		for problem in problems {
			fmt.eprintfln("modustool: test failed: %s", problem)
		}
		if len(problems) > 0 {
			passed = false
			continue
		}
		foundation.test_passed_print("after %s, each of the %d test parts has the same derivation, and the whole build another one", tree.what, len(part_names))
	}
	return passed
}
