package build

import "core:fmt"
import "core:os"
import "core:strings"
import "modus:contract/module"
import "modus:contract/output"
import "modus:contract/start_list"
import "modustool:foundation"
import "modustool:resources"

// The start lists of the boot images (src/md/features/start_policy.md):
// the rows that the default start policy and the rescue start policy read,
// in their order, written as the resources start_list and rescue_list of
// each image. The tool writes each list through the contract and reads it
// back through its border, and refuses at each build a list that the
// border refuses, a row that names no module with an entry in the image,
// a rescue list with no row that makes the machine usable, and a wiring
// row that the module files of its two rows refuse. A list of a released
// image is then never refused at the start.

// One row of a list, as this table writes it.
Start_List_Row :: struct {
	name:          string,
	needs:         start_list.Machine_Parts,
	absent_rule:   start_list.Absent_Part_Rule,
	usable_mark:   start_list.Usable_Mark,
	restart_count: u32,
}

// One wiring row of a list, as this table writes it: the record output of
// the start row writer, by its name or WIRING_OUTPUT_LOG, to the record
// input of the start row reader, which comes before it
// (src/md/features/module_outputs.md, "The wiring rows of a start list").
Start_List_Wiring :: struct {
	writer:        string,
	record_output: string,
	reader:        string,
	record_input:  string,
	pace:          output.Wiring_Pace,
	capacity:      u32, // 0: the default.
}

// The name of the record output log of a writer row in this table.
WIRING_OUTPUT_LOG :: "log"

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
	// The demonstration pair: the reader first, so the start of the writer
	// carries the wiring row, and the reader reads from the serial 0.
	{name = "wired_reader", absent_rule = .Not_Started},
	{name = "wired_writer", absent_rule = .Not_Started},
}

// The wiring rows of the default start list.
@(rodata)
DEFAULT_START_WIRINGS := [?]Start_List_Wiring{{writer = "wired_writer", record_output = "numbers", reader = "wired_reader", record_input = "numbers"}}

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
	start:          []Start_List_Row,
	start_wirings:  []Start_List_Wiring,
	rescue:         []Start_List_Row,
	rescue_wirings: []Start_List_Wiring,
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
	return {start = DEFAULT_START_LIST[:], start_wirings = DEFAULT_START_WIRINGS[:], rescue = DEFAULT_RESCUE_LIST[:]}
}

// The module files that the check of the wiring rows reads, by the name of
// their module: a file that is absent names no record stream.
Module_Files :: map[string][]u8

// start_list_bytes writes the bytes of a list through the contract, and
// reads them back through its border. problem: why the list is refused,
// or "".
start_list_bytes :: proc(rows: []Start_List_Row, wirings: []start_list.Wiring_Row_Record = nil) -> (bytes: []u8, list: start_list.List, problem: string) {
	if len(rows) > start_list.ROW_CAPACITY {
		return nil, {}, fmt.tprintf("it has %d rows, and a list holds %d", len(rows), start_list.ROW_CAPACITY)
	}
	if len(wirings) > start_list.WIRING_ROW_CAPACITY {
		return nil, {}, fmt.tprintf("it has %d wiring rows, and a list holds %d", len(wirings), start_list.WIRING_ROW_CAPACITY)
	}
	written := make([]start_list.Start_Row, len(rows), context.temp_allocator)
	for row, index in rows {
		made, ok := start_list.row_make(row.name, row.needs, row.absent_rule, row.usable_mark, row.restart_count)
		if !ok {
			return nil, {}, fmt.tprintf("the row %d names %q, which is not a module name", index, row.name)
		}
		written[index] = made
	}
	bytes = make([]u8, start_list.list_size(len(rows), len(wirings)), context.temp_allocator)
	if _, ok := start_list.list_write(written, wirings, bytes); !ok {
		return nil, {}, "the contract does not write it"
	}
	if read_problem, place, refusal := start_list.list_read(bytes, &list); read_problem != .None {
		if read_problem == .Wiring_Refused {
			return nil, {}, fmt.tprintf("its border refuses it: %s, at its wiring row %d: the field %d of output.Wiring_Field, the word %d", start_list.LIST_PROBLEM_TEXTS[read_problem], place, refusal.argument, refusal.value)
		}
		return nil, {}, fmt.tprintf("its border refuses it: %s, at its row %d", start_list.LIST_PROBLEM_TEXTS[read_problem], place)
	}
	return bytes, list, ""
}

