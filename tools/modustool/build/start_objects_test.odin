package build

import "core:testing"

// The lists of start objects of a module and of its packages, read from
// the sources that the compiler read: the names resolve in the package of
// their list, a test file is no source, and the order of the files changes
// no sum.
@(test)
the_start_objects_resolve_in_their_package :: proc(t: ^testing.T) {
	sources := []Fact_Source {
		{path = "src/modules/m/main.odin", source = "package m\n\nRING_PAGES :: 2\nLENT_PAGES :: 0x1\n// Its ring and the page that it lends.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES, RING_PAGES, LENT_PAGES}\n"},
		{path = "src/library/modus/display/text.odin", source = "package display\n\nTEXT_MEMORY_PAGES :: 354\n"},
		{path = "src/library/modus/display/objects.odin", source = "package display\n\n// The glyph memory of each process that draws.\nPACKAGE_START_OBJECTS :: [?]Start_Object{TEXT_MEMORY_PAGES}\n"},
		{path = "src/library/modus/display/objects_test.odin", source = "package display\n\n// A test.\nPACKAGE_START_OBJECTS :: [?]Start_Object{NOT_A_NAME}\n"},
	}
	pages, ok := start_objects_of_sources("src/modules/m", sources)
	testing.expect(t, ok)
	sum: u64 = 0
	for item in pages {
		sum += item
	}
	testing.expect_value(t, len(pages), 4)
	testing.expect_value(t, sum, 2 + 2 + 1 + 354)
	// A whole path of the file names the same package of the module.
	_, whole_ok := start_objects_of_sources("src/modules/m", {{path = "/home/b/src/modules/m/main.odin", source = sources[0].source}})
	testing.expect(t, whole_ok)
	// No list: no object.
	none, none_ok := start_objects_of_sources("src/modules/m", {{path = "src/modules/m/main.odin", source = "package m\n\nRING_PAGES :: 2\n"}})
	testing.expect(t, none_ok && len(none) == 0)
}

// Each form that is not one constant array of names of integer literals,
// with a comment, in its own package, stops the build: the tool does not
// guess an object.
@(test)
the_start_objects_refuse_another_form :: proc(t: ^testing.T) {
	cases := [?]struct {
		about:  string,
		path:   string,
		source: string,
	} {
		{"a name that is no constant", "src/modules/m/main.odin", "package m\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"},
		{"a constant of an expression", "src/modules/m/main.odin", "package m\nRING_PAGES :: 1 + 1\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"},
		{"an object of no page", "src/modules/m/main.odin", "package m\nRING_PAGES :: 0\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"},
		{"no comment", "src/modules/m/main.odin", "package m\nRING_PAGES :: 2\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"},
		{"inside a when", "src/modules/m/main.odin", "package m\nRING_PAGES :: 2\nwhen ODIN_DEBUG {\n\t// Why.\n\tMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n}\n"},
		{"a variable", "src/modules/m/main.odin", "package m\nRING_PAGES :: 2\n// Why.\nMODULE_START_OBJECTS := [?]system.Start_Object{RING_PAGES}\n"},
		{"another type", "src/modules/m/main.odin", "package m\nRING_PAGES :: 2\n// Why.\nMODULE_START_OBJECTS :: [?]u64{RING_PAGES}\n"},
		{"an element that is no name", "src/modules/m/main.odin", "package m\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{2}\n"},
		{"no element", "src/modules/m/main.odin", "package m\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{}\n"},
		{"the list of a package in the module", "src/modules/m/main.odin", "package m\nRING_PAGES :: 2\n// Why.\nPACKAGE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"},
		{"the list of the module in a package", "src/library/modus/display/a.odin", "package display\nRING_PAGES :: 2\n// Why.\nMODULE_START_OBJECTS :: [?]Start_Object{RING_PAGES}\n"},
		{"two lists in one file", "src/modules/m/main.odin", "package m\nRING_PAGES :: 2\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"},
	}
	for item in cases {
		_, ok := start_objects_of_sources("src/modules/m", {{path = item.path, source = item.source}})
		testing.expectf(t, !ok, "%s is refused", item.about)
	}
	// Two lists in two files of one package.
	_, two_ok := start_objects_of_sources("src/modules/m", {{path = "src/modules/m/a.odin", source = "package m\nRING_PAGES :: 2\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"}, {path = "src/modules/m/b.odin", source = "package m\n// Why.\nMODULE_START_OBJECTS :: [?]system.Start_Object{RING_PAGES}\n"}})
	testing.expect(t, !two_ok, "two lists in one package are refused")
}

