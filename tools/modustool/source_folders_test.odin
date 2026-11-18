package modustool

import "core:os"
import "core:strings"
import "core:testing"

// Each folder of the sources of the system is a folder of the repository:
// a constant that names nothing is a folder that no check reads.
@(test)
source_folders_are_folders_of_the_repository :: proc(t: ^testing.T) {
	folders := SOURCE_FOLDERS
	testing.expect_value(t, len(folders), 7)
	for folder in folders {
		testing.expectf(t, os.is_dir(folder), "%s is not a folder of the repository", folder)
	}
	testing.expectf(t, os.is_dir(SOURCE_FOLDER_LIBRARY), "%s is not a folder of the repository", SOURCE_FOLDER_LIBRARY)
	// The files that the tool names by a path of their own.
	for file in ([]string{RUNTIME_MEMORY, BOOT_PROGRAM_JUMP_SOURCE, RELEASE_NUMBER_SOURCE, CRYPTOGRAPHY_MANIFEST, CRYPTOGRAPHY_SYSTEM_FILES, FAULT_SOURCE_FILE, DEBUG_TARGET_SOURCE_FILE, SITE_SEARCH_MATCH_SOURCE, SITE_OPERATION_FILE, SITE_ERRORS_FILE, SITE_FIXED_ADDRESSES_FILE, SITE_SYSTEM_GRANTS_FILE, SITE_ROOT_ROLES_FILE, SITE_ROOT_BUDGETS_FILE, SITE_START_GRANT_FILE, FONT_OUTPUT, HALL_OF_FAME_CREDITS_FILE, HALL_OF_FAME_MODULE_FILE}) {
		testing.expectf(t, os.is_file(file), "%s is not a file of the repository", file)
	}
	// The folder of each module of the table, and of each host test.
	for build in module_builds {
		testing.expectf(t, os.is_dir(build.source), "the source %s of the module %s is not a folder of the repository", build.source, build.name)
	}
	host_test_folders := HOST_TEST_FOLDERS
	for folder in host_test_folders {
		testing.expectf(t, os.is_dir(folder), "the folder %s of a host test is not a folder of the repository", folder)
	}
}

// An import of a source library names the folder of its package; each
// other import names none.
@(test)
source_library_package_folder_of_an_import :: proc(t: ^testing.T) {
	folder, found := source_library_package_folder(CONTRACT_IMPORT_START + "ring")
	testing.expect(t, found)
	testing.expect_value(t, folder, SOURCE_FOLDER_CONTRACT + "/ring")
	folder, found = source_library_package_folder(SUPPORT_IMPORT_START + "cryptography/ed25519")
	testing.expect(t, found)
	testing.expect_value(t, folder, SOURCE_FOLDER_SUPPORT + "/cryptography/ed25519")
	// The two names that the libraries had before they became one are not
	// names of a library.
	for path in ([]string{"core:fmt", "base:runtime", "../shared", SOURCE_LIBRARY_NAME, SOURCE_LIBRARY_IMPORT_START, SOURCE_LIBRARY_NAME + "s:contract/ring", "system:c", "contract:ring", "support:system", KERNEL_LIBRARY_NAME, KERNEL_IMPORT_START, KERNEL_LIBRARY_NAME + "s:iommu"}) {
		_, other_found := source_library_package_folder(path)
		testing.expectf(t, !other_found, "%q is not an import of a source library", path)
	}
	// The last case: a kernel part is a folder under the kernel.
	folder, found = source_library_package_folder(KERNEL_IMPORT_START + "iommu")
	testing.expect(t, found)
	testing.expect_value(t, folder, SOURCE_FOLDER_KERNEL + "/iommu")
}

// The flag of the kernel parts goes to the kernel, to each folder under it
// and to the tool, and to no other folder: a module or a host test of the
// library that imports a kernel part then does not compile.
@(test)
the_folders_that_take_the_kernel_parts :: proc(t: ^testing.T) {
	for folder in ([]string{SOURCE_FOLDER_CONTRACT + "/ring", SOURCE_FOLDER_SUPPORT + "/system", SYSTEM_MODULE_SOURCES + "root", LIBRARY_MODULE_SOURCES + "drawing", SOURCE_FOLDER_BOOT, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_KERNEL + "s", "src", ""}) {
		testing.expectf(t, !source_folder_takes_kernel_library(folder), "%q does not take the kernel parts", folder)
	}
	for folder in ([]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_KERNEL + "/iommu", SOURCE_FOLDER_KERNEL + "/acpi_processors", TOOL_SOURCE_FOLDER}) {
		testing.expectf(t, source_folder_takes_kernel_library(folder), "%q takes the kernel parts", folder)
	}
	// Each module of the table that is a kernel, and no other, gets the flag
	// in its compile.
	for build in module_builds {
		testing.expectf(t, build.kernel == (build.source == SOURCE_FOLDER_KERNEL), "the module %s: a kernel compiles the folder of the kernel", build.name)
	}
}

