// The evaluator of Lex: it evaluates a syntax tree of lex_parser in an
// evaluation mode (src/md/features/declarations.md, "The evaluator
// package").
//
// Each node of the tree is a thunk, forced at most once: a second force
// gives the kept value, costs no step and runs no effect again. A call asks
// the evaluation host for its command, forces its arguments from the left,
// then the host runs it, so the effects run in the order of the data. Mode
// `console` forces the root, which reaches each node of a line; mode
// `declaration` refuses a call whose command has an effect, at its border.
//
// The evaluator writes no text: a refusal is a record with its place, and
// the host writes its sentence. The first refusal ends the evaluation.
//
// The package has no state, calls no allocator and makes no kernel call:
// the caller gives the memory of the evaluation, and host tests give a fake
// host.
package lex_evaluator

import module "modus:contract/module"
import "modus:private/console/console_condition"
import "modus:private/console/console_language"
import "modus:private/console/lex_parser"

// The steps of one evaluation, the same in both modes. A step is one thunk
// computed. The measure over the declarations of the system sets the bound
// when the evaluator first runs one; until then it is far above the steps
// of the longest line of the console, NODE_CAPACITY.
EVALUATION_BUDGET_STEPS :: 1 << 20

#assert(lex_parser.NODE_CAPACITY * 5000 < EVALUATION_BUDGET_STEPS)

// The two ways that the one evaluator runs.
Evaluation_Mode :: enum u8 {
	Console     = 0, // In the console: each effect runs, and each line is forced whole.
	Declaration = 1, // In the evaluation process: a call with an effect is refused at its border.
}

// The kinds of the values of Lex. The values up to Bytes are those of
// module.Type: the kind of a parameter is its type. Stream and Record_Input
// are kinds of the console only: no export takes or gives one.
Kind :: enum u8 {
	None           = 0,
	Integer        = 1,
	Text           = 2,
	Record         = 3,
	Handle         = 4,
	Table          = 5,
	Bytes          = 6, // A parameter: a Text value is its argument. A value: bytes with no description, which the console draws.
	Stream         = 7, // A record output of a process, read while the line runs. No variable keeps one.
	Record_Input   = 8, // A record input of a process, by its typed name: wire names it. No variable keeps one.
	Record_Literal = 9, // A record literal not typed yet: integer is its node. Its receiver types it; nothing else keeps one.
	Enum           = 10, // A member of an enum: integer is its value; file and detail name the enum (module.enum_type). A parameter: an Enum of an export.
	Member         = 11, // A member not typed yet, `.french`: integer is its node. The Enum parameter that receives it types it; nothing else keeps one.
}

// The fields of a record at most: those of a record that a call carries.
LITERAL_FIELD_CAPACITY :: module.RECORD_SIZE_LIMIT / 4

// A value of Lex. A parameter of a command of the console with the kind
// None takes a value of any kind: the command checks it.
Value :: struct {
	kind:      Kind,
	integer:   i64, // An Integer. A Handle: the handle. A Stream: its place in the streams of the host.
	text:      string,
	record:    []u8, // A Record: its bytes. A Table: the bytes of its records.
	file:      []u8, // A Record, a Table, a Stream or a Record_Input: the module that has the description of the record.
	detail:    u32, // A Record, a Table, a Stream or a Record_Input: the index of the description of the record in the module.
	condition: ^console_condition.Condition, // The argument of a parameter of the form Condition, in the memory of the host.
}

// Why an evaluation stopped. The values are fixed: a test names the member,
// and a record keeps it.
Refusal :: enum u8 {
	None                  = 0, // The evaluation runs, or it gave its value.
	Text                  = 1, // A refusal of the parser: text_refusal says which, node is the refused node.
	Operator_Kinds        = 2, // An operator on two kinds that it does not take: operator, left_kind, right_kind.
	Negate_Kind           = 3, // "-" before a value that is no Integer: left_kind.
	Overflow              = 4, // A result that does not fit in an Integer: operator, left, right. "-" before a value is Subtract with left 0.
	Division_By_Zero      = 5, // "/" or "%" by 0.
	Budget_Exceeded       = 6, // A thunk to compute past the budget: steps is the budget, the place is the node.
	Effect_Refused        = 7, // Mode `declaration`: a call of a command with an effect. command names it.
	Host_Refused          = 8, // The host refused a name, a call, a condition or a fact name, and wrote its own failure.
	Literal_No_Type       = 9, // A record literal that nothing types: the value of the line, or a parameter that is no Record (command, parameter, right_kind).
	Literal_Field_Unknown = 10, // A field of a literal that the record does not have: field, file, detail.
	Literal_Field_Missing = 11, // A field of the record that the literal does not give: field, file, detail.
	Literal_Field_Kind    = 12, // A value of another kind than its field: field, field_item, left_kind, file, detail.
	Literal_Field_Range   = 13, // A value that its field cannot hold: field, field_item, left (an Integer) or right (the bytes of a Text), file, detail.
	Argument_Unknown      = 14, // A named argument that names no parameter: command, field.
	Argument_Twice        = 15, // A parameter given by its place and by its name: command, field.
	Argument_Missing      = 16, // A parameter that a call with named arguments does not give: command, field.
	With_Kinds            = 17, // `with` on another value than a record on its left, or a record or a literal on its right: left_kind, right_kind.
	With_Records_Differ   = 18, // `with` on two records of two descriptions: file, detail, other_file, other_detail.
	Field_Unknown         = 19, // `binding.field` with no such field: field, and file and detail of a record, or left_kind.
	Cycle                 = 20, // A binding that its own value needs: command is its name.
	Member_No_Type        = 21, // A member that nothing types: the value of the line, or a parameter that is no Enum (command, parameter, right_kind).
	Member_Unknown        = 22, // A member that the enum of its parameter does not have: field is its name; command, parameter, file and detail name the enum.
}

