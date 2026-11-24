package console

import "modus:contract/errors"
import module "modus:contract/module"
import "modus:contract/value_kinds"
import "modus:console_condition"
import "modus:console_language"
import "internal:console/console_stream"
import "modus:lex_evaluator"
import "modus:lex_parser"
import "modus:sentence"
import "modus:system"

// The console as the evaluation host of Lex in mode `console`.
//
// The parser of Lex (src/library/modus/lex_parser) gives the
// syntax tree of a line, and the evaluator
// (src/library/modus/lex_evaluator) forces it whole, from the
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
// (src/library/modus/console_language/pipe.odin), so a line with
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
Value :: lex_evaluator.Host_Value

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
	case .Stream, .Record_Input, .Record_Literal, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
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
	.Function       = "a function",
	.List           = "a list",
	.Hash           = "Hash",
	.Boolean        = "Boolean",
	.Record_With    = "a record",
	.Module_Ref     = "a module reference",
	.Recipe_Ref     = "a recipe",
	.Follow_Ref     = "a release pointer",
	.Store_Ref      = "a store grant",
	.Plan_Value     = "a plan",
	.Project_Value  = "a project",
	.Tree_Ref       = "a tree",
}

// type_text gives the name of a type: "Integer", the name of a record or of
// an enum, "Handle(Read)", or "Stream(Counted)". The text lasts for one
// line.
type_text :: proc "contextless" (file: []u8, kind: Kind, detail: u32) -> string {
	if kind == .None || kind == .Record_Literal || kind == .Member || kind == .Function || kind == .List {
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

// The variables of the console. A variable keeps the bytes of its value
// (a Text, a Record, a Table and its description, the items of a List and
// their bytes) in a memory object of their size, which the budget of the
// console pays: a value has the size that the budget holds, not a size of
// a slot. A name has at most a name of an identifier of Lex that a person
// types.
VARIABLE_CAPACITY :: 64
VARIABLE_NAME_SIZE :: 64
ARGUMENT_CAPACITY :: module.PARAMETER_CAPACITY // The arguments of a call: those of an export at most.

// The items of a list that one variable keeps, the items of its nested
// lists included (lex_evaluator, kept_list.odin): each list that a line
// can make.
VARIABLE_LIST_ITEM_CAPACITY :: lex_evaluator.KEPT_LIST_ITEM_CAPACITY

Variable :: struct {
	name:            [VARIABLE_NAME_SIZE]u8,
	name_count:      int, // 0: the slot is free.
	value:           Value,
	// The memory object of the bytes of the value, mapped; 0: the value
	// holds no byte of a line.
	memory:          system.Handle,
	memory_bytes:    []u8,
	// A List: its items from 0, then the items of each nested list, in
	// memory_bytes. The value of a nested list names its first item here.
	list_items:      []Value,
	list_item_count: int,
	// The line that copied the items into its evaluation, and the place of
	// the first one there: a line reads a list variable many times, in a
	// body of a function too, and copies it once.
	list_line:       u64,
	list_line_first: int,
}

variables: [VARIABLE_CAPACITY]Variable

// The count of the lines that ran: the serial of the line that runs.
line_serial: u64

// The copy of a list that a line assigns, before it goes into its variable.
list_keeping: lex_evaluator.List_Keeping

// The memory of the Text values of one line: the texts of a line of
// LINE_CAPACITY bytes, and what the commands join from them.
scratch: [64 * 1024]u8
scratch_count: int

failed: bool

// The source copy of the line that runs. A Text value of the line is a slice
// of line_source, so it lives until the next line.
line_source: [LINE_CAPACITY]u8

// The syntax tree of the line that runs and its caller-owned buffers.
line_tree: lex_parser.Syntax_Tree
line_tree_buffers: lex_parser.Console_Tree_Buffers

// The evaluation of the tree of the line that runs and its caller-owned VM
// buffers.
line_evaluation: lex_evaluator.Evaluation
line_eval_buffers: lex_evaluator.Console_Eval_Buffers

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
	line_serial += 1
	failure_reset()
	line_records_start()

	// Keep a stable copy of the line text for slices returned during this line.
	source_len := copy(line_source[:], text)
	source := string(line_source[:source_len])
	name: string
	assigned := false
	value: Value
	// A line of spaces and a comment has no token: it does nothing.
	if !failed && console_language.token_next(source, 0).kind != .None {
		lex_parser.parse_console(source, {form_of = parameter_form_of}, &line_tree_buffers, &line_tree)
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
	if value.kind == .Function {
		fail(FUNCTION_VARIABLE_REFUSAL)
		return
	}
	if len(name) > VARIABLE_NAME_SIZE {
		fail("the name of a variable has ", i64(VARIABLE_NAME_SIZE), " bytes at most; this one has ", i64(len(name)))
		return
	}
	// The whole list is copied before the variable changes: a refusal
	// leaves the old value.
	if value.kind == .List {
		if !list_keep(value) {
			return
		}
	}
	if in_table_memory(value.file) && len(value.file) > DESCRIPTION_SIZE {
		fail("the description of the records has ", i64(len(value.file)), " bytes, more than the ", i64(DESCRIPTION_SIZE), " of a description that join or columns makes")
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
		fail("the console keeps ", i64(VARIABLE_CAPACITY), " variables: give a new value to one of them")
		return
	}
	// The bytes that the value keeps: a value from the line, its
	// description when join or columns made it, and the items of a list
	// with their bytes. Each part starts at a multiple of 8.
	kept_bytes := 0
	switch value.kind {
	case .List:
		kept_bytes = list_keeping.item_count * size_of(Value) + list_keeping.byte_count
	case .None, .Integer, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
		// The value holds no memory of the line: the slot keeps it as it is.
		// A Bytes value and a Stream were refused above; the evaluator
		// refuses a literal and a member that nothing typed. An Enum names
		// the module file of its enum, which stays while the module does.
	case .Text:
		kept_bytes = len(value.text)
	case .Record, .Table:
		kept_bytes = len(value.record)
	}
	description_bytes := in_table_memory(value.file) ? len(value.file) : 0
	value_end := (kept_bytes + 7) &~ 7
	memory: system.Handle
	memory_bytes: []u8
	if value_end + description_bytes > 0 {
		pages := u64(value_end + description_bytes + system.PAGE_SIZE - 1) / system.PAGE_SIZE
		created, status := system.memory_create(pages)
		address: rawptr
		if status == .Succeeded {
			address, status = system.memory_map(created, {.Write})
			if status != .Succeeded {
				system.close(created)
			}
		}
		if status != .Succeeded {
			// The old value stays: the new one is refused whole.
			fail("the budget of the console cannot pay the ", i64(value_end + description_bytes), " bytes of the value of ", name)
			return
		}
		memory, memory_bytes = created, ([^]u8)(address)[:pages * system.PAGE_SIZE]
	}
	variable_memory_end(slot)
	slot.name_count = copy(slot.name[:], name)
	slot.value = value
	slot.memory, slot.memory_bytes = memory, memory_bytes
	switch value.kind {
	case .List:
		list_keeping_commit(slot)
	case .None, .Integer, .Handle, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
	case .Text:
		count := copy(memory_bytes, value.text)
		slot.value.text = string(memory_bytes[:count])
	case .Record, .Table:
		copy(memory_bytes, value.record)
		slot.value.record = memory_bytes[:len(value.record)]
	}
	// The description that join or columns made lives for one line.
	if description_bytes > 0 {
		bytes := memory_bytes[value_end:][:description_bytes]
		copy(bytes, value.file)
		slot.value.file = bytes
	}
}

// variable_memory_end gives back the memory object of the value of a
// variable: a new value replaces it, whole.
variable_memory_end :: proc "contextless" (slot: ^Variable) {
	if slot.memory != 0 {
		system.memory_unmap(raw_data(slot.memory_bytes))
		system.close(slot.memory)
	}
	slot.memory, slot.memory_bytes, slot.list_items, slot.list_item_count = 0, nil, nil, 0
}

FUNCTION_VARIABLE_REFUSAL :: "a variable keeps no function: a function reads the values of its line, which end with the line"

// list_keep copies a List of the line into list_keeping, or fails the line
// with the sentence of the refusal and, at a bound, its error record.
list_keep :: proc "contextless" (value: Value) -> bool {
	result := lex_evaluator.list_keep(&list_keeping, &line_evaluation, value, in_table_memory)
	switch result.refusal {
	case .None:
		return true
	case .Items_Full:
		fail("a variable keeps a list of ", i64(VARIABLE_LIST_ITEM_CAPACITY), " items at most, the items of its nested lists included; this one has ", result.record.value, " or more")
		failure_record_set(result.record, "a list of a variable", nil)
	case .Bytes_Full:
		fail("a variable keeps ", i64(lex_evaluator.KEPT_LIST_BYTE_CAPACITY), " bytes of texts and records in a list at most; this one has ", result.record.value, " or more")
		failure_record_set(result.record, "a list of a variable", nil)
	case .Function:
		fail(FUNCTION_VARIABLE_REFUSAL, "; a list of a variable holds none")
	case .Table:
		fail("a list of a variable holds no Table: a variable keeps one table whole, t = ...")
	case .Hash:
		fail("a list of a variable holds no hash: a hash lives in the evaluation of its line")
	case .Description_Of_Line:
		fail("a list of a variable holds no record whose description join or columns made: that description lives in its line")
	case .Kind:
		fail("a list of a variable holds no ", kind_names[result.kind])
	}
	return false
}

// list_keeping_commit moves the list that list_keep copied into the memory
// of a variable: its items first, then their bytes, where each text and
// record of an item then points.
list_keeping_commit :: proc "contextless" (slot: ^Variable) {
	items_end := list_keeping.item_count * size_of(Value)
	slot.list_items = ([^]Value)(raw_data(slot.memory_bytes))[:list_keeping.item_count]
	slot.list_item_count = lex_evaluator.list_keeping_commit(&list_keeping, slot.list_items, slot.memory_bytes[items_end:])
	// The top list is the first items; the next line copies them again.
	slot.value.integer = 0
	slot.list_line = 0
}

// list_variable_read gives the list of a variable as a List of the line that
// runs: its items copied into the items of the evaluation once for each
// line, at the first read.
list_variable_read :: proc "contextless" (variable: ^Variable) -> Value {
	if variable.list_line != line_serial {
		value, record, read := lex_evaluator.kept_list_read(&line_evaluation, variable.list_items[:variable.list_item_count], variable.value.detail)
		if !read {
			fail("the lists of the line hold more than ", i64(lex_evaluator.LIST_ITEM_CAPACITY), " items in all, with the ", i64(variable.list_item_count), " items of ", string(variable.name[:variable.name_count]))
			failure_record_set(record, "the lists of the line", nil)
			return {}
		}
		variable.list_line, variable.list_line_first = line_serial, int(value.integer)
	}
	return {kind = .List, integer = i64(variable.list_line_first), detail = variable.value.detail}
}

// The most bytes of stack that the evaluation of a line took in this run:
// a line that takes more logs the new measure.
deepest_line_stack: uint

// line_evaluate forces the tree of the line whole, in mode `console`, then
// writes the sentence of the refusal of the evaluator, if any. A refusal of
// the host has written its own.
line_evaluate :: proc "contextless" () -> Value {
	lex_evaluator.evaluation_start(&line_evaluation, &line_tree, .Console, console_host(), &line_eval_buffers)
	value, ok := lex_evaluator.line_force(&line_evaluation)
	// A line that the bound stopped measures the bound, not the line.
	if line_evaluation.refusal.refusal != .Stack_Exceeded && line_evaluation.stack_deepest > deepest_line_stack {
		deepest_line_stack = line_evaluation.stack_deepest
		system.log_fact(.Info, Evaluator_Stack_Deepest{stack_bytes = u64(deepest_line_stack), bound_bytes = u64(line_evaluation.stack_bytes)})
	}
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
		fail(record_name(record.file, record.detail), " has no field ", record.field, fields_text(Table{file = record.file, record = described}, record.field, "its"))
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
			described, _ := module.record_type(record.file, record.detail)
			fail(record_name(record.file, record.detail), " has no field ", record.field, fields_text(Table{file = record.file, record = described}, record.field, "its"))
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
	case .Not_A_Function:
		if record.parameter == 2 {
			fail("map: argument 2 is ", kind_names[record.left_kind], ", not a function")
		} else {
			fail(record.command, " is ", kind_names[record.left_kind], ", not a function: a call of a binding needs a function")
		}
	case .Function_Arguments:
		switch {
		case record.parameter == 2:
			fail("map calls its function with 1 argument, and this function takes ", arguments_text(record.right))
		case record.command == lex_evaluator.MAP_NAME:
			fail("map takes 2 arguments, a list and a function; the call gives ", arguments_text(record.left))
		case:
			fail(record.command, ": the call gives ", arguments_text(record.left), ", and the function takes ", arguments_text(record.right))
		}
	case .List_Item_Kind:
		if record.left_kind == .None {
			fail("an item of a list has no value: the expression gives none")
		} else {
			fail("a list holds no ", kind_names[record.left_kind], ": a ", kind_names[record.left_kind], " lives in the wiring of its line")
		}
	case .Value_At_Border:
		fail(record.command, ": argument ", i64(record.parameter), " is ", kind_names[record.left_kind], ": a function and a list stay in their line, and no command takes one")
	case .Stack_Exceeded:
		already := failed
		fail("the line nests deeper than the stack of the evaluator holds: ", record.right, " bytes; it stopped at column ", i64(record.place.column))
		if !already {
			failure_record_set(errors.error_make(.Over_Limit, .None, 0, record.left, record.right), "the stack of the evaluation", nil)
		}
	case .Calls_Full:
		fail("the line makes more calls of functions than the evaluator holds")
	case .Lists_Full:
		already := failed
		fail("the lists of the line hold more than ", i64(lex_evaluator.LIST_ITEM_CAPACITY), " items in all")
		if !already {
			failure_record_set(errors.error_make(.Over_Limit, .None, 0, i64(lex_evaluator.LIST_ITEM_CAPACITY) + 1, lex_evaluator.LIST_ITEM_CAPACITY), "the lists of the line", nil)
		}
	case .Not_A_List:
		fail(record.command, ": argument 1 is ", kind_names[record.left_kind], ", not a list")
	case .Condition_Not_Boolean:
		fail("a condition needs a Boolean value, not ", kind_names[record.left_kind])
	case .Depth_Exceeded:
		fail("the line nests deeper than the evaluator allows: ", record.right, " levels")
	case .With_Pairs_Full, .Imports_Full:
		fail("the evaluation ran out of room for declarations")
	case .Assertion_Failed:
		fail("assertion did not hold: ", record.command)
	case .Interpolation_Kind:
		fail("a string interpolation does not format ", kind_names[record.left_kind])
	case .Pattern_Not_A_Record:
		fail("a record pattern needs a record, not ", kind_names[record.left_kind])
	case .Pattern_Extra_Field:
		fail("the record has an extra field ", record.field, " that the pattern does not list; add \"...\" to allow extra fields")
	case .Unit_Mismatch:
		switch {
		case record.left_unit.kind != .None && record.right_unit.kind != .None:
			fail("unit", value_kinds.integer_unit_text(record.left_unit), " does not match", value_kinds.integer_unit_text(record.right_unit))
		case record.left_unit.kind != .None:
			fail("this operation takes a number with no unit, not", value_kinds.integer_unit_text(record.left_unit))
		case record.right_unit.kind != .None:
			fail("this operation takes", value_kinds.integer_unit_text(record.right_unit), ", not a number with no unit")
		case:
			fail("units do not match")
		}
	case .Literal_Path_Outside_With:
		fail("a dotted field path belongs only on the right of \"with\"")
	case .Duplicate_Field:
		fail("the record already has a field named ", record.field)
	case .Field_Name_Invalid:
		if record.field != "" {
			fail("the text \"", record.field, "\" is not a field name")
		} else {
			fail("a field name must be a Text, not ", kind_names[record.left_kind])
		}
	case .No_Matching_Arm:
		fail("no arm of match matched the value")
	case .Coalesce_Not_Field_Access:
		fail("\"??\" needs a field selection on its left, as record.field ?? fallback")
	case .Index_Out_Of_Bounds:
		fail(record.command, ": index ", record.left, " is outside the list length ", record.right)
	case .Parameter_Kind:
		pname := record.field != "" ? record.field : scratch_text(i64(record.parameter))
		fail("parameter ", pname, " takes ", param_annot_name(record.expected_annot), ", not ", kind_names[record.left_kind])
	case .Empty_Separator:
		fail(record.command, ": the separator text is empty")
	}
}

param_annot_name :: proc "contextless" (annot: lex_parser.Param_Kind_Annot) -> string {
	switch annot {
	case .None:       return "any value"
	case .Integer:    return "Integer"
	case .Boolean:    return "Boolean"
	case .Text:       return "Text"
	case .Hash:       return "Hash"
	case .List:       return "List"
	case .Record:     return "Record"
	case .Function:   return "Function"
	case .Enum:       return "Enum"
	case .Module_Ref: return "Module_Ref"
	case .Tree_Ref:   return "Tree_Ref"
	case .Recipe_Ref: return "Recipe_Ref"
	case .Follow_Ref: return "Follow_Ref"
	case .Store_Ref:  return "Store_Ref"
	case .Plan:       return "Plan"
	case .Project:    return "Project"
	case .Handle:     return "Handle"
	case .Table:      return "Table"
	case .Bytes:      return "Bytes"
	}
	return "value"
}

// arguments_text gives a count of arguments with its noun: "1 argument",
// "2 arguments". The text lasts for one line.
arguments_text :: proc "contextless" (count: i64) -> string {
	return scratch_text(count, count == 1 ? " argument" : " arguments")
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
	case .Parameter_Name_Missing:
		fail("a function takes names in its parentheses: (x, y) => x + y")
	case .Parameter_Twice:
		fail("the parameter ", lex_parser.node_text(&line_tree, record.node), " is named twice in one function")
	case .Too_Many_Parameters:
		fail("a function takes ", i64(lex_parser.ARGUMENT_CAPACITY), " parameters at most")
	case .List_Close_Missing:
		fail("\",\" or \"]\" is missing")
	case .Hash_Not_Valid:
		fail("a hash literal is \"blake3:\" followed by 64 lowercase hexadecimal digits")
	case .If_Then_Missing:
		fail("\"then\" is missing after the condition of if")
	case .If_Else_Missing:
		fail("\"else\" is missing in if")
	case .Nesting_Too_Deep:
		fail("the expression nests too deeply")
	case .Thin_Arrow:
		parameters, body := console_language.thin_arrow_function(line_tree.text, int(record.place.offset))
		if parameters == "" || body == "" {
			fail("\"->\" is no operator: a function is written (n) => n * n")
		} else {
			fail("\"->\" is no operator: a function is written (", parameters, ") => ", body)
		}
	case .Pipe_No_Left:
		fail("|> has no value on its left: write a value, then |> and a call")
	case .Pipe_Line_End:
		fail("the line ends after |>: a call or the name of a command comes after it")
	case .Pipe_Not_A_Call:
		fail("|> takes a call or the name of a command on its right, not \"", lex_parser.node_text(&line_tree, record.node), "\"")
	case .Lone_Bar:
		fail("\"|\" is no operator: the pipe operator is \"|>\"")
	case .Placeholder_Not_Whole:
		fail("|>: _ must be a whole argument of the call on the right, not part of an expression")
	case .Placeholder_Twice:
		fail("|>: the call has two _; the value on the left takes one place")
	case .Placeholder_Nested:
		fail("|>: _ names an argument of the call on the right of |>, not of a nested call")
	case .Placeholder_Without_Pipe:
		fail("_ is a place of the call on the right of |>; this call has no |> before it")
	case .Escape_Not_Valid:
		fail("unknown escape sequence in text: use \\\\, \\\", \\n, \\r, \\t, \\$, or \\u{...}")
	case .Interpolation_Close_Missing:
		fail("\"}\" is missing at the end of a string interpolation")
	case .Pattern_Field_Missing:
		fail("a record pattern holds field names or \"...\": { a, b = 1, ... }")
	case .Pattern_Close_Missing:
		fail("\",\" or \"}\" is missing in a record pattern")
	case .Pattern_Field_Twice:
		fail("the field ", lex_parser.node_text(&line_tree, record.node), " appears twice in one record pattern")
	case .Pattern_Rest_Not_Last:
		fail("\"...\" must be the last item of a record pattern")
	case .Pattern_At_Missing_Brace:
		fail("\"@\" in a pattern must be followed by \"{ ... }\"")
	case .Literal_Path_Conflict:
		fail("two field paths in one record literal overlap")
	case .Comp_Bind_Missing:
		fail("a binding name or record pattern is missing after \"for\"")
	case .Comp_In_Missing:
		fail("\"in\" is missing in a record comprehension")
	case .Comp_Colon_Missing:
		fail("\":\" is missing in a record comprehension")
	case .Comp_Equal_Missing:
		fail("\"=\" is missing between the key and value of a record comprehension")
	case .Match_Open_Missing:
		fail("\"{\" is missing after the value of match")
	case .Match_Close_Missing:
		fail("\",\" or \"}\" is missing in match")
	case .Match_Arrow_Missing:
		fail("\"=>\" is missing after a pattern of match")
	case .Match_Pattern_Expected:
		fail("a pattern is missing in match")
	case .Match_Duplicate_Bind:
		fail("a name is bound twice in one arm of match")
	case .Match_Empty:
		fail("match needs at least one arm")
	case .Param_Kind_Unknown:
		fail("unknown parameter kind after \":\"")
	case .Param_Unit_Not_Valid:
		fail("unknown unit name in Integer[...] parameter kind")
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
	// The names of the evaluation that make the values of a plan come before
	// a command of the same name (plan_rows.odin).
	if plan_signature, is_plan_name := plan_name_signature(name); is_plan_name {
		return plan_signature, true
	}
	// The arguments are forced before the call connects a service
	// (command_find_connecting in call_run): a signature from the image
	// connects nothing.
	item := command_known(name)
	if item == nil {
		command_unknown_fail(name)
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
		}
		// Any parameter of an export can be optional: an Integer, a Handle
		// or an Enum (src/md/features/module_settings.md).
		signature.optional[index] = item.run == nil && module.parameter_optional(item.function, index)
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
	if _, is_plan_name := plan_name_signature(name); is_plan_name {
		value = plan_name_run(name, arguments)
		return value, !failed
	}
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
		if variable.name_count > 0 && string(variable.name[:variable.name_count]) == name {
			if variable.value.kind == .List {
				return list_variable_read(&variable)
			}
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
				described, _ := module.record_type(variable.value.file, variable.value.detail)
				return fail(type_text(variable.value.file, .Record, variable.value.detail), " has no field ", name[split + 1:], fields_text(Table{file = variable.value.file, record = described}, name[split + 1:], "its"))
			}
		}
		break
	}
	// owner.stream: a record output of a process that the console started
	// or of a service that it connected.
	if value, named := stream_value_of_name(name); named {
		return value
	}
	nearest := console_language.nearest_names_start(name)
	for &variable in variables {
		console_language.nearest_name_offer(&nearest, string(variable.name[:clamp(variable.name_count, 0, VARIABLE_NAME_SIZE)]))
	}
	return fail("no variable has the name ", name, nearest_names_text(&nearest))
}

