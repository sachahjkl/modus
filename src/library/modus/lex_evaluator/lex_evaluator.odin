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

import "modus:contract/blake3"
import module "modus:contract/module"
import "modus:console_condition"
import "modus:console_language"
import "modus:lex_parser"

// The steps of one evaluation, the same in both modes. A step is one thunk
// computed. The measure over the declarations of the system sets the bound
// when the evaluator first runs one; until then it is far above the steps
// of the longest line of the console, NODE_CAPACITY.
EVALUATION_BUDGET_STEPS :: 1 << 20

#assert(lex_parser.NODE_CAPACITY * 5000 < EVALUATION_BUDGET_STEPS)

// The bytes of stack that one evaluation may take, from its first force:
// the evaluator recurses one level for each force inside a force, and a
// level takes from 1 KiB (an operator) to 5 KiB (a call) in a module built
// with -o:speed. The deepest line of 200 bytes takes about 340 KiB. A host
// gives its thread this bound and room for its commands at the deepest
// place (src/md/features/declarations.md, "The functions of layer 4 as
// built").
EVALUATION_STACK_BYTES :: 512 * 1024

// The calls of functions of one evaluation, the thunks of their bodies, and
// the items of its lists. A call is kept until the evaluation ends: a
// function or a literal that it made can outlive it.
CALL_CAPACITY :: 256
CALL_THUNK_CAPACITY :: 512
LIST_ITEM_CAPACITY :: 256
HASH_CAPACITY :: 64
EVALUATION_DEPTH_LIMIT :: 256

// A call of a function in the memory of an evaluation, from 1.
Call_Index :: distinct i32

// No call: the top of the line, outside each function.
NO_CALL :: Call_Index(0)

// One call of a function: the function, the tree in which it lives, the call
// in which the function was written, and the first of its thunks in
// active_call_thunks.
Function_Call :: struct {
	function:   lex_parser.Node_Index,
	parent:     Call_Index,
	first_slot: i32,
	tree:       u16,
}

// One lazy `left with right` record composition in mode `declaration`.
With_Pair :: struct {
	left:  Value,
	right: Value,
}

// One lazy `recipe(builder, arguments)` value in mode `declaration`.
Recipe_Value :: struct {
	recipe_hash:  blake3.Hash,
	builder_hash: blake3.Hash,
	arguments:    Value,
}

// One parsed syntax tree and its thunk/slot tables in an evaluation.
Tree_Slot :: struct {
	tree:        ^lex_parser.Syntax_Tree,
	thunks:      []Thunk,
	slots:       []i16,
	slot_counts: []u16,
}

// Caller-supplied pools for a multi-line or multi-file declaration evaluation.
Evaluation_Pools :: struct {
	trees:          []Tree_Slot,
	calls:          []Function_Call,
	call_thunks:    []Thunk,
	list_items:     []Value,
	hashes:         []blake3.Hash,
	with_pairs:     []With_Pair,
	recipes:        []Recipe_Value,
	tagged_records: []Value,
	depth_limit:    int,
}

// The names of the evaluation that operate on lists. They are no commands of
// the host: the evaluator runs them directly.
MAP_NAME :: "map"
FILTER_NAME :: "filter"

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
	Function       = 12, // A function: integer is its node, call the call in which it was written, tree its tree index. No export takes one, and no variable keeps one.
	List           = 13, // A list: its items are active_list_items[integer:][:detail] of the evaluation. No export takes one; a variable of the console keeps a copy, which list_items_add gives back to a line.
	Hash           = 14, // A BLAKE3 hash literal or computed tree hash: `detail` indexes `active_hashes`.
	Boolean        = 15, // A boolean: `integer != 0` is true, `0` is false.
	Record_With    = 16, // Mode `declaration`: lazy `left with right` record composition (`integer` indexes `with_pairs`).
	Module_Ref     = 17, // Mode `declaration`: `module(blake3:...)`, `detail` indexes `active_hashes`.
	Recipe_Ref     = 18, // Mode `declaration`: `recipe(builder, arguments)`, `integer` indexes `recipes`.
	Follow_Ref     = 19, // Mode `declaration`: `follow(publisher, name)`, `detail` indexes `active_hashes`, name in `text`.
	Store_Ref      = 20, // Mode `declaration`: `store(name, ...rights)`, name in `text`, rights in `active_list_items[integer:][:detail]`.
	Plan_Value     = 21, // Mode `declaration`: `plan { ... }`, `integer` indexes `tagged_records`.
	Project_Value  = 22, // Mode `declaration`: `project { ... }`, `integer` indexes `tagged_records`.
}

// The fields of a record at most: those of a record that a call carries.
LITERAL_FIELD_CAPACITY :: module.RECORD_SIZE_LIMIT / 4

