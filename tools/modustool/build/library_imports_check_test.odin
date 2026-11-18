package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "modustool:foundation"

// A small tree with a kernel, two contract packages, one support package and
// the manifest of the cryptography of Odin, at the folders of the tool: the
// check reads them there. Each file is one import that the rule allows. The
// tree holds each folder of src/ that the check walks, and an empty folder
// of the tool: a folder that it names and the tree lacks stops the read of
// the whole tree.
@(private = "file")
library_tree_make :: proc(t: ^testing.T) -> (root: string) {
	folder, error := os.make_directory_temp("", "library_imports_test_*", context.temp_allocator)
	testing.expect_value(t, error, nil)
	folders := foundation.SOURCE_FOLDERS
	for name in folders {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, LIBRARY_IMPORTS_TOOL_FOLDER))
	for name in ([]string{foundation.SOURCE_FOLDER_CONTRACT + "/ring", foundation.SOURCE_FOLDER_CONTRACT + "/record/inner", foundation.SOURCE_FOLDER_SUPPORT + "/sentence", foundation.SOURCE_FOLDER_SUPPORT + "/cryptography"}) {
		_ = os.make_directory_all(fmt.tprintf("%s/%s", folder, name))
	}
	library_tree_file_write(folder, foundation.SOURCE_FOLDER_KERNEL + "/enter.odin", "package kernel\n\nimport \"base:intrinsics\"\nimport ring \"" + foundation.CONTRACT_IMPORT_START + "ring\"\nimport \"" + foundation.CONTRACT_IMPORT_START + "record/inner\"\n")
	library_tree_file_write(folder, foundation.SOURCE_FOLDER_CONTRACT + "/ring/ring.odin", "package ring\n\nimport \"" + foundation.CONTRACT_IMPORT_START + "record/inner\"\n")
	library_tree_file_write(folder, foundation.SOURCE_FOLDER_CONTRACT + "/ring/ring_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage ring\n\nimport \"core:testing\"\nimport \"core:math/rand\"\n")
	library_tree_file_write(folder, foundation.SOURCE_FOLDER_CONTRACT + "/record/inner/inner.odin", "package inner\n")
	library_tree_file_write(folder, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/sentence.odin", "package sentence\n\nimport \"base:intrinsics\"\nimport ring \"" + foundation.CONTRACT_IMPORT_START + "ring\"\n")
	library_tree_file_write(folder, foundation.CRYPTOGRAPHY_MANIFEST, "# The cryptography of Odin: this tree has no copy.\n")
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
			foundation.CONTRACT_IMPORT_START + "../support/sentence",
			"core:",
			"modus:",
			"",
		}) {
		for form in ([]Library_Source_Form{kernel_source, kernel_test, contract_source, contract_test, system_source, system_test, copied_source}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is refused in %v", path, form)
		}
	}

	// A relative path names a folder of the repository: a host test of a
	// source of the system and a file of the copy reach a folder there, as
	// the runtime. Where the path lands is another rule. A source that is not
	// a test imports no relative path.
	for form in ([]Library_Source_Form{system_test, copied_source}) {
		for path in ([]string{"../sentence", "./ref", "../../../runtime"}) {
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
		for path in ([]string{"base:intrinsics", "base:runtime", foundation.SOURCE_LIBRARY_IMPORT_START + "support/sentence", foundation.CONTRACT_IMPORT_START + "ring"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
	}
	for path in ([]string{"core:os", "core:fmt", "core:testing"}) {
		testing.expectf(t, !library_import_is_allowed(path, system_source), "%q is not an import of a source that is not a test", path)
		testing.expectf(t, library_import_is_allowed(path, copied_source), "%q is an import of the copy of the cryptography of Odin", path)
	}

	// A test runs on the host: the whole core library is open to it, with its
	// build line.
	for path in ([]string{"base:intrinsics", "core:testing", "core:math/rand", "core:os", foundation.SOURCE_LIBRARY_IMPORT_START + "support/sentence", foundation.CONTRACT_IMPORT_START + "ring"}) {
		testing.expectf(t, library_import_is_allowed(path, system_test), "%q is an import of a test", path)
	}

	// The kernel and a contract package import the contract packages only,
	// and a test of them adds the core library.
	for form in ([]Library_Source_Form{kernel_source, contract_source}) {
		for path in ([]string{"base:intrinsics", foundation.CONTRACT_IMPORT_START + "ring", foundation.CONTRACT_IMPORT_START + "record/inner"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
		for path in ([]string{foundation.SUPPORT_IMPORT_START + "sentence", foundation.SOURCE_LIBRARY_IMPORT_START + "contract", "core:testing", "core:os"}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is not an import of %v", path, form)
		}
	}
	for form in ([]Library_Source_Form{kernel_test, contract_test}) {
		for path in ([]string{"base:intrinsics", "core:testing", "core:os", foundation.CONTRACT_IMPORT_START + "ring"}) {
			testing.expectf(t, library_import_is_allowed(path, form), "%q is an import of %v", path, form)
		}
		for path in ([]string{foundation.SUPPORT_IMPORT_START + "sentence", foundation.SOURCE_LIBRARY_IMPORT_START + "contract"}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is not an import of %v", path, form)
		}
	}

	// A kernel part: the kernel itself ("kernel:" alone, "kernel:."), a path
	// with a part "." or ".." are refused in each form, a kernel part in each form outside the
	// kernel, and the last case, a kernel part in the kernel and its tests.
	for path in ([]string{foundation.KERNEL_IMPORT_START, foundation.KERNEL_IMPORT_START + ".", foundation.KERNEL_IMPORT_START + "./iommu", foundation.KERNEL_IMPORT_START + "iommu/.", foundation.CONTRACT_IMPORT_START + "./ring", foundation.KERNEL_IMPORT_START + "../processes/clock", foundation.KERNEL_IMPORT_START + "iommu/../../processes"}) {
		for form in ([]Library_Source_Form{kernel_source, kernel_test, contract_source, contract_test, system_source, system_test, copied_source}) {
			testing.expectf(t, !library_import_is_allowed(path, form), "%q is refused in %v", path, form)
		}
	}
	for form in ([]Library_Source_Form{contract_source, contract_test, system_source, system_test, copied_source}) {
		testing.expectf(t, !library_import_is_allowed(foundation.KERNEL_IMPORT_START + "iommu", form), "a kernel part is not an import of %v", form)
	}
	for form in ([]Library_Source_Form{kernel_source, kernel_test}) {
		testing.expectf(t, library_import_is_allowed(foundation.KERNEL_IMPORT_START + "iommu", form), "a kernel part is an import of %v", form)
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
	testing.expectf(t, len(reading.breaches[:]) == 0, "%v", reading.breaches[:])
	testing.expect_value(t, reading.source_count, 4)
	testing.expect_value(t, reading.test_count, 1)
	testing.expect_value(t, reading.copy_count, 0)
	testing.expect_value(t, reading.import_count, 8)
	testing.expect_value(t, reading.tool_count, 0)
}

// The two imports that the compiler refused when the kernel had the
// contract library only: a source of the kernel that imports a support
// package, and a contract package that imports a support package by a
// relative path. Each is refused with its file, its line and its text.
@(test)
library_import_of_a_support_package_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/report.odin", "package kernel\n\nimport \"base:intrinsics\"\n// A comment.\nimport sentence \"" + foundation.SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_CONTRACT + "/ring/write.odin", "package ring\n\nimport \"../../support/sentence\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches[:]), 2) {
		return
	}
	in_kernel, kernel_found := breach_of_file(reading.breaches[:], foundation.SOURCE_FOLDER_KERNEL + "/report.odin")
	testing.expect(t, kernel_found, "the file of the kernel is not named")
	testing.expect_value(t, in_kernel.line, 5)
	testing.expect_value(t, in_kernel.text, "\"" + foundation.SUPPORT_IMPORT_START + "sentence\"")
	sentence := library_import_breach_sentence(in_kernel)
	testing.expect(t, strings.contains(sentence, foundation.SOURCE_FOLDER_KERNEL + "/report.odin:5: the import \"" + foundation.SUPPORT_IMPORT_START + "sentence\" is refused"), sentence)
	testing.expect(t, strings.contains(sentence, "the kernel imports no support package"), sentence)
	in_contract, contract_found := breach_of_file(reading.breaches[:], foundation.SOURCE_FOLDER_CONTRACT + "/ring/write.odin")
	testing.expect(t, contract_found, "the file of the contract package is not named")
	testing.expect_value(t, in_contract.line, 3)
	testing.expect_value(t, in_contract.text, "\"../../support/sentence\"")
}

// A kernel part is imported from the kernel only. A module, a support
// package, a host test of the library and a contract package that import
// one are each refused with their line; inside the kernel, the package of
// the kernel itself ("kernel:" alone) and a path with ".." are refused too.
// The last case: the kernel, a kernel part and its host test import one.
@(test)
library_import_of_a_kernel_part_outside_the_kernel_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	part :: foundation.KERNEL_IMPORT_START + "iommu"
	library_tree_folder_make(root, foundation.DEMONSTRATION_MODULE_SOURCES + "clock")
	library_tree_file_write(root, foundation.DEMONSTRATION_MODULE_SOURCES + "clock/main.odin", "package clock\n\nimport \"base:intrinsics\"\nimport iommu \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/tables.odin", "package sentence\n\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/tables_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"core:testing\"\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_CONTRACT + "/ring/device.odin", "package ring\n\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/itself.odin", "package kernel\n\nimport \"" + foundation.KERNEL_IMPORT_START + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/around.odin", "package kernel\n\nimport \"" + foundation.KERNEL_IMPORT_START + "../processes/clock\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/here.odin", "package kernel\n\nimport \"" + foundation.KERNEL_IMPORT_START + ".\"\n")
	// A host test outside the kernel reaches a kernel part by a relative
	// path, which the compiler accepts there: once to a part, once to the
	// folder of the kernel itself.
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/reach_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"core:testing\"\nimport \"../../../kernel/iommu\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/whole_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"../../../kernel\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(reading.breaches[:]) == 9, "%v", reading.breaches[:])
	relative, relative_found := breach_of_file(reading.breaches[:], foundation.SOURCE_FOLDER_SUPPORT + "/sentence/reach_test.odin")
	testing.expect(t, relative_found, "the test that reaches a kernel part by a relative path is not named")
	testing.expect_value(t, relative.line, 5)
	testing.expect_value(t, relative.text, "\"../../../kernel/iommu\"")
	module, module_found := breach_of_file(reading.breaches[:], foundation.DEMONSTRATION_MODULE_SOURCES + "clock/main.odin")
	testing.expect(t, module_found, "the module that imports a kernel part is not named")
	testing.expect_value(t, module.line, 4)
	testing.expect_value(t, module.text, "\"" + part + "\"")
	testing.expect_value(t, module.reason, Library_Import_Breach_Reason.Refused_Import)
	sentence := library_import_breach_sentence(module)
	testing.expect(t, strings.contains(sentence, foundation.DEMONSTRATION_MODULE_SOURCES + "clock/main.odin:4: the import \"" + part + "\" is refused"), sentence)
	testing.expect(t, strings.contains(sentence, "is imported from " + foundation.SOURCE_FOLDER_KERNEL + " only"), sentence)
	for file in ([]string{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/tables.odin", foundation.SOURCE_FOLDER_SUPPORT + "/sentence/tables_test.odin", foundation.SOURCE_FOLDER_CONTRACT + "/ring/device.odin", foundation.SOURCE_FOLDER_KERNEL + "/itself.odin", foundation.SOURCE_FOLDER_KERNEL + "/around.odin", foundation.SOURCE_FOLDER_KERNEL + "/here.odin", foundation.SOURCE_FOLDER_SUPPORT + "/sentence/whole_test.odin"}) {
		testing.expectf(t, breach_count_of_file(reading.breaches[:], file) == 1, "%s: the import is not refused one time", file)
	}

	// The kernel, a kernel part that imports another part and a contract
	// package, the host test of the part, and a host test of the library
	// whose relative path lands beside the kernel, not in it.
	clean := library_tree_make(t)
	defer os.remove_all(clean)
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/beside_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"../../../runtime\"\nimport \"../../../kernel_notes\"\n")
	library_tree_folder_make(clean, foundation.SOURCE_FOLDER_KERNEL + "/iommu")
	library_tree_folder_make(clean, foundation.SOURCE_FOLDER_KERNEL + "/acpi_processors")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_KERNEL + "/devices.odin", "package kernel\n\nimport iommu \"" + part + "\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_KERNEL + "/iommu/iommu.odin", "package iommu\n\nimport \"" + foundation.KERNEL_IMPORT_START + "acpi_processors\"\nimport ring \"" + foundation.CONTRACT_IMPORT_START + "ring\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_KERNEL + "/iommu/iommu_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage iommu\n\nimport \"core:testing\"\nimport \"" + foundation.KERNEL_IMPORT_START + "acpi_processors\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_KERNEL + "/acpi_processors/acpi_processors.odin", "package acpi_processors\n")
	accepted, accepted_ok := library_import_breaches_of_tree(clean)
	testing.expect(t, accepted_ok)
	testing.expectf(t, len(accepted.breaches[:]) == 0, "%v", accepted.breaches[:])
}

// A relative import never lands in the folder of a module from outside it.
// Each is refused with its line: from a host test of a support package, to
// the module, to a folder under it, to src/modules itself, to the folder of
// a group, and by a path that starts with "./"; from a host test of another
// module; and from files of tools/, at the top and inside a `when`. The
// last case: a relative import to the runtime, a foreign import of its
// assembly, a folder beside src/modules whose name starts the same, a host
// test of a module that reaches a folder of its own module, and a file of
// tools/ that holds the refused line only inside a text.
@(test)
library_relative_import_into_a_module_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_folder_make(root, foundation.SYSTEM_MODULE_SOURCES + "console")
	library_tree_folder_make(root, LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool")
	refused := []struct {
		file:   string,
		source: string,
		text:   string,
	} {
		{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/peer_test.odin", "", "\"../../../modules/libraries/cryptography\""},
		{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/inner_test.odin", "", "\"../../../modules/libraries/cryptography/inner\""},
		{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/whole_test.odin", "", "\"../../../modules\""},
		{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/group_test.odin", "", "\"../../../modules/libraries\""},
		{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/dot_test.odin", "", "\"./../../../modules/libraries/cryptography\""},
		{foundation.SYSTEM_MODULE_SOURCES + "console/main_test.odin", "", "\"../../libraries/cryptography\""},
		{LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool/peer.odin", "package modustool\n\nimport \"core:fmt\"\nimport cryptography_module \"../../src/modules/libraries/cryptography\"\n", "\"../../src/modules/libraries/cryptography\""},
		{LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool/inside_when.odin", "package modustool\n\nimport \"core:fmt\"\n\nwhen false {\n\timport \"../../src/modules/system/console\"\n}\n", "\"../../src/modules/system/console\""},
	}
	for item in refused {
		source := item.source
		if source == "" {
			source = strings.concatenate({LIBRARY_HOST_BUILD_LINE, "\npackage sentence\n\nimport \"core:testing\"\nimport ", item.text, "\n"}, context.temp_allocator)
		}
		library_tree_file_write(root, item.file, source)
	}
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(reading.breaches[:]) == len(refused), "%v", reading.breaches[:])
	testing.expect_value(t, reading.tool_count, 2)
	for item in refused {
		breach, found := breach_of_file(reading.breaches[:], item.file)
		if !testing.expectf(t, found, "%s is not refused", item.file) {
			continue
		}
		testing.expect_value(t, breach.reason, Library_Import_Breach_Reason.Relative_Import_Into_A_Module)
		testing.expect_value(t, breach.text, item.text)
		testing.expect_value(t, breach_count_of_file(reading.breaches[:], item.file), 1)
	}
	peer, peer_found := breach_of_file(reading.breaches[:], LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool/peer.odin")
	if testing.expect(t, peer_found, "the file of the tool is not refused") {
		testing.expect_value(t, peer.line, 4)
		sentence := library_import_breach_sentence(peer)
		testing.expect(t, strings.contains(sentence, LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool/peer.odin:4: the import \"../../src/modules/libraries/cryptography\" is refused"), sentence)
		testing.expect(t, strings.contains(sentence, foundation.PRIVATE_IMPORT_START + "<module>/<part>"), sentence)
	}
	inside_when, when_found := breach_of_file(reading.breaches[:], LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool/inside_when.odin")
	testing.expect(t, when_found && inside_when.line == 6, "the import of the tool inside a `when` is not read")

	// The last case.
	clean := library_tree_make(t)
	defer os.remove_all(clean)
	library_tree_folder_make(clean, foundation.SYSTEM_MODULE_SOURCES + "console")
	library_tree_folder_make(clean, LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/memory_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"core:testing\"\nimport \"../../../runtime\"\nimport \"../../../modules_notes\"\n\nforeign import memory \"../../../runtime/memory_for_host_tests.asm\"\n")
	library_tree_file_write(clean, foundation.SYSTEM_MODULE_SOURCES + "console/main_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage console\n\nimport \"core:testing\"\nimport \"./history\"\nimport \"../console/lines\"\n")
	library_tree_file_write(clean, LIBRARY_IMPORTS_TOOL_FOLDER + "/modustool/peer.odin", "package modustool\n\nimport \"core:fmt\"\nimport \"" + foundation.PRIVATE_IMPORT_START + "cryptography/cryptography_primitives\"\n\nforeign import memory \"../../src/runtime/memory_for_host_tests.asm\"\n\nFIXTURE :: `\nimport \"../../src/modules/libraries/cryptography\"\n`\n")
	accepted, accepted_ok := library_import_breaches_of_tree(clean)
	testing.expect(t, accepted_ok)
	testing.expectf(t, len(accepted.breaches[:]) == 0, "%v", accepted.breaches[:])
	testing.expect_value(t, accepted.tool_count, 1)
}

// A private part is imported from the folder of its module and from the
// private parts of the same module only. Each other importer is refused with
// its line: another module, a support package and its host test, a private
// part of another module, a contract package; and a path that names no
// module of the table, or a module and no part; and a source of a support
// package that imports a private part of a module of the group libraries.
// The last case: the module, a private part of the same module and its host
// test import it, and a host test of a support package imports a private
// part of a module of the group libraries, which it stands in for.
@(test)
library_import_of_a_private_part_from_another_module_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	part :: foundation.PRIVATE_IMPORT_START + "console/line_cutter"
	library_part :: foundation.PRIVATE_IMPORT_START + "cryptography/cryptography_primitives"
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/seal.odin", "package sentence\n\nimport \"" + library_part + "\"\n")
	library_tree_folder_make(root, foundation.SOURCE_FOLDER_PRIVATE + "/console/line_cutter")
	library_tree_folder_make(root, foundation.SOURCE_FOLDER_PRIVATE + "/compositor/panel")
	library_tree_folder_make(root, foundation.SYSTEM_MODULE_SOURCES + "compositor")
	library_tree_folder_make(root, foundation.SYSTEM_MODULE_SOURCES + "console")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_PRIVATE + "/console/line_cutter/cutter.odin", "package line_cutter\n")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "compositor/main.odin", "package compositor\n\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/cut.odin", "package sentence\n\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/cut_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"core:testing\"\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_PRIVATE + "/compositor/panel/panel.odin", "package panel\n\nimport \"" + part + "\"\n")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "console/unknown.odin", "package console\n\nimport \"" + foundation.PRIVATE_IMPORT_START + "no_such_module/part\"\n")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "console/short.odin", "package console\n\nimport \"" + foundation.PRIVATE_IMPORT_START + "console\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_CONTRACT + "/ring/cut.odin", "package ring\n\nimport \"" + part + "\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(reading.breaches[:]) == 8, "%v", reading.breaches[:])
	other, other_found := breach_of_file(reading.breaches[:], foundation.SYSTEM_MODULE_SOURCES + "compositor/main.odin")
	testing.expect(t, other_found, "the module that imports a private part of another module is not named")
	testing.expect_value(t, other.line, 3)
	testing.expect_value(t, other.text, "\"" + part + "\"")
	testing.expect_value(t, other.reason, Library_Import_Breach_Reason.Private_Part_Of_Another_Module)
	sentence := library_import_breach_sentence(other)
	testing.expect(t, strings.contains(sentence, foundation.SYSTEM_MODULE_SOURCES + "compositor/main.odin:3: the import \"" + part + "\" is refused"), sentence)
	for file in ([]string{foundation.SOURCE_FOLDER_SUPPORT + "/sentence/seal.odin", foundation.SOURCE_FOLDER_SUPPORT + "/sentence/cut.odin", foundation.SOURCE_FOLDER_SUPPORT + "/sentence/cut_test.odin", foundation.SOURCE_FOLDER_PRIVATE + "/compositor/panel/panel.odin", foundation.SYSTEM_MODULE_SOURCES + "console/unknown.odin", foundation.SYSTEM_MODULE_SOURCES + "console/short.odin"}) {
		breach, found := breach_of_file(reading.breaches[:], file)
		testing.expectf(t, found && breach.reason == .Private_Part_Of_Another_Module && breach_count_of_file(reading.breaches[:], file) == 1, "%s: the import is not refused one time as a private part of another module", file)
	}
	// A contract package imports no private part, by the rule of its folder.
	in_contract, contract_found := breach_of_file(reading.breaches[:], foundation.SOURCE_FOLDER_CONTRACT + "/ring/cut.odin")
	testing.expect(t, contract_found && in_contract.reason == .Refused_Import, "the contract package that imports a private part is not refused")

	// The last case: the module, a private part of the same module, and the
	// host test of that part.
	clean := library_tree_make(t)
	defer os.remove_all(clean)
	library_tree_folder_make(clean, foundation.SOURCE_FOLDER_PRIVATE + "/console/line_cutter")
	library_tree_folder_make(clean, foundation.SOURCE_FOLDER_PRIVATE + "/console/history")
	library_tree_folder_make(clean, foundation.SYSTEM_MODULE_SOURCES + "console")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_PRIVATE + "/console/line_cutter/cutter.odin", "package line_cutter\n")
	library_tree_file_write(clean, foundation.SYSTEM_MODULE_SOURCES + "console/main.odin", "package console\n\nimport \"" + part + "\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_PRIVATE + "/console/history/history.odin", "package history\n\nimport \"" + part + "\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_PRIVATE + "/console/history/history_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage history\n\nimport \"core:testing\"\nimport \"" + part + "\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/seal_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage sentence\n\nimport \"core:testing\"\nimport \"" + library_part + "\"\n")
	accepted, accepted_ok := library_import_breaches_of_tree(clean)
	testing.expect(t, accepted_ok)
	testing.expectf(t, len(accepted.breaches[:]) == 0, "%v", accepted.breaches[:])
}

