// The build of a module whose source is outside the repository
// (docs/TOOLS.md, "A module from a source outside the repository"). The
// design is src/md/infrastructure/third_party_module.md.
//
// A developer has a folder with one Odin package and a module build file,
// module.txt, which holds the fields of a row of the module table. The
// command `module-build` fills one row from that file and runs the two
// steps of a module of the system on it (modules.odin, module_compile and
// module_convert): there is one build path. Three settings of the process
// say where the things of this build are: the folder of the outputs, the
// folder of the module files of the imports, and the folder of the source.
package build

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/blake3"
import info "modus:contract/boot_info"
import debug_object "modus:contract/debug_object"
import module "modus:contract/module"
import "modus:disk_process"
import "modustool:foundation"

// The name of the module build file, in the folder of the module.
MODULE_BUILD_FILE_NAME :: "module.txt"

// The environment variable that names the folder of the system. The
// command `modustool` of flake.nix reads it too, to find the sources of
// this tool: it runs before the tool reads an argument.
SYSTEM_FOLDER_VARIABLE :: "MODUS_SYSTEM"

// The folder of the outputs, in the folder of the module, when the
// command names none. The compiler reads the sources of one folder and
// not of the folders under it: the outputs are no sources.
OUTSIDE_MODULE_OUTPUT_FOLDER :: "build"

// The bytes of the name of a module, at most: an entry of a boot image
// holds the name with one zero byte after it.
MODULE_NAME_BYTES_MOST :: info.IMAGE_NAME_SIZE - 1

MODULE_BUILD_USAGE :: "modustool: module-build <folder of the module> [--system <folder of the system>] [--out <folder of the outputs>]"

// What a module build file says: the fields of a row of the module table
// that a developer chooses.
Module_Build_File :: struct {
	name:    string,
	imports: []string, // Names of modules of the system, in the order of the import table.
	defines: []string, // Settings of the compiler: NAME=value.
	library: bool, // The module is a library module.
}

// module_name_is_valid tells whether a text is a name of a module: lower
// case letters, digits and "_", with a bound of bytes.
module_name_is_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MODULE_NAME_BYTES_MOST {
		return false
	}
	for index in 0 ..< len(name) {
		switch name[index] {
		case 'a' ..= 'z', '0' ..= '9', '_':
		case:
			return false
		}
	}
	return true
}

// module_build_file_parse reads the text of a module build file. Each
// line that is not empty is `key: value`, each key at most one time. A
// line that the reader does not know is a fault: the tool guesses no
// field. problem is "" for a file that is read whole. The texts of the
// result are parts of `text` and memory of the temporary allocator.
module_build_file_parse :: proc(text: string) -> (file: Module_Build_File, problem: string) {
	Key :: enum {
		Name,
		Imports,
		Defines,
		Library,
	}
	key_names := [Key]string {
		.Name    = "name",
		.Imports = "imports",
		.Defines = "defines",
		.Library = "library",
	}
	seen: [Key]bool
	rest := text
	line_number := 0
	for whole_line in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(whole_line)
		if line == "" {
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			return {}, fmt.tprintf("line %d is not `key: value`", line_number)
		}
		written_key := line[:colon]
		value := strings.trim_space(line[colon + 1:])
		key: Key
		known := false
		for name, candidate in key_names {
			if name == written_key {
				key, known = candidate, true
			}
		}
		if !known {
			return {}, fmt.tprintf("line %d: the key %s is not known: the keys are name, imports, defines and library", line_number, written_key)
		}
		if seen[key] {
			return {}, fmt.tprintf("line %d: the key %s is written two times", line_number, written_key)
		}
		seen[key] = true
		switch key {
		case .Name:
			if !module_name_is_valid(value) {
				return {}, fmt.tprintf("line %d: %s is not a name of a module: a name has lower case letters, digits and _, and at most %d bytes", line_number, value, MODULE_NAME_BYTES_MOST)
			}
			file.name = value
		case .Imports:
			file.imports = strings.fields(value, context.temp_allocator)
			for name, place in file.imports {
				if !module_name_is_valid(name) {
					return {}, fmt.tprintf("line %d: %s is not a name of a module", line_number, name)
				}
				for earlier in file.imports[:place] {
					if earlier == name {
						return {}, fmt.tprintf("line %d: the import %s is written two times", line_number, name)
					}
				}
			}
		case .Defines:
			file.defines = strings.fields(value, context.temp_allocator)
			for define in file.defines {
				equal := strings.index_byte(define, '=')
				if equal <= 0 || equal == len(define) - 1 {
					return {}, fmt.tprintf("line %d: %s is not a setting of the compiler: write NAME=value", line_number, define)
				}
			}
		case .Library:
			switch value {
			case "yes":
				file.library = true
			case "no":
				file.library = false
			case:
				return {}, fmt.tprintf("line %d: the value of library is yes or no, not %s", line_number, value)
			}
		}
	}
	if !seen[.Name] {
		return {}, "the key name is absent"
	}
	return file, ""
}

