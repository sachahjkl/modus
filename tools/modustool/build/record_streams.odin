package build

import module "modus:contract/module"
import "core:fmt"
import "core:odin/ast"
import "core:path/filepath"
import "core:reflect"
import "core:slice"
import "core:strings"
import "modustool:foundation"

// The record outputs and the record inputs of a module
// (src/md/features/module_outputs.md, "The declaration in the module"). The
// source declares each one as a package variable of the package of the
// module, of the generic type `system.Record_Output(T)`,
// `system.Record_Input(T)` or `system.Record_Input_With_Terms(T, Terms)`.
// The tool reads each such declaration in the
// sources that the compiler read for the module, describes its record in
// the table Records, and writes the tables Record_Outputs and
// Record_Inputs. It has no type checker: it reads the type as the source
// writes it.
//
// The refusals, each with its reason:
//   - a declaration of the type that is not a package variable of the
//     package of the module (a local variable, a constant, a field of a
//     record, a declaration inside a `when`, a variable of another
//     package): the tool would not see each such stream, and a wiring names
//     only a row of the module;
//   - a record or terms type that is not a record type that the tool can
//     describe, or Any_Record as the terms;
//   - a record with a byte that no field names, or with a Handle field:
//     the record goes into memory that another process reads;
//   - two record outputs, two record inputs, or a record output and a
//     record input, with one name: `server.name` names one stream;
//   - Paired on a record output that is not generic, and Many_Types on a
//     record input that is not generic: each needs a type that a wiring
//     fixes;
//   - a generic record output in a module with no generic record input, or
//     with two: it takes the type of the one generic record input;
//   - more than module.RECORD_STREAM_INDEX_MOST of either: each loader
//     checks the place of each one against each other write of its load.

// The names of the declarations in the support package system
// (src/library/support/system/record_streams.odin).
RECORD_OUTPUT_TYPE_NAME :: "Record_Output"
RECORD_INPUT_TYPE_NAME :: "Record_Input"
RECORD_INPUT_WITH_TERMS_TYPE_NAME :: "Record_Input_With_Terms"
ANY_RECORD_TYPE_NAME :: "Any_Record"

// The names of the parameters of the generic types, for an argument that
// the source names.
RECORD_STREAM_RECORD_PARAMETER :: "Record_Type"
RECORD_OUTPUT_PAIRING_PARAMETER :: "pairing"
RECORD_INPUT_WIRINGS_PARAMETER :: "wirings"
RECORD_INPUT_TERMS_PARAMETER :: "Terms_Type"

// Which of the two declarations.
Record_Stream_Direction :: enum {
	Output, // A record output: the module writes it.
	Input, // A record input: the module reads it.
}

// Which of the three generic types a declaration names.
Record_Stream_Form :: enum {
	Output, // system.Record_Output: a record output.
	Input, // system.Record_Input: a record input with no wiring terms.
	Input_With_Terms, // system.Record_Input_With_Terms: a record input with wiring terms.
}

// The name of each generic type in the support package system.
@(rodata)
record_stream_type_names := [Record_Stream_Form]string {
	.Output           = RECORD_OUTPUT_TYPE_NAME,
	.Input            = RECORD_INPUT_TYPE_NAME,
	.Input_With_Terms = RECORD_INPUT_WITH_TERMS_TYPE_NAME,
}

// One record output or one record input that a module declares: one row of
// the table Record_Outputs or Record_Inputs.
Record_Stream_Description :: struct {
	direction:    Record_Stream_Direction,
	name:         string, // The name of the package variable.
	about:        string, // One line of help: the first sentence of its comment.
	text:         string, // The documentation text: its comment, in its Markdown.
	generic:      bool, // Its record type is system.Any_Record: a wiring fixes it.
	record:       Record_Description, // Its record, when it is not generic.
	record_index: u32, // The index of the record in Module_Description.records, from 1; 0 for a generic one. record_streams_merge sets it.
	pairing:      module.Record_Output_Pairing, // A record output: Paired or not.
	wirings:      module.Wiring_Count, // A record input: its count of wirings.
	has_terms:    bool, // A record input with wiring terms.
	terms:        Record_Description, // The record of its wiring terms.
	terms_index:  u32, // The index of the terms in Module_Description.records, from 1; 0 for none.
	package_name: string, // The package of the module: with the name, the symbol of the variable in the linked file (record_stream_place_of_elf).
	file:         string, // Where the source declares it.
	line:         int,
}