// The owners of a package are the bodies of code whose chain of imports
// reaches it, and a test is no owner. Refused: a support package that no
// body reaches, one that one module reaches (also through a private part of
// that module, so by two importing files, and also when a host test of
// another module imports it), and a private part that its module does not
// reach. The last case: a support package with two owners, one through a
// private part, and a private part that its module reaches.
@(test)
library_support_package_with_one_owner_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	for folder in ([]string{foundation.SOURCE_FOLDER_SUPPORT + "/alone", foundation.SOURCE_FOLDER_SUPPORT + "/twice", foundation.SOURCE_FOLDER_PRIVATE + "/console/history", foundation.SOURCE_FOLDER_PRIVATE + "/console/unused", foundation.SYSTEM_MODULE_SOURCES + "console", foundation.SYSTEM_MODULE_SOURCES + "compositor"}) {
		library_tree_folder_make(root, folder)
	}
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/alone/alone.odin", "package alone\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/twice/twice.odin", "package twice\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_PRIVATE + "/console/history/history.odin", "package history\n\nimport \"" + foundation.SUPPORT_IMPORT_START + "twice\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_PRIVATE + "/console/unused/unused.odin", "package unused\n")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "console/main.odin", "package console\n\nimport \"" + foundation.SUPPORT_IMPORT_START + "alone\"\nimport \"" + foundation.SUPPORT_IMPORT_START + "twice\"\nimport \"" + foundation.PRIVATE_IMPORT_START + "console/history\"\n")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "compositor/main_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage compositor\n\nimport \"core:testing\"\nimport \"" + foundation.SUPPORT_IMPORT_START + "alone\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(reading.breaches[:]) == 0, "%v", reading.breaches[:])
	owners := library_owner_breaches(reading)
	testing.expectf(t, len(owners) == 4, "%v", owners)
	nobody, nobody_found := breach_of_file(owners, foundation.SOURCE_FOLDER_SUPPORT + "/sentence")
	testing.expect(t, nobody_found && nobody.reason == .Support_Package_With_One_Owner && nobody.text == "", "the support package that no body reaches is not refused")
	testing.expect(t, strings.contains(library_import_breach_sentence(nobody), "no body of code reaches this support package"), library_import_breach_sentence(nobody))
	for folder in ([]string{foundation.SOURCE_FOLDER_SUPPORT + "/alone", foundation.SOURCE_FOLDER_SUPPORT + "/twice"}) {
		breach, found := breach_of_file(owners, folder)
		testing.expectf(t, found && breach.reason == .Support_Package_With_One_Owner && breach.text == "console", "%s: %v", folder, breach)
		sentence := library_import_breach_sentence(breach)
		testing.expect(t, strings.contains(sentence, foundation.join(folder, ": only console reaches this support package")) && strings.contains(sentence, foundation.SOURCE_FOLDER_PRIVATE + "/<module>/"), sentence)
	}
	unused, unused_found := breach_of_file(owners, foundation.SOURCE_FOLDER_PRIVATE + "/console/unused")
	testing.expect(t, unused_found && unused.reason == .Private_Part_Without_Its_Module && unused.text == "", "the private part that its module does not reach is not refused")

	// The last case.
	clean := library_tree_make(t)
	defer os.remove_all(clean)
	for folder in ([]string{foundation.SOURCE_FOLDER_SUPPORT + "/twice", foundation.SOURCE_FOLDER_PRIVATE + "/console/history", foundation.SYSTEM_MODULE_SOURCES + "console", foundation.SYSTEM_MODULE_SOURCES + "compositor"}) {
		library_tree_folder_make(clean, folder)
	}
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_SUPPORT + "/twice/twice.odin", "package twice\n\nimport \"" + foundation.SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_PRIVATE + "/console/history/history.odin", "package history\n\nimport \"" + foundation.SUPPORT_IMPORT_START + "twice\"\n")
	library_tree_file_write(clean, foundation.SYSTEM_MODULE_SOURCES + "console/main.odin", "package console\n\nimport \"" + foundation.PRIVATE_IMPORT_START + "console/history\"\n")
	library_tree_file_write(clean, foundation.SYSTEM_MODULE_SOURCES + "compositor/main.odin", "package compositor\n\nimport \"" + foundation.SUPPORT_IMPORT_START + "twice\"\n")
	accepted, accepted_ok := library_import_breaches_of_tree(clean)
	testing.expect(t, accepted_ok)
	testing.expectf(t, len(accepted.breaches[:]) == 0, "%v", accepted.breaches[:])
	accepted_owners := library_owner_breaches(accepted)
	testing.expectf(t, len(accepted_owners) == 0, "%v", accepted_owners)
}