// The file of a record stream: a module file with the record at an index.
@(private = "file")
Stream_File :: struct {
	file:   []u8,
	record: u32,
}

// stream_name_find gives the row of a record output or a record input of a
// module file by its name, from 1, or 0.
@(private = "file")
stream_name_find :: proc(file: []u8, kind: module.Table_Kind, name: string) -> u32 {
	for index in 1 ..< max(module.count(file, kind), 1) {
		row_name: string
		if kind == .Record_Outputs {
			row, _, _, ok := module.record_output(file, index)
			if !ok {
				continue
			}
			row_name = module.string_at(file, row.name_offset, row.name_count)
		} else {
			row, _, _, _, ok := module.record_input(file, index)
			if !ok {
				continue
			}
			row_name = module.string_at(file, row.name_offset, row.name_count)
		}
		if row_name == name {
			return index
		}
	}
	return 0
}

// start_list_wiring_records gives the record of each wiring row of a list,
// and the size of its record, after the checks that the module files of
// its two rows give (src/md/features/module_outputs.md, "The decisions of
// the wiring rows"): a row of the list at each end, a writer that the root
// service does not start in its own way, a record output that the writer
// declares and that is neither generic nor Paired, a log with a pace other
// than Never_Holds_Writer, a record input that the reader declares and
// that takes no terms, two equal records, and one row for a record input
// of the count One: each refusal of the root service that the files show.
// The order of the rows, a row that loops, the ends and a writer row with
// restarts are the border of the contract (start_list_bytes). Each fault
// is one problem, and a row with a fault gives no record.
start_list_wiring_records :: proc(rows: []Start_List_Row, wirings: []Start_List_Wiring, files: Module_Files) -> (records: []start_list.Wiring_Row_Record, record_sizes: []u32, problems: []string) {
	found := make([dynamic]string, context.temp_allocator)
	written := make([dynamic]start_list.Wiring_Row_Record, context.temp_allocator)
	sizes := make([dynamic]u32, context.temp_allocator)
	row_of :: proc(rows: []Start_List_Row, name: string) -> int {
		for row, index in rows {
			if row.name == name {
				return index
			}
		}
		return -1
	}
	log_file := make([]u8, output.DESCRIPTION_FILE_BYTES_MOST, context.temp_allocator)
	log_size, _ := output.log_output_file_write(log_file)
	for wiring, number in wirings {
		at := fmt.tprintf("the wiring row %d (%s.%s to %s.%s)", number, wiring.writer, wiring.record_output, wiring.reader, wiring.record_input)
		writer_row, reader_row := row_of(rows, wiring.writer), row_of(rows, wiring.reader)
		if writer_row < 0 || reader_row < 0 {
			append(&found, fmt.tprintf("%s names a module that is no row of the list", at))
			continue
		}
		if start_list.root_procedure_of(wiring.writer) != .None {
			append(&found, fmt.tprintf("%s has a writer that the root service starts in its own way, with no wiring list", at))
			continue
		}
		writer_file, has_writer := files[wiring.writer]
		reader_file, has_reader := files[wiring.reader]
		if !has_writer || !has_reader {
			append(&found, fmt.tprintf("%s names a module with no module file", at))
			continue
		}
		record := start_list.Wiring_Row_Record {
			writer_row = u32(writer_row + 1),
			wiring = {writer_end = u32(output.Wiring_End.Child), reader_end = u32(output.Wiring_End.Started), reader_handle = u32(reader_row + 1), pace = u32(wiring.pace), capacity = wiring.capacity},
		}
		writer: Stream_File
		if wiring.record_output == WIRING_OUTPUT_LOG {
			// The writer of log waits for room with no deadline: a row that
			// says it never waits is refused, as the root service refuses it.
			if wiring.pace == .Never_Holds_Writer {
				append(&found, fmt.tprintf("%s wires the log with the pace Never_Holds_Writer, which the writer of log does not keep", at))
				continue
			}
			record.wiring.writer_stream = u32(output.Writer_Stream.Log)
			writer = {log_file[:log_size], output.DESCRIPTION_RECORD_INDEX}
		} else {
			index := stream_name_find(writer_file, .Record_Outputs, wiring.record_output)
			if index == 0 {
				append(&found, fmt.tprintf("%s names a record output that the module %s does not declare", at, wiring.writer))
				continue
			}
			row, pairing, _, _ := module.record_output(writer_file, index)
			if pairing == .Paired {
				append(&found, fmt.tprintf("%s names a record output Paired, which the root service refuses until the collector", at))
				continue
			}
			if row.record == 0 {
				append(&found, fmt.tprintf("%s names a generic record output, whose type no row of a start list fixes", at))
				continue
			}
			record.wiring.writer_stream, record.wiring.writer_index = u32(output.Writer_Stream.Record_Output), index
			writer = {writer_file, row.record}
		}
		input_index := stream_name_find(reader_file, .Record_Inputs, wiring.record_input)
		if input_index == 0 {
			append(&found, fmt.tprintf("%s names a record input that the module %s does not declare", at, wiring.reader))
			continue
		}
		input_row, input_wirings, _, _, _ := module.record_input(reader_file, input_index)
		if input_row.terms != 0 {
			append(&found, fmt.tprintf("%s names a record input that takes terms, which a start list does not give", at))
			continue
		}
		if input_row.record != 0 {
			if difference, part := output.record_descriptions_compare(writer.file, writer.record, reader_file, input_row.record); difference != .Equal {
				append(&found, fmt.tprintf("%s joins two records that differ: %v, at the part %d", at, difference, part))
				continue
			}
		}
		record.wiring.reader_index = input_index
		taken := false
		for &before in written {
			taken ||= before.wiring.reader_handle == record.wiring.reader_handle && before.wiring.reader_index == input_index
		}
		if taken && input_wirings == .One {
			append(&found, fmt.tprintf("%s is a second row to a record input that takes one wiring", at))
			continue
		}
		described, _ := module.record_stream_type(writer.file, writer.record)
		append(&written, record)
		append(&sizes, described.size)
	}
	return written[:], sizes[:], found[:]
}

