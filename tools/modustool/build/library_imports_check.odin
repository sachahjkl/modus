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
//   - A kernel part ("kernel:iommu", a folder under src/modulus) is imported
//     from src/modulus only. The compiler already refuses it in a module,
//     which gets no flag of the kernel parts; the check refuses it in each
//     other file of src/ too, because a language server gives one set of
//     source libraries to every folder and then compiles the import. A
//     relative path that lands under src/modulus from outside it is refused
//     too: the compiler accepts a relative import in a host test.
//   - A source of a kernel part is pure, so that its host tests run each
//     procedure with no machine: each package variable is @(rodata), no
//     variable is @(static) or @(thread_local), and it holds no foreign
//     block, no foreign import, no asm and no intrinsic that reads the
//     machine. The compiler refuses a write to a variable that is
//     @(rodata), and the memory of the machine refuses a write through a
//     pointer to it: the check needs only the attributes.
//   - A private part ("internal:storage/storage_tree", a folder of
//     src/library/internal/<module>) is what one module alone compiles in.
//     The boot program, a body of code that is no module, has its private
//     parts in src/library/internal/boot_program. A part is imported from the folder
//     of its owner, or from another private part of the same owner, and
//     from no other source of src/; a host
//     test may import one of a module of the group libraries (below). The
//     tool, outside src/, reads some of them too: it is not a part of the
//     system.
//   - The owners of a package of the library are the bodies of code (the
//     kernel, the boot program, each module) whose chain of imports reaches
//     it. A support package has two owners or more, and a private part has
//     its module as its one owner: a reader then tells shared code from the
//     code of one module by its folder. The count is of owners, never of
//     importing files: a package that a private part of one module and that
//     module import has one owner.
//   - A test that imports a package of core: runs on the host: its first
//     build line is "#+build !freestanding", so that no build of the system
//     reads it. A test, and a file of the copy, may also import a relative
//     path, which reaches a folder of the repository that has no name in the
//     library.
//   - A relative import never lands in the folder of a module from a file
//     outside that folder, in src/ or in tools/: the compiler accepts it in
//     a host test and in the tool, and it makes the code of one module a
//     library of another reader. The code that a module and a host program
//     both need is a private part of the module; a host test may import a
//     private part of a module of the group libraries, because it stands in
//     for that module, which a host program cannot load.
//
// src/library/modus/cryptography/origin.manifest names the files that the
// system took from the cryptography of Odin. They keep the imports of their
// origin, and `modustool cryptography-origin` proves that nothing else
// changed.
//
// The reader is the parser of the library of the compiler. It reads each
// file of src/, a test and a file that a build tag leaves out too, and an
// import inside a `when` whatever its condition: the check is stricter than
// the compiler, never looser.
package build

import "core:fmt"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The starts of the paths of the packages that a source of src/ may import.
// A test runs on the host, and the copy of the cryptography of Odin keeps
// the imports of its origin: both may import a package of the core library.
LIBRARY_IMPORT_BASE_START :: "base:"
LIBRARY_IMPORT_CORE_START :: "core:"

// The build line of a host test: the compiler builds the file for the host
// only, and no build of the system reads it.
LIBRARY_HOST_BUILD_LINE :: "#+build !freestanding"

// The folder of the programs of the host that build the system: the check
// reads each of its files for the rule of the relative imports into a
// module alone, because the tool imports the core library freely.
LIBRARY_IMPORTS_TOOL_FOLDER :: "tools"

// The architectures whose host tests the check reads: a test of one
// architecture ends in "_test_<arch>.odin". A name of another architecture
// is read as a source, and the check then refuses its import of core:; add
// the architecture here with the first test of it.
LIBRARY_TEST_ARCHITECTURES :: [?]string{"amd64", "arm64"}

// The folder of src/ that a file is in: the kernel and the contract packages
// import the contract packages only, the kernel its kernel parts too, and a
// source of another folder imports each part of the library.
Library_Source_Kind :: enum {
	Kernel, // src/modulus and each kernel part under it.
	Contract,
	System,
}

// What a checked file is, which the rule of its imports follows.
Library_Source_Form :: struct {
	kind: Library_Source_Kind,
	test: bool, // A host test: its name ends in "_test.odin" or in "_test_<arch>.odin".
	copy: bool, // A file that src/library/modus/cryptography/origin.manifest names.
	part: bool, // A file of a kernel part: a folder under src/modulus.
}

// Why the check refuses a file or an import of it.
Library_Import_Breach_Reason :: enum {
	Unreadable_File, // The parser does not read the file whole, so an import of it can be unread.
	Refused_Import, // The import names a package that the rule of the file refuses.
	Test_Without_Build_Line, // A test imports a package of core: and has no build line of the host.
	Impure_Kernel_Part, // A source of a kernel part keeps state or reaches the machine.
	Private_Part_Of_Another_Module, // The import names a private part of another module, or of no module.
	Support_Package_With_One_Owner, // A support package that fewer than two bodies of code reach.
	Private_Part_Without_Its_Module, // A private part that its module does not reach.
	Relative_Import_Into_A_Module, // A relative import that lands in the folder of a module from outside it.
}