// The budgets of a fixed amount of the children of a module: read from its
// own package, refused in another package, refused for a name that is no
// constant of one literal, an amount of 0, another element type, and two
// lists.
@(test)
the_start_budgets_are_read_from_the_module_alone :: proc(t: ^testing.T) {
	module_source := "package m\nNODE_PAGES :: 900\n// Each node starts with its budget.\nMODULE_START_BUDGETS :: [?]system.Start_Budget{NODE_PAGES, NODE_PAGES}\n"
	pages, ok := start_budgets_of_sources("src/modules/m", {{path = "src/modules/m/main.odin", source = module_source}})
	testing.expect(t, ok && len(pages) == 2 && pages[0] == 900 && pages[1] == 900)
	none, none_ok := start_budgets_of_sources("src/modules/m", {{path = "src/modules/m/main.odin", source = "package m\n"}})
	testing.expect(t, none_ok && len(none) == 0)
	refused := [?]struct {
		path, source: string,
	} {
		{"src/library/modus/display/a.odin", module_source},
		{"src/modules/m/main.odin", "package m\n// Why.\nMODULE_START_BUDGETS :: [?]system.Start_Budget{NODE_PAGES}\n"},
		{"src/modules/m/main.odin", "package m\nNODE_PAGES :: 0\n// Why.\nMODULE_START_BUDGETS :: [?]system.Start_Budget{NODE_PAGES}\n"},
		{"src/modules/m/main.odin", "package m\nNODE_PAGES :: 9\n// Why.\nMODULE_START_BUDGETS :: [?]system.Start_Object{NODE_PAGES}\n"},
		{"src/modules/m/main.odin", "package m\nNODE_PAGES :: 9\nMODULE_START_BUDGETS :: [?]system.Start_Budget{NODE_PAGES}\n"},
	}
	for item in refused {
		_, item_ok := start_budgets_of_sources("src/modules/m", {{path = item.path, source = item.source}})
		testing.expectf(t, !item_ok, "%s is refused", item.source)
	}
	_, two_ok := start_budgets_of_sources("src/modules/m", {{path = "src/modules/m/a.odin", source = module_source}, {path = "src/modules/m/b.odin", source = "package m\n// Why.\nMODULE_START_BUDGETS :: [?]system.Start_Budget{NODE_PAGES}\n"}})
	testing.expect(t, !two_ok, "two lists are refused")
}