// The first refusal of an evaluation, and what its sentence needs.
Refusal_Record :: struct {
	refusal:      Refusal,
	place:        lex_parser.Place, // The node where the evaluation stopped.
	node:         lex_parser.Node_Index,
	operator:     lex_parser.Operator, // Operator_Kinds, Overflow.
	left_kind:    Kind, // Operator_Kinds, Negate_Kind, With_Kinds, Literal_Field_Kind, Field_Unknown.
	right_kind:   Kind, // Operator_Kinds, With_Kinds, Literal_No_Type: the kind of the parameter.
	left:         i64, // Overflow, Literal_Field_Range.
	right:        i64, // Overflow, Literal_Field_Range.
	text_refusal: lex_parser.Refusal, // Text.
	command:      string, // Effect_Refused, Literal_No_Type, the Argument refusals, Cycle; Text with Field_Name_Missing: the call.
	steps:        u32, // Budget_Exceeded: the budget.
	parameter:    int, // Literal_No_Type: the parameter that receives the literal, from 1; 0: the value of the line.
	field:        string, // The field or the parameter that the refusal names.
	field_item:   module.Field, // Literal_Field_Kind, Literal_Field_Range: the field of the record.
	file:         []u8, // The record of a literal refusal, of With_Records_Differ (left), of Field_Unknown.
	detail:       u32,
	other_file:   []u8, // With_Records_Differ: the record on the right.
	other_detail: u32,
}

// What the host says of a command: its effect and its parameters.
Command_Signature :: struct {
	has_effect:      bool, // An effect: mode `declaration` refuses the call.
	parameter_count: int,
	optional_last:   bool, // A call may leave out the last parameter.
	optional:        [lex_parser.ARGUMENT_CAPACITY]bool, // A call may leave out this parameter, an Enum: the host gives its absent word.
	names:           [lex_parser.ARGUMENT_CAPACITY]string, // The name of each parameter, or "": the command has none.
	kinds:           [lex_parser.ARGUMENT_CAPACITY]Kind,
	files:           [lex_parser.ARGUMENT_CAPACITY][]u8, // A Record or an Enum parameter: the module that describes its record or its enum, or nil.
	details:         [lex_parser.ARGUMENT_CAPACITY]u32, // A Record parameter: its description in the module. An Enum parameter: the index of its enum.
}

// What only the host knows. Each procedure that gives ok false has written
// the failure of the host; the evaluator then stops with Host_Refused.
Evaluation_Host :: struct {
	data:            rawptr, // The state of the host.
	name_value:      proc "contextless" (data: rawptr, name: string) -> (value: Value, ok: bool), // A name alone: a variable, or a field of one.
	command_find:    proc "contextless" (data: rawptr, name: string) -> (signature: Command_Signature, found: bool), // The command of a call, before its arguments.
	record_memory:   proc "contextless" (data: rawptr, size: int) -> (bytes: []u8, ok: bool), // Zero bytes for a record that a literal makes, for the evaluation.
	call_run:        proc "contextless" (data: rawptr, name: string, arguments: []Value) -> (value: Value, ok: bool), // Checks the arguments and runs the call: the effect.
	condition_value: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Value, node: lex_parser.Node_Index) -> (value: Value, ok: bool), // A Condition node; it forces the value of the condition through force when it needs it.
	fact_name_value: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Value, ok: bool), // A Fact_Name node.
	values_add:      proc "contextless" (data: rawptr, left, right: Value) -> (sum: Value, ok: bool), // "+" of two Texts, which it joins, or of two Tables, whose rows it joins: in the memory of the host.
}

// The state of a thunk.
Thunk_State :: enum u8 {
	Unforced = 0,
	Forced   = 1, // value is kept.
	Forcing  = 2, // Its value is being computed: a force now is a cycle.
}

Thunk :: struct {
	state: Thunk_State,
	value: Value,
}