// One refused import, one test without its build line, one impure
// construct of a kernel part, one package of the library with a wrong count
// of owners, or one file that the parser cannot read whole.
Library_Import_Breach :: struct {
	file: string, // For a count of owners: the folder of the package.
	line: int, // 0: the parser refuses the file, or a count of owners.
	// The import as the source writes it, with its quotes; for an impure
	// construct, its words ("the package variable TABLE with no @(rodata)");
	// for a count of owners, the owners, separated by ", ". "": the parser
	// refuses the file, or a package that no body of code reaches.
	text: string,
	reason: Library_Import_Breach_Reason,
	form: Library_Source_Form,
}

// The result of the check on a tree: each breach, the count of each kind of
// file that the check read, and the imports of the library of each source
// that is not a test, which the count of the owners reads.
Library_Import_Reading :: struct {
	breaches: [dynamic]Library_Import_Breach,
	source_count: int, // A source of src/ that is not a test and not a copy.
	test_count: int, // A host test of src/.
	copy_count: int, // A file of the copy of the cryptography of Odin.
	import_count: int, // The imports of the files of src/.
	tool_count: int, // A file of tools/, read for the relative imports into a module alone.
	library_imports: map[string][dynamic]string, // From the root of the tree: each "modus:" import path of the file.
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
	case strings.has_prefix(file, foundation.SOURCE_FOLDER_KERNEL + "/"):
		return .Kernel
	case strings.has_prefix(file, foundation.SOURCE_FOLDER_CONTRACT + "/"):
		return .Contract
	}
	return .System
}

// library_source_is_in_a_kernel_part says if a path from the root of the
// tree names a file of a folder under src/modulus, and not a file of the
// package of the kernel itself.
library_source_is_in_a_kernel_part :: proc(file: string) -> bool {
	start := foundation.SOURCE_FOLDER_KERNEL + "/"
	return strings.has_prefix(file, start) && strings.contains(file[len(start):], "/")
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
	// file of the copy may reach a package that has no name in the library;
	// where the path lands is the rule of library_relative_import_landing.
	if strings.has_prefix(path, "./") || strings.has_prefix(path, "../") {
		return form.copy || (form.test && form.kind == .System)
	}
	if strings.contains(path, "..") {
		return false
	}
	// A part "." after the name of a library names the folder that holds
	// it: "kernel:." is the package of the kernel itself, and
	// "modus:contract/./ring" a second spelling of a package.
	if colon := strings.index_byte(path, ':'); colon >= 0 {
		for part in strings.split(path[colon + 1:], "/", context.temp_allocator) {
			if part == "." {
				return false
			}
		}
	}
	if library_import_names_a_package_under(path, LIBRARY_IMPORT_BASE_START) {
		return true
	}
	if form.copy {
		if library_import_names_a_package_under(path, foundation.SOURCE_LIBRARY_IMPORT_START) {
			return true
		}
		return library_import_names_a_package_under(path, LIBRARY_IMPORT_CORE_START)
	}
	if form.kind == .System {
		if library_import_names_a_package_under(path, foundation.SOURCE_LIBRARY_IMPORT_START) || library_import_names_a_package_under(path, foundation.INTERNAL_IMPORT_START) {
			return true
		}
	} else {
		if library_import_names_a_package_under(path, foundation.CONTRACT_IMPORT_START) {
			return true
		}
	}
	// "modulus:" alone names the package of the kernel itself, which no
	// file imports: a kernel part names its folder.
	if form.kind == .Kernel && library_import_names_a_package_under(path, foundation.KERNEL_IMPORT_START) {
		return true
	}
	return form.test && library_import_names_a_package_under(path, LIBRARY_IMPORT_CORE_START)
}