@(private = "file")
record_stream_fail :: proc(path: string, line: int, format: string, args: ..any) -> bool {
	fmt.eprintf("modustool: record stream %s(%d): ", path, line)
	fmt.eprintfln(format, ..args)
	return false
}

// record_streams_of_sources gives the record outputs and the record inputs
// that the package in module_folder declares, in the order of the sources,
// read from sources: the sources that the compiler read for the module. A
// declaration of the two types in any other place of any source is refused.
// ok is false at the first refusal, which it prints.
record_streams_of_sources :: proc(module_folder: string, sources: []Fact_Source) -> (outputs, inputs: []Record_Stream_Description, ok: bool) {
	context.allocator = context.temp_allocator
	folder, _ := filepath.clean(module_folder)
	// The module package: one state for all its files, so that a record
	// type of one file serves a declaration of another.
	module_state: Describe_State
	module_state.records = make([dynamic]Record_Description)
	module_state.structs = make(map[string]Struct_Source)
	Parsed :: struct {
		file:      ^ast.File,
		state:     ^Describe_State,
		of_module: bool, // A file of the package of the module.
	}
	parsed := make([dynamic]Parsed)
	for item in sources {
		if strings.has_suffix(item.path, "_test.odin") {
			continue
		}
		if filepath.dir(item.path) == folder {
			file := parse_source(item.path, item.source, &module_state) or_return
			append(&parsed, Parsed{file = file, state = &module_state, of_module = true})
			continue
		}
		// A source of another package: only its form is read, with the
		// names of its own imports.
		if !strings.contains(item.source, RECORD_OUTPUT_TYPE_NAME) && !strings.contains(item.source, RECORD_INPUT_TYPE_NAME) {
			continue
		}
		state := new(Describe_State)
		state.records = make([dynamic]Record_Description)
		state.structs = make(map[string]Struct_Source)
		file := parse_source(item.path, item.source, state) or_return
		append(&parsed, Parsed{file = file, state = state, of_module = false})
	}
	found_outputs := make([dynamic]Record_Stream_Description)
	found_inputs := make([dynamic]Record_Stream_Description)
	for item in parsed {
		Walk :: struct {
			file:      ^ast.File,
			state:     ^Describe_State,
			of_module: bool,
			outputs:   ^[dynamic]Record_Stream_Description,
			inputs:    ^[dynamic]Record_Stream_Description,
			failed:    bool,
		}
		walked := Walk{file = item.file, state = item.state, of_module = item.of_module, outputs = &found_outputs, inputs = &found_inputs}
		visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			walk_state := (^Walk)(visitor.data)
			if node == nil || walk_state.failed {
				return nil
			}
			#partial switch found in node.derived {
			case ^ast.Value_Decl:
				if found.type == nil || !found.is_mutable || !walk_state.of_module || !declaration_at_package_scope(walk_state.file, found) {
					return visitor
				}
				call, form, is_stream := record_stream_call(walk_state.state, walk_state.file, found.type)
				if !is_stream {
					return visitor
				}
				for name_expression in found.names {
					name, is_name := name_expression.derived.(^ast.Ident)
					if !is_name {
						walk_state.failed = !record_stream_fail(walk_state.file.fullpath, found.pos.line, "a record stream has a name")
						return nil
					}
					stream, described := record_stream_describe(walk_state.state, walk_state.file, found, call, form, name.name)
					if !described {
						walk_state.failed = true
						return nil
					}
					append(form == .Output ? walk_state.outputs : walk_state.inputs, stream)
				}
				// The type of the declaration is read: its call is not a
				// misplaced declaration.
				return nil
			case ^ast.Pointer_Type:
				// A parameter that names a record stream by its address
				// declares none: the procedures of the library take one so.
				if _, _, is_stream := record_stream_call(walk_state.state, walk_state.file, found.elem); is_stream {
					return nil
				}
			case ^ast.Call_Expr:
				if form, is_stream := record_stream_call_form(walk_state.state, walk_state.file, found); is_stream {
					type_name := record_stream_type_names[form]
					walk_state.failed = !record_stream_fail(walk_state.file.fullpath, found.pos.line, "a %s that is not a package variable of the package of the module (%s): a local variable, a constant, a field of a record, a declaration inside a `when` or a variable of another package declares a stream that no row of the module names; declare it as `name: system.%s(Record)` at the top level of a file of the module", type_name, walk_state.of_module ? walk_state.file.pkg_name : "another package", type_name)
					return nil
				}
			}
			return visitor
		}
		walker := ast.Visitor{visit = visit, data = &walked}
		for declaration in item.file.decls {
			ast.walk(&walker, declaration)
			if walked.failed {
				return nil, nil, false
			}
		}
	}
	return found_outputs[:], found_inputs[:], true
}

