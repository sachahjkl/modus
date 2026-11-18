// The folders of the sources of the system: the one place of the tool that
// writes where each is (src/md/infrastructure/repository_layout.md). Each
// other path of a source in the tool is made from these constants, so the
// move of a folder is a change of one line of this file. A path that is
// written as text in another file is a folder that a check no longer reads
// after a move, with no error.
package modustool

import "core:strings"

SOURCE_FOLDER_KERNEL :: "src/kernel" // The kernel.
SOURCE_FOLDER_BOOT :: "src/boot" // The boot program.
SOURCE_FOLDER_RUNTIME :: "src/runtime" // The memory procedures in assembly.
SOURCE_FOLDER_MODULES :: "src/modules" // Each module of the system: one folder for each, in the folder of its module group.
SOURCE_FOLDER_LIBRARY :: "src/library" // The source library of the system: the three folders below, and nothing else.
SOURCE_FOLDER_CONTRACT :: SOURCE_FOLDER_LIBRARY + "/" + LIBRARY_PART_CONTRACT // The contract packages.
SOURCE_FOLDER_SUPPORT :: SOURCE_FOLDER_LIBRARY + "/" + LIBRARY_PART_SUPPORT // The support packages.
SOURCE_FOLDER_PRIVATE :: SOURCE_FOLDER_LIBRARY + "/" + LIBRARY_PART_PRIVATE // The private parts: one folder for each module that has one, named by the module.

// Each folder of the sources of the system. A list of the tool that reads
// a part of them names its folders by their constants, in its own order:
// the order of a list can be the order of an output.
SOURCE_FOLDERS :: [?]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_BOOT, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_CONTRACT, SOURCE_FOLDER_SUPPORT, SOURCE_FOLDER_PRIVATE}

// The folders of the sources that a move removed. The check of the source
// paths in the documents reads a code span that starts with one of them,
// and refuses it: a document that still names the old place is stale.
SOURCE_FOLDERS_GONE :: [?]string{"src/programs"}

// The module groups (src/md/infrastructure/repository_layout.md, "The
// module groups"): the folder of src/modules that holds a module says what
// it is for. The group is not in the module file, and no loader reads it:
// it says where a source lives, and whether a release ships it.
Module_Group :: enum {
	System, // The root service, the services, the desktop, the tools of a principal.
	Libraries, // The modules that export functions and have no entry, which other modules import.
	Demonstrations, // The demonstration modules, which each show a property to a principal.
	Tests, // The test modules, which only a machine test starts or imports.
}

// The start of the source of a row of the table of the modules, one for
// each group: a row names its folder as SYSTEM_MODULE_SOURCES + "root".
SYSTEM_MODULE_SOURCES :: SOURCE_FOLDER_MODULES + "/system/"
LIBRARY_MODULE_SOURCES :: SOURCE_FOLDER_MODULES + "/libraries/"
DEMONSTRATION_MODULE_SOURCES :: SOURCE_FOLDER_MODULES + "/demonstrations/"
TEST_MODULE_SOURCES :: SOURCE_FOLDER_MODULES + "/tests/"

// The start of the source of each group, as the procedure below reads it.
MODULE_GROUP_SOURCES :: [Module_Group]string {
	.System         = SYSTEM_MODULE_SOURCES,
	.Libraries      = LIBRARY_MODULE_SOURCES,
	.Demonstrations = DEMONSTRATION_MODULE_SOURCES,
	.Tests          = TEST_MODULE_SOURCES,
}

// module_group_of_source gives the group of the source folder of a module,
// from the folder that holds it. found is false for a folder in no group:
// the kernel, and a folder outside src/modules.
module_group_of_source :: proc(source: string) -> (group: Module_Group, found: bool) {
	starts := MODULE_GROUP_SOURCES
	for start, candidate in starts {
		if len(source) > len(start) && strings.has_prefix(source, start) {
			return candidate, true
		}
	}
	return .System, false
}

// The name of the one source library of the system: the word before the
// ":" of an import line (docs/glossary/communication.md, "Source library"). The name is
// not the folder: the flag of the compiler joins the two.
SOURCE_LIBRARY_NAME :: "modus"