// library_import_rule_words gives the rule of a file, as the message of a
// refusal states it. It is the same rule that library_import_is_allowed
// applies, so that a reader of the message reads the rule that was refused.
library_import_rule_words :: proc(form: Library_Source_Form) -> string {
	if form.copy {
		return "a file of the copy of the cryptography of Odin keeps the imports of its origin: a package of base:, of " + foundation.SOURCE_LIBRARY_IMPORT_START + ", of core:, or a relative path of the copy"
	}
	if form.kind == .Kernel {
		if form.test {
			return "a test of " + foundation.SOURCE_FOLDER_KERNEL + " imports a package of base:, of core:, under " + foundation.CONTRACT_IMPORT_START + " or under " + foundation.KERNEL_IMPORT_START + ", by a path with no \"..\"; the kernel imports no support package and no internal part"
		}
		return "a source of " + foundation.SOURCE_FOLDER_KERNEL + " imports a package of base:, under " + foundation.CONTRACT_IMPORT_START + " or under " + foundation.KERNEL_IMPORT_START + ", by a path with no \"..\"; the kernel imports no support package and no internal part"
	}
	if form.kind == .Contract {
		if form.test {
			return "a test of " + foundation.SOURCE_FOLDER_CONTRACT + " imports a package of base:, of core: or under " + foundation.CONTRACT_IMPORT_START + ", by a path with no \"..\"; a contract package imports no support package and no internal part"
		}
		return "a source of " + foundation.SOURCE_FOLDER_CONTRACT + " imports a package of base: or under " + foundation.CONTRACT_IMPORT_START + ", by a path with no \"..\"; a contract package imports no support package and no internal part"
	}
	if form.test {
		return "a test of src/ imports a package of base:, of core:, of " + foundation.SOURCE_LIBRARY_IMPORT_START + " or of " + foundation.INTERNAL_IMPORT_START + ", or a relative path of the repository, by a path with no \"..\" after the name of a library; a kernel part (" + foundation.KERNEL_IMPORT_START + ") is imported from " + foundation.SOURCE_FOLDER_KERNEL + " only"
	}
	return "a source of src/ that is not a test imports a package of base:, of " + foundation.SOURCE_LIBRARY_IMPORT_START + " or of " + foundation.INTERNAL_IMPORT_START + ", by a path with no \"..\"; a kernel part (" + foundation.KERNEL_IMPORT_START + ") is imported from " + foundation.SOURCE_FOLDER_KERNEL + " only"
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

// library_relative_import_reaches_a_kernel_part says if a relative import of
// a file outside src/modulus lands in src/modulus or in a folder under it. The
// compiler reads a relative path from the folder of the file, and accepts it
// in a host test, which gets no flag of the kernel parts: only the place
// where the path lands shows that it names a kernel part. file is a path
// from the root of the tree.
library_relative_import_reaches_a_kernel_part :: proc(file, path: string, form: Library_Source_Form) -> bool {
	if form.kind == .Kernel {
		return false
	}
	landing, relative := library_relative_import_landing(file, path)
	return relative && (landing == foundation.SOURCE_FOLDER_KERNEL || strings.has_prefix(landing, foundation.SOURCE_FOLDER_KERNEL + "/"))
}

// library_relative_import_landing gives the folder where a relative import
// of a file lands, as a path from the root of the tree: the compiler reads
// the path from the folder of the file. relative: the path starts with "./"
// or "../"; another path names a library and lands nowhere.
library_relative_import_landing :: proc(file, path: string) -> (landing: string, relative: bool) {
	if !(strings.has_prefix(path, "./") || strings.has_prefix(path, "../")) {
		return "", false
	}
	folder := ""
	if slash := strings.last_index_byte(file, '/'); slash >= 0 {
		folder = file[:slash]
	}
	return path_without_dots(foundation.join(folder, "/", path)), true
}

// library_relative_import_reaches_another_module says if a relative import
// of a file, a path from the root of the tree, lands in src/modules outside
// the folder of the module of the file. The folder of a module is
// src/modules/<group>/<module>; a landing on src/modules or on the folder
// of a group names no module, and is refused from each file.
library_relative_import_reaches_another_module :: proc(file, path: string) -> bool {
	landing, relative := library_relative_import_landing(file, path)
	if !relative || (landing != foundation.SOURCE_FOLDER_MODULES && !strings.has_prefix(landing, foundation.SOURCE_FOLDER_MODULES + "/")) {
		return false
	}
	// The parts of src/modules, then the group and the module.
	module_part_count := strings.count(foundation.SOURCE_FOLDER_MODULES, "/") + 3
	parts := strings.split(landing, "/", context.temp_allocator)
	if len(parts) < module_part_count {
		return true
	}
	module_folder := strings.join(parts[:module_part_count], "/", context.temp_allocator)
	return !strings.has_prefix(file, foundation.join(module_folder, "/"))
}

// The intrinsics that read or change the machine, by the start of their
// names: a kernel part that calls one reads the processor of the host in
// its host test, or does not link there. The intrinsics that compute a
// value from their arguments (count_ones, overflow_add) stay open.
KERNEL_PART_MACHINE_INTRINSIC_STARTS :: [?]string{"read_cycle_counter", "volatile_", "non_temporal_", "atomic_", "cpu_relax", "x86_", "arm64_", "wasm_", "syscall", "trap", "debug_trap", "prefetch_", "objc_", "valgrind_"}

// The walk of a source of a kernel part: the local name of base:intrinsics,
// and the list that each impure construct joins.
@(private = "file")
Kernel_Part_Walk :: struct {
	file:            string,
	form:            Library_Source_Form,
	intrinsics_name: string, // "": the file does not import base:intrinsics.
	breaches:        ^[dynamic]Library_Import_Breach,
}

// kernel_part_attribute_names gives the name of each attribute of a
// declaration: "rodata" for @(rodata), "link_name" for @(link_name = "x").
@(private = "file")
kernel_part_attribute_names :: proc(attributes: []^ast.Attribute) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for attribute in attributes {
		for element in attribute.elems {
			#partial switch item in element.derived {
			case ^ast.Ident:
				append(&names, item.name)
			case ^ast.Field_Value:
				if name, is_name := item.field.derived.(^ast.Ident); is_name {
					append(&names, name.name)
				}
			}
		}
	}
	return names[:]
}