// start_list_problems gives each fault of a list against the modules of an
// image: the refusal of its border, a row that names no module with an
// entry in the image, for a rescue list no row with the mark Needed, each
// fault of a wiring row against the module files, and wiring rows that
// need more pages than the reserve of the start policy.
start_list_problems :: proc(rows: []Start_List_Row, image_modules: []string, rescue: bool, wirings: []Start_List_Wiring = nil, files: Module_Files = nil) -> []string {
	problems := make([dynamic]string, context.temp_allocator)
	records, sizes, wiring_problems := start_list_wiring_records(rows, wirings, files)
	append(&problems, ..wiring_problems)
	_, list, problem := start_list_bytes(rows, records)
	if problem != "" {
		append(&problems, problem)
	} else if len(wiring_problems) == 0 {
		pages, counted := start_list.wiring_pages_of_list(&list, sizes)
		if !counted || pages > start_list.WIRING_PAGES_RESERVE {
			append(&problems, fmt.tprintf("its wiring rows need %d pages of the budget of the start policy, past its reserve of %d", pages, start_list.WIRING_PAGES_RESERVE))
		}
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
		wirings:  []Start_List_Wiring,
		resource: string,
		rescue:   bool,
	}{{lists.start, lists.start_wirings, start_list.START_LIST_RESOURCE, false}, {lists.rescue, lists.rescue_wirings, start_list.RESCUE_LIST_RESOURCE, true}}
	for kind in kinds {
		// The module files of the rows that a wiring row names: the build
		// wrote each one before the image.
		files := make(Module_Files, context.temp_allocator)
		for wiring in kind.wirings {
			for name in ([2]string{wiring.writer, wiring.reader}) {
				if name in files {
					continue
				}
				if file, read := foundation.read_file(foundation.module_path(name)); read {
					files[name] = file
				}
			}
		}
		problems := start_list_problems(kind.rows, modules, kind.rescue, kind.wirings, files)
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
		records, _, _ := start_list_wiring_records(kind.rows, kind.wirings, files)
		bytes, _, problem := start_list_bytes(kind.rows, records)
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

// The imports that the source of the start policy may name. operation and
// value_kinds give the types of the fields of its log facts, which the
// tool reads by their names; they hold no logic of a start. wiring_rows
// holds the decisions of the wiring rows, with their host tests, so the
// start policy keeps only their calls.
@(rodata)
START_POLICY_ALLOWED_IMPORTS := [?]string{"modus:contract/start_list", "modus:contract/root_ring", "modus:contract/ring", "modus:contract/operation", "modus:contract/value_kinds", "internal:start_policy/wiring_rows", "modus:system"}

// source_import_problems gives each import of the sources, tests not
// counted, that allowed refuses, each foreign import or block, and each
// import with no path; why ends each sentence. sources holds each file as
// its path and its text. lines is the count of the lines, tests not
// counted.
source_import_problems :: proc(sources: [][2]string, allowed: proc(imported: string) -> bool, why: string) -> (problems: [dynamic]string, lines: int) {
	problems = make([dynamic]string, context.temp_allocator)
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
				append(&problems, fmt.tprintf("%s: a foreign import or block: %s: %s", path, trimmed, why))
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
			if !allowed(imported) {
				append(&problems, fmt.tprintf("%s: the import %s is refused: %s", path, imported, why))
			}
		}
	}
	return
}