// outside_source_path gives the path that a debug object keeps for a
// source of a module whose folder is outside the repository: the path
// from the folder that holds the folder of the module, so the name of
// that folder and no folder above it. is_outside is false for a path that
// is not under the folder.
outside_source_path :: proc(path, outside_folder: string) -> (recorded: string, is_outside: bool) {
	if outside_folder == "" || !strings.has_prefix(path, foundation.join(outside_folder, "/")) {
		return "", false
	}
	return path[strings.last_index_byte(outside_folder, '/') + 1:], true
}

// outside_module_source_has_a_place tells whether a source that the
// compiler read for an outside module is in one of the three places of
// such a source: the folder of the module or a folder under it, the
// source library of the system, the libraries of the compiler. Each path
// is absolute. compiler_folder is "" when the compiler did not say where
// its libraries are: the layout of the installation of the flake then
// names them.
outside_module_source_has_a_place :: proc(path, module_folder, library_folder, compiler_folder: string) -> bool {
	if strings.has_prefix(path, foundation.join(module_folder, "/")) || strings.has_prefix(path, foundation.join(library_folder, "/")) {
		return true
	}
	if compiler_folder != "" {
		return strings.has_prefix(path, foundation.join(compiler_folder, "/"))
	}
	return strings.contains(path, "/share/base/") || strings.contains(path, "/share/core/")
}

// outside_module_sources_hold reads the list that the compiler wrote for
// an outside module, and refuses a source that is in none of the three
// places. A relative import that leaves the folder of the module, an
// import of a folder of the system that is not its library, and a source
// library of another name each put such a file in the list. It runs
// between the two steps: no module file is written from such a source.
outside_module_sources_hold :: proc(build: foundation.Module_Build) -> bool {
	source_files, _, listed := dependency_list_read(module_dependency_file(build.name))
	if !listed {
		fmt.eprintfln("modustool: module-build: the list of the sources of the compiler cannot be read: the places of the sources of %s are not checked", build.name)
		return false
	}
	root, root_error := os.get_working_directory(context.temp_allocator)
	if root_error != nil {
		fmt.eprintfln("modustool: module-build: cannot read the folder of the system: %v", root_error)
		return false
	}
	// The compiler names a file where it is after each link; the folder
	// as the tool names it is a second form of the same folder.
	library_by_name := foundation.join(root, "/", foundation.SOURCE_FOLDER_PUBLIC)
	library_by_link := library_by_name
	if resolved, resolve_error := os.get_absolute_path(foundation.SOURCE_FOLDER_PUBLIC, context.temp_allocator); resolve_error == nil {
		library_by_link = resolved
	}
	compiler_folder := odin_root()
	hold := true
	for listed_path in source_files {
		path := listed_path
		if !strings.has_prefix(path, "/") {
			path = foundation.join(root, "/", path)
		}
		if outside_module_source_has_a_place(path, build.source, library_by_link, compiler_folder) || outside_module_source_has_a_place(path, build.source, library_by_name, compiler_folder) {
			continue
		}
		fmt.eprintfln("modustool: module-build: %s: the source %s is refused: a source of a module is in the folder of the module (%s) or under it, in the source library %s (%s), or in the libraries of the compiler. Remove the import that names its package", build.name, path, build.source, foundation.SOURCE_LIBRARY_NAME, foundation.SOURCE_FOLDER_PUBLIC)
		hold = false
	}
	return hold
}