// record_stream_call gives the call of a type `system.Record_Output(...)`,
// `system.Record_Input(...)` or `system.Record_Input_With_Terms(...)`:
// through an import of the support package system under any name, or by
// its own name in a file of that package. is_stream is false for another
// expression.
@(private = "file")
record_stream_call :: proc(state: ^Describe_State, file: ^ast.File, type: ^ast.Expr) -> (call: ^ast.Call_Expr, form: Record_Stream_Form, is_stream: bool) {
	if type == nil {
		return nil, {}, false
	}
	found, is_call := type.derived.(^ast.Call_Expr)
	if !is_call {
		return nil, {}, false
	}
	form, is_stream = record_stream_call_form(state, file, found)
	return found, form, is_stream
}

// record_stream_call_form says if a call is one of the three types, and
// which.
@(private = "file")
record_stream_call_form :: proc(state: ^Describe_State, file: ^ast.File, call: ^ast.Call_Expr) -> (form: Record_Stream_Form, is_stream: bool) {
	name, of_system := system_type_name(state, file, call.expr)
	if !of_system {
		return {}, false
	}
	for candidate in Record_Stream_Form {
		if record_stream_type_names[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// system_type_name gives the name of a type of the support package system:
// `system.Name` through an import of the package under any name, or `Name`
// in a file of that package. of_system is false for another expression.
@(private = "file")
system_type_name :: proc(state: ^Describe_State, file: ^ast.File, expression: ^ast.Expr) -> (name: string, of_system: bool) {
	#partial switch named in expression.derived {
	case ^ast.Selector_Expr:
		library, is_name := named.expr.derived.(^ast.Ident)
		if is_name && state.imports[library.name] == foundation.SYSTEM_LIBRARY_FOLDER {
			return named.field.name, true
		}
	case ^ast.Ident:
		if filepath.dir(file.fullpath) == foundation.SYSTEM_LIBRARY_FOLDER {
			return named.name, true
		}
	}
	return "", false
}

// record_stream_arguments gives the arguments of a call of one of the two
// types by the name of their parameter: by place, in the order of the
// parameters, or by name. ok is false for an argument past the parameters,
// a name that is no parameter, and a parameter given two times.
@(private = "file")
record_stream_arguments :: proc(call: ^ast.Call_Expr, parameters: []string) -> (arguments: map[string]^ast.Expr, ok: bool) {
	arguments = make(map[string]^ast.Expr, context.temp_allocator)
	for argument, place in call.args {
		parameter := ""
		value := argument
		if named, is_named := argument.derived.(^ast.Field_Value); is_named {
			field, is_field := named.field.derived.(^ast.Ident)
			if !is_field {
				return nil, false
			}
			parameter, value = field.name, named.value
		} else if place < len(parameters) {
			parameter = parameters[place]
		}
		if !slice.contains(parameters, parameter) || parameter in arguments {
			return nil, false
		}
		arguments[parameter] = value
	}
	return arguments, true
}

// record_stream_describe reads one declaration: its record, its pairing or
// its count and terms, and its comment, and checks each record.
@(private = "file")
record_stream_describe :: proc(state: ^Describe_State, file: ^ast.File, declaration: ^ast.Value_Decl, call: ^ast.Call_Expr, form: Record_Stream_Form, name: string) -> (stream: Record_Stream_Description, ok: bool) {
	path, line := file.fullpath, declaration.pos.line
	direction := form == .Output ? Record_Stream_Direction.Output : Record_Stream_Direction.Input
	stream = {direction = direction, name = name, package_name = file.pkg_name, file = path, line = line}
	stream.text = markdown_of(declaration.docs)
	stream.about = about_of(documentation_text_of_markdown(stream.text), name)
	// The parameters of each type, in their order.
	output_parameters := [?]string{RECORD_STREAM_RECORD_PARAMETER, RECORD_OUTPUT_PAIRING_PARAMETER}
	input_parameters := [?]string{RECORD_STREAM_RECORD_PARAMETER, RECORD_INPUT_WIRINGS_PARAMETER}
	terms_parameters := [?]string{RECORD_STREAM_RECORD_PARAMETER, RECORD_INPUT_TERMS_PARAMETER, RECORD_INPUT_WIRINGS_PARAMETER}
	parameters: []string
	switch form {
	case .Output:
		parameters = output_parameters[:]
	case .Input:
		parameters = input_parameters[:]
	case .Input_With_Terms:
		parameters = terms_parameters[:]
	}
	type_name := record_stream_type_names[form]
	arguments, arguments_ok := record_stream_arguments(call, parameters)
	if !arguments_ok {
		parameter_list, _ := strings.join(parameters, ", ", context.temp_allocator)
		return {}, record_stream_fail(path, line, "%s: system.%s takes %s, by place or by name", name, type_name, parameter_list)
	}
	record_expression, has_record := arguments[RECORD_STREAM_RECORD_PARAMETER]
	if !has_record {
		return {}, record_stream_fail(path, line, "%s: system.%s names its record type first", name, type_name)
	}
	if type_name_of_record, is_system := system_type_name(state, file, record_expression); is_system && type_name_of_record == ANY_RECORD_TYPE_NAME {
		stream.generic = true
	} else {
		stream.record = record_stream_record(state, path, line, name, record_expression, "record") or_return
	}
	switch direction {
	case .Output:
		if expression, given := arguments[RECORD_OUTPUT_PAIRING_PARAMETER]; given {
			stream.pairing = record_stream_member(module.Record_Output_Pairing, expression, path, line, name) or_return
		}
		if stream.pairing == .Paired && !stream.generic {
			return {}, record_stream_fail(path, line, "%s: Paired on a record output of the record %s: Paired gives one ring for each wiring of the generic record input, of the type of that wiring, and a record output with a record has one type; declare it system.Record_Output(system.Any_Record, .Paired)", name, stream.record.name)
		}
	case .Input:
		if expression, given := arguments[RECORD_INPUT_WIRINGS_PARAMETER]; given {
			stream.wirings = record_stream_member(module.Wiring_Count, expression, path, line, name) or_return
		}
		if stream.wirings == .Many_Types && !stream.generic {
			return {}, record_stream_fail(path, line, "%s: Many_Types on a record input of the record %s: each wiring of Many_Types keeps its own type, and a record input with a record has one; write .Many, or declare it system.Record_Input(system.Any_Record, .Many_Types)", name, stream.record.name)
		}
		if form == .Input_With_Terms {
			terms_expression, given := arguments[RECORD_INPUT_TERMS_PARAMETER]
			if !given {
				return {}, record_stream_fail(path, line, "%s: system.%s names the record type of its wiring terms second; a record input with no terms is system.%s", name, type_name, RECORD_INPUT_TYPE_NAME)
			}
			if terms_name, is_system := system_type_name(state, file, terms_expression); is_system && terms_name == ANY_RECORD_TYPE_NAME {
				return {}, record_stream_fail(path, line, "%s: the wiring terms are system.Any_Record: the reader checks the terms against their description, so the terms have a record type", name)
			}
			stream.terms = record_stream_record(state, path, line, name, terms_expression, "terms") or_return
			stream.has_terms = true
		}
	}
	return stream, true
}

// record_stream_member reads an argument `.Member` of an enum of the
// contract.
@(private = "file")
record_stream_member :: proc($Enum: typeid, expression: ^ast.Expr, path: string, line: int, name: string) -> (member: Enum, ok: bool) {
	selector, is_selector := expression.derived.(^ast.Implicit_Selector_Expr)
	if is_selector {
		if value, known := reflect.enum_from_name(Enum, selector.field.name); known {
			return value, true
		}
	}
	return {}, record_stream_fail(path, line, "%s: write a member of %v as .Member: %v", name, typeid_of(Enum), reflect.enum_field_names(Enum))
}

// record_stream_record describes the record of a declaration, or its
// terms (what), and checks it: a record type that the tool knows, with no
// Handle field and no byte that no field names.
@(private = "file")
record_stream_record :: proc(state: ^Describe_State, path: string, line: int, name: string, expression: ^ast.Expr, what: string) -> (record: Record_Description, ok: bool) {
	// A record that struct_record refuses printed its refusal.
	number, is_record, record_ok := struct_record(state, expression, false)
	if !is_record {
		return {}, record_stream_fail(path, line, "%s: the %s type is not a record type of the package or of a package of the library that the file imports", name, what)
	}
	if !record_ok {
		return {}, false
	}
	record = state.records[number - 1]
	if problem := record_stream_record_problem(record); problem != "" {
		return {}, record_stream_fail(path, line, "%s: the %s %s: %s", name, what, record.name, problem)
	}
	return record, true
}

// record_stream_record_problem gives why the record of a record stream is
// refused, or "": a Handle field, a field of a type that a record does not
// hold, or padding.
record_stream_record_problem :: proc(record: Record_Description) -> string {
	for item in record.fields {
		switch item.type {
		case .Integer, .Text, .Bytes:
		case .Handle:
			return fmt.tprintf("the field %s is a Handle: a handle number in memory that another process reads names nothing there; a handle crosses a border through Handle_Give only", item.name)
		case .None, .Record, .Table:
			return fmt.tprintf("the field %s has a type that a record does not hold", item.name)
		}
	}
	return record_padding_problem(record)
}

// record_streams_merge adds the record outputs and the record inputs of a
// module to its description: the record of each one in the records, where
// an equal description takes the same index, and the rows sorted by name.
// It refuses each rule of the whole tables, printed with the place of the
// declaration.
record_streams_merge :: proc(description: ^Module_Description, outputs, inputs: []Record_Stream_Description) -> bool {
	if problem, at := record_streams_problem(outputs, inputs); problem != "" {
		return record_stream_fail(at.file, at.line, "%s", problem)
	}
	records := make([dynamic]Record_Description, context.temp_allocator)
	append(&records, ..description.records)
	merged_outputs := make([dynamic]Record_Stream_Description, context.temp_allocator)
	merged_inputs := make([dynamic]Record_Stream_Description, context.temp_allocator)
	for list, direction in ([2][]Record_Stream_Description{outputs, inputs}) {
		for stream in list {
			item := stream
			if !item.generic {
				index, added := record_description_add(&records, item.record)
				if !added {
					return record_stream_fail(item.file, item.line, "%s: the record %s has another description than the record %s that the module describes already: one module describes a record name one way", item.name, item.record.name, item.record.name)
				}
				item.record_index = index
			}
			if item.has_terms {
				index, added := record_description_add(&records, item.terms)
				if !added {
					return record_stream_fail(item.file, item.line, "%s: the terms %s have another description than the record %s that the module describes already: one module describes a record name one way", item.name, item.terms.name, item.terms.name)
				}
				item.terms_index = index
			}
			append(direction == 0 ? &merged_outputs : &merged_inputs, item)
		}
	}
	by_name :: proc(a, b: Record_Stream_Description) -> bool {return a.name < b.name}
	slice.sort_by(merged_outputs[:], by_name)
	slice.sort_by(merged_inputs[:], by_name)
	description.records = records[:]
	description.record_outputs = merged_outputs[:]
	description.record_inputs = merged_inputs[:]
	return true
}

// record_streams_problem gives why the record outputs and the record
// inputs of a module break a rule of the whole tables, and the declaration
// that breaks it, or "": the count of each, one name in two declarations,
// and a generic record output with no generic record input or with two.
record_streams_problem :: proc(outputs, inputs: []Record_Stream_Description) -> (problem: string, at: Record_Stream_Description) {
	if len(outputs) > module.RECORD_STREAM_INDEX_MOST {
		return fmt.tprintf("the module declares %d record outputs; a module declares at most %d, as each loader checks the place of each one against each other write of its load", len(outputs), module.RECORD_STREAM_INDEX_MOST), outputs[module.RECORD_STREAM_INDEX_MOST]
	}
	if len(inputs) > module.RECORD_STREAM_INDEX_MOST {
		return fmt.tprintf("the module declares %d record inputs; a module declares at most %d, as each loader checks the place of each one against each other write of its load", len(inputs), module.RECORD_STREAM_INDEX_MOST), inputs[module.RECORD_STREAM_INDEX_MOST]
	}
	// One name for one stream of the module, among both: the console
	// names each as `module.name`. A map keeps the work in proportion to
	// the declarations.
	seen := make(map[string]Record_Stream_Description, context.temp_allocator)
	for list in ([2][]Record_Stream_Description{outputs, inputs}) {
		for item in list {
			if other, taken := seen[item.name]; taken {
				return fmt.tprintf("two record streams of the module have the name %s (%s(%d)): `module.%s` names one stream", item.name, other.file, other.line, item.name), item
			}
			seen[item.name] = item
		}
	}
	generic_inputs := 0
	for item in inputs {
		if item.generic {
			generic_inputs += 1
		}
	}
	for item in outputs {
		if item.generic && generic_inputs != 1 {
			return fmt.tprintf("%s is a generic record output, and the module declares %d generic record inputs: a generic record output takes the type of the one generic record input of its module", item.name, generic_inputs), item
		}
	}
	return "", {}
}
