package console

import "modus:contract/errors"
import module "modus:contract/module"
import "modus:private/console/console_condition"
import "modus:private/console/console_language"
import "modus:private/console/lex_parser"
import "modus:support/system"

// The evaluation of a line of Lex.
//
// The parser of Lex (src/library/private/console/lex_parser) gives the
// syntax tree of a line, and this file evaluates it from the left, as the
// console read and ran a line in one pass before: the calls before a fault
// of the text run, then the line fails with the sentence of the fault. The
// form of each parameter of a command (Parameter_Form) says which argument
// the parser reads there: an expression, a condition on a field of the
// table of the first argument (`where(t, block = 12)`), or the name of a
// fact type (`facts(t, storage.Bad_Block)`). In a condition, a name is a
// field and, after the operator of a status field, a member of its enum:
// never a variable.
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
// and the console draws them; no variable keeps them.
//
// A line has one result: the value of its expression, or its failure. No
// command writes to the terminal: the console draws the result of the line
// by its kind (results.odin).

// The values are those of module.Type: the kind of a parameter is its type.
Kind :: enum u8 {
	None    = 0,
	Integer = 1,
	Text    = 2,
	Record  = 3,
	Handle  = 4,
	Table   = 5,
	Bytes   = 6, // A parameter: a Text value is its argument. A value: bytes with no description, which the console draws.
}

// A parameter of a command of the console with the kind None takes a value
// of any kind: the command checks it.
Value :: struct {
	kind:      Kind,
	integer:   i64, // An Integer. A Handle: the handle.
	text:      string,
	record:    []u8, // A Record: its bytes. A Table: the bytes of its records.
	file:      []u8, // A Record or a Table: the module that has the description of the record.
	detail:    u32, // A Record or a Table: the index of the description of the record in the module.
	condition: ^Condition, // The argument of a parameter of the form Condition, in line_conditions: the parser read it, not an expression.
}

// The conditions of the line that runs. A value names one by its address,
// so that a value stays small: a call keeps 12 of them on the stack.
line_conditions: console_condition.Condition_List

// What the parser reads for a parameter of a command: an expression, the
// name of a fact type (a Text value with the name), or a condition.
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
	.None    = "None",
	.Integer = "Integer",
	.Text    = "Text",
	.Record  = "Record",
	.Handle  = "Handle",
	.Table   = "Table",
	.Bytes   = "Bytes",
}