// outside_module_build builds one module from a folder outside the
// repository, in a process whose working folder is the folder of the
// system. folder and out are absolute paths with their links resolved.
// It sets the settings of the build for the rest of the process.
outside_module_build :: proc(folder, out: string) -> bool {
	build_file_path := foundation.join(folder, "/", MODULE_BUILD_FILE_NAME)
	text, read_error := os.read_entire_file(build_file_path, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("modustool: module-build: cannot read %s: %v. The folder of a module holds a file %s with the line `name: <name of the module>`, and the lines imports, defines and library when the module needs them", build_file_path, read_error, MODULE_BUILD_FILE_NAME)
		return false
	}
	described, problem := module_build_file_parse(string(text))
	if problem != "" {
		fmt.eprintfln("modustool: module-build: %s: %s", build_file_path, problem)
		return false
	}
	for name in described.imports {
		of_the_system := false
		for row in foundation.module_builds {
			if row.name == name && !row.kernel {
				of_the_system = true
			}
		}
		if !of_the_system {
			fmt.eprintfln("modustool: module-build: %s: the import %s is not a module of the system", build_file_path, name)
			return false
		}
		if imported := foundation.join(foundation.MODULE_BUILD_FOLDER, "/", name, ".module"); !os.exists(imported) {
			fmt.eprintfln("modustool: module-build: %s: the import %s has no file %s in the folder of the system: build the system first, with `modustool build` in its folder", build_file_path, name, imported)
			return false
		}
	}
	// One row, as a row of the module table. It is a module that links the
	// assembly files of the system library, as each module of the boot
	// image: the link drops the procedures that the module does not call.
	build := foundation.Module_Build {
		name    = described.name,
		source  = folder,
		imports = described.imports,
		defines = described.defines,
		image   = true,
		library = described.library,
	}
	foundation.module_build_folder = out
	foundation.module_import_folder = foundation.MODULE_BUILD_FOLDER
	outside_source_folder = folder
	debug_information = true
	if !module_compile(build) || !outside_module_sources_hold(build) || !module_convert(build) {
		return false
	}
	return outside_module_report(build)
}

// outside_module_report prints what the build wrote: the module file with
// its hash, which is its identity, the debug object, the hash of each
// import, and the names of the exports.
outside_module_report :: proc(build: foundation.Module_Build) -> bool {
	file := foundation.read_file(foundation.module_path(build.name)) or_return
	object := foundation.read_file(debug_object_path(build.name)) or_return
	fmt.printfln("modustool: the module %s: %s, %d bytes, hash %s", build.name, foundation.module_path(build.name), len(file), hash_as_hexadecimal(blake3.hash(file)))
	fmt.printfln("modustool: the debug object of %s: %s, %d bytes", build.name, debug_object_path(build.name), len(object))
	for name, index in build.imports {
		imported, _ := module.record(file, .Imports, u32(index + 1), module.Import)
		fmt.printfln("modustool: the module %s imports %s, hash %s", build.name, name, hash_as_hexadecimal(imported.hash))
	}
	export_count := int(module.count(file, .Exports)) - 1
	if export_count <= 0 {
		fmt.printfln("modustool: the module %s has no export", build.name)
		return true
	}
	names := strings.builder_make(context.temp_allocator)
	for export_index in 1 ..< module.count(file, .Exports) {
		fmt.sbprintf(&names, "%s%s", export_index > 1 ? ", " : "", module_export_name(file, export_index))
	}
	fmt.printfln("modustool: the module %s has %d exports: %s", build.name, export_count, strings.to_string(names))
	return true
}

