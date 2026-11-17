// The check of the imports of the sources of the system
// (docs/TOOLS.md, "The imports of the sources of the system").
//
// The system has one source library, so the compiler accepts each of its
// packages in each source: an import of a support package compiles in the
// kernel. The tool holds the rule of each folder, from the imports of each
// source file of src/. Each rule has its reason:
//
//   - A source that is not a test imports a package of base: or of modus:
//     only, and no package of core:, which reaches the host. The files that
//     the manifest of the cryptography of Odin names are the one exception,
//     below.
//   - The kernel imports the contract packages and its kernel parts only,
//     and a contract package imports no support package. A chain of imports
//     from the kernel then reaches no support package.
//   - A kernel part ("kernel:iommu", a folder under src/kernel) is imported
//     from src/kernel only. The compiler already refuses it in a module,
//     which gets no flag of the kernel parts; the check refuses it in each
//     other file of src/ too, because a language server gives one set of
//     source libraries to every folder and then compiles the import.
//   - A test that imports a package of core: runs on the host: its first
//     build line is "#+build !freestanding", so that no build of the system
//     reads it. A test, and a file of the copy, may also import a relative
//     path, which reaches a folder of the repository that has no name in the
//     library.
//
// src/library/support/cryptography/origin.manifest names the files that the
// system took from the cryptography of Odin. They keep the imports of their
// origin, and `modustool cryptography-origin` proves that nothing else
// changed.
//
// The reader is the parser of the library of the compiler. It reads each
// file of src/, a test and a file that a build tag leaves out too, and an
// import inside a `when` whatever its condition: the check is stricter than
// the compiler, never looser.
package modustool

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"

// The starts of the paths of the packages that a source of src/ may import.
// A test runs on the host, and the copy of the cryptography of Odin keeps
// the imports of its origin: both may import a package of the core library.
LIBRARY_IMPORT_BASE_START :: "base:"
LIBRARY_IMPORT_CORE_START :: "core:"

// The build line of a host test: the compiler builds the file for the host
// only, and no build of the system reads it.
LIBRARY_HOST_BUILD_LINE :: "#+build !freestanding"

// The architectures whose host tests the check reads: a test of one
// architecture ends in "_test_<arch>.odin". A name of another architecture
// is read as a source, and the check then refuses its import of core:; add
// the architecture here with the first test of it.
LIBRARY_TEST_ARCHITECTURES :: [?]string{"amd64", "arm64"}

// The folder of src/ that a file is in: the kernel and the contract packages
// import the contract packages only, the kernel its kernel parts too, and a
// source of another folder imports each part of the library.
Library_Source_Kind :: enum {
	Kernel, // src/kernel and each kernel part under it.
	Contract,
	System,
}

// What a checked file is, which the rule of its imports follows.
Library_Source_Form :: struct {
	kind: Library_Source_Kind,
	test: bool, // A host test: its name ends in "_test.odin" or in "_test_<arch>.odin".
	copy: bool, // A file that src/library/support/cryptography/origin.manifest names.
}

// Why the check refuses a file or an import of it.
Library_Import_Breach_Reason :: enum {
	Unreadable_File, // The parser does not read the file whole, so an import of it can be unread.
	Refused_Import, // The import names a package that the rule of the file refuses.
	Test_Without_Build_Line, // A test imports a package of core: and has no build line of the host.
}

// One refused import, one test without its build line, or one file that the
// parser cannot read whole.
Library_Import_Breach :: struct {
	file: string,
	line: int, // 0: the parser refuses the file.
	text: string, // The import as the source writes it, with its quotes. "": the parser refuses the file.
	reason: Library_Import_Breach_Reason,
	form: Library_Source_Form,
}

// The result of the check on a tree: each breach, and the count of each kind
// of file that the check read.
Library_Import_Reading :: struct {
	breaches: [dynamic]Library_Import_Breach,
	source_count: int, // A source of src/ that is not a test and not a copy.
	test_count: int, // A host test of src/.
	copy_count: int, // A file of the copy of the cryptography of Odin.
	import_count: int,
}

