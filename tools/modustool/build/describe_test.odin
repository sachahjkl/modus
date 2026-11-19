package build

import module "modus:contract/module"
import op "modus:contract/operation"
import "modus:contract/value_kinds"
import "base:runtime"
import "core:odin/tokenizer"
import "core:testing"

// The tokenizer of the Odin library fills its table of keywords at its
// first use. Two threads that use it first at the same time fill the
// table twice, and the second one stops on an assertion ("runtime
// assertion: import"). The test runner gives each test a thread, so the
// table is filled here, before the threads start.
@(init)
keywords_prepare :: proc "contextless" () {
	context = runtime.default_context()
	scanner: tokenizer.Tokenizer
	tokenizer.init(&scanner, "", "")
}

@(private = "file")
DESCRIBED_SOURCE :: `// A sample of a module. The second sentence
// of the first paragraph.
//
// A list:
//   one line that stays
// - a point
// - a second point,
// on two lines
package sample

helper :: proc "c" (x: i64) -> i64 {return x}

// scale gives a number times a factor. The second sentence is not help.
@(export, link_name = "scale")
scale_function :: proc "c" (number, factor: i64) -> i64 {return number * factor}

// title gives a text
// in capital letters.
@(export)
title :: proc "c" (text: ^string, result: ^[]u8) -> i64 {return 0}

// note writes a text to the log.
@(export, link_name = "note")
note :: proc "c" (text: ^string) {}

@(export, link_name = "entry")
entry :: proc "c" (start: rawptr) -> ! {for {}}
`

// The description of each export comes from the source: the name, the names
// and the types of the parameters, the result, and the help.
@(test)
describe_reads_the_source :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	package_text: string
	testing.expect(t, describe_source("sample.odin", DESCRIBED_SOURCE, &list, &package_text))
	// The documentation text: the comment as its author wrote it. The
	// reader of the system joins the lines of a paragraph.
	testing.expect_value(
		t,
		package_text,
		"A sample of a module. The second sentence\nof the first paragraph.\n\nA list:\n  one line that stays\n- a point\n- a second point,\non two lines",
	)
	testing.expect_value(t, about_of(documentation_text_of_markdown(package_text), ""), "A sample of a module")
	testing.expect_value(t, len(list), 4)
	if len(list) != 4 {
		return
	}
	scale := list[0]
	testing.expect_value(t, scale.name, "scale")
	testing.expect_value(t, scale.about, "gives a number times a factor")
	testing.expect_value(t, scale.text, "scale gives a number times a factor. The second sentence is not help.")
	testing.expect_value(t, scale.result, module.Type.Integer)
	testing.expect_value(t, len(scale.parameters), 2)
	testing.expect_value(t, scale.names[0], "number")
	testing.expect_value(t, scale.names[1], "factor")
	testing.expect_value(t, scale.parameters[1], module.Type.Integer)

	title := list[1]
	testing.expect_value(t, title.name, "title")
	testing.expect_value(t, title.about, "gives a text in capital letters")
	testing.expect_value(t, title.result, module.Type.Text)
	testing.expect_value(t, len(title.parameters), 1)
	testing.expect_value(t, title.parameters[0], module.Type.Text)
	testing.expect_value(t, title.names[0], "text")

	testing.expect_value(t, list[2].result, module.Type.None)
	testing.expect_value(t, list[3].name, "entry")
	testing.expect_value(t, len(list[3].parameters), 0)
}

@(private = "file")
RECORD_SOURCE :: `// Records and handles.
package sample

Span :: struct {
	memory: system.Lent({.Read}),
	first, count: i64,
}

Pair :: struct {
	left:  i64,
	right: i64,
}

Unused :: struct {
	value: i64,
}

// swap gives a pair in the other order.
@(export)
swap :: proc "c" (pair: ^Pair, result: ^Pair) {}

// sum adds the bytes of a span, and writes them.
@(export)
sum :: proc "c" (span: ^Span, target: Lent({.Read, .Write}), pair: ^Pair) -> i64 {return 0}
`

