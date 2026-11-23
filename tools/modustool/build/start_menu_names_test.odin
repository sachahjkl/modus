#+build !freestanding
package build

import "core:strings"
import "core:testing"
import "modustool:foundation"

// The start menu lists a module of the boot image with an entry whose
// category is an application, a tool or a demonstration, each section in
// the order of the alphabet. Refused: a service, a library, a test module,
// a module with no entry, a module of no boot image, the module of the one
// image of a test, a row whose category its group refuses, and a row that
// says Partner_Only or Log_Only, whatever its section.
@(test)
the_start_menu_lists_come_from_the_table :: proc(t: ^testing.T) {
	rows := []foundation.Module_Build {
		{name = "zeta", source = foundation.APPLICATION_MODULE_SOURCES + "zeta", entry = true, image = true},
		{name = "alpha", source = foundation.APPLICATION_MODULE_SOURCES + "alpha", entry = true, image = true},
		{name = "tool", source = foundation.SYSTEM_MODULE_SOURCES + "tool", category = .Developer_Tool, entry = true, image = true},
		{name = "shown", source = foundation.DEMONSTRATION_MODULE_SOURCES + "shown", entry = true, image = true},
		{name = "service", source = foundation.SYSTEM_MODULE_SOURCES + "service", category = .Service, entry = true, image = true},
		{name = "library", source = foundation.LIBRARY_MODULE_SOURCES + "library", entry = true, image = true},
		{name = "test", source = foundation.TEST_MODULE_SOURCES + "test", entry = true, image = true},
		{name = "no_entry", source = foundation.DEMONSTRATION_MODULE_SOURCES + "no_entry", image = true},
		{name = "no_image", source = foundation.DEMONSTRATION_MODULE_SOURCES + "no_image", entry = true},
		{name = "disk", source = foundation.DEMONSTRATION_MODULE_SOURCES + "disk", entry = true, image = true, disk = true},
		{name = "only_test", source = foundation.DEMONSTRATION_MODULE_SOURCES + "only_test", entry = true, image = true, only_in_image = "an image"},
		{name = "wrong", source = foundation.SYSTEM_MODULE_SOURCES + "wrong", entry = true, image = true},
		{name = "partner", source = foundation.DEMONSTRATION_MODULE_SOURCES + "partner", entry = true, image = true, menu = .Partner_Only},
		{name = "log_only", source = foundation.DEMONSTRATION_MODULE_SOURCES + "log_only", entry = true, image = true, menu = .Log_Only},
		{name = "quiet_tool", source = foundation.SYSTEM_MODULE_SOURCES + "quiet_tool", category = .System_Tool, entry = true, image = true, menu = .Log_Only},
		{name = "partner_application", source = foundation.APPLICATION_MODULE_SOURCES + "partner_application", entry = true, image = true, menu = .Partner_Only},
	}
	sections := start_menu_names_of_table(rows)
	testing.expect(t, len(sections[.Applications]) == 2 && sections[.Applications][0] == "alpha" && sections[.Applications][1] == "zeta")
	testing.expect(t, len(sections[.Tools]) == 1 && sections[.Tools][0] == "tool")
	testing.expect(t, len(sections[.Demonstrations]) == 1 && sections[.Demonstrations][0] == "shown")
	text := start_menu_names_text(rows)
	testing.expect(t, strings.contains(text, "APPLICATION_COUNT :: 2 ") && strings.contains(text, "TOOL_COUNT :: 1 "), text)
	testing.expect(t, strings.index(text, "\"alpha\"") < strings.index(text, "\"zeta\"") && strings.index(text, "\"zeta\"") < strings.index(text, "\"tool\"") && strings.index(text, "\"tool\"") < strings.index(text, "\"shown\""))
	// No row: an empty list of each section.
	empty := start_menu_names_of_table(nil)
	for section in empty {
		testing.expect_value(t, len(section), 0)
	}
	// The file of the repository is the text of the table: a build writes
	// it before it compiles the compositor.
	kept, read := foundation.read_file(START_MENU_NAMES_FILE)
	testing.expectf(t, read && string(kept) == start_menu_names_text(foundation.module_builds[:]), "%s is not the text of the table of the modules: run modustool build", START_MENU_NAMES_FILE)
}
