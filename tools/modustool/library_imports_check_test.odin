package modustool

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// A small tree with a kernel, two contract packages, one support package and
// the manifest of the cryptography of Odin, at the folders of the tool: the
// check reads them there. Each file is one import that the rule allows.
@(private = "file")
library_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "library_imports_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	for name in ([]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_CONTRACT + "/ring", SOURCE_FOLDER_CONTRACT + "/record/inner", SOURCE_FOLDER_SUPPORT + "/sentence", SOURCE_FOLDER_SUPPORT + "/cryptography"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	library_tree_file_write(folder, SOURCE_FOLDER_KERNEL + "/enter.odin", "package kernel\n\nimport \"base:intrinsics\"\nimport ring \"" + CONTRACT_IMPORT_START + "ring\"\nimport \"" + CONTRACT_IMPORT_START + "record/inner\"\n")
	library_tree_file_write(folder, SOURCE_FOLDER_CONTRACT + "/ring/ring.odin", "package ring\n\nimport \"" + CONTRACT_IMPORT_START + "record/inner\"\n")
	library_tree_file_write(folder, SOURCE_FOLDER_CONTRACT + "/ring/ring_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage ring\n\nimport \"core:testing\"\nimport \"core:math/rand\"\n")
	library_tree_file_write(folder, SOURCE_FOLDER_CONTRACT + "/record/inner/inner.odin", "package inner\n")
	library_tree_file_write(folder, SOURCE_FOLDER_SUPPORT + "/sentence/sentence.odin", "package sentence\n\nimport \"base:intrinsics\"\nimport ring \"" + CONTRACT_IMPORT_START + "ring\"\n")
	library_tree_file_write(folder, CRYPTOGRAPHY_MANIFEST, "# The cryptography of Odin: this tree has no copy.\n")
	return folder
}

@(private = "file")
library_tree_file_write :: proc(root, name, text: string) {
	_ = os.write_entire_file(fmt.tprintf("%s/%s", root, name), text)
}

@(private = "file")
library_tree_folder_make :: proc(root, name: string) {
	_ = os.make_directory_all(fmt.tprintf("%s/%s", root, name))
}

// The breach of one file of the tree, by the end of its path.
@(private = "file")
breach_of_file :: proc(breaches: []Library_Import_Breach, file_end: string) -> (breach: Library_Import_Breach, found: bool) {
	for item in breaches {
		if strings.has_suffix(item.file, file_end) {
			return item, true
		}
	}
	return {}, false
}

// The count of the breaches of one file of the tree, by the end of its path.
@(private = "file")
breach_count_of_file :: proc(breaches: []Library_Import_Breach, file_end: string) -> int {
	count := 0
	for item in breaches {
		if strings.has_suffix(item.file, file_end) {
			count += 1
		}
	}
	return count
}

