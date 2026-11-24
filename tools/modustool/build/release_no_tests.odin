// The boot image of a release: the boot image of the build with no module
// of a test (src/md/infrastructure/release_image.md, "The release boot
// image holds no test module").
package build

import "core:fmt"
import "core:os"
import "core:strings"
import info "modus:contract/boot_info"
import "modus:contract/plan_values"
import "modus:contract/release"
import "modus:contract/system_description"
import "modustool:foundation"
import "modustool:resources"

// The boot image of the release volume. Only `release image` writes it,
// from the boot image of the build.
BOOT_IMAGE_RELEASE :: foundation.BUILD_FOLDER + "/boot_release.image"

// module_included_in_release_image says if a release ships a module of the
// table: a module of the boot image of the build that is not in the group
// tests. A test module starts only in a machine test, and a principal has
// no use of it; the module of the one image of a test is in no release.
module_included_in_release_image :: proc(row: foundation.Module_Build) -> bool {
	if !foundation.module_in_boot_image(row) {
		return false
	}
	group, found := foundation.module_group_of_source(row.source)
	return !found || group != .Tests
}

// module_row_of_name gives the row of the table of the modules with a
// name. found is false for a name that the table does not have.
module_row_of_name :: proc(name: string) -> (row: foundation.Module_Build, found: bool) {
	for candidate in foundation.module_builds {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// release_test_module_names gives the names of the modules of the group
// tests that a boot image of the build holds: a shipped module that names
// one works in the tests and not in a release, which leaves it out. A test
// module that no image holds is missing in the tests too, as the import of
// `lonely` is on purpose.
release_test_module_names :: proc() -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for row in foundation.module_builds {
		group, found := foundation.module_group_of_source(row.source)
		if found && group == .Tests && foundation.module_in_a_boot_image(row) {
			append(&names, row.name)
		}
	}
	return names[:]
}

// quoted_name_in gives the first of the names that a source text holds
// between double quotes, outside a line of comment: the form in which a
// module names another one to load, start or replace it. A comment that
// shows a call names nothing that runs.
//
// The scan is a guard, not a proof. Its limits:
// - release_names_problems gives it the folder of the module only, not the
//   packages of src/library that the module imports: a library that names a
//   test module passes.
// - It skips a whole line of comment only: a quoted name in a comment at the
//   end of a line of code, or in a block comment, counts as a name.
// - Each string equal to a name counts, whatever its use: a log text that is
//   only the name of a test module is refused too.
// - A name that the module builds at run time from parts is not found.
quoted_name_in :: proc(text: string, names: []string) -> (name: string, found: bool) {
	for line in strings.split_lines(text, context.temp_allocator) {
		if strings.has_prefix(strings.trim_left_space(line), "//") {
			continue
		}
		for candidate in names {
			if candidate != "" && strings.contains(line, strings.concatenate({"\"", candidate, "\""}, context.temp_allocator)) {
				return candidate, true
			}
		}
	}
	return "", false
}

// release_names_problems gives one sentence for each place where a module
// that a release ships names a test module of release_test_module_names: an
// import of its row, a quoted name in a source that is not a test, and a
// replacement row of the build.
release_names_problems :: proc() -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	tests := release_test_module_names()
	is_test :: proc(names: []string, name: string) -> bool {
		for candidate in names {
			if candidate == name {
				return true
			}
		}
		return false
	}
	for row in foundation.module_builds {
		if !module_included_in_release_image(row) {
			continue
		}
		for imported in row.imports {
			if is_test(tests, imported) {
				append(&problems, fmt.tprintf("the shipped module %s imports the test module %s", row.name, imported))
			}
		}
		// The root service names each module that it can start, the test
		// modules too, in its start grant sets, its budgets and its
		// drivers: a row of a module that the image does not hold grants
		// nothing, and the root service keeps the bytes that the tests ran
		// (src/md/infrastructure/release_image.md, "The release boot image
		// holds no test module").
		if row.name == ROOT_SERVICE_MODULE {
			continue
		}
		paths, listed := foundation.files_with_suffix(row.source, ".odin")
		if !listed {
			continue
		}
		for path in paths {
			if library_source_is_a_test(path) {
				continue
			}
			text := foundation.read_file(path) or_continue
			if name, found := quoted_name_in(string(text), tests); found {
				append(&problems, fmt.tprintf("%s, a source of the shipped module %s, names the test module %s", path, row.name, name))
			}
		}
	}
	for item in replacement_rows_of_the_build {
		for name in ([2]string{item.from, item.to}) {
			if is_test(tests, name) {
				append(&problems, fmt.tprintf("the replacement row %s by %s names the test module %s", item.from, item.to, name))
			}
		}
	}
	return problems[:]
}

