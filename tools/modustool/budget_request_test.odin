package modustool

import module "modus:contract/module"
import "core:testing"

// The constant of a source gives the request that the conversion writes:
// each part from its integer literal, a part left out 0.
@(test)
budget_request_read_takes_the_constant :: proc(t: ^testing.T) {
	source :: "package p\n\nimport \"modus:support/system\"\n\n// Its loop, and one more thread.\nMODULE_BUDGET :: system.Budget_Request{pages = 4_096, threads = 2}\n"
	state: Describe_State
	file, parsed := parse_source("budget.odin", source, &state)
	if !testing.expect(t, parsed) {
		return
	}
	budget: Budget_Description
	testing.expect(t, budget_request_read(file, &budget))
	testing.expect(t, budget.stated)
	testing.expect_value(t, budget.request, module.Budget_Request{pages = 4096, programs = 0, threads = 2})
	testing.expect_value(t, budget.comment, "Its loop, and one more thread.")
	testing.expect_value(t, budget.line, 6)

	// A source with no constant states no request: the module asks for the
	// least budget, and the conversion writes no table.
	other_state: Describe_State
	other, other_parsed := parse_source("none.odin", "package p\n\nWIDTH :: 720\n", &other_state)
	if !testing.expect(t, other_parsed) {
		return
	}
	none: Budget_Description
	testing.expect(t, budget_request_read(other, &none))
	testing.expect(t, !none.stated)
}

// The type can be on the declaration, and a part can be written in
// hexadecimal, octal or binary: the compiler takes both forms, so the tool
// takes them too.
@(test)
budget_request_read_takes_the_typed_form_and_prefixes :: proc(t: ^testing.T) {
	cases := [?]struct {
		about, source: string,
		request:       module.Budget_Request,
	} {
		{"the type on the declaration", "package p\n// Why.\nMODULE_BUDGET : system.Budget_Request : {pages = 4096, threads = 2}\n", {pages = 4096, threads = 2}},
		{"the type on both", "package p\n// Why.\nMODULE_BUDGET : system.Budget_Request : system.Budget_Request{pages = 4096}\n", {pages = 4096}},
		{"a hexadecimal part", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 0x1000, programs = 0b11, threads = 0o10}\n", {pages = 4096, programs = 3, threads = 8}},
		{"a hexadecimal part with separators", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 0xA4_00}\n", {pages = 41984}},
	}
	for item in cases {
		state: Describe_State
		file, parsed := parse_source("case.odin", item.source, &state)
		if !testing.expectf(t, parsed, "%s: the parser takes it", item.about) {
			continue
		}
		budget: Budget_Description
		testing.expectf(t, budget_request_read(file, &budget), "%s", item.about)
		testing.expectf(t, budget.stated && budget.request == item.request, "%s: %v", item.about, budget.request)
	}
}

// Each form that is not one constant of integer literals, with a comment,
// stops the build: the tool does not guess a request.
@(test)
budget_request_read_refuses_another_form :: proc(t: ^testing.T) {
	cases := [?]struct {
		about, source: string,
	} {
		{"no comment", "package p\nMODULE_BUDGET :: system.Budget_Request{pages = 4096}\n"},
		{"a variable", "package p\n// Why.\nMODULE_BUDGET := system.Budget_Request{pages = 4096}\n"},
		{"an expression", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 2048 + 1024}\n"},
		{"a named constant as a part", "package p\nPAGES :: 4096\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = PAGES}\n"},
		{"a part of 0", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 0}\n"},
		{"a part that the record does not have", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{processor = 1000}\n"},
		{"a part two times", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 1, pages = 2}\n"},
		{"a part with no name", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{4096, 1, 1}\n"},
		{"another type", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Amounts{pages = 4096}\n"},
		{"another type on the declaration", "package p\n// Why.\nMODULE_BUDGET : system.Budget_Amounts : {pages = 4096}\n"},
		{"not a record", "package p\n// Why.\nMODULE_BUDGET :: 4096\n"},
		{"a literal with no type", "package p\n// Why.\nMODULE_BUDGET :: {pages = 4096}\n"},
		{"a part that is not an integer", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 4096.5}\n"},
		{"a part that does not fit in 64 bits", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 0x1_0000_0000_0000_0000}\n"},
		{"two constants", "package p\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 1}\n// Why.\nMODULE_BUDGET :: system.Budget_Request{pages = 2}\n"},
		// A declaration that the tool would not read is an error, never a
		// module that asks for the least budget in silence.
		{"inside a when", "package p\nwhen ODIN_DEBUG {\n\t// Why.\n\tMODULE_BUDGET :: system.Budget_Request{pages = 4096}\n}\n"},
		{"inside the else of a when", "package p\nwhen ODIN_DEBUG {\n\tWIDTH :: 1\n} else {\n\t// Why.\n\tMODULE_BUDGET :: system.Budget_Request{pages = 4096}\n}\n"},
		{"inside a when in a when", "package p\nwhen ODIN_DEBUG {\n\twhen ODIN_OS == .Linux {\n\t\t// Why.\n\t\tMODULE_BUDGET :: system.Budget_Request{pages = 4096}\n\t}\n}\n"},
		{"with other names", "package p\n// Why.\nMODULE_NAME, MODULE_BUDGET :: \"x\", system.Budget_Request{pages = 4096}\n"},
		{"after another name", "package p\n// Why.\nMODULE_BUDGET, MODULE_NAME :: system.Budget_Request{pages = 4096}, \"x\"\n"},
	}
	for item in cases {
		state: Describe_State
		file, parsed := parse_source("case.odin", item.source, &state)
		// Each case is a source that the parser takes: the refusal is the
		// refusal of the tool.
		if !testing.expectf(t, parsed, "%s: the parser takes it", item.about) {
			continue
		}
		budget: Budget_Description
		testing.expectf(t, !budget_request_read(file, &budget), "%s", item.about)
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
	asked := module.Budget_Request{pages = 4096, programs = 3, threads = 7}

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
