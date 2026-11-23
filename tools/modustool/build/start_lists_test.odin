package build

import "core:strings"
import "core:testing"
import "modus:contract/module"
import "modus:contract/module_file_writer"
import "modus:contract/output"
import "modus:contract/start_list"
import "modus:contract/wide_grants"
import "modustool:foundation"

// stream_module_file gives a module file with one data segment, these
// records, and these record outputs and record inputs, each sorted by name.
@(private = "file")
stream_module_file :: proc(records: []module_file_writer.Record_Description, outputs: []module_file_writer.Record_Output_Part, inputs: []module_file_writer.Record_Input_Part) -> []u8 {
	segments := make([]module_file_writer.Segment_Part, 1, context.temp_allocator)
	segments[0] = {memory_offset = 0, memory_size = module.PAGE_SIZE, flags = {.Read, .Write}}
	parts := module_file_writer.Module_Parts {
		segments       = segments,
		records        = records,
		record_outputs = outputs,
		record_inputs  = inputs,
	}
	bytes := make([]u8, 64 * 1024, context.temp_allocator)
	size, refusal := module_file_writer.write(parts, bytes)
	assert(refusal.refusal == .None, "the module file of the test is refused")
	return bytes[:size]
}

// The module files of the test of the wiring rows: a writer of numbers, of
// another record and of a generic record output, which also reads numbers
// back; and a reader of numbers with one wiring, of numbers with many, of
// numbers with terms, and of any record.
@(private = "file")
wired_files :: proc() -> Module_Files {
	number_fields := make([]module_file_writer.Field_Description, 2, context.temp_allocator)
	number_fields[0] = {name = "number", offset = 0, type = .Integer, unsigned = true}
	number_fields[1] = {name = "square", offset = 8, type = .Integer, unsigned = true}
	other_fields := make([]module_file_writer.Field_Description, 1, context.temp_allocator)
	other_fields[0] = {name = "value", offset = 0, type = .Integer, unsigned = true}
	records := make([]module_file_writer.Record_Description, 2, context.temp_allocator)
	records[0] = {name = "Wired_Number", size = 16, fields = number_fields}
	records[1] = {name = "Other", size = 8, fields = other_fields}
	writer_outputs := make([]module_file_writer.Record_Output_Part, 4, context.temp_allocator)
	writer_outputs[0] = {name = "anything", record_index = 0}
	writer_outputs[1] = {name = "numbers", record_index = 1}
	writer_outputs[2] = {name = "others", record_index = 2}
	writer_outputs[3] = {name = "paired", record_index = 0, pairing = .Paired}
	writer_inputs := make([]module_file_writer.Record_Input_Part, 2, context.temp_allocator)
	writer_inputs[0] = {name = "loopback", record_index = 1, wirings = .One}
	writer_inputs[1] = {name = "sources", record_index = 0, wirings = .Many}
	reader_inputs := make([]module_file_writer.Record_Input_Part, 4, context.temp_allocator)
	reader_inputs[0] = {name = "any", record_index = 0, wirings = .Many}
	reader_inputs[1] = {name = "many", record_index = 1, wirings = .Many}
	reader_inputs[2] = {name = "numbers", record_index = 1, wirings = .One}
	reader_inputs[3] = {name = "with_terms", record_index = 1, terms_index = 2, wirings = .One}
	files := make(Module_Files, context.temp_allocator)
	files["writer"] = stream_module_file(records, writer_outputs, writer_inputs)
	files["reader"] = stream_module_file(records, nil, reader_inputs)
	files["input"] = files["writer"]
	return files
}

// The module of the machine of the operation sequences has one name in the
// table of the tool and among the procedures of the root service, which
// starts it by its own procedure.
@(test)
the_module_of_the_operation_sequences_has_one_name :: proc(t: ^testing.T) {
	testing.expect_value(t, foundation.OPERATION_FUZZING_MODULE, start_list.OPERATION_FUZZING_NAME)
	testing.expect_value(t, start_list.root_procedure_of(foundation.OPERATION_FUZZING_MODULE), start_list.Root_Procedure.Operation_Fuzzing)
}