// The boot program, which is no module, owns the private parts under
// private/boot_program. Refused: a module that imports such a part, and a
// part that the boot program does not reach. The last case: the boot
// program imports its part, which then has its one owner.
@(test)
library_private_part_of_the_boot_program :: proc(t: ^testing.T) {
	part :: foundation.SOURCE_FOLDER_PRIVATE + "/" + PRIVATE_PART_OF_THE_BOOT_PROGRAM + "/memory_map"
	unused :: foundation.SOURCE_FOLDER_PRIVATE + "/" + PRIVATE_PART_OF_THE_BOOT_PROGRAM + "/unused"
	import_line :: "import \"" + foundation.PRIVATE_IMPORT_START + PRIVATE_PART_OF_THE_BOOT_PROGRAM + "/memory_map\"\n"
	root := library_tree_make(t)
	defer os.remove_all(root)
	for folder in ([]string{part, unused, foundation.SOURCE_FOLDER_BOOT, foundation.SYSTEM_MODULE_SOURCES + "console"}) {
		library_tree_folder_make(root, folder)
	}
	library_tree_file_write(root, part + "/memory_map.odin", "package memory_map\n")
	library_tree_file_write(root, unused + "/unused.odin", "package unused\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_BOOT + "/main.odin", "package boot\n\n" + import_line)
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "console/main.odin", "package console\n\n" + import_line)
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	module_breach, module_found := breach_of_file(reading.breaches[:], foundation.SYSTEM_MODULE_SOURCES + "console/main.odin")
	testing.expectf(t, module_found && module_breach.reason == .Private_Part_Of_Another_Module, "a module that imports a part of the boot program is not refused: %v", reading.breaches[:])
	_, boot_refused := breach_of_file(reading.breaches[:], foundation.SOURCE_FOLDER_BOOT + "/main.odin")
	testing.expect(t, !boot_refused, "the boot program is refused its own private part")
	owners := library_owner_breaches(reading)
	unused_breach, unused_found := breach_of_file(owners, unused)
	testing.expectf(t, unused_found && unused_breach.reason == .Private_Part_Without_Its_Module, "a part that the boot program does not reach is not refused: %v", owners)

	// The last case.
	clean := library_tree_make(t)
	defer os.remove_all(clean)
	for folder in ([]string{part, foundation.SOURCE_FOLDER_BOOT}) {
		library_tree_folder_make(clean, folder)
	}
	library_tree_file_write(clean, part + "/memory_map.odin", "package memory_map\n")
	library_tree_file_write(clean, foundation.SOURCE_FOLDER_BOOT + "/main.odin", "package boot\n\n" + import_line)
	accepted, accepted_ok := library_import_breaches_of_tree(clean)
	testing.expect(t, accepted_ok)
	testing.expectf(t, len(accepted.breaches[:]) == 0, "%v", accepted.breaches[:])
	// The tree of the test has a support package that no body reaches; only
	// the part of the boot program matters here.
	_, part_refused := breach_of_file(library_owner_breaches(accepted), part)
	testing.expect(t, !part_refused, "the part that the boot program reaches is refused")
}

