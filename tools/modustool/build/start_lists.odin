package build

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/start_list"
import "modustool:foundation"
import "modustool:resources"

// The start lists of the boot images (src/md/features/start_policy.md):
// the rows that the default start policy and the rescue start policy read,
// in their order, written as the resources start_list and rescue_list of
// each image. The tool writes each list through the contract and reads it
// back through its border, and refuses at each build a list that the
// border refuses, a row that names no module with an entry in the image,
// and a rescue list with no row that makes the machine usable. A list of a
// released image is then never refused at the start.

// One row of a list, as this table writes it.
Start_List_Row :: struct {
	name:          string,
	needs:         start_list.Machine_Parts,
	absent_rule:   start_list.Absent_Part_Rule,
	usable_mark:   start_list.Usable_Mark,
	restart_count: u32,
}

// The default start list: the start of the machine, row by row as the
// design maps it. The entropy service and the TPM service are no row: the
// seed and the keys of the machine need them before any start policy.
@(rodata)
DEFAULT_START_LIST := [?]Start_List_Row {
	// With no screen, no window reads a key. An absent PS/2 controller is
	// the line of the input service itself, which stops.
	{name = "input", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "compositor", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "date", absent_rule = .Not_Started},
	// A failure of the console no longer stops the machine: the start
	// policy stops before Machine_Usable, and the rescue starts.
	{name = "console", needs = {.Screen}, absent_rule = .Not_Started, usable_mark = .Needed},
	// The pass of the kept settings: it writes the page, then ends.
	{name = "settings", absent_rule = .Not_Started},
	{name = "unlock", absent_rule = .Not_Started},
}

// The rescue list: a principal reaches the machine through the console
// when the machine has a screen, and through remote when it has a network
// device and a client key that principal 0 allowed. remote is not needed:
// a machine with a screen is usable without it.
@(rodata)
DEFAULT_RESCUE_LIST := [?]Start_List_Row {
	{name = "input", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "compositor", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "console", needs = {.Screen}, absent_rule = .Not_Started, usable_mark = .Needed},
	{name = "remote", needs = {.Network_Device}, absent_rule = .Not_Started},
}

// The machine of the shortage of frames: one row, which the rescue list
// repeats, as the image holds no input service.
@(rodata)
SHORTAGE_START_LIST := [?]Start_List_Row{{name = "shortage", absent_rule = .Not_Started, usable_mark = .Needed}}

// The machine of the operation sequences: one row, which the rescue list
// repeats.
@(rodata)
OPERATION_SEQUENCES_START_LIST := [?]Start_List_Row{{name = foundation.OPERATION_FUZZING_MODULE, absent_rule = .Not_Started, usable_mark = .Needed}}

// The module that the row of the console names in the list of the test of
// the rescue: no module has this name.
MISSING_CONSOLE_MODULE :: "console_missing"

// The module of a test machine that the list of the test of the rescue
// names, and that its image does not hold: the root service refuses it
// before its procedure, which would stop the machine.
ABSENT_TEST_MODULE :: "shortage"

// The default start list with a row of the console that names a module
// that does not exist: the test of the rescue (start_policy_tests_run).
// Before it, a row of `shortage`, which only the image of its test holds.
// The check of the lists refuses it for these two rows, and for nothing
// else: it goes only into the image of that test.
@(rodata)
MISSING_CONSOLE_START_LIST := [?]Start_List_Row {
	{name = "input", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "compositor", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "date", absent_rule = .Not_Started},
	{name = ABSENT_TEST_MODULE, absent_rule = .Not_Started},
	{name = MISSING_CONSOLE_MODULE, needs = {.Screen}, absent_rule = .Not_Started, usable_mark = .Needed},
}

// The count of the restarts of the two rows of the test of the restarts:
// two, so that a row that restarts writes the counts 1 and 0 left, then
// stays stopped.
STOP_TEST_RESTARTS :: 2

// The rescue list of the test of the rescue: the default rescue list, then
// the two rows of the test of the restarts (src/md/features/start_policy.md,
// "The subtle points"). The rescue makes the machine usable, so its
// watch reads each stop: stops_refused stops with Refused and does not
// start again, stops_failed stops with Failed and starts again until its
// restarts end.
@(rodata)
MISSING_CONSOLE_RESCUE_LIST := [?]Start_List_Row {
	{name = "input", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "compositor", needs = {.Screen}, absent_rule = .Not_Started},
	{name = "console", needs = {.Screen}, absent_rule = .Not_Started, usable_mark = .Needed},
	{name = "remote", needs = {.Network_Device}, absent_rule = .Not_Started},
	{name = "stops_refused", absent_rule = .Not_Started, restart_count = STOP_TEST_RESTARTS},
	{name = "stops_failed", absent_rule = .Not_Started, restart_count = STOP_TEST_RESTARTS},
}