// The group of a module is the folder of its source. Refused first: a
// folder that is no group, a group with no module, a folder beside a group,
// the folder of a group alone, a group whose name a longer folder starts
// with. Then the table and the tree: each row that is not a kernel is in a
// group, each folder of a group is a row, src/modules holds the groups and
// nothing else, no two rows have one name, and each module marked with an entry has an
// entry function.
@(test)
the_group_of_a_module_is_its_folder :: proc(t: ^testing.T) {
	for source in ([]string{"", SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_MODULES, SOURCE_FOLDER_MODULES + "/root", SOURCE_FOLDER_MODULES + "/processes/root", SYSTEM_MODULE_SOURCES, SOURCE_FOLDER_MODULES + "/systems/root", "src/processes/root"}) {
		_, found := module_group_of_source(source)
		testing.expectf(t, !found, "%q is in no group", source)
	}
	starts := MODULE_GROUP_SOURCES
	for start, group in starts {
		found_group, found := module_group_of_source(strings.concatenate({start, "a_module"}, context.temp_allocator))
		testing.expectf(t, found && found_group == group, "%sa_module is in the group %v", start, group)
	}

	names := make(map[string]bool, context.temp_allocator)
	sources := make(map[string]bool, context.temp_allocator)
	for build in module_builds {
		testing.expectf(t, !names[build.name], "two rows of the table of the modules have the name %s", build.name)
		names[build.name] = true
		sources[build.source] = true
		if build.kernel {
			continue
		}
		_, found := module_group_of_source(build.source)
		testing.expectf(t, found, "the source %s of the module %s is in no module group", build.source, build.name)
		if build.entry {
			testing.expectf(t, module_source_declares_entry(build.source), "the module %s has no entry function in %s", build.name, build.source)
		}
	}
	entries, error := os.read_all_directory_by_path(SOURCE_FOLDER_MODULES, context.temp_allocator)
	testing.expect_value(t, error, nil)
	group_folders := make(map[string]bool, context.temp_allocator)
	for start in starts {
		group_folders[start[:len(start) - 1]] = true
	}
	for entry in entries {
		folder := strings.concatenate({SOURCE_FOLDER_MODULES, "/", entry.name}, context.temp_allocator)
		testing.expectf(t, group_folders[folder], "%s is no module group: a module is in the folder of its group", folder)
	}
	for start in starts {
		modules, list_error := os.read_all_directory_by_path(start[:len(start) - 1], context.temp_allocator)
		testing.expectf(t, list_error == nil && len(modules) > 0, "the group %s holds no module", start)
		for entry in modules {
			testing.expectf(t, entry.type == .Directory && sources[strings.concatenate({start, entry.name}, context.temp_allocator)], "%s%s is no row of the table of the modules", start, entry.name)
		}
	}
}

// module_source_declares_entry says if a source folder declares the
// procedure entry at the start of a line of a file that is not a test.
@(private = "file")
module_source_declares_entry :: proc(folder: string) -> bool {
	paths, listed := files_with_suffix(folder, ".odin")
	if !listed {
		return false
	}
	for path in paths {
		if library_source_is_a_test(path) {
			continue
		}
		text, read := read_file(path)
		if !read {
			continue
		}
		for line in strings.split_lines(string(text), context.temp_allocator) {
			if strings.has_prefix(line, ENTRY_NAME + " ::") {
				return true
			}
		}
	}
	return false
}

// The path from a folder to the root has one ".." for each part.
@(test)
path_from_a_folder_to_the_root :: proc(t: ^testing.T) {
	testing.expect_value(t, path_from_folder_to_root("boot"), "../")
	testing.expect_value(t, path_from_folder_to_root("src/boot"), "../../")
	testing.expect_value(t, path_from_folder_to_root("src/library/support/"), "../../../")
}