// Which import path each form of file can write. The refused forms come
// first: another library, an empty package, a path of another part of the
// library, and a path with ".." after the name of a library. A relative path
// comes next: only a host test and the copy of the cryptography may write
// one.
@(test)
library_import_paths_that_the_rule_allows :: proc(t: ^testing.T) {
	kernel_source := Library_Source_Form{kind = .Kernel}
	kernel_test := Library_Source_Form{kind = .Kernel, test = true}
	contract_source := Library_Source_Form{kind = .Contract}
	contract_test := Library_Source_Form{kind = .Contract, test = true}
	system_source := Library_Source_Form{kind = .System}
	system_test := Library_Source_Form{kind = .System, test = true}
	copied_source := Library_Source_Form{kind = .System, copy = true}

	for path in ([]string {
			"beside",
			"vendor:glfw",
			"contract:ring",
			"support:sentence",
			CONTRACT_IMPORT_START + "../support/sentence",
			"core:",
			"modus:",
			"",
		}) {
		for form in ([]Library_Source_Form{kernel_source, kernel_test, contract_source, contract_test, system_source, system_test, copied_source}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is refused in %v", path, form)
		}
	}

	// A relative path names a folder of the repository: a host test of a
	// source of the system and a file of the copy reach a module there. A
	// source that is not a test imports no relative path.
	for form in ([]Library_Source_Form{system_test, copied_source}) {
		for path in ([]string{"../sentence", "./ref", "../../../modules/cryptography"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
	}
	for form in ([]Library_Source_Form{kernel_source, kernel_test, contract_source, contract_test, system_source}) {
		for path in ([]string{"../sentence", "./ref"}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is not an import of %v", path, form)
		}
	}

	// A source that is not a test: the base library and the library, and no
	// package of the core library, which reaches the host.
	for form in ([]Library_Source_Form{system_source, copied_source}) {
		for path in ([]string{"base:intrinsics", "base:runtime", SOURCE_LIBRARY_IMPORT_START + "support/sentence", CONTRACT_IMPORT_START + "ring"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
	}
	for path in ([]string{"core:os", "core:fmt", "core:testing"}) {
		testing.expectf(t, !library_import_is_allowed(path, system_source), "%q is not an import of a source that is not a test", path)
		testing.expectf(t, library_import_is_allowed(path, copied_source), "%q is an import of the copy of the cryptography of Odin", path)
	}

	// A test: a package of the core library too.
	for path in ([]string{"base:intrinsics", "core:testing", "core:math/rand", SOURCE_LIBRARY_IMPORT_START + "support/sentence", CONTRACT_IMPORT_START + "ring"}) {
		testing.expectf(t, library_import_is_allowed(path, system_test), "%q is an import of a test", path)
	}

	// The kernel and a contract package: the contract packages only, and a
	// package of the core library in a test.
	for form in ([]Library_Source_Form{kernel_source, contract_source}) {
		for path in ([]string{"base:intrinsics", CONTRACT_IMPORT_START + "ring", CONTRACT_IMPORT_START + "record/inner"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
		for path in ([]string{SUPPORT_IMPORT_START + "sentence", SOURCE_LIBRARY_IMPORT_START + "contract", "core:testing", "core:os"}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is not an import of %v", path, form)
		}
	}
	for form in ([]Library_Source_Form{kernel_test, contract_test}) {
		for path in ([]string{"base:intrinsics", "core:testing", CONTRACT_IMPORT_START + "ring"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
		for path in ([]string{SUPPORT_IMPORT_START + "sentence", SOURCE_LIBRARY_IMPORT_START + "contract", "core:os"}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is not an import of %v", path, form)
		}
	}
}

// The names of a host test: the two forms that the rule reads, and the names
// that it does not read as a test.
@(test)
library_test_names_that_the_rule_reads :: proc(t: ^testing.T) {
	for name in ([]string{"src/a/b_test.odin", "src/a/b_test_amd64.odin", "a_test_arm64.odin", "src/library/contract/blake3/chunks_side_by_side_test_amd64.odin"}) {
		testing.expectf(t, library_source_is_a_test(name), "%q is the name of a host test", name)
	}
	for name in ([]string{"src/a/b.odin", "src/a/attest.odin", "src/a/b_test_other.odin", "a_test/b.odin", "src/a/b_test.odin.bak"}) {
		testing.expectf(t, !library_source_is_a_test(name), "%q is not the name of a host test", name)
	}
}

// A tree where each import is allowed has no breach, and the check counts
// each kind of file and each import of the tree.
@(test)
library_imports_of_an_allowed_tree :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(reading.breaches) == 0, "%v", reading.breaches)
	testing.expect_value(t, reading.source_count, 4)
	testing.expect_value(t, reading.test_count, 1)
	testing.expect_value(t, reading.copy_count, 0)
	testing.expect_value(t, reading.import_count, 8)
}

// The two imports that the compiler refused when the kernel had the
// contract library only: a source of the kernel that imports a support
// package, and a contract package that imports a support package by a
// relative path. Each is refused with its file, its line and its text.
@(test)
library_import_of_a_support_package_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, SOURCE_FOLDER_KERNEL + "/report.odin", "package kernel\n\nimport \"base:intrinsics\"\n// A comment.\nimport sentence \"" + SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_CONTRACT + "/ring/write.odin", "package ring\n\nimport \"../../support/sentence\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches), 2) {
		return
	}
	in_kernel, kernel_found := breach_of_file(reading.breaches, SOURCE_FOLDER_KERNEL + "/report.odin")
	testing.expect(t, kernel_found, "the file of the kernel is not named")
	testing.expect_value(t, in_kernel.line, 5)
	testing.expect_value(t, in_kernel.text, "\"" + SUPPORT_IMPORT_START + "sentence\"")
	sentence := library_import_breach_sentence(in_kernel)
	testing.expect(t, strings.contains(sentence, SOURCE_FOLDER_KERNEL + "/report.odin:5: the import \"" + SUPPORT_IMPORT_START + "sentence\" is refused"), sentence)
	testing.expect(t, strings.contains(sentence, "the kernel imports no support package"), sentence)
	in_contract, contract_found := breach_of_file(reading.breaches, SOURCE_FOLDER_CONTRACT + "/ring/write.odin")
	testing.expect(t, contract_found, "the file of the contract package is not named")
	testing.expect_value(t, in_contract.line, 3)
	testing.expect_value(t, in_contract.text, "\"../../support/sentence\"")
}

// The check reads what the compiler leaves out: an import inside a `when`
// whose condition is false, a file that a build tag leaves out, and a test.
@(test)
library_import_that_the_compiler_leaves_out_is_read :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, SOURCE_FOLDER_KERNEL + "/inside_when.odin", "package kernel\n\nwhen false {\n\timport \"" + SUPPORT_IMPORT_START + "sentence\"\n} else {\n\timport \"../beside\"\n}\n")
	library_tree_file_write(root, SOURCE_FOLDER_KERNEL + "/other_system.odin", "#+build windows\npackage kernel\n\nimport \"" + SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_CONTRACT + "/ring/write_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage ring\n\nimport \"core:testing\"\nimport \"" + SUPPORT_IMPORT_START + "sentence\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expect_value(t, len(reading.breaches), 4)
	inside_when := 0
	for breach in reading.breaches {
		if strings.has_suffix(breach.file, "/inside_when.odin") {
			inside_when += 1
			testing.expect(t, breach.line == 4 || breach.line == 6, "the line of an import inside a `when`")
		}
	}
	testing.expect_value(t, inside_when, 2)
	other_system, other_found := breach_of_file(reading.breaches, "/other_system.odin")
	testing.expect(t, other_found, "a file that a build tag leaves out is read")
	testing.expect_value(t, other_system.line, 4)
	in_test, test_found := breach_of_file(reading.breaches, "/write_test.odin")
	testing.expect(t, test_found, "a test is read")
	testing.expect_value(t, in_test.line, 5)
}

// A source that is not a test imports no package of the core library: not
// at its top, not inside a `when`, and not even with the build line of the
// host, which only a test needs.
@(test)
library_source_that_imports_core_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_folder_make(root, SOURCE_FOLDER_PROGRAMS + "/console")
	library_tree_folder_make(root, SOURCE_FOLDER_BOOT)
	library_tree_file_write(root, SOURCE_FOLDER_PROGRAMS + "/console/main.odin", "package console\n\nimport \"core:os\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_BOOT + "/inside_when.odin", "package boot\n\nwhen false {\n\timport \"core:fmt\"\n}\n")
	library_tree_file_write(root, SOURCE_FOLDER_PROGRAMS + "/console/on_the_host.odin", LIBRARY_HOST_BUILD_LINE + "\npackage console\n\nimport \"core:fmt\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches), 3) {
		return
	}
	main_source, main_found := breach_of_file(reading.breaches, "/console/main.odin")
	testing.expect(t, main_found, "a source that is not a test imports no core:os")
	testing.expect_value(t, main_source.line, 3)
	inside_when, when_found := breach_of_file(reading.breaches, "/boot/inside_when.odin")
	testing.expect(t, when_found, "an import inside a `when` is read")
	testing.expect_value(t, inside_when.line, 4)
	on_the_host, host_found := breach_of_file(reading.breaches, "/console/on_the_host.odin")
	testing.expect(t, host_found, "the build line of the host does not allow a source that is not a test to import core:")
	testing.expect_value(t, on_the_host.line, 4)
	for breach in reading.breaches {
		testing.expect_value(t, breach.reason, Library_Import_Breach_Reason.Refused_Import)
		testing.expect(t, strings.contains(library_import_breach_sentence(breach), "a source of src/ that is not a test imports a package of base: or of " + SOURCE_LIBRARY_IMPORT_START), library_import_breach_sentence(breach))
	}
	testing.expect_value(t, reading.source_count, 7)
}

// A test that imports a package of the core library is a host test: its
// first build line is the line of the host. A missing line, a first build
// line of another system, and a tag after a comma, are refused and name the
// file. A test that imports no package of core: needs no line, and a test of
// one architecture with the line is allowed.
@(test)
library_test_without_build_line_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, SOURCE_FOLDER_SUPPORT + "/sentence/sentence_test.odin", "package sentence\n\nimport \"core:testing\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_SUPPORT + "/sentence/other_test.odin", "#+build linux\npackage sentence\n\nimport \"core:testing\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_SUPPORT + "/sentence/comma_test.odin", "#+build !freestanding, linux\npackage sentence\n\nimport \"core:testing\"\n")
	library_tree_file_write(root, SOURCE_FOLDER_SUPPORT + "/sentence/small_test.odin", "package sentence\n")
	library_tree_file_write(root, SOURCE_FOLDER_CONTRACT + "/ring/fast_test_amd64.odin", LIBRARY_HOST_BUILD_LINE + "\npackage ring\n\nimport \"core:testing\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches), 3) {
		return
	}
	no_line, no_line_found := breach_of_file(reading.breaches, "/sentence/sentence_test.odin")
	testing.expect(t, no_line_found, "the test without the line is not named")
	testing.expect_value(t, no_line.reason, Library_Import_Breach_Reason.Test_Without_Build_Line)
	testing.expect_value(t, no_line.line, 3)
	testing.expect_value(t, no_line.text, "\"core:testing\"")
	sentence := library_import_breach_sentence(no_line)
	testing.expect(t, strings.contains(sentence, "/sentence/sentence_test.odin:3: the test imports \"core:testing\" and has no build line"), sentence)
	testing.expect(t, strings.contains(sentence, LIBRARY_HOST_BUILD_LINE), sentence)
	other, other_found := breach_of_file(reading.breaches, "/sentence/other_test.odin")
	testing.expect(t, other_found, "the first build line is the one of the host, whatever comes after it")
	testing.expect_value(t, other.reason, Library_Import_Breach_Reason.Test_Without_Build_Line)
	testing.expect_value(t, other.line, 4)
	comma, comma_found := breach_of_file(reading.breaches, "/sentence/comma_test.odin")
	testing.expect(t, comma_found, "a tag after a comma would allow a build that is freestanding")
	testing.expect_value(t, comma.reason, Library_Import_Breach_Reason.Test_Without_Build_Line)
	testing.expect_value(t, breach_count_of_file(reading.breaches, "/sentence/small_test.odin"), 0)
	testing.expect_value(t, breach_count_of_file(reading.breaches, "/ring/fast_test_amd64.odin"), 0)
	// The test of one architecture is read as a test, and not as a source.
	testing.expect_value(t, reading.test_count, 6)
}

// The files that src/library/support/cryptography/origin.manifest names keep
// the imports of their origin: a package of core:, and a relative path of the
// copy. The same import in a file that no manifest names is refused, and the
// copy is counted apart.
@(test)
library_copy_of_the_cryptography_is_exempt :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_folder_make(root, SOURCE_FOLDER_SUPPORT + "/cryptography/aes")
	library_tree_file_write(root, SOURCE_FOLDER_SUPPORT + "/cryptography/aes/aes_impl.odin", "package aes\n\nimport \"core:reflect\"\nimport \"../_subtle\"\n")
	library_tree_file_write(root, CRYPTOGRAPHY_MANIFEST, "# The cryptography of Odin.\n" + SOURCE_FOLDER_SUPPORT + "/cryptography/aes/aes_impl.odin core/crypto/aes/aes_impl.odin a-hash\n")
	library_tree_file_write(root, SOURCE_FOLDER_SUPPORT + "/sentence/reflect.odin", "package sentence\n\nimport \"core:reflect\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches), 1) {
		return
	}
	testing.expect_value(t, breach_count_of_file(reading.breaches, "/cryptography/aes/aes_impl.odin"), 0)
	testing.expect_value(t, breach_count_of_file(reading.breaches, "/sentence/reflect.odin"), 1)
	testing.expect_value(t, reading.copy_count, 1)
	testing.expect_value(t, reading.source_count, 5)
}

// The other forms that leave the contract packages: a path that goes up
// from a contract package, a library of the compiler that the project has
// not, one of the two names that the libraries had, and a package of the
// core library in a source that is not a test.
@(test)
library_import_of_another_form_is_refused :: proc(t: ^testing.T) {
	breaches, import_count := library_import_breaches_of_source("src/kernel/forms.odin", "package kernel\n\nimport \"" + CONTRACT_IMPORT_START + "../support/sentence\"\nimport \"vendor:glfw\"\nimport \"support:sentence\"\nimport \"core:testing\"\n", Library_Source_Form{kind = .Kernel})
	testing.expect_value(t, import_count, 4)
	if testing.expect_value(t, len(breaches), 4) {
		testing.expect_value(t, breaches[0].line, 3)
		testing.expect_value(t, breaches[1].text, "\"vendor:glfw\"")
		testing.expect_value(t, breaches[2].line, 5)
		testing.expect_value(t, breaches[3].text, "\"core:testing\"")
	}
}

// A file that the parser cannot read whole is refused as a file: an import
// after the error can be unread. An import inside a procedure is an error of
// syntax.
@(test)
library_import_file_that_the_parser_refuses :: proc(t: ^testing.T) {
	form := Library_Source_Form{kind = .Kernel}
	broken, _ := library_import_breaches_of_source("src/kernel/broken.odin", "package kernel\n\nbroken :: proc( {\n", form)
	if testing.expect_value(t, len(broken), 1) {
		testing.expect_value(t, broken[0].reason, Library_Import_Breach_Reason.Unreadable_File)
		testing.expect_value(t, broken[0].text, "")
		testing.expect_value(t, broken[0].line, 0)
		testing.expect(t, strings.contains(library_import_breach_sentence(broken[0]), "src/kernel/broken.odin: the parser cannot read the file whole"))
	}
	inside_procedure, _ := library_import_breaches_of_source("src/kernel/inside.odin", "package kernel\n\nwork :: proc() {\n\timport \"" + SUPPORT_IMPORT_START + "sentence\"\n}\n", form)
	testing.expect_value(t, len(inside_procedure), 1)
}

// The repository holds the rules: each import of each source of src/ follows
// the rule of its file, and each host test that imports a package of the
// core library names its build line.
@(test)
library_imports_of_the_repository :: proc(t: ^testing.T) {
	reading, read_ok := library_import_breaches_of_tree("")
	testing.expect(t, read_ok, "the sources cannot be read")
	for breach in reading.breaches {
		testing.expect(t, false, library_import_breach_sentence(breach))
	}
	testing.expect(t, reading.source_count > 0 && reading.test_count > 0 && reading.import_count > 0, "the check read no file or no import: a folder of the check is empty")
	testing.expect(t, reading.copy_count > 0, "the copy of the cryptography of Odin is not read")
}