@(private = "file")
kernel_part_breach_add :: proc(walk: ^Kernel_Part_Walk, line: int, words: string) {
	append(walk.breaches, Library_Import_Breach{file = walk.file, line = line, text = strings.clone(words, context.temp_allocator), reason = .Impure_Kernel_Part, form = walk.form})
}

// kernel_part_intrinsic_reads_the_machine says if an intrinsic is one of
// those that read or change the machine.
kernel_part_intrinsic_reads_the_machine :: proc(name: string) -> bool {
	starts := KERNEL_PART_MACHINE_INTRINSIC_STARTS
	for start in starts {
		if strings.has_prefix(name, start) {
			return true
		}
	}
	return false
}

@(private = "file")
kernel_part_visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}
	walk := (^Kernel_Part_Walk)(visitor.data)
	#partial switch item in node.derived {
	case ^ast.Value_Decl:
		for name in kernel_part_attribute_names(item.attributes[:]) {
			if name == "static" || name == "thread_local" {
				kernel_part_breach_add(walk, item.pos.line, fmt.tprintf("a variable marked @(%s)", name))
			}
		}
	case ^ast.Foreign_Block_Decl:
		kernel_part_breach_add(walk, item.pos.line, "a foreign block")
	case ^ast.Foreign_Import_Decl:
		kernel_part_breach_add(walk, item.pos.line, "a foreign import")
	case ^ast.Asm_Template:
		kernel_part_breach_add(walk, item.pos.line, "an asm template")
	case ^ast.Selector_Expr:
		if walk.intrinsics_name == "" || item.field == nil {
			break
		}
		if base, is_name := item.expr.derived.(^ast.Ident); is_name && base.name == walk.intrinsics_name && kernel_part_intrinsic_reads_the_machine(item.field.name) {
			kernel_part_breach_add(walk, item.pos.line, fmt.tprintf("the intrinsic %s.%s, which reads the machine", base.name, item.field.name))
		}
	}
	return visitor
}

// kernel_part_impure_constructs adds a breach for each construct of a source
// of a kernel part that keeps state or reaches the machine: a package
// variable with no @(rodata), a variable marked @(static) or
// @(thread_local), a foreign block or import, an asm template, and an
// intrinsic that reads the machine.
kernel_part_impure_constructs :: proc(file: string, tree: ^ast.File, form: Library_Source_Form, list: ^[dynamic]Library_Import_Breach) {
	walk := Kernel_Part_Walk {
		file     = file,
		form     = form,
		breaches = list,
	}
	for declaration in tree.imports {
		if strings.trim(declaration.fullpath, "\"`") != "base:intrinsics" {
			continue
		}
		walk.intrinsics_name = declaration.name.text != "" ? strings.clone(declaration.name.text, context.temp_allocator) : "intrinsics"
	}
	for statement in tree.decls {
		declaration, is_value := statement.derived.(^ast.Value_Decl)
		if !is_value || !declaration.is_mutable {
			continue
		}
		if slice.contains(kernel_part_attribute_names(declaration.attributes[:]), "rodata") {
			continue
		}
		name := "?"
		if len(declaration.names) > 0 {
			if identifier, is_name := declaration.names[0].derived.(^ast.Ident); is_name {
				name = identifier.name
			}
		}
		kernel_part_breach_add(&walk, declaration.pos.line, fmt.tprintf("the package variable %s with no @(rodata)", name))
	}
	visitor := ast.Visitor {
		visit = kernel_part_visit,
		data  = &walk,
	}
	for statement in tree.decls {
		ast.walk(&visitor, statement)
	}
}

// library_module_source_of_name gives the source folder of the module of the
// table of the modules that has a name, the module of a private part. A
// kernel is not such a module: a private part of it is refused.
library_module_source_of_name :: proc(name: string) -> (source: string, found: bool) {
	for build in foundation.module_builds {
		if !build.kernel && build.name == name {
			return build.source, true
		}
	}
	return "", false
}

