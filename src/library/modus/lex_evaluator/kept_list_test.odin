#+build !freestanding
#+build !modus
package lex_evaluator

import "core:strings"
import "core:testing"
import "modus:contract/errors"
import "modus:lex_parser"

// An evaluation with no list, whose items a test fills with list_items_add.
@(private = "file")
fresh_evaluation :: proc() -> ^Evaluation {
	bufs := new(lex_parser.Console_Tree_Buffers, context.temp_allocator)
	tree := new(lex_parser.Syntax_Tree, context.temp_allocator)
	lex_parser.parse_console("0", {}, bufs, tree)
	eval_bufs := new(Console_Eval_Buffers, context.temp_allocator)
	evaluation := new(Evaluation, context.temp_allocator)
	evaluation_start(evaluation, tree, .Console, {}, eval_bufs)
	return evaluation
}

// An evaluation whose pool of items has more room than a line has: a test
// of a kept list past its bounds needs a list that no line makes.
@(private = "file")
large_evaluation :: proc(items: int) -> ^Evaluation {
	bufs := new(lex_parser.Console_Tree_Buffers, context.temp_allocator)
	tree := new(lex_parser.Syntax_Tree, context.temp_allocator)
	lex_parser.parse_console("0", {}, bufs, tree)
	eval_bufs := new(Console_Eval_Buffers, context.temp_allocator)
	evaluation := new(Evaluation, context.temp_allocator)
	pools := console_eval_pools(eval_bufs)
	pools.list_items = make([]Value, items, context.temp_allocator)
	evaluation_start_with_pools(evaluation, tree, .Console, {}, pools)
	return evaluation
}

// list_of makes a List of the evaluation with the values.
@(private = "file")
list_of :: proc(t: ^testing.T, evaluation: ^Evaluation, values: []Host_Value) -> Host_Value {
	first, ok := list_items_add_host(evaluation, values)
	testing.expect(t, ok, "the items fit in the evaluation")
	vm_list := Value{kind = .List, data = u64(first), meta = u32(len(values))}
	return {kind = .List, integer = i64(first), detail = u32(len(values)), vm_value = vm_list}
}

@(private = "file")
integers :: proc(count: int, start := 0) -> []Host_Value {
	values := make([]Host_Value, count, context.temp_allocator)
	for &value, index in values {
		value = {kind = .Integer, integer = i64(start + index)}
	}
	return values
}

// The memory of a variable: its items and its bytes.
@(private = "file")
Kept :: struct {
	items: [KEPT_LIST_ITEM_CAPACITY]Host_Value,
	count: int,
	bytes: [KEPT_LIST_BYTE_CAPACITY]u8,
	top:   u32,
}

@(private = "file")
keep_into :: proc(t: ^testing.T, kept: ^Kept, evaluation: ^Evaluation, value: Host_Value) {
	keeping := new(List_Keeping, context.temp_allocator)
	result := list_keep(keeping, evaluation, value)
	testing.expect_value(t, result.refusal, List_Keep_Refusal.None)
	kept.count = list_keeping_commit(keeping, kept.items[:], kept.bytes[:])
	kept.top = value.detail
}

@(private = "file")
texts_of :: proc(evaluation: ^Evaluation, value: Host_Value) -> []string {
	texts := make([dynamic]string, context.temp_allocator)
	vm_val := value.vm_value.kind == .List ? value.vm_value : Value{kind = .List, data = u64(value.integer), meta = value.detail}
	for item in list_items_of(evaluation, vm_val) {
		if item.kind == .List {
			append(&texts, ..texts_of(evaluation, value_to_host(evaluation, item)))
		} else {
			append(&texts, value_text(evaluation, item))
		}
	}
	return texts[:]
}

