// The list of the modules of the manual: the modules of the boot image in
// groups by their module category, each group in the order of the
// alphabet, the tests in a last group that is closed until the principal
// opens it, and a filter on the words of the name, the group and the
// tags (src/md/features/manual_module_list.md). The list is made when the
// filter or the open groups change, never in a frame.
package module_list

import module "modus:contract/module"

// The groups of the list, in its order.
List_Group :: enum u8 {
	Applications, // The programs of the principal.
	Tools, // The system tools and the developer tools.
	Services, // The services of the system, with no window of their own.
	Libraries, // The modules that other modules import.
	Demonstrations, // The modules that each show one property.
	Tests, // The test modules: closed until the principal opens them.
	Other, // A module that states no category: the kernel.
}

// The heading of each group, as the list shows it.
@(rodata)
GROUP_TITLES := [List_Group]string {
	.Applications   = "applications",
	.Tools          = "tools",
	.Services       = "system services",
	.Libraries      = "libraries",
	.Demonstrations = "demonstrations",
	.Tests          = "tests",
	.Other          = "other",
}

// The word of each tag, which the filter matches.
@(rodata)
TAG_WORDS := [module.Module_Tag]string {
	.Graphics  = "graphics",
	.Text      = "text",
	.Network   = "network",
	.Storage   = "storage",
	.Security  = "security",
	.Processes = "processes",
	.Memory    = "memory",
	.Time      = "time",
	.Sound     = "sound",
	.Input     = "input",
	.Faults    = "faults",
	.Kernel    = "kernel",
}

// The bytes of the filter that the principal types.
FILTER_BYTES :: 32

// group_of gives the group of a module category.
group_of :: proc "contextless" (category: module.Module_Category) -> List_Group {
	switch category {
	case .Application:
		return .Applications
	case .System_Tool, .Developer_Tool:
		return .Tools
	case .Service:
		return .Services
	case .Library:
		return .Libraries
	case .Demonstration:
		return .Demonstrations
	case .Test:
		return .Tests
	case .None:
	}
	return .Other
}

// One module of the boot image, as the list reads it.
List_Module :: struct {
	name:  string,
	group: List_Group,
	tags:  module.Module_Tags,
}

// One row of the list: the heading of a group, or a module.
Item :: struct {
	module:      int, // The index of the module in the modules; -1 for the heading of a group.
	group:       List_Group,
	closed_count: int, // The heading of a closed group: the count of its modules, which the list does not show.
}

// order_build writes in order the index of each module, by group, then by
// name in the order of the bytes. It gives the count written: at most the
// length of order. An insertion sort: the boot image holds a few hundred
// modules, and the order is made once.
order_build :: proc "contextless" (modules: []List_Module, order: []int) -> int {
	count := min(len(modules), len(order))
	for index in 0 ..< count {
		order[index] = index
		place := index
		for place > 0 && before(modules[order[place]], modules[order[place - 1]]) {
			order[place], order[place - 1] = order[place - 1], order[place]
			place -= 1
		}
	}
	return count
}

// before says if a module comes before another one in the list.
@(private)
before :: proc "contextless" (first, second: List_Module) -> bool {
	if first.group != second.group {
		return first.group < second.group
	}
	return first.name < second.name
}

// lower gives a byte of ASCII in lower case.
@(private)
lower :: proc "contextless" (value: u8) -> u8 {
	return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value
}

// contains_folded says if a text holds a part, with the case of ASCII
// folded; "_" in the text and a space in the part are one character, so
// that "hall of" finds hall_of_fame.
@(private)
contains_folded :: proc "contextless" (text, part: string) -> bool {
	if len(part) == 0 {
		return true
	}
	for start := 0; start + len(part) <= len(text); start += 1 {
		same := true
		for index in 0 ..< len(part) {
			text_byte, part_byte := lower(text[start + index]), lower(part[index])
			if text_byte == '_' {
				text_byte = ' '
			}
			if part_byte == '_' {
				part_byte = ' '
			}
			if text_byte != part_byte {
				same = false
				break
			}
		}
		if same {
			return true
		}
	}
	return false
}

// matches says if a module passes a filter: an empty filter, or a filter
// that the name, the heading of its group or the word of one of its tags
// holds.
matches :: proc "contextless" (item: List_Module, filter: string) -> bool {
	if len(filter) == 0 || contains_folded(item.name, filter) || contains_folded(GROUP_TITLES[item.group], filter) {
		return true
	}
	for tag in item.tags {
		if contains_folded(TAG_WORDS[tag], filter) {
			return true
		}
	}
	return false
}

// items_build writes the rows of the list in items: for each group with a
// module that passes the filter, its heading, then each such module in the
// order. The group of the tests is closed while tests_open is false and the
// filter is empty: its heading alone, with the count of its modules. A
// filter shows the tests that it finds: the principal who types a name
// wants that module. It gives the count of the rows written; rows past the
// length of items are not written.
items_build :: proc "contextless" (modules: []List_Module, order: []int, filter: string, tests_open: bool, items: []Item) -> int {
	count := 0
	write :: proc "contextless" (items: []Item, count: ^int, item: Item) {
		if count^ < len(items) {
			items[count^] = item
			count^ += 1
		}
	}
	heading_written := [List_Group]bool{}
	closed_tests := 0
	for index in order {
		if index < 0 || index >= len(modules) {
			continue
		}
		item := modules[index]
		if !matches(item, filter) {
			continue
		}
		if item.group == .Tests && !tests_open && len(filter) == 0 {
			closed_tests += 1
			continue
		}
		if !heading_written[item.group] {
			heading_written[item.group] = true
			write(items, &count, Item{module = -1, group = item.group})
		}
		write(items, &count, Item{module = index, group = item.group})
	}
	if closed_tests > 0 {
		// The tests are the last group but Other: a closed heading takes
		// its place before the modules of Other.
		place := count
		for place > 0 && items[place - 1].group == .Other {
			place -= 1
		}
		if count < len(items) {
			for moved := count; moved > place; moved -= 1 {
				items[moved] = items[moved - 1]
			}
			items[place] = Item{module = -1, group = .Tests, closed_count = closed_tests}
			count += 1
		}
	}
	return count
}

// step gives the row of the next module after a row (forward) or before
// it, past the headings; the row itself when no module is there. A row out
// of the list starts at the first module or the last one.
step :: proc "contextless" (items: []Item, row: int, forward: bool) -> int {
	if len(items) == 0 {
		return -1
	}
	start := row
	if row < 0 || row >= len(items) {
		start = forward ? -1 : len(items)
	}
	for place := start + (forward ? 1 : -1); place >= 0 && place < len(items); place += forward ? 1 : -1 {
		if items[place].module >= 0 {
			return place
		}
	}
	return row >= 0 && row < len(items) ? row : -1
}

// row_of_module gives the row of a module in the list, or -1 when the
// list does not show it.
row_of_module :: proc "contextless" (items: []Item, module_index: int) -> int {
	for item, place in items {
		if item.module == module_index && module_index >= 0 {
			return place
		}
	}
	return -1
}
