package build

import "core:strings"
import "core:testing"
import "modustool:foundation"

// The check of a start list against the modules of an image. Each list
// that it must refuse comes first: a row of no module, a row of a module
// that the image leaves out, a row whose name the border refuses, a list
// past the capacity, and a rescue list with no row that makes the machine
// usable. Each list of each image of the build passes last, and the list
// of the test of the rescue is refused for its one row.
@(test)
a_start_list_that_is_not_valid_is_refused :: proc(t: ^testing.T) {
	modules := []string{"input", "compositor", "console", "date"}
	no_module := []Start_List_Row{{name = "console", usable_mark = .Needed, absent_rule = .Not_Started}, {name = "console_missing", absent_rule = .Not_Started}}
	problems := start_list_problems(no_module, modules, false)
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "console_missing"))
	}
	left_out := image_modules_with_an_entry(BOOT_IMAGE_SHORTAGE, "input")
	refused_input := start_list_problems(DEFAULT_START_LIST[:], left_out, false)
	testing.expect(t, len(refused_input) >= 1, "a list that names input is taken for an image with no input")
	bad_name := []Start_List_Row{{name = "Console", usable_mark = .Needed, absent_rule = .Not_Started}}
	testing.expect(t, len(start_list_problems(bad_name, modules, false)) >= 1)
	long := make([]Start_List_Row, 33, context.temp_allocator)
	for &row in long {
		row = {name = "date", absent_rule = .Not_Started}
	}
	testing.expect(t, len(start_list_problems(long, modules, false)) >= 1)
	not_usable := []Start_List_Row{{name = "console", absent_rule = .Not_Started}}
	not_usable_problems := start_list_problems(not_usable, modules, true)
	testing.expect_value(t, len(not_usable_problems), 1)
	// The same list is a start list that the check takes: the mark Needed
	// is a rule of a rescue list.
	testing.expect_value(t, len(start_list_problems(not_usable, modules, false)), 0)
	// The lists of the build against the modules of their images.
	images := [?][2]string{{BOOT_IMAGE, ""}, {BOOT_IMAGE_FAILS, foundation.START_POLICY_MODULE}, {BOOT_IMAGE_SHORTAGE, "input"}, {foundation.BOOT_IMAGE_OPERATION_SEQUENCES, ""}, {BOOT_IMAGE_MEASURE, ""}}
	for image in images {
		lists := start_lists_of_image(image[0])
		image_modules := image_modules_with_an_entry(image[0], image[1])
		testing.expectf(t, len(start_list_problems(lists.start, image_modules, false)) == 0, "the start list of %s is refused: %v", image[0], start_list_problems(lists.start, image_modules, false))
		testing.expectf(t, len(start_list_problems(lists.rescue, image_modules, true)) == 0, "the rescue list of %s is refused: %v", image[0], start_list_problems(lists.rescue, image_modules, true))
	}
	missing := start_lists_of_image(BOOT_IMAGE_MISSING_CONSOLE)
	testing.expect(t, missing.start_refused_on_purpose)
	missing_problems := start_list_problems(missing.start, image_modules_with_an_entry(BOOT_IMAGE_MISSING_CONSOLE, ""), false)
	testing.expect(t, refused_for_the_rows(missing_problems, REFUSED_ON_PURPOSE_ROWS[:]), "the list of the test of the rescue is not refused for its two rows alone")
	// shortage is in the image of its test only.
	testing.expect(t, len(start_list_problems(SHORTAGE_START_LIST[:], image_modules_with_an_entry(BOOT_IMAGE, ""), false)) == 1, "the main image holds shortage")
	// The check of a list refused on purpose refuses one problem too few,
	// one too many, and another row.
	testing.expect(t, !refused_for_the_rows(missing_problems[:1], REFUSED_ON_PURPOSE_ROWS[:]))
	more := make([dynamic]string, context.temp_allocator)
	append(&more, ..missing_problems)
	append(&more, "the row date names no module with an entry in the image")
	testing.expect(t, !refused_for_the_rows(more[:], REFUSED_ON_PURPOSE_ROWS[:]))
	testing.expect(t, !refused_for_the_rows(missing_problems, []string{ABSENT_TEST_MODULE, "date"}))
}

// The check of the source of the start policy: one line past the bound, an
// import of the core library, an import of another contract, an import
// with no path. A test file is not counted, and its import is not read.
// A source of the bound with the allowed imports passes last, and so does
// the source of the repository.
@(test)
a_start_policy_past_its_bound_is_refused :: proc(t: ^testing.T) {
	lines_of :: proc(count: int) -> string {
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, "package start_policy\n")
		for _ in 1 ..< count {
			strings.write_string(&builder, "// a line\n")
		}
		return strings.to_string(builder)
	}
	past := [][2]string{{"main.odin", lines_of(START_POLICY_SOURCE_LINE_LIMIT + 1)}}
	testing.expect_value(t, len(start_policy_source_problems(past)), 1)
	split := [][2]string{{"main.odin", lines_of(START_POLICY_SOURCE_LINE_LIMIT)}, {"rows.odin", "package start_policy\n"}}
	testing.expect_value(t, len(start_policy_source_problems(split)), 1)
	imports := [?]string{"import \"core:fmt\"\n", "import op \"modus:contract/operation\"\n", "import \"modus:support/storage\"\n", "import\n", "foreign import code \"code.asm\"\n", "\tforeign code {\n", "foreign {\n"}
	for line in imports {
		source := [][2]string{{"main.odin", strings.concatenate({"package start_policy\n", line}, context.temp_allocator)}}
		testing.expectf(t, len(start_policy_source_problems(source)) == 1, "the import %q is taken", line)
	}
	with_a_test := [][2]string{{"main.odin", lines_of(START_POLICY_SOURCE_LINE_LIMIT)}, {"rows_test.odin", strings.concatenate({lines_of(START_POLICY_SOURCE_LINE_LIMIT), "import \"core:testing\"\n"}, context.temp_allocator)}}
	testing.expect_value(t, len(start_policy_source_problems(with_a_test)), 0)
	allowed := [][2]string{{"main.odin", "package start_policy\n\nimport \"base:intrinsics\"\nimport \"modus:contract/ring\"\nimport \"modus:contract/root_ring\"\nimport \"modus:contract/start_list\"\nimport \"modus:support/system\"\n"}}
	testing.expect_value(t, len(start_policy_source_problems(allowed)), 0)
	testing.expect(t, start_policy_source_check(), "the source of the start policy of the repository is refused")
}