// library_source_is_a_test says if the name of a file says that it is a host
// test: it ends in "_test.odin", or in "_test_<arch>.odin" (AGENTS.md,
// "Iteration And Tests").
library_source_is_a_test :: proc(file: string) -> bool {
	name := file
	if slash := strings.last_index(file, "/"); slash >= 0 {
		name = file[slash + 1:]
	}
	if strings.has_suffix(name, "_test.odin") {
		return true
	}
	if !strings.has_suffix(name, ".odin") {
		return false
	}
	stem := name[:len(name) - len(".odin")]
	at := strings.last_index(stem, "_test_")
	if at < 0 {
		return false
	}
	architecture := stem[at + len("_test_"):]
	known := LIBRARY_TEST_ARCHITECTURES
	for name_of_architecture in known {
		if architecture == name_of_architecture {
			return true
		}
	}
	return false
}

// library_source_kind_of gives the folder of src/ that a path names, as a
// path from the root of the tree.
library_source_kind_of :: proc(file: string) -> Library_Source_Kind {
	switch {
	case strings.has_prefix(file, SOURCE_FOLDER_KERNEL + "/"):
		return .Kernel
	case strings.has_prefix(file, SOURCE_FOLDER_CONTRACT + "/"):
		return .Contract
	}
	return .System
}

// library_source_relative_to_root gives the path of a file as a manifest of
// the repository names it: from the root of the tree.
library_source_relative_to_root :: proc(root, file: string) -> string {
	if root == "" {
		return file
	}
	prefix := strings.concatenate({root, "/"}, context.temp_allocator)
	if strings.has_prefix(file, prefix) {
		return file[len(prefix):]
	}
	return file
}

// library_source_path gives the path of a file of the tree to read, from a
// path of the repository.
library_source_path :: proc(root, file: string) -> string {
	if root == "" {
		return file
	}
	return strings.concatenate({root, "/", file}, context.temp_allocator)
}

// library_import_names_a_package_under says if the path of an import names a
// package under a start. The path is longer than the start: an import of
// "core:" alone names no package.
library_import_names_a_package_under :: proc(path, start: string) -> bool {
	return len(path) > len(start) && strings.has_prefix(path, start)
}

// library_import_is_allowed says whether the path of an import, with no
// quotes, names a package that a file of the form may import. A path with
// ".." after the name of a library is refused:
// "modus:contract/../support/system" starts as a contract package and names
// a support package.
library_import_is_allowed :: proc(path: string, form: Library_Source_Form) -> bool {
	if path == "" {
		return false
	}
	// A relative path names a folder of the repository. A host test and a
	// file of the copy may reach a package that has no name in the library,
	// as a module of src/modules.
	if strings.has_prefix(path, "./") || strings.has_prefix(path, "../") {
		return form.copy || (form.test && form.kind == .System)
	}
	if strings.contains(path, "..") {
		return false
	}
	if library_import_names_a_package_under(path, LIBRARY_IMPORT_BASE_START) {
		return true
	}
	if form.copy {
		if library_import_names_a_package_under(path, SOURCE_LIBRARY_IMPORT_START) {
			return true
		}
		return library_import_names_a_package_under(path, LIBRARY_IMPORT_CORE_START)
	}
	library_start := form.kind == .System ? SOURCE_LIBRARY_IMPORT_START : CONTRACT_IMPORT_START
	if library_import_names_a_package_under(path, library_start) {
		return true
	}
	// "kernel:" alone names the package of the kernel itself, which no
	// file imports: a kernel part names its folder.
	if form.kind == .Kernel && library_import_names_a_package_under(path, KERNEL_IMPORT_START) {
		return true
	}
	return form.test && library_import_names_a_package_under(path, LIBRARY_IMPORT_CORE_START)
}

