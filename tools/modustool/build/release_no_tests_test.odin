#+build !freestanding
package build

import "core:testing"
import info "modus:contract/boot_info"
import "modus:contract/image_tree"
import "modus:contract/plan_values"
import "modus:contract/root_plan_values"
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
	testing.expect(t, valid && len(modules) == 2 && len(image_resources) == 2)
	if len(modules) == 2 && len(image_resources) == 2 {
		testing.expect_value(t, system_description.name_of(&modules[0].name), ROOT_SERVICE_MODULE)
		testing.expect_value(t, system_description.name_of(&modules[1].name), "console")
		testing.expect_value(t, system_description.name_of(&image_resources[0].name), "fonts")
		testing.expect_value(t, system_description.name_of(&image_resources[1].name), image_tree.RESOURCE_NAME)
		bytes, inside := info.image_entry_bytes(image, &modules[1])
		testing.expect(t, inside && string(bytes) == console_text)
	}
	testing.expect_value(t, boot_image_verify_image_tree(image), "")
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

// Every module in src/modules/tests (and every only_in_image test module) is
// absent from the derived release boot image, and zero start_grant_sets rows
// naming a test module match any module present in the release boot image.
@(test)
release_image_has_no_test_module_and_no_test_start_grant_matches :: proc(t: ^testing.T) {
	files := make([dynamic]Image_File, context.temp_allocator)
	for row in foundation.module_builds {
		if !foundation.module_in_boot_image(row) {
			continue
		}
		append(&files, Image_File{name = row.name, file = transmute([]u8)row.name})
	}
	full_build_image := boot_image_encode(files[:], len(files))
	release_image, problem := release_boot_image_of(full_build_image)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, release_test_module_problem(release_image, "release"), "")

	modules, _, valid := info.image_tables(release_image)
	testing.expect(t, valid, "the derived release image is a valid boot image")
	present := make(map[string]bool, context.temp_allocator)
	for &entry in modules {
		present[system_description.name_of(&entry.name)] = true
	}

	test_module_names := make(map[string]bool, context.temp_allocator)
	for row in foundation.module_builds {
		group, found := foundation.module_group_of_source(row.source)
		is_test := (found && group == .Tests) || row.only_in_image != ""
		if is_test {
			test_module_names[row.name] = true
			testing.expectf(t, !present[row.name], "test module %s must not be in boot_release.image", row.name)
		} else if module_included_in_release_image(row) {
			testing.expectf(t, present[row.name], "shipped module %s must be in boot_release.image", row.name)
		}
	}
	testing.expect(t, len(test_module_names) > 0, "the table defines test modules")

	// Read root's start_grant_sets: root stays byte-identical to the tested
	// binary, and no row naming a test module matches any shipped module.
	start_grant_text, read_ok := foundation.read_text_file_quiet(foundation.ROOT_START_GRANT_SETS_FILE)
	testing.expect(t, read_ok, "start_grant_sets.odin can be read")
	rows, _, read_problem := start_grant_sets_read(start_grant_text)
	testing.expect_value(t, read_problem, "")
	test_grant_rows := 0
	for row in rows {
		if test_module_names[row.name] {
			test_grant_rows += 1
			testing.expectf(t, !present[row.name], "start_grant_sets test row %s must not match any module in boot_release.image", row.name)
		}
	}
	testing.expect(t, test_grant_rows > 0, "start_grant_sets contains test module rows that match nothing in release")
}