// A value of Lex. A parameter of a command of the console with the kind
// None takes a value of any kind: the command checks it.
Value :: struct {
	kind:      Kind,
	tree:      u16, // A Function, a Record_Literal, a Member: the tree slot index in the evaluation.
	integer:   i64, // An Integer, Boolean, Handle, Stream, Node_Index, or pool index.
	text:      string,
	record:    []u8, // A Record: its bytes. A Table: the bytes of its records.
	file:      []u8, // A Record, a Table, a Stream or a Record_Input: the module that has the description of the record.
	detail:    u32, // A Record, a Table, a Stream or a Record_Input: record index. A List/Store_Ref: item count. A Hash/Module_Ref/Follow_Ref: hash pool index.
	call:      Call_Index, // A Function, a Record_Literal: the call in which it was written, whose thunks its body or its fields read.
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
	Not_A_Function        = 23, // A call of a name whose value is no function, or the second argument of map: command, left_kind; parameter 2 for map.
	Function_Arguments    = 24, // A call of a function with another count of arguments than its parameters: command, left (given), right (its parameters); parameter 2 for the function of map.
	Value_At_Border       = 25, // A function or a list given to a command of the host: command, parameter, left_kind.
	Stack_Exceeded        = 26, // A force past the bytes of stack of the evaluation: left (the bytes), right (the bound).
	Calls_Full            = 27, // A call of a function past CALL_CAPACITY calls or CALL_THUNK_CAPACITY thunks.
	Lists_Full            = 28, // A list past LIST_ITEM_CAPACITY items in all.
	Not_A_List            = 29, // The first argument of map or filter is no List: command, parameter, left_kind.
	List_Item_Kind        = 30, // An item of a list with no value, or a Stream or a Record_Input, which live in their wiring: left_kind; the place of the item, or of map.
	Condition_Not_Boolean = 31, // An `if` condition or `filter` predicate gave a value that is no Boolean: left_kind.
	Depth_Exceeded        = 32, // A force past the recursion depth bound of the evaluation: left (depth), right (bound).
	With_Pairs_Full       = 33, // Lazy `with` compositions past the pool capacity.
	Imports_Full          = 34, // Imported trees, recipes, or tagged records past pool capacity.
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
	untyped:         bool, // The parameters take each value as it is, a literal and a member untyped: a function of Lex, and map.
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

// One evaluation of one or more trees, in the memory of the caller.
Evaluation :: struct {
	tree:                ^lex_parser.Syntax_Tree,
	mode:                Evaluation_Mode,
	host:                Evaluation_Host,
	budget:              u32, // The steps that the evaluation may take.
	steps:               u32, // The steps taken.
	thunks:              [lex_parser.NODE_CAPACITY]Thunk, // Inline thunks for console lines.
	refusal:             Refusal_Record,
	call:                Call_Index, // The call whose nodes the evaluation computes now.
	calls:               [CALL_CAPACITY + 1]Function_Call, // Inline calls for console lines (from 1: 0 is NO_CALL).
	call_count:          int,
	call_thunks:         [CALL_THUNK_CAPACITY]Thunk,
	call_thunk_count:    int,
	list_items:          [LIST_ITEM_CAPACITY]Value,
	list_item_count:     int,
	hashes:              [HASH_CAPACITY]blake3.Hash,
	hash_count:          int,
	slots:               [lex_parser.NODE_CAPACITY]i16, // Inline slots for console lines.
	slot_counts:         [lex_parser.NODE_CAPACITY]u16, // Inline slot counts for console lines.
	stack_bytes:         uint, // The bytes of stack that the evaluation may take.
	stack_start:         uintptr, // The address of a local of the first force.
	stack_deepest:       uint, // The most bytes of stack that a force took: a measure.
	depth:               int, // The forces inside each other now.
	depth_limit:         int, // 0: no separate count bound (bounded by stack_bytes and TEXT_BYTES_MOST).
	current_tree:        u16, // Active tree slot index in active_trees.
	inline_trees:        [1]Tree_Slot,
	active_trees:        []Tree_Slot,
	active_tree_count:   int,
	active_calls:        []Function_Call,
	active_call_thunks:  []Thunk,
	active_list_items:   []Value,
	active_hashes:       []blake3.Hash,
	with_pairs:          []With_Pair,
	with_pair_count:     int,
	recipes:             []Recipe_Value,
	recipe_count:        int,
	tagged_records:      []Value,
	tagged_record_count: int,
}

// evaluation_start makes an evaluation of a single console tree ready: each
// thunk unforced, no step, no call, no refusal.
evaluation_start :: proc "contextless" (evaluation: ^Evaluation, tree: ^lex_parser.Syntax_Tree, mode: Evaluation_Mode, host: Evaluation_Host, budget: u32 = EVALUATION_BUDGET_STEPS, stack_bytes: uint = EVALUATION_STACK_BYTES) {
	evaluation.inline_trees[0] = {
		tree        = tree,
		thunks      = evaluation.thunks[:],
		slots       = evaluation.slots[:],
		slot_counts = evaluation.slot_counts[:],
	}
	pools := Evaluation_Pools {
		trees       = evaluation.inline_trees[:],
		calls       = evaluation.calls[:],
		call_thunks = evaluation.call_thunks[:],
		list_items  = evaluation.list_items[:],
		hashes      = evaluation.hashes[:],
		depth_limit = 0,
	}
	evaluation_start_with_pools(evaluation, tree, mode, host, pools, budget, stack_bytes)
}

// evaluation_start_with_pools starts an evaluation backed by caller-owned
// pools (supporting multi-line declarations, multi-file imports, lazy with
// pairs, and explicit recursion depth bounds). pools.trees[0] must already
// hold the slices for the root tree.
evaluation_start_with_pools :: proc "contextless" (evaluation: ^Evaluation, tree: ^lex_parser.Syntax_Tree, mode: Evaluation_Mode, host: Evaluation_Host, pools: Evaluation_Pools, budget: u32 = EVALUATION_BUDGET_STEPS, stack_bytes: uint = EVALUATION_STACK_BYTES) {
	evaluation.tree, evaluation.mode, evaluation.host, evaluation.budget, evaluation.steps = tree, mode, host, budget, 0
	evaluation.refusal = {}
	evaluation.call, evaluation.call_count, evaluation.call_thunk_count, evaluation.list_item_count, evaluation.hash_count = NO_CALL, 0, 0, 0, 0
	evaluation.stack_bytes, evaluation.stack_start, evaluation.stack_deepest, evaluation.depth = stack_bytes, 0, 0, 0
	evaluation.depth_limit = pools.depth_limit
	evaluation.current_tree = 0
	evaluation.active_trees = pools.trees
	evaluation.active_tree_count = 0
	evaluation.active_calls = pools.calls
	evaluation.active_call_thunks = pools.call_thunks
	evaluation.active_list_items = pools.list_items
	evaluation.active_hashes = pools.hashes
	evaluation.with_pairs = pools.with_pairs
	evaluation.with_pair_count = 0
	evaluation.recipes = pools.recipes
	evaluation.recipe_count = 0
	evaluation.tagged_records = pools.tagged_records
	evaluation.tagged_record_count = 0
	if len(pools.trees) > 0 {
		slot := &pools.trees[0]
		slot.tree = tree
		tree_slot_prepare(slot)
		evaluation.active_tree_count = 1
	}
}

// hash_intern stores a BLAKE3 hash in the evaluation's hash pool (deduplicating
// existing entries) and returns its pool index.
hash_intern :: proc "contextless" (evaluation: ^Evaluation, hash: blake3.Hash) -> (index: u32, ok: bool) {
	for existing, i in evaluation.active_hashes[:evaluation.hash_count] {
		if existing == hash {
			return u32(i), true
		}
	}
	if evaluation.hash_count >= len(evaluation.active_hashes) {
		return 0, false
	}
	idx := evaluation.hash_count
	evaluation.active_hashes[idx] = hash
	evaluation.hash_count += 1
	return u32(idx), true
}

// hash_of returns the 32-byte BLAKE3 hash of a Hash, Module_Ref, Follow_Ref
// or Recipe_Ref value.
hash_of :: proc "contextless" (evaluation: ^Evaluation, value: Value) -> (hash: blake3.Hash, ok: bool) {
	switch value.kind {
	case .Hash, .Module_Ref, .Follow_Ref:
		if int(value.detail) < evaluation.hash_count {
			return evaluation.active_hashes[int(value.detail)], true
		}
	case .Recipe_Ref:
		if int(value.integer) >= 0 && int(value.integer) < evaluation.recipe_count {
			return evaluation.recipes[int(value.integer)].recipe_hash, true
		}
	case .None, .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Member, .Function, .List, .Boolean, .Record_With, .Store_Ref, .Plan_Value, .Project_Value:
	}
	return {}, false
}

// evaluation_register_tree registers an additional parsed .lex syntax tree
// (from import or declaration) in the evaluation, sharing its budget and
// pools. Returns the tree slot index, or false if the tree pool is full.
evaluation_register_tree :: proc "contextless" (evaluation: ^Evaluation, slot: Tree_Slot) -> (tree_index: u16, ok: bool) {
	if evaluation.active_tree_count >= len(evaluation.active_trees) {
		return 0, false
	}
	idx := evaluation.active_tree_count
	evaluation.active_trees[idx] = slot
	tree_slot_prepare(&evaluation.active_trees[idx])
	evaluation.active_tree_count += 1
	return u16(idx), true
}

// tree_slot_prepare clears thunks and assigns call-frame slots to nodes of
// functions that two readers can force.
@(private)
tree_slot_prepare :: proc "contextless" (slot: ^Tree_Slot) {
	tree := slot.tree
	nodes := lex_parser.tree_nodes(tree)
	count := clamp(tree.node_count, 0, min(len(slot.thunks), min(len(slot.slots), len(slot.slot_counts))))
	for &thunk in slot.thunks[:count] {
		thunk = {}
	}
	for index in 0 ..< count {
		slot.slots[index], slot.slot_counts[index] = -1, 0
	}
	for index in 0 ..< count {
		node := &nodes[index]
		if node.kind == .Parameter {
			slot_give_in(slot, lex_parser.Node_Index(index))
		} else if node.kind == .Let_Binding || node.kind == .Literal_Field {
			slot_give_in(slot, node.first_child)
		}
	}
}

// slot_give_in gives a node of a function its place among the thunks of a
// call of that function in one tree slot.
@(private)
slot_give_in :: proc "contextless" (slot: ^Tree_Slot, index: lex_parser.Node_Index) {
	node := lex_parser.node_at(slot.tree, index)
	if node == nil || node.function == lex_parser.NO_NODE || int(index) >= len(slot.slots) || slot.slots[int(index)] >= 0 {
		return
	}
	function := int(node.function)
	if function >= len(slot.slot_counts) {
		return
	}
	slot.slots[int(index)] = i16(slot.slot_counts[function])
	slot.slot_counts[function] += 1
}

@(private)
active_slot :: proc "contextless" (evaluation: ^Evaluation, tree_index: u16) -> ^Tree_Slot {
	if int(tree_index) >= evaluation.active_tree_count {
		return nil
	}
	return &evaluation.active_trees[int(tree_index)]
}

// call_of gives the call of a function in which the evaluation reads the
// nodes of that function now: the current call, or the call in which it
// was written, outward. NO_NODE is the top of the tree.
@(private)
call_of :: proc "contextless" (evaluation: ^Evaluation, function: lex_parser.Node_Index) -> (call: Call_Index, found: bool) {
	if function == lex_parser.NO_NODE {
		return NO_CALL, true
	}
	for candidate := evaluation.call; candidate != NO_CALL; candidate = evaluation.active_calls[candidate].parent {
		if evaluation.active_calls[candidate].function == function && evaluation.active_calls[candidate].tree == evaluation.current_tree {
			return candidate, true
		}
	}
	return NO_CALL, false
}

// thunk_at gives the thunk of a node in a call, or nil: a node of a body
// that one reader forces is computed each time.
@(private)
thunk_at :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, call: Call_Index) -> ^Thunk {
	tree_slot := active_slot(evaluation, evaluation.current_tree)
	if tree_slot == nil {
		return nil
	}
	if node.function == lex_parser.NO_NODE {
		if int(index) >= len(tree_slot.thunks) {
			return nil
		}
		return &tree_slot.thunks[int(index)]
	}
	if int(index) >= len(tree_slot.slots) {
		return nil
	}
	slot := tree_slot.slots[int(index)]
	if slot < 0 || call == NO_CALL {
		return nil
	}
	pos := int(evaluation.active_calls[call].first_slot) + int(slot)
	if pos < 0 || pos >= len(evaluation.active_call_thunks) {
		return nil
	}
	return &evaluation.active_call_thunks[pos]
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
	case .Text_Too_Long, .Nodes_Full, .Nesting_Too_Deep:
		return refuse(evaluation, {refusal = .Text, text_refusal = tree.refusal.refusal, place = tree.refusal.place, node = tree.root})
	case .Thin_Arrow:
		// The names before a "->" are the parameters of a function that the
		// line meant, never values: no part of the line runs, so the
		// refusal names the form of a function, not a missing variable.
		return refuse(evaluation, {refusal = .Text, text_refusal = .Thin_Arrow, place = tree.refusal.place, node = tree.root})
	case .None, .Line_Ends_Too_Soon, .Unexpected, .Number_Too_Large, .Text_Without_End_Quote, .Close_Parenthesis_Missing, .Comma_Or_Close_Missing, .Too_Many_Arguments, .Fact_Name_Missing, .Condition_Head_Refused, .Field_Name_Missing, .Literal_Close_Missing, .Literal_Name_Missing, .Literal_Equal_Missing, .Literal_Field_Twice, .Named_Argument_Twice, .Positional_After_Named, .Let_Name_Missing, .Let_Equal_Missing, .Let_In_Missing, .Let_Name_Twice, .Word_As_Name, .Parameter_Name_Missing, .Parameter_Twice, .Too_Many_Parameters, .List_Close_Missing, .Hash_Not_Valid, .If_Then_Missing, .If_Else_Missing:
	}
	value = force(evaluation, tree.root) or_return
	if evaluation.mode == .Console {
		// The value of a line is drawn or kept: a literal or a member that
		// nothing typed has no type to draw or keep, also as an item of a list.
		untyped := untyped_find(evaluation, value, 0)
		if untyped.kind == .Record_Literal {
			literal := lex_parser.Node_Index(untyped.integer)
			return refuse(evaluation, {refusal = .Literal_No_Type, place = lex_parser.node_at(tree, literal).place, node = literal})
		}
		if untyped.kind == .Member {
			member := lex_parser.Node_Index(untyped.integer)
			return refuse(evaluation, {refusal = .Member_No_Type, place = lex_parser.node_at(tree, member).place, node = member})
		}
	}
	return value, true
}