// The three parts of the library: the first folder of the path of a
// package, after the ":" of an import line.
LIBRARY_PART_CONTRACT :: "contract" // What two parties agree on.
LIBRARY_PART_SUPPORT :: "support" // What two modules or more compile in.
LIBRARY_PART_PRIVATE :: "private" // What one module alone compiles in: "private/<module>/<part>".

// The start of the path of an import of each part: "modus:contract/ring",
// "modus:support/system", "modus:private/storage/storage_tree".
SOURCE_LIBRARY_IMPORT_START :: SOURCE_LIBRARY_NAME + ":"
CONTRACT_IMPORT_START :: SOURCE_LIBRARY_IMPORT_START + LIBRARY_PART_CONTRACT + "/"
SUPPORT_IMPORT_START :: SOURCE_LIBRARY_IMPORT_START + LIBRARY_PART_SUPPORT + "/"
PRIVATE_IMPORT_START :: SOURCE_LIBRARY_IMPORT_START + LIBRARY_PART_PRIVATE + "/"

// The one flag of the compiler for the library. Each command of the tool
// that runs the compiler gives it, the compile of the kernel too: flake.nix
// gives the same flag when it builds this tool, and the build of a module
// outside the repository gives it with the path of this folder. With one library the
// compiler accepts an import of a support package in the kernel, so the
// tool refuses it before the first compiler starts
// (library_imports_check.odin).
SOURCE_LIBRARY_FLAG :: "-collection:" + SOURCE_LIBRARY_NAME + "=" + SOURCE_FOLDER_LIBRARY

// The second source library: the kernel parts, the pure packages in the
// folders under src/kernel that the kernel alone compiles in
// (src/md/infrastructure/repository_layout.md, "The kernel parts and the
// second source library"). Its folder is the folder of the kernel:
// "kernel:iommu" is the folder iommu of the kernel. Only the compile of the
// kernel, the host tests of the folders under src/kernel and the compile of
// this tool get its flag, so the compiler refuses the import in each module
// and in each host test of the library. The check of the imports refuses
// it in each other file of src/ too, because a language server gives one
// set of source libraries to every folder.
KERNEL_LIBRARY_NAME :: "kernel"
KERNEL_IMPORT_START :: KERNEL_LIBRARY_NAME + ":"
KERNEL_LIBRARY_FLAG :: "-collection:" + KERNEL_LIBRARY_NAME + "=" + SOURCE_FOLDER_KERNEL

// source_folder_takes_kernel_library says if the compile or the host test
// of a folder gets the flag of the kernel parts: the kernel, each folder
// under it, and this tool.
source_folder_takes_kernel_library :: proc(folder: string) -> bool {
	return folder == SOURCE_FOLDER_KERNEL || strings.has_prefix(folder, SOURCE_FOLDER_KERNEL + "/") || folder == TOOL_SOURCE_FOLDER
}

// source_library_package_folder gives the folder of the package that the
// path of an import line names in one of the two source libraries of the
// system: "modus:contract/ring" is the folder ring of the contract
// packages, "kernel:iommu" the kernel part iommu. A path of another library
// ("core:fmt") and a relative path are not found.
source_library_package_folder :: proc(import_path: string, allocator := context.temp_allocator) -> (folder: string, found: bool) {
	if len(import_path) > len(SOURCE_LIBRARY_IMPORT_START) && strings.has_prefix(import_path, SOURCE_LIBRARY_IMPORT_START) {
		return strings.concatenate({SOURCE_FOLDER_LIBRARY, "/", import_path[len(SOURCE_LIBRARY_IMPORT_START):]}, allocator), true
	}
	if len(import_path) > len(KERNEL_IMPORT_START) && strings.has_prefix(import_path, KERNEL_IMPORT_START) {
		return strings.concatenate({SOURCE_FOLDER_KERNEL, "/", import_path[len(KERNEL_IMPORT_START):]}, allocator), true
	}
	return "", false
}

// path_from_folder_to_root gives the relative path from a folder of the
// repository to its root: "../" for each part of the path of the folder.
// The compiler reads the path of a `#load` from the folder of the source
// that holds it, and the tool names a file from the root.
path_from_folder_to_root :: proc(folder: string) -> string {
	parts := strings.count(strings.trim_suffix(folder, "/"), "/") + 1
	path := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< parts {
		strings.write_string(&path, "../")
	}
	return strings.to_string(path)
}
