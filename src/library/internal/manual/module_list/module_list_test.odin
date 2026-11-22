#+build !freestanding
package module_list

import "core:testing"
import module "modus:contract/module"

@(private = "file")
sample_modules :: proc() -> [8]List_Module {
	return {
		{name = "tally", group = .Demonstrations, tags = {.Processes}},
		{name = "manual", group = .Tools, tags = {.Text}},
		{name = "flood", group = .Tests},
		{name = "kernel", group = .Other},
		{name = "console", group = .Tools},
		{name = "hall_of_fame", group = .Demonstrations, tags = {.Graphics}},
		{name = "lonely", group = .Tests},
		{name = "drawing", group = .Libraries, tags = {.Graphics}},
	}
}

// The groups of the categories: each member has its group, and None is
// Other.
@(test)
each_category_has_its_group :: proc(t: ^testing.T) {
	for category in module.Module_Category {
		group := group_of(category)
		switch category {
		case .None:
			testing.expect_value(t, group, List_Group.Other)
		case .Application:
			testing.expect_value(t, group, List_Group.Applications)
		case .System_Tool, .Developer_Tool:
			testing.expect_value(t, group, List_Group.Tools)
		case .Service:
			testing.expect_value(t, group, List_Group.Services)
		case .Library:
			testing.expect_value(t, group, List_Group.Libraries)
		case .Demonstration:
			testing.expect_value(t, group, List_Group.Demonstrations)
		case .Test:
			testing.expect_value(t, group, List_Group.Tests)
		}
	}
}

// The order: by group, then by name; no module, one module, and an order
// shorter than the modules.
@(test)
the_order_is_by_group_then_by_name :: proc(t: ^testing.T) {
	modules := sample_modules()
	order: [8]int
	testing.expect_value(t, order_build(nil, order[:]), 0)
	testing.expect_value(t, order_build(modules[:1], order[:]), 1)
	testing.expect_value(t, order[0], 0)
	testing.expect_value(t, order_build(modules[:], order[:3]), 3)
	count := order_build(modules[:], order[:])
	testing.expect_value(t, count, 8)
	expected := [8]string{"console", "manual", "drawing", "hall_of_fame", "tally", "flood", "lonely", "kernel"}
	for index in 0 ..< count {
		testing.expect_value(t, modules[order[index]].name, expected[index])
	}
}

// The rows: a heading before each group, the tests closed with their
// count and before Other, then open; a filter by a name, by a part with a
// space for "_", by the case, by a tag word, by a group heading, a filter
// that finds a test with the tests closed, a filter that finds nothing,
// and a list longer than its rows.
@(test)
the_rows_have_headings_a_closed_group_and_a_filter :: proc(t: ^testing.T) {
	modules := sample_modules()
	order: [8]int
	count := order_build(modules[:], order[:])
	items: [16]Item
	rows := items_build(modules[:], order[:count], "", false, items[:])
	// tools: 2, libraries: 1, demonstrations: 2, tests closed, other: 1.
	testing.expect_value(t, rows, 3 + 2 + 3 + 1 + 2)
	testing.expect(t, items[0].module == -1 && items[0].group == .Tools)
	testing.expect(t, items[8].module == -1 && items[8].group == .Tests && items[8].closed_count == 2)
	testing.expect(t, items[9].module == -1 && items[9].group == .Other)
	testing.expect_value(t, modules[items[10].module].name, "kernel")
	rows = items_build(modules[:], order[:count], "", true, items[:])
	testing.expect_value(t, rows, 3 + 2 + 3 + 3 + 2)
	testing.expect(t, items[8].group == .Tests && items[8].closed_count == 0)

	Case :: struct {
		filter: string,
		names:  []string,
	}
	cases := []Case {
		{"manual", {"manual"}},
		{"MANUAL", {"manual"}},
		{"hall of", {"hall_of_fame"}},
		{"graph", {"drawing", "hall_of_fame"}},
		{"librar", {"drawing"}},
		{"flood", {"flood"}},
		{"no module has this", {}},
		{"a_name_longer_than_each_module_name", {}},
	}
	for item in cases {
		rows = items_build(modules[:], order[:count], item.filter, false, items[:])
		found := 0
		for row in items[:rows] {
			if row.module < 0 {
				testing.expectf(t, row.closed_count == 0, "%q: a closed heading", item.filter)
				continue
			}
			testing.expectf(t, found < len(item.names) && modules[row.module].name == item.names[found], "%q: the row %s", item.filter, modules[row.module].name)
			found += 1
		}
		testing.expectf(t, found == len(item.names), "%q: %d modules, not %d", item.filter, found, len(item.names))
	}
	// Fewer rows than the list: the first rows, and no write past them.
	small: [3]Item
	testing.expect_value(t, items_build(modules[:], order[:count], "", false, small[:]), 3)
	testing.expect_value(t, items_build(modules[:], order[:count], "", false, nil), 0)
	// An index past the modules in the order is no row.
	wrong := [2]int{-1, 99}
	testing.expect_value(t, items_build(modules[:], wrong[:], "", false, items[:]), 0)
}

// The keys walk the modules and skip the headings; the ends stay; a row
// out of the list starts at an end; an empty list has no row.
@(test)
the_keys_skip_the_headings :: proc(t: ^testing.T) {
	modules := sample_modules()
	order: [8]int
	count := order_build(modules[:], order[:])
	items: [16]Item
	rows := items_build(modules[:], order[:count], "", false, items[:])
	list := items[:rows]
	testing.expect_value(t, step(list, 0, true), 1)
	testing.expect_value(t, step(list, 2, true), 4) // manual, past the heading of the libraries, to drawing.
	testing.expect_value(t, step(list, 4, false), 2)
	testing.expect_value(t, step(list, 1, false), 1) // The first module stays.
	testing.expect_value(t, step(list, rows - 1, true), rows - 1) // The last module stays.
	testing.expect_value(t, step(list, -1, true), 1)
	testing.expect_value(t, step(list, rows, false), rows - 1)
	testing.expect_value(t, step(list, max(int), true), 1)
	testing.expect_value(t, step(nil, 0, true), -1)
	testing.expect_value(t, row_of_module(list, order[0]), 1)
	testing.expect_value(t, row_of_module(list, -1), -1)
	testing.expect_value(t, row_of_module(list, 2), -1) // flood: closed.
}
