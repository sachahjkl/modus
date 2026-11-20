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

// The kinds of the values of Lex. The values are those of module.Type: the
// kind of a parameter is its type.
Kind :: enum u8 {
	None    = 0,
	Integer = 1,
	Text    = 2,
	Record  = 3,
	Handle  = 4,
	Table   = 5,
	Bytes   = 6, // A parameter: a Text value is its argument. A value: bytes with no description, which the console draws.
}

// A value of Lex. A parameter of a command of the console with the kind
// None takes a value of any kind: the command checks it.
Value :: struct {
	kind:      Kind,
	integer:   i64, // An Integer. A Handle: the handle.
	text:      string,
	record:    []u8, // A Record: its bytes. A Table: the bytes of its records.
	file:      []u8, // A Record or a Table: the module that has the description of the record.
	detail:    u32, // A Record or a Table: the index of the description of the record in the module.
	condition: ^console_condition.Condition, // The argument of a parameter of the form Condition, in the memory of the host.
}

// Why an evaluation stopped. The values are fixed: a test names the member,
// and a record keeps it.
Refusal :: enum u8 {
	None             = 0, // The evaluation runs, or it gave its value.
	Text             = 1, // A refusal of the parser: text_refusal says which, node is the refused node.
	Operator_Kinds   = 2, // An operator on two kinds that it does not take: operator, left_kind, right_kind.
	Negate_Kind      = 3, // "-" before a value that is no Integer: left_kind.
	Overflow         = 4, // A result that does not fit in an Integer: operator, left, right. "-" before a value is Subtract with left 0.
	Division_By_Zero = 5, // "/" or "%" by 0.
	Budget_Exceeded  = 6, // A thunk to compute past the budget: steps is the budget, the place is the node.
	Effect_Refused   = 7, // Mode `declaration`: a call of a command with an effect. command names it.
	Host_Refused     = 8, // The host refused a name, a call, a condition or a fact name, and wrote its own failure.
}

// The first refusal of an evaluation, and what its sentence needs.
Refusal_Record :: struct {
	refusal:      Refusal,
	place:        lex_parser.Place, // The node where the evaluation stopped.
	node:         lex_parser.Node_Index,
	operator:     lex_parser.Operator, // Operator_Kinds, Overflow.
	left_kind:    Kind, // Operator_Kinds, Negate_Kind.
	right_kind:   Kind, // Operator_Kinds.
	left:         i64, // Overflow.
	right:        i64, // Overflow.
	text_refusal: lex_parser.Refusal, // Text.
	command:      string, // Effect_Refused.
	steps:        u32, // Budget_Exceeded: the budget.
}

// What only the host knows. Each procedure that gives ok false has written
// the failure of the host; the evaluator then stops with Host_Refused.
Evaluation_Host :: struct {
	data:            rawptr, // The state of the host.
	name_value:      proc "contextless" (data: rawptr, name: string) -> (value: Value, ok: bool), // A name alone: a variable, or a field of one.
	command_find:    proc "contextless" (data: rawptr, name: string) -> (has_effect: bool, found: bool), // The command of a call, before its arguments.
	call_run:        proc "contextless" (data: rawptr, name: string, arguments: []Value) -> (value: Value, ok: bool), // Checks the arguments and runs the call: the effect.
	condition_value: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, before: []Value, node: lex_parser.Node_Index) -> (value: Value, ok: bool), // A Condition node; it forces the value of the condition through force when it needs it.
	fact_name_value: proc "contextless" (data: rawptr, evaluation: ^Evaluation, command_name: string, node: lex_parser.Node_Index) -> (value: Value, ok: bool), // A Fact_Name node.
	text_join:       proc "contextless" (data: rawptr, left, right: string) -> (joined: string, ok: bool), // "+" of two Texts, in the memory of the host.
}

// The state of a thunk.
Thunk_State :: enum u8 {
	Unforced = 0,
	Forced   = 1, // value is kept.
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
	case .None, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused:
	}
	return force(evaluation, tree.root)
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
	if thunk.state == .Forced {
		return thunk.value, true
	}
	if evaluation.steps >= evaluation.budget {
		return refuse(evaluation, {refusal = .Budget_Exceeded, place = node.place, node = index, steps = evaluation.budget})
	}
	evaluation.steps += 1
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
		value, ok = host.name_value(host.data, lex_parser.node_text(tree, index))
		return host_answer(evaluation, index, node, value, ok)
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
	case .Refused:
		// The part that the parser read before the fault runs first.
		if node.first_child != lex_parser.NO_NODE {
			if _, before_ok := force(evaluation, node.first_child); !before_ok {
				return {}, false
			}
		}
		return refuse(evaluation, {refusal = .Text, text_refusal = node.refusal, place = node.place, node = index})
	}
	// The parser makes a condition and a fact name only as an argument of a
	// call, which forces them with its name.
	return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = node.place, node = index})
}

// call_compute asks the host for the command first, so a name that no
// command has fails before its arguments; then it forces the arguments from
// the left, and the host runs the call.
@(private)
call_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	host := evaluation.host
	name := lex_parser.node_text(tree, index)
	has_effect, found := host.command_find(host.data, name)
	if !found {
		return host_answer(evaluation, index, node, {}, false)
	}
	// At the border: nothing of the call is forced, and nothing runs.
	if evaluation.mode == .Declaration && has_effect {
		return refuse(evaluation, {refusal = .Effect_Refused, place = node.place, node = index, command = name})
	}
	arguments: [lex_parser.ARGUMENT_CAPACITY]Value
	count := 0
	for argument := node.first_child; argument != lex_parser.NO_NODE; argument = lex_parser.next_of(tree, argument) {
		argument_value := argument_force(evaluation, argument, name, arguments[:count]) or_return
		// The parser ends the arguments with a refusal at this count.
		if count == len(arguments) {
			argument_node := lex_parser.node_at(tree, argument)
			return refuse(evaluation, {refusal = .Text, text_refusal = .Too_Many_Arguments, place = argument_node.place, node = argument})
		}
		arguments[count] = argument_value
		count += 1
	}
	value, ok = host.call_run(host.data, name, arguments[:count])
	return host_answer(evaluation, index, node, value, ok)
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
		if left.kind == .Text && right.kind == .Text {
			host := evaluation.host
			joined, joined_ok := host.text_join(host.data, left.text, right.text)
			if !joined_ok {
				return host_answer(evaluation, index, node, {}, false)
			}
			return {kind = .Text, text = joined}, true
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
	case .None:
		// The parser gives each Binary node its operator.
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