// type_text gives the name of a type: "Integer", the name of a record, or
// "Handle(Read)". The text lasts for one line.
type_text :: proc "contextless" (file: []u8, kind: Kind, detail: u32) -> string {
	if kind == .None {
		return "None"
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

// field_value gives one field of a Record value, by name.
field_value :: proc "contextless" (value: Value, name: string) -> (result: Value, ok: bool) {
	described := module.record_type(value.file, value.detail) or_return
	for number in 0 ..< described.field_count {
		item := module.field(value.file, described, number) or_return
		if module.string_at(value.file, item.name_offset, item.name_count) != name {
			continue
		}
		// A byte that names no type gives no value, as a field of no value.
		type := module.field_type(item) or_return
		switch type {
		case .Integer:
			return {kind = .Integer, integer = module.field_integer(value.record, item)}, true
		case .Handle:
			return {kind = .Handle, integer = i64((^u32)(&value.record[item.offset])^)}, true
		case .Text:
			return {kind = .Text, text = module.field_text(value.record, item)}, true
		case .Bytes:
			// A hash: the console draws its bytes.
			return {kind = .Bytes, record = module.field_bytes(value.record, item)}, true
		case .None, .Record, .Table:
			// A field of a record holds no such value: the field gives none.
			return {}, false
		}
	}
	return {}, false
}

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
	failed, scratch_count, table_used, line_conditions.count = false, 0, 0, 0
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
	if failed {
		failure_draw()
		return
	}
	if !assigned {
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
	case .None, .Integer, .Handle, .Bytes:
		// The value holds no memory of the line: the slot keeps it as it is.
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

// line_evaluate evaluates the tree of the line, from the left. A refusal of
// the text is a node in its place: the parts before it run, then the line
// fails with its sentence, as when the console read and ran the line in one
// pass.
line_evaluate :: proc "contextless" () -> Value {
	// The bounds of the parser: no line that the console runs reaches them,
	// and a tree past one is not whole in its places, so nothing of it runs.
	switch line_tree.refusal.refusal {
	case .Text_Too_Long:
		return fail("the line has more than ", i64(lex_parser.TEXT_BYTES_MOST), " bytes")
	case .Nodes_Full:
		return fail("the line has more parts than the console reads: ", i64(lex_parser.NODE_CAPACITY))
	case .None, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused:
	}
	return evaluate(line_tree.root)
}

// evaluate gives the value of a node of the tree of the line.
evaluate :: proc "contextless" (index: lex_parser.Node_Index) -> Value {
	node := lex_parser.node_at(&line_tree, index)
	if node == nil {
		return fail("the line ends too soon")
	}
	switch node.kind {
	case .Integer:
		return {kind = .Integer, integer = node.integer}
	case .Text:
		quoted := lex_parser.node_text(&line_tree, index)
		return {kind = .Text, text = quoted[1:len(quoted) - 1]}
	case .Name:
		return name_evaluate(lex_parser.node_text(&line_tree, index))
	case .Call:
		return call(index)
	case .Negate:
		return negate_evaluate(node)
	case .Binary:
		return binary_evaluate(node)
	case .Refused:
		return refused_evaluate(index)
	case .Condition, .Fact_Name:
		// The parser makes these only as an argument of a call, and call
		// reads them there.
		return fail("unexpected \"", line_tree.text[int(node.place.offset):], "\"")
	}
	return {}
}

// binary_evaluate gives the value of an operator on two values. The left
// one runs first.
binary_evaluate :: proc "contextless" (node: ^lex_parser.Node) -> Value {
	left := evaluate(node.first_child)
	if failed {
		return {}
	}
	right := evaluate(lex_parser.next_of(&line_tree, node.first_child))
	if failed {
		return {}
	}
	operator := lex_parser.OPERATOR_TEXTS[node.operator]
	switch node.operator {
	case .Add, .Subtract:
		switch {
		case left.kind == .Integer && right.kind == .Integer:
			result: i64
			fits: bool
			if node.operator == .Add {
				result, fits = console_language.integer_add(left.integer, right.integer)
			} else {
				result, fits = console_language.integer_subtract(left.integer, right.integer)
			}
			if !fits {
				return fail_overflow(operator, left.integer, right.integer)
			}
			left.integer = result
		case left.kind == .Text && right.kind == .Text && node.operator == .Add:
			left.text = scratch_text(left.text, right.text)
		case:
			return fail("\"", operator, "\" does not take ", kind_names[left.kind], " and ", kind_names[right.kind])
		}
	case .Multiply, .Divide, .Remainder:
		if left.kind != .Integer || right.kind != .Integer {
			return fail("\"", operator, "\" does not take ", kind_names[left.kind], " and ", kind_names[right.kind])
		}
		if node.operator == .Multiply {
			product, fits := console_language.integer_multiply(left.integer, right.integer)
			if !fits {
				return fail_overflow("*", left.integer, right.integer)
			}
			left.integer = product
			break
		}
		if right.integer == 0 {
			return fail("division by zero")
		}
		quotient, rest, fits := console_language.integer_divide(left.integer, right.integer)
		if !fits {
			return fail_overflow("/", left.integer, right.integer)
		}
		left.integer = node.operator == .Divide ? quotient : rest
	case .None:
		// The parser gives each Binary node its operator.
		return fail("unexpected \"", line_tree.text[int(node.place.offset):], "\"")
	}
	return left
}

// negate_evaluate gives the opposite of an Integer.
negate_evaluate :: proc "contextless" (node: ^lex_parser.Node) -> Value {
	value := evaluate(node.first_child)
	if failed {
		return {}
	}
	if value.kind != .Integer {
		return fail("\"-\" does not take ", kind_names[value.kind])
	}
	opposite, fits := console_language.integer_negate(value.integer)
	if !fits {
		return fail_overflow("-", 0, value.integer)
	}
	value.integer = opposite
	return value
}

// refused_evaluate evaluates the part that the parser read before a fault
// of the text, then fails the line with the sentence of the fault.
refused_evaluate :: proc "contextless" (index: lex_parser.Node_Index) -> Value {
	node := lex_parser.node_at(&line_tree, index)
	if node.first_child != lex_parser.NO_NODE {
		evaluate(node.first_child)
		if failed {
			return {}
		}
	}
	switch node.refusal {
	case .Line_Ends_Too_Soon:
		return fail("the line ends too soon")
	case .Unexpected:
		return fail("unexpected \"", line_tree.text[int(node.place.offset):], "\"")
	case .Number_Too_Large:
		// The record: the limit is the largest Integer; the sentence has
		// the digits, which no Integer holds.
		result := fail("the number ", lex_parser.node_text(&line_tree, index), " does not fit in an Integer: the largest is ", i64(console_language.INTEGER_MOST))
		failure_record_set(errors.error_make(.Over_Limit, .None, 0, 0, console_language.INTEGER_MOST), "a number", nil)
		return result
	case .Text_Without_End_Quote:
		return fail("the text has no end quote")
	case .Close_Parenthesis_Missing:
		return fail("\")\" is missing")
	case .Comma_Or_Close_Missing:
		return fail("\",\" or \")\" is missing")
	case .Too_Many_Arguments:
		return fail("too many arguments")
	case .Text_Too_Long:
		return fail("the line has more than ", i64(lex_parser.TEXT_BYTES_MOST), " bytes")
	case .Nodes_Full:
		return fail("the line has more parts than the console reads: ", i64(lex_parser.NODE_CAPACITY))
	case .None, .Fact_Name_Missing, .Condition_Head_Refused:
		// A Fact_Name or a Condition node holds these; a Refused node never.
	}
	return fail("unexpected \"", line_tree.text[int(node.place.offset):], "\"")
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
	// A Record agrees when the two descriptions are equal: a record of one
	// module is a record of another module with the same fields. A command
	// of the console (run) takes a Table of any record.
	if kind == .Record || kind == .Table && found.run == nil {
		return module.records_equal(found.file, found.function.parameter_details[index], argument.file, argument.detail)
	}
	return true
}

// call evaluates the arguments of a Call node from the left, checks their
// types against the parameters, and calls the function.
call :: proc "contextless" (call_node: lex_parser.Node_Index) -> Value {
	name := lex_parser.node_text(&line_tree, call_node)
	found := command_find(name)
	if found == nil {
		return fail("no command has the name ", name, "; try help()")
	}
	arguments: [ARGUMENT_CAPACITY]Value
	count := 0
	for argument := lex_parser.node_at(&line_tree, call_node).first_child; argument != lex_parser.NO_NODE; argument = lex_parser.next_of(&line_tree, argument) {
		// A fact name and a condition are names that the console checks,
		// never an expression: `block` is a field, not a variable. A
		// refusal of the text after the arguments before it fails here.
		value: Value
		switch lex_parser.node_at(&line_tree, argument).kind {
		case .Fact_Name:
			value = fact_name_evaluate(name, argument)
		case .Condition:
			value = condition_evaluate(name, arguments[:count], argument)
		case .Integer, .Text, .Name, .Call, .Negate, .Binary, .Refused:
			value = evaluate(argument)
		}
		if failed {
			return {}
		}
		// The parser ends the arguments with a refusal at this count.
		if count == ARGUMENT_CAPACITY {
			return fail("too many arguments")
		}
		arguments[count] = value
		count += 1
	}
	if count != found.parameter_count {
		return fail(name, " takes ", i64(found.parameter_count), " arguments, not ", i64(count))
	}
	for kind, index in found.parameters[:count] {
		argument := &arguments[index]
		if !argument_accepted(found, index, argument^) {
			return fail(name, ": argument ", i64(index + 1), " is ", parameter_text(found, index), ", not ", type_text(argument.file, argument.kind, argument.detail))
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
		if stage.argument_count >= ARGUMENT_CAPACITY {
			fail(name, " has ", i64(stage.argument_count), " arguments already, and |> gives it one more: a call takes at most ", i64(ARGUMENT_CAPACITY))
			return text
		}
		if stage.argument_count + 1 != found.parameter_count {
			fail(name, " takes ", i64(found.parameter_count), " arguments, not ", i64(stage.argument_count + 1))
			return text
		}
		// The sentence of the same line with calls in calls.
		left, knowledge := pipe_left_value(text, stages, index)
		if knowledge == .Whole && !argument_accepted(found, 0, left) {
			fail(name, ": argument ", i64(1), " is ", parameter_text(found, 0), ", not ", type_text(left.file, left.kind, left.detail))
			return text
		}
		if !pipe_stage_names_check(text, stages, index, found, left, knowledge) {
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
	if stage.argument_count != 1 || found.parameter_count != 2 {
		return true
	}
	argument := text[stage.arguments_start:stage.arguments_end]
	switch found.parameter_forms[1] {
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
	case .None, .Name, .Text_Unfinished, .Operator, .Arrow, .Unknown, .Pipe:
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
	if knowledge == .Whole && left.kind == .Table && left.file != nil {
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
	case "where", "sort", "first", "skip":
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
	}
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
	case .Handle, .Bytes:
		// The rights of a Handle come with the value.
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
