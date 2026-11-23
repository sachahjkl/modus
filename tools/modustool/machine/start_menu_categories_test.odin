#+build !freestanding
package machine

import "core:testing"
import "internal:compositor/bar"
import module "modus:contract/module"
import "modustool:build"
import "modustool:foundation"

// The rule of the start menu, for each module category: an application in
// the applications, a system tool or a developer tool in the tools, a
// demonstration in the demonstrations. A module of no category, a service,
// a library and a test module have no line: a test module never reaches
// the menu of a principal. The lists themselves are the output of the
// build, which the build tests check against the table.
@(test)
the_start_menu_takes_each_category_in_its_section :: proc(t: ^testing.T) {
	for category in module.Module_Category {
		row := foundation.Module_Build {
			name   = "probe",
			entry  = true,
			image  = true,
		}
		expected: bar.Menu_Section
		expected_listed := true
		switch category {
		case .Application:
			row.source, expected = foundation.APPLICATION_MODULE_SOURCES + "probe", .Applications
		case .System_Tool, .Developer_Tool:
			row.source, row.category, expected = foundation.SYSTEM_MODULE_SOURCES + "probe", category, .Tools
		case .Demonstration:
			row.source, expected = foundation.DEMONSTRATION_MODULE_SOURCES + "probe", .Demonstrations
		case .Service:
			row.source, row.category, expected_listed = foundation.SYSTEM_MODULE_SOURCES + "probe", category, false
		case .Library:
			row.source, expected_listed = foundation.LIBRARY_MODULE_SOURCES + "probe", false
		case .Test:
			row.source, expected_listed = foundation.TEST_MODULE_SOURCES + "probe", false
		case .None:
			// A kernel is in no group, and states no category.
			row.kernel, expected_listed = true, false
		}
		section, listed := build.start_menu_section_of_row(row)
		testing.expectf(t, listed == expected_listed, "the category %v: listed is %v", category, listed)
		if listed && expected_listed {
			testing.expectf(t, section == expected, "the category %v goes in %v, not in %v", category, section, expected)
		}
	}
}