// The bounds first: the bytes at the bound and one past, the items at the
// bound and one past, the items of nested lists counted in all; each
// refusal with its error record.
@(test)
a_kept_list_is_refused_past_its_bounds_with_an_error_record :: proc(t: ^testing.T) {
	keeping := new(List_Keeping, context.temp_allocator)
	whole := strings.repeat("a", KEPT_LIST_BYTE_CAPACITY, context.temp_allocator)
	evaluation := fresh_evaluation()
	at_bound := list_of(t, evaluation, {{kind = .Text, text = whole}})
	testing.expect_value(t, list_keep(keeping, evaluation, at_bound).refusal, List_Keep_Refusal.None)
	testing.expect_value(t, keeping.byte_count, KEPT_LIST_BYTE_CAPACITY)
	past := list_of(t, evaluation, {{kind = .Text, text = whole}, {kind = .Text, text = "b"}})
	result := list_keep(keeping, evaluation, past)
	testing.expect_value(t, result.refusal, List_Keep_Refusal.Bytes_Full)
	testing.expect_value(t, result.record, errors.error_make(.Over_Limit, .Bytes, 0, KEPT_LIST_BYTE_CAPACITY + 1, KEPT_LIST_BYTE_CAPACITY))
	// An empty text takes no byte, also at the bound.
	empty := list_of(t, evaluation, {{kind = .Text, text = whole}, {kind = .Text, text = ""}})
	testing.expect_value(t, list_keep(keeping, evaluation, empty).refusal, List_Keep_Refusal.None)

	evaluation = fresh_evaluation()
	items := list_of(t, evaluation, integers(KEPT_LIST_ITEM_CAPACITY))
	testing.expect_value(t, list_keep(keeping, evaluation, items).refusal, List_Keep_Refusal.None)
	testing.expect_value(t, keeping.item_count, KEPT_LIST_ITEM_CAPACITY)
	evaluation = large_evaluation(KEPT_LIST_ITEM_CAPACITY + 1)
	items = list_of(t, evaluation, integers(KEPT_LIST_ITEM_CAPACITY + 1))
	result = list_keep(keeping, evaluation, items)
	testing.expect_value(t, result.refusal, List_Keep_Refusal.Items_Full)
	testing.expect_value(t, result.record, errors.error_make(.Over_Limit, .None, 0, KEPT_LIST_ITEM_CAPACITY + 1, KEPT_LIST_ITEM_CAPACITY))

	// Two nested lists of the half of the bound less one item, and the two
	// lists: the bound in all, kept; one item more in a nested list:
	// refused.
	HALF :: KEPT_LIST_ITEM_CAPACITY / 2
	evaluation = large_evaluation(3 * KEPT_LIST_ITEM_CAPACITY)
	inner := list_of(t, evaluation, integers(HALF - 1))
	outer := list_of(t, evaluation, {inner, inner})
	testing.expect_value(t, list_keep(keeping, evaluation, outer).refusal, List_Keep_Refusal.None)
	testing.expect_value(t, keeping.item_count, KEPT_LIST_ITEM_CAPACITY)
	larger := list_of(t, evaluation, integers(HALF))
	outer = list_of(t, evaluation, {inner, larger})
	result = list_keep(keeping, evaluation, outer)
	testing.expect_value(t, result.refusal, List_Keep_Refusal.Items_Full)
	testing.expect_value(t, result.record.limit, i64(KEPT_LIST_ITEM_CAPACITY))
}

@(private = "file")
description_of_the_line :: proc "contextless" (file: []u8) -> bool {
	return len(file) == 3
}