// untyped_find gives a literal or a member that nothing typed in a value:
// the value itself, or an item of a list, from the first. The kind None:
// there is none. A list holds lists only of items made before it, so the
// depth is bounded by the items of the evaluation.
@(private)
untyped_find :: proc "contextless" (evaluation: ^Evaluation, value: Value, depth: int) -> Value {
	if value.kind == .Record_Literal || value.kind == .Member {
		return value
	}
	if value.kind != .List || depth > len(evaluation.active_list_items) {
		return {}
	}
	for item in list_items_of(evaluation, value) {
		if found := untyped_find(evaluation, item, depth + 1); found.kind != .None {
			return found
		}
	}
	return {}
}

// list_items_add copies items that a host kept into the items of the
// evaluation, after the items of its lists, and gives the place of the
// first one: a variable of the console keeps a list across lines, and each
// line reads it as a list of its own. The host moves a nested List of the
// items to its new place. ok is false when the items do not fit, and the
// evaluation then holds nothing more.
list_items_add :: proc "contextless" (evaluation: ^Evaluation, items: []Value) -> (first: int, ok: bool) {
	if len(items) > len(evaluation.active_list_items) - evaluation.list_item_count {
		return 0, false
	}
	first = evaluation.list_item_count
	copy(evaluation.active_list_items[first:], items)
	evaluation.list_item_count += len(items)
	return first, true
}

