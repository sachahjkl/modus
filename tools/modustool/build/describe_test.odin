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
	form:        contract.Log_Record_Form,
	values:      value_kinds.Fact_Values_Field,
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
	testing.expect_value(t, check.size, 232)
	expected := [?]Field_Description {
		{"module_hash", 0, .Bytes, value_kinds.HASH_FIELD_BYTES, false, {}, .Hash, .None},
		{"name", 32, .Text, value_kinds.MODULE_NAME_FIELD_BYTES, false, {}, .Module_Name, .None},
		{"address", 64, .Integer, 0, true, {}, .Hexadecimal, .None},
		{"check", 72, .Integer, 4, true, {}, .Hexadecimal, .None},
		{"status", 76, .Integer, u32(size_of(op.Status)), true, {}, .Status, .Status},
		{"level", 80, .Integer, u32(size_of(op.Log_Level)), true, {}, .Status, .Log_Level},
		{"small", 81, .Integer, 1, true, {}, .Hexadecimal, .None},
		{"wide", 82, .Integer, 2, true, {}, .Hexadecimal, .None},
		{"form", 84, .Integer, u32(size_of(op.Log_Record_Form)), true, {}, .Status, .Log_Record_Form},
		{"values", 85, .Bytes, value_kinds.FACT_VALUES_FIELD_BYTES, false, {}, .Fact_Values, .None},
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
	// The values of a fact up to their last byte that is not zero, as the
	// raw form; values of zeros only are empty.
	values_row: [value_kinds.FACT_VALUES_FIELD_BYTES]u8
	values := module.Field{type = u8(module.Type.Bytes), offset = 0, detail = value_kinds.FACT_VALUES_FIELD_BYTES, kind = u8(value_kinds.Field_Kind.Fact_Values)}
	testing.expect_value(t, field_value(values_row[:], values), "")
	values_row[0], values_row[2] = 0x0C, 0x23
	testing.expect_value(t, field_value(values_row[:], values), "0c0023")
	broken := hexadecimal
	broken.kind = u8(max(value_kinds.Field_Kind)) + 1
	testing.expect_value(t, field_value(row[:], broken), "?")
}