// The items that no kept list holds: a function, a table, a hash, a record
// whose description lives in its line, a value of another kind; also inside
// a nested list. A record whose description stays is kept with its bytes.
@(test)
a_kept_list_refuses_the_items_of_its_line :: proc(t: ^testing.T) {
	keeping := new(List_Keeping, context.temp_allocator)
	line_file := []u8{1, 2, 3}
	module_file := []u8{1, 2, 3, 4}
	record := []u8{9, 8, 7, 6}
	Case :: struct {
		item:    Host_Value,
		refusal: List_Keep_Refusal,
	}
	cases := []Case {
		{{kind = .Function}, .Function},
		{{kind = .Table, record = record}, .Table},
		{{kind = .Hash}, .Hash},
		{{kind = .Record, file = line_file, record = record}, .Description_Of_Line},
		{{kind = .Bytes, record = record}, .Kind},
		{{kind = .Stream}, .Kind},
	}
	for item in cases {
		evaluation := fresh_evaluation()
		alone := list_of(t, evaluation, {{kind = .Integer, integer = 1}, item.item})
		result := list_keep(keeping, evaluation, alone, description_of_the_line)
		testing.expectf(t, result.refusal == item.refusal && result.kind == item.item.kind, "%v: %v %v", item.item.kind, result.refusal, result.kind)
		nested := list_of(t, evaluation, {alone})
		testing.expect_value(t, list_keep(keeping, evaluation, nested, description_of_the_line).refusal, item.refusal)
	}
	evaluation := fresh_evaluation()
	kept_record := list_of(t, evaluation, {{kind = .Record, file = module_file, record = record}})
	testing.expect_value(t, list_keep(keeping, evaluation, kept_record, description_of_the_line).refusal, List_Keep_Refusal.None)
	testing.expect(t, raw_data(keeping.items[0].record) != raw_data(record))
	testing.expect_value(t, keeping.items[0].record[3], u8(6))
}

// A line reads a full kept list among the items of its evaluation: one
// fits, the second is refused with its error record and adds nothing.
@(test)
two_full_kept_lists_do_not_fit_in_one_line :: proc(t: ^testing.T) {
	kept := new(Kept, context.temp_allocator)
	source := fresh_evaluation()
	keep_into(t, kept, source, list_of(t, source, integers(KEPT_LIST_ITEM_CAPACITY)))
	evaluation := fresh_evaluation()
	value, _, ok := kept_list_read(evaluation, kept.items[:kept.count], kept.top)
	testing.expect(t, ok)
	testing.expect_value(t, value.integer, 0)
	record: errors.Error_Record
	_, record, ok = kept_list_read(evaluation, kept.items[:kept.count], kept.top)
	testing.expect(t, !ok)
	testing.expect_value(t, record, errors.error_make(.Over_Limit, .None, 0, 2 * KEPT_LIST_ITEM_CAPACITY, LIST_ITEM_CAPACITY))
	testing.expect_value(t, evaluation.list_item_count, LIST_ITEM_CAPACITY)
}

// y = x keeps a copy: a new value of x leaves y. x = [x, x] reads the old
// items of x while the new list goes into the same memory.
@(test)
a_kept_list_is_a_copy_that_its_own_change_reads :: proc(t: ^testing.T) {
	x := new(Kept, context.temp_allocator)
	y := new(Kept, context.temp_allocator)
	first := fresh_evaluation()
	keep_into(t, x, first, list_of(t, first, {{kind = .Text, text = "ab"}, {kind = .Text, text = "cd"}}))

	second := fresh_evaluation()
	read, _, ok := kept_list_read(second, x.items[:x.count], x.top)
	testing.expect(t, ok)
	keep_into(t, y, second, read)
	keep_into(t, x, second, list_of(t, second, {{kind = .Text, text = "zz"}}))
	third := fresh_evaluation()
	y_read, _, _ := kept_list_read(third, y.items[:y.count], y.top)
	y_texts := texts_of(third, y_read)
	testing.expect_value(t, len(y_texts), 2)
	testing.expect_value(t, y_texts[0], "ab")
	testing.expect_value(t, y_texts[1], "cd")

	// x = [y, y] into y itself, through the copy.
	fourth := fresh_evaluation()
	y_read, _, _ = kept_list_read(fourth, y.items[:y.count], y.top)
	keep_into(t, y, fourth, list_of(t, fourth, {y_read, y_read}))
	testing.expect_value(t, y.count, 6)
	fifth := fresh_evaluation()
	y_read, _, _ = kept_list_read(fifth, y.items[:y.count], y.top)
	texts := texts_of(fifth, y_read)
	testing.expect_value(t, len(texts), 4)
	for text, index in texts {
		testing.expect_value(t, text, index % 2 == 0 ? "ab" : "cd")
	}
	for item in list_items_of(fifth, y_read.vm_value) {
		testing.expect_value(t, item.kind, Kind.List)
		testing.expect_value(t, item.meta, u32(2))
	}
}
