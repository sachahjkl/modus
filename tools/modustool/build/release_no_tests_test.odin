#+build !freestanding
package build

import "core:testing"
import info "modus:contract/boot_info"
import "modus:contract/system_description"
import "modustool:foundation"

// A release ships each module of the boot image of the build but the test
// modules: no row of the group tests, and no module of the one image of a
// test, is shipped; each other module of the boot image is.
@(test)
a_release_ships_no_test_module :: proc(t: ^testing.T) {
	shipped, tests := 0, 0
	for row in foundation.module_builds {
		group, found := foundation.module_group_of_source(row.source)
		is_test := found && group == .Tests
		if is_test || row.only_in_image != "" {
			testing.expectf(t, !module_included_in_release_image(row), "the test module %s ships in a release", row.name)
			tests += 1
			continue
		}
		testing.expectf(t, module_included_in_release_image(row) == foundation.module_in_boot_image(row), "the module %s ships %v, and the boot image holds it %v", row.name, module_included_in_release_image(row), foundation.module_in_boot_image(row))
		if module_included_in_release_image(row) {
			shipped += 1
		}
	}
	testing.expect(t, shipped > 30 && tests > 0, "the table has no module to ship or no test module")
}

// The start lists of the release image are those of the build: each row
// and each wiring row names a module that the release ships, or the start
// of a release would not be the start that the tests ran.
@(test)
the_start_lists_of_a_release_name_no_test_module :: proc(t: ^testing.T) {
	lists := start_lists_of_image(BOOT_IMAGE)
	for rows in ([2][]Start_List_Row{lists.start, lists.rescue}) {
		for row in rows {
			found_row, found := module_row_of_name(row.name)
			if !found {
				// A row can name a role, as "display": the check of the
				// list finds its holder in the image. The holder of the
				// display ships, below.
				continue
			}
			testing.expectf(t, module_included_in_release_image(found_row), "a start list names %s, which a release does not ship", row.name)
		}
	}
	holder, holder_found := module_row_of_name(foundation.DISPLAY_HOLDER_MODULE)
	testing.expect(t, holder_found && module_included_in_release_image(holder), "the holder of the display does not ship")
	for wirings in ([2][]Start_List_Wiring{lists.start_wirings, lists.rescue_wirings}) {
		for wiring in wirings {
			for name in ([2]string{wiring.writer, wiring.reader}) {
				if found_row, found := module_row_of_name(name); found {
					testing.expectf(t, module_included_in_release_image(found_row), "a wiring row names %s, which a release does not ship", name)
				}
			}
		}
	}
}

// The release image of a boot image: the test module and the module of
// the one image of a test go, the other modules keep their order and
// their bytes, and each resource stays. A name that the table does not
// have, and bytes that are no boot image, are refused; an image with no
// test module comes back with the same entries.
@(test)
the_release_image_drops_each_test_module :: proc(t: ^testing.T) {
	root_text, flood_text, console_text, fuzzing_text, fonts_text: string = "root", "flood", "console", "fuzzing", "fonts"
	files := []Image_File {
		{name = ROOT_SERVICE_MODULE, file = transmute([]u8)root_text},
		{name = "flood", file = transmute([]u8)flood_text},
		{name = "console", file = transmute([]u8)console_text},
		{name = foundation.OPERATION_FUZZING_MODULE, file = transmute([]u8)fuzzing_text},
		{name = "fonts", file = transmute([]u8)fonts_text},
	}
	build_image := boot_image_encode(files, 4)
	testing.expect(t, release_test_module_problem(build_image, "the build") != "", "an image with a test module is taken")
	// The image of the build may hold a test module, never a module of the
	// one image of a test.
	testing.expect(t, release_only_in_image_problem(build_image, "the build") != "", "the module of the image of a test is taken")
	without_fuzzing := boot_image_encode(files[:3], 3)
	testing.expect_value(t, release_only_in_image_problem(without_fuzzing, "the build"), "")
	testing.expect(t, release_only_in_image_problem(nil, "no bytes") != "", "no bytes are a boot image")
	image, problem := release_boot_image_of(build_image)
	testing.expect_value(t, problem, "")
	modules, image_resources, valid := info.image_tables(image)
	testing.expect(t, valid && len(modules) == 2 && len(image_resources) == 1)
	if len(modules) == 2 && len(image_resources) == 1 {
		testing.expect_value(t, system_description.name_of(&modules[0].name), ROOT_SERVICE_MODULE)
		testing.expect_value(t, system_description.name_of(&modules[1].name), "console")
		testing.expect_value(t, system_description.name_of(&image_resources[0].name), "fonts")
		bytes, inside := info.image_entry_bytes(image, &modules[1])
		testing.expect(t, inside && string(bytes) == console_text)
	}
	testing.expect_value(t, release_test_module_problem(image, "the release"), "")
	// An image with no test module: the same entries.
	again, again_problem := release_boot_image_of(image)
	testing.expect(t, again_problem == "" && string(again) == string(image), "an image with no test module changes")
	// A module that the table does not name.
	unknown := []Image_File{{name = "no_module_of_the_table", file = transmute([]u8)root_text}}
	_, problem = release_boot_image_of(boot_image_encode(unknown, 1))
	testing.expect(t, problem != "", "a module of no row is taken")
	// Bytes that are no boot image: none, and a cut header.
	_, problem = release_boot_image_of(nil)
	testing.expect(t, problem != "", "no bytes are taken")
	_, problem = release_boot_image_of(build_image[:8])
	testing.expect(t, problem != "", "a cut header is taken")
}
// No module that a release ships names a test module that the tests hold:
// by an import, by a quoted name in a source, or by a replacement row. The
// demonstrations imports, errors and tables named calendar_fixed,
// calendar_changed, lonely and hostile_exports, and the release lost them.
// The reader of a quoted name: none, the name inside another word, the
// name alone, and an empty name, which names nothing.
@(test)
no_shipped_module_names_a_test_module :: proc(t: ^testing.T) {
	names := []string{"", "flood", "probe"}
	_, found := quoted_name_in("", names)
	testing.expect(t, !found, "an empty text names a module")
	_, found = quoted_name_in("start(\"flooding\")", names)
	testing.expect(t, !found, "a longer word names a module")
	_, found = quoted_name_in("flood", names)
	testing.expect(t, !found, "a word with no quotes names a module")
	name: string
	name, found = quoted_name_in("start(\"probe\")", names)
	testing.expect(t, found && name == "probe")
	_, found = quoted_name_in("\"\"", names[:1])
	testing.expect(t, !found, "an empty name is named")
	_, found = quoted_name_in("\t// > start(\"probe\")\n", names)
	testing.expect(t, !found, "a line of comment names a module")
	name, found = quoted_name_in("// start(\"flood\")\nstart(\"probe\")", names)
	testing.expect(t, found && name == "probe", "a name after a comment is not found")
	testing.expect(t, len(release_test_module_names()) > 0, "no test module is in a boot image")
	for problem in release_names_problems() {
		testing.expectf(t, false, "%s", problem)
	}
}