// One evaluation of one tree, in the memory of the caller.
Evaluation :: struct {
	tree:    ^lex_parser.Syntax_Tree,
	mode:    Evaluation_Mode,
	host:    Evaluation_Host,
	budget:  u32, // The steps that the evaluation may take.
	steps:   u32, // The steps taken.
	thunks:  [lex_parser.NODE_CAPACITY]Thunk, // One for each node of the tree, by its index.
	refusal: Refusal_Record,
}

// evaluation_start makes an evaluation of a tree ready: each thunk
// unforced, no step, no refusal. Each host gives the default budget; a
// host test gives a smaller one, so that a tree of the parser reaches it.
evaluation_start :: proc "contextless" (evaluation: ^Evaluation, tree: ^lex_parser.Syntax_Tree, mode: Evaluation_Mode, host: Evaluation_Host, budget: u32 = EVALUATION_BUDGET_STEPS) {
	evaluation.tree, evaluation.mode, evaluation.host, evaluation.budget, evaluation.steps = tree, mode, host, budget, 0
	evaluation.refusal = {}
	for &thunk in evaluation.thunks[:clamp(tree.node_count, 0, len(evaluation.thunks))] {
		thunk = {}
	}
}

// refused says if the evaluation stopped.
refused :: proc "contextless" (evaluation: ^Evaluation) -> bool {
	return evaluation.refusal.refusal != .None
}

// line_force forces the root of the tree: in mode `console`, the whole
// line. A tree that a bound of the parser cut is not whole in its places,
// so nothing of it is forced.
line_force :: proc "contextless" (evaluation: ^Evaluation) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	switch tree.refusal.refusal {
	case .Text_Too_Long, .Nodes_Full:
		return refuse(evaluation, {refusal = .Text, text_refusal = tree.refusal.refusal, place = tree.refusal.place, node = tree.root})
	case .None, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice, .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing, .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name:
	}
	value = force(evaluation, tree.root) or_return
	// The value of a line is drawn or kept: a literal or a member that
	// nothing typed has no type to draw or keep.
	if value.kind == .Record_Literal {
		literal := lex_parser.Node_Index(value.integer)
		return refuse(evaluation, {refusal = .Literal_No_Type, place = lex_parser.node_at(tree, literal).place, node = literal})
	}
	if value.kind == .Member {
		member := lex_parser.Node_Index(value.integer)
		return refuse(evaluation, {refusal = .Member_No_Type, place = lex_parser.node_at(tree, member).place, node = member})
	}
	return value, true
}

// force gives the value of a node: the kept value of a forced thunk, or
// the value computed now, for one step. ok is false once the evaluation
// stopped.
force :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	return argument_force(evaluation, index, "", nil)
}

// argument_force forces a node that is an argument of the call command_name,
// after the arguments before. A condition and a fact name are read through
// the host, which needs the call.
@(private)
argument_force :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, command_name: string, before: []Value) -> (value: Value, ok: bool) {
	if refused(evaluation) {
		return {}, false
	}
	node := lex_parser.node_at(evaluation.tree, index)
	if node == nil {
		// Only a bound of the parser leaves a node with no child, and
		// line_force refuses such a tree first.
		return refuse(evaluation, {refusal = .Text, text_refusal = .Nodes_Full, place = evaluation.tree.refusal.place, node = index})
	}
	thunk := &evaluation.thunks[int(index)]
	switch thunk.state {
	case .Forced:
		return thunk.value, true
	case .Forcing:
		// The computation of this thunk needs its own value. A binding
		// refuses it first, with the place of its name.
		return refuse(evaluation, {refusal = .Cycle, place = node.place, node = index})
	case .Unforced:
	}
	if evaluation.steps >= evaluation.budget {
		return refuse(evaluation, {refusal = .Budget_Exceeded, place = node.place, node = index, steps = evaluation.budget})
	}
	evaluation.steps += 1
	thunk.state = .Forcing
	value, ok = compute(evaluation, index, node, command_name, before)
	if !ok {
		return {}, false
	}
	thunk.state, thunk.value = .Forced, value
	return value, true
}

// refuse keeps the first refusal of the evaluation.
@(private)
refuse :: proc "contextless" (evaluation: ^Evaluation, record: Refusal_Record) -> (value: Value, ok: bool) {
	if !refused(evaluation) {
		evaluation.refusal = record
	}
	return {}, false
}

// host_answer keeps what the host gave: its refusal when it wrote a
// failure, or the refusal of the evaluator when a force inside the host
// stopped the evaluation.
@(private)
host_answer :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, value: Value, ok: bool) -> (Value, bool) {
	if refused(evaluation) {
		return {}, false
	}
	if !ok {
		return refuse(evaluation, {refusal = .Host_Refused, place = node.place, node = index})
	}
	return value, true
}