// list_items_of gives the items of a List or Store_Ref value.
list_items_of :: proc "contextless" (evaluation: ^Evaluation, value: Value) -> []Value {
	limit := len(evaluation.active_list_items)
	first := clamp(int(value.integer), 0, limit)
	return evaluation.active_list_items[first:clamp(first + int(value.detail), first, limit)]
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
	// A node of a function is computed in the call of that function that
	// the current call sees: its own, or one in which it was written.
	owner, visible := call_of(evaluation, node.function)
	if !visible {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = node.place, node = index})
	}
	thunk := thunk_at(evaluation, index, node, owner)
	if thunk != nil {
		switch thunk.state {
		case .Forced:
			return thunk.value, true
		case .Forcing:
			// The computation of this thunk needs its own value. A binding
			// refuses it first, with the place of its name.
			return refuse(evaluation, {refusal = .Cycle, place = node.place, node = index})
		case .Unforced:
		}
	}
	// The stack that the forces inside each other took, from the first.
	marker := 0
	here := uintptr(&marker)
	if evaluation.depth == 0 {
		evaluation.stack_start = here
	}
	used := evaluation.stack_start > here ? uint(evaluation.stack_start - here) : 0
	evaluation.stack_deepest = max(evaluation.stack_deepest, used)
	if used > evaluation.stack_bytes {
		return refuse(evaluation, {refusal = .Stack_Exceeded, place = node.place, node = index, left = i64(used), right = i64(evaluation.stack_bytes)})
	}
	if evaluation.depth_limit > 0 && evaluation.depth >= evaluation.depth_limit {
		return refuse(evaluation, {refusal = .Depth_Exceeded, place = node.place, node = index, left = i64(evaluation.depth), right = i64(evaluation.depth_limit)})
	}
	if evaluation.steps >= evaluation.budget {
		return refuse(evaluation, {refusal = .Budget_Exceeded, place = node.place, node = index, steps = evaluation.budget})
	}
	evaluation.steps += 1
	if thunk != nil {
		thunk.state = .Forcing
	}
	saved := evaluation.call
	evaluation.call = owner
	evaluation.depth += 1
	value, ok = compute(evaluation, index, node, command_name, before)
	evaluation.depth -= 1
	evaluation.call = saved
	if !ok {
		return {}, false
	}
	if thunk != nil {
		thunk.state, thunk.value = .Forced, value
	}
	return value, true
}

// force_in forces a node in a call that the current call may not see: a
// field of a literal that a call made, typed after that call returned.
@(private)
force_in :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, call: Call_Index) -> (value: Value, ok: bool) {
	saved := evaluation.call
	evaluation.call = call
	value, ok = force(evaluation, index)
	evaluation.call = saved
	return value, ok
}

// force_in_tree switches to tree_index and call, forces index, and restores
// the active tree and call. Used for cross-file imports and lazy records.
force_in_tree :: proc "contextless" (evaluation: ^Evaluation, tree_index: u16, index: lex_parser.Node_Index, call: Call_Index) -> (value: Value, ok: bool) {
	slot := active_slot(evaluation, tree_index)
	if slot == nil || slot.tree == nil {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, node = index})
	}
	saved_tree := evaluation.tree
	saved_tree_index := evaluation.current_tree
	saved_call := evaluation.call
	evaluation.tree = slot.tree
	evaluation.current_tree = tree_index
	evaluation.call = call
	value, ok = force(evaluation, index)
	evaluation.call = saved_call
	evaluation.current_tree = saved_tree_index
	evaluation.tree = saved_tree
	return value, ok
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
		if evaluation.mode == .Console {
			// Mode `console`: force values from the left so effects run in order.
			for field := node.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(tree, field) {
				field_node := lex_parser.node_at(tree, field)
				if _, forced := force(evaluation, field_node.kind == .Literal_Field ? field_node.first_child : field); !forced {
					return {}, false
				}
			}
		} else {
			// Mode `declaration`: record fields stay unforced thunks until
			// selected! Only a direct syntax refusal node inside the brace
			// list stops here.
			for field := node.first_child; field != lex_parser.NO_NODE; field = lex_parser.next_of(tree, field) {
				field_node := lex_parser.node_at(tree, field)
				if field_node.kind == .Refused {
					return refuse(evaluation, {refusal = .Text, text_refusal = field_node.refusal, place = field_node.place, node = field})
				}
			}
		}
		return {kind = .Record_Literal, integer = i64(index), call = evaluation.call, tree = evaluation.current_tree}, true
	case .Let:
		return let_compute(evaluation, node)
	case .Member:
		// The name only; the Enum parameter that receives it gives the enum.
		return {kind = .Member, integer = i64(index), tree = evaluation.current_tree}, true
	case .Hash:
		decoded, valid := console_language.hash_value(tree.text, int(node.place.offset), int(node.end))
		if !valid {
			return refuse(evaluation, {refusal = .Text, text_refusal = .Hash_Not_Valid, place = node.place, node = index})
		}
		hash_idx, intern_ok := hash_intern(evaluation, decoded)
		if !intern_ok {
			return refuse(evaluation, {refusal = .Imports_Full, place = node.place, node = index})
		}
		return {kind = .Hash, detail = hash_idx}, true
	case .Boolean:
		return {kind = .Boolean, integer = node.integer != 0 ? 1 : 0}, true
	case .If:
		return if_compute(evaluation, index, node)
	case .Field_Select:
		base := force(evaluation, node.first_child) or_return
		return field_force(evaluation, base, lex_parser.node_text(tree, index), node.place, index)
	case .Function:
		// A refusal of the text inside it stops the line here: its body
		// runs only in a call, and the parse stopped in it.
		if refused_node := refusal_inside(tree, index); refused_node != lex_parser.NO_NODE {
			refused_at := lex_parser.node_at(tree, refused_node)
			return refuse(evaluation, {refusal = .Text, text_refusal = refused_at.refusal, place = refused_at.place, node = refused_node})
		}
		return {kind = .Function, integer = i64(index), call = evaluation.call, tree = evaluation.current_tree}, true
	case .List_Literal:
		return list_compute(evaluation, index, node)
	case .Literal_Field, .Named_Argument, .Let_Binding, .Parameter:
		// Their parent forces their value; a call gives a parameter.
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
	if value_node := lex_parser.node_at(evaluation.tree, value_index); value_node != nil {
		owner, _ := call_of(evaluation, value_node.function)
		if thunk := thunk_at(evaluation, value_index, value_node, owner); thunk != nil && thunk.state == .Forcing {
			return refuse(evaluation, {refusal = .Cycle, place = place, node = binding, command = lex_parser.node_text(evaluation.tree, binding)})
		}
	}
	return force(evaluation, value_index)
}