// A source of a kernel part keeps no state and reaches no machine. Each
// impure construct is refused with its line: a package variable with no
// @(rodata), a variable marked @(static) or @(thread_local) (also beside
// @(rodata)), a foreign import and a foreign block, an asm template, and an
// intrinsic that reads the machine, also under another local name. The
// same constructs in the package of the kernel itself and in a test of the
// part are not read by this rule. The last case: a part with @(rodata)
// tables and a pure intrinsic passes.
@(test)
library_kernel_part_that_is_not_pure_is_refused :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	part :: foundation.SOURCE_FOLDER_KERNEL + "/iommu"
	library_tree_folder_make(root, part)
	library_tree_file_write(root, part + "/state.odin", "package iommu\n\ncount := 0\n")
	library_tree_file_write(root, part + "/static.odin", "package iommu\n\nnext :: proc \"contextless\" () -> int {\n\t@(static) calls: int\n\tcalls += 1\n\treturn calls\n}\n")
	library_tree_file_write(root, part + "/thread.odin", "package iommu\n\n@(rodata, thread_local)\nlast := 0\n")
	library_tree_file_write(root, part + "/outside.odin", "package iommu\n\nforeign import kernel_symbols \"kernel_symbols.o\"\n\nforeign kernel_symbols {\n\tkernel_symbol :: proc() ---\n}\n")
	library_tree_file_write(root, part + "/template.odin", "package iommu\n\nbarrier :: asm() [\n\t#volatile,\n\t#clobber memory,\n] {\n\tmfence\n}\n")
	library_tree_file_write(root, part + "/machine.odin", "package iommu\n\nimport \"base:intrinsics\"\n\nstamp :: proc \"contextless\" () -> i64 {\n\treturn intrinsics.read_cycle_counter()\n}\n")
	library_tree_file_write(root, part + "/renamed.odin", "package iommu\n\nimport processor \"base:intrinsics\"\n\nidentify :: proc \"contextless\" () -> u32 {\n\teax, _, _, _ := processor.x86_cpuid(0, 0)\n\treturn eax\n}\n")
	// Not a kernel part: the package of the kernel holds its state, and a
	// host test of the part runs on the host.
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/state.odin", "package kernel\n\ncount := 0\n")
	library_tree_file_write(root, part + "/state_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage iommu\n\nimport \"core:testing\"\n\nruns := 0\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expectf(t, len(reading.breaches[:]) == 8, "%v", reading.breaches[:])
	for breach in reading.breaches {
		testing.expectf(t, breach.reason == .Impure_Kernel_Part, "%v is not an impure construct", breach)
	}
	expected := []struct {
		file:  string,
		line:  int,
		words: string,
	} {
		{part + "/state.odin", 3, "the package variable count with no @(rodata)"},
		{part + "/static.odin", 4, "a variable marked @(static)"},
		{part + "/thread.odin", 4, "a variable marked @(thread_local)"},
		{part + "/template.odin", 3, "an asm template"},
		{part + "/machine.odin", 6, "the intrinsic intrinsics.read_cycle_counter, which reads the machine"},
		{part + "/renamed.odin", 6, "the intrinsic processor.x86_cpuid, which reads the machine"},
	}
	for item in expected {
		breach, found := breach_of_file(reading.breaches[:], item.file)
		if !testing.expectf(t, found, "%s is not refused", item.file) {
			continue
		}
		testing.expect_value(t, breach.line, item.line)
		testing.expect_value(t, breach.text, item.words)
		testing.expect_value(t, breach_count_of_file(reading.breaches[:], item.file), 1)
	}
	testing.expect_value(t, breach_count_of_file(reading.breaches[:], part + "/outside.odin"), 2)
	sentence := library_import_breach_sentence(reading.breaches[0])
	testing.expect(t, strings.contains(sentence, "a kernel part is pure, so each package variable is @(rodata)"), sentence)

	// The last case: tables marked @(rodata), one of them beside another
	// attribute, constants, and an intrinsic that computes a value.
	clean := library_tree_make(t)
	defer os.remove_all(clean)
	library_tree_folder_make(clean, part)
	library_tree_file_write(clean, part + "/pure.odin", "package iommu\n\nimport \"base:intrinsics\"\n\nLIMIT :: 4\n\n@(rodata)\nTEXTS := [2]string{\"a\", \"b\"}\n\n@(private, rodata)\nCODES := [2]u8{1, 2}\n\nones :: proc \"contextless\" (value: u32) -> u32 {\n\treturn intrinsics.count_ones(value)\n}\n")
	accepted, accepted_ok := library_import_breaches_of_tree(clean)
	testing.expect(t, accepted_ok)
	testing.expectf(t, len(accepted.breaches[:]) == 0, "%v", accepted.breaches[:])
}

