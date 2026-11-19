package build

import module "modus:contract/module"
import "core:fmt"
import "core:strings"
import "core:testing"

// The folder of the sources of these tests: a module of the group tests.
@(private = "file")
STREAM_TEST_FOLDER :: "src/modules/tests/record_stream_probe"
// A support package that declares a record stream, which no module may do.
@(private = "file")
STREAM_TEST_OTHER_FOLDER :: "src/library/support/record_stream_sample"

// The record types of the sources of these tests: two records with each
// byte named, one with padding inside, one with padding at its end, one
// with a Handle.
@(private = "file")
STREAM_TEST_TYPES :: `Access :: struct {
	status: u64,
	bytes:  u64,
}

Terms :: struct {
	bound: u64,
}

Padded :: struct {
	small: u8,
	large: u64,
}

Tail :: struct {
	large: u64,
	small: u8,
}

Lent_Record :: struct {
	lent:  system.Lent({.Read}),
	other: u32,
}`

// stream_test_source gives the source of the module of these tests: the
// package, the import of system, the record types, then the declarations
// and the body of a procedure.
@(private = "file")
stream_test_source :: proc(declarations, body: string) -> Fact_Source {
	text := fmt.tprintf("package record_stream_probe\n\nimport \"modus:support/system\"\n\n%s\n\n%s\n\nwrite :: proc() {{\n%s\n}}\n", STREAM_TEST_TYPES, declarations, body)
	return {path = STREAM_TEST_FOLDER + "/main.odin", source = text}
}

// stream_test_streams reads the sources and merges the record streams in
// a description with no record. ok is false at the first refusal.
@(private = "file")
stream_test_streams :: proc(sources: ..Fact_Source) -> (description: Module_Description, ok: bool) {
	outputs, inputs := record_streams_of_sources(STREAM_TEST_FOLDER, sources) or_return
	record_streams_merge(&description, outputs, inputs) or_return
	return description, true
}