// The rows that the check must refuse in the list of the test of the
// rescue, each for a name of no module of the image.
@(rodata)
REFUSED_ON_PURPOSE_ROWS := [?]string{ABSENT_TEST_MODULE, MISSING_CONSOLE_MODULE}

// The lists of one boot image.
Start_Lists :: struct {
	start:  []Start_List_Row,
	rescue: []Start_List_Row,
	// The start list holds a row that the check refuses on purpose: the
	// build checks that the check refuses it, then writes it.
	start_refused_on_purpose: bool,
}

// start_lists_of_image gives the lists of a boot image of the build.
start_lists_of_image :: proc(image_path: string) -> Start_Lists {
	switch image_path {
	case BOOT_IMAGE_SHORTAGE:
		return {start = SHORTAGE_START_LIST[:], rescue = SHORTAGE_START_LIST[:]}
	case foundation.BOOT_IMAGE_OPERATION_SEQUENCES:
		return {start = OPERATION_SEQUENCES_START_LIST[:], rescue = OPERATION_SEQUENCES_START_LIST[:]}
	case BOOT_IMAGE_MISSING_CONSOLE:
		return {start = MISSING_CONSOLE_START_LIST[:], rescue = MISSING_CONSOLE_RESCUE_LIST[:], start_refused_on_purpose = true}
	}
	return {start = DEFAULT_START_LIST[:], rescue = DEFAULT_RESCUE_LIST[:]}
}

// start_list_bytes writes the bytes of a list through the contract, and
// reads them back through its border. problem: why the list is refused,
// or "".
start_list_bytes :: proc(rows: []Start_List_Row) -> (bytes: []u8, problem: string) {
	if len(rows) > start_list.ROW_CAPACITY {
		return nil, fmt.tprintf("it has %d rows, and a list holds %d", len(rows), start_list.ROW_CAPACITY)
	}
	written := make([]start_list.Start_Row, len(rows), context.temp_allocator)
	for row, index in rows {
		made, ok := start_list.row_make(row.name, row.needs, row.absent_rule, row.usable_mark, row.restart_count)
		if !ok {
			return nil, fmt.tprintf("the row %d names %q, which is not a module name", index, row.name)
		}
		written[index] = made
	}
	bytes = make([]u8, start_list.list_size(len(rows)), context.temp_allocator)
	if _, ok := start_list.list_write(written, bytes); !ok {
		return nil, "the contract does not write it"
	}
	read: [start_list.ROW_CAPACITY]start_list.Start_Row
	if _, read_problem, place := start_list.list_read(bytes, &read); read_problem != .None {
		return nil, fmt.tprintf("its border refuses it: %s, at its row %d", start_list.LIST_PROBLEM_TEXTS[read_problem], place)
	}
	return bytes, ""
}

// start_list_problems gives each fault of a list against the modules of an
// image: the refusal of its border, a row that names no module with an
// entry in the image, and for a rescue list no row with the mark Needed.
start_list_problems :: proc(rows: []Start_List_Row, image_modules: []string, rescue: bool) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	if _, problem := start_list_bytes(rows); problem != "" {
		append(&problems, problem)
	}
	for row in rows {
		found := false
		for name in image_modules {
			found ||= name == row.name
		}
		if !found {
			append(&problems, fmt.tprintf("the row %s names no module with an entry in the image", row.name))
		}
	}
	if rescue {
		usable := false
		for row in rows {
			usable ||= row.usable_mark == .Needed
		}
		if !usable {
			append(&problems, "it is a rescue list with no row that makes the machine usable (no row with the mark Needed)")
		}
	}
	return problems[:]
}

// image_modules_with_an_entry gives the modules with an entry of a boot
// image, as build_boot_image chooses them.
image_modules_with_an_entry :: proc(path: string, without: string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for build in foundation.module_builds {
		in_this_image := foundation.module_in_boot_image(build) && build.name != without || foundation.module_in_a_boot_image(build) && build.only_in_image == path
		if in_this_image && build.entry {
			append(&names, build.name)
		}
	}
	return names[:]
}

