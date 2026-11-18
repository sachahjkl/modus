package machine

import module "modus:contract/module"
import "core:strings"
import "core:testing"
import "modustool:build"

// The constant of a source gives the stated budget: each part from its
// integer literal, a part left out 0.
@(test)
budget_request_read_takes_the_constant :: proc(t: ^testing.T) {
	source :: "package p\n\nimport \"modus:support/system\"\n\n// Its loop, and one more thread.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4_096, threads = 2}\n"
	state: build.Describe_State
	file, parsed := build.parse_source("budget.odin", source, &state)
	if !testing.expect(t, parsed) {
		return
	}
	budget: build.Budget_Description
	testing.expect(t, build.budget_request_read(file, &budget))
	testing.expect(t, budget.stated)
	testing.expect_value(t, budget.parts, build.Stated_Budget{working_memory_pages = 4096, processes = 0, threads = 2})
	testing.expect_value(t, budget.comment, "Its loop, and one more thread.")
	testing.expect_value(t, budget.line, 6)

	// A source with no constant states no request: the module asks for the
	// least budget, and the conversion writes no table.
	other_state: build.Describe_State
	other, other_parsed := build.parse_source("none.odin", "package p\n\nWIDTH :: 720\n", &other_state)
	if !testing.expect(t, other_parsed) {
		return
	}
	none: build.Budget_Description
	testing.expect(t, build.budget_request_read(other, &none))
	testing.expect(t, !none.stated)
}

// The type can be on the declaration, and a part can be written in
// hexadecimal, octal or binary: the compiler takes both forms, so the tool
// takes them too.
@(test)
budget_request_read_takes_the_typed_form_and_prefixes :: proc(t: ^testing.T) {
	cases := [?]struct {
		about, source: string,
		parts:         build.Stated_Budget,
	} {
		{"the type on the declaration", "package p\n// Why.\nMODULE_BUDGET : system.Stated_Budget : {working_memory_pages = 4096, threads = 2}\n", {working_memory_pages = 4096, threads = 2}},
		{"the type on both", "package p\n// Why.\nMODULE_BUDGET : system.Stated_Budget : system.Stated_Budget{working_memory_pages = 4096}\n", {working_memory_pages = 4096}},
		{"a hexadecimal part", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 0x1000, processes = 0b11, threads = 0o10}\n", {working_memory_pages = 4096, processes = 3, threads = 8}},
		{"a hexadecimal part with separators", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 0xA4_00}\n", {working_memory_pages = 41984}},
		{"a window of literals", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = 640, window_height = 480}\n", {window_width = 640, window_height = 480}},
	}
	for item in cases {
		state: build.Describe_State
		file, parsed := build.parse_source("case.odin", item.source, &state)
		if !testing.expectf(t, parsed, "%s: the parser takes it", item.about) {
			continue
		}
		budget: build.Budget_Description
		testing.expectf(t, build.budget_request_read(file, &budget), "%s", item.about)
		testing.expectf(t, budget.stated && budget.parts == item.parts, "%s: %v", item.about, budget.parts)
	}
}