// The command module-build. It reads the two folders as the developer
// typed them, from the folder where the command runs, then moves the
// process to the folder of the system: each path of a source of the
// system in the tool is a path from that folder.
run_module_build :: proc(args: []string) -> int {
	folder_argument, out_argument := "", ""
	system_argument := os.get_env(SYSTEM_FOLDER_VARIABLE, context.temp_allocator)
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch {
		case argument == "--system" || argument == "--out":
			if index + 1 >= len(args) {
				fmt.eprintln(MODULE_BUILD_USAGE)
				return foundation.EXIT_USAGE
			}
			if argument == "--system" {
				system_argument = args[index + 1]
			} else {
				out_argument = args[index + 1]
			}
			index += 1
		case strings.has_prefix(argument, "--") || folder_argument != "":
			fmt.eprintln(MODULE_BUILD_USAGE)
			return foundation.EXIT_USAGE
		case:
			folder_argument = argument
		}
	}
	if folder_argument == "" {
		fmt.eprintln(MODULE_BUILD_USAGE)
		return foundation.EXIT_USAGE
	}
	// With each link resolved: the compiler names a source where it is
	// after each link, and the tool compares its paths with this one.
	folder, folder_error := os.get_absolute_path(folder_argument, context.temp_allocator)
	if folder_error != nil || !os.is_dir(folder) {
		fmt.eprintfln("modustool: module-build: %s is not a folder", folder_argument)
		return foundation.EXIT_USAGE
	}
	out_typed := out_argument
	if out_typed == "" {
		out_typed = foundation.join(folder, "/", OUTSIDE_MODULE_OUTPUT_FOLDER)
	}
	if !foundation.make_folder(out_typed) {
		return foundation.EXIT_FAILURE
	}
	out, out_error := os.get_absolute_path(out_typed, context.temp_allocator)
	if out_error != nil {
		fmt.eprintfln("modustool: module-build: cannot find the folder of the outputs %s: %v", out_typed, out_error)
		return foundation.EXIT_FAILURE
	}
	if system_argument != "" {
		if move_error := os.set_working_directory(system_argument); move_error != nil {
			fmt.eprintfln("modustool: module-build: cannot enter the folder of the system %s: %v", system_argument, move_error)
			return foundation.EXIT_USAGE
		}
	}
	if !os.is_dir(foundation.SOURCE_FOLDER_PUBLIC) || !os.exists(RUNTIME_MEMORY) {
		system_folder, _ := os.get_working_directory(context.temp_allocator)
		fmt.eprintfln("modustool: module-build: %s is not the folder of the system: it has no %s or no %s. Name the folder of the system with --system, or with the environment variable %s", system_folder, foundation.SOURCE_FOLDER_PUBLIC, RUNTIME_MEMORY, SYSTEM_FOLDER_VARIABLE)
		return foundation.EXIT_USAGE
	}
	return outside_module_build(folder, out) ? 0 : foundation.EXIT_FAILURE
}

// The proof of the build of an outside module in `modustool check`
// (docs/TOOLS.md, "A module from a source outside the repository"). Each
// example is a module of the system: the tool copies its sources with no
// change to a folder outside the sources, writes the module build file,
// and starts itself as a second process in the folder of the copy. So
// the check passes the path that a developer types.
Outside_Module_Example :: struct {
	name:       string, // The module of the system whose sources are copied; the folder of the copy has this name.
	source:     string,
	build_file: string, // The text of the module build file of the copy.
}

THIRD_PARTY_EXAMPLE_FOLDER :: foundation.BUILD_FOLDER + "/third_party_example"

// A module with an entry and no import, and a module with an import: the second
// needs the file of its import from the folder of the system while its
// own file goes to the folder of the copy.
OUTSIDE_MODULE_EXAMPLES :: [?]Outside_Module_Example {
	{name = "tally", source = foundation.DEMONSTRATION_MODULE_SOURCES + "tally", build_file = "name: tally\n"},
	{name = "agenda", source = foundation.DEMONSTRATION_MODULE_SOURCES + "agenda", build_file = "name: agenda\nimports: calendar\nlibrary: no\n"},
}

