package modustool

import "core:os"
import "core:strings"
import "core:testing"
import module "modus:contract/module"
import "modustool:foundation"
import "modustool:resources"
import "modustool:build"
import "modustool:checks"
import "modustool:machine"
import "modustool:site"

// Each folder of the sources of the system is a folder of the repository:
// a constant that names nothing is a folder that no check reads.
@(test)
source_folders_are_folders_of_the_repository :: proc(t: ^testing.T) {
	folders := foundation.SOURCE_FOLDERS
	testing.expect_value(t, len(folders), 6)
	for folder in folders {
		testing.expectf(t, os.is_dir(folder), "%s is not a folder of the repository", folder)
	}
	testing.expectf(t, os.is_dir(foundation.SOURCE_FOLDER_LIBRARY), "%s is not a folder of the repository", foundation.SOURCE_FOLDER_LIBRARY)
	testing.expectf(t, os.is_dir(foundation.SOURCE_FOLDER_CONTRACT), "%s is not a folder of the repository", foundation.SOURCE_FOLDER_CONTRACT)
	// The files that the tool names by a path of their own.
	for file in ([]string{build.RUNTIME_MEMORY, build.BOOT_PROGRAM_JUMP_SOURCE, build.RELEASE_NUMBER_SOURCE, foundation.CRYPTOGRAPHY_MANIFEST, checks.CRYPTOGRAPHY_SYSTEM_FILES, machine.FAULT_SOURCE_FILE, machine.DEBUG_TARGET_SOURCE_FILE, site.SITE_SEARCH_MATCH_SOURCE, site.SITE_OPERATION_FILE, site.SITE_ERRORS_FILE, site.SITE_FIXED_ADDRESSES_FILE, foundation.SYSTEM_GRANTS_FILE, foundation.ROOT_START_GRANT_SETS_FILE, site.SITE_ROOT_BUDGETS_FILE, site.SITE_START_GRANT_FILE, foundation.FONT_OUTPUT, foundation.BOOT_DISPLAY_FONT_OUTPUT, resources.HALL_OF_FAME_CREDITS_FILE, resources.HALL_OF_FAME_MODULE_FILE}) {
		testing.expectf(t, os.is_file(file), "%s is not a file of the repository", file)
	}
	// The folder of each module of the table, and of each host test.
	for module_build in foundation.module_builds {
		testing.expectf(t, os.is_dir(module_build.source), "the source %s of the module %s is not a folder of the repository", module_build.source, module_build.name)
	}
	host_test_folders := checks.HOST_TEST_FOLDERS
	for folder in host_test_folders {
		testing.expectf(t, os.is_dir(folder), "the folder %s of a host test is not a folder of the repository", folder)
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
	for source in ([]string{"", foundation.SOURCE_FOLDER_KERNEL, foundation.SOURCE_FOLDER_MODULES, foundation.SOURCE_FOLDER_MODULES + "/root", foundation.SOURCE_FOLDER_MODULES + "/processes/root", foundation.SYSTEM_MODULE_SOURCES, foundation.SOURCE_FOLDER_MODULES + "/systems/root", "src/processes/root"}) {
		_, found := foundation.module_group_of_source(source)
		testing.expectf(t, !found, "%q is in no group", source)
	}
	starts := foundation.MODULE_GROUP_SOURCES
	for start, group in starts {
		found_group, found := foundation.module_group_of_source(strings.concatenate({start, "a_module"}, context.temp_allocator))
		testing.expectf(t, found && found_group == group, "%sa_module is in the group %v", start, group)
	}

	names := make(map[string]bool, context.temp_allocator)
	sources := make(map[string]bool, context.temp_allocator)
	for build in foundation.module_builds {
		testing.expectf(t, !names[build.name], "two rows of the table of the modules have the name %s", build.name)
		names[build.name] = true
		sources[build.source] = true
		if build.kernel {
			continue
		}
		_, found := foundation.module_group_of_source(build.source)
		testing.expectf(t, found, "the source %s of the module %s is in no module group", build.source, build.name)
		if build.entry {
			testing.expectf(t, module_source_declares_entry(build.source), "the module %s has no entry function in %s", build.name, build.source)
		}
	}
	entries, error := os.read_all_directory_by_path(foundation.SOURCE_FOLDER_MODULES, context.temp_allocator)
	testing.expect_value(t, error, nil)
	group_folders := make(map[string]bool, context.temp_allocator)
	for start in starts {
		group_folders[start[:len(start) - 1]] = true
	}
	for entry in entries {
		folder := strings.concatenate({foundation.SOURCE_FOLDER_MODULES, "/", entry.name}, context.temp_allocator)
		testing.expectf(t, group_folders[folder], "%s is no module group: a module is in the folder of its group", folder)
	}
	for start in starts {
		// A group with no row has no folder yet: git keeps no empty folder.
		// The group applications waits for its first application.
		row_of_group := false
		for build in foundation.module_builds {
			row_of_group ||= strings.has_prefix(build.source, start)
		}
		if !row_of_group {
			testing.expectf(t, !os.exists(start[:len(start) - 1]), "the group %s has a folder and no row", start)
			continue
		}
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
	paths, listed := foundation.files_with_suffix(folder, ".odin")
	if !listed {
		return false
	}
	for path in paths {
		if build.library_source_is_a_test(path) {
			continue
		}
		text, read := foundation.read_file(path)
		if !read {
			continue
		}
		for line in strings.split_lines(string(text), context.temp_allocator) {
			if strings.has_prefix(line, build.ENTRY_NAME + " ::") {
				return true
			}
		}
	}
	return false
}
// The category of a module agrees with its group. Refused first: a row of
// system that states none, a row that states a category that its group
// does not allow, a kernel that states one. Then a row of each group with
// one category takes it, and each row of the table gives a category with
// no problem.
@(test)
the_category_of_a_module_agrees_with_its_group :: proc(t: ^testing.T) {
	Case :: struct {
		row:      foundation.Module_Build,
		category: module.Module_Category,
		refused:  bool,
	}
	cases := []Case {
		{row = {name = "a", source = foundation.SYSTEM_MODULE_SOURCES + "a"}, refused = true},
		{row = {name = "a", source = foundation.SYSTEM_MODULE_SOURCES + "a", category = .Demonstration}, refused = true},
		{row = {name = "a", source = foundation.DEMONSTRATION_MODULE_SOURCES + "a", category = .Application}, refused = true},
		{row = {name = "a", source = foundation.TEST_MODULE_SOURCES + "a", category = .System_Tool}, refused = true},
		{row = {name = "a", source = foundation.APPLICATION_MODULE_SOURCES + "a", category = .Test}, refused = true},
		{row = {name = "a", source = foundation.LIBRARY_MODULE_SOURCES + "a", category = .Service}, refused = true},
		{row = {name = "kernel", source = foundation.SOURCE_FOLDER_KERNEL, kernel = true, category = .Service}, refused = true},
		{row = {name = "kernel", source = foundation.SOURCE_FOLDER_KERNEL, kernel = true}, category = .None},
		// A module from outside the repository with the name of a module of
		// the system: its folder is in no group, and it states none.
		{row = {name = "console", source = "/home/a_developer/console", image = true}, category = .None},
		{row = {name = "console", source = "", image = true}, category = .None},
		{row = {name = "a", source = foundation.SYSTEM_MODULE_SOURCES + "a", category = .Developer_Tool}, category = .Developer_Tool},
		{row = {name = "a", source = foundation.APPLICATION_MODULE_SOURCES + "a"}, category = .Application},
		{row = {name = "a", source = foundation.DEMONSTRATION_MODULE_SOURCES + "a"}, category = .Demonstration},
		{row = {name = "a", source = foundation.DEMONSTRATION_MODULE_SOURCES + "a", category = .Demonstration}, category = .Demonstration},
		{row = {name = "a", source = foundation.TEST_MODULE_SOURCES + "a"}, category = .Test},
		{row = {name = "a", source = foundation.LIBRARY_MODULE_SOURCES + "a"}, category = .Library},
	}
	for item in cases {
		category, problem := foundation.module_category_of_row(item.row)
		if item.refused {
			testing.expectf(t, problem != "" && category == .None, "the row %v is taken with the category %v", item.row.source, category)
		} else {
			testing.expectf(t, problem == "" && category == item.category, "the row %v gives %v (%s), not %v", item.row.source, category, problem, item.category)
		}
	}
	for row in foundation.module_builds {
		category, problem := foundation.module_category_of_row(row)
		testing.expectf(t, problem == "", "%s", problem)
		testing.expectf(t, row.kernel || category != .None, "the module %s has no category", row.name)
	}
}