// parameter_value gives the value of a parameter in the call that the
// current call sees: the call gave it.
@(private)
parameter_value :: proc "contextless" (evaluation: ^Evaluation, parameter: lex_parser.Node_Index, parameter_node: ^lex_parser.Node, place: lex_parser.Place) -> (value: Value, ok: bool) {
	owner, visible := call_of(evaluation, parameter_node.function)
	thunk: ^Thunk
	if visible {
		thunk = thunk_at(evaluation, parameter, parameter_node, owner)
	}
	if thunk == nil || thunk.state != .Forced {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = place, node = parameter})
	}
	return thunk.value, true
}

// if_compute forces the condition only, checks it is Boolean, and forces
// only the selected branch.
@(private)
if_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	cond_node := node.first_child
	then_node := lex_parser.next_of(tree, cond_node)
	else_node := lex_parser.next_of(tree, then_node)
	cond := force(evaluation, cond_node) or_return
	if cond.kind != .Boolean {
		return refuse(evaluation, {refusal = .Condition_Not_Boolean, place = lex_parser.node_at(tree, cond_node).place, node = cond_node, left_kind = cond.kind})
	}
	// If the parse stopped at If_Then_Missing or If_Else_Missing, then_node
	// or else_node holds the Refused node.
	if then_node == lex_parser.NO_NODE {
		return refuse(evaluation, {refusal = .Text, text_refusal = .If_Then_Missing, place = node.place, node = index})
	}
	if lex_parser.node_at(tree, then_node).kind == .Refused {
		return force(evaluation, then_node)
	}
	if else_node == lex_parser.NO_NODE {
		return refuse(evaluation, {refusal = .Text, text_refusal = .If_Else_Missing, place = node.place, node = index})
	}
	if lex_parser.node_at(tree, else_node).kind == .Refused {
		return force(evaluation, else_node)
	}
	return force(evaluation, cond.integer != 0 ? then_node : else_node)
}

// binding_value gives the value of a name that a let or a function binds:
// the value of the binding or of the parameter, or a chain of fields after
// '.' (`r.outputs.tools`).
@(private)
binding_value :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	binding_node := lex_parser.node_at(tree, node.binding)
	if binding_node.kind == .Parameter {
		value = parameter_value(evaluation, node.binding, binding_node, node.place) or_return
	} else {
		value = binding_force(evaluation, node.binding, binding_node, node.place) or_return
	}
	name := lex_parser.node_text(tree, index)
	binding_name := lex_parser.node_text(tree, node.binding)
	if len(name) <= len(binding_name) + 1 {
		// The name alone; "a." has no field and reads as the name.
		return value, true
	}
	rest := name[len(binding_name) + 1:]
	for len(rest) > 0 {
		dot := -1
		for character, place in rest {
			if character == '.' {
				dot = place
				break
			}
		}
		segment := dot < 0 ? rest : rest[:dot]
		if len(segment) == 0 {
			break
		}
		value = field_force(evaluation, value, segment, node.place, index) or_return
		if dot < 0 {
			break
		}
		rest = rest[dot + 1:]
	}
	return value, true
}

// lazy_record_has_field checks if a lazy record (Record_Literal,
// Record_With, Plan_Value, Project_Value) defines field without forcing any
// field expressions.
lazy_record_has_field :: proc "contextless" (evaluation: ^Evaluation, base: Value, field: string, depth: int = 0) -> bool {
	if depth > EVALUATION_DEPTH_LIMIT {
		return false
	}
	switch base.kind {
	case .Record_Literal:
		slot := active_slot(evaluation, base.tree)
		if slot == nil || slot.tree == nil {
			return false
		}
		return literal_field_find(slot.tree, lex_parser.Node_Index(base.integer), field) != lex_parser.NO_NODE
	case .Record_With:
		idx := int(base.integer)
		if idx < 0 || idx >= evaluation.with_pair_count {
			return false
		}
		pair := evaluation.with_pairs[idx]
		return lazy_record_has_field(evaluation, pair.right, field, depth + 1) || lazy_record_has_field(evaluation, pair.left, field, depth + 1)
	case .Plan_Value, .Project_Value:
		idx := int(base.integer)
		if idx < 0 || idx >= evaluation.tagged_record_count {
			return false
		}
		return lazy_record_has_field(evaluation, evaluation.tagged_records[idx], field, depth + 1)
	case .None, .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Member, .Function, .List, .Hash, .Boolean, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref:
		return false
	}
	return false
}

