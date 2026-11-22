#+build !freestanding
package machine

import "core:testing"
import "internal:compositor/bar"
import module "modus:contract/module"
import "modustool:foundation"

// The start menu lists a module in the section of its module category: an
// application in the applications, a system tool or a developer tool in
// the tools, a demonstration in the demonstrations. A name of no row, a
// service, a library and a test module are refused: a test module never
// reaches the menu of a principal. Each section is in the order of the
// alphabet. Each module of the menu is in the boot image and has an entry,
// so its line starts something.
@(test)
the_start_menu_lists_each_module_in_the_section_of_its_category :: proc(t: ^testing.T) {
	for name, index in bar.names {
		row, found := module_table_row(name)
		testing.expectf(t, found, "the start menu names %s, which no row of the table of the modules names", name)
		if !found {
			continue
		}
		category, problem := foundation.module_category_of_row(row)
		testing.expectf(t, problem == "", "%s", problem)
		section := bar.section_of(index)
		testing.expectf(t, section_takes(section, category), "the start menu lists %s in %v, and its category is %v", name, section, category)
		testing.expectf(t, row.entry && foundation.module_in_boot_image(row), "the start menu lists %s, which the boot image does not start", name)
		if index > 0 && bar.section_of(index - 1) == section {
			testing.expectf(t, bar.names[index - 1] < name, "%s is not after %s in the order of the alphabet", name, bar.names[index - 1])
		}
	}
	// The rule itself: each category in each section.
	for section in bar.Menu_Section {
		for category in module.Module_Category {
			takes := section_takes(section, category)
			switch category {
			case .None, .Service, .Library, .Test:
				testing.expectf(t, !takes, "%v takes the category %v", section, category)
			case .Application, .System_Tool, .Developer_Tool, .Demonstration:
			}
		}
	}
}

// section_takes says if a section of the start menu lists a module of a
// category.
@(private = "file")
section_takes :: proc(section: bar.Menu_Section, category: module.Module_Category) -> bool {
	switch section {
	case .Applications:
		return category == .Application
	case .Tools:
		return category == .System_Tool || category == .Developer_Tool
	case .Demonstrations:
		return category == .Demonstration
	}
	return false
}

@(private = "file")
module_table_row :: proc(name: string) -> (row: foundation.Module_Build, found: bool) {
	for candidate in foundation.module_builds {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}
