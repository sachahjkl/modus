package foundation

import "core:testing"

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
	for folder in ([]string{SOURCE_FOLDER_CONTRACT + "/ring", SOURCE_FOLDER_SUPPORT + "/system", SYSTEM_MODULE_SOURCES + "root", LIBRARY_MODULE_SOURCES + "drawing", SOURCE_FOLDER_BOOT, SOURCE_FOLDER_RUNTIME, SOURCE_FOLDER_KERNEL + "s", TOOL_SOURCE_FOLDER + "s", TOOLS_FOLDER, "src", ""}) {
		testing.expectf(t, !source_folder_takes_kernel_library(folder), "%q does not take the kernel parts", folder)
		testing.expectf(t, !source_folder_is_of_the_tool(folder), "%q is no folder of the tool", folder)
	}
	for folder in ([]string{SOURCE_FOLDER_KERNEL, SOURCE_FOLDER_KERNEL + "/iommu", SOURCE_FOLDER_KERNEL + "/acpi_processors"}) {
		testing.expectf(t, source_folder_takes_kernel_library(folder), "%q takes the kernel parts", folder)
		testing.expectf(t, !source_folder_is_of_the_tool(folder), "%q is no folder of the tool", folder)
	}
	// The command of the tool and each of its packages take the kernel
	// parts and the source library of the tool.
	for folder in ([]string{TOOL_SOURCE_FOLDER, TOOL_SOURCE_FOLDER + "/foundation"}) {
		testing.expectf(t, source_folder_takes_kernel_library(folder), "%q takes the kernel parts", folder)
		testing.expectf(t, source_folder_is_of_the_tool(folder), "%q is a folder of the tool", folder)
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