outside_module_examples_check :: proc() -> bool {
	// The binary of this process, not the wrapper of the shell, which builds
	// the tool again.
	tool_path := foundation.tool_executable_path() or_return
	system_folder, folder_error := os.get_working_directory(context.temp_allocator)
	if folder_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read the folder of the system: %v", folder_error)
		return false
	}
	examples := OUTSIDE_MODULE_EXAMPLES
	for example in examples {
		outside_module_example_check(tool_path, system_folder, example) or_return
	}
	return true
}

// outside_module_example_build copies the sources of an example to its
// folder outside the sources, writes its module build file, and builds it
// as a developer does: the tool, started in that folder, with the folder
// of the system as an argument. It gives the folder.
outside_module_example_build :: proc(tool_path, system_folder: string, example: Outside_Module_Example) -> (folder: string, ok: bool) {
	folder = foundation.join(THIRD_PARTY_EXAMPLE_FOLDER, "/", example.name)
	foundation.reset_folder(folder) or_return
	sources := foundation.files_with_suffix(example.source, ".odin") or_return
	assembly := foundation.files_with_suffix(example.source, ".asm") or_return
	if len(sources) == 0 {
		fmt.eprintfln("modustool: test failed: %s has no source file", example.source)
		return "", false
	}
	for list in ([2][]string{sources, assembly}) {
		for source in list {
			copied_file := foundation.join(folder, source[strings.last_index_byte(source, '/'):])
			if copy_error := os.copy_file(copied_file, source); copy_error != nil {
				fmt.eprintfln("modustool: test failed: cannot copy %s to %s: %v", source, copied_file, copy_error)
				return "", false
			}
		}
	}
	build_file_path := foundation.join(folder, "/", MODULE_BUILD_FILE_NAME)
	if write_error := os.write_entire_file(build_file_path, example.build_file); write_error != nil {
		fmt.eprintfln("modustool: test failed: cannot write %s: %v", build_file_path, write_error)
		return "", false
	}
	// As a developer types it: in the folder of the module, with the
	// folder of the system as an argument.
	command := [?]string{tool_path, "module-build", ".", "--system", system_folder}
	state, standard_output, standard_error, start_error := os.process_exec({working_dir = folder, command = command[:]}, context.temp_allocator)
	os.write(os.stdout, standard_output)
	os.write(os.stderr, standard_error)
	if start_error != nil || !state.exited || !state.success {
		fmt.eprintfln("modustool: test failed: `module-build . --system %s` in %s did not build the module %s", system_folder, folder, example.name)
		return "", false
	}
	return folder, true
}