// The check reads what the compiler leaves out: an import inside a `when`
// whose condition is false, a file that a build tag leaves out, and a test.
@(test)
library_import_that_the_compiler_leaves_out_is_read :: proc(t: ^testing.T) {
	root := library_tree_make(t)
	defer os.remove_all(root)
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/inside_when.odin", "package kernel\n\nwhen false {\n\timport \"" + foundation.SUPPORT_IMPORT_START + "sentence\"\n} else {\n\timport \"../beside\"\n}\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_KERNEL + "/other_system.odin", "#+build windows\npackage kernel\n\nimport \"" + foundation.SUPPORT_IMPORT_START + "sentence\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_CONTRACT + "/ring/write_test.odin", LIBRARY_HOST_BUILD_LINE + "\npackage ring\n\nimport \"core:testing\"\nimport \"" + foundation.SUPPORT_IMPORT_START + "sentence\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	testing.expect_value(t, len(reading.breaches[:]), 4)
	inside_when := 0
	for breach in reading.breaches {
		if strings.has_suffix(breach.file, "/inside_when.odin") {
			inside_when += 1
			testing.expect(t, breach.line == 4 || breach.line == 6, "the line of an import inside a `when`")
		}
	}
	testing.expect_value(t, inside_when, 2)
	other_system, other_found := breach_of_file(reading.breaches[:], "/other_system.odin")
	testing.expect(t, other_found, "a file that a build tag leaves out is read")
	testing.expect_value(t, other_system.line, 4)
	in_test, test_found := breach_of_file(reading.breaches[:], "/write_test.odin")
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
	library_tree_folder_make(root, foundation.SYSTEM_MODULE_SOURCES + "console")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "console/main.odin", "package console\n\nimport \"core:os\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_BOOT + "/inside_when.odin", "package boot\n\nwhen false {\n\timport \"core:fmt\"\n}\n")
	library_tree_file_write(root, foundation.SYSTEM_MODULE_SOURCES + "console/on_the_host.odin", LIBRARY_HOST_BUILD_LINE + "\npackage console\n\nimport \"core:fmt\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches[:]), 3) {
		return
	}
	main_source, main_found := breach_of_file(reading.breaches[:], "/console/main.odin")
	testing.expect(t, main_found, "a source that is not a test imports no core:os")
	testing.expect_value(t, main_source.line, 3)
	inside_when, when_found := breach_of_file(reading.breaches[:], "/boot/inside_when.odin")
	testing.expect(t, when_found, "an import inside a `when` is read")
	testing.expect_value(t, inside_when.line, 4)
	on_the_host, host_found := breach_of_file(reading.breaches[:], "/console/on_the_host.odin")
	testing.expect(t, host_found, "the build line of the host does not allow a source that is not a test to import core:")
	testing.expect_value(t, on_the_host.line, 4)
	for breach in reading.breaches {
		testing.expect_value(t, breach.reason, Library_Import_Breach_Reason.Refused_Import)
		testing.expect(t, strings.contains(library_import_breach_sentence(breach), "a source of src/ that is not a test imports a package of base: or of " + foundation.SOURCE_LIBRARY_IMPORT_START), library_import_breach_sentence(breach))
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
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/sentence_test.odin", "package sentence\n\nimport \"core:testing\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/other_test.odin", "#+build linux\npackage sentence\n\nimport \"core:testing\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/comma_test.odin", "#+build !freestanding, linux\npackage sentence\n\nimport \"core:testing\"\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/small_test.odin", "package sentence\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_CONTRACT + "/ring/fast_test_amd64.odin", LIBRARY_HOST_BUILD_LINE + "\npackage ring\n\nimport \"core:testing\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches[:]), 3) {
		return
	}
	no_line, no_line_found := breach_of_file(reading.breaches[:], "/sentence/sentence_test.odin")
	testing.expect(t, no_line_found, "the test without the line is not named")
	testing.expect_value(t, no_line.reason, Library_Import_Breach_Reason.Test_Without_Build_Line)
	testing.expect_value(t, no_line.line, 3)
	testing.expect_value(t, no_line.text, "\"core:testing\"")
	sentence := library_import_breach_sentence(no_line)
	testing.expect(t, strings.contains(sentence, "/sentence/sentence_test.odin:3: the test imports \"core:testing\" and has no build line"), sentence)
	testing.expect(t, strings.contains(sentence, LIBRARY_HOST_BUILD_LINE), sentence)
	other, other_found := breach_of_file(reading.breaches[:], "/sentence/other_test.odin")
	testing.expect(t, other_found, "the first build line is the one of the host, whatever comes after it")
	testing.expect_value(t, other.reason, Library_Import_Breach_Reason.Test_Without_Build_Line)
	testing.expect_value(t, other.line, 4)
	comma, comma_found := breach_of_file(reading.breaches[:], "/sentence/comma_test.odin")
	testing.expect(t, comma_found, "a tag after a comma would allow a build that is freestanding")
	testing.expect_value(t, comma.reason, Library_Import_Breach_Reason.Test_Without_Build_Line)
	testing.expect_value(t, breach_count_of_file(reading.breaches[:], "/sentence/small_test.odin"), 0)
	testing.expect_value(t, breach_count_of_file(reading.breaches[:], "/ring/fast_test_amd64.odin"), 0)
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
	library_tree_folder_make(root, foundation.SOURCE_FOLDER_SUPPORT + "/cryptography/aes")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/cryptography/aes/aes_impl.odin", "package aes\n\nimport \"core:reflect\"\nimport \"../_subtle\"\n")
	library_tree_file_write(root, foundation.CRYPTOGRAPHY_MANIFEST, "# The cryptography of Odin.\n" + foundation.SOURCE_FOLDER_SUPPORT + "/cryptography/aes/aes_impl.odin core/crypto/aes/aes_impl.odin a-hash\n")
	library_tree_file_write(root, foundation.SOURCE_FOLDER_SUPPORT + "/sentence/reflect.odin", "package sentence\n\nimport \"core:reflect\"\n")
	reading, read_ok := library_import_breaches_of_tree(root)
	testing.expect(t, read_ok)
	if !testing.expect_value(t, len(reading.breaches[:]), 1) {
		return
	}
	testing.expect_value(t, breach_count_of_file(reading.breaches[:], "/cryptography/aes/aes_impl.odin"), 0)
	testing.expect_value(t, breach_count_of_file(reading.breaches[:], "/sentence/reflect.odin"), 1)
	testing.expect_value(t, reading.copy_count, 1)
	testing.expect_value(t, reading.source_count, 5)
}

// The other forms that leave the contract packages: a path that goes up
// from a contract package, a library of the compiler that the project has
// not, one of the two names that the libraries had, and a package of the
// core library in a source that is not a test.
@(test)
library_import_of_another_form_is_refused :: proc(t: ^testing.T) {
	breaches, import_count := library_import_breaches_of_source("src/kernel/forms.odin", "package kernel\n\nimport \"" + foundation.CONTRACT_IMPORT_START + "../support/sentence\"\nimport \"vendor:glfw\"\nimport \"support:sentence\"\nimport \"core:testing\"\n", Library_Source_Form{kind = .Kernel})
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
	inside_procedure, _ := library_import_breaches_of_source("src/kernel/inside.odin", "package kernel\n\nwork :: proc() {\n\timport \"" + foundation.SUPPORT_IMPORT_START + "sentence\"\n}\n", form)
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
	for breach in library_owner_breaches(reading) {
		testing.expect(t, false, library_import_breach_sentence(breach))
	}
	testing.expect(t, reading.source_count > 0 && reading.test_count > 0 && reading.import_count > 0, "the check read no file or no import: a folder of the check is empty")
	testing.expect(t, reading.copy_count > 0, "the copy of the cryptography of Odin is not read")
}