// library_private_part_parts gives the module and the part that the path of
// an internal part names, after "internal:" or "internal/"
// ("storage/storage_tree/x.odin" or "storage/storage_tree"). named: the
// path names a module and a part.
@(private = "file")
library_private_part_parts :: proc(path_in_internal: string) -> (module_name: string, part_name: string, named: bool) {
	parts := strings.split(path_in_internal, "/", context.temp_allocator)
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

// library_private_import_is_allowed says whether a file, as a path from the
// root of the tree, may import the path of an import: a path that names no
// internal part is not this rule. An internal part is imported from the
// folder of its module, or from an internal part of the same module; a path
// whose module names no row of the table of the modules is refused. A host
// test may also import an internal part of a module of the group libraries:
// a host program cannot load a module, so the test of a package that calls
// the exports of that module stands in for it with the code of the part.
library_private_import_is_allowed :: proc(file, path: string, form: Library_Source_Form) -> bool {
	if !strings.has_prefix(path, foundation.INTERNAL_IMPORT_START) {
		return true
	}
	module_name, _, named := library_private_part_parts(path[len(foundation.INTERNAL_IMPORT_START):])
	if !named {
		return false
	}
	source, found := library_private_owner_source(module_name)
	if !found {
		return false
	}
	if strings.has_prefix(file, foundation.join(source, "/")) || strings.has_prefix(file, foundation.join(foundation.SOURCE_FOLDER_INTERNAL, "/", module_name, "/")) {
		return true
	}
	return form.test && strings.has_prefix(source, foundation.LIBRARY_MODULE_SOURCES)
}

// PRIVATE_PART_OF_THE_BOOT_PROGRAM is the name, after internal/, of the
// internal parts of the boot program: it is a body of code that is no module,
// and the code that it alone compiles in has a host test there.
PRIVATE_PART_OF_THE_BOOT_PROGRAM :: "boot_program"

// library_module_table_problem says why a table of the modules cannot be
// read by the owner rule, or gives "": a row named
// PRIVATE_PART_OF_THE_BOOT_PROGRAM would make internal/boot_program name two
// owners, that module and the boot program.
library_module_table_problem :: proc(builds: []foundation.Module_Build) -> string {
	for build in builds {
		if build.name == PRIVATE_PART_OF_THE_BOOT_PROGRAM {
			return fmt.tprintf("the table of the modules has a row named %s (source %s): that name is the one of the internal parts of the boot program, %s%s/; give the module another name", build.name, build.source, foundation.INTERNAL_IMPORT_START, PRIVATE_PART_OF_THE_BOOT_PROGRAM)
		}
	}
	return ""
}

// library_private_owner_source gives the folder of the one owner of an
// internal part from the name after internal/: a module of the table, or
// the boot program. found: the name names one of them.
@(private = "file")
library_private_owner_source :: proc(owner_name: string) -> (source: string, found: bool) {
	if owner_name == PRIVATE_PART_OF_THE_BOOT_PROGRAM {
		return foundation.SOURCE_FOLDER_BOOT, true
	}
	return library_module_source_of_name(owner_name)
}

// library_owner_is_library_module tells whether an owner is a module of the
// module group libraries: a support package that a program outside needs
// has one such owner (src/md/infrastructure/repository_layout.md, "A
// package that a program outside needs").
@(private = "file")
library_owner_is_library_module :: proc(owner: string) -> bool {
	source, found := library_module_source_of_name(owner)
	if !found {
		return false
	}
	group, has_group := foundation.module_group_of_source(source)
	return has_group && group == .Libraries
}

// library_package_node gives the package of the two libraries that a path
// inside src/library names, as the owner rule counts it: "modus/<name>" for
// a support package with each folder under it, "modus/contract/<name>" for
// a contract package, "internal/<module>/<part>" for an internal part.
// found: the path names a package.
library_package_node :: proc(path_in_library: string) -> (node: string, found: bool) {
	parts := strings.split(path_in_library, "/", context.temp_allocator)
	if len(parts) >= 3 && parts[0] == foundation.INTERNAL_LIBRARY_NAME {
		return strings.join(parts[:3], "/", context.temp_allocator), parts[1] != "" && parts[2] != ""
	}
	if len(parts) >= 3 && parts[0] == foundation.SOURCE_LIBRARY_NAME && parts[1] == foundation.LIBRARY_PART_CONTRACT {
		return strings.join(parts[:3], "/", context.temp_allocator), parts[2] != ""
	}
	if len(parts) >= 2 && parts[0] == foundation.SOURCE_LIBRARY_NAME && parts[1] != "" && parts[1] != foundation.LIBRARY_PART_CONTRACT {
		return strings.join(parts[:2], "/", context.temp_allocator), true
	}
	return "", false
}

// library_package_node_of_import gives the node of an import path of the
// public library ("modus:...") or of the internal library ("internal:...").
@(private = "file")
library_package_node_of_import :: proc(import_path: string) -> (node: string, found: bool) {
	if library_import_names_a_package_under(import_path, foundation.SOURCE_LIBRARY_IMPORT_START) {
		return library_package_node(strings.concatenate({foundation.SOURCE_LIBRARY_NAME, "/", import_path[len(foundation.SOURCE_LIBRARY_IMPORT_START):]}, context.temp_allocator))
	}
	if library_import_names_a_package_under(import_path, foundation.INTERNAL_IMPORT_START) {
		return library_package_node(strings.concatenate({foundation.INTERNAL_LIBRARY_NAME, "/", import_path[len(foundation.INTERNAL_IMPORT_START):]}, context.temp_allocator))
	}
	return "", false
}

// library_owner_unit_of gives the body of code or the package of the library
// that a file of src/ is a part of: the package of the library (is_package),
// the name of a module of the table, or the folder of the kernel, of the
// boot program or of the runtime.
@(private = "file")
library_owner_unit_of :: proc(file: string) -> (unit: string, is_package: bool) {
	if strings.has_prefix(file, foundation.SOURCE_FOLDER_LIBRARY + "/") {
		rest := file[len(foundation.SOURCE_FOLDER_LIBRARY) + 1:]
		if slash := strings.last_index_byte(rest, '/'); slash >= 0 {
			if node, found := library_package_node(rest[:slash]); found {
				return node, true
			}
		}
		return rest, true
	}
	for build in foundation.module_builds {
		if !build.kernel && strings.has_prefix(file, foundation.join(build.source, "/")) {
			return build.name, false
		}
	}
	for folder in ([]string{foundation.SOURCE_FOLDER_KERNEL, foundation.SOURCE_FOLDER_BOOT, foundation.SOURCE_FOLDER_RUNTIME}) {
		if strings.has_prefix(file, foundation.join(folder, "/")) {
			return folder, false
		}
	}
	if slash := strings.last_index_byte(file, '/'); slash >= 0 {
		return file[:slash], false
	}
	return file, false
}

// library_owner_breaches counts the owners of each support package and of
// each private part that has a source in the reading, from the imports of
// the sources that are not tests. A support package with fewer than two
// owners, and a private part that its module does not own, is a breach that
// names its folder.
library_owner_breaches :: proc(reading: Library_Import_Reading) -> []Library_Import_Breach {
	list := make([dynamic]Library_Import_Breach, context.temp_allocator)
	edges := make(map[string][dynamic]string, context.temp_allocator)
	bodies := make([dynamic]string, context.temp_allocator)
	packages := make(map[string]bool, context.temp_allocator)
	for file, imports in reading.library_imports {
		unit, is_package := library_owner_unit_of(file)
		if is_package {
			packages[unit] = true
		} else if !slice.contains(bodies[:], unit) {
			append(&bodies, unit)
		}
		unit_edges := edges[unit]
		if unit_edges == nil {
			unit_edges = make([dynamic]string, context.temp_allocator)
		}
		for path in imports {
			if node, found := library_package_node_of_import(path); found {
				append(&unit_edges, node)
			}
		}
		edges[unit] = unit_edges
	}
	slice.sort(bodies[:])
	owners := make(map[string][dynamic]string, context.temp_allocator)
	for body in bodies {
		seen := make(map[string]bool, context.temp_allocator)
		stack := make([dynamic]string, context.temp_allocator)
		body_edges := edges[body]
		append(&stack, ..body_edges[:])
		for len(stack) > 0 {
			node := pop(&stack)
			if node in seen {
				continue
			}
			seen[node] = true
			node_edges := edges[node]
			append(&stack, ..node_edges[:])
			node_owners := owners[node]
			if node_owners == nil {
				node_owners = make([dynamic]string, context.temp_allocator)
			}
			append(&node_owners, body)
			owners[node] = node_owners
		}
	}
	nodes := make([dynamic]string, context.temp_allocator)
	for node in packages {
		append(&nodes, node)
	}
	slice.sort(nodes[:])
	for node in nodes {
		owners_of_node := owners[node]
		node_owners := owners_of_node[:]
		folder := strings.concatenate({foundation.SOURCE_FOLDER_LIBRARY, "/", node}, context.temp_allocator)
		text := strings.join(node_owners, ", ", context.temp_allocator)
		switch {
		case strings.has_prefix(node, foundation.SOURCE_LIBRARY_NAME + "/") && !strings.has_prefix(node, foundation.SOURCE_LIBRARY_NAME + "/" + foundation.LIBRARY_PART_CONTRACT + "/"):
			if len(node_owners) < 2 && !(len(node_owners) == 1 && library_owner_is_library_module(node_owners[0])) {
				append(&list, Library_Import_Breach{file = folder, text = text, reason = .Support_Package_With_One_Owner})
			}
		case strings.has_prefix(node, foundation.INTERNAL_LIBRARY_NAME + "/"):
			module_name, _, _ := library_private_part_parts(node[len(foundation.INTERNAL_LIBRARY_NAME) + 1:])
			// The boot program is counted as its folder, a module as its name.
			owner := module_name == PRIVATE_PART_OF_THE_BOOT_PROGRAM ? foundation.SOURCE_FOLDER_BOOT : module_name
			if len(node_owners) != 1 || node_owners[0] != owner {
				append(&list, Library_Import_Breach{file = folder, text = text, reason = .Private_Part_Without_Its_Module})
			}
		}
	}
	return list[:]
}

// library_import_breaches_of_source gives each refused import of one source
// file, and the test without its build line. A file with an error of syntax
// is one breach: the parser does not read it whole, so an import of it can
// be unread. An import inside a procedure is such an error.
library_import_breaches_of_source :: proc(file, source: string, form: Library_Source_Form, library_imports: ^[dynamic]string = nil) -> (breaches: []Library_Import_Breach, import_count: int) {
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
		reader.err = foundation.tokenizer_quiet_error
		reader.warn = foundation.tokenizer_quiet_error
		if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
			append(&list, Library_Import_Breach{file = file, reason = .Unreadable_File, form = form})
			return list[:], 0
		}
		import_count = len(tree.imports)
		for declaration in tree.imports {
			text := declaration.relpath.text
			path := strings.trim(text, "\"`")
			if library_imports != nil && (library_import_names_a_package_under(path, foundation.SOURCE_LIBRARY_IMPORT_START) || library_import_names_a_package_under(path, foundation.INTERNAL_IMPORT_START)) {
				append(library_imports, strings.clone(path, context.temp_allocator))
			}
			if !library_import_is_allowed(path, form) || library_relative_import_reaches_a_kernel_part(file, path, form) {
				append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator), reason = .Refused_Import, form = form})
				continue
			}
			if library_relative_import_reaches_another_module(file, path) {
				append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator), reason = .Relative_Import_Into_A_Module, form = form})
				continue
			}
			if !library_private_import_is_allowed(file, path, form) {
				append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator), reason = .Private_Part_Of_Another_Module, form = form})
			}
		}
		if form.part && !form.test {
			kernel_part_impure_constructs(file, tree, form, &list)
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

// library_import_breaches_of_tree reads each source file of src/ of a tree,
// and each file of tools/ for the relative imports into a module.
// root is the folder of the tree: "" is the folder where the tool runs, the
// root of the repository. The manifest of the cryptography of Odin of the
// tree names the files that the check reads with the rule of a copy.
library_import_breaches_of_tree :: proc(root: string) -> (reading: Library_Import_Reading, ok: bool) {
	paths := make([dynamic]string, context.temp_allocator)
	folders := foundation.SOURCE_FOLDERS
	for folder in folders {
		foundation.source_files_of_a_folder(root == "" ? folder : foundation.join(root, "/", folder), &paths) or_return
	}
	files := make([dynamic]string, context.temp_allocator)
	for path in paths {
		append(&files, library_source_relative_to_root(root, path))
	}
	slice.sort(files[:])
	copied := make(map[string]bool, context.temp_allocator)
	manifest := root == "" ? foundation.CRYPTOGRAPHY_MANIFEST : foundation.join(root, "/", foundation.CRYPTOGRAPHY_MANIFEST)
	lines, manifest_ok := foundation.manifest_lines(manifest)
	if !manifest_ok {
		return {}, false
	}
	for parts in lines {
		if len(parts) > 0 {
			copied[parts[0]] = true
		}
	}
	reading.breaches = make([dynamic]Library_Import_Breach, context.temp_allocator)
	reading.library_imports = make(map[string][dynamic]string, context.temp_allocator)
	for file in files {
		source, read_ok := foundation.read_text_file_quiet(library_source_path(root, file))
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return {}, false
		}
		form := Library_Source_Form {
			kind = library_source_kind_of(file),
			test = library_source_is_a_test(file),
			copy = file in copied,
			part = library_source_is_in_a_kernel_part(file),
		}
		// A test runs on the host: it makes no body of code an owner.
		library_imports: ^[dynamic]string
		file_library_imports := make([dynamic]string, context.temp_allocator)
		if !form.test {
			library_imports = &file_library_imports
		}
		file_breaches, file_imports := library_import_breaches_of_source(file, source, form, library_imports)
		if !form.test {
			reading.library_imports[file] = file_library_imports
		}
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
	// The files of tools/: the rule of the relative imports into a module
	// alone.
	tool_paths := make([dynamic]string, context.temp_allocator)
	foundation.source_files_of_a_folder(root == "" ? LIBRARY_IMPORTS_TOOL_FOLDER : foundation.join(root, "/", LIBRARY_IMPORTS_TOOL_FOLDER), &tool_paths) or_return
	tool_files := make([dynamic]string, context.temp_allocator)
	for path in tool_paths {
		append(&tool_files, library_source_relative_to_root(root, path))
	}
	slice.sort(tool_files[:])
	for file in tool_files {
		source, read_ok := foundation.read_text_file_quiet(library_source_path(root, file))
		if !read_ok {
			fmt.eprintfln("modustool: cannot read %s", file)
			return {}, false
		}
		append(&reading.breaches, ..library_tool_import_breaches_of_source(file, source))
		reading.tool_count += 1
	}
	return reading, true
}

// library_tool_import_breaches_of_source gives each relative import of one
// file of tools/ that lands in the folder of a module. The tool imports the
// core library and the private parts freely: it builds the system and is
// not a part of it. A file that the parser cannot read whole is one breach,
// as in src/.
library_tool_import_breaches_of_source :: proc(file, source: string) -> []Library_Import_Breach {
	list := make([dynamic]Library_Import_Breach, context.temp_allocator)
	form := Library_Source_Form{kind = .System}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		append(&list, Library_Import_Breach{file = file, reason = .Unreadable_File, form = form})
		return list[:]
	}
	defer virtual.arena_destroy(&arena)
	{
		context.allocator = virtual.arena_allocator(&arena)
		tree := ast.new_from_positions(ast.File, {}, {})
		tree.src = source
		tree.fullpath = file
		reader := parser.default_parser()
		reader.err = foundation.tokenizer_quiet_error
		reader.warn = foundation.tokenizer_quiet_error
		if !parser.parse_file(&reader, tree) || tree.syntax_error_count > 0 {
			append(&list, Library_Import_Breach{file = file, reason = .Unreadable_File, form = form})
			return list[:]
		}
		for declaration in tree.imports {
			text := declaration.relpath.text
			if library_relative_import_reaches_another_module(file, strings.trim(text, "\"`")) {
				append(&list, Library_Import_Breach{file = file, line = declaration.relpath.pos.line, text = strings.clone(text, context.temp_allocator), reason = .Relative_Import_Into_A_Module, form = form})
			}
		}
	}
	return list[:]
}