// Each source that the tool must refuse, with what it breaks: a
// declaration that is not a package variable of the module, a record type
// that it cannot describe or that has padding or a Handle, a form of the
// arguments that it does not read, Paired and Many_Types on a typed
// stream, terms that are no record, one name for two streams, and a
// generic record output with no generic record input or with two. For
// each, the tool gives no record stream.
@(test)
a_record_stream_that_breaks_a_rule_is_refused :: proc(t: ^testing.T) {
	Case :: struct {
		name:         string,
		declarations: string,
		body:         string,
	}
	generic_input :: "sources: system.Record_Input(system.Any_Record)"
	cases := [?]Case {
		// Not a package variable of the package of the module.
		{"a local variable", "", "local: system.Record_Output(Access)"},
		{"a local constant", "", "Local :: system.Record_Output(Access)"},
		{"a type of the package", "Alias :: system.Record_Output(Access)", ""},
		{"a distinct type of the package", "Alias :: distinct system.Record_Input(Access)", ""},
		{"a constant of the package", "requests : system.Record_Output(Access) : {}", ""},
		{"a field of a record", "Holder :: struct {\n\tstream: system.Record_Output(Access),\n}", ""},
		{"a declaration inside a when", "when ODIN_OS == .Linux {\n\tinside: system.Record_Output(Access)\n}", ""},
		{"a composite literal", "", "_ = system.Record_Output(Access){}"},
		{"a parameter by value", "read :: proc(stream: system.Record_Input(Access)) {}", ""},
		// The record and the terms.
		{"a record that is a number", "requests: system.Record_Output(u64)", ""},
		{"a record that the package does not declare", "requests: system.Record_Output(Missing)", ""},
		{"a record with padding inside", "requests: system.Record_Output(Padded)", ""},
		{"a record with padding at its end", "orders: system.Record_Input(Tail)", ""},
		{"a record with a Handle", "requests: system.Record_Output(Lent_Record)", ""},
		{"terms that are Any_Record", "orders: system.Record_Input(Access, .One, system.Any_Record)", ""},
		{"terms with padding", "orders: system.Record_Input(Access, .One, Padded)", ""},
		{"terms with a Handle", "orders: system.Record_Input(Access, Terms_Type = Lent_Record)", ""},
		// The form of the arguments.
		{"no argument", "requests: system.Record_Output()", ""},
		{"no record, by name", "orders: system.Record_Input(wirings = .Many)", ""},
		{"an argument past the parameters of an output", "requests: system.Record_Output(Access, .Unpaired, Terms)", ""},
		{"an argument past the parameters of an input", "orders: system.Record_Input(Access, .One, Terms, Terms)", ""},
		{"a name that is no parameter", "orders: system.Record_Input(Access, count = .Many)", ""},
		{"a parameter given two times", "orders: system.Record_Input(Access, Record_Type = Access)", ""},
		{"a pairing that names no member", "forward: system.Record_Output(system.Any_Record, .Twice)\n" + generic_input, ""},
		{"a pairing that is a number", "forward: system.Record_Output(system.Any_Record, 1)\n" + generic_input, ""},
		{"a count that names no member", "orders: system.Record_Input(Access, .All)", ""},
		// Paired and Many_Types on a typed stream.
		{"Paired on a typed record output", "requests: system.Record_Output(Access, .Paired)\n" + generic_input, ""},
		{"Many_Types on a typed record input", "orders: system.Record_Input(Access, .Many_Types)", ""},
		// The rules of the whole tables.
		{"two record outputs with one name", "requests: system.Record_Output(Access)\nrequests: system.Record_Output(Terms)", ""},
		{"two record inputs with one name", "orders: system.Record_Input(Access)\norders: system.Record_Input(Access, .Many)", ""},
		{"a record output and a record input with one name", "requests: system.Record_Output(Access)\nrequests: system.Record_Input(Access)", ""},
		{"a generic record output and no record input", "forward: system.Record_Output(system.Any_Record)", ""},
		{"a generic record output and a typed record input", "forward: system.Record_Output(system.Any_Record)\norders: system.Record_Input(Access, .Many)", ""},
		{"a generic record output and two generic record inputs", "forward: system.Record_Output(system.Any_Record, .Paired)\n" + generic_input + "\nmore: system.Record_Input(system.Any_Record, .Many)", ""},
	}
	for item in cases {
		_, ok := stream_test_streams(stream_test_source(item.declarations, item.body))
		testing.expectf(t, !ok, "a source with %s is taken", item.name)
	}
	// A package variable of another package than the module, which the
	// compiler read for the module.
	other := Fact_Source {
		path   = STREAM_TEST_OTHER_FOLDER + "/sample.odin",
		source = "package record_stream_sample\n\nimport \"modus:support/system\"\n\nSample :: struct {\n\tplace: u64,\n}\n\nelsewhere: system.Record_Output(Sample)\n",
	}
	_, other_ok := stream_test_streams(stream_test_source("", ""), other)
	testing.expect(t, !other_ok)
	// The same package with a pointer to a stream only: no declaration.
	pointer := other
	pointer.source = "package record_stream_sample\n\nimport \"modus:support/system\"\n\nSample :: struct {\n\tplace: u64,\n}\n\nwrite :: proc(stream: ^system.Record_Output(Sample)) {}\n"
	pointer_description, pointer_ok := stream_test_streams(stream_test_source("", ""), pointer)
	testing.expect(t, pointer_ok && len(pointer_description.record_outputs) == 0 && len(pointer_description.record_inputs) == 0)
}

