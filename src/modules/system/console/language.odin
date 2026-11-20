package console

import "modus:contract/errors"
import module "modus:contract/module"
import "modus:private/console/console_condition"
import "modus:private/console/console_language"
import "modus:private/console/console_stream"
import "modus:private/console/lex_evaluator"
import "modus:private/console/lex_parser"
import "modus:support/sentence"
import "modus:support/system"

// The console as the evaluation host of Lex in mode `console`.
//
// The parser of Lex (src/library/private/console/lex_parser) gives the
// syntax tree of a line, and the evaluator
// (src/library/private/console/lex_evaluator) forces it whole, from the
// left: the calls before a fault run, then the line fails. This file gives
// the evaluator the names, the commands and the runs of the calls, and
// writes the sentence of each refusal. The form of each parameter of a
// command (Parameter_Form) says which argument the parser reads there: an
// expression, a condition on a field of the table of the first argument
// (`where(t, block = 12)`), the name of a fact type
// (`facts(t, storage.Bad_Block)`), or the names of fields
// (`columns(t, name, slot)`). In a condition, a name is a field and, after
// the operator of a status field, a member of its enum: never a variable.
//
// The pipe operator has the lowest priority: `a |> f(b)` is `f(a, b)`, and
// `a |> f` is `f(a)`. The parser reads no "|>": before any call,
// pipe_nested_line writes the line with calls in calls
// (src/library/private/console/console_language/pipe.odin), so a line with
// "|>" checks and runs as that line.
//
// A value is an Integer, a Text, a Record, a Handle, a Table or Bytes. An
// operation on two Integers whose result does not fit in 64 bits with a
// sign is an error of the line: no result wraps. "+" joins two Texts. A Record has the description of a record of a module: the
// command with the name of the record makes one from its fields, and
// `variable.field` reads one field. A Handle names an object of the kernel
// that the console holds. A Table is records of one description, one after
// the other: a Table result gives one, and the commands of tables.odin
// combine them. Bytes are bytes with no description: a command gives them,
// and the console draws them; no variable keeps them. A Stream is a record
// output of a process, by its typed name `owner.output`: the line wires it
// when a command reads it, and ends the wiring when the line ends
// (streams.odin); no variable keeps it either.
//
// A line has one result: the value of its expression, or its failure. No
// command writes to the terminal: the console draws the result of the line
// by its kind (results.odin).

// The kinds and the values of Lex are those of the evaluator. A value of a
// condition points into line_conditions, and a Stream names its place in
// line_streams.
Kind :: lex_evaluator.Kind
Value :: lex_evaluator.Value

// The conditions of the line that runs. A value names one by its address,
// so that a value stays small: a call keeps 12 of them on the stack.
line_conditions: console_condition.Condition_List

// What the parser reads for a parameter of a command: an expression, the
// name of a fact type (a Text value with the name), a condition, or the
// names of fields (a Text value with the names).
Parameter_Form :: lex_parser.Parameter_Form

// A condition on one field of the rows of a table: `block = 12`,
// `level = Warning`, `name != "console"`. The package console_condition
// reads it, checks it and compares the values, with host tests.
Condition :: console_condition.Condition

// kind_of_type gives the kind of a type of the module contract.
kind_of_type :: proc "contextless" (type: module.Type) -> (kind: Kind) {
	switch type {
	case .None:
		kind = .None
	case .Integer:
		kind = .Integer
	case .Text:
		kind = .Text
	case .Record:
		kind = .Record
	case .Handle:
		kind = .Handle
	case .Table:
		kind = .Table
	case .Bytes:
		kind = .Bytes
	case .Enum:
		kind = .Enum
	}
	return kind
}

// type_of_kind gives the type of the module contract of a kind.
type_of_kind :: proc "contextless" (kind: Kind) -> (type: module.Type) {
	switch kind {
	case .None:
		type = .None
	case .Integer:
		type = .Integer
	case .Text:
		type = .Text
	case .Record:
		type = .Record
	case .Handle:
		type = .Handle
	case .Table:
		type = .Table
	case .Bytes:
		type = .Bytes
	case .Enum:
		type = .Enum
	case .Stream, .Record_Input, .Record_Literal, .Member:
		// No type of the module contract: no export takes one, and
		// type_text names it itself.
		type = .None
	}
	return type
}

// kind_of_type_word is the border of a byte of a type of a module file
// (module.type_of_word), as a kind of the console: false for a byte that
// names no type.
kind_of_type_word :: proc "contextless" (word: u8) -> (kind: Kind, ok: bool) {
	type := module.type_of_word(word) or_return
	return kind_of_type(type), true
}

@(rodata)
kind_names := [Kind]string {
	.None           = "None",
	.Integer        = "Integer",
	.Text           = "Text",
	.Record         = "Record",
	.Handle         = "Handle",
	.Table          = "Table",
	.Bytes          = "Bytes",
	.Stream         = "Stream",
	.Record_Input   = "Record_Input",
	.Record_Literal = "a record literal",
	.Enum           = "Enum",
	.Member         = "a member",
}

// type_text gives the name of a type: "Integer", the name of a record or of
// an enum, "Handle(Read)", or "Stream(Counted)". The text lasts for one
// line.
type_text :: proc "contextless" (file: []u8, kind: Kind, detail: u32) -> string {
	if kind == .None || kind == .Record_Literal || kind == .Member {
		return kind_names[kind]
	}
	if kind == .Stream || kind == .Record_Input {
		described, _ := module.record_type(file, detail)
		return scratch_text(kind_names[kind], "(", module.string_at(file, described.name_offset, described.name_count), ")")
	}
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	system.write_type(&writer, file, type_of_kind(kind), detail)
	scratch_count += writer.count
	return system.written(&writer)
}