// library_import_rule_words gives the rule of a file, as the message of a
// refusal states it. It is the same rule that library_import_is_allowed
// applies, so that a reader of the message reads the rule that was refused.
library_import_rule_words :: proc(form: Library_Source_Form) -> string {
	if form.copy {
		return "a file of the copy of the cryptography of Odin keeps the imports of its origin: a package of base:, of " + SOURCE_LIBRARY_IMPORT_START + ", of core:, or a relative path of the copy"
	}
	if form.kind == .Kernel {
		if form.test {
			return "a test of " + SOURCE_FOLDER_KERNEL + " imports a package of base:, of core:, under " + CONTRACT_IMPORT_START + " or under " + KERNEL_IMPORT_START + ", by a path with no \"..\"; the kernel imports no support package"
		}
		return "a source of " + SOURCE_FOLDER_KERNEL + " imports a package of base:, under " + CONTRACT_IMPORT_START + " or under " + KERNEL_IMPORT_START + ", by a path with no \"..\"; the kernel imports no support package"
	}
	if form.kind == .Contract {
		if form.test {
			return "a test of " + SOURCE_FOLDER_CONTRACT + " imports a package of base:, of core: or under " + CONTRACT_IMPORT_START + ", by a path with no \"..\"; a contract package imports no support package"
		}
		return "a source of " + SOURCE_FOLDER_CONTRACT + " imports a package of base: or under " + CONTRACT_IMPORT_START + ", by a path with no \"..\"; a contract package imports no support package"
	}
	if form.test {
		return "a test of src/ imports a package of base:, of core: or of " + SOURCE_LIBRARY_IMPORT_START + ", or a relative path of the repository, by a path with no \"..\" after the name of a library; a kernel part (" + KERNEL_IMPORT_START + ") is imported from " + SOURCE_FOLDER_KERNEL + " only"
	}
	return "a source of src/ that is not a test imports a package of base: or of " + SOURCE_LIBRARY_IMPORT_START + ", by a path with no \"..\"; a kernel part (" + KERNEL_IMPORT_START + ") is imported from " + SOURCE_FOLDER_KERNEL + " only"
}

// library_source_has_host_build_line says if the first build line of a
// source is the build line of the host. A line after the package clause is
// not a build line.
library_source_has_host_build_line :: proc(source: string) -> bool {
	for line in strings.split_lines(source, context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "//") {
			continue
		}
		if strings.has_prefix(trimmed, "#+build") {
			if !strings.has_prefix(trimmed, LIBRARY_HOST_BUILD_LINE) {
				return false
			}
			// Another tag after a comma would allow a build that is
			// freestanding: the line is the line of the host alone.
			rest := strings.trim_space(trimmed[len(LIBRARY_HOST_BUILD_LINE):])
			return rest == "" || strings.has_prefix(rest, "//")
		}
		if strings.has_prefix(trimmed, "#+") {
			continue
		}
		return false
	}
	return false
}

// library_import_breaches_of_source gives each refused import of one source
// file, and the test without its build line. A file with an error of syntax
// is one breach: the parser does not read it whole, so an import of it can
// be unread. An import inside a procedure is such an error.
library_import_breaches_of_source :: proc(file, source: string, form: Library_Source_Form) -> (breaches: []Library_Import_Breach, import_count: int) {
	list := make([dynamic]Library_Import_Breach, context.temp_allocator)
	// The tree of the parser lives in an arena of its own, freed before
	// the next file: a breach keeps only copies of its texts.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		append(&list, Library_Import_Breach{file = file, reason = .Unreadable_File, form = form})
		return list[:], 0
	}
	defer virtual.arena_destroy(&arena)
	{
		context.allocator = virtual.arena_allocator(&arena)
		tree := ast.new_from_positions(ast.File, {}, {})
		tree.src = source
		tree.fullpath = file
		reader := parser.default_parser()
		// The check reports a file that the parser refuses in its own words.
		reader.err = site_code_quiet_error
		reader.warn = site_code_quiet_error
		if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
			append(&list, Library_Import_Breach{file = file, reason = .Unreadable_File, form = form})
			return list[:], 0
		}
		import_count = len(tree.imports)
		for declaration in tree.imports {
			text := declaration.relpath.text
			if library_import_is_allowed(strings.trim(text, "\"`"), form) {
				continue
			}
			append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator), reason = .Refused_Import, form = form})
		}
		// One breach names the file: the line that the writer adds is the
		// first line of the file, whatever the count of its imports of core:.
		if form.test && !library_source_has_host_build_line(source) {
			for declaration in tree.imports {
				text := declaration.relpath.text
				if !strings.has_prefix(strings.trim(text, "\"`"), LIBRARY_IMPORT_CORE_START) {
					continue
				}
				append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator), reason = .Test_Without_Build_Line, form = form})
				break
			}
		}
	}
	return list[:], import_count
}