@(private = "file")
outside_module_example_check :: proc(tool_path, system_folder: string, example: Outside_Module_Example) -> bool {
	folder := outside_module_example_build(tool_path, system_folder, example) or_return
	sources := foundation.files_with_suffix(example.source, ".odin") or_return
	out := foundation.join(folder, "/", OUTSIDE_MODULE_OUTPUT_FOLDER)
	built := foundation.read_file(foundation.join(out, "/", example.name, ".module")) or_return
	if load_error := module.validate(built); load_error != .None {
		fmt.eprintfln("modustool: test failed: the loader refuses the module %s that was built from %s: %v", example.name, folder, load_error)
		return false
	}
	// The module of the system from the same sources: the same exports
	// with the same call forms, and the same line of documentation.
	of_the_system := foundation.read_file(foundation.module_path(example.name)) or_return
	export_count := module.count(built, .Exports)
	if export_count != module.count(of_the_system, .Exports) {
		fmt.eprintfln("modustool: test failed: the module %s that was built from %s has %d exports, the module of the system has %d", example.name, folder, int(export_count) - 1, int(module.count(of_the_system, .Exports)) - 1)
		return false
	}
	for export_index in 1 ..< export_count {
		built_form, built_readable := call_form_of_export(built, export_index)
		system_form, system_readable := call_form_of_export(of_the_system, export_index)
		if !built_readable || !system_readable || module_export_name(built, export_index) != module_export_name(of_the_system, export_index) || call_forms_difference(built_form, system_form) != "" {
			fmt.eprintfln("modustool: test failed: export %d of the module %s that was built from %s is not the export %s of the module of the system", export_index, example.name, folder, module_export_name(of_the_system, export_index))
			return false
		}
	}
	built_about, _ := module.documentation(built)
	system_about, _ := module.documentation(of_the_system)
	if built_about != system_about {
		fmt.eprintfln("modustool: test failed: the module %s that was built from %s has another line of documentation than the module of the system", example.name, folder)
		return false
	}
	// The import table names the file of each import of the build of the
	// system, in the order of the row of the module table.
	imports: []string
	for row in foundation.module_builds {
		if row.name == example.name {
			imports = row.imports
		}
	}
	if int(module.count(built, .Imports)) != len(imports) + 1 {
		fmt.eprintfln("modustool: test failed: the module %s that was built from %s has %d imports, its row of the module table has %d", example.name, folder, int(module.count(built, .Imports)) - 1, len(imports))
		return false
	}
	for name, index in imports {
		imported, _ := module.record(built, .Imports, u32(index + 1), module.Import)
		import_file := foundation.read_file(foundation.module_path(name)) or_return
		if imported.hash != blake3.hash(import_file) {
			fmt.eprintfln("modustool: test failed: import %d of the module %s that was built from %s does not name the hash of %s", index + 1, example.name, folder, foundation.module_path(name))
			return false
		}
	}
	// The debug object: no path of the host, and the sources of the copy
	// by the name of its folder.
	object := foundation.read_file(foundation.join(out, "/", example.name, ".debug")) or_return
	parts, fault := debug_object.tables(object)
	if fault != .None {
		fmt.eprintfln("modustool: test failed: the debug object of the module %s that was built from %s is refused: %s", example.name, folder, debug_object.fault_sentences[fault])
		return false
	}
	named_sources := 0
	for file in parts.files[min(1, len(parts.files)):] {
		path := debug_object.text_of(parts.strings, file.path_offset, file.path_count)
		if strings.has_prefix(path, "/") {
			fmt.eprintfln("modustool: test failed: the debug object of the module %s that was built from %s names the source %s by a path of the host", example.name, folder, path)
			return false
		}
		if strings.has_prefix(path, foundation.join(example.name, "/")) {
			named_sources += 1
		}
	}
	if named_sources == 0 {
		fmt.eprintfln("modustool: test failed: the debug object of the module %s that was built from %s names no source as %s/<file>", example.name, folder, example.name)
		return false
	}
	// A fact, not a condition: the path of a package can change the order
	// of its procedures, so the two files can differ with the same
	// procedures (src/md/infrastructure/third_party_module.md).
	built_hash := blake3.hash(built)
	system_hash := blake3.hash(of_the_system)
	foundation.test_passed_print(
		"the module %s, built by `module-build` from a copy of the %d source files of %s in %s: the loader accepts it, its %d exports have the names and the call forms of the module of the system, its import table names the hash of each of its %d imports, and its debug object names %d of its sources from the folder %s; its hash is %s, the hash of the module of the system is %s: %s",
		example.name,
		len(sources),
		example.source,
		folder,
		int(export_count) - 1,
		len(imports),
		named_sources,
		example.name,
		hash_as_hexadecimal(built_hash),
		hash_as_hexadecimal(system_hash),
		built_hash == system_hash ? "the same bytes" : "not the same bytes; the path of a package can change the order of its procedures",
	)
	return true
}

// The name of the outside module that the test of the disk processes starts
// in a machine: the sources of the module visitor, copied outside the
// sources and built by `module-build` under this name, which is no module
// of the boot image.
OUTSIDE_DISK_MODULE :: "outsider"

// The name of a second module from the same copy, built with one more
// setting: it writes to the address 0 after its start, and the test reads
// its stop report. Its folder is the folder of the copy, so its debug
// object names its sources from the folder `outsider` too.
OUTSIDE_FAULT_MODULE :: "outsider_fault"

