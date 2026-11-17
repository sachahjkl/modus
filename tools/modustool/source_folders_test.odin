package modustool

import "core:os"
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
	for file in ([]string{RUNTIME_MEMORY, BOOT_PROGRAM_JUMP_SOURCE, RELEASE_NUMBER_SOURCE, CRYPTOGRAPHY_MANIFEST, CRYPTOGRAPHY_SYSTEM_FILES, FAULT_SOURCE_FILE, DEBUG_TARGET_SOURCE_FILE, SITE_SEARCH_MATCH_SOURCE, SITE_OPERATION_FILE, SITE_ERRORS_FILE, SITE_FIXED_ADDRESSES_FILE, SITE_SYSTEM_GRANTS_FILE, SITE_ROOT_ROLES_FILE, SITE_ROOT_BUDGETS_FILE, SITE_START_GRANT_FILE, FONT_OUTPUT, HALL_OF_FAME_CREDITS_FILE, HALL_OF_FAME_PROGRAM_FILE}) {
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
	for folder in ([]string{SOURCE_FOLDER_CONTRACT + "/ring", SOURCE_FOLDER_SUPPORT + "/system", SOURCE_FOLDER_PROGRAMS + "/root", SOURCE_FOLDER_MODULES + "/drawing", SOURCE_FOLDER_BOOT, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_KERNEL + "s", "src", ""}) {
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

// The path from a folder to the root has one ".." for each part.
@(test)
path_from_a_folder_to_the_root :: proc(t: ^testing.T) {
	testing.expect_value(t, path_from_folder_to_root("boot"), "../")
	testing.expect_value(t, path_from_folder_to_root("src/boot"), "../../")
	testing.expect_value(t, path_from_folder_to_root("src/library/support/"), "../../../")
}