// The rules of the whole tables leave a description as it was when they
// refuse: the bound of the declarations and one past it, then a refusal of
// a name with a record already in the description.
@(test)
the_record_streams_of_a_module_keep_their_bound :: proc(t: ^testing.T) {
	stream := Record_Stream_Description{direction = .Output, record = {name = "Access", size = 8, fields = {{name = "status", offset = 0, type = .Integer}}}}
	at_bound := make([]Record_Stream_Description, module.RECORD_STREAM_INDEX_MOST, context.temp_allocator)
	for &item, index in at_bound {
		item = stream
		item.name = fmt.tprintf("stream_%d", index)
	}
	bound_problem, _ := record_streams_problem(at_bound, nil)
	testing.expect_value(t, bound_problem, "")
	past := make([]Record_Stream_Description, module.RECORD_STREAM_INDEX_MOST + 1, context.temp_allocator)
	copy(past, at_bound)
	past[module.RECORD_STREAM_INDEX_MOST] = stream
	past[module.RECORD_STREAM_INDEX_MOST].name = "one_more"
	past_problem, past_at := record_streams_problem(past, nil)
	testing.expect(t, strings.contains(past_problem, "at most") && past_at.name == "one_more")
	inputs_problem, _ := record_streams_problem(nil, past)
	testing.expect(t, strings.contains(inputs_problem, "record inputs"))

	// A refused merge changes nothing of the description.
	description := Module_Description{records = {{name = "Kept", size = 8, fields = {{name = "value", offset = 0, type = .Integer}}}}}
	twice := [2]Record_Stream_Description{stream, stream}
	twice[0].name, twice[1].name = "requests", "requests"
	testing.expect(t, !record_streams_merge(&description, twice[:], nil))
	testing.expect(t, len(description.records) == 1 && len(description.record_outputs) == 0)
	// A record of the name of a record of the module, with another
	// description: refused, and nothing changed.
	other := stream
	other.name = "requests"
	other.record.name = "Kept"
	others := [1]Record_Stream_Description{other}
	testing.expect(t, !record_streams_merge(&description, others[:], nil))
	testing.expect(t, len(description.records) == 1 && len(description.record_outputs) == 0)
}

// The declarations as a module writes them, last: a typed record output,
// a generic record output with Paired, a typed record input with Many by
// name, a generic record input with Many_Types and terms, and a procedure
// that takes a record output by its address. The rows are sorted by name,
// each record is described once, and the help is the first sentence of the
// comment.
@(test)
the_record_streams_of_a_module_are_read :: proc(t: ^testing.T) {
	declarations := `// One request that the server answered.
requests: system.Record_Output(Access)

// The streams to keep, each with the terms of its space.
sources: system.Record_Input(system.Any_Record, .Many_Types, Terms)

// The kept records, forwarded.
forward: system.Record_Output(system.Any_Record, .Paired)

// The orders to serve.
orders: system.Record_Input(Access, wirings = .Many)

// No terms, by the name of the default.
plain: system.Record_Input(Terms, .One, system.No_Terms)

write_one :: proc(output: ^system.Record_Output(Access)) {}`
	description, ok := stream_test_streams(stream_test_source(declarations, ""))
	testing.expect(t, ok)
	if !ok {
		return
	}
	testing.expect_value(t, len(description.record_outputs), 2)
	testing.expect_value(t, len(description.record_inputs), 3)
	testing.expect_value(t, len(description.records), 2)
	if len(description.record_outputs) != 2 || len(description.record_inputs) != 3 || len(description.records) != 2 {
		return
	}
	testing.expect(t, description.records[0].name == "Access" && description.records[1].name == "Terms")
	forward, requests := description.record_outputs[0], description.record_outputs[1]
	testing.expect(t, forward.name == "forward" && forward.generic && forward.pairing == .Paired && forward.record_index == 0)
	testing.expect(t, requests.name == "requests" && !requests.generic && requests.pairing == .Unpaired && requests.record_index == 1)
	testing.expect_value(t, requests.about, "One request that the server answered")
	orders, plain, sources := description.record_inputs[0], description.record_inputs[1], description.record_inputs[2]
	testing.expect(t, orders.name == "orders" && orders.record_index == 1 && orders.wirings == .Many && orders.terms_index == 0)
	testing.expect(t, plain.name == "plain" && plain.record_index == 2 && plain.wirings == .One && !plain.has_terms && plain.terms_index == 0)
	testing.expect(t, sources.name == "sources" && sources.generic && sources.wirings == .Many_Types && sources.terms_index == 2)
}