// outside_module_for_a_disk builds that module as a developer does, and
// gives its file and its debug object. With `faults`, it builds the module
// OUTSIDE_FAULT_MODULE from the same folder. The folder is written again
// at each build: the bytes that a build gave are read before the next one.
outside_module_for_a_disk :: proc(faults := false) -> (file: []u8, debug_file: []u8, ok: bool) {
	tool_path := foundation.tool_executable_path() or_return
	system_folder, folder_error := os.get_working_directory(context.temp_allocator)
	if folder_error != nil {
		fmt.eprintfln("modustool: test failed: cannot read the folder of the system: %v", folder_error)
		return nil, nil, false
	}
	module_name := faults ? OUTSIDE_FAULT_MODULE : OUTSIDE_DISK_MODULE
	build_file := faults ? "name: " + OUTSIDE_FAULT_MODULE + "\ndefines: BUILT_OUTSIDE=true FAULTS_AFTER_THE_START=true\n" : "name: " + OUTSIDE_DISK_MODULE + "\ndefines: BUILT_OUTSIDE=true\n"
	example := Outside_Module_Example{name = OUTSIDE_DISK_MODULE, source = foundation.TEST_MODULE_SOURCES + foundation.DISK_MODULE_NAME, build_file = build_file}
	folder := outside_module_example_build(tool_path, system_folder, example) or_return
	out := foundation.join(folder, "/", OUTSIDE_MODULE_OUTPUT_FOLDER, "/", module_name)
	file = foundation.read_file(foundation.join(out, ".module")) or_return
	debug_file = foundation.read_file(foundation.join(out, ".debug")) or_return
	return file, debug_file, true
}

// The command module-disk: it writes a data disk whose store `module_files`
// holds module files, each under the name of its file, and the debug
// object of each one that has the file `<name>.debug` beside it, under the
// hash of the module. A machine with that disk starts each one with
// `start_from_disk` and its hash, which the command prints; the debugger
// names its procedures and its lines. It writes no disk over a file that
// exists: a data disk holds the stores of a principal.
run_module_disk :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.eprintln("modustool: module-disk <disk file to write> <module file> [<module file> ...]")
		return foundation.EXIT_USAGE
	}
	disk := args[0]
	if os.exists(disk) {
		fmt.eprintfln("modustool: module-disk: %s exists, and a data disk holds the stores of a principal: remove it, or name another file", disk)
		return foundation.EXIT_USAGE
	}
	files := make([dynamic]Module_File, context.temp_allocator)
	for path in args[1:] {
		bytes, read := foundation.read_file(path)
		if !read {
			return foundation.EXIT_FAILURE
		}
		if load_error := module.validate(bytes); load_error != .None {
			fmt.eprintfln("modustool: module-disk: %s is not a module file that the loader takes: %v", path, load_error)
			return foundation.EXIT_FAILURE
		}
		name := path
		if slash := strings.last_index_byte(name, '/'); slash >= 0 {
			name = name[slash + 1:]
		}
		name = strings.trim_suffix(name, ".module")
		append(&files, Module_File{name = name, bytes = bytes})
		// The debug object that module-build wrote beside the module file
		// goes beside it in the store, named by the hash of the module.
		debug_path := foundation.join(strings.trim_suffix(path, ".module"), ".debug")
		if !os.exists(debug_path) {
			fmt.printfln("modustool: module-disk: %s has no debug object beside it: the debugger names no procedure of %s", path, name)
			continue
		}
		object, object_read := foundation.read_file(debug_path)
		if !object_read {
			return foundation.EXIT_FAILURE
		}
		debug_file, accepted := module_debug_object_file(name, bytes, object)
		if !accepted {
			return foundation.EXIT_FAILURE
		}
		append(&files, debug_file)
	}
	if !module_disk_write(disk, files[:]) {
		return foundation.EXIT_FAILURE
	}
	for file in files {
		if disk_process.debug_object_name_is(file.name) {
			continue
		}
		digits: [disk_process.HASH_DIGITS]u8
		disk_process.hash_write(&digits, blake3.hash(file.bytes))
		fmt.printfln("modustool: in the console of a machine with this disk: start_from_disk(\"%s\", \"%s\")", file.name, string(digits[:]))
	}
	return 0
}