// field_force selects and forces one named field of a Record,
// Record_Literal, Record_With, Plan_Value or Project_Value. For lazy
// records, only the selected field's thunk is forced.
field_force :: proc "contextless" (evaluation: ^Evaluation, base: Value, field: string, place: lex_parser.Place, node_index: lex_parser.Node_Index) -> (value: Value, ok: bool) {
	record := Refusal_Record {
		refusal   = .Field_Unknown,
		place     = place,
		node      = node_index,
		field     = field,
		left_kind = base.kind,
	}
	switch base.kind {
	case .Record:
		if found, found_ok := record_field_value(base, field); found_ok {
			return found, true
		}
		record.file, record.detail = base.file, base.detail
	case .Record_Literal:
		slot := active_slot(evaluation, base.tree)
		if slot != nil && slot.tree != nil {
			literal := lex_parser.Node_Index(base.integer)
			field_index := literal_field_find(slot.tree, literal, field)
			if field_index != lex_parser.NO_NODE {
				field_value_node := lex_parser.node_at(slot.tree, field_index).first_child
				// Check for direct or mutual record-field cycle before forcing.
				saved_tree, saved_idx, saved_call := evaluation.tree, evaluation.current_tree, evaluation.call
				evaluation.tree, evaluation.current_tree, evaluation.call = slot.tree, base.tree, base.call
				if vn := lex_parser.node_at(slot.tree, field_value_node); vn != nil {
					owner, _ := call_of(evaluation, vn.function)
					if thunk := thunk_at(evaluation, field_value_node, vn, owner); thunk != nil && thunk.state == .Forcing {
						evaluation.tree, evaluation.current_tree, evaluation.call = saved_tree, saved_idx, saved_call
						return refuse(evaluation, {refusal = .Cycle, place = place, node = node_index, command = field})
					}
				}
				evaluation.tree, evaluation.current_tree, evaluation.call = saved_tree, saved_idx, saved_call
				return force_in_tree(evaluation, base.tree, field_value_node, base.call)
			}
		}
	case .Record_With:
		idx := int(base.integer)
		if idx >= 0 && idx < evaluation.with_pair_count {
			pair := evaluation.with_pairs[idx]
			if lazy_record_has_field(evaluation, pair.right, field) {
				return field_force(evaluation, pair.right, field, place, node_index)
			}
			return field_force(evaluation, pair.left, field, place, node_index)
		}
	case .Plan_Value, .Project_Value:
		idx := int(base.integer)
		if idx >= 0 && idx < evaluation.tagged_record_count {
			return field_force(evaluation, evaluation.tagged_records[idx], field, place, node_index)
		}
	case .None, .Integer, .Text, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Member, .Function, .List, .Hash, .Boolean, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref:
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
		field_value := force_in(evaluation, field_node.first_child, value.call) or_return
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
			if field_value.kind == .Hash && item.detail == blake3.HASH_SIZE {
				h, h_ok := hash_of(evaluation, field_value)
				if !h_ok {
					return refuse(evaluation, record)
				}
				copy(bytes[item.offset:][:blake3.HASH_SIZE], h[:])
			} else if field_value.kind == .Bytes && len(field_value.record) == int(item.detail) {
				copy(bytes[item.offset:][:item.detail], field_value.record)
			} else {
				return refuse(evaluation, record)
			}
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
	// The callee: a function that a let or a parameter binds, map, filter, or
	// a command of the host.
	Callee :: enum u8 {
		Host     = 0,
		Function = 1,
		Map      = 2,
		Filter   = 3,
	}
	callee := Callee.Host
	function: Value
	signature: Command_Signature
	if node.binding != lex_parser.NO_NODE {
		function = binding_value(evaluation, index, node) or_return
		if function.kind != .Function {
			return refuse(evaluation, {refusal = .Not_A_Function, place = node.place, node = index, command = name, left_kind = function.kind})
		}
		callee = .Function
		fn_slot := active_slot(evaluation, function.tree)
		signature = function_signature(fn_slot != nil ? fn_slot.tree : tree, lex_parser.Node_Index(function.integer))
	} else if name == MAP_NAME {
		callee = .Map
		signature = {parameter_count = 2, untyped = true}
		signature.names[0], signature.names[1] = "list", "function"
	} else if name == FILTER_NAME {
		callee = .Filter
		signature = {parameter_count = 2, untyped = true}
		signature.names[0], signature.names[1] = "list", "function"
	} else {
		found: bool
		signature, found = host.command_find(host.data, name)
		if !found {
			return host_answer(evaluation, index, node, {}, false)
		}
		// At the border: nothing of the call is forced, and nothing runs.
		if evaluation.mode == .Declaration && signature.has_effect {
			return refuse(evaluation, {refusal = .Effect_Refused, place = node.place, node = index, command = name})
		}
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
	given := 0
	text_refused := false
	for argument := node.first_child; argument != lex_parser.NO_NODE; argument = lex_parser.next_of(tree, argument) {
		argument_node := lex_parser.node_at(tree, argument)
		slot := -1
		switch argument_node.kind {
		case .Refused:
			// A refusal of the text: the arguments before it run, then it.
			text_refused = true
			continue
		case .Named_Argument:
			given += 1
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
		case .Integer, .Text, .Name, .Call, .Negate, .Binary, .Condition, .Fact_Name, .Field_Names, .Record_Literal, .Literal_Field, .Let, .Let_Binding, .Member, .Function, .Parameter, .List_Literal, .Hash, .Boolean, .If, .Field_Select:
			given += 1
			if positional == len(slots) {
				continue
			}
			slot = positional
			positional += 1
		}
		slots[slot] = argument
		count = max(count, slot + 1)
		// A function and map take a literal and a member as they are.
		if signature.untyped {
			continue
		}
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
		if named && !text_refused {
			return refuse(evaluation, {refusal = .Argument_Missing, place = node.place, node = index, command = name, field = signature.names[parameter]})
		}
		missing = true
	}
	// A function, map and filter count their arguments themselves, before any
	// argument runs. A call whose text stops in its arguments has no count:
	// the arguments before the fault run, then the refusal of the text
	// comes at its place, as for a command of the host.
	if signature.untyped && callee != .Host && !text_refused && (count > parameter_count || !named && given != parameter_count) {
		return refuse(evaluation, {refusal = .Function_Arguments, place = node.place, node = index, command = name, left = i64(given), right = i64(parameter_count)})
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
		if signature.untyped {
			arguments[slot] = argument_value
			continue
		}
		// A function is code of Lex and a list holds values of this
		// evaluation: no command of the host reads either.
		if argument_value.kind == .Function || argument_value.kind == .List {
			return refuse(evaluation, {refusal = .Value_At_Border, place = argument_node.place, node = argument, command = name, parameter = slot + 1, left_kind = argument_value.kind})
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
	switch callee {
	case .Function:
		return function_call(evaluation, index, node, function, arguments[:count])
	case .Map:
		return map_compute(evaluation, index, node, arguments[0], arguments[1])
	case .Filter:
		return filter_compute(evaluation, index, node, arguments[0], arguments[1])
	case .Host:
	}
	value, ok = host.call_run(host.data, name, arguments[:count])
	return host_answer(evaluation, index, node, value, ok)
}

// function_signature gives the parameters of a function: their count and
// their names, which take any value.
@(private)
function_signature :: proc "contextless" (tree: ^lex_parser.Syntax_Tree, function: lex_parser.Node_Index) -> (signature: Command_Signature) {
	signature.untyped = true
	function_node := lex_parser.node_at(tree, function)
	if function_node == nil {
		return signature
	}
	for child := function_node.first_child; child != lex_parser.NO_NODE; child = lex_parser.next_of(tree, child) {
		if lex_parser.node_at(tree, child).kind != .Parameter || signature.parameter_count == lex_parser.ARGUMENT_CAPACITY {
			continue
		}
		signature.names[signature.parameter_count] = lex_parser.node_text(tree, child)
		signature.parameter_count += 1
	}
	return signature
}

// function_call runs a function on its arguments, which are forced: a new
// call, whose parent is the call in which the function was written, with
// one thunk for each node of the body that two readers force; the
// parameters hold the arguments. Then it forces the body in that call.
@(private)
function_call :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, function: Value, arguments: []Value) -> (value: Value, ok: bool) {
	fn_slot := active_slot(evaluation, function.tree)
	if fn_slot == nil || fn_slot.tree == nil {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = node.place, node = index})
	}
	tree := fn_slot.tree
	function_index := lex_parser.Node_Index(function.integer)
	function_node := lex_parser.node_at(tree, function_index)
	if function_node == nil || function_node.kind != .Function {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Unexpected, place = node.place, node = index})
	}
	slot_count := int(fn_slot.slot_counts[int(function_index)])
	max_calls := len(evaluation.active_calls) - 1
	if evaluation.call_count >= max_calls || slot_count > len(evaluation.active_call_thunks) - evaluation.call_thunk_count {
		return refuse(evaluation, {refusal = .Calls_Full, place = node.place, node = index})
	}
	evaluation.call_count += 1
	call := Call_Index(evaluation.call_count)
	first := evaluation.call_thunk_count
	evaluation.active_calls[call] = {function = function_index, parent = function.call, first_slot = i32(first), tree = function.tree}
	evaluation.call_thunk_count += slot_count
	for &thunk in evaluation.active_call_thunks[first:][:slot_count] {
		thunk = {}
	}
	body := lex_parser.NO_NODE
	parameter := 0
	for child := function_node.first_child; child != lex_parser.NO_NODE; child = lex_parser.next_of(tree, child) {
		if lex_parser.node_at(tree, child).kind != .Parameter {
			body = child
			continue
		}
		slot := int(fn_slot.slots[int(child)])
		if parameter < len(arguments) && slot >= 0 {
			evaluation.active_call_thunks[first + slot] = {state = .Forced, value = arguments[parameter]}
		}
		parameter += 1
	}
	if body == lex_parser.NO_NODE {
		return refuse(evaluation, {refusal = .Text, text_refusal = .Line_Ends_Too_Soon, place = function_node.place, node = function_index})
	}
	return force_in_tree(evaluation, function.tree, body, call)
}