@(private)
compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, command_name: string, before: []Value) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	host := evaluation.host
	switch node.kind {
	case .Integer:
		return {kind = .Integer, integer = node.integer}, true
	case .Text:
		quoted := lex_parser.node_text(tree, index)
		return {kind = .Text, text = quoted[1:len(quoted) - 1]}, true
	case .Name:
		if node.binding != lex_parser.NO_NODE {
			return binding_value(evaluation, index, node)
		}
		value, ok = host.name_value(host.data, lex_parser.node_text(tree, index))
		return host_answer(evaluation, index, node, value, ok)
	case .Record_Literal:
		// The values from the left; the receiver gives the type.
		for field := node.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(tree, field) {
			field_node := lex_parser.node_at(tree, field)
			if _, forced := force(evaluation, field_node.kind == .Literal_Field ? field_node.first_child : field); !forced {
				return {}, false
			}
		}
		return {kind = .Record_Literal, integer = i64(index)}, true
	case .Let:
		return let_compute(evaluation, node)
	case .Member:
		// The name only; the Enum parameter that receives it gives the enum.
		return {kind = .Member, integer = i64(index)}, true
	case .Literal_Field, .Named_Argument, .Let_Binding:
		// Their parent forces their value.
		break
	case .Call:
		return call_compute(evaluation, index, node)
	case .Negate:
		return negate_compute(evaluation, index, node)
	case .Binary:
		return binary_compute(evaluation, index, node)
	case .Condition:
		if command_name == "" {
			break
		}
		value, ok = host.condition_value(host.data, evaluation, command_name, before, index)
		return host_answer(evaluation, index, node, value, ok)
	case .Fact_Name:
		if command_name == "" {
			break
		}
		value, ok = host.fact_name_value(host.data, evaluation, command_name, index)
		return host_answer(evaluation, index, node, value, ok)
	case .Field_Names:
		if command_name == "" {
			break
		}
		if node.refusal == .Field_Name_Missing {
			return refuse(evaluation, {refusal = .Text, text_refusal = .Field_Name_Missing, place = node.place, node = index, command = command_name})
		}
		// The names as the line has them: the command checks each one
		// against the record of its table.
		return {kind = .Text, text = lex_parser.node_text(tree, index)}, true
	case .Refused:
		// The part that the parser read before the fault runs first.
		if node.first_child != lex_parser.NO_NODE {
			if _, before_ok := force(evaluation, node.first_child); !before_ok {
				return {}, false
			}
		}
		return refuse(evaluation, {refusal = .Text, text_refusal = node.refusal, place = node.place, node = index})
	}
	// The parser makes a condition, a fact name and field names only as an
	// argument of a call, which forces them with its name.
	return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = node.place, node = index})
}

// let_compute forces the bindings of a let from the left, in mode
// `console`, then its body: the line is forced whole. In mode `declaration`
// a binding is forced when a value needs it.
@(private)
let_compute :: proc "contextless" (evaluation: ^Evaluation, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	body := lex_parser.NO_NODE
	for child := node.first_child; child != lex_parser.NO_NODE; child = lex_parser.next_of(tree, child) {
		if lex_parser.node_at(tree, child).kind != .Let_Binding {
			body = child
		}
	}
	// With no body, the parse stopped in a binding: its refusal is met there.
	whole := evaluation.mode == .Console || body == lex_parser.NO_NODE
	for child := node.first_child; whole && child != lex_parser.NO_NODE; child = lex_parser.next_of(tree, child) {
		child_node := lex_parser.node_at(tree, child)
		if child_node.kind != .Let_Binding {
			continue
		}
		if _, forced := binding_force(evaluation, child, child_node, child_node.place); !forced {
			return {}, false
		}
	}
	if body == lex_parser.NO_NODE {
		// A let with no body holds the refusal of the text in a binding,
		// which the loop above met: this stays a refusal in any case.
		return refuse(evaluation, {refusal = .Text, text_refusal = .Let_In_Missing, place = node.place, node = lex_parser.NO_NODE})
	}
	return force(evaluation, body)
}

// binding_force gives the value of a binding: the thunk of its value. A
// value that its own computation needs is a cycle, refused at place: the
// name that closes it.
@(private)
binding_force :: proc "contextless" (evaluation: ^Evaluation, binding: lex_parser.Node_Index, binding_node: ^lex_parser.Node, place: lex_parser.Place) -> (value: Value, ok: bool) {
	value_index := binding_node.first_child
	if lex_parser.node_at(evaluation.tree, value_index) != nil && evaluation.thunks[int(value_index)].state == .Forcing {
		return refuse(evaluation, {refusal = .Cycle, place = place, node = binding, command = lex_parser.node_text(evaluation.tree, binding)})
	}
	return force(evaluation, value_index)
}