// A window part that names a constant takes the value of the constant,
// from any file of the package: the process passes the same constant to
// display.open, so the counted pictures are the pictures that it opens.
@(test)
budget_window_resolve_takes_the_constants_of_the_package :: proc(t: ^testing.T) {
	budget_source :: "package p\n// Its tables.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 100, window_width = WIDTH, window_height = HEIGHT}\n"
	layout_source :: "package p\nWIDTH :: 1000 // The window and its borders fit the screen.\nHEIGHT : int : 0x2C0\nMARGIN :: 2 * 6\n"
	state: build.Describe_State
	budget_file, budget_parsed := build.parse_source("main.odin", budget_source, &state)
	layout_file, layout_parsed := build.parse_source("layout.odin", layout_source, &state)
	if !testing.expect(t, budget_parsed && layout_parsed) {
		return
	}
	budget: build.Budget_Description
	constants := make(map[string]u64, context.temp_allocator)
	testing.expect(t, build.budget_request_read(budget_file, &budget))
	build.integer_constants_read(budget_file, &constants)
	build.integer_constants_read(layout_file, &constants)
	testing.expect_value(t, budget.window_names, [2]string{"WIDTH", "HEIGHT"})
	testing.expect(t, build.budget_window_resolve(&budget, constants))
	testing.expect_value(t, budget.parts, build.Stated_Budget{working_memory_pages = 100, window_width = 1000, window_height = 704})
	_, has_expression := constants["MARGIN"]
	testing.expect(t, !has_expression, "a constant of an expression is not read: the tool evaluates none")

	// A name of an expression, a name that the package does not have, and a
	// size above the limit of a surface stop the build.
	refused := [?]struct {
		about, source: string,
	} {
		{"a name of an expression", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = MARGIN, window_height = HEIGHT}\n"},
		{"a name that the package does not have", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = DEPTH, window_height = HEIGHT}\n"},
		{"a width above the limit", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = 4096, window_height = HEIGHT}\n"},
	}
	for item in refused {
		item_state: build.Describe_State
		file, parsed := build.parse_source("case.odin", item.source, &item_state)
		if !testing.expectf(t, parsed, "%s: the parser takes it", item.about) {
			continue
		}
		item_budget: build.Budget_Description
		testing.expectf(t, build.budget_request_read(file, &item_budget), "%s: the constant is read", item.about)
		testing.expectf(t, !build.budget_window_resolve(&item_budget, constants), "%s", item.about)
	}
}

// The sum on one module: the stated working memory, the pages of the
// module and of its two imports, the first thread and two more, and the
// two pictures of a window of 1000 x 704.
@(test)
budget_count_adds_the_counted_parts :: proc(t: ^testing.T) {
	stated := build.Stated_Budget{working_memory_pages = 2536, processes = 2, threads = 3, window_width = 1000, window_height = 704}
	// 98 pages and a part of one more; two imports of 19 and of 72 pages.
	module_size := u64(98 * 4096 + 1)
	imports := []u64{19 * 4096, 72 * 4096}
	counted, ok := build.budget_count(stated, module_size, imports)
	testing.expect(t, ok)
	testing.expect_value(t, counted.working_memory_pages, 2536)
	testing.expect_value(t, counted.module_pages, 99 + 19 + 72)
	// The first thread: 64 pages of stack, the context, 3 pages of thread
	// area, 4 pages of the own log ring; each other one: 16 pages of stack
	// and 3 of thread area.
	testing.expect_value(t, counted.thread_pages, 72 + 2 * 19)
	// 1000 x 704 pixels of 4 bytes, two pictures: 5632000 bytes, 1375 pages.
	testing.expect_value(t, counted.window_pages, 1375)
	testing.expect_value(t, counted.request, module.Budget_Request{pages = 2536 + 190 + 110 + 1375, processes = 2, threads = 3})

	// No part of threads: the tool counts the first thread, and the table
	// leaves the part to the starter. No window: no pictures.
	alone, alone_ok := build.budget_count({working_memory_pages = 10}, 4096, nil)
	testing.expect(t, alone_ok)
	testing.expect_value(t, alone.request, module.Budget_Request{pages = 10 + 1 + 72})
	testing.expect_value(t, alone.window_pages, 0)

	// A count of threads that passes the end of 64 bits is refused.
	_, huge_ok := build.budget_count({threads = ~u64(0)}, 0, nil)
	testing.expect(t, !huge_ok)
}

