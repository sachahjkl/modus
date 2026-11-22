// The boot image of a release: the boot image of the build with no module
// of a test (src/md/infrastructure/release_image.md, "The release boot
// image holds no test module").
package build

import "core:fmt"
import "core:os"
import info "modus:contract/boot_info"
import "modus:contract/system_description"
import "modustool:foundation"

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
		bytes, inside := info.image_entry_bytes(build_image, &entry)
		if !inside {
			return nil, fmt.tprintf("the entry %s of the boot image of the build points outside it", name)
		}
		append(&files, Image_File{name = name, file = bytes})
	}
	return boot_image_encode(files[:], module_count), ""
}

// release_boot_image_write writes the boot image of a release from the
// boot image of the build.
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
	return true
}
