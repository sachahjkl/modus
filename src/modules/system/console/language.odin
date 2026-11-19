package console

import "modus:contract/errors"
import module "modus:contract/module"
import "modus:private/console/console_language"
import "modus:support/system"

// The language of the console.
//
//   line       = name "=" pipeline | pipeline
//   pipeline   = expression { "|>" stage }
//   stage      = name | name "(" arguments ")"
//   expression = term { ("+" | "-") term }
//   term       = factor { ("*" | "/" | "%") factor }
//   factor     = "-" factor | integer | "text" | name | name "(" arguments ")" | "(" pipeline ")"
//   arguments  = argument { "," argument }
//   argument   = pipeline | condition | name
//   condition  = name ("=" | "!=" | "<" | "<=" | ">" | ">=") (pipeline | name)
//
// The form of each parameter of a command (Parameter_Form) says which
// argument the parser reads there: a pipeline, a condition on a field of
// the table of the first argument (`where(t, block = 12)`), or the name of
// a fact type (`facts(t, storage.Bad_Block)`). In a condition, a name is a
// field and, after the operator of a status field, a member of its enum:
// never a variable.
//
// The pipe operator has the lowest priority: `a |> f(b)` is `f(a, b)`, and
// `a |> f` is `f(a)`. The parser below reads no "|>": before any call,
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
CONDITION_CAPACITY :: 32
line_conditions: [CONDITION_CAPACITY]Condition
line_condition_count: int

// condition_keep keeps a condition for the line that runs, and gives its
// address; nil, with the line failed, when the line holds too many.
condition_keep :: proc "contextless" (condition: Condition) -> ^Condition {
	if line_condition_count == CONDITION_CAPACITY {
		fail("a line holds at most ", i64(CONDITION_CAPACITY), " conditions")
		return nil
	}
	line_conditions[line_condition_count] = condition
	line_condition_count += 1
	return &line_conditions[line_condition_count - 1]
}

// What the parser reads for a parameter of a command. Most parameters take
// an expression; a few take a name that the console checks against a
// description, never a variable (src/md/features/log_facts.md, "Filters
// of a reader: one form").
Parameter_Form :: enum u8 {
	Expression = 0, // An expression, whose value has the kind of the parameter.
	Fact_Name  = 1, // The name of a fact type, "package.Type": a Text value with the name.
	Condition  = 2, // A field of the table of the first argument, an operator and a value.
}

// The operators of a condition.
Comparison :: enum u8 {
	Equal            = 0, // =
	Not_Equal        = 1, // !=
	Less             = 2, // <
	Less_Or_Equal    = 3, // <=
	Greater          = 4, // >
	Greater_Or_Equal = 5, // >=
}

@(rodata)
comparison_texts := [Comparison]string {
	.Equal            = "=",
	.Not_Equal        = "!=",
	.Less             = "<",
	.Less_Or_Equal    = "<=",
	.Greater          = ">",
	.Greater_Or_Equal = ">=",
}

// A condition on one field of the rows of a table: `block = 12`,
// `level = Warning`, `name != "console"`. The value is an Integer for an
// Integer or a Handle field and for a Status field (the number of its
// member), a Text for a Text field.
Condition :: struct {
	field:      string, // The name of the field, as the line has it.
	comparison: Comparison,
	compared:   i64, // An Integer, a Handle, or the word of a member.
	text:       string, // A Text.
}

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

source: string
position: int
failed: bool

// The nested form of the line that runs, and the stages of its "|>". A
// Text value of the line is a part of its source, so the nested form lives
// until the next line.
NESTED_LINE_SIZE :: 1024 // A nested form is never longer than its line: a line of the history has 256 bytes at most.
nested_line: [NESTED_LINE_SIZE]u8
line_stages: [console_language.PIPE_STAGE_CAPACITY]console_language.Pipe_Stage

scratch_text :: proc "contextless" (parts: ..system.Part) -> string {
	text := system.format(scratch[scratch_count:], ..parts)
	scratch_count += len(text)
	return text
}