// start_list_resources checks the two lists of an image and writes each
// one as a resource file beside the image. A list that its check refuses
// stops the build, with each problem; the list of the test of the rescue
// must be refused, with its one row, or the build stops too.
start_list_resources :: proc(path: string, without: string) -> (files: []resources.Resource_File, ok: bool) {
	lists := start_lists_of_image(path)
	modules := image_modules_with_an_entry(path, without)
	written := make([dynamic]resources.Resource_File, context.temp_allocator)
	kinds := [2]struct {
		rows:     []Start_List_Row,
		resource: string,
		rescue:   bool,
	}{{lists.start, start_list.START_LIST_RESOURCE, false}, {lists.rescue, start_list.RESCUE_LIST_RESOURCE, true}}
	for kind in kinds {
		problems := start_list_problems(kind.rows, modules, kind.rescue)
		refused_on_purpose := lists.start_refused_on_purpose && !kind.rescue
		if refused_on_purpose {
			if !refused_for_the_rows(problems, REFUSED_ON_PURPOSE_ROWS[:]) {
				fmt.eprintfln("modustool: the start list of %s must be refused for its rows %v alone, and its check gives: %v", path, REFUSED_ON_PURPOSE_ROWS, problems)
				return nil, false
			}
		} else if len(problems) > 0 {
			for problem in problems {
				fmt.eprintfln("modustool: the list %s of %s is refused: %s", kind.resource, path, problem)
			}
			return nil, false
		}
		bytes, problem := start_list_bytes(kind.rows)
		if problem != "" {
			fmt.eprintfln("modustool: the list %s of %s is refused: %s", kind.resource, path, problem)
			return nil, false
		}
		file := fmt.tprintf("%s_%s.resource", strings.trim_suffix(path, ".image"), kind.resource)
		if err := os.write_entire_file(file, bytes); err != nil {
			fmt.eprintfln("modustool: cannot write %s: %v", file, err)
			return nil, false
		}
		append(&written, resources.Resource_File{name = kind.resource, path = file})
	}
	return written[:], true
}

// refused_for_the_rows says if the problems are one problem of the module
// of each row, in the order of the rows, and nothing else.
refused_for_the_rows :: proc(problems: []string, rows: []string) -> bool {
	if len(problems) != len(rows) {
		return false
	}
	for row, index in rows {
		if !strings.contains(problems[index], fmt.tprintf("the row %s names no module", row)) {
			return false
		}
	}
	return true
}

// The bound of the source of the start policy: it reads a list and asks
// for the starts, and holds no graph and no logic of its own.
START_POLICY_SOURCE_LINE_LIMIT :: 400

// The imports that the source of the start policy may name.
@(rodata)
START_POLICY_ALLOWED_IMPORTS := [?]string{"modus:contract/start_list", "modus:contract/root_ring", "modus:contract/ring", "modus:support/system"}

// start_policy_source_problems gives each fault of the sources of the
// start policy, tests not counted: more lines than the bound in all its
// files, and an import that is not base: or of the allowed set. sources
// holds each file as its path and its text.
start_policy_source_problems :: proc(sources: [][2]string) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	lines := 0
	for source in sources {
		path, text := source[0], source[1]
		if strings.has_suffix(path, "_test.odin") {
			continue
		}
		lines += strings.count(text, "\n")
		for line in strings.split_lines(text, context.temp_allocator) {
			trimmed := strings.trim_space(line)
			// A foreign import or block reaches code that no description of
			// a module names, past the allowed set: refused whole.
			if strings.has_prefix(trimmed, "foreign") {
				append(&problems, fmt.tprintf("%s: a foreign import or block: %s: the start policy holds no code of its own past its imports", path, trimmed))
				continue
			}
			// A bare `import` and a grouped `import (` are imports too: the
			// path check below refuses each one, so no import escapes it.
			if trimmed != "import" && !strings.has_prefix(trimmed, "import ") && !strings.has_prefix(trimmed, "import(") {
				continue
			}
			first := strings.index_byte(trimmed, '"')
			last := strings.last_index_byte(trimmed, '"')
			if first < 0 || last <= first {
				append(&problems, fmt.tprintf("%s: an import with no path: %s", path, trimmed))
				continue
			}
			imported := trimmed[first + 1:last]
			allowed := strings.has_prefix(imported, "base:")
			for name in START_POLICY_ALLOWED_IMPORTS {
				allowed ||= imported == name
			}
			if !allowed {
				append(&problems, fmt.tprintf("%s: the import %s is not base: or one of %v: the start policy holds no logic of its own", path, imported, START_POLICY_ALLOWED_IMPORTS))
			}
		}
	}
	if lines > START_POLICY_SOURCE_LINE_LIMIT {
		append(&problems, fmt.tprintf("the source of the start policy has %d lines, tests not counted, past the bound of %d: it reads a list in its order, and holds no graph and no logic", lines, START_POLICY_SOURCE_LINE_LIMIT))
	}
	return problems[:]
}

// start_policy_source_check reads the source folder of the start policy and
// stops the build at a fault.
start_policy_source_check :: proc() -> bool {
	folder := foundation.join(foundation.SYSTEM_MODULE_SOURCES, foundation.START_POLICY_MODULE)
	paths := foundation.files_with_suffix(folder, ".odin") or_return
	sources := make([dynamic][2]string, context.temp_allocator)
	for path in paths {
		text := foundation.read_text_file(path) or_return
		append(&sources, [2]string{path, text})
	}
	problems := start_policy_source_problems(sources[:])
	for problem in problems {
		fmt.eprintfln("modustool: %s", problem)
	}
	return len(problems) == 0
}