// A struct of the package is a Record with the layout of the C language,
// and Lent is a Handle with the rights that the callee needs.
@(test)
describe_reads_records_and_handles :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", RECORD_SOURCE, &list, nil, &records))
	if len(list) != 2 || len(records) != 2 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	// Each record one time, in the order of the first use. Unused has no description.
	pair, span := records[0], records[1]
	testing.expect_value(t, pair.name, "Pair")
	testing.expect_value(t, pair.size, 16)
	testing.expect_value(t, span.name, "Span")
	testing.expect_value(t, span.size, 24)
	testing.expect_value(t, len(span.fields), 3)
	if len(span.fields) == 3 {
		testing.expect_value(t, span.fields[0], Field_Description{"memory", 0, .Handle, transmute(u32)op.Rights{.Read}, false, {}, .Plain, .None})
		testing.expect_value(t, span.fields[1], Field_Description{"first", 8, .Integer, 0, false, {}, .Plain, .None})
		testing.expect_value(t, span.fields[2], Field_Description{"count", 16, .Integer, 0, false, {}, .Plain, .None})
	}
	swap, sum := list[0], list[1]
	testing.expect_value(t, swap.result, module.Type.Record)
	testing.expect_value(t, swap.result_detail, 1)
	testing.expect_value(t, len(swap.parameters), 1)
	testing.expect_value(t, swap.details[0], 1)
	testing.expect_value(t, sum.result, module.Type.Integer)
	testing.expect_value(t, len(sum.parameters), 3)
	if len(sum.parameters) == 3 {
		testing.expect_value(t, sum.parameters[0], module.Type.Record)
		testing.expect_value(t, sum.details[0], 2)
		testing.expect_value(t, sum.parameters[1], module.Type.Handle)
		testing.expect_value(t, sum.details[1], transmute(u32)op.Rights{.Read, .Write})
		testing.expect_value(t, sum.details[2], 1)
	}
}

@(private = "file")
TABLE_SOURCE :: `// Tables of records.
package sample

Row :: struct {
	name:  [20]u8,
	count: i64,
	tag:   [3]u8,
}

// rows gives the rows of a sample, in the memory of the caller.
@(export)
rows :: proc "c" (first: i64, result: ^[]Row) -> i64 {return 0}
`

// A field [N]u8 is a Text of N bytes, and a last parameter result: ^[]Name
// is the buffer of a Table result.
@(test)
describe_reads_tables :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", TABLE_SOURCE, &list, nil, &records))
	if len(list) != 1 || len(records) != 1 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	row := records[0]
	testing.expect_value(t, row.size, 40)
	testing.expect_value(t, len(row.fields), 3)
	if len(row.fields) == 3 {
		testing.expect_value(t, row.fields[0], Field_Description{"name", 0, .Text, 20, false, {}, .Plain, .None})
		testing.expect_value(t, row.fields[1], Field_Description{"count", 24, .Integer, 0, false, {}, .Plain, .None})
		testing.expect_value(t, row.fields[2], Field_Description{"tag", 32, .Text, 3, false, {}, .Plain, .None})
	}
	testing.expect_value(t, list[0].result, module.Type.Table)
	testing.expect_value(t, list[0].result_detail, 1)
	testing.expect_value(t, len(list[0].parameters), 1)
}

@(private = "file")
TABLE_WITH_UNITS_SOURCE :: `// A table whose fields count a size and a time.
package sample

import "modus:contract/value_kinds"

Usage :: struct {
	name:  [16]u8,
	used:  value_kinds.Size_In_Pages,
	wait:  value_kinds.Time_In_Milliseconds,
	count: i64,
}

// usages gives the rows of a sample, in the memory of the caller.
@(export)
usages :: proc "c" (result: ^[]Usage) -> i64 {return 0}
`