// binding_value gives the value of a name that a let binds: the value of
// the binding, or one field of it after a '.'.
@(private)
binding_value :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	binding_node := lex_parser.node_at(tree, node.binding)
	value = binding_force(evaluation, node.binding, binding_node, node.place) or_return
	name := lex_parser.node_text(tree, index)
	binding_name := lex_parser.node_text(tree, node.binding)
	if len(name) <= len(binding_name) + 1 {
		// The name alone; "a." has no field and reads as the name.
		return value, true
	}
	field := name[len(binding_name) + 1:]
	record := Refusal_Record {
		refusal   = .Field_Unknown,
		place     = node.place,
		node      = index,
		field     = field,
		left_kind = value.kind,
	}
	switch value.kind {
	case .Record:
		if found, found_ok := record_field_value(value, field); found_ok {
			return found, true
		}
		record.file, record.detail = value.file, value.detail
	case .Record_Literal:
		literal := lex_parser.Node_Index(value.integer)
		field_index := literal_field_find(tree, literal, field)
		if field_index != lex_parser.NO_NODE {
			return force(evaluation, lex_parser.node_at(tree, field_index).first_child)
		}
	case .None, .Integer, .Text, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Member:
		// A value with no fields.
	}
	return refuse(evaluation, record)
}

// record_field_value gives one field of a Record value, by name: an
// Integer, a Handle, a Text, or the Bytes of a hash.
record_field_value :: proc "contextless" (value: Value, name: string) -> (result: Value, ok: bool) {
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
			return {kind = .Handle, integer = i64(handle_of(value.record, item))}, true
		case .Text:
			return {kind = .Text, text = module.field_text(value.record, item)}, true
		case .Bytes:
			// A hash: the console draws its bytes.
			return {kind = .Bytes, record = module.field_bytes(value.record, item)}, true
		case .None, .Record, .Table, .Enum:
			// A field of a record holds no such value: the field gives none.
			return {}, false
		}
	}
	return {}, false
}

// handle_of reads the 4 bytes of a Handle field, from the lowest byte.
@(private)
handle_of :: proc "contextless" (record: []u8, item: module.Field) -> u32 {
	if u64(item.offset) > u64(len(record)) || u64(len(record)) - u64(item.offset) < 4 {
		return 0
	}
	handle: u32
	for index in 0 ..< u32(4) {
		handle |= u32(record[item.offset + index]) << (8 * index)
	}
	return handle
}

// literal_field_find gives the field of a literal with a name, or NO_NODE.
@(private)
literal_field_find :: proc "contextless" (tree: ^lex_parser.Syntax_Tree, literal: lex_parser.Node_Index, name: string) -> lex_parser.Node_Index {
	literal_node := lex_parser.node_at(tree, literal)
	if literal_node == nil {
		return lex_parser.NO_NODE
	}
	for field := literal_node.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(tree, field) {
		if lex_parser.node_at(tree, field).kind == .Literal_Field && lex_parser.node_text(tree, field) == name {
			return field
		}
	}
	return lex_parser.NO_NODE
}

// ---- The typing of a record literal by its receiver.

// record_field_find gives the number of a field of a record with a name.
@(private)
record_field_find :: proc "contextless" (file: []u8, described: module.Record, name: string) -> (item: module.Field, number: u32, found: bool) {
	for candidate in 0 ..< described.field_count {
		candidate_item := module.field(file, described, candidate) or_continue
		if module.string_at(file, candidate_item.name_offset, candidate_item.name_count) == name {
			return candidate_item, candidate, true
		}
	}
	return {}, 0, false
}

// literal_names_check checks the names of the fields of a literal against
// a record: each one is a field of the record, and, for a whole literal,
// each field of the record is given. It reads no value, so a call checks
// it before its arguments run.
@(private)
literal_names_check :: proc "contextless" (evaluation: ^Evaluation, literal: lex_parser.Node_Index, file: []u8, detail: u32, whole: bool) -> bool {
	tree := evaluation.tree
	literal_node := lex_parser.node_at(tree, literal)
	described, described_ok := module.record_type(file, detail)
	if literal_node == nil || !described_ok {
		place: lex_parser.Place
		if literal_node != nil {
			place = literal_node.place
		}
		refuse(evaluation, {refusal = .Literal_No_Type, place = place, node = literal})
		return false
	}
	given: [LITERAL_FIELD_CAPACITY]bool
	for field := literal_node.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(tree, field) {
		field_node := lex_parser.node_at(tree, field)
		if field_node.kind != .Literal_Field {
			// A refusal of the text, which the values met.
			continue
		}
		name := lex_parser.node_text(tree, field)
		_, number, found := record_field_find(file, described, name)
		if !found {
			refuse(evaluation, {refusal = .Literal_Field_Unknown, place = field_node.place, node = field, field = name, file = file, detail = detail})
			return false
		}
		if number < LITERAL_FIELD_CAPACITY {
			given[number] = true
		}
	}
	if !whole {
		return true
	}
	for number in 0 ..< min(described.field_count, LITERAL_FIELD_CAPACITY) {
		if given[number] {
			continue
		}
		item, _ := module.field(file, described, number)
		refuse(evaluation, {refusal = .Literal_Field_Missing, place = literal_node.place, node = literal, field = module.string_at(file, item.name_offset, item.name_count), file = file, detail = detail})
		return false
	}
	return true
}