// release_boot_image_of gives the boot image of a release from the boot
// image of the build: each module that a release ships, in its order and
// with the bytes that the tests ran, then each resource of the build. The
// start lists are resources, and name no test module (a host test checks
// it), so the start of the release is the start that the tests ran.
// problem: the bytes are no boot image, an entry points outside them, or a
// module has a name that the table does not have, whose kind the release
// cannot know.
release_boot_image_of :: proc(build_image: []u8) -> (image: []u8, problem: string) {
	modules, image_resources, valid := info.image_tables(build_image)
	if !valid {
		return nil, "the boot image of the build is not a boot image"
	}
	files := make([dynamic]Image_File, context.temp_allocator)
	for &entry in modules {
		name := system_description.name_of(&entry.name)
		row, found := module_row_of_name(name)
		if !found {
			return nil, fmt.tprintf("the boot image of the build holds the module %s, which the table of the modules does not name", name)
		}
		if !module_included_in_release_image(row) {
			continue
		}
		bytes, inside := info.image_entry_bytes(build_image, &entry)
		if !inside {
			return nil, fmt.tprintf("the entry %s of the boot image of the build points outside it", name)
		}
		append(&files, Image_File{name = name, file = bytes})
	}
	module_count := len(files)
	for &entry in image_resources {
		name := system_description.name_of(&entry.name)
		// The test plan file belongs only to test boot images.
		if name == plan_values.TEST_IMAGE_PLAN_RESOURCE {
			continue
		}
		bytes, inside := info.image_entry_bytes(build_image, &entry)
		if !inside {
			return nil, fmt.tprintf("the entry %s of the boot image of the build points outside it", name)
		}
		append(&files, Image_File{name = name, file = bytes})
	}
	return boot_image_encode(files[:], module_count), ""
}

// release_boot_image_write_direct is a `--fast` iteration path that encodes
// build/boot_release.image directly from shipped module files and non-test
// resources without building build/boot.image or any test module. Default,
// check, and release builds still derive build/boot_release.image from
// build/boot.image through release_boot_image_write, where manual_pages.resource
// covers all boot-image modules.
release_boot_image_write_direct :: proc(resource_files: []resources.Resource_File) -> bool {
	files := make([dynamic]Image_File, context.temp_allocator)
	for row in foundation.module_builds {
		if !module_included_in_release_image(row) {
			continue
		}
		append(&files, Image_File{name = row.name, file = foundation.read_file(foundation.module_path(row.name)) or_return})
	}
	module_count := len(files)
	for resource in resource_files {
		if resource.name == plan_values.TEST_IMAGE_PLAN_RESOURCE {
			continue
		}
		append(&files, Image_File{name = resource.name, file = foundation.read_file(resource.path) or_return})
	}
	lists := start_list_resources(BOOT_IMAGE, "") or_return
	for resource in lists {
		append(&files, Image_File{name = resource.name, file = foundation.read_file(resource.path) or_return})
	}
	image := boot_image_encode(files[:], module_count)
	if error := os.write_entire_file(BOOT_IMAGE_RELEASE, image); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BOOT_IMAGE_RELEASE, error)
		return false
	}
	catalog_text, catalog_problem := system_catalog_of_image(image, release.RELEASE_NUMBER, .Release_Image)
	if catalog_problem != "" {
		fmt.eprintfln("modustool: release: %s", catalog_problem)
		return false
	}
	if error := os.write_entire_file(CATALOG_RELEASE_FILE, transmute([]u8)catalog_text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CATALOG_RELEASE_FILE, error)
		return false
	}
	return true
}

// release_boot_image_write writes the boot image of a release from the
// boot image of the build, and its release catalog declaration with no test
// module.
release_boot_image_write :: proc() -> bool {
	build_image := foundation.read_file(BOOT_IMAGE) or_return
	image, problem := release_boot_image_of(build_image)
	if problem != "" {
		fmt.eprintfln("modustool: release: %s", problem)
		return false
	}
	if error := os.write_entire_file(BOOT_IMAGE_RELEASE, image); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", BOOT_IMAGE_RELEASE, error)
		return false
	}
	catalog_text, catalog_problem := system_catalog_of_image(image, release.RELEASE_NUMBER, .Release_Image)
	if catalog_problem != "" {
		fmt.eprintfln("modustool: release: %s", catalog_problem)
		return false
	}
	if error := os.write_entire_file(CATALOG_RELEASE_FILE, transmute([]u8)catalog_text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", CATALOG_RELEASE_FILE, error)
		return false
	}
	return true
}