// A field of a type of the contract such as value_kinds.Size_In_Pages is
// an Integer of 8 bytes with a sign, and states its integer unit; a plain
// i64 and a Text state none. The module file then holds the unit in the
// field, and the reader of the contract gives it back.
@(test)
describe_reads_the_unit_of_a_field :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", TABLE_WITH_UNITS_SOURCE, &list, nil, &records))
	if len(list) != 1 || len(records) != 1 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	usage := records[0]
	testing.expect_value(t, usage.size, 40)
	expected := [?]Field_Description {
		{"name", 0, .Text, 16, false, {}, .Plain, .None},
		{"used", 16, .Integer, 0, false, value_kinds.size_in(.Pages), .Plain, .None},
		{"wait", 24, .Integer, 0, false, value_kinds.time_in(.Milliseconds), .Plain, .None},
		{"count", 32, .Integer, 0, false, {}, .Plain, .None},
	}
	testing.expect_value(t, len(usage.fields), len(expected))
	for item, index in expected[:min(len(expected), len(usage.fields))] {
		testing.expect_value(t, usage.fields[index], item)
	}
}

@(private = "file")
TABLE_WITH_KINDS_SOURCE :: `// A table whose fields state their kinds.
package sample

import contract "modus:contract/operation"
import "modus:contract/value_kinds"

Check :: struct {
	module_hash: value_kinds.Hash_Field,
	name:        value_kinds.Module_Name_Field,
	address:     value_kinds.Hexadecimal_64,
	check:       value_kinds.Hexadecimal_32,
	status:      contract.Status,
	level:       contract.Log_Level,
	small:       value_kinds.Hexadecimal_8,
	wide:        value_kinds.Hexadecimal_16,
}

// checks gives the rows of a sample, in the memory of the caller.
@(export)
checks :: proc "c" (result: ^[]Check) -> i64 {return 0}
`

// A field of a type of the contract that states a field kind gets its
// kind, its type and its size: a hash is Bytes, a module name a Text, a
// hexadecimal type an unsigned Integer of its size, and a field of a
// contract enum, through an import under any name, an unsigned Integer of
// the size of the enum with the kind Status and its enum. Each field that
// the module file then holds passes the check of the contract.
@(test)
describe_reads_the_kind_of_a_field :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", TABLE_WITH_KINDS_SOURCE, &list, nil, &records))
	if len(list) != 1 || len(records) != 1 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	check := records[0]
	testing.expect_value(t, check.size, 88)
	expected := [?]Field_Description {
		{"module_hash", 0, .Bytes, value_kinds.HASH_FIELD_BYTES, false, {}, .Hash, .None},
		{"name", 32, .Text, value_kinds.MODULE_NAME_FIELD_BYTES, false, {}, .Module_Name, .None},
		{"address", 64, .Integer, 0, true, {}, .Hexadecimal, .None},
		{"check", 72, .Integer, 4, true, {}, .Hexadecimal, .None},
		{"status", 76, .Integer, u32(size_of(op.Status)), true, {}, .Status, .Status},
		{"level", 80, .Integer, u32(size_of(op.Log_Level)), true, {}, .Status, .Log_Level},
		{"small", 81, .Integer, 1, true, {}, .Hexadecimal, .None},
		{"wide", 82, .Integer, 2, true, {}, .Hexadecimal, .None},
	}
	testing.expect_value(t, len(check.fields), len(expected))
	for item, index in expected[:min(len(expected), len(check.fields))] {
		testing.expect_value(t, check.fields[index], item)
		stored := module.Field{offset = item.offset, type = u8(item.type), detail = item.detail, unsigned = item.unsigned, kind = u8(item.kind), contract_enum = u8(item.contract_enum)}
		testing.expectf(t, module.field_kind_valid(stored), "the field %s is refused by the contract", item.name)
	}
}