// library_import_breaches_of_tree reads each source file of src/ of a tree.
// root is the folder of the tree: "" is the folder where the tool runs, the
// root of the repository. The manifest of the cryptography of Odin of the
// tree names the files that the check reads with the rule of a copy.
library_import_breaches_of_tree :: proc(root: string) -> (reading: Library_Import_Reading, ok: bool) {
	paths := make([dynamic]string, context.temp_allocator)
	folders := SOURCE_FOLDERS
	for folder in folders {
		source_files_of_a_folder(root == "" ? folder : join(root, "/", folder), &paths) or_return
	}
	files := make([dynamic]string, context.temp_allocator)
	for path in paths {
		append(&files, library_source_relative_to_root(root, path))
	}
	slice.sort(files[:])
	copied := make(map[string]bool, context.temp_allocator)
	manifest := root == "" ? CRYPTOGRAPHY_MANIFEST : join(root, "/", CRYPTOGRAPHY_MANIFEST)
	lines, manifest_ok := manifest_lines(manifest)
	if !manifest_ok {
		return {}, false
	}
	for parts in lines {
		if len(parts) > 0 {
			copied[parts[0]] = true
		}
	}
	reading.breaches = make([dynamic]Library_Import_Breach, context.temp_allocator)
	for file in files {
		source, read_ok := site_read_quiet(library_source_path(root, file))
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return {}, false
		}
		form := Library_Source_Form {
			kind = library_source_kind_of(file),
			test = library_source_is_a_test(file),
			copy = file in copied,
		}
		file_breaches, file_imports := library_import_breaches_of_source(file, source, form)
		append(&reading.breaches, ..file_breaches)
		reading.import_count += file_imports
		switch {
		case form.copy:
			reading.copy_count += 1
		case form.test:
			reading.test_count += 1
		case:
			reading.source_count += 1
		}
	}
	return reading, true
}

// library_import_breach_sentence gives the line of the output for one
// breach: the file and the line first, as the compiler writes an error.
library_import_breach_sentence :: proc(breach: Library_Import_Breach) -> string {
	switch breach.reason {
	case .Unreadable_File:
		return fmt.tprintf("%s: the parser cannot read the file whole, so its imports are not checked: a source of src/ has no error of syntax, and no import inside a procedure", breach.file)
	case .Test_Without_Build_Line:
		return fmt.tprintf("%s:%d: the test imports %s and has no build line: a test of src/ that imports a package of core: starts with %q, so that no build of the system reads it", breach.file, breach.line, breach.text, LIBRARY_HOST_BUILD_LINE)
	case .Refused_Import:
		return fmt.tprintf("%s:%d: the import %s is refused: %s", breach.file, breach.line, breach.text, library_import_rule_words(breach.form))
	}
	return ""
}

// library_imports_hold reads the repository and prints each breach. Each
// build calls it before its first compiler starts: the build stops with
// the file and the line, as it stopped when the compiler refused the
// import.
library_imports_hold :: proc() -> (reading: Library_Import_Reading, hold: bool) {
	found, read_ok := library_import_breaches_of_tree("")
	if !read_ok {
		return {}, false
	}
	for breach in found.breaches {
		fmt.eprintfln("modustool: %s", library_import_breach_sentence(breach))
	}
	return found, len(found.breaches) == 0
}

// library_imports_check is the check of `modustool check` and of the
// command `library-imports`.
library_imports_check :: proc() -> bool {
	reading, hold := library_imports_hold()
	if !hold {
		fmt.eprintln("modustool: test failed: an import of a source of src/, or the build line of a host test, is refused")
		return false
	}
	test_passed_print("each of the %d imports of the %d sources and of the %d host tests of src/ is allowed, each host test that imports a package of core: starts with the build line of the host, and the %d files of the copy of the cryptography of Odin are exempt", reading.import_count, reading.source_count, reading.test_count, reading.copy_count)
	return true
}

run_library_imports :: proc(args: []string) -> int {
	return library_imports_check() ? 0 : EXIT_FAILURE
}
