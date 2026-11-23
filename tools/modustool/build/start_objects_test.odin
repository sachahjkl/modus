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