// library_import_breach_sentence gives the line of the output for one
// breach: the file and the line first, as the compiler writes an error.
library_import_breach_sentence :: proc(breach: Library_Import_Breach) -> string {
	switch breach.reason {
	case .Unreadable_File:
		return fmt.tprintf("%s: the parser cannot read the file whole, so its imports are not checked: a source of src/ or of tools/ has no error of syntax, and no import inside a procedure", breach.file)
	case .Impure_Kernel_Part:
		return fmt.tprintf("%s:%d: %s is refused: a kernel part is pure, so each package variable is @(rodata), no variable is @(static) or @(thread_local), and it holds no foreign block, no foreign import, no asm and no intrinsic that reads the machine", breach.file, breach.line, breach.text)
	case .Test_Without_Build_Line:
		return fmt.tprintf("%s:%d: the test imports %s and has no build line: a test of src/ that imports a package of core: starts with %q, so that no build of the system reads it", breach.file, breach.line, breach.text, LIBRARY_HOST_BUILD_LINE)
	case .Refused_Import:
		return fmt.tprintf("%s:%d: the import %s is refused: %s", breach.file, breach.line, breach.text, library_import_rule_words(breach.form))
	case .Private_Part_Of_Another_Module:
		return fmt.tprintf("%s:%d: the import %s is refused: an internal part (%s<module>/<part>) is imported from the folder of its module or from an internal part of the same module only, and by a host test when <module> is in %s; <module> is the name of a module of the table", breach.file, breach.line, breach.text, foundation.INTERNAL_IMPORT_START, foundation.LIBRARY_MODULE_SOURCES)
	case .Relative_Import_Into_A_Module:
		return fmt.tprintf("%s:%d: the import %s is refused: a relative import lands in the folder of a module (%s<group>/<module>) from outside it; the code that a module and another reader need is an internal part of the module, imported as %s<module>/<part>", breach.file, breach.line, breach.text, foundation.SOURCE_FOLDER_MODULES + "/", foundation.INTERNAL_IMPORT_START)
	case .Support_Package_With_One_Owner:
		if breach.text == "" {
			return fmt.tprintf("%s: no body of code reaches this support package: a support package has two owners or more, or one owner of the group libraries", breach.file)
		}
		return fmt.tprintf("%s: only %s reaches this support package: a support package has two owners or more, or one owner of the group libraries, and a package of one module is its internal part, in %s/<module>/", breach.file, breach.text, foundation.SOURCE_FOLDER_INTERNAL)
	case .Private_Part_Without_Its_Module:
		if breach.text == "" {
			return fmt.tprintf("%s: no body of code reaches this internal part: an internal part has its module as its one owner", breach.file)
		}
		return fmt.tprintf("%s: the owners of this internal part are %s: an internal part has its module as its one owner", breach.file, breach.text)
	}
	return ""
}