// The test-image plan file encodes valid budget rows for limits, log_flood,
// pdpe1gb_probe, and bootstrap_probe; the default plan file encodes the eight
// shipped post-ready budget rows; release_boot_image_of keeps default_plan_values
// and strips test_plan_values so no release image carries test plan rows.
@(test)
test_plan_values_encoded_and_stripped_from_release :: proc(t: ^testing.T) {
	encoded, ok := test_plan_values_encode()
	testing.expect(t, ok && len(encoded) > 0, "test plan values failed to encode")
	head, check_problem := plan_values.set_check(encoded)
	testing.expect_value(t, check_problem, plan_values.Set_Problem.None)
	testing.expect_value(t, head.principal, u64(0))
	testing.expect_value(t, head.owner_count, 4)

	limits_vals, limits_found := plan_values.owner_values_of(encoded, "limits")
	testing.expect(t, limits_found, "limits owner missing from test plan")
	limits_policy, limits_conflict, limits_over := root_plan_values.module_budget_policy_of(limits_vals)
	testing.expect(t, !limits_conflict && !limits_over, "limits policy reported conflict")
	testing.expect(t, limits_policy.has_processor && limits_policy.processor == TEST_LIMITS_PROCESSOR)
	testing.expect(t, limits_policy.has_log_records && limits_policy.log_records == TEST_LIMITS_LOG_RECORDS)

	flood_vals, flood_found := plan_values.owner_values_of(encoded, "log_flood")
	testing.expect(t, flood_found, "log_flood owner missing from test plan")
	flood_policy, flood_conflict, flood_over := root_plan_values.module_budget_policy_of(flood_vals)
	testing.expect(t, !flood_conflict && !flood_over, "log_flood policy reported conflict")
	testing.expect(t, !flood_policy.has_processor)
	testing.expect(t, flood_policy.has_log_records && flood_policy.log_records == TEST_LOG_FLOOD_LOG_RECORDS)

	pdpe_vals, pdpe_found := plan_values.owner_values_of(encoded, "pdpe1gb_probe")
	testing.expect(t, pdpe_found, "pdpe1gb_probe owner missing from test plan")
	pdpe_policy, pdpe_conflict, pdpe_over := root_plan_values.module_budget_policy_of(pdpe_vals)
	testing.expect(t, !pdpe_conflict && !pdpe_over, "pdpe1gb_probe policy reported conflict")
	testing.expect(t, pdpe_policy.size_kind == .Pages && pdpe_policy.pages == TEST_PDPE1GB_PROBE_PAGES)

	boot_vals, boot_found := plan_values.owner_values_of(encoded, "bootstrap_probe")
	testing.expect(t, boot_found, "bootstrap_probe owner missing from test plan")
	boot_policy, boot_conflict, boot_over := root_plan_values.module_budget_policy_of(boot_vals)
	testing.expect(t, !boot_conflict && !boot_over, "bootstrap_probe policy reported conflict")
	testing.expect(t, boot_policy.size_kind == .Pages && boot_policy.pages == TEST_BOOTSTRAP_PROBE_PAGES)

	_, absent := plan_values.owner_values_of(encoded, "console")
	testing.expect(t, !absent, "unrelated module unexpectedly present in test plan")

	default_encoded, default_ok := default_plan_values_encode()
	testing.expect(t, default_ok && len(default_encoded) > 0, "default plan values failed to encode")
	default_head, default_problem := plan_values.set_check(default_encoded)
	testing.expect_value(t, default_problem, plan_values.Set_Problem.None)
	testing.expect_value(t, default_head.principal, u64(0))
	testing.expect_value(t, default_head.owner_count, 8)

	Expected_Default :: struct {
		owner:       string,
		size_kind:   root_plan_values.Budget_Size_Kind,
		pages:       u64,
		share_parts: u64,
	}
	expected_defaults := [?]Expected_Default {
		{"browser", .Pages, DEFAULT_BROWSER_PAGES, 0},
		{"clock", .Pages, DEFAULT_CLOCK_PAGES, 0},
		{"debugger", .Pages, DEFAULT_DEBUGGER_PAGES, 0},
		{"doom", .Pages, DEFAULT_DOOM_PAGES, 0},
		{"guest_builder", .Pages, DEFAULT_GUEST_BUILDER_PAGES, 0},
		{"linux", .Share_Parts, 0, DEFAULT_LINUX_SHARE_PARTS},
		{"paint", .Pages, DEFAULT_PAINT_PAGES, 0},
		{"recipes", .Share_Parts, 0, DEFAULT_RECIPES_SHARE_PARTS},
	}
	for item in expected_defaults {
		vals, found := plan_values.owner_values_of(default_encoded, item.owner)
		testing.expectf(t, found, "shipped owner %s missing from default plan", item.owner)
		pol, conflict, over := root_plan_values.module_budget_policy_of(vals)
		testing.expectf(t, !conflict && !over, "default policy for %s reported conflict", item.owner)
		testing.expectf(t, pol.size_kind == item.size_kind && pol.pages == item.pages && pol.share_parts == item.share_parts, "default policy mismatch for %s", item.owner)
	}

	root_text, fonts_text: string = "root", "fonts"
	files := []Image_File {
		{name = ROOT_SERVICE_MODULE, file = transmute([]u8)root_text},
		{name = "fonts", file = transmute([]u8)fonts_text},
		{name = plan_values.DEFAULT_IMAGE_PLAN_RESOURCE, file = default_encoded},
		{name = plan_values.TEST_IMAGE_PLAN_RESOURCE, file = encoded},
	}
	build_image := boot_image_encode(files, 1)
	testing.expect(t, release_test_module_problem(build_image, "test build") != "", "release check did not refuse test_plan_values resource")
	release_image, problem := release_boot_image_of(build_image)
	testing.expect_value(t, problem, "")
	_, rel_resources, valid := info.image_tables(release_image)
	testing.expect(t, valid && len(rel_resources) == 3)
	if len(rel_resources) == 3 {
		testing.expect_value(t, system_description.name_of(&rel_resources[0].name), "fonts")
		testing.expect_value(t, system_description.name_of(&rel_resources[1].name), plan_values.DEFAULT_IMAGE_PLAN_RESOURCE)
		testing.expect_value(t, system_description.name_of(&rel_resources[2].name), image_tree.RESOURCE_NAME)
	}
	testing.expect_value(t, boot_image_verify_image_tree(release_image), "")
	testing.expect_value(t, release_test_module_problem(release_image, "release"), "")
}