// literal_typed gives the record of a literal of the record file:detail:
// a whole one, or base with the fields of the literal in place of its own
// for `with`. The values are forced already; each is checked against its
// field, and written in the memory of the host.
@(private)
literal_typed :: proc "contextless" (evaluation: ^Evaluation, value: Value, file: []u8, detail: u32, base: []u8) -> (typed: Value, ok: bool) {
	tree := evaluation.tree
	literal := lex_parser.Node_Index(value.integer)
	if !literal_names_check(evaluation, literal, file, detail, base == nil) {
		return {}, false
	}
	described, _ := module.record_type(file, detail)
	host := evaluation.host
	bytes, memory_ok := host.record_memory(host.data, int(described.size))
	literal_node := lex_parser.node_at(tree, literal)
	if !memory_ok || len(bytes) < int(described.size) {
		return host_answer(evaluation, literal, literal_node, {}, false)
	}
	if base != nil {
		copy(bytes, base)
	}
	for field := literal_node.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(tree, field) {
		field_node := lex_parser.node_at(tree, field)
		if field_node.kind != .Literal_Field {
			continue
		}
		name := lex_parser.node_text(tree, field)
		item, _, _ := record_field_find(file, described, name)
		field_value := force(evaluation, field_node.first_child) or_return
		record := Refusal_Record {
			refusal    = .Literal_Field_Kind,
			place      = field_node.place,
			node       = field,
			field      = name,
			field_item = item,
			left_kind  = field_value.kind,
			file       = file,
			detail     = detail,
		}
		type, _ := module.field_type(item)
		switch type {
		case .Integer:
			if field_value.kind != .Integer {
				return refuse(evaluation, record)
			}
			if !module.field_integer_fits(item, field_value.integer) {
				record.refusal, record.left = .Literal_Field_Range, field_value.integer
				return refuse(evaluation, record)
			}
			module.field_integer_set(bytes, item, field_value.integer)
		case .Text:
			if field_value.kind != .Text {
				return refuse(evaluation, record)
			}
			if len(field_value.text) > int(item.detail) {
				record.refusal, record.right = .Literal_Field_Range, i64(len(field_value.text))
				return refuse(evaluation, record)
			}
			text_place := bytes[item.offset:][:item.detail]
			for &cell in text_place {
				cell = 0
			}
			copy(text_place, field_value.text)
		case .Handle:
			if field_value.kind != .Handle {
				return refuse(evaluation, record)
			}
			for index in 0 ..< u32(4) {
				bytes[item.offset + index] = u8(u64(field_value.integer) >> (8 * index))
			}
		case .Bytes:
			if field_value.kind != .Bytes || len(field_value.record) != int(item.detail) {
				return refuse(evaluation, record)
			}
			copy(bytes[item.offset:][:item.detail], field_value.record)
		case .None, .Record, .Table, .Enum:
			return refuse(evaluation, record)
		}
	}
	return {kind = .Record, record = bytes[:described.size], file = file, detail = detail}, true
}