// The text of a field of each kind, as the machine tests and the measures
// read it: a hexadecimal Integer after 0x with the bits of its size, a
// status by its name and a word of no member by its number, a hash in
// hexadecimal with its zero bytes. A kind byte that names no kind is "?".
@(test)
field_value_writes_each_kind :: proc(t: ^testing.T) {
	row: [16]u8
	row[0] = 0xFE
	row[1] = 0xFF
	row[4] = u8(op.Log_Level.Warning)
	row[5] = u8(max(op.Log_Level)) + 1
	row[8], row[9], row[10] = 0x0A, 0x00, 0xFF
	hexadecimal := module.Field{type = u8(module.Type.Integer), offset = 0, detail = 2, kind = u8(value_kinds.Field_Kind.Hexadecimal)}
	testing.expect_value(t, field_value(row[:], hexadecimal), "0xfffe")
	level := module.Field{type = u8(module.Type.Integer), offset = 4, detail = 1, unsigned = true, kind = u8(value_kinds.Field_Kind.Status), contract_enum = u8(value_kinds.Contract_Enum.Log_Level)}
	testing.expect_value(t, field_value(row[:], level), "Warning")
	unknown := level
	unknown.offset = 5
	testing.expect_value(t, field_value(row[:], unknown), "4")
	hash := module.Field{type = u8(module.Type.Bytes), offset = 8, detail = 3, kind = u8(value_kinds.Field_Kind.Hash)}
	testing.expect_value(t, field_value(row[:], hash), "0a00ff")
	broken := hexadecimal
	broken.kind = u8(max(value_kinds.Field_Kind)) + 1
	testing.expect_value(t, field_value(row[:], broken), "?")
}

@(private = "file")
TABLE_PARAMETER_SOURCE :: `// Tables as parameters.
package sample

import "modus:support/system"

Kind :: enum u8 {
	None = 0,
	Box  = 1,
}

Draw :: struct {
	kind:        Kind,
	scale:       u8,
	x, y:        i32,
	color:       u32,
	text_start:  u32,
	text_count:  u32,
	element:     u64,
}

// draw appends the draw records of a frame and their text.
@(export)
draw :: proc "c" (drawn: ^system.Table_To_Read(Draw), changed: ^system.Table_To_Change(Draw), added: ^system.Table_To_Append(Draw), text: ^system.Bytes_To_Append, from: ^system.Bytes_To_Read, packets: ^system.Bytes_To_Change) -> i64 {return 0}
`

// ^system.Table_To_Read(Name) and its forms are Tables with a direction;
// ^system.Bytes_To_Read and its forms are Bytes. A field u8, i32, u32 or an
// enum u8 is an Integer of its size, at its natural alignment.
@(test)
describe_reads_table_parameters :: proc(t: ^testing.T) {
	list := make([dynamic]Export_Description, context.temp_allocator)
	records: []Record_Description
	testing.expect(t, describe_source("sample.odin", TABLE_PARAMETER_SOURCE, &list, nil, &records))
	if len(list) != 1 || len(records) != 1 {
		testing.expectf(t, false, "%d exports and %d records", len(list), len(records))
		return
	}
	draw := records[0]
	testing.expect_value(t, draw.size, 32)
	expected := [?]Field_Description {
		{"kind", 0, .Integer, 1, true, {}, .Plain, .None},
		{"scale", 1, .Integer, 1, true, {}, .Plain, .None},
		{"x", 4, .Integer, 4, false, {}, .Plain, .None},
		{"y", 8, .Integer, 4, false, {}, .Plain, .None},
		{"color", 12, .Integer, 4, true, {}, .Plain, .None},
		{"text_start", 16, .Integer, 4, true, {}, .Plain, .None},
		{"text_count", 20, .Integer, 4, true, {}, .Plain, .None},
		{"element", 24, .Integer, 0, true, {}, .Plain, .None},
	}
	testing.expect_value(t, len(draw.fields), len(expected))
	for item, index in expected[:min(len(expected), len(draw.fields))] {
		testing.expect_value(t, draw.fields[index], item)
	}
	export := list[0]
	testing.expect_value(t, len(export.parameters), 6)
	types := [6]module.Type{.Table, .Table, .Table, .Bytes, .Bytes, .Bytes}
	directions := [6]module.Direction{.Read, .Change, .Append, .Append, .Read, .Change}
	details := [6]u32{1, 1, 1, 0, 0, 0}
	for index in 0 ..< min(6, len(export.parameters)) {
		testing.expect_value(t, export.parameters[index], types[index])
		testing.expect_value(t, export.directions[index], directions[index])
		testing.expect_value(t, export.details[index], details[index])
	}
}