// The check of the wiring rows of a list against the module files. Each
// fault comes first, alone in its list, with its one problem and no record
// for it:
//
// - a record output that the writer does not declare, an output that no
//   module has;
// - a record input that the reader does not declare;
// - a writer that is no row of the list, and a module with no file;
// - a writer that the root service starts in its own way;
// - a generic record output; two records that differ; an input that takes
//   terms; a second row to an input of one wiring;
// - from the border: a row that loops, and a pair in the wrong order;
// - rows past the reserve of pages of the start policy.
//
// Then the list of two rows, numbers and the log, passes, with the
// records that the start policy reads; and the default start list passes
// against module files that declare its pair.
@(test)
a_wiring_row_that_the_module_files_refuse_is_refused :: proc(t: ^testing.T) {
	files := wired_files()
	rows := []Start_List_Row{{name = "input", absent_rule = .Not_Started}, {name = "reader", absent_rule = .Not_Started}, {name = "writer", absent_rule = .Not_Started}}
	modules := []string{"input", "reader", "writer"}
	cases := []struct {
		wirings: []Start_List_Wiring,
		problem: string,
	} {
		{{{writer = "writer", record_output = "absent", reader = "reader", record_input = "numbers"}}, "names a record output that the module writer does not declare"},
		{{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "absent"}}, "names a record input that the module reader does not declare"},
		{{{writer = "missing", record_output = "numbers", reader = "reader", record_input = "numbers"}}, "names a module that is no row of the list"},
		{{{writer = "input", record_output = "numbers", reader = "reader", record_input = "numbers"}}, "has a writer that the root service starts in its own way"},
		{{{writer = "writer", record_output = "anything", reader = "reader", record_input = "numbers"}}, "names a generic record output"},
		{{{writer = "writer", record_output = "paired", reader = "reader", record_input = "numbers"}}, "names a record output Paired"},
		{{{writer = "writer", record_output = WIRING_OUTPUT_LOG, reader = "reader", record_input = "any", pace = .Never_Holds_Writer}}, "wires the log with the pace Never_Holds_Writer"},
		{{{writer = "writer", record_output = "others", reader = "reader", record_input = "numbers"}}, "joins two records that differ"},
		{{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "with_terms"}}, "gives terms to a record input that takes none, or none to one that takes them"},
		{{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers", audit_bound = 16}}, "gives terms to a record input that takes none, or none to one that takes them"},
		{{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "with_terms", audit_bound = -1}}, "has an audit bound of -1"},
		{{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "with_terms", audit_bound = wide_grants.SPACE_AUDIT_BOUND_MOST + 1}}, "has an audit bound of"},
		{{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers"}, {writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers"}}, "is a second row to a record input that takes one wiring"},
		{{{writer = "writer", record_output = "numbers", reader = "writer", record_input = "loopback"}}, start_list.LIST_PROBLEM_TEXTS[.Wiring_Loops]},
	}
	for case_of, number in cases {
		records, sizes, wiring_problems := start_list_wiring_records(rows, case_of.wirings, files)
		problems := start_list_problems(rows, modules, false, case_of.wirings, files)
		testing.expectf(t, len(problems) == 1, "case %d: the problems %v", number, problems)
		if len(problems) == 1 {
			testing.expectf(t, strings.contains(problems[0], case_of.problem), "case %d: the problem %q does not say %q", number, problems[0], case_of.problem)
		}
		// A row with a fault gives no record; the border faults come
		// after the records.
		if len(wiring_problems) > 0 {
			testing.expectf(t, len(records) == len(case_of.wirings) - len(wiring_problems) && len(sizes) == len(records), "case %d: a refused row gave a record", number)
		}
	}
	// A module with no file names no record stream.
	no_file := make(Module_Files, context.temp_allocator)
	no_file["writer"] = files["writer"]
	no_file_problems := start_list_problems(rows, modules, false, []Start_List_Wiring{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers"}}, no_file)
	testing.expectf(t, len(no_file_problems) == 1 && strings.contains(no_file_problems[0], "names a module with no module file"), "the problems %v", no_file_problems)

	// A pair in the wrong order: a writer whose reader starts after it.
	ordered := []Start_List_Row{{name = "writer", absent_rule = .Not_Started}, {name = "reader", absent_rule = .Not_Started}}
	wrong_order := start_list_problems(ordered, modules, false, []Start_List_Wiring{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers"}}, files)
	testing.expectf(t, len(wrong_order) == 1 && strings.contains(wrong_order[0], start_list.LIST_PROBLEM_TEXTS[.Writer_Before_Reader]), "the problems %v", wrong_order)

	// A writer row with a restart: a restart would apply its rows again.
	restarting := []Start_List_Row{{name = "input", absent_rule = .Not_Started}, {name = "reader", absent_rule = .Not_Started}, {name = "writer", absent_rule = .Not_Started, restart_count = 1}}
	restart_problems := start_list_problems(restarting, modules, false, []Start_List_Wiring{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers"}}, files)
	testing.expectf(t, len(restart_problems) == 1 && strings.contains(restart_problems[0], start_list.LIST_PROBLEM_TEXTS[.Writer_Restarts]), "the problems %v", restart_problems)

	// A restart window on a row with no restart bounds nothing; with its
	// restarts, the window is written and read back.
	windowed := []Start_List_Row{{name = "input", absent_rule = .Not_Started, restart_window_seconds = 60}}
	window_problems := start_list_problems(windowed, modules, false, nil, files)
	testing.expectf(t, len(window_problems) == 1 && strings.contains(window_problems[0], start_list.LIST_PROBLEM_TEXTS[.Window_Without_Restarts]), "the problems %v", window_problems)
	windowed[0].restart_count = 5
	testing.expect_value(t, len(start_list_problems(windowed, modules, false, nil, files)), 0)
	_, windowed_list, windowed_problem := start_list_bytes(windowed)
	testing.expect_value(t, windowed_problem, "")
	testing.expect_value(t, windowed_list.rows[0].restart_window_seconds, u32(60))

	// Eight rows of the largest rings, which the reserve of the start
	// policy does not pay.
	large := make([]Start_List_Wiring, start_list.WIRING_ROW_CAPACITY, context.temp_allocator)
	for &wiring in large {
		wiring = {writer = "writer", record_output = "numbers", reader = "reader", record_input = "many", capacity = output.WIRING_CAPACITY_MOST}
	}
	past_reserve := start_list_problems(rows, modules, false, large, files)
	testing.expectf(t, len(past_reserve) == 1 && strings.contains(past_reserve[0], "past its reserve"), "the problems %v", past_reserve)
	nine := make([]Start_List_Wiring, start_list.WIRING_ROW_CAPACITY + 1, context.temp_allocator)
	for &wiring in nine {
		wiring = {writer = "writer", record_output = "numbers", reader = "reader", record_input = "many"}
	}
	testing.expect_value(t, len(start_list_problems(rows, modules, false, nine, files)), 1)

	// The success: numbers, and the log into a generic record input.
	wirings := []Start_List_Wiring{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "numbers"}, {writer = "writer", record_output = WIRING_OUTPUT_LOG, reader = "reader", record_input = "any", pace = .Always_Holds_Writer}}
	testing.expect_value(t, len(start_list_problems(rows, modules, false, wirings, files)), 0)
	records, sizes, problems := start_list_wiring_records(rows, wirings, files)
	testing.expect_value(t, len(problems), 0)
	testing.expect_value(t, len(records), 2)
	if len(records) == 2 {
		testing.expect_value(t, records[0].writer_row, 3)
		testing.expect_value(t, records[0].wiring.reader_handle, 2)
		testing.expect_value(t, records[0].wiring.writer_index, 2)
		testing.expect_value(t, records[0].wiring.reader_index, 3)
		testing.expect_value(t, records[0].wiring.writer_stream, u32(output.Writer_Stream.Record_Output))
		testing.expect_value(t, records[1].wiring.writer_stream, u32(output.Writer_Stream.Log))
		testing.expect_value(t, records[1].wiring.writer_index, 0)
		testing.expect_value(t, records[1].wiring.reader_index, 1)
		testing.expect_value(t, records[1].wiring.pace, u32(output.Wiring_Pace.Always_Holds_Writer))
		testing.expect_value(t, sizes[0], 16)
		testing.expect_value(t, sizes[1], size_of(output.Log_Output_Record))
	}

	// The audit of what leaves a server: terms of an audit space, its
	// bound, no forward, the size of the record of the writer, which the
	// border of the list reads back whole.
	audited := []Start_List_Wiring{{writer = "writer", record_output = "numbers", reader = "reader", record_input = "with_terms", audit_bound = 100}}
	testing.expect_value(t, len(start_list_problems(rows, modules, false, audited, files)), 0)
	audited_records, _, audited_problems := start_list_wiring_records(rows, audited, files)
	testing.expect_value(t, len(audited_problems), 0)
	if len(audited_records) == 1 {
		testing.expect_value(t, audited_records[0].wiring.terms_count, u32(start_list.START_LIST_TERMS_BYTES))
		testing.expect_value(t, audited_records[0].wiring.terms_offset, u32(0))
		terms := transmute(wide_grants.Space_Terms)audited_records[0].terms
		testing.expect_value(t, terms, wide_grants.Space_Terms{kind_word = i64(wide_grants.Collector_Space_Kind.Audit), bound_records = 100, forwarding_word = i64(wide_grants.Space_Forwarding.Keeps), record_size = 16})
		_, audited_list, audited_list_problem := start_list_bytes(rows, audited_records)
		testing.expect_value(t, audited_list_problem, "")
		testing.expect_value(t, audited_list.wirings[0].terms, audited_records[0].terms)
	}

	// The default start list, with module files that declare its pair as
	// the two modules of the pair declare it.
	pair := make(Module_Files, context.temp_allocator)
	pair["wired_writer"] = files["writer"]
	pair["wired_reader"] = files["reader"]
	default_problems := start_list_problems(DEFAULT_START_LIST[:], image_modules_with_an_entry(BOOT_IMAGE, ""), false, DEFAULT_START_WIRINGS[:], pair)
	testing.expectf(t, len(default_problems) == 0, "the default start list is refused: %v", default_problems)
}

// The check of a start list against the modules of an image. Each list
// that it must refuse comes first: a row of no module, a row of a module
// that the image leaves out, a row whose name the border refuses, a list
// past the capacity, and a rescue list with no row that makes the machine
// usable. Each list of each image of the build passes last, and the list
// of the test of the rescue is refused for its one row.
@(test)
a_start_list_that_is_not_valid_is_refused :: proc(t: ^testing.T) {
	modules := []string{"input", "compositor", "console", "date"}
	no_module := []Start_List_Row{{name = "console", usable_mark = .Needed, absent_rule = .Not_Started}, {name = "console_missing", absent_rule = .Not_Started}}
	problems := start_list_problems(no_module, modules, false)
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(t, strings.contains(problems[0], "console_missing"))
	}
	left_out := image_modules_with_an_entry(BOOT_IMAGE_SHORTAGE, "input")
	refused_input := start_list_problems(DEFAULT_START_LIST[:], left_out, false)
	testing.expect(t, len(refused_input) >= 1, "a list that names input is taken for an image with no input")
	bad_name := []Start_List_Row{{name = "Console", usable_mark = .Needed, absent_rule = .Not_Started}}
	testing.expect(t, len(start_list_problems(bad_name, modules, false)) >= 1)
	long := make([]Start_List_Row, 33, context.temp_allocator)
	for &row in long {
		row = {name = "date", absent_rule = .Not_Started}
	}
	testing.expect(t, len(start_list_problems(long, modules, false)) >= 1)
	not_usable := []Start_List_Row{{name = "console", absent_rule = .Not_Started}}
	not_usable_problems := start_list_problems(not_usable, modules, true)
	testing.expect_value(t, len(not_usable_problems), 1)
	// The same list is a start list that the check takes: the mark Needed
	// is a rule of a rescue list.
	testing.expect_value(t, len(start_list_problems(not_usable, modules, false)), 0)
	// The lists of the build against the modules of their images.
	images := [?][2]string{{BOOT_IMAGE, ""}, {BOOT_IMAGE_FAILS, foundation.START_POLICY_MODULE}, {BOOT_IMAGE_SHORTAGE, "input"}, {foundation.BOOT_IMAGE_OPERATION_SEQUENCES, ""}, {BOOT_IMAGE_MEASURE, ""}}
	for image in images {
		lists := start_lists_of_image(image[0])
		image_modules := image_modules_with_an_entry(image[0], image[1])
		testing.expectf(t, len(start_list_problems(lists.start, image_modules, false)) == 0, "the start list of %s is refused: %v", image[0], start_list_problems(lists.start, image_modules, false))
		testing.expectf(t, len(start_list_problems(lists.rescue, image_modules, true)) == 0, "the rescue list of %s is refused: %v", image[0], start_list_problems(lists.rescue, image_modules, true))
	}
	missing := start_lists_of_image(BOOT_IMAGE_MISSING_CONSOLE)
	testing.expect(t, missing.start_refused_on_purpose)
	missing_problems := start_list_problems(missing.start, image_modules_with_an_entry(BOOT_IMAGE_MISSING_CONSOLE, ""), false)
	testing.expect(t, refused_for_the_rows(missing_problems, REFUSED_ON_PURPOSE_ROWS[:]), "the list of the test of the rescue is not refused for its two rows alone")
	// Its rescue list, with the two rows of the test of the restarts, passes
	// against its image, and the main image holds neither row.
	missing_rescue_problems := start_list_problems(missing.rescue, image_modules_with_an_entry(BOOT_IMAGE_MISSING_CONSOLE, ""), true)
	testing.expectf(t, len(missing_rescue_problems) == 0, "the rescue list of the test of the rescue is refused: %v", missing_rescue_problems)
	testing.expect_value(t, len(start_list_problems(missing.rescue, image_modules_with_an_entry(BOOT_IMAGE, ""), true)), 2)
	// shortage is in the image of its test only.
	testing.expect(t, len(start_list_problems(SHORTAGE_START_LIST[:], image_modules_with_an_entry(BOOT_IMAGE, ""), false)) == 1, "the main image holds shortage")
	// The check of a list refused on purpose refuses one problem too few,
	// one too many, and another row.
	testing.expect(t, !refused_for_the_rows(missing_problems[:1], REFUSED_ON_PURPOSE_ROWS[:]))
	more := make([dynamic]string, context.temp_allocator)
	append(&more, ..missing_problems)
	append(&more, "the row date names no module with an entry in the image")
	testing.expect(t, !refused_for_the_rows(more[:], REFUSED_ON_PURPOSE_ROWS[:]))
	testing.expect(t, !refused_for_the_rows(missing_problems, []string{ABSENT_TEST_MODULE, "date"}))
}

// The check of the source of the start policy: one line past the bound, an
// import of the core library, an import of another contract, an import
// with no path. A test file is not counted, and its import is not read.
// A source of the bound with the allowed imports passes last, and so does
// the source of the repository.
@(test)
a_start_policy_past_its_bound_is_refused :: proc(t: ^testing.T) {
	lines_of :: proc(count: int) -> string {
		builder := strings.builder_make(context.temp_allocator)
		strings.write_string(&builder, "package start_policy\n")
		for _ in 1 ..< count {
			strings.write_string(&builder, "// a line\n")
		}
		return strings.to_string(builder)
	}
	past := [][2]string{{"main.odin", lines_of(START_POLICY_SOURCE_LINE_LIMIT + 1)}}
	testing.expect_value(t, len(start_policy_source_problems(past)), 1)
	split := [][2]string{{"main.odin", lines_of(START_POLICY_SOURCE_LINE_LIMIT)}, {"rows.odin", "package start_policy\n"}}
	testing.expect_value(t, len(start_policy_source_problems(split)), 1)
	imports := [?]string{"import \"core:fmt\"\n", "import \"modus:contract/errors\"\n", "import \"modus:storage\"\n", "import\n", "foreign import code \"code.asm\"\n", "\tforeign code {\n", "foreign {\n"}
	for line in imports {
		source := [][2]string{{"main.odin", strings.concatenate({"package start_policy\n", line}, context.temp_allocator)}}
		testing.expectf(t, len(start_policy_source_problems(source)) == 1, "the import %q is taken", line)
	}
	with_a_test := [][2]string{{"main.odin", lines_of(START_POLICY_SOURCE_LINE_LIMIT)}, {"rows_test.odin", strings.concatenate({lines_of(START_POLICY_SOURCE_LINE_LIMIT), "import \"core:testing\"\n"}, context.temp_allocator)}}
	testing.expect_value(t, len(start_policy_source_problems(with_a_test)), 0)
	allowed := [][2]string{{"main.odin", "package start_policy\n\nimport \"base:intrinsics\"\nimport op \"modus:contract/operation\"\nimport \"modus:contract/ring\"\nimport \"modus:contract/root_ring\"\nimport \"modus:contract/start_list\"\nimport \"modus:contract/value_kinds\"\nimport \"modus:system\"\n"}}
	testing.expect_value(t, len(start_policy_source_problems(allowed)), 0)
	testing.expect(t, start_policy_source_check(), "the source of the start policy of the repository is refused")
}

// The imports of wiring_rows: the support package system, which calls the
// kernel, another support package, a private part, a package of core:, a
// foreign import, and an import with no path are each refused. A test file
// is not read. base: and the contracts pass last, and so does the source
// of the repository.
@(test)
wiring_rows_that_call_the_kernel_are_refused :: proc(t: ^testing.T) {
	refused := [?]string{"import \"modus:system\"\n", "import \"modus:storage\"\n", "import \"internal:root/start_policy_rules\"\n", "import \"core:fmt\"\n", "foreign import code \"code.asm\"\n", "import\n"}
	for line in refused {
		source := [][2]string{{"wiring_rows.odin", strings.concatenate({"package wiring_rows\n", line}, context.temp_allocator)}}
		testing.expectf(t, len(wiring_rows_source_problems(source)) == 1, "the import %q is taken", line)
	}
	with_a_test := [][2]string{{"wiring_rows_test.odin", "package wiring_rows\nimport \"core:testing\"\nimport \"modus:system\"\n"}}
	testing.expect_value(t, len(wiring_rows_source_problems(with_a_test)), 0)
	allowed := [][2]string{{"wiring_rows.odin", "package wiring_rows\n\nimport \"base:intrinsics\"\nimport op \"modus:contract/operation\"\nimport \"modus:contract/output\"\nimport \"modus:contract/start_list\"\n"}}
	testing.expect_value(t, len(wiring_rows_source_problems(allowed)), 0)
	paths, listed := foundation.files_with_suffix(WIRING_ROWS_FOLDER, ".odin")
	testing.expect(t, listed && len(paths) > 0, "the folder of wiring_rows has no source")
	sources := make([dynamic][2]string, context.temp_allocator)
	for path in paths {
		text, read := foundation.read_text_file(path)
		testing.expect(t, read)
		append(&sources, [2]string{path, text})
	}
	testing.expectf(t, len(wiring_rows_source_problems(sources[:])) == 0, "the source of wiring_rows is refused: %v", wiring_rows_source_problems(sources[:]))
}
// The row of the input service in the default list and in the rescue list:
// its restarts have a window, and the bytes of the list keep both. The
// window bounds a loop of stops: the restart past the count is refused
// until the oldest restart is one window old, the last millisecond before
// it included, and allowed at that millisecond. A stop that the row reaches
// later starts it again: the count bounds a loop, not the life of the
// machine.
@(test)
the_input_service_restarts_within_a_window :: proc(t: ^testing.T) {
	for rows in ([?][]Start_List_Row{DEFAULT_START_LIST[:], DEFAULT_RESCUE_LIST[:]}) {
		testing.expect_value(t, rows[0].name, "input")
		testing.expect_value(t, rows[0].restart_count, u32(INPUT_RESTARTS))
		testing.expect_value(t, rows[0].restart_window_seconds, u32(INPUT_RESTART_WINDOW_SECONDS))
		_, list, problem := start_list_bytes(rows)
		testing.expect_value(t, problem, "")
		testing.expect_value(t, list.rows[0].restart_count, u32(INPUT_RESTARTS))
		testing.expect_value(t, list.rows[0].restart_window_seconds, u32(INPUT_RESTART_WINDOW_SECONDS))
	}
	WINDOW :: u64(INPUT_RESTART_WINDOW_SECONDS) * 1000
	FIRST :: u64(5_000)
	window: start_list.Restart_Window
	for index in u64(0) ..< INPUT_RESTARTS {
		allowed, left := start_list.restart_window_take(&window, INPUT_RESTARTS, INPUT_RESTART_WINDOW_SECONDS, FIRST + index)
		testing.expect(t, allowed)
		testing.expect_value(t, left, u32(INPUT_RESTARTS) - u32(index) - 1)
	}
	// A loop: the next stop at once, then one millisecond before the
	// oldest restart is one window old.
	allowed, _ := start_list.restart_window_take(&window, INPUT_RESTARTS, INPUT_RESTART_WINDOW_SECONDS, FIRST + INPUT_RESTARTS)
	testing.expect(t, !allowed)
	allowed, _ = start_list.restart_window_take(&window, INPUT_RESTARTS, INPUT_RESTART_WINDOW_SECONDS, FIRST + WINDOW - 1)
	testing.expect(t, !allowed)
	// The oldest restart is one window old: one restart more.
	allowed, _ = start_list.restart_window_take(&window, INPUT_RESTARTS, INPUT_RESTART_WINDOW_SECONDS, FIRST + WINDOW)
	testing.expect(t, allowed)
	// The second oldest is one window old one millisecond later, not before.
	allowed, _ = start_list.restart_window_take(&window, INPUT_RESTARTS, INPUT_RESTART_WINDOW_SECONDS, FIRST + WINDOW)
	testing.expect(t, !allowed)
	allowed, _ = start_list.restart_window_take(&window, INPUT_RESTARTS, INPUT_RESTART_WINDOW_SECONDS, FIRST + WINDOW + 1)
	testing.expect(t, allowed)
}