// call_compute asks the host for the command first, so a name that no
// command has fails before its arguments; then it forces the arguments from
// the left, and the host runs the call.
@(private)
call_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	host := evaluation.host
	name := lex_parser.node_text(tree, index)
	signature, found := host.command_find(host.data, name)
	if !found {
		return host_answer(evaluation, index, node, {}, false)
	}
	// At the border: nothing of the call is forced, and nothing runs.
	if evaluation.mode == .Declaration && signature.has_effect {
		return refuse(evaluation, {refusal = .Effect_Refused, place = node.place, node = index, command = name})
	}
	parameter_count := clamp(signature.parameter_count, 0, lex_parser.ARGUMENT_CAPACITY)
	// The names, before any argument runs: the parameter of each argument,
	// and the fields of each literal that a Record parameter receives.
	slots: [lex_parser.ARGUMENT_CAPACITY]lex_parser.Node_Index
	for &slot in slots {
		slot = lex_parser.NO_NODE
	}
	positional := 0
	named := false
	count := 0
	for argument := node.first_child; argument != lex_parser.NO_NODE; argument = lex_parser.next_of(tree, argument) {
		argument_node := lex_parser.node_at(tree, argument)
		slot := -1
		switch argument_node.kind {
		case .Refused:
			// A refusal of the text: the arguments before it run, then it.
			continue
		case .Named_Argument:
			named = true
			argument_name := lex_parser.node_text(tree, argument)
			for parameter_name, parameter in signature.names[:parameter_count] {
				if parameter_name != "" && parameter_name == argument_name {
					slot = parameter
				}
			}
			if slot < 0 {
				return refuse(evaluation, {refusal = .Argument_Unknown, place = argument_node.place, node = argument, command = name, field = argument_name})
			}
			if slots[slot] != lex_parser.NO_NODE {
				return refuse(evaluation, {refusal = .Argument_Twice, place = argument_node.place, node = argument, command = name, field = argument_name})
			}
		case .Integer, .Text, .Name, .Call, .Negate, .Binary, .Condition, .Fact_Name, .Field_Names, .Record_Literal, .Literal_Field, .Let, .Let_Binding, .Member:
			if positional == len(slots) {
				continue
			}
			slot = positional
			positional += 1
		}
		slots[slot] = argument
		count = max(count, slot + 1)
		literal := argument_node.kind == .Named_Argument ? argument_node.first_child : argument
		if literal_node := lex_parser.node_at(tree, literal); literal_node != nil && literal_node.kind == .Record_Literal && slot < parameter_count {
			if signature.kinds[slot] != .Record || signature.files[slot] == nil {
				return refuse(evaluation, {refusal = .Literal_No_Type, place = literal_node.place, node = literal, command = name, parameter = slot + 1, right_kind = signature.kinds[slot]})
			}
			if !literal_names_check(evaluation, literal, signature.files[slot], signature.details[slot], true) {
				return {}, false
			}
		}
		// A member is checked against the enum of its parameter here, at
		// its place, before any argument of the call runs.
		if member_node := lex_parser.node_at(tree, literal); member_node != nil && member_node.kind == .Member && slot < parameter_count {
			if _, typed := member_typed(evaluation, literal, name, slot, signature); !typed {
				return {}, false
			}
		}
	}
	// A parameter that the call does not give: an optional one, and the
	// last one that a call may leave out, get no value; the host gives an
	// optional Enum its absent word. A call with named arguments gives each
	// other parameter; a call by place that misses one is refused by the
	// host, which counts its arguments.
	missing := false
	for parameter in 0 ..< parameter_count {
		if slots[parameter] != lex_parser.NO_NODE || parameter == parameter_count - 1 && signature.optional_last || signature.optional[parameter] {
			continue
		}
		if named {
			return refuse(evaluation, {refusal = .Argument_Missing, place = node.place, node = index, command = name, field = signature.names[parameter]})
		}
		missing = true
	}
	if named || !missing {
		count = max(count, parameter_count - (signature.optional_last && parameter_count > 0 && slots[parameter_count - 1] == lex_parser.NO_NODE ? 1 : 0))
	}
	// The values, in the order of the line.
	arguments: [lex_parser.ARGUMENT_CAPACITY]Value
	for argument := node.first_child; argument != lex_parser.NO_NODE; argument = lex_parser.next_of(tree, argument) {
		argument_node := lex_parser.node_at(tree, argument)
		slot := -1
		for candidate, place in slots {
			if candidate == argument {
				slot = place
			}
		}
		argument_value: Value
		if argument_node.kind == .Named_Argument {
			argument_value = force(evaluation, argument_node.first_child) or_return
		} else {
			// A condition reads the arguments before it.
			argument_value = argument_force(evaluation, argument, name, arguments[:max(slot, 0)]) or_return
		}
		if slot < 0 {
			// The parser ends the arguments with a refusal past the
			// capacity: its force failed above.
			return refuse(evaluation, {refusal = .Text, text_refusal = .Too_Many_Arguments, place = argument_node.place, node = argument})
		}
		if argument_value.kind == .Record_Literal {
			if slot >= parameter_count || signature.kinds[slot] != .Record || signature.files[slot] == nil {
				literal := lex_parser.Node_Index(argument_value.integer)
				return refuse(evaluation, {refusal = .Literal_No_Type, place = argument_node.place, node = literal, command = name, parameter = slot + 1, right_kind = slot < parameter_count ? signature.kinds[slot] : .None})
			}
			argument_value = literal_typed(evaluation, argument_value, signature.files[slot], signature.details[slot], nil) or_return
		}
		if argument_value.kind == .Member {
			argument_value = member_typed(evaluation, lex_parser.Node_Index(argument_value.integer), name, slot, signature) or_return
		}
		arguments[slot] = argument_value
	}
	value, ok = host.call_run(host.data, name, arguments[:count])
	return host_answer(evaluation, index, node, value, ok)
}