// type_text_of_word gives the name of the type of a byte of a module file,
// as type_text: "?" for a byte that names no type.
type_text_of_word :: proc "contextless" (file: []u8, word: u8, detail: u32) -> string {
	kind, kind_ok := kind_of_type_word(word)
	if !kind_ok {
		return "?"
	}
	return type_text(file, kind, detail)
}

// parameter_text gives the type of a parameter of a command, with the
// direction of a Table or Bytes: "Table(Reading, Change)".
parameter_text :: proc "contextless" (item: ^Command, index: int) -> string {
	// The kinds of the console only have no type of the module contract.
	if item.parameters[index] == .Stream || item.parameters[index] == .Record_Input {
		return kind_names[item.parameters[index]]
	}
	writer := system.Writer {
		buffer = scratch[scratch_count:],
	}
	system.write_parameter_type(&writer, item.file, type_of_kind(item.parameters[index]), item.function.parameter_details[index], item.function.parameter_directions[index])
	scratch_count += writer.count
	return system.written(&writer)
}

// scratch_bytes gives zero bytes for a record, for one line.
scratch_bytes :: proc "contextless" (size: int) -> []u8 {
	start := (scratch_count + 7) &~ 7
	if size > len(scratch) - start {
		return nil
	}
	scratch_count = start + size
	bytes := scratch[start:scratch_count]
	for &b in bytes {
		b = 0
	}
	return bytes
}

// field_value gives one field of a Record value, by name: the reader of
// the evaluator, which `binding.field` of a let reads too.
field_value :: lex_evaluator.record_field_value

VARIABLE_CAPACITY :: 16
VARIABLE_NAME_SIZE :: 16
VARIABLE_TEXT_SIZE :: 96
ARGUMENT_CAPACITY :: module.PARAMETER_CAPACITY // The arguments of a call: those of an export at most.

Variable :: struct {
	name:        [VARIABLE_NAME_SIZE]u8,
	name_count:  int, // 0: the slot is free.
	value:       Value,
	text:        [VARIABLE_TEXT_SIZE]u8,
	record:      [module.RECORD_SIZE_LIMIT / 8]u64,
	table:       [TABLE_KEPT / 8]u64, // The records of a Table.
	description: [DESCRIPTION_SIZE / 8]u64, // A description that join or columns made: it is in the memory of the line.
}

variables: [VARIABLE_CAPACITY]Variable

// The memory of the Text values of one line.
scratch: [4096]u8
scratch_count: int

failed: bool