// service_export_split gives the service and the export of a name
// `service.export`, or ok false for a name with no period inside it.
service_export_split :: proc "contextless" (name: string) -> (service, export: string, ok: bool) {
	for character, index in transmute([]u8)name {
		if character == '.' {
			if index == 0 || index == len(name) - 1 {
				return "", "", false
			}
			return name[:index], name[index + 1:], true
		}
	}
	return "", "", false
}

// service_connected says if the console connected the service for its
// commands: its exports are commands already.
service_connected :: proc "contextless" (service: string) -> bool {
	for &sandbox in sandboxes {
		if sandbox.service && !sandbox.quiet && sandbox.process != 0 && sandbox.name == service {
			return true
		}
	}
	return false
}

// The command of an export of a module of the boot image that the console
// has not connected: its signature, read from the module file with no
// connection. It lasts until the next call of image_export_command.
image_export_pending: Command

// image_export_command gives the command of `service.export` from the
// module file of the boot image named service, when that file has the
// export and the service is not connected: the evaluator reads its
// signature and forces the arguments before any connection
// (command_find_connecting connects when the call runs). nil: no module of
// the image has the name, the module has no such export that the console
// can call, or the service is connected already.
image_export_command :: proc "contextless" (name: string) -> ^Command {
	service, export, split := service_export_split(name)
	if !split || service_connected(service) {
		return nil
	}
	file, _, found := image_module_file(service)
	if !found {
		return nil
	}
	head, _ := module.header(file)
	for index in 1 ..< module.count(file, .Exports) {
		if index == head.entry_export {
			continue
		}
		function, ok := module.function(file, index)
		if !ok || module.string_at(file, function.name_offset, function.name_count) != export {
			continue
		}
		if !export_command_make(&image_export_pending, file, index) {
			return nil
		}
		image_export_pending.name = name
		return &image_export_pending
	}
	return nil
}