// member_typed gives the value of a member node for the parameter slot of a
// call: the value of the member of the same name in the enum of the
// parameter. A parameter that is no Enum, and a name that the enum does not
// have, are refused at the place of the member.
@(private)
member_typed :: proc "contextless" (evaluation: ^Evaluation, member: lex_parser.Node_Index, command_name: string, slot: int, signature: Command_Signature) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	member_node := lex_parser.node_at(tree, member)
	if member_node == nil {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = tree.refusal.place, node = member})
	}
	if slot < 0 || slot >= clamp(signature.parameter_count, 0, lex_parser.ARGUMENT_CAPACITY) || signature.kinds[slot] != .Enum || signature.files[slot] == nil {
		right_kind := slot >= 0 && slot < lex_parser.ARGUMENT_CAPACITY ? signature.kinds[slot] : .None
		return refuse(evaluation, {refusal = .Member_No_Type, place = member_node.place, node = member, command = command_name, parameter = slot + 1, right_kind = right_kind})
	}
	text := lex_parser.node_text(tree, member)
	member_name := len(text) > 0 ? text[1:] : text
	file, enum_index := signature.files[slot], signature.details[slot]
	record := Refusal_Record{refusal = .Member_Unknown, place = member_node.place, node = member, command = command_name, parameter = slot + 1, field = member_name, file = file, detail = enum_index}
	described, problem := module.enum_type(file, enum_index)
	if problem != .None {
		return refuse(evaluation, record)
	}
	member_value, found := module.enum_value_of_name(file, described, member_name)
	if !found {
		return refuse(evaluation, record)
	}
	return {kind = .Enum, integer = member_value, file = file, detail = enum_index}, true
}

// with_compute gives `left with right`: the record on the left, with the
// fields of a literal on the right, or the record on the right when both
// have one description.
@(private)
with_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, left, right: Value) -> (value: Value, ok: bool) {
	if left.kind == .Record {
		switch right.kind {
		case .Record_Literal:
			return literal_typed(evaluation, right, left.file, left.detail, left.record)
		case .Record:
			if !module.records_equal(left.file, left.detail, right.file, right.detail) {
				return refuse(evaluation, {refusal = .With_Records_Differ, place = node.place, node = index, file = left.file, detail = left.detail, other_file = right.file, other_detail = right.detail})
			}
			return right, true
		case .None, .Integer, .Text, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Member:
		}
	}
	return refuse(evaluation, {refusal = .With_Kinds, place = node.place, node = index, operator = .With, left_kind = left.kind, right_kind = right.kind})
}

@(private)
negate_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	value = force(evaluation, node.first_child) or_return
	if value.kind != .Integer {
		return refuse(evaluation, {refusal = .Negate_Kind, place = node.place, node = index, left_kind = value.kind})
	}
	opposite, fits := console_language.integer_negate(value.integer)
	if !fits {
		return refuse(evaluation, {refusal = .Overflow, place = node.place, node = index, operator = .Subtract, left = 0, right = value.integer})
	}
	return {kind = .Integer, integer = opposite}, true
}

// binary_compute forces the left operand, then the right one.
@(private)
binary_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	left := force(evaluation, node.first_child) or_return
	right := force(evaluation, lex_parser.next_of(evaluation.tree, node.first_child)) or_return
	if node.operator == .With {
		return with_compute(evaluation, index, node, left, right)
	}
	record := Refusal_Record {
		place      = node.place,
		node       = index,
		operator   = node.operator,
		left_kind  = left.kind,
		right_kind = right.kind,
		left       = left.integer,
		right      = right.integer,
	}
	integers := left.kind == .Integer && right.kind == .Integer
	result: i64
	fits := true
	switch node.operator {
	case .Add:
		// Two Texts or two Tables: the host has the memory of the sum, and
		// refuses two Tables of two records.
		if left.kind == right.kind && (left.kind == .Text || left.kind == .Table) {
			host := evaluation.host
			sum, sum_ok := host.values_add(host.data, left, right)
			return host_answer(evaluation, index, node, sum, sum_ok)
		}
		if !integers {
			break
		}
		result, fits = console_language.integer_add(left.integer, right.integer)
	case .Subtract:
		if !integers {
			break
		}
		result, fits = console_language.integer_subtract(left.integer, right.integer)
	case .Multiply:
		if !integers {
			break
		}
		result, fits = console_language.integer_multiply(left.integer, right.integer)
	case .Divide, .Remainder:
		if !integers {
			break
		}
		if right.integer == 0 {
			record.refusal = .Division_By_Zero
			return refuse(evaluation, record)
		}
		quotient, rest, quotient_fits := console_language.integer_divide(left.integer, right.integer)
		if node.operator == .Divide {
			result, fits = quotient, quotient_fits
		} else {
			// The remainder of a division by -1 is 0, also when the
			// quotient does not fit.
			result = right.integer == -1 ? 0 : rest
		}
	case .None, .With:
		// The parser gives each Binary node its operator; `with` is above.
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = node.place, node = index})
	}
	if !integers {
		record.refusal = .Operator_Kinds
		return refuse(evaluation, record)
	}
	if !fits {
		record.refusal = .Overflow
		return refuse(evaluation, record)
	}
	return {kind = .Integer, integer = result}, true
}
