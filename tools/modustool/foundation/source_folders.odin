// The folders of the sources of the system: the one place of the tool that
// writes where each is (src/md/infrastructure/repository_layout.md). Each
// other path of a source in the tool is made from these constants, so the
// move of a folder is a change of one line of this file. A path that is
// written as text in another file is a folder that a check no longer reads
// after a move, with no error.
package foundation

import "core:os"
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

// The folder of the programs of the host that build, test and tell the
// system: this tool. It is not a folder of the sources of the system, but
// a document names its files, and the check of the source paths reads
// such a span, so a move of a file of the tool cannot leave a dead
// pointer in silence.
TOOLS_FOLDER :: "tools"

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
// under it, and this tool with each of its packages, because a package of
// the tool that imports another one compiles in the kernel parts that the
// other one imports.
source_folder_takes_kernel_library :: proc(folder: string) -> bool {
	return folder == SOURCE_FOLDER_KERNEL || strings.has_prefix(folder, SOURCE_FOLDER_KERNEL + "/") || source_folder_is_of_the_tool(folder)
}

// source_folder_is_of_the_tool says if a folder is the folder of the
// command of the tool or of one of its packages: its compile and its host
// test get the flag of the source library of the tool.
source_folder_is_of_the_tool :: proc(folder: string) -> bool {
	return folder == TOOL_SOURCE_FOLDER || strings.has_prefix(folder, TOOL_SOURCE_FOLDER + "/")
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

// The source library of the tool: each package of the tool under
// tools/modustool imports another one by one line, "modustool:foundation",
// in each file that imports it
// (src/md/infrastructure/repository_layout.md, "The tool in packages"). It
// is a library of the tool, not of the system: no source of src/ may name
// it, and the readers of the system sources do not resolve it.
TOOL_LIBRARY_NAME :: "modustool"
TOOL_IMPORT_START :: TOOL_LIBRARY_NAME + ":"
// The flag of the compiler for the source library of the tool. Each
// compile of the tool and each host test of a folder of the tool gives
// it: flake.nix gives the same words for the first binary and for the
// derivation of the check.
TOOL_LIBRARY_FLAG :: "-collection:" + TOOL_LIBRARY_NAME + "=" + TOOL_SOURCE_FOLDER

// tool_library_package_folder gives the folder of the package of the tool
// that the path of an import line names: "modustool:build" is the folder
// build of the tool. The identity of the tool follows these imports, so a
// change of a file of a package of the tool builds each module again. A
// path of another library and a path with no package are not found.
tool_library_package_folder :: proc(import_path: string, allocator := context.temp_allocator) -> (folder: string, found: bool) {
	if len(import_path) > len(TOOL_IMPORT_START) && strings.has_prefix(import_path, TOOL_IMPORT_START) {
		return strings.concatenate({TOOL_SOURCE_FOLDER, "/", import_path[len(TOOL_IMPORT_START):]}, allocator), true
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

ROOT_MARK :: "flake.nix"

BUILD_FOLDER :: "build"

// The pictures and other files of the repository that a build reads.
RESOURCE_FOLDER :: "resources"

DOCUMENT_SCREENSHOT_FOLDER :: "docs/screenshots"

// The development log: one folder of pictures per run of `screenshots`. It
// is beside the repository, not in it: no run replaces the pictures of
// another run. It is beside the main working tree: a run in a worktree
// writes there too, not beside the worktree.
DEVELOPMENT_LOG_NAME :: "kernel-devlog"

// development_log_folder gives the development log beside the main
// working tree.
development_log_folder :: proc() -> string {
	if !os.is_file(".git") {
		return "../" + DEVELOPMENT_LOG_NAME // The main working tree: .git is a folder.
	}
	content, _ := read_file(".git")
	return development_log_folder_of(string(content))
}

// development_log_folder_of gives the development log for the content of
// the file .git. In a worktree, it is "gitdir: <main>/.git/worktrees/<name>".
development_log_folder_of :: proc(git_file: string) -> string {
	text := strings.trim_space(git_file)
	if strings.has_prefix(text, "gitdir: ") {
		if at := strings.index(text, "/.git/worktrees/"); at > len("gitdir: ") {
			return join(text[len("gitdir: "):at], "/../", DEVELOPMENT_LOG_NAME)
		}
	}
	return "../" + DEVELOPMENT_LOG_NAME
}

// The file that declares the kernel operations: the check of their count
// reads it, and so do the fuzzing and the site.
OPERATION_SOURCE :: SOURCE_FOLDER_CONTRACT + "/operation/operation.odin"

TOOL_SOURCE_FOLDER :: "tools/modustool"

FONT_OUTPUT :: SOURCE_FOLDER_SUPPORT + "/graphics/font.odin"

// The table of the roles of the root service (process_roles_check.odin).
ROOT_ROLES_FILE :: SYSTEM_MODULE_SOURCES + "root/roles.odin"

SYSTEM_GRANTS_FILE :: SYSTEM_LIBRARY_FOLDER + "/grants.odin"

// git_commit_read reads the commit of the work tree from the files of git,
// with no host process: .git is a folder, or a file "gitdir: <folder>" in a
// work tree; HEAD names a reference, which is a file or a line of
// packed-refs in the common folder.
git_commit_read :: proc() -> string {
	read_trimmed :: proc(path: string) -> string {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return ""
		}
		return strings.trim_space(string(data))
	}
	git_folder := ".git"
	if !os.is_dir(git_folder) {
		pointer := read_trimmed(".git")
		if !strings.has_prefix(pointer, "gitdir: ") {
			return ""
		}
		git_folder = pointer[len("gitdir: "):]
	}
	head := read_trimmed(strings.concatenate({git_folder, "/HEAD"}, context.temp_allocator))
	if !strings.has_prefix(head, "ref: ") {
		return len(head) == 40 ? head : ""
	}
	reference := head[len("ref: "):]
	common := git_folder
	if relative := read_trimmed(strings.concatenate({git_folder, "/commondir"}, context.temp_allocator)); relative != "" {
		common = os.is_absolute_path(relative) ? relative : strings.concatenate({git_folder, "/", relative}, context.temp_allocator)
	}
	for folder in ([]string{git_folder, common}) {
		if commit := read_trimmed(strings.concatenate({folder, "/", reference}, context.temp_allocator)); len(commit) == 40 {
			return commit
		}
	}
	for line in lines_of_text(read_trimmed(strings.concatenate({common, "/packed-refs"}, context.temp_allocator))) {
		if strings.has_suffix(line, strings.concatenate({" ", reference}, context.temp_allocator)) && len(line) > 40 {
			return line[:40]
		}
	}
	return ""
}