// command_known gives the command of a name for the checks before a call:
// a command of the table, or the signature of an export of the image that
// is not connected yet. It connects nothing.
command_known :: proc "contextless" (name: string) -> ^Command {
	if found := command_find(name); found != nil {
		return found
	}
	return image_export_command(name)
}

// nearest_names_text gives "; did you mean a or b?" for the names that a
// search kept, or an empty text. The text lasts for one line.
nearest_names_text :: proc "contextless" (nearest: ^console_language.Nearest_Names) -> string {
	writer := sentence.Writer {
		buffer = scratch[scratch_count:],
	}
	console_condition.nearest_names_write(&writer, nearest)
	text := sentence.written(&writer)
	scratch_count += len(text)
	return text
}

// command_unknown_fail fails the line for a name that no command has, with
// the names of the commands near it, or the way to the list of all.
command_unknown_fail :: proc "contextless" (name: string) -> Value {
	nearest := console_language.nearest_names_start(name)
	for builtin_name in ([?]string{
		lex_evaluator.MAP_NAME,
		lex_evaluator.FILTER_NAME,
		lex_evaluator.FOLD_NAME,
		lex_evaluator.ZIP_NAME,
		lex_evaluator.FIELDS_NAME,
		lex_evaluator.VALUES_NAME,
		lex_evaluator.HAS_NAME,
		lex_evaluator.EXTEND_NAME,
		lex_evaluator.MERGE_DEEP_NAME,
		lex_evaluator.ASSERT_NAME,
		lex_evaluator.TRACE_NAME,
		lex_evaluator.FROM_ENTRIES_NAME,
		lex_evaluator.LEN_NAME,
		lex_evaluator.AT_NAME,
		lex_evaluator.SLICE_NAME,
		lex_evaluator.ANY_NAME,
		lex_evaluator.ALL_NAME,
		lex_evaluator.FLAT_MAP_NAME,
		lex_evaluator.UNIQUE_NAME,
		lex_evaluator.SORT_BY_NAME,
		lex_evaluator.SPLIT_NAME,
		lex_evaluator.JOIN_TEXT_NAME,
		lex_evaluator.STARTS_WITH_NAME,
		lex_evaluator.ENDS_WITH_NAME,
		lex_evaluator.CONTAINS_NAME,
		lex_evaluator.REPLACE_TEXT_NAME,
	}) {
		console_language.nearest_name_offer(&nearest, builtin_name)
	}
	for &command in commands[:command_count] {
		console_language.nearest_name_offer(&nearest, command.name)
	}
	// The exports of a module of the image that is not connected: a fault
	// in the name of an export gets the name, and connects nothing.
	if service, _, split := service_export_split(name); split && !service_connected(service) {
		if file, _, found := image_module_file(service); found {
			head, _ := module.header(file)
			for index in 1 ..< module.count(file, .Exports) {
				function, ok := module.function(file, index)
				if !ok || index == head.entry_export || !callable_by_console(file, function) {
					continue
				}
				console_language.nearest_name_offer(&nearest, scratch_text(service, ".", module.string_at(file, function.name_offset, function.name_count)))
			}
		}
	}
	if nearest.count == 0 {
		return fail("no command has the name ", name, "; try help()")
	}
	return fail("no command has the name ", name, nearest_names_text(&nearest))
}