// map_compute calls a function on each item of a list, from the first, and
// gives the list of the results.
@(private)
map_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, list, function: Value) -> (value: Value, ok: bool) {
	if list.kind != .List {
		return refuse(evaluation, {refusal = .Not_A_List, place = node.place, node = index, command = MAP_NAME, parameter = 1, left_kind = list.kind})
	}
	if function.kind != .Function {
		return refuse(evaluation, {refusal = .Not_A_Function, place = node.place, node = index, command = MAP_NAME, parameter = 2, left_kind = function.kind})
	}
	fn_slot := active_slot(evaluation, function.tree)
	fn_tree := fn_slot != nil ? fn_slot.tree : evaluation.tree
	if parameters := function_signature(fn_tree, lex_parser.Node_Index(function.integer)).parameter_count; parameters != 1 {
		return refuse(evaluation, {refusal = .Function_Arguments, place = node.place, node = index, command = MAP_NAME, parameter = 2, left = 1, right = i64(parameters)})
	}
	count := int(list.detail)
	if count > len(evaluation.active_list_items) - evaluation.list_item_count {
		return refuse(evaluation, {refusal = .Lists_Full, place = node.place, node = index})
	}
	// The results take their places first: a call can make a list too.
	first := evaluation.list_item_count
	evaluation.list_item_count += count
	for item_number in 0 ..< count {
		item := [1]Value{evaluation.active_list_items[int(list.integer) + item_number]}
		result := function_call(evaluation, index, node, function, item[:]) or_return
		if !list_item_takes(result.kind) {
			return refuse(evaluation, {refusal = .List_Item_Kind, place = node.place, node = index, left_kind = result.kind})
		}
		evaluation.active_list_items[first + item_number] = result
	}
	return {kind = .List, integer = i64(first), detail = u32(count)}, true
}

// filter_compute keeps each item of a list for which a Boolean predicate
// function returns true, preserving order.
@(private)
filter_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, list, function: Value) -> (value: Value, ok: bool) {
	if list.kind != .List {
		return refuse(evaluation, {refusal = .Not_A_List, place = node.place, node = index, command = FILTER_NAME, parameter = 1, left_kind = list.kind})
	}
	if function.kind != .Function {
		return refuse(evaluation, {refusal = .Not_A_Function, place = node.place, node = index, command = FILTER_NAME, parameter = 2, left_kind = function.kind})
	}
	fn_slot := active_slot(evaluation, function.tree)
	fn_tree := fn_slot != nil ? fn_slot.tree : evaluation.tree
	if parameters := function_signature(fn_tree, lex_parser.Node_Index(function.integer)).parameter_count; parameters != 1 {
		return refuse(evaluation, {refusal = .Function_Arguments, place = node.place, node = index, command = FILTER_NAME, parameter = 2, left = 1, right = i64(parameters)})
	}
	count := int(list.detail)
	if count > len(evaluation.active_list_items) - evaluation.list_item_count {
		return refuse(evaluation, {refusal = .Lists_Full, place = node.place, node = index})
	}
	// Reserve worst-case room up front so calls inside predicate cannot overwrite.
	first := evaluation.list_item_count
	evaluation.list_item_count += count
	kept := 0
	for item_number in 0 ..< count {
		item := [1]Value{evaluation.active_list_items[int(list.integer) + item_number]}
		pred := function_call(evaluation, index, node, function, item[:]) or_return
		if pred.kind != .Boolean {
			return refuse(evaluation, {refusal = .Condition_Not_Boolean, place = node.place, node = index, command = FILTER_NAME, left_kind = pred.kind})
		}
		if pred.integer != 0 {
			evaluation.active_list_items[first + kept] = item[0]
			kept += 1
		}
	}
	return {kind = .List, integer = i64(first), detail = u32(kept)}, true
}

// list_item_takes says if a list holds a value of a kind: each value but
// none, and a Stream or a Record_Input, which live in the wiring of their
// line and have no item to draw.
@(private)
list_item_takes :: proc "contextless" (kind: Kind) -> bool {
	switch kind {
	case .None, .Stream, .Record_Input:
		return false
	case .Integer, .Text, .Record, .Handle, .Table, .Bytes, .Record_Literal, .Enum, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
	}
	return true
}