// start_policy_source_problems gives each fault of the sources of the
// start policy, tests not counted: more lines than the bound in all its
// files, and an import that is not base: or of the allowed set.
start_policy_source_problems :: proc(sources: [][2]string) -> []string {
	allowed :: proc(imported: string) -> bool {
		for name in START_POLICY_ALLOWED_IMPORTS {
			if imported == name {
				return true
			}
		}
		return strings.has_prefix(imported, "base:")
	}
	problems, lines := source_import_problems(sources, allowed, fmt.tprintf("the start policy imports base: and %v only, and holds no logic of its own", START_POLICY_ALLOWED_IMPORTS))
	if lines > START_POLICY_SOURCE_LINE_LIMIT {
		append(&problems, fmt.tprintf("the source of the start policy has %d lines, tests not counted, past the bound of %d: it reads a list in its order, and holds no graph and no logic", lines, START_POLICY_SOURCE_LINE_LIMIT))
	}
	return problems[:]
}

// The library part of the wiring rows of the start policy: it makes no
// call of the kernel, so its host tests reach each decision
// (src/md/features/start_policy.md, "The rescue start policy").
WIRING_ROWS_FOLDER :: foundation.SOURCE_FOLDER_INTERNAL + "/start_policy/wiring_rows"

// wiring_rows_source_problems gives each import of the sources of
// wiring_rows, tests not counted, that is not base: or a contract: a
// support package, as system, calls the kernel, and a package of core:
// calls the host.
wiring_rows_source_problems :: proc(sources: [][2]string) -> []string {
	allowed :: proc(imported: string) -> bool {
		return strings.has_prefix(imported, "base:") || strings.has_prefix(imported, "modus:contract/")
	}
	problems, _ := source_import_problems(sources, allowed, "wiring_rows imports base: and the contracts only: it makes no call of the kernel")
	return problems[:]
}

// start_policy_source_check reads the source folders of the start policy
// and of wiring_rows, and stops the build at a fault.
start_policy_source_check :: proc() -> bool {
	checks := [2]struct {
		folder:   string,
		problems: proc(sources: [][2]string) -> []string,
	}{{foundation.join(foundation.SYSTEM_MODULE_SOURCES, foundation.START_POLICY_MODULE), start_policy_source_problems}, {WIRING_ROWS_FOLDER, wiring_rows_source_problems}}
	ok := true
	for check in checks {
		paths := foundation.files_with_suffix(check.folder, ".odin") or_return
		sources := make([dynamic][2]string, context.temp_allocator)
		for path in paths {
			text := foundation.read_text_file(path) or_return
			append(&sources, [2]string{path, text})
		}
		for problem in check.problems(sources[:]) {
			fmt.eprintfln("modustool: %s", problem)
			ok = false
		}
	}
	return ok
}