// The start grants of the repository: the console sends Wire from its root
// ring, so its floor holds its wiring budget; the start policy prices its
// wirings with its list; a module with no root ring wires nothing; a name
// with no row wires nothing. The detector parses the Odin syntax tree:
// comments, strings, unimported names, Wire_Step.None and calls to
// unrelated procedures taking .Wire do not trigger a wiring part, while
// calls to package helpers taking root_ring.Root_Command (positional or
// named) and aliased imports of modus:contract/root_ring do.
@(test)
the_wiring_of_a_floor_follows_the_start_grants :: proc(t: ^testing.T) {
	wires := []Fact_Source{{path = "src/modules/system/console/streams.odin", source = "package console\nimport \"modus:contract/root_ring\"\nstep :: proc() { _ = root_ring.Wire_Step.Apply }\n"}}
	never := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\n"}}
	in_comment := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\nimport \"modus:contract/root_ring\"\n// root_ring.Wire_Step.Apply and root_ring.Root_Command.Wire\n"}}
	in_string := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\nimport \"modus:contract/root_ring\"\nTEXT :: \"root_ring.Wire_Step.List_Page Root_Command.Wire\"\n"}}
	unimported := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\nWire_Step :: enum { Apply }\nstep :: Wire_Step.Apply\n"}}
	wire_step_none := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\nimport \"modus:contract/root_ring\"\nstep :: root_ring.Wire_Step.None\n"}}
	other_command := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\nimport \"modus:contract/root_ring\"\ndisk_request :: proc(kind: root_ring.Root_Command) {}\nrun :: proc() { disk_request(.Start) }\n"}}
	unrelated_call := []Fact_Source{{path = "src/modules/system/console/main.odin", source = "package console\nOther :: enum { Wire }\nother_call :: proc(kind: Other) {}\nrun :: proc() { other_call(.Wire) }\n"}}
	in_a_package := []Fact_Source{{path = "src/library/modus/system/a.odin", source = "package system\nimport \"modus:contract/root_ring\"\nstep :: root_ring.Wire_Step.Apply\n"}}
	in_a_test := []Fact_Source{{path = "src/modules/system/console/a_test.odin", source = "package console\nimport \"modus:contract/root_ring\"\nstep :: root_ring.Wire_Step.Apply\n"}}
	cross_file_call := []Fact_Source {
		{path = "src/modules/system/console/commands.odin", source = "package console\nimport \"modus:contract/root_ring\"\ndisk_request :: proc(kind: root_ring.Root_Command, values: [7]u64) {}\n"},
		{path = "src/modules/system/console/streams.odin", source = "package console\nrun :: proc() { disk_request(.Wire, {}) }\n"},
	}
	named_arg_call := []Fact_Source {
		{path = "src/modules/system/console/commands.odin", source = "package console\nimport \"modus:contract/root_ring\"\ndisk_request :: proc(tag: u32, kind: root_ring.Root_Command) {}\n"},
		{path = "src/modules/system/console/streams.odin", source = "package console\nrun :: proc() { disk_request(kind = .Wire, tag = 1) }\n"},
	}
	aliased_import := []Fact_Source{{path = "src/modules/system/console/streams.odin", source = "package console\nimport rr \"modus:contract/root_ring\"\nrun :: proc() { _ = rr.Root_Command.Wire }\n"}}
	broken_source := []Fact_Source{{path = "src/modules/system/console/broken.odin", source = "package console\nproc( {\n"}}

	// Refusal and non-wiring cases first.
	for item in ([?]struct {
		about:   string,
		sources: []Fact_Source,
	} {
		{"a holder of the grant that never wires", never},
		{"a comment naming Wire_Step and Root_Command.Wire", in_comment},
		{"a string literal naming Wire_Step and Root_Command.Wire", in_string},
		{"a local Wire_Step without importing modus:contract/root_ring", unimported},
		{"Wire_Step.None alone", wire_step_none},
		{"a call passing .Start instead of .Wire", other_command},
		{"an unrelated procedure taking .Wire", unrelated_call},
		{"a step named in another package", in_a_package},
		{"a step named in a test", in_a_test},
	}) {
		got, got_ok := floor_wiring_derived("console", "src/modules/system/console", item.sources)
		testing.expectf(t, got_ok && !got, "%s must not derive wiring", item.about)
	}
	_, broken_ok := floor_wiring_derived("console", "src/modules/system/console", broken_source)
	testing.expect(t, !broken_ok, "a broken own source file fails floor_wiring_derived")

	policy, policy_ok := floor_wiring_derived("start_policy", "src/modules/system/start_policy", wires)
	testing.expect(t, policy_ok && !policy)
	clock, clock_ok := floor_wiring_derived("clock", "src/modules/demonstrations/clock", wires)
	testing.expect(t, clock_ok && !clock, "no grant Root_Ring")
	nobody, nobody_ok := floor_wiring_derived("no_such_module", "src/modules/x", wires)
	testing.expect(t, nobody_ok && !nobody)

	// Genuine wiring cases last.
	for item in ([?]struct {
		about:   string,
		sources: []Fact_Source,
	} {
		{"root_ring.Wire_Step.Apply", wires},
		{"cross-file helper call with positional .Wire", cross_file_call},
		{"cross-file helper call with named .Wire", named_arg_call},
		{"aliased import rr.Root_Command.Wire", aliased_import},
	}) {
		got, got_ok := floor_wiring_derived("console", "src/modules/system/console", item.sources)
		testing.expectf(t, got_ok && got, "%s must derive wiring", item.about)
	}
}

// A derived wiring budget is as large as the rest of the floor, so the
// carve of half of the floor is the wiring part; a stated one is taken as
// it is; the start budgets count at their pages.
@(test)
the_floor_holds_the_wiring_carve_and_the_child_budgets :: proc(t: ^testing.T) {
	plain, _ := floor_count({modules = {{pages = 1, segment_pages = {1}}}})
	derived, derived_ok := floor_count({modules = {{pages = 1, segment_pages = {1}}}, wiring_derived = true})
	testing.expect(t, derived_ok)
	testing.expect_value(t, derived.floor.wiring_pages, plain.floor.pages)
	testing.expect_value(t, derived.floor.pages, 2 * plain.floor.pages)
	stated, _ := floor_count({stated = {wiring_pages = 28}, modules = {{pages = 1, segment_pages = {1}}}, wiring_derived = true})
	testing.expect_value(t, stated.floor.wiring_pages, 28)
	testing.expect_value(t, stated.floor.pages, plain.floor.pages + 28)
	budgets, _ := floor_count({modules = {{pages = 1, segment_pages = {1}}}, start_budgets = {900, 900}})
	testing.expect_value(t, budgets.floor.pages, plain.floor.pages + 1800)
	_, huge_ok := floor_count({start_budgets = {max(u64)}})
	testing.expect(t, !huge_ok)
	_, huge_wiring_ok := floor_count({stated = {working_memory_pages = max(u64) / 2 + 1}, wiring_derived = true})
	testing.expect(t, !huge_wiring_ok, "a derived wiring part past 64 bits is refused")
}