// list_compute forces the items of a list from the left, and gives the
// List. Its items take their places first: an item can make a list too.
@(private)
list_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node) -> (value: Value, ok: bool) {
	tree := evaluation.tree
	count := 0
	for item := node.first_child; item != lex_parser.NO_NODE; item = lex_parser.next_of(tree, item) {
		count += 1
	}
	if count > len(evaluation.active_list_items) - evaluation.list_item_count {
		return refuse(evaluation, {refusal = .Lists_Full, place = node.place, node = index})
	}
	first := evaluation.list_item_count
	evaluation.list_item_count += count
	place := first
	for item := node.first_child; item != lex_parser.NO_NODE; item = lex_parser.next_of(tree, item) {
		item_value := force(evaluation, item) or_return
		if !list_item_takes(item_value.kind) {
			return refuse(evaluation, {refusal = .List_Item_Kind, place = lex_parser.node_at(tree, item).place, node = item, left_kind = item_value.kind})
		}
		evaluation.active_list_items[place] = item_value
		place += 1
	}
	return {kind = .List, integer = i64(first), detail = u32(count)}, true
}

// refusal_inside gives the node of a subtree where the parse stopped, or
// NO_NODE: a Refused node, or a condition, a fact name or field names with
// their refusal.
@(private)
refusal_inside :: proc "contextless" (tree: ^lex_parser.Syntax_Tree, index: lex_parser.Node_Index) -> lex_parser.Node_Index {
	node := lex_parser.node_at(tree, index)
	if node == nil {
		return lex_parser.NO_NODE
	}
	if node.kind == .Refused || node.refusal != .None {
		return index
	}
	for child := node.first_child; child != lex_parser.NO_NODE; child = lex_parser.next_of(tree, child) {
		if found := refusal_inside(tree, child); found != lex_parser.NO_NODE {
			return found
		}
	}
	return lex_parser.NO_NODE
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

// is_lazy_record says if a value is a lazy record value of mode `declaration`.
is_lazy_record :: proc "contextless" (kind: Kind) -> bool {
	return kind == .Record_Literal || kind == .Record_With || kind == .Plan_Value || kind == .Project_Value
}

// with_compute gives `left with right`: the record on the left, with the
// fields of a literal on the right, or the record on the right when both
// have one description. In mode `declaration`, two lazy records compose
// lazily without forcing any fields.
@(private)
with_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, left, right: Value) -> (value: Value, ok: bool) {
	if evaluation.mode == .Declaration && is_lazy_record(left.kind) && is_lazy_record(right.kind) {
		if evaluation.with_pair_count >= len(evaluation.with_pairs) {
			return refuse(evaluation, {refusal = .With_Pairs_Full, place = node.place, node = index})
		}
		pair_index := evaluation.with_pair_count
		evaluation.with_pairs[pair_index] = {left = left, right = right}
		evaluation.with_pair_count += 1
		return {kind = .Record_With, integer = i64(pair_index)}, true
	}
	if left.kind == .Record {
		switch right.kind {
		case .Record_Literal:
			return literal_typed(evaluation, right, left.file, left.detail, left.record)
		case .Record:
			if !module.records_equal(left.file, left.detail, right.file, right.detail) {
				return refuse(evaluation, {refusal = .With_Records_Differ, place = node.place, node = index, file = left.file, detail = left.detail, other_file = right.file, other_detail = right.detail})
			}
			return right, true
		case .None, .Integer, .Text, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Enum, .Member, .Function, .List, .Hash, .Boolean, .Record_With, .Module_Ref, .Recipe_Ref, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
		}
	}
	return refuse(evaluation, {refusal = .With_Kinds, place = node.place, node = index, operator = .With, left_kind = left.kind, right_kind = right.kind})
}

// member_name_of gives the name of an untyped Member value (without its
// leading '.').
member_name_of :: proc "contextless" (evaluation: ^Evaluation, value: Value) -> string {
	slot := active_slot(evaluation, value.tree)
	if slot == nil || slot.tree == nil {
		return ""
	}
	text := lex_parser.node_text(slot.tree, lex_parser.Node_Index(value.integer))
	return len(text) > 0 && text[0] == '.' ? text[1:] : text
}

// comparison_compute evaluates `=`, `!=`, `<`, `<=`, `>`, `>=` and gives a
// Boolean value.
@(private)
comparison_compute :: proc "contextless" (evaluation: ^Evaluation, index: lex_parser.Node_Index, node: ^lex_parser.Node, left, right: Value) -> (value: Value, ok: bool) {
	equality_only := node.operator == .Equal || node.operator == .Not_Equal
	record := Refusal_Record {
		refusal    = .Operator_Kinds,
		place      = node.place,
		node       = index,
		operator   = node.operator,
		left_kind  = left.kind,
		right_kind = right.kind,
	}
	if left.kind != right.kind {
		return refuse(evaluation, record)
	}
	result := false
	switch left.kind {
	case .Integer:
		switch node.operator {
		case .Equal:
			result = left.integer == right.integer
		case .Not_Equal:
			result = left.integer != right.integer
		case .Less:
			result = left.integer < right.integer
		case .Less_Or_Equal:
			result = left.integer <= right.integer
		case .Greater:
			result = left.integer > right.integer
		case .Greater_Or_Equal:
			result = left.integer >= right.integer
		case .None, .Add, .Subtract, .Multiply, .Divide, .Remainder, .With:
			return refuse(evaluation, record)
		}
	case .Boolean:
		if !equality_only {
			return refuse(evaluation, record)
		}
		same := (left.integer != 0) == (right.integer != 0)
		result = node.operator == .Equal ? same : !same
	case .Text:
		if !equality_only {
			return refuse(evaluation, record)
		}
		same := left.text == right.text
		result = node.operator == .Equal ? same : !same
	case .Hash, .Module_Ref, .Recipe_Ref:
		if !equality_only {
			return refuse(evaluation, record)
		}
		lh, lok := hash_of(evaluation, left)
		rh, rok := hash_of(evaluation, right)
		if !lok || !rok {
			return refuse(evaluation, record)
		}
		same := lh == rh
		result = node.operator == .Equal ? same : !same
	case .Member:
		if !equality_only {
			return refuse(evaluation, record)
		}
		same := member_name_of(evaluation, left) == member_name_of(evaluation, right)
		result = node.operator == .Equal ? same : !same
	case .None, .Record, .Handle, .Table, .Bytes, .Stream, .Record_Input, .Record_Literal, .Enum, .Function, .List, .Record_With, .Follow_Ref, .Store_Ref, .Plan_Value, .Project_Value:
		return refuse(evaluation, record)
	}
	return {kind = .Boolean, integer = result ? 1 : 0}, true
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
	switch node.operator {
	case .Equal, .Not_Equal, .Less, .Less_Or_Equal, .Greater, .Greater_Or_Equal:
		return comparison_compute(evaluation, index, node, left, right)
	case .None, .Add, .Subtract, .Multiply, .Divide, .Remainder, .With:
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
	case .None, .With, .Equal, .Not_Equal, .Less, .Less_Or_Equal, .Greater, .Greater_Or_Equal:
		// Handled above.
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