// library_imports_hold reads the repository and prints each breach. Each
// build calls it before its first compiler starts: the build stops with
// the file and the line, as it stopped when the compiler refused the
// import.
library_imports_hold :: proc() -> (reading: Library_Import_Reading, hold: bool) {
	if problem := library_module_table_problem(foundation.module_builds[:]); problem != "" {
		fmt.eprintfln("modustool: %s", problem)
		return {}, false
	}
	found, read_ok := library_import_breaches_of_tree("")
	if !read_ok {
		return {}, false
	}
	append(&found.breaches, ..library_owner_breaches(found))
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
		fmt.eprintln("modustool: test failed: an import of a source of src/ or of tools/, the build line of a host test, or a construct of a kernel part that is not pure, is refused")
		return false
	}
	foundation.test_passed_print("each of the %d imports of the %d sources and of the %d host tests of src/ is allowed, each host test that imports a package of core: starts with the build line of the host, each source of a kernel part is pure, the %d files of the copy of the cryptography of Odin are exempt, and no relative import of the %d files of tools/ lands in a module", reading.import_count, reading.source_count, reading.test_count, reading.copy_count, reading.tool_count)
	return true
}

run_library_imports :: proc(args: []string) -> int {
	return library_imports_check() ? 0 : foundation.EXIT_FAILURE
}