// The nested form of the line that runs, and the stages of its "|>". A
// Text value of the line is a part of its nested form, so the nested form
// lives until the next line.
NESTED_LINE_SIZE :: 1024 // A nested form is never longer than its line: a line of the history has 256 bytes at most.
nested_line: [NESTED_LINE_SIZE]u8
line_stages: [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage

// The syntax tree of the nested form of the line that runs. Its names and
// its texts are parts of the nested form.
line_tree: lex_parser.Syntax_Tree

// The evaluation of the tree of the line that runs: its thunks keep values
// whose texts are parts of the nested form and of scratch, for one line.
line_evaluation: lex_evaluator.Evaluation

// console_host gives the console as the evaluation host. Each procedure
// that fails the line gives ok false, and the evaluator stops.
console_host :: proc "contextless" () -> lex_evaluator.Evaluation_Host {
	return {
		name_value = host_name_value,
		command_find = host_command_find,
		call_run = host_call_run,
		condition_value = host_condition_value,
		fact_name_value = host_fact_name_value,
		values_add = host_values_add,
		record_memory = host_record_memory,
	}
}

scratch_text :: proc "contextless" (parts: ..system.Part) -> string {
	text := system.format(scratch[scratch_count:], ..parts)
	scratch_count += len(text)
	return text
}

// parameter_form_of gives the parser the form of a parameter of a command:
// the forms of the command that a call of the name runs, as the call reads
// them when the line runs.
parameter_form_of :: proc "contextless" (data: rawptr, command_name: string, index: int) -> lex_parser.Parameter_Form {
	found := command_find(command_name)
	if found == nil || index < 0 || index >= len(found.parameter_forms) {
		return .Expression
	}
	return found.parameter_forms[index]
}

// run_line runs one line: it evaluates the expression, shows the log
// records of what the line called, then draws the one result of the line:
// its failure, or the value of an expression. A line that keeps its value
// in a variable draws nothing.
run_line :: proc "contextless" (text: string) {
	failed, scratch_count, table_used, line_conditions.count, line_stream_count = false, 0, 0, 0, 0
	failure_reset()
	line_records_start()

	// A fault of "|>" fails the line here, before any call runs.
	nested := pipe_nested_line(text)
	name: string
	assigned := false
	value: Value
	if !failed {
		lex_parser.parse(nested, {form_of = parameter_form_of}, &line_tree)
		name = line_tree.assigned_name
		assigned = len(name) > 0
		value = line_evaluate()
	}
	line_records_show()
	if !failed && assigned {
		assign(name, value)
	}
	line_value = assigned ? Value{} : value
	// A Stream is drawn one row at a time as each record comes, until its
	// end or Escape: its draw reads it, and can fail.
	// A record input has no record to draw: stream_draw says so.
	typed := value.kind == .Stream || value.kind == .Record_Input
	if !failed && !assigned && typed {
		stream_draw(value)
	}
	// Each Stream that the line wired ends with the line.
	line_streams_end()
	if failed {
		failure_draw()
		return
	}
	if !assigned && !typed {
		value_draw(value)
	}
}

assign :: proc "contextless" (name: string, value: Value) {
	if value.kind == .None {
		fail("the expression has no value")
		return
	}
	if value.kind == .Bytes {
		fail("a variable keeps no Bytes value")
		return
	}
	if value.kind == .Stream {
		fail(console_stream.VARIABLE_REFUSAL)
		return
	}
	if value.kind == .Record_Input {
		fail("a variable keeps no Record_Input: a typed name lives in its line, where wire(from, to) names it")
		return
	}
	if len(name) > VARIABLE_NAME_SIZE || len(value.text) > VARIABLE_TEXT_SIZE {
		fail("the name or the text is too long")
		return
	}
	if value.kind == .Table && len(value.record) > TABLE_KEPT || in_table_memory(value.file) && len(value.file) > DESCRIPTION_SIZE {
		fail("a variable keeps a table of ", i64(TABLE_KEPT), " bytes at most; this one has ", i64(len(value.record)))
		return
	}
	slot: ^Variable
	for &variable in variables {
		if string(variable.name[:variable.name_count]) == name {
			slot = &variable
			break
		}
		if variable.name_count == 0 && slot == nil {
			slot = &variable
		}
	}
	if slot == nil {
		fail("no room for a variable")
		return
	}
	slot.name_count = copy(slot.name[:], name)
	slot.value = value
	switch value.kind {
	case .None, .Integer, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member:
		// The value holds no memory of the line: the slot keeps it as it is.
		// A Bytes value and a Stream were refused above; the evaluator
		// refuses a literal and a member that nothing typed. An Enum names
		// the module file of its enum, which stays while the module does.
	case .Text:
		count := copy(slot.text[:], value.text)
		slot.value.text = string(slot.text[:count])
	case .Record:
		bytes := ([^]u8)(&slot.record)[:len(value.record)]
		copy(bytes, value.record)
		slot.value.record = bytes
	case .Table:
		bytes := ([^]u8)(&slot.table)[:len(value.record)]
		copy(bytes, value.record)
		slot.value.record = bytes
	}
	// The description that join or columns made lives for one line.
	if in_table_memory(value.file) {
		bytes := ([^]u8)(&slot.description)[:len(value.file)]
		copy(bytes, value.file)
		slot.value.file = bytes
	}
}

// line_evaluate forces the tree of the line whole, in mode `console`, then
// writes the sentence of the refusal of the evaluator, if any. A refusal of
// the host has written its own.
line_evaluate :: proc "contextless" () -> Value {
	lex_evaluator.evaluation_start(&line_evaluation, &line_tree, .Console, console_host())
	value, ok := lex_evaluator.line_force(&line_evaluation)
	if !ok {
		evaluation_refusal_fail(line_evaluation.refusal)
		return {}
	}
	return value
}

// evaluation_refusal_fail fails the line with the sentence of a refusal of
// the evaluator.
evaluation_refusal_fail :: proc "contextless" (record: lex_evaluator.Refusal_Record) {
	operator := lex_parser.OPERATOR_TEXTS[record.operator]
	switch record.refusal {
	case .None, .Host_Refused:
		// The host wrote the failure of the line.
	case .Text:
		text_refusal_fail(record)
	case .Operator_Kinds:
		fail("\"", operator, "\" does not take ", kind_names[record.left_kind], " and ", kind_names[record.right_kind])
	case .Negate_Kind:
		fail("\"-\" does not take ", kind_names[record.left_kind])
	case .Overflow:
		fail_overflow(operator, record.left, record.right)
	case .Division_By_Zero:
		fail("division by zero")
	case .Budget_Exceeded:
		already := failed
		fail("the line needs more than ", i64(record.steps), " steps of the evaluator: it stopped at column ", i64(record.place.column))
		if !already {
			failure_record_set(errors.error_make(.Over_Limit, .None, 0, i64(record.steps) + 1, i64(record.steps)), "the evaluation", nil)
		}
	case .Effect_Refused:
		fail(record.command, " has an effect, and an evaluation in mode declaration runs none")
	case .Literal_No_Type:
		if record.parameter == 0 {
			fail("a record literal takes the type of the parameter that receives it, and nothing receives this one")
		} else {
			fail(record.command, ": argument ", i64(record.parameter), " is ", kind_names[record.right_kind], ", not a record literal: a literal takes the type of a parameter Record")
		}
	case .Literal_Field_Unknown:
		described, _ := module.record_type(record.file, record.detail)
		fail(record_name(record.file, record.detail), " has no field ", record.field, "; its fields are ", field_names(Table{file = record.file, record = described}))
	case .Literal_Field_Missing:
		fail(record_name(record.file, record.detail), " needs the field ", record.field, ", which has no default")
	case .Literal_Field_Kind:
		fail(record_name(record.file, record.detail), ": the field ", record.field, " is ", type_text_of_field(record.file, record.field_item), ", the value is ", kind_names[record.left_kind])
	case .Literal_Field_Range:
		if record.field_item.type == u8(module.Type.Text) {
			fail(record_name(record.file, record.detail), ": the field ", record.field, " holds ", i64(record.field_item.detail), " bytes, the text has ", record.right)
		} else {
			fail(record_name(record.file, record.detail), ": the field ", record.field, " is ", type_text_of_field(record.file, record.field_item), ", it does not hold ", record.left)
		}
	case .Argument_Unknown:
		fail(record.command, " has no parameter ", record.field, "; ", parameter_names_text(record.command))
	case .Argument_Twice:
		fail(record.command, ": the parameter ", record.field, " is given twice")
	case .Argument_Missing:
		fail(record.command, " needs the parameter ", record.field, ", which has no default")
	case .With_Kinds:
		fail("\"with\" composes a record with a record literal or a record, not ", kind_names[record.left_kind], " with ", kind_names[record.right_kind])
	case .With_Records_Differ:
		fail("\"with\": ", record_name(record.file, record.detail), " and ", record_name(record.other_file, record.other_detail), " are two records")
	case .Field_Unknown:
		switch {
		case record.file != nil:
			fail(record_name(record.file, record.detail), " has no field ", record.field)
		case record.left_kind == .Record_Literal:
			fail("the record literal has no field ", record.field)
		case:
			fail(kind_names[record.left_kind], " has no field ", record.field)
		}
	case .Cycle:
		fail("the binding ", record.command, " needs its own value: a let cannot read a binding in its own value")
	case .Member_No_Type:
		if record.parameter == 0 {
			fail("a member takes the enum of the parameter that receives it, and nothing receives this one")
		} else {
			fail(record.command, ": argument ", i64(record.parameter), " is ", kind_names[record.right_kind], ", not a member: a member takes the enum of a parameter Enum")
		}
	case .Member_Unknown:
		described, _ := module.enum_type(record.file, record.detail)
		fail(record.command, ": ", module.enum_name(record.file, described), " has no member .", record.field, "; its members are ", enum_members_text(record.file, record.detail))
	}
}

// enum_members_text gives the members of an enum as a line names them:
// ".united_states, .french". The text lasts for one line.
enum_members_text :: proc "contextless" (file: []u8, enum_index: u32) -> string {
	described, problem := module.enum_type(file, enum_index)
	if problem != .None {
		return "none that the module file describes"
	}
	start := scratch_count
	for number in 0 ..< described.member_count {
		member, _ := module.enum_member(file, described, number)
		scratch_text(number == 0 ? "." : ", .", module.string_at(file, member.name_offset, member.name_count))
	}
	return string(scratch[start:scratch_count])
}

// record_name gives the name of a record of a module.
record_name :: proc "contextless" (file: []u8, detail: u32) -> string {
	described, _ := module.record_type(file, detail)
	return module.string_at(file, described.name_offset, described.name_count)
}

// parameter_names_text says the names of the parameters of a command, for
// a named argument that names none of them.
parameter_names_text :: proc "contextless" (command_name: string) -> string {
	found := command_find(command_name)
	if found == nil {
		return "it has no parameters"
	}
	start := scratch_count
	written := 0
	for name in found.parameter_names[:clamp(found.parameter_count, 0, ARGUMENT_CAPACITY)] {
		if name == "" {
			continue
		}
		scratch_text(written == 0 ? "its parameters are " : ", ", name)
		written += 1
	}
	if written == 0 {
		return "its parameters have no names"
	}
	return string(scratch[start:scratch_count])
}

// text_refusal_fail fails the line with the sentence of a refusal of the
// parser, which the evaluator met in its place.
text_refusal_fail :: proc "contextless" (record: lex_evaluator.Refusal_Record) {
	rest := line_tree.text[min(int(record.place.offset), len(line_tree.text)):]
	switch record.text_refusal {
	case .Line_Ends_Too_Soon:
		fail("the line ends too soon")
	case .Number_Too_Large:
		// The record: the limit is the largest Integer; the sentence has
		// the digits, which no Integer holds.
		already := failed
		fail("the number ", lex_parser.node_text(&line_tree, record.node), " does not fit in an Integer: the largest is ", i64(console_language.INTEGER_MOST))
		if !already {
			failure_record_set(errors.error_make(.Over_Limit, .None, 0, 0, console_language.INTEGER_MOST), "a number", nil)
		}
	case .Text_Without_End_Quote:
		fail("the text has no end quote")
	case .Close_Parenthesis_Missing:
		fail("\")\" is missing")
	case .Comma_Or_Close_Missing:
		fail("\",\" or \")\" is missing")
	case .Too_Many_Arguments:
		fail("too many arguments")
	case .Text_Too_Long:
		fail("the line has more than ", i64(lex_parser.TEXT_BYTES_MOST), " bytes")
	case .Nodes_Full:
		fail("the line has more parts than the console reads: ", i64(lex_parser.NODE_CAPACITY))
	case .Field_Name_Missing:
		fail(record.command, ": the name of a field comes here, as ", record.command, "(t, name, slot)")
	case .Literal_Close_Missing:
		fail("\",\" or \"}\" is missing")
	case .Literal_Name_Missing:
		fail("a record literal holds fields, each a name, \"=\" and a value: {x = 1, y = 2}")
	case .Literal_Equal_Missing:
		fail("\"=\" is missing after the name of a field")
	case .Literal_Field_Twice:
		fail("the field ", lex_parser.node_text(&line_tree, record.node), " is given twice in one record literal")
	case .Named_Argument_Twice:
		fail("the parameter ", lex_parser.node_text(&line_tree, record.node), " is named twice in one call")
	case .Positional_After_Named:
		fail("an argument with no name comes after a named one: the arguments with no name come first")
	case .Let_Name_Missing:
		fail("let takes bindings, each a name, \"=\" and a value, then in: let a = 1 in a + 1")
	case .Let_Equal_Missing:
		fail("\"=\" is missing after the name of a binding")
	case .Let_In_Missing:
		fail("\",\" or \"in\" is missing after a binding of let")
	case .Let_Name_Twice:
		fail("the name ", lex_parser.node_text(&line_tree, record.node), " is bound twice in one let")
	case .Word_As_Name:
		word := lex_parser.node_text(&line_tree, record.node)
		if word == "_" {
			fail("_ is no name: it is the place of the value on the left of |>, in the call on its right")
		} else {
			fail(word, " is a word of Lex, not a name")
		}
	case .Unexpected, .None, .Fact_Name_Missing, .Condition_Head_Refused:
		// A Fact_Name or a Condition node holds the last two, and the
		// console reads them itself.
		fail("unexpected \"", rest, "\"")
	}
}

// ---- The procedures of the evaluation host.

host_name_value :: proc "contextless" (data: rawptr, name: string) -> (value: Value, ok: bool) {
	value = name_evaluate(name)
	return value, !failed
}

// host_command_find fails the line for a name that no command has, before
// the arguments of the call, and gives the signature of a command: the
// names of its parameters, their kinds, and the description of each Record
// parameter of an export. Each command of the console has an effect: the
// names of the evaluation, which have none, are not built.
host_command_find :: proc "contextless" (data: rawptr, name: string) -> (signature: lex_evaluator.Command_Signature, found: bool) {
	item := command_find(name)
	if item == nil {
		fail("no command has the name ", name, "; try help()")
		return {}, false
	}
	signature.has_effect = true
	signature.parameter_count = clamp(item.parameter_count, 0, ARGUMENT_CAPACITY)
	signature.optional_last = item.optional_last
	for index in 0 ..< signature.parameter_count {
		signature.names[index] = item.parameter_names[index]
		signature.kinds[index] = item.parameters[index]
		// An export describes the record of a parameter; a command of the
		// console and a command that makes a record take no record.
		if item.parameters[index] == .Record && item.run == nil && item.record == 0 {
			signature.files[index], signature.details[index] = item.file, item.function.parameter_details[index]
		}
		// An Enum parameter: its enum names the members that a line gives
		// it, and an optional one may be left out.
		if item.parameters[index] == .Enum {
			enum_index, _ := module.enum_detail_of(item.function.parameter_details[index])
			signature.files[index], signature.details[index] = item.file, enum_index
			signature.optional[index] = module.parameter_optional(item.function, index)
		}
	}
	return signature, true
}

// host_record_memory gives zero bytes for a record that a literal makes, in
// the memory of the line.
host_record_memory :: proc "contextless" (data: rawptr, size: int) -> (bytes: []u8, ok: bool) {
	bytes = scratch_bytes(size)
	if bytes == nil && size != 0 {
		fail("the line has too many records")
		return nil, false
	}
	return bytes, true
}

host_call_run :: proc "contextless" (data: rawptr, name: string, arguments: []Value) -> (value: Value, ok: bool) {
	value = call_run(name, arguments)
	return value, !failed
}

host_condition_value :: proc "contextless" (data: rawptr, evaluation: ^lex_evaluator.Evaluation, command_name: string, before: []Value, node: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	value = condition_evaluate(command_name, before, node)
	return value, !failed && !lex_evaluator.refused(evaluation)
}

host_fact_name_value :: proc "contextless" (data: rawptr, evaluation: ^lex_evaluator.Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	value = fact_name_evaluate(command_name, node)
	return value, !failed
}

// host_values_add gives "+" of two values of one kind that the evaluator
// leaves to the console: two Texts join, and two Tables of one record
// description give the rows of both, a general operation of tables
// (src/md/features/module_outputs.md, "The wiring list of a start").
host_values_add :: proc "contextless" (data: rawptr, left, right: Value) -> (sum: Value, ok: bool) {
	if left.kind == .Table {
		sum = table_sum_value(left, right)
		return sum, !failed
	}
	return {kind = .Text, text = scratch_text(left.text, right.text)}, true
}

// name_evaluate gives the value of a name alone: a variable, or one field
// of a Record variable.
name_evaluate :: proc "contextless" (name: string) -> Value {
	for &variable in variables {
		if string(variable.name[:variable.name_count]) == name {
			return variable.value
		}
	}
	for &command in commands[:command_count] {
		if command.name == name {
			return fail(name, " is a command: write ", name, "(...)")
		}
	}
	// variable.field: one field of a Record.
	for split := len(name) - 1; split > 0; split -= 1 {
		if name[split] != '.' {
			continue
		}
		for &variable in variables {
			if string(variable.name[:variable.name_count]) == name[:split] && variable.value.kind == .Record {
				if value, found := field_value(variable.value, name[split + 1:]); found {
					return value
				}
				return fail(type_text(variable.value.file, .Record, variable.value.detail), " has no field ", name[split + 1:])
			}
		}
		break
	}
	// owner.stream: a record output of a process that the console started
	// or of a service that it connected.
	if value, named := stream_value_of_name(name); named {
		return value
	}
	return fail("no variable has the name ", name)
}

// command_find gives the command that a call of a name runs: of two
// commands with one name, the one added last. nil: no command has it.
command_find :: proc "contextless" (name: string) -> (found: ^Command) {
	for &command in commands[:command_count] {
		if command.name == name {
			found = &command
		}
	}
	return found
}

// argument_accepted says if the parameter index of a command takes a value:
// the check of a call before it runs, and of the value on the left of a
// "|>" when the console knows it before the run.
argument_accepted :: proc "contextless" (found: ^Command, index: int, argument: Value) -> bool {
	// A fact name and a condition are read by the parser, and their
	// evaluation checked them against the image and against the table: no
	// value comes there.
	if found.parameter_forms[index] != .Expression {
		return true
	}
	kind := found.parameters[index]
	// A parameter None of a command of the console takes any value.
	if kind == .None && found.run != nil {
		return true
	}
	// A Table parameter of a command that reads each row as it comes takes
	// a Stream too: where, first, table.
	if kind == .Table && argument.kind == .Stream {
		return found.takes_stream
	}
	// A table parameter takes a Table value of an equal record; Bytes
	// take a Text, or the Bytes of a memory object that bytes() read: the
	// call copies either one. The direction says what the export does with
	// it.
	if kind == .Bytes {
		return argument.kind == .Text || argument.kind == .Bytes
	}
	if argument.kind != kind {
		return false
	}
	// An Enum agrees when the two enums are one description: a member of
	// another enum with the same value is no member of this one.
	if kind == .Enum {
		enum_index, _ := module.enum_detail_of(found.function.parameter_details[index])
		return module.enums_equal(found.file, enum_index, argument.file, argument.detail)
	}
	// A Record agrees when the two descriptions are equal: a record of one
	// module is a record of another module with the same fields. A command
	// of the console (run) takes a Table of any record.
	if kind == .Record || kind == .Table && found.run == nil {
		return module.records_equal(found.file, found.function.parameter_details[index], argument.file, argument.detail)
	}
	return true
}

// argument_refusal fails the line for an argument that a parameter does not
// take: a Stream where a Table is needed has the sentence that names the
// two ways to make a Table of it.
argument_refusal :: proc "contextless" (name: string, found: ^Command, index: int, argument: Value) -> Value {
	if argument.kind == .Stream && found.parameters[index] == .Table {
		writer := sentence.Writer {
			buffer = scratch[scratch_count:],
		}
		console_stream.table_needed_write(&writer, name)
		text := sentence.written(&writer)
		scratch_count += len(text)
		return fail(text)
	}
	return fail(name, ": argument ", i64(index + 1), " is ", parameter_text(found, index), ", not ", type_text(argument.file, argument.kind, argument.detail))
}

// call_run checks the arguments of a call, which the evaluator forced from
// the left, against the parameters of its command, and calls the function.
// The parser read the names of a parameter of the form Field_Names as one
// argument, a Text.
call_run :: proc "contextless" (name: string, arguments: []Value) -> Value {
	found := command_find(name)
	if found == nil {
		return fail("no command has the name ", name, "; try help()")
	}
	count := len(arguments)
	// A command whose last parameter may be left out takes one argument
	// less: start(name) and start(name, list).
	if count != found.parameter_count && !(found.optional_last && count == found.parameter_count - 1) {
		return fail(name, " takes ", i64(found.parameter_count), " arguments, not ", i64(count))
	}
	for kind, index in found.parameters[:count] {
		argument := &arguments[index]
		// An optional Enum that the line leaves out has no value: the call
		// gives the absent word, which names no member.
		if kind == .Enum && argument.kind == .None && found.run == nil && module.parameter_optional(found.function, index) {
			enum_index, _ := module.enum_detail_of(found.function.parameter_details[index])
			described, _ := module.enum_type(found.file, enum_index)
			argument^ = {kind = .Enum, integer = module.enum_absent_word(described), file = found.file, detail = enum_index}
			continue
		}
		if !argument_accepted(found, index, argument^) {
			return argument_refusal(name, found, index, argument^)
		}
		if kind == .Record {
			// A copy: the export can write in its record, and a call
			// writes the handles of the receiver in it.
			bytes := scratch_bytes(len(argument.record))
			if bytes == nil && len(argument.record) != 0 {
				return fail("the line has too many records")
			}
			copy(bytes, argument.record)
			argument.record = bytes
		}
	}
	if found.record != 0 {
		return record_build(found, arguments[:count])
	}
	if found.sandbox != 0 {
		return call_isolated(found, arguments[:count])
	}
	if found.address != 0 {
		return call_export(found, arguments[:count])
	}
	return found.run(arguments[:count])
}

// ---- The pipe operator.

// What the console knows, before the run, of the value on the left of a
// "|>".
Left_Knowledge :: enum u8 {
	None  = 0, // Nothing: the value comes when the line runs.
	Kind  = 1, // Its kind, not the record of a Table or of a Record.
	Whole = 2, // Its kind and its record: what argument_accepted reads.
}

// pipe_nested_line gives the line with calls in calls in the place of each
// "|>", which the parser then reads. Before any call runs, it fails the
// line on each fault that the text and the command table show: the form
// of the operator, a name that no command has, a count of arguments, and a
// first parameter that refuses a value whose kind the console knows. The
// call then checks again what it checks for each line.
pipe_nested_line :: proc "contextless" (text: string) -> string {
	form := console_language.pipe_nested_form(text, console_language.expression_start(text), nested_line[:], line_stages[:])
	if form.refusal != .None {
		pipe_refusal_fail(text, form)
		return text
	}
	stages := line_stages[:form.stage_count]
	// The names first, from the last stage: the nested form looks up its
	// outer call before it reads the arguments of that call.
	for index := len(stages) - 1; index >= 0; index -= 1 {
		name := text[stages[index].name_start:stages[index].name_end]
		if command_find(name) == nil {
			fail("no command has the name ", name, "; try help()")
			return text
		}
	}
	for stage, index in stages {
		name := text[stage.name_start:stage.name_end]
		found := command_find(name)
		if found.parameter_count == 0 {
			fail(name, " takes no argument, and |> gives it the value on its left")
			return text
		}
		// With a '_', the value on the left takes its place: it is one of
		// the arguments in the parentheses.
		placeholder := stage.placeholder_start >= 0
		if !placeholder && stage.argument_count >= ARGUMENT_CAPACITY {
			fail(name, " has ", i64(stage.argument_count), " arguments already, and |> gives it one more: a call takes at most ", i64(ARGUMENT_CAPACITY))
			return text
		}
		// The names of a parameter of the form Field_Names are one argument
		// of the call, which the stage counts as one for each name.
		names_last := found.parameter_forms[found.parameter_count - 1] == .Field_Names
		arguments_given := placeholder ? stage.argument_count : stage.argument_count + 1
		count_ok := arguments_given == found.parameter_count || (names_last && arguments_given > found.parameter_count) || (found.optional_last && arguments_given == found.parameter_count - 1)
		if !count_ok {
			fail(name, " takes ", i64(found.parameter_count), " arguments, not ", i64(arguments_given))
			return text
		}
		// The parameter that takes the value on the left: the first one, or
		// the place of the '_'. A '_' of a named argument names its
		// parameter, which the call checks when it runs.
		parameter := placeholder ? stage.placeholder_argument : 0
		if stage.placeholder_named || parameter < 0 || parameter >= found.parameter_count {
			continue
		}
		// The sentence of the same line with calls in calls.
		left, knowledge := pipe_left_value(text, stages, index)
		if knowledge == .Whole && !argument_accepted(found, parameter, left) {
			argument_refusal(name, found, parameter, left)
			return text
		}
		if !placeholder && !pipe_stage_names_check(text, stages, index, found, left, knowledge) {
			return text
		}
	}
	return form.nested
}

// pipe_stage_names_check checks, before any call, the argument of a stage
// that the parser reads as names: a fact name against the fact names of
// the image, and the field of a condition against the record on the left
// of the stage when the console knows it (pipe_left_record). A form that
// it does not read, it leaves to the parser and to the evaluation, which
// fail on it when the line runs.
pipe_stage_names_check :: proc "contextless" (text: string, stages: []console_language.Pipe_Stage, index: int, found: ^Command, left: Value, knowledge: Left_Knowledge) -> bool {
	stage := stages[index]
	name := text[stage.name_start:stage.name_end]
	if found.parameter_count != 2 || (stage.argument_count != 1 && found.parameter_forms[1] != .Field_Names) {
		return true
	}
	argument := text[stage.arguments_start:stage.arguments_end]
	switch found.parameter_forms[1] {
	case .Field_Names:
		file, detail, known := pipe_left_record(text, stages, index, left, knowledge)
		if !known {
			return true
		}
		record, record_ok := module.record_type(file, detail)
		if !record_ok {
			return true
		}
		// Each name against the record on the left, with the sentence of
		// the command when it runs.
		for token := console_language.token_next(argument, 0); token.kind != .None; token = console_language.token_next(argument, token.end) {
			if token.kind != .Name {
				continue
			}
			field_name := argument[token.start:token.end]
			if _, field_found := console_condition.field_find(file, record, field_name); !field_found {
				named := Table {
					file   = file,
					record = record,
				}
				fail(name, ": the records ", module.string_at(file, record.name_offset, record.name_count), " have no field ", field_name, "; their fields are ", field_names(named))
				return false
			}
		}
	case .Expression:
	case .Fact_Name:
		first := console_language.token_next(argument, 0)
		if first.kind == .Name && !fact_name_known(argument[first.start:first.end]) {
			fact_name_fail(name, argument[first.start:first.end])
			return false
		}
	case .Condition:
		file, detail, known := pipe_left_record(text, stages, index, left, knowledge)
		if !known {
			return true
		}
		record, record_ok := module.record_type(file, detail)
		if !record_ok {
			return true
		}
		// The same checks as condition_evaluate, with the same sentences.
		details := console_condition.Refusal_Details {
			command = name,
			file    = file,
			record  = record,
		}
		head, refusal := console_condition.head_read(argument, 0)
		details.field, details.comparison = head.field, head.comparison
		if refusal != .None {
			condition_fail(refusal, details)
			return false
		}
		found_field: bool
		if details.item, found_field = console_condition.field_find(file, record, head.field); !found_field {
			condition_fail(.Unknown_Field, details)
			return false
		}
		if refusal = console_condition.field_check(details.item, head.comparison); refusal != .None {
			condition_fail(refusal, details)
			return false
		}
		if which, status := console_condition.field_is_status(details.item); status {
			// After the operator of a status: a name of a member, never a
			// text, a number or an expression.
			_, details.member, _, refusal = console_condition.member_read(argument, head.value_start, which)
			if refusal != .None {
				condition_fail(refusal, details)
				return false
			}
			return true
		}
		// A literal alone: its kind and its range are known before the
		// run. Another expression is checked when it runs.
		if value_type, value, literal := literal_of(argument, head.value_start); literal {
			details.value_type = value_type
			if refusal = console_condition.value_check(details.item, value_type, value); refusal != .None {
				condition_fail(refusal, details)
				return false
			}
		}
	}
	return true
}

// literal_of reads a value that is one literal and nothing after it, at a
// byte place of an argument: a number, a number after "-", or a text.
// literal is false for any other expression, and for a number that does
// not fit in an Integer: the evaluation checks those when the line runs.
literal_of :: proc "contextless" (text: string, place: int) -> (type: module.Type, value: i64, literal: bool) {
	token := console_language.token_next(text, place)
	negative := false
	if token.kind == .Operator && text[token.start] == '-' {
		negative = true
		token = console_language.token_next(text, token.end)
	}
	if console_language.token_next(text, token.end).kind != .None {
		return .None, 0, false
	}
	switch token.kind {
	case .Number:
		value = console_language.number_value(text, token.start, token.end) or_return
		if negative {
			value = console_language.integer_negate(value) or_return
		}
		return .Integer, value, true
	case .Text:
		return .Text, 0, !negative
	case .None, .Name, .Text_Unfinished, .Operator, .Arrow, .Unknown, .Pipe, .Member:
		// A variable, a call, an expression: its kind comes when it runs.
	}
	return .None, 0, false
}

// pipe_left_record gives the record of the table on the left of a stage,
// when the console knows it before the run: the result of an export, the
// table of a stage `facts(...)`, whose record the console makes from the
// fact type, and the table of a stage that keeps the record of its own
// left (where, sort, first, skip). description_buffer: where the
// description of a table of facts() goes; nil puts it in the memory of the
// line.
pipe_left_record :: proc "contextless" (text: string, stages: []console_language.Pipe_Stage, index: int, left: Value, knowledge: Left_Knowledge, description_buffer: []u8 = nil) -> (file: []u8, detail: u32, known: bool) {
	if knowledge == .Whole && (left.kind == .Table || left.kind == .Stream) && left.file != nil {
		return left.file, left.detail, true
	}
	stage := stages[index]
	if stage.left != .Stage || stage.stage_before < 0 || stage.stage_before >= index {
		return nil, 0, false
	}
	before := stages[stage.stage_before]
	before_name := text[before.name_start:before.name_end]
	before_command := command_find(before_name)
	if before_command == nil || before_command.run == nil {
		return nil, 0, false
	}
	switch before_name {
	case "where", "sort", "first", "skip", "table":
		before_left, before_knowledge := pipe_left_value(text, stages, stage.stage_before)
		return pipe_left_record(text, stages, stage.stage_before, before_left, before_knowledge, description_buffer)
	}
	if before_command.parameter_forms[1] != .Fact_Name || before.argument_count != 1 {
		return nil, 0, false
	}
	argument := text[before.arguments_start:before.arguments_end]
	token := console_language.token_next(argument, 0)
	if token.kind != .Name {
		return nil, 0, false
	}
	return facts_description(argument[token.start:token.end], description_buffer)
}

// pipe_refusal_fail fails the line with the sentence of a fault of the
// form of "|>".
pipe_refusal_fail :: proc "contextless" (text: string, form: console_language.Pipe_Form) {
	found_start := clamp(form.found_start, 0, len(text))
	found := text[found_start:clamp(form.found_end, found_start, len(text))]
	switch form.refusal {
	case .None:
	case .No_Left_Value:
		fail("|> has no value on its left: write a value, then |> and a call")
	case .Line_End:
		fail("the line ends after |>: a call or the name of a command comes after it")
	case .Not_A_Call:
		fail("|> takes a call or the name of a command on its right, not \"", found, "\"")
	case .Lone_Bar:
		fail("\"|\" is no operator: the pipe operator is \"|>\"")
	case .Unmatched_Close:
		fail("unexpected \"", found, "\"")
	case .Too_Many_Stages:
		fail("a line holds at most ", i64(console_language.PIPE_STAGE_CAPACITY), " |>")
	case .Too_Long:
		fail("the line with calls in calls has more than ", i64(NESTED_LINE_SIZE), " bytes")
	case .Placeholder_Not_Whole:
		fail("|>: _ is a whole argument of ", pipe_text_at(text, form.call_start, form.call_end), ", not a part of an expression")
	case .Placeholder_Twice:
		fail("|>: ", pipe_text_at(text, form.call_start, form.call_end), " has two _; the value on the left takes one place")
	case .Placeholder_Nested:
		fail("|>: _ names an argument of ", pipe_text_at(text, form.call_start, form.call_end), ", not of ", pipe_text_at(text, form.inner_start, form.inner_end), " inside it")
	case .Placeholder_Without_Pipe:
		fail("_ is a place of the call on the right of |>; this call has no |> before it")
	}
}

// pipe_text_at gives the bytes start:end of a line, cut to the line.
pipe_text_at :: proc "contextless" (text: string, start, end: int) -> string {
	first := clamp(start, 0, len(text))
	return text[first:clamp(end, first, len(text))]
}

// pipe_left_value gives what the console knows, before the run, of the
// value on the left of the stage index.
pipe_left_value :: proc "contextless" (text: string, stages: []console_language.Pipe_Stage, index: int) -> (value: Value, knowledge: Left_Knowledge) {
	stage := stages[index]
	switch stage.left {
	case .Other:
	case .Integer:
		value, knowledge = Value{kind = .Integer}, .Whole
	case .Text:
		value, knowledge = Value{kind = .Text}, .Whole
	case .Name:
		// A name alone is a variable; any other name fails when it runs.
		name := text[stage.left_start:stage.left_end]
		for &variable in variables {
			if variable.name_count > 0 && string(variable.name[:variable.name_count]) == name {
				value, knowledge = variable.value, .Whole
			}
		}
		// A typed name: its record description is in the module file of its
		// owner, so the fields of a condition after it are checked before
		// the line runs, and the completion offers them.
		if knowledge == .None {
			if file, detail, kind, known := stream_name_known(name); known {
				value, knowledge = Value{kind = kind, file = file, detail = detail}, .Whole
			}
		}
	case .Call:
		value, knowledge = result_knowledge(command_find(text[stage.left_start:stage.left_end]))
	case .Stage:
		if stage.stage_before >= 0 && stage.stage_before < index {
			before := stages[stage.stage_before]
			value, knowledge = result_knowledge(command_find(text[before.name_start:before.name_end]))
		}
	}
	return value, knowledge
}

// result_knowledge gives what the console knows of the result of a
// command before it runs: its kind, and the record of an export, which its
// description states. A command of the console makes the description of
// its record when it runs.
result_knowledge :: proc "contextless" (found: ^Command) -> (value: Value, knowledge: Left_Knowledge) {
	if found == nil {
		return {}, .None
	}
	value.kind = found.result
	switch found.result {
	case .None, .Integer, .Text:
		knowledge = .Whole
	case .Record, .Table:
		knowledge = .Kind
		if found.run == nil {
			value.file, value.detail = found.file, found.function.result_detail
			knowledge = .Whole
		}
	case .Enum:
		// The enum of an export is in its description.
		value.file, value.detail = found.file, found.function.result_detail
		knowledge = .Whole
	case .Handle, .Bytes:
		// The rights of a Handle come with the value.
		knowledge = .Kind
	case .Stream, .Record_Input, .Record_Literal, .Member:
		// A command of the console makes a Stream, and the record of the
		// record output comes with the value when the line runs.
		knowledge = .Kind
	}
	return value, knowledge
}

// pipe_stage_takes says if a command can be the call on the right of a
// "|>": it takes an argument, and its first parameter takes what the
// console knows of the value on the left.
pipe_stage_takes :: proc "contextless" (item: ^Command, left: Value, knowledge: Left_Knowledge) -> bool {
	if item.parameter_count == 0 {
		return false
	}
	switch knowledge {
	case .None:
		return true
	case .Kind:
		kind := item.parameters[0]
		if kind == .None && item.run != nil {
			return true
		}
		return (kind == .Bytes ? Kind.Text : kind) == left.kind
	case .Whole:
		return argument_accepted(item, 0, left)
	}
	return false
}