// The measure of a build has one line with the request of each module.
@(test)
build_measure_lines_name_each_budget_request_once :: proc(t: ^testing.T) {
	requests := make([dynamic]build.Build_Budget_Request, context.temp_allocator)
	append(&requests, build.Build_Budget_Request{name = "block", request = {pages = 256, processes = 1, threads = 1}}, build.Build_Budget_Request{name = "console", request = {pages = 8192, processes = 5, threads = 6}})
	lines := build.build_measure_lines(build.Build_Measure{budget_requests = requests}, 0)
	last := lines[len(lines) - 1]
	testing.expect(t, strings.contains(last, "block 256 pages, 1 processes, 1 threads; console 8192 pages, 5 processes, 6 threads"), last)
	testing.expect_value(t, strings.count(last, "console"), 1)
}

// Each form that is not one constant of integer literals, with a comment,
// stops the build: the tool does not guess a request.
@(test)
budget_request_read_refuses_another_form :: proc(t: ^testing.T) {
	cases := [?]struct {
		about, source: string,
	} {
		{"no comment", "package p\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4096}\n"},
		{"a variable", "package p\n// Why.\nMODULE_BUDGET := system.Stated_Budget{working_memory_pages = 4096}\n"},
		{"an expression", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 2048 + 1024}\n"},
		{"a named constant as a part that is not a window part", "package p\nPAGES :: 4096\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = PAGES}\n"},
		{"an expression as a window part", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = 2 * 500, window_height = 704}\n"},
		{"one window part", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = 1000}\n"},
		{"one window part by its name", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_height = HEIGHT}\n"},
		{"a part of 0", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 0}\n"},
		{"a part that the record does not have", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{processor = 1000}\n"},
		{"the whole pages, which the tool counts", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{pages = 4096}\n"},
		{"a part two times", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{threads = 1, threads = 2}\n"},
		{"a window part two times", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{window_width = WIDTH, window_width = 4, window_height = 4}\n"},
		{"a part with no name", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{4096, 1, 1}\n"},
		{"the record of the table", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 4096}\n"},
		{"another type on the declaration", "package p\n// Why.\nMODULE_BUDGET : system.Budget_Amounts : {pages = 4096}\n"},
		{"not a record", "package p\n// Why.\nMODULE_BUDGET :: 4096\n"},
		{"a literal with no type", "package p\n// Why.\nMODULE_BUDGET :: {working_memory_pages = 4096}\n"},
		{"a part that is not an integer", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4096.5}\n"},
		{"a part that does not fit in 64 bits", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 0x1_0000_0000_0000_0000}\n"},
		{"two constants", "package p\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{threads = 1}\n// Why.\nMODULE_BUDGET :: system.Stated_Budget{threads = 2}\n"},
		// A declaration that the tool would not read is an error, never a
		// module that asks for the least budget in silence.
		{"inside a when", "package p\nwhen ODIN_DEBUG {\n\t// Why.\n\tMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4096}\n}\n"},
		{"inside the else of a when", "package p\nwhen ODIN_DEBUG {\n\tWIDTH :: 1\n} else {\n\t// Why.\n\tMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4096}\n}\n"},
		{"inside a when in a when", "package p\nwhen ODIN_DEBUG {\n\twhen ODIN_OS == .Linux {\n\t\t// Why.\n\t\tMODULE_BUDGET :: system.Stated_Budget{working_memory_pages = 4096}\n\t}\n}\n"},
		{"with other names", "package p\n// Why.\nMODULE_NAME, MODULE_BUDGET :: \"x\", system.Stated_Budget{working_memory_pages = 4096}\n"},
		{"after another name", "package p\n// Why.\nMODULE_BUDGET, MODULE_NAME :: system.Stated_Budget{working_memory_pages = 4096}, \"x\"\n"},
	}
	for item in cases {
		state: build.Describe_State
		file, parsed := build.parse_source("case.odin", item.source, &state)
		// Each case is a source that the parser takes: the refusal is the
		// refusal of the tool.
		if !testing.expectf(t, parsed, "%s: the parser takes it", item.about) {
			continue
		}
		budget: build.Budget_Description
		testing.expectf(t, !build.budget_request_read(file, &budget), "%s", item.about)
		testing.expectf(t, !budget.stated || item.about == "two constants", "%s: no request is kept", item.about)
	}
}

// A module file with a table Budget of one record of record_size bytes, or
// with no table when record_size is 0 and count is 0.
@(private = "file")
file_with_budget :: proc(storage: ^[512]u8, count: u32, record_size: u32, request: module.Budget_Request) -> []u8 {
	Directory :: [module.TABLE_COUNT]module.Table_Entry
	directory: Directory
	offset := u64(size_of(module.Header) + size_of(Directory))
	records := [2]module.Budget_Request{1 = request}
	bytes := ([^]u8)(rawptr(&records))[:size_of(records)]
	// Record n of the table starts at n * record_size: a shorter record holds
	// the first bytes of each part, a longer one has zero bytes after them.
	for index in 0 ..< int(count) {
		size := min(int(record_size), size_of(module.Budget_Request))
		copy(storage[int(offset) + index * int(record_size):][:size], bytes[index * size_of(module.Budget_Request):][:size])
	}
	if count != 0 {
		directory[module.Table_Kind.Budget] = {offset = offset, count = count, record_size = record_size}
	}
	end := offset + u64(count) * u64(record_size)
	(^module.Header)(&storage[0])^ = {magic = module.MAGIC, version = module.VERSION, header_size = size_of(module.Header), machine = .X86_64, table_count = module.TABLE_COUNT}
	(^Directory)(&storage[size_of(module.Header)])^ = directory
	return storage[:end]
}

// The reader of the table: the record of the file, the least for a file
// with no table, and the rule of the growth of a record.
@(test)
budget_request_reads_the_table :: proc(t: ^testing.T) {
	asked := module.Budget_Request{pages = 4096, processes = 3, threads = 7}

	storage: [512]u8
	file := file_with_budget(&storage, 2, size_of(module.Budget_Request), asked)
	testing.expect_value(t, module.validate(file), module.Error.None)
	request, stated := module.budget_request(file)
	testing.expect(t, stated)
	testing.expect_value(t, request, asked)

	// No table: the module asks for the least budget.
	empty_storage: [512]u8
	empty := file_with_budget(&empty_storage, 0, 0, {})
	testing.expect_value(t, module.validate(empty), module.Error.None)
	request, stated = module.budget_request(empty)
	testing.expect(t, !stated)
	testing.expect_value(t, request, module.Budget_Request{})

	// A table with only the empty record 0 states no request.
	only_storage: [512]u8
	only_empty := file_with_budget(&only_storage, 1, size_of(module.Budget_Request), {})
	_, stated = module.budget_request(only_empty)
	testing.expect(t, !stated)

	// A record of an older size, 8 bytes: the pages only; the parts that
	// the record does not have are 0, the least.
	short_storage: [512]u8
	short := file_with_budget(&short_storage, 2, 8, asked)
	testing.expect_value(t, module.validate(short), module.Error.None)
	request, stated = module.budget_request(short)
	testing.expect(t, stated)
	testing.expect_value(t, request, module.Budget_Request{pages = 4096})

	// A record of a newer size, 32 bytes: the reader takes its first parts.
	long_storage: [512]u8
	long := file_with_budget(&long_storage, 2, 32, asked)
	testing.expect_value(t, module.validate(long), module.Error.None)
	request, stated = module.budget_request(long)
	testing.expect(t, stated)
	testing.expect_value(t, request, asked)

	// A table that passes the end of the file: validate refuses the file
	// before a reader takes a request from it.
	cut_storage: [512]u8
	cut := file_with_budget(&cut_storage, 2, size_of(module.Budget_Request), asked)
	testing.expect_value(t, module.validate(cut[:len(cut) - 1]), module.Error.Bad_Table)
	request, stated = module.budget_request(cut[:len(cut) - 1])
	testing.expect(t, !stated, "a record that is not inside the file is no request")
}