// The tool does not guess: a source that breaks a rule gives no description.
@(test)
describe_rejects_what_has_no_description :: proc(t: ^testing.T) {
	Case :: struct {
		about:  string,
		source: string,
	}
	cases := [?]Case {
		{"a parameter of 32 bits", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: u32) -> i64 {return 0}\n"},
		{"a float result", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> f64 {return 0}\n"},
		{"the Odin calling convention", "package p\n// f gives x.\n@(export)\nf :: proc(x: i64) -> i64 {return 0}\n"},
		{"no comment", "package p\n@(export)\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"an export of data", "package p\n// d is data.\n@(export)\nd: i64\n"},
		{"a buffer that is not the last parameter", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]u8, x: i64) -> i64 {return 0}\n"},
		{"a Text result with no count", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]u8) {}\n"},
		{"thirteen parameters", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g, h, i, j, k, l, m, n: i64) -> i64 {return 0}\n"},
		{"a Text result and twelve parameters", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g, h, i, j, k, l, m: i64, result: ^[]u8) -> i64 {return 0}\n"},
		{"a function that does not return", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> ! {for {}}\n"},
		{"an entry with two parameters", "package p\n@(export)\nentry :: proc \"c\" (a, b: rawptr) -> ! {for {}}\n"},
		{"a record with a float field", "package p\nR :: struct {a: f32}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a packed record", "package p\nR :: struct #packed {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a record that is too large", "package p\nR :: struct {a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, aa, ab, ac, ad, ae, af, ag: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a result record with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64, result: ^R) {}\n"},
		{"a record result and a result type", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64, result: ^R) -> i64 {return 0}\n"},
		{"a record result and twelve parameters", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g, h, i, j, k, l, m: i64, result: ^R) {}\n"},
		{"a pointer to an unknown type", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^Other) -> i64 {return 0}\n"},
		{"a right that does not exist", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (h: Lent({.Fly})) -> i64 {return 0}\n"},
		{"a handle result", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> Lent({.Read}) {return {}}\n"},
		{"an entry with an integer", "package p\n@(export)\nentry :: proc \"c\" (a: i64) -> ! {for {}}\n"},
		{"a Table result with no count", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]R) {}\n"},
		{"a Table that is not the result", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^[]R, x: i64) -> i64 {return 0}\n"},
		{"a Table of records with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (result: ^[]R) -> i64 {return 0}\n"},
		{"a Text field with a size that is not a number", "package p\nN :: 4\nR :: struct {a: [N]u8}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a table parameter of records with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^Table_To_Read(R)) -> i64 {return 0}\n"},
		{"a table parameter of a type that is not a record", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^Table_To_Change(i64)) -> i64 {return 0}\n"},
		{"a table parameter with two types", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (rows: ^Table_To_Append(R, R)) -> i64 {return 0}\n"},
		{"an integer field of an enum with no backing type", "package p\nK :: enum {A}\nR :: struct {k: K}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a Text field of 300 bytes", "package p\nR :: struct {a: [300]u8}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a field kind of a type that value_kinds does not have", "package p\nimport \"modus:contract/value_kinds\"\nR :: struct {a: value_kinds.Hexadecimal_128}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a field kind of a package that is not value_kinds", "package p\nimport value_kinds \"modus:support/system\"\nR :: struct {a: value_kinds.Hash_Field}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a status of a package that is not the contract", "package p\nimport op \"modus:support/system\"\nR :: struct {a: op.Log_Level}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a field kind as a parameter", "package p\nimport \"modus:contract/value_kinds\"\n// f gives x.\n@(export)\nf :: proc \"c\" (x: value_kinds.Hexadecimal_64) -> i64 {return 0}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		testing.expectf(t, !describe_source("case.odin", item.source, &list), "%s", item.about)
	}
}