// The parser reads its tokens with the scanner of src/library/private/console/console_language,
// the one that colors the lines: the two agree on each token.
skip_spaces :: proc "contextless" () {
	position = console_language.space_end(source, position)
}

peek :: proc "contextless" () -> u8 {
	skip_spaces()
	return position < len(source) ? source[position] : 0
}

accept :: proc "contextless" (character: u8) -> bool {
	if peek() == character {
		position += 1
		return true
	}
	return false
}

read_name :: proc "contextless" () -> string {
	skip_spaces()
	start := position
	position = console_language.name_end(source, start)
	return source[start:position]
}

// run_line runs one line: it evaluates the expression, shows the log
// records of what the line called, then draws the one result of the line:
// its failure, or the value of an expression. A line that keeps its value
// in a variable draws nothing.
run_line :: proc "contextless" (text: string) {
	source, position, failed, scratch_count, table_used, line_condition_count = text, 0, false, 0, 0, 0
	failure_reset()
	line_records_start()

	// A fault of "|>" fails the line here, before any call runs.
	source = pipe_nested_line(text)
	name: string
	assigned := false
	value: Value
	if !failed {
		// An assignment starts with a name and "=".
		name = read_name()
		assigned = len(name) > 0 && accept('=')
		if !assigned {
			position = 0
		}
		value = expression()
		if !failed && peek() != 0 {
			fail("unexpected \"", source[position:], "\"")
		}
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

expression :: proc "contextless" () -> Value {
	left := term()
	for !failed {
		operator := peek()
		if operator != '+' && operator != '-' {
			break
		}
		position += 1
		right := term()
		if failed {
			break
		}
		switch {
		case left.kind == .Integer && right.kind == .Integer:
			result: i64
			fits: bool
			if operator == '+' {
				result, fits = console_language.integer_add(left.integer, right.integer)
			} else {
				result, fits = console_language.integer_subtract(left.integer, right.integer)
			}
			if !fits {
				return fail_overflow(operator == '+' ? "+" : "-", left.integer, right.integer)
			}
			left.integer = result
		case left.kind == .Text && right.kind == .Text && operator == '+':
			left.text = scratch_text(left.text, right.text)
		case:
			return fail("\"", string([]u8{operator}), "\" does not take ", kind_names[left.kind], " and ", kind_names[right.kind])
		}
	}
	return left
}

term :: proc "contextless" () -> Value {
	left := factor()
	for !failed {
		operator := peek()
		if operator != '*' && operator != '/' && operator != '%' {
			break
		}
		position += 1
		right := factor()
		if failed {
			break
		}
		if left.kind != .Integer || right.kind != .Integer {
			return fail("\"", string([]u8{operator}), "\" does not take ", kind_names[left.kind], " and ", kind_names[right.kind])
		}
		switch operator {
		case '*':
			product, fits := console_language.integer_multiply(left.integer, right.integer)
			if !fits {
				return fail_overflow("*", left.integer, right.integer)
			}
			left.integer = product
		case '/', '%':
			if right.integer == 0 {
				return fail("division by zero")
			}
			quotient, rest, fits := console_language.integer_divide(left.integer, right.integer)
			if !fits {
				return fail_overflow("/", left.integer, right.integer)
			}
			left.integer = operator == '/' ? quotient : rest
		}
	}
	return left
}

factor :: proc "contextless" () -> Value {
	c := peek()
	switch {
	case c == '-':
		position += 1
		value := factor()
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
	case c == '(':
		position += 1
		value := expression()
		if !failed && !accept(')') {
			return fail("\")\" is missing")
		}
		return value
	case console_language.digit(c):
		start := position
		end := console_language.number_end(source, start)
		position = end
		value, fits := console_language.number_value(source, start, end)
		if !fits {
			// The record: the limit is the largest Integer; the sentence
			// has the digits, which no Integer holds.
			result := fail("the number ", source[start:end], " does not fit in an Integer: the largest is ", i64(console_language.INTEGER_MOST))
			failure_record_set(errors.error_make(.Over_Limit, .None, 0, 0, console_language.INTEGER_MOST), "a number", nil)
			return result
		}
		return {kind = .Integer, integer = value}
	case c == '"':
		start := position + 1
		end, finished := console_language.text_end(source, position)
		if !finished {
			position = end
			return fail("the text has no end quote")
		}
		position = end
		return {kind = .Text, text = source[start:end - 1]}
	case console_language.name_first(c):
		name := read_name()
		if accept('(') {
			return call(name)
		}
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
	case c == 0:
		return fail("the line ends too soon")
	}
	return fail("unexpected \"", source[position:], "\"")
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
	// A fact name and a condition are read by the parser, which checked
	// them against the image and against the table: no value comes there.
	if found.parameter_forms[index] != .Expression {
		return true
	}
	kind := found.parameters[index]
	// A parameter None of a command of the console takes any value.
	if kind == .None && found.run != nil {
		return true
	}
	// A table parameter takes a Table value of an equal record; Bytes
	// take a Text. The direction says what the export does with it.
	wanted := kind == .Bytes ? Kind.Text : kind
	if argument.kind != wanted {
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

// call reads the arguments of a command, checks their types against the
// parameters, and calls the function.
call :: proc "contextless" (name: string) -> Value {
	found := command_find(name)
	if found == nil {
		return fail("no command has the name ", name, "; try help()")
	}
	arguments: [ARGUMENT_CAPACITY]Value
	count := 0
	if !accept(')') {
		for {
			if count == ARGUMENT_CAPACITY {
				return fail("too many arguments")
			}
			// A fact name and a condition are names that the console
			// checks, never an expression: `block` is a field, not a
			// variable.
			value: Value
			switch found.parameter_forms[count] {
			case .Expression:
				value = expression()
			case .Fact_Name:
				value = fact_name_read(name)
			case .Condition:
				value = condition_read(name, arguments[:count])
			}
			if failed {
				return {}
			}
			arguments[count] = value
			count += 1
			if accept(')') {
				break
			}
			if !accept(',') {
				return fail("\",\" or \")\" is missing")
			}
		}
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
// it does not read, it leaves to the parser, which fails on it when the
// line runs.
pipe_stage_names_check :: proc "contextless" (text: string, stages: []console_language.Pipe_Stage, index: int, found: ^Command, left: Value, knowledge: Left_Knowledge) -> bool {
	stage := stages[index]
	name := text[stage.name_start:stage.name_end]
	if stage.argument_count != 1 || found.parameter_count != 2 {
		return true
	}
	argument := text[stage.arguments_start:stage.arguments_end]
	first := console_language.token_next(argument, 0)
	if first.kind != .Name {
		return true
	}
	first_name := argument[first.start:first.end]
	switch found.parameter_forms[1] {
	case .Expression:
	case .Fact_Name:
		if !fact_name_known(first_name) {
			fact_name_fail(name, first_name)
			return false
		}
	case .Condition:
		file, detail, known := pipe_left_record(text, stages, index, left, knowledge)
		if !known {
			return true
		}
		table := Table{file = file}
		table.record, known = module.record_type(file, detail)
		if !known {
			return true
		}
		comparison, comparison_end, has_comparison := comparison_at(argument, console_language.space_end(argument, first.end))
		if !has_comparison {
			fail(name, ": after the field ", first_name, " comes an operator: =, !=, <, <=, > or >=")
			return false
		}
		item, has_field := table_field(table, first_name)
		if !has_field {
			fail(name, ": the records ", type_text(file, .Record, detail), " have no field ", first_name, "; their fields are ", field_names(table))
			return false
		}
		if !condition_check(name, file, item, first_name, comparison) {
			return false
		}
		if kind, _ := module.field_kind(item); kind == .Status {
			member := console_language.token_next(argument, comparison_end)
			which, _ := module.field_contract_enum(item)
			if member.kind == .Name {
				if _, named := status_member_word(name, first_name, which, argument[member.start:member.end]); !named {
					return false
				}
			}
		}
	}
	return true
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