@(private = "file")
TABLE_PARAMETER_SOURCE :: `// Tables as parameters.
package sample

import "modus:system"

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
		{"a Text result and twelve parameters, four of them optional: seventeen words", "package p\nimport \"modus:contract/module\"\n// f gives x.\n@(export)\nf :: proc \"c\" (a_presence: module.Presence, a: i64, b_presence: module.Presence, b: i64, c_presence: module.Presence, c: i64, d_presence: module.Presence, d: i64, e, g, h, i, j, k, l, m: i64, result: ^[]u8) -> i64 {return 0}\n"},
		{"a function that does not return", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64) -> ! {for {}}\n"},
		{"an entry with two parameters", "package p\n@(export)\nentry :: proc \"c\" (a, b: rawptr) -> ! {for {}}\n"},
		{"a record with a float field", "package p\nR :: struct {a: f32}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a packed record", "package p\nR :: struct #packed {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a record that is too large", "package p\nR :: struct {a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z, aa, ab, ac, ad, ae, af, ag: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a result record with a handle", "package p\nR :: struct {h: Lent({.Read})}\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64, result: ^R) {}\n"},
		{"a record result and a result type", "package p\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (x: i64, result: ^R) -> i64 {return 0}\n"},
		{"thirteen parameters", "package p\n// f gives x.\n@(export)\nf :: proc \"c\" (a, b, c, d, e, g, h, i, j, k, l, m, n: i64) -> i64 {return 0}\n"},
		{"a record result and twelve parameters, four of them optional: seventeen words", "package p\nimport \"modus:contract/module\"\nR :: struct {a: i64}\n// f gives x.\n@(export)\nf :: proc \"c\" (a_presence: module.Presence, a: i64, b_presence: module.Presence, b: i64, c_presence: module.Presence, c: i64, d_presence: module.Presence, d: i64, e, g, h, i, j, k, l, m: i64, result: ^R) {}\n"},
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
		{"a field kind of a package that is not value_kinds", "package p\nimport value_kinds \"modus:system\"\nR :: struct {a: value_kinds.Hash_Field}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a status of a package that is not the contract", "package p\nimport op \"modus:system\"\nR :: struct {a: op.Log_Level}\n// f gives x.\n@(export)\nf :: proc \"c\" (r: ^R) -> i64 {return 0}\n"},
		{"a field kind as a parameter", "package p\nimport \"modus:contract/value_kinds\"\n// f gives x.\n@(export)\nf :: proc \"c\" (x: value_kinds.Hexadecimal_64) -> i64 {return 0}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		testing.expectf(t, !describe_source("case.odin", item.source, &list), "%s", item.about)
	}
}

// A table of display texts: each rule of the reader refuses its edges, with
// a line that names the table: the language, the form of the table, its
// enum, each row and each text, and two tables of one enum and one
// language. Then the texts of two tables come in the order of the format.
@(test)
describe_refuses_a_table_of_display_texts_that_breaks_a_rule :: proc(t: ^testing.T) {
	Case :: struct {
		about:  string,
		source: string,
	}
	HEAD :: "package p\nMode :: enum u32 {Slow = 0, Fast = 1}\nOther :: enum u32 {Low = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"
	// One byte past the bound, and the bound: 25 and 24 bytes.
	LONG :: "aaaaaaaaaaaaaaaaaaaaaaaaa"
	LONGEST :: "bbbbbbbbbbbbbbbbbbbbbbbb"
	#assert(len(LONG) == module.MEMBER_TEXT_CAPACITY + 1 && len(LONGEST) == module.MEMBER_TEXT_CAPACITY)
	cases := [?]Case {
		{"an empty tag", HEAD + "@(rodata, member_texts = \"\")\nt := #partial [Mode]string{.Slow = \"slow\"}\n"},
		{"a tag that starts with -", HEAD + "@(rodata, member_texts = \"-fr\")\nt := #partial [Mode]string{.Slow = \"lent\"}\n"},
		{"a tag with an empty subtag", HEAD + "@(rodata, member_texts = \"fr--CA\")\nt := #partial [Mode]string{.Slow = \"lent\"}\n"},
		{"a tag with _", HEAD + "@(rodata, member_texts = \"fr_CA\")\nt := #partial [Mode]string{.Slow = \"lent\"}\n"},
		{"a tag with a private use and nothing after it", HEAD + "@(rodata, member_texts = \"en-x\")\nt := #partial [Mode]string{.Slow = \"slow\"}\n"},
		{"a tag that is no text", HEAD + "@(rodata, member_texts = 1)\nt := #partial [Mode]string{.Slow = \"slow\"}\n"},
		{"a table that is a slice", HEAD + "@(rodata, member_texts = \"en\")\nt := []string{\"slow\"}\n"},
		{"a table of numbers", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]i64{.Slow = 1}\n"},
		{"a table with no value", HEAD + "@(rodata, member_texts = \"en\")\nt: [Mode]string\n"},
		{"a table of an enum of no export", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Other]string{.Low = \"low\"}\n"},
		{"a table of a type that is no enum", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [4]string{0 = \"low\"}\n"},
		{"a row that is no member", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Medium = \"medium\"}\n"},
		{"a row with no member name", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{\"slow\"}\n"},
		{"a row of a name, not a text", HEAD + "S :: \"slow\"\n@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = S}\n"},
		{"an empty text", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"\"}\n"},
		{"a text past its bound", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"" + LONG + "\"}\n"},
		{"a text with an escape", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"sl\\tow\"}\n"},
		{"a text with a control character", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = `sl\x01ow`}\n"},
		{"a text with a space of no width", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"sl\u200bow\"}\n"},
		{"a text with a mark of direction", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"\u202ewols\"}\n"},
		{"a text of spaces only", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"   \"}\n"},
		{"two tables of one enum and one tag", HEAD + "@(rodata, member_texts = \"en\")\nt := #partial [Mode]string{.Slow = \"slow\"}\n@(rodata, member_texts = \"en\")\nu := #partial [Mode]string{.Slow = \"sluggish\"}\n"},
		{"two tables of one enum and one tag in two cases", HEAD + "@(rodata, member_texts = \"fr-CA\")\nt := #partial [Mode]string{.Slow = \"lent\"}\n@(rodata, member_texts = \"FR-ca\")\nu := #partial [Mode]string{.Slow = \"lente\"}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		testing.expectf(t, !describe_source("case.odin", item.source, &list), "%s", item.about)
	}
	// The success comes last: three tables, one of a text of the largest
	// length, one with its tag in another case, read in the order of the
	// enum, the member and the canonical tag.
	longest := LONGEST
	source := "package p\nMode :: enum u32 {Slow = 0, Fast = 1}\nLevel :: enum u8 {Low = 1, High = 2}\n// f sets x.\n@(export)\nf :: proc \"c\" (level: Level, mode: Mode) -> i64 {return 0}\n" +
		"@(rodata, member_texts = \"en\")\nlevels := #partial [Level]string{.High = \"high!\", .Low = \"" + LONGEST + "\"}\n" +
		"@(rodata, member_texts = \"FR-ca\")\nmodes_fr := #partial [Mode]string{.Slow = \"Lent\"}\n" +
		"@(rodata, member_texts = \"en\")\nmodes := [Mode]string{.Fast = \"Fast 2x\", .Slow = \"Slow\"}\n"
	list := make([dynamic]Export_Description, context.temp_allocator)
	texts: []Member_Text_Description
	if !testing.expect(t, describe_source("case.odin", source, &list, nil, nil, nil, &texts)) || !testing.expect_value(t, len(texts), 5) {
		return
	}
	testing.expect_value(t, texts[0], Member_Text_Description{1, 0, "en", longest})
	testing.expect_value(t, texts[1], Member_Text_Description{1, 1, "en", "high!"})
	testing.expect_value(t, texts[2], Member_Text_Description{2, 0, "en", "Slow"})
	testing.expect_value(t, texts[3], Member_Text_Description{2, 0, "fr-CA", "Lent"})
	testing.expect_value(t, texts[4], Member_Text_Description{2, 1, "en", "Fast 2x"})
}

// Each row of buttons of the palette fits the fields of an entry, or the
// build refuses the module: an act name, a name of a row and a button one
// byte past their bound. An export that gives no row is not checked. Then
// a member whose name is past the bound of a button and whose display text
// fits, and the act name at its bound, pass.
@(test)
describe_refuses_a_palette_row_that_does_not_fit :: proc(t: ^testing.T) {
	Case :: struct {
		about:       string,
		module_name: string,
		source:      string,
	}
	// 25 bytes: one past a button and a name of a row.
	PAST :: "abcdefghijklmnopqrstuvwxy"
	cases := [?]Case {
		{"an act name of 33 bytes", "a_module_name_of_26_bytes_", "package p\nMode :: enum u32 {Slow = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a name of a row of 25 bytes", "m", "package p\nMode :: enum u32 {Slow = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (" + PAST + ": Mode) -> i64 {return 0}\n"},
		{"a button of 25 bytes", "m", "package p\nMode :: enum u32 {" + PAST + " = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		enums: []Enum_Description
		texts: []Member_Text_Description
		if !testing.expectf(t, describe_source("case.odin", item.source, &list, nil, nil, &enums, &texts), "%s: the source is refused", item.about) {
			continue
		}
		testing.expectf(t, !palette_rows_fit(item.module_name, list[:], enums, texts), "%s", item.about)
	}
	// The successes: an export with a required Integer beside its enum gives
	// no row; a member past the bound of a button with a display text that
	// fits; an act name of 32 bytes.
	no_row := "package p\nMode :: enum u32 {" + PAST + " = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (count: i64, mode: Mode) -> i64 {return 0}\n"
	with_text := "package p\nMode :: enum u32 {" + PAST + " = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n@(rodata, member_texts = \"en\")\nt := [Mode]string{." + PAST + " = \"short\"}\n"
	taken := [?][2]string{{"m", no_row}, {"m", with_text}, {"a_module_name_of_25_bytes", "package p\nMode :: enum u32 {Slow = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"}}
	for item in taken {
		list := make([dynamic]Export_Description, context.temp_allocator)
		enums: []Enum_Description
		texts: []Member_Text_Description
		testing.expect(t, describe_source("case.odin", item[1], &list, nil, nil, &enums, &texts))
		testing.expectf(t, palette_rows_fit(item[0], list[:], enums, texts), "%q is refused", item[1])
	}
}

// The enum of an export, its getter and its optional parameters: each rule
// of the reader refuses its edges, with a line that names the export. A
// getter that the attribute names and that is no export, or that gives
// another type, is refused as each enum that the format cannot hold.
@(test)
describe_refuses_an_enum_parameter_that_breaks_a_rule :: proc(t: ^testing.T) {
	Case :: struct {
		about:  string,
		source: string,
	}
	HEAD :: "package p\nMode :: enum u32 {Slow = 0, Fast = 1}\nOther :: enum u32 {Slow = 0, Fast = 1}\n"
	cases := [?]Case {
		{"an enum with no backing type", "package p\nMode :: enum {Slow, Fast}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"an enum with no member", "package p\nMode :: enum u32 {}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a member whose value is an expression", "package p\nBASE :: 4\nMode :: enum u32 {Slow = BASE, Fast}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a member past its backing type", "package p\nMode :: enum u8 {Slow = 0, Fast = 256}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"two members of one value", "package p\nMode :: enum u32 {Slow = 1, Fast = 1}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"two members of one name in lower case", "package p\nMode :: enum u32 {Slow = 0, SLOW = 1}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a member with a name of 32 bytes", "package p\nMode :: enum u32 {Abcdefghijklmnopqrstuvwxyzabcdef = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a member that starts with _", "package p\nMode :: enum u32 {_Slow = 0}\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter that is no export", HEAD + "// f sets x.\n@(export, enum_getters = \"mode = g\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter that gives another enum", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" () -> Other {return .Slow}\n// f sets x.\n@(export, enum_getters = \"mode = g\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter that gives an Integer", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" () -> i64 {return 0}\n// f sets x.\n@(export, enum_getters = \"mode = g\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter that takes a parameter", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" (x: i64) -> Mode {return .Slow}\n// f sets x.\n@(export, enum_getters = \"mode = g\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter of no parameter", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" () -> Mode {return .Slow}\n// f sets x.\n@(export, enum_getters = \"speed = g\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter of a parameter that is no enum", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" () -> Mode {return .Slow}\n// f sets x.\n@(export, enum_getters = \"x = g\")\nf :: proc \"c\" (mode: Mode, x: i64) -> i64 {return 0}\n"},
		{"a parameter given two getters", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" () -> Mode {return .Slow}\n// f sets x.\n@(export, enum_getters = \"mode = g, mode = g\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a pair with no =", HEAD + "// f sets x.\n@(export, enum_getters = \"mode\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a getter that is no text", HEAD + "// f sets x.\n@(export, enum_getters = 4)\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a presence before a text", HEAD + "import \"modus:contract/module\"\n// f sets x.\n@(export)\nf :: proc \"c\" (name_presence: module.Presence, name: ^string) -> i64 {return 0}\n"},
		{"a presence of another name", HEAD + "import \"modus:contract/module\"\n// f sets x.\n@(export)\nf :: proc \"c\" (speed_presence: module.Presence, mode: Mode) -> i64 {return 0}\n"},
		{"a presence with no name before its suffix", HEAD + "import \"modus:contract/module\"\n// f sets x.\n@(export)\nf :: proc \"c\" (_presence: module.Presence, mode: Mode) -> i64 {return 0}\n"},
		{"a presence that ends the parameters", HEAD + "import \"modus:contract/module\"\n// f sets x.\n@(export)\nf :: proc \"c\" (mode: Mode, mode_presence: module.Presence) -> i64 {return 0}\n"},
		{"two presences in a row", HEAD + "import \"modus:contract/module\"\n// f sets x.\n@(export)\nf :: proc \"c\" (mode_presence: module.Presence, other_presence: module.Presence, mode: Mode) -> i64 {return 0}\n"},
		{"a presence in a shared declaration", HEAD + "import \"modus:contract/module\"\n// f sets x.\n@(export)\nf :: proc \"c\" (a_presence, b_presence: module.Presence, mode: Mode) -> i64 {return 0}\n"},
		{"a range on an enum", HEAD + "// f sets x.\n@(export, parameter_ranges = \"mode = 0..1\")\nf :: proc \"c\" (mode: Mode) -> i64 {return 0}\n"},
		{"a range of no parameter", HEAD + "// f sets x.\n@(export, parameter_ranges = \"speed = 0..1\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"a range that starts above its end", HEAD + "// f sets x.\n@(export, parameter_ranges = \"x = 2..1\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"a range that is no range", HEAD + "// f sets x.\n@(export, parameter_ranges = \"x = 2\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"a range past the integers", HEAD + "// f sets x.\n@(export, parameter_ranges = \"x = 0..9223372036854775808\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"a range given twice", HEAD + "// f sets x.\n@(export, parameter_ranges = \"x = 0..1, x = 0..2\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"choices of no export", HEAD + "// f sets x.\n@(export, parameter_choices = \"x = nothing\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"choices of an export with no table", HEAD + "// g gives x.\n@(export)\ng :: proc \"c\" () -> i64 {return 0}\n// f sets x.\n@(export, parameter_choices = \"x = g\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"instances of a second parameter", HEAD + "// f sets x.\n@(export, parameter_instances = \"y = f\")\nf :: proc \"c\" (x: i64, y: i64) -> i64 {return 0}\n"},
		{"the attributes on no export", HEAD + "// f sets x.\n@(parameter_ranges = \"x = 0..1\")\nf :: proc \"c\" (x: i64) -> i64 {return 0}\n"},
		{"an enum result with an error record", "package p\nimport \"modus:contract/errors\"\nMode :: enum u32 {Slow = 0}\n// g gives x.\n@(export)\ng :: proc \"c\" (error: ^errors.Error_Record) -> Mode {return .Slow}\n"},
	}
	for item in cases {
		list := make([dynamic]Export_Description, context.temp_allocator)
		testing.expectf(t, !describe_source("case.odin", item.source, &list), "%s", item.about)
	}
	// The success comes last: the members in lower case with their values,
	// the next value after a value, the getter in the detail, the optional
	// bit, and an enum of a getter that is one description with the enum of
	// its parameter.
	source := "package p\nimport \"modus:contract/module\"\nMode :: enum i16 {Slow = -3, Fast, Very_Fast = 7}\n// mode gives x.\n@(export, link_name = \"mode\")\nmode_get :: proc \"c\" () -> Mode {return .Slow}\n// f sets x.\n@(export, enum_getters = \"mode = mode\", parameter_ranges = \"count = -5..9223372036854775807\")\nf :: proc \"c\" (count: i64, mode_presence: module.Presence, mode: Mode) -> i64 {return 0}\n"
	list := make([dynamic]Export_Description, context.temp_allocator)
	enums: []Enum_Description
	if !testing.expect(t, describe_source("case.odin", source, &list, nil, nil, &enums)) || !testing.expect_value(t, len(list), 2) || !testing.expect_value(t, len(enums), 1) {
		return
	}
	testing.expect(t, enums[0].name == "Mode" && enums[0].size == 2 && !enums[0].unsigned && len(enums[0].members) == 3)
	testing.expect(t, enums[0].members[0] == {"slow", -3} && enums[0].members[1] == {"fast", -2} && enums[0].members[2] == {"very_fast", 7})
	testing.expect(t, list[0].result == .Enum && list[0].result_detail == 1)
	setter := list[1]
	enum_index, getter := module.enum_detail_of(setter.details[1])
	testing.expect(t, setter.parameters[1] == .Enum && enum_index == 1 && getter == 1 && len(setter.needs) == 2 && setter.needs[0] == .Required && setter.needs[1] == .Optional)
	testing.expect(t, len(setter.setting_rows) == 1 && setter.setting_rows[0] == {export_index = 2, parameter = 0, has_range = true, least = -5, most = max(i64)})
}