// command_find_connecting gives the command that a call runs, after its
// arguments were forced. A name `service.export` of an export that the
// module file of the boot image named service has, when the console has not
// connected the service, connects it first, as connect(service) does: the
// root service checks that the principal may connect it, starts a service
// that starts at its first connection, and logs the connection. A module
// that is no service, or that the principal may not connect, fails the line
// with the refusal of connect, and the slot of the connection is free
// again. A name of an export that the file does not have asks for no
// connection: it gets the near names (command_unknown_fail).
command_find_connecting :: proc "contextless" (name: string) -> ^Command {
	if found := command_find(name); found != nil || failed {
		return found
	}
	if image_export_command(name) == nil {
		return nil
	}
	service, _, _ := service_export_split(name)
	connect_arguments := [1]Value{{kind = .Text, text = service}}
	connect_service(connect_arguments[:])
	if failed {
		return nil
	}
	return command_find(name)
}

// argument_count_fail fails a call with a count of arguments that its
// command does not take. help takes none: the help on one name is
// describe(name), so help(name) names that command.
argument_count_fail :: proc "contextless" (name: string, found: ^Command, count: int, topic := "let") -> Value {
	if name == "help" && count == 1 {
		return fail("help takes no argument: use describe(\"", topic, "\") for the help on one name, a command or a word of Lex")
	}
	return fail(name, " takes ", i64(found.parameter_count), " arguments, not ", i64(count))
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
	found := command_find_connecting(name)
	if found == nil {
		return failed ? {} : command_unknown_fail(name)
	}
	count := len(arguments)
	// A command whose last parameter may be left out takes one argument
	// less: start(name) and start(name, list).
	if count != found.parameter_count && !(found.optional_last && count == found.parameter_count - 1) {
		topic := count == 1 && arguments[0].kind == .Text ? arguments[0].text : "let"
		return argument_count_fail(name, found, count, topic)
	}
	for kind, index in found.parameters[:count] {
		argument := &arguments[index]
		// An optional parameter that the line leaves out has no value: the
		// call gives the Presence word Absent, then 0.
		if argument.kind == .None && found.run == nil && module.parameter_optional(found.function, index) {
			continue
		}
		// A plan given to a table of the rows of a plan becomes those rows
		// (plan_rows.odin); a refusal fails the line with its sentence.
		if !plan_rows_of_argument(found, index, argument) && failed {
			return {}
		}
		if !argument_accepted(found, index, argument^) {
			return argument_refusal(name, found, index, argument^)
		}
		if kind == .Integer {
			expected_unit := found.parameter_units[index]
			if expected_unit.kind == .None && found.run == nil && found.record == 0 {
				if u, uok := value_kinds.integer_unit_of_detail(found.function.parameter_details[index]); uok {
					expected_unit = u
				}
			}
			if argument.integer_unit.kind != .None || expected_unit.kind != .None {
				converted, ustatus := lex_evaluator.convert_integer_unit(argument.integer, argument.integer_unit, expected_unit, true)
				switch ustatus {
				case .Ok:
					argument.integer = converted
					argument.integer_unit = expected_unit
				case .Overflow:
					return fail(name, ": argument ", i64(index + 1), " does not fit in an Integer when converted to", value_kinds.integer_unit_text(expected_unit))
				case .Incompatible, .Non_Exact:
					if expected_unit.kind == .None {
						return fail(name, ": argument ", i64(index + 1), " takes a number with no unit, not", value_kinds.integer_unit_text(argument.integer_unit))
					}
					return fail(name, ": argument ", i64(index + 1), " takes", value_kinds.integer_unit_text(expected_unit), ", not", value_kinds.integer_unit_text(argument.integer_unit))
				}
			}
		}
		// The range of an Integer: the console refuses a value out of it
		// before the call; the export checks it again at its border.
		if kind == .Integer && found.run == nil && found.record == 0 {
			if setting, has_setting := module.parameter_setting(found.file, found.export, index); has_setting && module.parameter_setting_ranged(setting) && (argument.integer < setting.least || argument.integer > setting.most) {
				return fail(name, ": the argument ", found.parameter_names[index], " is ", argument.integer, ", outside its range ", setting.least, " to ", setting.most)
			}
		}
		// The bound of the bytes of a Text, as for a range.
		if kind == .Text && found.run == nil && found.record == 0 {
			if setting, has_setting := module.parameter_setting(found.file, found.export, index); has_setting && !module.text_in_bound(setting, argument.text) {
				return fail(name, ": the argument ", found.parameter_names[index], " has ", i64(len(argument.text)), " bytes, outside its bound of ", setting.least, " to ", setting.most, " bytes")
			}
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

// ---- The pipe operator (static left-type knowledge for completion).

// What the console knows, before the run, of the value on the left of a
// "|>".
Left_Knowledge :: enum u8 {
	None  = 0, // Nothing: the value comes when the line runs.
	Kind  = 1, // Its kind, not the record of a Table or of a Record.
	Whole = 2, // Its kind and its record: what argument_accepted reads.
}

// pipe_left_value_node gives what the console knows before the run of an AST
// node standing on the left of a "|>".
pipe_left_value_node :: proc "contextless" (tree: ^lex_parser.Syntax_Tree, left_idx: lex_parser.Node_Index) -> (value: Value, knowledge: Left_Knowledge) {
	node := lex_parser.node_at(tree, left_idx)
	if node == nil {
		return {}, .None
	}
	#partial switch node.kind {
	case .Integer:
		return {kind = .Integer}, .Whole
	case .Text:
		return {kind = .Text}, .Whole
	case .Name:
		name := lex_parser.node_text(tree, left_idx)
		for &variable in variables {
			if variable.name_count > 0 && string(variable.name[:variable.name_count]) == name {
				return variable.value, .Whole
			}
		}
		if file, detail, kind, known := stream_name_known(name); known {
			return {kind = kind, file = file, detail = detail}, .Whole
		}
	case .Call:
		return result_knowledge(command_find(lex_parser.node_text(tree, left_idx)))
	case .Pipe:
		_, right := lex_parser.node_binary_children(tree, left_idx)
		if rn := lex_parser.node_at(tree, right); rn != nil && rn.kind == .Call {
			return result_knowledge(command_find(lex_parser.node_text(tree, right)))
		}
	}
	return {}, .None
}

// pipe_left_record_node gives the record of the table on the left of a pipe
// stage when known statically: the result of an export, a `facts(...)` stage,
// or a stage that preserves its left record (`where`, `sort`, `first`, `skip`,
// `table`).
pipe_left_record_node :: proc "contextless" (tree: ^lex_parser.Syntax_Tree, left_idx: lex_parser.Node_Index, left: Value, knowledge: Left_Knowledge, description_buffer: []u8 = nil) -> (file: []u8, detail: u32, known: bool) {
	if knowledge == .Whole && (left.kind == .Table || left.kind == .Stream) && left.file != nil {
		return left.file, left.detail, true
	}
	node := lex_parser.node_at(tree, left_idx)
	if node == nil || node.kind != .Pipe {
		return nil, 0, false
	}
	prev_left, right := lex_parser.node_binary_children(tree, left_idx)
	rn := lex_parser.node_at(tree, right)
	if rn == nil || rn.kind != .Call {
		return nil, 0, false
	}
	before_name := lex_parser.node_text(tree, right)
	before_command := command_find(before_name)
	if before_command == nil || before_command.run == nil {
		return nil, 0, false
	}
	switch before_name {
	case "where", "sort", "first", "skip", "table":
		before_left, before_knowledge := pipe_left_value_node(tree, prev_left)
		return pipe_left_record_node(tree, prev_left, before_left, before_knowledge, description_buffer)
	}
	args := lex_parser.node_children(tree, right)
	if before_command.parameter_forms[1] != .Fact_Name || len(args) != 1 {
		return nil, 0, false
	}
	arg := args[0]
	an := lex_parser.node_at(tree, arg)
	if an == nil || (an.kind != .Fact_Name && an.kind != .Name) {
		return nil, 0, false
	}
	return facts_description(lex_parser.node_text(tree, arg), description_buffer)
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
	case .Stream, .Record_Input, .Record_Literal, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Tree_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
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
