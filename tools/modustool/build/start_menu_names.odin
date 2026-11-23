// The lists of the start menu, written from the table of the modules
// (src/md/features/desktop_shell_look.md, "The start menu").
package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "internal:compositor/bar"
import "modustool:foundation"

// The file of the lists of the start menu, in the internal part of the bar
// of the compositor.
START_MENU_NAMES_FILE :: foundation.SOURCE_FOLDER_INTERNAL + "/compositor/bar/start_menu_names.odin"

// start_menu_section_of_row gives the section of the start menu of a row of
// the table of the modules: a module of the boot image with an entry, whose
// category is an application, a system tool, a developer tool or a
// demonstration, and whose row lists it (foundation.Menu_Presence). listed
// is false for each other row: a service, a library, a test module, a
// module that no principal starts, the partner of another process, and a
// module whose result is only on the log.
start_menu_section_of_row :: proc(row: foundation.Module_Build) -> (section: bar.Menu_Section, listed: bool) {
	if !row.entry || !foundation.module_in_boot_image(row) {
		return .Applications, false
	}
	switch row.menu {
	case .Listed:
	case .Partner_Only, .Log_Only:
		return .Applications, false
	}
	category, problem := foundation.module_category_of_row(row)
	if problem != "" {
		return .Applications, false
	}
	switch category {
	case .Application:
		return .Applications, true
	case .System_Tool, .Developer_Tool:
		return .Tools, true
	case .Demonstration:
		return .Demonstrations, true
	case .None, .Service, .Library, .Test:
	}
	return .Applications, false
}

// start_menu_names_of_table gives the names of the start menu, by section,
// each section in the order of the bytes of the names.
start_menu_names_of_table :: proc(rows: []foundation.Module_Build) -> (sections: [bar.Menu_Section][]string) {
	lists: [bar.Menu_Section][dynamic]string
	for section in bar.Menu_Section {
		lists[section] = make([dynamic]string, context.temp_allocator)
	}
	for row in rows {
		if section, listed := start_menu_section_of_row(row); listed {
			append(&lists[section], row.name)
		}
	}
	for section in bar.Menu_Section {
		slice.sort(lists[section][:])
		sections[section] = lists[section][:]
	}
	return sections
}

// start_menu_names_text gives the text of START_MENU_NAMES_FILE for the
// table of the modules.
start_menu_names_text :: proc(rows: []foundation.Module_Build) -> string {
	sections := start_menu_names_of_table(rows)
	out := strings.builder_make(context.temp_allocator)
	strings.write_string(&out, "// This file is the output of the build of the tool\n// (tools/modustool/build/start_menu_names.odin), from the table of the\n// modules. Do not change it by hand.\npackage bar\n\n")
	strings.write_string(&out, "// The modules of the start menu: the applications, then the tools, then\n// the demonstrations, each section in the order of the alphabet.\n@(rodata)\nnames := [?]string {\n")
	for section in bar.Menu_Section {
		for name in sections[section] {
			fmt.sbprintf(&out, "\t%q,\n", name)
		}
	}
	strings.write_string(&out, "}\n\n// The icon of each module of names, at the same index (icon_of).\n@(rodata)\nname_icons := [?]Icon {\n")
	for section in bar.Menu_Section {
		for name in sections[section] {
			fmt.sbprintf(&out, "\t.%v,\n", bar.icon_of(name))
		}
	}
	strings.write_string(&out, "}\n#assert(len(name_icons) == len(names))\n\n")
	fmt.sbprintf(&out, "APPLICATION_COUNT :: %d // The applications: the first names.\n", len(sections[.Applications]))
	fmt.sbprintf(&out, "TOOL_COUNT :: %d // The tools: the names after the applications.\n", len(sections[.Tools]))
	return strings.to_string(out)
}

// start_menu_names_write writes START_MENU_NAMES_FILE when its text is not
// the text of the table of the modules, before any module is compiled, so
// that the compositor that the build compiles lists the modules of the
// table. A file with the same text is not written: its time stays, and no
// build of the compositor starts again for it.
start_menu_names_write :: proc() -> bool {
	text := start_menu_names_text(foundation.module_builds[:])
	if kept, read := os.read_entire_file(START_MENU_NAMES_FILE, context.temp_allocator); read == nil && string(kept) == text {
		return true
	}
	if error := os.write_entire_file(START_MENU_NAMES_FILE, transmute([]u8)text); error != nil {
		fmt.eprintfln("modustool: cannot write %s: %v", START_MENU_NAMES_FILE, error)
		return false
	}
	fmt.printfln("modustool: %s is written again from the table of the modules", START_MENU_NAMES_FILE)
	return true
}
